// 设备与连接: DevicesView.swift (A2687 only) with SavedChargerRow,
// DeviceRow, AddChargerSheet and CustomChargingPowerEditor, ProductStage.swift
// for the connection card's product well, and the 模型屏保 tier:
// ModelScreenSettingsSheet.swift, ModelScreenCropEditor.swift,
// ModelScreenArtwork.swift (rendered here on canvas) and CoverSyncView.swift.
// The writes and their read-back live in Go (service_devices.go).

import { html, useEffect, useLayoutEffect, useMemo, useRef, useState } from '../lib.js';
import { currentLocale, t, tf } from '../core/l10n.js';
import {
  activeDisplayName,
  activeProduct,
  canBrowseNearbyDevices,
  hasRememberedCharger,
  isBusy,
  isDelivering,
  isLive,
  isOn,
  phaseShortLabel,
  savedCharger,
  savedDisplayName,
  snapshotDisplayName,
  telemetryPort,
  totalPower,
} from '../core/model.js';
import { call, setActionMessage, setPrefs } from '../core/store.js';
import {
  ActionButton,
  Chip,
  ConnectionLadder,
  CopyIconButton,
  Icon,
  SlateCard,
  Toggle,
  confirmDialog,
  cx,
  openMenu,
} from '../ui/components.js';
import { registerIcons } from '../ui/icons.js';
import A2345Devices, { restartInitialSetup } from './devices-a2345.js';
import SignInSheet, { accountNickname } from './signin.js';

registerIcons({
  'dv-circle':
    '<svg class="ck-icon" width="1em" height="1em" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><circle cx="12" cy="12" r="9"/></svg>',
  'dv-check-circle-fill':
    '<svg class="ck-icon" width="1em" height="1em" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10" fill="currentColor"/><path d="m7.5 12.3 3 3 6-6.3" fill="none" stroke="var(--c-bg)" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  'dv-x-circle-fill':
    '<svg class="ck-icon" width="1em" height="1em" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10" fill="currentColor"/><path d="m8.5 8.5 7 7m0-7-7 7" fill="none" stroke="var(--c-bg)" stroke-width="2.2" stroke-linecap="round"/></svg>',
  'dv-question-fill':
    '<svg class="ck-icon" width="1em" height="1em" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10" fill="currentColor"/><path d="M9.6 9.3a2.5 2.5 0 0 1 4.9.7c0 1.7-2.5 2.2-2.5 3.6" fill="none" stroke="var(--c-bg)" stroke-width="2" stroke-linecap="round"/><circle cx="12" cy="16.9" r="1.2" fill="var(--c-bg)"/></svg>',
  'dv-photo-stack':
    '<svg class="ck-icon" width="1em" height="1em" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="7" width="15" height="13" rx="2"/><path d="M7 4h12a2 2 0 0 1 2 2v10"/><path d="m3 17 4-4 4 4 3-3 4 4"/></svg>',
  'dv-play':
    '<svg class="ck-icon" width="1em" height="1em" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M4.5 2.6v10.8a.6.6 0 0 0 .9.5l8.6-5.4a.6.6 0 0 0 0-1L5.4 2.1a.6.6 0 0 0-.9.5Z"/></svg>',
  'dv-lock':
    '<svg class="ck-icon" width="1em" height="1em" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M7 10V7.5a5 5 0 0 1 10 0V10h.5A1.5 1.5 0 0 1 19 11.5v8a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 5 19.5v-8A1.5 1.5 0 0 1 6.5 10H7Zm2 0h6V7.5a3 3 0 0 0-6 0V10Z"/></svg>',
});

const PLACEHOLDER = '—';
const NEARBY_ROW_HEIGHT = 48;
const NEARBY_LIST_MAX = 280;

// ---- Labels (DevicesView's static helpers) ---------------------------------------------

const LANGUAGES = [
  ['0', 'English'],
  ['1', '简体中文'],
  ['2', '日本語'],
  ['3', 'Deutsch'],
];
const TIMEOUTS = [
  ['0', '30 秒'],
  ['1', '1 分钟'],
  ['2', '5 分钟'],
  ['3', '30 分钟'],
  ['4', '12 小时'],
];
const ORIENTATIONS = [
  ['0', '向上'],
  ['1', '向左'],
  ['2', '向下'],
  ['3', '向右'],
];
const ALLOCATIONS = [
  ['0', 'C1 口优先'],
  ['1', '双笔电模式'],
];

const label = (list, value) => {
  const hit = list.find(([v]) => v === String(value));
  if (!hit) return PLACEHOLDER;
  return list === LANGUAGES ? hit[1] : t(hit[1]);
};

function chargingModeLabel(code) {
  switch (code) {
    case 0:
      return t('AI 模式 2.0');
    case 1:
      return t('标准模式');
    case 2:
      return t('自定义模式');
    default:
      return `Unknown (0x${Number(code).toString(16).toUpperCase().padStart(2, '0')})`;
  }
}

function settingSummary(key, value) {
  switch (key) {
    case 'language':
      return tf('设备语言：%@', label(LANGUAGES, value));
    case 'screenTimeout':
      return tf('自动锁屏：%@', label(TIMEOUTS, value));
    case 'brightness':
      return tf('屏幕亮度：%d%%', Number(value));
    case 'orientation':
      return tf('屏幕方向：%@', label(ORIENTATIONS, value));
    case 'gyroscope':
      return tf('自动旋转：%@', value === 'true' ? t('开') : t('关'));
    case 'fixedAllocation':
      return tf('固定分配：%@', label(ALLOCATIONS, value));
    default:
      return key;
  }
}

/** Redact.identifier */
function redactIdentifier(value) {
  if (!value) return PLACEHOLDER;
  if (value.length <= 8) return '•'.repeat(value.length);
  return `${value.slice(0, 4)}…${value.slice(-4)}`;
}

function relativeTime(ms) {
  const locale = currentLocale() === 'en' ? 'en' : 'zh-CN';
  const rtf = new Intl.RelativeTimeFormat(locale, { numeric: 'auto' });
  const diff = (ms - Date.now()) / 1000;
  const abs = Math.abs(diff);
  if (abs < 60) return rtf.format(Math.round(diff), 'second');
  if (abs < 3600) return rtf.format(Math.round(diff / 60), 'minute');
  if (abs < 86400) return rtf.format(Math.round(diff / 3600), 'hour');
  if (abs < 86400 * 30) return rtf.format(Math.round(diff / 86400), 'day');
  if (abs < 86400 * 365) return rtf.format(Math.round(diff / (86400 * 30)), 'month');
  return rtf.format(Math.round(diff / (86400 * 365)), 'year');
}

// ---- AppModel predicates -----------------------------------------------------------------

function peripheralId(state) {
  return state.devices?.peripheralId || state.session.device?.id || null;
}

/** Connected or mid-handshake, rather than merely the charger last in use. */
function isLinked(session) {
  return session.phase === 'polling' || session.phase === 'handshake';
}

function chargerSettingBlocker(state) {
  if (!isLive(state.session)) return t('需要先连上充电器');
  let version = (state.session.device?.firmware || '').trim().toLowerCase();
  if (version.startsWith('v')) version = version.slice(1);
  if (version !== '0.0.5.2') return t('这些写入目前只在固件 v0.0.5.2 上验证过');
  return null;
}

function chargingModeBlocker(state) {
  return isLive(state.session) ? null : t('需要先连上充电器');
}

function isChangingSetting(state) {
  const o = state.devices?.settingChange?.outcome;
  return o === 'sending' || o === 'reconnecting';
}

function isSwitchingMode(state) {
  return state.devices?.modeChange?.outcome === 'sending';
}

function chargerSwitchBlocker(state) {
  if (state.devices?.coverPush?.phase === 'running') return t('正在推送屏保，完成后再切换');
  if (isChangingSetting(state)) return t('正在写入设备设置，完成后再切换');
  if (isSwitchingMode(state)) return t('正在切换充电模式，完成后再切换');
  return null;
}

function coverPushBlocker(state) {
  if (state.prefs.demoMode) return t('演示模式里没有真实充电器可以写入');
  if (!isLive(state.session)) return t('需要先连上充电器');
  return null;
}

/** Shows a Go refusal (a Chinese source key) as the action message. */
function run(method, ...args) {
  return call(method, ...args).catch((err) => {
    setActionMessage(t(String(err?.message || err)));
  });
}

// ---- Small pieces ------------------------------------------------------------------------------

export function Spinner({ size = 12 }) {
  return html`<span class="dv-spinner" style=${{ width: `${size}px`, height: `${size}px` }} aria-hidden="true"></span>`;
}

/** A GhostButtonStyle Menu label: value + chevrons. */
export function SettingMenu({ text, items, disabled, help, label: aria }) {
  return html`<${ActionButton}
    class="dv-setting-menu"
    disabled=${disabled}
    help=${help}
    aria-label=${aria}
    onClick=${(e) => openMenu(e.currentTarget, typeof items === 'function' ? items() : items, { align: 'end' })}
  >
    <span>${text}</span><${Icon} name="chevron.up.chevron.down" class="dv-setting-menu__chevron" />
  </${ActionButton}>`;
}

export function Hairline({ vertical }) {
  return html`<div class=${vertical ? 'dv-vline' : 'dv-hline'}></div>`;
}

/** A floating panel under its anchor (SwiftUI .popover). */
export function Popover({ anchor, onClose, width, children }) {
  const ref = useRef(null);
  const [pos, setPos] = useState(null);
  useLayoutEffect(() => {
    if (!anchor) return;
    const r = anchor.getBoundingClientRect();
    const el = ref.current;
    const w = el.offsetWidth;
    const h = el.offsetHeight;
    let left = r.left + r.width / 2 - w / 2;
    left = Math.min(Math.max(8, left), window.innerWidth - w - 8);
    let top = r.bottom + 8;
    if (top + h > window.innerHeight - 8) top = Math.max(8, r.top - h - 8);
    setPos({ left, top });
  }, [anchor]);
  useEffect(() => {
    const outside = (e) => {
      if (ref.current && !ref.current.contains(e.target)) onClose();
    };
    const key = (e) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        onClose();
      }
    };
    const timer = setTimeout(() => document.addEventListener('pointerdown', outside, true));
    document.addEventListener('keydown', key, true);
    return () => {
      clearTimeout(timer);
      document.removeEventListener('pointerdown', outside, true);
      document.removeEventListener('keydown', key, true);
    };
  }, [onClose]);
  return html`<div
    ref=${ref}
    class="dv-popover"
    style=${{ width: `${width}px`, left: `${pos?.left ?? -9999}px`, top: `${pos?.top ?? -9999}px` }}
  >
    ${children}
  </div>`;
}

/** A sheet over the window (SwiftUI .sheet). */
function Sheet({ width, onClose, children, class: className }) {
  useEffect(() => {
    const key = (e) => {
      if (e.key === 'Escape' && onClose) {
        e.preventDefault();
        onClose();
      }
    };
    document.addEventListener('keydown', key);
    return () => document.removeEventListener('keydown', key);
  }, [onClose]);
  return html`<div class="dialog-backdrop dv-sheet-backdrop">
    <div class=${cx('dv-sheet', className)} role="dialog" style=${{ width: `${width}px` }}>${children}</div>
  </div>`;
}

