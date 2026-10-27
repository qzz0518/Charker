// Read-only views of AppState that the macOS views get from CharkerCore and
// AppModel: phase labels (SessionState.swift), port predicates and texts
// (A2687Protocol Telemetry + Components.swift), session stats and the power
// chart scale (PowerChartScale.swift). Every function takes plain AppState
// pieces; nothing here talks to Go.

import { t, tf } from './l10n.js';

export const PORTS = ['C1', 'C2', 'C3'];
export const RATED_WATTS = 160;

// ---- SessionPhase ------------------------------------------------------------

const STAGES = [
  'idle',
  'initialConnect',
  'capability',
  'baseInfo',
  'setCapability',
  'publicKeyExchange',
  'sharedSecretDerived',
  'aesMetadata',
  'userAuth',
  'sessionReady',
];

const STAGE_LABELS = {
  idle: '空闲',
  initialConnect: '初始握手',
  capability: '能力协商',
  baseInfo: '读取设备信息',
  setCapability: '确认能力',
  publicKeyExchange: '交换公钥',
  sharedSecretDerived: '派生会话密钥',
  aesMetadata: '同步会话参数',
  userAuth: '身份认证',
  sessionReady: '会话就绪',
};

/** monitoring: the macOS name of the Go "polling" phase. */
export function isLive(session) {
  return session.phase === 'polling';
}

export function isBusy(session) {
  return ['scanning', 'connecting', 'handshake', 'reconnecting'].includes(session.phase);
}

export function phaseShortLabel(session) {
  switch (session.phase) {
    case 'scanning':
      return t('搜索中');
    case 'connecting':
      return t('连接中');
    case 'handshake':
      return t('握手中');
    case 'polling':
      return t('已连接');
    case 'reconnecting':
      return t('重连中');
    case 'failed':
      return t('出错');
    default:
      return t('未启动');
  }
}

export function phaseDetail(session) {
  switch (session.phase) {
    case 'scanning':
      return t('正在搜索附近的 Anker Prime 充电器');
    case 'connecting':
      return t('正在连接充电器');
    case 'handshake':
      return tf('协商会话中 · %@', t(STAGE_LABELS[session.stage] || '空闲'));
    case 'polling':
      return t('正在接收实时数据');
    case 'reconnecting':
      return tf('第 %d 次重试 · %.0f 秒后继续', session.attempt || 1, retryDelay(session.attempt));
    case 'failed':
      return session.lastError || t('出错');
    default:
      return t('尚未开始');
  }
}

function retryDelay(attempt) {
  const a = Math.min(Math.max(attempt || 1, 1), 6);
  return 2 ** (a - 1);
}

/** SessionPhase.negotiationProgress: nil outside the handshake ladder. */
export function negotiationProgress(session) {
  switch (session.phase) {
    case 'connecting':
      return 0.05;
    case 'handshake': {
      const total = STAGES.indexOf('sessionReady');
      const index = Math.max(0, STAGES.indexOf(session.stage));
      return 0.1 + 0.9 * (index / total);
    }
    case 'polling':
      return 1;
    default:
      return null;
  }
}

/** SessionSnapshot.canBrowseNearbyDevices */
export function canBrowseNearbyDevices(session) {
  return ['idle', 'scanning', 'connecting', 'reconnecting', 'failed'].includes(session.phase);
}

// ---- Names ---------------------------------------------------------------------

/** SessionSnapshot.displayName */
export function snapshotDisplayName(session) {
  const d = session.device;
  if (!d) return null;
  if (d.productName) return d.productName === 'Charging' ? 'Anker Prime 160W' : d.productName;
  return d.name || null;
}

export function savedCharger(state, id) {
  return (state.savedChargers || []).find((c) => c.id === id) || null;
}

/** SavedCharger.displayName */
export function savedDisplayName(c) {
  if (c.nickname) return c.nickname;
  const serial = c.serialNumber || '';
  return serial.length >= 4 ? `Anker Prime 160W · ${serial.slice(-4)}` : 'Anker Prime 160W';
}

