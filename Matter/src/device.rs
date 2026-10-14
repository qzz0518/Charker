//! The Matter node: root endpoint + one endpoint per charger port (port i =
//! endpoint i+1), each an On/Off Plug-in Unit (0x010A) + Electrical Sensor
//! (0x0510) with OnOff, ElectricalPowerMeasurement (DC),
//! ElectricalEnergyMeasurement (IMPE|CUME) and PowerTopology (TREE).
//! As a bridge, EP1 is an Aggregator and port i = endpoint i+2, also a
//! Bridged Node (0x0013) with Bridged Device Basic Information.
//!
//! The stack runs single-threaded on the caller's thread (rs-matter is built
//! WITHOUT `sync-mutex`, so nothing of it may be touched from another thread):
//! - host -> Matter: `Port::update` (stdin thread) stores atomics and signals
//!   `embassy_sync` signals; the cluster hooks' `run()` futures (polled by
//!   `InteractionModel::run`) await them and `notify(...)` their handler,
//!   which bumps the dataver and reports to subscribers.
//! - Matter -> host: `OnOffHooks::set_on_off` emits a `command` event.

use core::pin::pin;

use std::net::{Ipv6Addr, SocketAddr, SocketAddrV6, UdpSocket};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, AtomicU8, Ordering::Relaxed};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use embassy_futures::select::{select, select3, select4, Either};
use embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex;
use embassy_sync::signal::Signal;
use embassy_time::Timer;
use embassy_time_queue_utils as _;

use log::{info, warn};
use rand::Rng;

use rs_matter::crypto::{default_crypto, Crypto};
use rs_matter::dm::clusters::app::elec_energy_meas::{
    self, ElecEnergyMeasHooks, EnergyMeasurement, Timestamp,
};
use rs_matter::dm::clusters::app::elec_pwr_meas::{self, ElecPwrMeasHooks, PowerModeEnum};
use rs_matter::dm::clusters::app::measurement::{MeasurementAccuracy, MeasurementAccuracyRange};
use rs_matter::dm::clusters::app::on_off::{
    self, EffectVariantEnum, NoLevelControl, OnOffHandler, OnOffHooks, OutOfBandMessage,
};
use rs_matter::dm::clusters::app::power_topology;
use rs_matter::dm::clusters::basic_info::BasicInfoConfig;
use rs_matter::dm::clusters::decl::bridged_device_basic_information as bdbi;
use rs_matter::dm::clusters::decl::globals::MeasurementTypeEnum;
use rs_matter::dm::clusters::desc::{self, ClusterHandler as _};
use rs_matter::dm::clusters::groups::{self, ClusterHandler as _};
use rs_matter::dm::clusters::identify::{self, IdentifyHandler};
use rs_matter::dm::devices::test::{DAC_PRIVKEY, TEST_DEV_ATT, TEST_PID, TEST_VID};
use rs_matter::dm::devices::{
    DEV_TYPE_AGGREGATOR, DEV_TYPE_BRIDGED_NODE, DEV_TYPE_ELECTRICAL_SENSOR,
};
use rs_matter::dm::endpoints;
use rs_matter::dm::networks::eth::EthNetwork;
use rs_matter::dm::networks::SysNetifs;
use rs_matter::dm::{
    Async, Cluster, DataModel, Dataver, DeviceType, Endpoint, EndptId, InvokeContext, Node,
    ReadContext,
};
use rs_matter::error::{Error, ErrorCode};
use rs_matter::im::{EthInteractionModelState, InteractionModel};
use rs_matter::pairing::qr::{no_optional_data, CommFlowType, NoOptionalData, QrPayload};
use rs_matter::pairing::DiscoveryCapabilities;
use rs_matter::persist::{KvBlobStore, KvBlobStoreAccess, VENDOR_KEYS_START};
use rs_matter::respond::{DefaultResponder, ExchangeHandler, Responder};
use rs_matter::sc::pase::{
    CommWindowState, Spake2pVerifierPassword, Spake2pVerifierPasswordRef,
    MAX_COMM_WINDOW_TIMEOUT_SECS,
};
use rs_matter::tlv::{TLVBuilderParent, Utf8StrBuilder};
use rs_matter::transport::exchange::{Exchange, MatterBuffers};
use rs_matter::utils::select::Coalesce;
use rs_matter::{clusters, devices, root_endpoint, with, BasicCommData, Matter};

use crate::mdns;
use crate::proto::{emit, Event};
use crate::storage::{KvStore, Pairing};

// ---------------------------------------------------------------------------
// Host-shared per-port state
// ---------------------------------------------------------------------------

pub const MAX_PORTS: usize = 5;

/// EEM reports (each one also emits a CumulativeEnergyMeasured event) are
/// throttled to one per this many seconds per port.
const ENERGY_REPORT_SECS: u64 = 60;

/// A regular responder handler gives up on (and drops) a single exchange whose
/// handling has not finished within this long. A normal PASE/CASE handshake
/// completes in well under a second; this only ever fires on a handshake the
/// peer started and abandoned, which would otherwise hold the handler until its
/// much longer MRP receive timeout. See the responder wiring in `run`.
const HANDLER_TIMEOUT_SECS: u64 = 30;

/// An [`ExchangeHandler`] decorator that drops the wrapped handler's work on a
/// single exchange if it has not finished within `secs`, freeing the handler.
/// Dropping the inner `handle` future drops the exchange it owns, which ends it
/// (`Exchange`'s `Drop` removes it from the session). Only the handling is
/// bounded; accepting a new exchange is the caller's concern and still blocks.
struct DropStalled<H> {
    inner: H,
    secs: u64,
}

