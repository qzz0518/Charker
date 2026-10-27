// ============================================================================
// Charker — browser mock bridge (owner: web-shell)
//
// Installs `window.mygo` ONLY when the real mygo bridge is absent, so the page
// and every screenshot render without the Go app. Shape mirrors the real
// runtime (mygo/packages/runtime/src/types.ts) closely enough for state.js:
//   call(method, ...args): Promise<T> · on(event, listener): unsubscribe
//   once · channel · platform · windowId · version · locale · preferences
// The Go binding names are PascalCase (`Charker.State`, `Charker.SetPortEnabled`);
// dispatch is case-insensitive so lower-camel contract names work too.
//
// Lively A2687 AppState per contract §4.1: connected, 42 W on C2 (Apple PD),
// C1 idle at 5.08 V, C3 off, 180 history points updated at 1 Hz.
//
// Query flags: ?mock=empty | scan | error | light   (default: live)
//   empty → idle phase, no device, no data
//   scan  → scanning phase with 3 nearby devices, nothing connected
//   error → failed phase + error toast
//   light → live data with light appearance
// Also: window.mock.setState(patch) merges a patch into the mock snapshot
// (handy for screenshots), window.mock.getState(), window.mock.mode.
// ============================================================================

const params = new URLSearchParams(window.location.search);
const rawMode = String(params.get('mock') || '').toLowerCase();
const MODES = ['empty', 'scan', 'error', 'light'];
const mode = MODES.includes(rawMode) ? rawMode : 'live';
const themePref =
  mode === 'light' || params.get('theme') === 'light'
    ? 'light'
    : params.get('theme') === 'dark'
      ? 'dark'
      : 'dark';
const requestedLocale = params.get('lang');
const locale =
  requestedLocale === 'en'
    ? 'en'
    : requestedLocale === 'zh'
      ? 'zh'
      : /^en/i.test(navigator.language || '')
        ? 'en'
        : 'zh';

const installed = !window.mygo;
const liveDeviceId = 'mock-a2687-01';

const CONNECTED_AT = Date.now() - 3991000; // 1:06:31 ago, matches the contract example

// ---------------------------------------------------------------------------
// Helpers

const clamp = (n, lo, hi) => Math.min(hi, Math.max(lo, n));
const round2 = (n) => Math.round(n * 100) / 100;
const round1 = (n) => Math.round(n * 10) / 10;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const nowMs = () => Date.now();

function deepClone(value) {
  try {
    return structuredClone(value);
  } catch (_) {
    return JSON.parse(JSON.stringify(value));
  }
}

function deepMerge(base, patch) {
  if (!patch || typeof patch !== 'object') return base;
  const out = Array.isArray(base) ? base.slice() : { ...(base || {}) };
  for (const [key, value] of Object.entries(patch)) {
    if (Array.isArray(value)) out[key] = value.slice();
    else if (value && typeof value === 'object') out[key] = deepMerge(out[key], value);
    else out[key] = value;
  }
  return out;
}

function makePort(id, overrides = {}) {
  return {
    id,
    label: id,
    enabled: true,
    status: 1,
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
    ...overrides,
  };
}

function livePorts() {
  return [
    makePort('C1', {
      volts: 5.08,
      cable: 'EPR · 240W 线',
      epr: true,
    }),
    makePort('C2', {
      watts: 42,
      volts: 27.46,
      amps: 1.53,
      protocol: 'Apple PD',
      epr: true,
      deviceKind: 'phone',
      deviceName: 'Apple',
      barPct: 42 / 160,
      cable: 'EPR · 240W 线',
    }),
    makePort('C3', {
      enabled: false,
      status: 0,
    }),
  ];
}

function idlePorts() {
  return [makePort('C1'), makePort('C2'), makePort('C3', { enabled: false, status: 0 })];
}

