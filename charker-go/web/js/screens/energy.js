// Energy screen (#/energy) — owner: web-screens.
//
// Range tabs (day / week / month), four summary metrics, a bar+mean energy
// chart with hover inspection, the session ledger grouped by day, and CSV /
// JSON export through Charker.ExportEnergy. Data comes from
// Charker.EnergyReport(range) (contract.md §4) with state.energy as the cheap
// pre-render fallback.

import {
  makeUI, h, txt, clear, pageHead, actionButton, card, cardHead, metric,
  notice, emptyState, skeleton, energyParts, durationText, timeText, dayLabel,
  dayKey, bucketLabel, currencySymbol, colHead, callSafe, clamp,
} from './screens-util.js';

const RANGE_DEFS = [
  { value: 'day', label: '今天', sub: '今天按小时分段 · 指针移过查看' },
  { value: 'week', label: '本周', sub: '本周按天分段 · 指针移过查看' },
  { value: 'month', label: '本月', sub: '本月按天分段 · 指针移过查看' },
];

const X_LABELS = { day: 5, week: 7, month: 5 };
const PAGE_SIZE = 16;

let instances = new Set();

export function render(root, state, ctx) {
  let inst = root.__scEnergy;
  if (!inst) {
    inst = createEnergyScreen(root);
    root.__scEnergy = inst;
    instances.add(inst);
  }
  inst.update(makeUI(ctx, state), state);
}

export function cleanup() {
  for (const inst of instances) inst.dispose();
  instances.clear();
}

function emptyReport(range) {
  return { range, buckets: [], totalWh: 0, cost: 0, currency: 'CNY', sessions: [] };
}

