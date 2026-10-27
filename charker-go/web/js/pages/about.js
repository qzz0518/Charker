// 关于 Charker (SettingsViews.swift AboutView). Windows has no Sparkle:
// 检查更新… asks GitHub for the newest Windows release and offers its page.

import { html } from '../lib.js';
import { t, tf } from '../core/l10n.js';
import { call, setActionMessage } from '../core/store.js';
import { ActionButton, SlateCard } from '../ui/components.js';
import { SettingsGroup, SettingsPage } from './settings.js';

const GITHUB_URL = 'https://github.com/qzz0518/Charker';
const X_URL = 'https://x.com/zerah_eth';

/** AppModel.versionText: nil for a development build. */
function versionText(version) {
  if (!version || /dev/i.test(version) || version === '0.0.0') return null;
  return version;
}

/** The real product icon; tilts on hover, the About page's one wink. */
function AppMark() {
  return html`<div class="about-mark" aria-hidden="true">
    <img src="assets/app-icon.png" alt="" draggable="false" />
  </div>`;
}

/** Brand links stay icon-only; the tooltip carries the action. */
function LinkButton({ title, url, mark, size }) {
  return html`<button
    class="about-link"
    title=${title}
    aria-label=${title}
    onClick=${() => call('OpenExternal', url).catch((err) => setActionMessage(String(err?.message || err)))}
  >
    <span
      class="about-link__mark"
      style=${{ width: `${size}px`, height: `${size}px`, '--mark': `url(/assets/brand/${mark}.svg)` }}
    ></span>
  </button>`;
}

export default function AboutPage({ state }) {
  const version = versionText(state.app.version);
  return html`<${SettingsPage} title=${t('关于 Charker')}>
    <${SlateCard} class="about-card">
      <${AppMark} />
      <div class="about-card__name">
        <span class="t-title c-primary">Charker</span>
        <span class="t-caption c-tertiary">${version ? tf('版本 %@', version) : t('开发构建')}</span>
      </div>
      <div class="about-card__links">
        <${LinkButton} title=${t('打开 Charker 的 GitHub 仓库')} url=${GITHUB_URL} mark="GitHub" size=${19} />
        <${LinkButton} title=${t('在 X 上关注 @zerah_eth')} url=${X_URL} mark="X" size=${17} />
      </div>
    </${SlateCard}>

    <${SettingsGroup}>
      <div class="settings-row">
        <span class="t-body c-primary">${t('软件更新')}</span>
        <${ActionButton} title=${t('检查更新…')} onClick=${() => call('CheckForUpdates').catch(() => {})} />
      </div>
    </${SettingsGroup}>

    <p class="t-caption c-tertiary para about-footnote">
      ${t('独立项目，与 Anker 无关联、未获其背书。Anker、Anker Prime 为 Anker Innovations 的商标。')}
    </p>
  </${SettingsPage}>`;
}