function deviceSummary(overrides = {}) {
  return {
    id: liveDeviceId,
    name: 'Anker Prime 160W',
    product: 'a2687',
    address: 'A4:C1:38:7B:2D:9F',
    rssi: -52,
    connected: true,
    saved: true,
    mock: true,
    ...overrides,
  };
}

function nearbyDevices() {
  return [
    deviceSummary({ id: 'near-01', name: 'Anker Prime 160W', connected: false, saved: false, rssi: -52 }),
    deviceSummary({
      id: 'near-02',
      name: 'Anker Prime 250W',
      product: 'a2345',
      address: 'C8:1F:66:04:AA:31',
      connected: false,
      saved: false,
      rssi: -67,
    }),
    deviceSummary({
      id: 'near-03',
      name: 'Anker Nano 65W',
      product: 'a2687',
      address: 'D0:39:72:11:BC:08',
      connected: false,
      saved: false,
      rssi: -78,
    }),
  ];
}

/** Deterministic, lively-looking total watts for sample `i` of the history. */
function historicalWatts(i) {
  const noise = Math.abs(Math.sin(i * 12.9898) * 43758.5453) % 1;
  const spike = i % 29 === 0 ? 6.5 : i % 17 === 0 ? 3 : 0;
  return clamp(42 + Math.sin(i * 0.42) * 2.6 + Math.sin(i * 1.73) * 0.9 + noise * 1.6 + spike, 28, 62);
}

function makeHistory(count = 180) {
  const end = nowMs();
  const points = [];
  for (let i = 0; i < count; i += 1) {
    points.push({ t: end - (count - 1 - i) * 1000, w: round1(historicalWatts(i)) });
  }
  return points;
}

// ---------------------------------------------------------------------------
// Initial snapshot

function emptyTotals() {
  return { watts: 0, limit: 160, chargingCount: 0, connectedCount: 0 };
}

function emptyStats() {
  return { peakW: 0, avgW: 0, energyWh: 0, connectedMs: 0 };
}

function energyBuckets() {
  return {
    day: { wh: 12.3, cost: 2.1, currency: 'CNY' },
    week: { wh: 86.4, cost: 14.7, currency: 'CNY' },
    month: { wh: 342.8, cost: 58.3, currency: 'CNY' },
  };
}

function baseState() {
  return {
    app: {
      version: '0.1.0',
      locale,
      theme: themePref,
      mock: true,
      platform: 'windows',
    },
    phase: 'idle',
    scanning: false,
    device: null,
    devices: [],
    ports: idlePorts(),
    totals: emptyTotals(),
    history: [],
    stats: emptyStats(),
    settings: {
      screenOn: true,
      brightness: 80,
      language: locale,
      orientation: 'auto',
      autoLock: false,
      theme: '',
      fixedAllocation: false,
    },
    menuBar: {
      items: [
        { kind: 'total', decimals: 1 },
        { kind: 'port', port: 'C2', decimals: 1 },
      ],
    },
    energy: energyBuckets(),
    notice: null,
    lastUpdatedMs: nowMs(),
  };
}

function liveState() {
  const state = baseState();
  const device = deviceSummary();
  state.phase = 'polling';
  state.device = device;
  state.devices = [device];
  state.ports = livePorts();
  state.totals = {
    watts: 42,
    limit: 160,
    chargingCount: 1,
    connectedCount: 2,
  };
  state.history = makeHistory(180);
  state.stats = {
    peakW: 59.4,
    avgW: 35.3,
    energyWh: 34.8,
    connectedMs: nowMs() - CONNECTED_AT,
  };
  return state;
}

function buildInitialState() {
  if (mode === 'empty') {
    const state = baseState();
    state.phase = 'idle';
    state.scanning = false;
    state.device = null;
    state.devices = [];
    return state;
  }
  if (mode === 'scan') {
    const state = baseState();
    state.phase = 'scanning';
    state.scanning = true;
    state.devices = nearbyDevices();
    state.history = [];
    return state;
  }
  if (mode === 'error') {
    const state = baseState();
    state.phase = 'failed';
    state.notice = {
      kind: 'error',
      text: '连接失败：请确认充电器已通电，并暂时退出正在占用它的官方 Anker App。',
    };
    return state;
  }
  return liveState();
}