impl<H> DropStalled<H> {
    const fn new(inner: H, secs: u64) -> Self {
        Self { inner, secs }
    }
}

impl<H: ExchangeHandler> ExchangeHandler for DropStalled<H> {
    async fn handle(&self, exchange: Exchange<'_>) -> Result<(), Error> {
        // Captured before the exchange is moved into the handler; `ExchangeId`
        // is `Copy` and its `Display` is just "session::index" — no setup code.
        let id = exchange.id();

        match select(self.inner.handle(exchange), Timer::after_secs(self.secs)).await {
            Either::First(result) => result,
            Either::Second(()) => {
                warn!(
                    "dropping exchange {id}: handling stalled past {}s",
                    self.secs
                );
                Ok(())
            }
        }
    }
}

/// Vendor KV keys, one per port: OnOff state (rs-matter's handler) and the
/// cumulative energy.
const ONOFF_KEYS: u16 = VENDOR_KEYS_START + 0x10;
const ENERGY_KEYS: u16 = VENDOR_KEYS_START + 0x20;

const METER_V: u8 = 1;
const METER_I: u8 = 2;
const METER_P: u8 = 4;

pub struct Port {
    on: AtomicBool,
    voltage_mv: AtomicI64,
    current_ma: AtomicI64,
    power_mw: AtomicI64,
    /// `METER_*` bits changed since the last EPM report.
    meter_dirty: AtomicU8,
    energy: Mutex<Energy>,
    /// mW·ms total last loaded from / written to the KV store.
    energy_saved: AtomicU64,
    /// host -> Matter: the port's real on/off state (reflect only).
    host_onoff: Signal<CriticalSectionRawMutex, bool>,
    /// host -> Matter: some of V/I/P changed.
    meter_changed: Signal<CriticalSectionRawMutex, ()>,
}

impl Port {
    const fn new() -> Self {
        Self {
            on: AtomicBool::new(false),
            voltage_mv: AtomicI64::new(0),
            current_ma: AtomicI64::new(0),
            power_mw: AtomicI64::new(0),
            meter_dirty: AtomicU8::new(0),
            energy: Mutex::new(Energy::new()),
            energy_saved: AtomicU64::new(0),
            host_onoff: Signal::new(),
            meter_changed: Signal::new(),
        }
    }

    /// Thread-safe: a host `port` line. Signals only what actually changed.
    /// `on` is compared with the last host value or controller command, so a
    /// host refusing a command flips the attribute back, and a confirmation
    /// does not disturb e.g. a running OnWithTimedOff.
    pub fn update(&self, on: bool, voltage_mv: u32, current_ma: u32, power_mw: u32) {
        if self.on.swap(on, Relaxed) != on {
            self.host_onoff.signal(on);
        }
        let mut dirty = 0;
        for (attr, value, bit) in [
            (&self.voltage_mv, voltage_mv, METER_V),
            (&self.current_ma, current_ma, METER_I),
            (&self.power_mw, power_mw, METER_P),
        ] {
            if attr.swap(value.into(), Relaxed) != i64::from(value) {
                dirty |= bit;
            }
        }
        self.energy
            .lock()
            .unwrap()
            .set_power(power_mw.into(), Instant::now());
        if dirty != 0 {
            self.meter_dirty.fetch_or(dirty, Relaxed);
            self.meter_changed.signal(());
        }
    }

    fn energy_mwh(&self) -> i64 {
        let mw_ms = self.energy.lock().unwrap().total_mw_ms(Instant::now());
        (mw_ms / 3_600_000) as i64
    }
}

/// Sample-and-hold integral of the host's `power_mw` over monotonic time.
struct Energy {
    mw_ms: u64,
    power_mw: u64,
    since: Option<Instant>,
}

impl Energy {
    const fn new() -> Self {
        Self {
            mw_ms: 0,
            power_mw: 0,
            since: None,
        }
    }

    fn total_mw_ms(&self, now: Instant) -> u64 {
        let held = self.since.map_or(0, |t| {
            let ms = now.saturating_duration_since(t).as_millis() as u64;
            self.power_mw.saturating_mul(ms)
        });
        self.mw_ms.saturating_add(held)
    }

    fn set_power(&mut self, power_mw: u64, now: Instant) {
        self.mw_ms = self.total_mw_ms(now);
        self.power_mw = power_mw;
        self.since = Some(now);
    }
}

/// Cumulative energy survives restarts: per port the mW·ms total as 8 LE
/// bytes. Added, not assigned: the stdin thread may already have integrated a
/// little since launch.
fn load_energy(store: &mut dyn KvBlobStore, buf: &mut [u8], ports: &[Port]) -> Result<(), Error> {
    for (i, port) in ports.iter().enumerate() {
        let Some(data) = store.load(ENERGY_KEYS + i as u16, buf)? else {
            continue;
        };
        let Ok(bytes) = <[u8; 8]>::try_from(data) else {
            warn!("port {i}: ignoring a stored energy of {} bytes", data.len());
            continue;
        };
        let saved = u64::from_le_bytes(bytes);
        let mut energy = port.energy.lock().unwrap();
        energy.mw_ms = energy.mw_ms.saturating_add(saved);
        port.energy_saved.store(saved, Relaxed);
    }
    Ok(())
}

