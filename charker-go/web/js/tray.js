// The tray flyout: MenuBarReadout.swift, the menu bar popover, as a compressed
// mirror of the dashboard. Go opens web/tray.html in a flyout above the
// notification-area icon (internal/app/tray.go) and sizes it to this page.

import { html, render, useState } from './lib.js';
import { loadLocale, t, tf } from './core/l10n.js';
import { boot, call, getState, setPrefs, subscribe, useStore } from './core/store.js';
import { activeProduct } from './pages/menubar.js';
import {
  activeDisplayName,
  hasReadings,
  isDelivering,
  isOn,
  isStandby,
  phaseShortLabel,
  telemetryPort,
  totalPower,
} from './core/model.js';
import { ActionButton, Icon, PowerRail, StateDot, TotalReadout, cx } from './ui/components.js';

function Header({ state }) {
  const s = state.session;
  const stale = s.isStale;
  const cloud = a2345View(state);
  return html`<div class="tray-header">
    <span class="t-heading c-primary tray-header__name">${activeDisplayName(state) ?? t('未连接')}</span>
    <span class="tray-header__status">
      <${StateDot} session=${s} stale=${stale} />
      <span class=${cx('t-caption', stale ? 'c-warn' : 'c-secondary')}>
        ${cloud ? cloud.statusLabel ?? phaseShortLabel(s) : stale ? t('数据陈旧') : phaseShortLabel(s)}
      </span>
    </span>
  </div>`;
}

// Monotone cubic interpolation (Swift Charts' .monotone, d3's monotoneX).
function monotonePath(points) {
  const n = points.length;
  if (n < 2) return '';
  const dx = [];
  const slope = [];
  for (let i = 0; i < n - 1; i++) {
    dx.push(points[i + 1][0] - points[i][0]);
    slope.push(dx[i] ? (points[i + 1][1] - points[i][1]) / dx[i] : 0);
  }
  const tangent = [slope[0]];
  for (let i = 1; i < n - 1; i++) {
    const a = slope[i - 1];
    const b = slope[i];
    tangent.push(a * b <= 0 ? 0 : (3 * (dx[i - 1] + dx[i])) / ((2 * dx[i] + dx[i - 1]) / a + (dx[i] + 2 * dx[i - 1]) / b));
  }
  tangent.push(slope[n - 2]);
  let d = `M${points[0][0]},${points[0][1]}`;
  for (let i = 0; i < n - 1; i++) {
    const h = dx[i] / 3;
    d +=
      `C${points[i][0] + h},${points[i][1] + h * tangent[i]} ` +
      `${points[i + 1][0] - h},${points[i + 1][1] - h * tangent[i + 1]} ` +
      `${points[i + 1][0]},${points[i + 1][1]}`;
  }
  return d;
}

/** The last few minutes at a glance: the dashboard's curve, no axes. */
function Sparkline({ history, stale, ratedWatts }) {
  if (history.length <= 8) return null;
  const samples = history.slice(-90);
  const width = 308;
  const height = 36;
  const t0 = samples[0].t;
  const span = Math.max(1, samples[samples.length - 1].t - t0);
  const ceiling = ratedWatts * 1.05;
  const points = samples.map((s) => [
    ((s.t - t0) / span) * width,
    height - (Math.max(0, Math.min(ceiling, s.total)) / ceiling) * height,
  ]);
  const line = monotonePath(points);
  const area = `${line}L${width},${height}L0,${height}Z`;
  return html`<svg
    class=${cx('tray-spark', stale && 'is-stale')}
    viewBox="0 0 ${width} ${height}"
    preserveAspectRatio="none"
    role="img"
    aria-label=${t('本次实时功率趋势')}
  >
    <defs>
      <linearGradient id="tray-spark-fill" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0" class="tray-spark__stop-top" />
        <stop offset="1" class="tray-spark__stop-bottom" />
      </linearGradient>
    </defs>
    <path d=${area} fill="url(#tray-spark-fill)" />
    <path d=${line} class="tray-spark__line" fill="none" vector-effect="non-scaling-stroke" />
  </svg>`;
}

