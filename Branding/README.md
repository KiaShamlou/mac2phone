# Mac2Phone identity

A connected desktop-and-phone outline, with a small touch point. Mint on deep ink-teal connects the logo to the native apps and project website. The opaque square is intentionally not rounded; Apple applies the platform's icon mask.

## Assets

- `logo-master.png`: original generated artwork, 1254 × 1254.
- `AppIcon.png`: 1024 × 1024 opaque iOS export.
- `Mac2Phone.icns`: standard macOS icon family.
- `../site/assets/logo.png`: lightweight 256 × 256 website export, also bundled for the browser client.
- `../iOS/Mac2Phone/Assets.xcassets/AppIcon.appiconset`: iOS app-icon catalog.

Keep the mark unobstructed and maintain its proportions. Use the original square on both light and dark backgrounds. The MIT repository license applies to these original artwork assets too; website dependencies have separate notices.

## Production

Created with the built-in image-generation tool; resized mechanically with macOS `sips`, then packaged with `iconutil`. No external image service, runtime font, or CDN is required by the website. The original generation prompt is preserved in `logo-prompt.txt`.

## Website

The website lives in `site/`, separate from the native apps. Its screen composition is explicitly labeled as an illustration, not an actual live session or a claim of tested device behavior. The mode selector explains the three native control modes; it does not connect to a Mac.

The React website uses Lenis, GSAP, and React Bits. Run `npm --prefix site ci`, `npm --prefix site run build`, and `python3 Scripts/check-site.py`; preview with `npm --prefix site run dev`. GitHub Pages deploys only `site/dist/`, never application sources, signing assets, or local verification files. See `site/THIRD_PARTY_NOTICES.md`.
