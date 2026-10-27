// Shared views from the macOS Design/ folder: SlateCard, PowerRail,
// TotalReadout, Chip, StateDot, ConnectionLadder, CopyIconButton,
// CharkerSegmentedControl, CharkerActionButtonStyle, Toggle, popup menus and
// confirmation dialogs. Pages compose these; page-specific views stay in the
// page module.

import { html, useEffect, useLayoutEffect, useRef, useState } from '../lib.js';
import { t, tf } from '../core/l10n.js';
import { isBusy, isLive, negotiationProgress, phaseDetail, phaseShortLabel } from '../core/model.js';
import { icon } from './icons.js';

const cx = (...parts) => parts.filter(Boolean).join(' ');
export { cx };

// SF Symbol names used by the Swift views -> the inline icon registry.
const SF = {
  'bolt.fill': 'bolt',
  'bolt.slash': 'bolt-slash',
  'bolt.slash.fill': 'bolt-slash-fill',
  'chart.bar.xaxis': 'bar-chart',
  'chart.xyaxis.line': 'line-chart',
  'antenna.radiowaves.left.and.right': 'radio',
  'dot.radiowaves.left.and.right': 'radio',
  'menubar.rectangle': 'panel-top',
  'wrench.and.screwdriver': 'wrench',
  'info.circle': 'info',
  'info.circle.fill': 'info-fill',
  'chevron.right': 'chevron-right',
  'chevron.left': 'chevron-left',
  'chevron.down': 'chevron-down',
  'chevron.up.chevron.down': 'chevron-up-down',
  'xmark': 'x',
  'xmark.circle': 'x-circle',
  'checkmark': 'check',
  'checkmark.circle.fill': 'check-circle',
  'doc.on.doc': 'copy',
  'arrow.up.and.down': 'arrow-up-down',
  'arrow.left.and.right': 'arrow-left-right',
  'arrow.clockwise': 'rotate-cw',
  'arrow.counterclockwise': 'rotate-ccw',
  'arrow.triangle.2.circlepath': 'refresh',
  'arrow.left': 'arrow-left',
  'arrow.right': 'arrow-right',
  'timer': 'timer',
  'ellipsis': 'more-horizontal',
  'trash': 'trash',
  'plus': 'plus',
  'plus.circle.fill': 'plus-circle',
  'play.fill': 'play',
  'stop.circle': 'circle-stop',
  'photo': 'image',
  'move.3d': 'move-3d',
  'view.3d': 'rotate-3d',
  'bookmark.fill': 'bookmark',
  'square.and.arrow.up': 'share',
  'exclamationmark.triangle.fill': 'alert-triangle',
  'exclamationmark.circle.fill': 'alert-circle',
  'questionmark.circle': 'question',
  'lock.fill': 'lock',
  'wifi': 'wifi',
  'battery.75percent': 'battery',
  'banknote.fill': 'banknote',
  'archivebox': 'archive',
  'gauge.with.dots.needle.0percent': 'gauge',
  'plus.magnifyingglass': 'zoom-in',
  'minus.magnifyingglass': 'zoom-out',
  'person.badge.key': 'user-key',
};

/** Image(systemName:) — `name` is an SF Symbol name or a registry key. */
export function Icon({ name, size, class: className, style }) {
  const markup = icon(SF[name] || name, size);
  return html`<span
    class=${cx('icon-box', className)}
    style=${{ display: 'inline-flex', lineHeight: 0, ...style }}
    aria-hidden="true"
    dangerouslySetInnerHTML=${{ __html: markup }}
  ></span>`;
}

export function SlateCard({ class: className, padding, hovering, style, children, ...rest }) {
  const pad = padding == null ? undefined : `${padding}px`;
  return html`<div
    class=${cx('slate', hovering && 'is-hovering', className)}
    style=${{ padding: pad, ...style }}
    ...${rest}
  >
    ${children}
  </div>`;
}

export function Chip({ text, tone = 'neutral', title }) {
  return html`<span class=${cx('chip', tone !== 'neutral' && `is-${tone}`)} title=${title}
    >${text}</span
  >`;
}

