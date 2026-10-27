// 任务栏: the Mac's 菜单栏 page (MenuBarEditorView.swift MenuBarSettingsView)
// with the item model of CharkerCore MenuBarConfig. Windows shows no text in
// the notification area, so the menu bar title splits in two: the tray
// icon draws the live total as digits (internal/app/trayicon.go), and its
// tooltip shows the item layout, rendered in Go by the twin of renderItems()
// below (internal/app/menubar.go). The editor is a taskbar corner with that
// icon and its tooltip, whose items are edited in place. The Mac's icon
// options (show icon, symbol) and compact spacing have no counterpart.

import { html, useEffect, useLayoutEffect, useMemo, useRef, useState } from '../lib.js';
import { t, tf } from '../core/l10n.js';
import { call, setPrefs } from '../core/store.js';
import { activeDisplayName, activeProduct, phaseShortLabel } from '../core/model.js';
import { ActionButton, Icon, cx, openMenu } from '../ui/components.js';
import { registerIcons } from '../ui/icons.js';
import { Segmented, SettingsGroup, SettingsPage, SwitchRow } from './settings.js';

const L = (body) =>
  `<svg class="ck-icon" width="1em" height="1em" viewBox="0 0 24 24" fill="none" ` +
  `stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" ` +
  `aria-hidden="true" focusable="false">${body}</svg>`;

registerIcons({
  number: L(
    '<line x1="4" x2="20" y1="9" y2="9"/><line x1="4" x2="20" y1="15" y2="15"/>' +
      '<line x1="10" x2="8" y1="3" y2="21"/><line x1="16" x2="14" y1="3" y2="21"/>',
  ),
  tag: L(
    '<path d="M12.586 2.586A2 2 0 0 0 11.172 2H4a2 2 0 0 0-2 2v7.172a2 2 0 0 0 .586 1.414l8.704 8.704a2.426 2.426 0 0 0 3.42 0l6.58-6.58a2.426 2.426 0 0 0 0-3.42z"/>' +
      '<circle cx="7.5" cy="7.5" r=".5" fill="currentColor"/>',
  ),
  'circle.grid.2x1': L(
    '<circle cx="6.5" cy="12" r="3.5" fill="currentColor" stroke="none"/>' +
      '<circle cx="17.5" cy="12" r="3.5" fill="currentColor" stroke="none"/>',
  ),
  'character.cursor.ibeam': L(
    '<path d="M5 4h1a3 3 0 0 1 3 3 3 3 0 0 1 3-3h1"/><path d="M13 20h-1a3 3 0 0 1-3-3 3 3 0 0 1-3 3H5"/>' +
      '<path d="M5 16H4a2 2 0 0 1-2-2v-4a2 2 0 0 1 2-2h1"/><path d="M13 8h7a2 2 0 0 1 2 2v4a2 2 0 0 1-2 2h-7"/><path d="M9 7v10"/>',
  ),
  'plus.circle.solid': L(
    '<circle cx="12" cy="12" r="10" fill="currentColor" stroke="none"/>' +
      '<path d="M7.5 12h9M12 7.5v9" stroke="#fff" stroke-width="2.4"/>',
  ),
  'speaker.wave.2': L(
    '<path d="M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587A1.4 1.4 0 0 1 5.416 8H3a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2.416a1.4 1.4 0 0 1 .997.413l3.383 3.384A.705.705 0 0 0 11 19.298z"/>' +
      '<path d="M16 9a5 5 0 0 1 0 6"/><path d="M19.364 18.364a9 9 0 0 0 0-12.728"/>',
  ),
});

// ---- MenuBarItem / MenuBarConfig ----------------------------------------------

// ChargerPortID labels by raw value: the A2687 has the first three ports,
// the A2345 all six.
const PORT_LABELS = ['C1', 'C2', 'C3', 'C4', 'A1', 'A2'];

export { activeProduct };
const KINDS = ['totalPower', 'portPower', 'portsCount', 'state', 'deviceName', 'separator', 'text'];
const PLACEHOLDER = '—';

function newId() {
  const uuid = globalThis.crypto?.randomUUID?.();
  if (uuid) return uuid.toUpperCase();
  return 'xxxxxxxx-xxxx-4xxx-8xxx-xxxxxxxxxxxx'.replace(/x/g, () =>
    Math.floor(Math.random() * 16).toString(16).toUpperCase(),
  );
}

/** MenuBarItem(kind:…) with the Swift initializer's defaults. */
export function makeItem(kind, fields = {}) {
  return { id: newId(), kind, showsUnit: true, showsPortName: true, ...fields };
}

