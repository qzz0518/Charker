// ============================================================================
// Charker — application boot, shell, router (owner: web-shell)
//
// Responsibilities:
//   - paint the shell (sidebar + detail) once; update it in place afterwards
//   - boot the store (`Charker.State` once, then `state` events only)
//   - hash router (#/overview … #/about), body[data-route], Ctrl+1…6
//   - mount the screen modules: `render(root, state, ctx)` on a `.ck-page` root
//   - i18n/theme application, toasts, deviceLost, error boundary (never blank)
//
// Screens animate on entrance; main.js re-renders the current route on each
// state event (rAF-throttled) on the SAME root so live values update without
// losing DOM/focus. The root is cleared only on route switch or locale change.
// ============================================================================

import {
  EMPTY_STATE,
  getState,
  hasBridge,
  init as initStore,
  on,
  setState,
  subscribe,
  call,
} from './state.js';
import {
  applyI18n,
  detectLocale,
  getLocale,
  loadExternalStrings,
  onLocaleChange,
  setLocale,
  t,
} from './i18n.js';
import { fmt } from './format.js';
import { icon, icons } from './icons.js';

// ---------------------------------------------------------------------------
// Route table (contract §5: overview | energy | devices | menubar | advanced | about)

const ROUTES = ['overview', 'energy', 'devices', 'menubar', 'advanced', 'about'];

const ROUTE_ALIASES = {
  dashboard: 'overview',
  overview: 'overview',
  energy: 'energy',
  devices: 'devices',
  menubar: 'menubar',
  menuBar: 'menubar',
  settings: 'advanced',
  advanced: 'advanced',
  about: 'about',
};

/** route → screen module path (note: advanced lives in screens/settings.js) */
const ROUTE_MODULES = {
  overview: './screens/overview.js',
  energy: './screens/energy.js',
  devices: './screens/devices.js',
  menubar: './screens/menubar.js',
  advanced: './screens/settings.js',
  about: './screens/about.js',
};

const ROUTE_LABELS = {
  overview: '总览',
  energy: '能耗记录',
  devices: '设备与连接',
  menubar: '菜单栏',
  advanced: '高级',
  about: '关于',
};

const ROUTE_SUBTITLES = {
  overview: '实时功率、端口状态与能耗概览',
  energy: '用电统计、趋势与会话记录',
  devices: '蓝牙连接、设备设置与附近设备',
  menubar: '菜单栏读数样式与预设',
  advanced: '外观、启动、诊断与实验选项',
  about: '版本信息与开源项目',
};

const ROUTE_ICONS = {
  overview: 'bolt',
  energy: 'bar-chart',
  devices: 'radio',
  menubar: 'panel-top',
  advanced: 'wrench',
  about: 'info',
};

const query = new URLSearchParams(window.location.search);
const queryTheme = query.get('theme');
const queryLang = query.get('lang');
const themePinned = queryTheme === 'light' || queryTheme === 'dark';
const localePinned = queryLang === 'zh' || queryLang === 'en';

// ---------------------------------------------------------------------------
// Runtime state

const shell = {
  root: null,
  sidebar: null,
  resizer: null,
  nav: null,
  pill: null,
  deviceChip: null,
  statusDot: null,
  statusLabel: null,
  deviceName: null,
  footerActions: null,
  version: null,
  routeRoot: null,
  detail: null,
  toastStack: null,
};

const current = {
  route: '',
  root: null,
  module: null,
  ctx: null,
  cleanups: [],
};

const moduleCache = new Map();
let navigationToken = 0;
let pendingRender = false;
let themeMode = 'dark';
let themeResolved = 'dark';
let footerSignature = '';
let fatalShown = false;
let resizing = null;

const clamp = (n, lo, hi) => Math.min(hi, Math.max(lo, n));