/// Writes every port whose total changed since it was loaded or last written.
fn store_energy(store: &mut dyn KvBlobStore, buf: &mut [u8], ports: &[Port]) -> Result<(), Error> {
    let now = Instant::now();
    for (i, port) in ports.iter().enumerate() {
        let total = port.energy.lock().unwrap().total_mw_ms(now);
        if total != port.energy_saved.load(Relaxed) {
            store.store(ENERGY_KEYS + i as u16, &total.to_le_bytes(), buf)?;
            port.energy_saved.store(total, Relaxed);
        }
    }
    Ok(())
}

pub static PORTS: [Port; MAX_PORTS] = [const { Port::new() }; MAX_PORTS];

/// Set once `InteractionModel::startup` returned: OnOff `set_on_off` calls
/// before that are the persisted-state restore, not controller commands.
static STARTED: AtomicBool = AtomicBool::new(false);

/// Ends `run` cleanly (between two polls, so never in the middle of a KV write).
pub static SHUTDOWN: Signal<CriticalSectionRawMutex, ()> = Signal::new();

// ---------------------------------------------------------------------------
// Cluster hooks
// ---------------------------------------------------------------------------

/// On/Off Plug-in Unit. rs-matter has no constant for it. drev 4 = Device
/// Library rev used by matter.js 0.16 (`deviceRevision: 4`).
const DEV_TYPE_ON_OFF_PLUGIN_UNIT: DeviceType = DeviceType {
    dtype: 0x010A,
    drev: 4,
};

struct PlugOnOff(usize);

impl OnOffHooks for PlugOnOff {
    // Device Library: On/Off Plug-in Unit mandates the LT feature on OnOff
    // (matter.js: `BaseOnOffServer.with("Lighting")`).
    const CLUSTER: Cluster<'static> = on_off::FULL_CLUSTER
        .with_revision(6)
        .with_features(on_off::Feature::LIGHTING.bits())
        .with_attrs(with!(
            required;
            on_off::AttributeId::OnOff
                | on_off::AttributeId::GlobalSceneControl
                | on_off::AttributeId::OnTime
                | on_off::AttributeId::OffWaitTime
                | on_off::AttributeId::StartUpOnOff
        ))
        .with_cmds(with!(
            on_off::CommandId::Off
                | on_off::CommandId::On
                | on_off::CommandId::Toggle
                | on_off::CommandId::OffWithEffect
                | on_off::CommandId::OnWithRecallGlobalScene
                | on_off::CommandId::OnWithTimedOff
        ));

    /// Matter -> host. The handler sets OnOff to `on` in the same call, before
    /// the host can answer.
    fn set_on_off(&self, on: bool) {
        // Startup restore of the persisted value: not a command; `run` below
        // replaces it with the host's state.
        if !STARTED.load(Relaxed) {
            return;
        }
        PORTS[self.0].on.store(on, Relaxed);
        info!("controller: port {} on={on}", self.0);
        emit(&Event::Command { index: self.0, on });
    }

    async fn handle_off_with_effect(&self, _effect: EffectVariantEnum) {}

    async fn run<F: Fn(OutOfBandMessage)>(&self, notify: F) {
        let port = &PORTS[self.0];
        // Reflect only: `Update` sets OnOff + reports, never calls `set_on_off`.
        notify(OutOfBandMessage::Update(port.on.load(Relaxed)));
        loop {
            notify(OutOfBandMessage::Update(port.host_onoff.wait().await));
        }
    }
}

const MAX_V_MV: i64 = 48_000; // USB PD EPR
const MAX_I_MA: i64 = 5_000;
const MAX_P_MW: i64 = 240_000;
const MAX_E_MWH: i64 = i64::MAX / 3600;

struct PortPower(usize);

impl ElecPwrMeasHooks for PortPower {
    const CLUSTER: Cluster<'static> = elec_pwr_meas::FULL_CLUSTER
        .with_revision(3)
        .with_features(elec_pwr_meas::Feature::DIRECT_CURRENT.bits())
        .with_attrs(with!(
            required;
            elec_pwr_meas::AttributeId::Voltage | elec_pwr_meas::AttributeId::ActiveCurrent
        ))
        .with_cmds(with!())
        .with_events(with!());

    const POWER_MODE: PowerModeEnum = PowerModeEnum::DC;

    const ACCURACY: &'static [MeasurementAccuracy] = &[
        MeasurementAccuracy::new(
            MeasurementTypeEnum::Voltage,
            0,
            MAX_V_MV,
            &[MeasurementAccuracyRange::percent(0, MAX_V_MV, 500)],
        ),
        MeasurementAccuracy::new(
            MeasurementTypeEnum::ActiveCurrent,
            0,
            MAX_I_MA,
            &[MeasurementAccuracyRange::percent(0, MAX_I_MA, 500)],
        ),
        MeasurementAccuracy::new(
            MeasurementTypeEnum::ActivePower,
            0,
            MAX_P_MW,
            &[MeasurementAccuracyRange::percent(0, MAX_P_MW, 500)],
        ),
    ];

    /// Never `None` (Apple Home wants 0, not null).
    fn active_power(&self) -> Option<i64> {
        Some(PORTS[self.0].power_mw.load(Relaxed))
    }

    fn voltage(&self) -> Option<i64> {
        Some(PORTS[self.0].voltage_mv.load(Relaxed))
    }

    fn active_current(&self) -> Option<i64> {
        Some(PORTS[self.0].current_ma.load(Relaxed))
    }

    async fn run<F: Fn(elec_pwr_meas::OutOfBandMessage)>(&self, notify: F) {
        let port = &PORTS[self.0];
        loop {
            port.meter_changed.wait().await;
            let dirty = port.meter_dirty.swap(0, Relaxed);
            for (bit, msg) in [
                (METER_V, elec_pwr_meas::OutOfBandMessage::Voltage),
                (METER_I, elec_pwr_meas::OutOfBandMessage::ActiveCurrent),
                (METER_P, elec_pwr_meas::OutOfBandMessage::ActivePower),
            ] {
                if dirty & bit != 0 {
                    notify(msg);
                }
            }
        }
    }
}

