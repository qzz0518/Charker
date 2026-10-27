// The overview's 3D charger: NativeChargerSceneView.swift in three.js. Same
// camera orbit and limits, HDR environment, black cover glass, Anker Prime
// screen artwork, plugged-in cables per port and the port pills that float
// left of each port. One renderer and scene live for the whole run and are
// re-attached when the overview comes back, like NativeChargerStage.retained.

import * as THREE from 'three';
import { GLTFLoader } from '../../vendor/three/addons/loaders/GLTFLoader.js';
import { DRACOLoader } from '../../vendor/three/addons/loaders/DRACOLoader.js';
import { HDRLoader } from '../../vendor/three/addons/loaders/HDRLoader.js';
import { t, tf } from '../core/l10n.js';

const CAMERA_TARGET = new THREE.Vector3(0.0035, -0.006, 0.001);
const DEFAULT_ORBIT = { theta: 29.77, phi: 64.91, distance: 0.174 };
const MIN_DISTANCE = 0.09;
const MAX_DISTANCE = 0.42;
const MIN_POLAR = 8;
const MAX_POLAR = 172;
const RESET_SECONDS = 0.58;
const CABLE_APPROACH = 0.015;
const CABLE_SEATED = -0.0058;
const SCREEN_NODE = '资源 9@4x';
const TOP_GLASS_NODE = '51923734';
const TOP_GLASS_MATERIAL = 'A2687_LCD_DECO_COVER';
const BRAND_BLUE = new THREE.Color().setRGB(0, 167 / 255, 225 / 255, THREE.SRGBColorSpace);

const PORTS = [
  { position: [0.00556, 0.01091, 0.03208], normal: [0.053, 0.003, 0.999], cableEnd: [-0.014, -0.095, 0.058] },
  { position: [0.00564, -0.00128, 0.03211], normal: [0.053, 0.003, 0.999], cableEnd: [0.006, -0.095, 0.055] },
  { position: [0.00597, -0.01396, 0.03214], normal: [0.054, 0.004, 0.999], cableEnd: [0.026, -0.095, 0.052] },
].map((p) => ({
  position: new THREE.Vector3(...p.position),
  normal: new THREE.Vector3(...p.normal).normalize(),
  cableEnd: new THREE.Vector3(...p.cableEnd),
}));

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

export function orbitFromPose(pose) {
  if (!pose || ![pose.theta, pose.phi, pose.distance].every(Number.isFinite)) return { ...DEFAULT_ORBIT };
  return {
    theta: pose.theta % 360,
    phi: clamp(pose.phi, MIN_POLAR, MAX_POLAR),
    distance: clamp(pose.distance, MIN_DISTANCE, MAX_DISTANCE),
  };
}

// ---- Screen artwork (ModelScreenArtwork.ankerPrimeTexture) --------------------

function ankerPrimeTexture() {
  const canvas = document.createElement('canvas');
  canvas.width = 960;
  canvas.height = 400;
  const ctx = canvas.getContext('2d');
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  // glTF UVs: the image's top row is v = 0.
  texture.flipY = false;
  const blue = '#00a7e1';
  const draw = (logo) => {
    ctx.clearRect(0, 0, 960, 400);
    // AppKit's y axis points up: the logo sits just above the middle,
    // PRIME below it.
    if (logo) {
      ctx.drawImage(logo, 480 - 143, 200 - 2 - 68, 286, 68);
    } else {
      ctx.fillStyle = blue;
      ctx.font = '600 52px "Segoe UI", sans-serif';
      ctx.textAlign = 'center';
      ctx.fillText('ANKER', 480, 186);
    }
    ctx.fillStyle = blue;
    ctx.font = '600 29px "Segoe UI", sans-serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    if ('letterSpacing' in ctx) ctx.letterSpacing = '7px';
    ctx.fillText('PRIME', 480 + 3.5, 200 + 59 - 19);
    texture.needsUpdate = true;
  };
  draw(null);
  const img = new Image();
  img.onload = () => {
    draw(img);
    stage.requestRender();
  };
  img.src = './assets/brand/Anker.svg';
  return texture;
}

// ---- Geometry helpers --------------------------------------------------------------

function cubicBezier(start, c1, c2, end, segments) {
  const points = [];
  for (let i = 0; i <= segments; i++) {
    const s = i / segments;
    const u = 1 - s;
    points.push(
      new THREE.Vector3()
        .addScaledVector(start, u * u * u)
        .addScaledVector(c1, 3 * u * u * s)
        .addScaledVector(c2, 3 * u * s * s)
        .addScaledVector(end, s * s * s),
    );
  }
  return points;
}