function normalizeRoute(value) {
  if (value == null) return '';
  let route = String(value).trim();
  if (!route) return '';
  route = route.replace(/^#/, '').replace(/^\/+/, '');
  route = route.split('?')[0].split('/')[0];
  const exact = Object.keys(ROUTE_ALIASES).find((key) => key.toLowerCase() === route.toLowerCase());
  if (exact) route = ROUTE_ALIASES[exact];
  return ROUTES.includes(route) ? route : '';
}

function routeFromHash() {
  return normalizeRoute(window.location.hash) || 'overview';
}

function navigate(route) {
  const next = normalizeRoute(route) || 'overview';
  const target = `#/${next}`;
  if (window.location.hash === target) {
    mountRoute(next);
    return;
  }
  window.location.hash = target;
}

// ---------------------------------------------------------------------------
// Theme

function resolveTheme(mode) {
  if (mode === 'light' || mode === 'dark') return mode;
  if (mode === 'system') {
    try {
      return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
    } catch (_) {
      return 'dark';
    }
  }
  return 'dark';
}

function applyTheme(mode) {
  themeMode = mode === 'light' || mode === 'dark' || mode === 'system' ? mode : 'system';
  themeResolved = resolveTheme(themeMode);
  document.documentElement.dataset.theme = themeResolved;
  return themeResolved;
}

function getTheme() {
  return themeMode;
}

function setTheme(mode) {
  applyTheme(mode);
  call('Charker.SetTheme', themeMode).catch(() => {});
}

function applyThemeFromState(state) {
  if (themePinned) return;
  const next = state && state.app && state.app.theme;
  if ((next === 'light' || next === 'dark' || next === 'system') && next !== themeMode) {
    applyTheme(next);
  }
}

// ---------------------------------------------------------------------------
// Locale

function applyLocaleFromState(state) {
  if (localePinned) return;
  const next = state && state.app && state.app.locale;
  if ((next === 'zh' || next === 'en') && next !== getLocale()) {
    setLocale(next);
  }
}

// ---------------------------------------------------------------------------
// Shell markup

function brandMarkup() {
  return (
    `<img class="ck-side__brand" src="./assets/brand/Anker.svg" alt="ANKER" draggable="false" ` +
    `width="42" height="10">`
  );
}

function navMarkup() {
  return ROUTES.map((route) => {
    const label = ROUTE_LABELS[route];
    return (
      `<a class="ck-side__row" id="nav-${route}" href="#/${route}" data-nav-route="${route}" ` +
      `data-i18n-aria="${label}">` +
      `<span class="ck-side__icon" aria-hidden="true">${icon(ROUTE_ICONS[route])}</span>` +
      `<span class="ck-side__label" data-i18n="${label}">${t(label)}</span>` +
      `</a>`
    );
  }).join('');
}

function renderShellMarkup() {
  return (
    `<div class="ck-shell" id="ck-shell">` +
    `<aside class="ck-shell__sidebar" id="ck-sidebar" aria-label="Charker">` +
    `<div class="ck-side__top">` +
    `<button class="ck-side__device" id="shell-device-chip" type="button" data-i18n-aria="打开「设备与连接」" data-i18n-title="打开「设备与连接」">` +
    `<span class="ck-side__device-top">` +
    `<span class="ck-side__brand-wrap">${brandMarkup()}</span>` +
    `<span class="ck-side__status"><span class="ck-state-dot" id="shell-status-dot" data-state="idle"></span>` +
    `<span id="shell-status-label">${t('未连接')}</span></span>` +
    `</span>` +
    `<span class="ck-side__device-bottom">` +
    `<span class="ck-side__device-name" id="shell-device-name">${t('未连接')}</span>` +
    `<span class="ck-side__chevron" aria-hidden="true">${icon('chevron-right')}</span>` +
    `</span>` +
    `</button>` +
    `</div>` +
    `<nav class="ck-side__nav" id="shell-nav" aria-label="Charker">` +
    `<span class="ck-side__pill" id="shell-nav-pill" aria-hidden="true"></span>` +
    navMarkup() +
    `</nav>` +
    `<div class="ck-side__footer">` +
    `<span class="ck-side__version" id="shell-version">Charker 0.1.0</span>` +
    `<span class="ck-side__footer-actions" id="shell-footer-actions"></span>` +
    `</div>` +
    `<button class="ck-shell__resizer" id="shell-resizer" type="button" role="separator" ` +
    `aria-orientation="vertical" aria-label="调整侧边栏宽度" tabindex="0" title="拖动调整侧边栏宽度，双击恢复"></button>` +
    `</aside>` +
    `<main class="ck-shell__detail" id="shell-detail" aria-label="Charker">` +
    `<div class="ck-route" id="shell-route" data-route="overview"></div>` +
    `<div class="ck-toast-stack" id="shell-toasts" aria-live="polite" aria-atomic="false"></div>` +
    `</main>` +
    `</div>`
  );
}

function buildShell() {
  const app = document.getElementById('app');
  if (!app) throw new Error('#app container missing from index.html');
  app.textContent = '';
  const template = document.createElement('template');
  template.innerHTML = renderShellMarkup();
  app.append(template.content);

  shell.root = document.getElementById('ck-shell');
  shell.sidebar = document.getElementById('ck-sidebar');
  shell.resizer = document.getElementById('shell-resizer');
  shell.nav = document.getElementById('shell-nav');
  shell.pill = document.getElementById('shell-nav-pill');
  shell.deviceChip = document.getElementById('shell-device-chip');
  shell.statusDot = document.getElementById('shell-status-dot');
  shell.statusLabel = document.getElementById('shell-status-label');
  shell.deviceName = document.getElementById('shell-device-name');
  shell.footerActions = document.getElementById('shell-footer-actions');
  shell.version = document.getElementById('shell-version');
  shell.routeRoot = document.getElementById('shell-route');
  shell.detail = document.getElementById('shell-detail');
  shell.toastStack = document.getElementById('shell-toasts');

  // ANKER wordmark fallback: text mark if the SVG asset cannot load.
  const brand = shell.deviceChip.querySelector('.ck-side__brand');
  if (brand) {
    brand.addEventListener('error', () => {
      const fallback = document.createElement('span');
      fallback.className = 'ck-side__brand ck-side__brand--text';
      fallback.textContent = 'ANKER';
      brand.replaceWith(fallback);
    });
  }

  shell.deviceChip.addEventListener('click', () => navigate('devices'));
  initResizer();
  if (typeof ResizeObserver === 'function') {
    const observer = new ResizeObserver(() => updateNavPill());
    observer.observe(shell.sidebar);
  }
  window.addEventListener('resize', requestPillUpdate);
}

// ---------------------------------------------------------------------------
// Sidebar resize (196 … 240, ideal 208; double-click / Home resets)

function setSidebarWidth(px) {
  const width = clamp(Math.round(px), 196, 240);
  document.documentElement.style.setProperty('--ck-sidebar-w', `${width}px`);
  updateNavPill();
}

function initResizer() {
  const handle = shell.resizer;
  const sidebar = shell.sidebar;
  if (!handle || !sidebar) return;

  handle.addEventListener('pointerdown', (event) => {
    event.preventDefault();
    resizing = {
      startX: event.clientX,
      startWidth: sidebar.getBoundingClientRect().width,
    };
    handle.dataset.dragging = 'true';
    try {
      handle.setPointerCapture(event.pointerId);
    } catch (_) {
      /* pointer capture unsupported */
    }
  });

  handle.addEventListener('pointermove', (event) => {
    if (!resizing) return;
    setSidebarWidth(resizing.startWidth + (event.clientX - resizing.startX));
  });

  const stop = () => {
    resizing = null;
    handle.dataset.dragging = 'false';
  };
  handle.addEventListener('pointerup', stop);
  handle.addEventListener('pointercancel', stop);
  handle.addEventListener('lostpointercapture', stop);

  handle.addEventListener('dblclick', () => {
    document.documentElement.style.removeProperty('--ck-sidebar-w');
    updateNavPill();
  });

  handle.addEventListener('keydown', (event) => {
    const width = sidebar.getBoundingClientRect().width;
    if (event.key === 'ArrowLeft') {
      event.preventDefault();
      setSidebarWidth(width - 8);
    } else if (event.key === 'ArrowRight') {
      event.preventDefault();
      setSidebarWidth(width + 8);
    } else if (event.key === 'Home') {
      event.preventDefault();
      document.documentElement.style.removeProperty('--ck-sidebar-w');
      updateNavPill();
    }
  });
}

function requestPillUpdate() {
  window.requestAnimationFrame(updateNavPill);
}

/** Slide the selection capsule under the active nav row. */
function updateNavPill() {
  if (!shell.nav || !shell.pill) return;
  const active = shell.nav.querySelector('[data-nav-route][aria-current="page"]');
  if (!active) {
    shell.pill.style.opacity = '0';
    return;
  }
  const navRect = shell.nav.getBoundingClientRect();
  const rowRect = active.getBoundingClientRect();
  const offset = rowRect.top - navRect.top + shell.nav.scrollTop;
  shell.pill.style.transform = `translateY(${Math.round(offset)}px)`;
  shell.pill.style.height = `${Math.round(rowRect.height)}px`;
  shell.pill.style.opacity = '1';
}

// ---------------------------------------------------------------------------
// Shell chrome updates

const PHASE_STATUS = {
  polling: { key: '已连接', dot: 'ok', busy: false },
  handshake: { key: '握手中', dot: 'idle', busy: true },
  connecting: { key: '连接中', dot: 'idle', busy: true },
  scanning: { key: '搜索中', dot: 'idle', busy: true },
  reconnecting: { key: '重连中', dot: 'warn', busy: true },
  failed: { key: '连接失败', dot: 'danger', busy: false },
  idle: { key: '未连接', dot: 'idle', busy: false },
};

function updateShellChrome(state) {
  if (!shell.statusDot) return;
  const snapshot = state || EMPTY_STATE;
  const connected = Boolean(snapshot.device && snapshot.device.connected);
  const phase = snapshot.phase || 'idle';
  const status = PHASE_STATUS[phase] || (connected ? PHASE_STATUS.polling : PHASE_STATUS.idle);

  shell.statusDot.dataset.state = status.dot;
  shell.statusDot.dataset.busy = status.busy ? 'true' : 'false';
  shell.statusLabel.textContent = t(status.key);

  const name = snapshot.device && snapshot.device.name ? snapshot.device.name : t('未连接');
  if (shell.deviceName.textContent !== name) shell.deviceName.textContent = name;

  const version = snapshot.app && snapshot.app.version ? snapshot.app.version : '0.1.0';
  const versionText = `Charker ${version}`;
  if (shell.version.textContent !== versionText) shell.version.textContent = versionText;

  const isMock = Boolean(snapshot.app && snapshot.app.mock);
  const signature = `${isMock ? 'mock' : 'real'}:${version}`;
  if (signature !== footerSignature) {
    footerSignature = signature;
    renderFooterActions(isMock);
  }
}

function renderFooterActions(isMock) {
  if (!shell.footerActions) return;
  shell.footerActions.textContent = '';
  if (!isMock) return;
  const chip = document.createElement('span');
  chip.className = 'ck-chip ck-chip--accent';
  chip.textContent = t('演示模式');
  const exit = document.createElement('button');
  exit.type = 'button';
  exit.className = 'ck-side__exit';
  exit.textContent = t('退出');
  exit.addEventListener('click', () => {
    call('Charker.UseMock', false).catch((err) => {
      showToast({ kind: 'warn', text: t('操作失败：%@', err && err.message ? err.message : err) });
    });
  });
  shell.footerActions.append(chip, exit);
}

// ---------------------------------------------------------------------------
// Toasts

function showToast(payload) {
  if (!shell.toastStack) return;
  const data = payload && typeof payload === 'object' ? payload : { text: payload };
  const kind = ['info', 'warn', 'error'].includes(data.kind) ? data.kind : 'info';
  const text = data.text == null ? '' : String(data.text);
  if (!text) return;

  const card = document.createElement('div');
  card.className = `ck-toast ck-toast--${kind}`;
  card.setAttribute('role', kind === 'error' ? 'alert' : 'status');

  const iconBox = document.createElement('span');
  iconBox.className = 'ck-toast__icon';
  iconBox.setAttribute('aria-hidden', 'true');
  iconBox.innerHTML = icon(kind === 'error' ? 'alert-circle' : kind === 'warn' ? 'alert-triangle' : 'info');

  const body = document.createElement('span');
  body.className = 'ck-toast__text';
  body.textContent = text;

  const close = document.createElement('button');
  close.type = 'button';
  close.className = 'ck-toast__close ck-icon-btn ck-icon-btn--plain';
  close.setAttribute('aria-label', t('关闭'));
  close.innerHTML = icon('x', { size: 12 });

  card.append(iconBox, body, close);
  shell.toastStack.append(card);

  while (shell.toastStack.childElementCount > 4) {
    shell.toastStack.firstElementChild.remove();
  }

  const timer = window.setTimeout(remove, kind === 'error' ? 7000 : 4500);
  function remove() {
    window.clearTimeout(timer);
    card.remove();
  }
  close.addEventListener('click', remove);
}

// ---------------------------------------------------------------------------
// Error boundary

function errorText(err) {
  if (!err) return t('未知错误');
  if (typeof err === 'string') return err;
  if (err.message) return `${err.name && err.name !== 'Error' ? `${err.name}: ` : ''}${err.message}`;
  try {
    return JSON.stringify(err);
  } catch (_) {
    return String(err);
  }
}

/** Render a readable panel into the route root instead of leaving a blank page. */
function showRouteError(err, route) {
  const root = current.root;
  if (!root) return;
  console.error(`[charker] route "${route || current.route}" failed`, err);
  if (root.querySelector('.ck-error')) return;
  root.textContent = '';

  const section = document.createElement('section');
  section.className = 'ck-error';
  section.setAttribute('role', 'alert');

  const head = document.createElement('div');
  head.className = 'ck-error__head';
  const headIcon = document.createElement('span');
  headIcon.setAttribute('aria-hidden', 'true');
  headIcon.innerHTML = icon('alert-triangle');
  const title = document.createElement('h2');
  title.className = 'ck-error__title';
  title.textContent = t('页面渲染出错');
  head.append(headIcon, title);

  const message = document.createElement('p');
  message.className = 'ck-error__msg';
  message.textContent = errorText(err);

  const actions = document.createElement('div');
  actions.className = 'ck-error__actions';
  const reload = document.createElement('button');
  reload.type = 'button';
  reload.className = 'ck-btn ck-btn--primary';
  reload.textContent = t('重新加载');
  reload.addEventListener('click', () => window.location.reload());
  const back = document.createElement('button');
  back.type = 'button';
  back.className = 'ck-btn ck-btn--quiet';
  back.textContent = t('返回总览');
  back.addEventListener('click', () => navigate('overview'));
  actions.append(reload);
  if ((route || current.route) !== 'overview') actions.append(back);

  section.append(head, message, actions);
  root.append(section);
}

/** Last-resort fallback when even the shell cannot be built. */
function showFatalBoot(err) {
  if (fatalShown) return;
  fatalShown = true;
  console.error('[charker] boot failed', err);
  const app = document.getElementById('app');
  if (!app) return;
  app.textContent = '';
  const wrap = document.createElement('div');
  wrap.style.cssText = 'padding:28px;max-width:720px;margin:0 auto;';
  const section = document.createElement('section');
  section.className = 'ck-error';
  section.setAttribute('role', 'alert');
  const head = document.createElement('div');
  head.className = 'ck-error__head';
  const headIcon = document.createElement('span');
  headIcon.setAttribute('aria-hidden', 'true');
  headIcon.innerHTML = icon('alert-triangle');
  const title = document.createElement('h2');
  title.className = 'ck-error__title';
  title.textContent = t('页面渲染出错');
  head.append(headIcon, title);
  const message = document.createElement('p');
  message.className = 'ck-error__msg';
  message.textContent = errorText(err);
  const actions = document.createElement('div');
  actions.className = 'ck-error__actions';
  const reload = document.createElement('button');
  reload.type = 'button';
  reload.className = 'ck-btn ck-btn--primary';
  reload.textContent = t('重新加载');
  reload.addEventListener('click', () => window.location.reload());
  actions.append(reload);
  section.append(head, message, actions);
  wrap.append(section);
  app.append(wrap);
}

// ---------------------------------------------------------------------------
// Router / screen mounting

function cleanupRoute() {
  for (const fn of current.cleanups.splice(0).reverse()) {
    try {
      fn();
    } catch (err) {
      console.error('[charker] route cleanup failed', err);
    }
  }
  if (current.module && typeof current.module.cleanup === 'function') {
    try {
      current.module.cleanup();
    } catch (err) {
      console.error('[charker] screen cleanup failed', err);
    }
  }
}

function makeCtx() {
  return {
    route: current.route,
    navigate,
    t,
    call: (method, ...args) => call(method, ...args),
    icons,
    icon: (name, opts) => icon(name, opts),
    onCleanup(fn) {
      if (typeof fn === 'function') current.cleanups.push(fn);
    },
    onState(fn) {
      return subscribe(fn);
    },
    onEvent: (event, fn) => on(event, fn),
    toast(text, kind = 'info') {
      showToast({ kind, text: text == null ? '' : String(text) });
    },
    setLocale(next) {
      setLocale(next);
      call('Charker.SetLocale', getLocale()).catch(() => {});
    },
    setTheme,
    getTheme,
    applyTheme,
    fmt,
    routes: ROUTES.slice(),
  };
}

/**
 * Shared segmented-control behaviour. Screen helpers may create `.ck-seg`
 * markup and set `--n`/`--i`; setting custom properties through
 * `Object.assign(el.style, {...})` silently fails (a CSSStyleDeclaration
 * ignores `style['--x'] = …`), so the shell normalizes every control after a
 * render. Also gives the tablist roving tabindex.
 */
function syncSegControls(root) {
  if (!root) return;
  for (const seg of root.querySelectorAll('.ck-seg')) {
    const items = Array.from(seg.querySelectorAll(':scope > .ck-seg__item'));
    if (!items.length) continue;
    if (!seg.style.getPropertyValue('--n')) seg.style.setProperty('--n', String(items.length));
    items.forEach((item, index) => {
      if (item.getAttribute('aria-selected') === 'true') {
        seg.style.setProperty('--i', String(index));
        item.tabIndex = 0;
      } else {
        item.tabIndex = -1;
      }
    });
  }
}

function renderCurrent() {
  if (!current.module || !current.root) return;
  const state = getState();
  try {
    if (typeof current.module.render !== 'function') {
      throw new Error(`screen module "${current.route}" does not export render(root, state, ctx)`);
    }
    current.module.render(current.root, state, current.ctx);
    syncSegControls(current.root);
  } catch (err) {
    showRouteError(err, current.route);
  }
}

function scheduleRender() {
  if (pendingRender) return;
  pendingRender = true;
  window.requestAnimationFrame(() => {
    pendingRender = false;
    renderCurrent();
  });
}

function updateNavState(route) {
  if (!shell.nav) return;
  for (const row of shell.nav.querySelectorAll('[data-nav-route]')) {
    if (row.dataset.navRoute === route) row.setAttribute('aria-current', 'page');
    else row.removeAttribute('aria-current');
  }
  updateNavPill();
}

async function loadScreenModule(route) {
  if (moduleCache.has(route)) return moduleCache.get(route);
  const mod = await import(ROUTE_MODULES[route]);
  moduleCache.set(route, mod);
  return mod;
}

async function mountRoute(routeValue, { force = false } = {}) {
  const route = normalizeRoute(routeValue) || 'overview';
  if (!force && route === current.route && current.root) {
    scheduleRender();
    return;
  }
  const token = ++navigationToken;
  cleanupRoute();
  current.route = route;
  current.module = null;
  current.root = null;
  current.ctx = null;

  document.body.dataset.route = route;
  document.title = `Charker · ${t(ROUTE_LABELS[route] || '总览')}`;
  updateNavState(route);

  const routeRoot = shell.routeRoot;
  if (!routeRoot) return;
  routeRoot.dataset.route = route;
  routeRoot.textContent = '';
  const root = document.createElement('div');
  root.className = 'ck-page';
  root.id = 'ck-page';
  routeRoot.append(root);
  current.root = root;
  current.ctx = makeCtx();

  let module;
  try {
    module = await loadScreenModule(route);
  } catch (err) {
    if (token !== navigationToken) return;
    showRouteError(
      new Error(`无法加载页面模块 ${ROUTE_MODULES[route]}：${errorText(err)}`),
      route,
    );
    return;
  }
  if (token !== navigationToken) return;
  current.module = module;
  renderCurrent();
  requestPillUpdate();
}

// ---------------------------------------------------------------------------
// Store wiring

function handleStateChanged(state) {
  applyLocaleFromState(state);
  applyThemeFromState(state);
  updateShellChrome(state);
  scheduleRender();
}

function wireStoreEvents() {
  on('state', (payload) => {
    setState(payload == null ? {} : payload);
  });
  on('toast', (payload) => showToast(payload));
  on('deviceLost', () => {
    showToast({ kind: 'warn', text: t('设备连接已断开') });
  });
  on('mygo:locale', (payload) => {
    if (localePinned) return;
    const tag = typeof payload === 'string' ? payload : payload && (payload.locale || payload.tag || payload.value);
    if (typeof tag === 'string' && tag) setLocale(/^zh/i.test(tag) ? 'zh' : 'en');
  });
  on('mygo:preferences', (payload) => {
    if (themePinned) return;
    const theme = payload && (payload.theme || (payload.value && payload.value.theme));
    if (theme === 'light' || theme === 'dark' || theme === 'system') applyTheme(theme);
  });

  subscribe(handleStateChanged);

  onLocaleChange(() => {
    applyI18n(document);
    updateShellChrome(getState());
    footerSignature = '';
    document.title = `Charker · ${t(ROUTE_LABELS[current.route] || '总览')}`;
    if (current.route) mountRoute(current.route, { force: true });
  });
}

// ---------------------------------------------------------------------------
// Keyboard + global keys

function installKeyboard() {
  window.addEventListener('keydown', (event) => {
    if (event.defaultPrevented) return;
    const modifier = event.ctrlKey || event.metaKey;
    if (!modifier || event.altKey || event.shiftKey) return;
    const index = Number(event.key);
    if (Number.isInteger(index) && index >= 1 && index <= ROUTES.length) {
      event.preventDefault();
      navigate(ROUTES[index - 1]);
    }
  });
}

function installGlobalErrorHandlers() {
  window.addEventListener('error', (event) => {
    const error = event && (event.error || event.message);
    if (!error) return;
    console.error('[charker] uncaught error', error);
  });
  window.addEventListener('unhandledrejection', (event) => {
    const reason = event && event.reason;
    console.error('[charker] unhandled rejection', reason);
    const message = errorText(reason);
    if (message && message !== 'undefined') {
      showToast({ kind: 'warn', text: t('发生了一个错误：%@', message) });
    }
  });
}

// ---------------------------------------------------------------------------
// Boot

function initialTheme() {
  if (queryTheme === 'light' || queryTheme === 'dark') return queryTheme;
  if (query.get('mock') === 'light') return 'light';
  const bridgeTheme = window.mygo && window.mygo.preferences && window.mygo.preferences.theme;
  if (bridgeTheme === 'light' || bridgeTheme === 'dark' || bridgeTheme === 'system') return bridgeTheme;
  const attr = document.documentElement.dataset.theme;
  return attr === 'light' ? 'light' : 'dark';
}

async function boot() {
  applyTheme(initialTheme());

  const initialLocale = detectLocale();
  setLocale(initialLocale);
  await loadExternalStrings();
  setLocale(getLocale());

  buildShell();
  applyI18n(document);
  installGlobalErrorHandlers();
  installKeyboard();
  wireStoreEvents();
  updateShellChrome(getState());

  window.addEventListener('hashchange', () => {
    mountRoute(routeFromHash());
  });

  try {
    await initStore();
  } catch (err) {
    console.error('[charker] Charker.State failed', err);
    showToast({ kind: 'warn', text: t('操作失败：%@', errorText(err)) });
  }

  const initialRoute = normalizeRoute(query.get('route')) || routeFromHash();
  await mountRoute(initialRoute);

  if (normalizeRoute(query.get('route')) && routeFromHash() !== initialRoute) {
    try {
      window.history.replaceState(null, '', `#/${initialRoute}`);
    } catch (_) {
      window.location.hash = `#/${initialRoute}`;
    }
  }

  // QA/automation handle (not used by the app itself)
  window.__charker = {
    routes: ROUTES.slice(),
    getState,
    setState,
    navigate,
    mountRoute: (route) => mountRoute(route, { force: true }),
    t,
    setLocale,
    setTheme,
    hasBridge,
    icons: icons.names,
  };
}

boot().catch((err) => {
  showFatalBoot(err);
});
