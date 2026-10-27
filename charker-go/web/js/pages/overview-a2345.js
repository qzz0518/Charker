// 总览 for the Anker Prime 250W: A2345DashboardView.swift with
// A2345ModelStage.swift around the three.js stage (stage-a2345.js),
// A2345PortControls.swift (switch, countdown menu, schedule editor) and
// A2345CustomModeSheet.swift, exported for the connection page that presents
// it.

import { html, useEffect, useLayoutEffect, useMemo, useRef, useState } from '../lib.js';
import { t, tf, tt, currentLocale } from '../core/l10n.js';
import { activeProduct, chartAxisValues, chartCeiling } from '../core/model.js';
import { call, selectSection, setActionMessage, setPrefs } from '../core/store.js';
import { ActionButton, Chip, Icon, SlateCard, Toggle, Segmented, confirmDialog, cx, openMenu } from '../ui/components.js';
import { registerIcons } from '../ui/icons.js';
import { mountA2345Stage } from './stage-a2345.js';

// Page glyphs: cable.connector (an upright USB-C plug), powerplug lying on
// its side as the Mac draws it in the port rows, timer.circle.fill and the
// single double-headed arrow.left.and.right.
registerIcons({
  'cable-connector':
    '<svg class="ck-icon" width="1em" height="1em" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true" focusable="false">' +
    '<rect x="5.4" y="0.8" width="5.2" height="8.6" rx="1.7"/><rect x="7.2" y="9" width="1.6" height="6.4" rx="0.8"/></svg>',
  'powerplug-side':
    '<svg class="ck-icon" width="1em" height="1em" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">' +
    '<path d="M2 9h5M2 15h5"/><path d="M7 6h5a6 6 0 0 1 0 12H7z"/><path d="M18 12h4"/></svg>',
  'left-right':
    '<svg class="ck-icon" width="1em" height="1em" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">' +
    '<path d="M3 12h18"/><path d="m7 8-4 4 4 4"/><path d="m17 8 4 4-4 4"/></svg>',
  'timer-circle-fill':
    '<svg class="ck-icon" width="1em" height="1em" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true" focusable="false">' +
    '<path fill-rule="evenodd" d="M8 1a7 7 0 1 1 0 14A7 7 0 0 1 8 1Zm0 2.6a.8.8 0 0 0-.8.8V8c0 .21.08.42.23.57l2.1 2.1a.8.8 0 0 0 1.14-1.14L8.8 7.67V4.4A.8.8 0 0 0 8 3.6Z"/></svg>',
});

const PLACEHOLDER = '—';
const TIMER_PRESETS = [3600, 7200, 10800];
const CHART_OPTIONS = [50, 100, 150, 200, 250];
const MAXIMUM_INTEGRABLE_GAP = 120;

// ---- Helpers ---------------------------------------------------------------------

const pad2 = (n) => String(n).padStart(2, '0');

function useTick(ms, active = true) {
  const [, set] = useState(0);
  useEffect(() => {
    if (!active) return undefined;
    const id = setInterval(() => set((n) => n + 1), ms);
    return () => clearInterval(id);
  }, [ms, active]);
}

/** value.formatted(.number.precision(.fractionLength(decimals))) */
function formatted(value, decimals) {
  return Number(value || 0).toLocaleString(currentLocale() === 'en' ? 'en' : 'zh-CN', {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  });
}

/** PortCard.durationText */
function durationText(seconds) {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  if (hours > 0 && minutes > 0) return tf('%d 小时 %d 分钟', hours, minutes);
  if (hours > 0) return tf('%d 小时', hours);
  return tf('%d 分钟', minutes);
}

const isOn = (p) => !!p && p.statusCode !== 0;
const isDelivering = (p) => isOn(p) && p.current > 0.02 && p.voltage > 3;
const hasReadings = (p) => isOn(p) && (p.voltage > 0 || p.current > 0 || p.power > 0);

/** The control group of a port: C1…C4, or the shared A1/A2. */
const groupOf = (port) => (port === 'A1' || port === 'A2' ? 'A1/A2' : port);

function groupControl(snap, group) {
  return snap?.a2345?.settings?.groups?.find((g) => g.group === group) || null;
}

function stateTone(snap) {
  if (!snap) return 'idle';
  if (snap.isDemo) return 'accent';
  const stale = snap.isStale;
  switch (snap.stage) {
    case 'failed':
      return 'danger';
    case 'reconnecting':
      return 'warn';
    case 'monitoring':
      return stale ? 'warn' : 'ok';
    case 'waitingForTelemetry':
    case 'signingIn':
    case 'loadingDevices':
    case 'connecting':
      return stale ? 'warn' : 'accent';
    default:
      return stale ? 'warn' : 'idle';
  }
}

const isBusyStage = (stage) => ['signingIn', 'loadingDevices', 'connecting', 'reconnecting'].includes(stage);

/** A2345ConnectionPhase.shortLabel */
function stageShortLabel(stage) {
  return t(
    {
      signingIn: '登录中',
      loadingDevices: '查找设备',
      connecting: '连接云端',
      waitingForTelemetry: '等待数据',
      monitoring: '已连接',
      reconnecting: '重连中',
      failed: '出错',
    }[stage] || '未连接',
  );
}

// Short forms: the row is 310 pt wide and also carries the readings.
function cableLabel(code) {
  return t(['3A 线', '5A 线', 'EPR 线', '华为线', '小米线'][code] || '');
}

function fastChargeChipLabel(code) {
  return code === 1 ? 'SCP' : t('澎湃秒充');
}

function fastChargeLabel(code) {
  return t(code === 1 ? '华为 SCP' : '小米澎湃秒充');
}

function brandLabel(code) {
  return t(code === 1 ? '华为/荣耀' : '小米');
}

function describe(err) {
  const text = String(err?.message || err || '');
  return t(text) || t('操作没有完成。');
}

/** A2345 writes waiting for their acknowledgement. */
function isWritePending(snap, messageType, group) {
  return (snap?.a2345?.pendingWrites || []).some(
    (w) => w.messageType === messageType && (group == null || w.group === group),
  );
}

// ---- Port actions (AppModel.setA2345PortOutput / Countdown / Schedule) ----------

async function send(method, ...args) {
  try {
    await call(method, ...args);
  } catch (err) {
    setActionMessage(describe(err));
  }
}

function timerConsequence(label) {
  return tf('到点后 %@ 会断电，那时正在从它取电的设备会断开。', label);
}

// ---- Anchored popover (.popover(arrowEdge: .bottom)) -----------------------------

function AnchoredPopover({ anchor, width, onClose, children, label }) {
  const box = useRef(null);
  const [pos, setPos] = useState(null);
  useLayoutEffect(() => {
    const r = anchor.getBoundingClientRect();
    const h = box.current.offsetHeight;
    let top = r.bottom + 8;
    if (top + h > window.innerHeight - 8) top = Math.max(8, r.top - h - 8);
    const left = Math.min(Math.max(8, r.left + r.width / 2 - width / 2), window.innerWidth - width - 8);
    setPos({ left, top });
  }, [anchor, width]);
  useEffect(() => {
    const key = (e) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        onClose();
      }
    };
    document.addEventListener('keydown', key, true);
    return () => document.removeEventListener('keydown', key, true);
  }, [onClose]);
  return html`<div class="a2345-popover-backdrop" onPointerDown=${(e) => e.target === e.currentTarget && onClose()}>
    <div
      ref=${box}
      class="popover a2345-popover"
      role="dialog"
      aria-label=${label}
      style=${{ width: `${width}px`, left: `${pos?.left ?? 0}px`, top: `${pos?.top ?? 0}px`, opacity: pos ? 1 : 0 }}
    >
      ${children}
    </div>
  </div>`;
}

