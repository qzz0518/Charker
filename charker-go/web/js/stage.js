// ============================================================================
// Charker — A2687 three.js stage (owner: web-overview)
//
// Reproduces Charker's SceneKit "digital twin" with the vendored three.js build
// (spec-ui §4). Everything is lazy + fail-soft: a missing WebGL context, a
// failed Draco decode or a 404 all end in the static product render with the
// live port badges, never in a broken page.
//
// Public API (called by js/screens/overview.js):
//   const stage = createStage(container, {
//     labels: { loading, unavailable, reload },
//     icon(name) -> svg string,
//     readHomePose() -> {theta, phi, distance} | null,
//     writeHomePose(pose) -> void,
//     theme() -> 'dark' | 'light',
//     disabled: boolean,          // ?stage=off
//   });
//   stage.update(state)           // port watts / enabled / status
//   stage.setPorts([{label, text, lit}])
//   stage.setSelected(index|null) / setHighlighted(index|null)
//   stage.reset() / saveHome() / restoreHome() / hasHome()
//   stage.dispose()               // real teardown (renderer + GL resources)
//   stage.detach()                // route switch: keep the GPU stage alive
//
// Camera / lighting values are quoted from ChargerSceneMetrics /
// configureLighting in NativeChargerSceneView.swift (spec-ui §4.4–§4.6).
// ============================================================================

const TARGET = { x: 0.0035, y: -0.006, z: 0.001 };
const DEFAULT_POSE = { theta: 16, phi: 55, distance: 0.174 };
const POSE_LIMITS = { minDistance: 0.09, maxDistance: 0.42, minPhi: 8, maxPhi: 172 };
const FOV = 29;
const NEAR = 0.005;
const FAR = 2;
const DRAG_DEG_PER_PX = 0.34;
const WHEEL_K_PRECISE = 0.0065;
const WHEEL_K_LINE = 0.03;
const RESET_MS = 580;
const ENV_INTENSITY = 0.78; // NativeChargerSceneView.swift:596
const MODEL_URL = './assets/models/a2687.glb';
const FALLBACK_IMAGE = './assets/models/a2687-hero.png';
const DRACO_PATH = './vendor/three/draco/gltf/';

// ChargerSceneMetrics.ports, world metres (spec-ui §4.8)
const PORTS = [
  { pos: [0.00556, 0.01091, 0.03208], n: [0.053, 0.003, 0.999] },
  { pos: [0.00564, -0.00128, 0.03211], n: [0.053, 0.003, 0.999] },
  { pos: [0.00597, -0.01396, 0.03214], n: [0.054, 0.004, 0.999] },
];

// ProductStage.swift 2.5D overlay coordinates for the static fallback render.
const FALLBACK_PORTS = [
  { u: 0.75, v: 0.546 },
  { u: 0.736, v: 0.674 },
  { u: 0.733, v: 0.798 },
];

function clamp(value, min, max) {
  return value < min ? min : value > max ? max : value;
}

function deg(rad) {
  return (rad * 180) / Math.PI;
}

function rad(degrees) {
  return (degrees * Math.PI) / 180;
}

function smoothstep5(p) {
  return p * p * p * (p * (p * 6 - 15) + 10);
}

function shortestDelta(target, from) {
  let delta = (target - from) % 360;
  if (delta > 180) delta -= 360;
  if (delta < -180) delta += 360;
  return delta;
}

function reduceMotion() {
  try {
    return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  } catch (_) {
    return false;
  }
}

function webglAvailable() {
  try {
    const canvas = document.createElement('canvas');
    const gl =
      canvas.getContext('webgl2', { failIfMajorPerformanceCaveat: false }) ||
      canvas.getContext('webgl', { failIfMajorPerformanceCaveat: false });
    if (!gl) return false;
    const lose = gl.getExtension('WEBGL_lose_context');
    if (lose) lose.loseContext();
    return true;
  } catch (_) {
    return false;
  }
}

// Debug-only camera overrides for framing comparisons
// (?theta=29.77&phi=64.91&dist=0.174&exposure=0.9). Ignored in normal use.
let DEBUG_PARAMS = null;
function debugParams() {
  if (DEBUG_PARAMS) return DEBUG_PARAMS;
  const out = { theta: NaN, phi: NaN, dist: NaN, exposure: NaN, artlift: NaN };
  try {
    const query = new URLSearchParams(window.location.search);
    const read = (name) => {
      const raw = query.get(name);
      if (raw == null || raw === '') return NaN;
      const value = Number(raw);
      return Number.isFinite(value) ? value : NaN;
    };
    out.theta = read('theta');
    out.phi = read('phi');
    out.dist = read('dist');
    out.exposure = read('exposure');
    out.artlift = read('artlift');
    out.artdebug = query.get('artdebug') === '1';
    out.glassdebug = query.get('glassdebug') || '';
  } catch (_) {
    /* ignore */
  }
  DEBUG_PARAMS = out;
  return out;
}

// ---------------------------------------------------------------------------
// Module singleton: the finished GPU stage survives route changes (§4.13).

const shared = {
  three: null,
  ready: false,
  error: null,
  booted: null,
  renderer: null,
  scene: null,
  camera: null,
  model: null,
  canvas: null,
  screenCanvas: null,
  screenTexture: null,
  screenMaterial: null,
  envTexture: null,
  pmrem: null,
  draco: null,
  active: null,
  disposed: false,
  raf: 0,
  lastFrame: 0,
  lastScreenSig: '',
};