/** A Slider: the filled part of the track is the accent. */
export function Slider({ value, min, max, step = 'any', disabled, onInput, onChange, label: aria, class: className }) {
  const fill = ((value - min) / (max - min)) * 100;
  return html`<input
    type="range"
    class=${cx('dv-slider', className)}
    min=${min}
    max=${max}
    step=${step}
    value=${value}
    disabled=${disabled}
    aria-label=${aria}
    style=${{ '--fill': `${Math.max(0, Math.min(100, fill))}%` }}
    onInput=${(e) => onInput?.(Number(e.currentTarget.value))}
    onChange=${(e) => onChange?.(Number(e.currentTarget.value))}
  />`;
}

function Checkbox({ checked, onChange, children }) {
  return html`<label class="dv-checkbox">
    <input type="checkbox" checked=${checked} onChange=${(e) => onChange(e.currentTarget.checked)} />
    <span class="dv-checkbox__box"><${Icon} name="checkmark" /></span>
    <span>${children}</span>
  </label>`;
}

// ---- Product stage (ProductStage.swift) ------------------------------------------------------

// Port mouths on the 1822x2000 render, as fractions of the image.
const PORT_SLOTS = [
  { x: 0.75, y: 0.546, w: 0.064, tilt: 5 },
  { x: 0.736, y: 0.674, w: 0.066, tilt: 6 },
  { x: 0.733, y: 0.798, w: 0.068, tilt: 7 },
];

function ProductStage({ state, height }) {
  const session = state.session;
  const active = isLive(session);
  const width = height * 0.91;
  const lights = ['C1', 'C2', 'C3'].map((port) => {
    const p = telemetryPort(state, port);
    return { lit: active && isDelivering(p), watts: p && isOn(p) ? p.power : 0 };
  });
  const lit = lights.map((l, i) => (l.lit ? `C${i + 1}` : null)).filter(Boolean);
  const summary = !active
    ? t('未连接')
    : lit.length
      ? tf('%@ 正在输出', lit.join(t('、')))
      : t('没有端口在输出');
  return html`<div
    class="dv-stage"
    style=${{ width: `${height * 1.1}px`, '--h': `${height}px` }}
    role="img"
    aria-label=${`${t('充电器实拍图')}, ${summary}`}
  >
    <div class="dv-stage__shadow" style=${{ width: `${width * 0.78}px`, height: `${height * 0.085}px`, bottom: `${height * 0.255 + height * 0.26 - 1}px` }}></div>
    <div class=${cx('dv-stage__art', !active && 'is-asleep')} style=${{ width: `${width}px`, height: `${height}px` }}>
      <img src="assets/models/a2687-hero.png" alt="" draggable="false" />
      ${PORT_SLOTS.map((slot, i) => {
        const l = lights[i];
        const brightness = l.lit ? Math.min(1, 0.55 + 0.45 * Math.min(1, l.watts / 100)) : 0;
        const w = width * slot.w;
        return html`<span
          class="dv-stage__port"
          style=${{
            left: `${slot.x * 100}%`,
            top: `${slot.y * 100}%`,
            width: `${w}px`,
            height: `${w * 0.3}px`,
            opacity: brightness,
            transform: `translate(-50%, -50%) rotate(${slot.tilt}deg)`,
          }}
        ></span>`;
      })}
    </div>
    <div class="dv-stage__reflection" style=${{ width: `${width}px`, height: `${height * 0.26}px`, opacity: active ? 0.14 : 0.08 }}>
      <img src="assets/models/a2687-hero.png" alt="" draggable="false" style=${{ height: `${height}px` }} />
    </div>
  </div>`;
}

// ---- Demo banner -----------------------------------------------------------------------------------

function DemoModeCard({ onChooseAnother }) {
  return html`<${SlateCard} class="dv-card">
    <div class="dv-demo">
      <span class="dv-demo__badge"><${Icon} name="dv-play" /></span>
      <span class="t-label c-primary">${t('正在使用模拟设备')}</span>
      <span class="dv-spacer"></span>
      <${ActionButton} emphasis="quiet" title=${t('选择其他充电器')} onClick=${onChooseAnother} />
      <${ActionButton} title=${t('退出模拟')} onClick=${() => setPrefs({ demoMode: false })} />
    </div>
  </${SlateCard}>`;
}

// ---- Current connection ----------------------------------------------------------------------------

function CurrentCard({ state, onChooseAnother, onForget }) {
  const session = state.session;
  const pid = peripheralId(state);
  const switchBlocker = chargerSwitchBlocker(state);
  const device = session.device;
  const serial = device?.serial || '';
  let conflicting = null;
  if (!state.prefs.demoMode && device?.name && serial) {
    const advertised = device.name.trim();
    const [longer, shorter] = advertised.length >= serial.length ? [advertised, serial] : [serial, advertised];
    if (advertised && !longer.toLowerCase().startsWith(shorter.toLowerCase())) conflicting = advertised;
  }
  const menu = (e) =>
    openMenu(
      e.currentTarget,
      [
        { title: t('选择其他充电器'), action: onChooseAnother },
        { separator: true },
        {
          title: t('忘记这台充电器'),
          destructive: true,
          disabled: !pid || !!switchBlocker,
          action: () => onForget(pid),
        },
      ],
      { align: 'end' },
    );
  return html`<${SlateCard} class="dv-card">
    <div class="dv-stack dv-gap-l dv-pad-bottom">
      <div class="dv-header">
        <span class="t-heading c-primary">${t('当前连接')}</span>
        <span class="dv-spacer"></span>
        <${ActionButton} icon="arrow.clockwise" title=${t('重新连接')} onClick=${() => run('Reconnect')} />
        <button
          class="dv-more"
          disabled=${!pid}
          title=${t('更多设备操作')}
          aria-label=${t('更多设备操作')}
          onClick=${menu}
        >
          <${Icon} name="ellipsis" />
        </button>
      </div>
      <div class="dv-current">
        <div class="dv-current__well"><${ProductStage} state=${state} height=${136} /></div>
        <div class="dv-current__details">
          <div class="dv-stack dv-gap-s">
            <span class="t-title c-primary dv-name">${activeDisplayName(state) ?? PLACEHOLDER}</span>
            <${ConnectionLadder} session=${session} />
          </div>
          <div class="dv-meta">
            <div class="dv-meta__row">
              <div class="dv-meta__cell">
                <span class="t-micro c-tertiary">${t('BLE 版本')}</span>
                <span
                  class="dv-meta__value num"
                  title=${t('充电器握手时报告的 BLE / 设备版本号。官方 App 显示的版本号属于另一套体系，两者不能直接比较。')}
                  >${device?.firmware || PLACEHOLDER}</span
                >
              </div>
              <${Hairline} vertical />
              <div class="dv-meta__cell">
                <span class="t-micro c-tertiary">${t('蓝牙地址')}</span>
                <span class="dv-meta__value num">${device?.mac || PLACEHOLDER}</span>
              </div>
            </div>
            <${Hairline} />
            <div class="dv-meta__cell dv-meta__serial">
              <span class="t-micro c-tertiary">${t('序列号')}</span>
              <div class="dv-row dv-gap-s">
                ${serial
                  ? html`<span class="dv-meta__value num" title=${t('完整序列号；导出诊断时仍然隐藏')}>${serial}</span>
                      <span class="dv-spacer"></span>
                      <${CopyIconButton} value=${serial} help="复制完整序列号" />`
                  : html`<span class="dv-meta__value num">${PLACEHOLDER}</span>`}
              </div>
            </div>
          </div>
        </div>
      </div>
      ${conflicting
        ? html`<div
            class="dv-row dv-gap-xs dv-advertised"
            title=${t('这台充电器的广播名通常就是它的序列号。两者对不上时，握手读到的信息可能来自另一台设备。')}
          >
            <${Icon} name="questionmark.circle" />
            <span class="t-caption c-tertiary">${tf('广播名 %@ 与序列号不一致', redactIdentifier(conflicting))}</span>
          </div>`
        : null}
    </div>
  </${SlateCard}>`;
}

// ---- Device settings ------------------------------------------------------------------------------

function useBrightnessDraft(state) {
  const current = state.session.telemetry?.settings?.screenBrightness;
  const clamp = (v) => Math.min(100, Math.max(25, v));
  const [draft, setDraft] = useState(current != null ? clamp(current) : 100);
  const editing = useRef(false);
  useEffect(() => {
    if (!editing.current && current != null) setDraft(clamp(current));
  }, [current]);
  return [draft, setDraft, editing, current];
}

