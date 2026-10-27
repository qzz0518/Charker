// ============================================================================
// Charker — Overview (A2687 dashboard), owner: web-overview
//
// spec-ui §3.8–§3.14 + §4 + §5. Rendering model:
//   · render() is called by js/main.js on every AppState event (rAF-throttled)
//   · the DOM is built once per mount, then only values are patched so numeric
//     rolling / rail widths / selection can animate
//   · all data comes from state.ports / totals / history / stats (§4.1)
//   · 3D lives in js/stage.js, the timeline in js/chart.js
// ============================================================================

import { createStage } from '../stage.js';
import { createChart } from '../chart.js';

const PORT_COUNT = 3;
const PORTS_ORDER = ['C1', 'C2', 'C3'];

// ---------------------------------------------------------------------------
// formatting / DOM helpers

function num(value, fallback = 0) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

function h(tag, className, text) {
  const el = document.createElement(tag);
  if (className) el.className = className;
  if (text != null) el.textContent = text;
  return el;
}

function reduceMotion() {
  try {
    return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  } catch (_) {
    return false;
  }
}

/** Numeric text roll — spec-ui §5.3. Keeps tabular digits from jumping. */
function roll(el, text) {
  if (!el) return;
  const next = text == null ? '' : String(text);
  if (el._ckValue === next) return;
  el._ckValue = next;
  if (el._ckTimer) {
    clearTimeout(el._ckTimer);
    el._ckTimer = 0;
  }
  if (reduceMotion() || el.textContent === '' || el.textContent === next) {
    el.classList.remove('ck-num--rolling');
    el.textContent = next;
    return;
  }
  const from = el.textContent;
  el.classList.remove('ck-num--rolling');
  el.textContent = '';
  const a = h('span', 'ck-num__from', from);
  const b = h('span', 'ck-num__to', next);
  el.append(a, b);
  void el.offsetWidth; // flush styles so the roll starts from `from`
  el.classList.add('ck-num--rolling');
  el._ckTimer = setTimeout(() => {
    el._ckTimer = 0;
    el.textContent = next;
    el.classList.remove('ck-num--rolling');
  }, 170);
}

function setText(el, text) {
  if (!el) return;
  const next = text == null ? '' : String(text);
  if (el.textContent !== next) el.textContent = next;
}

function iconMarkup(ctx, name) {
  try {
    if (ctx && typeof ctx.icon === 'function') {
      const markup = ctx.icon(name);
      if (markup) return markup;
    }
    if (ctx && ctx.icons && typeof ctx.icons.get === 'function') {
      const markup = ctx.icons.get(name);
      if (markup) return markup;
    }
  } catch (_) {
    /* fall through to the local glyphs */
  }
  return LOCAL_ICONS[name] || '';
}

const LOCAL_ICONS = {
  usbc: '<svg viewBox="0 0 20 9.2" width="20" height="9.2" aria-hidden="true"><rect x=".7" y=".7" width="18.6" height="7.8" rx="3.9" fill="none" stroke="currentColor" stroke-width="1.4"/><rect x="4.8" y="3.5" width="10.4" height="2.2" rx="1.1" fill="currentColor"/></svg>',
  timer: '<svg viewBox="0 0 16 16" width="10" height="10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true"><circle cx="8" cy="8.6" r="5.4"/><path d="M8 5.6v3.2l2 1.2M6.4 1.6h3.2"/></svg>',
  'move-3d': '<svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" aria-hidden="true"><path d="M8 2v12M2.4 5.2 8 2l5.6 3.2M2.4 10.8 8 14l5.6-3.2"/></svg>',
  bookmark: '<svg viewBox="0 0 16 16" width="10" height="10" aria-hidden="true"><path d="M4 2.2h8v11.6L8 10.9l-4 2.9V2.2Z" fill="currentColor"/></svg>',
  'rotate-3d': '<svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" aria-hidden="true"><path d="M13.5 8a5.5 5.5 0 1 1-1.9-4.17"/><path d="M13.6 2.4v3.2h-3.2"/></svg>',
  'chevron-down': '<svg viewBox="0 0 8 8" width="7" height="7" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M1.2 2.8 4 5.8l2.8-3"/></svg>',
  'rotate-cw': '<svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" aria-hidden="true"><path d="M13.5 8a5.5 5.5 0 1 1-1.9-4.17"/><path d="M13.6 2.4v3.2h-3.2"/></svg>',
};

// ---------------------------------------------------------------------------
// state derivation

function isLive(state) {
  if (!state) return false;
  const phase = state.phase;
  const connected = !state.device || state.device.connected !== false;
  return connected && (phase === 'polling' || phase === 'reconnecting');
}

function hasTelemetry(state) {
  return isLive(state) && Array.isArray(state.ports) && state.ports.length > 0;
}

function portList(state) {
  const ports = Array.isArray(state && state.ports) ? state.ports : [];
  return ports.slice(0, PORT_COUNT).map((port, index) => ({
    ...port,
    index,
    label: port.label || PORTS_ORDER[index] || `C${index + 1}`,
    enabled: port.enabled !== false,
    watts: num(port.watts),
    volts: num(port.volts),
    amps: num(port.amps),
  }));
}

function cableAttached(port) {
  const raw = port && port.cable != null ? String(port.cable).trim() : '';
  return Boolean(raw) || port.volts > 3 || port.watts > 0.1;
}

function hasReadings(port) {
  return (
    port.enabled &&
    (port.volts > 0.05 || port.amps > 0.05 || port.watts > 0.05 || num(port.status) > 0)
  );
}

