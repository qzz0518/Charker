// sc- shared helpers for the five secondary screens (energy / devices /
// settings / menubar / about). Owner: web-screens.
//
// Everything here is presentation-only: no state is kept in the module except
// the string table fallback. Screens own their DOM and call these builders.

import { SCREEN_STRINGS } from '../strings-screens.js';

// ---------------------------------------------------------------------------
// DOM

/** Tiny element builder. Dynamic user-visible strings always land in
 *  textContent, never innerHTML (spec-ui §7.2.10). `html` is only for the
 *  static, trusted SVG returned by the shell's icon registry. */
export function h(tag, attrs = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs || {})) {
    if (value == null || value === false) continue;
    if (key === 'class') el.className = value;
    else if (key === 'text') el.textContent = value;
    else if (key === 'html') el.innerHTML = value;
    else if (key === 'dataset') Object.assign(el.dataset, value);
    else if (key === 'style' && typeof value === 'object') Object.assign(el.style, value);
    else if (key.startsWith('on') && typeof value === 'function') {
      el.addEventListener(key.slice(2).toLowerCase(), value);
    } else if (value === true) el.setAttribute(key, '');
    else el.setAttribute(key, String(value));
  }
  append(el, kids);
  return el;
}

function append(el, kids) {
  for (const kid of kids) {
    if (kid == null || kid === false) continue;
    if (Array.isArray(kid)) append(el, kid);
    else if (kid instanceof Node) el.append(kid);
    else el.append(document.createTextNode(String(kid)));
  }
}

/** Set textContent only when it changed, so live re-renders keep selection,
 *  scroll and the DOM nodes stable. */
export function txt(el, value) {
  const next = value == null ? '' : String(value);
  if (el && el.textContent !== next) el.textContent = next;
  return el;
}

export function clear(el) {
  while (el.firstChild) el.removeChild(el.firstChild);
}

// ---------------------------------------------------------------------------
// Strings

function formatArgs(template, args) {
  let i = 0;
  return String(template).replace(/%(?:\.(\d+))?([@dsfxX%])/g, (m, prec, kind) => {
    if (kind === '%') return '%';
    const v = args[i++];
    if (kind === '@' || kind === 's') return v == null ? '—' : String(v);
    if (kind === 'd') return String(Math.trunc(Number(v) || 0));
    if (kind === 'f') return (Number(v) || 0).toFixed(prec == null ? 0 : Number(prec));
    return String(v);
  });
}

function localeOf(state) {
  return state && state.app && String(state.app.locale).toLowerCase().startsWith('en') ? 'en' : 'zh';
}

// ---------------------------------------------------------------------------
// UI context

/**
 * Build the per-render UI context every screen and builder uses:
 *   ui.t(key, ...args)   localized text (shell table, extension fallback)
 *   ui.toast(text, kind) app-wide toast (shell helper, local fallback)
 *   ui.icon(name)        SVG markup from the shell icon registry
 *   ui.el(name, size)    element wrapping that icon
 *   ui.locale            'zh' | 'en'
 *   ui.fmt / ui.num      number formatting
 *   ui.ctx / ui.state    the raw shell context + snapshot
 */