/** AppModel.activeDisplayName: the session's name, or the saved nickname. */
export function activeDisplayName(state) {
  const name = snapshotDisplayName(state.session);
  if (name == null) return null;
  if (state.prefs.demoMode) return name;
  const saved = savedCharger(state, state.session.device?.id);
  return saved?.nickname || name;
}

export function hasRememberedCharger(state) {
  return (state.savedChargers || []).length > 0 || !!state.prefs.lastDeviceId;
}

// ---- Telemetry -------------------------------------------------------------------

export function telemetryPort(state, port) {
  return state.session.telemetry?.ports?.find((p) => p.port === port) || null;
}

export function totalPower(session) {
  const ports = session.telemetry?.ports;
  if (!ports) return null;
  return ports.reduce((sum, p) => sum + (p.statusCode !== 0 ? p.power : 0), 0);
}

export const isOn = (p) => !!p && p.statusCode !== 0;
export const isDelivering = (p) => isOn(p) && p.current > 0.02 && p.voltage > 3.0;
export const hasReadings = (p) => isOn(p) && (p.voltage > 0 || p.current > 0);

/** CableCapability: 0 60 W, 1 100 W, 2 EPR 240 W, 3 none; null unreported. */
export function cableCode(p) {
  return p && p.cableCode != null ? p.cableCode : null;
}

/** PortTelemetry.isCableAttached: null means not reported. */
export function isCableAttached(p) {
  if (isDelivering(p)) return true;
  const code = cableCode(p);
  if (code == null) return null;
  return code !== 3;
}

/** PortStandby.applies */
export function isStandby(p, graceUntil = 0) {
  if (!p || !isOn(p) || isDelivering(p)) return false;
  if (p.voltage > 3.0) return true;
  const code = cableCode(p);
  if (code != null && code !== 3) return true;
  return Date.now() < graceUntil;
}

export function cableIsBottleneck(p) {
  if (!isDelivering(p)) return false;
  switch (cableCode(p)) {
    case 0:
      return p.power > 55;
    case 1:
      return p.power > 92;
    default:
      return false;
  }
}

export function cableChipText(p) {
  const code = cableCode(p);
  if (code == null || code === 3) return null;
  switch (code) {
    case 0:
      return t(cableIsBottleneck(p) ? '线缆限制 60W' : '3A · 60W 线');
    case 1:
      return t(cableIsBottleneck(p) ? '线缆限制 100W' : '5A · 100W 线');
    case 2:
      return t('EPR · 240W 线');
    default:
      return t('未知线缆');
  }
}

export function profileText(p) {
  return p?.profileLabel || null;
}

// ---- Connected device (B4) ---------------------------------------------------------

const USB_VENDORS = {
  0x03f0: 'HP',
  0x045e: 'Microsoft',
  0x04e8: 'Samsung',
  0x05ac: 'Apple',
  0x0bda: 'Realtek',
  0x12d1: 'Huawei',
  0x17ef: 'Lenovo',
  0x18d1: 'Google',
  0x1d6b: 'Linux Foundation',
  0x2717: 'Xiaomi',
  0x291a: 'Anker',
  0x413c: 'Dell',
  0x8087: 'Intel',
};

const USB_SERIES = {
  0x05ac: {
    'iPhone 17': [0x751b, 0x7519, 0x751a],
    'iPhone Air': [0x7518],
    'iPhone 16': [0x751c, 0x7515, 0x7517],
    'iPhone 15': [0x7510, 0x7511, 0x7512, 0x7513],
    'iPhone 14': [0x750e, 0x750d, 0x750f],
    'iPhone 13': [0x7507, 0x7509, 0x750a],
    'iPhone 12': [0x7504, 0x7506],
    'iPhone SE 3': [0x750b],
    iPad: [0x7111, 0x7112, 0x711b],
    'iPad Air': [0x710d, 0x7108, 0x7114, 0x711c, 0x7115, 0x711d],
    'iPad mini': [0x710c, 0x7116],
    'iPad Pro': [0x7102, 0x7109, 0x710e, 0x7117, 0x711e],
    'MacBook Air': [0x7302, 0x7307, 0x730b, 0x7318, 0x7310, 0x7314, 0x731c, 0x731b],
    'MacBook Pro': [
      0x7304, 0x7306, 0x730e, 0x7308, 0x730c, 0x7313, 0x7319, 0x731a, 0x7309, 0x730d, 0x7312,
      0x7315,
    ],
  },
  0x291a: {
    'Anker Prime Power Bank 26K': [0x110a],
    'Anker Prime Power Bank 20K': [0x110b],
    'Anker Power Bank 5K': [0x1665],
    'Anker Power Bank 10K': [0x1669],
    'Anker Power Bank 27K': [0x1340],
    'Anker Wireless Charger 35W': [0x25f7],
  },
};