const isUnique = (item) => item.kind !== 'separator' && item.kind !== 'text';
const uniqueKey = (item) => (item.kind === 'portPower' ? `portPower.${item.port ?? -1}` : item.kind);

/** MenuBarConfig.decode: item-tolerant; null when nothing is stored. */
function decodeItems(raw) {
  if (!Array.isArray(raw)) return null;
  return raw
    .filter((item) => item && KINDS.includes(item.kind))
    .map((item) => ({
      ...item,
      id: item.id || newId(),
      showsUnit: item.showsUnit ?? true,
      showsPortName: item.showsPortName ?? true,
    }));
}

/** MenuBarConfig.parse for the A2687's tokens. */
export function parseTemplate(template) {
  const tokens = { '{total}': 'totalPower', '{ports}': 'portsCount', '{state}': 'state', '{device}': 'deviceName' };
  const items = [];
  let buffer = '';
  const flush = () => {
    const text = buffer.trim();
    buffer = '';
    if (text) items.push(makeItem('text', { label: text }));
  };
  let rest = String(template || '');
  outer: while (rest) {
    const ch = rest[0];
    if (ch === '·' || ch === '|') {
      flush();
      items.push(makeItem('separator', { label: ch }));
      rest = rest.slice(1);
      continue;
    }
    if (ch === '{') {
      for (const [token, kind] of Object.entries(tokens)) {
        if (rest.startsWith(token)) {
          flush();
          items.push(makeItem(kind));
          rest = rest.slice(token.length);
          continue outer;
        }
      }
      for (let port = 0; port < PORT_LABELS.length; port++) {
        const token = `{${PORT_LABELS[port].toLowerCase()}}`;
        if (!rest.startsWith(token)) continue;
        if (buffer.trim().toLowerCase() === PORT_LABELS[port].toLowerCase()) {
          buffer = '';
          items.push(makeItem('portPower', { port, showsPortName: true }));
        } else {
          flush();
          items.push(makeItem('portPower', { port, showsPortName: false }));
        }
        rest = rest.slice(token.length);
        continue outer;
      }
    }
    const [first] = rest;
    buffer += first;
    rest = rest.slice(first.length);
  }
  flush();
  return items;
}

/** MenuBarConfig.serialize: lossy by design. */
export function serializeItems(items) {
  return items
    .map((item) => {
      switch (item.kind) {
        case 'totalPower':
          return '{total}';
        case 'portPower': {
          const name = PORT_LABELS[item.port];
          if (!name) return null;
          const token = `{${name.toLowerCase()}}`;
          return item.showsPortName ? `${item.label ?? name} ${token}` : token;
        }
        case 'portsCount':
          return item.label == null && item.systemContent === 'activePortsCount' ? `{ports} ${t('口')}` : '{ports}';
        case 'state':
          return '{state}';
        case 'deviceName':
          return '{device}';
        case 'separator':
          return item.label ?? '·';
        case 'text':
          if (item.label != null) return item.label;
          return item.systemContent === 'sampleText' ? t('文本') : null;
        default:
          return null;
      }
    })
    .filter((s) => s != null)
    .join(' ');
}

const portOf = (ctx, index) => ctx.telemetry?.ports?.find((p) => p.port === PORT_LABELS[index]) || null;
const on = (p) => !!p && p.statusCode !== 0;
const delivering = (p) => on(p) && p.current > 0.02 && p.voltage > 3.0;

/**
 * MenuBarConfig.display: one item against live data, or null when it
 * elides. ctx: {ports, telemetry, stateLabel, deviceName, decimals,
 * hideIdlePorts, nicknames}. The tooltip has no width to hold steady, so
 * figures are not padded as the Mac status item pads them.
 */
