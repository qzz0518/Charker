// The 250W overview's 3D charger: A2345ModelStage.swift (A2345SceneView and
// A2345OrbitSceneView) in three.js. The official GLB normalised and turned
// like the SceneKit install, the same three lights, the tuned metal and
// glass finishes (a studio environment on the brushed body only), the
// bubble-clock screen (A2345ScreenArtwork.swift), and the purpose-built
// orbit: drag to rotate, wheel to zoom, no panning. One renderer and scene
// live for the whole run and are re-attached when the overview comes back,
// like A2345InstalledStage.

import * as THREE from 'three';
import { GLTFLoader } from '../../vendor/three/addons/loaders/GLTFLoader.js';
import { DRACOLoader } from '../../vendor/three/addons/loaders/DRACOLoader.js';
import { HDRLoader } from '../../vendor/three/addons/loaders/HDRLoader.js';

const SCREEN_MATERIAL = '1280X1280 (2)';
const DEFAULT_ORBIT = { azimuth: 0.08, elevation: 0.027, distance: 2.25 };
const MIN_ELEVATION = -0.46;
const MAX_ELEVATION = 0.62;
const MIN_DISTANCE = 1.48;
const MAX_DISTANCE = 3.35;
const RESET_SECONDS = 0.58;
const DEG = 180 / Math.PI;

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

/** OrbitInteractionMath.normalizedRadians */
function normalizedRadians(angle) {
  if (!Number.isFinite(angle)) return 0;
  const turn = Math.PI * 2;
  let n = angle % turn;
  if (n > Math.PI) n -= turn;
  if (n < -Math.PI) n += turn;
  return n;
}

/** A2345OrbitSceneView.orbit(from:): a saved pose in degrees to radians. */
export function orbitFromPose(pose) {
  if (!pose || ![pose.theta, pose.phi, pose.distance].every(Number.isFinite)) return { ...DEFAULT_ORBIT };
  return {
    azimuth: normalizedRadians(pose.theta / DEG),
    elevation: clamp(pose.phi / DEG, MIN_ELEVATION, MAX_ELEVATION),
    distance: clamp(pose.distance, MIN_DISTANCE, MAX_DISTANCE),
  };
}

// ---- Screen artwork (A2345ScreenArtwork.bubbleClock) -------------------------

const SCREEN_W = 1920;
const SCREEN_H = 768;
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

function drawBubble(ctx, x, y, radius, [r, g, b]) {
  const rgb = `${Math.round(r * 255)}, ${Math.round(g * 255)}, ${Math.round(b * 255)}`;
  const gradient = ctx.createRadialGradient(x, y, 0, x, y, radius);
  gradient.addColorStop(0, `rgba(${rgb}, 0.44)`);
  gradient.addColorStop(0.58, `rgba(${rgb}, 0.15)`);
  gradient.addColorStop(1, `rgba(${rgb}, 0)`);
  ctx.fillStyle = gradient;
  ctx.fillRect(0, 0, SCREEN_W, SCREEN_H);
}

/**
 * The deliberately non-live clock face. AppKit's y axis points up and
 * NSAttributedString.draw(at:) places the line's bottom (baseline minus the
 * descender) at the point; both are converted to canvas coordinates here.
 */
function drawClock(ctx, date) {
  ctx.clearRect(0, 0, SCREEN_W, SCREEN_H);
  ctx.fillStyle = 'rgb(1, 1, 1)';
  ctx.fillRect(0, 0, SCREEN_W, SCREEN_H);
  drawBubble(ctx, 120, SCREEN_H - 690, 430, [0.02, 0.34, 0.58]);
  drawBubble(ctx, 1840, SCREEN_H - 84, 390, [0.0, 0.55, 0.72]);
  drawBubble(ctx, 1640, SCREEN_H - 720, 170, [0.1, 0.2, 0.42]);

  const pad = (n) => String(n).padStart(2, '0');
  const time = `${pad(date.getHours())}:${pad(date.getMinutes())}`;
  const day = `${MONTHS[date.getMonth()]}. ${date.getDate()} / ${WEEKDAYS[date.getDay()]}.`;
  const family = '"Segoe UI Variable Display", "Segoe UI", "SF Pro Display", system-ui, sans-serif';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'alphabetic';

  ctx.fillStyle = '#ffffff';
  ctx.font = `500 232px ${family}`;
  if ('letterSpacing' in ctx) ctx.letterSpacing = '-8px';
  ctx.fillText(time, SCREEN_W / 2, SCREEN_H - (278 + 232 * 0.24));

  ctx.fillStyle = 'rgb(163, 163, 163)';
  ctx.font = `500 54px ${family}`;
  if ('letterSpacing' in ctx) ctx.letterSpacing = '1.2px';
  ctx.fillText(day, SCREEN_W / 2, SCREEN_H - (210 + 54 * 0.24));
  if ('letterSpacing' in ctx) ctx.letterSpacing = '0px';
}