function DeviceSettingsCard({ state }) {
  const dv = state.devices || {};
  const settings = state.session.telemetry?.settings || null;
  const blocker = chargerSettingBlocker(state);
  const changing = isChangingSetting(state);
  const switchingMode = isSwitchingMode(state);
  const controlsDisabled = !!blocker || changing || switchingMode;
  const change = dv.settingChange;
  const pending = change && (change.outcome === 'sending' || change.outcome === 'reconnecting') ? change : null;
  const pendingValue = (key) => (pending && pending.key === key ? pending.value : null);
  const write = (key, value) => run('ChangeChargerSetting', key, String(value));

  const timeout = pendingValue('screenTimeout') ?? settings?.screenTimeout ?? null;
  const orientation = pendingValue('orientation') ?? settings?.screenOrientation ?? null;
  const gyroPending = pendingValue('gyroscope');
  const gyro = gyroPending != null ? gyroPending === 'true' : (settings?.gyroscopeEnabled ?? null);

  const [draft, setDraft, editing, currentBrightness] = useBrightnessDraft(state);
  const percent = Math.min(100, Math.max(25, Math.round(draft)));
  const brightnessChanged = currentBrightness !== percent;

  let note = null;
  if (change) {
    const summary = settingSummary(change.key, change.value);
    switch (change.outcome) {
      case 'sending':
        note = { text: tf('正在写入「%@」…', summary), tone: 'c-secondary' };
        break;
      case 'reconnecting':
        note = { text: tf('充电器已接受「%@」，正在重新连接并回读…', summary), tone: 'c-secondary' };
        break;
      case 'confirmed':
        note = { text: tf('「%@」已写入，并通过重新连接回读确认。', summary), tone: 'c-ok' };
        break;
      case 'accepted':
        note = { text: tf('充电器已接受「%@」。这个设置没有可读取的回读字段。', summary), tone: 'c-ok' };
        break;
      case 'unconfirmed':
        note = {
          text: tf('充电器已接受「%@」，但重新连接后的值没有确认变化；请先查看设备，不要连续重试。', summary),
          tone: 'c-warn',
        };
        break;
      default:
        note = { text: t(change.reason || '操作没有完成。'), tone: 'c-danger' };
    }
  } else if (blocker) {
    note = { text: blocker, tone: 'c-tertiary' };
  }

  const menuItems = (list, current, key) =>
    list.map(([value, text]) => ({
      title: list === LANGUAGES ? text : t(text),
      checked: current == null ? undefined : String(current) === value,
      action: () => {
        if (current != null && String(current) === value) return;
        write(key, value);
      },
    }));

  const languageText = pendingValue('language') != null ? label(LANGUAGES, pendingValue('language')) : t('选择…');
  const allocationText =
    pendingValue('fixedAllocation') != null ? label(ALLOCATIONS, pendingValue('fixedAllocation')) : t('选择…');

  return html`<${SlateCard} class="dv-card">
    <div class="dv-stack dv-gap-m dv-pad-bottom">
      <div class="dv-header dv-gap-s">
        <span class="t-heading c-primary">${t('设备设置')}</span>
        <${Chip} text=${t('上次连接时的值')} title=${t('在充电器上改过设置后，重新连接才会更新。')} />
        <span class="dv-spacer"></span>
        <${ActionButton} title=${t('重新连接以刷新')} onClick=${() => run('Reconnect')} />
      </div>
      <div class="dv-stack dv-gap-m">
        <div class="dv-setting">
          <span class="t-body c-secondary">${t('设备语言')}</span>
          <span class="dv-spacer"></span>
          <${SettingMenu}
            text=${languageText}
            disabled=${controlsDisabled}
            help=${blocker ?? t('语言没有可读取的设置字段，写入后请以充电器屏幕为准。')}
            items=${() =>
              LANGUAGES.map(([value, text]) => ({ title: text, action: () => write('language', value) }))}
          />
        </div>
        <div class="dv-setting">
          <span class="t-body c-secondary">${t('自动锁屏')}</span>
          <span class="dv-spacer"></span>
          ${timeout == null
            ? html`<span class="t-label c-primary">${PLACEHOLDER}</span>`
            : html`<${SettingMenu}
                text=${label(TIMEOUTS, timeout)}
                disabled=${controlsDisabled}
                items=${() => menuItems(TIMEOUTS, timeout, 'screenTimeout')}
              />`}
        </div>
        <div class="dv-setting dv-gap-m" title=${blocker ?? t('固件会把低于 25% 的值自动调整为 25%，所以滑杆从 25% 开始。')}>
          <span class="t-body c-secondary dv-brightness__label">${t('屏幕亮度')}</span>
          <${Slider}
            class="dv-brightness__slider"
            value=${draft}
            min=${25}
            max=${100}
            disabled=${controlsDisabled || currentBrightness == null}
            label=${t('屏幕亮度')}
            onInput=${(v) => {
              editing.current = true;
              setDraft(v);
            }}
            onChange=${() => {
              editing.current = false;
            }}
          />
          <span class="dv-brightness__value num">${`${percent}%`}</span>
          <${ActionButton}
            title=${t('应用')}
            disabled=${controlsDisabled || currentBrightness == null || !brightnessChanged}
            onClick=${() => write('brightness', percent)}
          />
        </div>
        <div class="dv-setting">
          <span class="t-body c-secondary">${t('自动旋转')}</span>
          <span class="dv-spacer"></span>
          ${gyro == null
            ? html`<span class="t-label c-primary">${PLACEHOLDER}</span>`
            : html`<${Toggle}
                small
                on=${gyro}
                disabled=${controlsDisabled}
                label=${t('自动旋转')}
                onChange=${(on) => write('gyroscope', on ? 'true' : 'false')}
              />`}
        </div>
        <div class="dv-setting">
          <span class="t-body c-secondary">${t('屏幕方向')}</span>
          <span class="dv-spacer"></span>
          ${orientation == null
            ? html`<span class="t-label c-primary">${PLACEHOLDER}</span>`
            : html`<${SettingMenu}
                text=${label(ORIENTATIONS, orientation)}
                disabled=${controlsDisabled}
                items=${() => menuItems(ORIENTATIONS, orientation, 'orientation')}
              />`}
        </div>
        <span class="t-caption c-tertiary para dv-note">${t('手动设置方向后自动旋转暂停，重新通电后恢复。')}</span>
      </div>
      ${note
        ? html`<div class="dv-row dv-gap-xs dv-note-row" key=${note.text}>
            ${changing ? html`<${Spinner} />` : null}
            <span class=${cx('t-caption para dv-note', note.tone)}>${note.text}</span>
          </div>`
        : null}
      <${Hairline} />
      <${ChargingModeRow} state=${state} />
      ${settings?.chargingMode === 1
        ? html`<div class="dv-setting">
            <span class="t-body c-secondary">${t('固定分配')}</span>
            <span class="dv-spacer"></span>
            <${SettingMenu}
              text=${allocationText}
              disabled=${controlsDisabled}
              items=${() =>
                ALLOCATIONS.map(([value, text]) => ({ title: t(text), action: () => write('fixedAllocation', value) }))}
            />
          </div>`
        : null}
    </div>
  </${SlateCard}>`;
}

function ChargingModeRow({ state }) {
  const dv = state.devices || {};
  const current = state.session.telemetry?.settings?.chargingMode ?? null;
  const blocker = chargingModeBlocker(state);
  const switching = isSwitchingMode(state);
  const [editor, setEditor] = useState(null);
  const disabled = !!blocker || switching || isChangingSetting(state);
  const text = current == null ? PLACEHOLDER : chargingModeLabel(current);

  let note = null;
  const change = dv.modeChange;
  if (change) {
    const mode = chargingModeLabel(change.mode);
    switch (change.outcome) {
      case 'sending':
        note = { text: tf('正在切到「%@」…', mode), tone: 'c-secondary' };
        break;
      case 'confirmed':
        note = { text: tf('已经切到「%@」', mode), tone: 'c-ok' };
        break;
      case 'unconfirmed':
        note = {
          text: tf('「%@」已经发给充电器了，这次连接里还看不到变化。重新连接后再看这一行。', mode),
          tone: 'c-warn',
        };
        break;
      default:
        note = { text: t(change.reason || '操作没有完成。'), tone: 'c-danger' };
    }
  } else if (blocker) {
    note = { text: blocker, tone: 'c-tertiary' };
  } else if (current != null) {
    note = { text: t('切换时正在充电的设备可能短暂断电。'), tone: 'c-tertiary' };
  }

  const option = (code, anchor) => ({
    title: chargingModeLabel(code),
    checked: current === code,
    action: () => {
      if (code === 2) setEditor(anchor);
      else if (code !== current) run('ChangeChargingMode', code);
    },
  });
  return html`<div class="dv-stack dv-gap-xs">
    <div class="dv-setting">
      <span class="t-body c-secondary">${t('充电模式')}</span>
      <span class="dv-spacer"></span>
      ${switching ? html`<${Spinner} />` : null}
      ${current == null
        ? html`<span class="t-label c-primary">${text}</span>`
        : html`<${ActionButton}
            class="dv-setting-menu"
            disabled=${disabled}
            help=${blocker ?? t('切换时正在充电的设备可能短暂断电。')}
            aria-label=${t('充电模式')}
            onClick=${(e) => {
              const anchor = e.currentTarget;
              openMenu(
                anchor,
                [option(0, anchor), option(1, anchor), { separator: true }, { header: t('可能不生效') }, option(2, anchor)],
                { align: 'end' },
              );
            }}
          >
            <span>${text}</span><${Icon} name="chevron.up.chevron.down" class="dv-setting-menu__chevron" />
          </${ActionButton}>`}
    </div>
    ${note ? html`<span class=${cx('t-caption para dv-note', note.tone)} key=${note.text}>${note.text}</span>` : null}
    ${editor
      ? html`<${Popover} anchor=${editor} width=${300} onClose=${() => setEditor(null)}>
          <${CustomChargingPowerEditor}
            cancel=${() => setEditor(null)}
            apply=${(autoExit, watts) => {
              setEditor(null);
              run('ChangeCustomChargingMode', autoExit, watts[0], watts[1], watts[2]);
            }}
          />
        </${Popover}>`
      : null}
  </div>`;
}

/** C1-C3 limits for custom mode: each 0 or 15-140 W, at most 160 W together. */
function CustomChargingPowerEditor({ apply, cancel }) {
  const [watts, setWatts] = useState([60, 60, 40]);
  const [autoExit, setAutoExit] = useState(false);
  const snap = (value) => {
    if (value <= 0) return 0;
    if (value < 15) return value < 8 ? 0 : 15;
    return Math.min(140, value);
  };
  const total = watts.reduce((a, b) => a + b, 0);
  const valid = total <= 160 && watts.every((w) => w === 0 || (w >= 15 && w <= 140));
  return html`<div class="dv-stack dv-gap-m dv-custom">
    <span class="t-label c-primary">${t('自定义模式')}</span>
    ${watts.map(
      (w, i) => html`<div class="dv-row dv-gap-s">
        <span class="num dv-custom__port">C${i + 1}</span>
        <${Slider}
          value=${w}
          min=${0}
          max=${140}
          label=${`C${i + 1}`}
          onInput=${(v) => setWatts(watts.map((x, j) => (j === i ? snap(Math.round(v)) : x)))}
        />
        <span class="num dv-custom__watts">${`${w} W`}</span>
      </div>`,
    )}
    <div class="dv-row">
      <span class="t-caption c-secondary">${t('合计')}</span>
      <span class="dv-spacer"></span>
      <span class=${cx('num dv-custom__total', total > 160 && 'c-danger')}>${tf('%d / %d W', total, 160)}</span>
    </div>
    <div class="dv-row dv-gap-m">
      <div class="dv-stack dv-gap-xxs dv-grow">
        <span class="t-body c-primary">${t('自动退出')}</span>
        <span class="t-caption c-tertiary para">${t('有设备插到设为 0 W 的端口时，切回 AI 模式。')}</span>
      </div>
      <${Toggle} small on=${autoExit} label=${t('自动退出')} onChange=${setAutoExit} />
    </div>
    <div class="dv-row dv-gap-s">
      <span class="dv-spacer"></span>
      <${ActionButton} title=${t('取消')} onClick=${cancel} />
      <${ActionButton} emphasis="primary" title=${t('切换')} disabled=${!valid} onClick=${() => apply(autoExit, watts)} />
    </div>
  </div>`;
}

// ---- Saved chargers -------------------------------------------------------------------------------

function SavedChargersCard({ state, onAdd, onForget }) {
  const blocker = chargerSwitchBlocker(state);
  const session = state.session;
  const pid = peripheralId(state);
  const chargers = state.savedChargers || [];
  return html`<${SlateCard} class="dv-card">
    <div class="dv-stack dv-gap-m dv-pad-bottom">
      <div class="dv-header">
        <span class="t-heading c-primary">${t('我的充电器')}</span>
        <span class="dv-spacer"></span>
        <${ActionButton} emphasis="quiet" icon="plus" title=${t('添加充电器')} disabled=${!!blocker} onClick=${onAdd} />
      </div>
      ${blocker ? html`<span class="t-caption c-warn">${blocker}</span>` : null}
      <div class="dv-stack dv-gap-xs">
        ${chargers.map(
          (c) => html`<${SavedChargerRow}
            key=${c.id}
            charger=${c}
            isCurrent=${c.id === pid}
            status=${phaseShortLabel(session)}
            live=${isLive(session)}
            canSwitch=${!blocker}
            canForget=${!blocker || c.id !== pid}
            onForget=${() => onForget(c.id)}
          />`,
        )}
      </div>
    </div>
  </${SlateCard}>`;
}

