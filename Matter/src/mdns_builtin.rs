//! mDNS advertisement without Bonjour (Windows): rs-matter's builtin
//! responder on a socket of our own.
//!
//! Windows' DNS-SD API (DnsServiceRegister) cannot publish the `_L`/`_S`/`_CM`
//! subtypes a commissioner browses for, so the records are served here
//! instead. The socket shares UDP 5353 with Windows' own mDNS service (and
//! browsers'): every socket in the group gets each multicast query, and each
//! answers only for its own names. The host name is the pairing serial, so it
//! never collides with the computer's name or with the other helper.
//!
//! Same contract as the Bonjour version: a failure (no usable interface,
//! 5353 not bindable, the responder erroring out) emits `mdns ok:false` once
//! per failure streak and is retried (2 s, doubling to 30 s); `ok:true` once it
//! runs again. A change of interface or address restarts it silently.

use core::pin::pin;

use embassy_futures::select::{select, Either};
use embassy_time::Timer;
use log::{info, warn};
use rs_matter::crypto::Crypto;
use rs_matter::transport::network::mdns::builtin::{BuiltinMdns, Host};
use rs_matter::Matter;

use crate::device::Fatal;
use crate::lan::{mdns_socket, Lan};
use crate::proto::{emit, Event};

const RETRY_FIRST_SECS: u64 = 2;
const RETRY_MAX_SECS: u64 = 30;
/// How often the interface is looked at again.
const NETWORK_POLL_SECS: u64 = 10;

/// Keeps the node's current services advertised; never returns.
pub async fn run<C: Crypto>(matter: &Matter<'_>, crypto: C, serial: &str) -> Result<(), Fatal> {
    let mut retry_secs = RETRY_FIRST_SECS;
    let mut failing = false;
    loop {
        let error = match advertise(matter, &crypto, serial, &mut || {
            if failing {
                info!("mDNS recovered");
                emit(&Event::Mdns { ok: true });
                failing = false;
                retry_secs = RETRY_FIRST_SECS;
            }
        })
        .await
        {
            Ok(()) => continue,
            Err(e) => e,
        };
        if failing {
            info!("mDNS failed again ({error}); retry in {retry_secs} s");
        } else {
            warn!("mDNS failed ({error})");
            emit(&Event::Mdns { ok: false });
            failing = true;
        }
        Timer::after_secs(retry_secs).await;
        retry_secs = (retry_secs * 2).min(RETRY_MAX_SECS);
    }
}

/// Runs the responder until the network changes (Ok) or something fails.
/// `up` is called once the socket is ready.
async fn advertise<C: Crypto>(
    matter: &Matter<'_>,
    crypto: &C,
    serial: &str,
    up: &mut dyn FnMut(),
) -> Result<(), String> {
    let lan = Lan::pick()?;
    let socket = mdns_socket(&lan).map_err(|e| format!("UDP 5353 on {}: {e}", lan.name))?;
    let socket = async_io::Async::new(socket).map_err(|e| e.to_string())?;
    info!(
        "mDNS on {} (#{}) {} {:?}",
        lan.name, lan.index, lan.ipv4, lan.ipv6
    );
    up();
    let host = Host {
        hostname: serial,
        ip: lan.ipv4.octets().into(),
        ipv6: &lan
            .ipv6
            .iter()
            .map(|ip| ip.octets().into())
            .collect::<Vec<_>>(),
    };
    let ipv6_interface = (!lan.ipv6.is_empty()).then_some(lan.index);
    let mut mdns = BuiltinMdns::new();
    let responder = pin!(mdns.run(
        &socket,
        &socket,
        &host,
        Some(lan.ipv4.octets().into()),
        ipv6_interface,
        matter,
        crypto,
    ));
    let moved = pin!(async {
        loop {
            Timer::after_secs(NETWORK_POLL_SECS).await;
            if Lan::pick().as_ref() != Ok(&lan) {
                return;
            }
        }
    });
    match select(responder, moved).await {
        Either::First(Ok(())) => Err("responder stopped".into()),
        Either::First(Err(e)) => Err(e.to_string()),
        Either::Second(()) => {
            info!("network changed; advertising again");
            Ok(())
        }
    }
}
