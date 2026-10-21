import test from 'node:test';
import assert from 'node:assert/strict';
import { modes, nextTabIndex, setupCommands } from '../src/modes.js';
test('all three modes have distinct complete content', () => {
  assert.deepEqual(Object.keys(modes), ['touch','pointer','trackpad']);
  for (const mode of Object.values(modes)) for (const field of ['label','title','description','note','caption']) assert.ok(mode[field].length > 3);
  assert.match(modes.touch.description, /hides the streamed cursor/);
});
test('keyboard navigation wraps and supports Home and End', () => {
  assert.equal(nextTabIndex('ArrowLeft',0,3),2);
  assert.equal(nextTabIndex('ArrowRight',2,3),0);
  assert.equal(nextTabIndex('Home',2,3),0);
  assert.equal(nextTabIndex('End',0,3),2);
  assert.equal(nextTabIndex('Tab',1,3),null);
});
test('setup copy matches the public repository and runs without installation', () => {
  assert.match(setupCommands,/KiaShamlou\/mac2phone.git/);
  assert.match(setupCommands,/swift run mac2phone --no-speak$/);
  assert.equal(setupCommands.includes('sudo'),false);
});
