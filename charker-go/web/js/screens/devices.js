// Devices screen (#/devices) — owner: web-screens.
//
// Current connection (product, redacted address, RSSI, ladder, disconnect),
// saved chargers, the nearby-device scan panel (Charker.ScanStart/ScanStop,
// Charker.Connect), the demo-mode switch (Charker.UseMock), and phase notices.

import {
  makeUI, h, txt, clear, pageHead, actionButton, card, cardHead, chip,
  notice, emptyState, group, switchRow, callSafe, signalBars, redactAddress,
  relativeText, timeText, durationText,
} from './screens-util.js';

const PRODUCT_NAMES = { a2687: 'Anker Prime 160W', a2345: 'Anker Prime 250W' };

const PHASE_INFO = {
  idle: { label: '未连接', detail: '等待扫描或选择充电器', progress: 0.02, state: 'idle', busy: false },
  scanning: { label: '搜索中', detail: '正在搜索附近的 Anker Prime 充电器', progress: 0.2, state: 'warn', busy: true },
  connecting: { label: '连接中', detail: '正在连接充电器', progress: 0.45, state: 'warn', busy: true },
  handshake: { label: '握手中', detail: '正在协商会话', progress: 0.72, state: 'warn', busy: true },
  polling: { label: '已连接', detail: '正在接收实时数据', progress: 1, state: 'ok', busy: false },
  reconnecting: { label: '重连中', detail: '连接中断，正在重试', progress: 0.35, state: 'warn', busy: true },
  failed: { label: '连接失败', detail: '请确认充电器已通电，并退出正在占用它的 Anker App', progress: 0, state: 'danger', busy: false },
};

let instances = new Set();

export function render(root, state, ctx) {
  let inst = root.__scDevices;
  if (!inst) {
    inst = createDevicesScreen(root);
    root.__scDevices = inst;
    instances.add(inst);
  }
  inst.update(makeUI(ctx, state), state);
}

export function cleanup() {
  for (const inst of instances) inst.dispose();
  instances.clear();
}

