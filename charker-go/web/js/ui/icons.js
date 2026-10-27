// ============================================================================
// Charker — inline icon registry
//
// Lucide-style paths (ISC) + hand-drawn glyphs where Lucide has no equivalent
// (solid bolt, USB-C connector, HomeKit house). SF Symbols are not
// redistributable; components.js maps every Swift symbol used by the UI.
//
// Usage:
//   icon('bolt')                 -> inline SVG string, sized 1em (CSS)
//   icon('bolt', 12)             -> inline SVG string, 12 px
//   icon('bolt', {size:12})      -> same, with extra attrs
//   iconEl('bolt', {size:12})    -> SVGElement
//   icons.get / icons.el / icons.names
//
// Icons inherit currentColor; solid glyphs use fill, line glyphs stroke 1.5
// (Lucide's default 2 is too heavy at 10-12 px).
// ============================================================================

const L = (body, extra = '') =>
  `<svg class="ck-icon" width="1em" height="1em" viewBox="0 0 24 24" fill="none" ` +
  `stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" ` +
  `aria-hidden="true" focusable="false"${extra}>${body}</svg>`;

const S = (body, vb = '0 0 16 16') =>
  `<svg class="ck-icon" width="1em" height="1em" viewBox="${vb}" fill="currentColor" ` +
  `aria-hidden="true" focusable="false">${body}</svg>`;

