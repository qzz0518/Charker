//! mDNS advertisement through the system DNS-SD daemon (astro-dnssd).
//!
//! Replaces rs-matter's `AstroMdns`, which ends on the first failed
//! registration and, run again, waits for the next service change before
//! retrying. macOS may deny Local Network access before the user answers the
//! alert, and a process that exits right after such a failure may never get
//! the alert (TN3179, FB16131937), so a failure here is retried while UDP keeps
//! running. Publish only: this node never resolves or browses.

use std::collections::hash_map::{Entry, HashMap};

use astro_dnssd::{DNSServiceBuilder, RegisteredDnsService};
use embassy_time::Timer;
use log::{info, warn};
use rs_matter::transport::network::MatterLocalService;
use rs_matter::Matter;

use crate::device::Fatal;
use crate::proto::{emit, Event};

const RETRY_FIRST_SECS: u64 = 2;
const RETRY_MAX_SECS: u64 = 30;

/// Keeps the node's current services registered; never returns. Emits
/// `mdns ok:false` once per failure streak and `ok:true` when it recovers.
pub async fn run(matter: &Matter<'_>) -> Result<(), Fatal> {
    let mut registered = HashMap::new();
    let mut retry_secs = RETRY_FIRST_SECS;
    let mut failing = false;
    loop {
        match sync(matter, &mut registered) {
            Ok(()) => {
                // Nothing to publish (between two commissioning windows) is
                // no recovery yet.
                if failing && !registered.is_empty() {
                    info!("mDNS registration recovered");
                    emit(&Event::Mdns { ok: true });
                    failing = false;
                    retry_secs = RETRY_FIRST_SECS;
                }
                matter.transport().wait_mdns().await;
            }
            Err(e) => {
                if failing {
                    info!("mDNS registration failed again ({e}); retry in {retry_secs} s");
                } else {
                    warn!("mDNS registration failed ({e}); Local Network access denied?");
                    emit(&Event::Mdns { ok: false });
                    failing = true;
                }
                Timer::after_secs(retry_secs).await;
                retry_secs = (retry_secs * 2).min(RETRY_MAX_SECS);
            }
        }
    }
}

/// Drops (deregisters) what is gone and registers what is missing; on an
/// error the registrations made so far are kept.
fn sync(
    matter: &Matter<'_>,
    registered: &mut HashMap<MatterLocalService, RegisteredDnsService>,
) -> Result<(), String> {
    let mut services = Vec::new();
    matter
        .mdns_services(|s| {
            services.push(s);
            Ok(())
        })
        .map_err(|e| e.to_string())?;
    registered.retain(|s, _| services.contains(s));
    for service in services {
        if let Entry::Vacant(slot) = registered.entry(service) {
            let handle = register(matter, slot.key())?;
            info!("mDNS: registered {:?}", slot.key());
            slot.insert(handle);
        }
    }
    Ok(())
}

/// Blocks until the daemon answers (astro waits up to 10 s for the callback).
/// The error carries the raw DNS-SD code, e.g. -65570 PolicyDenied when Local
/// Network access is denied; 0 means no answer in time.
fn register(
    matter: &Matter<'_>,
    service: &MatterLocalService,
) -> Result<RegisteredDnsService, String> {
    let mut buf = [0u8; 512];
    let (s, _) = service
        .service(matter, &mut buf)
        .map_err(|e| e.to_string())?;
    // DNSServiceRegister's subtype syntax: `_type._proto,_sub1,_sub2`.
    let mut regtype = s.service_protocol.to_string();
    for sub in s.service_subtypes {
        regtype.push(',');
        regtype.push_str(sub);
    }
    let mut builder = DNSServiceBuilder::new(&regtype, s.port).with_name(s.name);
    for (k, v) in s.txt_kvs {
        builder = builder.with_key_value(k.to_string(), v.to_string());
    }
    builder.register().map_err(|e| format!("{regtype}: {e}"))
}