export function makeUI(ctx, state) {
  const locale = localeOf(state);
  const table = (SCREEN_STRINGS && SCREEN_STRINGS[locale]) || {};
  const zhTable = (SCREEN_STRINGS && SCREEN_STRINGS.zh) || {};

  const t = (key, ...args) => {
    let out;
    try {
      out = ctx && typeof ctx.t === 'function' ? ctx.t(key, ...args) : undefined;
    } catch (_) {
      out = undefined;
    }
    if (out == null || out === key) {
      const raw = table[key] != null ? table[key] : zhTable[key];
      out = raw != null ? formatArgs(raw, args) : key;
    }
    return out;
  };

  let toastEl = null;
  let toastTimer = 0;
  const toast = (text, kind = 'info') => {
    if (ctx && typeof ctx.toast === 'function') {
      try {
        ctx.toast(text, kind);
        return;
      } catch (_) { /* fall through to the local card */ }
    }
    // Fallback only when the shell has no toast helper: a floating card at the
    // top of the page, exactly the spec-ui §3.20 treatment.
    if (!toastEl) {
      toastEl = h('div', { class: 'sc-toast', role: 'status', 'aria-live': 'polite' },
        h('span', { class: 'sc-toast__ico' }),
        h('span', { class: 'sc-toast__text' }),
        h('button', { class: 'sc-toast__close', type: 'button', 'aria-label': '×', onclick: () => hideToast() }, '×'));
      document.body.append(toastEl);
      if (ctx && typeof ctx.onCleanup === 'function') {
        ctx.onCleanup(() => {
          if (toastEl) { toastEl.remove(); toastEl = null; }
          if (toastTimer) clearTimeout(toastTimer);
        });
      }
    }
    toastEl.dataset.kind = kind;
    txt(toastEl.querySelector('.sc-toast__text'), text);
    toastEl.hidden = false;
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(hideToast, 4200);
  };
  const hideToast = () => {
    if (toastTimer) { clearTimeout(toastTimer); toastTimer = 0; }
    if (toastEl) toastEl.hidden = true;
  };

  const iconMarkup = (name) => {
    if (!name) return '';
    try {
      if (ctx && ctx.icon && typeof ctx.icon === 'function') {
        const s = ctx.icon(name);
        if (typeof s === 'string' && s) return s;
      }
      if (ctx && ctx.icons && typeof ctx.icons.get === 'function') {
        const s = ctx.icons.get(name);
        if (typeof s === 'string' && s) return s;
      }
    } catch (_) { /* fall back to a dot */ }
    return `<svg viewBox="0 0 16 16" aria-hidden="true" focusable="false"><circle cx="8" cy="8" r="2.4" fill="currentColor"/></svg>`;
  };

  const el = (name, size = 12, extraClass = '') => {
    const span = h('span', { class: `sc-ico${extraClass ? ' ' + extraClass : ''}`, 'aria-hidden': 'true', style: { width: `${size}px`, height: `${size}px` } });
    span.innerHTML = iconMarkup(name);
    return span;
  };

  const num = (value) => h('span', { class: 'ck-u-num', text: value });

  return {
    ctx,
    state,
    locale,
    t,
    toast,
    icon: iconMarkup,
    el,
    num,
    fmt: {
      /** Whole/decimals number with locale grouping. */
      number: (n, d = 0) => {
        if (n == null || !Number.isFinite(Number(n))) return '—';
        try {
          return new Intl.NumberFormat(locale === 'en' ? 'en-US' : 'zh-CN', {
            minimumFractionDigits: d, maximumFractionDigits: d,
          }).format(Number(n));
        } catch (_) {
          return Number(n).toFixed(d);
        }
      },
      watts: (n, d = 1) => {
        if (n == null || !Number.isFinite(Number(n))) return '—';
        const v = Number(n);
        return d == null ? String(Math.round(v)) : v.toFixed(d);
      },
    },
  };
}

/** True when the shell context carries at least the core call helper. */
export function hasBridge(ui) {
  return !!(ui && ui.ctx && typeof ui.ctx.call === 'function');
}

/** Promise-safe bridge call: resolves `fallback` instead of rejecting. */
export async function callSafe(ui, method, args, fallback = null) {
  if (!hasBridge(ui)) return fallback;
  try {
    const out = await ui.ctx.call(method, ...(args || []));
    return out == null ? fallback : out;
  } catch (err) {
    return { __error: err };
  }
}