// ---- A2345PortControls ---------------------------------------------------------------

function PortControls({ snap, group }) {
  const control = groupControl(snap, group);
  const on = !!control?.isOn;
  const blocker = snap.a2345?.portControlBlocker || null;
  const disabled = blocker != null || control == null;
  const switchPending = isWritePending(snap, 0x0207, group);
  const hasTimer = !!control && (control.countdown.enabled || control.powerOn.enabled || control.powerOff.enabled);

  const [pendingTarget, setPendingTarget] = useState(null);
  const [customAnchor, setCustomAnchor] = useState(null);
  const [scheduleAnchor, setScheduleAnchor] = useState(null);
  const timerButton = useRef(null);

  const flip = async () => {
    const target = !on;
    setPendingTarget(target);
    const ok = await confirmDialog({
      title: target ? tf('打开 %@？', group) : tf('关闭 %@？', group),
      message: target ? tf('%@ 将恢复供电。', group) : tf('正在从 %@ 取电的设备会立即断电。', group),
      actions: [
        { title: t('取消'), role: 'cancel' },
        { title: t(target ? '打开端口' : '关闭端口'), role: target ? undefined : 'destructive', default: true },
      ],
    });
    setPendingTarget(null);
    if (ok) send('SetA2345PortOutput', group, target);
  };

  const askToArm = async (seconds) => {
    const ok = await confirmDialog({
      title: tf('让 %@ 在 %@ 后断电？', group, durationText(seconds)),
      message: timerConsequence(group),
      actions: [
        { title: t('取消'), role: 'cancel' },
        { title: t('设定倒计时'), default: true },
      ],
    });
    if (ok) send('SetA2345PortCountdown', group, seconds);
  };

  const menu = (e) => {
    const anchor = e.currentTarget;
    const items = [
      ...TIMER_PRESETS.map((s) => ({ title: durationText(s), disabled: !on, action: () => askToArm(s) })),
      { title: t('自定义…'), disabled: !on, action: () => setCustomAnchor(anchor) },
    ];
    if (control?.countdown.enabled) {
      items.push({ title: t('关闭倒计时'), action: () => send('SetA2345PortCountdown', group, 0) });
    }
    items.push({ separator: true }, { title: t('定时开关…'), action: () => setScheduleAnchor(anchor) });
    openMenu(anchor, items, { align: 'end' });
  };

  return html`<span class="a2345-controls" title=${blocker ? tt(blocker) : tf('%@ 端口开关', group)}>
    <button
      ref=${timerButton}
      class=${cx('a2345-timer', hasTimer && 'is-set')}
      disabled=${disabled}
      title=${blocker ? tt(blocker) : tf('让 %@ 在一段时间后自动断电', group)}
      aria-label=${tf('%@ 自动断电倒计时', group)}
      onClick=${menu}
    >
      <${Icon} name=${hasTimer ? 'timer-circle-fill' : 'timer'} />
    </button>
    <button
      class=${cx('toggle a2345-switch', (pendingTarget ?? on) && 'is-on')}
      role="switch"
      aria-checked=${pendingTarget ?? on}
      aria-label=${tf('%@ 输出', group)}
      disabled=${disabled}
      style=${{ opacity: disabled ? undefined : switchPending ? 0.6 : 1 }}
      onClick=${flip}
    ></button>
    ${customAnchor
      ? html`<${CustomTimerPopover}
          anchor=${customAnchor}
          group=${group}
          onClose=${() => setCustomAnchor(null)}
        />`
      : null}
    ${scheduleAnchor
      ? html`<${AnchoredPopover}
          anchor=${scheduleAnchor}
          width=${292}
          label=${tf('%@ 定时开关', group)}
          onClose=${() => setScheduleAnchor(null)}
        >
          <${ScheduleEditor} snap=${snap} group=${group} close=${() => setScheduleAnchor(null)} />
        </${AnchoredPopover}>`
      : null}
  </span>`;
}

function CustomTimerPopover({ anchor, group, onClose }) {
  const [text, setText] = useState('');
  const input = useRef(null);
  useEffect(() => input.current?.focus(), []);
  // The official picker offers 5-minute steps up to 23 h 55 min.
  const value = /^\s*\d+\s*$/.test(text) ? Number(text) : null;
  const minutes = value != null && value >= 5 && value <= 1435 && value % 5 === 0 ? value : null;
  const commit = () => {
    if (!minutes) return;
    onClose();
    send('SetA2345PortCountdown', group, minutes * 60);
  };
  return html`<${AnchoredPopover} anchor=${anchor} width=${268} label=${t('自定义倒计时')} onClose=${onClose}>
    <div class="t-label c-primary">${t('自定义倒计时')}</div>
    <div class="popover__row">
      <input
        ref=${input}
        class="field"
        style=${{ width: '68px' }}
        placeholder="90"
        aria-label=${t('倒计时分钟数')}
        value=${text}
        onInput=${(e) => setText(e.currentTarget.value)}
        onKeyDown=${(e) => e.key === 'Enter' && commit()}
      />
      <span class="t-body c-secondary">${t('分钟')}</span>
    </div>
    <div class="t-micro c-tertiary">${t('5 到 1435 分钟，5 的倍数。')}</div>
    <div class="t-caption c-secondary para">${timerConsequence(group)}</div>
    <div class="popover__actions">
      <button class="btn" onClick=${onClose}>${t('取消')}</button>
      <button class="btn is-primary" disabled=${!minutes} onClick=${commit}>${t('设定倒计时')}</button>
    </div>
  </${AnchoredPopover}>`;
}

// ---- A2345ScheduleText / A2345WeekdayPicker / A2345ScheduleEditor ----------------

const WEEKDAY_SYMBOLS = ['一', '二', '三', '四', '五', '六', '日'];
const WEEKDAY_NAMES = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

function scheduleTime(s) {
  return `${pad2(s.hour)}:${pad2(s.minute)}`;
}

function scheduleDays(mask) {
  switch (mask & 0x7f) {
    case 0:
      return t('仅一次');
    case 0x7f:
      return t('每天');
    case 0x1f:
      return t('工作日');
    case 0x60:
      return t('周末');
    default:
      return WEEKDAY_NAMES.filter((_, i) => mask & (1 << i))
        .map((n) => t(n))
        .join(' ');
  }
}

function WeekdayPicker({ mask, onChange, disabled }) {
  return html`<span class="weekdays">
    ${WEEKDAY_SYMBOLS.map((symbol, i) => {
      const bit = 1 << i;
      const on = (mask & bit) !== 0;
      return html`<button
        class=${cx('weekdays__day', on && 'is-on')}
        aria-label=${t(WEEKDAY_NAMES[i])}
        aria-pressed=${on}
        disabled=${disabled}
        onClick=${() => onChange(mask ^ bit)}
      >
        ${t(symbol)}
      </button>`;
    })}
  </span>`;
}

/** Slot(schedule): hour and minute clamped, an unset slot every day. */
function slotFrom(s) {
  return {
    enabled: !!s?.enabled,
    hour: Math.min(s?.hour ?? 8, 23),
    minute: Math.min(s?.minute ?? 0, 59),
    days: !s || s.unset ? 0x7f : s.weekdays & 0x7f,
  };
}

const sameSlot = (a, b) => a.enabled === b.enabled && a.hour === b.hour && a.minute === b.minute && a.days === b.days;