struct PortEnergy(usize);

fn matter_epoch_secs() -> u32 {
    const MATTER_EPOCH_UNIX: u64 = 946_684_800;
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs().saturating_sub(MATTER_EPOCH_UNIX) as u32)
        .unwrap_or(0)
}

impl ElecEnergyMeasHooks for PortEnergy {
    const CLUSTER: Cluster<'static> = elec_energy_meas::FULL_CLUSTER
        .with_revision(2)
        .with_features(
            elec_energy_meas::Feature::IMPORTED_ENERGY.bits()
                | elec_energy_meas::Feature::CUMULATIVE_ENERGY.bits(),
        )
        .with_attrs(with!(
            required;
            elec_energy_meas::AttributeId::CumulativeEnergyImported
        ))
        .with_cmds(with!())
        .with_events(with!(elec_energy_meas::EventId::CumulativeEnergyMeasured));

    const ACCURACY: MeasurementAccuracy = MeasurementAccuracy::new(
        MeasurementTypeEnum::ElectricalEnergy,
        0,
        MAX_E_MWH,
        &[MeasurementAccuracyRange::percent(0, MAX_E_MWH, 500)],
    );

    fn cumulative_energy_imported(&self) -> Option<EnergyMeasurement> {
        Some(EnergyMeasurement::cumulative(
            PORTS[self.0].energy_mwh(),
            Timestamp::both(
                matter_epoch_secs(),
                embassy_time::Instant::now().as_millis(),
            ),
        ))
    }

    async fn run<F: Fn(elec_energy_meas::OutOfBandMessage)>(&self, notify: F) {
        let mut reported = 0;
        loop {
            Timer::after_secs(ENERGY_REPORT_SECS).await;
            let mwh = PORTS[self.0].energy_mwh();
            if mwh != reported {
                reported = mwh;
                notify(elec_energy_meas::OutOfBandMessage::CumulativeEnergyImported);
            }
        }
    }
}

/// rs-matter's `PowerTopologyHandler` only does NODE; this serves TREE.
/// Per spec AvailableEndpoints is SET-only and ActiveEndpoints is DYPF-only,
/// so TREE alone has no cluster-specific attributes.
struct TreeTopology {
    dataver: Dataver,
}

const TREE_TOPOLOGY_CLUSTER: Cluster<'static> = power_topology::FULL_CLUSTER
    .with_revision(1)
    .with_features(power_topology::Feature::TREE_TOPOLOGY.bits())
    .with_attrs(with!(required))
    .with_cmds(with!());

impl power_topology::ClusterHandler for TreeTopology {
    const CLUSTER: Cluster<'static> = TREE_TOPOLOGY_CLUSTER;

    fn dataver(&self) -> u32 {
        self.dataver.get()
    }

    fn dataver_changed(&self) {
        self.dataver.changed();
    }
}

/// Bridged Device Basic Information of a bridged port. Home names the tile
/// after NodeLabel.
struct BridgedPort<'a> {
    dataver: Dataver,
    name: &'a str,
    label: &'a str,
    /// `<serial>-<index>`: SerialNumber and UniqueID.
    id: &'a str,
}

const BRIDGED_INFO_CLUSTER: Cluster<'static> = bdbi::FULL_CLUSTER
    .with_attrs(with!(
        required;
        bdbi::AttributeId::VendorName
            | bdbi::AttributeId::ProductName
            | bdbi::AttributeId::NodeLabel
            | bdbi::AttributeId::SerialNumber
            | bdbi::AttributeId::UniqueID
    ))
    .with_cmds(with!());

impl bdbi::ClusterHandler for BridgedPort<'_> {
    const CLUSTER: Cluster<'static> = BRIDGED_INFO_CLUSTER;

    fn dataver(&self) -> u32 {
        self.dataver.get()
    }

    fn dataver_changed(&self) {
        self.dataver.changed();
    }

    fn vendor_name<P: TLVBuilderParent>(
        &self,
        _ctx: impl ReadContext,
        b: Utf8StrBuilder<P>,
    ) -> Result<P, Error> {
        b.set(DEV_DET.vendor_name)
    }

    fn product_name<P: TLVBuilderParent>(
        &self,
        _ctx: impl ReadContext,
        b: Utf8StrBuilder<P>,
    ) -> Result<P, Error> {
        b.set(self.name)
    }

    fn node_label<P: TLVBuilderParent>(
        &self,
        _ctx: impl ReadContext,
        b: Utf8StrBuilder<P>,
    ) -> Result<P, Error> {
        b.set(self.label)
    }

    fn serial_number<P: TLVBuilderParent>(
        &self,
        _ctx: impl ReadContext,
        b: Utf8StrBuilder<P>,
    ) -> Result<P, Error> {
        b.set(self.id)
    }

    fn reachable(&self, _ctx: impl ReadContext) -> Result<bool, Error> {
        Ok(true)
    }

    fn unique_id<P: TLVBuilderParent>(
        &self,
        _ctx: impl ReadContext,
        b: Utf8StrBuilder<P>,
    ) -> Result<P, Error> {
        b.set(self.id)
    }

    fn handle_keep_active(
        &self,
        _ctx: impl InvokeContext,
        _request: bdbi::KeepActiveRequest<'_>,
    ) -> Result<(), Error> {
        Err(ErrorCode::CommandNotFound.into())
    }
}

