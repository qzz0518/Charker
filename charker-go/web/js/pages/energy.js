// EnergyHistoryView: the local energy ledger as an EV trip log — an odometer
// on top, a range chart, the port mix and load profile, then the inspectable
// connection runs. The ledger itself lives in Go (internal/energy, a port of
// EnergyHistory.swift); this page asks for one range's digest with
// Charker.EnergyReport whenever state.energy.revision moves.

import { html, useEffect, useLayoutEffect, useMemo, useRef, useState } from '../lib.js';
import { currentLocale, t, tf } from '../core/l10n.js';
import { call, setActionMessage, setPrefs } from '../core/store.js';
import { chartAxisValues, chartCeiling as powerChartCeiling, isLive } from '../core/model.js';
import { ActionButton, Chip, Icon, Segmented, SlateCard, confirmDialog, cx, openMenu } from '../ui/components.js';
import { registerIcons } from '../ui/icons.js';

// Glyphs the registry lacks (Lucide-style, ISC).
registerIcons({
  // bolt.horizontal.fill
  'energy-bolt-horizontal':
    '<svg class="ck-icon" width="1em" height="1em" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true" focusable="false"><path d="M1.5 14.2 7.4 8.6c.4-.4 1-.3 1.3.1l3.6 4.3 3.9-4.6c.4-.5 1.1-.5 1.5-.1l4.8 4.6c.5.5-.1 1.3-.7 1l-4.3-2.3-3.9 4.6c-.4.5-1.1.5-1.5 0L8.3 12l-5.9 3.4c-.7.4-1.4-.6-.9-1.2Z"/></svg>',
  // point.3.filled.connected.trianglepath.dotted
  'energy-points':
    '<svg class="ck-icon" width="1em" height="1em" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-dasharray="2 2.6" aria-hidden="true" focusable="false"><path d="M5 6.5h14M5.8 7.6l5.4 10M18.2 7.6l-5.4 10"/><g fill="currentColor" stroke="none"><circle cx="4.5" cy="6" r="2.6"/><circle cx="19.5" cy="6" r="2.6"/><circle cx="12" cy="19" r="2.6"/></g></svg>',
});

// ---- Constants from the Swift view ----------------------------------------------

const S = { xxs: 2, xs: 4, s: 8, m: 12, l: 16, xl: 20, xxl: 28 };
const PORT_OPACITY = [1, 0.82, 0.68, 0.56, 0.44, 0.34];
const RANGES = ['session', 'day', 'week', 'month', 'all'];
const RANGE_TITLE = { session: '本次', day: '今天', week: '本周', month: '本月', all: '全部' };
const SUMMARY_LABEL = {
  session: '本次累计能量',
  day: '今日累计能量',
  week: '本周累计能量',
  month: '本月累计能量',
  all: '全部累计能量',
};
const CHART_SUBTITLE = {
  session: '本次按小时分段 · 指针移过查看',
  day: '今天按小时分段 · 指针移过查看',
  week: '本周按天分段 · 指针移过查看',
  month: '本月按天分段 · 指针移过查看',
  all: '按月分段 · 指针移过查看',
};
const X_TICKS = { session: 4, day: 5, week: 7, month: 5, all: 6 };
// The smallest tick step each range's axis label can tell apart.
const AXIS_UNIT = { session: 60000, day: 3600000, week: 86400000, month: 86400000, all: 0 };
const METRICS = ['energy', 'averagePower', 'peakPower'];
const METRIC_TITLE = { energy: '能量', averagePower: '平均', peakPower: '峰值' };
const CLEAR = {
  day: { menu: '清空今天的记录…', title: '清空今天的能耗记录？', button: '清空今天', done: '今天的能耗记录已清空' },
  week: { menu: '清空本周的记录…', title: '清空本周的能耗记录？', button: '清空本周', done: '本周的能耗记录已清空' },
  month: { menu: '清空本月的记录…', title: '清空本月的能耗记录？', button: '清空本月', done: '本月的能耗记录已清空' },
  all: { menu: '清空全部记录…', title: '清空全部能耗记录？', button: '清空全部记录', done: '能耗记录已清空' },
};
// ChargerPortID raw values: the slot of each port in every per-port array.
const PORT_SLOTS = ['C1', 'C2', 'C3', 'C4', 'A1', 'A2'];
const DEFAULT_PORTS = ['C1', 'C2', 'C3'];

/** ChargerProduct.ports as {label, slot}. */
const productPorts = (labels) =>
  (labels?.length ? labels : DEFAULT_PORTS).map((label) => ({ label, slot: PORT_SLOTS.indexOf(label) }));

// PowerChartScale.options(for:) and the preference key per product.
const CHART_OPTIONS = { a2687: [50, 100, 160], a2345: [50, 100, 150, 200, 250] };
const chartOptions = (product) => CHART_OPTIONS[product] || CHART_OPTIONS.a2687;
const chartPreferenceKey = (product) => (product === 'A2345' ? 'a2345PowerChartMaximum' : 'a2687PowerChartMaximum');

/** PowerChartScale.effectiveMaximum. */
function effectiveChartMaximum(preference, product, observedPeak) {
  const choices = chartOptions(product);
  const normalized = preference === 0 || choices.includes(preference) ? preference : 0;
  const peak = Number.isFinite(observedPeak) ? Math.max(0, observedPeak) : 0;
  const target = normalized === 0 ? peak * 1.15 : peak;
  const required = Math.max(normalized === 0 ? choices[0] : normalized, target);
  const choice = choices.find((c) => c >= required);
  if (choice) return choice;
  return Math.max(Math.ceil(required / 50) * 50, choices[choices.length - 1]);
}

const CROSSHAIR = { width: 1, dash: '3 3', opacity: 0.72, gap: 12 };
const CHART_HEIGHT = 238;

const portColor = (index) =>
  `color-mix(in srgb, var(--c-accent) ${(PORT_OPACITY[index] ?? 0.3) * 100}%, transparent)`;

// ---- Formatting -------------------------------------------------------------------

function energyText(wh) {
  if (wh >= 1000) return { value: tf(wh >= 10000 ? '%.1f' : '%.2f', wh / 1000), unit: 'kWh' };
  return { value: tf(wh < 10 ? '%.2f' : '%.1f', wh), unit: 'Wh' };
}

function shortEnergy(wh) {
  const v = energyText(wh);
  return tf('%@ %@', v.value, v.unit);
}

function portEnergy(values, index) {
  const v = values?.[index];
  return Number.isFinite(v) ? Math.max(0, v) : 0;
}

function durationText(seconds) {
  const total = Math.max(0, Math.trunc(seconds));
  if (total < 60) return tf('%d秒', total);
  const minutes = Math.trunc(total / 60);
  const days = Math.trunc(minutes / 1440);
  const hours = Math.trunc((minutes % 1440) / 60);
  if (days > 0) return tf('%d天 %d小时', days, hours);
  if (hours > 0) return tf('%d小时 %d分', hours, minutes % 60);
  return tf('%d分钟', minutes % 60);
}

function compactDuration(seconds) {
  if (!(seconds > 0)) return '—';
  if (seconds < 60) return tf('%ds', Math.max(1, Math.round(seconds)));
  const minutes = Math.max(0, Math.trunc(seconds / 60));
  if (minutes >= 60) return tf('%dh%dm', Math.trunc(minutes / 60), minutes % 60);
  return tf('%dm', minutes);
}

function rowDurationText(seconds) {
  const total = Math.max(0, Math.trunc(seconds));
  if (total < 60) return tf('%d秒', total);
  const minutes = Math.trunc(total / 60);
  if (minutes >= 60) return tf('%d小时 %d分', Math.trunc(minutes / 60), minutes % 60);
  return tf('%d分钟', minutes);
}

