// Menu-bar editor (#/menubar) — owner: web-screens.
//
// Windows has no numeric tray title, so this screen is the source of truth for
// the ordered readout item list: edit chips on a real-proportioned strip, tune
// each item, and save through Charker.SetSetting("menuBar", JSON). The pure
// renderer below is shared with the tray tooltip / flyout — same input, same
// output, so the preview can never lie (spec-ui §1.6, §3.17).

import {
  makeUI, h, txt, clear, pageHead, actionButton, card, cardHead, chip,
  notice, group, switchRow, segControl, selectRow, row, divider, callSafe,
} from './screens-util.js';

const PHASE_KEYS = {
  idle: '未连接',
  scanning: '搜索中',
  connecting: '连接中',
  handshake: '握手中',
  polling: '已连接',
  reconnecting: '重连中',
  failed: '连接失败',
};

const KIND_DEFS = [
  { value: 'total', label: '总功率', icon: 'bolt' },
  { value: 'port', label: '单口功率', icon: 'plug' },
  { value: 'device', label: '设备名称', icon: 'tag' },
  { value: 'state', label: '连接状态', icon: 'radio' },
];

const PRESETS = [
  { label: '总功率', items: [{ kind: 'total' }] },
  { label: '三口功率', items: [{ kind: 'port', port: 'C1' }, { kind: 'port', port: 'C2' }, { kind: 'port', port: 'C3' }] },
  { label: '设备名 · 总功率', items: [{ kind: 'device' }, { kind: 'total' }] },
];

const RICH_KIND_MAP = {
  total: 'total', totalPower: 'total',
  port: 'port', portPower: 'port',
  device: 'device', deviceName: 'device',
  state: 'state',
};

// ---------------------------------------------------------------------------
// Pure readout renderer (must stay free of DOM/state access)

function padFigure(text, digits) {
  const match = /^(\d+)/.exec(text);
  if (!match) return text;
  const whole = match[1].length;
  if (whole >= digits) return text;
  return '\u2007'.repeat(digits - whole) + text;
}

function portLabelOf(item) {
  const raw = item.port;
  if (typeof raw === 'number') return ['C1', 'C2', 'C3', 'C4', 'A1', 'A2'][raw] || 'C1';
  return String(raw || 'C1').toUpperCase();
}

function formatWatts(value, decimals, opts) {
  const number = Number(value);
  const d = Math.max(0, Math.min(3, Number.isInteger(decimals) ? decimals : (opts.decimals == null ? 1 : opts.decimals)));
  if (!Number.isFinite(number)) return opts.t ? opts.t('—') : '—';
  const text = number.toFixed(d);
  return padFigure(text, opts.figureDigits || 2);
}

/**
 * Render one menu-bar item against a snapshot (AppState).
 * @param {object} item   contract item {kind, port?, decimals?, showsUnit?, showsPortName?, label?}
 * @param {object} snapshot  AppState
 * @param {{decimals?:number, figureDigits?:number, t?:Function}} opts
 * @returns {string|null} null when the item elides entirely
 */
export function renderMenuBarItem(item, snapshot, opts = {}) {
  const t = opts.t || ((key) => key);
  const snap = snapshot || {};
  const kind = String(item && item.kind || 'total');
  if (kind === 'separator') return item.label == null ? '·' : String(item.label);
  if (kind === 'text') return item.label == null ? '' : String(item.label);
  if (kind === 'total' || kind === 'totalPower') {
    const watts = totalWatts(snap);
    const value = formatWatts(watts, item.decimals, opts);
    const unit = item.showsUnit === false ? '' : ' W';
    const prefix = item.label ? `${item.label} ` : '';
    return `${prefix}${value}${unit}`;
  }
  if (kind === 'port' || kind === 'portPower') {
    const label = portLabelOf(item);
    const port = (Array.isArray(snap.ports) ? snap.ports : []).find((p) => String(p.id) === label);
    const watts = port ? Number(port.watts) || 0 : null;
    const name = item.label || (item.showsPortName === false ? '' : label);
    const value = watts == null ? (opts.t ? opts.t('—') : '—') : formatWatts(port.enabled === false ? 0 : watts, item.decimals, opts);
    const unit = item.showsUnit === false ? '' : ' W';
    return name ? `${name} ${value}${unit}` : `${value}${unit}`;
  }
  if (kind === 'device' || kind === 'deviceName') {
    const name = (snap.device && snap.device.name) || 'Charker';
    return item.label ? `${item.label} ${name}` : name;
  }
  if (kind === 'state') {
    const key = PHASE_KEYS[snap.phase] || PHASE_KEYS.idle;
    const text = t(key);
    return item.label ? `${item.label} ${text}` : text;
  }
  return null;
}