// ---------------------------------------------------------------------------
// Node composition
// ---------------------------------------------------------------------------

const PORT_CLUSTERS: &[Cluster<'static>] = clusters!(
    desc::DescHandler::CLUSTER,
    identify::CLUSTER,
    groups::GroupsHandler::CLUSTER,
    <PlugOnOff as OnOffHooks>::CLUSTER,
    TREE_TOPOLOGY_CLUSTER,
    <PortPower as ElecPwrMeasHooks>::CLUSTER,
    <PortEnergy as ElecEnergyMeasHooks>::CLUSTER,
);

const BRIDGED_PORT_CLUSTERS: &[Cluster<'static>] = clusters!(
    desc::DescHandler::CLUSTER,
    identify::CLUSTER,
    groups::GroupsHandler::CLUSTER,
    BRIDGED_INFO_CLUSTER,
    <PlugOnOff as OnOffHooks>::CLUSTER,
    TREE_TOPOLOGY_CLUSTER,
    <PortPower as ElecPwrMeasHooks>::CLUSTER,
    <PortEnergy as ElecEnergyMeasHooks>::CLUSTER,
);

const PORT_DEVICES: &[DeviceType] =
    devices!(DEV_TYPE_ON_OFF_PLUGIN_UNIT, DEV_TYPE_ELECTRICAL_SENSOR);

const BRIDGED_PORT_DEVICES: &[DeviceType] = devices!(
    DEV_TYPE_ON_OFF_PLUGIN_UNIT,
    DEV_TYPE_ELECTRICAL_SENSOR,
    DEV_TYPE_BRIDGED_NODE
);

const fn port_endpoint(id: u16) -> Endpoint<'static> {
    Endpoint::new(id, PORT_DEVICES, PORT_CLUSTERS)
}

const fn bridged_port_endpoint(id: u16) -> Endpoint<'static> {
    Endpoint::new(id, BRIDGED_PORT_DEVICES, BRIDGED_PORT_CLUSTERS)
}

const AGGREGATOR_EP: EndptId = 1;

const AGGREGATOR: Endpoint<'static> = Endpoint::new(
    AGGREGATOR_EP,
    devices!(DEV_TYPE_AGGREGATOR),
    clusters!(desc::DescHandler::CLUSTER),
);

/// `--bridge`; set before the data model is built. The chain's matchers are
/// plain `fn`s, so they read it from here.
static BRIDGE: AtomicBool = AtomicBool::new(false);

/// Port i is endpoint i+1, or i+2 behind the Aggregator.
fn port_ep(i: usize) -> EndptId {
    let first = if BRIDGE.load(Relaxed) {
        AGGREGATOR_EP + 1
    } else {
        1
    };
    first + i as EndptId
}

const NODE_3: Node<'static> = Node {
    endpoints: &[
        root_endpoint!(eth),
        port_endpoint(1),
        port_endpoint(2),
        port_endpoint(3),
    ],
};

const NODE_5: Node<'static> = Node {
    endpoints: &[
        root_endpoint!(eth),
        port_endpoint(1),
        port_endpoint(2),
        port_endpoint(3),
        port_endpoint(4),
        port_endpoint(5),
    ],
};

const BRIDGE_3: Node<'static> = Node {
    endpoints: &[
        root_endpoint!(eth),
        AGGREGATOR,
        bridged_port_endpoint(2),
        bridged_port_endpoint(3),
        bridged_port_endpoint(4),
    ],
};

const BRIDGE_5: Node<'static> = Node {
    endpoints: &[
        root_endpoint!(eth),
        AGGREGATOR,
        bridged_port_endpoint(2),
        bridged_port_endpoint(3),
        bridged_port_endpoint(4),
        bridged_port_endpoint(5),
        bridged_port_endpoint(6),
    ],
};

type OnOffH = OnOffHandler<'static, PlugOnOff, NoLevelControl>;
type PwrH = elec_pwr_meas::ElecPwrMeasHandler<PortPower>;
type EnH = elec_energy_meas::ElecEnergyMeasHandler<PortEnergy>;

/// `chain()` only takes `fn(EndptId, ClusterId) -> bool` (no captures), so the
/// port index has to be a literal: one macro expansion per port.
macro_rules! port_chain {
    ($chain:expr, $i:literal, $rand:ident, $oo:expr, $pw:expr, $en:expr, $bp:expr) => {
        $chain
            .chain(
                |e, c| e == port_ep($i) && c == desc::DescHandler::CLUSTER.id,
                Async(desc::DescHandler::new(Dataver::new_rand(&mut $rand)).adapt()),
            )
            .chain(
                |e, c| e == port_ep($i) && c == identify::CLUSTER.id,
                Async(IdentifyHandler::new(Dataver::new_rand(&mut $rand)).adapt()),
            )
            .chain(
                |e, c| e == port_ep($i) && c == groups::GroupsHandler::CLUSTER.id,
                Async(groups::GroupsHandler::new(Dataver::new_rand(&mut $rand)).adapt()),
            )
            .chain(
                |e, c| e == port_ep($i) && c == <PlugOnOff as OnOffHooks>::CLUSTER.id,
                Async(on_off::HandlerAdaptor($oo)),
            )
            .chain(
                |e, c| e == port_ep($i) && c == TREE_TOPOLOGY_CLUSTER.id,
                Async(power_topology::HandlerAdaptor(TreeTopology {
                    dataver: Dataver::new_rand(&mut $rand),
                })),
            )
            .chain(
                |e, c| e == port_ep($i) && c == <PortPower as ElecPwrMeasHooks>::CLUSTER.id,
                Async(elec_pwr_meas::HandlerAdaptor($pw)),
            )
            .chain(
                |e, c| e == port_ep($i) && c == <PortEnergy as ElecEnergyMeasHooks>::CLUSTER.id,
                Async(elec_energy_meas::HandlerAdaptor($en)),
            )
            .chain(
                |e, c| e == port_ep($i) && c == BRIDGED_INFO_CLUSTER.id,
                Async(bdbi::HandlerAdaptor($bp)),
            )
    };
}