/** StateDot: the session dot; busy phases breathe. */
export function StateDot({ session, stale = false, diameter = 7, glowsWhenLive = true }) {
  let tone = '';
  if (stale) tone = 'is-warn';
  else if (session.phase === 'polling') tone = 'is-ok';
  else if (session.phase === 'failed') tone = 'is-danger';
  else if (session.phase === 'reconnecting') tone = 'is-warn';
  return html`<span
    class=${cx('state-dot', tone, glowsWhenLive && isLive(session) && 'glows', isBusy(session) && 'is-busy')}
    style=${{ width: `${diameter}px`, height: `${diameter}px` }}
    aria-label=${phaseShortLabel(session)}
  ></span>`;
}

/**
 * PowerRail: every port on the same 0-ceiling scale; `segments` splits the
 * fill into per-port bands of one hue at stepped opacity.
 */
export function PowerRail({ watts, ceiling = 160, isDelivering, segments, flowing, dimmed }) {
  const fraction = Math.max(0, Math.min(1, (watts || 0) / ceiling));
  const intensity = isDelivering ? 0.45 + 0.55 * fraction ** 0.6 : 0;
  const opacity = intensity * (dimmed ? 0.45 : 1);
  const hasSegments = segments && segments.some((v) => v > 0.1);
  const minWidth = isDelivering ? 6 : 0;
  return html`<div class="rail" role="img" aria-label=${t('功率')}>
    ${hasSegments
      ? html`<div class="rail__segments" style=${{ opacity }}>
          ${segments.map((v, i) =>
            v > 0.1
              ? html`<div
                  class="rail__segment"
                  style=${{
                    width: `${(v / ceiling) * 100}%`,
                    minWidth: '6px',
                    opacity: [1, 0.72, 0.5][i % 3],
                  }}
                ></div>`
              : null,
          )}
        </div>`
      : html`<div
          class="rail__fill"
          style=${{ width: `max(${minWidth}px, ${fraction * 100}%)`, opacity }}
        ></div>`}
    ${flowing && isDelivering && !dimmed
      ? html`<div
          class="rail__shimmer"
          style=${{ width: `max(6px, ${fraction * 100}%)`, opacity }}
        ></div>`
      : null}
  </div>`;
}

/** TotalReadout: the face of the app. */
export function TotalReadout({ watts, isStale, size = 56 }) {
  return html`<div
    class="total-readout"
    style=${{
      display: 'flex',
      alignItems: 'baseline',
      gap: '8px',
      opacity: isStale ? 0.45 : 1,
      transition: 'opacity 0.2s ease-out',
    }}
  >
    ${watts != null
      ? html`<span
            class="num"
            style=${{
              fontSize: `${size}px`,
              fontWeight: 600,
              letterSpacing: '-0.6px',
              lineHeight: 1,
              backgroundImage:
                'linear-gradient(to bottom, var(--c-text-primary), color-mix(in srgb, var(--c-text-primary) 76%, transparent))',
              WebkitBackgroundClip: 'text',
              backgroundClip: 'text',
              color: 'transparent',
            }}
            >${tf('%.1f', watts)}</span
          ><span
            style=${{
              fontSize: `${size * 0.39}px`,
              fontWeight: 500,
              color: 'var(--c-text-secondary)',
            }}
            >W</span
          >`
      : html`<span
          style=${{
            fontSize: `${size * 0.33}px`,
            fontWeight: 500,
            color: 'var(--c-text-tertiary)',
            position: 'relative',
            top: `${-size * 0.06}px`,
          }}
          >${t('暂无数据')}</span
        >`}
  </div>`;
}

/** ConnectionLadder: the handshake as a determinate ladder. */
export function ConnectionLadder({ session, compact = false }) {
  const progress = negotiationProgress(session);
  const [bar, setBar] = useState({ visible: progress != null && progress < 1, value: progress || 0 });
  const generation = useRef(0);
  useEffect(() => {
    generation.current += 1;
    if (progress != null && progress < 1) {
      setBar({ visible: true, value: progress });
    } else if (progress != null) {
      setBar((b) => (b.visible ? { visible: true, value: 1 } : b));
      const g = generation.current;
      const timer = setTimeout(() => {
        if (g === generation.current) setBar((b) => ({ ...b, visible: false }));
      }, 450);
      return () => clearTimeout(timer);
    } else {
      setBar((b) => ({ ...b, visible: false }));
    }
    return undefined;
  }, [progress]);
  return html`<div style=${{ display: 'flex', alignItems: 'flex-start', gap: '8px' }}>
    <span style=${{ paddingTop: '4px', display: 'inline-flex' }}><${StateDot} session=${session} /></span>
    <div
      style=${{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: '8px' }}
    >
      <span class="t-label c-secondary">${phaseShortLabel(session)}</span>
      ${!compact
        ? html`<span class="t-caption c-tertiary" style=${{ lineHeight: 1.5 }}
            >${phaseDetail(session)}</span
          >`
        : null}
      ${bar.visible
        ? html`<div class="rail" style=${{ height: '2px' }}>
            <div
              class="rail__fill"
              style=${{
                width: `${bar.value * 100}%`,
                background: 'var(--c-accent)',
              }}
            ></div>
          </div>`
        : null}
    </div>
  </div>`;
}