function SavedChargerRow({ charger, isCurrent, status, live, canSwitch, canForget, onForget }) {
  const [renaming, setRenaming] = useState(null);
  const [draft, setDraft] = useState('');
  const more = useRef(null);
  const title = charger.nickname || 'Anker Prime 160W';
  const parts = [];
  if (charger.serialNumber) parts.push(charger.serialNumber);
  if (!(isCurrent && live) && charger.lastConnectedAt) {
    parts.push(tf('上次连接 %@', relativeTime(charger.lastConnectedAt)));
  }
  const commit = () => {
    run('RenameCharger', charger.id, draft);
    setRenaming(null);
  };
  return html`<div class=${cx('dv-saved', isCurrent && 'is-current')}>
    <span class=${cx('dv-saved__mark', isCurrent ? 'c-accent' : 'c-tertiary')}>
      <${Icon} name=${isCurrent ? 'dv-check-circle-fill' : 'dv-circle'} />
    </span>
    <div class="dv-saved__text">
      <span class="t-label c-primary dv-ellipsis">${title}</span>
      ${parts.length ? html`<span class="t-micro c-tertiary dv-ellipsis">${parts.join(' · ')}</span>` : null}
    </div>
    <span class="dv-spacer"></span>
    ${isCurrent
      ? html`<span class=${cx('t-micro', live ? 'c-ok' : 'c-secondary')}>${status}</span>`
      : html`<${ActionButton}
          title=${t('切换')}
          disabled=${!canSwitch}
          aria-label=${tf('切换到 %@', savedDisplayName(charger))}
          onClick=${() => run('ConnectCharger', charger.id)}
        />`}
    <button
      ref=${more}
      class="dv-saved__more"
      title=${t('重命名或忘记')}
      aria-label=${tf('%@ 的更多操作', savedDisplayName(charger))}
      onClick=${(e) =>
        openMenu(
          e.currentTarget,
          [
            {
              title: t('重命名…'),
              action: () => {
                setDraft(charger.nickname || '');
                setTimeout(() => setRenaming(more.current));
              },
            },
            { separator: true },
            { title: t('忘记这台充电器…'), destructive: true, disabled: !canForget, action: onForget },
          ],
          { align: 'end' },
        )}
    >
      <${Icon} name="ellipsis" />
    </button>
    ${renaming
      ? html`<${Popover} anchor=${renaming} width=${252} onClose=${() => setRenaming(null)}>
          <form
            class="dv-stack dv-gap-s"
            onSubmit=${(e) => {
              e.preventDefault();
              commit();
            }}
          >
            <span class="t-label c-primary">${t('给这台充电器起个名字')}</span>
            <input
              class="field"
              autofocus
              value=${draft}
              maxlength=${24}
              placeholder="Anker Prime 160W"
              aria-label=${t('充电器名称')}
              onInput=${(e) => setDraft(e.currentTarget.value.slice(0, 24))}
              ref=${(el) => el && !el.dataset.focused && ((el.dataset.focused = '1'), el.focus())}
            />
            <div class="dv-row dv-gap-s">
              <span class="dv-spacer"></span>
              <${ActionButton} type="button" title=${t('取消')} onClick=${() => setRenaming(null)} />
              <${ActionButton} type="submit" emphasis="primary" title=${t('保存')} />
            </div>
          </form>
        </${Popover}>`
      : null}
  </div>`;
}

// ---- Nearby ------------------------------------------------------------------------------------------

/** snapshot.sortedNearbyDevices: the current charger first, then signal. */
function nearbyDevices(state) {
  const s = state.session;
  const pid = peripheralId(state);
  const all = [...(s.device && s.device.id ? [s.device] : []), ...(s.nearby || [])];
  const seen = new Set();
  const list = all.filter((d) => d.id && !seen.has(d.id) && seen.add(d.id));
  return list.sort((a, b) => {
    if ((a.id === pid) !== (b.id === pid)) return a.id === pid ? -1 : 1;
    const bars = signalBars(b.rssi) - signalBars(a.rssi);
    if (bars) return bars;
    return a.id < b.id ? -1 : 1;
  });
}

function signalBars(rssi) {
  if (!rssi || rssi >= 0) return 0;
  if (rssi >= -55) return 4;
  if (rssi >= -67) return 3;
  if (rssi >= -80) return 2;
  return 1;
}

function nearbyName(state, device) {
  const saved = savedCharger(state, device.id);
  if (saved) return savedDisplayName(saved);
  if (device.id === peripheralId(state)) return snapshotDisplayName(state.session);
  return null;
}

/** Go's scan warning in the Mac's words; anything else is shown as it came. */
function scanHint(session) {
  if (session.phase !== 'scanning' || !session.warning) return null;
  if (session.warning.startsWith('no charger found')) {
    return t('还没有找到充电器。充电器被连接时会完全停止广播——请确认它已通电，且官方 Anker App 或另一台设备没有占用它。');
  }
  return null;
}

function DeviceRow({ state, device, isCurrent, isSaved, preferredName, onConnect }) {
  const bars = signalBars(device.rssi);
  const subtitle = device.rssi && device.rssi < 0 ? `${device.rssi} dBm` : t('信号强度未报告');
  return html`<div class="dv-device">
    <span class="dv-signal" aria-hidden="true">
      ${[1, 2, 3, 4].map((b) => html`<span class=${cx(b <= bars && 'is-on')} style=${{ height: `${b * 3}px` }}></span>`)}
    </span>
    <div class="dv-device__text">
      <span class="t-body c-primary dv-ellipsis">${preferredName || device.name || device.productName || PLACEHOLDER}</span>
      <span class="t-caption c-tertiary dv-ellipsis num">${subtitle}</span>
    </div>
    <span class="dv-spacer"></span>
    ${isCurrent
      ? html`<${Chip} text=${t('已连接')} tone="ok" />`
      : html`${isSaved ? html`<${Chip} text=${t('已保存')} tone="accent" />` : html`<${Chip} text=${t('充电器')} tone="accent" />`}
          <${ActionButton} title=${t('连接')} onClick=${onConnect} />`}
  </div>`;
}

function NearbyList({ state, devices, height, onConnect, currentLinked = true }) {
  const pid = peripheralId(state);
  return html`<div class="dv-nearby scroll" style=${{ height: `${height}px` }}>
    <div class="dv-stack dv-gap-xs">
      ${devices.map(
        (d) => html`<${DeviceRow}
          key=${d.id}
          state=${state}
          device=${d}
          isCurrent=${currentLinked && d.id === pid && isLinked(state.session)}
          isSaved=${!!savedCharger(state, d.id)}
          preferredName=${nearbyName(state, d)}
          onConnect=${() => onConnect(d.id)}
        />`,
      )}
    </div>
  </div>`;
}

function ScanningGlyph({ scanning }) {
  return scanning ? html`<span class="dv-scanning c-accent"><${Icon} name="dot.radiowaves.left.and.right" /></span>` : null;
}

function ScanHintRow({ hint }) {
  if (!hint) return null;
  return html`<div class="dv-row dv-gap-s dv-top">
    <span class="dv-hint-icon"><${Icon} name="exclamationmark.triangle.fill" /></span>
    <span class="t-caption c-secondary para">${hint}</span>
  </div>`;
}

function NearbyCard({ state }) {
  const s = state.session;
  const devices = nearbyDevices(state);
  const height = Math.min(Math.max(devices.length, 1) * NEARBY_ROW_HEIGHT + Math.max(devices.length - 1, 0) * 4, NEARBY_LIST_MAX);
  return html`<${SlateCard} class="dv-card">
    <div class="dv-stack dv-gap-m dv-pad-bottom">
      <div class="dv-header dv-gap-s">
        <span class="t-heading c-primary">${t('附近的蓝牙设备')}</span>
        <${ScanningGlyph} scanning=${s.scanning} />
        <span class="dv-spacer"></span>
        <${ActionButton}
          title=${t('重新扫描')}
          disabled=${!canBrowseNearbyDevices(s) || s.scanning}
          onClick=${() => run('Browse')}
        />
      </div>
      <${ScanHintRow} hint=${scanHint(s)} />
      ${devices.length === 0
        ? html`<span class="t-caption c-tertiary para">${t('尚未发现设备。请确认充电器已通电，且官方 Anker App 没有连着它。')}</span>`
        : html`<${NearbyList} state=${state} devices=${devices} height=${height} onConnect=${(id) => run('ConnectCharger', id)} />`}
    </div>
  </${SlateCard}>`;
}

/** Adding a charger: the current one is let go and everything nearby listed. */
function AddChargerSheet({ state, onClose }) {
  const s = state.session;
  const picked = useRef(false);
  const [released] = useState(() => (isLive(s) ? activeDisplayName(state) : null));
  useEffect(() => {
    run('BeginAddingCharger');
    return () => {
      if (!picked.current) run('CancelAddingCharger');
    };
  }, []);
  const devices = nearbyDevices(state).filter((d) => !(d.id === peripheralId(state) && isLinked(s)));
  return html`<${Sheet} width=${460} onClose=${onClose}>
    <div class="dv-stack dv-gap-m">
      <div class="dv-header dv-gap-s">
        <span class="t-heading c-primary">${t('添加充电器')}</span>
        <${ScanningGlyph} scanning=${s.scanning} />
        <span class="dv-spacer"></span>
        <${ActionButton}
          title=${t('重新扫描')}
          disabled=${!canBrowseNearbyDevices(s) || s.scanning}
          onClick=${() => run('Browse')}
        />
      </div>
      ${released ? html`<span class="t-caption c-secondary para">${tf('已暂时断开「%@」。', released)}</span>` : null}
      <${ScanHintRow} hint=${scanHint(s)} />
      ${devices.length === 0
        ? html`<div class="dv-add-empty"><span class="t-caption c-tertiary para">${t('尚未发现设备。请确认充电器已通电，且官方 Anker App 没有连着它。')}</span></div>`
        : html`<${NearbyList}
            state=${state}
            devices=${devices}
            height=${240}
            currentLinked=${false}
            onConnect=${(id) => {
              picked.current = true;
              run('ConnectCharger', id);
              onClose();
            }}
          />`}
      <div class="dv-row"><span class="dv-spacer"></span><${ActionButton} title=${t('取消')} onClick=${onClose} /></div>
    </div>
  </${Sheet}>`;
}

// ---- First connection ---------------------------------------------------------------------------------

function FirstConnectionCard({ state }) {
  const s = state.session;
  const step = (n, text) => html`<div class="dv-row dv-gap-s dv-step">
    <span class="dv-step__n num">${n}</span>
    <span class="t-caption c-secondary">${t(text)}</span>
  </div>`;
  return html`<${SlateCard} class="dv-card">
    <div class="dv-first">
      <div class="dv-first__figure">
        <span class=${cx('dv-radar', isBusy(s) && 'is-active')}><i></i><i></i><i></i></span>
        <img src="assets/models/a2687-hero.png" alt="" draggable="false" />
      </div>
      <div class="dv-stack dv-gap-m dv-grow">
        <div class="dv-stack dv-gap-xs">
          <span class="t-heading c-primary">${t('连接第一台充电器')}</span>
          <span class="t-caption c-tertiary para">${t('无需在 Windows 蓝牙设置里配对。')}</span>
        </div>
        <div class="dv-stack dv-gap-s">
          ${step(1, '给 Anker Prime 充电器通电')} ${step(2, '退出可能正在占用它的官方 Anker App')}
          ${step(3, '在下方选择带“充电器”标记的设备并点“连接”')}
        </div>
        <div class="dv-row dv-gap-s">
          <${ActionButton}
            emphasis="primary"
            icon="antenna.radiowaves.left.and.right"
            title=${s.scanning ? t('正在扫描…') : t('扫描附近设备')}
            disabled=${!canBrowseNearbyDevices(s) || s.scanning}
            onClick=${() => run('Browse')}
          />
          <${ActionButton} emphasis="quiet" icon="arrow.left" title=${t('重新选择型号')} onClick=${restartInitialSetup} />
        </div>
      </div>
    </div>
  </${SlateCard}>`;
}