export function displayItem(item, ctx, { placeholder = PLACEHOLDER } = {}) {
  const format = (watts) => {
    const decimals = Math.max(0, Math.min(3, item.decimals ?? ctx.decimals));
    const number = watts.toFixed(decimals);
    return item.showsUnit ? `${number} W` : number;
  };
  const prefixed = (value, label) => (label ? `${label} ${value}` : value);
  switch (item.kind) {
    case 'totalPower': {
      const ports = ctx.telemetry?.ports;
      const value = ports ? format(ports.reduce((s, p) => s + (on(p) ? p.power : 0), 0)) : placeholder;
      return prefixed(value, item.label);
    }
    case 'portPower': {
      const index = item.port;
      // A port of another product elides.
      if (!(index >= 0 && index < PORT_LABELS.length) || !ctx.ports.includes(PORT_LABELS[index])) return null;
      const nickname = ctx.nicknames?.[index] || '';
      const name = item.label ?? (nickname || PORT_LABELS[index]);
      const p = portOf(ctx, index);
      if (!p) return prefixed(placeholder, item.showsPortName ? name : null);
      if (ctx.hideIdlePorts && !delivering(p)) return null;
      return prefixed(format(on(p) ? p.power : 0), item.showsPortName ? name : null);
    }
    case 'portsCount': {
      const count = (ctx.telemetry?.ports || []).filter(delivering).length;
      if (item.label != null) return prefixed(String(count), item.label);
      if (item.systemContent === 'activePortsCount') return tf('%d 口', count);
      return String(count);
    }
    case 'state':
      return ctx.stateLabel;
    case 'deviceName':
      return ctx.deviceName || 'Charker';
    case 'separator':
      return item.label ?? '·';
    case 'text': {
      if (item.label != null) return item.label === '' ? null : item.label;
      const text = item.systemContent === 'sampleText' ? t('文本') : '';
      return text || null;
    }
    default:
      return null;
  }
}

/** MenuBarConfig.render: separator-delimited runs collapse. */
export function renderItems(items, ctx, options = {}) {
  const runs = [];
  let current = { parts: [], portItems: 0, elided: 0, separatorAfter: null };
  for (const item of items) {
    if (item.kind === 'separator') {
      current.separatorAfter = item.label ?? '·';
      runs.push(current);
      current = { parts: [], portItems: 0, elided: 0, separatorAfter: null };
      continue;
    }
    if (item.kind === 'portPower') current.portItems += 1;
    const text = displayItem(item, ctx, options);
    if (text != null) current.parts.push(text);
    else if (item.kind === 'portPower') current.elided += 1;
  }
  runs.push(current);
  const kept = runs.filter((r) => r.parts.length && !(r.portItems > 0 && r.portItems === r.elided));
  return kept
    .map((r, i) => r.parts.join(' ') + (i < kept.length - 1 ? ` ${r.separatorAfter ?? '·'} ` : ''))
    .join('');
}

/** MenuBarConfig.presets. */
const PRESETS = [
  ['总功率', () => [makeItem('totalPower')]],
  ['纯数字', () => [makeItem('totalPower', { showsUnit: false, decimals: 0 })]],
  [
    '总功率 · 端口数',
    () => [makeItem('totalPower'), makeItem('separator', { label: '·' }), makeItem('portsCount', { systemContent: 'activePortsCount' })],
  ],
  ['C1 · C2', () => [makeItem('portPower', { port: 0 }), makeItem('separator', { label: '·' }), makeItem('portPower', { port: 1 })]],
  [
    '三口功率',
    () => [
      makeItem('portPower', { port: 0 }),
      makeItem('separator', { label: '·' }),
      makeItem('portPower', { port: 1 }),
      makeItem('separator', { label: '·' }),
      makeItem('portPower', { port: 2 }),
    ],
  ],
  ['总功率｜状态', () => [makeItem('totalPower'), makeItem('separator', { label: '|' }), makeItem('state')]],
  ['设备名 · 总功率', () => [makeItem('deviceName'), makeItem('separator', { label: '·' }), makeItem('totalPower')]],
  [
    '极简三口',
    () =>
      [0, 1, 2].flatMap((port, i) => [
        ...(i ? [makeItem('separator', { label: '|' })] : []),
        makeItem('portPower', { port, showsUnit: false, showsPortName: false, decimals: 0 }),
      ]),
  ],
];

/** StatusTemplate.tokens, the A2687's. */
const TOKENS = [
  ['{total}', '总功率'],
  ['{c1}', 'C1 口功率'],
  ['{c2}', 'C2 口功率'],
  ['{c3}', 'C3 口功率'],
  ['{c4}', 'C4 口功率'],
  ['{a1}', 'A1 口功率'],
  ['{a2}', 'A2 口功率'],
  ['{ports}', '正在输出的端口数'],
  ['{state}', '连接状态，例如「已连接」'],
  ['{device}', '充电器名称'],
];

function typeTitle(item) {
  switch (item.kind) {
    case 'totalPower':
      return t('总功率');
    case 'portPower':
      return tf('%@ 功率', PORT_LABELS[item.port] ?? t('端口'));
    case 'portsCount':
      return t('输出端口数');
    case 'state':
      return t('连接状态');
    case 'deviceName':
      return t('设备名称');
    case 'separator':
      return t('分隔符');
    default:
      return t('自定义文本');
  }
}

