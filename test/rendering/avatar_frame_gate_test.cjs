// Run with: node --test test/rendering/avatar_frame_gate_test.cjs
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

function runtime(active = true, reduced = false) {
  // Exercise the actual document-start JS, substituting its two Dart booleans.
  const source = fs.readFileSync(path.join(__dirname, '../../lib/src/rendering/avatar_frame_gate.dart'), 'utf8');
  const script = source.split("'''")[1]
    .replace('$active', String(active)).replace('$reducedMotion', String(reduced));
  let next = 1;
  const scheduled = new Map();
  const window = {
    requestAnimationFrame(callback) { const id = next++; scheduled.set(id, callback); return id; },
    cancelAnimationFrame(id) { scheduled.delete(id); },
  };
  vm.runInNewContext(script, { window, console });
  return {
    window, scheduled,
    frame() { const batch = [...scheduled.values()]; scheduled.clear(); batch.forEach(callback => callback(100)); },
  };
}

test('many RAF clients share one browser callback, and cancellation survives batching', () => {
  const r = runtime();
  let draws = 0;
  let second;
  r.window.requestAnimationFrame(() => { draws++; r.window.cancelAnimationFrame(second); });
  second = r.window.requestAnimationFrame(() => draws++);
  assert.equal(r.scheduled.size, 1);
  r.frame();
  assert.equal(draws, 1);
  assert.equal(r.scheduled.size, 0);
});

test('pause cancels pending frame; repeated resume never duplicates loop', () => {
  const r = runtime();
  let draws = 0;
  function draw() { draws++; r.window.requestAnimationFrame(draw); }
  r.window.requestAnimationFrame(draw);
  r.window.Talk2UFrameGate.setPolicy({ active: false, reducedMotion: false });
  assert.equal(r.scheduled.size, 0);
  r.frame();
  assert.equal(draws, 0);
  for (let i = 0; i < 3; i++) r.window.Talk2UFrameGate.setPolicy({ active: true, reducedMotion: false });
  assert.equal(r.scheduled.size, 1);
  r.frame();
  assert.equal(draws, 1);
  assert.equal(r.scheduled.size, 1);
});

test('reduced motion paints once and only repaints on explicit invalidation', () => {
  const r = runtime(true, true);
  let draws = 0;
  function draw() { draws++; r.window.requestAnimationFrame(draw); }
  r.window.requestAnimationFrame(draw);
  r.frame();
  assert.equal(draws, 1);
  assert.equal(r.scheduled.size, 0);
  r.window.Talk2UFrameGate.invalidate();
  r.window.Talk2UFrameGate.invalidate();
  assert.equal(r.scheduled.size, 1);
  r.frame();
  assert.equal(draws, 2);
  assert.equal(r.scheduled.size, 0);
});