// ---- Model screen artwork (ModelScreenArtwork.swift) -------------------------------------------------

const TEX_W = 960;
const TEX_H = 400;
const SCREEN_FRAME = { x: 294, y: 2, w: 396, h: 396 };
const SCREEN_IMAGE = { x: 306, y: 14, w: 372, h: 372 };
const MAX_ZOOM = 4;
const OFFICIAL_VIGNETTE = { red: 0, green: 0, blue: 0, strength: 0.62, innerRadius: 0.45 };
const BRAND_BLUE = 'rgb(0, 167, 225)';

function clampCrop(crop, w, h) {
  const width = Math.max(w, 1);
  const height = Math.max(h, 1);
  const zoom = Math.min(Math.max(Number.isFinite(crop.zoom) ? crop.zoom : 1, 1), MAX_ZOOM);
  const side = Math.min(width, height) / zoom;
  const hx = side / width / 2;
  const hy = side / height / 2;
  const cxv = Number.isFinite(crop.centerX) ? crop.centerX : 0.5;
  const cyv = Number.isFinite(crop.centerY) ? crop.centerY : 0.5;
  return {
    centerX: Math.min(Math.max(cxv, hx), 1 - hx),
    centerY: Math.min(Math.max(cyv, hy), 1 - hy),
    zoom,
  };
}

/** ModelScreenCrop.sourceRect, in top-left image coordinates. */
function sourceRect(crop, w, h) {
  const c = clampCrop(crop, w, h);
  const side = Math.min(w, h) / c.zoom;
  return { x: w * c.centerX - side / 2, y: h * c.centerY - side / 2, w: side, h: side };
}

function rgb(v) {
  const c = (x) => Math.round(Math.min(Math.max(Number.isFinite(x) ? x : 0, 0), 1) * 255);
  return [c(v.red), c(v.green), c(v.blue)];
}

function drawVignette(ctx, v, r) {
  if (!v || !(v.strength > 0.001) || r.w <= 0) return;
  const [R, G, B] = rgb(v);
  const strength = Math.min(Math.max(v.strength, 0), 1);
  const inner = Math.min(Math.max(Number.isFinite(v.innerRadius) ? v.innerRadius : 0.45, 0), 0.95);
  const cxp = r.x + r.w / 2;
  const cyp = r.y + r.h / 2;
  const half = Math.hypot(r.w, r.h) / 2;
  const g = ctx.createRadialGradient(cxp, cyp, 0, cxp, cyp, half);
  g.addColorStop(inner, `rgba(${R},${G},${B},0)`);
  g.addColorStop(1, `rgba(${R},${G},${B},${strength})`);
  ctx.save();
  ctx.beginPath();
  ctx.rect(r.x, r.y, r.w, r.h);
  ctx.clip();
  ctx.fillStyle = g;
  ctx.fillRect(r.x, r.y, r.w, r.h);
  ctx.restore();
}

function roundRect(ctx, r, radius) {
  ctx.beginPath();
  ctx.roundRect(r.x, r.y, r.w, r.h, radius);
}

/** customTexture: the 960x400 strip the 3D model wears. */
function renderTexture(img, crop, vignette) {
  const canvas = document.createElement('canvas');
  canvas.width = TEX_W;
  canvas.height = TEX_H;
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = 'rgba(1, 1, 1, 0.54)';
  roundRect(ctx, SCREEN_FRAME, 50);
  ctx.fill();
  ctx.save();
  roundRect(ctx, SCREEN_IMAGE, 36);
  ctx.clip();
  ctx.fillStyle = '#000';
  ctx.fillRect(SCREEN_IMAGE.x, SCREEN_IMAGE.y, SCREEN_IMAGE.w, SCREEN_IMAGE.h);
  ctx.imageSmoothingQuality = 'high';
  const s = sourceRect(crop, img.width, img.height);
  ctx.drawImage(img, s.x, s.y, s.w, s.h, SCREEN_IMAGE.x, SCREEN_IMAGE.y, SCREEN_IMAGE.w, SCREEN_IMAGE.h);
  drawVignette(ctx, vignette, SCREEN_IMAGE);
  ctx.restore();
  ctx.strokeStyle = 'rgba(0, 0, 0, 0.46)';
  ctx.lineWidth = 1.5;
  roundRect(ctx, { x: SCREEN_IMAGE.x + 0.75, y: SCREEN_IMAGE.y + 0.75, w: SCREEN_IMAGE.w - 1.5, h: SCREEN_IMAGE.h - 1.5 }, 35.25);
  ctx.stroke();
  return canvas;
}

/** deviceCoverJPEG: the bare 240x240 square the panel receives. */
function renderCover(img, crop, vignette) {
  const canvas = document.createElement('canvas');
  canvas.width = 240;
  canvas.height = 240;
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = '#000';
  ctx.fillRect(0, 0, 240, 240);
  ctx.imageSmoothingQuality = 'high';
  const s = sourceRect(crop, img.width, img.height);
  ctx.drawImage(img, s.x, s.y, s.w, s.h, 0, 0, 240, 240);
  drawVignette(ctx, vignette, { x: 0, y: 0, w: 240, h: 240 });
  return canvas.toDataURL('image/jpeg', 0.85);
}

let ankerPrimeURL = null;
let ankerPrimePromise = null;

/** ankerPrimeTexture: the brand logo and PRIME on a clear strip. */
function ankerPrimeTexture() {
  if (ankerPrimeURL) return Promise.resolve(ankerPrimeURL);
  if (!ankerPrimePromise) {
    ankerPrimePromise = loadImage('assets/brand/Anker.svg').then((logo) => {
      const canvas = document.createElement('canvas');
      canvas.width = TEX_W;
      canvas.height = TEX_H;
      const ctx = canvas.getContext('2d');
      ctx.drawImage(logo, TEX_W / 2 - 143, 130, 286, 68);
      ctx.fillStyle = BRAND_BLUE;
      ctx.font = '600 29px "Segoe UI Variable Display", "Segoe UI", system-ui, sans-serif';
      ctx.letterSpacing = '7px';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText('PRIME', TEX_W / 2 + 3.5, 240);
      ankerPrimeURL = canvas.toDataURL('image/png');
      return ankerPrimeURL;
    });
  }
  return ankerPrimePromise;
}

function useAnkerPrime() {
  const [url, setUrl] = useState(ankerPrimeURL);
  useEffect(() => {
    if (!url) ankerPrimeTexture().then(setUrl, () => {});
  }, []);
  return url;
}

function loadImage(src) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error('image'));
    img.src = src;
  });
}

/** ModelScreenSquare: just the picture, square, out of the texture strip. */
function ScreenSquare({ texture, side, radius, class: className }) {
  const scale = side / SCREEN_IMAGE.w;
  return html`<span
    class=${cx('dv-square', className)}
    style=${{
      width: `${side}px`,
      height: `${side}px`,
      borderRadius: `${radius}px`,
      backgroundImage: texture ? `url(${texture})` : 'none',
      backgroundSize: `${TEX_W * scale}px ${TEX_H * scale}px`,
      backgroundPosition: `${-SCREEN_IMAGE.x * scale}px ${-SCREEN_IMAGE.y * scale}px`,
    }}
  ></span>`;
}

// The saved pictures, fetched once per library revision.
let library = { revision: -1, items: new Map(), promise: null };

function useArtworkImages(revision) {
  const [, bump] = useState(0);
  useEffect(() => {
    if (library.revision === revision) return;
    const target = revision;
    library.promise = call('ModelScreenArtworks')
      .then((items) => {
        library = { revision: target, items: new Map((items || []).map((i) => [i.id, i])), promise: null };
        bump((n) => n + 1);
      })
      .catch(() => {});
  }, [revision]);
  return library.items;
}

const parseJSON = (raw, fallback) => {
  if (raw && typeof raw === 'object') return raw;
  try {
    return JSON.parse(raw);
  } catch {
    return fallback;
  }
};

function libraryState(state) {
  const ms = state.devices?.modelScreen || { revision: 0, artworks: [], syncedSlots: [] };
  const artworks = [...(ms.artworks || [])].sort((a, b) => a.id - b.id);
  const style = state.prefs.modelScreenStyle;
  const slot = state.prefs.modelScreenCustomSlot;
  const selected = style === 'custom' ? artworks.find((a) => a.id === slot) || null : null;
  return { ms, artworks, selected, number: selected ? artworks.indexOf(selected) + 1 : null };
}

// ---- 模型屏保 card ------------------------------------------------------------------------------------

function ModelScreenCard({ state, onOpen }) {
  const { ms, artworks, selected, number } = libraryState(state);
  const images = useArtworkImages(ms.revision);
  const prime = useAnkerPrime();
  const texture = selected ? images.get(selected.id)?.texture : prime;
  return html`<${SlateCard} class="dv-card">
    <div class="dv-stack dv-gap-m">
      <div class="dv-header">
        <span class="t-heading c-primary">${t('模型屏保')}</span>
        <span class="dv-spacer"></span>
        <${ActionButton} title=${t('设置…')} aria-label=${t('设置模型屏保')} onClick=${onOpen} />
      </div>
      <div class="dv-row dv-gap-m">
        <${ScreenSquare} texture=${texture} side=${64} radius=${6} class="dv-thumb" />
        <div class="dv-stack dv-gap-xxs">
          <span class="t-body c-primary">${selected ? tf('自定义屏保 %d', number) : 'Anker Prime'}</span>
          <span class="t-caption c-tertiary">
            ${selected ? tf('已保存 %d / 3', artworks.length) : t('默认品牌待机画面')}
          </span>
        </div>
      </div>
    </div>
  </${SlateCard}>`;
}

// ---- ModelScreenSettingsSheet -------------------------------------------------------------------------