function pbr(rgb, metalness, roughness, clearcoat = 0, clearcoatRoughness = 0) {
  const color = new THREE.Color().setRGB(rgb[0], rgb[1], rgb[2], THREE.SRGBColorSpace);
  const options = { color, metalness, roughness, side: THREE.DoubleSide };
  if (clearcoat) return new THREE.MeshPhysicalMaterial({ ...options, clearcoat, clearcoatRoughness });
  return new THREE.MeshStandardMaterial(options);
}

function roundedBox(w, h, d, r) {
  // A box with its edges softened, close enough to SCNBox's chamfer at this scale.
  const shape = new THREE.Shape();
  const x = -w / 2;
  const y = -h / 2;
  const rr = Math.min(r, w / 2, h / 2);
  shape.moveTo(x + rr, y);
  shape.lineTo(x + w - rr, y);
  shape.quadraticCurveTo(x + w, y, x + w, y + rr);
  shape.lineTo(x + w, y + h - rr);
  shape.quadraticCurveTo(x + w, y + h, x + w - rr, y + h);
  shape.lineTo(x + rr, y + h);
  shape.quadraticCurveTo(x, y + h, x, y + h - rr);
  shape.lineTo(x, y + rr);
  shape.quadraticCurveTo(x, y, x + rr, y);
  const bevel = Math.min(rr * 0.6, d / 4);
  const g = new THREE.ExtrudeGeometry(shape, {
    depth: d - 2 * bevel,
    bevelEnabled: true,
    bevelThickness: bevel,
    bevelSize: bevel * 0.6,
    bevelSegments: 2,
    curveSegments: 6,
  });
  g.translate(0, 0, -(d - 2 * bevel) / 2);
  return g;
}

function createCable(index, spec, scene) {
  const group = new THREE.Group();
  const orientation = new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 0, 1), spec.normal);
  group.quaternion.copy(orientation);
  group.position.copy(spec.position).addScaledVector(spec.normal, CABLE_APPROACH);
  group.visible = false;

  const shell = pbr([0.68, 0.71, 0.74], 0.82, 0.24);
  const inset = pbr([0.1, 0.11, 0.13], 0.05, 0.6);
  const housingValue = [
    [0.85, 0.87, 0.88],
    [0.81, 0.84, 0.85],
    [0.77, 0.8, 0.82],
  ][index];
  const housing = pbr(housingValue, 0.02, 0.58, 0.22, 0.46);
  const lead = pbr([[0.8, 0.82, 0.84], [0.76, 0.8, 0.82], [0.73, 0.77, 0.79]][index], 0, 0.78);
  const materials = [shell, inset, housing, lead];

  const add = (geometry, material, z) => {
    const mesh = new THREE.Mesh(geometry, material);
    mesh.position.z = z;
    group.add(mesh);
    return mesh;
  };
  add(roundedBox(0.00825, 0.00285, 0.0065, 0.00122), shell, 0.00325);
  add(roundedBox(0.0064, 0.00135, 0.00038, 0.00055), inset, 0.00666);
  add(roundedBox(0.0112, 0.0064, 0.0114, 0.00175), housing, 0.0116);
  const relief = new THREE.Mesh(new THREE.CylinderGeometry(0.0029, 0.0029, 0.0082, 24), housing);
  relief.rotation.x = Math.PI / 2;
  relief.position.z = 0.0208;
  group.add(relief);

  // Control points are tuned in world space and converted into the plug's
  // local space, as on macOS.
  const inverse = orientation.clone().invert();
  const seated = spec.position.clone().addScaledVector(spec.normal, CABLE_SEATED);
  const localEnd = spec.cableEnd.clone().sub(seated).applyQuaternion(inverse);
  const localDown = new THREE.Vector3(0, -1, 0).applyQuaternion(inverse);
  const localOut = new THREE.Vector3(0, 0, 1);
  const start = new THREE.Vector3(0, 0, 0.024);
  const points = cubicBezier(
    start,
    start.clone().addScaledVector(localOut, 0.01).addScaledVector(localDown, 0.01),
    localEnd.clone().addScaledVector(localOut, 0.002).addScaledVector(localDown, -0.026),
    localEnd,
    36,
  );
  const tube = new THREE.TubeGeometry(new THREE.CatmullRomCurve3(points), 72, 0.00105, 10, false);
  group.add(new THREE.Mesh(tube, lead));

  const halo = new THREE.Mesh(
    roundedBox(0.0102, 0.0046, 0.00055, 0.00165),
    new THREE.MeshBasicMaterial({
      color: BRAND_BLUE,
      transparent: true,
      opacity: 0,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    }),
  );
  halo.position.copy(spec.position).addScaledVector(spec.normal, 0.0002);
  halo.quaternion.copy(orientation);
  scene.add(halo);
  scene.add(group);
  return { group, halo, spec, materials, attached: false, anim: null };
}

