// 设备与连接 for the Anker Prime 250W: A2345DevicesView.swift with
// A2345SettingsCards.swift (device settings, clock screensaver and its
// schedule popover, 实验室) and A2345ThemePickerSheet.swift with
// A2345PictureEncoder.swift. The engine is cloudsession (state.a2345); the
// calls live in service_account.go.

import { html, useEffect, useRef, useState } from '../lib.js';
import { t, tf, tt } from '../core/l10n.js';
import { call, selectSection, setActionMessage, setPrefs } from '../core/store.js';
import { ActionButton, Chip, Icon, Segmented, SlateCard, Toggle, confirmDialog, cx, openMenu } from '../ui/components.js';
import { Hairline, Popover, SettingMenu, Slider, Spinner } from './devices.js';
import SignInSheet from './signin.js';

const PLACEHOLDER = '—';

// a2345.Capabilities bits (internal/a2345/settings.go).
const CAP = {
  customChargingMode: 1 << 0,
  clockSchedule: 1 << 1,
  maxCompatibility: 1 << 5,
  customImageTimeDisplay: 1 << 6,
  ufcsSwitch: 1 << 8,
  deviceIdentification: 1 << 9,
  protocolManagement: 1 << 11,
};
const supports = (settings, cap) => settings?.capabilities != null && (settings.capabilities & cap) !== 0;

// The cloud phases that must not be restarted (A2345ConnectionPhase.isBusy).
const BUSY_STAGES = ['signingIn', 'loadingDevices', 'connecting', 'reconnecting'];

// The custom picture size of the clock screen (A2345PictureEncoder).
const PICTURE_W = 480;
const PICTURE_H = 200;
const PICTURE_MAX_BYTES = 98304;
const PICTURE_MIN_BYTES = 78643;
const CUSTOM_PICTURE_LIMIT = 8;

/** Shows a Go refusal as the action message. */
function run(method, ...args) {
  return call(method, ...args).catch((err) => setActionMessage(t(String(err?.message || err))));
}

/** restartInitialSetup: back to the product chooser on the dashboard. */
export function restartInitialSetup() {
  setActionMessage(null);
  return call('RestartInitialSetup')
    .then(() => selectSection('dashboard'))
    .catch((err) => setActionMessage(String(err?.message || err)));
}

function enterDemoMode() {
  call('CompleteInitialSetup', 'A2345', 'demo')
    .then(() => selectSection('dashboard'))
    .catch((err) => setActionMessage(String(err?.message || err)));
}

// ---- A2345Labels -----------------------------------------------------------------------

const MODES = [
  [1, '智能动态分配'],
  [2, '端口优先分配'],
  [3, '双笔电模式'],
  [4, '涓流模式'],
];
const TIMEOUTS = [
  [0, '常亮'],
  [1, '30 秒'],
  [2, '1 分钟'],
  [3, '5 分钟'],
  [4, '30 分钟'],
];
const KNOBS = [
  [0, '正向'],
  [1, '反向'],
];
const labelOf = (list, value) => {
  const hit = list.find(([v]) => v === value);
  return hit ? t(hit[1]) : PLACEHOLDER;
};
const builtInStyle = (kind) => tf('样式 %d', kind + 1);

function priorityText(bitmap) {
  const ports = ['C1', 'C2', 'C3', 'C4'].filter((_, i) => bitmap & (1 << i));
  return ports.length ? ports.join(t('、')) : t('无');
}

