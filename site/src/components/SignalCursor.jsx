import React, { useEffect, useRef } from 'react';
import { gsap } from 'gsap';
import { installSignalCursor } from '../signalCursor.js';
import './SignalCursor.css';

// Decorative only: never a focus target, live region, or input surface.
export default function SignalCursor() {
  const root = useRef(null);
  useEffect(() => installSignalCursor({ root: root.current, gsap }), []);
  return <div ref={root} className="signal-cursor" aria-hidden="true">
    <span className="signal-cursor__glow" />
    <span className="signal-cursor__frame"><i /><i /><i /><i /></span>
    <span className="signal-cursor__dot" />
    <span className="signal-cursor__ripple" />
  </div>;
}