function ScheduleEditor({ snap, group, close }) {
  const control = groupControl(snap, group);
  const [base] = useState(() => (control ? { on: slotFrom(control.powerOn), off: slotFrom(control.powerOff) } : null));
  const [powerOn, setPowerOn] = useState(() => base?.on || slotFrom(null));
  const [powerOff, setPowerOff] = useState(() => base?.off || slotFrom(null));
  const loaded = base != null;
  const changed = loaded && (!sameSlot(powerOn, base.on) || !sameSlot(powerOff, base.off));
  // The official app refuses an on and an off time at the same minute on a
  // shared day.
  const conflicts =
    powerOn.enabled &&
    powerOff.enabled &&
    powerOn.hour === powerOff.hour &&
    powerOn.minute === powerOff.minute &&
    (powerOn.days === 0 || powerOff.days === 0 || (powerOn.days & powerOff.days) !== 0);
  const blocked = snap.a2345?.portControlBlocker != null;

  const save = () => {
    if (!loaded) return;
    const wire = (s) => ({ enabled: s.enabled, hour: s.hour, minute: s.minute, weekdays: s.days });
    if (!sameSlot(powerOn, base.on)) send('SetA2345PortSchedule', group, 'powerOn', wire(powerOn));
    if (!sameSlot(powerOff, base.off)) send('SetA2345PortSchedule', group, 'powerOff', wire(powerOff));
    close();
  };

  const slotEditor = (title, slot, set) => html`<div class="schedule-slot">
    <div class="schedule-slot__head">
      <span class="t-body c-primary">${title}</span>
      <${Toggle} small on=${slot.enabled} label=${title} onChange=${(v) => set({ ...slot, enabled: v })} />
    </div>
    <div class="schedule-slot__row" style=${{ opacity: slot.enabled ? 1 : 0.5 }}>
      <input
        type="time"
        class="field schedule-slot__time num"
        aria-label=${title}
        disabled=${!slot.enabled}
        value=${`${pad2(slot.hour)}:${pad2(slot.minute)}`}
        onInput=${(e) => {
          const [h, m] = e.currentTarget.value.split(':').map(Number);
          if (Number.isInteger(h) && Number.isInteger(m)) set({ ...slot, hour: h, minute: m });
        }}
      />
      <span style=${{ flex: 1 }}></span>
      <${WeekdayPicker} mask=${slot.days} disabled=${!slot.enabled} onChange=${(days) => set({ ...slot, days })} />
    </div>
    <span class="t-micro c-tertiary">${scheduleDays(slot.days)}</span>
  </div>`;

  return html`<div class="schedule-editor">
    <div class="t-label c-primary">${tf('%@ 定时开关', group)}</div>
    ${slotEditor(t('定时开启'), powerOn, setPowerOn)}
    <div class="schedule-editor__rule"></div>
    ${slotEditor(t('定时关闭'), powerOff, setPowerOff)}
    ${conflicts ? html`<div class="t-caption c-warn">${t('开和关不能设在同一时间。')}</div>` : null}
    <div class="popover__actions">
      <button class="btn" onClick=${close}>${t('取消')}</button>
      <button class="btn is-primary" disabled=${conflicts || !changed || blocked} onClick=${save}>${t('保存')}</button>
    </div>
  </div>`;
}

/** A2345PortTimerLine: the countdown and daily times as one short line. */
function PortTimerLine({ snap, group, publishedAt }) {
  const control = groupControl(snap, group);
  const visible = !!control && (control.countdown.enabled || control.powerOn.enabled || control.powerOff.enabled);
  useTick(1000, visible && control.countdown.enabled);
  if (!visible) return null;
  const parts = [];
  if (control.countdown.enabled) {
    const elapsed = publishedAt ? Math.max(0, (Date.now() - publishedAt) / 1000) : 0;
    const seconds = Math.max(0, Math.ceil((control.countdown.remaining ?? 0) - elapsed));
    parts.push(`${pad2(Math.floor(seconds / 3600))}:${pad2(Math.floor((seconds % 3600) / 60))}:${pad2(seconds % 60)}`);
  }
  if (control.powerOn.enabled) parts.push(tf('%@ 开', scheduleTime(control.powerOn)));
  if (control.powerOff.enabled) parts.push(tf('%@ 关', scheduleTime(control.powerOff)));
  return html`<span class="a2345-timer-line">
    <${Icon} name="timer" />
    <span class="t-micro num">${parts.join(' · ')}</span>
  </span>`;
}

// ---- Port row ----------------------------------------------------------------------------

function PortRow({ state, snap, port, index, selected, onSelect }) {
  const value = snap.telemetry?.ports?.find((p) => p.port === port) || null;
  const stale = snap.isStale;
  const freshDelivery = isDelivering(value) && !stale;
  const group = groupOf(port);
  const settings = snap.a2345?.settings || null;
  const control = groupControl(snap, group);
  const faulted = !!control?.hasFault;
  const nickname = state.prefs.portNicknames?.[index] || '';
  const name = nickname || (value?.deviceBrand != null ? brandLabel(value.deviceBrand) : null);
  const reads = hasReadings(value);

  let detail;
  if (settings && control?.hasFault) detail = t('端口异常');
  else if (settings && control && !control.isOn) detail = t('已关闭');
  else if (!isOn(value)) detail = t('未输出');
  else if (reads) {
    const electrical = tf('%.2f V · %.2f A', value.voltage, value.current);
    detail = value.cable != null ? tf('%@ · %@', electrical, cableLabel(value.cable)) : electrical;
  } else detail = t('已开启 · 等待负载');

  const a11y = [];
  if (reads) a11y.push(tf('%.1f 瓦', value.power));
  a11y.push(detail);
  if (value?.fastCharge != null) a11y.push(fastChargeLabel(value.fastCharge));
  if (stale) a11y.push(t('数据已陈旧'));

  const glyph = faulted ? 'exclamationmark.triangle.fill' : port.startsWith('C') ? 'cable-connector' : 'powerplug-side';
  const powerTint = stale ? 'c-tertiary' : isDelivering(value) ? 'c-primary' : 'c-secondary';

  return html`<div
    class=${cx('a2345-port', selected && 'is-selected', selected && stale && 'is-stale')}
    role="button"
    tabindex="0"
    aria-pressed=${selected}
    aria-label=${tf('%@ 端口', port)}
    aria-description=${[...a11y, selected ? t('按下以取消此端口曲线筛选') : t('按下以筛选此端口曲线')].join(t('，'))}
    onClick=${(e) => {
      // Not a button: the switch and countdown menu inside stay clickable.
      if (e.target.closest('button, input, .a2345-popover-backdrop')) return;
      onSelect();
    }}
    onKeyDown=${(e) => {
      if ((e.key === 'Enter' || e.key === ' ') && e.target === e.currentTarget) {
        e.preventDefault();
        onSelect();
      }
    }}
  >
    <div class="a2345-port__text">
      <div class="a2345-port__title">
        <${Icon}
          name=${glyph}
          class=${cx('a2345-port__glyph', faulted ? 'c-danger' : freshDelivery ? 'c-accent' : 'c-tertiary')}
        />
        <span class=${cx('num a2345-port__label', freshDelivery ? 'c-accent' : 'c-primary')}>${port}</span>
        ${name ? html`<span class="t-micro c-tertiary a2345-port__name">${name}</span>` : null}
        ${value?.fastCharge != null
          ? html`<span class="a2345-port__chip"
              ><${Chip} text=${fastChargeChipLabel(value.fastCharge)} tone=${freshDelivery ? 'accent' : 'neutral'}
            /></span>`
          : null}
      </div>
      <span class=${cx('t-micro num a2345-port__detail', faulted ? 'c-danger' : 'c-tertiary')}>${detail}</span>
      <${PortTimerLine} snap=${snap} group=${group} publishedAt=${state.lastUpdatedMs} />
    </div>
    <span class="a2345-port__spacer"></span>
    <span class="a2345-port__power">
      <span class=${cx('num', powerTint)}>${reads ? formatted(value.power, 1) : PLACEHOLDER}</span>
      <span class="t-micro c-tertiary">W</span>
    </span>
    ${settings ? html`<${PortControls} snap=${snap} group=${group} />` : null}
  </div>`;
}

