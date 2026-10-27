// Apple 家庭 (SettingsViews.swift AppleHomeView): the switch, then one card
// per accessory with its setup code until it is in Home. The Mac's
// local-network hint becomes the Windows Firewall one.

import { html, useMemo } from '../lib.js';
import { t, tf } from '../core/l10n.js';
import { call, setActionMessage } from '../core/store.js';
import { ActionButton, Chip, CopyIconButton, Icon, SlateCard, confirmDialog, cx, openMenu } from '../ui/components.js';
import { icon, registerIcons } from '../ui/icons.js';
import { encode } from '../../vendor/uqr/index.mjs';
import { SettingsGroup, SettingsPage, SwitchRow } from './settings.js';

registerIcons({
  'powerplug.fill': icon('powerplug-fill'),
  // Lucide shield-alert (ISC).
  'exclamationmark.shield':
    '<svg class="ck-icon" width="1em" height="1em" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">' +
    '<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/>' +
    '<path d="M12 8v4"/><path d="M12 16h.01"/></svg>',
  'square.grid.2x2.fill':
    '<svg class="ck-icon" width="1em" height="1em" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true" focusable="false">' +
    '<rect x="1.5" y="1.5" width="5.5" height="5.5" rx="1.4"/><rect x="9" y="1.5" width="5.5" height="5.5" rx="1.4"/>' +
    '<rect x="1.5" y="9" width="5.5" height="5.5" rx="1.4"/><rect x="9" y="9" width="5.5" height="5.5" rx="1.4"/></svg>',
});

const report = (err) => setActionMessage(String(err?.message || err));

export default function AppleHomePage({ state }) {
  const p = state.prefs;
  const home = state.home;
  const isOn = p.matterEnabled && !p.demoMode;
  const statuses = [home.whole.state, home.ports.state];
  // Home can find the charger: a helper is up and showing its code, or is
  // already in Home.
  const isReachable = statuses.some((s) => s === 'paired' || s === 'waitingForPairing');

  // The most serious state of either helper. Pairing shows in each
  // accessory's own card.
  // Windows Firewall comes first: the helpers start once it lets them in.
  const firewall = home.firewall;
  const firewallClosed = isOn && (firewall === 'missing' || firewall === 'blocked');
  let subtitle = null;
  if (p.demoMode) subtitle = t('演示模式下不可用');
  else if (isOn && firewall === 'checking') subtitle = t('正在检查 Windows 防火墙…');
  else if (firewallClosed) subtitle = t('Windows 防火墙还没放行');
  else if (statuses.includes('unavailable')) subtitle = t('这个版本不支持');
  else if (statuses.includes('mdnsFailed'))
    subtitle = t('需要在 Windows 防火墙里允许 charker-matter 访问专用网络');
  else if (statuses.includes('failed')) subtitle = t('无法启动');
  else if (statuses.includes('restarting')) subtitle = t('出错了，正在重试');
  else if (statuses.includes('starting')) subtitle = t('正在启动…');

  return html`<${SettingsPage} title=${t('Apple 家庭')}>
    <${SettingsGroup} footnote=${isOn ? t('电脑睡眠或 Charker 退出后，「家庭」里会显示「无响应」。') : null}>
      <div class="home-switch">
        <${GlyphTile} symbol="homekit" lit=${isOn && isReachable} />
        <${SwitchRow}
          title=${t('接入 Apple 家庭')}
          subtitle=${subtitle}
          titleClass="t-heading"
          on=${isOn}
          disabled=${p.demoMode}
          onChange=${(on) => call('SetHomeEnabled', on).catch(report)}
        />
      </div>
    </${SettingsGroup}>
    ${firewallClosed ? html`<${FirewallCard} blocked=${firewall === 'blocked'} />` : null}
    ${isOn && firewall === 'allowed'
      ? html`
          <${AccessoryCard}
            kind="whole"
            title="整台充电器"
            symbol="powerplug.fill"
            names=${[home.name]}
            showsInstruction=${true}
            status=${home.whole}
          />
          <${AccessoryCard}
            kind="ports"
            title="每个端口"
            symbol="square.grid.2x2.fill"
            names=${home.tiles}
            showsInstruction=${home.whole.state !== 'waitingForPairing'}
            status=${home.ports}
          />
        `
      : null}
  </${SettingsPage}>`;
}

/**
 * Windows Firewall keeps the helper from hearing the iPhone. Allowing it
 * takes one administrator prompt; a Cancel on Windows' own alert left a
 * block rule, which the same prompt removes.
 */
function FirewallCard({ blocked }) {
  const allow = () =>
    call('AllowHomeFirewall')
      .then((ok) => !ok && setActionMessage(t('没有放行，Apple 家庭暂时用不了。')))
      .catch(report);
  return html`<${SettingsGroup}>
    <div class="home-firewall">
      <${Icon} name="exclamationmark.shield" class="home-firewall__icon c-warn" />
      <div class="home-firewall__text">
        <span class="t-body c-primary">
          ${blocked ? t('Windows 防火墙拦住了 Apple 家庭') : t('Windows 防火墙还没放行 Apple 家庭')}
        </span>
        <span class="t-caption c-tertiary para">
          ${t('不放行的话，iPhone 找得到充电器但连不上。放行只对家庭、公司这类专用网络生效，需要管理员确认一次。')}
        </span>
      </div>
      <${ActionButton} emphasis="primary" title=${t('允许…')} onClick=${allow} />
    </div>
  </${SettingsGroup}>`;
}