const intlLocale = () => (currentLocale() === 'en' ? 'en-US' : 'zh-CN');
const formatters = new Map();
function fmtDate(ms, options) {
  const key = intlLocale() + JSON.stringify(options);
  let f = formatters.get(key);
  if (!f) {
    f = new Intl.DateTimeFormat(intlLocale(), options);
    formatters.set(key, f);
  }
  return f.format(new Date(ms));
}
const F = {
  hm: { hour: 'numeric', minute: '2-digit' },
  hms: { hour: 'numeric', minute: '2-digit', second: '2-digit' },
  hms2: { hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' },
  hm2: { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' },
  h2: { hour: '2-digit', hourCycle: 'h23' },
  md: { month: 'short', day: 'numeric' },
  ymd: { year: 'numeric', month: 'short', day: 'numeric' },
  ym: { year: 'numeric', month: 'short' },
  ymWide: { year: 'numeric', month: 'long' },
  wd: { weekday: 'short' },
  ymdw: { year: 'numeric', month: 'short', day: 'numeric', weekday: 'short' },
};

function periodLabel(range, ms) {
  if (range === 'session' || range === 'day') return fmtDate(ms, F.hm);
  if (range === 'all') return fmtDate(ms, F.ym);
  return fmtDate(ms, F.md);
}

function axisLabel(range, ms) {
  switch (range) {
    case 'session':
      return fmtDate(ms, F.hm2);
    case 'day':
      return fmtDate(ms, F.h2);
    case 'week':
      return fmtDate(ms, F.wd);
    case 'month':
      return fmtDate(ms, F.md);
    default:
      return fmtDate(ms, F.ym);
  }
}

function coverageLabel(range, report) {
  switch (range) {
    case 'session':
      return t('本次记录');
    case 'day':
      return fmtDate(report.nowMs, F.ymd);
    case 'week':
      return tf('%@ – %@', fmtDate(report.weekStartMs, F.md), fmtDate(report.weekEndMs - 1000, F.md));
    case 'month':
      return fmtDate(report.nowMs, F.ymWide);
    default:
      return t('全部历史');
  }
}

const startOfDay = (ms) => {
  const d = new Date(ms);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
};
const addDays = (ms, n) => {
  const d = new Date(ms);
  d.setDate(d.getDate() + n);
  return d.getTime();
};
const monthStart = (ms) => {
  const d = new Date(ms);
  return new Date(d.getFullYear(), d.getMonth(), 1).getTime();
};
const addMonths = (ms, n) => {
  const d = new Date(ms);
  return new Date(d.getFullYear(), d.getMonth() + n, 1).getTime();
};

function dayLabel(ms, nowMs) {
  const today = startOfDay(nowMs);
  if (ms === today) return t('今天');
  if (ms === addDays(today, -1)) return t('昨天');
  return fmtDate(ms, F.ymdw);
}

function formattedCurrency(amount, code) {
  const safe = Number.isFinite(amount) ? Math.max(0, amount) : 0;
  const currency = /^[A-Z]{3}$/.test(code || '') ? code : 'CNY';
  try {
    return new Intl.NumberFormat(currentLocale() === 'en' ? 'en' : 'zh-Hans', {
      style: 'currency',
      currency,
      minimumFractionDigits: 2,
      maximumFractionDigits: safe < 1 ? 4 : 2,
    }).format(safe);
  } catch {
    return tf('%@ %.2f', currency, safe);
  }
}

function estimatedCost(prefs, wh) {
  const price = prefs.energyPricePerKWh;
  if (!(price > 0) || !Number.isFinite(price) || !(wh >= 0) || !Number.isFinite(wh)) return null;
  const amount = (wh / 1000) * price;
  return Number.isFinite(amount) ? amount : null;
}

/** An energy.Text from Go: an L10n key whose arguments may be Texts. */
function localize(text) {
  if (!text) return '';
  const args = (text.args || []).map((a) => (a && typeof a === 'object' ? localize(a) : a));
  return tf(text.key, ...args);
}

function metricValue(metric, p) {
  const v = metric === 'energy' ? p.energyWh : metric === 'averagePower' ? p.averageWatts : p.peakWatts;
  return Number.isFinite(v) ? Math.max(0, v) : 0;
}

function metricAxisLabel(metric, value) {
  if (metric === 'energy') {
    if (value >= 1000) return tf('%.1f kWh', value / 1000);
    return tf(value < 10 ? '%.1f Wh' : '%.0f Wh', value);
  }
  return tf('%.0f W', value);
}

function quantizedCeiling(value) {
  if (!(value > 0) || !Number.isFinite(value)) return 1;
  const magnitude = 10 ** Math.floor(Math.log10(value));
  const steps = [1, 1.5, 2, 3, 4, 5, 6, 8, 10];
  return (steps.find((s) => value <= s * magnitude) ?? 10) * magnitude;
}

/** Swift Charts' automatic numeric ticks: a 1/2/5 step giving about `count`. */
function niceTicks(max, count) {
  if (!(max > 0)) return [0];
  const raw = max / Math.max(1, count - 1);
  const mag = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => s >= raw) ?? 10 * mag;
  const out = [];
  for (let v = 0; v <= max + step * 1e-9; v += step) out.push(Math.round(v / step) * step);
  return out;
}

/** Calendar-aware time ticks for a [lo, hi] ms domain, about `count` of them. */
function timeTicks(lo, hi, count, minStep = 0) {
  const span = hi - lo;
  const sec = 1000;
  const steps = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200].map(
    (s) => s * sec,
  );
  const step = minStep >= 86400000 ? null : steps.find((s) => s >= minStep && span / s <= count + 1);
  const out = [];
  if (step) {
    const offset = new Date(lo).getTimezoneOffset() * 60 * 1000;
    let v = Math.ceil((lo - offset) / step) * step + offset;
    for (; v <= hi; v += step) out.push(v);
    return out;
  }
  const days = span / 86400000;
  const dayStep = [1, 2, 7, 14].find((d) => days / d <= count + 1);
  if (dayStep) {
    let v = startOfDay(lo);
    if (v < lo) v = addDays(v, 1);
    if (dayStep === 7 || dayStep === 14) {
      // Weeks start on Monday, as the ledger's calendar does.
      while (new Date(v).getDay() !== 1) v = addDays(v, 1);
    }
    for (; v <= hi; v = addDays(v, dayStep)) out.push(v);
    return out;
  }
  const months = days / 30;
  const monthStep = [1, 2, 3, 6, 12].find((m) => months / m <= count + 1) ?? 12;
  let v = monthStart(lo);
  if (v < lo) v = addMonths(v, 1);
  for (; v <= hi; v = addMonths(v, monthStep)) out.push(v);
  return out;
}

// Monotone cubic through points (SwiftUI's .monotone interpolation).
function monotonePath(points) {
  const n = points.length;
  if (n === 0) return '';
  if (n === 1) return `M${points[0][0]},${points[0][1]}`;
  const dx = [];
  const m = [];
  for (let i = 0; i < n - 1; i++) {
    dx.push(points[i + 1][0] - points[i][0]);
    m.push(dx[i] === 0 ? 0 : (points[i + 1][1] - points[i][1]) / dx[i]);
  }
  const tangent = [m[0]];
  for (let i = 1; i < n - 1; i++) {
    tangent.push(m[i - 1] * m[i] <= 0 ? 0 : (3 * (dx[i - 1] + dx[i])) / ((2 * dx[i] + dx[i - 1]) / m[i - 1] + (dx[i] + 2 * dx[i - 1]) / m[i]));
  }
  tangent.push(m[n - 2]);
  let d = `M${points[0][0]},${points[0][1]}`;
  for (let i = 0; i < n - 1; i++) {
    const h = dx[i] / 3;
    d += `C${points[i][0] + h},${points[i][1] + tangent[i] * h} ${points[i + 1][0] - h},${points[i + 1][1] - tangent[i + 1] * h} ${points[i + 1][0]},${points[i + 1][1]}`;
  }
  return d;
}

// Catmull-Rom through points (Charts' .catmullRom), as cubic Béziers.
function catmullRomPath(points) {
  if (points.length < 3) return points.map((p, i) => `${i ? 'L' : 'M'}${p[0]},${p[1]}`).join('');
  let d = `M${points[0][0]},${points[0][1]}`;
  for (let i = 0; i < points.length - 1; i++) {
    const p0 = points[i - 1] || points[i];
    const p1 = points[i];
    const p2 = points[i + 1];
    const p3 = points[i + 2] || p2;
    d += `C${p1[0] + (p2[0] - p0[0]) / 6},${p1[1] + (p2[1] - p0[1]) / 6} ${p2[0] - (p3[0] - p1[0]) / 6},${p2[1] - (p3[1] - p1[1]) / 6} ${p2[0]},${p2[1]}`;
  }
  return d;
}

// ---- Derived values -----------------------------------------------------------------

function makePortSlices(summary, ports) {
  const values = ports.map((p) => portEnergy(summary.perPortWh, p.slot));
  const total = values.reduce((a, b) => a + b, 0);
  if (!(total > 0)) return ports.map((p) => ({ port: p.label, index: p.slot, energyWh: 0, percentage: 0 }));
  const raw = values.map((v) => (v / total) * 100);
  const pct = raw.map(Math.floor);
  const remainder = Math.max(0, 100 - pct.reduce((a, b) => a + b, 0));
  const order = raw
    .map((_, i) => i)
    .sort((a, b) => {
      const l = raw[a] - Math.floor(raw[a]);
      const r = raw[b] - Math.floor(raw[b]);
      return l === r ? values[b] - values[a] : r - l;
    });
  for (let k = 0; k < remainder; k++) pct[order[k % order.length]] += 1;
  return ports.map((p, i) => ({ port: p.label, index: p.slot, energyWh: values[i], percentage: pct[i] }));
}

