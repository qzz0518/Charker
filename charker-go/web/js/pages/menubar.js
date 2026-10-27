// 任务栏: the Windows counterpart of the Mac's 菜单栏 page. Windows shows no
// text in the notification area, so the live wattage is drawn into the tray
// icon itself and the details go to its tooltip, which reads the same for
// everyone (charger and total, then the ports). What is left to choose is
// what the icon shows, the decimals and whether idle ports are listed; the
// tooltip and the flyout follow both.

import { html, useEffect, useState } from '../lib.js';
import { t } from '../core/l10n.js';
import { call, setPrefs } from '../core/store.js';
import { cx } from '../ui/components.js';
import { Segmented, SettingsGroup, SettingsPage, SwitchRow } from './settings.js';

/** The tray icon and tooltip as Windows shows them now, from Go. */
function useTrayPreview(state) {
  const [preview, setPreview] = useState(null);
  const s = state.session;
  const total =
    s.phase === 'polling' && s.telemetry
      ? (s.telemetry.ports || []).reduce((sum, p) => sum + (p.statusCode ? p.power : 0), 0)
      : -1;
  // Refresh when the readout changes in a way the tooltip shows.
  const key = [
    total.toFixed(state.prefs.decimals),
    s.phase,
    s.isStale,
    state.prefs.showIconOnly,
    state.prefs.hideIdlePorts,
    state.prefs.decimals,
    state.app.locale,
    state.app.product,
  ].join('|');
  useEffect(() => {
    let live = true;
    const load = () =>
      call('TrayIconPreview')
        .then((p) => live && setPreview(p))
        .catch(() => {});
    load();
    // The taskbar can switch between light and dark while nothing else
    // changes: read it again whenever the window comes back to the front.
    window.addEventListener('focus', load);
    return () => {
      live = false;
      window.removeEventListener('focus', load);
    };
  }, [key]);
  return preview;
}

function TrayPreview({ preview }) {
  const dark = preview?.dark ?? true;
  return html`<div class=${cx('tray-preview', dark ? 'is-dark' : 'is-light')} aria-hidden="true">
    <div class="tray-preview__tip">${preview?.toolTip ?? 'Charker'}</div>
    <div class="tray-preview__bar">
      <img class="tray-preview__icon" src=${preview?.icon || 'assets/app-icon.png'} alt="" />
    </div>
  </div>`;
}

function ControlRow({ title, children }) {
  return html`<div class="settings-row">
    <div class="settings-row__text"><span class="t-body c-primary">${title}</span></div>
    ${children}
  </div>`;
}

export default function MenuBarPage({ state }) {
  const p = state.prefs;
  const preview = useTrayPreview(state);
  const set = (patch) => setPrefs(patch).catch(() => {});
  return html`<${SettingsPage} title=${t('任务栏')}>
    <${SettingsGroup}
      footnote=${t('Windows 会先把新图标收进任务栏的 ^ 里；把它拖到任务栏上就会一直显示。')}
    >
      <${TrayPreview} preview=${preview} />
      <${ControlRow} title=${t('图标')}>
        <${Segmented}
          label=${t('图标')}
          value=${p.showIconOnly ? 'app' : 'power'}
          segments=${[
            { value: 'power', title: t('实时功率') },
            { value: 'app', title: t('应用图标') },
          ]}
          onChange=${(v) => set({ showIconOnly: v === 'app' })}
        />
      </${ControlRow}>
    </${SettingsGroup}>

    <${SettingsGroup} title=${t('显示')}>
      <${ControlRow} title=${t('默认小数位')}>
        <${Segmented}
          label=${t('默认小数位')}
          value=${p.decimals}
          segments=${[0, 1, 2, 3].map((n) => ({ value: n, title: String(n) }))}
          onChange=${(v) => set({ decimals: v })}
        />
      </${ControlRow}>
      <${SwitchRow}
        title=${t('隐藏没有输出的端口')}
        on=${p.hideIdlePorts}
        onChange=${(v) => set({ hideIdlePorts: v })}
      />
    </${SettingsGroup}>
  </${SettingsPage}>`;
}
