import { defineConfig } from 'vite';
export default defineConfig({
  base: './',
  esbuild: { jsx: 'automatic' },
  ssr: { noExternal: ['gsap', 'lenis'] },
  build: { target: 'es2022', sourcemap: false },
});