function makeLoadBands(range, periods, history, rated) {
  const b = [0, rated / 8, (rated * 3) / 8, (rated * 5) / 8, rated];
  const l = b.map(Math.round);
  const defs = [
    [tf('%d–%d W', l[0], l[1]), b[0], b[1], 0.34],
    [tf('%d–%d W', l[1], l[2]), b[1], b[2], 0.52],
    [tf('%d–%d W', l[2], l[3]), b[2], b[3], 0.72],
    [tf('%d–%d W', l[3], l[4]), b[3], Number.MAX_VALUE, 1],
  ];
  let source = [];
  if (range === 'session' && history.length > 1) {
    for (let i = 1; i < history.length; i++) {
      const elapsed = (history[i].t - history[i - 1].t) / 1000;
      if (elapsed > 0 && elapsed < 120) source.push([(history[i - 1].total + history[i].total) / 2, elapsed]);
    }
  } else {
    source = periods.map((p) => [p.averageWatts, p.activeSeconds]);
  }
  return defs.map(([label, lo, hi, opacity]) => ({
    label,
    opacity,
    seconds: source.reduce((sum, [w, s]) => sum + (w >= lo && w < hi ? s : 0), 0),
  }));
}

// ---- Page ---------------------------------------------------------------------------

export default function EnergyPage({ state }) {
  const [range, setRange] = useState(() =>
    RANGES.includes(state.prefs.dashboardEnergyScope) ? state.prefs.dashboardEnergyScope : 'session',
  );
  const [metric, setMetric] = useState('energy');
  const [contentRevision, setContentRevision] = useState(0);
  const [visibleLimit, setVisibleLimit] = useState(16);
  const [report, setReport] = useState(null);
  const [rateSheet, setRateSheet] = useState(false);
  const [width, setWidth] = useState(0);
  const [minute, setMinute] = useState(0);
  const scroller = useRef(null);
  const revision = state.energy?.revision ?? 0;
  const ephemeral = !!state.energy?.ephemeral;

  useLayoutEffect(() => {
    const el = scroller.current;
    if (!el) return undefined;
    const ro = new ResizeObserver(() => setWidth(el.getBoundingClientRect().width));
    ro.observe(el);
    setWidth(el.getBoundingClientRect().width);
    return () => ro.disconnect();
  }, []);

  // The digest follows the ledger's revision (DigestCache) and the range.
  useEffect(() => {
    let live = true;
    call('EnergyReport', range)
      .then((r) => live && setReport(r))
      .catch((err) => live && setActionMessage(String(err?.message || err)));
    return () => {
      live = false;
    };
  }, [range, revision, contentRevision, minute]);

  // Calendar ranges roll over at midnight even without new telemetry.
  useEffect(() => {
    const timer = setInterval(() => setMinute((n) => n + 1), 60000);
    return () => clearInterval(timer);
  }, []);

  const changeRange = (next) => {
    setRange(next);
    setContentRevision((n) => n + 1);
    setVisibleLimit(16);
    if (next !== 'all') setPrefs({ dashboardEnergyScope: next }).catch(() => {});
  };

  // Layout branches by the scroll view's width, as the Swift view does
  // (contentWidth; the legacy scroller always takes 15 pt).
  const contentWidth = width;
  const scrolled = contentWidth - 15;
  const layout = {
    analyticsSide: contentWidth > 0 && Math.min(contentWidth, 1120) - 2 * S.xxl >= 470 + S.l + 258,
    analyticsPair: contentWidth > 0 && Math.min(contentWidth, 1120) - 2 * S.xxl >= 300 + S.l + 300,
    summarySide: contentWidth > 0 && Math.min(scrolled, 1120) - 2 * S.xxl - 2 * S.xl >= 270 + 1 + 370,
    rowOneLine:
      contentWidth > 0 && Math.min(scrolled, 1120) - 2 * S.xxl - 2 * S.l - 2 * S.m >= 210 + 92 + 90 + 126 + 3 * S.m,
  };

  const history = state.session.history || [];
  const digest = useMemo(() => {
    if (!report) return null;
    const ports = productPorts(report.ports);
    const portSlices = makePortSlices(report.summary, ports);
    const loadBands = makeLoadBands(range, report.periods, history, report.ratedWatts || 160);
    return {
      ...report,
      ports,
      portSlices,
      renderedSlices: portSlices.filter((s) => s.energyWh > 0 && s.percentage > 0),
      loadBands,
      loadCeiling: Math.max(1, ...loadBands.map((b) => b.seconds)),
    };
    // Session load bands integrate the live history, which only grows at the end.
  }, [report, range, range === 'session' ? history.length && history[history.length - 1].t : 0]);

  const ctx = { state, range, metric, setMetric, digest, layout, ephemeral, contentRevision };

  return html`<div class="page scroll energy" ref=${scroller}>
    <div class="page__content energy__content">
      <${Header}
        ...${ctx}
        onRange=${changeRange}
        onCleared=${() => {
          setContentRevision((n) => n + 1);
          setVisibleLimit(16);
        }}
      />
      ${digest && !ephemeral
        ? html`${digest.warning ? html`<${WarningCard} text=${localize(digest.warning)} />` : null}
          ${digest.skippedCompaction ? html`<${WarningCard} text=${localize(digest.skippedCompaction)} />` : null}`
        : null}
      ${!digest
        ? null
        : digest.periods.length === 0 && digest.sessions.length === 0
          ? html`<${EmptyState} range=${range} ephemeral=${ephemeral} />`
          : html`<${SummaryCard} key=${`summary-${contentRevision}`} ...${ctx} onRate=${() => setRateSheet(true)} />
              <${Analytics} ...${ctx} />
              <${SessionLedger}
                ...${ctx}
                limit=${visibleLimit}
                onMore=${() => setVisibleLimit((n) => n + 16)}
              />`}
      ${digest && !ephemeral && digest.archivedSessionCount > 0
        ? html`<div class="energy__folded t-micro c-tertiary">
            <${Icon} name="archivebox" size=${10} />
            <span class="para">${tf('更早的 %d 段旅程已折叠，只保留计数。', digest.archivedSessionCount)}</span>
          </div>`
        : null}
    </div>
    ${rateSheet ? html`<${ElectricityRateSheet} prefs=${state.prefs} onClose=${() => setRateSheet(false)} />` : null}
  </div>`;
}

// ---- Header ---------------------------------------------------------------------------

function Header({ state, range, digest, ephemeral, onRange, onCleared }) {
  const row = useRef(null);
  const [stacked, setStacked] = useState(false);
  // ViewThatFits: the one-row header when its ideal width fits, else the
  // stacked one. Ideal widths are measured from content, never from the
  // current branch, so switching cannot feed back into the measurement.
  useLayoutEffect(() => {
    const el = row.current;
    if (!el) return undefined;
    const check = () => {
      const items = [...el.querySelectorAll('.segmented__item')];
      const picker = items.reduce((sum, b) => sum + measureText(b.textContent.trim(), 12, 'ui') + 2 * S.m, 0) + S.xxs * (items.length - 1) + 8;
      const buttons = [...el.querySelectorAll('.energy__actions > .btn')];
      const actions = buttons.reduce((sum, b) => sum + b.offsetWidth, 0) + S.m * (buttons.length - 1);
      setStacked(picker + S.m + actions > el.clientWidth + 0.5);
    };
    const ro = new ResizeObserver(check);
    ro.observe(el);
    check();
    return () => ro.disconnect();
  }, []);

  const hasActive = !!state.energy?.hasActiveSession;
  const exportUnavailable = ephemeral || !digest?.exportable;
  const canClear = !!digest?.canClear;

  const exportAs = async (format) => {
    try {
      const path = await call('ExportEnergy', format);
      if (path) setActionMessage(tf('已导出到 %@', path.split(/[\\/]/).pop()));
    } catch (err) {
      setActionMessage(tf('导出失败：%@', String(err?.message || err)));
    }
  };

  const clear = async (scope) => {
    const c = CLEAR[scope];
    const message =
      scope === 'all'
        ? t('这会永久删除这台电脑上保存的全部能耗记录，无法撤销。不会断开充电器或停止供电；如果仍在连接，下一次采样会从零开始一段新记录。')
        : t('这会永久删除所选日历范围内的能耗记录，无法撤销。跨越范围边界的连接旅程也会从列表移除，但范围外的能耗汇总会保留。不会断开充电器或停止供电；仍在连接时，下一次采样会开始新记录。');
    const choice = await confirmDialog({
      title: t(c.title),
      message,
      actions: [
        { title: t('取消'), role: 'cancel', default: true },
        { title: t(c.button), role: 'destructive', value: scope },
      ],
    });
    if (choice !== scope) return;
    try {
      const ok = await call('ClearEnergyHistoryIn', scope);
      if (ok) {
        onCleared();
        setActionMessage(t(c.done));
      }
    } catch {
      // Go posted the failure as the action message.
    }
  };

  const exportButton = html`<${ActionButton}
    icon="square.and.arrow.up"
    title=${t('导出')}
    disabled=${exportUnavailable}
    help=${ephemeral ? t('演示数据不写入历史，也不提供导出') : t('导出这台电脑上的能耗记录；文件里会写明这些数字是怎么来的')}
    onClick=${(e) =>
      openMenu(e.currentTarget, [
        { title: t('导出 CSV…'), action: () => exportAs('csv') },
        { title: t('导出 JSON…'), action: () => exportAs('json') },
      ])}
  />`;
  const endButton = html`<${ActionButton}
    icon="stop.circle"
    title=${t('结束本次')}
    disabled=${!hasActive}
    help=${t('只结束统计，不影响充电；之后会自动开始新的一段')}
    aria-description=${t('不会断开充电器或停止供电')}
    onClick=${() => call('EndEnergySession').catch(() => {})}
  />`;
  const clearButton = html`<${ActionButton}
    emphasis="destructive"
    icon="trash"
    title=${t('清理记录')}
    disabled=${!canClear}
    help=${ephemeral ? t('演示数据不会写入本机记录') : t('按今天、本周、本月或全部范围清理本机能耗记录')}
    onClick=${(e) =>
      openMenu(e.currentTarget, [
        ...['day', 'week', 'month'].map((scope) => ({
          title: t(CLEAR[scope].menu),
          destructive: true,
          disabled: !digest?.clearable?.[scope],
          action: () => clear(scope),
        })),
        { separator: true },
        { title: t(CLEAR.all.menu), destructive: true, action: () => clear('all') },
      ])}
  />`;
  const picker = html`<${Segmented}
    class="energy__range"
    label=${t('能耗统计范围')}
    value=${range}
    segments=${RANGES.map((r) => ({ value: r, title: t(RANGE_TITLE[r]) }))}
    onChange=${onRange}
  />`;

  return html`<div class="energy__header">
    <div class="energy__title">
      <h1 class="t-title c-primary">${t('能耗里程')}</h1>
      <${Chip} text=${t(ephemeral ? '演示数据' : '本机记录')} tone=${ephemeral ? 'accent' : 'neutral'} />
    </div>
    <div class=${cx('energy__controls', stacked && 'is-stacked')} ref=${row}>
      ${picker}
      <div class="energy__actions">${exportButton}${endButton}${clearButton}</div>
    </div>
  </div>`;
}