const TYPE_SYMBOLS = {
  totalPower: 'bolt.fill',
  portPower: 'powerplug',
  portsCount: 'number',
  state: 'dot.radiowaves.left.and.right',
  deviceName: 'tag',
  separator: 'circle.grid.2x1',
  text: 'character.cursor.ibeam',
};

/** The live inputs every render reads (AppModel's active reading). */
function readoutContext(state, hideIdlePorts) {
  return {
    ports: activeProduct(state).ports,
    telemetry: state.session.telemetry,
    stateLabel: phaseShortLabel(state.session),
    deviceName: activeDisplayName(state),
    decimals: state.prefs.decimals,
    hideIdlePorts,
    nicknames: state.prefs.portNicknames || [],
  };
}

// The layout of a pre-items configuration, parsed once per template so its
// ids hold still until the first edit stores it.
let parsedTemplate = { template: null, items: [] };
function layoutOf(prefs) {
  const stored = decodeItems(prefs.menuBarItems);
  if (stored) return stored;
  if (parsedTemplate.template !== prefs.statusTemplate) {
    parsedTemplate = { template: prefs.statusTemplate, items: parseTemplate(prefs.statusTemplate || '{total}') };
  }
  return parsedTemplate.items;
}

/** Preferences.menuBarItems setter: the template follows the items. */
function setItems(items) {
  return setPrefs({ menuBarItems: items, statusTemplate: serializeItems(items) }).catch(() => {});
}

// ---- The page -----------------------------------------------------------------

export default function TaskbarPage({ state }) {
  const p = state.prefs;
  const stored = layoutOf(p);
  const [selection, setSelection] = useState(null);
  const [draft, setDraft] = useState(null); // the order while a chip is dragged
  const items = draft || stored;

  const update = (id, mutate) => {
    const next = items.map((item) => (item.id === id ? mutate({ ...item }) : item));
    setItems(next);
  };
  const insert = (item) => {
    const index = items.findIndex((i) => i.id === selection);
    const at = index >= 0 ? index + 1 : items.length;
    setItems([...items.slice(0, at), item, ...items.slice(at)]);
    setSelection(item.id);
  };
  // Deleting selects a neighbour, so Delete can walk down the row.
  const remove = (id) => {
    const index = items.findIndex((i) => i.id === id);
    if (index < 0) return;
    const next = items.filter((i) => i.id !== id);
    setItems(next);
    setSelection(next.length ? next[Math.min(index, next.length - 1)].id : null);
  };
  const move = (id, delta) => {
    const index = items.findIndex((i) => i.id === id);
    const target = index + delta;
    if (index < 0 || target < 0 || target >= items.length) return;
    const next = items.slice();
    [next[index], next[target]] = [next[target], next[index]];
    setItems(next);
    setSelection(id);
  };
  const apply = (preset) => {
    setItems(preset());
    setSelection(null);
  };

  const selected = items.find((i) => i.id === selection) || null;
  const presetCtx = readoutContext(state, false);
  const half = Math.ceil(PRESETS.length / 2);

  return html`<${SettingsPage} title=${t('任务栏')}>
    <${SettingsGroup}
      footnote=${t('Windows 会先把新图标收进任务栏的 ^ 里；把它拖到任务栏上就会一直显示。')}
    >
      <${SwitchRow}
        title=${t('在图标上显示实时功率')}
        on=${!p.showIconOnly}
        onChange=${(value) => setPrefs({ showIconOnly: !value }).catch(() => {})}
      />
      <${Editor}
        state=${state}
        items=${items}
        selection=${selection}
        setSelection=${setSelection}
        setDraft=${setDraft}
        insert=${insert}
        remove=${remove}
        move=${move}
      />
      <div class="mb-divider"></div>
      ${selected
        ? html`<${ItemInspector}
            key=${selected.id}
            item=${selected}
            isFirst=${items[0]?.id === selected.id}
            isLast=${items[items.length - 1]?.id === selected.id}
            globalDecimals=${p.decimals}
            nicknames=${p.portNicknames || []}
            update=${(mutate) => update(selected.id, mutate)}
            move=${(delta) => move(selected.id, delta)}
            remove=${() => remove(selected.id)}
          />`
        : html`<p class="t-caption c-tertiary mb-hint">${t('点选组件设置，拖动排序，⌫ 删除。')}</p>`}
    </${SettingsGroup}>

    <${SettingsGroup} title=${t('显示')}>
      <div class="settings-row">
        <span class="t-body c-primary">${t('默认小数位')}</span>
        <${Segmented}
          label=${t('默认小数位')}
          value=${p.decimals}
          style=${{ width: '168px' }}
          segments=${[0, 1, 2, 3].map((n) => ({ title: String(n), value: n }))}
          onChange=${(decimals) => setPrefs({ decimals }).catch(() => {})}
        />
      </div>
      <${SwitchRow}
        title=${t('隐藏没有输出的端口')}
        on=${p.hideIdlePorts}
        onChange=${(hideIdlePorts) => setPrefs({ hideIdlePorts }).catch(() => {})}
      />
    </${SettingsGroup}>

    <${SettingsGroup} title=${t('预设')} footnote=${t('应用预设会替换当前布局。')}>
      <div class="mb-presets">
        ${[PRESETS.slice(0, half), PRESETS.slice(half)].map(
          (row) => html`<div class="mb-presets__row">
            ${row.map(([name, build]) => {
              const sample = renderItems(build(), presetCtx);
              return html`<${ActionButton}
                key=${name}
                title=${t(name)}
                help=${sample || t('用这个组合替换当前布局')}
                onClick=${() => apply(build)}
              />`;
            })}
          </div>`,
        )}
      </div>
    </${SettingsGroup}>

    <${SettingsGroup}>
      <${TemplateDisclosure} items=${stored} />
    </${SettingsGroup}>
  </${SettingsPage}>`;
}