function clockTexture() {
  const canvas = document.createElement('canvas');
  canvas.width = SCREEN_W;
  canvas.height = SCREEN_H;
  const ctx = canvas.getContext('2d');
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  // glTF UVs: the image's top row is v = 0.
  texture.flipY = false;
  texture.anisotropy = 16;
  texture.wrapS = texture.wrapT = THREE.ClampToEdgeWrapping;
  let minute = null;
  return {
    texture,
    /** True when a new minute was drawn. */
    refresh(force = false, date = new Date()) {
      const m = Math.floor(date.getTime() / 60000);
      if (!force && m === minute) return false;
      minute = m;
      drawClock(ctx, date);
      texture.needsUpdate = true;
      return true;
    },
  };
}

// ---- The retained stage ----------------------------------------------------------

const stage = {
  renderer: null,
  scene: null,
  camera: null,
  product: null,
  clock: null,
  loadState: 'idle', // idle | loading | ready | failed
  loadPromise: null,
  orbit: { ...DEFAULT_ORBIT },
  home: { ...DEFAULT_ORBIT },
  homeConfigured: false,
  opacity: 1,
  host: null,
  frame: 0,
  cameraAnim: null,
  listeners: new Set(),
  requestRender() {
    if (this.frame || !this.host) return;
    this.frame = requestAnimationFrame(() => {
      this.frame = 0;
      this.render();
    });
  },
  render() {
    if (!this.host || !this.renderer || this.loadState !== 'ready') return;
    let animating = false;
    if (this.cameraAnim) {
      const a = this.cameraAnim;
      const p = clamp((performance.now() - a.started) / (RESET_SECONDS * 1000), 0, 1);
      const e = p * p * p * (p * (p * 6 - 15) + 10);
      this.orbit = {
        azimuth: normalizedRadians(a.from.azimuth + a.dAzimuth * e),
        elevation: a.from.elevation + a.dElevation * e,
        distance: a.from.distance + a.dDistance * e,
      };
      if (p >= 1) {
        this.orbit = { ...a.to };
        this.cameraAnim = null;
      } else animating = true;
    }
    this.applyExposure();
    this.applyCamera();
    this.renderer.render(this.scene, this.camera);
    if (animating) this.requestRender();
  },
  /** Locked exposure, brighter on the white light-mode card. */
  applyExposure() {
    const light = document.documentElement.dataset.theme === 'light';
    this.renderer.toneMappingExposure = 2 ** (light ? -0.25 : -0.72) * EXPOSURE_SCALE;
  },
  applyCamera() {
    let { azimuth, elevation, distance } = this.orbit;
    if (![azimuth, elevation, distance].every(Number.isFinite)) {
      this.orbit = { ...this.home };
      ({ azimuth, elevation, distance } = this.orbit);
    }
    const horizontal = distance * Math.cos(elevation);
    this.camera.position.set(
      horizontal * Math.sin(azimuth),
      distance * Math.sin(elevation),
      horizontal * Math.cos(azimuth),
    );
    // Roll pinned to world-up.
    this.camera.up.set(0, 1, 0);
    this.camera.lookAt(0, 0, 0);
    this.camera.updateMatrixWorld();
  },
  animateOrbit(to, reduceMotion) {
    this.cameraAnim = null;
    if (reduceMotion) {
      this.orbit = { ...to };
      this.requestRender();
      return;
    }
    const from = { ...this.orbit };
    this.cameraAnim = {
      from,
      to: { ...to },
      dAzimuth: normalizedRadians(to.azimuth - from.azimuth),
      dElevation: to.elevation - from.elevation,
      dDistance: to.distance - from.distance,
      started: performance.now(),
    };
    this.requestRender();
  },
  /** Returns false at either limit, so continued scrolling goes to the page. */
  zoom(amount) {
    if (!Number.isFinite(amount)) return false;
    const next = clamp(this.orbit.distance * Math.exp(amount), MIN_DISTANCE, MAX_DISTANCE);
    if (Math.abs(next - this.orbit.distance) <= 0.0001) return false;
    this.orbit.distance = next;
    this.requestRender();
    return true;
  },
  setOpacity(opacity) {
    if (!this.product || this.opacity === opacity) return;
    this.opacity = opacity;
    this.product.traverse((node) => {
      if (!node.isMesh) return;
      for (const m of Array.isArray(node.material) ? node.material : [node.material]) {
        if (m.userData.baseOpacity == null) {
          m.userData.baseOpacity = m.opacity;
          m.userData.baseTransparent = m.transparent;
        }
        m.opacity = m.userData.baseOpacity * opacity;
        const transparent = m.userData.baseTransparent || opacity < 1;
        if (m.transparent !== transparent) {
          m.transparent = transparent;
          m.needsUpdate = true;
        }
      }
    });
    this.requestRender();
  },
};