/** CopyIconButton: puts `value` on the clipboard and ticks for a moment. */
export function CopyIconButton({ value, help }) {
  const [copied, setCopied] = useState(false);
  const timer = useRef(0);
  const copy = () => {
    navigator.clipboard?.writeText(value).catch(() => {});
    setCopied(true);
    clearTimeout(timer.current);
    timer.current = setTimeout(() => setCopied(false), 1600);
  };
  return html`<button class="icon-btn" title=${t(help)} aria-label=${t(help)} onClick=${copy}>
    <${Icon} name=${copied ? 'checkmark' : 'doc.on.doc'} />
  </button>`;
}

/** CharkerActionButtonStyle: primary | secondary | quiet | destructive. */
export function ActionButton({
  emphasis = 'secondary',
  icon: iconName,
  title,
  help,
  disabled,
  onClick,
  class: className,
  children,
  ...rest
}) {
  return html`<button
    class=${cx('btn', emphasis !== 'secondary' && `is-${emphasis}`, className)}
    title=${help}
    disabled=${disabled}
    onClick=${onClick}
    ...${rest}
  >
    ${iconName ? html`<${Icon} name=${iconName} />` : null}${title != null ? html`<span>${title}</span>` : null}${children}
  </button>`;
}

/** CharkerSegmentedControl: one sliding capsule marks the choice. */
export function Segmented({ label, value, segments, onChange, class: className, style }) {
  const root = useRef(null);
  const [pill, setPill] = useState(null);
  useLayoutEffect(() => {
    const el = root.current?.querySelector('.segmented__item.is-selected');
    const next = el ? { left: el.offsetLeft, width: el.offsetWidth } : null;
    setPill((old) => (old && next && old.left === next.left && old.width === next.width ? old : next));
  });
  return html`<div
    ref=${root}
    class=${cx('segmented', className)}
    style=${style}
    role="radiogroup"
    aria-label=${label}
    onKeyDown=${(e) => {
      const i = segments.findIndex((s) => s.value === value);
      if (e.key === 'ArrowLeft' && i > 0) onChange(segments[i - 1].value);
      if (e.key === 'ArrowRight' && i < segments.length - 1) onChange(segments[i + 1].value);
    }}
  >
    ${pill
      ? html`<span class="segmented__pill" style=${{ left: `${pill.left}px`, width: `${pill.width}px` }}></span>`
      : null}
    ${segments.map(
      (s) => html`<button
        key=${String(s.value)}
        class=${cx('segmented__item', s.value === value && 'is-selected')}
        role="radio"
        aria-checked=${s.value === value}
        onClick=${() => s.value !== value && onChange(s.value)}
      >
        ${s.title}
      </button>`,
    )}
  </div>`;
}

/** Toggle(isOn:).toggleStyle(.switch), tinted with the accent. */
export function Toggle({ on, onChange, disabled, small, label, help }) {
  return html`<button
    class=${cx('toggle', on && 'is-on', small && 'is-small')}
    role="switch"
    aria-checked=${!!on}
    aria-label=${label}
    title=${help}
    disabled=${disabled}
    onClick=${() => onChange(!on)}
  ></button>`;
}

// ---- Popup menus ---------------------------------------------------------------

let closeOpenMenu = null;

/**
 * Opens a menu under `anchor`. Items: {title, checked, disabled, destructive,
 * action} | {separator: true} | {header: '…'}.
 */
