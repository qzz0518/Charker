// The page side of AppModel: one AppState from Go ("Charker.State", then
// "state" events), a few page-only values (the open section, the transient
// action message), and the calls back into Go.

import { useEffect, useState } from '../lib.js';

const listeners = new Set();
let state = null;
let ui = { section: 'dashboard', actionMessage: null };

function emit() {
  for (const fn of listeners) fn();
}

export function getState() {
  return state;
}

export function getUI() {
  return ui;
}

/** Calls fn after every state or UI change; returns the unsubscribe. */
export function subscribe(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

/** Re-renders the calling component on every state or UI change. */
export function useStore() {
  const [, bump] = useState(0);
  useEffect(() => {
    const fn = () => bump((n) => n + 1);
    listeners.add(fn);
    return () => listeners.delete(fn);
  }, []);
  return [state, ui];
}

export function call(method, ...args) {
  const bridge = window.mygo;
  if (!bridge || typeof bridge.call !== 'function') {
    return Promise.reject(new Error('Charker needs its Windows host'));
  }
  return bridge.call(`Charker.${method}`, ...args);
}

export function on(event, fn) {
  const bridge = window.mygo;
  if (!bridge || typeof bridge.on !== 'function') return () => {};
  return bridge.on(event, fn) || (() => {});
}

export async function boot() {
  state = await call('State');
  ui = { ...ui, section: normalizeSection(state.prefs.lastSection) };
  on('state', (next) => {
    state = next;
    emit();
  });
  on('toast', (toast) => setActionMessage(toast.text));
  return state;
}

/** Merges preference keys, optimistically, then persists them in Go. */
export function setPrefs(patch) {
  state = { ...state, prefs: { ...state.prefs, ...patch } };
  emit();
  return call('SetPrefs', patch).catch((err) => {
    setActionMessage(String(err?.message || err));
    throw err;
  });
}

export const SECTIONS = ['dashboard', 'energy', 'devices', 'menuBar', 'advanced', 'about'];

function normalizeSection(value) {
  return SECTIONS.includes(value) ? value : 'dashboard';
}

export function selectSection(section) {
  section = normalizeSection(section);
  if (ui.section === section) return;
  ui = { ...ui, section };
  emit();
  setPrefs({ lastSection: section }).catch(() => {});
}

let messageTimer = 0;

/** AppModel.setActionMessage: a transient notice floating above the page. */
export function setActionMessage(message, autoClearAfter = 12) {
  clearTimeout(messageTimer);
  ui = { ...ui, actionMessage: message || null };
  emit();
  if (message && autoClearAfter) {
    messageTimer = setTimeout(() => setActionMessage(null), autoClearAfter * 1000);
  }
}