let state = buildInitialState();
let tick = 0;

// ---------------------------------------------------------------------------
// Event bus + command dispatch

const handlers = new Map();

function emit(event, payload) {
  const list = handlers.get(event);
  if (!list) return;
  for (const fn of Array.from(list)) {
    try {
      fn(payload);
    } catch (err) {
      console.error('[charker:mock] listener failed', err);
    }
  }
}

function emitState() {
  state.lastUpdatedMs = nowMs();
  emit('state', deepClone(state));
}

function on(event, fn) {
  if (typeof fn !== 'function') return () => {};
  if (!handlers.has(event)) handlers.set(event, new Set());
  handlers.get(event).add(fn);
  return () => {
    const set = handlers.get(event);
    if (set) set.delete(fn);
  };
}

function once(event, fn) {
  const off = on(event, (payload) => {
    off();
    fn(payload);
  });
  return off;
}

function recalcTotals() {
  const ports = state.ports || [];
  const total = ports.reduce((sum, port) => sum + (Number(port.watts) || 0), 0);
  state.totals = {
    watts: round1(total),
    limit: state.totals.limit || 160,
    chargingCount: ports.filter((port) => (Number(port.watts) || 0) > 0.1).length,
    connectedCount: ports.filter(
      (port) => port.enabled && (Number(port.volts) || 0) > 3,
    ).length,
  };
  for (const port of ports) {
    port.barPct = clamp((Number(port.watts) || 0) / (state.totals.limit || 160), 0, 1);
  }
}

function findPort(portId) {
  const wanted = String(portId || '').toUpperCase();
  return (state.ports || []).find(
    (port) => String(port.id).toUpperCase() === wanted || String(port.label).toUpperCase() === wanted,
  );
}

function coerceSetting(key, value) {
  if (key === 'brightness') return clamp(Number(value) || 0, 0, 100);
  if (key === 'language') return String(value) === 'en' ? 'en' : 'zh';
  if (key === 'screenOn' || key === 'autoLock' || key === 'fixedAllocation') {
    return value === true || value === 'true' || value === 1 || value === '1';
  }
  return value;
}

function buildEnergyReport(range) {
  const normalized = ['day', 'week', 'month'].includes(range) ? range : 'day';
  const summary = state.energy[normalized] || { wh: 0, cost: 0, currency: 'CNY' };
  const plan =
    normalized === 'day'
      ? { count: 24, step: 3600000 }
      : normalized === 'week'
        ? { count: 7, step: 86400000 }
        : { count: 30, step: 86400000 };
  const end = nowMs();
  const totalWh = Number(summary.wh) || 0;
  const weights = [];
  let weightSum = 0;
  for (let i = 0; i < plan.count; i += 1) {
    const weight = 0.55 + Math.abs(Math.sin(i * 1.31 + 0.4)) * 0.9;
    weights.push(weight);
    weightSum += weight;
  }
  let assigned = 0;
  const buckets = weights.map((weight, i) => {
    const isLast = i === weights.length - 1;
    const wh = isLast ? Math.max(0, round2(totalWh - assigned)) : round2((weight / weightSum) * totalWh);
    assigned = round2(assigned + wh);
    return { t: end - (plan.count - 1 - i) * plan.step, wh };
  });
  const sessions = [];
  const sessionCount = normalized === 'day' ? 3 : normalized === 'week' ? 7 : 12;
  for (let i = 0; i < sessionCount; i += 1) {
    const startMs = end - (sessionCount - i) * 3 * 3600000 - i * 900000;
    const durationMs = (28 + ((i * 13) % 55)) * 60000;
    const wh = round2((totalWh / sessionCount) * (0.6 + ((i * 7) % 10) / 20));
    sessions.push({
      startMs,
      endMs: startMs + durationMs,
      wh,
      peakW: round1(30 + ((i * 11) % 28)),
    });
  }
  return {
    range: normalized,
    buckets,
    totalWh,
    cost: Number(summary.cost) || 0,
    currency: summary.currency || 'CNY',
    sessions,
  };
}