// A2345ScheduleText
const WEEKDAY_SYMBOLS = ['一', '二', '三', '四', '五', '六', '日'];
const WEEKDAY_NAMES = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
function daysText(mask) {
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
const pad2 = (n) => String(n).padStart(2, '0');
const clockScheduleText = (s) =>
  `${pad2(s.startHour)}:${pad2(s.startMinute)}–${pad2(s.endHour)}:${pad2(s.endMinute)} · ${daysText(s.weekdays)}`;

// ---- Small pieces ------------------------------------------------------------------------

/** A2345StateTone */
function stateTone(stage, stale, isDemo) {
  if (isDemo) return 'accent';
  switch (stage) {
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

/** A2345StateDot: busy phases breathe. */
function A2345StateDot({ snap, diameter = 7 }) {
  const tone = stateTone(snap.stage, snap.isStale, snap.isDemo);
  return html`<span
    class=${cx('state-dot', tone !== 'idle' && `is-${tone}`, BUSY_STAGES.includes(snap.stage) && 'is-busy')}
    style=${{ width: `${diameter}px`, height: `${diameter}px` }}
    aria-hidden="true"
  ></span>`;
}

/** A2345ProductStage: the static render, desaturated while offline. */
function A2345ProductStage({ active, height }) {
  return html`<div
    class=${cx('d5-stage', !active && 'is-asleep')}
    style=${{ height: `${height}px` }}
    role="img"
    aria-label=${`${t('Anker Prime 250W 充电器产品图')}, ${t(active ? '在线' : '未连接')}`}
  >
    <img src="assets/models/a2345-hero.png" alt="" draggable="false" />
  </div>`;
}

function ConnectionArtwork({ active, fills }) {
  return html`<div class=${cx('dv-current__well d5-well', fills && 'is-filling')}>
    <${A2345ProductStage} active=${active} height=${136} />
  </div>`;
}

/** One labelled row of a settings card (A2345Row). */
function Row({ title, help, children }) {
  return html`<div class="d5-row" title=${help}>
    <span class="t-body c-secondary">${title}</span>
    <span class="dv-spacer"></span>
    ${children}
  </div>`;
}

const plainValue = (text) => html`<span class="t-label c-primary">${text}</span>`;

// ---- Page ----------------------------------------------------------------------------------

export default function A2345Devices({ state }) {
  const snap = state.a2345 || { stage: 'idle', devices: [], a2345: {}, statusLabel: {}, statusDetail: {} };
  const x = snap.a2345 || {};
  const demo = !!snap.isDemo;
  const [signingIn, setSigningIn] = useState(false);
  const [themes, setThemes] = useState(false);
  // A2345CustomModeSheet lives with the 250W overview (overview-a2345.js);
  // loaded on demand so this page does not pull in the 3D stage.
  const [CustomModes, setCustomModes] = useState(null);
  const openCustomModes = () =>
    import('./overview-a2345.js')
      .then((m) => setCustomModes(() => m.A2345CustomModeSheet))
      .catch((err) => setActionMessage(String(err?.message || err)));
  const hasSettings = !!x.settings;

  const confirmSignOut = async () => {
    const ok = await confirmDialog({
      title: t('退出 A2345 云端连接？'),
      message: t('不会解除官方 Anker App 中的设备绑定，也不会删除本地能耗记录。'),
      actions: [
        { title: t('取消'), role: 'cancel' },
        { title: t('退出并删除本机保存的令牌'), role: 'destructive', value: true },
      ],
    });
    if (ok) {
      await run('ForgetA2345Account');
      selectSection('devices');
    }
  };

  return html`<div class="page scroll devices">
    <div class="page__content dv-content">
      ${demo
        ? html`<${SlateCard} class="dv-card">
            <div class="dv-demo">
              <span class="dv-demo__badge"><${Icon} name="dv-play" /></span>
              <span class="t-label c-primary">${t('正在使用 A2345 模拟设备')}</span>
              <span class="dv-spacer"></span>
              <${ActionButton} emphasis="quiet" title=${t('选择其他充电器')} onClick=${restartInitialSetup} />
              <${ActionButton} title=${t('退出模拟')} onClick=${() => setPrefs({ demoMode: false }).catch(() => {})} />
            </div>
          </${SlateCard}>`
        : null}
      <${CurrentConnectionCard} state=${state} snap=${snap} onSignIn=${() => setSigningIn(true)} />
      ${hasSettings
        ? html`<${DeviceSettingsCard} snap=${snap} onCustomModes=${openCustomModes} />
            <${ClockCard} snap=${snap} onThemes=${() => setThemes(true)} />
            <${LabCard} snap=${snap} onCustomModes=${openCustomModes} />`
        : null}
      ${!demo && snap.signedIn
        ? html`<${SlateCard} class="dv-card">
            <div class="dv-header">
              <span class="t-heading c-primary">${t('Anker 账号')}</span>
              <span class="dv-spacer"></span>
              <${ActionButton} emphasis="destructive" title=${t('退出账号')} onClick=${confirmSignOut} />
            </div>
          </${SlateCard}>`
        : null}
    </div>
    ${signingIn ? html`<${SignInSheet} state=${state} purpose="a2345" onClose=${() => setSigningIn(false)} />` : null}
    ${themes ? html`<${ThemePickerSheet} snap=${snap} onClose=${() => setThemes(false)} />` : null}
    ${CustomModes ? html`<${CustomModes} state=${state} onClose=${() => setCustomModes(null)} />` : null}
  </div>`;
}

// ---- Current connection ----------------------------------------------------------------------

function CurrentConnectionCard({ state, snap, onSignIn }) {
  const x = snap.a2345 || {};
  const demo = !!snap.isDemo;
  const failed = snap.stage === 'failed';
  const busy = BUSY_STAGES.includes(snap.stage);
  const devices = snap.devices || [];
  const selectedSerial = state.prefs.a2345SelectedSerial;
  // canRetryA2345: the engine's checks plus "not in demo mode".
  const canRetry = !!snap.canRetry && !state.prefs.demoMode;
  const hasSelectedBoundDevice = devices.length <= 1 || devices.some((d) => d.serial === selectedSerial);

  let content;
  if (demo || (!failed && snap.device)) content = html`<${ConnectedContent} snap=${snap} />`;
  else if (failed)
    content = html`<div class="dv-current d5-current--center">
      <${ConnectionArtwork} active=${false} />
      <div class="dv-stack dv-gap-m dv-grow">
        <div class="dv-row dv-top dv-gap-m">
          <${Icon} name="bolt.slash.fill" class="c-danger d5-failed__icon" />
          <div class="dv-stack dv-gap-xs">
            <span class="t-title c-primary">${t('连接没有完成')}</span>
            <span class="t-caption c-danger para">${tt(snap.failure || snap.statusDetail)}</span>
          </div>
        </div>
        <div class="dv-row dv-gap-s d5-wrap">
          ${canRetry && hasSelectedBoundDevice
            ? html`<${ActionButton} emphasis="primary" icon="arrow.clockwise" title=${t('重新连接')} onClick=${() => run('RetryA2345')} />`
            : !snap.signedIn
              ? html`<${ActionButton} emphasis="primary" icon="person.badge.key" title=${t('重新登录')} onClick=${onSignIn} />`
              : null}
          <${ActionButton} icon="dv-play" title=${t('体验模拟设备')} onClick=${enterDemoMode} />
        </div>
      </div>
    </div>`;
  else if (busy)
    content = html`<div class="dv-row dv-top dv-gap-m" role="status">
      <${Spinner} />
      <div class="dv-stack dv-gap-xs">
        <span class="t-label c-primary">${tt(snap.statusLabel)}</span>
        <span class="t-caption c-secondary para">${tt(snap.statusDetail)}</span>
      </div>
    </div>`;
  else {
    const step = (n, text) => html`<div class="dv-row dv-gap-s d5-step">
      <span class="d5-step__n num">${n}</span>
      <span class="t-caption c-secondary">${t(text)}</span>
    </div>`;
    content = html`<div class="dv-current d5-current--center">
      <${ConnectionArtwork} active=${false} />
      <div class="dv-stack dv-gap-m dv-grow">
        <span class="t-title c-primary">${t('使用 Anker 账号查找 A2345')}</span>
        <div class="dv-stack dv-gap-s">
          ${step(1, '确认充电器已在官方 Anker App 中完成 Wi-Fi 配网')} ${step(2, '使用绑定该设备的同一个 Anker 账号登录')}
        </div>
        <div class="dv-row dv-gap-s d5-wrap">
          <${ActionButton}
            emphasis="primary"
            icon="person.badge.key"
            title=${t('登录并连接')}
            help=${t('登录 Anker 账号并连接 A2345')}
            disabled=${busy || snap.signingIn}
            onClick=${onSignIn}
          />
          <${ActionButton} emphasis="quiet" icon="arrow.left" title=${t('重新选择型号')} onClick=${restartInitialSetup} />
        </div>
      </div>
    </div>`;
  }

  return html`<${SlateCard} class="dv-card">
    <div class="dv-stack dv-gap-l">
      <div class="dv-header d5-current-header">
        <span class="t-heading c-primary">${t('当前连接')}</span>
        <span class="dv-spacer"></span>
        <div class="dv-row dv-gap-s">
          ${demo
            ? html`<${Chip} text=${t('模拟')} tone="accent" />`
            : html`<${ActionButton}
                  emphasis="quiet"
                  icon="arrow.triangle.2.circlepath"
                  title=${t('选择其他充电器')}
                  onClick=${restartInitialSetup}
                />
                ${busy
                  ? html`<${Spinner} />`
                  : canRetry && snap.device && !failed
                    ? html`<${ActionButton} icon="arrow.clockwise" title=${t('重新连接')} onClick=${() => run('RetryA2345')} />`
                    : null}`}
        </div>
      </div>
      ${content}
      ${devices.length > 1
        ? html`<${Hairline} />
            <${DevicePicker} snap=${snap} selectedSerial=${selectedSerial} disabled=${busy} />`
        : null}
    </div>
  </${SlateCard}>`;
}

function wifiText(online) {
  if (online === true) return t('已连接');
  if (online === false) return t('离线');
  return t('未知');
}

function ConnectedContent({ snap }) {
  const tone = stateTone(snap.stage, snap.isStale, snap.isDemo);
  const device = snap.device;
  const cell = (label, value, middle) => html`<div class="dv-meta__cell">
    <span class="t-micro c-tertiary">${t(label)}</span>
    <span class=${cx('dv-meta__value d5-meta__value num', middle && 'is-middle')} title=${middle ? value : undefined}
      >${value}</span
    >
  </div>`;
  return html`<div class="dv-current">
    <${ConnectionArtwork} active=${!!snap.live} fills />
    <div class="dv-current__details">
      <div class="dv-stack dv-gap-s">
        <span class="t-title c-primary dv-name">${device?.name || 'Anker Prime 250W'}</span>
        <div class="dv-row dv-gap-s">
          <${A2345StateDot} snap=${snap} diameter=${8} />
          <div class="dv-stack dv-gap-xxs">
            <span class=${cx('t-label', `d5-tone--${tone}`)}>${tt(snap.statusLabel)}</span>
            <span class=${cx('t-caption', tone === 'danger' ? 'c-danger' : 'c-tertiary')}>${tt(snap.statusDetail)}</span>
          </div>
        </div>
      </div>
      <div class="dv-meta">
        <div class="dv-meta__row">
          ${cell('型号', 'A2345')}
          <${Hairline} vertical />
          ${cell('固件', device?.firmware || PLACEHOLDER)}
        </div>
        <${Hairline} />
        <div class="dv-meta__row">
          ${cell('Wi-Fi', wifiText(device?.wifiOnline))}
          <${Hairline} vertical />
          ${cell('序列号', device?.serial || 'A2345-DEMO', true)}
        </div>
      </div>
    </div>
  </div>`;
}

function DevicePicker({ snap, selectedSerial, disabled }) {
  const status = (online) => (online === true ? t('Wi-Fi 在线') : online === false ? t('Wi-Fi 离线') : t('Wi-Fi 状态未知'));
  return html`<div class="dv-stack dv-gap-s">
    <span class="t-label c-primary">${t('账号中的 A2345')}</span>
    ${(snap.devices || []).map((d) => {
      const selected = snap.device?.serial === d.serial || (!snap.device && selectedSerial === d.serial);
      return html`<button
        key=${d.serial}
        class=${cx('d5-device', selected && 'is-selected')}
        disabled=${disabled}
        aria-label=${tf('%@，序列号 %@', d.name, d.serial)}
        aria-pressed=${selected}
        aria-description=${t('按下以监控这台设备')}
        onClick=${() => run('SelectA2345Device', d.serial)}
      >
        <${Icon} name=${selected ? 'dv-check-circle-fill' : 'dv-circle'} class=${selected ? 'c-accent' : 'c-tertiary'} />
        <span class="dv-stack dv-gap-xxs d5-device__text">
          <span class="t-label c-primary dv-ellipsis">${d.name}</span>
          <span class="d5-device__serial num">${d.serial}</span>
        </span>
        <span class="dv-spacer"></span>
        <span class=${cx('t-micro', d.wifiOnline === true ? 'c-ok' : d.wifiOnline === false ? 'c-warn' : 'c-tertiary')}
          >${status(d.wifiOnline)}</span
        >
      </button>`;
    })}
  </div>`;
}

// ---- Device settings (A2345DeviceSettingsCard) ------------------------------------------------

function useBrightnessDraft(current) {
  const clamp = (v) => Math.min(100, Math.max(20, v));
  const [draft, setDraft] = useState(current != null ? clamp(current) : 60);
  const editing = useRef(false);
  useEffect(() => {
    if (!editing.current && current != null) setDraft(clamp(current));
  }, [current]);
  return [draft, setDraft, editing];
}

function DeviceSettingsCard({ snap, onCustomModes }) {
  const x = snap.a2345 || {};
  const settings = x.settings;
  const blocker = x.controlBlocker ? tt(x.controlBlocker) : null;
  const disabled = !!blocker;
  const modes = x.chargingModes || [];
  const code = settings?.chargingMode ?? null;
  const isCustom = !!settings?.isCustomChargingMode;
  const preset = !isCustom && MODES.some(([v]) => v === code) ? code : null;
  const customModeAvailable = !!x.supportsCustomMode && !!x.cloudSettings?.customModeEnabled;
  const activeProfile = isCustom ? modes.find((m) => m.number === (settings?.customProfile?.number ?? 0)) : null;
  const modePending = (x.pendingWrites || []).some((w) => w.messageType === 0x0206);

  let modeText = PLACEHOLDER;
  if (settings) {
    if (isCustom) modeText = activeProfile?.name || t('自定义模式');
    else if (preset != null) modeText = labelOf(MODES, preset);
  }

  const confirmProfile = async (profile) => {
    const ok = await confirmDialog({
      title: tf('切换到「%@」？', profile.name),
      message: t('所有端口会断电几秒后恢复。'),
      actions: [
        { title: t('取消'), role: 'cancel' },
        { title: t('切换'), value: true, default: true },
      ],
    });
    if (ok) run('ApplyA2345ChargingMode', profile);
  };

  const modeItems = () => {
    const items = MODES.map(([value, text]) => ({
      title: t(text),
      checked: preset === value,
      action: () => {
        if (preset !== value) run('SetA2345ChargingMode', value);
      },
    }));
    if (customModeAvailable) {
      items.push({ separator: true }, { header: t('自定义模式') });
      for (const profile of modes) {
        const active = activeProfile?.id === profile.id;
        items.push({ title: profile.name, checked: active, action: () => !active && confirmProfile(profile) });
      }
      items.push({ title: t('管理自定义模式…'), action: onCustomModes });
    }
    return items;
  };

  const bitmap = settings?.priorityBitmap ?? 0;
  const chosenCount = [0, 1, 2, 3].filter((i) => bitmap & (1 << i)).length;
  const priorityItems = () =>
    ['C1', 'C2', 'C3', 'C4'].map((label, i) => {
      const bit = 1 << i;
      const chosen = (bitmap & bit) !== 0;
      return {
        title: label,
        checked: chosen,
        disabled: !chosen && chosenCount >= 2,
        action: () => run('SetA2345PortPriority', chosen ? bitmap & ~bit : bitmap | bit),
      };
    });

  const timeout = settings?.screenTimeout ?? null;
  const knob = settings?.knobDirection ?? null;
  const brightness = settings?.brightness ?? null;
  const [draft, setDraft, editing] = useBrightnessDraft(brightness);
  // The charger takes 20…100 in steps of five.
  const percent = Math.min(100, Math.max(20, Math.round(draft / 5) * 5));

  const pickerItems = (list, current, method) => () =>
    list.map(([value, text]) => ({
      title: t(text),
      checked: current === value,
      action: () => current !== value && run(method, value),
    }));

  return html`<${SlateCard} class="dv-card">
    <div class="dv-stack dv-gap-m dv-pad-bottom">
      <span class="t-heading c-primary">${t('设备设置')}</span>
      <${Row} title=${t('充电模式')}>
        ${modePending ? html`<${Spinner} />` : null}
        ${code == null
          ? plainValue(modeText)
          : html`<${SettingMenu} text=${modeText} label=${t('充电模式')} disabled=${disabled} items=${modeItems} />`}
      </${Row}>
      ${preset === 2
        ? html`<${Row} title=${t('优先端口')} help=${t('最多两个端口。')}>
            <${SettingMenu} text=${priorityText(bitmap)} disabled=${disabled} items=${priorityItems} />
          </${Row}>`
        : null}
      <span class="t-caption c-tertiary">${t('切换时正在充电的设备可能短暂断电。')}</span>
      <${Hairline} />
      <${Row} title=${t('熄屏时间')}>
        ${timeout == null
          ? plainValue(PLACEHOLDER)
          : html`<${SettingMenu}
              text=${labelOf(TIMEOUTS, timeout)}
              disabled=${disabled}
              items=${pickerItems(TIMEOUTS, timeout, 'SetA2345ScreenTimeout')}
            />`}
      </${Row}>
      <div class="dv-setting dv-gap-m">
        <span class="t-body c-secondary dv-brightness__label">${t('屏幕亮度')}</span>
        <${Slider}
          class="dv-brightness__slider"
          value=${draft}
          min=${20}
          max=${100}
          disabled=${disabled || brightness == null}
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
          disabled=${disabled || brightness == null || brightness === percent}
          onClick=${() => run('SetA2345Brightness', percent)}
        />
      </div>
      <${Row} title=${t('旋钮方向')}>
        ${knob == null
          ? plainValue(PLACEHOLDER)
          : html`<${SettingMenu}
              text=${labelOf(KNOBS, knob)}
              disabled=${disabled}
              items=${pickerItems(KNOBS, knob, 'SetA2345KnobDirection')}
            />`}
      </${Row}>
      ${blocker ? html`<span class="t-caption c-tertiary">${blocker}</span>` : null}
    </div>
  </${SlateCard}>`;
}

// ---- Clock screensaver (A2345ClockCard) ------------------------------------------------------------

function themeName(snap) {
  const x = snap.a2345 || {};
  const clock = x.settings?.clock;
  if (!clock) return PLACEHOLDER;
  if (clock.themeCode >= 0 && clock.themeCode <= 2) return builtInStyle(clock.themeCode);
  const theme = x.currentPictureTheme;
  if (theme) {
    if (theme.kind === 5) return t('我的图片');
    return theme.title || t('云端主题');
  }
  return clock.themeCode === 5 ? t('我的图片') : t('云端主题');
}

function ClockCard({ snap, onThemes }) {
  const x = snap.a2345 || {};
  const settings = x.settings;
  const clock = settings?.clock || null;
  const disabled = !!x.controlBlocker;
  const clockOn = !!clock?.isOn;
  // Firmware reporting protocol version 1 or the clock-schedule capability.
  const hasClockExtras = settings?.protocolVersion === 1 || supports(settings, CAP.clockSchedule);
  const schedule = settings?.clockSchedule;
  const [editAnchor, setEditAnchor] = useState(null);

  return html`<${SlateCard} class="dv-card">
    <div class="dv-stack dv-gap-m dv-pad-bottom">
      <div class="dv-header">
        <span class="t-heading c-primary">${t('时钟屏保')}</span>
        <span class="dv-spacer"></span>
        <${Toggle}
          small
          on=${clockOn}
          label=${t('时钟屏保')}
          disabled=${disabled || !clock || !x.canToggleClock}
          onChange=${(on) => run('SetA2345ClockEnabled', on)}
        />
      </div>
      <${Row} title=${t('主题')}>
        ${x.themeDownload != null ? html`<${Spinner} />` : null}
        <span class="t-label c-primary dv-ellipsis">${themeName(snap)}</span>
        <${ActionButton}
          title=${t('更换…')}
          disabled=${disabled || !clock || !clockOn}
          help=${clockOn ? undefined : t('先打开时钟屏保。')}
          onClick=${onThemes}
        />
      </${Row}>
      ${hasClockExtras
        ? html`<${Row} title=${t('时间格式')}>
            <div class=${cx('d5-segmented', (disabled || !clockOn || settings?.hourFormat == null) && 'is-disabled')}>
              <${Segmented}
                label=${t('时间格式')}
                value=${settings?.hourFormat ?? 1}
                segments=${[
                  { title: t('12 小时制'), value: 0 },
                  { title: t('24 小时制'), value: 1 },
                ]}
                onChange=${(v) => run('SetA2345HourFormat', v)}
              />
            </div>
          </${Row}>`
        : null}
      ${supports(settings, CAP.clockSchedule) && schedule
        ? html`<${Row} title=${t('显示时段')}>
            <span class="t-label c-primary num dv-ellipsis">${clockScheduleText(schedule)}</span>
            <${ActionButton}
              title=${t('编辑…')}
              disabled=${disabled || !clockOn}
              onClick=${(e) => setEditAnchor(e.currentTarget)}
            />
          </${Row}>`
        : null}
      ${hasClockExtras
        ? html`<${Row} title=${t('节日屏保')}>
            <${Toggle}
              small
              on=${!!clock?.holidayEnabled}
              label=${t('节日屏保')}
              disabled=${disabled || !clockOn}
              onChange=${(on) => run('SetA2345HolidayTheme', on)}
            />
          </${Row}>`
        : null}
      ${clock?.themeCode === 5 && supports(settings, CAP.customImageTimeDisplay)
        ? html`<${Row} title=${t('显示时间')}>
            <${Toggle}
              small
              on=${settings?.customImageTimeDisplay ?? true}
              label=${t('显示时间')}
              disabled=${disabled}
              onChange=${(on) => run('SetA2345CustomImageTimeDisplay', on)}
            />
          </${Row}>`
        : null}
    </div>
    ${editAnchor && schedule
      ? html`<${Popover} anchor=${editAnchor} width=${268} onClose=${() => setEditAnchor(null)}>
          <${ClockScheduleEditor} initial=${schedule} close=${() => setEditAnchor(null)} />
        </${Popover}>`
      : null}
  </${SlateCard}>`;
}

/** A2345WeekdayPicker: seven toggle chips, Monday first. */
function WeekdayPicker({ mask, onChange }) {
  return html`<div class="d5-weekdays">
    ${WEEKDAY_SYMBOLS.map((symbol, i) => {
      const on = (mask & (1 << i)) !== 0;
      return html`<button
        class=${cx('d5-weekday', on && 'is-on')}
        aria-label=${t(WEEKDAY_NAMES[i])}
        aria-pressed=${on}
        onClick=${() => onChange(mask ^ (1 << i))}
      >
        ${t(symbol)}
      </button>`;
    })}
  </div>`;
}

const timeValue = (h, m) => `${pad2(h)}:${pad2(m)}`;
function parseTime(value) {
  const [h, m] = String(value || '').split(':').map(Number);
  return Number.isFinite(h) && Number.isFinite(m) ? [h, m] : null;
}

/** A2345ClockScheduleEditor: seeded once per opening. */
function ClockScheduleEditor({ initial, close }) {
  const [start, setStart] = useState(() => [initial.startHour, initial.startMinute]);
  const [end, setEnd] = useState(() => [initial.endHour, initial.endMinute]);
  const [days, setDays] = useState(() => initial.weekdays & 0x7f);
  const schedule = { startHour: start[0], startMinute: start[1], endHour: end[0], endMinute: end[1], weekdays: days };
  const unchanged =
    schedule.startHour === initial.startHour &&
    schedule.startMinute === initial.startMinute &&
    schedule.endHour === initial.endHour &&
    schedule.endMinute === initial.endMinute &&
    schedule.weekdays === (initial.weekdays & 0x7f);
  const save = () => {
    if (unchanged) return;
    run('SetA2345ClockSchedule', schedule);
    close();
  };
  return html`<div
    class="dv-stack dv-gap-m"
    onKeyDown=${(e) => {
      if (e.key === 'Enter' && e.target.tagName !== 'BUTTON') {
        e.preventDefault();
        save();
      }
    }}
  >
    <span class="t-label c-primary">${t('显示时段')}</span>
    <div class="dv-row dv-gap-s">
      <input
        class="field d5-time num"
        type="time"
        step="60"
        aria-label=${t('开始时间')}
        value=${timeValue(...start)}
        onChange=${(e) => {
          const v = parseTime(e.currentTarget.value);
          if (v) setStart(v);
        }}
      />
      <span class="c-tertiary">–</span>
      <input
        class="field d5-time num"
        type="time"
        step="60"
        aria-label=${t('结束时间')}
        value=${timeValue(...end)}
        onChange=${(e) => {
          const v = parseTime(e.currentTarget.value);
          if (v) setEnd(v);
        }}
      />
    </div>
    <${WeekdayPicker} mask=${days} onChange=${setDays} />
    <span class="t-micro c-tertiary">${daysText(days)}</span>
    <div class="dv-row dv-gap-s">
      <span class="dv-spacer"></span>
      <button class="btn" onClick=${close}>${t('取消')}</button>
      <button class="btn is-primary" disabled=${unchanged} onClick=${save}>${t('保存')}</button>
    </div>
  </div>`;
}

// ---- Laboratory (A2345LabCard) ----------------------------------------------------------------

function LabCard({ snap, onCustomModes }) {
  const x = snap.a2345 || {};
  const settings = x.settings;
  const cloud = x.cloudSettings || null;
  const disabled = !!x.controlBlocker;
  const work = x.cloudWork || [];
  if (!settings) return null;
  const showsCustom = supports(settings, CAP.customChargingMode);
  const showsMax = supports(settings, CAP.maxCompatibility);
  const showsIdentification = supports(settings, CAP.deviceIdentification);
  const showsUFCS = supports(settings, CAP.ufcsSwitch) && !supports(settings, CAP.protocolManagement);
  if (!showsCustom && !showsMax && !showsIdentification && !showsUFCS) return null;

  const labToggle = (title, value, kind, method) => {
    const working = work.includes(kind);
    return html`<div class="dv-row dv-gap-s">
      ${working ? html`<${Spinner} />` : null}
      <${Toggle}
        small
        on=${!!value}
        label=${title}
        disabled=${disabled || value == null || working}
        onChange=${(on) => run(method, on)}
      />
    </div>`;
  };

  return html`<${SlateCard} class="dv-card">
    <div class="dv-stack dv-gap-m dv-pad-bottom">
      <span class="t-heading c-primary">${t('实验室')}</span>
      ${showsCustom
        ? html`<${Row} title=${t('自定义充电模式')}>
            <${ActionButton}
              title=${t('管理…')}
              disabled=${disabled || cloud?.customModeEnabled !== true}
              onClick=${onCustomModes}
            />
            ${labToggle(t('自定义充电模式'), cloud?.customModeEnabled, 'customModeSwitch', 'SetA2345CustomModeEnabled')}
          </${Row}>`
        : null}
      ${showsMax
        ? html`<${Row} title=${t('最大兼容性')} help=${t('部分无人机的电池仓会充得更快。和充电设备识别不能同时打开。')}>
            ${labToggle(t('最大兼容性'), cloud?.maxCompatibility ?? settings.maxCompatibility, 'labExclusive', 'SetA2345MaxCompatibility')}
          </${Row}>`
        : null}
      ${showsIdentification
        ? html`<${Row} title=${t('充电设备识别')} help=${t('充电器屏幕显示正在充电的设备型号。和最大兼容性不能同时打开。')}>
            ${labToggle(
              t('充电设备识别'),
              cloud?.deviceIdentification ?? settings.deviceIdentification,
              'labExclusive',
              'SetA2345DeviceIdentification',
            )}
          </${Row}>`
        : null}
      ${showsUFCS
        ? html`<${Row} title="UFCS">
            <${Toggle}
              small
              on=${!!settings.ufcs}
              label="UFCS"
              disabled=${disabled || settings.ufcs == null}
              onChange=${(on) => run('SetA2345UFCS', on)}
            />
          </${Row}>`
        : null}
    </div>
  </${SlateCard}>`;
}

// ---- Clock themes (A2345ThemePickerSheet) -------------------------------------------------------

/** A2345PictureEncoder: filled into 480×200 and saved as a JPEG of ~77–96 KB. */
async function encodePicture(file) {
  const bitmap = await createImageBitmap(file);
  const canvas = document.createElement('canvas');
  canvas.width = PICTURE_W;
  canvas.height = PICTURE_H;
  const ctx = canvas.getContext('2d');
  ctx.imageSmoothingQuality = 'high';
  ctx.fillStyle = '#000';
  ctx.fillRect(0, 0, PICTURE_W, PICTURE_H);
  const scale = Math.max(PICTURE_W / bitmap.width, PICTURE_H / bitmap.height);
  const w = bitmap.width * scale;
  const h = bitmap.height * scale;
  ctx.drawImage(bitmap, (PICTURE_W - w) / 2, (PICTURE_H - h) / 2, w, h);
  bitmap.close?.();
  const encode = (quality) => new Promise((resolve) => canvas.toBlob(resolve, 'image/jpeg', quality / 100));
  // Searches the quality (1…90) for a file inside the size window.
  let low = 1;
  let high = 90;
  let quality = 45;
  let best = null;
  for (let i = 0; i < 8; i++) {
    const blob = await encode(quality);
    if (!blob) break;
    if (blob.size > PICTURE_MAX_BYTES) {
      high = quality - 1;
    } else {
      best = blob;
      if (blob.size >= PICTURE_MIN_BYTES) break;
      low = quality + 1;
    }
    if (low > high) break;
    quality = Math.floor((low + high) / 2);
  }
  best ??= await encode(1);
  if (!best) return null;
  const dataURL = await new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = reject;
    reader.readAsDataURL(best);
  });
  return { preview: canvas.toDataURL('image/jpeg', 0.9), jpeg: String(dataURL).split(',')[1] };
}

function PictureScreen({ url }) {
  const [phase, setPhase] = useState('loading');
  useEffect(() => setPhase('loading'), [url]);
  return html`<span class="d5-tile__screen-content">
    <img
      class=${cx('d5-tile__picture', phase !== 'loaded' && 'is-hidden')}
      src=${url}
      alt=""
      draggable="false"
      onLoad=${() => setPhase('loaded')}
      onError=${() => setPhase('failed')}
    />
    ${phase === 'loaded' ? html`<img class="d5-tile__clock" src="assets/clock-themes/clock.png" alt="" draggable="false" />` : null}
    ${phase === 'loading' ? html`<${Spinner} />` : null}
    ${phase === 'failed' ? html`<${Icon} name="photo" class="d5-tile__broken" />` : null}
  </span>`;
}

function ThemeTile({ title, selected, enabled, downloading, busy, screen, onClick, onContextMenu }) {
  return html`<button
    class=${cx('d5-tile', selected && 'is-selected')}
    disabled=${!enabled || busy}
    style=${{ opacity: enabled ? 1 : 0.45 }}
    aria-label=${title || t('我的图片')}
    aria-pressed=${selected}
    onClick=${onClick}
    onContextMenu=${onContextMenu}
  >
    <span class="d5-tile__screen">
      ${screen}
      ${downloading ? html`<span class="d5-tile__downloading"><${Spinner} /></span>` : null}
    </span>
    ${title ? html`<span class=${cx('t-caption d5-tile__title', selected ? 'c-accent' : 'c-secondary')}>${title}</span>` : null}
  </button>`;
}

function ThemePickerSheet({ snap, onClose }) {
  const x = snap.a2345 || {};
  const clock = x.settings?.clock || null;
  const clockOn = !!clock?.isOn;
  const downloading = x.themeDownload ?? null;
  const work = x.cloudWork || [];
  const uploading = work.includes('pictures');
  const [pending, setPending] = useState(null);
  const fileInput = useRef(null);

  useEffect(() => {
    run('ReloadA2345Pictures');
  }, []);

  useEffect(() => {
    const key = (e) => {
      if (e.defaultPrevented) return;
      if (e.key === 'Escape') {
        e.preventDefault();
        if (pending) setPending(null);
        else onClose();
      } else if (e.key === 'Enter' && e.target.tagName !== 'BUTTON') {
        // Return belongs to 上传 while an upload waits for confirmation.
        e.preventDefault();
        if (pending) upload();
        else onClose();
      }
    };
    document.addEventListener('keydown', key);
    return () => document.removeEventListener('keydown', key);
  });

  const upload = () => {
    if (!pending || !x.canUploadPicture) return;
    run('UploadA2345Picture', pending.jpeg);
    setPending(null);
  };

  const chooseImage = async (e) => {
    const file = e.currentTarget.files?.[0];
    e.currentTarget.value = '';
    if (!file) return;
    try {
      const encoded = await encodePicture(file);
      if (encoded) setPending(encoded);
    } catch {
      // Not an image the system can decode: nothing to upload, as on the Mac.
    }
  };

  const confirmDelete = async (theme) => {
    const ok = await confirmDialog({
      title: t('删除这张图片？'),
      actions: [
        { title: t('取消'), role: 'cancel' },
        { title: t('删除'), role: 'destructive', value: true },
      ],
    });
    if (ok) run('DeleteA2345Picture', theme.id);
  };

  const themes = x.themes;
  const categories = [];
  for (const theme of themes || []) if (!categories.includes(theme.category)) categories.push(theme.category);

  const pictureTile = (theme, custom) =>
    html`<${ThemeTile}
      key=${`${custom ? 'p' : 't'}${theme.id}`}
      title=${theme.kind === 5 ? null : theme.title}
      selected=${clock?.themeCode === theme.kind && clock?.themeId === theme.id}
      enabled=${clockOn && (theme.kind === 5 || !!x.supportsPictureThemes)}
      downloading=${downloading === theme.id}
      busy=${downloading != null}
      screen=${html`<${PictureScreen} url=${theme.imageURL} />`}
      onClick=${() => run('ApplyA2345PictureTheme', theme.id, custom)}
      onContextMenu=${custom
        ? (e) => {
            e.preventDefault();
            openMenu(e.currentTarget, [{ title: t('删除'), destructive: true, action: () => confirmDelete(theme) }]);
          }
        : undefined}
    />`;

  const section = (title, children) => html`<div class="dv-stack dv-gap-s">
    <span class="t-label c-secondary">${title}</span>
    <div class="d5-grid">${children}</div>
  </div>`;

  const pictures = x.customPictures;
  const uploadHelp =
    !x.canUploadPicture && (pictures?.length ?? 0) >= CUSTOM_PICTURE_LIMIT ? tf('最多 %d 张。', CUSTOM_PICTURE_LIMIT) : undefined;

  return html`<div class="dialog-backdrop dv-sheet-backdrop">
    <div class="dv-sheet d5-themes" role="dialog" aria-modal="true" aria-label=${t('时钟主题')}>
      <div class="dv-header d5-themes__header">
        <span class="t-heading c-primary">${t('时钟主题')}</span>
        <span class="dv-spacer"></span>
        ${downloading != null
          ? html`<${Spinner} /><span class="t-caption c-secondary">${t('充电器正在下载…')}</span>`
          : null}
        <button class=${cx('btn', !pending && 'is-primary')} onClick=${onClose}>${t('完成')}</button>
      </div>
      <${Hairline} />
      <div class=${cx('d5-themes__body scroll', x.controlBlocker && 'is-disabled')}>
        ${section(
          t('标准样式'),
          [0, 1, 2].map(
            (kind) => html`<${ThemeTile}
              key=${`s${kind}`}
              title=${builtInStyle(kind)}
              selected=${clock?.themeCode === kind}
              enabled=${clockOn}
              busy=${downloading != null}
              screen=${html`<img class="d5-tile__picture" src=${`assets/clock-themes/style${kind + 1}.png`} alt="" draggable="false" />`}
              onClick=${() => run('ApplyA2345BuiltInStyle', kind)}
            />`,
          ),
        )}
        ${categories.map((category) =>
          section(
            category || t('云端主题'),
            themes.filter((theme) => theme.category === category).map((theme) => pictureTile(theme, false)),
          ),
        )}
        ${!snap.isDemo && pictures != null
          ? section(
              t('我的图片'),
              html`${pictures.map((theme) => pictureTile(theme, true))}
                <button
                  class="d5-tile d5-upload"
                  disabled=${!x.canUploadPicture || uploading}
                  title=${uploadHelp}
                  onClick=${() => fileInput.current?.click()}
                >
                  <span class="d5-tile__screen d5-upload__screen">
                    ${uploading ? html`<${Spinner} />` : html`<${Icon} name="plus" class="d5-upload__plus" />`}
                  </span>
                  <span class="t-caption c-secondary d5-tile__title">${t('上传图片')}</span>
                </button>`,
            )
          : null}
        ${themes == null && !snap.isDemo ? html`<span class="t-caption c-tertiary">${t('云端主题没有读到。')}</span>` : null}
      </div>
      ${pending
        ? html`<${Hairline} />
            <div class="d5-upload-confirm">
              <img class="d5-upload-confirm__preview" src=${pending.preview} alt="" />
              <div class="dv-stack dv-gap-xs">
                <span class="t-caption c-secondary para">${t('上传到 Anker 账号后就能用在充电器上。')}</span>
                <div class="dv-row dv-gap-s">
                  <button class="btn" onClick=${() => setPending(null)}>${t('取消')}</button>
                  <button class="btn is-primary" disabled=${!x.canUploadPicture} onClick=${upload}>${t('上传')}</button>
                </div>
              </div>
            </div>`
        : null}
      <input ref=${fileInput} type="file" accept="image/*" hidden onChange=${chooseImage} />
    </div>
  </div>`;
}