function logOnce(message, error) {
  if (shared.logged === message) return;
  shared.logged = message;
  console.warn(`[charker stage] ${message}`, error || '');
}

// ---------------------------------------------------------------------------
// Screen artwork — spec-ui §4.11 (ANKER / PRIME idle screen). Drawn on a
// 960×400 transparent canvas and blended additively over the black glass; the
// per-port watt row is updated from the live snapshot (§4.11 allows a theme /
// state driven artwork; the wordmark stays the constant identity).

function drawScreenArtwork(canvas, ports, theme) {
  const g = canvas.getContext('2d');
  if (!g) return;
  const w = canvas.width;
  const h = canvas.height;
  g.clearRect(0, 0, w, h);
  const cyan = theme === 'light' ? '#0093C8' : '#00A7E1';
  g.fillStyle = cyan;
  g.textAlign = 'center';
  g.textBaseline = 'middle';

  // ANKER wordmark (fallback text for the vendored wordmark, spec §4.11)
  g.save();
  g.font = '600 52px "Segoe UI Variable Display", "Segoe UI", sans-serif';
  if ('letterSpacing' in g) g.letterSpacing = '1.2px';
  g.fillText('ANKER', w / 2, 202);
  g.restore();

  // PRIME, kern 7
  g.save();
  g.font = '600 29px "Segoe UI Variable Display", "Segoe UI", sans-serif';
  if ('letterSpacing' in g) g.letterSpacing = '7px';
  g.fillText('PRIME', w / 2, 141);
  g.restore();

  // live per-port row (C1…C3 + watts), quiet under the wordmark
  const items = Array.isArray(ports) ? ports.slice(0, 3) : [];
  if (items.length) {
    g.save();
    g.font = '600 21px "Segoe UI Variable Display", "Segoe UI", sans-serif';
    const step = w / 3;
    for (let i = 0; i < items.length; i += 1) {
      const port = items[i] || {};
      const live = port.enabled !== false && Number(port.watts) > 0.05;
      g.globalAlpha = live ? 0.95 : 0.42;
      const watts = Number(port.watts);
      const text = `${port.label || `C${i + 1}`}  ${live ? `${watts.toFixed(1)} W` : '—'}`;
      g.fillText(text, step * (i + 0.5), 330);
    }
    g.restore();
  }
}

// ---------------------------------------------------------------------------
// Environment map — the shipped A2687.hdr is not vendored (§4.2), so the IBL is
// a generated studio-gradient equirect: bright overhead softbox, cool horizon
// and a dark floor. PMREM-filtered exactly like an HDR would be.

function buildEnvironment(THREE, renderer) {
  const canvas = document.createElement('canvas');
  canvas.width = 1024;
  canvas.height = 512;
  const g = canvas.getContext('2d');
  const sky = g.createLinearGradient(0, 0, 0, 512);
  sky.addColorStop(0, '#f4f7fb');
  sky.addColorStop(0.34, '#c9d3df');
  sky.addColorStop(0.5, '#8f9aa9');
  sky.addColorStop(0.62, '#414851');
  sky.addColorStop(1, '#0a0b0e');
  g.fillStyle = sky;
  g.fillRect(0, 0, 1024, 512);

  // key softbox (upper left)
  const key = g.createRadialGradient(300, 90, 8, 300, 90, 360);
  key.addColorStop(0, 'rgba(255,255,255,1)');
  key.addColorStop(0.35, 'rgba(255,255,255,0.72)');
  key.addColorStop(1, 'rgba(255,255,255,0)');
  g.fillStyle = key;
  g.fillRect(0, 0, 1024, 512);

  // cool fill (upper right)
  const fill = g.createRadialGradient(760, 150, 10, 760, 150, 300);
  fill.addColorStop(0, 'rgba(150,190,235,0.85)');
  fill.addColorStop(1, 'rgba(150,190,235,0)');
  g.fillStyle = fill;
  g.fillRect(0, 0, 1024, 512);

  // warm bounce (floor)
  const bounce = g.createRadialGradient(512, 470, 10, 512, 470, 340);
  bounce.addColorStop(0, 'rgba(90,80,70,0.55)');
  bounce.addColorStop(1, 'rgba(90,80,70,0)');
  g.fillStyle = bounce;
  g.fillRect(0, 0, 1024, 512);

  const texture = new THREE.CanvasTexture(canvas);
  texture.mapping = THREE.EquirectangularReflectionMapping;
  texture.colorSpace = THREE.SRGBColorSpace;
  const pmrem = new THREE.PMREMGenerator(renderer);
  pmrem.compileEquirectangularShader();
  const env = pmrem.fromEquirectangular(texture).texture;
  texture.dispose();
  pmrem.dispose();
  return env;
}

// ---------------------------------------------------------------------------
// Model fix-ups — spec-ui §4.6

