import { useEffect } from 'react';
import Lenis from 'lenis';
import { gsap } from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';

gsap.registerPlugin(ScrollTrigger);

export function usePageMotion(root) {
  useEffect(() => {
    const media = gsap.matchMedia();
    media.add('(prefers-reduced-motion: no-preference)', () => {
      const lenis = new Lenis({autoRaf: false, smoothWheel: true, syncTouch: false, duration: 1.05, anchors: true});
      const tick = seconds => lenis.raf(seconds * 1000);
      lenis.on('scroll', ScrollTrigger.update);
      gsap.ticker.add(tick);
      const context = gsap.context(() => {
        gsap.from('.hero-art', {opacity: 0, y: 24, duration: 1.25, delay: 0.2, ease: 'power3.out'});
        gsap.from('.preview-strip', {opacity: 0, y: 16, duration: 0.7, scrollTrigger: {trigger: '.preview-strip', start: 'top 94%', once: true}});
        const desktop = gsap.matchMedia();
        desktop.add('(min-width: 801px)', () => {
          gsap.to('.tablet', {y: -24, ease: 'none', scrollTrigger: {trigger: '.hero', start: 'top top', end: 'bottom top', scrub: 0.8}});
          gsap.to('.phone', {y: 18, ease: 'none', scrollTrigger: {trigger: '.hero', start: 'top top', end: 'bottom top', scrub: 0.8}});
        });
        return () => desktop.revert();
      }, root);
      ScrollTrigger.refresh();
      return () => {
        context.revert();
        gsap.ticker.remove(tick);
        lenis.off('scroll', ScrollTrigger.update);
        lenis.destroy();
      };
    });
    return () => media.revert();
  }, [root]);
}
