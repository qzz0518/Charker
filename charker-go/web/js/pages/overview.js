// 总览: DashboardView.swift with the inspector presentation of PortCard.swift,
// DigitalTwinStage.swift around the three.js stage, the power timeline
// (PowerChart + PowerCurveHoverLayer) and the stats row.

import { html, useEffect, useLayoutEffect, useMemo, useRef, useState } from '../lib.js';
import { t, tf, currentLocale } from '../core/l10n.js';
import {
  PORTS,
  RATED_WATTS,
  cableChipText,
  cableCode,
  cableIsBottleneck,
  chartAxisValues,
  chartCeiling,
  connectedDeviceHelp,
  connectedDeviceText,
  effectiveChartMaximum,
  hasReadings as portHasReadings,
  hasRememberedCharger,
  isBusy,
  isCableAttached,
  isDelivering as portIsDelivering,
  isLive,
  isOn as portIsOn,
  isStandby,
  negotiationProgress,
  phaseDetail,
  phaseShortLabel,
  profileText,
  sessionErrorText,
  sessionStats,
  telemetryPort,
  totalPower,
  POWER_CHART_OPTIONS,
} from '../core/model.js';
import { call, selectSection, setActionMessage, setPrefs } from '../core/store.js';
import {
  ActionButton,
  Chip,
  Icon,
  PowerRail,
  SlateCard,
  StateDot,
  TotalReadout,
  confirmDialog,
  cx,
  openMenu,
} from '../ui/components.js';
import { registerIcons } from '../ui/icons.js';
import { mountStage } from './stage.js';

// view.3d reads as the letters "3D" next to 归位.
registerIcons({
  'view-3d':
    '<svg class="ck-icon" width="1.5em" height="1em" viewBox="0 0 15 10" fill="currentColor" aria-hidden="true">' +
    '<text x="7.5" y="8.6" text-anchor="middle" font-size="10" font-weight="600" font-family="Segoe UI, sans-serif">3D</text></svg>',
});

const PLACEHOLDER = '—';
const RAIL_SEGMENT_FLOOR = 0.1;
const INSTRUMENT_MIN_HEIGHT = 304;
const TIMER_PRESETS = [3600, 7200, 10800];

// Entrance plays once per app run (AppModel.dashboardHasEntered).
let dashboardHasEntered = false;

// ---- Helpers -----------------------------------------------------------------

function describeError(err) {
  const text = String(err?.message || err || '');
  if (text.includes('not ready')) return t('连接还没就绪，命令没有发出去。');
  if (text.includes('writes disabled')) return t('写入开关还没打开，命令没有发出去。');
  if (text.includes('timed out')) return t('充电器没有回应，这次操作有没有生效不清楚。');
  if (text.includes('rejected')) return t('充电器拒绝了这次操作。');
  return t('操作没有完成。');
}

/** PortCard.durationText, shared with the confirmation and the result. */
function durationText(seconds) {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  if (hours > 0 && minutes > 0) return tf('%d 小时 %d 分钟', hours, minutes);
  if (hours > 0) return tf('%d 小时', hours);
  return tf('%d 分钟', minutes);
}

function timerConsequence(label) {
  return tf(
    '到点后 %@ 会断电，那时正在从它取电的设备会断开。倒计时由充电器自己跑——电脑睡眠、关机或断开蓝牙都照样生效。',
    label,
  );
}

function pad2(n) {
  return String(n).padStart(2, '0');
}