function cableChip(ctx, state, port) {
  if (!hasTelemetry(state)) return '';
  const raw = port && port.cable != null ? String(port.cable).trim() : '';
  if (!raw) return '';
  const key = raw.toLowerCase().replace(/\s+/g, '');
  if (key.includes('epr') || key.includes('240')) return ctx.t('EPR · 240W 线');
  if (key.includes('5a') || key.includes('100')) return ctx.t('5A · 100W 线');
  if (key.includes('3a') || key.includes('60')) return ctx.t('3A · 60W 线');
  if (/[^\x00-\x7f]/.test(raw)) return raw; // already human-readable text
  return ctx.t('未知线缆');
}

function portStatusText(ctx, state, port, total) {
  if (!hasTelemetry(state)) return ctx.t('无数据');
  if (!port.enabled) return ctx.t('已关闭');
  if (port.watts <= 0.1) {
    return cableAttached(port) ? ctx.t('待机') : ctx.t('未接入设备');
  }
  const protocol = port.protocol != null ? String(port.protocol).trim() : '';
  if (protocol) return protocol;
  if (port.watts < 2.5) return ctx.t('涓流');
  if (total > 0) {
    const pct = Math.round((port.watts / total) * 100);
    if (pct >= 5) return ctx.t('占 %d%%', pct);
  }
  return ctx.t('供电中');
}

function portDeviceText(ctx, state, port) {
  if (!hasTelemetry(state) || !port.enabled) return '—';
  const name = port.deviceName != null ? String(port.deviceName).trim() : '';
  if (name) return name;
  const kind = port.deviceKind != null ? String(port.deviceKind).trim() : '';
  if (kind) return kind;
  if (cableAttached(port)) return ctx.t('已接入 · 未报告身份');
  return '—';
}

function scopeLabel(ctx, scope) {
  switch (scope) {
    case 'day':
      return ctx.t('今日能量');
    case 'week':
      return ctx.t('本周能量');
    case 'month':
      return ctx.t('本月能量');
    default:
      return ctx.t('本次能量');
  }
}

function scopeEnergy(state, scope) {
  if (scope === 'session') return num(state && state.stats && state.stats.energyWh);
  const bucket = state && state.energy ? state.energy[scope] : null;
  return num(bucket && bucket.wh);
}

// ---------------------------------------------------------------------------
// module-level view state (one mounted screen at a time)

let ui = null;
let selectedPort = null;
let energyScope = 'session';
let popover = null;
let popoverCleanup = null;

function closePopover() {
  if (popoverCleanup) {
    try {
      popoverCleanup();
    } catch (_) {
      /* ignore */
    }
    popoverCleanup = null;
  }
  if (popover) {
    popover.remove();
    popover = null;
  }
}

function openPopover(anchor, items, opts) {
  closePopover();
  if (!ui || !anchor || !anchor.isConnected) return;
  const panel = h('div', 'ov-pop');
  panel.setAttribute('role', 'menu');
  for (const item of items) {
    if (item === '-') {
      panel.append(h('div', 'ov-pop__sep'));
      continue;
    }
    const button = h('button', 'ov-pop__item');
    button.type = 'button';
    button.setAttribute('role', 'menuitem');
    const check = h('span', 'ov-pop__check');
    if (item.checked) {
      check.innerHTML =
        '<svg viewBox="0 0 16 16" width="10" height="10" aria-hidden="true"><path d="M3 8.4 6.4 12 13 4.6" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';
    }
    button.append(check, h('span', 'ov-pop__label', item.label));
    if (item.disabled) {
      button.disabled = true;
      button.setAttribute('aria-disabled', 'true');
    }
    if (item.danger) button.classList.add('ov-pop__item--danger');
    button.addEventListener('click', () => {
      if (item.disabled) return;
      closePopover();
      try {
        item.onSelect?.();
      } catch (error) {
        console.error('[overview] menu action failed', error);
      }
    });
    panel.append(button);
  }
  document.body.append(panel);
  popover = panel;

  const rect = anchor.getBoundingClientRect();
  const panelRect = panel.getBoundingClientRect();
  const align = (opts && opts.align) || 'start';
  let left = align === 'end' ? rect.right - panelRect.width : rect.left;
  left = Math.min(window.innerWidth - panelRect.width - 8, Math.max(8, left));
  let top = rect.bottom + 6;
  if (top + panelRect.height > window.innerHeight - 8) {
    top = Math.max(8, rect.top - panelRect.height - 6);
  }
  panel.style.left = `${Math.round(left)}px`;
  panel.style.top = `${Math.round(top)}px`;

  const onPointerDown = (event) => {
    if (panel.contains(event.target) || anchor.contains(event.target)) return;
    closePopover();
  };
  const onKeyDown = (event) => {
    if (event.key === 'Escape') {
      event.stopPropagation();
      closePopover();
    }
  };
  const onScroll = () => closePopover();
  document.addEventListener('pointerdown', onPointerDown, true);
  document.addEventListener('keydown', onKeyDown, true);
  window.addEventListener('resize', onScroll);
  document.addEventListener('scroll', onScroll, true);
  popoverCleanup = () => {
    document.removeEventListener('pointerdown', onPointerDown, true);
    document.removeEventListener('keydown', onKeyDown, true);
    window.removeEventListener('resize', onScroll);
    document.removeEventListener('scroll', onScroll, true);
  };
}

