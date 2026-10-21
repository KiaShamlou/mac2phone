# Website dependencies

The original Mac2Phone code and artwork are MIT licensed. Third-party code retains its own terms; the repository MIT license does not replace those terms.

- **React / React DOM:** Meta and contributors, MIT. Installed through npm with versions pinned in `package-lock.json`.
- **Lenis:** darkroom.engineering, MIT. https://github.com/darkroomengineering/lenis
- **GSAP / ScrollTrigger:** GreenSock, standard GSAP license. See `node_modules/gsap/LICENSE` and https://gsap.com/standard-license/ . GSAP is a website dependency, not relicensed as MIT.
- **React Bits AnimatedContent:** David Haz, MIT + Commons Clause. The complete upstream license is retained beside the component at `src/components/react-bits/LICENSE.md`. Source: https://github.com/DavidHDev/react-bits/blob/main/src/content/Animations/AnimatedContent/AnimatedContent.jsx . This component is used as part of the Mac2Phone website, not distributed as a standalone component product. Local modifications keep prerendered content visible and respond to live reduced-motion preference changes.
- **Vite:** Vite contributors, MIT (build tooling).

No tracking, analytics, CDN scripts, remote fonts, or cookie storage are added. Motion is enhancement only: the built page contains prerendered HTML, and reduced-motion disables Lenis and scroll choreography.
