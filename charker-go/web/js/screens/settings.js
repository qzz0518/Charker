// Advanced / Settings screen (#/advanced, alias #/settings) — owner: web-screens.
//
// Mirrors Charker's AdvancedView plus the charger's own settings card:
// appearance (Charker.SetTheme), app language (Charker.SetLocale), device
// settings via Charker.SetSetting, energy export, and honestly-degraded
// capability notices for the 250 W cloud model and Apple Home / Matter.

import {
  makeUI, h, clear, pageHead, actionButton, card, cardHead, notice,
  group, switchRow, sliderRow, segRow, selectRow, row, divider, chip,
  callSafe, switchControl,
} from './screens-util.js';

const THEME_ITEMS = [
  { value: 'system', label: '跟随系统' },
  { value: 'light', label: '浅色' },
  { value: 'dark', label: '深色' },
];
const LOCALE_ITEMS = [
  { value: 'zh', label: '中文' },
  { value: 'en', label: 'English' },
];
const ORIENTATION_ITEMS = [
  { value: 'up', label: '向上' },
  { value: 'left', label: '向左' },
  { value: 'down', label: '向下' },
  { value: 'right', label: '向右' },
];
const TIMEOUT_ITEMS = [
  { value: '30s', label: '30 秒' },
  { value: '1m', label: '1 分钟' },
  { value: '5m', label: '5 分钟' },
  { value: '30m', label: '30 分钟' },
  { value: '12h', label: '12 小时' },
];
const DEVICE_LANGUAGE_ITEMS = [
  { value: 'zh', label: '简体中文' },
  { value: 'en', label: 'English' },
  { value: 'ja', label: '日本語' },
  { value: 'de', label: 'Deutsch' },
];
const CHARGING_MODE_ITEMS = [
  { value: 'ai', label: 'AI 模式 2.0' },
  { value: 'standard', label: '标准模式' },
  { value: 'custom', label: '自定义模式' },
];
const ALLOCATION_ITEMS = [
  { value: 'c1Priority', label: 'C1 口优先' },
  { value: 'dualLaptop', label: '双笔电模式' },
];

let instances = new Set();

export function render(root, state, ctx) {
  let inst = root.__scSettings;
  if (!inst) {
    inst = createSettingsScreen(root);
    root.__scSettings = inst;
    instances.add(inst);
  }
  inst.update(makeUI(ctx, state), state);
}

export function cleanup() {
  for (const inst of instances) inst.dispose();
  instances.clear();
}

