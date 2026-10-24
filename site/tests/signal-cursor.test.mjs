import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { cursorFrame, cursorMedia, installSignalCursor } from '../src/signalCursor.js';

function fixture(matches = true) {
  class Target {
    listeners = new Map();
    addEventListener(type, fn) { const set = this.listeners.get(type) || new Set(); set.add(fn); this.listeners.set(type, set); }
    removeEventListener(type, fn) { this.listeners.get(type)?.delete(fn); }
    fire(type, fields = {}) { for (const fn of this.listeners.get(type) || []) fn(fields); }
    count() { return [...this.listeners.values()].reduce((sum, set) => sum + set.size, 0); }
  }
  const classes = () => {
    const values = new Set();
    return { add: (...names) => names.forEach(n => values.add(n)), remove: (...names) => names.forEach(n => values.delete(n)),
      contains: n => values.has(n), toggle: (n, on) => on ? values.add(n) : values.delete(n) };
  };
  const root = { classList: classes(), querySelector: selector => nodes[selector.split('__')[1]] };
  const nodes = Object.fromEntries(['dot', 'frame', 'glow', 'ripple'].map(n => [n, {}]));
  const doc = new Target(), win = new Target(), media = new Target();
  doc.documentElement = new Target(); doc.documentElement.classList = classes();
  media.matches = matches;
  win.matchMedia = query => { assert.equal(query, cursorMedia); return media; };
  let id = 0, jobs = new Map(), reads = 0, target = null, isNative = false, disabled = false;
  win.requestAnimationFrame = fn => { jobs.set(++id, fn); return id; };
  win.cancelAnimationFrame = key => jobs.delete(key);
  doc.elementFromPoint = () => { reads++; return { closest: selector => selector.startsWith('input') ? (isNative ? {} : null)
    : selector.startsWith('[disabled]') ? (disabled ? {} : null) : target }; };
  const animations = [], quick = [];
  const gsap = {
    set: (items, values) => (Array.isArray(items) ? items : [items]).forEach(node => Object.assign(node, values)),
    to: (node, values) => animations.push({ node, values }),
    killTweensOf: () => {},
    quickTo: (node, key) => { const fn = value => { node[key] = value; }; fn.tween = { pause() {}, kill() { this.killed = true; } }; quick.push(fn); return fn; },
  };
  const install = () => installSignalCursor({ root, gsap, win, doc });
  return { root, nodes, doc, win, media, animations, quick, install,
    move: (x = 60, y = 90, extra = {}) => win.fire('pointermove', { clientX: x, clientY: y, pointerType: 'mouse', buttons: 0, ...extra }),
    flush: () => { const batch = [...jobs.values()]; jobs.clear(); batch.forEach(fn => fn()); },
    pending: () => jobs.size, reads: () => reads,
    control: rect => { target = { getBoundingClientRect: () => rect }; },
    native: value => { isNative = value; }, disabled: value => { disabled = value; },
  };
}

test('cursor frames fit controls, reject invalid/large targets, and keep a precise free point', () => {
  const point = { x: 20, y: 40 };
  assert.deepEqual(cursorFrame(point), { ...point, width: 34, height: 34, locked: false });
  assert.deepEqual(cursorFrame(point, { left: 10, top: 30, width: 100, height: 40 }),
    { x: 60, y: 50, width: 116, height: 54, locked: true });
  for (const width of [0, -1, 481, NaN, Infinity]) assert.equal(cursorFrame(point, { left: 0, top: 0, width, height: 30 }).locked, false);
});

test('touch/reduced-motion mode installs no pointer listeners or animation loop', () => {
  const f = fixture(false), stop = f.install();
  assert.equal(f.win.count(), 0); assert.equal(f.pending(), 0); assert.equal(f.quick.length, 0);
  stop(); assert.equal(f.media.count(), 0);
});