/// One chain for all `MAX_PORTS` and both compositions; `node` decides which
/// endpoints and clusters exist (in 3-port mode the ep4/ep5 handlers, and
/// without `--bridge` the BDBI ones, are never addressed).
fn data_model<'a>(
    node: Node<'static>,
    mut rand: impl Rng + Copy,
    oo: &'a [OnOffH; MAX_PORTS],
    pw: &'a [PwrH; MAX_PORTS],
    en: &'a [EnH; MAX_PORTS],
    bp: &'a [BridgedPort<'a>; MAX_PORTS],
) -> impl DataModel + 'a {
    let chain = endpoints::EthSysHandlerBuilder::new()
        .netif_diag(&SysNetifs)
        .build(rand)
        .chain(
            |e, c| BRIDGE.load(Relaxed) && e == AGGREGATOR_EP && c == desc::DescHandler::CLUSTER.id,
            Async(desc::DescHandler::new_aggregator(Dataver::new_rand(&mut rand)).adapt()),
        );
    let chain = port_chain!(chain, 0, rand, &oo[0], &pw[0], &en[0], &bp[0]);
    let chain = port_chain!(chain, 1, rand, &oo[1], &pw[1], &en[1], &bp[1]);
    let chain = port_chain!(chain, 2, rand, &oo[2], &pw[2], &en[2], &bp[2]);
    let chain = port_chain!(chain, 3, rand, &oo[3], &pw[3], &en[3], &bp[3]);
    let chain = port_chain!(chain, 4, rand, &oo[4], &pw[4], &en[4], &bp[4]);
    (node, chain)
}

// ---------------------------------------------------------------------------
// Runtime
// ---------------------------------------------------------------------------

pub struct Config<'a> {
    pub storage: &'a Path,
    pub name: &'a str,
    pub labels: &'a [String],
    pub udp_port: u16,
    pub bridge: bool,
}

/// Fatal error: becomes the `error` event.
#[derive(Debug)]
pub struct Fatal {
    pub code: &'static str,
    pub message: String,
}

fn fatal(code: &'static str) -> impl Fn(Error) -> Fatal {
    move |e| Fatal {
        code,
        message: e.to_string(),
    }
}

/// VID/PID MUST stay 0xFFF1/0x8001 while using `TEST_DEV_ATT`: the bundled
/// test DAC is issued for exactly FFF1/8001.
const DEV_DET: BasicInfoConfig<'static> = BasicInfoConfig {
    vid: TEST_VID,
    pid: TEST_PID,
    hw_ver: 1,
    hw_ver_str: "1",
    sw_ver: 1,
    sw_ver_str: env!("CARGO_PKG_VERSION"),
    manufacturing_date: "20261014",
    vendor_name: "Charker",
    device_type: Some(0x010A),
    ..BasicInfoConfig::new()
};

/// `MT:...` QR payload text and the 11-digit manual code (OnNetwork discovery).
fn onboarding_codes(
    comm: &BasicCommData,
    dev_det: &BasicInfoConfig,
) -> Result<(String, String), Error> {
    let payload = QrPayload::new_from_basic_info(
        DiscoveryCapabilities::IP,
        CommFlowType::Standard,
        comm.clone(),
        dev_det,
        no_optional_data as NoOptionalData,
    );
    let mut buf = [0u8; 1024];
    let (qr, _) = payload.as_str(&mut buf)?;
    Ok((qr.to_string(), comm.compute_pairing_code().to_string()))
}

/// `[::]:port`, else an ephemeral port (mDNS advertises whatever we got).
fn bind(port: u16) -> Result<UdpSocket, Fatal> {
    let any = |p| SocketAddr::V6(SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, p, 0, 0));
    UdpSocket::bind(any(port))
        .or_else(|e| {
            warn!("UDP [::]:{port}: {e}; falling back to an ephemeral port");
            UdpSocket::bind(any(0))
        })
        .map_err(|e| Fatal {
            code: "bind",
            message: format!("UDP [::]:{port} and [::]:0: {e}"),
        })
}

/// rs-matter revokes a window after 20 failed PAKE attempts. Reopening it
/// before its full timeout would have run out would lift that limit.
fn may_open_window(opened: Option<Instant>, now: Instant) -> bool {
    let timeout = Duration::from_secs(MAX_COMM_WINDOW_TIMEOUT_SECS.into());
    opened.is_none_or(|t| now.saturating_duration_since(t) >= timeout)
}