const ICONS = {
  // ---- brand / power ------------------------------------------------------
  bolt: S('<path d="M9.6 1 3 9.4h3.3L6 15l6.7-8.6h-3.2L9.6 1Z"/>'),
  'bolt-slash': L(
    '<path d="M12.5 2.5 6 10.4h3.3L9 15.5l4.4-5.6"/><path d="m3 3 18 18"/>',
  ),
  'bolt-badge-clock': L(
    '<path d="M11 2.5 4 11h4l-.6 5.5L14 8h-4"/><circle cx="18" cy="17" r="4"/><path d="M18 15.4V17l1.1.8"/>',
  ),
  power: L('<path d="M12 2v10"/><path d="M18.4 6.6a9 9 0 1 1-12.8 0"/>'),
  plug: L(
    '<path d="M12 22v-5"/><path d="M9 8V2"/><path d="M15 8V2"/>' +
      '<path d="M18 8v5a4 4 0 0 1-4 4h-4a4 4 0 0 1-4-4V8Z"/>',
  ),
  usbc: S(
    '<rect x="1" y="1" width="18" height="7.2" rx="3.6" fill="none" stroke="currentColor" stroke-width="1.4"/>' +
      '<rect x="4.8" y="3.4" width="10.4" height="2.4" rx="1.2"/>',
    '0 0 20 9.2',
  ),

  // ---- sidebar / navigation ----------------------------------------------
  'bar-chart': L(
    '<path d="M3 3v18h18"/><path d="M18 17V9"/><path d="M13 17V5"/><path d="M8 17v-3"/>',
  ),
  radio: L(
    '<path d="M4.9 19.1C1 15.2 1 8.8 4.9 4.9"/><path d="M7.8 16.2c-2.3-2.3-2.3-6.1 0-8.5"/>' +
      '<circle cx="12" cy="12" r="2"/><path d="M16.2 7.8c2.3 2.3 2.3 6.1 0 8.5"/>' +
      '<path d="M19.1 4.9C23 8.8 23 15.2 19.1 19.1"/>',
  ),
  'panel-top': L(
    '<rect width="18" height="18" x="3" y="3" rx="2"/><path d="M3 9h18"/>',
  ),
  // The taskbar section (Windows' twin of the menu bar).
  'panel-bottom': L(
    '<rect width="18" height="18" x="3" y="3" rx="2"/><path d="M3 15h18"/><path d="M15 18h2"/>',
  ),
  wrench: L(
    '<path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/>',
  ),
  info: L(
    '<circle cx="12" cy="12" r="10"/><path d="M12 16v-4"/><path d="M12 8h.01"/>',
  ),
  homekit: L(
    '<path d="m3 10 9-7 9 7v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z"/>' +
      '<path d="M9 22V12h6v10"/>',
  ),

  // ---- chevrons / arrows --------------------------------------------------
  'chevron-right': L('<path d="m9 18 6-6-6-6"/>'),
  'chevron-left': L('<path d="m15 18-6-6 6-6"/>'),
  'chevron-down': L('<path d="m6 9 6 6 6-6"/>'),
  'chevron-up': L('<path d="m18 15-6-6-6 6"/>'),
  'chevron-up-down': L('<path d="m7 15 5 5 5-5"/><path d="m7 9 5-5 5 5"/>'),
  'arrow-up': L('<path d="m5 12 7-7 7 7"/><path d="M12 19V5"/>'),
  'arrow-down': L('<path d="M12 5v14"/><path d="m19 12-7 7-7-7"/>'),
  'arrow-left': L('<path d="M19 12H5"/><path d="m12 19-7-7 7-7"/>'),
  'arrow-right': L('<path d="M5 12h14"/><path d="m12 5 7 7-7 7"/>'),
  'arrow-up-right': L('<path d="M7 7h10v10"/><path d="M7 17 17 7"/>'),
  'arrow-left-right': L('<path d="M8 3 4 7l4 4"/><path d="M4 7h16"/><path d="m16 21 4-4-4-4"/><path d="M20 17H4"/>'),
  'arrow-up-down': L('<path d="m21 16-4 4-4-4"/><path d="M17 20V4"/><path d="m3 8 4-4 4 4"/><path d="M7 4v16"/>'),

  // ---- actions ------------------------------------------------------------
  plus: L('<path d="M5 12h14"/><path d="M12 5v14"/>'),
  'plus-circle': L('<circle cx="12" cy="12" r="10"/><path d="M8 12h8"/><path d="M12 8v8"/>'),
  check: L('<path d="M20 6 9 17l-5-5"/>'),
  'check-circle': L('<path d="M21.8 10A10 10 0 1 1 17 3.34"/><path d="m9 11 3 3L22 4"/>'),
  x: L('<path d="M18 6 6 18"/><path d="m6 6 12 12"/>'),
  'x-circle': L('<circle cx="12" cy="12" r="10"/><path d="m15 9-6 6"/><path d="m9 9 6 6"/>'),
  trash: L(
    '<path d="M3 6h18"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/>' +
      '<path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>' +
      '<line x1="10" x2="10" y1="11" y2="17"/><line x1="14" x2="14" y1="11" y2="17"/>',
  ),
  timer: L(
    '<line x1="10" x2="14" y1="2" y2="2"/><line x1="12" x2="15" y1="14" y2="11"/>' +
      '<circle cx="12" cy="14" r="8"/>',
  ),
  'more-horizontal': L(
    '<circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/><circle cx="5" cy="12" r="1"/>',
  ),
  copy: L(
    '<rect width="14" height="14" x="8" y="8" rx="2" ry="2"/>' +
      '<path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>',
  ),
  share: L(
    '<path d="M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8"/>' +
      '<polyline points="16 6 12 2 8 6"/><line x1="12" x2="12" y1="2" y2="15"/>',
  ),
  upload: L(
    '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>' +
      '<polyline points="17 8 12 3 7 8"/><line x1="12" x2="12" y1="3" y2="15"/>',
  ),
  download: L(
    '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>' +
      '<polyline points="7 10 12 15 17 10"/><line x1="12" x2="12" y1="15" y2="3"/>',
  ),
  refresh: L('<path d="M21 12a9 9 0 1 1-9-9c2.5 0 4.9 1 6.7 2.7L21 8"/><path d="M21 3v5h-5"/>'),
  'rotate-cw': L('<path d="M21 12a9 9 0 1 1-9-9c2.5 0 4.9 1 6.7 2.7L21 8"/><path d="M21 3v5h-5"/>'),
  'rotate-ccw': L('<path d="M3 12a9 9 0 1 0 9-9c-2.5 0-4.9 1-6.7 2.7L3 8"/><path d="M3 3v5h5"/>'),
  'external-link': L(
    '<path d="M15 3h6v6"/><path d="M10 14 21 3"/>' +
      '<path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/>',
  ),
  play: S('<path d="M6 3.2 20 12 6 20.8 6 3.2Z"/>'),
  'circle-stop': L('<circle cx="12" cy="12" r="10"/><rect width="6" height="6" x="9" y="9" rx="1"/>'),
  scan: L(
    '<path d="M3 7V5a2 2 0 0 1 2-2h2"/><path d="M17 3h2a2 2 0 0 1 2 2v2"/>' +
      '<path d="M21 17v2a2 2 0 0 1-2 2h-2"/><path d="M7 21H5a2 2 0 0 1-2-2v-2"/>' +
      '<line x1="7" x2="17" y1="12" y2="12"/>',
  ),
  bookmark: L('<path d="m19 21-7-4-7 4V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2v16z"/>'),
  'move-3d': L(
    '<path d="M12 2v20"/><path d="m8 6 4-4 4 4"/><path d="m8 18 4 4 4-4"/>' +
      '<path d="M2 12h20"/><path d="m6 8-4 4 4 4"/><path d="m18 8 4 4-4 4"/>',
  ),
  'rotate-3d': L(
    '<path d="M12 3a9 9 0 1 0 9 9"/><path d="m21 3-4 4"/><path d="M12 8v4l3 2"/>',
  ),

  // ---- status / notices ---------------------------------------------------
  'alert-triangle': L(
    '<path d="m21.7 18-8-14a2 2 0 0 0-3.5 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.7-3Z"/>' +
      '<path d="M12 9v4"/><path d="M12 17h.01"/>',
  ),
  'alert-circle': L('<circle cx="12" cy="12" r="10"/><path d="M12 8v4"/><path d="M12 16h.01"/>'),
  question: L(
    '<circle cx="12" cy="12" r="10"/>' +
      '<path d="M9.1 9a3 3 0 0 1 5.8 1c0 2-3 3-3 3"/>' +
      '<path d="M12 17h.01"/>',
  ),
  'info-fill': S(
    '<path d="M8 0a8 8 0 1 0 0 16A8 8 0 0 0 8 0Zm.9 6.1H8.8V9h1.9V6.1H8.9Zm0 6.6V9.6h1.9V12H8.9Z"/>',
  ),
  activity: L('<polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/>'),
  wifi: L(
    '<path d="M12 20h.01"/><path d="M2 8.8a15 15 0 0 1 20 0"/>' +
      '<path d="M5 12.9a10 10 0 0 1 14 0"/><path d="M8.5 16.4a5 5 0 0 1 7 0"/>',
  ),
  battery: L(
    '<rect width="16" height="10" x="2" y="7" rx="2"/><line x1="22" x2="22" y1="11" y2="13"/>',
  ),
  'battery-charging': L(
    '<path d="M15 7h1a2 2 0 0 1 2 2v6a2 2 0 0 1-2 2h-2"/>' +
      '<path d="M6 7H4a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h1"/>' +
      '<path d="m11 7-3 5h4l-3 5"/><line x1="22" x2="22" y1="11" y2="13"/>',
  ),
  gauge: L('<path d="m12 14 4-4"/><path d="M3.3 19a10 10 0 1 1 17.3 0"/>'),
  thermometer: L('<path d="M14 4v10.5a4 4 0 1 1-4 0V4a2 2 0 0 1 4 0Z"/>'),
  lock: L(
    '<rect width="18" height="11" x="3" y="11" rx="2" ry="2"/>' +
      '<path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
  ),
  clock: L('<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>'),
  banknote: L(
    '<rect width="20" height="12" x="2" y="6" rx="2"/><circle cx="12" cy="12" r="2"/>' +
      '<path d="M6 12h.01M18 12h.01"/>',
  ),
  archive: L(
    '<rect width="20" height="5" x="2" y="3" rx="1"/>' +
      '<path d="M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8"/><path d="M10 12h4"/>',
  ),
  'line-chart': L('<path d="M3 3v18h18"/><path d="m19 9-5 5-4-4-3 3"/>'),
  image: L(
    '<rect width="18" height="18" x="3" y="3" rx="2" ry="2"/><circle cx="9" cy="9" r="2"/>' +
      '<path d="m21 15-3.1-3.1a2 2 0 0 0-2.8 0L6 21"/>',
  ),

  // ---- display / theme ----------------------------------------------------
  sun: L(
    '<circle cx="12" cy="12" r="4"/>' +
      '<path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
  ),
  moon: L('<path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"/>'),
  monitor: L(
    '<rect width="20" height="14" x="2" y="3" rx="2"/>' +
      '<line x1="8" x2="16" y1="21" y2="21"/><line x1="12" x2="12" y1="17" y2="21"/>',
  ),

  // ---- menu-bar editor palette -------------------------------------------
  hash: L(
    '<line x1="4" x2="20" y1="9" y2="9"/><line x1="4" x2="20" y1="15" y2="15"/>' +
      '<line x1="10" x2="8" y1="3" y2="21"/><line x1="16" x2="14" y1="3" y2="21"/>',
  ),
  tag: L(
    '<path d="M12.6 2.6A2 2 0 0 0 11.2 2H4a2 2 0 0 0-2 2v7.2a2 2 0 0 0 .6 1.4l8.7 8.7a2.4 2.4 0 0 0 3.4 0l6.6-6.6a2.4 2.4 0 0 0 0-3.4z"/>' +
      '<circle cx="7.5" cy="7.5" r=".6" fill="currentColor"/>',
  ),
  type: L(
    '<polyline points="4 7 4 4 20 4 20 7"/>' +
      '<line x1="9" x2="15" y1="20" y2="20"/><line x1="12" x2="12" y1="4" y2="20"/>',
  ),
  'grip-horizontal': L(
    '<circle cx="12" cy="9" r="1"/><circle cx="19" cy="9" r="1"/><circle cx="5" cy="9" r="1"/>' +
      '<circle cx="12" cy="15" r="1"/><circle cx="19" cy="15" r="1"/><circle cx="5" cy="15" r="1"/>',
  ),
  'grid-2x2': L(
    '<rect width="18" height="18" x="3" y="3" rx="2"/><path d="M3 12h18"/><path d="M12 3v18"/>',
  ),
  'share-2': L(
    '<circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/>' +
      '<line x1="8.6" x2="15.4" y1="13.5" y2="17.5"/><line x1="15.4" x2="8.6" y1="6.5" y2="10.5"/>',
  ),
  'zoom-in': L(
    '<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>' +
      '<path d="M11 8v6"/><path d="M8 11h6"/>',
  ),
  'zoom-out': L(
    '<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/><path d="M8 11h6"/>',
  ),
  'user-key': L(
    '<circle cx="10" cy="8" r="4"/><path d="M2 21a8 8 0 0 1 10.6-7.6"/>' +
      '<path d="m17 11 4 4"/><path d="m20 14 1-1"/>',
  ),
  'powerplug-fill': S(
    '<path d="M6.2 1.4 7.6 0l2.3 2.3-1.4 1.4zM13.4 8.6l1.4-1.4 2.3 2.3-1.4 1.4z"/>' +
      '<path d="M5.7 5.7 8 3.4l6.6 6.6-2.3 2.3z"/><path d="m2 14 2-2 6 6-2 2z"/>',
  ),
  'cable': L(
    '<path d="M17 21v-2a1 1 0 0 0-1-1H4a1 1 0 0 0-1 1v2"/>' +
      '<path d="M9 3h6v4a3 3 0 0 1-3 3 3 3 0 0 1-3-3z"/><path d="M12 10v3a4 4 0 0 0 4 4h3"/>',
  ),
};

