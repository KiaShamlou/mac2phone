#!/usr/bin/env python3
"""Dependency-free checks for the static GitHub Pages site and brand exports."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit, unquote
import sys
import json
import struct

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / 'site/dist'
SOURCE_ONLY = '--source' in sys.argv

class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ids = set()
        self.refs = []
        self.h1s = 0
        self.titles = 0
        self.lang = None
        self.tabs = []
        self.images = 0
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if 'id' in a:
            assert a['id'] not in self.ids, f"Duplicate id: {a['id']}"
            self.ids.add(a['id'])
        if tag == 'html': self.lang = a.get('lang')
        if tag == 'h1': self.h1s += 1
        if tag == 'title': self.titles += 1
        if tag == 'img':
            assert 'alt' in a, 'Image has no alternative text'
            assert 'width' in a and 'height' in a, 'Image dimensions missing'
            self.images += 1
        if a.get('role') == 'tab': self.tabs.append(a)
        for attr in ('src', 'href'):
            if attr in a: self.refs.append(a[attr])
        for attr in ('aria-controls', 'aria-labelledby'):
            for value in a.get(attr, '').split(): self.refs.append('#' + value)

if SOURCE_ONLY:
    package = json.loads((ROOT / 'site/package.json').read_text())
    assert all(name in package['dependencies'] for name in ['react', 'react-dom', 'lenis', 'gsap'])
    assert (ROOT / 'site/src/components/react-bits/LICENSE.md').is_file()
    for file in ['src/App.jsx', 'src/usePageMotion.js', 'src/components/ModeExplorer.jsx', 'public/assets/logo.png']:
        assert (ROOT / 'site' / file).is_file(), file
    print('SITE SOURCE: React, Lenis, GSAP, React Bits and local assets verified')
    sys.exit(0)

page = Page()
text = (SITE / 'index.html').read_text()
page.feed(text)
assert page.lang == 'en' and page.h1s == 1 and page.titles == 1
assert len(page.tabs) == 3 and sum(t.get('aria-selected') == 'true' for t in page.tabs) == 1
for ref in page.refs:
    url = urlsplit(ref)
    if url.scheme or url.netloc:
        assert url.scheme == 'https', f'Non-HTTPS external asset/link: {ref}'
        continue
    if url.path:
        path = (SITE / unquote(url.path)).resolve()
        assert path.is_relative_to(SITE.resolve()) and path.is_file(), f'Missing/escaping asset: {ref}'
    elif url.fragment:
        assert unquote(url.fragment) in page.ids, f'Broken anchor: {ref}'
assert 'unauthenticated and unencrypted' not in text
assert 'Pairing and encryption are still on the roadmap' not in text
assert 'Windows &amp; Android: Beta.' in text
assert 'id="platforms"' in text and 'approved pairing and encrypted transports' in text
assert 'Wayland is view-only' in text and 'unification is in progress' in text
assert 'Interface illustration' in text
assert 'prefers-reduced-motion' in (ROOT / 'site/styles.css').read_text()
assert (SITE / '.nojekyll').is_file()
assert (ROOT / 'LICENSE').read_text().startswith('MIT License')
icon = ROOT / 'iOS/Mac2Phone/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
data = icon.read_bytes()
assert data[:8] == b'\x89PNG\r\n\x1a\n'
width, height, depth, color_type = struct.unpack('>IIBB', data[16:26])
assert (width, height) == (1024, 1024) and color_type in (0, 2), 'App icon must be 1024 square without alpha'
assert data == (ROOT / 'Branding/AppIcon.png').read_bytes()
catalog = json.loads((icon.parent / 'Contents.json').read_text())
assert catalog['images'][0]['filename'] == 'AppIcon.png'
assert (ROOT / 'Branding/Mac2Phone.icns').read_bytes()[:4] == b'icns'
assert (ROOT / 'Sources/mac2phone/Resources/WebIcon.png').read_bytes() == (ROOT / 'site/public/assets/logo.png').read_bytes()
print(f'SITE: {len(page.refs)} links/references, 3 accessible mode tabs, and app-icon exports passed')
