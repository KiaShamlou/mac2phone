export const cursorMedia = '(hover: hover) and (pointer: fine) and (prefers-reduced-motion: no-preference) and (forced-colors: none)';
const interactive = 'a[href], button, [role="button"], [role="tab"], summary';
const native = 'input, textarea, select, [contenteditable]:not([contenteditable="false"]), pre, code, iframe, [data-cursor="native"]';

// Large cards keep the free cursor; small controls get a precise focus frame.
export function cursorFrame({ x, y }, rect) {
  if (rect && [rect.left, rect.top, rect.width, rect.height].every(Number.isFinite)
    && rect.width > 0 && rect.height > 0 && rect.width <= 480 && rect.height <= 160) {
    return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2,
      width: Math.max(28, rect.width + 16), height: Math.max(28, rect.height + 14), locked: true };
  }
  return { x, y, width: 34, height: 34, locked: false };
}

export function installSignalCursor({ root, gsap, win = window, doc = document }) {
  const media = win.matchMedia(cursorMedia);
  let stop = () => {};
  const configure = () => {
    stop();
    if (!media.matches) { stop = () => {}; return; }
    const dot = root.querySelector('.signal-cursor__dot');
    const frame = root.querySelector('.signal-cursor__frame');
    const glow = root.querySelector('.signal-cursor__glow');
    const ripple = root.querySelector('.signal-cursor__ripple');
    const nodes = [dot, frame, glow, ripple];
    let pending = 0, visible = false, point = { x: 0, y: 0 }, pressed = false;
    const listeners = [];
    const on = (target, type, callback, options) => {
      target.addEventListener(type, callback, options);
      listeners.push(() => target.removeEventListener(type, callback, options));
    };
    gsap.set(nodes, { xPercent: -50, yPercent: -50 });
    // Reuse tweens, rather than allocate an animation on every pointer event.
    const follow = Object.fromEntries(['x', 'y', 'width', 'height'].map(key =>
      [key, gsap.quickTo(frame, key, { duration: 0.3, ease: 'power3.out' })]));
    const glowTo = Object.fromEntries(['x', 'y'].map(key =>
      [key, gsap.quickTo(glow, key, { duration: 0.48, ease: 'power3.out' })]));
    const pause = () => [...Object.values(follow), ...Object.values(glowTo)].forEach(fn => fn.tween.pause());
    const hide = () => {
      if (pending) win.cancelAnimationFrame(pending);
      pending = 0; visible = false;
      root.classList.remove('is-visible', 'is-locked');
      doc.documentElement.classList.remove('has-signal-cursor');
      pause(); gsap.killTweensOf(ripple); gsap.set(ripple, { opacity: 0 });
    };
    const paint = () => {
      pending = 0;
      if (doc.hidden || pressed) { hide(); return; }
      const element = doc.elementFromPoint(point.x, point.y);
      if (!element || element.closest(native) || element.closest('[disabled], [aria-disabled="true"]')) { hide(); return; }
      const target = element.closest(interactive);
      const next = cursorFrame(point, target?.getBoundingClientRect());
      const { locked, ...geometry } = next;
      // The precise dot never lags; only the decorative frame and glow trail.
      gsap.set(dot, point);
      if (!visible) {
        gsap.set(frame, geometry); gsap.set(glow, point);
        // quickTo holds cached starts: explicitly reset them after re-entry.
        for (const key in follow) follow[key](geometry[key], geometry[key]);
        for (const key in glowTo) glowTo[key](point[key], point[key]);
      } else {
        for (const key in follow) follow[key](geometry[key]);
        for (const key in glowTo) glowTo[key](point[key]);
      }
      root.classList.toggle('is-locked', locked);
      root.classList.add('is-visible');
      doc.documentElement.classList.add('has-signal-cursor');
      visible = true;
    };
    const schedule = () => { if (!pending) pending = win.requestAnimationFrame(paint); };
    on(win, 'pointermove', event => {
      if (event.pointerType !== 'mouse' || event.buttons) { hide(); return; }
      point = { x: event.clientX, y: event.clientY }; pressed = false; schedule();
    }, { passive: true });
    on(win, 'pointerdown', event => {
      if (event.pointerType !== 'mouse' || event.button !== 0) { hide(); return; }
      pressed = true;
      if (!visible) return;
      gsap.killTweensOf(ripple);
      gsap.set(ripple, { x: event.clientX, y: event.clientY, scale: 0.5, opacity: 0.7 });
      gsap.to(ripple, { scale: 3.2, opacity: 0, duration: 0.65, ease: 'power2.out' });
    }, { passive: true });
    on(win, 'pointerup', () => { pressed = false; });
    on(win, 'pointercancel', () => { pressed = false; hide(); });
    on(doc.documentElement, 'pointerleave', hide);
    on(win, 'blur', () => { pressed = false; hide(); });
    on(doc, 'visibilitychange', hide);
    on(win, 'keydown', hide);
    // Resolve the element under the pointer again while Lenis moves the page.
    on(win, 'scroll', () => { if (visible) schedule(); }, { passive: true, capture: true });
    on(win, 'resize', hide, { passive: true });
    stop = () => {
      hide(); listeners.forEach(remove => remove());
      [...Object.values(follow), ...Object.values(glowTo)].forEach(fn => fn.tween.kill());
      gsap.killTweensOf(nodes);
    };
  };
  media.addEventListener('change', configure);
  configure();
  return () => { stop(); media.removeEventListener('change', configure); };
}