function ModelScreenSettingsSheet({ state, onClose }) {
  const { ms, artworks, selected, number } = libraryState(state);
  const images = useArtworkImages(ms.revision);
  const prime = useAnkerPrime();
  const style = state.prefs.modelScreenStyle;
  const [crop, setCrop] = useState(null); // {targetId, image, crop, vignette}
  const [importError, setImportError] = useState(null);
  const fileInput = useRef(null);
  const destination = useRef(null);
  const selectedTexture = selected ? images.get(selected.id)?.texture : prime;

  const beginImport = (target) => {
    setImportError(null);
    destination.current = target;
    fileInput.current.value = '';
    fileInput.current.click();
  };
  const handleImport = async (file) => {
    if (!file) return;
    if (destination.current == null && artworks.length >= 3) {
      setImportError(t('最多只能添加 3 个自定义屏保'));
      return;
    }
    try {
      const image = await sourceImageFrom(file);
      setCrop({
        targetId: destination.current,
        image,
        crop: { centerX: 0.5, centerY: 0.5, zoom: 1 },
        vignette: { ...OFFICIAL_VIGNETTE },
      });
    } catch {
      setImportError(t('无法读取这张图片，请选择 PNG、JPEG、HEIC 或 WebP 文件'));
    }
  };
  const editSelected = async () => {
    const source = images.get(selected.id)?.source;
    if (!source) return;
    const image = await loadImage(source);
    setCrop({
      targetId: selected.id,
      image,
      crop: parseJSON(selected.crop, { centerX: 0.5, centerY: 0.5, zoom: 1 }),
      vignette: parseJSON(selected.vignette, { red: 0, green: 0, blue: 0, strength: 0, innerRadius: 0.45 }),
    });
  };
  const commit = async (session, newCrop, vignette) => {
    setImportError(null);
    const img = session.image;
    const safe = clampCrop(newCrop, img.width, img.height);
    const sourceCanvas = document.createElement('canvas');
    sourceCanvas.width = img.width;
    sourceCanvas.height = img.height;
    sourceCanvas.getContext('2d').drawImage(img, 0, 0);
    await run('SaveModelScreenArtwork', {
      slot: session.targetId == null ? -1 : session.targetId,
      source: sourceCanvas.toDataURL('image/png'),
      texture: renderTexture(img, safe, vignette).toDataURL('image/png'),
      cover: renderCover(img, safe, vignette),
      crop: safe,
      vignette,
    });
  };

  const choiceBg = (selectedNow) => cx('dv-choice', selectedNow && 'is-selected');
  const error = importError || (ms.error ? t(ms.error) : null);
  return html`<${Sheet} width=${560} onClose=${crop ? null : onClose}>
    <div class="dv-stack dv-gap-l dv-ms">
      <div class="dv-header">
        <span class="t-title c-primary">${t('模型屏保')}</span>
        <span class="dv-spacer"></span>
        <button class="dv-ms__close" title=${t('关闭')} aria-label=${t('关闭模型屏保设置')} onClick=${onClose}>
          <span><${Icon} name="xmark" /></span>
        </button>
      </div>
      <div class="dv-row dv-gap-xl">
        <span
          class="dv-ms__preview"
          role="img"
          aria-label=${number ? tf('当前为自定义屏保 %d', number) : t('当前为 Anker Prime 默认屏保')}
        >
          <${ScreenSquare} texture=${selectedTexture} side=${176} radius=${0} />
        </span>
        <span class="t-heading c-primary">${number ? tf('自定义屏保 %d', number) : 'Anker Prime'}</span>
      </div>
      <button
        class=${choiceBg(style !== 'custom' || !selected)}
        aria-label="Anker Prime"
        onClick=${() => setPrefs({ modelScreenStyle: 'ankerPrime' })}
      >
        <${ScreenSquare} texture=${prime} side=${58} radius=${6} class="dv-thumb" />
        <span class="t-body c-primary">Anker Prime</span>
        <span class="dv-spacer"></span>
        <${SelectionIndicator} selected=${style !== 'custom' || !selected} />
      </button>
      <div class="dv-stack dv-gap-s">
        <div class="dv-row dv-gap-s">
          <span class="t-label c-secondary">${t('自定义屏保')}</span>
          <span class="dv-spacer"></span>
          <span class="dv-count num">${`${artworks.length} / 3`}</span>
          ${artworks.length === 3 ? html`<span class="t-micro c-tertiary">${t('已满')}</span>` : null}
        </div>
        <div class="dv-grid">
          ${[0, 1, 2].map((i) => {
            if (i < artworks.length) {
              const a = artworks[i];
              const isSel = selected?.id === a.id;
              return html`<button
                class=${cx(choiceBg(isSel), 'dv-slot')}
                aria-label=${tf('自定义屏保 %d', i + 1)}
                onClick=${() => setPrefs({ modelScreenStyle: 'custom', modelScreenCustomSlot: a.id })}
              >
                <span class="dv-slot__thumb">
                  <${ScreenSquare} texture=${images.get(a.id)?.texture} side=${76} radius=${6} class="dv-thumb" />
                  ${isSel ? html`<span class="dv-slot__check"><${Icon} name="dv-check-circle-fill" /></span>` : null}
                </span>
                <span class=${cx('t-caption', isSel ? 'c-primary' : 'c-secondary')}>${tf('屏保 %d', i + 1)}</span>
              </button>`;
            }
            if (i === artworks.length) {
              return html`<button class="dv-slot dv-slot--add" aria-label=${t('添加自定义屏保')} onClick=${() => beginImport(null)}>
                <span class="dv-slot__plus"><${Icon} name="plus" /></span>
                <span class="t-caption c-secondary">${t('添加屏保')}</span>
              </button>`;
            }
            return html`<div class="dv-slot dv-slot--empty" aria-hidden="true">
              <span class="dv-slot__photo"><${Icon} name="photo" /></span>
              <span class="t-caption">${t('空位')}</span>
            </div>`;
          })}
        </div>
      </div>
      <${Hairline} />
      <${CoverSyncSection} state=${state} artwork=${selected} images=${images} />
      ${error
        ? html`<div class="dv-row dv-gap-xs c-danger t-caption"><${Icon} name="exclamationmark.triangle.fill" /><span>${error}</span></div>`
        : null}
      <div class="dv-row dv-gap-s dv-ms__actions">
        ${selected
          ? html`<${ActionButton} title=${t('更换图片…')} onClick=${() => beginImport(selected.id)} />
              ${selected.hasSource ? html`<${ActionButton} title=${t('编辑裁剪与暗角')} onClick=${editSelected} />` : null}
              <${ActionButton} emphasis="destructive" title=${t('移除')} onClick=${() => run('RemoveModelScreenArtwork', selected.id)} />`
          : artworks.length < 3
            ? html`<${ActionButton} title=${t('添加屏保…')} onClick=${() => beginImport(null)} />`
            : null}
        <span class="dv-spacer"></span>
        <${ActionButton} emphasis="primary" title=${t('完成')} onClick=${onClose} />
      </div>
      <input
        ref=${fileInput}
        type="file"
        accept="image/*"
        hidden
        onChange=${(e) => handleImport(e.currentTarget.files?.[0])}
      />
    </div>
    ${crop
      ? html`<${CropEditor}
          session=${crop}
          synced=${crop.targetId != null && (ms.syncedSlots || []).includes(crop.targetId)}
          onCancel=${() => setCrop(null)}
          onApply=${(c, v) => {
            const session = crop;
            setCrop(null);
            commit(session, c, v);
          }}
        />`
      : null}
  </${Sheet}>`;
}

function SelectionIndicator({ selected }) {
  return html`<span class=${cx('dv-indicator', selected && 'is-selected')}>
    <${Icon} name=${selected ? 'dv-check-circle-fill' : 'dv-circle'} />
  </span>`;
}

