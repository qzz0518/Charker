// ============================================================================
// Charker — i18n (owner: web-shell)
//
// `t(key, ...args)`:
//   - key is the Chinese source string (spec-ui §6.2)
//   - Swift format specifiers: %@ %s %d %.1f %2$@? (positional is not used)
//     %x/%X (hex, honouring a precision like %02X) and %% for a literal percent
//   - object form: t('{n} / {total} 端口在充电', { n: 1, total: 3 })
//   - array form: t('已选 C%d', [2])
//   - missing key → the key itself (Chinese source text → safe fallback)
//
// `setLocale('zh' | 'en')` switches the table, sets <html lang>, refreshes all
// `[data-i18n]` nodes and notifies subscribers (main.js re-renders the route).
//
// Screen owners ship their own tables as strings-overview.js / strings-screens.js;
// `loadExternalStrings()` merges them per key OVER the base table at boot.
// ============================================================================

import { STRINGS } from './strings.js';

const LOCALE_TAGS = { zh: 'zh-CN', en: 'en-US' };
const EXTENSION_MODULES = ['./strings-overview.js', './strings-screens.js'];

/** Mutable merged tables: base shell/shared copy + every screen extension. */
const TABLES = {
  zh: { ...STRINGS.zh },
  en: { ...STRINGS.en },
};

const listeners = new Set();
let lang = 'zh';
let externalLoaded = false;

// ---------------------------------------------------------------------------
// Locale selection

export function isLocale(value) {
  return value === 'zh' || value === 'en';
}

/**
 * Initial locale, in priority order:
 *  1. `?lang=zh|en` (screenshot/debug override)
 *  2. `window.mygo.locale` (BCP 47 tag, available from document start)
 *  3. `zh` — the port's default (spec-ui §6.2 rule 1); this user's machine is
 *     zh-Hans, and Chinese is the source language so a missing translation
 *     degrades to readable text instead of key soup.
 */
export function detectLocale() {
  try {
    const query = new URLSearchParams(window.location.search).get('lang');
    if (isLocale(query)) return query;
  } catch (_) {
    /* ignore malformed URLs */
  }
  const bridgeLocale = window.mygo && window.mygo.locale;
  if (typeof bridgeLocale === 'string' && bridgeLocale) {
    return /^zh/i.test(bridgeLocale) ? 'zh' : 'en';
  }
  return 'zh';
}

export function getLocale() {
  return lang;
}

export function localeTag() {
  return LOCALE_TAGS[lang] || LOCALE_TAGS.zh;
}

/** Set the active locale; returns the accepted locale. No-op when identical. */
export function setLocale(next) {
  const resolved = isLocale(next) ? next : 'zh';
  const changed = resolved !== lang;
  lang = resolved;
  if (document.documentElement) {
    document.documentElement.lang = localeTag();
  }
  applyI18n(document);
  if (changed) {
    for (const fn of listeners) {
      try {
        fn(lang);
      } catch (err) {
        console.error('[charker] locale listener failed', err);
      }
    }
  }
  return lang;
}

/** Subscribe to locale changes. Returns an unsubscribe function. */
export function onLocaleChange(fn) {
  if (typeof fn !== 'function') return () => {};
  listeners.add(fn);
  return () => listeners.delete(fn);
}

// ---------------------------------------------------------------------------
// Translation

const SPECIFIER = /%(?:\.(\d+))?([@dfsxX%])/g;

function padHex(value, precision) {
  const text = Math.trunc(Math.abs(Number(value) || 0)).toString(16);
  return precision ? text.padStart(Number(precision), '0') : text;
}

function printf(template, values) {
  if (!values || !values.length) return template;
  let i = 0;
  return template.replace(SPECIFIER, (match, precision, kind) => {
    if (kind === '%') return '%';
    const value = values[i++];
    switch (kind) {
      case '@':
      case 's':
        return value == null ? '—' : String(value);
      case 'd':
        return String(Math.trunc(Number(value) || 0));
      case 'f':
        return (Number(value) || 0).toFixed(precision == null ? 2 : Number(precision));
      case 'x':
        return padHex(value, precision);
      case 'X':
        return padHex(value, precision).toUpperCase();
      default:
        return value == null ? '—' : String(value);
    }
  });
}