function usbModel(vid, pid) {
  const series = USB_SERIES[vid];
  if (!series) return null;
  for (const [name, ids] of Object.entries(series)) if (ids.includes(pid)) return name;
  return null;
}

/** unreported | noIdentity | unidentified | identified */
export function connectedDeviceState(p) {
  const d = p?.device;
  if (!d) return 'unreported';
  if (d.noIdentity) return 'noIdentity';
  if (d.vendorId === 0 && d.productId === 0) return 'unidentified';
  return 'identified';
}

export function connectedDeviceText(p) {
  switch (connectedDeviceState(p)) {
    case 'unidentified':
      return t('已接入 · 未报告身份');
    case 'identified':
      return (
        usbModel(p.device.vendorId, p.device.productId) ||
        USB_VENDORS[p.device.vendorId] ||
        t('已接入')
      );
    default:
      return null;
  }
}

export function connectedDeviceHelp(p) {
  switch (connectedDeviceState(p)) {
    case 'unreported':
      return t('充电器没有报告接入设备的信息');
    case 'noIdentity':
      return t('充电器没报这个口接的是什么。要看有没有插东西，看上面的电压电流。');
    case 'unidentified':
      return t('设备已接入，但没有报出 USB 身份');
    default: {
      const vendor = USB_VENDORS[p.device.vendorId];
      return vendor ? tf('充电器识别到 %@ 设备', vendor) : t('充电器识别到设备，但无法判断厂商');
    }
  }
}

// ---- Session stats ------------------------------------------------------------------

/** AppModel.sessionStats, from the rolling history. */
export function sessionStats(session) {
  const history = session.history || [];
  if (history.length < 2) return null;
  let peak = 0;
  let sum = 0;
  let energyWs = 0;
  history.forEach((s, i) => {
    peak = Math.max(peak, s.total);
    sum += s.total;
    if (i > 0) {
      const dt = (s.t - history[i - 1].t) / 1000;
      if (dt > 0 && dt < 120) energyWs += (dt * (s.total + history[i - 1].total)) / 2;
    }
  });
  return {
    peak,
    average: sum / history.length,
    energyWh: energyWs / 3600,
    connectedAt: session.connectedAtMs || null,
  };
}

// ---- PowerChartScale -----------------------------------------------------------------

export const POWER_CHART_OPTIONS = [50, 100, 160];

export function effectiveChartMaximum(preference, observedPeak) {
  const choices = POWER_CHART_OPTIONS;
  const normalized = preference === 0 || choices.includes(preference) ? preference : 0;
  const peak = Number.isFinite(observedPeak) ? Math.max(0, observedPeak) : 0;
  const target = normalized === 0 ? peak * 1.15 : peak;
  const floor = normalized === 0 ? choices[0] : normalized;
  const required = Math.max(floor, target);
  const choice = choices.find((c) => c >= required);
  if (choice) return choice;
  return Math.max(Math.ceil(required / 50) * 50, choices[choices.length - 1]);
}

export function chartCeiling(maximum) {
  return Math.max(1, maximum) * 1.05;
}

export function chartAxisValues(maximum) {
  const max = Math.max(1, maximum);
  let step;
  if (max <= 50) step = 10;
  else if (max <= 100) step = 25;
  else if (max === 150) step = 50;
  else if (max === 160) step = 40;
  else if (max <= 250) step = 50;
  else step = Math.max(50, Math.ceil(max / 5 / 50) * 50);
  const values = [];
  for (let v = 0; v <= max; v += step) values.push(v);
  if (values[values.length - 1] !== max) values.push(max);
  return values;
}