/** Render the whole readout title: items joined by a single space. */
export function renderMenuBarTitle(items, snapshot, opts = {}) {
  const list = Array.isArray(items) ? items : [];
  const parts = [];
  for (const item of list) {
    const text = renderMenuBarItem(item, snapshot, opts);
    if (text != null && text !== '') parts.push(text);
  }
  return parts.join(' ');
}

function totalWatts(snapshot) {
  if (snapshot && snapshot.totals && Number.isFinite(Number(snapshot.totals.watts))) {
    return Number(snapshot.totals.watts);
  }
  const ports = snapshot && Array.isArray(snapshot.ports) ? snapshot.ports : [];
  return ports.reduce((sum, p) => sum + (Number(p.watts) || 0), 0);
}

// ---------------------------------------------------------------------------
// Editing model (AppState ⇄ draft items)

function normalizeItem(raw, index) {
  const item = raw || {};
  const kind = RICH_KIND_MAP[String(item.kind)] || 'total';
  const out = {
    id: String(item.id || `item-${index}`),
    kind,
    decimals: Number.isInteger(item.decimals) ? Math.max(0, Math.min(3, item.decimals)) : null,
    showsUnit: item.showsUnit !== false,
    showsPortName: item.showsPortName !== false,
    label: typeof item.label === 'string' && item.label ? item.label : null,
  };
  if (kind === 'port') out.port = portLabelOf(item);
  return out;
}

function normalizeItems(raw) {
  const list = raw && Array.isArray(raw.items) ? raw.items : Array.isArray(raw) ? raw : [];
  return list.map(normalizeItem);
}

function serializeItems(items) {
  return items.map((item) => {
    const out = { kind: item.kind };
    if (item.kind === 'port') out.port = item.port;
    if (Number.isInteger(item.decimals)) out.decimals = item.decimals;
    if (item.kind === 'total' || item.kind === 'port') {
      if (item.showsUnit === false) out.showsUnit = false;
      if (item.kind === 'port' && item.showsPortName === false) out.showsPortName = false;
    }
    if (item.label) out.label = item.label;
    return out;
  });
}

function itemsKey(items) {
  return JSON.stringify(serializeItems(items));
}

// ---------------------------------------------------------------------------

let instances = new Set();

export function render(root, state, ctx) {
  let inst = root.__scMenuBar;
  if (!inst) {
    inst = createMenuBarScreen(root);
    root.__scMenuBar = inst;
    instances.add(inst);
  }
  inst.update(makeUI(ctx, state), state);
}

export function cleanup() {
  for (const inst of instances) inst.dispose();
  instances.clear();
}