function createSettingsScreen(root) {
  const screen = h('div', { class: 'sc-screen sc-adv' });
  const content = h('div', { class: 'sc-adv__content' });
  root.append(screen);
  screen.append(content);

  let ui = null;
  let state = null;
  let builtLocale = null;
  let disposed = false;
  let lastSig = '';
  const pending = new Set();
  let brightnessDraft = null;
  let writesDraft; // optimistic local value for 允许端口开关

  // ---- helpers ------------------------------------------------------------

  function localize(items) {
    return items.map((item) => ({ value: item.value, label: ui.t(item.label) }));
  }

  function validTimeout(value) {
    return TIMEOUT_ITEMS.some((item) => item.value === String(value)) ? String(value) : '';
  }

  function validChargingMode(value) {
    return CHARGING_MODE_ITEMS.some((item) => item.value === String(value)) ? String(value) : '';
  }

  function settings() {
    return (state && state.settings) || {};
  }

  function isConnected() {
    if (!state) return false;
    if (state.phase === 'polling' || state.phase === 'handshake') return true;
    return !!(state.device && state.device.connected);
  }

  function signature() {
    return JSON.stringify({
      locale: ui ? ui.locale : '',
      theme: state && state.app ? state.app.theme : '',
      connected: isConnected(),
      settings: settings(),
      mock: !!(state && state.app && state.app.mock),
      version: state && state.app ? state.app.version : '',
      writesEnabled: writesEnabledValue(),
      writesDraft: typeof writesDraft === 'boolean' ? writesDraft : null,
      pending: [...pending].sort(),
    });
  }

  /** Port-switching capability: state first, optimistic draft while in flight. */
  function writesEnabledValue() {
    const s = settings();
    if (typeof writesDraft === 'boolean') return writesDraft;
    if (typeof s.writesEnabled === 'boolean') return s.writesEnabled;
    if (typeof state.writesEnabled === 'boolean') return state.writesEnabled;
    return false;
  }

  async function setWritesEnabled(on) {
    writesDraft = on;
    renderContent();
    // app-wiring exposes a dedicated setter; older builds only have SetSetting.
    let out = await callSafe(ui, 'Charker.SetWritesEnabled', [on], null);
    if (out && out.__error) {
      out = await callSafe(ui, 'Charker.SetSetting', ['writesEnabled', on ? 'true' : 'false'], null);
    }
    if (disposed) return;
    if (out && out.__error) {
      writesDraft = undefined;
      ui.toast(ui.t('设置失败：%@', out.__error.message || out.__error), 'error');
      renderContent();
      return;
    }
    ui.toast(on ? ui.t('已开启端口开关') : ui.t('已关闭端口开关'), 'info');
  }

  async function writeSetting(key, value, labelKey) {
    if (!ui || !ui.ctx || typeof ui.ctx.call !== 'function') return;
    pending.add(key);
    renderContent();
    const out = await callSafe(ui, 'Charker.SetSetting', [key, String(value)], null);
    pending.delete(key);
    if (disposed) return;
    if (out && out.__error) {
      ui.toast(ui.t('设置失败：%@', out.__error.message || out.__error), 'error');
    } else {
      ui.toast(ui.t('已发送「%@」', ui.t(labelKey)), 'info');
    }
    renderContent();
  }

  function applyTheme(theme) {
    // Prefer the shell helper: it applies the attribute immediately and asks
    // the Go side to persist it. Fall back to the bare binding call.
    if (ui.ctx && typeof ui.ctx.setTheme === 'function') {
      try {
        ui.ctx.setTheme(theme);
        return;
      } catch (_) { /* fall through to the binding call */ }
    }
    if (ui.ctx && typeof ui.ctx.call === 'function') {
      callSafe(ui, 'Charker.SetTheme', [theme], null).then((out) => {
        if (disposed || !out || !out.__error) return;
        ui.toast(ui.t('主题切换失败：%@', out.__error.message || out.__error), 'error');
      });
    }
  }

  function applyLocale(locale) {
    if (ui.ctx && typeof ui.ctx.setLocale === 'function') {
      try {
        ui.ctx.setLocale(locale);
        return;
      } catch (_) { /* fall through to the binding call */ }
    }
    if (ui.ctx && typeof ui.ctx.call === 'function') {
      callSafe(ui, 'Charker.SetLocale', [locale], null).then((out) => {
        if (disposed || !out || !out.__error) return;
        ui.toast(ui.t('语言切换失败：%@', out.__error.message || out.__error), 'error');
      });
    }
  }

  function exportEnergy(format) {
    if (!ui.ctx || typeof ui.ctx.call !== 'function') {
      ui.toast(ui.t('请在浏览器打开'), 'warn');
      return;
    }
    callSafe(ui, 'Charker.ExportEnergy', ['month', format], '').then((out) => {
      if (disposed) return;
      if (out && out.__error) {
        ui.toast(ui.t('导出失败：%@', out.__error.message || out.__error), 'error');
        return;
      }
      const path = typeof out === 'string' ? out.trim() : '';
      ui.toast(path ? ui.t('已导出到 %@', path) : ui.t('已取消'), path ? 'info' : 'warn');
    });
  }

  function reconnectDevice() {
    const id = state && state.device && state.device.id;
    if (!id) { ui.toast(ui.t('没有已连接的充电器'), 'warn'); return; }
    callSafe(ui, 'Charker.Connect', [id], null).then((out) => {
      if (!disposed && out && out.__error) ui.toast(ui.t('连接失败：%@', out.__error.message || out.__error), 'error');
    });
  }

  // ---- rendering ----------------------------------------------------------

  function build() {
    builtLocale = ui.locale;
    clear(screen);
    screen.append(pageHead(ui, '高级'), content);
    renderContent();
    lastSig = signature();
  }

  function renderContent() {
    clear(content);
    const s = settings();
    content.append(deviceSettingsGroup(s));
    content.append(appearanceGroup());
    content.append(languageGroup());
    content.append(energyGroup());
    content.append(portControlGroup());
    content.append(advancedGroup());
    content.append(aboutGroup());
    content.append(capabilitiesGroup());
  }

  function deviceSettingsGroup(s) {
    const connected = isConnected();
    const head = h('div', { class: 'sc-devicehead' },
      chip(connected ? ui.t('上次连接时的值') : ui.t('未连接'), connected ? 'neutral' : 'warn'),
      h('span', { class: 'sc-row__sub sc-muted ck-u-cjk',
        text: connected ? ui.t('重新连接后才会更新') : ui.t('连接后可修改') }),
      h('span', { class: 'sc-devicehead__spacer' }),
      actionButton(ui, ui.t('重新连接以刷新'), {
        tone: 'quiet', icon: 'refresh', disabled: !!(state && state.phase === 'reconnecting'),
        onclick: reconnectDevice,
      }));

    const rows = [];
    if (!connected) {
      rows.push(notice(ui, 'info', ui.t('未连接充电器，设备设置不可修改。请先在「设备与连接」中连接。')));
    }

    // Screen always-on is read back from the charger but has no write command
    // in this port (a2687 exposes no such opcode), so the switch is read-only.
    const screenOnSwitch = switchControl({ checked: !!s.screenOn, label: ui.t('屏幕常亮'), disabled: true });
    rows.push(withNote(row(ui, { title: '屏幕常亮', control: screenOnSwitch.el }), ui.t('此版本只读')));

    const brightnessValue = brightnessDraft != null ? brightnessDraft : (Number(s.brightness) || 80);
    let applyBtn = null;
    const brightness = sliderRow(ui, {
      title: '屏幕亮度', min: 25, max: 100, step: 1, value: brightnessValue, unit: '%',
      disabled: !connected,
      onChange: (v) => {
        brightnessDraft = v;
        if (applyBtn) applyBtn.disabled = !connected || (Number(settings().brightness) || 80) === Number(v);
      },
    });
    applyBtn = actionButton(ui, ui.t('应用'), {
      disabled: !connected || (Number(s.brightness) || 80) === Number(brightness.value),
      onclick: () => {
        brightnessDraft = brightness.value;
        writeSetting('brightness', String(Math.round(brightness.value)), '屏幕亮度');
      },
    });
    brightness.el.querySelector('.sc-slider__value').append(applyBtn);
    rows.push(brightness.el);

    rows.push(selectRow(ui, {
      title: '屏幕方向', items: localize(ORIENTATION_ITEMS), value: s.orientation || 'up',
      disabled: !connected,
      onChange: (v) => writeSetting('orientation', v, '屏幕方向'),
    }).el);

    rows.push(selectRow(ui, {
      title: '自动锁屏',
      items: localize(TIMEOUT_ITEMS),
      value: validTimeout(s.screenTimeout) || (s.autoLock ? '1m' : '12h'),
      disabled: !connected,
      onChange: (v) => writeSetting('screenTimeout', v, '自动锁屏'),
    }).el);

    const rotate = switchRow(ui, {
      title: '自动旋转',
      checked: s.autoRotate !== false,
      disabled: true,
      note: '此版本只读',
    });
    rows.push(rotate.el);

    rows.push(selectRow(ui, {
      title: '设备语言', items: localize(DEVICE_LANGUAGE_ITEMS), value: s.language || 'zh',
      disabled: !connected,
      onChange: (v) => writeSetting('language', v, '设备语言'),
    }).el);

    rows.push(selectRow(ui, {
      title: '充电模式',
      sub: validChargingMode(s.chargingMode) ? null : '充电器不回报当前模式，选择后会立即发送。',
      items: localize(CHARGING_MODE_ITEMS),
      value: validChargingMode(s.chargingMode) || 'ai',
      disabled: !connected,
      onChange: (v) => writeSetting('chargingMode', v, '充电模式'),
    }).el);

    rows.push(selectRow(ui, {
      title: '固定分配', sub: '当前设置只回报是否启用；重新选择会立即发送。',
      items: localize(ALLOCATION_ITEMS), value: s.fixedAllocation ? 'c1Priority' : 'dualLaptop', disabled: !connected,
      onChange: (v) => writeSetting('fixedAllocation', v, '固定分配'),
    }).el);

    return h('section', { class: 'sc-group' },
      h('div', { class: 'sc-group__label' },
        h('span', { class: 'ck-t-label', text: ui.t('设备设置') }),
        chip(connected ? ui.t('已连接') : ui.t('未连接'), connected ? 'ok' : 'neutral')),
      h('div', { class: 'sc-group__card' }, head, ...rows),
      h('p', { class: 'sc-group__foot ck-u-cjk', text: ui.t('手动设置方向后自动旋转暂停，重新通电后恢复。') }));
  }

  function withNote(rowEl, noteText) {
    rowEl.classList.add('sc-row--with-note');
    const titleEl = rowEl.querySelector('.sc-row__title');
    if (titleEl) titleEl.append(h('span', { class: 'sc-row__note', text: noteText }));
    return rowEl;
  }

  function appearanceGroup() {
    const theme = (state && state.app && state.app.theme) || 'system';
    const seg = segRow(ui, {
      title: '窗口外观', items: localize(THEME_ITEMS), value: theme, width: 240,
      onChange: (v) => applyTheme(v),
    });
    return group(ui, { title: '外观', footnote: '外观会立即应用，并保存到本机设置。' }, seg.el);
  }

  function languageGroup() {
    const locale = (state && state.app && state.app.locale) || 'zh';
    const seg = segRow(ui, {
      title: '界面语言', items: localize(LOCALE_ITEMS), value: String(locale).startsWith('en') ? 'en' : 'zh', width: 240,
      onChange: (v) => applyLocale(v),
    });
    return group(ui, { title: '语言', footnote: '切换后整个界面会重新渲染。' }, seg.el);
  }

  function energyGroup() {
    const csv = actionButton(ui, ui.t('导出 CSV…'), { icon: 'share', onclick: () => exportEnergy('csv') });
    const json = actionButton(ui, ui.t('导出 JSON…'), { icon: 'share', onclick: () => exportEnergy('json') });
    const clearBtn = actionButton(ui, ui.t('清理能耗记录'), {
      tone: 'destructive', icon: 'trash', disabled: true,
    });
    return group(ui, {
      title: '能耗与电费',
      footnote: '当前版本不支持清理能耗记录；导出范围为最近一个月。',
    },
    row(ui, { title: '导出本月能耗', sub: 'CSV 带 BOM，可直接用 Excel 打开。', control: h('span', { class: 'sc-info-actions' }, csv, json) }),
    divider(),
    row(ui, { title: '清理能耗记录', sub: '当前版本暂未提供清理接口。', control: clearBtn }));
  }

  function portControlGroup() {
    const sw = switchRow(ui, {
      title: '允许端口开关',
      sub: '开启后可在总览页开关端口与设置倒计时。',
      checked: writesEnabledValue(),
      onChange: (on) => setWritesEnabled(on),
    });
    return group(ui, { title: '端口控制' }, sw.el);
  }

  function advancedGroup() {
    const capture = switchRow(ui, {
      title: '记录原始报文', checked: false, disabled: true,
    });
    const exportBtn = actionButton(ui, ui.t('导出诊断…'), { tone: 'primary', disabled: true });
    const revealBtn = actionButton(ui, ui.t('在资源管理器中显示'), { disabled: true });
    return group(ui, {
      title: '高级',
      footnote: '诊断功能在此 Windows 移植版中暂未提供。',
    },
    capture.el,
    divider(),
    row(ui, { title: '诊断日志', sub: '尚未接入诊断日志。', control: h('span', { class: 'sc-info-actions' }, exportBtn, revealBtn) }));
  }

  function aboutGroup() {
    const version = (state && state.app && state.app.version) || '—';
    return group(ui, { title: '关于与更新' },
      row(ui, { title: '版本', control: h('span', { class: 'sc-adv__value', text: version }) }),
      divider(),
      row(ui, {
        title: '查看「关于」',
        control: actionButton(ui, ui.t('关于'), {
          tone: 'quiet', icon: 'info',
          onclick: () => { if (ui.ctx && typeof ui.ctx.navigate === 'function') ui.ctx.navigate('about'); },
        }),
      }),
      divider(),
      row(ui, {
        title: '软件更新',
        sub: '此版本不包含自动更新；请从 GitHub 获取新版本。',
        control: actionButton(ui, ui.t('检查更新…'), { disabled: true }),
      }));
  }

  function capabilitiesGroup() {
    const cloud = capabilityCard({
      icon: 'cloud',
      title: 'Anker Prime 250W 与 Wi-Fi 云端',
      body: '250W 机型的云端数据需要 Anker 账号与 Wi-Fi 连接，这条链路没有移植到 Windows。',
      meta: '此 Windows 移植版暂未支持',
    });
    const matter = capabilityCard({
      icon: 'homekit',
      title: 'Apple 家庭（Matter）',
      body: '本版本不包含 HomeKit / Matter 配件服务，因此没有配对二维码与手动配对码。',
      meta: '此 Windows 移植版暂未支持',
    });
    return h('section', { class: 'sc-group' },
      h('div', { class: 'sc-group__label' },
        h('span', { class: 'ck-t-label', text: ui.t('平台支持') }),
        chip(ui.t('部分功能不可用'), 'warn')),
      h('div', { class: 'sc-group__stack' }, cloud, matter),
      h('p', { class: 'sc-group__foot ck-u-cjk', text: ui.t('其余功能为 Windows 原生实现，缺失部分会随着后续版本补齐。') }));
  }

  function capabilityCard({ icon, title, body, meta }) {
    return card('sc-cap',
      h('div', { class: 'sc-cap__head' },
        h('span', { class: 'sc-cap__tile' }, ui.el(icon, 14)),
        h('h2', { class: 'sc-cap__title ck-t-heading', text: ui.t(title) }),
        chip(ui.t('暂不支持'), 'warn')),
      h('p', { class: 'sc-cap__body ck-u-cjk', text: ui.t(body) }),
      h('p', { class: 'sc-cap__meta', text: ui.t(meta) }));
  }

  // ---- lifecycle ----------------------------------------------------------

  function update(nextUi, nextState) {
    if (disposed) return;
    const localeChanged = builtLocale !== nextUi.locale;
    ui = nextUi;
    state = nextState || {};
    if (localeChanged || !content.firstChild) {
      build();
      return;
    }
    const sig = signature();
    if (sig !== lastSig) {
      lastSig = sig;
      renderContent();
    }
  }

  function dispose() {
    if (disposed) return;
    disposed = true;
    instances.delete(inst);
  }

  const inst = { update, dispose, get screen() { return screen; } };
  return inst;
}