/// Emits `fabrics` on every change and keeps a commissioning window open
/// while uncommissioned (first launch, window expired, removed from Home).
/// While the helper's own window is open the reported count is 0: a fabric
/// being commissioned counts once CommissioningComplete closes the window.
async fn supervise(
    matter: &Matter<'_>,
    open_window: impl Fn() -> Result<(), Error>,
) -> Result<(), Fatal> {
    let mut reported = None;
    let mut last_count = 0;
    // When the helper last opened its window.
    let mut opened = None;
    loop {
        let count = matter.with_state(|s| s.fabrics.iter().count());
        let window = matter.comm_window_state();
        let shown = match window {
            CommWindowState::Open { opener: None } => 0,
            _ => count,
        };
        if reported != Some(shown) {
            reported = Some(shown);
            emit(&Event::Fabrics { count: shown });
        }
        if count == 0 && last_count > 0 {
            // Removed from Home: open right away.
            opened = None;
        }
        last_count = count;
        let now = Instant::now();
        if count == 0 && !window.is_open() && may_open_window(opened, now) {
            // Taken before opening, so `opened + timeout` is never later than
            // rs-matter's own expiry.
            opened = Some(now);
            match open_window() {
                Ok(()) => info!("commissioning window open"),
                Err(e) => {
                    opened = None;
                    warn!("opening the commissioning window: {e}");
                }
            }
        }
        Timer::after_secs(1).await;
    }
}