function createMenuBarScreen(root) {
  const screen = h('div', { class: 'sc-screen sc-menubar' });
  root.append(screen);

  let ui = null;
  let state = null;
  let builtLocale = null;
  let disposed = false;

  let draft = [];
  let selection = -1; // index into draft; -1 = none
  let paletteOpen = false;
  let dirty = false;
  let externalKey = '';
  let saving = false;
  let savedTimer = 0;

  const refs = {};
  const cleanups = [];

  // ---- helpers ------------------------------------------------------------

  function kindDef(kind) {
    return KIND_DEFS.find((k) => k.value === kind) || KIND_DEFS[0];
  }

  function portIds() {
    const ports = state && Array.isArray(state.ports) ? state.ports.map((p) => String(p.id)) : [];
    return ports.length ? ports : ['C1', 'C2', 'C3'];
  }

  function syncFromState(force) {
    const nextKey = itemsKey(normalizeItems(state && state.menuBar));
    if (!force && (dirty || saving || nextKey === externalKey)) return false;
    externalKey = nextKey;
    draft = normalizeItems(state && state.menuBar);
    if (selection >= draft.length) selection = draft.length - 1;
    dirty = false;
    return true;
  }

  function markDirty() {
    dirty = true;
    updateDirty();
  }

  function updateDirty() {
    if (refs.saveBtn) refs.saveBtn.disabled = !dirty || saving;
    if (refs.dirtyChip) {
      refs.dirtyChip.hidden = !dirty;
      txt(refs.dirtyChip, ui.t('未保存'));
    }
    if (refs.saveHint) {
      txt(refs.saveHint, dirty ? ui.t('有未保存的修改') : ui.t('布局已保存'));
    }
  }

  // ---- build --------------------------------------------------------------

  function build() {
    builtLocale = ui.locale;
    clear(screen);
    refs.head = pageHead(ui, '菜单栏');
    refs.content = h('div', { class: 'sc-mb' });
    screen.append(refs.head, refs.content);
    refs.windowsNote = notice(ui, 'info', ui.t('Windows 通知区域不能显示数字读数。这里的布局会同步到托盘提示与浮出面板。'));
    refs.saveBtn = actionButton(ui, ui.t('保存'), { tone: 'primary', icon: 'check', onclick: () => save() });
    refs.resetBtn = actionButton(ui, ui.t('重置'), { tone: 'quiet', icon: 'rotate-ccw', onclick: () => resetDraft() });
    refs.dirtyChip = chip(ui.t('未保存'), 'warn');
    refs.dirtyChip.hidden = true;
    refs.card = h('section', { class: 'ck-card sc-card sc-mb__card' });
    refs.cardHead = cardHead(ui, {
      title: '菜单栏读数',
      sub: '点选组件设置，用箭头调整顺序，Delete 键删除。',
      right: [refs.saveBtn, refs.resetBtn],
    });
    refs.cardHead.querySelector('.sc-cardhead__row').append(refs.dirtyChip);

    refs.stripWrap = h('div', { class: 'sc-mb__stripwrap' });
    refs.strip = h('div', { class: 'sc-mb__strip', role: 'toolbar', 'aria-label': ui.t('菜单栏读数') });
    refs.palette = h('div', { class: 'sc-mb__palette', hidden: true, role: 'menu' });
    refs.stripWrap.append(refs.strip, refs.palette);
    refs.strip.addEventListener('keydown', onStripKey);

    refs.inspector = h('div', { class: 'sc-mb__inspector' });
    refs.card.append(refs.cardHead, refs.stripWrap, refs.inspector);

    refs.presets = h('div', { class: 'sc-presets' });
    refs.presetsGroup = h('section', { class: 'sc-group' },
      h('div', { class: 'sc-group__label' }, h('span', { class: 'ck-t-label', text: ui.t('预设') })),
      h('div', { class: 'sc-group__card' },
        refs.presets,
        h('p', { class: 'sc-group__foot', style: { padding: '0' }, text: ui.t('应用预设会替换当前布局。') })));
    for (const preset of PRESETS) {
      refs.presets.append(actionButton(ui, ui.t(preset.label), {
        onclick: () => applyPreset(preset),
        title: presetPreview(preset),
      }));
    }

    refs.saveHint = h('span', { class: 'sc-mb__savehint' });
    refs.content.append(refs.windowsNote, refs.card, refs.presetsGroup);

    rebuildStrip();
    rebuildInspector();
    updateDirty();
  }

  function presetPreview(preset) {
    const items = preset.items.map((it, i) => normalizeItem(it, i));
    return renderMenuBarTitle(items, state, { t: ui.t, figureDigits: 2 });
  }

  function applyPreset(preset) {
    draft = preset.items.map((it, i) => normalizeItem(it, i));
    draft.forEach((item, i) => { item.id = `preset-${Date.now()}-${i}`; });
    selection = draft.length ? 0 : -1;
    markDirty();
    rebuildStrip();
    rebuildInspector();
  }

  // ---- strip --------------------------------------------------------------

  function rebuildStrip() {
    clear(refs.strip);
    const iconChip = h('button', {
      class: 'sc-mb__iconchip', type: 'button', 'aria-label': ui.t('菜单栏图标'), title: ui.t('菜单栏图标'),
      onclick: () => { selection = -1; closePalette(); rebuildStrip(); rebuildInspector(); },
    }, ui.el('bolt', 12));
    refs.strip.append(iconChip);
    if (!draft.length) {
      refs.strip.append(h('span', { class: 'sc-mb__hint', style: { padding: '0 6px' }, text: ui.t('添加内容') }));
    }
    draft.forEach((item, index) => {
      const text = renderMenuBarItem(item, state, { t: ui.t, figureDigits: 2 }) || ui.t('—');
      const btn = h('button', {
        class: 'sc-mb__chip', type: 'button', 'aria-selected': String(index === selection),
        title: text, onclick: () => { selection = index; closePalette(); rebuildStrip(); rebuildInspector(); },
      }, document.createTextNode(text));
      btn.dataset.index = String(index);
      refs.strip.append(btn);
    });
    const add = h('button', {
      class: 'sc-mb__add', type: 'button', 'aria-label': ui.t('添加内容'), title: ui.t('添加内容'),
      'aria-haspopup': 'menu', 'aria-expanded': String(paletteOpen),
      onclick: (ev) => { ev.stopPropagation(); togglePalette(); },
    }, ui.el('plus-circle', 13));
    refs.strip.append(add);
    refs.strip.append(h('span', { class: 'sc-mb__neigh' },
      ui.el('wifi', 12), ui.el('battery', 12), h('span', { text: ui.t('周四 9:41') })));
    updateChips();
  }

  function updateChips() {
    if (!refs.strip) return;
    const buttons = refs.strip.querySelectorAll('.sc-mb__chip');
    buttons.forEach((btn) => {
      const index = Number(btn.dataset.index);
      const item = draft[index];
      if (!item) return;
      const text = renderMenuBarItem(item, state, { t: ui.t, figureDigits: 2 }) || ui.t('—');
      txt(btn, text);
      btn.title = text;
      btn.setAttribute('aria-selected', String(index === selection));
    });
  }

  function togglePalette() {
    paletteOpen = !paletteOpen;
    refs.palette.hidden = !paletteOpen;
    const add = refs.strip.querySelector('.sc-mb__add');
    if (add) add.setAttribute('aria-expanded', String(paletteOpen));
    if (paletteOpen) {
      buildPalette();
      document.addEventListener('click', onDocumentClick, true);
    } else {
      document.removeEventListener('click', onDocumentClick, true);
    }
  }

  function closePalette() {
    if (!paletteOpen) return;
    paletteOpen = false;
    if (refs.palette) refs.palette.hidden = true;
    document.removeEventListener('click', onDocumentClick, true);
    const add = refs.strip && refs.strip.querySelector('.sc-mb__add');
    if (add) add.setAttribute('aria-expanded', 'false');
  }

  function onDocumentClick(ev) {
    if (!paletteOpen) return;
    const target = ev.target;
    if (refs.palette && refs.palette.contains(target)) return;
    if (target && target.closest && target.closest('.sc-mb__add')) return;
    closePalette();
  }

  function buildPalette() {
    clear(refs.palette);
    const categories = [
      {
        label: '设备数据',
        entries: [
          { kind: 'total', port: null, label: '总功率' },
          ...portIds().map((port) => ({ kind: 'port', port, label: `${port} ${ui.t('功率')}` })),
        ],
      },
      {
        label: '状态',
        entries: [
          { kind: 'device', port: null, label: '设备名称' },
          { kind: 'state', port: null, label: '连接状态' },
        ],
      },
    ];
    for (const category of categories) {
      refs.palette.append(h('div', { class: 'sc-mb__palette-cat', text: ui.t(category.label) }));
      for (const entry of category.entries) {
        const taken = draft.some((item) => item.kind === entry.kind && (entry.kind !== 'port' || item.port === entry.port));
        const preview = renderMenuBarItem(
          { kind: entry.kind, port: entry.port, showsUnit: true, showsPortName: true },
          state, { t: ui.t, figureDigits: 2 },
        );
        refs.palette.append(h('button', {
          class: 'sc-mb__palette-row', type: 'button', role: 'menuitem', disabled: taken,
          title: taken ? ui.t('这一项只能添加一次') : ui.t('插入到当前选中项之后'),
          onclick: () => {
            if (taken) return;
            insertItem(entry);
          },
        },
        ui.el(entry.kind === 'port' ? 'plug' : entry.kind === 'total' ? 'bolt' : entry.kind === 'device' ? 'tag' : 'radio', 11),
        h('span', { text: entry.kind === 'port' ? entry.label : ui.t(entry.label) }),
        h('span', { class: 'sc-mb__palette-sample', text: taken ? ui.t('已添加') : preview })));
      }
    }
  }

  function insertItem(entry) {
    const item = normalizeItem({
      kind: entry.kind,
      port: entry.port,
      showsUnit: true,
      showsPortName: true,
    }, draft.length);
    item.id = `item-${Date.now()}-${draft.length}`;
    const at = selection >= 0 && selection < draft.length ? selection + 1 : draft.length;
    draft.splice(at, 0, item);
    selection = at;
    closePalette();
    markDirty();
    rebuildStrip();
    rebuildInspector();
  }

  function onStripKey(ev) {
    if (ev.key === 'Delete' || ev.key === 'Backspace') {
      if (selection < 0 || selection >= draft.length) return;
      ev.preventDefault();
      removeSelected();
    } else if (ev.key === 'ArrowLeft' && selection > 0) {
      ev.preventDefault();
      selection -= 1;
      rebuildStrip();
      rebuildInspector();
    } else if (ev.key === 'ArrowRight' && selection < draft.length - 1) {
      ev.preventDefault();
      selection += 1;
      rebuildStrip();
      rebuildInspector();
    } else if (ev.key === 'Escape') {
      closePalette();
    }
  }

  function removeSelected() {
    if (selection < 0 || selection >= draft.length) return;
    draft.splice(selection, 1);
    if (selection >= draft.length) selection = draft.length - 1;
    markDirty();
    rebuildStrip();
    rebuildInspector();
  }

  function moveSelected(delta) {
    const target = selection + delta;
    if (selection < 0 || target < 0 || target >= draft.length) return;
    const [item] = draft.splice(selection, 1);
    draft.splice(target, 0, item);
    selection = target;
    markDirty();
    rebuildStrip();
    rebuildInspector();
  }

  function updateSelected(mutate) {
    if (selection < 0 || selection >= draft.length) return;
    mutate(draft[selection]);
    markDirty();
    updateChips();
  }

  // ---- inspector ----------------------------------------------------------

  function rebuildInspector() {
    clear(refs.inspector);
    const item = draft[selection];
    if (!item) {
      refs.inspector.append(h('p', { class: 'sc-mb__empty ck-u-cjk', text: ui.t('点选组件设置，用箭头调整顺序，Delete 键删除。') }));
      return;
    }
    const def = kindDef(item.kind);
    const header = h('div', { class: 'sc-mb__inspectorhead' },
      ui.el(def.icon, 11),
      h('h3', { class: 'ck-t-heading', text: ui.t(def.label) }),
      h('div', { class: 'sc-mb__inspector-actions' },
        actionButton(ui, '', { icon: 'chevron-left', title: ui.t('左移'), disabled: selection === 0, onclick: () => moveSelected(-1) }),
        actionButton(ui, '', { icon: 'chevron-right', title: ui.t('右移'), disabled: selection >= draft.length - 1, onclick: () => moveSelected(1) }),
        actionButton(ui, '', { tone: 'destructive', icon: 'trash', title: ui.t('移除'), onclick: removeSelected })));
    refs.inspector.append(header, divider());

    const kindSel = selectRow(ui, {
      title: '组件类型',
      items: KIND_DEFS.map((k) => ({ value: k.value, label: ui.t(k.label) })),
      value: item.kind,
      onChange: (value) => {
        updateSelected((it) => {
          it.kind = value;
          if (value === 'port' && !it.port) it.port = portIds()[0];
          if (value !== 'port') delete it.port;
        });
        rebuildStrip();
        rebuildInspector();
      },
    });
    refs.inspector.append(kindSel.el);

    if (item.kind === 'port') {
      const portSel = selectRow(ui, {
        title: '端口',
        items: portIds().map((port) => ({ value: port, label: port })),
        value: item.port || portIds()[0],
        onChange: (value) => {
          updateSelected((it) => { it.port = value; });
          rebuildStrip();
        },
      });
      refs.inspector.append(portSel.el);
      const nameSwitch = switchRow(ui, {
        title: '显示端口名',
        checked: item.showsPortName !== false,
        onChange: (on) => {
          updateSelected((it) => { it.showsPortName = on; });
          rebuildStrip();
        },
      });
      refs.inspector.append(nameSwitch.el);
    }

    if (item.kind === 'total' || item.kind === 'port') {
      const unitSwitch = switchRow(ui, {
        title: '显示单位 W',
        checked: item.showsUnit !== false,
        onChange: (on) => {
          updateSelected((it) => { it.showsUnit = on; });
          rebuildStrip();
        },
      });
      refs.inspector.append(unitSwitch.el);
    }

    if (item.kind === 'total' || item.kind === 'port') {
      const decimals = segRowLocal(item);
      refs.inspector.append(decimals);
    }

    if (item.kind !== 'state') {
      refs.inspector.append(labelRow(item));
    }

    if (item.kind === 'state' || item.kind === 'device') {
      refs.inspector.append(h('p', { class: 'sc-mb__empty', text: ui.t('此组件没有可配置选项。') }));
    }
  }

  function segRowLocal(item) {
    const values = [{ value: -1, label: ui.t('全局') }, { value: 0, label: '0' }, { value: 1, label: '1' }, { value: 2, label: '2' }, { value: 3, label: '3' }];
    const current = Number.isInteger(item.decimals) ? item.decimals : -1;
    const seg = segControl({
      items: values.map((v) => ({ value: String(v.value), label: v.label })),
      value: String(current),
      label: ui.t('小数位'),
      width: 240,
      onChange: (value) => {
        const next = Number(value);
        updateSelected((it) => { it.decimals = next < 0 ? null : next; });
        rebuildStrip();
        updateChips();
      },
    });
    return h('div', { class: 'sc-row' },
      h('div', { class: 'sc-row__text' }, h('span', { class: 'ck-t-body sc-row__title', text: ui.t('小数位') })),
      h('div', { class: 'sc-row__control' }, h('span', { class: 'ck-t-caption sc-muted', text: ui.t('全局（%d）', 1) }), seg.el));
  }

  function labelRow(item) {
    const input = h('input', {
      class: 'sc-field ck-field', type: 'text', value: item.label || '',
      placeholder: item.kind === 'port' ? (item.port || '') : ui.t('无前缀'),
      'aria-label': ui.t('标签'),
    });
    input.addEventListener('input', () => {
      updateSelected((it) => {
        const value = input.value.trim();
        it.label = value || null;
      });
      updateChips();
    });
    return h('div', { class: 'sc-row' },
      h('div', { class: 'sc-row__text' }, h('span', { class: 'ck-t-body sc-row__title', text: ui.t('标签') })),
      h('div', { class: 'sc-row__control' }, input));
  }

  // ---- save / reset -------------------------------------------------------

  async function save() {
    if (saving || !ui.ctx || typeof ui.ctx.call !== 'function') return;
    saving = true;
    updateDirty();
    const payload = JSON.stringify(serializeItems(draft));
    const out = await callSafe(ui, 'Charker.SetSetting', ['menuBar', payload], null);
    saving = false;
    if (disposed) return;
    if (out && out.__error) {
      ui.toast(ui.t('保存失败：%@', out.__error.message || out.__error), 'error');
      updateDirty();
      return;
    }
    externalKey = itemsKey(draft);
    dirty = false;
    updateDirty();
    ui.toast(ui.t('菜单栏布局已保存'), 'info');
    if (savedTimer) clearTimeout(savedTimer);
    savedTimer = setTimeout(() => { savedTimer = 0; }, 2000);
  }

  function resetDraft() {
    syncFromState(true);
    selection = draft.length ? 0 : -1;
    rebuildStrip();
    rebuildInspector();
    updateDirty();
  }

  // ---- lifecycle ----------------------------------------------------------

  function update(nextUi, nextState) {
    if (disposed) return;
    const localeChanged = builtLocale !== nextUi.locale;
    ui = nextUi;
    state = nextState || {};
    if (localeChanged) {
      build();
      return;
    }
    if (!refs.strip) {
      build();
      return;
    }
    const resynced = syncFromState(false);
    if (resynced) {
      rebuildStrip();
      rebuildInspector();
      updateDirty();
    } else {
      updateChips();
      updateDirty();
    }
  }

  function dispose() {
    if (disposed) return;
    disposed = true;
    if (savedTimer) clearTimeout(savedTimer);
    document.removeEventListener('click', onDocumentClick, true);
    while (cleanups.length) {
      try { cleanups.pop()(); } catch (_) { /* ignore */ }
    }
    instances.delete(inst);
  }

  const inst = { update, dispose, get screen() { return screen; } };
  return inst;
}