// SceneKit lumens to three.js intensities, and its HDR camera to the ACES
// curve. The 1.5 and 1.75 factors are fudges, tuned side by side against
// the Mac render.
const LUMEN = (Math.PI / 1000) * 1.5;
const EXPOSURE_SCALE = 1.75;
// SceneKit draws the brushed body ('new') as near-diffuse silver under its
// three lamps; three.js reads the GLB's metalness map (~0.7) and renders it
// almost black without an environment. So the body alone gets a lower
// metalness and the studio HDR (another fudge); the polished frame, the knob
// and the black glass keep the lamps' highlights alone, as on the Mac.
const BODY_ENVIRONMENT = 1.8;
const BODY_METALNESS = 0.3;

/**
 * tuneImportedMaterials: the GLB's mirror metals (roughness 0) and the
 * over-range specular on the glass clip in a compact stage; the screen's
 * JPEG emissive layer is dropped for the clock face.
 */
function tuneMaterial(material, environment) {
  const name = material.name || '';
  if (name === SCREEN_MATERIAL) {
    const screen = new THREE.MeshBasicMaterial({
      name,
      map: stage.clock.texture,
      side: THREE.DoubleSide,
      toneMapped: false,
    });
    material.dispose();
    return screen;
  }
  if (name.startsWith('jinshu')) {
    material.roughness = 0.3;
    if ('specularIntensity' in material) material.specularIntensity = 0.42;
  } else if (name === 'new') {
    material.metalnessMap = null;
    material.metalness = BODY_METALNESS;
    material.envMap = environment;
    material.envMapIntensity = BODY_ENVIRONMENT;
  } else if (name.startsWith('M_KV_01_v1_table_')) {
    material.roughness = 0.44;
    if ('specularColor' in material) {
      material.specularColor.setRGB(1, 1, 1);
      material.specularIntensity = 0.24;
    }
  }
  material.side = THREE.DoubleSide;
  return material;
}