function WarningCard({ text }) {
  return html`<div class="energy__warning">
    <span class="c-warn"><${Icon} name="exclamationmark.triangle.fill" /></span>
    <span class="t-caption c-secondary para">${text}</span>
  </div>`;
}

function EmptyState({ range, ephemeral }) {
  const title =
    range === 'session' ? t('本次统计尚未开始') : t(ephemeral ? '演示能耗正在生成' : '该时段还没有能耗记录');
  return html`<${SlateCard} padding=${S.xxl}>
    <div class="energy__empty">
      <span class="c-accent"><${Icon} name="gauge.with.dots.needle.0percent" size=${27} /></span>
      <span class="t-heading c-primary">${title}</span>
    </div>
  <//>`;
}

// ---- Summary card ------------------------------------------------------------------------

function SummaryCard({ state, range, digest, layout, onRate }) {
  const summary = digest.summary;
  const recording = state.energy?.hasActiveSession && range === 'session';
  return html`<${SlateCard} padding=${0} class="energy__summary">
    <div class="energy__summary-head">
      <div class="energy__stack-xs">
        <span class="t-heading c-primary">${t('里程总览')}</span>
        <span class="t-micro c-tertiary">${coverageLabel(range, digest)}</span>
      </div>
      ${recording
        ? html`<span class="energy__recording t-micro"><span class="energy__dot"></span>${t('正在记录')}</span>`
        : null}
    </div>
    <div class="energy__hairline"></div>
    <div class=${cx('energy__summary-body', layout.summarySide ? 'is-side' : 'is-stacked')}>
      <${Odometer} range=${range} summary=${summary} ports=${digest.ports} />
      ${layout.summarySide ? html`<div class="energy__vdivider"></div>` : html`<div class="energy__hairline"></div>`}
      <${MetricGrid} summary=${summary} />
    </div>
    <${InsightRail} prefs=${state.prefs} summary=${summary} ports=${digest.ports} onRate=${onRate} />
  <//>`;
}

function Odometer({ range, summary, ports }) {
  const energy = energyText(summary.energyWh);
  return html`<div class="energy__odometer">
    <div class="energy__stack-xs">
      <span class="t-micro c-tertiary">${t(SUMMARY_LABEL[range])}</span>
      <div class="energy__reading">
        <span class="num energy__reading-value">${energy.value}</span>
        <span class="energy__reading-unit">${energy.unit}</span>
      </div>
    </div>
    <${PortEnergyRail} values=${summary.perPortWh} ports=${ports} height=${5} />
    <div class="energy__port-legend">
      ${ports.map(
        (p) => html`<span class="energy__port-legend-item t-micro c-tertiary">
          <span class="energy__swatch" style=${{ background: portColor(p.slot) }}></span>
          ${`${p.label} ${shortEnergy(portEnergy(summary.perPortWh, p.slot))}`}
        </span>`,
      )}
    </div>
  </div>`;
}

function MetricGrid({ summary }) {
  const metric = (label, value, unit) => html`<div class="energy__stack-xs">
    <span class="t-micro c-tertiary">${t(label)}</span>
    <span class="energy__metric">
      <span class="num energy__metric-value">${value}</span>
      ${unit ? html`<span class="energy__metric-unit">${t(unit)}</span>` : null}
    </span>
  </div>`;
  return html`<div class="energy__metric-grid">
    ${metric('监测时长', durationText(summary.activeSeconds))}
    ${metric('连接旅程', tf('%d 段', summary.sessionCount))}
    ${metric('平均功率', tf('%.1f', summary.averageWatts), 'W')}
    ${metric('峰值功率', tf('%.1f', summary.peakWatts), 'W')}
  </div>`;
}

function InsightRail({ prefs, summary, ports, onRate }) {
  const row = useRef(null);
  const [stacked, setStacked] = useState(false);
  useLayoutEffect(() => {
    const el = row.current;
    if (!el) return undefined;
    const check = () => {
      const insights = [...el.querySelectorAll('.energy__insight')];
      const ideal = insights.reduce(
        (sum, c) => sum + [...c.children].reduce((w, k) => w + k.offsetWidth, 0) + S.s * (c.children.length - 1),
        0,
      );
      const dividers = (insights.length - 1) * (1 + 2 * S.m);
      setStacked(ideal + dividers > el.clientWidth - 2 * S.xl + 0.5);
    };
    const ro = new ResizeObserver(check);
    ro.observe(el);
    check();
    return () => ro.disconnect();
  }, []);

  let dominant = t('暂无');
  if (summary.energyWh > 0 && ports.length) {
    let best = ports[0];
    for (const p of ports) {
      if (portEnergy(summary.perPortWh, p.slot) > portEnergy(summary.perPortWh, best.slot)) best = p;
    }
    dominant = `${best.label} · ${Math.round((portEnergy(summary.perPortWh, best.slot) / summary.energyWh) * 100)}%`;
  }
  const average = summary.sessionCount > 0 ? shortEnergy(summary.energyWh / summary.sessionCount) : t('暂无');
  const amount = estimatedCost(prefs, summary.energyWh);
  const cost = amount == null ? t('设置电价') : formattedCurrency(amount, prefs.energyCurrencyCode);
  const rateHelp =
    prefs.energyPricePerKWh > 0
      ? tf('按 %@/kWh 估算，点击修改', formattedCurrency(prefs.energyPricePerKWh, prefs.energyCurrencyCode))
      : t('点击设置货币和每度电价格');
  const insight = (icon, label, value) => html`<span class="energy__insight">
    <span class="energy__insight-icon"><${Icon} name=${icon} size=${13} /></span>
    <span class="t-micro c-tertiary energy__nowrap">${t(label)}</span>
    <span class="num energy__insight-value">${value}</span>
  </span>`;
  const divider = stacked ? null : html`<span class="energy__insight-divider"></span>`;
  return html`<div class=${cx('energy__insights', stacked && 'is-stacked')} ref=${row}>
    ${insight('energy-bolt-horizontal', '主力端口', dominant)} ${divider}
    ${insight('activity', '最高负载', tf('%.1f W', summary.peakWatts))} ${divider}
    ${insight('energy-points', '每段平均', average)} ${divider}
    <button class="energy__insight-button" title=${rateHelp} aria-description=${t('打开货币和每度电价格设置')} onClick=${onRate}>
      ${insight('banknote.fill', '估算电费', cost)}
    </button>
  </div>`;
}

/** PortEnergyRail: one capsule split by each port's share. */
function PortEnergyRail({ values, ports, height = 5, maxWidth }) {
  const active = ports.map((p) => p.slot).filter((i) => portEnergy(values, i) > 0.000001);
  const total = active.reduce((sum, i) => sum + portEnergy(values, i), 0);
  return html`<div
    class="energy__rail"
    style=${{ height: `${height}px`, maxWidth: maxWidth ? `${maxWidth}px` : undefined }}
    role="img"
    aria-label=${t('端口能量占比')}
  >
    ${total > 0
      ? html`<div class="energy__rail-segments">
          ${active.map(
            (i) => html`<span
              style=${{
                flex: `${portEnergy(values, i) / total} 1 0`,
                minWidth: '2px',
                background: portColor(i),
              }}
            ></span>`,
          )}
        </div>`
      : html`<div class="energy__rail-empty"></div>`}
  </div>`;
}