/** ModelScreenArtwork.sourceImage: decoded and capped at 2048 px. */
async function sourceImageFrom(file) {
  const url = URL.createObjectURL(file);
  try {
    const img = await loadImage(url);
    if (!img.width || !img.height) throw new Error('empty');
    const scale = Math.min(1, 2048 / Math.max(img.width, img.height));
    if (scale === 1) return img;
    const canvas = document.createElement('canvas');
    canvas.width = Math.round(img.width * scale);
    canvas.height = Math.round(img.height * scale);
    const ctx = canvas.getContext('2d');
    ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
    return canvas;
  } finally {
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
}

// ---- ModelScreenCropEditor -----------------------------------------------------------------------------

const VIGNETTE_PRESETS = [
  { name: '黑', red: 0, green: 0, blue: 0 },
  { name: '白', red: 1, green: 1, blue: 1 },
  { name: '深蓝', red: 0.04, green: 0.09, blue: 0.28 },
  { name: '青', red: 0, green: 167 / 255, blue: 225 / 255 },
  { name: '洋红', red: 0.86, green: 0.09, blue: 0.45 },
];
const MIN_STRENGTH = 0.08;
const STRENGTH_KEY = 'charker.modelScreenVignetteStrength';

function rememberedStrength() {
  try {
    const v = Number(localStorage.getItem(STRENGTH_KEY));
    if (Number.isFinite(v) && v > 0) return Math.min(Math.max(v, MIN_STRENGTH), 1);
  } catch {
    // storage unavailable
  }
  return OFFICIAL_VIGNETTE.strength;
}

function CropEditor({ session, synced, onCancel, onApply }) {
  const img = session.image;
  const viewport = 324;
  const [crop, setCrop] = useState(() => clampCrop(session.crop, img.width, img.height));
  const [vignette, setVignette] = useState(() => ({ innerRadius: 0.45, ...session.vignette }));
  const [restored, setRestored] = useState(() => (session.vignette.strength > 0.001 ? session.vignette.strength : rememberedStrength()));
  const [drag, setDrag] = useState(null);
  const enabled = vignette.strength > 0.001;
  const remember = (strength) => {
    setRestored(strength);
    try {
      localStorage.setItem(STRENGTH_KEY, String(strength));
    } catch {
      // storage unavailable
    }
  };
  const apply = (v) => {
    setVignette(v);
    if (v.strength > 0.001) remember(v.strength);
  };

  const aspect = Math.max(img.width, 1) / Math.max(img.height, 1);
  const base = aspect >= 1 ? { w: viewport * aspect, h: viewport } : { w: viewport, h: viewport / aspect };
  const size = { w: base.w * crop.zoom, h: base.h * crop.zoom };
  const clampOffset = (o) => {
    const mx = Math.max(0, (size.w - viewport) / 2);
    const my = Math.max(0, (size.h - viewport) / 2);
    return { x: Math.min(Math.max(o.x, -mx), mx), y: Math.min(Math.max(o.y, -my), my) };
  };
  const baseOffset = { x: size.w * (0.5 - crop.centerX), y: size.h * (0.5 - crop.centerY) };
  const shown = clampOffset(drag ? { x: baseOffset.x + drag.dx, y: baseOffset.y + drag.dy } : baseOffset);

  const onPointerDown = (e) => {
    e.currentTarget.setPointerCapture(e.pointerId);
    setDrag({ x0: e.clientX, y0: e.clientY, dx: 0, dy: 0 });
  };
  const onPointerMove = (e) => {
    if (!drag) return;
    setDrag({ ...drag, dx: e.clientX - drag.x0, dy: e.clientY - drag.y0 });
  };
  const onPointerUp = () => {
    if (!drag) return;
    const final = clampOffset({ x: baseOffset.x + drag.dx, y: baseOffset.y + drag.dy });
    setDrag(null);
    setCrop(clampCrop({ centerX: 0.5 - final.x / size.w, centerY: 0.5 - final.y / size.h, zoom: crop.zoom }, img.width, img.height));
  };
  const imgSrc = useMemo(() => (img instanceof HTMLCanvasElement ? img.toDataURL() : img.src), [img]);
  const [R, G, B] = rgb(vignette);
  const strength = Math.min(Math.max(vignette.strength, 0), 1);
  const inner = Math.min(Math.max(vignette.innerRadius ?? 0.45, 0), 0.95);
  const matches = (p) =>
    Math.abs(p.red - vignette.red) < 1 / 512 && Math.abs(p.green - vignette.green) < 1 / 512 && Math.abs(p.blue - vignette.blue) < 1 / 512;
  const isOfficial =
    vignette.red === 0 && vignette.green === 0 && vignette.blue === 0 && vignette.strength === OFFICIAL_VIGNETTE.strength && inner === 0.45;
  const hex = `#${[R, G, B].map((c) => c.toString(16).padStart(2, '0')).join('')}`;

  return html`<div class="dialog-backdrop dv-sheet-backdrop dv-sheet-backdrop--nested">
    <div class="dv-sheet" role="dialog" style=${{ width: '500px' }}>
      <div class="dv-stack dv-gap-l">
        <div class="dv-stack dv-gap-xs">
          <span class="t-title c-primary">${t('裁剪与暗角')}</span>
          <span class="t-caption c-tertiary">${t('拖动图片调整位置')}</span>
        </div>
        <div class="dv-row"><span class="dv-spacer"></span>
          <div class="dv-crop" role="img" aria-label=${t('方形图片裁剪区域')}>
            <div
              class="dv-crop__viewport"
              onPointerDown=${onPointerDown}
              onPointerMove=${onPointerMove}
              onPointerUp=${onPointerUp}
              onPointerCancel=${onPointerUp}
            >
              <img
                src=${imgSrc}
                alt=""
                draggable="false"
                style=${{
                  width: `${size.w}px`,
                  height: `${size.h}px`,
                  transform: `translate(${-size.w / 2 + viewport / 2 + shown.x}px, ${-size.h / 2 + viewport / 2 + shown.y}px)`,
                }}
              />
              ${enabled
                ? html`<span
                    class="dv-crop__vignette"
                    style=${{
                      background: `radial-gradient(circle ${(viewport * Math.SQRT2) / 2}px at center, rgba(${R},${G},${B},0) ${inner * 100}%, rgba(${R},${G},${B},${strength}) 100%)`,
                    }}
                  ></span>`
                : null}
              <span class="dv-crop__grid"></span>
            </div>
          </div>
        <span class="dv-spacer"></span></div>
        <div class="dv-row dv-gap-m">
          <span class="c-tertiary"><${Icon} name="minus.magnifyingglass" /></span>
          <${Slider}
            value=${crop.zoom}
            min=${1}
            max=${MAX_ZOOM}
            label=${t('图片缩放')}
            onInput=${(z) => setCrop(clampCrop({ ...crop, zoom: z }, img.width, img.height))}
          />
          <span class="c-tertiary"><${Icon} name="plus.magnifyingglass" /></span>
          <span class="num dv-crop__zoom">${tf('%.1f×', crop.zoom)}</span>
        </div>
        <${Hairline} />
        <div class="dv-stack dv-gap-s">
          <div class="dv-row dv-gap-s">
            <span class="t-label c-secondary">${t('暗角')}</span>
            <span class="dv-spacer"></span>
            <${ActionButton}
              title=${t('官方同款')}
              disabled=${isOfficial}
              help=${t('黑色，强度 0.62，和 Anker 官方 App 一样')}
              onClick=${() => apply({ ...OFFICIAL_VIGNETTE })}
            />
            <${Toggle}
              on=${enabled}
              label=${t('暗角')}
              onChange=${(on) => {
                if (on) setVignette({ ...vignette, strength: Math.max(restored, MIN_STRENGTH) });
                else {
                  remember(vignette.strength);
                  setVignette({ ...vignette, strength: 0 });
                }
              }}
            />
          </div>
          ${enabled
            ? html`<div class="dv-row dv-gap-s">
                  ${VIGNETTE_PRESETS.map(
                    (p) => html`<button
                      class=${cx('dv-swatch', matches(p) && 'is-selected')}
                      title=${t(p.name)}
                      aria-label=${tf('暗角颜色 %@', t(p.name))}
                      onClick=${() =>
                        apply({
                          red: p.red,
                          green: p.green,
                          blue: p.blue,
                          strength: Math.max(vignette.strength, MIN_STRENGTH),
                          innerRadius: vignette.innerRadius ?? 0.45,
                        })}
                    >
                      <span style=${{ background: `rgb(${rgb(p).join(',')})` }}></span>
                    </button>`,
                  )}
                  <input
                    type="color"
                    class="dv-color"
                    value=${hex}
                    aria-label=${t('自定义暗角颜色')}
                    onInput=${(e) => {
                      const v = e.currentTarget.value;
                      setVignette({
                        ...vignette,
                        red: parseInt(v.slice(1, 3), 16) / 255,
                        green: parseInt(v.slice(3, 5), 16) / 255,
                        blue: parseInt(v.slice(5, 7), 16) / 255,
                      });
                    }}
                  />
                </div>
                <div class="dv-row dv-gap-m">
                  <span class="t-caption c-tertiary">${t('强度')}</span>
                  <${Slider}
                    value=${strength}
                    min=${MIN_STRENGTH}
                    max=${1}
                    label=${t('暗角强度')}
                    onInput=${(v) => {
                      setVignette({ ...vignette, strength: v });
                      remember(v);
                    }}
                  />
                  <span class="num dv-crop__zoom">${`${Math.round(strength * 100)}%`}</span>
                </div>`
            : null}
          ${synced
            ? html`<div class="dv-resident">
                <span class="dv-hint-icon"><${Icon} name="exclamationmark.triangle.fill" /></span>
                <div class="dv-stack dv-gap-xxs">
                  <span class="t-caption c-primary">${t('这张图已经推给过充电器')}</span>
                  <span class="t-micro c-secondary">${t('改动后要重推一次才会更新到充电器。')}</span>
                </div>
              </div>`
            : null}
        </div>
        <div class="dv-row dv-gap-s">
          <${ActionButton} title=${t('居中')} onClick=${() => setCrop(clampCrop({ centerX: 0.5, centerY: 0.5, zoom: 1 }, img.width, img.height))} />
          <span class="dv-spacer"></span>
          <${ActionButton} title=${t('取消')} onClick=${onCancel} />
          <${ActionButton}
            emphasis="primary"
            title=${t('应用裁剪与暗角')}
            onClick=${() => onApply(clampCrop(crop, img.width, img.height), vignette)}
          />
        </div>
      </div>
    </div>
  </div>`;
}

// ---- CoverSyncSection (同步屏保) ---------------------------------------------------------------------

function coverMinimumSeconds(bytes) {
  const n = Math.ceil(bytes / 156);
  let checkpoints = 0;
  for (let i = 0; i < n; i++) if (i === n - 1 || (i + 1) % 10 === 0) checkpoints++;
  return Math.max(1, Math.floor(0.15 + 0.2 + 0.04 * (n - checkpoints) + 0.4));
}

function durationHint(seconds) {
  if (seconds < 7) return t('推一次大概十几秒');
  if (seconds < 21) return t('推一次大概半分钟');
  if (seconds < 46) return t('推一次大概一两分钟');
  return t('推一次大概要几分钟');
}

const REMEDY = {
  nothingWritten: ['一个字节都没写进去', '这次没有任何数据写进充电器，可以直接再来一次。'],
  interrupted: [
    '已经写进去一部分',
    '停下之前已经写进去的部分留在充电器里，没有命令能删。再推一次是从头完整传一遍，会再占一个位置。',
  ],
  lostSlices: [
    '图没有传完整',
    '写进去的是一张不完整的图，充电器不会显示它，也删不掉。再推一次是从头完整传一遍，会再占一个位置。',
  ],
  selectionDidNotTake: ['图传过去了，没看到屏幕换过来', '图已经在充电器里了，只差「显示这张」这一步，可以单独再试一次。'],
};

function stageLabel(stage) {
  switch (stage) {
    case 'starting':
      return t('正在准备…');
    case 'sending':
      return t('正在推送图片…');
    case 'verifying':
      return t('正在确认…');
    case 'finished':
      return t('已完成');
    default:
      return t('正在选图…');
  }
}

function CoverHint({ icon, tone, title, detail }) {
  return html`<div class="dv-row dv-gap-s dv-top">
    <span class=${cx('dv-cover__icon', tone)}><${Icon} name=${icon} /></span>
    <div class="dv-stack dv-gap-xxs dv-grow">
      <span class="t-body c-primary">${title}</span>
      ${detail ? html`<span class="t-caption c-secondary para">${detail}</span>` : null}
    </div>
  </div>`;
}

function CoverSyncSection({ state, artwork, images }) {
  const push = state.devices?.coverPush || { phase: 'idle' };
  const blocker = coverPushBlocker(state);
  const [confirming, setConfirming] = useState(false);
  const [ack, setAck] = useState(false);
  useEffect(() => {
    setConfirming(false);
    setAck(false);
  }, [artwork?.id]);
  const otherScreen =
    push.slot != null && push.slot !== artwork?.id
      ? html`<span class="t-micro c-tertiary">${t('这是另一张自定义屏保的推送。')}</span>`
      : null;

  let card;
  if (push.phase === 'running') {
    const p = push.progress || { stage: 'selecting', chunksSent: 0, chunkCount: 0 };
    const fraction = p.chunkCount > 0 ? Math.min(Math.max(p.chunksSent / p.chunkCount, 0), 1) : null;
    card = html`<div class="dv-stack dv-gap-s">
      <div class="dv-row dv-gap-s">
        <span class="t-body c-primary">${stageLabel(p.stage)}</span>
        <span class="dv-spacer"></span>
        ${fraction != null ? html`<span class="num dv-cover__pct">${`${Math.round(fraction * 100)}%`}</span>` : null}
      </div>
      <div class=${cx('dv-progress', fraction == null && 'is-indeterminate')}>
        <span style=${{ width: fraction != null ? `${fraction * 100}%` : '30%' }}></span>
      </div>
      ${otherScreen}
      ${p.chunkCount > 0
        ? html`<span class="t-micro c-tertiary">${t('取消撤不回已经写进去的部分。')}</span>
            <div class="dv-row">
              <${ActionButton}
                title=${push.stopping ? t('正在停…') : t('取消')}
                disabled=${push.stopping}
                onClick=${() => run('CancelCoverPush')}
              />
            </div>`
        : null}
    </div>`;
  } else if (push.phase === 'done') {
    const witnessed = push.verification === 'witnessed';
    card = html`<div class="dv-stack dv-gap-s">
      <${CoverHint}
        icon=${witnessed ? 'dv-check-circle-fill' : 'dv-question-fill'}
        tone=${witnessed ? 'c-ok' : 'c-warn'}
        title=${witnessed ? t('屏幕换过来了') : t('传完了，但确认不了屏幕换没换')}
        detail=${witnessed ? null : t('去看一眼充电器的屏幕。')}
      />
      ${otherScreen}
      <div class="dv-row"><${ActionButton} emphasis="primary" title=${t('完成')} onClick=${() => run('DismissCoverPushResult')} /></div>
    </div>`;
  } else if (push.phase === 'failed' && push.failure) {
    const f = push.failure;
    const [headline, advice] = REMEDY[f.remedy] || REMEDY.nothingWritten;
    card = html`<div class="dv-stack dv-gap-s">
      <${CoverHint}
        icon=${f.pixelsMayHaveLanded ? 'exclamationmark.triangle.fill' : 'dv-x-circle-fill'}
        tone=${f.pixelsMayHaveLanded ? 'c-warn' : 'c-danger'}
        title=${t(headline)}
        detail=${f.detail ? t(f.detail) : null}
      />
      <span class="t-micro c-tertiary para">${t(advice)}</span>
      ${f.suggestsCloudId ? html`<span class="t-micro c-tertiary para">${t('这台充电器可能只接受官方 App 推送的图。')}</span>` : null}
      ${otherScreen}
      <div class="dv-row dv-gap-s">
        ${f.remedy === 'selectionDidNotTake'
          ? html`<${ActionButton}
              emphasis="primary"
              title=${t('重新指定这张封面')}
              disabled=${!!blocker}
              onClick=${() => run('RetryCoverSelection')}
            />`
          : null}
        ${artwork
          ? html`<${ActionButton}
              title=${t('重新推一次')}
              disabled=${!!blocker}
              onClick=${() => {
                setAck(false);
                run('DismissCoverPushResult');
                setConfirming(true);
              }}
            />`
          : null}
        <${ActionButton} emphasis="quiet" title=${t('关闭')} onClick=${() => run('DismissCoverPushResult')} />
      </div>
    </div>`;
  } else if (push.phase === 'reselected') {
    card = html`<div class="dv-stack dv-gap-s">
      <${CoverHint} icon="dv-check-circle-fill" tone="c-ok" title=${t('充电器已经切到这张封面')} />
      <div class="dv-row"><${ActionButton} emphasis="primary" title=${t('完成')} onClick=${() => run('DismissCoverPushResult')} /></div>
    </div>`;
  } else if (confirming) {
    card = html`<div class="dv-stack dv-gap-s">
      <div class="dv-row dv-gap-s">
        <span class="dv-hint-icon"><${Icon} name="exclamationmark.triangle.fill" /></span>
        <span class="t-heading c-primary">${t('这一步撤不回来')}</span>
      </div>
      <span class="t-caption c-secondary para">${t('机内固定 4 个位置。推第 5 张会挤掉其中一张，不确定是哪一张。')}</span>
      <${Checkbox} checked=${ack} onChange=${setAck}><span class="t-caption c-primary">${t('我知道推上去的图删不掉')}</span></${Checkbox}>
      <div class="dv-row dv-gap-s">
        <${ActionButton}
          emphasis="destructive"
          title=${t('开始推送')}
          disabled=${!ack || !artwork}
          onClick=${() => {
            setConfirming(false);
            run('PushCover', artwork.id, ack);
          }}
        />
        <${ActionButton}
          title=${t('取消')}
          onClick=${() => {
            setConfirming(false);
            setAck(false);
          }}
        />
      </div>
    </div>`;
  } else if (!artwork) {
    card = html`<${CoverHint} icon="dv-photo-stack" tone="c-secondary" title=${t('先在上面选一张自定义屏保')} />`;
  } else if (!artwork.hasSource) {
    card = html`<${CoverHint}
      icon="exclamationmark.triangle.fill"
      tone="c-warn"
      title=${t('这张屏保没有原图')}
      detail=${t('重新导入一次就能推。')}
    />`;
  } else {
    const cover = images.get(artwork.id)?.cover;
    card = html`<div class="dv-stack dv-gap-s">
      <div class="dv-row dv-gap-m dv-top">
        <span class="dv-cover__preview" role="img" aria-label=${t('充电器屏幕预览 240 × 240')}>
          ${cover ? html`<img src=${cover} alt="" />` : null}
        </span>
        ${artwork.coverBytes ? html`<span class="t-micro c-tertiary">${durationHint(coverMinimumSeconds(artwork.coverBytes))}</span>` : null}
      </div>
      ${blocker
        ? html`<div class="dv-row dv-gap-xs t-micro c-tertiary"><${Icon} name="dv-lock" /><span class="para">${blocker}</span></div>`
        : null}
      <div class="dv-row">
        <${ActionButton}
          emphasis="primary"
          title=${t('推送到充电器…')}
          disabled=${!!blocker || !artwork.coverBytes}
          onClick=${() => {
            setAck(false);
            setConfirming(true);
          }}
        />
      </div>
    </div>`;
  }
  return html`<div class="dv-stack dv-gap-s">
    <div class="dv-row dv-gap-s">
      <span class="t-label c-secondary">${t('同步屏保')}</span>
      <span class="dv-spacer"></span>
      <span class="dv-count t-micro c-tertiary">${t('充电器实体屏')}</span>
    </div>
    <div class="dv-cover">${card}</div>
  </div>`;
}

// ---- Page --------------------------------------------------------------------------------------------------

export default function DevicesPage({ state }) {
  // DevicesView switches to A2345DevicesView when the 250W is on screen.
  if (activeProduct(state).id === 'A2345') return html`<${A2345Devices} state=${state} />`;
  return html`<${A2687Devices} state=${state} />`;
}

function A2687Devices({ state }) {
  const s = state.session;
  const demo = !!state.prefs.demoMode;
  const pid = peripheralId(state);
  const firstConnection = !demo && !hasRememberedCharger(state) && !pid;
  const [adding, setAdding] = useState(false);
  const [screenSettings, setScreenSettings] = useState(false);

  // Picker browsing lists nearby chargers when there is no charger to wait for.
  useEffect(() => {
    if (!pid && canBrowseNearbyDevices(s)) run('Browse');
  }, []);

  const [signingIn, setSigningIn] = useState(false);
  // Both connection pages share this way back to the product chooser.
  const chooseAnother = restartInitialSetup;

  const forget = async (id) => {
    const saved = savedCharger(state, id);
    const live = id === pid && isLinked(s);
    const choice = await confirmDialog({
      title: saved ? tf('忘记「%@」？', savedDisplayName(saved)) : t('忘记这台充电器？'),
      message: t(
        live
          ? '会断开它，之后不再自动连接。能耗历史和各项设置都会保留，官方 App 里的绑定不受影响。'
          : '之后不再自动连接它。能耗历史和各项设置都会保留，官方 App 里的绑定不受影响。',
      ),
      actions: [
        { title: t('取消'), role: 'cancel' },
        { title: t('忘记'), role: 'destructive', value: true },
      ],
    });
    if (choice) run('ForgetCharger', id);
  };

  return html`<div class="page scroll devices">
    <div class="page__content dv-content">
      ${firstConnection
        ? html`<${FirstConnectionCard} state=${state} /><${NearbyCard} state=${state} />`
        : html`${demo ? html`<${DemoModeCard} onChooseAnother=${chooseAnother} />` : null}
            <${CurrentCard} state=${state} onChooseAnother=${chooseAnother} onForget=${forget} />
            ${!demo && (state.savedChargers || []).length
              ? html`<${SavedChargersCard} state=${state} onAdd=${() => setAdding(true)} onForget=${forget} />`
              : null}
            <${DeviceSettingsCard} state=${state} />
            <${ModelScreenCard} state=${state} onOpen=${() => setScreenSettings(true)} />
            ${!demo
              ? html`<${AccountCard} state=${state} onSignIn=${() => setSigningIn(true)} />
                  <${NearbyCard} state=${state} />`
              : null}`}
    </div>
    ${adding ? html`<${AddChargerSheet} state=${state} onClose=${() => setAdding(false)} />` : null}
    ${screenSettings ? html`<${ModelScreenSettingsSheet} state=${state} onClose=${() => setScreenSettings(false)} />` : null}
    ${signingIn ? html`<${SignInSheet} state=${state} purpose="ownerID" onClose=${() => setSigningIn(false)} />` : null}
  </div>`;
}

// ---- Anker account (DevicesView.accountCard) --------------------------------------------------------

const isValidOwnerUserID = (value) => /^[0-9a-f]{40}$/.test(value.trim().toLowerCase());

/**
 * Hardened firmware only streams to the account that owns the charger, so
 * this id is the difference between a working app and a silent one. It is an
 * account identifier, not a password, and only goes to the charger.
 */
function AccountCard({ state, onSignIn }) {
  const saved = state.prefs.ownerUserID || '';
  // A staged copy: committing on every keystroke would rebuild the session.
  const [draft, setDraft] = useState(saved);
  const [open, setOpen] = useState(false);
  // The sign-in sheet writes the id from over this card; the draft follows.
  useEffect(() => {
    setDraft((d) => (d === saved ? d : saved));
  }, [saved]);
  const commit = (value) => {
    const normalized = value.trim().toLowerCase();
    if (normalized !== saved) setPrefs({ ownerUserID: normalized }).catch(() => {});
  };
  const nickname = accountNickname();
  // Seam: the Mac's 只读模式/身份被拒 chip and note need the session's
  // authRejected flag, which the BLE engine does not report yet.
  return html`<${SlateCard} class="dv-card">
    <div class="dv-stack dv-gap-m dv-pad-bottom">
      <div class="dv-header">
        <span class="t-heading c-primary">${t('Anker 账号 ID')}</span>
        <span class="dv-spacer"></span>
        ${isValidOwnerUserID(saved) ? html`<${Chip} text=${t('已填写')} tone="ok" />` : null}
      </div>
      <span class="t-caption c-secondary para">${t('充电器只认绑定它的 Anker 账号。')}</span>
      <div class="dv-row dv-gap-s">
        <${ActionButton} emphasis="primary" icon="person.badge.key" title=${t('用 Anker 账号获取')} onClick=${onSignIn} />
        ${nickname ? html`<span class="t-caption c-tertiary">${nickname}</span>` : null}
      </div>
      <div class=${cx('dv-disclosure', open && 'is-open')}>
        <button class="dv-disclosure__toggle t-caption c-secondary" aria-expanded=${open} onClick=${() => setOpen(!open)}>
          <${Icon} name="chevron.right" class="dv-disclosure__chevron" />
          <span>${t('或手动填写')}</span>
        </button>
        ${open
          ? html`<div class="dv-stack dv-gap-s dv-disclosure__body">
              <input
                class="field num dv-owner-field"
                placeholder=${t('40 位小写十六进制')}
                spellcheck=${false}
                autocomplete="off"
                value=${draft}
                onInput=${(e) => {
                  const value = e.currentTarget.value;
                  setDraft(value);
                  // Commit silently the moment the id becomes valid; half-typed ids stay local.
                  if (isValidOwnerUserID(value)) commit(value);
                }}
                onKeyDown=${(e) => {
                  if (e.key === 'Enter') commit(e.currentTarget.value);
                }}
              />
              ${draft && !isValidOwnerUserID(draft)
                ? html`<span class="t-caption c-warn">${t('格式不对：应为 40 个字符的十六进制字符串。')}</span>`
                : null}
              <span class="t-caption c-tertiary para">
                ${t('可用 Frida 抓安卓端 MQTT 主题 dt/anker_power/<40位hex>，或在未加密的 iOS 备份里搜同一主题。')}
              </span>
            </div>`
          : null}
      </div>
    </div>
  </${SlateCard}>`;
}