export function openMenu(anchor, items, { align = 'start' } = {}) {
  closeOpenMenu?.();
  const host = document.createElement('div');
  document.body.appendChild(host);
  const close = () => {
    document.removeEventListener('pointerdown', outside, true);
    document.removeEventListener('keydown', key, true);
    window.removeEventListener('blur', close);
    host.remove();
    if (closeOpenMenu === close) closeOpenMenu = null;
  };
  const outside = (e) => {
    if (!host.contains(e.target)) close();
  };
  const key = (e) => {
    if (e.key === 'Escape') {
      e.preventDefault();
      close();
    }
  };
  closeOpenMenu = close;
  const menu = document.createElement('div');
  menu.className = 'menu';
  menu.setAttribute('role', 'menu');
  for (const item of items) {
    if (!item) continue;
    if (item.separator) {
      menu.appendChild(Object.assign(document.createElement('div'), { className: 'menu__separator' }));
      continue;
    }
    if (item.header) {
      menu.appendChild(
        Object.assign(document.createElement('div'), { className: 'menu__header', textContent: item.header }),
      );
      continue;
    }
    const b = document.createElement('button');
    b.className = cx('menu__item', item.destructive && 'is-destructive');
    b.setAttribute('role', item.checked != null ? 'menuitemradio' : 'menuitem');
    if (item.checked != null) b.setAttribute('aria-checked', String(!!item.checked));
    b.disabled = !!item.disabled;
    const check = document.createElement('span');
    check.className = 'menu__check';
    if (item.checked) check.innerHTML = icon('check');
    b.appendChild(check);
    b.appendChild(document.createTextNode(item.title));
    b.addEventListener('click', () => {
      close();
      item.action?.();
    });
    menu.appendChild(b);
  }
  host.appendChild(menu);
  const r = anchor.getBoundingClientRect();
  const m = menu.getBoundingClientRect();
  let left = align === 'end' ? r.right - m.width : r.left;
  let top = r.bottom + 4;
  if (top + m.height > window.innerHeight - 8) top = Math.max(8, r.top - m.height - 4);
  left = Math.min(Math.max(8, left), window.innerWidth - m.width - 8);
  menu.style.left = `${left}px`;
  menu.style.top = `${top}px`;
  setTimeout(() => {
    document.addEventListener('pointerdown', outside, true);
    document.addEventListener('keydown', key, true);
    window.addEventListener('blur', close);
  });
  return close;
}

/** A popup button (Picker(.menu)): shows `title`, opens `items` on click. */
export function MenuButton({ title, items, disabled, help, align, class: className, style }) {
  return html`<button
    class=${cx('menu-button', className)}
    style=${style}
    disabled=${disabled}
    title=${help}
    onClick=${(e) => openMenu(e.currentTarget, typeof items === 'function' ? items() : items, { align })}
  >
    <span>${title}</span><${Icon} name="chevron.up.chevron.down" />
  </button>`;
}

// ---- Dialogs -----------------------------------------------------------------------

/**
 * confirmationDialog / alert. Resolves with the chosen action's `value`, or
 * null on cancel (Escape, backdrop).
 */
export function confirmDialog({ title, message, actions }) {
  return new Promise((resolve) => {
    const host = document.createElement('div');
    host.className = 'dialog-backdrop';
    const box = document.createElement('div');
    box.className = 'dialog';
    box.setAttribute('role', 'alertdialog');
    const done = (value) => {
      document.removeEventListener('keydown', key, true);
      host.remove();
      resolve(value);
    };
    const key = (e) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        done(null);
      } else if (e.key === 'Enter') {
        const preferred = actions.find((a) => a.default) || actions[actions.length - 1];
        e.preventDefault();
        done(preferred.role === 'cancel' ? null : (preferred.value ?? true));
      }
    };
    if (title) box.appendChild(Object.assign(document.createElement('h2'), { className: 'dialog__title', textContent: title }));
    if (message) box.appendChild(Object.assign(document.createElement('p'), { className: 'dialog__message', textContent: message }));
    const row = document.createElement('div');
    row.className = 'dialog__actions';
    for (const a of actions) {
      const b = document.createElement('button');
      b.className = cx('btn', a.role === 'destructive' ? 'is-destructive' : a.default && 'is-primary');
      b.textContent = a.title;
      b.addEventListener('click', () => done(a.role === 'cancel' ? null : (a.value ?? true)));
      row.appendChild(b);
    }
    box.appendChild(row);
    host.appendChild(box);
    host.addEventListener('pointerdown', (e) => {
      if (e.target === host) done(null);
    });
    document.body.appendChild(host);
    document.addEventListener('keydown', key, true);
    (row.querySelector('.is-primary') || row.lastElementChild)?.focus();
  });
}