// ---- Editor canvas --------------------------------------------------------------

/** The whole-watt total the tray icon shows (trayDigits in Go). */
function iconDigits(state) {
  const s = state.session;
  if (state.prefs.showIconOnly || s.phase !== 'polling' || !s.telemetry) return '';
  const total = (s.telemetry.ports || []).reduce((sum, p) => sum + (on(p) ? p.power : 0), 0);
  return `${Math.min(999, Math.max(0, total)).toFixed(0)}/${s.isStale}`;
}

/**
 * The tray icon as the taskbar shows it now, from Go (the same renderer as
 * the real icon): its digits, the taskbar's mode and the tooltip.
 */
function useTrayPreview(state) {
  const [preview, setPreview] = useState(null);
  const key = `${iconDigits(state)}|${state.app.locale}`;
  useEffect(() => {
    let live = true;
    const load = () =>
      call('TrayIconPreview')
        .then((p) => live && setPreview(p))
        .catch(() => {});
    load();
    // The taskbar's mode can change while the digits hold still: read it
    // again whenever the window comes back to the front.
    window.addEventListener('focus', load);
    return () => {
      live = false;
      window.removeEventListener('focus', load);
    };
  }, [key]);
  return preview;
}

/**
 * The taskbar corner, live: the tray icon with its digits among the
 * system's icons, and its tooltip above it holding the items — the Mac's
 * menu bar strip, edited in place.
 */
