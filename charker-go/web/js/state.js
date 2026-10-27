// ============================================================================
// Charker — store + bridge wrapper (owner: web-shell)
//
// One code path for the real mygo bridge and the browser mock:
//   mock.js installs window.mygo only when it is missing, so everything below
//   calls the same `call()` / `on()` API either way.
//
// Public API (contract §5):
//   getState()            → AppState (never null; defaults filled in)
//   setState(next)        → normalized snapshot, notifies subscribers
//   subscribe(fn)         → unsubscribe
//   call(method, ...args) → Promise<result>
//   on(event, fn)         → unsubscribe
//   init()                → calls Charker.State once and returns the snapshot
//
// Wire names: the plain-JS bridge uses the exact exported Go method names
// (`Charker.State`, `Charker.SetPortEnabled`, …). Lower-camel spellings from
// contract §4 (`Charker.state`, `Charker.setPortEnabled`) are normalized here,
// so screens may write either; bare names get the `Charker.` prefix.
// ============================================================================

import './mock.js';

const SERVICE = 'Charker';

// ---------------------------------------------------------------------------
// Defaults: missing/unknown fields must never crash the UI (contract §4.1).

const DEFAULT_PORT = Object.freeze({
  id: '',
  label: '',
  enabled: false,
  status: 0,
  watts: 0,
  volts: 0,
  amps: 0,
  protocol: '',
  epr: false,
  deviceKind: '',
  deviceName: '',
  barPct: 0,
  configLabel: '',
  countdownEndMs: 0,
  timerMinutes: 0,
  cable: '',
});

const DEFAULT_APP = Object.freeze({
  version: '0.1.0',
  locale: 'zh',
  theme: 'system',
  mock: false,
  platform: 'windows',
});

const DEFAULT_SETTINGS = Object.freeze({
  screenOn: true,
  brightness: 80,
  language: 'zh',
  orientation: 'auto',
  autoLock: false,
  theme: '',
  fixedAllocation: false,
});

const DEFAULT_ENERGY = Object.freeze({
  day: { wh: 0, cost: 0, currency: 'CNY' },
  week: { wh: 0, cost: 0, currency: 'CNY' },
  month: { wh: 0, cost: 0, currency: 'CNY' },
});

const EMPTY_STATE = Object.freeze({
  app: DEFAULT_APP,
  phase: 'idle',
  scanning: false,
  device: null,
  devices: [],
  ports: [],
  totals: { watts: 0, limit: 160, chargingCount: 0, connectedCount: 0 },
  history: [],
  stats: { peakW: 0, avgW: 0, energyWh: 0, connectedMs: 0 },
  settings: DEFAULT_SETTINGS,
  menuBar: { items: [{ kind: 'total', decimals: 1 }] },
  energy: DEFAULT_ENERGY,
  notice: null,
  lastUpdatedMs: 0,
});

function clone(value) {
  if (value == null || typeof value !== 'object') return value;
  try {
    return structuredClone(value);
  } catch (_) {
    return JSON.parse(JSON.stringify(value));
  }
}

function objectOr(value, fallback) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : fallback;
}

function arrayOr(value) {
  return Array.isArray(value) ? value : [];
}

/** Fill every field the shell/screens read so a partial snapshot is safe. */
export function normalizeState(raw) {
  const source = objectOr(raw, {});
  const state = {
    ...clone(EMPTY_STATE),
    ...source,
    app: { ...DEFAULT_APP, ...objectOr(source.app, {}) },
    device: objectOr(source.device, null),
    devices: arrayOr(source.devices),
    ports: arrayOr(source.ports).map((port) => ({ ...DEFAULT_PORT, ...objectOr(port, {}) })),
    totals: {
      watts: 0,
      limit: 160,
      chargingCount: 0,
      connectedCount: 0,
      ...objectOr(source.totals, {}),
    },
    history: arrayOr(source.history),
    stats: { peakW: 0, avgW: 0, energyWh: 0, connectedMs: 0, ...objectOr(source.stats, {}) },
    settings: { ...DEFAULT_SETTINGS, ...objectOr(source.settings, {}) },
    menuBar: { items: [{ kind: 'total', decimals: 1 }], ...objectOr(source.menuBar, {}) },
    energy: {
      day: { ...DEFAULT_ENERGY.day, ...objectOr(objectOr(source.energy, {}).day, {}) },
      week: { ...DEFAULT_ENERGY.week, ...objectOr(objectOr(source.energy, {}).week, {}) },
      month: { ...DEFAULT_ENERGY.month, ...objectOr(objectOr(source.energy, {}).month, {}) },
    },
    notice: objectOr(source.notice, null),
    lastUpdatedMs: Number(source.lastUpdatedMs) || 0,
  };
  state.phase = typeof state.phase === 'string' && state.phase ? state.phase : 'idle';
  state.scanning = Boolean(state.scanning);
  return state;
}