test('pointer work is coalesced to one frame and uses only the newest coordinates', () => {
  const f = fixture(), stop = f.install();
  assert.equal(f.root.classList.contains('is-visible'), false);
  f.move(12, 30); f.move(50, 80); f.move(90, 120);
  assert.equal(f.pending(), 1); assert.equal(f.reads(), 0);
  f.flush(); assert.equal(f.reads(), 1); assert.equal(f.nodes.dot.x, 90); assert.equal(f.nodes.dot.y, 120);
  assert.equal(f.root.classList.contains('is-visible'), true); assert.equal(f.pending(), 0);
  stop();
});

test('hover locks to a control and updates its bounds while the page scrolls', () => {
  const f = fixture(), stop = f.install();
  const rect = { left: 80, top: 100, width: 150, height: 44 }; f.control(rect);
  f.move(100, 110); f.flush();
  assert.equal(f.root.classList.contains('is-locked'), true);
  assert.equal(f.nodes.frame.width, 166); assert.equal(f.nodes.frame.y, 122);
  rect.top = 60; f.win.fire('scroll'); f.flush(); assert.equal(f.nodes.frame.y, 82);
  stop();
});

test('native text fields, code and disabled controls restore the system cursor', () => {
  const f = fixture(), stop = f.install();
  f.move(); f.flush(); assert.equal(f.doc.documentElement.classList.contains('has-signal-cursor'), true);
  f.native(true); f.move(); f.flush(); assert.equal(f.root.classList.contains('is-visible'), false);
  f.native(false); f.disabled(true); f.move(); f.flush(); assert.equal(f.doc.documentElement.classList.contains('has-signal-cursor'), false);
  stop();
});

test('click produces one bounded ripple; dragging, touch and keyboard restore native interaction', () => {
  const f = fixture(), stop = f.install(); f.move(); f.flush();
  f.win.fire('pointerdown', { pointerType: 'mouse', button: 0, clientX: 60, clientY: 90 });
  assert.equal(f.animations.length, 1); assert.equal(f.animations[0].values.duration, 0.65);
  f.move(65, 95, { buttons: 1 }); assert.equal(f.root.classList.contains('is-visible'), false);
  f.win.fire('pointerup'); f.move(); f.flush();
  f.win.fire('keydown', { key: 'Tab' }); assert.equal(f.doc.documentElement.classList.contains('has-signal-cursor'), false);
  f.move(30, 40, { pointerType: 'touch' }); assert.equal(f.pending(), 0);
  stop();
});

test('leave/blur/visibility/resize cancel work; preference changes and remounts leak no listeners', () => {
  const f = fixture(); let stop = f.install();
  for (const [target, type] of [[f.doc.documentElement, 'pointerleave'], [f.win, 'blur'], [f.doc, 'visibilitychange'], [f.win, 'resize']]) {
    f.move(); target.fire(type); assert.equal(f.pending(), 0); assert.equal(f.root.classList.contains('is-visible'), false);
  }
  f.move(); f.media.matches = false; f.media.fire('change');
  assert.equal(f.pending(), 0); assert.equal(f.win.count(), 0); assert.equal(f.doc.count(), 0);
  assert(f.quick.every(fn => fn.tween.killed));
  f.media.matches = true; f.media.fire('change'); assert(f.win.count() > 0);
  stop(); stop = f.install(); stop();
  for (const target of [f.win, f.doc, f.doc.documentElement, f.media]) assert.equal(target.count(), 0);
});

test('decorative overlay is noninteractive and CSS disables it for reduced motion, touch and forced colors', () => {
  const css = readFileSync(new URL('../src/components/SignalCursor.css', import.meta.url), 'utf8');
  const component = readFileSync(new URL('../src/components/SignalCursor.jsx', import.meta.url), 'utf8');
  assert.match(component, /aria-hidden="true"/); assert.match(css, /pointer-events:none/);
  for (const policy of ['prefers-reduced-motion:reduce', 'pointer:coarse', 'forced-colors:active']) assert(css.includes(policy));
  assert.match(css, /\.signal-cursor\{display:none\}/);
});