function ElectricityRateSheet({ prefs, onClose }) {
  const initialPrice = () => {
    const p = prefs.energyPricePerKWh;
    if (!(p > 0) || !Number.isFinite(p)) return '0';
    return new Intl.NumberFormat(intlLocale(), { maximumFractionDigits: 6, useGrouping: false }).format(p);
  };
  const [code, setCode] = useState(prefs.energyCurrencyCode || '');
  const [priceText, setPriceText] = useState(initialPrice);
  const normalized = /^[A-Z]{3}$/.test(code.trim().toUpperCase()) ? code.trim().toUpperCase() : null;
  const trimmed = priceText.trim();
  const parsed = trimmed === '' ? NaN : Number(trimmed.replace(',', '.'));
  const price = Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
  const canSave = normalized != null && price != null;
  const save = () => {
    if (!canSave) return;
    setPrefs({ energyCurrencyCode: normalized, energyPricePerKWh: price }).catch(() => {});
    onClose();
  };
  useEffect(() => {
    const key = (e) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        onClose();
      }
    };
    document.addEventListener('keydown', key, true);
    return () => document.removeEventListener('keydown', key, true);
  }, []);
  return html`<div class="dialog-backdrop" onPointerDown=${(e) => e.target === e.currentTarget && onClose()}>
    <div class="dialog energy__rate" role="dialog" aria-label=${t('电费估算')}>
      <div class="energy__rate-head">
        <span class="energy__rate-icon"><${Icon} name="banknote.fill" size=${18} /></span>
        <span class="t-heading c-primary">${t('电费估算')}</span>
      </div>
      <${SlateCard} padding=${S.l}>
        <div class="energy__rate-body">
          <label class="energy__rate-row">
            <span class="t-caption c-secondary">${t('货币代码')}</span>
            <input
              class="field"
              style=${{ width: '92px' }}
              placeholder="CNY"
              value=${code}
              onInput=${(e) => {
                const next = e.currentTarget.value.toUpperCase().slice(0, 3);
                e.currentTarget.value = next;
                setCode(next);
              }}
            />
          </label>
          <div class="energy__hairline"></div>
          <label class="energy__rate-row">
            <span class="t-caption c-secondary">${t('每度电价格')}</span>
            <span class="energy__rate-price">
              <input
                class="field"
                style=${{ width: '112px' }}
                placeholder="0.60"
                value=${priceText}
                onInput=${(e) => setPriceText(e.currentTarget.value)}
                onKeyDown=${(e) => e.key === 'Enter' && save()}
              />
              <span class="t-caption c-tertiary">/ kWh</span>
            </span>
          </label>
          <div class="energy__rate-row">
            <span class="t-micro c-tertiary">${t('输入 0 可关闭电费估算')}</span>
            ${normalized && price != null
              ? html`<span class="num energy__rate-current">${tf('当前电价 %@/kWh', formattedCurrency(price, normalized))}</span>`
              : null}
          </div>
        </div>
      <//>
      <div class="dialog__actions energy__rate-actions">
        <button class="btn" onClick=${onClose}>${t('取消')}</button>
        <button class="btn is-primary" disabled=${!canSave} onClick=${save}>${t('保存')}</button>
      </div>
    </div>
  </div>`;
}

// ---- Analytics -----------------------------------------------------------------------------

function Analytics(props) {
  const { layout } = props;
  const side = useRef(null);
  const [sideHeight, setSideHeight] = useState(0);
  useLayoutEffect(() => {
    const el = side.current;
    if (!el) return undefined;
    const ro = new ResizeObserver(() => setSideHeight(Math.ceil(el.getBoundingClientRect().height)));
    ro.observe(el);
    return () => ro.disconnect();
  }, [layout.analyticsSide]);

  if (layout.analyticsSide) {
    return html`<div class="energy__analytics is-side">
      <div class="energy__trend-col"><${TrendCard} ...${props} minimumHeight=${sideHeight} /></div>
      <div class="energy__side-col" ref=${side}>
        <${PortMixCard} ...${props} />
        <${LoadProfileCard} ...${props} />
      </div>
    </div>`;
  }
  return html`<div class="energy__analytics">
    <${TrendCard} ...${props} />
    ${layout.analyticsPair
      ? html`<div class="energy__pair">
          <${PortMixCard} ...${props} inline=${true} />
          <${LoadProfileCard} ...${props} />
        </div>`
      : html`<${PortMixCard} ...${props} /><${LoadProfileCard} ...${props} />`}
  </div>`;
}

function TrendCard({ state, range, metric, setMetric, digest, contentRevision, minimumHeight = 0 }) {
  // The hover date lives in the card (ChartHoverScope); a new range, metric
  // or clear drops it.
  const [selected, setSelected] = useState(null);
  useEffect(() => setSelected(null), [range, metric, contentRevision]);
  const expands = minimumHeight > 0;
  const history = state.session.history || [];
  const observedPeak = history.reduce((m, s) => Math.max(m, s.total), 0);
  const product = digest.product;
  const preference = state.prefs[chartPreferenceKey(product)] || 0;
  const periods = digest.periods;
  const reference = range === 'session' ? 0 : chartReferenceValue(metric, periods);

  let chart;
  if (range === 'session' && history.length > 1) {
    chart = html`<${LivePowerChart}
      history=${history}
      ports=${digest.ports}
      axisMaximum=${effectiveChartMaximum(preference, product, observedPeak)}
      expands=${expands}
      selected=${selected}
      onSelect=${setSelected}
    />`;
  } else if (periods.length === 0) {
    chart = html`<div class=${cx('energy__chart-empty t-caption c-tertiary', expands && 'expands')}>
      <${Icon} name="chart.bar.xaxis" size=${18} />
      <span>${t(range === 'session' ? '正在积累本次功率轨迹…' : '该范围内暂无记录')}</span>
    </div>`;
  } else {
    chart = html`<${EnergyChart}
      key=${`chart-${range}-${metric}`}
      range=${range}
      metric=${metric}
      digest=${digest}
      prefs=${state.prefs}
      expands=${expands}
      selected=${selected}
      onSelect=${setSelected}
    />`;
  }

  let inspector = null;
  if (range === 'session') {
    const sample = (selected != null && nearestSample(history, selected)) || history[history.length - 1];
    inspector = html`<div class="energy__inspector-live">
      <div class="energy__live-legend" style=${{ maxWidth: digest.ports.length > 3 ? '360px' : '240px' }}>
        ${legendDot('总输出', 'var(--c-accent)', true)} ${digest.ports.map((p) => legendDot(p.label, portColor(p.slot), false))}
      </div>
      ${sample
        ? html`<span class="num energy__live-sample">${tf('%@ · %.1f W', fmtDate(sample.t, F.hms), sample.total)}</span>`
        : null}
    </div>`;
  } else {
    const record = (selected != null && nearestPeriod(periods, selected)) || periods[periods.length - 1];
    if (record) {
      inspector = html`<div class="energy__inspector">
        ${inspectorMetric('时段', periodLabel(range, record.startedAt))}
        <span class="energy__inspector-divider"></span>
        ${inspectorMetric('能量', shortEnergy(record.energyWh))}
        <span class="energy__inspector-divider"></span>
        ${inspectorMetric('平均', tf('%.1f W', record.averageWatts))}
        <span class="energy__inspector-divider"></span>
        ${inspectorMetric('峰值', tf('%.1f W', record.peakWatts))}
      </div>`;
    }
  }

  return html`<${SlateCard} padding=${S.xl} class="energy__trend">
    <div class="energy__trend-body" style=${{ minHeight: `${Math.max(0, minimumHeight - 2 * S.xl - 2)}px` }}>
      <div class="energy__card-head">
        <div class="energy__stack-xs">
          <span class="t-heading c-primary">${t(range === 'session' ? '实时功率轨迹' : '能耗趋势')}</span>
          <span class="t-micro c-tertiary">${range === 'session' ? t('指针移到图上查看任意时刻') : t(CHART_SUBTITLE[range])}</span>
          ${reference > 0
            ? html`<span class="energy__reference t-micro c-tertiary">
                <span class="energy__reference-dashes"><i></i><i></i><i></i></span>
                ${tf('均值 %@', metric === 'energy' ? shortEnergy(reference) : tf('%.1f W', reference))}
              </span>`
            : null}
        </div>
        ${range === 'session'
          ? html`<${PowerChartScaleMenu} product=${product} preference=${preference} observedPeak=${observedPeak} />`
          : html`<${Segmented}
              class="energy__metric-picker"
              label=${t('趋势图指标')}
              value=${metric}
              segments=${METRICS.map((m) => ({ value: m, title: t(METRIC_TITLE[m]) }))}
              onChange=${setMetric}
            />`}
      </div>
      ${chart} ${inspector}
    </div>
  <//>`;
}