// ---- A2345ModelStage ------------------------------------------------------------------------

function ModelStage({ state, snap, height }) {
  const el = useRef(null);
  const controller = useRef(null);
  const [loadState, setLoadState] = useState('loading');
  const [pageScrolls, setPageScrolls] = useState(false);
  const scrolls = useRef(false);
  scrolls.current = pageScrolls;
  useEffect(() => {
    controller.current = mountA2345Stage({
      el: el.current,
      onLoad: setLoadState,
      pageScrolls: () => scrolls.current,
    });
    // The window is shorter than the overview: the wheel scrolls the page.
    const page = el.current.closest('.page');
    const check = () => setPageScrolls(page ? page.scrollHeight > page.clientHeight + 0.5 : false);
    const ro = new ResizeObserver(check);
    if (page) {
      ro.observe(page);
      if (page.firstElementChild) ro.observe(page.firstElementChild);
    }
    check();
    return () => {
      ro.disconnect();
      controller.current.dispose();
    };
  }, []);

  const active = !!snap?.live;
  const homePose = state.prefs.a2345ModelHomeCamera || null;
  useEffect(() => {
    controller.current?.update({
      active,
      homePose,
      reduceMotion: window.matchMedia('(prefers-reduced-motion: reduce)').matches,
    });
  });

  const ports = activeProduct(state).ports;
  const telemetry = snap?.telemetry;
  const live = (port) => active && isDelivering(telemetry?.ports?.find((p) => p.port === port));
  const ready = loadState === 'ready';

  let summary;
  if (loadState === 'loading') summary = t('载入三维模型');
  else if (loadState === 'failed') summary = t('三维视图暂不可用');
  else if (snap?.isStale) summary = t('数据已陈旧');
  else if (!active) summary = t('未连接');
  else {
    const lit = ports.filter(live);
    summary = lit.length ? tf('%@ 正在输出', lit.join(t('、'))) : t('没有端口在输出');
  }

  const cameraMenu = (e) =>
    openMenu(
      e.currentTarget,
      [
        { title: t('将当前视角设为归位'), action: () => setPrefs({ a2345ModelHomeCamera: controller.current.capture() }) },
        {
          title: t('恢复初始归位视角'),
          disabled: homePose == null,
          action: () => {
            setPrefs({ a2345ModelHomeCamera: null });
            setTimeout(() => controller.current.reset(), 0);
          },
        },
      ],
      { align: 'end' },
    );

  return html`<div
    class=${cx('stage a2345-stage', ready && 'is-ready')}
    style=${{ height: `${height}px` }}
    ref=${el}
    tabindex=${ready ? 0 : -1}
    role="application"
    aria-label=${t('Anker Prime 250W 三维模型')}
    aria-description=${`${summary}${t('，')}${t('方向键旋转，加减号缩放，0 归位')}`}
  >
    ${loadState === 'failed'
      ? html`<div class="stage__fallback stage__overlay">
          <${FallbackFigure} active=${active} telemetry=${telemetry} ports=${ports} height=${height} />
          <span class="t-caption c-tertiary">${t('三维视图暂不可用')}</span>
          <${ActionButton} title=${t('重新载入')} onClick=${() => controller.current.reload()} />
        </div>`
      : null}
    <div class="a2345-stage__hint stage__overlay t-micro c-tertiary">
      ${loadState === 'loading' ? html`<span class="spinner spinner--mini"></span>` : null}
      <${Icon} name="move.3d" />
      <span
        >${t(
          loadState === 'loading' ? '载入三维模型' : pageScrolls ? '拖动旋转 · Ctrl 滚轮缩放' : '拖动旋转 · 滚轮缩放',
        )}</span
      >
    </div>
    ${ready
      ? html`<div class="stage__corner stage__corner--top stage__overlay">
          <${ActionButton}
            icon=${homePose == null ? 'viewfinder' : 'bookmark.fill'}
            title=${t('设定')}
            class="btn--micro"
            help=${t('设置归位视角与缩放')}
            aria-label=${t(homePose == null ? '设定归位视角' : '自定义归位视角已启用')}
            onClick=${cameraMenu}
          />
        </div>`
      : null}
    <div class="a2345-stage__bottom stage__overlay">
      <div class="a2345-stage__legend" aria-hidden="true">
        ${ports.map(
          (port) => html`<span class=${cx('a2345-stage__legend-item', live(port) && 'is-live')}>
            <span class="a2345-stage__legend-dot"></span>
            <span class="num">${port}</span>
          </span>`,
        )}
      </div>
      <span style=${{ flex: 1, minWidth: '4px' }}></span>
      ${ready
        ? html`<div class="a2345-stage__resets">
            <${ActionButton}
              icon="left-right"
              class="btn--micro a2345-stage__level"
              help=${t('将机身恢复到桌面水平姿态，保留当前缩放')}
              aria-label=${t('水平归位')}
              onClick=${() => controller.current.level()}
            />
            <${ActionButton}
              icon="view-3d"
              title=${t('归位')}
              class="btn--micro"
              help=${t('恢复保存的归位视角与缩放')}
              onClick=${() => controller.current.reset()}
            />
          </div>`
        : null}
    </div>
  </div>`;
}

/** A2345FallbackFigure: schematic, truthful labels and live dots. */
function FallbackFigure({ active, telemetry, ports, height }) {
  return html`<div class="a2345-fallback" style=${{ width: `${height * 0.43}px`, height: `${height * 0.52}px` }}>
    <span class="num a2345-fallback__rating">250</span>
    <span class="t-micro a2345-fallback__unit">W</span>
    <div class="a2345-fallback__ports">
      ${ports.map((port) => {
        const live = active && isDelivering(telemetry?.ports?.find((p) => p.port === port));
        return html`<div class="a2345-fallback__port">
          <span class=${cx('a2345-fallback__socket', port.startsWith('C') && 'is-c')}></span>
          <span class="num">${port}</span>
          <span class=${cx('a2345-fallback__dot', live && 'is-live')}></span>
        </div>`;
      })}
    </div>
  </div>`;
}

// ---- Power chart --------------------------------------------------------------------

/** Monotone cubic interpolation (Swift Charts .monotone) as an SVG path. */
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
  const tangents = [m[0]];
  for (let i = 1; i < n - 1; i++) {
    if (m[i - 1] * m[i] <= 0) tangents.push(0);
    else {
      const w1 = 2 * dx[i] + dx[i - 1];
      const w2 = dx[i] + 2 * dx[i - 1];
      tangents.push((w1 + w2) / (w1 / m[i - 1] + w2 / m[i]));
    }
  }
  tangents.push(m[n - 2]);
  let d = `M${points[0][0]},${points[0][1]}`;
  for (let i = 0; i < n - 1; i++) {
    const h = dx[i] / 3;
    d += `C${points[i][0] + h},${points[i][1] + h * tangents[i]} ${points[i + 1][0] - h},${
      points[i + 1][1] - h * tangents[i + 1]
    } ${points[i + 1][0]},${points[i + 1][1]}`;
  }
  return d;
}

