// InitialSetupView.swift: the only first-run decision Charker cannot infer —
// which product the user owns, then whether this run uses the real charger or
// the simulator. Connection details stay on the product's 设备与连接 page.

import { html, useState } from '../lib.js';
import { t, tf } from '../core/l10n.js';
import { call, selectSection, setActionMessage } from '../core/store.js';
import { Chip, Icon, cx } from '../ui/components.js';
import { registerIcons } from '../ui/icons.js';

registerIcons({
  'su-play':
    '<svg class="ck-icon" width="1em" height="1em" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M4.5 2.6v10.8a.6.6 0 0 0 .9.5l8.6-5.4a.6.6 0 0 0 0-1L5.4 2.1a.6.6 0 0 0-.9.5Z"/></svg>',
});

const PRODUCTS = {
  A2687: {
    id: 'A2687',
    displayName: 'Anker Prime 160W',
    connectionLabel: '蓝牙直连',
    portSummary: '3 个 USB-C 端口 · 最高 160 W',
    // The Mac reads "无需在 macOS 蓝牙设置里配对。".
    realDetail: '无需在 Windows 蓝牙设置里配对。',
    realSymbol: 'antenna.radiowaves.left.and.right',
  },
  A2345: {
    id: 'A2345',
    displayName: 'Anker Prime 250W',
    connectionLabel: 'Wi-Fi 云端',
    portSummary: '4 个 USB-C + 2 个 USB-A · 最高 250 W',
    realDetail: '使用绑定设备的 Anker 账号登录；请先在官方 App 中完成 Wi-Fi 配网。',
    realSymbol: 'wifi',
  },
};

/** ProductStage(active: true) / A2345ProductStage: the static renders. */
function ProductArtwork({ product, height }) {
  if (product.id === 'A2345') {
    return html`<div class="su-art su-art--a2345" style=${{ height: `${height * 0.82}px` }}>
      <img src="assets/models/a2345-hero.png" alt="" draggable="false" />
    </div>`;
  }
  const width = height * 0.91;
  return html`<div class="dv-stage su-art--a2687" style=${{ width: `${height * 1.1}px` }}>
    <div
      class="dv-stage__shadow"
      style=${{ width: `${width * 0.78}px`, height: `${height * 0.085}px`, bottom: `${height * 0.255 + height * 0.26 - 1}px` }}
    ></div>
    <div class="dv-stage__art" style=${{ width: `${width}px`, height: `${height}px` }}>
      <img src="assets/models/a2687-hero.png" alt="" draggable="false" />
    </div>
    <div class="dv-stage__reflection" style=${{ width: `${width}px`, height: `${height * 0.26}px`, opacity: 0.14 }}>
      <img src="assets/models/a2687-hero.png" alt="" draggable="false" style=${{ height: `${height}px` }} />
    </div>
  </div>`;
}

function SetupStep({ number, title, active, completed }) {
  return html`<div class=${cx('su-step', (active || completed) && 'is-on', active && 'is-active')}>
    <span class="su-step__dot num">${completed ? html`<${Icon} name="checkmark" />` : number}</span>
    <span class="t-micro">${title}</span>
  </div>`;
}

function ProductChoiceButton({ product, onChoose }) {
  return html`<button
    class="su-choice"
    aria-label=${tf('选择 %@，%@', product.displayName, t(product.connectionLabel))}
    onClick=${onChoose}
  >
    <div class="su-well su-well--choice"><${ProductArtwork} product=${product} height=${product.id === 'A2345' ? 86 / 0.82 : 102} /></div>
    <div class="su-identity">
      <span class="t-heading c-primary">${product.displayName}</span>
      <span class="t-caption c-accent">${t(product.connectionLabel)}</span>
      <span class="t-caption c-tertiary">${t(product.portSummary)}</span>
    </div>
    <div class="su-choice__cta c-accent">
      <span class="t-label">${t('选择这款')}</span>
      <span class="su-spacer"></span>
      <${Icon} name="arrow.right" class="su-arrow" />
    </div>
  </button>`;
}

