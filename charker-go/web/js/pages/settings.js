// The settings chrome of SettingsViews.swift that 菜单栏, 高级 and 关于 share:
// SettingsPage, SettingsGroup, SwitchRow and SliderRow. Styles live in
// css/advanced.css (.settings-*).

import { html, useEffect, useLayoutEffect, useRef, useState } from '../lib.js';
import { t, tf } from '../core/l10n.js';
import { Segmented, SlateCard, Toggle, cx } from '../ui/components.js';

export { Segmented };

/** SettingsPage: a 620-wide column under the page title. */
export function SettingsPage({ title, children }) {
  return html`<div class="page scroll">
    <div class="page__content settings-page">
      <h1 class="t-title c-primary settings-page__title">${title}</h1>
      ${children}
    </div>
  </div>`;
}

/** SettingsGroup: optional label, a SlateCard, optional footnote. */
export function SettingsGroup({ title, footnote, class: className, children }) {
  return html`<section class=${cx('settings-group', className)}>
    ${title ? html`<h2 class="t-label c-secondary settings-group__title">${title}</h2>` : null}
    <${SlateCard} padding=${16} class="settings-group__card">
      <div class="settings-group__body">${children}</div>
    </${SlateCard}>
    ${footnote ? html`<p class="t-caption c-tertiary para settings-group__footnote">${footnote}</p>` : null}
  </section>`;
}

/** SwitchRow: label left, small switch right. */
export function SwitchRow({ title, subtitle, on, onChange, disabled, titleClass = 't-body' }) {
  return html`<div class=${cx('settings-row', disabled && 'is-disabled')}>
    <div class="settings-row__text">
      <span class=${cx(titleClass, 'c-primary')}>${title}</span>
      ${subtitle ? html`<span class="t-caption c-tertiary">${subtitle}</span>` : null}
    </div>
    <${Toggle} small on=${on} onChange=${onChange} disabled=${disabled} label=${title} />
  </div>`;
}

/**
 * SliderRow: label and live value pill, a continuous slider with one tick
 * per unit below. The value commits on release, not on every position.
 */
export function SliderRow({ title, value, min, max, unit, onChange }) {
  const [draft, setDraft] = useState(value);
  const [dragging, setDragging] = useState(false);
  useEffect(() => {
    if (!dragging) setDraft(value);
  }, [value]);
  const current = Math.round(draft);
  const commit = () => {
    setDragging(false);
    const clamped = Math.min(max, Math.max(min, current));
    setDraft(clamped);
    if (clamped !== value) onChange(clamped);
  };
  const fraction = (draft - min) / (max - min);
  const steps = max - min;
  return html`<div class="settings-slider">
    <div class="settings-row">
      <span class="t-body c-primary">${title}</span>
      <span class="settings-slider__pill" aria-hidden="true">
        <span class="num settings-slider__value">${current}</span>
        <span class="settings-slider__unit">${t(unit)}</span>
      </span>
    </div>
    <div class="settings-slider__track-row">
      <input
        type="range"
        class="settings-slider__input"
        min=${min}
        max=${max}
        step="any"
        value=${draft}
        style=${{ '--fill': `${fraction * 100}%` }}
        aria-label=${title}
        aria-valuetext=${tf('%d %@', current, t(unit))}
        onPointerDown=${() => setDragging(true)}
        onInput=${(e) => setDraft(Number(e.currentTarget.value))}
        onChange=${commit}
        onKeyDown=${(e) => {
          const delta = { ArrowLeft: -1, ArrowDown: -1, ArrowRight: 1, ArrowUp: 1 }[e.key];
          if (!delta) return;
          e.preventDefault();
          const next = Math.min(max, Math.max(min, current + delta));
          setDraft(next);
          if (next !== value) onChange(next);
        }}
      />
      <div class="settings-slider__ticks" aria-hidden="true">
        ${Array.from({ length: steps + 1 }, (_, i) => html`<span key=${i}></span>`)}
      </div>
    </div>
  </div>`;
}