/** Confirmation dialog (spec-ui §1.5): resolves true when confirmed. */
function confirmDialog(opts) {
  return new Promise((resolve) => {
    if (!ui) {
      resolve(false);
      return;
    }
    const dialog = h('dialog', 'ov-dlg');
    const title = h('div', 'ov-dlg__title', opts.title);
    const body = h('div', 'ov-dlg__body', opts.body || '');
    const actions = h('div', 'ov-dlg__actions');
    const cancel = h('button', 'ck-btn ck-btn--quiet ov-dlg__cancel', opts.cancel || '取消');
    cancel.type = 'button';
    const confirm = h(
      'button',
      `ck-btn ${opts.destructive ? 'ck-btn--destructive' : 'ck-btn--primary'} ov-dlg__confirm`,
      opts.confirm || 'OK',
    );
    confirm.type = 'button';
    actions.append(cancel, confirm);
    const card = h('div', 'ov-dlg__card');
    card.append(title, body, actions);
    dialog.append(card);
    ui.dash.append(dialog);
    let settled = false;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      try {
        dialog.close();
      } catch (_) {
        /* ignore */
      }
      dialog.remove();
      resolve(value);
    };
    cancel.addEventListener('click', () => finish(false));
    confirm.addEventListener('click', () => finish(true));
    dialog.addEventListener('cancel', (event) => {
      event.preventDefault();
      finish(false);
    });
    try {
      dialog.showModal();
    } catch (_) {
      finish(false);
      return;
    }
    confirm.focus();
  });
}

// ---------------------------------------------------------------------------
// mount