function clock(date, seconds = true) {
  const s = `${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
  return seconds ? `${s}:${pad2(date.getSeconds())}` : s;
}

function sameDay(a, b) {
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
}

/** Text(date, style: .timer): m:ss, then h:mm:ss. */
function timerText(ms) {
  const total = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return h > 0 ? `${h}:${pad2(m)}:${pad2(s)}` : `${m}:${pad2(s)}`;
}

function useTick(ms, active = true) {
  const [, set] = useState(0);
  useEffect(() => {
    if (!active) return undefined;
    const id = setInterval(() => set((n) => n + 1), ms);
    return () => clearInterval(id);
  }, [ms, active]);
}

// ---- Shutdown schedules (PortShutdownSchedule + its store) ---------------------

const SCHEDULE_KEY = 'portShutdownSchedulesV1';

function loadSchedules() {
  try {
    const list = JSON.parse(localStorage.getItem(SCHEDULE_KEY) || '[]');
    return Array.isArray(list) ? list.filter((s) => s.armedAt + s.durationSeconds * 1000 > Date.now()) : [];
  } catch {
    return [];
  }
}

function saveSchedules(list) {
  try {
    localStorage.setItem(SCHEDULE_KEY, JSON.stringify(list));
  } catch {
    /* per-viewer convenience only */
  }
}

let schedules = loadSchedules();

/** The charger's own running countdown, else the local projection. */
function activeSchedule(state, index) {
  const deviceId = state.session.device?.id;
  const port = telemetryPort(state, PORTS[index]);
  const c = port?.control;
  const receivedAt = state.session.telemetry?.receivedAtMs;
  if (c?.running && receivedAt) {
    const elapsed = (c.countdownTotal - c.countdownRemaining) * 1000;
    const reported = { armedAt: receivedAt - elapsed, durationSeconds: c.countdownTotal };
    if (reported.armedAt + reported.durationSeconds * 1000 > Date.now()) return reported;
  }
  return (
    schedules.find(
      (s) => s.deviceId === deviceId && s.port === index && s.armedAt + s.durationSeconds * 1000 > Date.now(),
    ) || null
  );
}

// ---- Port actions (AppModel.setPort / setPortTimer / cancelPortTimer) ----------

async function setPort(state, index, on) {
  if (!(state.prefs.demoMode || state.prefs.writesEnabled)) return false;
  const label = PORTS[index];
  setActionMessage(tf('%@：正在发送…', label), null);
  try {
    await call('SetPortEnabled', label, on);
    setActionMessage(on ? tf('%@ 已打开', label) : tf('%@ 已关闭', label));
    return true;
  } catch (err) {
    setActionMessage(tf('%@：%@', label, describeError(err)));
    return false;
  }
}

async function setPortTimer(state, index, seconds) {
  if (!(state.prefs.demoMode || state.prefs.writesEnabled)) return;
  const label = PORTS[index];
  setActionMessage(tf('%@：正在发送…', label), null);
  try {
    await call('SetPortTimer', label, seconds);
    const deviceId = state.session.device?.id;
    schedules = schedules.filter((s) => !(s.deviceId === deviceId && s.port === index));
    schedules.push({ deviceId, port: index, armedAt: Date.now(), durationSeconds: seconds });
    if (!state.prefs.demoMode) saveSchedules(schedules);
    setActionMessage(null);
  } catch (err) {
    setActionMessage(tf('%@：%@', label, describeError(err)));
  }
}

async function cancelPortTimer(state, index) {
  if (!(state.prefs.demoMode || state.prefs.writesEnabled)) return;
  const label = PORTS[index];
  setActionMessage(tf('%@：正在发送…', label), null);
  try {
    await call('SetPortTimer', label, 0);
    const deviceId = state.session.device?.id;
    schedules = schedules.filter((s) => !(s.deviceId === deviceId && s.port === index));
    if (!state.prefs.demoMode) saveSchedules(schedules);
    setActionMessage(tf('%@ 的倒计时已关闭', label));
  } catch (err) {
    setActionMessage(tf('%@：%@', label, describeError(err)));
  }
}

// ---- USBCGlyph ------------------------------------------------------------------

function USBCGlyph({ lit, size = 20 }) {
  const h = size * 0.46;
  return html`<span class=${cx('usbc', lit && 'is-lit')} style=${{ width: `${size}px`, height: `${h}px` }}>
    <span style=${{ width: `${size * 0.52}px`, height: `${h * 0.32}px` }}></span>
  </span>`;
}

// ---- PortCard (.inspector) ---------------------------------------------------------

function PortRow({ state, index, selected, onHover, onSelect }) {
  const label = PORTS[index];
  const telemetry = telemetryPort(state, label);
  const stale = state.session.isStale;
  const delivering = portIsDelivering(telemetry);
  const on = portIsOn(telemetry);
  const watts = on ? telemetry?.power || 0 : 0;
  const readings = portHasReadings(telemetry);
  const canSwitch = state.session.writesEnabled && isLive(state.session) && telemetry != null;
  const schedule = activeSchedule(state, index);
  const grace = Math.max(45, state.prefs.pollSeconds * 3) * 1000;

  // Grace window after the draw stops, and the one-way latch on B4.
  const memo = useRef({ wasDelivering: null, graceUntil: 0, sawDevice: false });
  const [burst, setBurst] = useState(0);
  useEffect(() => {
    const m = memo.current;
    const d = telemetry ? delivering : null;
    if (d === false && m.wasDelivering === true) m.graceUntil = Date.now() + grace;
    if (d === true && m.wasDelivering === false && Date.now() >= m.graceUntil) setBurst((n) => n + 1);
    m.wasDelivering = d;
  }, [delivering, telemetry != null]);
  if (telemetry?.device) memo.current.sawDevice = true;
  const sawDevice = memo.current.sawDevice;
  const standby = isStandby(telemetry, memo.current.graceUntil);

  const totalW = totalPower(state.session);
  let statusText;
  if (!telemetry) statusText = t('无数据');
  else if (!on) statusText = t('已关闭');
  else if (delivering) {
    if (watts < 2.5) statusText = t('涓流');
    else if (profileText(telemetry)) statusText = profileText(telemetry);
    else if (totalW > 0.5 && watts > 0.5) statusText = tf('占 %.0f%%', Math.min(100, (watts / totalW) * 100));
    else statusText = t('供电中');
  } else if (standby) statusText = t('待机');
  else statusText = t('未接入设备');

  const powerText = readings ? tf('%.1f', watts) : PLACEHOLDER;
  const voltageText = readings ? tf('%.2f', telemetry.voltage) : PLACEHOLDER;
  const currentText = readings ? tf('%.2f', telemetry.current) : PLACEHOLDER;
  const tint = !readings ? 'c-tertiary' : delivering ? 'c-primary' : 'c-secondary';
  const nickname = state.prefs.portNicknames?.[index] || '';
  const cable = cableChipText(telemetry);
  const auxiliary = sawDevice || schedule != null;

  const [inFlight, setInFlight] = useState(null);
  const [pending, setPending] = useState(null);
  useEffect(() => setInFlight(null), [on]);
  useEffect(() => {
    if (inFlight == null) return undefined;
    const id = setTimeout(() => setInFlight(null), 15000);
    return () => clearTimeout(id);
  }, [inFlight]);
  const shownOn = pending != null ? pending : (inFlight ?? on);

  const flip = async () => {
    const target = !shownOn;
    setPending(target);
    const ok = await confirmDialog({
      title: target ? tf('打开 %@？', label) : tf('关闭 %@？', label),
      message: target ? tf('%@ 将恢复供电。', label) : tf('正在从 %@ 取电的设备会立即断电。', label),
      actions: [
        { title: t('取消'), role: 'cancel' },
        { title: t(target ? '打开端口' : '关闭端口'), role: target ? undefined : 'destructive', default: true },
      ],
    });
    setPending(null);
    if (!ok) return;
    setInFlight(target);
    setPort(state, index, target);
  };

  const askToArm = async (seconds) => {
    const ok = await confirmDialog({
      title: tf('让 %@ 在 %@ 后断电？', label, durationText(seconds)),
      message: timerConsequence(label),
      actions: [
        { title: t('取消'), role: 'cancel' },
        { title: t('设定倒计时'), default: true },
      ],
    });
    if (ok) setPortTimer(state, index, seconds);
  };

  const [customOpen, setCustomOpen] = useState(false);
  const timerMenu = (e) => {
    const items = [
      ...TIMER_PRESETS.map((s) => ({ title: durationText(s), disabled: !on, action: () => askToArm(s) })),
      { separator: true },
      { title: t('自定义…'), disabled: !on, action: () => setCustomOpen(true) },
    ];
    if (schedule) items.push({ separator: true }, { title: t('关闭倒计时'), action: () => cancelPortTimer(state, index) });
    openMenu(e.currentTarget, items, { align: 'end' });
  };

  return html`<div
    class=${cx('port-row', selected && 'is-selected', auxiliary && 'has-aux', burst && 'is-burst')}
    key=${burst}
    role="button"
    tabindex="0"
    aria-label=${tf('%@ 端口', label)}
    onClick=${(e) => {
      if (e.target.closest('input, button, .menu')) return;
      onSelect();
    }}
    onKeyDown=${(e) => {
      if ((e.key === 'Enter' || e.key === ' ') && e.target === e.currentTarget) {
        e.preventDefault();
        onSelect();
      }
    }}
    onPointerEnter=${() => onHover(true)}
    onPointerLeave=${() => onHover(false)}
    style=${{ opacity: stale ? 0.5 : 1 }}
  >
    <div class="port-row__head">
      <span class="port-row__id">
        <${USBCGlyph} lit=${delivering} />
        <span class=${cx('num port-row__label', delivering ? 'c-accent' : 'c-tertiary')}>${label}</span>
      </span>
      <input
        class="port-row__nick"
        type="text"
        maxlength="24"
        placeholder=${t('备注')}
        value=${nickname}
        title=${tf('给 %@ 起个备注名，例如接的是哪台设备', label)}
        aria-label=${tf('%@ 备注名', label)}
        onInput=${(e) => {
          const next = [...(state.prefs.portNicknames || ['', '', ''])];
          next[index] = e.currentTarget.value;
          setPrefs({ portNicknames: next });
        }}
        onKeyDown=${(e) => e.key === 'Enter' && e.currentTarget.blur()}
      />
      <span class="port-row__spacer"></span>
      ${cable
        ? html`<${Chip} text=${cable} tone=${cableIsBottleneck(telemetry) ? 'warn' : 'neutral'} />`
        : html`<span class="port-row__cable-placeholder" title=${t('线缆状态未知')} aria-label=${t('线缆状态未知')}
            >${PLACEHOLDER}</span
          >`}
      ${canSwitch
        ? html`<span class="port-row__controls">
            <button
              class=${cx('port-row__timer', on && 'is-on')}
              disabled=${!on && !schedule}
              title=${tf('让 %@ 在一段时间后自动断电', label)}
              aria-label=${tf('%@ 自动断电倒计时', label)}
              onClick=${timerMenu}
            >
              <${Icon} name="timer" />
            </button>
            <button
              class=${cx('toggle is-small', shownOn && 'is-on')}
              role="switch"
              aria-checked=${shownOn}
              aria-label=${tf('%@ 输出', label)}
              title=${tf('%@ 端口开关', label)}
              onClick=${flip}
            ></button>
          </span>`
        : null}
    </div>
    <div class="port-row__reading">
      <span class="port-row__power">
        <span class=${cx('num', tint)}>${powerText}</span><span class="port-row__unit">W</span>
      </span>
      <span class="port-row__details">
        <span class="port-row__metrics">
          <${Metric} value=${voltageText} unit="V" />
          <${Metric} value=${currentText} unit="A" />
        </span>
        <span class="t-micro c-tertiary">${statusText}</span>
      </span>
    </div>
    ${auxiliary
      ? html`<div class="port-row__aux">
          ${sawDevice
            ? html`<${DeviceRow} telemetry=${telemetry} />`
            : html`<span style=${{ flex: 1 }}></span>`}
          ${schedule ? html`<${ShutdownCountdown} schedule=${schedule} label=${label} />` : null}
        </div>`
      : null}
    <${PowerRail} watts=${watts} isDelivering=${delivering} dimmed=${stale} />
    ${customOpen
      ? html`<${CustomTimer}
          label=${label}
          onCancel=${() => setCustomOpen(false)}
          onCommit=${(minutes) => {
            setCustomOpen(false);
            setPortTimer(state, index, minutes * 60);
          }}
        />`
      : null}
  </div>`;
}

function Metric({ value, unit }) {
  const placeheld = value === PLACEHOLDER;
  return html`<span class="metric">
    <span class=${cx('num', placeheld ? 'c-tertiary' : 'c-secondary')}>${value}</span><span class="metric__unit"
      >${unit}</span
    >
  </span>`;
}

function DeviceRow({ telemetry }) {
  const value = connectedDeviceText(telemetry);
  const help = telemetry ? connectedDeviceHelp(telemetry) : t('充电器没有报告这个口接的是什么');
  return html`<span class="device-row" title=${help} aria-label=${t('接入设备')}>
    <span class="t-micro c-tertiary">${t('接入设备')}</span>
    <span class=${cx('t-caption device-row__value', value ? 'c-secondary' : 'c-tertiary')}>${value ?? PLACEHOLDER}</span>
  </span>`;
}

function ShutdownCountdown({ schedule, label }) {
  useTick(1000);
  const now = new Date();
  const deadline = new Date(schedule.armedAt + schedule.durationSeconds * 1000);
  if (deadline <= now) return null;
  const remaining = Math.ceil((deadline - now) / 1000);
  const text = `${pad2(Math.floor(remaining / 3600))}:${pad2(Math.floor((remaining % 3600) / 60))}:${pad2(remaining % 60)}`;
  let when = clock(deadline, false);
  const tomorrow = new Date(now);
  tomorrow.setDate(now.getDate() + 1);
  if (!sameDay(deadline, now)) {
    when = sameDay(deadline, tomorrow)
      ? tf('明天 %@', when)
      : deadline.toLocaleString(currentLocale() === 'en' ? 'en' : 'zh-CN', {
          month: 'short',
          day: 'numeric',
          hour: '2-digit',
          minute: '2-digit',
          hour12: false,
        });
  }
  return html`<span
    class="countdown"
    aria-label=${tf('%@ 自动断电倒计时', label)}
    title=${tf('剩余 %@，预计 %@ 断电', text, when)}
  >
    <${Icon} name="timer" />
    <span class="num countdown__value">${text}</span>
    <span class="c-tertiary">·</span>
    <span class="t-micro c-secondary">${when}</span>
  </span>`;
}

function CustomTimer({ label, onCancel, onCommit }) {
  const [text, setText] = useState('');
  const input = useRef(null);
  useEffect(() => input.current?.focus(), []);
  const value = /^\s*\d+\s*$/.test(text) ? Number(text) : null;
  const minutes = value != null && value >= 1 && value <= 1435 ? value : null;
  return html`<div class="popover-backdrop" onPointerDown=${(e) => e.target === e.currentTarget && onCancel()}>
    <div class="popover" role="dialog" onKeyDown=${(e) => e.key === 'Escape' && onCancel()}>
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
          onKeyDown=${(e) => e.key === 'Enter' && minutes && onCommit(minutes)}
        />
        <span class="t-body c-secondary">${t('分钟')}</span>
      </div>
      <div class="t-micro c-tertiary">${t('1 到 1435 分钟。')}</div>
      <div class="t-caption c-secondary para">${timerConsequence(label)}</div>
      <div class="popover__actions">
        <button class="btn" onClick=${onCancel}>${t('取消')}</button>
        <button class="btn is-primary" disabled=${!minutes} onClick=${() => onCommit(minutes)}>${t('设定倒计时')}</button>
      </div>
    </div>
  </div>`;
}

// ---- Digital twin --------------------------------------------------------------

function DigitalTwin({ state, height, highlightedPort, selectedPort, onPortTap, onPortHover }) {
  const el = useRef(null);
  const pills = useRef(null);
  const controller = useRef(null);
  const [loadState, setLoadState] = useState('loading');
  const callbacks = useRef({});
  callbacks.current = { onPortTap, onPortHover };
  useEffect(() => {
    controller.current = mountStage({
      el: el.current,
      pillsEl: pills.current,
      onPortTap: (i) => callbacks.current.onPortTap(i),
      onPortHover: (i) => callbacks.current.onPortHover(i),
      onLoad: setLoadState,
    });
    return () => controller.current.dispose();
  }, []);

  const telemetry = state.session.telemetry;
  const active = isLive(state.session);
  const homePose = state.prefs.modelHomeCamera || null;
  useEffect(() => {
    controller.current?.update({
      active,
      totalWatts: totalPower(state.session) || 0,
      highlightedPort,
      selectedPort,
      reduceMotion: window.matchMedia('(prefers-reduced-motion: reduce)').matches,
      homePose,
      ports: PORTS.map((label) => {
        const p = telemetry?.ports?.find((x) => x.port === label);
        const code = cableCode(p);
        const capability =
          code === 0 ? '60 W' : code === 1 ? '100 W' : code === 2 ? '240 W EPR' : code != null && code !== 3 ? t('未知规格') : null;
        return {
          watts: p && portIsOn(p) ? p.power : 0,
          lit: active && portIsDelivering(p),
          attached: active && p ? isCableAttached(p) : null,
          capability,
        };
      }),
    });
  });

  const cameraMenu = (e) =>
    openMenu(
      e.currentTarget,
      [
        { title: t('将当前视角设为归位'), action: () => setPrefs({ modelHomeCamera: controller.current.capture() }) },
        {
          title: t('恢复初始归位视角'),
          disabled: homePose == null,
          action: () => {
            setPrefs({ modelHomeCamera: null });
            setTimeout(() => controller.current.reset(), 0);
          },
        },
      ],
      { align: 'end' },
    );

  return html`<div class="stage" style=${{ height: `${height}px` }} ref=${el}>
    <div class="stage__pills" ref=${pills}></div>
    ${loadState === 'failed'
      ? html`<div class="stage__fallback stage__overlay">
          <img src="assets/models/a2687-hero.png" alt="" style=${{ height: `${height * 0.58}px`, filter: `saturate(${active ? 0.8 : 0.35})` }} />
          <span class="t-caption c-tertiary">${t('三维视图暂不可用')}</span>
          <${ActionButton} title=${t('重新载入')} onClick=${() => controller.current.reload()} />
        </div>`
      : null}
    ${loadState === 'loading'
      ? html`<div class="stage__badge stage__overlay">
          <span class="spinner"></span><span class="t-micro c-tertiary">${t('载入三维模型')}</span>
        </div>`
      : null}
    ${loadState === 'ready'
      ? html`
          <div class="stage__hint t-micro c-tertiary">
            <${Icon} name="move.3d" /><span>${t('拖动旋转 · 滚轮或捏合缩放 · 点击端口')}</span>
          </div>
          <div class="stage__corner stage__corner--top stage__overlay">
            <${ActionButton}
              icon=${homePose == null ? 'viewfinder' : 'bookmark.fill'}
              title=${t('设定')}
              class="btn--micro"
              help=${t('设置归位视角与缩放')}
              aria-label=${t(homePose == null ? '设定归位视角' : '自定义归位视角已启用')}
              onClick=${cameraMenu}
            />
          </div>
          <div class="stage__corner stage__corner--bottom stage__overlay">
            <${ActionButton}
              icon="view-3d"
              title=${t('归位')}
              class="btn--micro"
              help=${t('恢复保存的归位视角与缩放')}
              onClick=${() => controller.current.reset()}
            />
          </div>
        `
      : null}
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

function PowerChart({ history, selectedPort, scalePreference }) {
  const wrap = useRef(null);
  const [size, setSize] = useState({ w: 0, h: 0 });
  const [hoverAt, setHoverAt] = useState(null);
  useLayoutEffect(() => {
    const ro = new ResizeObserver(([entry]) => {
      const r = entry.contentRect;
      setSize({ w: r.width, h: r.height });
    });
    ro.observe(wrap.current);
    return () => ro.disconnect();
  }, []);
  const peak = history.reduce((m, s) => Math.max(m, s.total), 0);
  const axisMax = effectiveChartMaximum(scalePreference, peak);
  const ceiling = chartCeiling(axisMax);
  const axis = chartAxisValues(axisMax);
  const shortSpan = history.length < 2 || history[history.length - 1].t - history[0].t < 150000;

  // Plot frame inside the padded chart: trailing y labels, bottom x labels.
  const yLabelWidth = Math.max(...axis.map((v) => (v === axisMax ? `${v} W` : `${v}`).length)) * 6 + 8;
  const plot = { x: 0, y: 6, w: Math.max(0, size.w - yLabelWidth), h: Math.max(0, size.h - 6 - 18) };
  const t0 = history[0]?.t ?? 0;
  const t1 = history[history.length - 1]?.t ?? 1;
  const span = Math.max(1, t1 - t0);
  const xOf = (time) => plot.x + ((time - t0) / span) * plot.w;
  const yOf = (w) => plot.y + plot.h - (Math.min(w, ceiling) / ceiling) * plot.h;

  const line = monotonePath(history.map((s) => [xOf(s.t), yOf(s.total)]));
  const area = line ? `${line}L${xOf(t1)},${plot.y + plot.h}L${xOf(t0)},${plot.y + plot.h}Z` : '';
  const portLine =
    selectedPort != null
      ? monotonePath(
          history.filter((s) => selectedPort < (s.perPort?.length || 0)).map((s) => [xOf(s.t), yOf(s.perPort[selectedPort])]),
        )
      : '';
  const last = history[history.length - 1];
  const divisions = Math.max(1, Math.round(plot.w / 16));
  const ticks = size.w ? timeTicks(t0, t1, shortSpan ? 3 : 4) : [];

  const hovered =
    hoverAt != null && history.length
      ? history.reduce((best, s) => (Math.abs(s.t - hoverAt) < Math.abs(best.t - hoverAt) ? s : best))
      : null;
  const onMove = (e) => {
    const r = wrap.current.getBoundingClientRect();
    const x = e.clientX - r.left - plot.x;
    setHoverAt(x >= 0 && x <= plot.w ? t0 + (x / plot.w) * span : null);
  };

  return html`<div class="chart" ref=${wrap} onPointerMove=${onMove} onPointerLeave=${() => setHoverAt(null)}>
    ${size.w
      ? html`<svg width=${size.w} height=${size.h} class="chart__svg" aria-hidden="true">
          <defs>
            <linearGradient id="chart-area" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0" stop-color="var(--c-accent)" stop-opacity="0.30" />
              <stop offset="1" stop-color="var(--c-accent)" stop-opacity="0.02" />
            </linearGradient>
          </defs>
          <g class="chart__fine-grid">
            ${Array.from({ length: divisions - 1 }, (_, i) => {
              const x = plot.x + (plot.w * (i + 1)) / divisions;
              return html`<line x1=${x} x2=${x} y1=${plot.y} y2=${plot.y + plot.h} />`;
            })}
          </g>
          <g class="chart__grid">
            ${axis.map((v) => html`<line x1=${plot.x} x2=${plot.x + plot.w} y1=${yOf(v)} y2=${yOf(v)} />`)}
          </g>
          <path d=${area} fill="url(#chart-area)" />
          <path d=${line} class="chart__line" />
          ${portLine ? html`<path d=${portLine} class="chart__port-line" />` : null}
          ${last ? html`<circle cx=${xOf(last.t)} cy=${yOf(last.total)} r="3" class="chart__dot" />` : null}
          <g class="chart__labels">
            ${axis.map(
              (v) =>
                html`<text x=${plot.x + plot.w + 6} y=${yOf(v) + 3.5}>${v === axisMax ? tf('%d W', v) : String(v)}</text>`,
            )}
            ${ticks.map(
              (v) =>
                html`<text x=${xOf(v)} y=${plot.y + plot.h + 14} text-anchor="middle">${clock(new Date(v), shortSpan)}</text>`,
            )}
          </g>
          ${hovered
            ? html`<line
                  class="chart__crosshair"
                  x1=${xOf(hovered.t)}
                  x2=${xOf(hovered.t)}
                  y1=${plot.y}
                  y2=${plot.y + plot.h}
                /><circle cx=${xOf(hovered.t)} cy=${yOf(hovered.total)} r="3.5" class="chart__dot" />`
            : null}
        </svg>`
      : null}
    ${hovered
      ? html`<${ChartHoverBubble}
          anchor=${{ x: xOf(hovered.t), y: yOf(hovered.total) }}
          plot=${plot}
          headline=${tf('%.1f W', hovered.total)}
          detail=${selectedPort != null && selectedPort < (hovered.perPort?.length || 0)
            ? tf('%@ · %.1f W', `C${selectedPort + 1}`, hovered.perPort[selectedPort])
            : null}
          caption=${clock(new Date(hovered.t))}
        />`
      : null}
  </div>`;
}

/** ChartHoverBubble: above the point, else to its side, clamped to the plot. */
function ChartHoverBubble({ anchor, plot, headline, detail, caption }) {
  const ref = useRef(null);
  const [pos, setPos] = useState(null);
  useLayoutEffect(() => {
    const el = ref.current;
    const w = el.offsetWidth;
    const h = el.offsetHeight;
    const gap = 12;
    const fitsAbove = anchor.y - gap - h >= plot.y;
    const toRight = anchor.x + gap + w / 2;
    const toLeft = anchor.x - gap - w / 2;
    const wantedX = fitsAbove ? anchor.x : toRight + w / 2 <= plot.x + plot.w ? toRight : toLeft;
    const cx0 = Math.min(Math.max(wantedX, plot.x + w / 2), plot.x + plot.w - w / 2);
    const cy0 = fitsAbove ? anchor.y - gap - h / 2 : Math.max(plot.y + h / 2, anchor.y);
    setPos({ left: cx0 - w / 2, top: cy0 - h / 2 });
  }, [anchor.x, anchor.y, headline, detail]);
  return html`<div
    class="hover-bubble"
    ref=${ref}
    style=${{ left: `${pos?.left ?? 0}px`, top: `${pos?.top ?? 0}px`, opacity: pos ? 1 : 0 }}
  >
    <div class="num hover-bubble__headline">${headline}</div>
    ${detail ? html`<div class="num hover-bubble__detail">${detail}</div>` : null}
    <div class="t-micro c-tertiary">${caption}</div>
  </div>`;
}

/** PowerChartScaleMenu */
function ScaleMenu({ observedPeak, preference }) {
  const effective = effectiveChartMaximum(preference, observedPeak);
  useEffect(() => {
    if (preference !== 0 && effective > preference && POWER_CHART_OPTIONS.includes(effective)) {
      setPrefs({ a2687PowerChartMaximum: effective });
    }
  }, [effective, preference]);
  const title = preference === 0 ? tf('自动 · %d W', effective) : tf('%d W', effective);
  const set = (v) => v !== preference && setPrefs({ a2687PowerChartMaximum: v });
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
          ...POWER_CHART_OPTIONS.map((v) => ({ title: tf('%d W', v), checked: preference === v, action: () => set(v) })),
        ],
        { align: 'end' },
      )}
  />`;
}

// ---- Searching hero --------------------------------------------------------------------

function RadarPulse({ diameter = 128, active }) {
  return html`<div class=${cx('radar', active && 'is-active')} style=${{ width: `${diameter}px`, height: `${diameter}px` }}>
    ${active ? [0, 1, 2].map((i) => html`<span style=${{ animationDelay: `${-i * 0.8}s` }}></span>`) : html`<span class="radar__still"></span>`}
  </div>`;
}

/** ChargerFigure: the drawn charger in the searching state. */
function ChargerFigure({ height = 72 }) {
  const w = height * 0.74;
  const r = height * 0.14;
  return html`<svg class="charger-figure" width=${w} height=${height * 1.08} viewBox=${`0 ${-height * 0.08} ${w} ${height * 1.08}`} aria-label=${t('充电器示意图')}>
    <defs>
      <linearGradient id="cf-shell" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0" class="cf-shell-a" />
        <stop offset="1" class="cf-shell-b" />
      </linearGradient>
      <linearGradient id="cf-glass" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0" stop-color="#0d0f14" />
        <stop offset="1" stop-color="#1a1c24" />
      </linearGradient>
    </defs>
    <rect class="cf-prong" x=${w / 2 - w * 0.08 - w * 0.1} y=${-height * 0.08} width=${w * 0.1} height=${height * 0.16} rx=${w * 0.035} />
    <rect class="cf-prong" x=${w / 2 + w * 0.08} y=${-height * 0.08} width=${w * 0.1} height=${height * 0.16} rx=${w * 0.035} />
    <rect x="0.5" y="0.5" width=${w - 1} height=${height - 1} rx=${r} fill="url(#cf-shell)" class="cf-shell" />
    <rect x=${w * 0.09} y=${w * 0.09} width=${w * 0.82} height=${height * 0.52} rx=${height * 0.09} fill="url(#cf-glass)" />
    <path
      d=${(() => {
        const cx0 = w / 2;
        const cy0 = w * 0.09 + height * 0.075 + height * 0.12;
        const rr = height * 0.12 - 1;
        const a0 = (135 * Math.PI) / 180;
        const a1 = (405 * Math.PI) / 180;
        return `M${cx0 + rr * Math.cos(a0)},${cy0 + rr * Math.sin(a0)} A${rr},${rr} 0 1 1 ${cx0 + rr * Math.cos(a1)},${cy0 + rr * Math.sin(a1)}`;
      })()}
      fill="none"
      stroke="rgba(255,255,255,0.14)"
      stroke-width=${Math.max(1.2, height * 0.02)}
      stroke-linecap="round"
    />
    <circle cx=${w / 2} cy=${w * 0.09 + height * 0.52 - height * 0.055 - height * 0.065} r=${height * 0.065 - 0.5} fill="none" stroke="rgba(255,255,255,0.35)" stroke-width=${Math.max(1, height * 0.012)} />
    ${[0, 1, 2].map(
      (i) => html`<rect
        x=${w * 0.09 + i * ((w * 0.82 - 2 * w * 0.07) / 3 + w * 0.07)}
        y=${w * 0.09 + height * 0.52 + height * 0.045}
        width=${(w * 0.82 - 2 * w * 0.07) / 3}
        height=${height * 0.1}
        rx=${height * 0.05}
        class="cf-port"
      />`,
    )}
  </svg>`;
}

function SearchingHero({ state }) {
  const s = state.session;
  const failed = s.phase === 'failed';
  const isFirst = !state.prefs.demoMode && !hasRememberedCharger(state) && !s.device;
  const progress = negotiationProgress(s);
  return html`<div class="searching">
    <div class="searching__figure">
      <${RadarPulse} diameter=${128} active=${isBusy(s)} />
      <div class="searching__center">
        ${failed ? html`<${Icon} name="bolt.slash" class="searching__fail" />` : html`<${ChargerFigure} height=${72} />`}
      </div>
    </div>
    <div class="searching__text">
      <div class="t-heading c-primary">${isFirst ? t('连接你的 Anker Prime') : phaseShortLabel(s)}</div>
      ${!isFirst ? html`<div class="t-caption c-tertiary para" style=${{ textAlign: 'center' }}>${phaseDetail(s)}</div>` : null}
    </div>
    ${isFirst
      ? html`<div class="searching__actions">
            <${ActionButton}
              emphasis="primary"
              icon="antenna.radiowaves.left.and.right"
              title=${t('查找充电器')}
              onClick=${() => {
                selectSection('devices');
                call('Scan').catch(() => {});
              }}
            />
            <${ActionButton} icon="play.fill" title=${t('体验模拟设备')} onClick=${() => setPrefs({ demoMode: true })} />
          </div>
          <div class="t-micro c-tertiary" style=${{ textAlign: 'center', maxWidth: '420px' }}>
            ${t('先给充电器通电，并暂时退出正在占用它的官方 Anker App。')}
          </div>`
      : null}
    ${progress != null && progress < 1
      ? html`<div class="rail" style=${{ width: '220px', height: '2px' }}>
          <div class="rail__fill" style=${{ width: `${progress * 100}%`, background: 'var(--c-accent)' }}></div>
        </div>`
      : null}
    ${failed && !isFirst
      ? html`<${ActionButton} emphasis="primary" title=${t('重新连接')} onClick=${() => call('Reconnect').catch(() => {})} />`
      : null}
  </div>`;
}

// ---- Stats row --------------------------------------------------------------------------

const SCOPES = [
  { id: 'session', menu: '本次', tile: '本次能量' },
  { id: 'day', menu: '今天', tile: '今日能量' },
  { id: 'week', menu: '本周', tile: '本周能量' },
  { id: 'month', menu: '本月', tile: '本月能量' },
];

function StatTile({ label, value, unit, accessory }) {
  return html`<div class="stat">
    <span class=${cx('stat__label t-micro', accessory ? 'c-accent' : 'c-tertiary')}>
      <span>${label}</span>${accessory ? html`<${Icon} name=${accessory} class="stat__chevron" />` : null}
    </span>
    <span class="stat__value">
      <span class="num">${value}</span><span class="stat__unit">${unit}</span>
    </span>
  </div>`;
}

function StatsRow({ state, stats }) {
  useTick(1000, stats.connectedAt != null);
  const scope = SCOPES.find((s) => s.id === state.prefs.dashboardEnergyScope) || SCOPES[0];
  const summary = state.energy?.scopes?.[scope.id];
  const wh = summary ? summary.wh : scope.id === 'session' ? stats.energyWh : 0;
  let value;
  let unit;
  if (wh >= 1000) {
    value = tf(wh >= 10000 ? '%.1f' : '%.2f', wh / 1000);
    unit = 'kWh';
  } else {
    value = tf(wh < 10 ? '%.2f' : '%.1f', wh);
    unit = 'Wh';
  }
  const menu = (e) =>
    openMenu(e.currentTarget, [
      ...SCOPES.map((s) => ({
        title: t(s.menu),
        checked: s.id === scope.id,
        action: () => setPrefs({ dashboardEnergyScope: s.id }),
      })),
      { separator: true },
      { title: t('查看能耗记录'), action: () => selectSection('energy') },
      {
        title: t('结束本次统计'),
        disabled: !state.energy?.hasActiveSession,
        action: () => call('EndEnergySession').catch((err) => setActionMessage(String(err?.message || err))),
      },
    ]);
  return html`<${SlateCard} padding=${0} class="stats">
    <${StatTile} label=${t('峰值')} value=${tf('%.1f', stats.peak)} unit="W" />
    <span class="stats__divider"></span>
    <${StatTile} label=${t('平均')} value=${tf('%.1f', stats.average)} unit="W" />
    <span class="stats__divider"></span>
    <button
      class="stats__menu"
      title=${t('切换统计周期')}
      aria-label=${tf('%@，%@ %@', t(scope.tile), value, unit)}
      onClick=${menu}
    >
      <${StatTile} label=${t(scope.tile)} value=${value} unit=${unit} accessory="chevron.down" />
    </button>
    <span class="stats__divider"></span>
    <div class="stat">
      <span class="stat__label t-micro c-tertiary">${t('连接时长')}</span>
      <span class="stat__value"
        ><span class="num">${stats.connectedAt != null ? timerText(Date.now() - stats.connectedAt) : '—'}</span></span
      >
    </div>
  </${SlateCard}>`;
}

// ---- Notices ---------------------------------------------------------------------------

function Notices({ session }) {
  const live = isLive(session);
  const items = [];
  if (session.warning) items.push({ text: session.warning, symbol: 'exclamationmark.triangle.fill', tone: 'warn' });
  if (session.lastError && !live)
    items.push({ text: sessionErrorText(session), symbol: 'bolt.slash.fill', tone: 'danger' });
  if (!items.length) return null;
  return html`<div class="notices">
    ${items.map(
      (n) => html`<${SlateCard} padding=${12} class="notice">
        <${Icon} name=${n.symbol} class=${`c-${n.tone}`} />
        <span class="t-body c-secondary para">${n.text}</span>
      </${SlateCard}>`,
    )}
  </div>`;
}

// ---- Page ------------------------------------------------------------------------------

export default function Overview({ state }) {
  const s = state.session;
  const [hoveredPort, setHoveredPort] = useState(null);
  const [selectedPort, setSelectedPort] = useState(null);
  const [appeared] = useState(dashboardHasEntered);
  useEffect(() => {
    dashboardHasEntered = true;
  }, []);
  const inspector = useRef(null);
  const page = useRef(null);
  const [instrumentHeight, setInstrumentHeight] = useState(INSTRUMENT_MIN_HEIGHT);
  const [contentWidth, setContentWidth] = useState(0);
  useLayoutEffect(() => {
    const ro = new ResizeObserver(() => {
      if (inspector.current) setInstrumentHeight(Math.max(INSTRUMENT_MIN_HEIGHT, Math.ceil(inspector.current.offsetHeight)));
      if (page.current) setContentWidth(page.current.clientWidth);
    });
    if (inspector.current) ro.observe(inspector.current);
    if (page.current) ro.observe(page.current);
    return () => ro.disconnect();
  });

  const telemetry = s.telemetry;
  const stale = s.isStale;
  const total = totalPower(s);
  const searching = telemetry == null && !isLive(s);
  const stats = useMemo(() => sessionStats(s), [s.history, s.connectedAtMs]);

  const segments = telemetry
    ? PORTS.map((label) => {
        const p = telemetry.ports.find((x) => x.port === label);
        return p && portIsOn(p) ? p.power : 0;
      })
    : null;
  const portSegments = segments && segments.some((v) => v > RAIL_SEGMENT_FLOOR) ? segments : null;
  const legendVisible = (portSegments?.filter((v) => v > RAIL_SEGMENT_FLOOR).length || 0) > 1;

  const charging = telemetry ? telemetry.ports.filter((p) => portIsDelivering(p)).length : 0;
  const connected = telemetry
    ? telemetry.ports.filter((p) => isCableAttached(p) === true || (portIsOn(p) && p.power > RAIL_SEGMENT_FLOOR)).length
    : 0;
  const summaryText =
    connected > charging
      ? tf('%d / %d 端口在充电 · %d 口已连接未充电 · %d W 上限', charging, PORTS.length, connected - charging, RATED_WATTS)
      : tf('%d / %d 端口在充电 · %d W 上限', charging, PORTS.length, RATED_WATTS);

  const toggleSelection = (i) => setSelectedPort((cur) => (cur === i ? null : i));
  const sideBySide = contentWidth === 0 || Math.min(contentWidth, 1040) - 2 * 28 - 2 * 20 >= 276 + 12 + 284;
  const history = s.history || [];
  const chartPeak = history.reduce((m, x) => Math.max(m, x.total), 0);

  let status = null;
  if (!(isLive(s) && !stale)) {
    status = html`<span class="summary__status">
      <${StateDot} session=${s} stale=${stale} />
      ${stale && telemetry
        ? html`<span class="t-label c-warn num">${tf('数据陈旧 · %@更新', relativeTime(telemetry.receivedAtMs))}</span>`
        : html`<span class="t-label c-secondary">${phaseShortLabel(s)}</span>`}
    </span>`;
  }

  const inspectorView = html`<div class="inspector" ref=${inspector}>
    <div class="inspector__head">
      <span class="t-heading c-primary">${t('端口')}</span>
      <span class="t-micro c-tertiary">
        ${selectedPort != null ? tf('已选 C%d', selectedPort + 1) : t('点击端口查看单口曲线')}
      </span>
    </div>
    <div class="inspector__rule"></div>
    ${PORTS.map(
      (_, i) => html`
        <${PortRow}
          state=${state}
          index=${i}
          selected=${selectedPort === i}
          onHover=${(inside) => setHoveredPort((cur) => (inside ? i : cur === i ? null : cur))}
          onSelect=${() => toggleSelection(i)}
        />
        ${i < PORTS.length - 1 ? html`<div class="inspector__rule inspector__rule--inset"></div>` : null}
      `,
    )}
  </div>`;

  const twin = (height) => html`<${DigitalTwin}
    state=${state}
    height=${height}
    highlightedPort=${hoveredPort}
    selectedPort=${selectedPort}
    onPortTap=${toggleSelection}
    onPortHover=${setHoveredPort}
  />`;

  return html`<div class="page scroll overview" ref=${page}>
    <div class=${cx('overview__column', !appeared && 'is-entering')}>
      <${SlateCard} padding=${0} class=${cx('hero', searching && 'is-searching')}>
        ${searching
          ? html`<${SearchingHero} state=${state} />`
          : html`
              <div class="summary">
                <div class="summary__top">
                  <div class="summary__titles">
                    <span class="t-label c-secondary">${t('实时总输出')}</span>
                    <span class="t-micro c-tertiary">${summaryText}</span>
                  </div>
                  <span class="summary__spacer"></span>
                  ${status}
                  <${TotalReadout} watts=${total} isStale=${stale} size=${36} />
                </div>
                <${PowerRail}
                  watts=${total || 0}
                  ceiling=${RATED_WATTS}
                  isDelivering=${(total || 0) > 0}
                  segments=${portSegments}
                  dimmed=${stale}
                />
                <div class="summary__legend" aria-hidden=${!legendVisible}>
                  ${legendVisible
                    ? portSegments.map((v, i) =>
                        v > RAIL_SEGMENT_FLOOR
                          ? html`<span class="legend-item">
                              <span class="legend-item__dot" style=${{ opacity: [1, 0.72, 0.5][i % 3] }}></span>
                              <span class="num c-tertiary">C${i + 1}</span>
                              <span class="num c-secondary">${v < 10 ? tf('%.1f W', v) : tf('%.0f W', v)}</span>
                            </span>`
                          : null,
                      )
                    : null}
                </div>
              </div>
              <div class="hero__rule"></div>
              <div class="instruments">
                ${sideBySide
                  ? html`<div class="instruments__row">
                      <div class="instruments__twin">${twin(instrumentHeight)}</div>
                      <div class="instruments__inspector">${inspectorView}</div>
                    </div>`
                  : html`<div class="instruments__stack">${twin(270)}${inspectorView}</div>`}
              </div>
              <div class="hero__rule"></div>
              <div class="timeline">
                <div class="timeline__head">
                  <span class="t-label c-secondary">${t('功率时间线')}</span>
                  <span class="timeline__spacer"></span>
                  <span class="t-micro c-tertiary timeline__hint">
                    ${selectedPort != null ? tf('总输出 + C%d', selectedPort + 1) : t('指针移到图上查看任意时刻')}
                  </span>
                  <${ScaleMenu} observedPeak=${chartPeak} preference=${state.prefs.a2687PowerChartMaximum || 0} />
                </div>
                <div class="chart-well">
                  ${history.length > 1
                    ? html`<${PowerChart}
                        history=${history}
                        selectedPort=${selectedPort}
                        scalePreference=${state.prefs.a2687PowerChartMaximum || 0}
                      />`
                    : html`<div class="chart-well__empty">
                        ${isLive(s) ? html`<span class="spinner"></span>` : null}
                        <span class="t-caption c-tertiary">
                          ${t(isLive(s) ? '正在积累功率曲线…' : '连接后开始记录功率曲线')}
                        </span>
                      </div>`}
                </div>
              </div>
            `}
      </${SlateCard}>
      ${stats && telemetry ? html`<${StatsRow} state=${state} stats=${stats} />` : null}
      <${Notices} session=${s} />
    </div>
  </div>`;
}

function relativeTime(ms) {
  const seconds = Math.round((Date.now() - ms) / 1000);
  const locale = currentLocale() === 'en' ? 'en' : 'zh-CN';
  const rtf = new Intl.RelativeTimeFormat(locale, { numeric: 'auto' });
  if (seconds < 60) return rtf.format(-seconds, 'second');
  if (seconds < 3600) return rtf.format(-Math.round(seconds / 60), 'minute');
  return rtf.format(-Math.round(seconds / 3600), 'hour');
}
