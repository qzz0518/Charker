//! Sockets and the LAN interface where there is no Bonjour (Windows).
//!
//! - Every socket is dual-stack: Windows defaults IPV6_V6ONLY to on, so a
//!   plain `[::]` bind would never hear IPv4.
//! - On Windows an ICMP port unreachable for an earlier send makes the next
//!   `recv_from` fail with WSAECONNRESET, which would end the Matter
//!   transport or the mDNS responder; that report is switched off.
//! - mDNS goes out on one interface: the one the default route uses, so a
//!   Hyper-V / WSL switch or a VPN adapter is not picked over the real LAN.

use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV6, UdpSocket};

use rs_matter::transport::network::mdns::{
    MDNS_IPV4_BROADCAST_ADDR, MDNS_IPV6_BROADCAST_ADDR, MDNS_PORT,
};
use socket2::{Domain, Protocol, Socket, Type};

/// A dual-stack UDP socket on `[::]:port`; `reuse` lets it share the port
/// (mDNS, next to the system's own responder and other apps).
fn dual_stack(port: u16, reuse: bool) -> io::Result<Socket> {
    let socket = Socket::new(Domain::IPV6, Type::DGRAM, Some(Protocol::UDP))?;
    if reuse {
        socket.set_reuse_address(true)?;
    }
    socket.set_only_v6(false)?;
    socket.bind(&SocketAddr::V6(SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, port, 0, 0)).into())?;
    ignore_icmp_resets(&socket)?;
    Ok(socket)
}

/// The Matter socket. `addr` is always `[::]:port`.
pub fn udp_bind(addr: SocketAddr) -> io::Result<UdpSocket> {
    Ok(dual_stack(addr.port(), false)?.into())
}

/// The mDNS socket on `[::]:5353`, in the mDNS groups on `lan` and sending
/// through it.
pub fn mdns_socket(lan: &Lan) -> io::Result<UdpSocket> {
    let socket = dual_stack(MDNS_PORT, true)?;
    socket.join_multicast_v4(&MDNS_IPV4_BROADCAST_ADDR, &lan.ipv4)?;
    socket.set_multicast_if_v4(&lan.ipv4)?;
    if !lan.ipv6.is_empty() {
        socket.join_multicast_v6(&MDNS_IPV6_BROADCAST_ADDR, lan.index)?;
        socket.set_multicast_if_v6(lan.index)?;
    }
    Ok(socket.into())
}

#[cfg(windows)]
fn ignore_icmp_resets(socket: &Socket) -> io::Result<()> {
    use std::os::windows::io::AsRawSocket;
    use windows_sys::Win32::Networking::WinSock::{
        WSAIoctl, SIO_UDP_CONNRESET, SIO_UDP_NETRESET, SOCKET,
    };
    for code in [SIO_UDP_CONNRESET, SIO_UDP_NETRESET] {
        let off: u32 = 0;
        let mut returned = 0u32;
        // SAFETY: a valid socket, a 4-byte BOOL in, nothing out, no overlap.
        let rc = unsafe {
            WSAIoctl(
                socket.as_raw_socket() as SOCKET,
                code,
                (&off as *const u32).cast(),
                4,
                std::ptr::null_mut(),
                0,
                &mut returned,
                std::ptr::null_mut(),
                None,
            )
        };
        if rc != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

#[cfg(not(windows))]
fn ignore_icmp_resets(_: &Socket) -> io::Result<()> {
    Ok(())
}

/// The interface mDNS is published on, and the addresses it advertises.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Lan {
    pub name: String,
    pub index: u32,
    pub ipv4: Ipv4Addr,
    /// Every IPv6 address of the interface, link-local first. Empty when it
    /// has none: then no AAAA record and no IPv6 multicast.
    pub ipv6: Vec<Ipv6Addr>,
}

/// One address of one interface, as `if_addrs` lists them.
#[derive(Debug, Clone)]
struct Addr {
    name: String,
    index: u32,
    ip: IpAddr,
    up: bool,
}

/// Adapters the fallback never picks: virtual switches, VPNs, tunnels.
const VIRTUAL: &[&str] = &[
    "vethernet",
    "virtual",
    "vmware",
    "vbox",
    "hyper-v",
    "wsl",
    "docker",
    "loopback",
    "tailscale",
    "zerotier",
    "vpn",
    "tap",
    "tun",
];

impl Lan {
    pub fn pick() -> Result<Lan, String> {
        let addrs = if_addrs::get_if_addrs()
            .map_err(|e| format!("listing interfaces: {e}"))?
            .into_iter()
            .map(|i| Addr {
                up: i.is_oper_up(),
                index: i.index.unwrap_or(0),
                ip: i.ip(),
                name: i.name,
            })
            .collect::<Vec<_>>();
        choose(&addrs, default_route_v4())
    }
}

/// The local IPv4 address the default route leaves from. Connecting a UDP
/// socket only selects the route; nothing is sent.
fn default_route_v4() -> Option<Ipv4Addr> {
    let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).ok()?;
    socket.connect((Ipv4Addr::new(8, 8, 8, 8), 53)).ok()?;
    match socket.local_addr().ok()?.ip() {
        IpAddr::V4(ip) if !ip.is_unspecified() => Some(ip),
        _ => None,
    }
}