/** MatterGlyphTile: a glyph on a small tile, lit while its thing is in Home. */
function GlyphTile({ symbol, lit }) {
  return html`<span class=${cx('home-tile', lit && 'is-lit')} aria-hidden="true">
    <${Icon} name=${symbol} />
  </span>`;
}

/**
 * MatterAccessoryCard: what Home calls it, then its code until it is in
 * Home, or a way to start over once it is. While its helper is starting only
 * the frame shows; when it cannot run there is no card.
 */
function AccessoryCard({ kind, title, symbol, names, showsInstruction, status }) {
  let paired;
  switch (status.state) {
    case 'waitingForPairing':
      paired = false;
      break;
    case 'paired':
      paired = true;
      break;
    case 'starting':
    case 'restarting':
      paired = null;
      break;
    default:
      return null;
  }
  const more = tf('%@ 的更多操作', t(title));
  const reset = async () => {
    const choice = await confirmDialog({
      title: t('重置配对？'),
      message: t('重置后要在「家庭」App 里删除这个配件，再重新添加。'),
      actions: [
        { title: t('取消'), role: 'cancel' },
        { title: t('重置'), role: 'destructive', value: true },
      ],
    });
    if (choice) call('ResetHomePairing', kind).catch(report);
  };
  return html`<${SlateCard} class="home-card">
    <div class="home-card__body">
      <div class="home-card__header">
        <div class="home-card__title" role="heading" aria-level="2">
          <${GlyphTile} symbol=${symbol} lit=${paired === true} />
          <span class="t-heading c-primary">${t(title)}</span>
          ${paired != null
            ? html`<span class="home-card__badge">
                <span class=${cx('home-card__dot', paired && 'is-ok')}></span>
                <span class="t-caption c-secondary home-card__badge-text">${t(paired ? '已添加' : '待添加')}</span>
              </span>`
            : null}
        </div>
        ${paired === true
          ? html`<button
              class="home-more"
              title=${more}
              aria-label=${more}
              onClick=${(e) =>
                openMenu(e.currentTarget, [{ title: t('重置配对…'), destructive: true, action: reset }], {
                  align: 'end',
                })}
            >
              <${Icon} name="ellipsis" />
            </button>`
          : null}
      </div>
      <div class="home-card__chips">${names.map((n) => html`<${Chip} key=${n} text=${n} />`)}</div>
      ${paired === false
        ? html`<${Pairing} qr=${status.qr} manualCode=${status.manualCode} showsInstruction=${showsInstruction} />`
        : null}
    </div>
  </${SlateCard}>`;
}

// The copy button copies the bare 11 digits: Home's code field takes them as
// typed.
function Pairing({ qr, manualCode, showsInstruction }) {
  return html`<div class="home-pairing">
    <${QRCode} payload=${qr} />
    <div class="home-pairing__text">
      <div class="home-pairing__code">
        <span class="t-micro c-tertiary">${t('配对码')}</span>
        <div class="home-pairing__code-row">
          <span class="t-metric-sm c-primary home-pairing__digits">${formattedManualCode(manualCode)}</span>
          <${CopyIconButton} value=${manualCode} help="复制配对码" />
        </div>
      </div>
      ${showsInstruction
        ? html`<p class="t-caption c-tertiary para home-pairing__hint">
            ${t('在 iPhone「家庭」App 里添加配件，扫描二维码；提示未认证配件时选「仍然添加」。')}
          </p>`
        : null}
    </div>
  </div>`;
}

/** MatterHelperEvent.formattedManualCode: 34970112332 -> 3497-011-2332. */
function formattedManualCode(code = '') {
  return /^\d{11}$/.test(code) ? `${code.slice(0, 4)}-${code.slice(4, 7)}-${code.slice(7)}` : code;
}

/**
 * MatterQRCode: the setup code on white, quiet zone included, so the iPhone
 * camera reads it in the dark appearance too. ECC level M and a one-module
 * border, as CoreImage draws it.
 */
function QRCode({ payload }) {
  const path = useMemo(() => {
    if (!payload) return null;
    try {
      const { size, data } = encode(payload, { ecc: 'M', border: 1 });
      let d = '';
      for (let y = 0; y < size; y++) {
        for (let x = 0; x < size; x++) if (data[y][x]) d += `M${x} ${y}h1v1h-1z`;
      }
      return { size, d };
    } catch {
      return null;
    }
  }, [payload]);
  return html`<div class="home-qr" role="img" aria-label=${t('配对二维码')}>
    ${path
      ? html`<svg viewBox="0 0 ${path.size} ${path.size}" width="136" height="136" shape-rendering="crispEdges">
          <path d=${path.d} fill="#000" />
        </svg>`
      : null}
  </div>`;
}