function mount(root, ctx) {
  closePopover();
  selectedPort = null;
  energyScope = 'session';

  const state = { root, ctx, stage: null, chart: null, timer: 0, disposed: false };
  const dash = h('div', 'ck-dash');
  state.dash = dash;

  // ------------------------------------------------------------------ hero
  const hero = h('div', 'ck-hero');
  const heroRow = h('div', 'ck-hero__row');
  const heroText = h('div', 'ck-hero__text');
  const heroLabel = h('div', 'ck-hero__label');
  const heroSub = h('div', 'ck-hero__sub ck-u-num');
  heroText.append(heroLabel, heroSub);
  const heroStatus = h('div', 'ck-hero__status');
  heroStatus.hidden = true;
  const statusDot = h('span', 'ck-state-dot');
  const statusText = h('span', 'ck-hero__status-text');
  heroStatus.append(statusDot, statusText);
  const readout = h('div', 'ck-readout');
  const readoutNum = h('span', 'ck-readout__num ck-u-num');
  const readoutUnit = h('span', 'ck-readout__unit', 'W');
  readout.append(readoutNum, readoutUnit);
  heroRow.append(heroText, heroStatus, readout);
  const rail = h('div', 'ck-rail');
  const railFill = h('div', 'ck-rail__fill');
  rail.append(railFill);
  const legend = h('div', 'ck-hero__legend');
  legend.dataset.visible = 'false';
  hero.append(heroRow, rail, legend);

  // ---------------------------------------------------------- 3D + inspector
  const instrument = h('div', 'ck-dash__instrument');
  const stageChrome = buildStageChrome(ctx);
  const insp = h('div', 'ck-insp');
  const inspHead = h('div', 'ck-insp__head');
  const inspTitle = h('div', 'ck-insp__title');
  const inspHint = h('div', 'ck-insp__hint');
  inspHead.append(inspTitle, inspHint);
  const inspHeadRule = h('div', 'ck-dash__hairline ck-insp__headrule');
  const inspRows = h('div', 'ck-insp__rows');
  const rowViews = [];
  for (let i = 0; i < PORT_COUNT; i += 1) {
    if (i > 0) inspRows.append(h('div', 'ck-insp__sep'));
    const view = buildPortRow(ctx, i);
    rowViews.push(view);
    inspRows.append(view.row);
  }
  insp.append(inspHead, inspHeadRule, inspRows);
  instrument.append(stageChrome.stage, insp);

  // ------------------------------------------------------------------ chart
  const chartBand = h('div', 'ck-dash__chartband');
  const chartHead = h('div', 'ck-chart__head');
  const chartTitle = h('span', 'ck-chart__title');
  const chartHint = h('span', 'ck-chart__hint');
  chartHead.append(chartTitle, chartHint);
  const chartEl = h('div', 'ck-chart');
  const chartWell = h('div', 'ck-chart__well');
  const chartPlot = h('div', 'ck-chart__plot');
  chartWell.append(chartPlot);
  chartEl.append(chartWell);
  chartBand.append(chartHead, chartEl);

  // ------------------------------------------------------------------- card
  const card = h('section', 'ck-card ck-dash__card');
  card.append(
    hero,
    h('div', 'ck-dash__hairline'),
    instrument,
    h('div', 'ck-dash__hairline'),
    chartBand,
  );

  // ------------------------------------------------------------------ stats
  const stats = buildStats(ctx);

  dash.append(card, stats.card);
  root.append(dash);

  Object.assign(state, {
    hero,
    heroLabel,
    heroSub,
    heroStatus,
    statusDot,
    statusText,
    readout,
    readoutNum,
    readoutUnit,
    rail,
    railFill,
    legend,
    stageChrome,
    inspTitle,
    inspHint,
    chartTitle,
    chartHint,
    chartEl,
    chartWell,
    rowViews,
    stats,
    durationBase: 0,
    durationAt: 0,
  });

  // 3D stage controller (never throws: falls back to the product render)
  state.stage = createStage(stageChrome.stage, {
    labels: {
      loading: ctx.t('载入三维模型'),
      unavailable: ctx.t('三维视图暂不可用'),
      reload: ctx.t('重新载入'),
    },
    icon: (name) => iconMarkup(ctx, name),
    theme: themeOf,
    readHomePose: () => readHomePose(state),
    writeHomePose: (pose) => {
      state.homePose = pose;
      try {
        const result = ctx.call('Charker.setSetting', 'modelHomeCamera', JSON.stringify(pose));
        if (result && typeof result.catch === 'function') result.catch(() => {});
      } catch (_) {
        /* bridge unavailable in a static preview */
      }
    },
    onSelectPort: (index) => selectPort(state, index),
  });

  // timeline
  state.chart = createChart(chartEl);

  // overlays
  stageChrome.hint.innerHTML = `${iconMarkup(ctx, 'move-3d')}<span></span>`;
  setText(stageChrome.hint.querySelector('span'), ctx.t('拖动旋转 · 滚轮缩放 · 点击端口'));
  setText(stageChrome.loadingText, ctx.t('载入三维模型'));
  setText(stageChrome.menuLabel, ctx.t('设定'));
  setText(stageChrome.resetLabel, ctx.t('归位'));
  stageChrome.menuButton.title = ctx.t('设定');

  // ------------------------------------------------------------- wiring
  for (let i = 0; i < rowViews.length; i += 1) {
    const view = rowViews[i];
    view.row.addEventListener('click', (event) => {
      if (event.target.closest('button, input, label, .ck-switch, select, a')) return;
      selectPort(state, i);
    });
    view.row.addEventListener('pointerenter', () => {
      try {
        state.stage?.setHighlighted?.(i);
      } catch (_) {
        /* ignore */
      }
      view.row.dataset.hover = 'true';
    });
    view.row.addEventListener('pointerleave', () => {
      try {
        state.stage?.setHighlighted?.(null);
      } catch (_) {
        /* ignore */
      }
      delete view.row.dataset.hover;
    });
    view.timer.addEventListener('click', (event) => {
      event.stopPropagation();
      openTimerMenu(state, i, view.timer);
    });
    view.switchInput.addEventListener('click', (event) => event.stopPropagation());
    view.switchInput.addEventListener('change', (event) => {
      event.stopPropagation();
      const next = Boolean(view.switchInput.checked);
      const current = view.row.dataset.on === 'true';
      view.switchInput.checked = current;
      if (next !== current) togglePort(state, i, next);
    });
    const badge = stageChrome.badges[i];
    if (badge) {
      badge.addEventListener('click', (event) => {
        event.stopPropagation();
        selectPort(state, i);
      });
      badge.addEventListener('pointerenter', () => {
        try {
          state.stage?.setHighlighted?.(i);
        } catch (_) {
          /* ignore */
        }
        rowViews[i].row.dataset.hover = 'true';
      });
      badge.addEventListener('pointerleave', () => {
        try {
          state.stage?.setHighlighted?.(null);
        } catch (_) {
          /* ignore */
        }
        delete rowViews[i].row.dataset.hover;
      });
    }
  }

  stageChrome.menuButton.addEventListener('click', (event) => {
    event.stopPropagation();
    let hasHome = false;
    try {
      hasHome = Boolean(state.stage && state.stage.hasHome && state.stage.hasHome());
    } catch (_) {
      hasHome = false;
    }
    openPopover(
      stageChrome.menuButton,
      [
        {
          label: ctx.t('将当前视角设为归位'),
          onSelect: () => {
            try {
              state.homePose = state.stage.saveHome();
            } catch (_) {
              /* ignore */
            }
          },
        },
        {
          label: ctx.t('恢复初始归位视角'),
          disabled: !hasHome,
          onSelect: () => {
            try {
              state.stage?.restoreHome?.();
            } catch (_) {
              /* ignore */
            }
          },
        },
      ],
      { align: 'end' },
    );
  });
  stageChrome.resetButton.addEventListener('click', (event) => {
    event.stopPropagation();
    try {
      state.stage?.reset?.();
    } catch (_) {
      /* ignore */
    }
  });

  stats.energyTile.addEventListener('click', () => openEnergyMenu(state));

  // live duration ticker (spec §7.1: one 1 s interval, never a full re-render)
  state.timer = window.setInterval(() => {
    if (!state.disposed) updateDuration(state);
  }, 1000);

  const cleanup = () => {
    if (state.disposed) return;
    state.disposed = true;
    if (state.timer) window.clearInterval(state.timer);
    state.timer = 0;
    closePopover();
    try {
      state.chart?.dispose();
    } catch (_) {
      /* ignore */
    }
    try {
      state.stage?.detach?.();
    } catch (_) {
      /* ignore */
    }
  };
  state.cleanup = cleanup;
  try {
    ctx.onCleanup(cleanup);
  } catch (_) {
    /* shell may not expose onCleanup in a static harness */
  }

  return state;
}

function themeOf() {
  try {
    const theme = document.documentElement.dataset.theme;
    if (theme === 'light' || theme === 'dark') return theme;
    return window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark';
  } catch (_) {
    return 'dark';
  }
}