function legendDot(label, color, solid) {
  return html`<span class="energy__legend-dot t-micro c-tertiary">
    <span style=${{ width: '12px', height: `${solid ? 3 : 2}px`, borderRadius: '2px', background: color, opacity: solid ? 1 : 0.68 }}></span>
    ${t(label)}
  </span>`;
}

function inspectorMetric(label, value) {
  return html`<span class="energy__inspector-metric">
    <span class="t-micro c-tertiary">${t(label)}</span>
    <span class="num energy__inspector-value">${value}</span>
  </span>`;
}

function chartReferenceValue(metric, periods) {
  if (!periods.length) return 0;
  const avg = periods.reduce((sum, p) => sum + metricValue(metric, p), 0) / periods.length;
  return Number.isFinite(avg) ? Math.max(0, avg) : 0;
}

const nearestSample = (history, at) =>
  history.reduce((best, s) => (!best || Math.abs(s.t - at) < Math.abs(best.t - at) ? s : best), null);
const nearestPeriod = (periods, at) =>
  periods.reduce(
    (best, p) => (!best || Math.abs(p.startedAt - at) < Math.abs(best.startedAt - at) ? p : best),
    null,
  );

/** PowerChartScaleMenu: the label always names the range being drawn. */
function PowerChartScaleMenu({ product, preference, observedPeak }) {
  const effective = effectiveChartMaximum(preference, product, observedPeak);
  const options = chartOptions(product);
  const key = chartPreferenceKey(product);
  // promoteManualRangeIfNeeded
  useEffect(() => {
    if (preference !== 0 && effective > preference && options.includes(effective)) {
      setPrefs({ [key]: effective }).catch(() => {});
    }
  }, [preference, effective, key]);
  const title = preference === 0 ? tf('自动 · %d W', effective) : tf('%d W', effective);
  const choose = (v) => v !== preference && setPrefs({ [key]: v }).catch(() => {});
  return html`<button
    class="btn energy__scale"
    title=${t('设置功率图纵轴；读数超过手动上限时会自动提高量程')}
    aria-label=${t('功率图量程')}
    aria-description=${title}
    onClick=${(e) =>
      openMenu(
        e.currentTarget,
        [
          { title: t('自动量程'), checked: preference === 0, action: () => choose(0) },
          { separator: true },
          ...options.map((m) => ({ title: tf('%d W', m), checked: preference === m, action: () => choose(m) })),
        ],
        { align: 'end' },
      )}
  >
    <${Icon} name="arrow.up.and.down" /><span>${title}</span>
  </button>`;
}

// ---- Charts ------------------------------------------------------------------------------------