function createDevicesScreen(root) {
  const screen = h('div', { class: 'sc-screen sc-devices' });
  const noticeHost = h('div', { class: 'sc-devices__notices' });
  const content = h('div', { class: 'sc-devices__content' });
  root.append(screen);
  screen.append(noticeHost, content);

  let ui = null;
  let state = null;
  let builtLocale = null;
  let disposed = false;
  let busy = false; // a connect/scan command is in flight
  let lastSig = '';
  const cleanups = [];

  function build() {
    builtLocale = ui.locale;
    clear(content);
    clear(noticeHost);
    const oldHead = screen.querySelector('.ck-page__head');
    if (oldHead) oldHead.remove();
    const head = pageHead(ui, '设备与连接');
    screen.prepend(head);
    renderContent();
  }

  function phaseInfo() {
    const phase = (state && state.phase) || 'idle';
    const info = PHASE_INFO[phase] || PHASE_INFO.idle;
    return { ...info, phase };
  }

  function currentDevice() {
    const d = state && state.device;
    if (!d) return null;
    if (d.connected === false && !(state.phase === 'polling' || state.phase === 'handshake')) return null;
    return d;
  }

  function allDevices() {
    return Array.isArray(state && state.devices) ? state.devices.filter((d) => d && d.id) : [];
  }

  function nearbyDevices() {
    const current = currentDevice();
    return allDevices().filter((d) => !d.connected && (!current || d.id !== current.id));
  }

  function savedDevices() {
    const current = currentDevice();
    return allDevices().filter((d) => d.saved || (current && d.id === current.id));
  }

  function signature() {
    const d = currentDevice();
    const nearby = nearbyDevices();
    return JSON.stringify({
      busy,
      phase: state && state.phase,
      scanning: !!(state && state.scanning),
      mock: !!(state && state.app && state.app.mock),
      current: d ? [d.id, d.name, d.rssi, d.address, d.connected] : null,
      nearby: nearby.map((n) => [n.id, n.name, n.rssi, n.saved, n.product]),
      saved: savedDevices().map((s) => [s.id, s.name, s.saved]),
      notice: state && state.notice ? [state.notice.kind, state.notice.text] : null,
      locale: ui.locale,
    });
  }

  // ---- rendering ----------------------------------------------------------

  function renderContent() {
    clear(content);
    const phase = phaseInfo();
    const current = currentDevice();
    const nearby = nearbyDevices();
    const saved = savedDevices();
    const mock = !!(state && state.app && state.app.mock);

    renderNotices(phase, current, nearby, saved);

    if (!current && !nearby.length && !saved.length) {
      content.append(onboardingCard(phase));
    }
    if (mock && current) content.append(mockBanner());
    if (current) content.append(currentCard(current, phase));
    if (saved.length) content.append(savedCard(saved, current));
    content.append(scanCard(nearby, phase, mock));
    content.append(testingGroup(mock));
  }

  function renderNotices(phase, current, nearby, saved) {
    clear(noticeHost);
    const note = state && state.notice;
    const pushed = [];
    if (phase.phase === 'failed') {
      pushed.push(notice(ui, 'error',
        (note && note.kind !== 'info' && note.text) || ui.t('连接失败。请确认充电器已通电，并退出正在占用它的官方 Anker App。')));
    } else if (!current && (phase.phase === 'scanning' || (state && state.scanning))) {
      pushed.push(h('div', { class: 'sc-notice sc-notice--info', role: 'status' },
        ui.el('radio', 13, 'sc-notice__ico sc-scan-pulse'),
        h('span', { class: 'sc-notice__text', text: ui.t('正在搜索附近的 Anker Prime 充电器…') })));
    } else if (phase.phase === 'connecting' || phase.phase === 'handshake' || phase.phase === 'reconnecting') {
      pushed.push(h('div', { class: 'sc-notice sc-notice--info', role: 'status' },
        h('span', { class: 'ck-spinner sc-notice__ico' }),
        h('span', { class: 'sc-notice__text', text: ui.t(phase.detail) })));
    }
    if (note && note.text && !pushed.some((el) => el.textContent && el.textContent.includes(note.text))) {
      const kind = note.kind === 'error' ? 'error' : note.kind === 'warn' ? 'warn' : 'info';
      pushed.push(notice(ui, kind, note.text));
    }
    for (const el of pushed) noticeHost.append(el);
  }

  function onboardingCard(phase) {
    const scanning = !!(state && state.scanning) || phase.phase === 'scanning';
    return card('sc-onboard',
      h('div', { class: 'sc-onboard__top' },
        h('div', { class: 'sc-onboard__media' },
          h('div', { class: 'sc-radar', 'aria-hidden': 'true' },
            h('span', { class: 'sc-radar__ring' }), h('span', { class: 'sc-radar__ring' }), h('span', { class: 'sc-radar__ring' })),
          h('img', { src: './assets/models/a2687-hero.png', alt: '', width: '74' })),
        h('div', { class: 'sc-onboard__text' },
          h('h2', { class: 'sc-onboard__title ck-t-heading', text: ui.t('连接第一台充电器') }),
          h('p', { class: 'ck-t-caption sc-muted ck-u-cjk', text: ui.t('无需在 macOS 蓝牙设置里配对。') }),
          h('div', { class: 'sc-steps' },
            step(1, '给 Anker Prime 充电器通电'),
            step(2, '退出可能正在占用它的官方 Anker App'),
            step(3, '在下方选择带“充电器”标记的设备并点“连接”')),
          h('div', { class: 'sc-info-actions' },
            actionButton(ui, scanning ? ui.t('正在扫描…') : ui.t('扫描附近设备'), {
              tone: scanning ? '' : 'primary', icon: 'radio', disabled: scanning || busy,
              onclick: () => startScan(),
            }),
            actionButton(ui, ui.t('重新选择型号'), {
              tone: 'quiet', icon: 'arrow-left',
              onclick: () => ui.toast(ui.t('首次设置在此 Windows 移植版中暂不可用'), 'warn'),
            })))));
  }

  function step(n, key) {
    return h('div', { class: 'sc-step' },
      h('span', { class: 'sc-step__num', text: String(n) }),
      h('span', { class: 'sc-step__text', text: ui.t(key) }));
  }

  function mockBanner() {
    return card('sc-demo',
      h('span', { class: 'sc-demo__tile' }, ui.el('play', 12)),
      h('span', { class: 'sc-demo__text', text: ui.t('正在使用模拟设备') }),
      h('div', { class: 'sc-info-actions' },
        actionButton(ui, ui.t('退出模拟'), {
          onclick: () => setMock(false),
        })));
  }

  function setMock(on) {
    if (busy) return;
    busy = true;
    callSafe(ui, 'Charker.UseMock', [on], null).then((out) => {
      busy = false;
      if (disposed) return;
      if (out && out.__error) ui.toast(ui.t('操作失败：%@', out.__error.message || out.__error), 'error');
      refresh();
    });
  }

  function routingText() {
    return phaseInfo();
  }

  function currentCard(device, phase) {
    const productName = PRODUCT_NAMES[String(device.product)] || device.name || '—';
    const rssi = Number.isFinite(Number(device.rssi)) ? Number(device.rssi) : null;
    const lastUpdated = state && Number(state.lastUpdatedMs);
    const updatedText = lastUpdated > 0 ? relativeText(ui, Date.now() - lastUpdated) : '—';
    const ladderFill = h('div', { class: 'sc-ladder__fill', style: { width: `${Math.round(phase.progress * 100)}%` } });
    const live = phase.phase === 'polling';
    const info = !live;
    const el = card('sc-current',
      cardHead(ui, {
        title: '当前连接',
        chipText: !!(state.app && state.app.mock) ? ui.t('演示数据') : '',
        chipTone: 'neutral',
        right: [
          actionButton(ui, ui.t('重新连接'), {
            icon: 'refresh', disabled: busy,
            onclick: () => reconnect(device),
          }),
        ],
      }),
      h('div', { class: 'sc-current__body' },
        h('div', { class: 'sc-stagewell' },
          h('img', {
            src: productHero(device.product), alt: '',
          })),
        h('div', { class: 'sc-current__identity' },
          h('div', { class: 'sc-current__name' },
            h('h2', { text: device.name || productName }),
            device.mock ? chip(ui.t('模拟'), 'accent') : null,
            device.saved ? chip(ui.t('已保存'), 'neutral') : null),
          h('div', { class: 'sc-current__sub ck-t-caption', text: productName }),
          h('div', { class: 'sc-ladder' },
            h('div', { class: 'sc-ladder__row' },
              h('span', { class: 'ck-state-dot', dataset: { state: phase.state, busy: phase.busy ? 'true' : 'false' } }),
              h('span', { class: 'sc-ladder__label', text: ui.t(phase.label) }),
              h('span', { class: 'sc-ladder__detail', text: ui.t(phase.detail) })),
            h('div', { class: 'sc-ladder__bar' }, ladderFill)),
          h('div', { class: 'sc-meta' },
            h('div', { class: 'sc-meta__cells' },
              metaCell(ui.t('产品型号'), productName),
              metaCell(ui.t('蓝牙地址'), redactAddress(device.address))),
            h('div', { class: 'sc-meta__row' },
              h('span', { class: 'sc-meta__label ck-t-micro', text: ui.t('信号强度') }),
              h('span', { class: 'sc-meta__grow' }),
              rssi == null ? h('span', { class: 'sc-meta__value', text: '—' })
                : h('span', { class: 'sc-saved__detail', text: `${rssi} dBm` }),
              signalBars(rssi)),
            h('div', { class: 'sc-meta__row' },
              h('span', { class: 'sc-meta__label ck-t-micro', text: ui.t('最后更新') }),
              h('span', { class: 'sc-meta__grow' }),
              h('span', { class: 'sc-meta__value', text: updatedText })),
            h('div', { class: 'sc-meta__row' },
              h('span', { class: 'sc-meta__label ck-t-micro', text: ui.t('固件版本') }),
              h('span', { class: 'sc-meta__grow' }),
              h('span', { class: 'sc-meta__value', text: '—' }))))),
      h('div', { class: 'sc-info-actions' },
        actionButton(ui, ui.t('断开连接'), {
          tone: 'destructive', icon: 'x-circle', disabled: busy,
          onclick: () => disconnect(),
        })));
    return el;
  }

  function metaCell(label, value) {
    return h('div', { class: 'sc-meta__cell' },
      h('span', { class: 'sc-meta__label ck-t-micro', text: label }),
      h('span', { class: 'sc-meta__value', text: value }));
  }

  function savedCard(saved, current) {
    return h('section', { class: 'ck-card sc-saved' },
      h('div', { class: 'sc-saved__head', style: { padding: '14px 16px 10px' } },
        cardHead(ui, { title: '我的充电器', chipText: ui.t('%d 台', saved.length) })),
      h('div', { class: 'sc-saved__list' },
        ...saved.map((device) => {
          const isCurrent = current && device.id === current.id;
          const productName = PRODUCT_NAMES[String(device.product)] || device.name || '—';
          return h('div', { class: `sc-saved__row${isCurrent ? ' sc-saved__row--current' : ''}` },
            h('span', { class: 'sc-saved__check' }, ui.el(isCurrent ? 'check-circle' : 'radio', 13)),
            h('div', { class: 'sc-saved__text' },
              h('span', { class: 'sc-saved__name', text: device.name || productName }),
              h('span', { class: 'sc-saved__detail', text: productName })),
            isCurrent
              ? h('span', { class: 'sc-saved__status', text: ui.t('已连接') })
              : actionButton(ui, ui.t('切换'), {
                tone: 'quiet', disabled: busy,
                onclick: () => connectTo(device),
              }));
        })));
  }

  function scanCard(nearby, phase, mock) {
    const scanning = !!(state && state.scanning) || phase.phase === 'scanning';
    const list = h('div', { class: 'sc-nearby__list' });
    if (nearby.length) {
      for (const device of nearby) {
        const productName = PRODUCT_NAMES[String(device.product)] || ui.t('充电器');
        const rssi = Number.isFinite(Number(device.rssi)) ? Number(device.rssi) : null;
        const subtitle = [
          rssi == null ? ui.t('信号强度未报告') : `${rssi} dBm`,
          device.name && device.name !== productName ? productName : null,
          device.mock ? ui.t('模拟') : null,
        ].filter(Boolean).join(' · ');
        list.append(h('div', { class: 'sc-nearby__row' },
          signalBars(rssi),
          h('div', { class: 'sc-nearby__text' },
            h('span', { class: 'sc-nearby__name', text: device.name || productName }),
            h('span', { class: 'sc-nearby__sub', text: subtitle })),
          device.saved ? chip(ui.t('已保存'), 'accent') : chip(ui.t('充电器'), 'accent'),
          actionButton(ui, ui.t('连接'), { tone: 'quiet', disabled: busy, onclick: () => connectTo(device) })));
      }
    } else {
      list.append(h('p', { class: 'sc-nearby__empty ck-u-cjk', text: scanning
        ? ui.t('正在扫描附近的蓝牙设备…')
        : ui.t('尚未发现设备。请确认充电器已通电，且官方 Anker App 没有连着它。') }));
    }
    return h('section', { class: 'ck-card sc-nearby' },
      cardHead(ui, {
        title: '附近的蓝牙设备',
        right: [
          actionButton(ui, scanning ? ui.t('停止扫描') : ui.t('重新扫描'), {
            icon: scanning ? 'x' : 'refresh', disabled: busy,
            onclick: () => (scanning ? stopScan() : startScan()),
          }),
        ],
      }),
      mock ? h('p', { class: 'sc-nearby__empty', text: ui.t('演示模式下不扫描真实蓝牙设备。') }) : null,
      list);
  }

  function testingGroup(mock) {
    const sw = switchRow(ui, {
      title: '演示模式（模拟充电器）',
      sub: '打开后使用模拟充电器，不连接真实蓝牙设备。',
      checked: mock,
      onChange: (on) => setMock(on),
      disabled: busy || (currentDevice() && !mock),
      note: mock ? ui.t('正在演示') : '',
    });
    return group(ui, { title: '测试', footnote: '演示数据不会写入本机记录。' }, sw.el);
  }

  // ---- commands -----------------------------------------------------------

  function startScan() {
    if (busy) return;
    busy = true;
    refresh();
    callSafe(ui, 'Charker.ScanStart', [], null).then((out) => {
      busy = false;
      if (disposed) return;
      if (out && out.__error) ui.toast(ui.t('无法开始扫描：%@', out.__error.message || out.__error), 'error');
      refresh();
    });
  }

  function stopScan() {
    if (busy) return;
    busy = true;
    refresh();
    callSafe(ui, 'Charker.ScanStop', [], null).then((out) => {
      busy = false;
      if (disposed) return;
      if (out && out.__error) ui.toast(ui.t('无法停止扫描：%@', out.__error.message || out.__error), 'error');
      refresh();
    });
  }

  function connectTo(device) {
    if (busy || !device) return;
    busy = true;
    refresh();
    callSafe(ui, 'Charker.Connect', [device.id], null).then((out) => {
      busy = false;
      if (disposed) return;
      if (out && out.__error) ui.toast(ui.t('连接失败：%@', out.__error.message || out.__error), 'error');
      refresh();
    });
  }

  function reconnect(device) {
    connectTo(device);
  }

  function disconnect() {
    if (busy) return;
    busy = true;
    refresh();
    callSafe(ui, 'Charker.Disconnect', [], null).then((out) => {
      busy = false;
      if (disposed) return;
      if (out && out.__error) ui.toast(ui.t('断开连接失败：%@', out.__error.message || out.__error), 'error');
      else ui.toast(ui.t('已断开连接'), 'info');
      refresh();
    });
  }

  // ---- lifecycle ----------------------------------------------------------

  function productHero(product) {
    return String(product) === 'a2345' ? './assets/models/a2345-hero.png' : './assets/models/a2687-hero.png';
  }

  function refresh() {
    const sig = signature();
    if (sig !== lastSig || builtLocale !== ui.locale) {
      lastSig = sig;
      renderContent();
    }
  }

  function update(nextUi, nextState) {
    if (disposed) return;
    const localeChanged = builtLocale !== nextUi.locale;
    ui = nextUi;
    state = nextState || {};
    if (localeChanged || !screen.querySelector('.ck-page__head')) {
      build();
      lastSig = signature();
      return;
    }
    refresh();
  }

  function dispose() {
    if (disposed) return;
    disposed = true;
    instances.delete(inst);
  }

  const inst = { update, dispose, get screen() { return screen; } };
  return inst;
}