function readHomePose(state) {
  try {
    const raw = state && state.settings ? state.settings.modelHomeCamera : null;
    if (!raw) return null;
    return typeof raw === 'string' ? JSON.parse(raw) : raw;
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// stage chrome (overlays live in HTML, spec-ui §4.10)

function buildStageChrome(ctx) {
  const stage = h('div', 'ck-stage');
  const loading = h('div', 'ck-stage__loading');
  const loadingText = h('span', 'ck-stage__loading-text', ctx.t('载入三维模型'));
  loading.append(h('span', 'ck-spinner'), loadingText);
  loading.hidden = true;

  const hint = h('div', 'ck-stage__hint');
  hint.setAttribute('aria-hidden', 'true');

  const menuWrap = h('div', 'ck-stage__menuwrap');
  const menuButton = h('button', 'ck-btn ck-btn--quiet ck-stage__menu');
  menuButton.type = 'button';
  menuButton.title = ctx.t('设定');
  menuButton.innerHTML = `${iconMarkup(ctx, 'bookmark')}<span></span>`;
  const menuLabel = menuButton.querySelector('span');
  menuWrap.append(menuButton);

  const resetButton = h('button', 'ck-btn ck-btn--quiet ck-stage__reset');
  resetButton.type = 'button';
  resetButton.innerHTML = `${iconMarkup(ctx, 'rotate-3d')}<span></span>`;
  const resetLabel = resetButton.querySelector('span');

  const badges = [];
  for (let i = 0; i < PORT_COUNT; i += 1) {
    const badge = h('button', 'ck-stage__badge');
    badge.type = 'button';
    badge.dataset.port = String(i);
    badge.dataset.lit = 'false';
    badge.dataset.focused = 'false';
    badge.setAttribute('aria-pressed', 'false');
    const dot = h('span', 'ck-stage__badge-dot');
    const text = h('span', 'ck-stage__badge-txt');
    badge.append(dot, text);
    badges.push(badge);
    stage.append(badge);
  }

  stage.append(loading, hint, menuWrap, resetButton);
  return { stage, loading, loadingText, hint, menuButton, menuLabel, resetButton, resetLabel, badges };
}

// ---------------------------------------------------------------------------
// inspector port row (spec-ui §3.11 inspector presentation)

function buildPortRow(ctx, index) {
  const row = h('div', 'ck-insp__row');
  row.dataset.port = String(index);
  row.dataset.on = 'false';
  row.tabIndex = 0;
  row.setAttribute('role', 'button');

  const header = h('div', 'ck-insp__hdr');
  const id = h('span', 'ck-insp__id');
  const usbc = h('span', 'ck-insp__usbc');
  usbc.innerHTML = iconMarkup(ctx, 'usbc');
  const label = h('span', 'ck-insp__label ck-u-num', PORTS_ORDER[index] || `C${index + 1}`);
  id.append(usbc, label);

  const nick = h('span', 'ck-insp__nick');
  const spacer = h('span', 'ck-insp__spacer');
  const chip = h('span', 'ck-insp__chip');
  const timer = h('button', 'ck-insp__timer');
  timer.type = 'button';
  timer.innerHTML = iconMarkup(ctx, 'timer');
  timer.title = ctx.t('设定倒计时');

  const switchLabel = h('label', 'ck-switch ck-switch--small ck-insp__switch');
  switchLabel.title = ctx.t('端口开关');
  const switchInput = h('input');
  switchInput.type = 'checkbox';
  switchInput.setAttribute('role', 'switch');
  const track = h('span', 'ck-switch__track');
  const knob = h('span', 'ck-switch__knob');
  track.append(knob);
  switchLabel.append(switchInput, track);
  header.append(id, nick, spacer, chip, timer, switchLabel);

  const reading = h('div', 'ck-insp__read');
  const watts = h('span', 'ck-insp__watts ck-u-num');
  const wunit = h('span', 'ck-insp__wunit', 'W');
  const detail = h('div', 'ck-insp__detail');
  const va = h('div', 'ck-insp__va');
  const volts = h('span', 'ck-insp__va-value ck-u-num');
  const voltsUnit = h('span', 'ck-insp__unit', 'V');
  const amps = h('span', 'ck-insp__va-value ck-u-num');
  const ampsUnit = h('span', 'ck-insp__unit', 'A');
  va.append(volts, voltsUnit, amps, ampsUnit);
  const status = h('div', 'ck-insp__status');
  detail.append(va, status);
  reading.append(watts, wunit, detail);

  const aux = h('div', 'ck-insp__aux');
  const auxLabel = h('span', 'ck-insp__aux-label', ctx.t('接入设备'));
  const auxValue = h('span', 'ck-insp__aux-value');
  aux.append(auxLabel, auxValue);

  const railEl = h('div', 'ck-insp__rail');
  const railFill = h('span', 'ck-insp__rail-fill');
  railEl.append(railFill);

  row.append(header, reading, aux, railEl);

  return {
    row,
    usbc,
    label,
    nick,
    chip,
    timer,
    switchLabel,
    switchInput,
    watts,
    volts,
    amps,
    status,
    auxLabel,
    auxValue,
    railFill,
    port: null,
  };
}

// ---------------------------------------------------------------------------
// stats row (spec-ui §3.13)

function buildStats(ctx) {
  const card = h('section', 'ck-card ck-stats');

  function tile(labelText, accessory) {
    const tile = h('div', 'ck-stat');
    const labelEl = h('div', 'ck-stat__label');
    const labelTextEl = h('span', 'ck-stat__label-text', labelText);
    labelEl.append(labelTextEl);
    if (accessory) {
      const chevron = h('span', 'ck-stat__chevron');
      chevron.innerHTML = iconMarkup(ctx, 'chevron-down');
      labelEl.append(chevron);
    }
    const valueRow = h('div', 'ck-stat__value-row');
    const value = h('span', 'ck-stat__value ck-u-num');
    const unit = h('span', 'ck-stat__unit');
    valueRow.append(value, unit);
    tile.append(labelEl, valueRow);
    return { tile, labelEl, labelTextEl, value, unit };
  }

  const peak = tile(ctx.t('峰值'));
  const average = tile(ctx.t('平均'));
  const energy = tile(ctx.t('本次能量'), true);
  energy.tile.classList.add('ck-stat--button');
  energy.tile.setAttribute('role', 'button');
  energy.tile.tabIndex = 0;
  energy.tile.title = ctx.t('切换统计周期');
  const duration = tile(ctx.t('连接时长'));

  const divider = () => h('div', 'ck-stats__div');
  card.append(peak.tile, divider(), average.tile, divider(), energy.tile, divider(), duration.tile);

  return {
    card,
    peak,
    average,
    energyTile: energy.tile,
    energyLabel: energy.labelEl,
    energyLabelText: energy.labelTextEl,
    energyValue: energy.value,
    energyUnit: energy.unit,
    durationValue: duration.value,
    durationUnit: duration.unit,
  };
}

// ---------------------------------------------------------------------------
// update — the only place that touches state-driven DOM

function update(state) {
  if (!ui || ui.disposed) return;
  ui.state = state;
  const ctx = ui.ctx;
  const live = isLive(state);
  const ports = portList(state);
  ui.ports = ports;

  // ---- hero ------------------------------------------------------------
  setText(ui.heroLabel, ctx.t('实时总输出'));
  const total = live ? num(state.totals && state.totals.watts) : null;
  const limit = num(state.totals && state.totals.limit, 160) || 160;
  const totals = (state && state.totals) || {};
  const chargingCount = live
    ? Number.isFinite(Number(totals.chargingCount))
      ? num(totals.chargingCount)
      : ports.filter((p) => p.enabled && p.watts > 0.1).length
    : 0;
  const connectedCount = live
    ? Number.isFinite(Number(totals.connectedCount))
      ? num(totals.connectedCount)
      : ports.filter((p) => p.enabled && cableAttached(p)).length
    : 0;

  if (total == null) {
    setText(ui.heroSub, ctx.t('%d / %d 端口在充电 · %d W 上限', 0, PORT_COUNT, limit));
    ui.readout.classList.add('ck-readout--empty');
    ui.readoutUnit.hidden = true;
    setText(ui.readoutNum, ctx.t('暂无数据'));
  } else {
    ui.readout.classList.remove('ck-readout--empty');
    ui.readoutUnit.hidden = false;
    roll(ui.readoutNum, total.toFixed(1));
    if (connectedCount > chargingCount) {
      setText(
        ui.heroSub,
        ctx.t(
          '%d / %d 端口在充电 · %d 口已连接未充电 · %d W 上限',
          chargingCount,
          PORT_COUNT,
          connectedCount - chargingCount,
          limit,
        ),
      );
    } else {
      setText(ui.heroSub, ctx.t('%d / %d 端口在充电 · %d W 上限', chargingCount, PORT_COUNT, limit));
    }
  }

  // stale / offline status row (hidden while live and fresh)
  const phase = (state && state.phase) || 'idle';
  const showStatus = !live && phase !== 'idle';
  ui.heroStatus.hidden = !showStatus;
  if (showStatus) {
    let dotState = 'warn';
    let label = ctx.t('数据陈旧');
    if (phase === 'failed') {
      dotState = 'danger';
      label = ctx.t('未连接');
    } else if (phase === 'scanning' || phase === 'connecting' || phase === 'handshake') {
      dotState = 'idle';
      label = ctx.t('搜索中');
    }
    ui.statusDot.dataset.state = dotState;
    ui.statusDot.dataset.busy = 'false';
    setText(ui.statusText, label);
  }

  // rail: chroma encodes magnitude, segments split by port
  const fraction = total == null ? 0 : Math.max(0, Math.min(1, total / limit));
  const intensity = total != null && total > 0 ? 0.45 + 0.55 * Math.pow(fraction, 0.6) : 0;
  const segments = ports.filter((p) => p.enabled && p.watts > 0.1);
  const segmentSig = segments.map((p) => `${p.index}:${p.watts.toFixed(2)}`).join(',');
  if (segments.length > 1) {
    ui.railFill.classList.add('ck-rail__fill--segments');
    ui.railFill.style.width = '100%';
    if (ui.railFill.dataset.sig !== segmentSig) {
      ui.railFill.dataset.sig = segmentSig;
      ui.railFill.textContent = '';
      for (const port of segments) {
        const seg = h('span', 'ck-rail__seg');
        seg.style.width = `${Math.min(100, (port.watts / limit) * 100)}%`;
        seg.style.opacity = String([1, 0.72, 0.5][port.index % 3]);
        ui.railFill.append(seg);
      }
    }
    ui.railFill.style.opacity = String(intensity);
  } else {
    ui.railFill.classList.remove('ck-rail__fill--segments');
    if (ui.railFill.dataset.sig !== 'single') {
      ui.railFill.dataset.sig = 'single';
      ui.railFill.textContent = '';
    }
    ui.railFill.style.width = `${fraction * 100}%`;
    ui.railFill.style.opacity = String(intensity);
  }

  // legend slot (fixed 12 px tall; visible only when >1 port shares the rail)
  const legendSig = segments.length > 1 ? segmentSig : '';
  if (ui.legend.dataset.sig !== legendSig) {
    ui.legend.dataset.sig = legendSig;
    ui.legend.textContent = '';
    if (segments.length > 1) {
      for (const port of segments) {
        const item = h('span', 'ck-hero__legend-item');
        const dot = h('span', 'ck-hero__legend-dot');
        dot.style.opacity = String([1, 0.72, 0.5][port.index % 3]);
        const label = h('span', 'ck-hero__legend-label ck-u-num', port.label);
        const value = h(
          'span',
          'ck-hero__legend-value ck-u-num',
          port.watts < 10 ? `${port.watts.toFixed(1)} W` : `${Math.round(port.watts)} W`,
        );
        item.append(dot, label, value);
        ui.legend.append(item);
      }
    }
  }
  ui.legend.dataset.visible = segments.length > 1 ? 'true' : 'false';

  // ---- inspector -------------------------------------------------------
  setText(ui.inspTitle, ctx.t('端口'));
  setText(ui.inspHint, selectedPort == null ? ctx.t('点击端口查看单口曲线') : ctx.t('已选 C%d', selectedPort + 1));
  for (let i = 0; i < ui.rowViews.length; i += 1) {
    updatePortRow(ui.rowViews[i], i, state, ports[i], live, total == null ? 0 : total);
  }

  // ---- chart -----------------------------------------------------------
  setText(ui.chartTitle, ctx.t('功率时间线'));
  setText(
    ui.chartHint,
    selectedPort == null ? ctx.t('指针移到图上查看任意时刻') : ctx.t('总输出 + C%d', selectedPort + 1),
  );
  ui.chart.setEmptyText(live ? ctx.t('正在积累功率曲线…') : ctx.t('连接后开始记录功率曲线'), '');
  ui.chart.setSelected(selectedPort);
  ui.chart.update(state);

  // ---- stats -----------------------------------------------------------
  const stats = (state && state.stats) || {};
  roll(ui.stats.peak.value, live ? num(stats.peakW).toFixed(1) : '—');
  setText(ui.stats.peak.unit, 'W');
  roll(ui.stats.average.value, live ? num(stats.avgW).toFixed(1) : '—');
  setText(ui.stats.average.unit, 'W');
  const energyRaw = scopeEnergy(state, energyScope);
  let energy;
  try {
    energy = ctx.fmt && ctx.fmt.energy
      ? ctx.fmt.energy(live ? energyRaw : 0)
      : { value: energyRaw.toFixed(1), unit: 'Wh' };
  } catch (_) {
    energy = { value: energyRaw.toFixed(1), unit: 'Wh' };
  }
  setText(ui.stats.energyLabelText, scopeLabel(ctx, energyScope));
  roll(ui.stats.energyValue, live ? energy.value : '—');
  setText(ui.stats.energyUnit, energy.unit);
  ui.stats.durationUnit.textContent = '';
  ui.durationBase = live ? num(stats.connectedMs) : 0;
  ui.durationAt = Date.now();
  updateDuration(ui);

  // ---- stage -----------------------------------------------------------
  try {
    ui.stage.update(state);
    const badges = [];
    for (let i = 0; i < PORT_COUNT; i += 1) {
      const port = ports[i] || { enabled: false, watts: 0, label: PORTS_ORDER[i] };
      let text;
      const lit = port.watts > 0.1;
      if (!live) text = '—';
      else if (lit) text = `${port.label}  ${port.watts.toFixed(1)} W`;
      else if (cableAttached(port)) text = `${port.label}  ${ctx.t('已接线')}`;
      else text = `${port.label}  ${ctx.t('未接线')}`;
      badges.push({ label: port.label, text, lit, watts: port.watts, enabled: port.enabled });
    }
    ui.stage.setPorts(badges);
    ui.stage.setSelected(selectedPort);
  } catch (error) {
    console.error('[overview] stage update failed', error);
  }

  applySelection(ui);
}

function updatePortRow(view, index, state, port, live, total) {
  const ctx = ui.ctx;
  if (!port) {
    port = { index, label: PORTS_ORDER[index], enabled: false, watts: 0, volts: 0, amps: 0, status: 0 };
  }
  view.port = port;
  view.row.dataset.on = port.enabled ? 'true' : 'false';
  view.row.dataset.live = live ? 'true' : 'false';
  const delivering = port.watts > 0.1;
  view.row.dataset.delivering = delivering && port.enabled ? 'true' : 'false';
  view.usbc.dataset.lit = delivering && live ? 'true' : 'false';

  const nickname = port.nickname != null ? String(port.nickname).trim() : '';
  if (nickname) {
    view.nick.textContent = nickname;
    view.nick.dataset.placeholder = 'false';
  } else {
    view.nick.textContent = ctx.t('备注');
    view.nick.dataset.placeholder = 'true';
  }

  const chip = live ? cableChip(ctx, state, port) : '';
  view.chip.textContent = chip || '—';
  view.chip.dataset.placeholder = chip ? 'false' : 'true';

  view.switchInput.checked = port.enabled;
  view.switchInput.disabled = !live;
  view.timer.disabled = !live || !port.enabled;
  view.timer.dataset.active = num(port.countdownEndMs) > 0 ? 'true' : 'false';

  const readings = live && hasReadings(port);
  roll(view.watts, readings ? port.watts.toFixed(1) : '—');
  setText(view.volts, readings ? port.volts.toFixed(2) : '—');
  setText(view.amps, readings ? port.amps.toFixed(2) : '—');
  setText(view.status, portStatusText(ctx, state, port, total));

  setText(view.auxLabel, ctx.t('接入设备'));
  const deviceText = portDeviceText(ctx, state, port);
  setText(view.auxValue, deviceText);
  view.auxValue.dataset.placeholder = deviceText === '—' ? 'true' : 'false';

  const fraction = Math.max(0, Math.min(1, port.watts / 160));
  view.railFill.style.width = `${fraction * 100}%`;
  view.railFill.dataset.lit = delivering && port.enabled ? 'true' : 'false';
}

function updateDuration(state) {
  if (!ui || ui.disposed || !state) return;
  const live = isLive(state.state);
  const ms = live
    ? (state.durationBase || 0) + Math.max(0, Date.now() - (state.durationAt || Date.now()))
    : 0;
  let text = '—';
  if (live) {
    try {
      text = ui.ctx.fmt.clock(ms);
    } catch (_) {
      text = '—';
    }
  }
  if (ui.stats.durationValue) setText(ui.stats.durationValue, text);
}

// ---------------------------------------------------------------------------
// selection / actions

function selectPort(state, index) {
  selectedPort = selectedPort === index ? null : index;
  applySelection(state);
  try {
    ui.chart.setSelected(selectedPort);
  } catch (_) {
    /* ignore */
  }
  setText(
    ui.inspHint,
    selectedPort == null ? ui.ctx.t('点击端口查看单口曲线') : ui.ctx.t('已选 C%d', selectedPort + 1),
  );
  setText(
    ui.chartHint,
    selectedPort == null ? ui.ctx.t('指针移到图上查看任意时刻') : ui.ctx.t('总输出 + C%d', selectedPort + 1),
  );
}

function applySelection(state) {
  if (!ui) return;
  for (let i = 0; i < ui.rowViews.length; i += 1) {
    const row = ui.rowViews[i].row;
    row.dataset.selected = selectedPort === i ? 'true' : 'false';
    row.setAttribute('aria-pressed', selectedPort === i ? 'true' : 'false');
  }
  for (let i = 0; i < ui.stageChrome.badges.length; i += 1) {
    const badge = ui.stageChrome.badges[i];
    badge.dataset.selected = selectedPort === i ? 'true' : 'false';
    badge.setAttribute('aria-pressed', selectedPort === i ? 'true' : 'false');
  }
  try {
    ui.stage?.setSelected?.(selectedPort);
  } catch (_) {
    /* ignore */
  }
  void state;
}

async function togglePort(state, index, next) {
  const port = (ui.ports && ui.ports[index]) || { label: PORTS_ORDER[index] };
  const label = port.label || PORTS_ORDER[index];
  const ctx = ui.ctx;
  const on = Boolean(next);
  const confirmed = await confirmDialog({
    title: on ? ctx.t('打开 %@？', label) : ctx.t('关闭 %@？', label),
    body: on ? ctx.t('%@ 将恢复供电。', label) : ctx.t('正在从 %@ 取电的设备会立即断电。', label),
    confirm: on ? ctx.t('打开端口') : ctx.t('关闭端口'),
    cancel: ctx.t('取消'),
    destructive: !on,
  });
  if (!confirmed) return;
  try {
    await ctx.call('Charker.setPortEnabled', label, on);
  } catch (error) {
    console.warn('[overview] setPortEnabled failed', error);
    try {
      ctx.toast?.(String((error && error.message) || error), 'error');
    } catch (_) {
      /* ignore */
    }
  }
}

function openTimerMenu(state, index, anchor) {
  const ctx = ui.ctx;
  const port = (ui.ports && ui.ports[index]) || { label: PORTS_ORDER[index] };
  const label = port.label || PORTS_ORDER[index];
  const items = [
    { minutes: 60, label: ctx.t('1 小时') },
    { minutes: 120, label: ctx.t('2 小时') },
    { minutes: 180, label: ctx.t('3 小时') },
  ].map((preset) => ({
    label: preset.label,
    onSelect: () => setCountdown(label, preset.minutes),
  }));
  if (num(port.countdownEndMs) > 0) {
    items.push('-', {
      label: ctx.t('关闭倒计时'),
      danger: true,
      onSelect: () => setCountdown(label, 0),
    });
  }
  openPopover(anchor, items, { align: 'end' });
}

async function setCountdown(label, minutes) {
  const ctx = ui && ui.ctx;
  if (!ctx) return;
  try {
    await ctx.call('Charker.setCountdown', label, minutes);
  } catch (error) {
    console.warn('[overview] setCountdown failed', error);
  }
}

function openEnergyMenu(state) {
  if (!ui) return;
  const ctx = ui.ctx;
  const scopes = [
    { id: 'session', label: ctx.t('本次') },
    { id: 'day', label: ctx.t('今天') },
    { id: 'week', label: ctx.t('本周') },
    { id: 'month', label: ctx.t('本月') },
  ];
  const items = scopes.map((scope) => ({
    label: scope.label,
    checked: energyScope === scope.id,
    onSelect: () => {
      energyScope = scope.id;
      update(ui.state || state);
    },
  }));
  items.push('-');
  items.push({
    label: ctx.t('查看能耗记录'),
    onSelect: () => {
      try {
        ctx.navigate?.('energy');
      } catch (_) {
        /* ignore */
      }
    },
  });
  items.push({ label: ctx.t('结束本次统计'), disabled: true, onSelect: () => {} });
  openPopover(ui.stats.energyTile, items, { align: 'start' });
}

// ---------------------------------------------------------------------------
// screen entry point (contract §5)

export function render(root, state, ctx) {
  try {
    const stale = !ui || ui.root !== root || !ui.dash.isConnected || ui.disposed;
    if (stale) {
      if (ui) {
        try {
          ui.cleanup?.();
        } catch (_) {
          /* ignore */
        }
        ui = null;
      }
      ui = mount(root, ctx);
    }
    update(state);
  } catch (error) {
    console.error('[overview] render failed', error);
  }
}

export default render;
