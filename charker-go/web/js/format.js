// ============================================================================
// Charker — shared formatters (owner: web-shell)
//
// Every number the UI prints goes through these so the zh/en behaviour matches
// the Swift `formatted(…)` calls (spec-ui §6.2 rule 5). Screens receive this as
// `ctx.fmt`; they may still roll their own local formatting for chart axes.
// ============================================================================

import { getLocale } from './i18n.js';

function tag() {
  return getLocale() === 'en' ? 'en-US' : 'zh-CN';
}

function finite(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

/** Grouped decimal number. */
export function number(value, decimals = 0) {
  const n = finite(value);
  if (n == null) return '—';
  try {
    return new Intl.NumberFormat(tag(), {
      minimumFractionDigits: decimals,
      maximumFractionDigits: decimals,
    }).format(n);
  } catch (_) {
    return n.toFixed(decimals);
  }
}

/** Watts, always the fixed number of decimals the layout reserves. */
export function watts(value, decimals = 1) {
  const n = finite(value);
  if (n == null) return '—';
  return n.toFixed(decimals);
}

/**
 * Energy value + unit (spec-ui §3.13): <10 Wh → 2 dp, <1000 Wh → 1 dp,
 * ≥1000 Wh → kWh (2 dp, 1 dp at ≥10 kWh).
 * @returns {{value: string, unit: 'Wh'|'kWh'}}
 */
export function energy(value) {
  const n = finite(value);
  if (n == null) return { value: '—', unit: 'Wh' };
  const abs = Math.abs(n);
  if (abs >= 1000) {
    const k = n / 1000;
    return { value: abs >= 10 ? k.toFixed(1) : k.toFixed(2), unit: 'kWh' };
  }
  return { value: abs >= 10 ? n.toFixed(1) : n.toFixed(2), unit: 'Wh' };
}

/** `HH:MM:SS` clock (stats-row connected-time style, no leading zero on hours). */
export function clock(ms) {
  const total = Math.max(0, Math.round(Number(ms) || 0) / 1000);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = Math.floor(total % 60);
  return `${hours}:${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`;
}

/** Local wall-clock time `HH:MM:SS` for an epoch timestamp. */
export function timeOfDay(timestamp, withSeconds = false) {
  const n = finite(timestamp);
  if (n == null || n <= 0) return '—';
  try {
    return new Intl.DateTimeFormat(tag(), {
      hour: '2-digit',
      minute: '2-digit',
      ...(withSeconds ? { second: '2-digit' } : {}),
      hour12: false,
    }).format(new Date(n));
  } catch (_) {
    return new Date(n).toLocaleTimeString();
  }
}

/** `HH:MM` short time. */
export function time(timestamp) {
  return timeOfDay(timestamp, false);
}

/** Calendar date, long form. */
export function date(timestamp, style = 'medium') {
  const n = finite(timestamp);
  if (n == null || n <= 0) return '—';
  const options =
    style === 'short'
      ? { month: 'numeric', day: 'numeric' }
      : { year: 'numeric', month: 'long', day: 'numeric', weekday: 'short' };
  try {
    return new Intl.DateTimeFormat(tag(), options).format(new Date(n));
  } catch (_) {
    return new Date(n).toLocaleDateString();
  }
}

/** Relative past time (`2小时前` / `2 hours ago`) from an age in milliseconds. */
export function relative(msAgo) {
  const n = finite(msAgo);
  if (n == null) return '—';
  const seconds = Math.round(n / 1000);
  const abs = Math.abs(seconds);
  let unit = 'second';
  let divisor = 1;
  if (abs >= 86400 * 30) {
    unit = 'month';
    divisor = 86400 * 30;
  } else if (abs >= 86400 * 7) {
    unit = 'week';
    divisor = 86400 * 7;
  } else if (abs >= 86400) {
    unit = 'day';
    divisor = 86400;
  } else if (abs >= 3600) {
    unit = 'hour';
    divisor = 3600;
  } else if (abs >= 60) {
    unit = 'minute';
    divisor = 60;
  }
  try {
    return new Intl.RelativeTimeFormat(tag(), { numeric: 'auto' }).format(
      Math.round(seconds / divisor),
      unit,
    );
  } catch (_) {
    return `${Math.round(seconds / divisor)} ${unit}`;
  }
}

/** `42%` with the locale's percent sign. */
export function percent(value, decimals = 0) {
  const n = finite(value);
  if (n == null) return '—';
  try {
    return new Intl.NumberFormat(tag(), {
      style: 'percent',
      minimumFractionDigits: decimals,
      maximumFractionDigits: decimals,
    }).format(n / 100);
  } catch (_) {
    return `${n.toFixed(decimals)}%`;
  }
}

/** Compact duration: 42s / 5m / 3h12m (settings/summary rows). */
export function compactDuration(ms) {
  const seconds = Math.round(Math.max(0, Number(ms) || 0) / 1000);
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  return `${Math.floor(seconds / 3600)}h${String(Math.floor((seconds % 3600) / 60)).padStart(2, '0')}m`;
}

export const fmt = {
  number,
  watts,
  energy,
  clock,
  time,
  timeOfDay,
  date,
  relative,
  percent,
  compactDuration,
};

export default fmt;