/// Blocking: runs the whole Matter stack on the calling thread until
/// `SHUTDOWN` or a fatal error.
pub fn run(cfg: &Config, pairing: &Pairing) -> Result<(), Fatal> {
    BRIDGE.store(cfg.bridge, Relaxed);
    let n = cfg.labels.len();
    info!(
        "ports {:?} -> endpoints {}..={}",
        cfg.labels,
        port_ep(0),
        port_ep(n - 1)
    );

    let socket = bind(cfg.udp_port)?;
    let udp_port = socket
        .local_addr()
        .map_err(|e| Fatal {
            code: "bind",
            message: e.to_string(),
        })?
        .port();

    let comm_data = BasicCommData {
        password: Spake2pVerifierPassword::new_from_ref(Spake2pVerifierPasswordRef::new(
            &pairing.passcode.to_le_bytes(),
        )),
        discriminator: pairing.discriminator,
    };
    let unique_id = format!("charker-{}", pairing.serial);
    let dev_det = BasicInfoConfig {
        serial_no: &pairing.serial,
        unique_id: &unique_id,
        product_name: cfg.name,
        product_label: cfg.name,
        device_name: cfg.name,
        ..DEV_DET
    };
    let matter = Matter::new(&dev_det, comm_data.clone(), &TEST_DEV_ATT, udp_port);
    let buffers: MatterBuffers = MatterBuffers::new();
    let state: EthInteractionModelState = EthInteractionModelState::new(EthNetwork::new_default());
    let kv = matter.kv(KvStore::new(cfg.storage.to_path_buf()));

    // Fabrics, ACLs, basic-info settings come back from the storage dir.
    matter.startup(&kv).map_err(fatal("storage"))?;
    let ports = &PORTS[..n];
    kv.access(|store, buf| load_energy(store, buf, ports))
        .map_err(fatal("storage"))?;

    let crypto = default_crypto(rand::rng(), DAC_PRIVKEY);
    let mut rand = crypto.rand().map_err(fatal("internal"))?;

    let oo: [OnOffH; MAX_PORTS] = core::array::from_fn(|i| {
        OnOffHandler::new_standalone(
            Dataver::new_rand(&mut rand),
            port_ep(i),
            ONOFF_KEYS + i as u16,
            PlugOnOff(i),
        )
    });
    let pw: [PwrH; MAX_PORTS] = core::array::from_fn(|i| {
        elec_pwr_meas::ElecPwrMeasHandler::new(
            Dataver::new_rand(&mut rand),
            port_ep(i),
            PortPower(i),
        )
    });
    let en: [EnH; MAX_PORTS] = core::array::from_fn(|i| {
        elec_energy_meas::ElecEnergyMeasHandler::new(
            Dataver::new_rand(&mut rand),
            port_ep(i),
            PortEnergy(i),
        )
    });
    let ids: [String; MAX_PORTS] = core::array::from_fn(|i| format!("{}-{i}", pairing.serial));
    let bp: [BridgedPort; MAX_PORTS] = core::array::from_fn(|i| BridgedPort {
        dataver: Dataver::new_rand(&mut rand),
        name: cfg.name,
        label: cfg.labels.get(i).map_or("", String::as_str),
        id: &ids[i],
    });

    let node = match (cfg.bridge, n) {
        (false, 5) => NODE_5,
        (false, _) => NODE_3,
        (true, 5) => BRIDGE_5,
        (true, _) => BRIDGE_3,
    };
    let im = InteractionModel::new(
        &matter,
        &crypto,
        &buffers,
        data_model(node, rand, &oo, &pw, &en, &bp),
        &kv,
        &state,
    );
    futures_lite::future::block_on(im.startup()).map_err(fatal("storage"))?;
    STARTED.store(true, Relaxed);
    if let Err(e) = matter.persist_reboot_count(&kv) {
        warn!("saving the reboot count: {e}");
    }

    let (qr, code) = onboarding_codes(&comm_data, &dev_det).map_err(fatal("internal"))?;
    info!("UDP {udp_port}");
    emit(&Event::Onboarding {
        qr: &qr,
        manual_code: &code,
    });

    let socket = async_io::Async::new(socket).map_err(|e| Fatal {
        code: "internal",
        message: e.to_string(),
    })?;
    let responder = DefaultResponder::new(&im);
    // Wrap the regular (non-busy) handler so a single accepted exchange is
    // dropped once its handling stalls past `HANDLER_TIMEOUT_SECS`. A
    // commissioner that discovers several of this host's addresses (Wi-Fi and
    // Ethernet, IPv4 and IPv6) can start a PASE/CASE handshake on several and
    // abandon all but one; each abandoned one otherwise parks a regular
    // handler until its multi-minute MRP receive timeout, and with every
    // handler parked the node answers only "busy" and never pairs again until
    // restarted. Dropping the stalled handler future drops its exchange, which
    // frees the handler. Only the handling of an *accepted* exchange is timed
    // out; the wait for a new exchange still blocks indefinitely.
    let regular = Responder::new(
        "Responder",
        DropStalled::new(responder.responder().handler(), HANDLER_TIMEOUT_SECS),
        &matter,
        0,
    );

    let mut transport = pin!(async {
        matter
            .run(&crypto, &socket, &socket, &socket)
            .await
            .map_err(fatal("internal"))
    });
    let mut mdns = pin!(mdns::run(&matter));
    // 8 regular handlers (one per concurrent exchange) plus the stock busy
    // responder (500 ms, unchanged), mirroring `DefaultResponder::run`.
    let mut respond = pin!(async {
        let regular = regular.run::<8>();
        let busy = responder.busy_responder().run::<4>();
        select(regular, busy)
            .coalesce()
            .await
            .map_err(fatal("internal"))
    });
    // Only KV persistence does file I/O in here.
    let mut im_job = pin!(async {
        im.run().await.map_err(|e| {
            let code = if e.code() == ErrorCode::StdIoError {
                "storage"
            } else {
                "internal"
            };
            fatal(code)(e)
        })
    });
    let open_window = || im.open_basic_comm_window(MAX_COMM_WINDOW_TIMEOUT_SECS);
    let mut housekeeping = pin!(supervise(&matter, open_window));
    // Best effort: a failed write only loses what was integrated since the last one.
    let save_energy = || {
        if let Err(e) = kv.access(|store, buf| store_energy(store, buf, ports)) {
            warn!("saving energy: {e}");
        }
    };
    let mut energy = pin!(async {
        loop {
            Timer::after_secs(ENERGY_REPORT_SECS).await;
            save_energy();
        }
    });
    let mut shutdown = pin!(async {
        SHUTDOWN.wait().await;
        save_energy();
        Ok(())
    });

    let stack = select4(&mut transport, &mut mdns, &mut respond, &mut im_job).coalesce();
    let control = select3(&mut housekeeping, &mut energy, &mut shutdown).coalesce();
    futures_lite::future::block_on(select(stack, control).coalesce())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn energy_is_sample_and_hold() {
        let t0 = Instant::now();
        let mut e = Energy::new();
        assert_eq!(e.total_mw_ms(t0), 0);
        e.set_power(30_000, t0);
        let t1 = t0 + Duration::from_secs(60);
        assert_eq!(e.total_mw_ms(t1), 30_000 * 60_000);
        e.set_power(0, t1);
        assert_eq!(
            e.total_mw_ms(t1 + Duration::from_secs(3600)),
            30_000 * 60_000
        );
        // 30 W for one minute = 0.5 Wh
        assert_eq!(e.total_mw_ms(t1) / 3_600_000, 500);
    }

    #[test]
    fn energy_survives_a_restart() {
        let dir =
            std::env::temp_dir().join(format!("charker-matter-test-energy-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = |i: u16| dir.join(format!("k_{:04x}", ENERGY_KEYS + i));
        let mut kv = KvStore::new(dir.clone());
        let mut buf = [0u8; 64];

        let before: [Port; 3] = [const { Port::new() }; 3];
        before[1].energy.lock().unwrap().mw_ms = 500 * 3_600_000;
        store_energy(&mut kv, &mut buf, &before).unwrap();
        assert!(!file(0).exists(), "unchanged 0 is not written");
        assert!(file(1).exists());
        std::fs::write(file(2), b"bad").unwrap();

        let after: [Port; 3] = [const { Port::new() }; 3];
        // Integrated by the stdin thread before the load.
        after[1].energy.lock().unwrap().mw_ms = 3_600_000;
        load_energy(&mut kv, &mut buf, &after).unwrap();
        assert_eq!(after[1].energy_mwh(), 501);
        assert_eq!(after[2].energy_mwh(), 0);

        std::fs::remove_file(file(1)).unwrap();
        after[1].energy.lock().unwrap().mw_ms = 500 * 3_600_000;
        store_energy(&mut kv, &mut buf, &after).unwrap();
        assert!(!file(1).exists(), "unchanged since the load");
        after[1].energy.lock().unwrap().mw_ms = 502 * 3_600_000;
        store_energy(&mut kv, &mut buf, &after).unwrap();
        assert_eq!(
            std::fs::read(file(1)).unwrap(),
            (502u64 * 3_600_000).to_le_bytes()
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn window_reopens_only_after_its_full_timeout() {
        let t0 = Instant::now();
        let full = Duration::from_secs(MAX_COMM_WINDOW_TIMEOUT_SECS.into());
        assert!(may_open_window(None, t0));
        // Closed early (revoked after failed PAKE attempts): wait for the expiry.
        assert!(!may_open_window(Some(t0), t0 + Duration::from_secs(30)));
        assert!(!may_open_window(
            Some(t0),
            t0 + full - Duration::from_millis(1)
        ));
        // Expired on its own.
        assert!(may_open_window(Some(t0), t0 + full));
        assert!(may_open_window(Some(t0), t0 + full * 2));
    }
}