function Editor({ state, items, selection, setSelection, setDraft, insert, remove, move }) {
  const root = useRef(null);
  const row = useRef(null);
  const icon = useRef(null);
  const [palette, setPalette] = useState(null); // the + button's rect while open
  const [dragging, setDragging] = useState(null);
  const [tipRight, setTipRight] = useState(0);
  const preview = useTrayPreview(state);
  const ctx = readoutContext(state, false);

  // The tooltip sits over the icon, as Windows shows it.
  useLayoutEffect(() => {
    const box = root.current?.getBoundingClientRect();
    const r = icon.current?.getBoundingClientRect();
    if (!box || !r) return;
    const right = Math.max(0, Math.round(box.right - (r.left + r.width / 2) - 24));
    if (right !== tipRight) setTipRight(right);
  });

  const select = (id) => {
    setSelection(id);
    root.current?.focus({ preventScroll: true });
  };

  const onKeyDown = (e) => {
    const index = items.findIndex((i) => i.id === selection);
    switch (e.key) {
      case 'Delete':
      case 'Backspace':
        if (index < 0) return;
        e.preventDefault();
        remove(selection);
        return;
      case 'ArrowLeft':
      case 'ArrowRight': {
        e.preventDefault();
        const delta = e.key === 'ArrowLeft' ? -1 : 1;
        if (index < 0) {
          const end = delta > 0 ? items[0] : items[items.length - 1];
          if (end) setSelection(end.id);
        } else if (e.altKey) {
          move(selection, delta);
        } else if (items[index + delta]) {
          setSelection(items[index + delta].id);
        }
        return;
      }
      case 'Escape':
        setSelection(null);
        return;
      default:
    }
  };

  // Real reorder, not a visual offset: the order changes as the pointer
  // crosses a neighbour's midpoint, and is stored when the drag ends.
  const startDrag = (e, item) => {
    if (e.button !== 0) return;
    const startX = e.clientX;
    const el = e.currentTarget;
    let order = null;
    let moved = false;
    const onMove = (ev) => {
      if (!moved && Math.abs(ev.clientX - startX) < 4) return;
      if (!moved) {
        moved = true;
        try {
          el.setPointerCapture(e.pointerId);
        } catch {}
        setDragging(item.id);
        select(item.id);
      }
      const current = order || items;
      const others = current.filter((i) => i.id !== item.id);
      const rects = new Map(
        [...row.current.querySelectorAll('[data-chip]')].map((c) => [c.dataset.chip, c.getBoundingClientRect()]),
      );
      const proposed = others.reduce((n, o) => {
        const r = rects.get(o.id);
        return n + (r && r.left + r.width / 2 < ev.clientX ? 1 : 0);
      }, 0);
      if (current.findIndex((i) => i.id === item.id) === proposed) return;
      order = [...others.slice(0, proposed), item, ...others.slice(proposed)];
      setDraft(order);
    };
    const onUp = () => {
      window.removeEventListener('pointermove', onMove);
      window.removeEventListener('pointerup', onUp);
      window.removeEventListener('pointercancel', onUp);
      if (!moved) {
        select(selection === item.id ? null : item.id);
        return;
      }
      setDragging(null);
      if (order) setItems(order).finally(() => setDraft(null));
      else setDraft(null);
    };
    window.addEventListener('pointermove', onMove);
    window.addEventListener('pointerup', onUp);
    window.addEventListener('pointercancel', onUp);
  };

  const contextMenu = (e, item) => {
    e.preventDefault();
    select(item.id);
    openMenu(e.currentTarget, [
      { title: t('左移'), disabled: items[0]?.id === item.id, action: () => move(item.id, -1) },
      { title: t('右移'), disabled: items[items.length - 1]?.id === item.id, action: () => move(item.id, 1) },
      { separator: true },
      { title: t('移除'), destructive: true, action: () => remove(item.id) },
    ]);
  };

  const dark = preview ? preview.dark : true;
  return html`<div
    ref=${root}
    class=${cx('mb-editor', dark ? 'is-dark' : 'is-light')}
    tabindex="0"
    role="group"
    aria-label=${t('菜单栏布局编辑器')}
    onKeyDown=${onKeyDown}
    onPointerDown=${(e) => {
      if (!e.target.closest('.mb-chip, .mb-editor__add, .mb-palette')) select(null);
    }}
  >
    <div class="mb-tip-row" style=${{ paddingRight: `${tipRight}px` }}>
      <div class="mb-tip" ref=${row}>
        <span class="mb-tip__app">Charker ·</span>
        ${items.map((item) => {
          const text = displayItem(item, ctx) ?? typeTitle(item);
          return html`<button
            key=${item.id}
            data-chip=${item.id}
            class=${cx('mb-chip', 'num', selection === item.id && 'is-selected', dragging === item.id && 'is-dragging')}
            aria-pressed=${selection === item.id}
            aria-label=${tf('%@，当前显示 %@', typeTitle(item), text)}
            title=${t('点按选中，按住拖动排序')}
            onPointerDown=${(e) => startDrag(e, item)}
            onContextMenu=${(e) => contextMenu(e, item)}
          >
            ${text}
          </button>`;
        })}
        <button
          class="mb-editor__add"
          title=${t('添加内容')}
          aria-label=${t('添加内容')}
          onClick=${(e) => setPalette(palette ? null : e.currentTarget.getBoundingClientRect())}
        >
          <${Icon} name="plus.circle.solid" />
        </button>
      </div>
    </div>
    <div class="mb-taskbar" aria-hidden="true">
      <${Icon} name="chevron-up" class="mb-taskbar__glyph" />
      <span class="mb-taskbar__icon" ref=${icon}>
        ${preview?.icon
          ? html`<img src=${preview.icon} alt="" draggable="false" />`
          : html`<img class="is-app" src="assets/app-icon.png" alt="" draggable="false" />`}
      </span>
      <span class="mb-taskbar__group">
        <${Icon} name="wifi" />
        <${Icon} name="speaker.wave.2" />
        <${Icon} name="battery.75percent" />
      </span>
      <span class="mb-taskbar__clock num"><span>9:41</span><span>2026/10/29</span></span>
    </div>
    ${palette
      ? html`<${Palette}
          anchor=${palette}
          state=${state}
          existing=${items}
          insert=${(item) => {
            insert(item);
            setPalette(null);
          }}
          close=${() => setPalette(null)}
        />`
      : null}
  </div>`;
}

