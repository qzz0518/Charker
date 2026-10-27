// ============================================================================
// Charker — dashboard power timeline (owner: web-overview)
//
// Dependency-free canvas chart, spec-ui §2.6 / §3.14:
//   · well is a DOM surface (.ck-chart__well); everything inside is canvas ink
//   · 16 px vertical grid, 1 px horizontal grid at 0 / ½ / max watts
//   · monotone area + line, accent 1.5 px, last-point dot
//   · hover: dashed crosshair, 7 px dot and a DOM bubble (ck-tip) that flips
//     left/right and clamps inside the plot
//   · y labels ride the trailing edge (top tick carries the unit), x label is
//     the elapsed span centred under the plot (shipped screenshot's look)
//   · DPR-aware (canvas backing store = css px × min(dpr, 2))
//
// Public API:
//   const chart = createChart(hostEl)   // host = .ck-chart
//   chart.update(state)                 // { history, totals }
//   chart.setSelected(index | null)     // port selection (adds dashed series
//                                       // when the snapshot carries perPort)
//   chart.dispose()
// ============================================================================

const NUM_FALLBACK = '"Segoe UI Variable Display", "Segoe UI", "SF Pro Rounded", ui-rounded, system-ui, sans-serif';
const UI_FALLBACK = '"Segoe UI Variable Text", "Segoe UI", system-ui, "Microsoft YaHei UI", sans-serif';

const Y_GUTTER = 36; // trailing axis label column (css px)
const X_GUTTER = 15; // x caption strip inside the plot (css px)
const GRID_STEP = 16; // vertical grid spacing (spec §7.5: 16 px divisions)
const TIP_GAP = 12; // bubble sits 12 px above the point