const TIME_STEPS = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 21600];

function timeTicks(start, end, desired) {
  const span = (end - start) / 1000;
  const step = TIME_STEPS.find((s) => span / s <= desired) || TIME_STEPS[TIME_STEPS.length - 1];
  const ms = step * 1000;
  const offset = new Date(start).getTimezoneOffset() * 60000;
  const ticks = [];
  for (let v = Math.ceil((start - offset) / ms) * ms + offset; v <= end; v += ms) ticks.push(v);
  return ticks;
}

/** .dateTime.hour().minute() */
function hourMinute(ms) {
  const d = new Date(ms);
  if (currentLocale() === 'en') return d.toLocaleTimeString('en', { hour: 'numeric', minute: '2-digit' });
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

/** PowerChartScale.effectiveMaximum for the A2345. */
function effectiveChartMaximum(preference, observedPeak) {
  const normalized = preference === 0 || CHART_OPTIONS.includes(preference) ? preference : 0;
  const peak = Number.isFinite(observedPeak) ? Math.max(0, observedPeak) : 0;
  const target = normalized === 0 ? peak * 1.15 : peak;
  const required = Math.max(normalized === 0 ? CHART_OPTIONS[0] : normalized, target);
  const choice = CHART_OPTIONS.find((c) => c >= required);
  if (choice) return choice;
  return Math.max(Math.ceil(required / 50) * 50, CHART_OPTIONS[CHART_OPTIONS.length - 1]);
}

function PowerChart({ history, selectedIndex, axisMax, stale }) {
  const wrap = useRef(null);
  const [size, setSize] = useState({ w: 0, h: 0 });
  useLayoutEffect(() => {
    const ro = new ResizeObserver(([entry]) => setSize({ w: entry.contentRect.width, h: entry.contentRect.height }));
    ro.observe(wrap.current);
    return () => ro.disconnect();
  }, []);
  const ceiling = chartCeiling(axisMax);
  const axis = chartAxisValues(axisMax);
  const yLabelWidth = Math.max(...axis.map((v) => (v === axisMax ? tf('%d W', v) : `${v}`).length)) * 6 + 10;
  const plot = { x: 0, y: 4, w: Math.max(0, size.w - yLabelWidth), h: Math.max(0, size.h - 4 - 20) };
  const t0 = history[0]?.t ?? Date.now() - 60000;
  const t1 = history.length > 1 ? history[history.length - 1].t : t0 + 60000;
  const span = Math.max(1, t1 - t0);
  const xOf = (time) => plot.x + ((time - t0) / span) * plot.w;
  const yOf = (w) => plot.y + plot.h - (Math.min(Math.max(w, 0), ceiling) / ceiling) * plot.h;

  const line = monotonePath(history.map((s) => [xOf(s.t), yOf(s.total)]));
  const area =
    history.length > 1 ? `${line}L${xOf(t1)},${plot.y + plot.h}L${xOf(t0)},${plot.y + plot.h}Z` : '';
  const portLine =
    selectedIndex != null
      ? monotonePath(
          history
            .filter((s) => selectedIndex < (s.perPort?.length || 0))
            .map((s) => [xOf(s.t), yOf(s.perPort[selectedIndex])]),
        )
      : '';
  const ticks = size.w ? timeTicks(t0, t1, 4) : [];

  return html`<div class="a2345-chart" ref=${wrap} role="img" aria-label=${t('本次实时功率趋势')}>
    ${size.w
      ? html`<svg width=${size.w} height=${size.h} class="chart__svg" aria-hidden="true">
          <defs>
            <linearGradient id="a2345-chart-area" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0" stop-color=${stale ? 'var(--c-text-tertiary)' : 'var(--c-accent)'} stop-opacity=${stale ? 0.16 : 0.26} />
              <stop offset="1" stop-color=${stale ? 'var(--c-text-tertiary)' : 'var(--c-accent)'} stop-opacity=${stale ? 0.01 : 0.02} />
            </linearGradient>
          </defs>
          <g class="a2345-chart__xgrid">
            ${ticks.map((v) => html`<line x1=${xOf(v)} x2=${xOf(v)} y1=${plot.y} y2=${plot.y + plot.h} />`)}
          </g>
          <g class="chart__grid">
            ${axis.map((v) => html`<line x1=${plot.x} x2=${plot.x + plot.w} y1=${yOf(v)} y2=${yOf(v)} />`)}
          </g>
          ${area ? html`<path d=${area} fill="url(#a2345-chart-area)" />` : null}
          ${line ? html`<path d=${line} class=${cx('a2345-chart__line', stale && 'is-stale')} />` : null}
          ${portLine ? html`<path d=${portLine} class="a2345-chart__port-line" />` : null}
          <g class="chart__labels">
            ${axis.map(
              (v) =>
                html`<text x=${plot.x + plot.w + 6} y=${yOf(v) + 3.5}>${v === axisMax ? tf('%d W', v) : String(v)}</text>`,
            )}
            ${ticks.map(
              (v) => html`<text x=${xOf(v)} y=${plot.y + plot.h + 15} text-anchor="middle">${hourMinute(v)}</text>`,
            )}
          </g>
        </svg>`
      : null}
  </div>`;
}

/** PowerChartScaleMenu(product: .a2345) */
function ScaleMenu({ observedPeak, preference }) {
  const effective = effectiveChartMaximum(preference, observedPeak);
  useEffect(() => {
    if (preference !== 0 && effective > preference && CHART_OPTIONS.includes(effective)) {
      setPrefs({ a2345PowerChartMaximum: effective });
    }
  }, [effective, preference]);
  const title = preference === 0 ? tf('自动 · %d W', effective) : tf('%d W', effective);
  const set = (v) => v !== preference && setPrefs({ a2345PowerChartMaximum: v });
  return html`<${ActionButton}
    icon="arrow.up.and.down"
    title=${title}
    class="btn--micro"
    help=${t('设置功率图纵轴；读数超过手动上限时会自动提高量程')}
    aria-label=${t('功率图量程')}
    onClick=${(e) =>
      openMenu(
        e.currentTarget,
        [
          { title: t('自动量程'), checked: preference === 0, action: () => set(0) },
          { separator: true },
          ...CHART_OPTIONS.map((v) => ({ title: tf('%d W', v), checked: preference === v, action: () => set(v) })),
        ],
        { align: 'end' },
      )}
  />`;
}

// ---- Stats ---------------------------------------------------------------------------------

function historyStats(history) {
  if (!history?.length) return { peak: 0, average: 0, energyWh: 0 };
  let peak = 0;
  let sum = 0;
  let energy = 0;
  history.forEach((s, i) => {
    peak = Math.max(peak, s.total);
    sum += s.total;
    if (i === 0) return;
    const previous = history[i - 1];
    const seconds = (s.t - previous.t) / 1000;
    if (seconds > 0 && seconds < MAXIMUM_INTEGRABLE_GAP) energy += (seconds * (s.total + previous.total)) / 2 / 3600;
  });
  return { peak, average: sum / history.length, energyWh: energy };
}

function Metric({ title, value, unit }) {
  return html`<div class="a2345-metric">
    <span class="t-micro c-tertiary">${t(title)}</span>
    <span class="a2345-metric__value">
      <span class="num">${value}</span>${unit ? html`<span class="t-micro c-tertiary">${unit}</span>` : null}
    </span>
  </div>`;
}

// ---- Page --------------------------------------------------------------------------------------

export default function A2345Dashboard({ state }) {
  const snap = state.a2345 || null;
  const product = activeProduct(state);
  const page = useRef(null);
  const [contentWidth, setContentWidth] = useState(0);
  const [selectedPort, setSelectedPort] = useState(null);
  useLayoutEffect(() => {
    const ro = new ResizeObserver(() => page.current && setContentWidth(page.current.clientWidth));
    ro.observe(page.current);
    return () => ro.disconnect();
  }, []);

  const telemetry = snap?.telemetry || null;
  const reading = telemetry != null;
  const stale = !!snap?.isStale;
  const isDemo = !!snap?.isDemo;
  const stage = snap?.stage || 'idle';
  const history = snap?.history || [];
  const stats = useMemo(() => historyStats(history), [history]);
  const chartPeak = history.reduce((m, s) => Math.max(m, s.total), 0);
  const scalePreference = state.prefs.a2345PowerChartMaximum || 0;
  const axisMax = effectiveChartMaximum(scalePreference, chartPeak);
  const failureReason = stage === 'failed' ? tt(snap?.failure) : null;
  const canRetry = !!snap?.canRetry && !state.prefs.demoMode;
  const settings = snap?.a2345?.settings || null;
  const wide = contentWidth === 0 || contentWidth >= 720;
  const selectedIndex = selectedPort != null ? product.ports.indexOf(selectedPort) : null;
  const total = telemetry ? telemetry.ports.reduce((sum, p) => sum + (isOn(p) ? p.power : 0), 0) : null;
  const activeCount = telemetry ? telemetry.ports.filter(isDelivering).length : 0;
  const tone = stateTone(snap);
  const statusLabel = snap ? tt(snap.statusLabel) : t('未连接');

  const toggleSelection = (port) => setSelectedPort((cur) => (cur === port ? null : port));
  const retry = () => call('RetryA2345').catch((err) => setActionMessage(describe(err)));

  const summaryHeader = html`<div class="a2345-summary">
    <div class="a2345-summary__titles">
      <span class="a2345-summary__line">
        <span class="t-label c-secondary">${t('实时总输出')}</span>
        <${Chip} text=${t(isDemo ? '模拟数据' : 'Wi-Fi 云端')} />
      </span>
      <span class="t-caption c-tertiary">
        ${reading
          ? tf('%d / 6 端口在充电 · 250 W 上限', activeCount)
          : t('6 端口 · 250 W 上限')}
      </span>
    </div>
    <span class="a2345-summary__spacer"></span>
    <div class="a2345-summary__readout">
      <span class="a2345-summary__total">
        <span class=${cx('num', stale ? 'c-tertiary' : 'c-primary')}>${reading ? formatted(total, 1) : PLACEHOLDER}</span>
        <span class="t-label c-secondary">W</span>
      </span>
      <span class="a2345-summary__status">
        <span class=${cx('a2345-dot', `is-${tone}`, isBusyStage(stage) && 'is-busy')}></span>
        <span class=${cx('t-micro', `a2345-tone-${tone}`)}>${statusLabel}</span>
      </span>
    </div>
  </div>`;

  const emptyTitle =
    stage === 'failed' ? t('连接没有完成') : stage === 'waitingForTelemetry' ? t('等待充电器数据') : t('连接 Anker Prime 250W');
  const emptyState = html`<div class=${cx('a2345-empty', wide ? 'is-wide' : 'is-stacked')}>
    <div class="a2345-empty__preview">
      <img
        src="assets/models/a2345-hero.png"
        alt=${t('Anker Prime 250W 充电器产品图')}
        class="a2345-empty__art"
      />
    </div>
    <div class="a2345-empty__details">
      <div class="a2345-empty__text">
        <span class="t-heading c-primary">${emptyTitle}</span>
        <span class="t-caption c-secondary para">${snap ? tt(snap.statusDetail) : ''}</span>
      </div>
      <div class="a2345-empty__actions">
        ${isBusyStage(stage) || stage === 'waitingForTelemetry'
          ? html`<span class="spinner"></span>
              <span class="t-caption c-secondary">${stageShortLabel(stage)}</span>`
          : failureReason != null && canRetry
            ? html`<${ActionButton} emphasis="primary" icon="arrow.clockwise" title=${t('重新连接')} onClick=${retry} />`
            : html`<${ActionButton}
                emphasis="primary"
                icon="person.badge.key"
                title=${t('前往连接')}
                onClick=${() => {
                  setPrefs({ initialSetupCompleted: true, demoMode: false, connectionMode: 'cloud' }).catch(() => {});
                  selectSection('devices');
                }}
              />`}
        <${ActionButton}
          icon="play.fill"
          title=${t('体验模拟设备')}
          disabled=${isDemo}
          onClick=${() => {
            setPrefs({ initialSetupCompleted: true, demoProduct: 'A2345', demoMode: true }).catch(() => {});
            selectSection('dashboard');
          }}
        />
      </div>
    </div>
  </div>`;

  const portPanel = html`<div class=${cx('a2345-ports', wide && 'is-side')}>
    <div class="a2345-ports__head">
      <span class="t-heading c-primary">${t('端口')}</span>
      <span class="t-micro c-tertiary">
        ${selectedPort ? tf('已选 %@', selectedPort) : t('点击端口查看单口曲线')}
      </span>
    </div>
    <div class="a2345-rule"></div>
    ${product.ports.map(
      (port, i) => html`
        <${PortRow}
          state=${state}
          snap=${snap}
          port=${port}
          index=${i}
          selected=${selectedPort === port}
          onSelect=${() => toggleSelection(port)}
        />
        ${i < product.ports.length - 1 ? html`<div class="a2345-rule a2345-rule--inset"></div>` : null}
      `,
    )}
  </div>`;

  const instrumentBody = html`<div class=${cx('a2345-instruments', wide ? 'is-wide' : 'is-stacked')}>
    <div class="a2345-instruments__stage">
      <${ModelStage} state=${state} snap=${snap} height=${wide ? 338 : 292} />
    </div>
    ${portPanel}
  </div>`;

  const chartSection = html`<div class="a2345-timeline">
    <div class="a2345-timeline__head">
      <span class="t-label c-secondary">${t('功率时间线')}</span>
      <span class="a2345-summary__spacer"></span>
      <span class="t-micro c-tertiary a2345-timeline__hint">
        ${selectedPort ? tf('总输出 + %@', selectedPort) : t('点击端口筛选单口曲线')}
      </span>
      <${ScaleMenu} observedPeak=${chartPeak} preference=${scalePreference} />
    </div>
    <div class="a2345-chart-well" aria-description=${statusLabel}>
      <${PowerChart} history=${history} selectedIndex=${selectedIndex} axisMax=${axisMax} stale=${stale} />
    </div>
  </div>`;

  // Fault, failure and warning notices under the stats.
  let faultNotice = null;
  if (settings?.hasFault) {
    const groups = settings.groups.filter((g) => g.hasFault).map((g) => g.group);
    const text = settings.isOverTemperature
      ? t('充电器温度过高，已启用过温保护。')
      : groups.length
        ? tf('%@ 端口异常。', groups.join(t('、')))
        : t('充电器报告了端口异常。');
    faultNotice = html`<${SlateCard} padding=${12} class="a2345-notice">
      <${Icon} name=${settings.isOverTemperature ? 'thermometer' : 'exclamationmark.triangle.fill'} class="c-danger" />
      <span class="t-body c-danger para">${text}</span>
    </${SlateCard}>`;
  }

  return html`<div class="page scroll overview a2345-overview" ref=${page}>
    <div class="overview__column">
      <${SlateCard} padding=${0} class=${cx('a2345-hero', reading && 'is-reading')}>
        ${summaryHeader}
        <div class="a2345-rule"></div>
        ${reading
          ? html`${instrumentBody}
              <div class="a2345-rule"></div>
              ${chartSection}`
          : emptyState}
      </${SlateCard}>
      ${reading
        ? html`<div class="a2345-metrics" style=${{ opacity: stale ? 0.45 : 1 }}>
            <${Metric} title="峰值" value=${formatted(stats.peak, 1)} unit="W" />
            <span class="a2345-metrics__divider"></span>
            <${Metric} title="平均" value=${formatted(stats.average, 1)} unit="W" />
            <span class="a2345-metrics__divider"></span>
            <${Metric} title="本次能量" value=${formatted(stats.energyWh, 2)} unit="Wh" />
            <span class="a2345-metrics__divider"></span>
            <${Metric} title="数据来源" value=${t(isDemo ? '模拟' : '云端')} />
          </div>`
        : null}
      ${faultNotice}
      ${failureReason != null && reading
        ? html`<${SlateCard} padding=${12} class="a2345-notice is-centered" aria-label=${tf('连接失败：%@', failureReason)}>
            <${Icon} name="bolt.slash.fill" class="c-danger" />
            <span class="t-body c-danger para">${failureReason}</span>
            <span class="a2345-summary__spacer"></span>
            ${canRetry
              ? html`<${ActionButton} emphasis="primary" icon="arrow.clockwise" title=${t('重新连接')} onClick=${retry} />`
              : null}
          </${SlateCard}>`
        : null}
      ${snap?.warning
        ? html`<${SlateCard} class="a2345-notice is-top">
            <${Icon} name="exclamationmark.triangle.fill" class="c-warn" />
            <span class="t-caption c-warn">${tt(snap.warning)}</span>
          </${SlateCard}>`
        : null}
    </div>
  </div>`;
}

// ---- A2345CustomModeSheet ------------------------------------------------------------------

const USB_A_CHOICES = [0, 15, 24];
const CUSTOM_TOTAL_LIMIT = 250;
const MODE_PORT_NAMES = ['C1', 'C2', 'C3', 'C4', 'A'];
const GROUP_LABELS = ['C1', 'C2', 'C3', 'C4', 'A1/A2'];
// a2345.Capabilities bits.
const CAP_PORT_PROTOCOLS = 1 << 4;
const CAP_PROTOCOL_MANAGEMENT = 1 << 11;

/** A2345CustomChargingProfile.maximumWatts */
function maximumWatts(groupIndex, mainland) {
  if (groupIndex === 0) return 140;
  if (groupIndex === 4) return 24;
  return mainland ? 120 : 100;
}

function modeSetting(mode, groupIndex) {
  const name = MODE_PORT_NAMES[groupIndex];
  return (
    mode.powerSettings?.find((s) => String(s.name).toUpperCase() === name) || mode.powerSettings?.[groupIndex] || null
  );
}

function modeSummary(mode) {
  return GROUP_LABELS.map((label, i) => `${i === 4 ? 'A' : label} ${modeSetting(mode, i)?.power ?? 0}W`).join(' · ');
}

function isActiveMode(settings, mode) {
  return !!settings?.isCustomChargingMode && (settings?.customProfile?.number ?? 0) === mode.number;
}

/**
 * Up to four custom charging profiles stored in the Anker account, as the
 * connection page presents them: `<A2345CustomModeSheet state onClose />`.
 */
export function A2345CustomModeSheet({ state, onClose }) {
  const snap = state.a2345 || null;
  const extras = snap?.a2345 || {};
  const settings = extras.settings || null;
  const [editing, setEditing] = useState(null);
  const disabled =
    extras.controlBlocker != null ||
    (extras.cloudWork || []).includes('chargingModes') ||
    isWritePending(snap, 0x0211) ||
    isWritePending(snap, 0x0206);

  useEffect(() => {
    if (editing) return undefined;
    const key = (e) => {
      if (e.key === 'Escape' || e.key === 'Enter') {
        // A confirmation on top owns the keys.
        if (document.querySelector('.dialog')) return;
        e.preventDefault();
        onClose();
      }
    };
    document.addEventListener('keydown', key);
    return () => document.removeEventListener('keydown', key);
  }, [editing, onClose]);

  const use = async (mode) => {
    const ok = await confirmDialog({
      title: tf('切换到「%@」？', mode.name),
      message: t('所有端口会断电几秒后恢复。'),
      actions: [
        { title: t('取消'), role: 'cancel' },
        { title: t('切换'), default: true },
      ],
    });
    if (ok) send('ApplyA2345ChargingMode', mode);
  };
  const remove = async (mode) => {
    const ok = await confirmDialog({
      title: tf('删除「%@」？', mode.name),
      message: isActiveMode(settings, mode) ? t('充电器会退出自定义模式。') : null,
      actions: [
        { title: t('取消'), role: 'cancel' },
        { title: t('删除'), role: 'destructive', default: true },
      ],
    });
    if (ok) send('DeleteA2345ChargingMode', mode);
  };
  const create = async () => {
    const number = extras.nextChargingModeNumber;
    try {
      const template = await call('A2345ChargingModeTemplate', number, tf('模式 %d', number));
      setEditing({ draft: template, isNew: true });
    } catch (err) {
      setActionMessage(describe(err));
    }
  };

  const modes = extras.chargingModes;
  return html`<div class="dialog-backdrop">
    <div class="a2345-sheet" role="dialog" aria-label=${t('自定义模式')}>
      ${editing
        ? html`<${CustomModeEditor}
            snap=${snap}
            draft=${editing.draft}
            isNew=${editing.isNew}
            isActive=${isActiveMode(settings, editing.draft)}
            close=${() => setEditing(null)}
          />`
        : html`<div class="a2345-sheet__head">
              <span class="t-heading c-primary">${t('自定义模式')}</span>
              <span class="a2345-summary__spacer"></span>
              ${(extras.cloudWork || []).includes('chargingModes') ? html`<span class="spinner"></span>` : null}
              <button class="btn is-primary" onClick=${onClose}>${t('完成')}</button>
            </div>
            <div class="a2345-rule"></div>
            <div class="a2345-sheet__body">
              ${modes
                ? html`${modes.map(
                      (mode) => html`<${SlateCard} padding=${12} class="a2345-mode">
                        <div class="a2345-mode__text">
                          <span class="a2345-mode__title">
                            <span class="t-label c-primary">${mode.name}</span>
                            ${isActiveMode(settings, mode) ? html`<${Chip} text=${t('使用中')} tone="accent" />` : null}
                          </span>
                          <span class="t-micro c-tertiary num a2345-mode__summary">${modeSummary(mode)}</span>
                        </div>
                        <span class="a2345-summary__spacer"></span>
                        <${ActionButton}
                          emphasis="primary"
                          title=${t('使用')}
                          disabled=${disabled || isActiveMode(settings, mode)}
                          onClick=${() => use(mode)}
                        />
                        <${ActionButton}
                          title=${t('编辑')}
                          disabled=${disabled}
                          onClick=${() => setEditing({ draft: mode, isNew: false })}
                        />
                        <${ActionButton}
                          icon="trash"
                          disabled=${disabled}
                          aria-label=${t('删除')}
                          onClick=${() => remove(mode)}
                        />
                      </${SlateCard}>`,
                    )}
                    ${extras.nextChargingModeNumber != null
                      ? html`<div>
                          <${ActionButton} icon="plus" title=${t('新建')} disabled=${disabled} onClick=${create} />
                        </div>`
                      : null}`
                : html`<span class="t-caption c-tertiary">${t('自定义模式没有读到。')}</span>`}
            </div>`}
    </div>
  </div>`;
}

function CustomModeEditor({ snap, draft: initial, isNew, isActive, close }) {
  const extras = snap?.a2345 || {};
  const mainland = !!extras.mainland;
  const settings = extras.settings || null;
  const caps = settings?.capabilities ?? 0;
  const showsProtocols = settings != null && (caps & CAP_PORT_PROTOCOLS) !== 0 && (caps & CAP_PROTOCOL_MANAGEMENT) === 0;
  const [draft, setDraft] = useState(() => JSON.parse(JSON.stringify(initial)));
  const total = (draft.powerSettings || []).reduce((sum, s) => sum + s.power, 0);
  const valid = draft.name.trim() !== '' && total <= CUSTOM_TOTAL_LIMIT;

  const groupIndex = (index) => {
    const i = MODE_PORT_NAMES.indexOf(String(draft.powerSettings[index].name).toUpperCase());
    return i >= 0 ? i : index < 5 ? index : 0;
  };
  const setPower = (index, power) =>
    setDraft((d) => ({ ...d, powerSettings: d.powerSettings.map((s, i) => (i === index ? { ...s, power } : s)) }));
  const toggleFlag = (index, key) =>
    setDraft((d) => ({ ...d, powerSettings: d.powerSettings.map((s, i) => (i === index ? { ...s, [key]: !s[key] } : s)) }));

  // C ports take 0 or 15 W and up; the official editor jumps over 1–14.
  const snap0 = (value, maximum) => (value <= 0 ? 0 : value < 15 ? (value < 8 ? 0 : 15) : Math.min(maximum, value));
  const step = (index, delta, maximum) => {
    const current = draft.powerSettings[index].power;
    let next = current + delta;
    if (delta > 0 && next > 0 && next < 15) next = 15;
    if (delta < 0 && next < 15) next = 0;
    setPower(index, Math.min(maximum, Math.max(0, next)));
  };

  const chips = [
    { title: mainland ? t('华为 SCP') : 'SCP', key: mainland ? 'huawei' : 'scp', voltage: false },
    { title: 'UFCS', key: 'ufcs', voltage: false },
    { title: 'PD 12V', key: 'pd12V', voltage: true },
    { title: '5-11V PPS', key: 'pps11V', voltage: true },
    { title: '5-16V PPS', key: 'pps16V', voltage: true },
    { title: '4.5-21V PPS', key: 'pps21V', voltage: true },
    ...(mainland ? [{ title: t('小米澎湃秒充'), key: 'xiaomi', voltage: false }] : []),
  ];

  const save = async () => {
    if (isActive) {
      const ok = await confirmDialog({
        title: t('保存并应用到充电器？'),
        message: t('所有端口会断电几秒后恢复。'),
        actions: [
          { title: t('取消'), role: 'cancel' },
          { title: t('保存'), default: true },
        ],
      });
      if (!ok) return;
    }
    send('SaveA2345ChargingMode', draft, isNew);
    close();
  };

  // 保存 is the default action.
  const canSave = valid && extras.controlBlocker == null;
  const latest = useRef(null);
  latest.current = canSave ? save : null;
  useEffect(() => {
    const key = (e) => {
      if (e.key !== 'Enter' || document.querySelector('.dialog') || e.target.closest?.('button')) return;
      if (!latest.current) return;
      e.preventDefault();
      latest.current();
    };
    document.addEventListener('keydown', key);
    return () => document.removeEventListener('keydown', key);
  }, []);

  return html`<div class="a2345-sheet__head">
      <${ActionButton} icon="chevron.left" aria-label=${t('返回')} onClick=${close} />
      <span class="t-heading c-primary">${t(isNew ? '新建自定义模式' : '编辑自定义模式')}</span>
      <span class="a2345-summary__spacer"></span>
      <button class="btn is-primary" disabled=${!canSave} onClick=${save}>${t('保存')}</button>
    </div>
    <div class="a2345-rule"></div>
    <div class="a2345-sheet__body">
      <label class="a2345-mode-name">
        <span class="t-body c-secondary">${t('名称')}</span>
        <input
          class="field"
          value=${draft.name}
          maxlength="20"
          onInput=${(e) => setDraft((d) => ({ ...d, name: e.currentTarget.value.slice(0, 20) }))}
        />
      </label>
      ${draft.powerSettings.map((setting, index) => {
        const g = groupIndex(index);
        const label = GROUP_LABELS[g];
        const maximum = maximumWatts(g, mainland);
        const voltageCount = chips.filter((c) => c.voltage && setting[c.key]).length;
        return html`<${SlateCard} padding=${12} class="a2345-mode-port">
          <div class="a2345-mode-port__row">
            <span class="num a2345-mode-port__label">${label}</span>
            ${g === 4
              ? html`<${Segmented}
                    label=${label}
                    value=${setting.power}
                    segments=${USB_A_CHOICES.map((w) => ({ title: `${w} W`, value: w }))}
                    onChange=${(w) => setPower(index, w)}
                    style=${{ width: '180px' }}
                  /><span class="a2345-summary__spacer"></span>`
              : html`<input
                    type="range"
                    class="a2345-slider"
                    min="0"
                    max=${maximum}
                    step="1"
                    value=${setting.power}
                    aria-label=${label}
                    onInput=${(e) => setPower(index, snap0(Math.round(Number(e.currentTarget.value)), maximum))}
                  />
                  <span class="a2345-stepper">
                    <button aria-label=${tf('%@ 增加', label)} onClick=${() => step(index, 1, maximum)}>
                      <${Icon} name="chevron-up" />
                    </button>
                    <button aria-label=${tf('%@ 减少', label)} onClick=${() => step(index, -1, maximum)}>
                      <${Icon} name="chevron-down" />
                    </button>
                  </span>
                  <span class="num a2345-mode-port__watts">${setting.power} W</span>`}
          </div>
          ${showsProtocols && g !== 4
            ? html`<div class="a2345-chips">
                ${chips.map((chip) => {
                  const on = !!setting[chip.key];
                  // At most three of PD 12V and the PPS ranges; PD 12V and
                  // Xiaomi exclude each other — the official protocol rules.
                  let blocked = !on && chip.voltage && voltageCount >= 3;
                  if (mainland && !on && chip.key === 'pd12V' && setting.xiaomi) blocked = true;
                  if (mainland && !on && chip.key === 'xiaomi' && setting.pd12V) blocked = true;
                  return html`<button
                    class=${cx('a2345-chip', on && 'is-on')}
                    aria-pressed=${on}
                    disabled=${blocked}
                    onClick=${() => toggleFlag(index, chip.key)}
                  >
                    ${chip.title}
                  </button>`;
                })}
              </div>`
            : null}
        </${SlateCard}>`;
      })}
      <div class="a2345-mode-total">
        <span class="t-body c-secondary">${t('合计')}</span>
        <span class=${cx('num', total > CUSTOM_TOTAL_LIMIT ? 'c-danger' : 'c-primary')}
          >${tf('%d / %d W', total, CUSTOM_TOTAL_LIMIT)}</span
        >
      </div>
      <div class="a2345-switch-row">
        <div class="a2345-switch-row__text">
          <span class="t-body c-primary">${t('自动退出')}</span>
          <span class="t-caption c-tertiary para">${t('有设备插到设为 0 W 的端口时，切回智能动态分配。')}</span>
        </div>
        <${Toggle} small on=${draft.autoExit} label=${t('自动退出')} onChange=${(v) => setDraft((d) => ({ ...d, autoExit: v }))} />
      </div>
    </div>`;
}