// ---- commands -------------------------------------------------------------

const COMMANDS = {
  state() {
    return deepClone(state);
  },

  scanStart() {
    state.scanning = true;
    if (!state.device) {
      state.phase = 'scanning';
      state.devices = nearbyDevices();
    }
    emitState();
    return null;
  },

  scanStop() {
    state.scanning = false;
    state.phase = state.device ? 'polling' : 'idle';
    emitState();
    return null;
  },

  async connect(id) {
    const wanted = String(id == null ? '' : id);
    const found =
      (state.devices || []).find((device) => device.id === wanted) || deviceSummary({ id: wanted || liveDeviceId });
    state.phase = 'connecting';
    state.scanning = false;
    emitState();
    await sleep(900);
    state.device = { ...found, connected: true, saved: true, rssi: found.rssi || -52 };
    state.devices = [state.device, ...(state.devices || []).filter((device) => device.id !== state.device.id)];
    state.phase = 'polling';
    state.ports = livePorts();
    recalcTotals();
    if (!state.history.length) state.history = makeHistory(180);
    state.stats = {
      peakW: 59.4,
      avgW: 35.3,
      energyWh: 34.8,
      connectedMs: nowMs() - CONNECTED_AT,
    };
    state.energy = energyBuckets();
    state.notice = null;
    emitState();
    return null;
  },

  disconnect() {
    state.device = null;
    state.phase = 'idle';
    state.scanning = false;
    state.ports = idlePorts();
    state.totals = emptyTotals();
    state.history = [];
    state.stats = emptyStats();
    emitState();
    return null;
  },

  useMock(onValue) {
    state.app.mock = Boolean(onValue);
    emitState();
    return null;
  },

  setPortEnabled(portId, enabled) {
    const port = findPort(portId);
    if (!port) throw new Error(`mock: unknown port ${portId}`);
    port.enabled = Boolean(enabled);
    port.status = port.enabled ? 1 : 0;
    if (!port.enabled) {
      port.watts = 0;
      port.amps = 0;
      port.barPct = 0;
    } else if (String(port.id).toUpperCase() === 'C2') {
      port.watts = 42;
      port.volts = 27.46;
      port.amps = 1.53;
      port.protocol = 'Apple PD';
      port.epr = true;
      port.cable = 'EPR · 240W 线';
      port.deviceName = 'Apple';
    }
    recalcTotals();
    emitState();
    return null;
  },

  setCountdown(portId, minutes) {
    const port = findPort(portId);
    if (!port) throw new Error(`mock: unknown port ${portId}`);
    const value = Math.max(0, Math.trunc(Number(minutes) || 0));
    port.timerMinutes = value;
    port.countdownEndMs = value > 0 ? nowMs() + value * 60000 : 0;
    emitState();
    return null;
  },

  setSetting(key, value) {
    state.settings[key] = coerceSetting(key, value);
    if (key === 'language') {
      state.app.locale = state.settings.language;
    }
    emitState();
    return null;
  },

  energyReport(range) {
    return buildEnergyReport(range);
  },

  exportEnergy(range, format) {
    const normalized = ['day', 'week', 'month'].includes(range) ? range : 'day';
    const extension = format === 'json' ? 'json' : 'csv';
    return `charker-能耗-${normalized}.${extension}`;
  },

  setLocale(next) {
    state.app.locale = next === 'en' ? 'en' : 'zh';
    state.settings.language = state.app.locale;
    emitState();
    return null;
  },

  setTheme(theme) {
    state.app.theme = ['light', 'dark', 'system'].includes(theme) ? theme : 'system';
    emitState();
    return null;
  },
};