/** Measures an element's box; charts lay out in CSS pixels. */
function useSize() {
  const ref = useRef(null);
  const [size, setSize] = useState({ width: 0, height: 0 });
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return undefined;
    const ro = new ResizeObserver(() => {
      const r = el.getBoundingClientRect();
      setSize((s) => (s.width === r.width && s.height === r.height ? s : { width: r.width, height: r.height }));
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  return [ref, size];
}

/** The plot frame inside a chart box: leading y labels, x labels below. */
function plotFrame(size, yLabels) {
  const labelWidth = Math.max(...yLabels.map((s) => measureText(s, 9)), 0);
  const left = Math.ceil(labelWidth) + 6;
  const bottom = 18;
  return { x: left, y: 6, w: Math.max(1, size.width - left), h: Math.max(1, size.height - bottom - 6) };
}

let measureCtx = null;
function measureText(text, px, family = 'num') {
  measureCtx ||= document.createElement('canvas').getContext('2d');
  const font = getComputedStyle(document.documentElement).getPropertyValue(family === 'ui' ? '--font-ui' : '--font-num');
  measureCtx.font = `500 ${px}px ${font || 'sans-serif'}`;
  return measureCtx.measureText(text).width;
}

/** Drops x labels that would collide (greedy, 16 px minimum spacing). */
function greedyLabels(ticks, xOf, label, plot) {
  const out = [];
  let lastRight = -Infinity;
  for (const tick of ticks) {
    const x = xOf(tick);
    if (x < plot.x - 0.5 || x > plot.x + plot.w + 0.5) continue;
    const text = label(tick);
    const w = measureText(text, 10);
    const left = x - w / 2;
    if (left < lastRight + 16) continue;
    out.push({ tick, x, text });
    lastRight = x + w / 2;
  }
  return out;
}

/** ChartHoverBubble: above the point, else flipped to a side, kept in the plot. */
function HoverBubble({ anchor, plot, headline, caption }) {
  const ref = useRef(null);
  const [size, setSize] = useState(null);
  useLayoutEffect(() => {
    const r = ref.current?.getBoundingClientRect();
    if (r && (!size || size.w !== r.width || size.h !== r.height)) setSize({ w: r.width, h: r.height });
  });
  let style = { opacity: 0 };
  if (size) {
    const gap = CROSSHAIR.gap;
    const fitsAbove = anchor.y - gap - size.h >= plot.y;
    const toRight = anchor.x + gap + size.w / 2;
    const toLeft = anchor.x - gap - size.w / 2;
    const wantedX = fitsAbove ? anchor.x : toRight + size.w / 2 <= plot.x + plot.w ? toRight : toLeft;
    const cx = Math.min(Math.max(wantedX, plot.x + size.w / 2), plot.x + plot.w - size.w / 2);
    const cy = fitsAbove ? anchor.y - gap - size.h / 2 : Math.max(plot.y + size.h / 2, anchor.y);
    style = { left: `${cx - size.w / 2}px`, top: `${cy - size.h / 2}px` };
  }
  return html`<div class="energy__bubble" ref=${ref} style=${style}>
    <span class="num energy__bubble-headline">${headline}</span>
    <span class="t-micro c-tertiary">${caption}</span>
  </div>`;
}

function LivePowerChart({ history, ports, axisMaximum, expands, selected, onSelect }) {
  const [ref, size] = useSize();
  const ceiling = powerChartCeiling(axisMaximum);
  const axis = chartAxisValues(axisMaximum);
  const yLabels = axis.map((w) => `${w} W`);
  const plot = plotFrame(size, yLabels);
  const lo = history[0].t;
  const hi = Math.max(history[history.length - 1].t, lo + 1);
  const xOf = (ms) => plot.x + ((ms - lo) / (hi - lo)) * plot.w;
  const yOf = (w) => plot.y + plot.h - (Math.max(0, w) / ceiling) * plot.h;
  const totalPoints = history.map((s) => [xOf(s.t), yOf(s.total)]);
  const totalPath = monotonePath(totalPoints);
  const base = plot.y + plot.h;
  const area = totalPath
    ? `${totalPath}L${totalPoints[totalPoints.length - 1][0]},${base}L${totalPoints[0][0]},${base}Z`
    : '';
  const ticks = greedyLabels(timeTicks(lo, hi, 5), xOf, (ms) => fmtDate(ms, F.hms2), plot);
  const hovered = selected != null ? nearestSample(history, selected) : null;

  const move = (e) => {
    const r = e.currentTarget.getBoundingClientRect();
    const x = e.clientX - r.left;
    if (x < plot.x || x > plot.x + plot.w) return onSelect(null);
    const at = lo + ((x - plot.x) / plot.w) * (hi - lo);
    const sample = nearestSample(history, at);
    if (sample?.t !== selected) onSelect(sample ? sample.t : null);
  };

  return html`<div
    class=${cx('energy__chart', expands && 'expands')}
    ref=${ref}
    aria-label=${t('本次实时功率趋势')}
    onPointerMove=${move}
    onPointerLeave=${() => onSelect(null)}
  >
    ${size.width > 0
      ? html`<svg width=${size.width} height=${size.height} aria-hidden="true">
          <defs>
            <linearGradient id="energy-live-fill" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0" stop-color="var(--c-accent)" stop-opacity="0.26" />
              <stop offset="1" stop-color="var(--c-accent)" stop-opacity="0.01" />
            </linearGradient>
          </defs>
          <rect x=${plot.x} y=${plot.y} width=${plot.w} height=${plot.h} rx="6" class="energy__plot-bg" />
          ${ticks.map((tk) => html`<line x1=${tk.x} x2=${tk.x} y1=${plot.y} y2=${base} class="energy__grid-x" />`)}
          ${axis.map(
            (w) => html`<line x1=${plot.x} x2=${plot.x + plot.w} y1=${yOf(w)} y2=${yOf(w)} class="energy__grid-y-strong" />
              <text x=${plot.x - 6} y=${yOf(w)} class="energy__axis-label" text-anchor="end" dominant-baseline="middle">${w} W</text>`,
          )}
          <path d=${area} fill="url(#energy-live-fill)" />
          ${ports.map(({ slot: i }) => {
            if (!history.some((s) => s.perPort && i < s.perPort.length)) return null;
            const d = monotonePath(history.map((s) => [xOf(s.t), yOf(s.perPort?.[i] ?? 0)]));
            return html`<path
              d=${d}
              fill="none"
              stroke=${portColor(i)}
              stroke-opacity=${i === 0 ? 0.82 : 0.68}
              stroke-width="1"
              stroke-linecap="round"
              stroke-dasharray=${i === 0 ? undefined : `${3 + i} ${2 + i}`}
            />`;
          })}
          <path d=${totalPath} fill="none" stroke="var(--c-accent)" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" />
          ${ticks.map(
            (tk) => html`<text x=${tk.x} y=${base + 13} class="energy__axis-label" text-anchor="middle">${tk.text}</text>`,
          )}
          ${hovered
            ? html`<line
                  x1=${xOf(hovered.t)}
                  x2=${xOf(hovered.t)}
                  y1=${plot.y}
                  y2=${base}
                  class="energy__crosshair"
                />
                <circle cx=${xOf(hovered.t)} cy=${yOf(hovered.total)} r="3.5" fill="var(--c-accent)" />`
            : null}
        </svg>`
      : null}
    ${hovered && size.width > 0
      ? html`<${HoverBubble}
          anchor=${{ x: xOf(hovered.t), y: yOf(hovered.total) }}
          plot=${plot}
          headline=${tf('%.1f W', hovered.total)}
          caption=${fmtDate(hovered.t, F.hms)}
        />`
      : null}
  </div>`;
}

function chartDomain(range, digest) {
  const now = Date.now();
  const periods = digest.periods;
  const today = startOfDay(now);
  if (range === 'all' && periods.length) {
    return [monthStart(periods[0].startedAt) - 1000, addMonths(monthStart(periods[periods.length - 1].startedAt), 1)];
  }
  if (range === 'session') {
    const start = digest.activeSessionStartMs ?? now;
    return [start - 1000, Math.max(now + 1000, start + 60000)];
  }
  const start = digest.rangeStartMs ?? today;
  const end = range === 'day' ? Math.max(now + 60000, start + 3600000) : addDays(today, 1);
  return [start - 1000, end];
}

function bucketWidthMs(range, ms) {
  if (range === 'session' || range === 'day') return 3600000;
  if (range === 'all') return addMonths(monthStart(ms), 1) - monthStart(ms);
  return 86400000;
}

function EnergyChart({ range, metric, digest, prefs, expands, selected, onSelect }) {
  const [ref, size] = useSize();
  const periods = digest.periods;
  const values = periods.map((p) => metricValue(metric, p));
  const ceiling =
    metric === 'energy'
      ? quantizedCeiling(Math.max(0, ...values))
      : powerChartCeiling(
          effectiveChartMaximum(prefs[chartPreferenceKey(digest.product)] || 0, digest.product, Math.max(0, ...values)),
        );
  const yTicks = niceTicks(ceiling, 7).filter((v) => v <= ceiling + 1e-9);
  const yLabels = yTicks.map((v) => metricAxisLabel(metric, v));
  const plot = plotFrame(size, yLabels);
  const [lo, hi] = chartDomain(range, digest);
  const pad = 18;
  const xOf = (ms) => plot.x + pad + ((ms - lo) / (hi - lo)) * (plot.w - 2 * pad);
  const yOf = (v) => plot.y + plot.h - (Math.max(0, v) / ceiling) * plot.h;
  const base = plot.y + plot.h;
  const reference = chartReferenceValue(metric, periods);
  const record = selected != null ? nearestPeriod(periods, selected) : null;
  const tickValues = range === 'all' ? periods.map((p) => p.startedAt) : timeTicks(lo, hi, X_TICKS[range], AXIS_UNIT[range]);
  const ticks = greedyLabels(tickValues, xOf, (ms) => axisLabel(range, ms), plot);
  const points = periods.map((p) => [xOf(p.startedAt), yOf(metricValue(metric, p))]);
  const linePath = periods.length >= 3 ? catmullRomPath(points) : points.map((p, i) => `${i ? 'L' : 'M'}${p[0]},${p[1]}`).join('');

  const move = (e) => {
    const r = e.currentTarget.getBoundingClientRect();
    const x = e.clientX - r.left;
    if (x < plot.x || x > plot.x + plot.w) return onSelect(null);
    const at = lo + ((x - plot.x - pad) / (plot.w - 2 * pad)) * (hi - lo);
    onSelect(at);
  };

  const headline = record ? (metric === 'energy' ? shortEnergy(record.energyWh) : tf('%.1f W', metricValue(metric, record))) : '';

  return html`<div
    class=${cx('energy__chart', expands && 'expands')}
    ref=${ref}
    onPointerMove=${move}
    onPointerLeave=${() => onSelect(null)}
  >
    ${size.width > 0
      ? html`<svg width=${size.width} height=${size.height} aria-hidden="true">
          <defs>
            <linearGradient id="energy-bar-fill" x1="0" y1="1" x2="0" y2="0">
              <stop offset="0" stop-color="var(--c-accent-dim)" stop-opacity="0.76" />
              <stop offset="1" stop-color="var(--c-accent)" />
            </linearGradient>
            <linearGradient id="energy-area-fill" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0" stop-color="var(--c-accent)" stop-opacity="0.24" />
              <stop offset="1" stop-color="var(--c-accent)" stop-opacity="0.01" />
            </linearGradient>
            <clipPath id="energy-plot-clip"><rect x=${plot.x} y=${plot.y} width=${plot.w} height=${plot.h} rx="6" /></clipPath>
          </defs>
          <rect x=${plot.x} y=${plot.y} width=${plot.w} height=${plot.h} rx="6" class="energy__plot-bg" />
          ${ticks.map((tk) => html`<line x1=${tk.x} x2=${tk.x} y1=${plot.y} y2=${base} class="energy__grid-x" />`)}
          ${yTicks.map(
            (v, i) => html`<line x1=${plot.x} x2=${plot.x + plot.w} y1=${yOf(v)} y2=${yOf(v)} class="energy__grid-y" />
              <text x=${plot.x - 6} y=${yOf(v)} class="energy__axis-label" text-anchor="end" dominant-baseline="middle">${yLabels[i]}</text>`,
          )}
          <g clip-path="url(#energy-plot-clip)">
            ${metric === 'energy'
              ? periods.map((p) => {
                  const x0 = xOf(p.startedAt);
                  const bw = Math.max(2, Math.min(28, (xOf(p.startedAt + bucketWidthMs(range, p.startedAt)) - x0) * 0.62));
                  const y = yOf(p.energyWh);
                  const h = Math.max(0, base - y);
                  const dim = record && record.startedAt !== p.startedAt;
                  return html`<path
                    d=${roundedTopBar(x0 - bw / 2, y, bw, h, 4)}
                    fill="url(#energy-bar-fill)"
                    opacity=${dim ? 0.38 : 1}
                  />`;
                })
              : html`<path
                    d=${points.length ? `${linePath}L${points[points.length - 1][0]},${base}L${points[0][0]},${base}Z` : ''}
                    fill="url(#energy-area-fill)"
                  />
                  <path d=${linePath} fill="none" stroke="var(--c-accent)" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" />
                  ${periods.map((p, i) => {
                    const isSel = record && record.startedAt === p.startedAt;
                    return html`<circle
                      cx=${points[i][0]}
                      cy=${points[i][1]}
                      r=${isSel ? 3.5 : 2.4}
                      fill="var(--c-accent)"
                      opacity=${!record || isSel ? 1 : 0.46}
                    />`;
                  })}`}
            ${reference > 0
              ? html`<line x1=${plot.x} x2=${plot.x + plot.w} y1=${yOf(reference)} y2=${yOf(reference)} class="energy__reference-rule" />`
              : null}
            ${record
              ? html`<line x1=${xOf(record.startedAt)} x2=${xOf(record.startedAt)} y1=${plot.y} y2=${base} class="energy__crosshair" />
                  <circle cx=${xOf(record.startedAt)} cy=${yOf(metricValue(metric, record))} r="3.7" fill="var(--c-accent)" />`
              : null}
          </g>
          ${ticks.map(
            (tk) => html`<text x=${tk.x} y=${base + 13} class="energy__axis-label is-micro" text-anchor="middle">${tk.text}</text>`,
          )}
        </svg>`
      : null}
    ${record && size.width > 0
      ? html`<${HoverBubble}
          anchor=${{ x: xOf(record.startedAt), y: yOf(metricValue(metric, record)) }}
          plot=${plot}
          headline=${headline}
          caption=${periodLabel(range, record.startedAt)}
        />`
      : null}
  </div>`;
}

function roundedTopBar(x, y, w, h, r) {
  if (h <= 0) return '';
  const rr = Math.min(r, w / 2, h);
  return `M${x},${y + h}V${y + rr}Q${x},${y} ${x + rr},${y}H${x + w - rr}Q${x + w},${y} ${x + w},${y + rr}V${y + h}Z`;
}

// ---- Port mix and load profile -------------------------------------------------------------

function PortMixCard({ digest, inline }) {
  const summary = digest.summary;
  return html`<${SlateCard} padding=${S.l} class="energy__side-card">
    <div class="energy__side-body">
      <div class="energy__stack-xs">
        <span class="t-heading c-primary">${t('端口构成')}</span>
        <span class="t-micro c-tertiary">${t('累计能量占比')}</span>
      </div>
      ${summary.energyWh > 0
        ? inline
          ? html`<div class="energy__mix is-inline">
              <${Donut} digest=${digest} />
              <${MixLegend} slices=${digest.portSlices} columns=${1} />
            </div>`
          : html`<div class="energy__mix">
              <${Donut} digest=${digest} />
              <${MixLegend} slices=${digest.portSlices} columns=${digest.portSlices.length > 3 ? 2 : 1} />
            </div>`
        : html`<${CompactEmpty} text="暂无端口能量" />`}
    </div>
  <//>`;
}

function Donut({ digest }) {
  const slices = digest.renderedSlices;
  const total = energyText(digest.summary.energyWh);
  const size = 104;
  const outer = size / 2;
  const inner = outer * 0.66;
  const sum = slices.reduce((s, x) => s + x.energyWh, 0);
  const many = slices.length > 1;
  // angularInset 0.8 pt on each side of a sector.
  const insetAngle = many ? 0.8 / ((outer + inner) / 2) : 0;
  let angle = -Math.PI / 2;
  const sectors = slices.map((slice) => {
    const sweep = (slice.energyWh / sum) * Math.PI * 2;
    const a0 = angle + insetAngle;
    const a1 = angle + sweep - insetAngle;
    angle += sweep;
    return { slice, a0, a1 };
  });
  const arc = (a0, a1) => {
    if (a1 - a0 >= Math.PI * 2 - 1e-6) {
      return `M${outer},0A${outer},${outer} 0 1 1 ${outer - 0.01},0ZM${outer},${outer - inner}A${inner},${inner} 0 1 0 ${outer + 0.01},${outer - inner}Z`;
    }
    const large = a1 - a0 > Math.PI ? 1 : 0;
    const p = (r, a) => `${outer + r * Math.cos(a)},${outer + r * Math.sin(a)}`;
    return `M${p(outer, a0)}A${outer},${outer} 0 ${large} 1 ${p(outer, a1)}L${p(inner, a1)}A${inner},${inner} 0 ${large} 0 ${p(inner, a0)}Z`;
  };
  return html`<div class="energy__donut">
    <svg width=${size} height=${size} aria-hidden="true">
      ${sectors.map(
        ({ slice, a0, a1 }) => html`<path
          d=${arc(a0, a1)}
          fill=${portColor(slice.index)}
          fill-rule="evenodd"
        ><title>${slice.port} ${slice.percentage}%</title></path>`,
      )}
    </svg>
    <div class="energy__donut-center">
      <span class="t-micro c-tertiary">${t('总计')}</span>
      <span class="energy__donut-total"><span class="num">${total.value}</span><span>${total.unit}</span></span>
    </div>
  </div>`;
}

function MixLegend({ slices, columns }) {
  return html`<div class="energy__mix-legend" style=${{ gridTemplateColumns: `repeat(${columns}, minmax(0, 1fr))` }}>
    ${slices.map(
      (s) => html`<div class="energy__mix-row">
        <span class="energy__swatch" style=${{ background: portColor(s.index) }}></span>
        <span class="t-micro c-secondary">${s.port}</span>
        <span class="num energy__mix-energy">${shortEnergy(s.energyWh)}</span>
        <span class="num energy__mix-pct">${s.percentage}%</span>
      </div>`,
    )}
  </div>`;
}

function LoadProfileCard({ digest }) {
  const bands = digest.loadBands;
  return html`<${SlateCard} padding=${S.l} class="energy__side-card">
    <div class="energy__side-body">
      <div class="energy__stack-xs">
        <span class="t-heading c-primary">${t('负载分布')}</span>
        <span class="t-micro c-tertiary">${t('各功率档位的累计时长')}</span>
      </div>
      ${bands.some((b) => b.seconds > 0)
        ? html`<div class="energy__bands">
            ${bands.map(
              (b) => html`<div class="energy__band" aria-label=${tf('%@，观测 %@', b.label, compactDuration(b.seconds))}>
                <span class="num energy__band-label">${b.label}</span>
                <span class="energy__band-track">
                  ${b.seconds > 0
                    ? html`<span
                        class="energy__band-fill"
                        style=${{
                          width: `max(3px, ${Math.min(100, (b.seconds / digest.loadCeiling) * 100)}%)`,
                          opacity: b.opacity,
                        }}
                      ></span>`
                    : null}
                </span>
                <span class=${cx('num energy__band-value', b.seconds > 0 && 'has-value')}>${compactDuration(b.seconds)}</span>
              </div>`,
            )}
          </div>`
        : html`<${CompactEmpty} text="尚无负载样本" />`}
    </div>
  <//>`;
}

function CompactEmpty({ text }) {
  return html`<div class="energy__compact-empty t-caption c-tertiary">
    <${Icon} name="chart.xyaxis.line" /><span>${t(text)}</span>
  </div>`;
}

// ---- Session ledger ------------------------------------------------------------------------

function SessionLedger({ state, digest, layout, limit, onMore }) {
  const sessions = digest.sessions;
  const live = isLive(state.session);
  const groups = [];
  for (const record of sessions.slice(0, limit)) {
    const day = startOfDay(record.startedAt);
    let g = groups.find((x) => x.day === day);
    if (!g) groups.push((g = { day, records: [] }));
    g.records.push(record);
  }
  groups.sort((a, b) => b.day - a.day);
  groups.forEach((g) => g.records.sort((a, b) => b.startedAt - a.startedAt));

  return html`<${SlateCard} padding=${0} class="energy__ledger" aria-label=${tf('连接旅程，%d 段', sessions.length)}>
    <div class="energy__ledger-head">
      <span class="t-heading c-primary">${t('连接旅程')}</span>
      <${Chip} text=${tf('%d 段', sessions.length)} />
    </div>
    <div class="energy__hairline"></div>
    <div class="energy__ledger-body">
      ${groups.map(
        (g) => html`<div class="energy__day" key=${g.day}>
          <div class="energy__day-head">
            <span class="t-micro c-tertiary">${dayLabel(g.day, digest.nowMs)}</span>
            <span class="num energy__day-count">${tf('%d 段', g.records.length)}</span>
          </div>
          <div class="energy__rows">
            ${g.records.map(
              (record, i) => html`<${SessionRow}
                  key=${record.id}
                  record=${record}
                  active=${live && digest.activeSessionId === record.id}
                  oneLine=${layout.rowOneLine}
                  ports=${digest.ports}
                />${i < g.records.length - 1 ? html`<div class="energy__row-divider"></div>` : null}`,
            )}
          </div>
        </div>`,
      )}
      ${sessions.length > limit
        ? html`<div class="energy__more">
            <span class="t-micro c-tertiary">${tf('已显示最近 %d / %d 段', Math.min(limit, sessions.length), sessions.length)}</span>
            <${ActionButton} icon="chevron.down" title=${t('显示更多')} onClick=${onMore} />
          </div>`
        : null}
    </div>
  <//>`;
}

function SessionRow({ record, active, oneLine, ports }) {
  const energy =
    record.energyWh >= 1000
      ? tf('%.2f kWh', record.energyWh / 1000)
      : tf(record.energyWh < 10 ? '%.2f Wh' : '%.1f Wh', record.energyWh);
  const avgPeak = tf('%.1f / %.1f W', record.averageWatts, record.peakWatts);
  const timeRange = tf('%@ – %@', fmtDate(record.startedAt, F.hm), active ? t('更新中') : fmtDate(record.endedAt, F.hm));
  const metric = (label, value, w) => html`<span class="energy__row-metric" style=${w ? { width: `${w}px` } : undefined}>
    <span class="t-micro c-tertiary">${t(label)}</span>
    <span class="num energy__row-value">${value}</span>
  </span>`;
  const identity = html`<div class="energy__identity">
    <span class=${cx('energy__identity-icon', active && 'is-active')}>
      <${Icon} name=${active ? 'bolt.fill' : 'clock'} size=${11} />
    </span>
    <div class="energy__stack-xs energy__identity-text">
      <span class="energy__identity-line">
        <span class="num energy__time">${timeRange}</span>
        ${active ? html`<${Chip} text=${t('进行中')} tone="accent" />` : null}
      </span>
      <${PortEnergyRail} values=${record.perPortWh} ports=${ports} height=${5} maxWidth=${170} />
    </div>
  </div>`;
  return oneLine
    ? html`<div class="energy__row is-one-line">
        ${identity} ${metric('能量', energy, 92)} ${metric('监测', rowDurationText(record.activeSeconds), 90)}
        ${metric('平均 / 峰值', avgPeak, 126)}
      </div>`
    : html`<div class="energy__row">
        ${identity}
        <div class="energy__row-metrics">
          ${metric('能量', energy)} ${metric('监测', rowDurationText(record.activeSeconds))} ${metric('平均 / 峰值', avgPeak)}
        </div>
      </div>`;
}