async function load() {
  if (stage.loadPromise) return stage.loadPromise;
  stage.loadState = 'loading';
  stage.loadPromise = (async () => {
    const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, powerPreference: 'high-performance' });
    renderer.setClearColor(0x000000, 0);
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    const scene = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(34, 1, 0.01, 100);

    const draco = new DRACOLoader();
    draco.setDecoderPath('./vendor/three/draco/gltf/');
    const loader = new GLTFLoader();
    loader.setDRACOLoader(draco);
    const [hdr, gltf] = await Promise.all([
      new HDRLoader().loadAsync('./assets/models/a2687.hdr'),
      loader.loadAsync('./assets/models/a2345.glb'),
    ]);
    // The studio for the brushed body only (see BODY_ENVIRONMENT); the scene
    // itself has no environment, as in SceneKit.
    const pmrem = new THREE.PMREMGenerator(renderer);
    hdr.mapping = THREE.EquirectangularReflectionMapping;
    const environment = pmrem.fromEquirectangular(hdr).texture;
    hdr.dispose();
    pmrem.dispose();

    stage.clock = clockTexture();
    stage.clock.refresh(true);
    const model = gltf.scene;
    model.traverse((node) => {
      if (!node.isMesh) return;
      node.material = Array.isArray(node.material)
        ? node.material.map((m) => tuneMaterial(m, environment))
        : tuneMaterial(node.material, environment);
    });

    // Normalise to 1.25 units and centre, then turn a parent: rotating the
    // translated model itself would move its centre off the camera target.
    const bounds = new THREE.Box3().setFromObject(model);
    const centre = bounds.getCenter(new THREE.Vector3());
    const size = bounds.getSize(new THREE.Vector3());
    const extent = Math.max(size.x, size.y, size.z);
    const scale = extent > 0 ? 1.25 / extent : 1;
    model.scale.setScalar(scale);
    model.position.set(-centre.x * scale, -centre.y * scale - 0.03, -centre.z * scale);
    const product = new THREE.Group();
    product.name = 'A2345_PRODUCT';
    product.rotation.y = -Math.PI / 8;
    product.add(model);
    scene.add(product);

    // Key: SceneKit lights shine down their node's -Z; place the light
    // along +Z of the same euler rotation. 6100 K.
    const key = new THREE.DirectionalLight(new THREE.Color().setRGB(1, 0.965, 0.93, THREE.SRGBColorSpace), 210 * LUMEN);
    key.position.copy(new THREE.Vector3(0, 0, 1).applyEuler(new THREE.Euler(-0.72, -0.58, -0.18, 'ZYX')));
    scene.add(key);
    const fill = new THREE.PointLight(0xffffff, 52 * LUMEN, 0, 0);
    fill.position.set(1.3, 0.5, 1.1);
    scene.add(fill);
    scene.add(new THREE.AmbientLight(new THREE.Color().setRGB(0.72, 0.78, 0.86, THREE.SRGBColorSpace), 38 * LUMEN));

    Object.assign(stage, { renderer, scene, camera, product });
    stage.opacity = 1;
    renderer.compile(scene, camera);
    stage.loadState = 'ready';
  })().catch((err) => {
    console.error('3D stage:', err);
    stage.loadState = 'failed';
    stage.loadPromise = null;
  });
  return stage.loadPromise.then(() => {
    for (const fn of stage.listeners) fn(stage.loadState);
  });
}

// The face changes once a minute; one timer serves every mount.
setInterval(() => {
  if (stage.clock?.refresh()) stage.requestRender();
}, 30000);

// Exposure follows the appearance.
new MutationObserver(() => stage.requestRender()).observe(document.documentElement, {
  attributes: true,
  attributeFilter: ['data-theme'],
});

/**
 * Mounts the stage into `host` = {el, onLoad, pageScrolls()}. Returns the
 * controller the page drives.
 */