const commandLookup = new Map(Object.keys(COMMANDS).map((key) => [key.toLowerCase(), key]));

function dispatch(method, args) {
  const bare = String(method == null ? '' : method).split('.').pop() || '';
  const camel = bare.charAt(0).toLowerCase() + bare.slice(1);
  const key = commandLookup.get(camel.toLowerCase());
  if (!key) return Promise.reject(new Error(`mock: unsupported method ${method}`));
  try {
    return Promise.resolve(COMMANDS[key](...args));
  } catch (err) {
    return Promise.reject(err);
  }
}

// ---------------------------------------------------------------------------
// Live ticker: 1 Hz sine + jitter, keeps the layout identical to the Go app.

let ticker = 0;
function startTicker() {
  if (ticker) return;
  ticker = window.setInterval(() => {
    state.lastUpdatedMs = nowMs();
    if (!state.device || !state.device.connected || !state.ports.length) {
      return;
    }
    tick += 1;
    const base = 42 + Math.sin(tick * 0.37) * 2.1 + Math.sin(tick * 1.9) * 0.7;
    const jitter = (Math.random() - 0.5) * 1.2;
    const spike = tick % 47 === 0 ? 8 : tick % 23 === 0 ? 4 : 0;
    const total = clamp(base + jitter + spike, 30, 60);
    const port = findPort('C2');
    if (port && port.enabled) {
      port.watts = round2(total);
      port.volts = round2(27.4 + Math.sin(tick * 0.11) * 0.25);
      port.amps = round2(port.watts / (port.volts || 1));
      port.barPct = clamp(port.watts / (state.totals.limit || 160), 0, 1);
    }
    const c1 = findPort('C1');
    if (c1 && c1.enabled) c1.volts = round2(5.08 + Math.sin(tick * 0.23) * 0.02);
    recalcTotals();
    state.history = (state.history || []).concat({ t: nowMs(), w: state.totals.watts });
    if (state.history.length > 180) state.history = state.history.slice(-180);
    state.stats.energyWh = round2(state.stats.energyWh + state.totals.watts / 3600);
    state.stats.connectedMs = nowMs() - CONNECTED_AT;
    state.stats.peakW = Math.max(state.stats.peakW, state.totals.watts);
    emitState();
  }, 1000);
}

// ---------------------------------------------------------------------------
// Install window.mygo

function install() {
  const api = {
    platform: 'windows',
    windowId: 'mock-window',
    version: '0.1.0',
    locale: locale === 'en' ? 'en-US' : 'zh-CN',
    preferences: { theme: themePref },
    call(method, ...args) {
      return dispatch(method, args);
    },
    on,
    once,
    channel() {
      return {
        on() {
          return () => {};
        },
        close() {},
      };
    },
    // screenshot/testing helpers
    setState(patch) {
      state = deepMerge(state, patch || {});
      emitState();
      return deepClone(state);
    },
    getState() {
      return deepClone(state);
    },
    get mode() {
      return mode;
    },
  };
  window.mygo = api;
  window.__charkerMock = api;
  window.mock = api;
  startTicker();

  // One-time notices that the real app would emit after connecting.
  if (mode === 'error') {
    window.setTimeout(() => {
      emit('toast', {
        kind: 'error',
        text: state.notice
          ? state.notice.text
          : '连接失败：请确认充电器已通电，并暂时退出正在占用它的官方 Anker App。',
      });
    }, 700);
  } else if (mode === 'scan') {
    window.setTimeout(() => {
      emit('toast', { kind: 'info', text: '正在扫描附近的充电器…' });
    }, 600);
  }
}

if (installed) install();

export const MOCK_ACTIVE = installed;
export const MOCK_MODE = installed ? mode : null;
export function isMockActive() {
  return installed;
}
export function isMockMode(name) {
  return installed && mode === name;
}
