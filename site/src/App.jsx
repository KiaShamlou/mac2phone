import React, { useRef, useState } from 'react';
import AnimatedContent from './components/react-bits/AnimatedContent.jsx';
import ModeExplorer from './components/ModeExplorer.jsx';
import { usePageMotion } from './usePageMotion.js';
import { setupCommands } from './modes.js';
import { platforms } from './platforms.js';

export default function App() {
  const root = useRef(null);
  const [copied, setCopied] = useState(false);
  const [copyStatus, setCopyStatus] = useState('');
  usePageMotion(root);
  async function copyCommands() {
    try {
      await navigator.clipboard.writeText(setupCommands);
      setCopied(true); setCopyStatus('Setup commands copied.');
    } catch {
      const code = root.current.querySelector('.code-box code');
      const range = document.createRange(); range.selectNodeContents(code);
      const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
      setCopyStatus('Commands selected. Use your device’s Copy action.');
    }
  }
  return <div ref={root}>

  <a className="skip" href="#main">Skip to content</a>
  <header className="header wrap">
    <a className="brand" href="#" aria-label="Mac2Phone home"><img src="assets/logo.png" width="42" height="42" alt="" /><span>Mac2Phone</span></a>
    <nav aria-label="Main navigation"><a href="#platforms">Platforms</a><a href="#start">Get started</a><a className="nav-source" href="https://github.com/KiaShamlou/mac2phone">GitHub <span aria-hidden="true">↗</span></a></nav>
  </header>
  <main id="main" tabIndex={-1}>
    <section className="hero wrap" aria-labelledby="hero-title">
      <AnimatedContent className="hero-copy" trigger="mount" distance={24} duration={1.1} stagger={0.08}>
        <p className="eyebrow"><span className="status-dot"></span> Open source. Within reach.</p>
        <h1 id="hero-title">Your screens.<br /><em>Closer together.</em></h1>
        <p className="hero-description">Share a screen. Reach across devices.<br className="desktop-break" /> A touch-first Mac experience, growing beyond Apple.</p>
        <div className="actions"><a className="button primary" href="#start">Find your setup <span aria-hidden="true">↗</span></a><a className="text-link" href="https://github.com/KiaShamlou/mac2phone">Explore the source <span aria-hidden="true">→</span></a></div>
        <p className="compatibility">Mac · iPhone · iPad <span>·</span> Windows &amp; Android Beta</p>
      </AnimatedContent>
      <div className="hero-art" aria-label="Illustration of the same desktop on a tablet and a phone">
        <div className="orbit-label"><span></span> A familiar screen. A new way in.</div>
        <div className="tablet">
          <div className="desktop-scene">
            <div className="scene-menubar"><span>Mac2Phone</span><span>Local connection</span></div>
            <div className="desktop-window"><div className="window-bar"><i></i><i></i><i></i><span>A little room to think</span></div><div className="window-body"><span className="mini-label">TODAY'S PLAN</span><strong>Less desk.<br />More freedom.</strong><div className="task-line"><b>✓</b> Find a comfortable spot</div><div className="task-line"><b>✓</b> Bring your Mac along</div><div className="task-line"><b className="empty"></b> Make something good</div><span className="note-doodle" aria-hidden="true">✳</span></div></div>
            <div className="touch-indicator" aria-hidden="true"></div>
            <div className="scene-dock" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i></div>
            <div className="remote-controls"><span>⌗ Fit</span><span className="active">◉ Touch</span><span>⌨</span><span>•••</span></div>
          </div>
        </div>
        <div className="phone" aria-hidden="true"><div className="phone-island"></div><div className="phone-scene"><span className="phone-time">9:41</span><div className="phone-note"><small>YOUR DESKTOP</small><strong>Same Mac.<br />Smaller pocket.</strong><span>✳</span></div><div className="phone-toolbar">⌗ <b>◉</b> •••</div></div><div className="phone-home"></div></div>
        <div className="art-caption"><span>01 / THE IDEA</span> Interface illustration · not a live connection</div>
      </div>
    </section>
    <div className="preview-strip wrap"><span className="pill">DEVELOPMENT PREVIEW</span><p>Windows and Android are Beta. Local connections require approval; platform support and performance are still evolving.</p><a href="https://github.com/KiaShamlou/mac2phone/blob/main/SECURITY.md">Project status <span aria-hidden="true">↗</span></a></div>
    <section className="experience wrap" id="touch" aria-labelledby="touch-title">
      <div className="section-heading"><p className="eyebrow">A DIFFERENT KIND OF REMOTE</p><h2 id="touch-title">Less pointing.<br />More doing.</h2><p>Some days call for a cursor. Others call for a screen you can reach out and touch. Choose what feels right.</p></div>
      <ModeExplorer />
    </section>
    <section className="details wrap" aria-label="Made for your devices"><AnimatedContent distance={24} duration={0.8}><article><span className="feature-index">01 — NATIVE AT BOTH ENDS</span><h3>Mac power.<br /> Pocket-sized access.</h3><p>ScreenCaptureKit and hardware video encoding on your Mac. A native SwiftUI app on your iPhone and iPad.</p></article></AnimatedContent><AnimatedContent distance={24} duration={0.8}><article><span className="feature-index">02 — YOUR LOCAL NETWORK</span><h3>No cloud account.<br /> Your local connection.</h3><p>Discover nearby running apps, compare the code, and accept before sharing. Screen, input and audio stay on your local network.</p></article></AnimatedContent><AnimatedContent distance={24} duration={0.8}><article><span className="feature-index">03 — ROOM TO MAKE IT YOURS</span><h3>Open code.<br /> Open possibilities.</h3><p>Read it, build it, improve it. The apps and this website are in one repository, released under the MIT license.</p></article></AnimatedContent></section>
    <section className="platforms wrap" id="platforms" aria-labelledby="platform-title">
      <div className="platform-heading"><div><p className="eyebrow">ONE PROJECT. DIFFERENT STAGES.</p><h2 id="platform-title">Find your way in.</h2></div><p>Not every device works the same way. Here is what exists today—and what is still taking shape.</p></div>
      <div className="platform-list">{platforms.map((platform, index) => <article className="platform-row" key={platform.name}>
        <div className="platform-name"><span className="platform-number">0{index + 1}</span><h3>{platform.name}</h3><span className={'platform-status ' + platform.tone}>{platform.status}</span></div>
        <p>{platform.detail}</p><a className="text-link" href={platform.href}>{platform.action} <span aria-hidden="true">↗</span></a>
      </article>)}</div>
      <p className="platform-note"><strong>Windows &amp; Android: Beta.</strong> Expect rough edges. No platform is presented as a stable 1.0 release. <a href="https://github.com/KiaShamlou/mac2phone/blob/main/docs/CROSS_PLATFORM.md">Read the full capability matrix ↗</a></p>
    </section>
    <section className="getting-started" id="start" aria-labelledby="start-title"><div className="wrap"><div className="start-heading"><div><p className="eyebrow">FROM SOURCE TO SOFA</p><h2 id="start-title">Make the connection.</h2></div><p>Desktop preview downloads are on GitHub. Apple mobile and Android builds start from source; iPhone installation needs Xcode and your signing team.</p></div><div className="download-row"><a className="button primary" href="https://github.com/KiaShamlou/mac2phone/releases">Desktop preview downloads <span aria-hidden="true">↗</span></a><span>Mac desktop viewer + Windows Beta · Keep every file in the Windows ZIP together.</span></div><ol className="steps"><li><span className="step-number">1</span><h3>Start on your Mac</h3><p>Clone the repo, then build and run the companion.</p><div className="code-box"><pre><code>{setupCommands}</code></pre><button type="button" onClick={copyCommands} id="copy-command" aria-label="Copy Mac setup commands">{copied ? 'Copied' : 'Copy'}</button></div><p className="copy-status" id="copy-status" role="status" aria-live="polite">{copyStatus}</p></li><li><span className="step-number">2</span><h3>Bring your iPhone or iPad</h3><p>Open <code>iOS/Mac2Phone.xcodeproj</code>, select your signing team, and build for your device.</p><a className="text-link" href="https://github.com/KiaShamlou/mac2phone#iphone-and-ipad">iOS setup guide <span aria-hidden="true">↗</span></a></li><li><span className="step-number">3</span><h3>Find your Mac. Reach out.</h3><p>Allow the requested screen and local-network permissions, send a nearby connection request, compare the code and accept. Then enable Control and choose Touch for a Mac host.</p><a className="text-link" href="https://github.com/KiaShamlou/mac2phone#touch-mode">Learn the gestures <span aria-hidden="true">↗</span></a></li></ol><div className="honest-note"><strong>A quick reality check.</strong><p>Touch gestures translate into Mac mouse, keyboard, and scroll events—not native macOS multitouch. Pinch support varies by app. Connections use approved pairing and encrypted transports. This is a development preview, not an independently audited release. Remote control of an iPhone screen is not supported; its broadcast is view-only.</p></div></div></section>
    <section className="closing wrap"><img src="assets/logo.png" alt="Mac2Phone connected-screen logo" width="72" height="72" /><h2>A small bridge.<br />More ways to connect.</h2><a className="button primary" href="https://github.com/KiaShamlou/mac2phone">Make it yours on GitHub <span aria-hidden="true">↗</span></a></section>
  </main>
  <footer className="footer wrap"><span>Mac2Phone <span className="footer-dot">·</span> Built to be within reach.</span><nav aria-label="Footer navigation"><a href="https://github.com/KiaShamlou/mac2phone/blob/main/LICENSE">MIT license</a><a href="https://github.com/KiaShamlou/mac2phone/blob/main/CONTRIBUTING.md">Contribute</a><a href="https://github.com/KiaShamlou/mac2phone/issues">Feedback</a></nav></footer>

</div>;
}