export function mountA2345Stage(host) {
  // Pointer and key events are taken on the container: the canvas inside it
  // is the retained renderer's and moves between mounts.
  const el = host.el;
  const record = { width: 1, height: 1 };
  let reduceMotion = false;

  const onOverlay = (e) => !!e.target.closest?.('.stage__overlay, button');
  let drag = null;
  el.addEventListener('pointerdown', (e) => {
    if (e.button !== 0 || onOverlay(e) || stage.loadState !== 'ready') return;
    el.setPointerCapture(e.pointerId);
    stage.cameraAnim = null;
    drag = { x: e.clientX, y: e.clientY };
    el.classList.add('is-dragging');
    el.focus({ preventScroll: true });
  });
  el.addEventListener('pointermove', (e) => {
    if (!drag) return;
    const dx = e.clientX - drag.x;
    const dy = e.clientY - drag.y;
    drag.x = e.clientX;
    drag.y = e.clientY;
    if (!Number.isFinite(dx) || !Number.isFinite(dy)) return;
    // DOM y points down; AppKit's up-positive drag is -dy, and the camera
    // elevation is inverted so the product follows the pointer.
    stage.orbit.azimuth = normalizedRadians(stage.orbit.azimuth - dx * 0.008);
    stage.orbit.elevation = clamp(stage.orbit.elevation + dy * 0.007, MIN_ELEVATION, MAX_ELEVATION);
    stage.requestRender();
  });
  const endDrag = () => {
    drag = null;
    el.classList.remove('is-dragging');
  };
  el.addEventListener('pointerup', endDrag);
  el.addEventListener('pointercancel', endDrag);
  el.addEventListener(
    'wheel',
    (e) => {
      if (stage.loadState !== 'ready') return;
      // The window is shorter than the overview: the wheel scrolls the page
      // unless Ctrl says it is meant for the model (pinch arrives as Ctrl).
      if (host.pageScrolls() && !e.ctrlKey) return;
      stage.cameraAnim = null;
      const scale = e.deltaMode === 1 ? 0.03 : 0.0015;
      // At either limit continued scrolling returns to the page.
      if (stage.zoom(e.deltaY * scale) || e.ctrlKey) e.preventDefault();
    },
    { passive: false },
  );

  const perform = (action) => {
    if (stage.loadState !== 'ready') return false;
    stage.cameraAnim = null;
    const o = stage.orbit;
    switch (action) {
      case 'rotateLeft':
        o.azimuth = normalizedRadians(o.azimuth + 0.1);
        break;
      case 'rotateRight':
        o.azimuth = normalizedRadians(o.azimuth - 0.1);
        break;
      case 'rotateUp':
        o.elevation = clamp(o.elevation - 0.08, MIN_ELEVATION, MAX_ELEVATION);
        break;
      case 'rotateDown':
        o.elevation = clamp(o.elevation + 0.08, MIN_ELEVATION, MAX_ELEVATION);
        break;
      case 'zoomIn':
        stage.zoom(-0.12);
        return true;
      case 'zoomOut':
        stage.zoom(0.12);
        return true;
      case 'reset':
        stage.animateOrbit(stage.home, reduceMotion);
        return true;
      default:
        return false;
    }
    stage.requestRender();
    return true;
  };

  el.addEventListener('keydown', (e) => {
    if (e.target !== el) return;
    const action = {
      ArrowLeft: 'rotateLeft',
      ArrowRight: 'rotateRight',
      ArrowUp: 'rotateUp',
      ArrowDown: 'rotateDown',
      Escape: 'reset',
      '+': 'zoomIn',
      '=': 'zoomIn',
      '-': 'zoomOut',
      _: 'zoomOut',
      0: 'reset',
    }[e.key];
    if (action && perform(action)) e.preventDefault();
  });

  const resize = () => {
    record.width = Math.max(1, el.clientWidth);
    record.height = Math.max(1, el.clientHeight);
    if (stage.host !== record || !stage.renderer) return;
    stage.renderer.setPixelRatio(window.devicePixelRatio || 1);
    stage.renderer.setSize(record.width, record.height, false);
    stage.camera.aspect = record.width / record.height;
    stage.camera.updateProjectionMatrix();
    stage.render();
  };
  const ro = new ResizeObserver(resize);
  ro.observe(el);

  let pendingOpacity = 1;
  const attach = () => {
    if (stage.loadState !== 'ready' || stage.host === record) return;
    const canvas = stage.renderer.domElement;
    canvas.className = 'stage__canvas';
    el.prepend(canvas);
    stage.host = record;
    // A later mount starts from home, like moveToHomeImmediately.
    stage.cameraAnim = null;
    stage.orbit = { ...stage.home };
    stage.clock.refresh(true);
    stage.setOpacity(pendingOpacity);
    resize();
    host.onLoad('ready');
  };

  stage.listeners.add(attach);
  if (stage.loadState === 'ready') attach();
  else {
    host.onLoad(stage.loadState === 'failed' ? 'failed' : 'loading');
    load().then(() => {
      if (stage.loadState === 'failed') host.onLoad('failed');
    });
  }

  return {
    update(next) {
      reduceMotion = !!next.reduceMotion;
      const home = orbitFromPose(next.homePose);
      if (!stage.homeConfigured) {
        stage.homeConfigured = true;
        stage.orbit = { ...home };
      }
      stage.home = home;
      pendingOpacity = next.active ? 1 : 0.48;
      if (stage.host === record) stage.setOpacity(pendingOpacity);
    },
    perform,
    /** 水平归位: the desk-level default angles, keeping the zoom. */
    level() {
      if (stage.loadState !== 'ready') return;
      stage.animateOrbit(
        { azimuth: DEFAULT_ORBIT.azimuth, elevation: DEFAULT_ORBIT.elevation, distance: stage.orbit.distance },
        reduceMotion,
      );
    },
    reset() {
      perform('reset');
    },
    /** The current camera as a ModelCameraPose (degrees). */
    capture() {
      return {
        theta: normalizedRadians(stage.orbit.azimuth) * DEG,
        phi: stage.orbit.elevation * DEG,
        distance: stage.orbit.distance,
      };
    },
    reload() {
      stage.loadPromise = null;
      stage.loadState = 'idle';
      host.onLoad('loading');
      load().then(() => host.onLoad(stage.loadState));
    },
    dispose() {
      ro.disconnect();
      stage.listeners.delete(attach);
      if (stage.host === record) {
        stage.host = null;
        stage.renderer.domElement.remove();
      }
    },
  };
}
