import React, { useRef, useState, useEffect } from 'react';
import { gsap } from 'gsap';
import { modes, nextTabIndex } from '../modes.js';

export default function ModeExplorer() {
  const [active, setActive] = useState('touch');
  const buttons = useRef([]);
  const panel = useRef(null);
  const names = Object.keys(modes);
  const content = modes[active];
  useEffect(() => {
    const media = gsap.matchMedia();
    media.add('(prefers-reduced-motion: no-preference)', () => {
      gsap.fromTo(panel.current.querySelector('.mode-copy'), {opacity: 0, y: 8}, {opacity: 1, y: 0, duration: 0.3, ease: 'power2.out'});
    });
    return () => media.revert();
  }, [active]);
  return <div className="mode-explorer">
    <div className="tabs" role="tablist" aria-label="Explore control modes">
      {names.map((name, index) => <button key={name} ref={el => {buttons.current[index] = el;}} id={`tab-${name}`} type="button" role="tab" aria-selected={active === name} aria-controls="mode-panel" tabIndex={active === name ? 0 : -1} onClick={() => setActive(name)} onKeyDown={event => {
        const next = nextTabIndex(event.key, index, names.length);
        if (next !== null) {event.preventDefault(); setActive(names[next]); buttons.current[next].focus();}
      }}>{modes[name].label}</button>)}
    </div>
    <div className="mode-content" id="mode-panel" role="tabpanel" aria-labelledby={`tab-${active}`} tabIndex={0} ref={panel}>
      <div className="gesture-art" data-illustration={active} aria-hidden="true"><div className="gesture-grid"/><div className="gesture-window"><span/><i/><i/><i/></div><div className="gesture-mark"/><span className="gesture-caption">{content.caption}</span></div>
      <div className="mode-copy"><span className="mini-label">{content.kicker}</span><h3>{content.title}</h3><p>{content.description}</p><p className="mode-note">{content.note}</p></div>
    </div>
  </div>;
}