function createEnergyScreen(root) {
  const refs = {};
  let ui = null;
  let state = null;
  let disposed = false;

  let range = 'day';
  let report = null;
  let reportRange = null;
  let loading = false;
  let failed = null;
  let expanded = PAGE_SIZE;
  let hoverIndex = -1;
  let builtLocale = null;

  const screen = h('div', { class: 'sc-screen sc-energy' });

  // ---- static shell -------------------------------------------------------

  const rangeSeg = h('div', { class: 'ck-seg sc-seg', role: 'tablist' });
  let exportCsv = null;
  let exportJson = null;

  const summary = h('section', { class: 'ck-card sc-metrics' });
  const trendCard = h('section', { class: 'ck-card sc-trend' });
  const ledgerCard = h('section', { class: 'ck-card sc-ledger' });

  function build(ui0) {
    ui = ui0;
    builtLocale = ui.locale;
    clear(screen);
    clear(summary);
    clear(trendCard);
    clear(ledgerCard);

    // Range segmented control rebuilt per locale (labels are text).
    clear(rangeSeg);
    rangeSeg.style.setProperty('--n', String(RANGE_DEFS.length));
    rangeSeg.append(h('span', { class: 'ck-seg__thumb', 'aria-hidden': 'true' }));
    const rangeButtons = RANGE_DEFS.map((def) => {
      const btn = h('button', {
        class: 'ck-seg__item', type: 'button', role: 'tab', 'aria-selected': 'false',
        text: ui.t(def.label), onclick: () => selectRange(def.value),
      });
      rangeSeg.append(btn);
      return btn;
    });
    refs.rangeButtons = rangeButtons;
    refs.rangeSeg = rangeSeg;

    // Export buttons + header.
    exportCsv = makeExportButton('导出 CSV…', 'csv');
    exportJson = makeExportButton('导出 JSON…', 'json');
    const head = pageHead(ui, '能耗记录', []);
    const headRow = h('div', { class: 'sc-headrow' },
      rangeSeg,
      h('span', { class: 'sc-headrow__spacer' }),
      exportCsv,
      exportJson);
    head.append(h('div', { class: 'sc-head__range' }, headRow));

    // Summary metrics.
    summary.append(
      metric(ui, { label: '总用电量', value: '—', unit: 'Wh', big: true }),
      metric(ui, { label: '电费', value: '—' }),
      metric(ui, { label: '折合满功率时长', value: '—', unit: '小时' }),
      metric(ui, { label: '峰值', value: '—', unit: 'W' }),
    );

    // Trend card.
    clear(trendCard);
    const trendHead = cardHead(ui, { title: '能耗趋势', sub: RANGE_DEFS.find((r) => r.value === range).sub });
    const chartWrap = h('div', { class: 'sc-chartwrap' });
    const chart = h('div', { class: 'sc-chart', role: 'img' });
    const canvas = h('canvas', { 'aria-hidden': 'true' });
    const tip = h('div', { class: 'sc-chart__tip', hidden: true },
      h('div', { class: 'sc-chart__tip-main' }, h('span', { class: 'ck-u-num' }), h('span', { class: 'sc-chart__tip-unit', text: 'Wh' })),
      h('div', { class: 'sc-chart__tip-caption' }));
    chart.append(canvas, tip);
    chartWrap.append(chart);
    const legend = h('div', { class: 'sc-legend' },
      h('span', { class: 'sc-legend__item' }, h('span', { class: 'sc-legend__swatch' }), h('span', { text: ui.t('能量') })),
      h('span', { class: 'sc-legend__item' },
        h('span', { class: 'sc-legend__rule' }),
        h('span', { class: 'sc-legend__txt' })));
    chartWrap.append(legend);
    refs.trendBody = h('div', { class: 'sc-trend__body' }, chartWrap);
    trendCard.append(trendHead, refs.trendBody);
    refs.trendHead = trendHead;
    refs.legend = legend;
    refs.canvas = canvas;
    refs.chart = chart;
    refs.chartWrap = chartWrap;
    refs.tip = tip;

    // Ledger card.
    clear(ledgerCard);
    refs.ledgerHead = cardHead(ui, { title: '会话记录' });
    refs.colhead = colHead([
      { label: ui.t('时间') },
      { label: ui.t('时长') },
      { label: ui.t('用电'), align: 'end' },
      { label: ui.t('峰值'), align: 'end' },
    ]);
    refs.ledgerBody = h('div', { class: 'sc-ledger__body' });
    ledgerCard.append(refs.ledgerHead, refs.colhead, refs.ledgerBody);

    screen.append(head, summary, trendCard, ledgerCard);
    root.append(screen);

    // Canvas interactions (rebuilt with the canvas, so they die with it).
    canvas.addEventListener('mousemove', (ev) => onChartMove(ev));
    canvas.addEventListener('mouseleave', () => { hoverIndex = -1; hideTip(); drawChart(); });
    if (typeof ResizeObserver !== 'undefined') {
      if (refs.ro) refs.ro.disconnect();
      refs.ro = new ResizeObserver(() => drawChart());
      refs.ro.observe(chart);
    }
    if (ui.ctx && typeof ui.ctx.onCleanup === 'function') {
      ui.ctx.onCleanup(() => dispose());
    }
  }

  function makeExportButton(labelKey, format) {
    const label = ui.t(labelKey);
    return h('button', {
      class: 'ck-btn sc-btn', type: 'button', 'data-export': format,
      title: label, 'aria-label': label,
      onclick: () => doExport(format),
    }, ui.el('share', 11), h('span', { text: label }));
  }

  // ---- data ---------------------------------------------------------------

  function selectRange(next) {
    if (next === range) return;
    range = next;
    hoverIndex = -1;
    expanded = PAGE_SIZE;
    hideTip();
    syncRangeTabs();
    updateTrendHead();
    load(range);
    updateLedger();
    drawChart();
  }

  async function load(nextRange) {
    if (!ui || !ui.ctx || typeof ui.ctx.call !== 'function') {
      report = emptyReport(nextRange);
      reportRange = nextRange;
      renderAll();
      return;
    }
    loading = true;
    failed = null;
    if (reportRange !== nextRange) report = null;
    renderAll();
    const out = await callSafe(ui, 'Charker.EnergyReport', [nextRange], null);
    if (disposed) return;
    loading = false;
    if (out && out.__error) {
      failed = out.__error;
      if (reportRange !== nextRange) report = emptyReport(nextRange);
    } else if (out && typeof out === 'object') {
      report = normalizeReport(nextRange, out);
      reportRange = nextRange;
      expanded = PAGE_SIZE;
    } else {
      report = emptyReport(nextRange);
      reportRange = nextRange;
    }
    renderAll();
  }

  function normalizeReport(nextRange, raw) {
    const buckets = Array.isArray(raw.buckets) ? raw.buckets
      .map((b) => ({ t: Number(b.t) || 0, wh: Number(b.wh) || 0 }))
      .filter((b) => b.t > 0) : [];
    buckets.sort((a, b) => a.t - b.t);
    const sessions = Array.isArray(raw.sessions) ? raw.sessions
      .map((s) => ({
        startMs: Number(s.startMs) || 0,
        endMs: Number(s.endMs) || 0,
        wh: Number(s.wh) || 0,
        peakW: Number(s.peakW) || 0,
      }))
      .filter((s) => s.startMs > 0) : [];
    sessions.sort((a, b) => b.startMs - a.startMs);
    const totalWh = Number.isFinite(Number(raw.totalWh))
      ? Number(raw.totalWh)
      : buckets.reduce((sum, b) => sum + b.wh, 0);
    return {
      range: raw.range || nextRange,
      buckets,
      sessions,
      totalWh: totalWh || 0,
      cost: Number(raw.cost) || 0,
      currency: raw.currency || 'CNY',
    };
  }

  async function doExport(format) {
    if (!ui.ctx || typeof ui.ctx.call !== 'function') {
      ui.toast(ui.t('请在浏览器打开'), 'warn');
      return;
    }
    const btn = format === 'csv' ? exportCsv : exportJson;
    if (btn) btn.disabled = true;
    const out = await callSafe(ui, 'Charker.ExportEnergy', [range, format], '');
    if (disposed) return;
    if (btn) btn.disabled = false;
    if (out && out.__error) {
      const msg = out.__error.message || String(out.__error);
      ui.toast(ui.t('导出失败：%@', msg), 'error');
      return;
    }
    const path = typeof out === 'string' ? out.trim() : '';
    ui.toast(path ? ui.t('已导出到 %@', path) : ui.t('已取消'), path ? 'info' : 'warn');
  }

  // ---- rendering ----------------------------------------------------------

  function syncRangeTabs() {
    if (!refs.rangeButtons) return;
    const idx = Math.max(0, RANGE_DEFS.findIndex((r) => r.value === range));
    rangeSeg.style.setProperty('--i', String(idx));
    refs.rangeButtons.forEach((b, i) => b.setAttribute('aria-selected', String(i === idx)));
  }

  function updateTrendHead() {
    if (!refs.trendHead) return;
    const def = RANGE_DEFS.find((r) => r.value === range);
    const sub = refs.trendHead.querySelector('.sc-cardhead__sub');
    if (sub) txt(sub, ui.t(def.sub));
  }

  function statsForReport() {
    const rep = report || emptyReport(range);
    const ratedW = state && state.app && state.device && String(state.device.product) === 'a2345' ? 250 : 160;
    const peak = rep.sessions.reduce((max, s) => Math.max(max, s.peakW), 0)
      || (state && state.stats && Number(state.stats.peakW)) || 0;
    const hours = ratedW > 0 ? rep.totalWh / ratedW : 0;
    return { rep, peak, hours, ratedW };
  }

  function renderSummary() {
    const { rep, peak, hours } = statsForReport();
    const [ev, eu] = energyParts(rep.totalWh);
    const metrics = summary.querySelectorAll('.sc-metric');
    const [totalM, costM, eqM, peakM] = metrics;
    const [energyValue, energyUnit] = [totalM.querySelector('.sc-metric__value .ck-u-num'), totalM.querySelector('.sc-metric__unit')];
    txt(energyValue, ev);
    txt(energyUnit, eu);
    const costNum = Number(rep.cost) || 0;
    txt(costM.querySelector('.sc-metric__value .ck-u-num'),
      `${currencySymbol(rep.currency)}${(Math.abs(costNum) >= 100 ? costNum.toFixed(0) : costNum.toFixed(2))}`);
    const costUnit = costM.querySelector('.sc-metric__unit');
    if (costUnit) costUnit.textContent = '';
    txt(eqM.querySelector('.sc-metric__value .ck-u-num'), hours >= 100 ? hours.toFixed(0) : hours.toFixed(1));
    txt(eqM.querySelector('.sc-metric__unit'), ui.t('小时'));
    txt(peakM.querySelector('.sc-metric__value .ck-u-num'), peak.toFixed(1));
    txt(peakM.querySelector('.sc-metric__unit'), 'W');
  }

  function updateLegend() {
    if (!refs.legend) return;
    const { rep } = statsForReport();
    const withData = rep.buckets.filter((b) => b.wh > 0);
    const mean = withData.length ? rep.totalWh / withData.length : 0;
    const [mv, mu] = energyParts(mean);
    const label = refs.legend.querySelector('.sc-legend__txt');
    if (label) txt(label, ui.t('均值 %@', `${mv} ${mu}`));
  }

  function renderTrend() {
    if (!refs.trendBody) return;
    const { rep } = statsForReport();
    const hasData = rep.buckets.some((b) => b.wh > 0);
    const existingEmpty = refs.trendBody.querySelector('.sc-empty');
    const existingSkel = refs.trendBody.querySelector('.sc-skel');
    const chartEl = refs.trendBody.querySelector('.sc-chartwrap');
    if (loading && !report) {
      if (existingEmpty) existingEmpty.remove();
      if (chartEl) chartEl.hidden = true;
      if (!existingSkel) refs.trendBody.append(skeleton(5, { height: 30 }));
      return;
    }
    if (existingSkel) existingSkel.remove();
    if (chartEl) chartEl.hidden = !hasData;
    if (!hasData) {
      if (!existingEmpty) {
        refs.trendBody.append(emptyState(ui, {
          icon: 'line-chart',
          title: ui.t('该时段还没有能耗记录'),
          detail: ui.t('连接充电器后开始记录。'),
          compact: true,
        }));
      }
      return;
    }
    if (existingEmpty) existingEmpty.remove();
    updateLegend();
    drawChart();
  }

  function renderAll() {
    syncRangeTabs();
    updateTrendHead();
    renderSummary();
    renderTrend();
    updateLedger();
  }

  // ---- ledger -------------------------------------------------------------

  function updateLedger() {
    if (!refs.ledgerBody) return;
    const rep = report || emptyReport(range);
    const count = rep.sessions.length;
    const head = refs.ledgerHead;
    let chip = head && head.querySelector('.ck-chip');
    if (head && !chip) {
      const row = head.querySelector('.sc-cardhead__row');
      if (row) {
        chip = h('span', { class: 'ck-chip ck-chip--neutral sc-chip', hidden: true });
        row.append(chip);
      }
    }
    if (chip) {
      if (count > 0) {
        chip.hidden = false;
        txt(chip, ui.t('%d 段', count));
      } else {
        chip.hidden = true;
      }
    }
    clear(refs.ledgerBody);
    if (loading && !report) {
      refs.ledgerBody.append(skeleton(4, { height: 34 }));
      return;
    }
    if (failed) {
      refs.ledgerBody.append(notice(ui, 'error', ui.t('无法读取能耗数据。'),
        { action: actionButton(ui, ui.t('重试'), { tone: 'quiet', onclick: () => load(range), title: ui.t('重试') }) }));
      return;
    }
    if (!count) {
      refs.ledgerBody.append(emptyState(ui, {
        icon: 'archive',
        title: ui.t('该时段还没有能耗记录'),
        detail: ui.t('连接充电器后开始记录。'),
        compact: true,
      }));
      return;
    }

    const shown = rep.sessions.slice(0, expanded);
    const groups = new Map();
    for (const session of shown) {
      const key = dayKey(session.startMs);
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(session);
    }
    for (const [, sessions] of groups) {
      const dayCard = h('div', { class: 'sc-day__group' });
      for (const session of sessions) dayCard.append(sessionRow(session));
      refs.ledgerBody.append(h('div', { class: 'sc-day' },
        h('div', { class: 'sc-day__label' },
          h('span', { text: dayLabel(ui, sessions[0].startMs) }),
          h('span', { text: ui.t('%d 段', sessions.length) })),
        dayCard));
    }
    if (rep.sessions.length > shown.length) {
      refs.ledgerBody.append(h('div', { class: 'sc-ledger__more' },
        actionButton(ui, ui.t('显示更多'), { tone: 'quiet', onclick: () => { expanded += PAGE_SIZE; updateLedger(); } })));
    }
  }

  function sessionRow(session) {
    const now = Date.now();
    const live = !session.endMs || session.endMs > now - 60_000;
    const endMs = session.endMs || now;
    const badge = h('span', { class: `sc-session__badge${live ? ' sc-session__badge--live' : ''}` },
      ui.el(live ? 'bolt' : 'clock', 11));
    const rangeText = session.endMs
      ? `${timeText(ui.locale, session.startMs)} – ${timeText(ui.locale, session.endMs)}`
      : timeText(ui.locale, session.startMs);
    const [ev, eu] = energyParts(session.wh);
    const rowEl = h('div', { class: 'sc-session' },
      h('div', { class: 'sc-session__id' },
        badge,
        h('div', { class: 'sc-session__times' },
          h('div', { class: 'sc-session__range' },
            h('span', { text: rangeText }),
            live ? h('span', { class: 'ck-chip ck-chip--accent', text: ui.t('进行中') }) : null),
          h('span', { class: 'sc-session__day ck-t-micro', text: dayLabel(ui, session.startMs) }))),
      h('span', { class: 'sc-session__cell', text: durationText(ui, endMs - session.startMs) }),
      h('span', { class: 'sc-session__cell sc-session__cell--end' },
        h('span', { class: 'ck-u-num', text: ev }), h('span', { class: 'sc-session__unit', text: eu })),
      h('span', { class: 'sc-session__cell sc-session__cell--end' },
        h('span', { class: 'ck-u-num', text: session.peakW.toFixed(1) }), h('span', { class: 'sc-session__unit', text: 'W' })));
    return rowEl;
  }

  // ---- chart --------------------------------------------------------------

  function themeColors() {
    const cs = getComputedStyle(document.documentElement);
    const pick = (name, fallback) => (cs.getPropertyValue(name) || '').trim() || fallback;
    return {
      accent: pick('--ck-accent', '#00A7E1'),
      accentDim: pick('--ck-accent-dim', '#006F97'),
      grid: pick('--ck-stroke', '#2A2E37'),
      text3: pick('--ck-text-3', '#7B8494'),
      text2: pick('--ck-text-2', '#9AA3B2'),
    };
  }

  function chartGeometry() {
    const canvas = refs.canvas;
    const wrap = refs.chart;
    if (!canvas || !wrap) return null;
    const rect = wrap.getBoundingClientRect();
    const w = Math.max(160, Math.round(rect.width));
    const hgt = Math.max(120, Math.round(rect.height));
    const plot = { x: 46, y: 14, w: w - 46 - 14, h: hgt - 14 - 22 };
    return { canvas, w, hgt, plot, dpr: Math.min(2.5, window.devicePixelRatio || 1) };
  }

  function drawChart() {
    const geo = chartGeometry();
    if (!geo || !refs.canvas) return;
    const { canvas, w, hgt, plot, dpr } = geo;
    if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(hgt * dpr)) {
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(hgt * dpr);
    }
    const ctx2d = canvas.getContext('2d');
    if (!ctx2d) return;
    ctx2d.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx2d.clearRect(0, 0, w, hgt);
    const colors = themeColors();
    const rep = report || emptyReport(range);
    const buckets = rep.buckets;
    if (!buckets.length) return;

    const values = buckets.map((b) => b.wh);
    const maxWh = Math.max(...values, 0.001);
    const step = niceStep(maxWh / 3.2);
    const yMax = Math.max(step * 3, Math.ceil(maxWh / step) * step);
    const yTicks = [];
    for (let v = 0; v <= yMax + 1e-9; v += step) yTicks.push(v);

    // Horizontal grid + leading labels (unit on the top tick only).
    ctx2d.font = '9px ' + (getComputedStyle(document.documentElement).getPropertyValue('--ck-font-num') || 'Segoe UI');
    ctx2d.textAlign = 'right';
    ctx2d.textBaseline = 'middle';
    for (const tick of yTicks) {
      const y = plot.y + plot.h - (tick / yMax) * plot.h;
      ctx2d.strokeStyle = colors.grid;
      ctx2d.globalAlpha = 0.7;
      ctx2d.lineWidth = 1;
      ctx2d.beginPath();
      ctx2d.moveTo(plot.x, Math.round(y) + 0.5);
      ctx2d.lineTo(plot.x + plot.w, Math.round(y) + 0.5);
      ctx2d.stroke();
      ctx2d.globalAlpha = 1;
      ctx2d.fillStyle = colors.text3;
      const [tv, tu] = energyParts(tick);
      const isTop = tick === yTicks[yTicks.length - 1];
      ctx2d.fillText(isTop ? `${tv} ${tu}` : tv, plot.x - 8, y);
    }

    // Bars.
    const n = buckets.length;
    const slot = plot.w / n;
    const barW = clamp(slot * 0.62, 2, 28);
    const grad = ctx2d.createLinearGradient(0, plot.y + plot.h, 0, plot.y);
    grad.addColorStop(0, withAlpha(colors.accentDim, 0.76));
    grad.addColorStop(1, colors.accent);
    ctx2d.fillStyle = grad;
    for (let i = 0; i < n; i++) {
      const value = values[i];
      const barH = value <= 0 ? 0 : Math.max(2, (value / yMax) * plot.h);
      const x = plot.x + i * slot + (slot - barW) / 2;
      const y = plot.y + plot.h - barH;
      ctx2d.globalAlpha = hoverIndex < 0 || hoverIndex === i ? 1 : 0.38;
      if (barH > 0) roundRect(ctx2d, x, y, barW, barH, Math.min(4, barW / 2));
      ctx2d.fill();
    }
    ctx2d.globalAlpha = 1;

    // Mean rule.
    const withData = values.filter((v) => v > 0);
    if (withData.length) {
      const mean = withData.reduce((a, b) => a + b, 0) / withData.length;
      const my = plot.y + plot.h - (mean / yMax) * plot.h;
      ctx2d.save();
      ctx2d.strokeStyle = colors.text3;
      ctx2d.globalAlpha = 0.58;
      ctx2d.lineWidth = 1;
      ctx2d.setLineDash([4, 4]);
      ctx2d.beginPath();
      ctx2d.moveTo(plot.x, Math.round(my) + 0.5);
      ctx2d.lineTo(plot.x + plot.w, Math.round(my) + 0.5);
      ctx2d.stroke();
      ctx2d.restore();
    }

    // X labels: evenly spaced, skipping overlaps.
    const wanted = X_LABELS[range] || 5;
    const stride = Math.max(1, Math.ceil(n / wanted));
    ctx2d.fillStyle = colors.text3;
    ctx2d.textAlign = 'center';
    ctx2d.textBaseline = 'top';
    let lastRight = -Infinity;
    for (let i = 0; i < n; i += stride) {
      const label = bucketLabel(ui, buckets[i].t, range);
      const cx = plot.x + i * slot + slot / 2;
      const tw = ctx2d.measureText(label).width;
      if (cx - tw / 2 < lastRight + 6) continue;
      ctx2d.fillText(label, cx, plot.y + plot.h + 7);
      lastRight = cx + tw / 2;
    }
  }

  function withAlpha(color, alpha) {
    if (!color) return `rgba(0,167,225,${alpha})`;
    if (color.startsWith('#')) {
      const hex = color.length === 4
        ? `#${color[1]}${color[1]}${color[2]}${color[2]}${color[3]}${color[3]}`
        : color;
      const r = parseInt(hex.slice(1, 3), 16);
      const g = parseInt(hex.slice(3, 5), 16);
      const b = parseInt(hex.slice(5, 7), 16);
      return `rgba(${r},${g},${b},${alpha})`;
    }
    return color;
  }

  function roundRect(ctx2d, x, y, w, hgt, r) {
    const rr = Math.min(r, w / 2, hgt / 2);
    ctx2d.beginPath();
    ctx2d.moveTo(x + rr, y);
    ctx2d.arcTo(x + w, y, x + w, y + hgt, rr);
    ctx2d.arcTo(x + w, y + hgt, x, y + hgt, rr);
    ctx2d.arcTo(x, y + hgt, x, y, rr);
    ctx2d.arcTo(x, y, x + w, y, rr);
    ctx2d.closePath();
  }

  function onChartMove(ev) {
    if (!refs.chart) return;
    const rep = report || emptyReport(range);
    if (!rep.buckets.length) return;
    const rect = refs.chart.getBoundingClientRect();
    const geo = chartGeometry();
    if (!geo) return;
    const x = ev.clientX - rect.left;
    const { plot } = geo;
    if (x < plot.x || x > plot.x + plot.w) { hideTip(); if (hoverIndex !== -1) { hoverIndex = -1; drawChart(); } return; }
    const i = clamp(Math.floor(((x - plot.x) / plot.w) * rep.buckets.length), 0, rep.buckets.length - 1);
    if (i === hoverIndex) return;
    hoverIndex = i;
    drawChart();
    showTip(i, rect, geo);
  }

  function showTip(index, rect, geo) {
    const rep = report || emptyReport(range);
    if (!refs.tip || !refs.chart) return;
    const bucket = rep.buckets[index];
    if (!bucket) return;
    const { plot } = geo;
    const slot = plot.w / rep.buckets.length;
    const cx = plot.x + index * slot + slot / 2;
    const maxWh = Math.max(...rep.buckets.map((b) => b.wh), 0.001);
    const step = niceStep(maxWh / 3.2);
    const yMax = Math.max(step * 3, Math.ceil(maxWh / step) * step);
    const cy = plot.y + plot.h - (bucket.wh / yMax) * plot.h;
    const [ev, eu] = energyParts(bucket.wh);
    const main = refs.tip.querySelector('.sc-chart__tip-main .ck-u-num');
    const unit = refs.tip.querySelector('.sc-chart__tip-unit');
    txt(main, ev);
    txt(unit, eu);
    txt(refs.tip.querySelector('.sc-chart__tip-caption'),
      range === 'week' || range === 'month'
        ? bucketLabel(ui, bucket.t, range)
        : timeText(ui.locale, bucket.t));
    refs.tip.hidden = false;
    const chartRect = refs.chart.getBoundingClientRect();
    const left = clamp(cx, 56, chartRect.width - 56);
    refs.tip.style.left = `${left}px`;
    refs.tip.style.top = `${Math.max(34, cy)}px`;
  }

  function hideTip() {
    if (refs.tip) refs.tip.hidden = true;
  }

  function niceStep(raw) {
    if (!Number.isFinite(raw) || raw <= 0) return 1;
    const exp = Math.floor(Math.log10(raw));
    const base = Math.pow(10, exp);
    for (const m of [1, 2, 2.5, 5, 10]) {
      if (raw <= m * base) return m * base;
    }
    return 10 * base;
  }

  // ---- lifecycle ----------------------------------------------------------

  function update(nextUi, nextState) {
    if (disposed) return;
    const localeChanged = builtLocale !== nextUi.locale;
    ui = nextUi;
    state = nextState;
    if (localeChanged || !refs.canvas) {
      build(ui);
      if (reportRange === range && report) {
        renderAll();
      } else {
        load(range);
      }
      return;
    }
    // Fresh data from the shell's cheap cache before the detailed report lands.
    if (!report && state && state.energy) syncFromCache();
    renderAll();
  }

  function syncFromCache() {
    const cached = state.energy && state.energy[range];
    if (!cached) return;
    report = {
      range,
      buckets: [],
      sessions: [],
      totalWh: Number(cached.wh) || 0,
      cost: Number(cached.cost) || 0,
      currency: cached.currency || 'CNY',
    };
    reportRange = range;
  }

  function dispose() {
    if (disposed) return;
    disposed = true;
    if (refs.ro) { refs.ro.disconnect(); refs.ro = null; }
    hideTip();
    instances.delete(inst);
  }

  const inst = {
    update,
    dispose,
    get screen() { return screen; },
  };
  return inst;
}