/**
 * Localize a key. `args` may be format-specifier values (spread or array) or a
 * single `{name}` interpolation object.
 * @param {string} key Chinese source string
 * @param {...unknown} args
 * @returns {string}
 */
export function t(key, ...args) {
  if (key == null) return '';
  const table = TABLES[lang] || TABLES.zh;
  let text = table[key];
  if (text == null) text = TABLES.zh[key];
  // Missing key: fall back to the Chinese source string (= the key) but still
  // apply the format specifiers, so a screen that forgot a table entry still
  // prints "操作失败：timeout" instead of the raw "操作失败：%@".
  if (text == null) text = String(key);
  text = String(text);

  if (args.length === 1) {
    const only = args[0];
    if (only && typeof only === 'object' && !Array.isArray(only)) {
      return text.replace(/\{(\w+)\}/g, (match, name) =>
        only[name] != null ? String(only[name]) : match,
      );
    }
    if (Array.isArray(only)) return printf(text, only);
  }
  return printf(text, args);
}

// ---------------------------------------------------------------------------
// data-i18n attributes (static shell markup)

/**
 * Refresh every localized node under `root`:
 *   data-i18n="key"              → textContent
 *   data-i18n-title="key"        → title attribute
 *   data-i18n-aria="key"         → aria-label attribute
 *   data-i18n-placeholder="key"  → placeholder attribute
 */
export function applyI18n(root = document) {
  if (!root || typeof root.querySelectorAll !== 'function') return;
  for (const el of root.querySelectorAll('[data-i18n]')) {
    const value = t(el.getAttribute('data-i18n'));
    if (el.textContent !== value) el.textContent = value;
  }
  for (const el of root.querySelectorAll('[data-i18n-title]')) {
    el.setAttribute('title', t(el.getAttribute('data-i18n-title')));
  }
  for (const el of root.querySelectorAll('[data-i18n-aria]')) {
    el.setAttribute('aria-label', t(el.getAttribute('data-i18n-aria')));
  }
  for (const el of root.querySelectorAll('[data-i18n-placeholder]')) {
    el.setAttribute('placeholder', t(el.getAttribute('data-i18n-placeholder')));
  }
}

// ---------------------------------------------------------------------------
// Extension tables (screen owners)

/** Merge `{zh, en}` tables into the live registry, per key (extension wins). */
export function mergeStrings(table) {
  if (!table || typeof table !== 'object') return;
  for (const locale of ['zh', 'en']) {
    const source = table[locale];
    if (!source || typeof source !== 'object') continue;
    for (const [key, value] of Object.entries(source)) {
      if (typeof value === 'string') TABLES[locale][key] = value;
    }
  }
}

function pickTable(mod) {
  if (!mod) return null;
  const candidates = [
    mod.default,
    mod.SCREEN_STRINGS,
    mod.OVERVIEW_STRINGS,
    mod.STRINGS,
    mod.strings,
  ];
  for (const candidate of candidates) {
    if (candidate && typeof candidate === 'object' && (candidate.zh || candidate.en)) {
      return candidate;
    }
  }
  if (mod.default && typeof mod.default === 'object') {
    const nested = mod.default.default || mod.default.SCREEN_STRINGS || mod.default.OVERVIEW_STRINGS;
    if (nested && (nested.zh || nested.en)) return nested;
  }
  return null;
}

/**
 * Load and merge the screen owners' string tables. A missing file (the normal
 * state while the screens are still being written) is not an error: the base
 * table is complete for the shell, and unknown keys render as Chinese source.
 */
export async function loadExternalStrings() {
  if (externalLoaded) return;
  externalLoaded = true;
  await Promise.all(
    EXTENSION_MODULES.map(async (specifier) => {
      try {
        const mod = await import(specifier);
        const table = pickTable(mod);
        if (table) mergeStrings(table);
      } catch (_) {
        /* not shipped yet — the shell strings are enough */
      }
    }),
  );
}