// ---- The retained stage ---------------------------------------------------------------

const stage = {
  renderer: null,
  scene: null,
  camera: null,
  model: null,
  cables: [],
  hits: [],
  screenTexture: null,
  loadState: 'idle', // idle | loading | ready | failed
  loadPromise: null,
  orbit: { ...DEFAULT_ORBIT },
  home: { ...DEFAULT_ORBIT },
  homeConfigured: false,
  state: null,
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
    const host = this.host;
    if (!host || !this.renderer || this.loadState !== 'ready') return;
    const now = performance.now();
    let animating = false;
    if (this.cameraAnim) {
      const a = this.cameraAnim;
      const p = clamp((now - a.started) / (RESET_SECONDS * 1000), 0, 1);
      const e = p * p * p * (p * (p * 6 - 15) + 10);
      this.orbit = {
        theta: a.from.theta + a.dTheta * e,
        phi: a.from.phi + a.dPhi * e,
        distance: a.from.distance + a.dDistance * e,
      };
      if (p >= 1) {
        this.orbit = { ...a.to };
        this.cameraAnim = null;
      } else animating = true;
    }
    for (const cable of this.cables) {
      if (!cable.anim) continue;
      const a = cable.anim;
      const p = clamp((now - a.started) / (a.duration * 1000), 0, 1);
      const e = a.attaching ? 1 - (1 - p) ** 3 : p ** 3;
      cable.group.position.lerpVectors(a.from, a.to, e);
      const opacity = a.attaching ? e : 1 - e;
      for (const m of cable.materials) {
        m.transparent = opacity < 1;
        m.opacity = opacity;
      }
      if (p >= 1) {
        cable.anim = null;
        cable.group.visible = cable.attached;
      } else animating = true;
    }
    this.applyCamera();
    this.renderer.render(this.scene, this.camera);
    this.positionPills();
    if (animating) this.requestRender();
  },
  applyCamera() {
    const polar = (this.orbit.phi * Math.PI) / 180;
    const azimuth = (this.orbit.theta * Math.PI) / 180;
    const d = this.orbit.distance;
    this.camera.position.set(
      CAMERA_TARGET.x + d * Math.sin(polar) * Math.sin(azimuth),
      CAMERA_TARGET.y + d * Math.cos(polar),
      CAMERA_TARGET.z + d * Math.sin(polar) * Math.cos(azimuth),
    );
    this.camera.up.set(0, 1, 0);
    this.camera.lookAt(CAMERA_TARGET);
    this.camera.updateMatrixWorld();
  },
  positionPills() {
    const host = this.host;
    if (!host) return;
    const w = host.canvasWidth;
    const h = host.canvasHeight;
    host.pills.forEach((pill, index) => {
      if (!pill) return;
      const spec = PORTS[index];
      const toCamera = this.camera.position.clone().sub(spec.position);
      const front = toCamera.dot(spec.normal) > 0;
      const p = spec.position.clone().project(this.camera);
      const x = ((p.x + 1) / 2) * w;
      const y = ((1 - p.y) / 2) * h;
      const visible = front && p.z >= -1 && p.z <= 1 && x >= -40 && x <= w + 40 && y >= -30 && y <= h + 30;
      pill.style.visibility = visible ? 'visible' : 'hidden';
      if (visible) pill.style.transform = `translate(${x - pill.offsetWidth - 8}px, ${y - 11}px)`;
    });
  },
  animateCamera(to) {
    const from = { ...this.orbit };
    let dTheta = (to.theta - from.theta) % 360;
    if (dTheta > 180) dTheta -= 360;
    if (dTheta < -180) dTheta += 360;
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      this.orbit = { ...to };
      this.requestRender();
      return;
    }
    this.cameraAnim = {
      from,
      to,
      dTheta,
      dPhi: to.phi - from.phi,
      dDistance: to.distance - from.distance,
      started: performance.now(),
    };
    this.requestRender();
  },
};