function SetupRouteButton({ title, detail, symbol, primary, onClick }) {
  return html`<button class=${cx('su-route', primary && 'is-primary')} aria-label=${`${title}。${detail}`} onClick=${onClick}>
    <span class="su-route__icon"><${Icon} name=${symbol} /></span>
    <span class="su-route__text">
      <span class="t-heading c-primary">${title}</span>
      <span class="t-caption c-secondary para">${detail}</span>
    </span>
    <${Icon} name="arrow.right" class="su-arrow su-route__arrow" />
  </button>`;
}

export default function InitialSetup() {
  const [selected, setSelected] = useState(null);
  const product = selected ? PRODUCTS[selected] : null;

  const finish = (mode) => {
    call('CompleteInitialSetup', product.id, mode)
      .then(() => {
        // useBluetoothConnection / useA2345CloudConnection land on the
        // device page; enterDemoMode on the dashboard.
        selectSection(mode === 'demo' ? 'dashboard' : 'devices');
      })
      .catch((err) => setActionMessage(String(err?.message || err)));
  };

  return html`<div class="setup">
    <div class="titlebar titlebar--detail"></div>
    <div class="su-column">
      <div class="su-header">
        <img class="su-header__icon" src="assets/app-icon.png" alt="" />
        <div class="su-header__text">
          <span class="t-title c-primary">Charker</span>
          <span class="t-caption c-tertiary">${t('充电器功率与能耗监控')}</span>
        </div>
        <span class="su-spacer"></span>
        <${Chip} text=${t('首次设置')} />
      </div>

      <div class="su-progress" role="group" aria-label=${tf('首次设置，第 %d 步，共 2 步', product ? 2 : 1)}>
        <${SetupStep} number=${1} title=${t('选择型号')} active=${!product} completed=${!!product} />
        <span class=${cx('su-progress__line', product && 'is-done')} aria-hidden="true"></span>
        <${SetupStep} number=${2} title=${t('选择使用方式')} active=${!!product} completed=${false} />
      </div>

      ${product
        ? html`<div class="su-body su-body--forward" key="route">
            <h1 class="su-title">${t('选择使用方式')}</h1>
            <div class="su-route-row">
              <div class="su-selected">
                <div class="su-well su-well--selected"><${ProductArtwork} product=${product} height=${116} /></div>
                <div class="su-identity">
                  <span class="t-heading c-primary">${product.displayName}</span>
                  <span class="t-caption c-accent">${t(product.connectionLabel)}</span>
                  <span class="t-caption c-tertiary">${t(product.portSummary)}</span>
                </div>
              </div>
              <div class="su-routes">
                <${SetupRouteButton}
                  title=${t('连接真实设备')}
                  detail=${t(product.realDetail)}
                  symbol=${product.realSymbol}
                  primary
                  onClick=${() => finish('real')}
                />
                <${SetupRouteButton}
                  title=${t('体验模拟设备')}
                  detail=${t('无需充电器或账号。')}
                  symbol="su-play"
                  onClick=${() => finish('demo')}
                />
                <div class="su-back">
                  <button class="btn is-quiet" onClick=${() => setSelected(null)}>
                    <${Icon} name="arrow.left" /><span>${t('重新选择型号')}</span>
                  </button>
                </div>
              </div>
            </div>
          </div>`
        : html`<div class="su-body su-body--back" key="product">
            <h1 class="su-title">${t('你使用哪一款充电器？')}</h1>
            <div class="su-choices">
              <${ProductChoiceButton} product=${PRODUCTS.A2687} onChoose=${() => setSelected('A2687')} />
              <${ProductChoiceButton} product=${PRODUCTS.A2345} onChoose=${() => setSelected('A2345')} />
            </div>
          </div>`}
    </div>
  </div>`;
}
