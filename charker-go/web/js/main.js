// RootView: the sidebar (device chip, sections, demo footer), the detail
// page with its entrance, and the floating action message. The window has no
// system title bar; the top strip drags it and leaves room for the caption
// buttons Windows draws at the right.

import { html, render, useEffect, useState } from './lib.js';
import { loadLocale, t, tf } from './core/l10n.js';
import { activeDisplayName, hasRememberedCharger, phaseShortLabel } from './core/model.js';
import {
  boot,
  getState,
  selectSection,
  setActionMessage,
  setPrefs,
  subscribe,
  useStore,
} from './core/store.js';
import { Chip, Icon, SlateCard, StateDot, cx } from './ui/components.js';

const SECTIONS = [
  { id: 'dashboard', title: '总览', symbol: 'bolt.fill', module: './pages/overview.js' },
  { id: 'energy', title: '能耗记录', symbol: 'chart.bar.xaxis', module: './pages/energy.js' },
  {
    id: 'devices',
    title: '设备与连接',
    symbol: 'antenna.radiowaves.left.and.right',
    module: './pages/devices.js',
  },
  { id: 'menuBar', title: '菜单栏', symbol: 'menubar.rectangle', module: './pages/menubar.js' },
  { id: 'advanced', title: '高级', symbol: 'wrench.and.screwdriver', module: './pages/advanced.js' },
  { id: 'about', title: '关于', symbol: 'info.circle', module: './pages/about.js' },
];

const pageCache = new Map();

function usePage(section) {
  const entry = SECTIONS.find((s) => s.id === section) || SECTIONS[0];
  const [page, setPage] = useState(() => pageCache.get(entry.id) || null);
  useEffect(() => {
    let live = true;
    if (pageCache.has(entry.id)) {
      setPage(pageCache.get(entry.id));
      return undefined;
    }
    setPage(null);
    import(entry.module)
      .then((m) => {
        pageCache.set(entry.id, m.default);
        if (live) setPage(() => m.default);
      })
      .catch((err) => {
        console.error(err);
        setActionMessage(String(err?.message || err));
      });
    return () => {
      live = false;
    };
  }, [entry.id]);
  return page;
}

function deviceTitle(state) {
  if (state.prefs.demoMode) return t('模拟 Prime 160W');
  const fallback = hasRememberedCharger(state) ? t('未连接') : t('查找充电器');
  const name = activeDisplayName(state) ?? fallback;
  const prefix = 'Anker ';
  return name.startsWith(prefix) && name.length > prefix.length ? name.slice(prefix.length) : name;
}

function DeviceChip({ state }) {
  const title = deviceTitle(state);
  return html`<button
    class="device-chip"
    title=${t('打开「设备与连接」')}
    aria-label=${tf('%@，%@', title, phaseShortLabel(state.session))}
    onClick=${() => selectSection('devices')}
  >
    <div class="device-chip__top">
      <img class="device-chip__brand" src="assets/brand/Anker.svg" alt="" />
      <span class="device-chip__status">
        <${StateDot} session=${state.session} diameter=${6} glowsWhenLive=${false} />
        <span>${phaseShortLabel(state.session)}</span>
      </span>
    </div>
    <div class="device-chip__name">
      <span>${title}</span>
      <${Icon} name="chevron.right" class="device-chip__chevron" />
    </div>
  </button>`;
}

function Sidebar({ state, section }) {
  return html`<nav class="sidebar">
    <div class="titlebar titlebar--sidebar">
      <img class="titlebar__icon" src="assets/app-icon.png" alt="" />
      <span class="titlebar__name">Charker</span>
    </div>
    <div class="sidebar__chip"><${DeviceChip} state=${state} /></div>
    ${SECTIONS.map(
      (s) => html`<button
        class=${cx('sidebar-row', s.id === section && 'is-selected')}
        aria-current=${s.id === section ? 'page' : undefined}
        onClick=${() => selectSection(s.id)}
      >
        <${Icon} name=${s.symbol} class="sidebar-row__icon" />
        <span>${t(s.title)}</span>
      </button>`,
    )}
    <div class="sidebar__spacer"></div>
    <div class="sidebar__footer">
      ${state.prefs.demoMode
        ? html`<div class="sidebar__demo">
            <${Chip} text=${t('演示模式')} tone="accent" />
            <button
              class="sidebar__exit"
              title=${t('退出模拟并查找真实充电器')}
              onClick=${() => setPrefs({ demoMode: false })}
            >
              <${Icon} name="xmark.circle" />
              <span>${t('退出')}</span>
            </button>
          </div>`
        : null}
      <span class="t-micro c-tertiary">${tf('Charker %@', state.app.version)}</span>
    </div>
  </nav>`;
}

function ActionMessage({ message }) {
  if (!message) return null;
  return html`<div class="action-message">
    <${SlateCard} padding=${12} class="action-message__card">
      <${Icon} name="info.circle.fill" class="c-accent" />
      <span class="t-caption c-secondary para">${message}</span>
      <button class="action-message__close" aria-label=${t('关闭')} onClick=${() => setActionMessage(null)}>
        <${Icon} name="xmark" />
      </button>
    </${SlateCard}>
  </div>`;
}

function Detail({ state, section }) {
  const Page = usePage(section);
  return html`<main class="detail">
    <div class="titlebar titlebar--detail"></div>
    ${Page ? html`<div class="detail__page" key=${section}><${Page} state=${state} /></div>` : null}
  </main>`;
}

function Root() {
  const [state, ui] = useStore();
  useEffect(() => {
    const entry = SECTIONS.find((s) => s.id === ui.section);
    window.mygo?.window?.setTitle?.(entry ? `Charker · ${t(entry.title)}` : 'Charker');
  }, [ui.section, state.app.locale]);
  return html`<div class="root">
    <${Sidebar} state=${state} section=${ui.section} />
    <${Detail} state=${state} section=${ui.section} />
    <${ActionMessage} message=${ui.actionMessage} />
  </div>`;
}

function applyAppearance(appearance) {
  const dark =
    appearance === 'dark' ||
    (appearance !== 'light' && window.matchMedia('(prefers-color-scheme: dark)').matches);
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
}

async function start() {
  const host = document.getElementById('app');
  try {
    const state = await boot();
    await loadLocale(state.app.locale);
    applyAppearance(state.prefs.appearance);
    window
      .matchMedia('(prefers-color-scheme: dark)')
      .addEventListener('change', () => applyAppearance(getState().prefs.appearance));
    // Language and appearance changes apply to the whole tree.
    let locale = state.app.locale;
    let appearance = state.prefs.appearance;
    subscribe(async () => {
      const s = getState();
      if (s.prefs.appearance !== appearance) {
        appearance = s.prefs.appearance;
        applyAppearance(appearance);
      }
      if (s.app.locale !== locale) {
        locale = s.app.locale;
        await loadLocale(locale);
        render(null, host);
        render(html`<${Root} />`, host);
      }
    });
    host.textContent = '';
    render(html`<${Root} />`, host);
  } catch (err) {
    console.error(err);
    host.innerHTML = '';
    const p = document.createElement('p');
    p.className = 'boot-error';
    p.textContent = String(err?.message || err);
    host.appendChild(p);
  }
}

// Ctrl+1…6 switch sections, like ⌘1…⌘6 on macOS.
document.addEventListener('keydown', (e) => {
  if (!e.ctrlKey || e.altKey || e.metaKey) return;
  const n = Number(e.key);
  if (n >= 1 && n <= SECTIONS.length) {
    e.preventDefault();
    selectSection(SECTIONS[n - 1].id);
  }
});

start();