async function load() {
  if (stage.loadPromise) return stage.loadPromise;
  stage.loadState = 'loading';
  stage.loadPromise = (async () => {
    const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, powerPreference: 'high-performance' });
    renderer.setClearColor(0x000000, 0);
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    // SceneKit's exposureOffset -0.48.
    renderer.toneMappingExposure = 2 ** -0.48 * 1.75;
    const scene = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(26, 1, 0.005, 2);

    const pmrem = new THREE.PMREMGenerator(renderer);
    const [hdr, gltf] = await Promise.all([
      new HDRLoader().loadAsync('./assets/models/a2687.hdr'),
      (() => {
        const draco = new DRACOLoader();
        draco.setDecoderPath('./vendor/three/draco/gltf/');
        const loader = new GLTFLoader();
        loader.setDRACOLoader(draco);
        return loader.loadAsync('./assets/models/a2687.glb');
      })(),
    ]);
    hdr.mapping = THREE.EquirectangularReflectionMapping;
    scene.environment = pmrem.fromEquirectangular(hdr).texture;
    scene.environmentIntensity = 0.78;
    hdr.dispose();
    pmrem.dispose();

    scene.add(new THREE.AmbientLight(new THREE.Color().setRGB(0.73, 0.78, 0.84, THREE.SRGBColorSpace), 0.042 * Math.PI));
    const key = new THREE.DirectionalLight(new THREE.Color().setRGB(0.92, 0.95, 1, THREE.SRGBColorSpace), 0.22 * Math.PI);
    // SceneKit lights shine down their node's -Z; place the light along +Z
    // of the same euler rotation.
    const dir = new THREE.Vector3(0, 0, 1).applyEuler(new THREE.Euler(-0.72, -0.58, -0.18, 'ZYX'));
    key.position.copy(dir);
    scene.add(key);

    const model = gltf.scene;
    stage.screenTexture = ankerPrimeTexture();
    model.traverse((node) => {
      if (!node.isMesh) return;
      const mats = Array.isArray(node.material) ? node.material : [node.material];
      const isScreen = node.name.includes(SCREEN_NODE) || mats.some((m) => m.name?.includes(SCREEN_NODE));
      const isGlass = node.name === TOP_GLASS_NODE || mats.some((m) => m.name?.includes(TOP_GLASS_MATERIAL));
      if (isScreen) {
        node.material = new THREE.MeshBasicMaterial({
          map: stage.screenTexture,
          transparent: true,
          blending: THREE.AdditiveBlending,
          depthWrite: false,
          side: THREE.DoubleSide,
          toneMapped: false,
        });
        node.renderOrder = 20;
      } else if (isGlass) {
        // configureTopGlassMaterial: optically black with one tight Blinn
        // highlight, no environment reflection.
        node.material = new THREE.MeshPhongMaterial({
          color: new THREE.Color().setRGB(0.006, 0.007, 0.01, THREE.SRGBColorSpace),
          specular: new THREE.Color(0.72, 0.72, 0.72),
          shininess: 90,
          side: THREE.DoubleSide,
        });
      } else {
        for (const m of mats) m.side = THREE.DoubleSide;
      }
    });
    scene.add(model);

    stage.cables = PORTS.map((spec, i) => createCable(i, spec, scene));
    stage.hits = PORTS.map((spec, i) => {
      const mesh = new THREE.Mesh(
        new THREE.BoxGeometry(0.016, 0.01, 0.004),
        new THREE.MeshBasicMaterial({ visible: false }),
      );
      mesh.position.copy(spec.position).addScaledVector(spec.normal, 0.0015);
      mesh.quaternion.setFromUnitVectors(new THREE.Vector3(0, 0, 1), spec.normal);
      mesh.userData.port = i;
      scene.add(mesh);
      return mesh;
    });
    Object.assign(stage, { renderer, scene, camera, model });
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

/** Applies NativeChargerRenderState. */
function applyState(state, previous, animate) {
  if (!stage.model) return;
  stage.model.traverse((node) => {
    if (!node.isMesh || node.userData.port != null) return;
    const mats = Array.isArray(node.material) ? node.material : [node.material];
    for (const m of mats) {
      if (m.userData.baseOpacity == null) m.userData.baseOpacity = m.opacity;
      const o = state.active ? m.userData.baseOpacity : m.userData.baseOpacity * 0.48;
      if (m.opacity !== o) {
        m.opacity = o;
        m.transparent = o < 1 || m.blending === THREE.AdditiveBlending || m.userData.wasTransparent;
      }
    }
  });
  const highlighted = state.pointerPort ?? state.highlightedPort;
  stage.cables.forEach((cable, index) => {
    const port = state.ports[index] || {};
    const attached = state.active && port.attached === true;
    const lit = state.active && port.lit;
    const focused = state.selectedPort === index || highlighted === index;
    cable.halo.material.opacity = attached ? (focused ? 0.14 : lit ? 0.1 : 0.025) : 0;
    if (cable.attached === attached) return;
    cable.attached = attached;
    const seated = cable.spec.position.clone().addScaledVector(cable.spec.normal, CABLE_SEATED);
    const approach = cable.spec.position.clone().addScaledVector(cable.spec.normal, CABLE_APPROACH);
    const changed = previous?.ports?.[index]?.attached !== port.attached;
    if (!animate || !changed || state.reduceMotion) {
      cable.anim = null;
      cable.group.position.copy(attached ? seated : approach);
      for (const m of cable.materials) {
        m.opacity = 1;
        m.transparent = false;
      }
      cable.group.visible = attached;
      return;
    }
    cable.group.visible = true;
    cable.anim = {
      attaching: attached,
      from: cable.group.position.clone(),
      to: attached ? seated : approach,
      duration: attached ? 0.28 : 0.2,
      started: performance.now(),
    };
  });
  stage.requestRender();
}

/**
 * Mounts the stage into `host` = {el, pillsEl, onPortTap, onPortHover,
 * onLoad}. Returns the controller the page drives.
 */
export function mountStage(host) {
  // Pointer and key events are taken on the container: the canvas inside it
  // is the retained renderer's and moves between mounts.
  const canvas = host.el;
  const pills = [0, 1, 2].map((i) => {
    const b = document.createElement('button');
    b.className = 'stage__pill';
    b.addEventListener('click', () => host.onPortTap(i));
    b.addEventListener('pointerenter', () => setPointerPort(i));
    b.addEventListener('pointerleave', () => setPointerPort(null));
    host.pillsEl.appendChild(b);
    return b;
  });
  const record = { canvasWidth: 1, canvasHeight: 1, pills };
  let state = null;
  let pointerPort = null;
  let firstState = true;

  function setPointerPort(index) {
    if (pointerPort === index) return;
    pointerPort = index;
    host.onPortHover(index);
    if (state) {
      const next = { ...state, pointerPort };
      applyState(next, state, false);
      state = next;
      updatePills();
    }
  }

  function updatePills() {
    if (!state) return;
    const dark = document.documentElement.dataset.theme !== 'light';
    const highlighted = state.pointerPort ?? state.highlightedPort;
    pills.forEach((pill, i) => {
      const port = state.ports[i] || {};
      let status;
      if (state.active && port.lit) status = tf('%.1f W', port.watts);
      else if (state.active && port.attached === true) status = t('已接线');
      else if (state.active && port.attached === false) status = t('未接线');
      else status = '—';
      const focused = state.selectedPort === i || highlighted === i;
      pill.classList.toggle('is-focused', focused);
      pill.classList.toggle('is-lit', !!(state.active && port.lit));
      pill.classList.toggle('is-light', !dark);
      pill.innerHTML = '';
      const dot = document.createElement('span');
      dot.className = 'stage__pill-dot';
      dot.textContent = '●';
      const text = document.createElement('span');
      text.textContent = `C${i + 1}  ${status}`;
      pill.append(dot, text);
      const cable = port.capability ? tf('，%@ 线', port.capability) : '';
      const power = state.active && port.lit ? tf('，%@', status) : '';
      const desc =
        port.attached === true
          ? tf('已连接%@%@', cable, power)
          : port.attached === false
            ? t('未接线')
            : t('线缆状态未知');
      pill.setAttribute('aria-label', tf('选择 C%d 端口，%@', i + 1, desc));
    });
    stage.positionPills();
  }

  // ---- Pointer: orbit, click a port, hover, wheel zoom ----
  const raycaster = new THREE.Raycaster();
  const portAt = (e) => {
    if (stage.loadState !== 'ready') return null;
    const r = canvas.getBoundingClientRect();
    const ndc = new THREE.Vector2(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1);
    raycaster.setFromCamera(ndc, stage.camera);
    const hit = raycaster.intersectObjects(stage.hits, false)[0];
    return hit ? hit.object.userData.port : null;
  };
  let drag = null;
  const onPill = (e) => !!e.target.closest?.('.stage__pill, .stage__overlay');
  canvas.addEventListener('pointerdown', (e) => {
    if (e.button !== 0 || onPill(e)) return;
    canvas.setPointerCapture(e.pointerId);
    drag = { x: e.clientX, y: e.clientY, distance: 0 };
    canvas.focus({ preventScroll: true });
  });
  canvas.addEventListener('pointermove', (e) => {
    if (drag) {
      const dx = e.clientX - drag.x;
      const dy = e.clientY - drag.y;
      drag.distance += Math.hypot(dx, dy);
      drag.x = e.clientX;
      drag.y = e.clientY;
      stage.cameraAnim = null;
      stage.orbit.theta -= dx * 0.34;
      stage.orbit.phi = clamp(stage.orbit.phi - dy * 0.34, MIN_POLAR, MAX_POLAR);
      stage.requestRender();
    } else if (!onPill(e)) {
      setPointerPort(portAt(e));
    }
  });
  canvas.addEventListener('pointerup', (e) => {
    if (drag && drag.distance < 3) {
      const port = portAt(e);
      if (port != null) host.onPortTap(port);
    }
    drag = null;
  });
  canvas.addEventListener('pointerleave', () => {
    if (!drag) setPointerPort(null);
  });
  canvas.addEventListener(
    'wheel',
    (e) => {
      const scroller = host.el.closest('.page');
      const pageScrolls = scroller && scroller.scrollHeight > scroller.clientHeight + 0.5;
      if (pageScrolls && !e.ctrlKey) return;
      e.preventDefault();
      const scale = e.deltaMode === 1 ? 0.03 : 0.0015;
      stage.cameraAnim = null;
      stage.orbit.distance = clamp(stage.orbit.distance * Math.exp(e.deltaY * scale), MIN_DISTANCE, MAX_DISTANCE);
      stage.requestRender();
    },
    { passive: false },
  );
  canvas.tabIndex = 0;
  canvas.setAttribute('role', 'application');
  canvas.setAttribute('aria-label', t('Anker Prime 160W 原生三维视图'));
  canvas.addEventListener('keydown', (e) => {
    const o = stage.orbit;
    const step = {
      ArrowLeft: () => (o.theta -= 4),
      ArrowRight: () => (o.theta += 4),
      ArrowUp: () => (o.phi = clamp(o.phi - 4, MIN_POLAR, MAX_POLAR)),
      ArrowDown: () => (o.phi = clamp(o.phi + 4, MIN_POLAR, MAX_POLAR)),
      '+': () => (o.distance = Math.max(MIN_DISTANCE, o.distance / 1.12)),
      '=': () => (o.distance = Math.max(MIN_DISTANCE, o.distance / 1.12)),
      '-': () => (o.distance = Math.min(MAX_DISTANCE, o.distance * 1.12)),
    }[e.key];
    if (!step) return;
    e.preventDefault();
    stage.cameraAnim = null;
    step();
    stage.requestRender();
  });

  const resize = () => {
    const w = Math.max(1, host.el.clientWidth);
    const h = Math.max(1, host.el.clientHeight);
    record.canvasWidth = w;
    record.canvasHeight = h;
    if (stage.host !== record || !stage.renderer) return;
    stage.renderer.setPixelRatio(window.devicePixelRatio || 1);
    stage.renderer.setSize(w, h, false);
    stage.camera.aspect = w / h;
    stage.camera.updateProjectionMatrix();
    stage.render();
  };
  const ro = new ResizeObserver(resize);
  ro.observe(host.el);

  const attach = () => {
    if (stage.loadState !== 'ready' || stage.host === record) return;
    const el = stage.renderer.domElement;
    el.className = 'stage__canvas';
    host.el.prepend(el);
    stage.host = record;
    resize();
    if (state) applyState(state, null, false);
    updatePills();
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
      const previous = state;
      state = { ...next, pointerPort };
      if (!stage.homeConfigured) {
        stage.homeConfigured = true;
        stage.home = orbitFromPose(next.homePose);
        stage.orbit = { ...stage.home };
      } else {
        stage.home = orbitFromPose(next.homePose);
      }
      if (stage.host === record) applyState(state, previous, !firstState);
      firstState = false;
      updatePills();
    },
    reset() {
      stage.animateCamera(stage.home);
    },
    capture() {
      return { theta: stage.orbit.theta % 360, phi: stage.orbit.phi, distance: stage.orbit.distance };
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
      for (const p of pills) p.remove();
    },
  };
}