// Friendly aliases used by different screens/spec tables.
const ALIASES = {
  'chart-bar': 'bar-chart',
  'bar-chart-3': 'bar-chart',
  'antenna': 'radio',
  'panel': 'panel-top',
  menubar: 'panel-top',
  chevron: 'chevron-right',
  'ellipsis': 'more-horizontal',
  'checkmark': 'check',
  'checkmark-circle': 'check-circle',
  'xmark': 'x',
  'close': 'x',
  'add': 'plus',
  'plus-circle-fill': 'plus-circle',
  'doc-copy': 'copy',
  'refresh-cw': 'refresh',
  'arrow-clockwise': 'rotate-cw',
  'arrow-counterclockwise': 'rotate-ccw',
  'alert-warning': 'alert-triangle',
  'warning': 'alert-triangle',
  'error': 'alert-circle',
  'bolt-slash-fill': 'bolt-slash',
  'dot': 'info',
  'home': 'homekit',
  'house': 'homekit',
  'sunny': 'sun',
  'display': 'monitor',
  'spinner': 'refresh',
  'ellipsis-vertical': 'more-horizontal',
  'powerplug': 'plug',
  'usb-c': 'usbc',
  'powercord': 'cable',
  'viewfinder': 'scan',
  'bookmark-fill': 'bookmark',
  'play-fill': 'play',
  'waveform': 'activity',
  'cash': 'banknote',
  'gauge-with-dots': 'gauge',
  'trash-2': 'trash',
  'person-badge-key': 'user-key',
  'questionmark-circle': 'question',
  'grip': 'grip-horizontal',
  'grid': 'grid-2x2',
  'info-circle': 'info',
  'info-circle-fill': 'info-fill',
  'alert-circle-fill': 'alert-circle',
  'alert-triangle-fill': 'alert-triangle',
  'timer-fill': 'timer',
  'rotate': 'rotate-cw',
  'download-cloud': 'download',
  'upload-cloud': 'upload',
  'scale': 'arrow-up-down',
};

