// 关于 Charker (SettingsViews.swift AboutView). Windows has no Sparkle:
// 检查更新… asks GitHub for the newest Windows release and offers its page.

import { html, useState } from '../lib.js';
import { t, tf } from '../core/l10n.js';
import { call, setActionMessage } from '../core/store.js';
import { ActionButton, SlateCard, confirmDialog } from '../ui/components.js';
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

// Downloads, verifies and installs the update; Charker restarts on success.
function installUpdate() {
  call('InstallUpdate').catch((err) => setActionMessage(tf('更新失败：%@', String(err?.message || err))));
}

async function checkForUpdates(setChecking, canInstall) {
  setChecking(true);
  try {
    const result = await call('CheckForUpdates');
    if (result.available) {
      const go = await confirmDialog({
        title: t('发现新版本'),
        message: tf('Charker %@ 已发布，你现在用的是 %@。', result.latest, result.current),
        actions: [
          { title: t('以后再说'), role: 'cancel' },
          { title: canInstall ? t('安装并重新启动') : t('前往下载'), default: true, value: true },
        ],
      });
      if (go && canInstall) installUpdate();
      else if (go) await call('OpenExternal', result.url);
    } else {
      await confirmDialog({
        title: t('已是最新版本'),
        message: tf('Charker %@ 是目前最新的版本。', versionText(result.current) || t('开发构建')),
        actions: [{ title: t('好'), default: true }],
      });
    }
  } catch (err) {
    setActionMessage(tf('检查更新失败：%@', String(err?.message || err)));
  } finally {
    setChecking(false);
  }
}

export default function AboutPage({ state }) {
  const [checking, setChecking] = useState(false);
  const version = versionText(state.app.version);
  const update = state.update || {};
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
        <div class="settings-row__text">
          <span class="t-body c-primary">${t('软件更新')}</span>
          ${update.installing
            ? html`<span class="t-caption c-secondary">${t('正在下载更新…')}</span>`
            : update.available
              ? html`<span class="t-caption c-secondary">${tf('Charker %@ 可以更新了', update.latest)}</span>`
              : null}
        </div>
        ${update.available && update.canInstall
          ? html`<${ActionButton}
              emphasis="primary"
              title=${t('安装并重新启动')}
              disabled=${update.installing}
              onClick=${installUpdate}
            />`
          : html`<${ActionButton}
              title=${t('检查更新…')}
              disabled=${checking}
              onClick=${() => checkForUpdates(setChecking, update.canInstall)}
            />`}
      </div>
    </${SettingsGroup}>

    <p class="t-caption c-tertiary para about-footnote">
      ${t('独立项目，与 Anker 无关联、未获其背书。Anker、Anker Prime 为 Anker Innovations 的商标。')}
    </p>
  </${SettingsPage}>`;
}