function fixMaterials(THREE, root) {
  let screen = null;
  let glassDone = false;
  const debug = debugParams();

  root.traverse((node) => {
    if (!node.isMesh) return;
    const materials = Array.isArray(node.material) ? node.material : [node.material];
    const names = materials.map((m) => (m && m.name) || '');

    // top glass: node 51923734 / material A2687_LCD_DECO_COVER_V2…
    // Optically black glass: no diffuse metal, a tight clear-coat highlight and
    // only a restrained environment reflection so the OLED art underneath reads.
    if (!glassDone && names.some((name) => name.includes('A2687_LCD_DECO_COVER'))) {
      if (debug.glassdebug === 'hide') {
        node.visible = false;
      } else if (debug.glassdebug === 'red') {
        node.material = new THREE.MeshBasicMaterial({ color: 0xff0000, side: THREE.DoubleSide });
      } else {
        node.material = new THREE.MeshPhysicalMaterial({
          color: 0x020204,
          roughness: 0.34,
          metalness: 0,
          clearcoat: 0.7,
          clearcoatRoughness: 0.16,
          envMapIntensity: 0.06,
          side: THREE.DoubleSide,
        });
      }
      glassDone = true;
    }

    // screen plane: material name contains the CJK "资源 9@4x" (the GLB stores
    // it in GBK, so match the ASCII tail; the node's scale is the fallback key)
    if (!screen && names.some((name) => name.includes('9@4x'))) {
      screen = node;
    }
  });
  return { screen, glassDone };
}

/*
 * Note on the OLED face: the shipped GLB's screen mesh (material `资源 9@4x`)
 * is the top-most surface of the top glass per raycast, so js/stage.js replaces
 * its material in place with the additive canvas artwork (spec-ui §4.11). The
 * cover glass (51923734) is overridden to optically black glass underneath it.
 */

// ---------------------------------------------------------------------------
// DOM helpers

function element(tag, className, text) {
  const el = document.createElement(tag);
  if (className) el.className = className;
  if (text != null) el.textContent = text;
  return el;
}

function svgIcon(opts, name) {
  try {
    if (typeof opts.icon === 'function') {
      const markup = opts.icon(name);
      if (markup) return markup;
    }
  } catch (_) {
    /* fall through */
  }
  return '';
}

// ---------------------------------------------------------------------------
// ONE controller per mounted stage container. The GPU objects live in `shared`.