// ---------------------------------------------------------------------------
// Store

const listeners = new Set();
let state = normalizeState({});

/** @returns {object} the current AppState (defaults filled, never null) */
export function getState() {
  return state;
}

/** Replace the snapshot and notify subscribers. Returns the new snapshot. */
export function setState(next) {
  state = normalizeState(next);
  for (const fn of listeners) {
    try {
      fn(state);
    } catch (err) {
      console.error('[charker] state subscriber failed', err);
    }
  }
  return state;
}

/** Subscribe to state changes. Returns an unsubscribe function. */
export function subscribe(fn) {
  if (typeof fn !== 'function') return () => {};
  listeners.add(fn);
  return () => listeners.delete(fn);
}

// ---------------------------------------------------------------------------
// Bridge

function getBridge() {
  const bridge = window.mygo;
  if (bridge && typeof bridge.call === 'function') return bridge;
  return null;
}

/** True when a bridge exists (real mygo or the mock installed by mock.js). */
export function hasBridge() {
  return Boolean(getBridge());
}

/**
 * Normalize a method name to the Go binding's exact PascalCase form:
 *   'Charker.state'        → 'Charker.State'
 *   'Charker.State'        → 'Charker.State'
 *   'state'                → 'Charker.State'
 *   'Charker.setPortEnabled' → 'Charker.SetPortEnabled'
 */
export function wireMethod(method) {
  const raw = String(method == null ? '' : method).trim();
  if (!raw) return '';
  const dotted = raw.includes('.') ? raw : `${SERVICE}.${raw}`;
  const dot = dotted.indexOf('.');
  const service = dotted.slice(0, dot);
  const name = dotted.slice(dot + 1);
  if (!name) return dotted;
  return `${service}.${name.charAt(0).toUpperCase()}${name.slice(1)}`;
}

/**
 * Call a Go binding. Rejects when the bridge is unavailable or the Go call
 * rejects (contract §4). Accepts lower-camel or PascalCase method names.
 * @returns {Promise<unknown>}
 */
export async function call(method, ...args) {
  const bridge = getBridge();
  if (!bridge) {
    throw new Error('bridge-unavailable');
  }
  const result = bridge.call(wireMethod(method), ...args);
  return await result;
}

/**
 * Unwrap the event payload shapes the bridge may deliver (raw value, an event
 * wrapper with `.data`, or a JSON string) so handlers always see the payload.
 */
function unwrapEvent(payload) {
  if (typeof payload === 'string') {
    try {
      return JSON.parse(payload);
    } catch (_) {
      return payload;
    }
  }
  if (
    payload &&
    typeof payload === 'object' &&
    'data' in payload &&
    ('type' in payload || 'event' in payload || 'name' in payload)
  ) {
    return payload.data;
  }
  return payload;
}

/**
 * Listen to a bridge event (`state` / `toast` / `deviceLost`, or any mygo event
 * such as `mygo:locale`). Returns an unsubscribe function, or a no-op when the
 * bridge is gone.
 */
export function on(event, fn) {
  const bridge = getBridge();
  if (!bridge || typeof bridge.on !== 'function' || typeof fn !== 'function') {
    return () => {};
  }
  const wrapped = (payload) => fn(unwrapEvent(payload));
  const unsubscribe = bridge.on(event, wrapped);
  return typeof unsubscribe === 'function' ? unsubscribe : () => {};
}

/** One-shot event listener; falls back to `on` when `once` is missing. */
export function once(event, fn) {
  const bridge = getBridge();
  if (bridge && typeof bridge.once === 'function' && typeof fn === 'function') {
    return bridge.once(event, (payload) => fn(unwrapEvent(payload)));
  }
  const off = on(event, (payload) => {
    off();
    fn(payload);
  });
  return off;
}

// ---------------------------------------------------------------------------
// Boot

/**
 * Fetch the first snapshot: `Charker.State` once on boot (contract §4: no
 * polling; every later update arrives as a `state` event). Returns the state;
 * a rejected call is re-thrown so main.js can show an error boundary instead
 * of a blank window.
 */
export async function init() {
  const snapshot = await call('Charker.State');
  return setState(snapshot == null ? {} : snapshot);
}

export { DEFAULT_PORT, EMPTY_STATE };