/** Await a call and toast its failure text; returns result or fallback. */
export async function callToast(ui, method, args, fallback = null) {
  const out = await callSafe(ui, method, args, fallback);
  if (out && out.__error) {
    const msg = out.__error && out.__error.message ? out.__error.message : String(out.__error);
    ui.toast(ui.t('操作失败：%@', msg), 'error');
    return fallback;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Number / date formatting

/** Energy value + unit per spec-ui §3.13: <10 Wh 2 dp, <1000 Wh 1 dp,
 *  >=1000 Wh as kWh (2 dp, 1 dp at >=10 kWh). */
export function energyParts(wh) {
  const v = Number(wh);
  if (!Number.isFinite(v)) return ['—', 'Wh'];
  if (Math.abs(v) >= 1000) {
    const k = v / 1000;
    return [Math.abs(k) >= 10 ? k.toFixed(1) : k.toFixed(2), 'kWh'];
  }
  if (Math.abs(v) >= 10) return [v.toFixed(1), 'Wh'];
  return [v.toFixed(2), 'Wh'];
}

/** Compact localized duration: 42s / 5m / 3h12m / 2 天 3 小时. */
export function durationText(ui, ms) {
  const sec = Math.round(Math.max(0, Number(ms) || 0) / 1000);
  if (sec < 60) return ui.t('%ds', sec);
  if (sec < 3600) return ui.t('%dm', Math.floor(sec / 60));
  if (sec < 86400) {
    const h = Math.floor(sec / 3600);
    const m = Math.floor((sec % 3600) / 60);
    return ui.t('%dh%dm', h, m);
  }
  const d = Math.floor(sec / 86400);
  const h = Math.floor((sec % 86400) / 3600);
  return ui.t('%d天 %d小时', d, h);
}

export function clockText(locale, ts) {
  if (!Number.isFinite(Number(ts)) || Number(ts) <= 0) return '—';
  try {
    return new Intl.DateTimeFormat(locale === 'en' ? 'en-US' : 'zh-CN', {
      hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false,
    }).format(new Date(Number(ts)));
  } catch (_) {
    return new Date(Number(ts)).toLocaleTimeString();
  }
}

export function timeText(locale, ts) {
  if (!Number.isFinite(Number(ts)) || Number(ts) <= 0) return '—';
  try {
    return new Intl.DateTimeFormat(locale === 'en' ? 'en-US' : 'zh-CN', {
      hour: '2-digit', minute: '2-digit', hour12: false,
    }).format(new Date(Number(ts)));
  } catch (_) {
    return new Date(Number(ts)).toLocaleTimeString();
  }
}

export function dayKey(ts) {
  try {
    const d = new Date(Number(ts));
    return `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;
  } catch (_) {
    return String(ts);
  }
}

/** 今天 / 昨天 / 2026年8月14日周五-style day header. */
export function dayLabel(ui, ts) {
  const now = new Date();
  const d = new Date(Number(ts));
  const today = dayKey(now.getTime());
  const yesterday = dayKey(now.getTime() - 86400000);
  const key = dayKey(ts);
  if (key === today) return ui.t('今天');
  if (key === yesterday) return ui.t('昨天');
  try {
    return new Intl.DateTimeFormat(ui.locale === 'en' ? 'en-US' : 'zh-CN', {
      year: 'numeric', month: 'long', day: 'numeric', weekday: 'short',
    }).format(d);
  } catch (_) {
    return d.toLocaleDateString();
  }
}

/** Relative time ("2 小时前"), for the last-seen row. */
export function relativeText(ui, ms) {
  const diff = Number(ms);
  if (!Number.isFinite(diff)) return '—';
  const sec = Math.round(diff / 1000);
  const abs = Math.abs(sec);
  let unit = 'second';
  let div = 1;
  if (abs >= 86400 * 30) { unit = 'month'; div = 86400 * 30; }
  else if (abs >= 86400 * 7) { unit = 'week'; div = 86400 * 7; }
  else if (abs >= 86400) { unit = 'day'; div = 86400; }
  else if (abs >= 3600) { unit = 'hour'; div = 3600; }
  else if (abs >= 60) { unit = 'minute'; div = 60; }
  try {
    return new Intl.RelativeTimeFormat(ui.locale === 'en' ? 'en-US' : 'zh-CN', { numeric: 'auto' })
      .format(Math.round(sec / div), unit);
  } catch (_) {
    return `${Math.round(sec / div)} ${unit}`;
  }
}

/** Axis label for an energy bucket by range: HH / 周一 / M/D. */
export function bucketLabel(ui, ts, range) {
  const d = new Date(Number(ts));
  if (!Number.isFinite(d.getTime())) return '';
  try {
    if (range === 'day') {
      return new Intl.DateTimeFormat(ui.locale === 'en' ? 'en-US' : 'zh-CN', { hour: '2-digit', hour12: false })
        .format(d).replace(/^24$/, '00');
    }
    if (range === 'week') {
      return new Intl.DateTimeFormat(ui.locale === 'en' ? 'en-US' : 'zh-CN', { weekday: 'short' }).format(d);
    }
    return new Intl.DateTimeFormat(ui.locale === 'en' ? 'en-US' : 'zh-CN', { month: 'numeric', day: 'numeric' }).format(d);
  } catch (_) {
    return String(d.getHours());
  }
}

export function currencySymbol(code) {
  switch (String(code || '').toUpperCase()) {
    case 'CNY': case 'RMB': return '¥';
    case 'USD': return '$';
    case 'EUR': return '€';
    case 'GBP': return '£';
    case 'JPY': return '¥';
    case 'KRW': return '₩';
    default: return code ? `${code} ` : '¥';
  }
}

export function clamp(n, lo, hi) { return Math.min(hi, Math.max(lo, n)); }

// ---------------------------------------------------------------------------
// Shared page-level components (ck-card + sc- scaffolding)

export function pageHead(ui, titleKey, actions = []) {
  return h('header', { class: 'ck-page__head sc-head' },
    h('div', { class: 'sc-head__text' },
      h('h1', { class: 'ck-page__title ck-t-title sc-head__title', text: ui.t(titleKey) })),
    actions.length ? h('div', { class: 'ck-page__actions sc-head__actions' }, actions) : null);
}

export function actionButton(ui, label, { tone = '', icon = '', onclick, disabled = false, title } = {}) {
  const cls = ['ck-btn', tone ? `ck-btn--${tone}` : '', 'sc-btn'].filter(Boolean).join(' ');
  const el = h('button', {
    class: cls, type: 'button', disabled: disabled || false,
    title: title || label || '', 'aria-label': title || label || '',
    onclick: (e) => { if (!disabled && onclick) onclick(e); },
  }, icon ? ui.el(icon, 11) : null, label ? h('span', { text: label }) : null);
  return el;
}

export function iconButton(ui, iconName, label, onclick, { disabled = false, tone = '' } = {}) {
  return h('button', {
    class: `ck-icon-btn sc-iconbtn${tone ? ` sc-iconbtn--${tone}` : ''}`,
    type: 'button', title: label, 'aria-label': label, disabled: disabled || false,
    onclick: (e) => { if (!disabled) onclick(e); },
  }, ui.el(iconName, 11));
}

export function chip(text, tone = 'neutral') {
  return h('span', { class: `ck-chip ck-chip--${tone} sc-chip`, text });
}

export function card(cls = '', ...kids) {
  return h('section', { class: `ck-card sc-card${cls ? ' ' + cls : ''}` }, kids);
}

export function group(ui, { title, footnote, actions = [], chipText, chipTone } = {}, ...rows) {
  const label = title
    ? h('div', { class: 'sc-group__label' },
      h('span', { class: 'ck-t-label', text: ui.t(title) }),
      chipText ? chip(chipText, chipTone) : null,
      actions.length ? h('span', { class: 'sc-group__actions' }, actions) : null)
    : null;
  return h('section', { class: 'sc-group' },
    label,
    h('div', { class: 'sc-group__card ck-card' }, ...rows),
    footnote ? h('p', { class: 'sc-group__foot ck-u-cjk', text: ui.t(footnote) }) : null);
}

/** A plain settings row: label (+subtitle) left, control right. */
export function row(ui, { title, sub, control, fitted = false, titleEl } = {}) {
  return h('div', { class: `sc-row${fitted ? ' sc-row--fitted' : ''}` },
    h('div', { class: 'sc-row__text' },
      titleEl || h('span', { class: 'ck-t-body sc-row__title', text: title == null ? '' : (titleEl ? '' : ui.t(title)) }),
      sub ? h('span', { class: 'ck-t-caption sc-row__sub sc-muted ck-u-cjk', text: ui.t(sub) }) : null),
    control ? h('div', { class: 'sc-row__control' }, control) : null);
}

export function divider(cls = '') {
  return h('div', { class: `sc-divider${cls ? ' ' + cls : ''}`, role: 'separator' });
}

// ---- switch ---------------------------------------------------------------

/** Control only. Pair with `switchRow`.
 *  @returns {{el: HTMLElement, set(checked:boolean, disabled?:boolean):void}} */
export function switchControl({ checked = false, label = '', onChange, disabled = false } = {}) {
  const input = h('input', { type: 'checkbox', role: 'switch', 'aria-label': label });
  input.checked = !!checked;
  input.disabled = !!disabled;
  const el = h('label', { class: 'ck-switch sc-switch' }, input,
    h('span', { class: 'ck-switch__track' }, h('span', { class: 'ck-switch__knob' })));
  input.addEventListener('change', () => { if (onChange) onChange(input.checked); });
  return {
    el,
    set(next, disabledNext) {
      input.checked = !!next;
      if (disabledNext != null) input.disabled = !!disabledNext;
    },
  };
}

/** Full switch row with visible label, optional subtitle and trailing note. */
export function switchRow(ui, { title, sub, checked = false, onChange, disabled = false, note }) {
  const sw = switchControl({ checked, label: ui.t(title || ''), onChange, disabled });
  const el = row(ui, {
    title,
    sub,
    titleEl: note ? h('span', { class: 'ck-t-body sc-row__title' },
      h('span', { text: ui.t(title) }), h('span', { class: 'sc-row__note', text: ui.t(note) })) : null,
    control: sw.el,
  });
  el.classList.add('sc-row--switch');
  return { el, set: sw.set };
}

// ---- segmented ------------------------------------------------------------

/** Capsule segmented control; one thumb slides to the selected item. */
export function segControl({ items, value, onChange, label = '', width = 0 } = {}) {
  const index = Math.max(0, items.findIndex((it) => it.value === value));
  const el = h('div', {
    class: 'ck-seg sc-seg', role: 'tablist', 'aria-label': label,
    style: { '--n': String(items.length), '--i': String(index), ...(width ? { width: `${width}px` } : {}) },
  }, h('span', { class: 'ck-seg__thumb', 'aria-hidden': 'true' }));
  const buttons = items.map((it) => {
    const btn = h('button', {
      class: 'ck-seg__item', type: 'button', role: 'tab', 'aria-selected': String(it.value === value),
      text: it.label,
      onclick: () => { if (it.value !== value) { value = it.value; set(it.value); if (onChange) onChange(it.value); } },
    });
    el.append(btn);
    return btn;
  });
  function set(next) {
    value = next;
    const i = Math.max(0, items.findIndex((it) => it.value === next));
    el.style.setProperty('--i', String(i));
    buttons.forEach((b, bi) => b.setAttribute('aria-selected', String(bi === i)));
  }
  return { el, set };
}

export function segRow(ui, { title, items, value, onChange, width = 0 }) {
  const seg = segControl({ items, value, onChange, label: ui.t(title || ''), width });
  return { el: row(ui, { title, control: seg.el }), set: seg.set };
}

// ---- slider ---------------------------------------------------------------

/** Settings slider with value pill; commits on release / keyboard change. */
export function sliderRow(ui, {
  title, sub, min, max, step = 1, value, unit = '', suffixText = '', onChange, onCommit,
  disabled = false, ariaLabel,
}) {
  const pill = h('span', { class: 'sc-valuepill' },
    h('span', { class: 'ck-u-num sc-valuepill__num' }), h('span', { class: 'sc-valuepill__unit', text: unit }));
  const fill = clamp(((value - min) / (max - min)) * 100, 0, 100);
  const input = h('input', {
    type: 'range', class: 'sc-range', min: String(min), max: String(max), step: String(step),
    value: String(value), 'aria-label': ariaLabel || ui.t(title), disabled: disabled || false,
  });
  input.style.setProperty('--fill', `${fill}%`);
  txt(pill.querySelector('.sc-valuepill__num'), String(Math.round(value)));
  const marks = [];
  const steps = Math.max(1, Math.round((max - min) / step));
  const dots = h('div', { class: 'sc-range__ticks', 'aria-hidden': 'true' });
  for (let i = 0; i <= steps && steps <= 40; i++) dots.append(h('i'));
  const el = h('div', { class: 'sc-slider' },
    h('div', { class: 'sc-slider__head' },
      h('div', { class: 'sc-slider__titles' },
        h('span', { class: 'ck-t-body sc-row__title', text: ui.t(title) }),
        sub ? h('span', { class: 'ck-t-caption sc-row__sub sc-muted ck-u-cjk', text: ui.t(sub) }) : null),
      h('div', { class: 'sc-slider__value' }, pill, suffixText ? h('span', { class: 'ck-t-body sc-muted', text: suffixText }) : null)),
    input, dots);
  input.addEventListener('input', () => {
    const v = Number(input.value);
    txt(pill.querySelector('.sc-valuepill__num'), String(Math.round(v)));
    input.style.setProperty('--fill', `${clamp(((v - min) / (max - min)) * 100, 0, 100)}%`);
    if (onChange) onChange(v);
  });
  input.addEventListener('change', () => { if (onCommit) onCommit(Number(input.value)); });
  return {
    el,
    get value() { return Number(input.value); },
    set(v, disabledNext) {
      input.value = String(v);
      txt(pill.querySelector('.sc-valuepill__num'), String(Math.round(v)));
      input.style.setProperty('--fill', `${clamp(((v - min) / (max - min)) * 100, 0, 100)}%`);
      if (disabledNext != null) input.disabled = !!disabledNext;
    },
    input,
  };
}

// ---- select (native, styled) ---------------------------------------------

export function selectControl({ items, value, onChange, label = '', disabled = false }) {
  const el = h('select', { class: 'sc-select', 'aria-label': label, disabled: disabled || false });
  for (const it of items) {
    el.append(h('option', { value: String(it.value), selected: String(it.value) === String(value), text: it.label }));
  }
  el.addEventListener('change', () => { if (onChange) onChange(el.value); });
  return { el, set(next) { el.value = String(next); } };
}

export function selectRow(ui, { title, sub, items, value, onChange, disabled = false }) {
  const sel = selectControl({ items, value, onChange, label: ui.t(title || ''), disabled });
  return { el: row(ui, { title, sub, control: sel.el }), set: sel.set };
}

// ---- notices / empty / skeleton ------------------------------------------

export function notice(ui, kind, text, { action } = {}) {
  const tone = kind === 'error' || kind === 'danger' ? 'danger' : kind === 'warn' ? 'warn' : 'info';
  const icon = tone === 'danger' ? 'alert-circle' : tone === 'warn' ? 'alert-triangle' : 'info';
  return h('div', { class: `sc-notice sc-notice--${tone}`, role: tone === 'info' ? 'status' : 'alert' },
    ui.el(icon, 13, 'sc-notice__ico'),
    h('div', { class: 'sc-notice__text ck-u-cjk', text }),
    action || null);
}

export function emptyState(ui, { icon = 'gauge', title, detail, actions = [], compact = false } = {}) {
  return h('div', { class: `sc-empty${compact ? ' sc-empty--compact' : ''}` },
    ui.el(icon, 28, 'sc-empty__ico'),
    h('div', { class: 'sc-empty__title ck-t-heading', text: title }),
    detail ? h('div', { class: 'sc-empty__detail ck-t-caption sc-muted ck-u-cjk', text: detail }) : null,
    actions.length ? h('div', { class: 'sc-empty__actions' }, actions) : null);
}

export function skeleton(rows = 3, { height = 14 } = {}) {
  const el = h('div', { class: 'sc-skel', 'aria-hidden': 'true' });
  for (let i = 0; i < rows; i++) {
    el.append(h('div', { class: 'sc-skel__line', style: { height: `${height}px`, width: `${75 - i * 9}%` } }));
  }
  return el;
}

/** A metric tile used by the energy summary and stats bands. */
export function metric(ui, { label, value, unit, big = false, title }) {
  return h('div', { class: `sc-metric${big ? ' sc-metric--big' : ''}`, title: title || '' },
    h('span', { class: 'sc-metric__label ck-t-micro', text: ui.t(label) }),
    h('div', { class: 'sc-metric__value' },
      h('span', { class: 'ck-u-num', text: value }),
      unit ? h('span', { class: 'sc-metric__unit', text: unit }) : null));
}

/** "n 段" / label + chip pair used by card headers. */
export function cardHead(ui, { title, sub, right = [], chipText, chipTone = 'neutral' } = {}) {
  return h('header', { class: 'sc-cardhead' },
    h('div', { class: 'sc-cardhead__text' },
      h('div', { class: 'sc-cardhead__row' },
        h('h2', { class: 'ck-t-heading sc-cardhead__title', text: ui.t(title) }),
        chipText ? chip(chipText, chipTone) : null),
      sub ? h('p', { class: 'ck-t-micro sc-cardhead__sub sc-muted ck-u-cjk', text: typeof sub === 'string' ? sub : ui.t(sub) }) : null),
    right.length ? h('div', { class: 'sc-cardhead__right' }, right) : null);
}

/** Table-like header row shared by the ledger and the session lists. */
export function colHead(cols) {
  return h('div', { class: 'sc-colhead', role: 'row' },
    cols.map((c) => h('span', { class: `sc-colhead__cell${c.align ? ` sc-colhead__cell--${c.align}` : ''} ck-t-micro`, role: 'columnheader', text: c.label })));
}

/** Signal strength meter: 4 bars, lit per RSSI. */
export function signalBars(rssi) {
  const bars = rssi == null ? 0 : rssi >= -55 ? 4 : rssi >= -65 ? 3 : rssi >= -75 ? 2 : rssi >= -85 ? 1 : 0;
  const el = h('span', { class: 'sc-signal', 'aria-hidden': 'true' });
  for (let i = 1; i <= 4; i++) {
    el.append(h('i', { class: `sc-signal__bar${i <= bars ? ' is-on' : ''}`, style: { height: `${i * 3}px` } }));
  }
  return el;
}

/** Redacted Bluetooth address: keeps the OUI prefix and the tail. */
export function redactAddress(addr) {
  const s = String(addr || '').trim();
  if (!s) return '—';
  const parts = s.split(':');
  if (parts.length !== 6) return s.length > 5 ? `${s.slice(0, 2)}…` : s;
  return `${parts[0]}:${parts[1]}:••:••:${parts[4]}:${parts[5]}`;
}
