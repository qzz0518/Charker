//! charker-matter: exposes a Charker charger's ports to Matter (Apple Home).
//! The app spawns it as a child process and talks JSON lines over stdin/stdout.
//!
//! Protocol v1.2
//!
//! Launch: `charker-matter --storage <dir> --name <name> --ports <l1,l2,...> [--udp-port <n>] [--bridge]`
//! - `--storage`: created if missing; holds `pairing.json` + the Matter KV files.
//!   Deleting it resets pairing.
//! - `--name`: BasicInformation ProductName/ProductLabel and the mDNS DN.
//! - `--ports`: exactly 3 or 5 labels; port index i <-> endpoint i+1.
//! - `--udp-port`: default 5540; if taken, an ephemeral port (mDNS advertises it).
//! - `--bridge`: a bridge instead. EP1 is an Aggregator and port index i <->
//!   bridged endpoint i+2, Bridged Device Basic Information NodeLabel = its label
//!   (Home's tile name; at most 32 bytes), ProductName = `--name`, SerialNumber
//!   and UniqueID = `<serial>-<i>`. stdin/stdout are the same in both modes.
//! - `RUST_LOG`: default `warn`.
//!
//! Runs until stdin EOF or `{"type":"shutdown"}`, then exits 0. A fatal error
//! emits an `error` event and exits non-zero. An mDNS failure is not fatal.
//!
//! stdin, host -> helper (latest value wins; malformed lines are logged and ignored):
//! - `{"type":"port","index":0,"on":true,"voltage_mv":20000,"current_ma":1500,"power_mw":30000}`
//! - `{"type":"shutdown"}`
//!
//! stdout, helper -> host (one flushed line per event):
//! - `{"type":"onboarding","qr":"MT:...","manual_code":"34970112332"}` once after startup
//! - `{"type":"fabrics","count":2}` after startup and on every change. 0 while the
//!   helper's own commissioning window is open, so a fabric being commissioned
//!   counts only once CommissioningComplete closes the window.
//! - `{"type":"command","index":0,"on":false}` a controller switched a port (never
//!   for the OnOff startup restore). OnOff already shows `on`; the host MUST answer
//!   with a `port` line carrying the real state, which flips Home back on refusal.
//! - `{"type":"mdns","ok":false}` mDNS registration failed (macOS: Local Network
//!   access denied? Windows: no usable interface or UDP 5353), once per failure streak. UDP stays up and registration is retried
//!   (2 s, doubling to 30 s); `{"type":"mdns","ok":true}` once it succeeds again.
//! - `{"type":"error","code":"bind|storage|config|internal","message":"..."}`
//!
//! Until the first `port` line for an index that port reads off, 0 V/0 A/0 W.
//! Passcode, discriminator and serial are generated once into `pairing.json`.
//! Cumulative energy is integrated here from `power_mw` and kept per port in the
//! storage dir, so it survives restarts and resets only with pairing.
//!
//! Known upstream race: a `port` line changing `on` and a controller command
//! landing in the same poll share rs-matter's latest-wins OnOff signal, so the
//! command can be dropped (no `command` event); OnOff still ends at the real state.
#![recursion_limit = "512"]

mod device;
#[cfg(not(target_os = "macos"))]
mod lan;
#[cfg_attr(not(target_os = "macos"), path = "mdns_builtin.rs")]
mod mdns;
mod proto;
mod storage;

use std::io::BufRead;
use std::path::PathBuf;
use std::process::exit;
use std::time::Duration;

use log::warn;

use proto::{emit, Event, HostLine};

/// ProductName / NodeLabel / mDNS DN limit.
const MAX_NAME_LEN: usize = 32;

#[derive(Debug, PartialEq)]
struct Args {
    storage: PathBuf,
    name: String,
    ports: Vec<String>,
    udp_port: u16,
    bridge: bool,
}

fn parse_args(mut args: impl Iterator<Item = String>) -> Result<Args, String> {
    let (mut storage, mut name, mut ports, mut udp_port) = (None, None, None, 5540);
    let mut bridge = false;
    while let Some(flag) = args.next() {
        let mut value = || args.next().ok_or_else(|| format!("{flag} needs a value"));
        match flag.as_str() {
            "--storage" => storage = Some(PathBuf::from(value()?)),
            "--name" => name = Some(value()?),
            "--ports" => ports = Some(value()?),
            "--udp-port" => {
                let v = value()?;
                udp_port = v
                    .parse()
                    .map_err(|_| format!("--udp-port {v:?} is not a UDP port"))?;
            }
            "--bridge" => bridge = true,
            _ => return Err(format!("unknown argument {flag:?}")),
        }
    }
    let storage = storage
        .filter(|s| !s.as_os_str().is_empty())
        .ok_or("--storage is required")?;
    let name = name
        .filter(|n| !n.trim().is_empty())
        .ok_or("--name is required")?;
    if name.len() > MAX_NAME_LEN {
        return Err(format!("--name is longer than {MAX_NAME_LEN} bytes"));
    }
    let ports: Vec<String> = ports
        .ok_or("--ports is required")?
        .split(',')
        .map(|l| l.trim().to_string())
        .collect();
    if !matches!(ports.len(), 3 | 5) || ports.iter().any(String::is_empty) {
        return Err(format!(
            "--ports needs exactly 3 or 5 non-empty labels, got {ports:?}"
        ));
    }
    if let Some(l) = ports.iter().find(|l| bridge && l.len() > MAX_NAME_LEN) {
        return Err(format!(
            "--ports label {l:?} is longer than {MAX_NAME_LEN} bytes"
        ));
    }
    Ok(Args {
        storage,
        name,
        ports,
        udp_port,
        bridge,
    })
}

