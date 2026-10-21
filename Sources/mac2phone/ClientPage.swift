/// Emergency fallback viewer, served at http://<mac>:<port>/.
/// The native app is the real client; this exists for the day the app's
/// signature expires and the Mac's screen still cannot be read.
let clientHTML = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black">
<meta name="apple-mobile-web-app-title" content="Mac2Phone">
<link rel="apple-touch-icon" href="/icon.png">
<title>Mac2Phone</title>
<style>
  :root { color-scheme: dark; }
  * { margin: 0; padding: 0; box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  html, body { height: 100%; overflow: hidden; background: #000; font: 500 14px -apple-system, system-ui, sans-serif; color: #eee; }
  #stage { position: fixed; inset: 0; touch-action: none; overflow: hidden; }
  #screen { position: absolute; top: 0; left: 0; transform-origin: 0 0; image-rendering: -webkit-optimize-contrast; }
  #bar { position: fixed; left: 0; right: 0; bottom: 0; padding: 8px calc(8px + env(safe-area-inset-right)) calc(8px + env(safe-area-inset-bottom)) calc(8px + env(safe-area-inset-left));
         display: flex; gap: 6px; align-items: center; background: rgba(18,18,22,.86); backdrop-filter: blur(20px);
         border-top: 1px solid rgba(255,255,255,.08); transition: transform .22s ease; overflow-x: auto; }
  #bar.hidden { transform: translateY(110%); }
  button { flex: none; background: rgba(255,255,255,.1); color: #eee; border: 0; border-radius: 9px; padding: 9px 12px; font-size: 13px; font-weight: 600; }
  button.on { background: #2f6fea; color: #fff; }
  #status { position: fixed; top: calc(8px + env(safe-area-inset-top)); left: 50%; transform: translateX(-50%);
            background: rgba(18,18,22,.85); border-radius: 999px; padding: 6px 14px; font-size: 12px; letter-spacing: .2px;
            backdrop-filter: blur(20px); transition: opacity .3s; }
  #status.gone { opacity: 0; }
  #grab { position: fixed; right: 10px; bottom: calc(10px + env(safe-area-inset-bottom)); width: 42px; height: 42px; border-radius: 50%;
          background: rgba(18,18,22,.85); display: none; align-items: center; justify-content: center; font-size: 17px; backdrop-filter: blur(20px); }
  #bar.hidden ~ #grab { display: flex; }
  #keys { position: fixed; left: 0; right: 0; bottom: 0; padding: 6px calc(6px + env(safe-area-inset-left)) calc(6px + env(safe-area-inset-bottom)) calc(6px + env(safe-area-inset-right));
          display: none; gap: 5px; flex-wrap: wrap; background: rgba(18,18,22,.94); backdrop-filter: blur(20px); }
  #keys.show { display: flex; }
  #keys button { padding: 8px 10px; font-size: 12px; }
  #sink { position: fixed; opacity: 0; pointer-events: none; width: 1px; height: 1px; top: -50px; }
</style>
</head>
<body>
<div id="stage"><canvas id="screen"></canvas></div>
<div id="status">connecting…</div>
<div id="bar">
  <button id="bFit">fit</button>
  <button id="b100">1:1</button>
  <button id="bCtl">control</button>
  <button id="bKeys">keys</button>
  <button id="bQ">quality</button>
  <button id="bHide">hide</button>
</div>
<div id="grab">▲</div>
<div id="keys">
  <button data-k="escape">esc</button><button data-k="tab">tab</button>
  <button data-m="cmd">⌘</button><button data-m="shift">⇧</button><button data-m="ctrl">⌃</button><button data-m="alt">⌥</button>
  <button data-k="left">←</button><button data-k="down">↓</button><button data-k="up">↑</button><button data-k="right">→</button>
  <button data-k="delete">⌫</button><button data-k="return">⏎</button>
  <button id="bType">type…</button>