function makeController(container, opts) {
  const controller = {
    container,
    opts: opts || {},
    badges: [],
    leaders: [],
    canvas: null,
    hit: null,
    loadingEl: null,
    fallbackEl: null,
    fallbackImg: null,
    ro: null,
    mode: 'idle', // idle | loading | ready | fallback
    width: 0,
    height: 0,
    view: { ...DEFAULT_POSE },
    target: { ...DEFAULT_POSE },
    resetAnim: null,
    damping: false,
    dirty: true,
    selected: null,
    highlighted: null,
    ports: [],
    pointer: null,
    listeners: [],
    disposed: false,
    api: null,
  };

  controller.badges = Array.from(container.querySelectorAll('.ck-stage__badge'));
  controller.leaders = Array.from(container.querySelectorAll('.ck-stage__leaders line'));
  controller.loadingEl = container.querySelector('.ck-stage__loading');
  controller.portRects = [];

  // ---- listeners ---------------------------------------------------------
  function listen(target, type, handler, options) {
    target.addEventListener(type, handler, options);
    controller.listeners.push(() => target.removeEventListener(type, handler, options));
  }

  // ---- DOM scaffolding ---------------------------------------------------
  function scaffold() {
    const canvas = document.createElement('canvas');
    canvas.className = 'ck-stage__canvas';
    const hit = document.createElement('div');
    hit.className = 'ck-stage__hit';
    hit.tabIndex = 0;
    hit.setAttribute('role', 'application');
    hit.setAttribute('aria-label', '3D');
    const leaders = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    leaders.setAttribute('class', 'ck-stage__leaders');
    leaders.setAttribute('aria-hidden', 'true');
    for (let i = 0; i < 3; i += 1) {
      const line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
      line.setAttribute('data-port', String(i));
      leaders.append(line);
    }
    container.prepend(leaders);
    container.prepend(hit);
    container.prepend(canvas);
    controller.canvas = canvas;
    controller.hit = hit;
    controller.leaders = Array.from(leaders.querySelectorAll('line'));
    bindPointer();
  }

  // ---- camera ------------------------------------------------------------
  function applyCamera() {
    const camera = shared.camera;
    if (!camera) return;
    const polar = rad(controller.view.phi);
    const azim = rad(controller.view.theta);
    camera.position.set(
      TARGET.x + controller.view.distance * Math.sin(polar) * Math.sin(azim),
      TARGET.y + controller.view.distance * Math.cos(polar),
      TARGET.z + controller.view.distance * Math.sin(polar) * Math.cos(azim),
    );
    camera.up.set(0, 1, 0);
    camera.lookAt(TARGET.x, TARGET.y, TARGET.z);
    camera.updateMatrixWorld();
  }

  function requestFrame() {
    controller.dirty = true;
    if (!shared.ready || shared.disposed) return;
    if (shared.raf) return;
    const step = (now) => {
      shared.raf = 0;
      const active = shared.active;
      if (!active || active.disposed || !shared.ready) return;
      let animating = false;
      const dt = shared.lastFrame ? Math.min(64, now - shared.lastFrame) : 16;
      shared.lastFrame = now;

      if (active.resetAnim) {
        const p = Math.min(1, (now - active.resetAnim.start) / RESET_MS);
        const e = smoothstep5(p);
        const a = active.resetAnim.from;
        const b = active.resetAnim.to;
        active.view.theta = a.theta + b.dTheta * e;
        active.view.phi = a.phi + (b.phi - a.phi) * e;
        active.view.distance = a.distance + (b.distance - a.distance) * e;
        if (p >= 1) {
          active.view.theta = ((active.target.theta % 360) + 360) % 360;
          active.resetAnim = null;
          active.damping = false;
        } else {
          animating = true;
        }
        active.dirty = true;
      } else if (active.damping) {
        const f = 1 - Math.exp(-dt / 55);
        active.view.theta += (active.target.theta - active.view.theta) * f;
        active.view.phi += (active.target.phi - active.view.phi) * f;
        active.view.distance += (active.target.distance - active.view.distance) * f;
        const dTheta = Math.abs(active.target.theta - active.view.theta);
        const dPhi = Math.abs(active.target.phi - active.view.phi);
        const dDist = Math.abs(active.target.distance - active.view.distance);
        if (dTheta < 0.02 && dPhi < 0.02 && dDist < 0.0002) {
          active.view = { ...active.target };
          active.damping = false;
        } else {
          animating = true;
        }
        active.dirty = true;
      }

      if (active.dirty) {
        active.dirty = false;
        resizeRenderer(active);
        applyCamera();
        if (shared.renderer && shared.scene && shared.camera) {
          shared.renderer.render(shared.scene, shared.camera);
        }
        projectBadges(active);
        window.__charkerReady = true;
        window.__charkerStageError = null;
      }
      if (animating) {
        shared.raf = requestAnimationFrame(step);
      }
    };
    shared.raf = requestAnimationFrame(step);
  }

  // ---- badges / projection ----------------------------------------------
  function facingCamera(port, cameraPosition) {
    const dx = cameraPosition.x - port.pos[0];
    const dy = cameraPosition.y - port.pos[1];
    const dz = cameraPosition.z - port.pos[2];
    const n = port.n;
    return dx * n[0] + dy * n[1] + dz * n[2] > 0;
  }

  function projectBadges(active) {
    const camera = shared.camera;
    const three = shared.three;
    if (!camera || !three) return;
    const width = active.width;
    const height = active.height;
    if (width < 10 || height < 10) return;
    const cameraPosition = camera.position;
    const tmp = new three.Vector3();

    for (let i = 0; i < PORTS.length; i += 1) {
      const badge = active.badges[i];
      if (!badge) continue;
      const port = PORTS[i];
      tmp.set(port.pos[0], port.pos[1], port.pos[2]).project(camera);
      const x = (tmp.x * 0.5 + 0.5) * width;
      const y = (-tmp.y * 0.5 + 0.5) * height;
      const visible =
        facingCamera(port, cameraPosition) &&
        tmp.z >= -1 &&
        tmp.z <= 1 &&
        x >= -40 &&
        x <= width + 40 &&
        y >= -30 &&
        y <= height + 30;
      if (!visible) {
        badge.style.visibility = 'hidden';
        const line = active.leaders[i];
        if (line) line.setAttribute('visibility', 'hidden');
        continue;
      }
      badge.style.visibility = '';
      const bw = active.portRects[i] ? active.portRects[i].w : badge.offsetWidth || 70;
      const bh = active.portRects[i] ? active.portRects[i].h : badge.offsetHeight || 22;
      const idealLeft = x - bw - 8;
      const idealTop = y - bh / 2;
      const left = clamp(idealLeft, 4, Math.max(4, width - bw - 4));
      const top = clamp(idealTop, 4, Math.max(4, height - bh - 4));
      badge.style.transform = `translate3d(${Math.round(left)}px, ${Math.round(top)}px, 0)`;
      badge.dataset.front = 'true';

      // leader line only when the pill had to be pushed away from its anchor
      const line = active.leaders[i];
      if (line) {
        const displaced = Math.abs(left - idealLeft) + Math.abs(top - idealTop) > 1;
        if (displaced) {
          const startX = left > x ? left : left + bw;
          const startY = top + bh / 2;
          line.setAttribute('x1', String(Math.round(startX)));
          line.setAttribute('y1', String(Math.round(startY)));
          line.setAttribute('x2', String(Math.round(x - (left > x ? 3 : -3))));
          line.setAttribute('y2', String(Math.round(y)));
          line.setAttribute('visibility', 'visible');
        } else {
          line.setAttribute('visibility', 'hidden');
        }
      }
    }
  }

  function measureBadges(active) {
    active.portRects = active.badges.map((badge) => {
      if (!badge) return null;
      const w = badge.offsetWidth || 70;
      const h = badge.offsetHeight || 22;
      return { w, h };
    });
  }

  // ---- fallback ----------------------------------------------------------
  function buildFallback(active, reason) {
    if (active.mode === 'fallback') return;
    active.mode = 'fallback';
    window.__charkerStageError = reason || 'unavailable';
    window.__charkerReady = true;
    if (active.loadingEl) active.loadingEl.hidden = true;
    if (active.canvas) active.canvas.style.display = 'none';
    if (active.hit) active.hit.style.display = 'none';
    for (const line of active.leaders) line.setAttribute('visibility', 'hidden');

    const labels = active.opts.labels || {};
    const wrap = element('div', 'ck-stage__fallback');
    const img = element('img', 'ck-stage__fallback-img');
    img.src = FALLBACK_IMAGE;
    img.alt = '';
    img.draggable = false;
    wrap.append(img);
    const text = element('div', 'ck-stage__fallback-text', labels.unavailable || '3D View Unavailable');
    wrap.append(text);
    const button = element('button', 'ck-btn ck-btn--quiet ck-stage__fallback-reload');
    button.type = 'button';
    button.innerHTML = `${svgIcon(active.opts, 'rotate-cw')}<span>${labels.reload || 'Reload'}</span>`;
    button.addEventListener('click', () => {
      wrap.remove();
      active.fallbackEl = null;
      active.fallbackImg = null;
      active.mode = 'idle';
      if (active.canvas) active.canvas.style.display = '';
      if (active.hit) active.hit.style.display = '';
      retry(active);
    });
    wrap.append(button);
    active.container.append(wrap);
    active.fallbackEl = wrap;
    active.fallbackImg = img;
    layoutFallbackBadges(active);
    img.addEventListener('load', () => layoutFallbackBadges(active));
  }

  function layoutFallbackBadges(active) {
    const img = active.fallbackImg;
    if (!img || !active.width) return;
    const stageH = active.height || active.container.clientHeight || 1;
    const imgH = stageH * 0.58;
    const rect = img.getBoundingClientRect();
    const imgW = rect.width || imgH * 1.0;
    const imgLeft = (active.width - imgW) / 2;
    const imgTop = (active.height - imgH) / 2;
    for (let i = 0; i < active.badges.length; i += 1) {
      const badge = active.badges[i];
      if (!badge) continue;
      const p = FALLBACK_PORTS[i] || { u: 0.75, v: 0.6 };
      const x = imgLeft + p.u * imgW;
      const y = imgTop + p.v * imgH;
      const bw = badge.offsetWidth || 70;
      badge.style.visibility = '';
      badge.style.transform = `translate3d(${Math.round(clamp(x - bw - 6, 4, active.width - bw - 4))}px, ${Math.round(y - 11)}px, 0)`;
    }
  }

  // ---- resize ------------------------------------------------------------
  function resizeRenderer(active) {
    const rect = active.container.getBoundingClientRect();
    const w = Math.max(1, Math.round(rect.width));
    const h = Math.max(1, Math.round(rect.height));
    active.width = w;
    active.height = h;
    if (active.mode === 'fallback') {
      layoutFallbackBadges(active);
      return;
    }
    if (!shared.renderer || !shared.camera) return;
    const dpr = Math.min(window.devicePixelRatio || 1, 2.5);
    shared.renderer.setPixelRatio(dpr);
    shared.renderer.setSize(w, h, false);
    if (shared.canvas) {
      shared.canvas.style.width = `${w}px`;
      shared.canvas.style.height = `${h}px`;
    }
    shared.camera.aspect = w / h;
    shared.camera.updateProjectionMatrix();
  }

  function observeResize() {
    if (typeof ResizeObserver !== 'undefined') {
      controller.ro = new ResizeObserver(() => {
        if (controller.disposed) return;
        resizeRenderer(controller);
        requestFrame();
      });
      controller.ro.observe(controller.container);
    }
  }

  // ---- interactions ------------------------------------------------------
  function bindPointer() {
    const hit = controller.hit;
    if (!hit) return;
    let drag = null;

    listen(hit, 'pointerdown', (event) => {
      if (event.button !== 0 && event.pointerType === 'mouse') return;
      drag = { x: event.clientX, y: event.clientY, moved: 0, id: event.pointerId };
      hit.classList.add('is-dragging');
      container.classList.add('is-dragging');
      try {
        hit.setPointerCapture(event.pointerId);
      } catch (_) {
        /* ignore */
      }
      event.preventDefault();
    });

    listen(hit, 'pointermove', (event) => {
      if (!drag || drag.id !== event.pointerId) return;
      const dx = event.clientX - drag.x;
      const dy = event.clientY - drag.y;
      drag.x = event.clientX;
      drag.y = event.clientY;
      drag.moved += Math.abs(dx) + Math.abs(dy);
      controller.target.theta -= dx * DRAG_DEG_PER_PX;
      controller.target.phi = clamp(
        controller.target.phi + dy * DRAG_DEG_PER_PX,
        POSE_LIMITS.minPhi,
        POSE_LIMITS.maxPhi,
      );
      controller.damping = true;
      controller.resetAnim = null;
      requestFrame();
    });

    const endDrag = (event) => {
      if (!drag || drag.id !== event.pointerId) return;
      const wasClick = drag.moved < 3;
      drag = null;
      hit.classList.remove('is-dragging');
      container.classList.remove('is-dragging');
      try {
        hit.releasePointerCapture(event.pointerId);
      } catch (_) {
        /* ignore */
      }
      if (wasClick) pickPort(event);
    };
    listen(hit, 'pointerup', endDrag);
    listen(hit, 'pointercancel', endDrag);

    listen(
      hit,
      'wheel',
      (event) => {
        const pageScrolls = document.documentElement.scrollHeight > window.innerHeight + 4;
        if (pageScrolls && !event.ctrlKey) return;
        event.preventDefault();
        const k = event.deltaMode === 1 ? WHEEL_K_LINE : WHEEL_K_PRECISE;
        controller.target.distance = clamp(
          controller.target.distance * Math.exp(-event.deltaY * k),
          POSE_LIMITS.minDistance,
          POSE_LIMITS.maxDistance,
        );
        controller.damping = true;
        controller.resetAnim = null;
        requestFrame();
      },
      { passive: false },
    );

    listen(hit, 'keydown', (event) => {
      const key = event.key;
      let handled = true;
      if (key === 'ArrowLeft') controller.target.theta += 4;
      else if (key === 'ArrowRight') controller.target.theta -= 4;
      else if (key === 'ArrowUp') controller.target.phi = clamp(controller.target.phi - 4, POSE_LIMITS.minPhi, POSE_LIMITS.maxPhi);
      else if (key === 'ArrowDown') controller.target.phi = clamp(controller.target.phi + 4, POSE_LIMITS.minPhi, POSE_LIMITS.maxPhi);
      else if (key === '+' || key === '=') controller.target.distance = clamp(controller.target.distance / 1.12, POSE_LIMITS.minDistance, POSE_LIMITS.maxDistance);
      else if (key === '-' || key === '_') controller.target.distance = clamp(controller.target.distance * 1.12, POSE_LIMITS.minDistance, POSE_LIMITS.maxDistance);
      else handled = false;
      if (handled) {
        event.preventDefault();
        controller.damping = true;
        controller.resetAnim = null;
        requestFrame();
      }
    });
  }

  function pickPort(event) {
    const three = shared.three;
    const camera = shared.camera;
    if (!three || !camera || controller.mode !== 'ready') return;
    const rect = controller.container.getBoundingClientRect();
    const ndc = new three.Vector2(
      ((event.clientX - rect.left) / rect.width) * 2 - 1,
      -((event.clientY - rect.top) / rect.height) * 2 + 1,
    );
    const raycaster = new three.Raycaster();
    raycaster.setFromCamera(ndc, camera);
    const point = new three.Vector3();
    let best = -1;
    let bestDistance = Infinity;
    for (let i = 0; i < PORTS.length; i += 1) {
      const [px, py, pz] = PORTS[i].pos;
      const box = new three.Box3(
        new three.Vector3(px - 0.016, py - 0.011, pz - 0.012),
        new three.Vector3(px + 0.016, py + 0.011, pz + 0.012),
      );
      if (raycaster.ray.intersectBox(box, point)) {
        const distance = point.distanceToSquared(camera.position);
        if (distance < bestDistance) {
          bestDistance = distance;
          best = i;
        }
      }
    }
    if (best >= 0 && typeof controller.opts.onSelectPort === 'function') {
      controller.opts.onSelectPort(best);
    }
  }

  // ---- shared scene attach ----------------------------------------------
  function attachScene(active) {
    if (active.mode === 'fallback') return;
    active.mode = 'ready';
    if (active.canvas) active.canvas.style.display = '';
    if (active.hit) active.hit.style.display = '';
    if (shared.canvas && shared.canvas !== active.canvas) {
      active.canvas.replaceWith(shared.canvas);
      active.canvas = shared.canvas;
    }
    if (shared.canvas) shared.canvas.style.display = '';
    if (active.loadingEl) active.loadingEl.hidden = true;
    if (active.fallbackEl) {
      active.fallbackEl.remove();
      active.fallbackEl = null;
    }
    const home = readHomePose(active);
    active.view = { ...home };
    active.target = { ...home };
    measureBadges(active);
    setScreenFromPorts(active, active.ports);
    resizeRenderer(active);
    applyCamera();
    requestFrame();
  }

  function readHomePose(active) {
    let pose = null;
    try {
      pose = active.opts.readHomePose ? active.opts.readHomePose() : null;
      if (typeof pose === 'string') pose = JSON.parse(pose);
    } catch (_) {
      pose = null;
    }
    let resolved;
    if (pose && Number.isFinite(pose.theta) && Number.isFinite(pose.phi) && Number.isFinite(pose.distance)) {
      resolved = {
        theta: pose.theta,
        phi: clamp(pose.phi, POSE_LIMITS.minPhi, POSE_LIMITS.maxPhi),
        distance: clamp(pose.distance, POSE_LIMITS.minDistance, POSE_LIMITS.maxDistance),
      };
    } else {
      resolved = { ...DEFAULT_POSE };
    }
    // debug overrides (?theta=…&phi=…&dist=…) for framing comparisons only
    const debug = debugParams();
    if (Number.isFinite(debug.theta)) resolved.theta = debug.theta;
    if (Number.isFinite(debug.phi)) resolved.phi = clamp(debug.phi, POSE_LIMITS.minPhi, POSE_LIMITS.maxPhi);
    if (Number.isFinite(debug.dist)) {
      resolved.distance = clamp(debug.dist, POSE_LIMITS.minDistance, POSE_LIMITS.maxDistance);
    }
    return resolved;
  }

  // ---- screen texture ----------------------------------------------------
  function setScreenFromPorts(active, ports) {
    if (!shared.screenTexture || !shared.screenCanvas) return;
    const sig = (ports || [])
      .map((p) => `${p.label}:${Number(p.watts).toFixed(1)}:${p.enabled === false ? 0 : 1}`)
      .join('|');
    if (sig === shared.lastScreenSig) return;
    shared.lastScreenSig = sig;
    drawScreenArtwork(shared.screenCanvas, ports, active.opts.theme ? active.opts.theme() : 'dark');
    shared.screenTexture.needsUpdate = true;
    requestFrame();
  }

  // ---- public API --------------------------------------------------------
  controller.api = {
    update(state) {
      if (controller.disposed) return;
      const ports = Array.isArray(state && state.ports) ? state.ports : [];
      controller.ports = ports;
      setScreenFromPorts(controller, ports);
    },
    setPorts(ports) {
      if (controller.disposed) return;
      controller.ports = ports || [];
      let changed = false;
      for (let i = 0; i < controller.badges.length; i += 1) {
        const badge = controller.badges[i];
        const info = controller.ports[i];
        if (!badge || !info) continue;
        const textEl = badge.querySelector('.ck-stage__badge-txt');
        const nextText = info.text == null ? '' : String(info.text);
        if (textEl && textEl.textContent !== nextText) {
          textEl.textContent = nextText;
          changed = true;
        }
        const lit = info.lit ? 'true' : 'false';
        if (badge.dataset.lit !== lit) badge.dataset.lit = lit;
        const status = info.status == null ? '' : String(info.status);
        if (badge.dataset.status !== status) badge.dataset.status = status;
      }
      if (changed) measureBadges(controller);
      setScreenFromPorts(controller, controller.ports.map((info, i) => ({
        label: info.label || `C${i + 1}`,
        watts: info.watts != null ? info.watts : 0,
        enabled: info.enabled !== false,
      })));
      if (controller.mode === 'ready') requestFrame();
      else if (controller.mode === 'fallback') layoutFallbackBadges(controller);
    },
    setSelected(index) {
      controller.selected = index == null ? null : Number(index);
      for (let i = 0; i < controller.badges.length; i += 1) {
        const badge = controller.badges[i];
        if (!badge) continue;
        badge.dataset.selected = controller.selected === i ? 'true' : 'false';
        badge.setAttribute('aria-pressed', controller.selected === i ? 'true' : 'false');
      }
    },
    setHighlighted(index) {
      controller.highlighted = index == null ? null : Number(index);
      for (let i = 0; i < controller.badges.length; i += 1) {
        const badge = controller.badges[i];
        if (!badge) continue;
        badge.dataset.hover = controller.highlighted === i ? 'true' : 'false';
      }
    },
    reset() {
      restoreHome(controller);
    },
    saveHome() {
      const pose = {
        theta: ((controller.view.theta % 360) + 360) % 360,
        phi: controller.view.phi,
        distance: controller.view.distance,
      };
      try {
        if (controller.opts.writeHomePose) controller.opts.writeHomePose(pose);
      } catch (_) {
        /* persistence is best-effort */
      }
      controller.homePose = pose;
      return pose;
    },
    restoreHome() {
      restoreHome(controller);
    },
    hasHome() {
      return Boolean(controller.homePose);
    },
    getPose() {
      return {
        theta: controller.view.theta,
        phi: controller.view.phi,
        distance: controller.view.distance,
      };
    },
    resize() {
      resizeRenderer(controller);
      requestFrame();
    },
    detach() {
      if (controller.disposed) return;
      controller.disposed = true;
      for (const off of controller.listeners) off();
      controller.listeners.length = 0;
      if (controller.ro) controller.ro.disconnect();
      controller.ro = null;
      if (shared.active === controller) shared.active = null;
      if (shared.raf) {
        cancelAnimationFrame(shared.raf);
        shared.raf = 0;
      }
    },
    dispose() {
      this.detach();
      disposeShared();
    },
    get mode() {
      return controller.mode;
    },
  };

  controller.homePose = (() => {
    try {
      const pose = controller.opts.readHomePose ? controller.opts.readHomePose() : null;
      const parsed = typeof pose === 'string' ? JSON.parse(pose) : pose;
      if (parsed && Number.isFinite(parsed.theta)) return parsed;
    } catch (_) {
      /* ignore */
    }
    return null;
  })();

  function restoreHome(active) {
    const pose = active.homePose && Number.isFinite(active.homePose.theta)
      ? active.homePose
      : DEFAULT_POSE;
    const to = {
      theta: pose.theta,
      phi: pose.phi,
      distance: pose.distance,
    };
    active.target = { ...to };
    if (reduceMotion()) {
      active.view = { ...to };
      active.damping = false;
      active.resetAnim = null;
      requestFrame();
      return;
    }
    active.resetAnim = {
      start: performance.now(),
      from: {
        theta: active.view.theta,
        phi: active.view.phi,
        distance: active.view.distance,
        dTheta: shortestDelta(to.theta, active.view.theta),
      },
      to,
    };
    active.damping = false;
    requestFrame();
  }

  // ---- boot --------------------------------------------------------------
  function retry(active) {
    if (shared.error && shared.error !== 'disabled') {
      shared.error = null;
      shared.ready = false;
      shared.booted = null;
    }
    if (active.mode === 'idle') {
      bootstrap(active);
    }
  }

  async function bootstrap(active) {
    active.mode = 'loading';
    if (!controller.canvas) scaffold();
    if (active.loadingEl) active.loadingEl.hidden = false;
    observeResize();

    try {
      if (!shared.booted) {
        shared.booted = (async () => {
          const [THREE, gltfMod, dracoMod] = await Promise.all([
            import('three'),
            import('three/addons/loaders/GLTFLoader.js'),
            import('three/addons/loaders/DRACOLoader.js'),
          ]);
          const debug = debugParams();
          const renderer = new THREE.WebGLRenderer({
            canvas: controller.canvas,
            antialias: true,
            alpha: true,
            powerPreference: 'high-performance',
            preserveDrawingBuffer: false,
          });
          renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2.5));
          renderer.outputColorSpace = THREE.SRGBColorSpace;
          renderer.toneMapping = THREE.ACESFilmicToneMapping;
          renderer.toneMappingExposure = Number.isFinite(debug.exposure) ? debug.exposure : 0.9;
          renderer.shadowMap.enabled = false;
          renderer.setClearColor(0x000000, 0);
          shared.three = THREE;
          shared.renderer = renderer;
          shared.canvas = renderer.domElement;

          const scene = new THREE.Scene();
          scene.background = null;
          shared.scene = scene;
          shared.envTexture = buildEnvironment(THREE, renderer);
          scene.environment = shared.envTexture;
          scene.environmentIntensity = ENV_INTENSITY;

          const camera = new THREE.PerspectiveCamera(FOV, 1, NEAR, FAR);
          shared.camera = camera;

          // lighting — NativeChargerSceneView.configureLighting (spec §4.5)
          const ambient = new THREE.AmbientLight(0xbac7d6, 0.55);
          scene.add(ambient);
          const key = new THREE.DirectionalLight(0xebf2ff, 2.2);
          key.position.set(0, 0, 1).applyEuler(new THREE.Euler(-0.72, -0.58, -0.18));
          key.castShadow = false;
          scene.add(key);

          // screen artwork canvas + additive material
          const screenCanvas = document.createElement('canvas');
          screenCanvas.width = 960;
          screenCanvas.height = 400;
          shared.screenCanvas = screenCanvas;
          const screenTexture = new THREE.CanvasTexture(screenCanvas);
          screenTexture.colorSpace = THREE.SRGBColorSpace;
          screenTexture.anisotropy = Math.min(4, renderer.capabilities.getMaxAnisotropy());
          shared.screenTexture = screenTexture;

          const draco = new dracoMod.DRACOLoader();
          draco.setDecoderPath(DRACO_PATH);
          shared.draco = draco;
          const loader = new gltfMod.GLTFLoader();
          loader.setDRACOLoader(draco);
          const gltf = await loader.loadAsync(MODEL_URL);
          const root = gltf.scene;
          const fixed = fixMaterials(THREE, root);
          shared.screenMaterial = new THREE.MeshBasicMaterial({
            map: screenTexture,
            transparent: true,
            depthWrite: false,
            blending: THREE.AdditiveBlending,
            toneMapped: false,
            side: THREE.DoubleSide,
            // the plane sits above the cover; keep it hidden behind the body
            depthTest: true,
          });
          if (fixed.screen) {
            fixed.screen.material = shared.screenMaterial;
            fixed.screen.renderOrder = 20;
            shared.artwork = fixed.screen;
            // initial content before the first telemetry update
            drawScreenArtwork(screenCanvas, [], 'dark');
            screenTexture.needsUpdate = true;
          }
          root.traverse((node) => {
            if (node.isMesh) {
              node.castShadow = false;
              node.receiveShadow = false;
            }
          });
          scene.add(root);
          shared.model = root;
          shared.ready = true;
          return true;
        })();
      }
      await shared.booted;
      if (controller.disposed) return;
      if (shared.active !== controller) return;
      attachScene(controller);
    } catch (error) {
      shared.error = (error && error.message) || 'stage-failed';
      logOnce(`3D stage unavailable (${shared.error})`, error);
      if (controller.disposed) return;
      buildFallback(controller, shared.error);
    }
  }

  // ---- kick-off ----------------------------------------------------------
  if (shared.active && shared.active !== controller) {
    try {
      shared.active.api.detach();
    } catch (_) {
      /* old controller already gone */
    }
  }
  shared.active = controller;
  const disabled =
    controller.opts.disabled === true ||
    (() => {
      try {
        return new URLSearchParams(window.location.search).get('stage') === 'off';
      } catch (_) {
        return false;
      }
    })();

  if (disabled) {
    scaffold();
    observeResize();
    controller.width = container.clientWidth || 320;
    controller.height = container.clientHeight || 300;
    buildFallback(controller, 'disabled');
  } else if (!webglAvailable()) {
    scaffold();
    observeResize();
    controller.width = container.clientWidth || 320;
    controller.height = container.clientHeight || 300;
    buildFallback(controller, 'no-webgl');
  } else {
    bootstrap(controller).catch((error) => {
      logOnce('stage bootstrap failed', error);
      buildFallback(controller, (error && error.message) || 'stage-failed');
    });
  }

  return controller.api;
}