/** Adds glyphs a page needs (name -> SVG markup built like the ones above). */
export function registerIcons(extra) {
  Object.assign(ICONS, extra);
}

const NAMES = Array.from(
  new Set([...Object.keys(ICONS), ...Object.keys(ALIASES)]),
).sort();

function resolve(name) {
  if (!name) return ICONS.question;
  const key = String(name).trim().toLowerCase().replace(/^i-/, '').replace(/_/g, '-');
  if (ICONS[key]) return ICONS[key];
  if (ALIASES[key] && ICONS[ALIASES[key]]) return ICONS[ALIASES[key]];
  return ICONS.question;
}

function sizeAttrs(opts) {
  let size = 0;
  if (typeof opts === 'number') size = opts;
  else if (opts && typeof opts === 'object' && opts.size) size = Number(opts.size) || 0;
  return size > 0 ? ` width="${size}" height="${size}" style="width:${size}px;height:${size}px"` : '';
}

/**
 * Inline SVG markup. The caller may inject it into a trusted container
 * (`el.innerHTML = icon(...)`); never pass user data as `name`.
 * @param {string} name
 * @param {number|{size?:number}} [opts]
 * @returns {string}
 */
export function icon(name, opts) {
  const markup = resolve(name);
  const extra = sizeAttrs(opts);
  if (!extra) return markup;
  // the registry markup already ends with `>`; splice the size in on the tag
  return markup.replace(/^<svg /, `<svg ${extra.trim()} `);
}

/** @param {string} name @param {number|{size?:number,class?:string}} [opts] */
export function iconEl(name, opts) {
  const size = typeof opts === 'number' ? opts : opts && opts.size;
  const cls = opts && typeof opts === 'object' && opts.class ? ` ${opts.class}` : '';
  const span = document.createElement('span');
  span.className = `ck-icon-box${cls}`;
  span.style.display = 'inline-flex';
  span.style.width = size ? `${size}px` : '1em';
  span.style.height = size ? `${size}px` : '1em';
  span.setAttribute('aria-hidden', 'true');
  span.innerHTML = icon(name, opts);
  return span.firstElementChild || span;
}

/** Object form handed to screens as `ctx.icons`. */
export const icons = {
  get: icon,
  el: iconEl,
  names: NAMES,
  has: (name) => {
    const key = String(name || '').trim().toLowerCase().replace(/^i-/, '').replace(/_/g, '-');
    return Boolean(ICONS[key] || (ALIASES[key] && ICONS[ALIASES[key]]));
  },
};

export default icons;