</div>
<input id="sink" autocapitalize="off" autocorrect="off" spellcheck="false">
<script>
(() => {
  const canvas = document.getElementById('screen');
  const ctx = canvas.getContext('2d', { alpha: false, desynchronized: true });
  const stage = document.getElementById('stage');
  const statusEl = document.getElementById('status');
  const bar = document.getElementById('bar');
  const keys = document.getElementById('keys');
  const sink = document.getElementById('sink');

  let ws = null, W = 0, H = 0, scale = 1, tx = 0, ty = 0;
  let control = false, decoding = false, mods = new Set();
  const qualities = [[1280, 20, .5], [1600, 24, .6], [2048, 30, .7]];
  let qIndex = 1;

  const status = (text, sticky) => {
    statusEl.textContent = text;
    statusEl.classList.remove('gone');
    if (!sticky) setTimeout(() => statusEl.classList.add('gone'), 1600);
  };

  function connect() {
    ws = new WebSocket(`ws://${location.host}/ws`);
    ws.binaryType = 'arraybuffer';
    ws.onopen = () => { status('connected'); sendCfg(); };
    ws.onclose = () => { status('reconnecting…', true); setTimeout(connect, 1000); };
    ws.onerror = () => ws.close();
    ws.onmessage = (event) => {
      if (typeof event.data === 'string') return;
      if (decoding) { ack(); return; }
      decoding = true;
      createImageBitmap(new Blob([event.data], { type: 'image/jpeg' }))
        .then(bitmap => {
          if (bitmap.width !== W || bitmap.height !== H) {
            W = canvas.width = bitmap.width;
            H = canvas.height = bitmap.height;
            canvas.style.width = W + 'px';
            canvas.style.height = H + 'px';
            fit();
          }
          ctx.drawImage(bitmap, 0, 0);
          bitmap.close();
        })
        .finally(() => { decoding = false; ack(); });
    };
  }

  const send = (object) => { if (ws && ws.readyState === 1) ws.send(JSON.stringify(object)); };
  const ack = () => send({ t: 'ack' });
  setInterval(() => send({ t: 'ping' }), 5000);
  window.addEventListener('blur', () => cancelInteraction());
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) cancelInteraction();
  });
  const sendCfg = () => {
    const [w, fps, q] = qualities[qIndex];
    send({ t: 'cfg', width: w, fps, q });
  };

  // ---- view transform
  const apply = () => { canvas.style.transform = `translate3d(${tx}px,${ty}px,0) scale(${scale})`; };
  function fit() {
    if (!W) return;
    scale = Math.min(innerWidth / W, innerHeight / H);
    tx = (innerWidth - W * scale) / 2;
    ty = (innerHeight - H * scale) / 2;
    apply();
  }
  const oneToOne = () => {
    const cx = innerWidth / 2, cy = innerHeight / 2;
    const px = (cx - tx) / scale, py = (cy - ty) / scale;
    scale = 1 / (devicePixelRatio || 1) * 2;
    tx = cx - px * scale; ty = cy - py * scale; apply();
  };
  const norm = (x, y) => [Math.min(1, Math.max(0, (x - tx) / scale / W)),
                          Math.min(1, Math.max(0, (y - ty) / scale / H))];

  // ---- gestures
  let touches = new Map(), gesture = null, start = null;
  const dist = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);
  const pts = () => [...touches.values()];
  function cancelInteraction() {
    send({ t: 'cancel' });
    touches.clear(); gesture = null; start = null;
  }

  stage.addEventListener('touchstart', (e) => {
    e.preventDefault();
    if (!W || !H) return;
    if (control) send({ t: 'cancel' });
    for (const t of e.changedTouches) touches.set(t.identifier, { x: t.clientX, y: t.clientY });
    const p = pts();
    if (p.length === 1) {
      start = { x: p[0].x, y: p[0].y, tx, ty, time: Date.now() };
      gesture = control ? 'pending' : 'pan';
    } else if (p.length >= 2) {
      gesture = 'two';
      start = { d: dist(p[0], p[1]), cx: (p[0].x + p[1].x) / 2, cy: (p[0].y + p[1].y) / 2,
                lx: (p[0].x + p[1].x) / 2, ly: (p[0].y + p[1].y) / 2, scale, tx, ty, kind: null };
    }
  }, { passive: false });

  stage.addEventListener('touchmove', (e) => {
    e.preventDefault();
    for (const t of e.changedTouches) if (touches.has(t.identifier)) touches.set(t.identifier, { x: t.clientX, y: t.clientY });
    const p = pts();

    if (gesture === 'pan' && p.length === 1) {
      tx = start.tx + (p[0].x - start.x); ty = start.ty + (p[0].y - start.y); apply();
    } else if (gesture === 'pending' && p.length === 1) {
      if (Math.hypot(p[0].x - start.x, p[0].y - start.y) > 9) {
        gesture = 'drag';
        const [nx, ny] = norm(start.x, start.y);
        send({ t: 'm', x: nx, y: ny }); send({ t: 'd', b: 0 });
      }
    } else if (gesture === 'drag' && p.length === 1) {
      const [nx, ny] = norm(p[0].x, p[0].y);
      send({ t: 'g', x: nx, y: ny, b: 0 });
    } else if (gesture === 'two' && p.length >= 2) {
      const d = dist(p[0], p[1]), cx = (p[0].x + p[1].x) / 2, cy = (p[0].y + p[1].y) / 2;
      if (!start.kind) {
        if (Math.abs(d - start.d) > 24) start.kind = 'pinch';
        else if (Math.hypot(cx - start.cx, cy - start.cy) > 18) start.kind = control ? 'scroll' : 'pan2';
      }
      if (start.kind === 'pinch') {
        scale = Math.min(8, Math.max(0.1, start.scale * d / start.d));
        const px = (start.cx - start.tx) / start.scale, py = (start.cy - start.ty) / start.scale;
        tx = cx - px * scale; ty = cy - py * scale; apply();
      } else if (start.kind === 'pan2') {
        tx = start.tx + (cx - start.cx); ty = start.ty + (cy - start.cy); apply();
      } else if (start.kind === 'scroll') {
        send({ t: 's', dx: (cx - start.lx) * 2, dy: (cy - start.ly) * 2 });
      }
      start.lx = cx; start.ly = cy;
    }
  }, { passive: false });

  const endTouch = (e) => {
    e.preventDefault();
    const p = pts();
    if (gesture === 'pending' && Date.now() - start.time < 450) {
      const [nx, ny] = norm(start.x, start.y);
      send({ t: 'c', x: nx, y: ny, b: Date.now() - start.time > 300 ? 1 : 0, n: 1 });
    } else if (gesture === 'drag') {
      send({ t: 'u', b: 0 });
    }
    if (gesture === 'two' && start.kind === 'scroll') send({ t: 'se', vx: 0, vy: 0 });
    for (const t of e.changedTouches) touches.delete(t.identifier);
    gesture = null; start = null;
  };
  stage.addEventListener('touchend', endTouch, { passive: false });
  stage.addEventListener('touchcancel', (e) => { e.preventDefault(); cancelInteraction(); }, { passive: false });

  // ---- controls
  document.getElementById('bFit').onclick = fit;
  document.getElementById('b100').onclick = oneToOne;
  document.getElementById('bCtl').onclick = (e) => {
    cancelInteraction();
    control = !control;
    if (!control) sink.blur();
    e.target.classList.toggle('on', control);
    status(control ? 'control on — tap to click, 2 fingers scroll' : 'view only');
  };
  document.getElementById('bKeys').onclick = (e) => {
    if (!control) { status('Turn Control on to use the keyboard'); return; }
    keys.classList.toggle('show');
    e.target.classList.toggle('on', keys.classList.contains('show'));
  };
  document.getElementById('bQ').onclick = () => {
    qIndex = (qIndex + 1) % qualities.length;
    sendCfg();
    status(`${qualities[qIndex][0]}px · ${qualities[qIndex][1]}fps`);
  };
  document.getElementById('bHide').onclick = () => bar.classList.add('hidden');
  document.getElementById('grab').onclick = () => bar.classList.remove('hidden');

  keys.addEventListener('click', (e) => {
    const button = e.target.closest('button');
    if (!button || !control) return;
    if (button.dataset.m) {
      const m = button.dataset.m;
      mods.has(m) ? mods.delete(m) : mods.add(m);
      button.classList.toggle('on', mods.has(m));
    } else if (button.dataset.k) {
      send({ t: 'key', k: button.dataset.k, m: [...mods] });
      mods.clear();
      keys.querySelectorAll('[data-m]').forEach(b => b.classList.remove('on'));
    }
  });

  document.getElementById('bType').onclick = () => { sink.value = ''; sink.focus(); };
  sink.addEventListener('input', () => {
    if (!control || !sink.value) return;
    if (mods.size) {
      send({ t: 'key', k: sink.value.slice(-1), m: [...mods] });
      mods.clear();
      keys.querySelectorAll('[data-m]').forEach(b => b.classList.remove('on'));
    } else {
      send({ t: 'txt', s: sink.value });
    }
    sink.value = '';
  });
  sink.addEventListener('keydown', (e) => {
    if (!control) return;
    if (e.key === 'Backspace') send({ t: 'key', k: 'delete', m: [] });
    if (e.key === 'Enter') { e.preventDefault(); send({ t: 'key', k: 'return', m: [] }); }
  });

  addEventListener('resize', () => setTimeout(fit, 60));
  addEventListener('orientationchange', () => setTimeout(fit, 260));
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden && (!ws || ws.readyState > 1)) connect();
    if (!document.hidden) lock();
  });

  let wakeLock = null;
  async function lock() {
    try { wakeLock = await navigator.wakeLock.request('screen'); } catch (_) {}
  }
  lock();
  connect();
})();
</script>
</body>
</html>
"""#