function finite(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function reduceMotion() {
  try {
    return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  } catch (_) {
    return false;
  }
}

/** mm:ss, or h:mm:ss once the span passes an hour. */
function elapsedText(ms) {
  const total = Math.max(0, Math.round(ms / 1000));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  if (hours > 0) {
    return `${hours}:${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`;
  }
  return `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`;
}

function smoothEaseOut(p) {
  return 1 - (1 - p) * (1 - p) * (1 - p);
}

/** Normalize history into ascending {t, w} samples (never mutates input). */
function buildSamples(history) {
  const out = [];
  if (!Array.isArray(history)) return out;
  for (let i = 0; i < history.length; i += 1) {
    const raw = history[i];
    if (!raw || typeof raw !== 'object') continue;
    const t = finite(raw.t);
    const w = finite(raw.w != null ? raw.w : raw.total);
    if (t == null || w == null) continue;
    out.push({ t, w: w < 0 ? 0 : w, perPort: Array.isArray(raw.perPort) ? raw.perPort : null });
  }
  out.sort((a, b) => a.t - b.t);
  return out;
}

/**
 * Stable axis maximum: the rated limit (160 W for the A2687), promoted only when
 * a real reading exceeds it — spec §3.9 "the ceiling is always 160 W".
 */
function ceilingFor(peak, limit) {
  let max = Math.max(1, Math.round(limit || 160));
  const need = peak * 1.15;
  if (need > max) max = Math.ceil(need / 50) * 50;
  return max;
}

export function createChart(host) {
  if (!host) throw new Error('createChart: host required');

  const tip = host.querySelector('.ck-tip') || document.createElement('div');
  if (!tip.parentNode) {
    tip.className = 'ck-tip';
    tip.innerHTML = '<span class="ck-tip__head"></span><span class="ck-tip__detail"></span><span class="ck-tip__cap"></span>';
    host.append(tip);
  }
  const tipHead = tip.querySelector('.ck-tip__head');
  const tipDetail = tip.querySelector('.ck-tip__detail');
  const tipCap = tip.querySelector('.ck-tip__cap');
  tip.hidden = true;

  const well = host.querySelector('.ck-chart__well') || host;
  const plot = host.querySelector('.ck-chart__plot') || well;
  const canvas = document.createElement('canvas');
  canvas.className = 'ck-chart__canvas';
  canvas.setAttribute('aria-hidden', 'true');
  plot.append(canvas);
  const ctx = canvas.getContext('2d');

  // ---- state -------------------------------------------------------------
  let state = null;
  let samples = [];
  let xs = new Float32Array(0);
  let ys = new Float32Array(0);
  let limit = 160;
  let ceiling = 168;
  let ticks = [0, 80, 160];
  let selected = null;
  let hoverIndex = -1;
  let reveal = 0;
  let revealStart = 0;
  let revealRaf = 0;
  let width = 0;
  let height = 0;
  let dpr = 1;
  let colors = null;
  let reduced = reduceMotion();
  let disposed = false;

  // ---- css helpers -------------------------------------------------------
  function readColors(force) {
    if (colors && !force) return colors;
    const cs = getComputedStyle(host);
    const get = (name, fallback) => {
      const v = cs.getPropertyValue(name);
      return v && v.trim() ? v.trim() : fallback;
    };
    colors = {
      accent: get('--ck-accent', '#00A7E1'),
      accentDim: get('--ck-accent-dim', '#006F97'),
      stroke: get('--ck-stroke', '#2A2E37'),
      text2: get('--ck-text-2', '#9AA3B2'),
      text3: get('--ck-text-3', '#7B8494'),
      numFont: get('--ck-font-num', NUM_FALLBACK),
      uiFont: get('--ck-font-ui', UI_FALLBACK),
    };
    return colors;
  }

  function cssPx(value, fallback) {
    const n = parseFloat(value);
    return Number.isFinite(n) ? n : fallback;
  }

  // ---- layout ------------------------------------------------------------
  function resize() {
    if (disposed) return;
    const rect = plot.getBoundingClientRect();
    width = Math.max(0, Math.round(rect.width));
    height = Math.max(0, Math.round(rect.height));
    if (width < 8 || height < 8) return;
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = Math.round(width * dpr);
    canvas.height = Math.round(height * dpr);
    canvas.style.width = `${width}px`;
    canvas.style.height = `${height}px`;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    readColors(true);
    draw();
  }

  // ---- geometry ----------------------------------------------------------
  function plotRect() {
    return {
      left: 0,
      right: Math.max(8, width - Y_GUTTER),
      top: 0,
      bottom: Math.max(24, height - X_GUTTER),
    };
  }

  function yFor(w, rect) {
    const span = ceiling * 1.05;
    return rect.bottom - (w / span) * (rect.bottom - rect.top);
  }

  // ---- monotone interpolation (Fritsch–Carlson, matches Swift Charts) ----
  // Fills xs/ys (screen space) and returns the open line path plus the closed
  // area path, so the fill and the stroke share exactly the same curve.
  function buildSeriesPaths(rect) {
    const n = samples.length;
    const line = new Path2D();
    const area = new Path2D();
    if (n === 0) return { line, area };
    const x0 = rect.left;
    const x1 = rect.right;
    const t0 = samples[0].t;
    const span = samples[n - 1].t - t0 || 1;

    if (n === 1) {
      const x = (x0 + x1) / 2;
      const y = yFor(samples[0].w, rect);
      xs[0] = x;
      ys[0] = y;
      line.moveTo(x, y);
      line.lineTo(x, y);
      area.moveTo(x, y);
      area.lineTo(x, rect.bottom);
      area.lineTo(x, rect.bottom);
      area.closePath();
      return { line, area };
    }

    // segment widths and secant slopes
    const slope = new Float32Array(n);
    const h = new Float32Array(n - 1);
    for (let i = 0; i < n - 1; i += 1) {
      h[i] = Math.max(1e-6, (samples[i + 1].t - samples[i].t) / span);
      slope[i] = (samples[i + 1].w - samples[i].w) / h[i];
    }
    for (let i = 1; i < n - 1; i += 1) {
      if (slope[i - 1] * slope[i] <= 0) {
        slope[i] = 0;
      } else {
        const w1 = 2 * h[i] + h[i - 1];
        const w2 = h[i] + 2 * h[i - 1];
        slope[i] = (w1 + w2) / (w1 / slope[i - 1] + w2 / slope[i]);
      }
    }
    slope[n - 1] = slope[n - 2] || 0;

    for (let i = 0; i < n; i += 1) {
      xs[i] = x0 + ((samples[i].t - t0) / span) * (x1 - x0);
      ys[i] = yFor(samples[i].w, rect);
    }

    line.moveTo(xs[0], ys[0]);
    area.moveTo(xs[0], ys[0]);
    for (let i = 0; i < n - 1; i += 1) {
      const dx = (xs[i + 1] - xs[i]) / 3;
      const c1x = xs[i] + dx;
      const c1y = ys[i] + slope[i] * dx;
      const c2x = xs[i + 1] - dx;
      const c2y = ys[i + 1] - slope[i + 1] * dx;
      line.bezierCurveTo(c1x, c1y, c2x, c2y, xs[i + 1], ys[i + 1]);
      area.bezierCurveTo(c1x, c1y, c2x, c2y, xs[i + 1], ys[i + 1]);
    }
    area.lineTo(xs[n - 1], rect.bottom);
    area.lineTo(xs[0], rect.bottom);
    area.closePath();
    return { line, area };
  }

  // ---- drawing -----------------------------------------------------------
  function align(v) {
    // crisp hairlines: snap to the device-pixel grid
    return Math.round(v * dpr) / dpr;
  }

  function drawEmpty() {
    const c = readColors();
    ctx.clearRect(0, 0, width, height);
    ctx.fillStyle = c.text3;
    ctx.font = `400 11px ${c.uiFont}`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    const message = host.dataset.emptyText || '';
    if (message) ctx.fillText(message, width / 2, (height - X_GUTTER) / 2);
  }

  function draw() {
    if (disposed || !ctx || width < 8 || height < 8) return;
    const c = readColors();
    ctx.clearRect(0, 0, width, height);
    if (!samples.length) {
      drawEmpty();
      return;
    }

    const rect = plotRect();
    const plotW = rect.right - rect.left;
    const plotH = rect.bottom - rect.top;

    // ---- vertical grid (16 px divisions, stroke @ .48, 1 device px) ------
    const divisions = Math.max(2, Math.round(plotW / GRID_STEP));
    ctx.save();
    ctx.globalAlpha = 0.48;
    ctx.fillStyle = c.stroke;
    for (let i = 1; i < divisions; i += 1) {
      const x = align(rect.left + (plotW / divisions) * i);
      ctx.fillRect(x, rect.top, 1 / dpr, plotH);
    }
    ctx.restore();

    // ---- horizontal grid at labelled ticks (usually 0 / 80 / 160) -------
    ctx.fillStyle = c.stroke;
    for (let i = 0; i < ticks.length; i += 1) {
      const y = align(yFor(ticks[i], rect));
      ctx.fillRect(rect.left, y, plotW, 1 / dpr);
    }

    // ---- series ---------------------------------------------------------
    if (!xs.length || xs.length !== samples.length) {
      xs = new Float32Array(samples.length);
      ys = new Float32Array(samples.length);
    }
    const paths = buildSeriesPaths(rect);

    const revealed = reveal >= 1 || reduced;
    if (!revealed) {
      const clipW = plotW * reveal;
      ctx.save();
      ctx.beginPath();
      ctx.rect(rect.left, rect.top - 2, clipW, plotH + 4);
      ctx.clip();
    }

    // area fill accent .30 → .02
    const areaGrad = ctx.createLinearGradient(0, rect.top, 0, rect.bottom);
    areaGrad.addColorStop(0, hexWithAlpha(c.accent, 0.3));
    areaGrad.addColorStop(1, hexWithAlpha(c.accent, 0.02));
    ctx.fillStyle = areaGrad;
    ctx.fill(paths.area);

    // total line
    ctx.strokeStyle = c.accent;
    ctx.lineWidth = 1.5;
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';
    ctx.stroke(paths.line);

    if (!revealed) ctx.restore();

    // peak marker (quiet 2 px dot, only when the peak is not the last sample)
    let peakIndex = 0;
    for (let i = 1; i < samples.length; i += 1) {
      if (samples[i].w > samples[peakIndex].w) peakIndex = i;
    }
    if (peakIndex < samples.length - 1 && samples[peakIndex].w > 0.5) {
      ctx.beginPath();
      ctx.arc(xs[peakIndex], ys[peakIndex], 2, 0, Math.PI * 2);
      ctx.fillStyle = hexWithAlpha(c.accentDim, 0.9);
      ctx.fill();
    }

    // last point dot (Ø ≈ 6 px)
    const last = samples.length - 1;
    ctx.beginPath();
    ctx.arc(xs[last], ys[last], 3, 0, Math.PI * 2);
    ctx.fillStyle = c.accent;
    ctx.fill();

    // ---- axis labels ----------------------------------------------------
    ctx.font = `500 10px ${c.numFont}`;
    ctx.fillStyle = c.text3;
    ctx.textAlign = 'right';
    ctx.textBaseline = 'middle';
    const labelX = width - 1;
    for (let i = 0; i < ticks.length; i += 1) {
      const value = ticks[i];
      const text = value === ceiling ? `${value} W` : String(value);
      ctx.fillText(text, labelX, yFor(value, rect));
    }

    // elapsed span caption, centred under the plot (shipped screenshot look)
    const span = samples[samples.length - 1].t - samples[0].t;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'top';
    ctx.fillStyle = c.text3;
    ctx.fillText(elapsedText(span), rect.left + plotW / 2, rect.bottom + 5);

    // selected port's own curve (dashed) when the snapshot carries perPort
    if (selected != null && samples[0].perPort) drawSelectedSeries(rect, plotW);

    // ---- hover crosshair + dot -----------------------------------------
    if (hoverIndex >= 0 && hoverIndex < samples.length) {
      const hx = align(xs[hoverIndex]);
      const hy = ys[hoverIndex];
      ctx.save();
      ctx.setLineDash([3, 3]);
      ctx.strokeStyle = hexWithAlpha(c.text2, 0.72);
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(hx + 0.5, rect.top);
      ctx.lineTo(hx + 0.5, rect.bottom);
      ctx.stroke();
      ctx.restore();
      ctx.beginPath();
      ctx.arc(hx, hy, 3.5, 0, Math.PI * 2);
      ctx.fillStyle = c.accent;
      ctx.fill();
    }
  }

  function drawSelectedSeries(rect, plotW) {
    if (selected == null) return;
    const c = readColors();
    ctx.save();
    ctx.setLineDash([3, 3]);
    ctx.strokeStyle = c.accentDim;
    ctx.lineWidth = 1;
    ctx.beginPath();
    const span = samples[samples.length - 1].t - samples[0].t || 1;
    const t0 = samples[0].t;
    let started = false;
    for (let i = 0; i < samples.length; i += 1) {
      const v = samples[i].perPort ? finite(samples[i].perPort[selected]) : null;
      if (v == null) continue;
      const x = rect.left + ((samples[i].t - t0) / span) * plotW;
      const y = yFor(v, rect);
      if (!started) {
        ctx.moveTo(x, y);
        started = true;
      } else {
        ctx.lineTo(x, y);
      }
    }
    if (started) ctx.stroke();
    ctx.restore();
  }

  function hexWithAlpha(color, alpha) {
    const value = String(color).trim();
    if (value.startsWith('#') && (value.length === 7 || value.length === 4)) {
      let hex = value.slice(1);
      if (hex.length === 3) hex = hex.replace(/./g, (ch) => ch + ch);
      const r = parseInt(hex.slice(0, 2), 16);
      const g = parseInt(hex.slice(2, 4), 16);
      const b = parseInt(hex.slice(4, 6), 16);
      return `rgba(${r}, ${g}, ${b}, ${alpha})`;
    }
    if (value.startsWith('rgb')) return value.replace(/\)$/, `, ${alpha})`).replace('rgb(', 'rgba(');
    return value;
  }

  // ---- reveal ------------------------------------------------------------
  function startReveal() {
    if (revealRaf) cancelAnimationFrame(revealRaf);
    if (reduced) {
      reveal = 1;
      return;
    }
    reveal = 0;
    revealStart = performance.now();
    const step = (now) => {
      if (disposed) return;
      const p = Math.min(1, (now - revealStart) / 420);
      reveal = smoothEaseOut(p);
      draw();
      if (p < 1) revealRaf = requestAnimationFrame(step);
      else revealRaf = 0;
    };
    revealRaf = requestAnimationFrame(step);
  }

  // ---- hover -------------------------------------------------------------
  function clearHover() {
    if (hoverIndex < 0 && tip.hidden) return;
    hoverIndex = -1;
    tip.hidden = true;
    draw();
  }

  function onPointerMove(event) {
    if (!samples.length || disposed) return;
    const rect = plot.getBoundingClientRect();
    if (!rect.width || !rect.height) return;
    const x = event.clientX - rect.left;
    const y = event.clientY - rect.top;
    const area = plotRect();
    if (
      x < area.left - 8 ||
      x > area.right + Y_GUTTER ||
      y < area.top - 8 ||
      y > area.bottom + X_GUTTER + 8
    ) {
      clearHover();
      return;
    }
    const clampedX = Math.min(area.right, Math.max(area.left, x));
    const fraction = (clampedX - area.left) / Math.max(1, area.right - area.left);
    let index = Math.round(fraction * (samples.length - 1));
    index = Math.max(0, Math.min(samples.length - 1, index));
    if (index !== hoverIndex) {
      hoverIndex = index;
      draw();
    }
    positionTip();
  }

  function positionTip() {
    if (hoverIndex < 0) return;
    const sample = samples[hoverIndex];
    const offset = sample.t - samples[0].t;

    tipHead.textContent = `${sample.w.toFixed(1)} W`;
    let detail = '';
    if (selected != null && sample.perPort) {
      const v = finite(sample.perPort[selected]);
      if (v != null) detail = `${selectedPortLabel()} · ${v.toFixed(1)} W`;
    }
    tipDetail.textContent = detail;
    tipDetail.hidden = !detail;
    tipCap.textContent = elapsedText(offset);
    tip.hidden = false;

    // canvas > plot > host; convert canvas-space point into host-space
    const plotRect = plot.getBoundingClientRect();
    const hostRect = host.getBoundingClientRect();
    const pointX = plotRect.left - hostRect.left + (xs[hoverIndex] || 0);
    const pointY = plotRect.top - hostRect.top + (ys[hoverIndex] || 0);

    const tipRect = tip.getBoundingClientRect();
    let left = pointX - tipRect.width / 2;
    const minLeft = plotRect.left - hostRect.left + 4;
    const maxLeft = plotRect.right - hostRect.left - tipRect.width - 4;
    if (maxLeft > minLeft) left = Math.min(maxLeft, Math.max(minLeft, left));
    let top = pointY - tipRect.height - TIP_GAP;
    if (top < 4) top = pointY + TIP_GAP;
    tip.style.left = `${Math.round(left)}px`;
    tip.style.top = `${Math.round(top)}px`;
    tip.dataset.side = left + tipRect.width / 2 < pointX ? 'left' : 'right';
  }

  function selectedPortLabel() {
    return `C${Number(selected) + 1}`;
  }

  // ---- public update -----------------------------------------------------
  function update(nextState) {
    if (disposed) return;
    state = nextState || null;
    samples = buildSamples(state && state.history);
    limit = (state && state.totals && finite(state.totals.limit)) || 160;
    let peak = 0;
    for (let i = 0; i < samples.length; i += 1) if (samples[i].w > peak) peak = samples[i].w;
    ceiling = ceilingFor(peak, limit);
    ticks = [0, Math.round(ceiling / 2), ceiling];
    xs = new Float32Array(samples.length);
    ys = new Float32Array(samples.length);
    readColors(true);
    if (hoverIndex >= samples.length) hoverIndex = -1;
    if (!samples.length) {
      reveal = 0;
      tip.hidden = true;
      draw();
      return;
    }
    if (reveal < 1 && !revealRaf) {
      startReveal();
      return;
    }
    draw();
  }

  function setSelected(index) {
    const next = index == null ? null : Number(index);
    if (selected === next) return;
    selected = next;
    draw();
  }

  function setEmptyText(accumulating, connected) {
    host.dataset.accumulatingText = accumulating || '';
    host.dataset.emptyText = connected || '';
    if (!samples.length) draw();
  }

  // ---- wiring ------------------------------------------------------------
  const ro = typeof ResizeObserver !== 'undefined' ? new ResizeObserver(() => resize()) : null;
  if (ro) ro.observe(plot);
  window.addEventListener('resize', resize);
  plot.addEventListener('pointermove', onPointerMove);
  plot.addEventListener('pointerleave', clearHover);
  const mq = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : null;
  const onMotionChange = () => {
    reduced = reduceMotion();
    if (reduced) reveal = 1;
    draw();
  };
  if (mq) {
    if (typeof mq.addEventListener === 'function') mq.addEventListener('change', onMotionChange);
    else if (typeof mq.addListener === 'function') mq.addListener(onMotionChange);
  }

  resize();

  return {
    update,
    setSelected,
    setEmptyText,
    resize,
    getSamples: () => samples,
    dispose() {
      disposed = true;
      if (revealRaf) cancelAnimationFrame(revealRaf);
      revealRaf = 0;
      if (ro) ro.disconnect();
      window.removeEventListener('resize', resize);
      plot.removeEventListener('pointermove', onPointerMove);
      plot.removeEventListener('pointerleave', clearHover);
      if (mq) {
        if (typeof mq.removeEventListener === 'function') mq.removeEventListener('change', onMotionChange);
        else if (typeof mq.removeListener === 'function') mq.removeListener(onMotionChange);
      }
      canvas.remove();
      tip.remove();
    },
  };
}

export default createChart;
