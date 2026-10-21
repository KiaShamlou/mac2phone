import test from 'node:test';
import assert from 'node:assert/strict';
import { platforms } from '../src/platforms.js';
test('Windows and Android are explicitly Beta, not stable releases', () => {
  for (const name of ['Windows', 'Android']) {
    const p = platforms.find(p => p.name === name);
    assert.equal(p.status, 'Beta'); assert.equal(p.tone, 'beta');
  }
  assert.equal(platforms.length, 6);
});
test('platform links use the project repository and explain incomplete features', () => {
  for (const p of platforms) {
    assert.match(p.href, /^https:\/\/github\.com\/KiaShamlou\/mac2phone(?:\/|#|$)/);
    assert(p.detail.length > 60); assert(p.action.length > 5);
  }
  assert.match(platforms.find(p => p.name === 'Linux').detail, /Wayland is view-only/);
  assert.match(platforms.find(p => p.name === 'Mac').detail, /unification is in progress/);
  assert.match(platforms.find(p => p.name === 'Apple Watch').detail, /not a full screen-mirroring/);
});