fn fail(code: &str, message: &str) -> ! {
    log::error!("{code}: {message}");
    emit(&Event::Error { code, message });
    exit(1)
}

/// stdin loop; returns on EOF, read error or `shutdown`.
fn read_host(ports: usize) {
    let mut stdin = std::io::stdin().lock();
    let mut buf = Vec::new();
    loop {
        buf.clear();
        match stdin.read_until(b'\n', &mut buf) {
            Ok(0) => return,
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => {
                warn!("stdin: {e}");
                return;
            }
        }
        let line = String::from_utf8_lossy(&buf);
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        match proto::parse_host_line(line) {
            Ok(HostLine::Port {
                index,
                on,
                voltage_mv,
                current_ma,
                power_mw,
            }) if index < ports => {
                device::PORTS[index].update(on, voltage_mv, current_ma, power_mw)
            }
            Ok(HostLine::Port { index, .. }) => warn!("ignoring port {index}: only {ports} ports"),
            Ok(HostLine::Shutdown) => return,
            Err(e) => warn!("ignoring host line {line:?}: {e}"),
        }
    }
}

fn main() {
    let mut logger = env_logger::Builder::new();
    logger.parse_filters(&std::env::var("RUST_LOG").unwrap_or_else(|_| "warn".into()));
    logger.target(env_logger::Target::Stderr).init();

    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        default_hook(info);
        emit(&Event::Error {
            code: "internal",
            message: &format!("panic: {info}"),
        });
        std::process::abort();
    }));

    let args = parse_args(std::env::args().skip(1)).unwrap_or_else(|m| fail("config", &m));
    let pairing =
        storage::Pairing::load_or_create(&args.storage).unwrap_or_else(|m| fail("storage", &m));

    let ports = args.ports.len();
    std::thread::spawn(move || {
        read_host(ports);
        // Let the Matter thread stop between two polls; exit anyway if it is
        // stuck (e.g. in astro's mDNS register, which blocks up to 10 s).
        device::SHUTDOWN.signal(());
        std::thread::sleep(Duration::from_millis(500));
        exit(0);
    });

    let cfg = device::Config {
        storage: &args.storage,
        name: &args.name,
        labels: &args.ports,
        udp_port: args.udp_port,
        bridge: args.bridge,
    };
    match device::run(&cfg, &pairing) {
        Ok(()) => exit(0),
        Err(f) => fail(f.code, &f.message),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(s: &str) -> Result<Args, String> {
        parse_args(s.split(' ').map(String::from))
    }

    #[test]
    fn args() {
        let a = parse_args(
            [
                "--storage",
                "/tmp/x",
                "--name",
                "Charker 250W",
                "--ports",
                "C1,C2,C3,C4,USB-A",
                "--udp-port",
                "5560",
            ]
            .map(String::from)
            .into_iter(),
        )
        .unwrap();
        assert_eq!(a.name, "Charker 250W");
        assert_eq!(a.ports.len(), 5);
        assert_eq!(a.udp_port, 5560);
        assert!(!a.bridge);
        assert_eq!(
            parse("--storage /tmp/x --name N --ports C1,C2,C3")
                .unwrap()
                .udp_port,
            5540
        );
    }

    #[test]
    fn bridge_args() {
        assert!(
            parse("--bridge --storage /tmp/x --name N --ports C1,C2,C3,C4,A")
                .unwrap()
                .bridge
        );
        let with_ports = |ports: &str, bridge: bool| {
            let mut a = vec!["--storage", "/tmp/x", "--name", "N", "--ports", ports];
            if bridge {
                a.push("--bridge");
            }
            parse_args(a.into_iter().map(String::from))
        };
        // 32 bytes, 12 chars
        let longest = format!("C1,C2,{}AB", "端".repeat(10));
        assert!(with_ports(&longest, true).is_ok());
        assert!(with_ports(&format!("{longest}C"), true).is_err());
        assert!(with_ports(&format!("{longest}C"), false).is_ok());
    }

    #[test]
    fn bad_args() {
        for s in [
            "--name N --ports C1,C2,C3",
            "--storage /tmp/x --ports C1,C2,C3",
            "--storage /tmp/x --name N",
            "--storage /tmp/x --name N --ports C1,C2",
            "--storage /tmp/x --name N --ports C1,C2,C3,C4",
            "--storage /tmp/x --name N --ports C1,,C3",
            "--storage /tmp/x --name N --ports C1,C2,C3 --udp-port 70000",
            "--storage /tmp/x --name N --ports C1,C2,C3 --udp-port",
            "--storage /tmp/x --name N --ports C1,C2,C3 --bridge 1",
            "--storage /tmp/x --name 123456789012345678901234567890123 --ports C1,C2,C3",
        ] {
            assert!(parse(s).is_err(), "{s}");
        }
    }
}