/// The interface holding `routed`, else the first up, non-virtual one with a
/// private (or at least non-link-local) IPv4 address.
fn choose(addrs: &[Addr], routed: Option<Ipv4Addr>) -> Result<Lan, String> {
    let usable = |a: &&Addr| match a.ip {
        IpAddr::V4(ip) => a.up && !ip.is_loopback() && !ip.is_link_local() && !ip.is_unspecified(),
        IpAddr::V6(_) => false,
    };
    let is_virtual = |a: &&Addr| {
        let name = a.name.to_lowercase();
        VIRTUAL.iter().any(|v| name.contains(v))
    };
    let found = routed
        .and_then(|r| addrs.iter().filter(usable).find(|a| a.ip == IpAddr::V4(r)))
        .or_else(|| {
            let real = || addrs.iter().filter(usable).filter(|a| !is_virtual(a));
            real()
                .find(|a| matches!(a.ip, IpAddr::V4(ip) if ip.is_private()))
                .or_else(|| real().next())
        })
        .ok_or("no network interface with an IPv4 address")?;
    let IpAddr::V4(ipv4) = found.ip else {
        unreachable!("usable() keeps IPv4 only")
    };
    let same = |a: &&Addr| a.name == found.name;
    let mut ipv6: Vec<Ipv6Addr> = addrs
        .iter()
        .filter(same)
        .filter_map(|a| match a.ip {
            IpAddr::V6(ip) if !ip.is_loopback() && !ip.is_unspecified() => Some(ip),
            _ => None,
        })
        .collect();
    ipv6.sort_by_key(|ip| !ip.is_unicast_link_local());
    ipv6.dedup();
    Ok(Lan {
        name: found.name.clone(),
        index: found.index,
        ipv4,
        ipv6,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn addr(name: &str, index: u32, ip: &str) -> Addr {
        Addr {
            name: name.into(),
            index,
            ip: ip.parse().unwrap(),
            up: true,
        }
    }

    /// The test PC: a Hyper-V switch with IPv4 + IPv6, the LAN with IPv4 only.
    fn windows_pc() -> Vec<Addr> {
        vec![
            addr("vEthernet (Default Switch)", 9, "fe80::131:9d2b:967d:de66"),
            addr("Loopback Pseudo-Interface 1", 1, "::1"),
            addr("vEthernet (Default Switch)", 9, "172.18.112.1"),
            addr("以太网", 23, "192.168.1.20"),
            addr("Loopback Pseudo-Interface 1", 1, "127.0.0.1"),
        ]
    }

    #[test]
    fn picks_the_routed_interface() {
        let lan = choose(&windows_pc(), Some("192.168.1.20".parse().unwrap())).unwrap();
        assert_eq!(lan.name, "以太网");
        assert_eq!(lan.index, 23);
        assert!(lan.ipv6.is_empty());
    }

    #[test]
    fn falls_back_to_a_real_private_interface() {
        let lan = choose(&windows_pc(), None).unwrap();
        assert_eq!(lan.ipv4, "192.168.1.20".parse::<Ipv4Addr>().unwrap());
        // A route through an address no interface has (VPN) falls back too.
        let lan = choose(&windows_pc(), Some("10.8.0.2".parse().unwrap())).unwrap();
        assert_eq!(lan.index, 23);
    }

    #[test]
    fn collects_every_ipv6_link_local_first() {
        let mut addrs = windows_pc();
        addrs.push(addr("以太网", 23, "2001:db8::5"));
        addrs.push(addr("以太网", 23, "fe80::1"));
        let lan = choose(&addrs, Some("192.168.1.20".parse().unwrap())).unwrap();
        assert_eq!(
            lan.ipv6,
            vec![
                "fe80::1".parse::<Ipv6Addr>().unwrap(),
                "2001:db8::5".parse().unwrap()
            ]
        );
    }

    /// Loopback only, so no firewall prompt on Windows.
    #[test]
    fn an_icmp_unreachable_does_not_fail_the_next_recv() {
        use std::time::Duration;
        let socket = |quiet: bool| {
            let s = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP)).unwrap();
            s.bind(&SocketAddr::from((Ipv4Addr::LOCALHOST, 0)).into())
                .unwrap();
            if quiet {
                ignore_icmp_resets(&s).unwrap();
            }
            let s: UdpSocket = s.into();
            s.set_read_timeout(Some(Duration::from_millis(300)))
                .unwrap();
            s
        };
        let closed = {
            let s = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
            s.local_addr().unwrap()
        };
        let recv_after_unreachable = |s: &UdpSocket| {
            s.send_to(b"x", closed).unwrap();
            s.recv_from(&mut [0; 8]).unwrap_err().kind()
        };
        let quiet = recv_after_unreachable(&socket(true));
        assert!(
            matches!(quiet, io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut),
            "{quiet:?}"
        );
        // Proves the test reaches the case on Windows.
        #[cfg(windows)]
        assert_eq!(
            recv_after_unreachable(&socket(false)),
            io::ErrorKind::ConnectionReset
        );
    }

    #[test]
    fn skips_down_loopback_and_link_local() {
        let mut down = addr("Wi-Fi", 5, "192.168.1.10");
        down.up = false;
        let addrs = vec![
            down,
            addr("Loopback", 1, "127.0.0.1"),
            addr("Ethernet 2", 7, "169.254.3.4"),
        ];
        assert!(choose(&addrs, None).is_err());
    }
}