function PortStrip({ port, telemetry, nickname, labelWidth, railWidth }) {
  const [hovering, setHovering] = useState(false);
  const delivering = isDelivering(telemetry);
  const watts = isOn(telemetry) ? telemetry.power : 0;
  const readings = hasReadings(telemetry);
  let detail;
  if (!telemetry) detail = t('无数据');
  else if (!isOn(telemetry)) detail = t('已关闭');
  else if (readings) detail = tf('%.1fV %.2fA', telemetry.voltage, telemetry.current);
  else if (isStandby(telemetry)) detail = t('待机');
  else detail = t('未接入');
  return html`<div
    class=${cx('tray-port', hovering && 'is-hovering')}
    onPointerEnter=${() => setHovering(true)}
    onPointerLeave=${() => setHovering(false)}
  >
    <span
      class=${cx('tray-port__label', nickname ? 't-label' : 'num', delivering && 'is-lit')}
      style=${{ width: `${labelWidth}px` }}
      title=${nickname ? `${port} · ${nickname}` : port}
      >${nickname || port}</span
    >
    <span class="tray-port__watts">
      ${readings
        ? html`<span class=${cx('num tray-port__value', delivering && 'is-lit')}>${tf('%.1f', watts)}</span
            ><span class="tray-port__unit">W</span>`
        : html`<span class="num tray-port__value is-empty">—</span>`}
    </span>
    <span class="tray-port__rail" style=${{ width: `${railWidth}px` }}>
      <${PowerRail} watts=${watts} isDelivering=${delivering} />
    </span>
    <span class="tray-port__spacer"></span>
    <span class=${cx('tray-port__detail', readings ? 'num' : 't-caption')}>${detail}</span>
  </div>`;
}

/**
 * The A2345 (cloud) side of AppModel the popover reads. AppState carries
 * none of it yet: the A2345 port fills state.a2345 with {phase, isDemo,
 * canRetry, supportsCloud, hasRemembered, failure, warning, statusLabel} and these
 * branches light up. Null for the A2687.
 */
function a2345View(state) {
  return activeProduct(state).id === 'A2345' ? state.a2345 || null : null;
}

/** A2345PortStrip: six ports on the product's own power scale. */
function A2345PortStrip({ port, telemetry, ceiling, stale }) {
  const [hovering, setHovering] = useState(false);
  const delivering = !stale && isDelivering(telemetry);
  const watts = isOn(telemetry) ? telemetry.power : 0;
  const readings = hasReadings(telemetry);
  let detail;
  if (!telemetry) detail = t('无数据');
  else if (readings) detail = tf('%.1fV %.2fA', telemetry.voltage, telemetry.current);
  else detail = isOn(telemetry) ? t('待机') : t('未接入');
  return html`<div
    class=${cx('tray-port', hovering && 'is-hovering')}
    onPointerEnter=${() => setHovering(true)}
    onPointerLeave=${() => setHovering(false)}
  >
    <span class=${cx('tray-port__label num', delivering && 'is-lit')} style=${{ width: '24px' }}>${port}</span>
    <span class="tray-port__watts">
      ${readings
        ? html`<span class=${cx('num tray-port__value', delivering && 'is-lit')}>${tf('%.1f', watts)}</span
            ><span class="tray-port__unit">W</span>`
        : html`<span class="num tray-port__value is-empty">—</span>`}
    </span>
    <span class="tray-port__rail" style=${{ width: '80px' }}>
      <${PowerRail} watts=${watts} ceiling=${Math.max(1, ceiling)} isDelivering=${delivering} dimmed=${stale} />
    </span>
    <span class="tray-port__spacer"></span>
    <span class=${cx('tray-port__detail', readings ? 'num' : 't-caption')} style=${{ width: '76px' }}>${detail}</span>
  </div>`;
}