// ---- Add palette ---------------------------------------------------------------

/**
 * The anchored component palette: categorised, each entry with a live
 * sample, duplicates of unique items disabled. openMenu cannot draw these
 * rows (icon, title and a right-aligned sample), so it is drawn here.
 */
function Palette({ anchor, state, existing, insert, close }) {
  const box = useRef(null);
  const [pos, setPos] = useState({ left: anchor.left, top: anchor.bottom + 6 });
  useLayoutEffect(() => {
    const m = box.current.getBoundingClientRect();
    let left = anchor.left + anchor.width / 2 - m.width / 2;
    left = Math.min(Math.max(8, left), window.innerWidth - m.width - 8);
    let top = anchor.bottom + 6;
    if (top + m.height > window.innerHeight - 8) top = Math.max(8, anchor.top - m.height - 6);
    if (left !== pos.left || top !== pos.top) setPos({ left, top });
  }, []);
  useEffect(() => {
    const outside = (e) => {
      if (!box.current?.contains(e.target)) close();
    };
    const key = (e) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        e.stopPropagation();
        close();
      }
    };
    const timer = setTimeout(() => document.addEventListener('pointerdown', outside, true));
    document.addEventListener('keydown', key, true);
    window.addEventListener('blur', close);
    return () => {
      clearTimeout(timer);
      document.removeEventListener('pointerdown', outside, true);
      document.removeEventListener('keydown', key, true);
      window.removeEventListener('blur', close);
    };
  }, []);

  const keys = new Set(existing.map(uniqueKey));
  const ctx = readoutContext(state, false);
  const categories = useMemo(
    () => [
      [
        '设备数据',
        [
          makeItem('totalPower'),
          ...activeProduct(state).ports.map((label) => makeItem('portPower', { port: PORT_LABELS.indexOf(label) })),
          makeItem('portsCount', { systemContent: 'activePortsCount' }),
        ],
      ],
      ['状态', [makeItem('state'), makeItem('deviceName')]],
      [
        '文本与分隔符',
        [makeItem('separator', { label: '·' }), makeItem('separator', { label: '|' }), makeItem('text', { systemContent: 'sampleText' })],
      ],
    ],
    [],
  );

  return html`<div
    ref=${box}
    class="mb-palette"
    role="menu"
    style=${{ left: `${pos.left}px`, top: `${pos.top}px` }}
    onPointerDown=${(e) => e.stopPropagation()}
  >
    ${categories.map(
      ([title, list]) => html`<div class="mb-palette__header">${t(title)}</div>
        ${list.map((item) => {
          const taken = isUnique(item) && keys.has(uniqueKey(item));
          const sample = displayItem(item, ctx) ?? '';
          return html`<button
            key=${item.id}
            class=${cx('mb-palette__row', taken && 'is-taken')}
            role="menuitem"
            disabled=${taken}
            title=${t(taken ? '这一项只能添加一次' : '插入到当前选中项之后')}
            onClick=${() => insert({ ...item, id: newId() })}
          >
            <${Icon} name=${TYPE_SYMBOLS[item.kind]} class="mb-palette__icon" />
            <span class="mb-palette__title">${typeTitle(item)}</span>
            <span class="mb-palette__sample num">${taken ? t('已添加') : sample}</span>
          </button>`;
        })}`,
    )}
  </div>`;
}

// ---- Item inspector --------------------------------------------------------------