/**
 * Mount (or re-mount) the shared stage into a container.
 * Never throws: on any failure the controller switches to the static fallback.
 * @returns the controller API used by js/screens/overview.js
 */
export function createStage(container, opts) {
  return makeController(container, opts || {});
}

// ---------------------------------------------------------------------------
// Shared teardown (only on app teardown, never on route change — §4.13)

function disposeShared() {
  if (shared.disposed) return;
  shared.disposed = true;
  shared.ready = false;
  if (shared.raf) cancelAnimationFrame(shared.raf);
  shared.raf = 0;
  if (shared.scene) {
    shared.scene.traverse((node) => {
      if (node.isMesh) {
        if (node.geometry) node.geometry.dispose();
        const materials = Array.isArray(node.material) ? node.material : [node.material];
        for (const material of materials) {
          if (!material) continue;
          if (material.map && material.map !== shared.screenTexture) material.map.dispose();
          material.dispose();
        }
      }
    });
    shared.scene.clear();
  }
  if (shared.screenTexture) shared.screenTexture.dispose();
  if (shared.envTexture) shared.envTexture.dispose();
  if (shared.renderer) {
    shared.renderer.dispose();
    if (shared.renderer.domElement && shared.renderer.domElement.parentNode) {
      shared.renderer.domElement.parentNode.removeChild(shared.renderer.domElement);
    }
  }
  if (shared.draco) shared.draco.dispose();
  shared.scene = null;
  shared.camera = null;
  shared.renderer = null;
  shared.model = null;
}

export { DEFAULT_POSE, PORTS };
export default createStage;