/** The footer's second action, by product and connection. */
function SecondAction({ state }) {
  const cloud = a2345View(state);
  if (activeProduct(state).id !== 'A2345') {
    return html`<${ActionButton} title=${t('重新连接')} onClick=${() => call('Reconnect').catch(() => {})} />`;
  }
  if (cloud?.isDemo) {
    return html`<${ActionButton} title=${t('退出模拟')} onClick=${() => setPrefs({ demoMode: false }).catch(() => {})} />`;
  }
  if (cloud?.canRetry) {
    return html`<${ActionButton} title=${t('重新连接')} onClick=${() => call('Reconnect').catch(() => {})} />`;
  }
  const title = !cloud?.supportsCloud
    ? t('查看系统要求')
    : cloud?.hasRemembered
      ? t('查看连接状态')
      : t('登录并连接');
  return html`<${ActionButton}
    title=${title}
    onClick=${() =>
      setPrefs({ lastSection: 'devices' })
        .then(() => call('ShowMainWindow'))
        .catch(() => {})}
  />`;
}

function Readout() {
  const [state] = useStore();
  const s = state.session;
  const stale = s.isStale;
  const total = totalPower(s);
  const product = activeProduct(state);
  const cloud = a2345View(state);
  const nicknames = state.prefs.portNicknames || [];
  const hasNicknames = nicknames.some((n) => n);
  // A failure explains itself in red; a warning is a quiet footnote.
  const warning = cloud ? cloud.failure || cloud.warning || null : s.warning || s.lastError || null;
  const failure = cloud ? !!cloud.failure : !!s.lastError && !s.warning;
  return html`<div class="tray">
    <${Header} state=${state} />
    <div class="tray-total">
      <${TotalReadout} watts=${total} isStale=${stale} size=${30} />
      <${PowerRail}
        watts=${total ?? 0}
        ceiling=${product.ratedWatts}
        isDelivering=${!stale && (total ?? 0) > 0}
        dimmed=${stale}
      />
    </div>
    <${Sparkline} history=${s.history || []} stale=${stale} ratedWatts=${product.ratedWatts} />
    <div class="tray-ports">
      ${product.ports.map((port, i) =>
        product.id === 'A2345'
          ? html`<${A2345PortStrip}
              key=${port}
              port=${port}
              telemetry=${telemetryPort(state, port)}
              ceiling=${product.ratedWatts}
              stale=${stale}
            />`
          : html`<${PortStrip}
          key=${port}
          port=${port}
          telemetry=${telemetryPort(state, port)}
          nickname=${nicknames[i] || ''}
          labelWidth=${hasNicknames ? 64 : 22}
          railWidth=${hasNicknames ? 60 : 82}
        />`,
      )}
    </div>
    ${warning
      ? html`<div class="tray-warning">
          ${failure ? html`<${Icon} name="bolt.slash.fill" class="tray-warning__icon" />` : null}
          <span class=${cx('t-caption para', failure ? 'c-danger' : 'c-tertiary')}>${warning}</span>
        </div>`
      : null}
    <div class="tray-divider"></div>
    <div class="tray-footer">
      <${ActionButton} emphasis="primary" title=${t('打开主窗口')} onClick=${() => call('ShowMainWindow').catch(() => {})} />
      <${SecondAction} state=${state} />
      <span class="tray-footer__spacer"></span>
      <${ActionButton}
        title=${t('退出')}
        help=${t('退出 Charker（不影响充电器输出）')}
        onClick=${() => call('Quit').catch(() => {})}
      />
    </div>
  </div>`;
}

function applyAppearance(appearance) {
  const dark =
    appearance === 'dark' ||
    (appearance !== 'light' && window.matchMedia('(prefers-color-scheme: dark)').matches);
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
}

async function start() {
  const host = document.getElementById('app');
  try {
    const state = await boot();
    await loadLocale(state.app.locale);
    applyAppearance(state.prefs.appearance);
    window
      .matchMedia('(prefers-color-scheme: dark)')
      .addEventListener('change', () => applyAppearance(getState().prefs.appearance));
    let locale = state.app.locale;
    let appearance = state.prefs.appearance;
    subscribe(async () => {
      const s = getState();
      if (s.prefs.appearance !== appearance) {
        appearance = s.prefs.appearance;
        applyAppearance(appearance);
      }
      if (s.app.locale !== locale) {
        locale = s.app.locale;
        await loadLocale(locale);
        render(null, host);
        render(html`<${Readout} />`, host);
      }
    });
    render(html`<${Readout} />`, host);
  } catch (err) {
    console.error(err);
    host.textContent = String(err?.message || err);
  }
}

start();