/** Options for the selected component, inline below the editor. */
function ItemInspector({ item, isFirst, isLast, globalDecimals, nicknames, update, move, remove }) {
  const set = (fields) => update((copy) => Object.assign(copy, fields));
  // MenuBarItem.setUserLabel: built-in copy becomes the user's own text.
  const setUserLabel = (label) => set({ label, systemContent: undefined });
  const inherited = () => {
    const nickname = nicknames[item.port] || '';
    return nickname || PORT_LABELS[item.port] || t('端口');
  };

  const labelField = (placeholder) => html`<div class="mb-field-row">
    <span class="t-body c-primary">${t('标签')}</span>
    <input
      class="field mb-field"
      type="text"
      placeholder=${placeholder}
      value=${item.label ?? ''}
      onInput=${(e) => setUserLabel(e.currentTarget.value === '' ? undefined : e.currentTarget.value)}
    />
  </div>`;
  const unitToggle = html`<${SwitchRow}
    title=${t('显示单位 W')}
    on=${item.showsUnit}
    onChange=${(showsUnit) => set({ showsUnit })}
  />`;
  const decimalsPicker = html`<div class="settings-row">
    <span class="t-body c-primary">${t('小数位')}</span>
    <${Segmented}
      label=${t('小数位')}
      value=${item.decimals ?? -1}
      style=${{ width: '240px' }}
      segments=${[
        { title: tf('全局（%d）', globalDecimals), value: -1 },
        ...[0, 1, 2, 3].map((n) => ({ title: String(n), value: n })),
      ]}
      onChange=${(value) => set({ decimals: value === -1 ? undefined : value })}
    />
  </div>`;

  let options = null;
  switch (item.kind) {
    case 'totalPower':
      options = [labelField(t('无前缀')), unitToggle, decimalsPicker];
      break;
    case 'portPower':
      options = [
        html`<${SwitchRow}
          title=${t('显示端口名')}
          on=${item.showsPortName}
          onChange=${(showsPortName) => set({ showsPortName })}
        />`,
        labelField(inherited()),
        unitToggle,
        decimalsPicker,
      ];
      break;
    case 'portsCount':
      options = [labelField(t('无前缀'))];
      break;
    case 'separator':
      options = [
        html`<div class="settings-row">
          <span class="t-body c-primary">${t('样式')}</span>
          <${Segmented}
            label=${t('样式')}
            value=${item.label ?? '·'}
            style=${{ width: '110px' }}
            segments=${[
              { title: '·', value: '·' },
              { title: '|', value: '|' },
            ]}
            onChange=${(label) => setUserLabel(label)}
          />
        </div>`,
      ];
      break;
    case 'text':
      options = [
        html`<div class="mb-field-row">
          <span class="t-body c-primary">${t('内容')}</span>
          <input
            class="field mb-field"
            type="text"
            placeholder=${t('文本')}
            value=${item.label ?? (item.systemContent === 'sampleText' ? t('文本') : '')}
            onInput=${(e) => setUserLabel(e.currentTarget.value)}
          />
        </div>`,
      ];
      break;
    default:
  }

  return html`<div class="mb-inspector">
    <div class="mb-inspector__header">
      <${Icon} name=${TYPE_SYMBOLS[item.kind]} class="mb-inspector__symbol" />
      <span class="t-heading c-primary">${typeTitle(item)}</span>
      <span class="mb-inspector__spacer"></span>
      <button class="mb-borderless" disabled=${isFirst} title=${t('左移')} aria-label=${t('左移')} onClick=${() => move(-1)}>
        <${Icon} name="chevron.left" />
      </button>
      <button class="mb-borderless" disabled=${isLast} title=${t('右移')} aria-label=${t('右移')} onClick=${() => move(1)}>
        <${Icon} name="chevron.right" />
      </button>
      <button class="mb-borderless is-destructive" title=${t('移除（⌫）')} aria-label=${t('移除')} onClick=${remove}>
        <${Icon} name="trash" />
      </button>
    </div>
    ${options}
  </div>`;
}

// ---- 高级：编辑模板 ------------------------------------------------------------------

function TemplateDisclosure({ items }) {
  const [open, setOpen] = useState(false);
  const [draft, setDraft] = useState(() => serializeItems(items));
  const focused = useRef(false);
  const serialized = serializeItems(items);
  useEffect(() => {
    if (!focused.current) setDraft(serialized);
  }, [serialized]);
  return html`<div class=${cx('mb-disclosure', open && 'is-open')}>
    <button class="mb-disclosure__toggle t-body" aria-expanded=${open} onClick=${() => setOpen(!open)}>
      <${Icon} name="chevron.right" class="mb-disclosure__chevron" />
      <span>${t('高级：编辑模板')}</span>
    </button>
    ${open
      ? html`<div class="mb-disclosure__body">
          <p class="t-caption c-tertiary para mb-disclosure__note">${t('按回车应用，单位和标签会恢复默认。')}</p>
          <input
            class="field mb-template"
            type="text"
            placeholder=${t('模板')}
            value=${draft}
            onFocus=${() => (focused.current = true)}
            onBlur=${() => (focused.current = false)}
            onInput=${(e) => setDraft(e.currentTarget.value)}
            onKeyDown=${(e) => {
              if (e.key === 'Enter') {
                e.preventDefault();
                setItems(parseTemplate(draft));
              }
            }}
          />
          ${TOKENS.map(
            ([key, summary]) => html`<div class="mb-token" key=${key}>
              <span class="mb-token__key num">${key}</span>
              <span class="t-caption c-secondary">${t(summary)}</span>
            </div>`,
          )}
        </div>`
      : null}
  </div>`;
}
