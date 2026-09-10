'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { createSupervisor, EXIT_ADDR_IN_USE } = require('../lib/supervisor');
const { coverage } = require('../lib/coverage');

// A scripted world: children are fake emitters the test drives, probes
// answer from a queue, timers are node:test's mock clock.
function world(t, { probes = [] } = {}) {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const children = [];
  const states = [];
  const probeLog = [];
  const sup = createSupervisor({
    spawn: (cov) => { const c = new EventEmitter(); c.coverage = cov; c.killed = false; c.kill = () => { c.killed = true; }; children.push(c); return c; },
    probe: async () => { const r = probes.length > 1 ? probes.shift() : probes[0]; probeLog.push(r); return r; },
    onState: (s) => states.push(s.kind),
    intervals: { elsewherePoll: 5000, foreignPoll: 30000, raceRetry: 500, crashBackoffMin: 1000, crashBackoffMax: 4000 },
  });
  return { sup, children, states, probeLog, probes };
}

const tick = () => new Promise((r) => setImmediate(r)); // let awaited probes settle

test('binds and serves; deactivation kills the daemon', (t) => {
  const { sup, children, states } = world(t);
  sup.setCoverage(coverage());
  assert.equal(children.length, 1);
  assert.deepEqual(children[0].coverage, coverage());
  children[0].emit('listening');
  assert.equal(sup.state.kind, 'serving');
  sup.stop();
  assert.ok(children[0].killed);
  assert.deepEqual(states, ['starting', 'serving', 'stopped']);
});

test('coverage change restarts a daemon we own, with the new arguments', (t) => {
  const { sup, children } = world(t);
  sup.setCoverage(coverage());
  children[0].emit('listening');
  sup.setCoverage(coverage()); // unchanged: nothing happens
  assert.equal(children.length, 1);
  assert.ok(!children[0].killed);
  sup.setCoverage(coverage({ text: 'on' }));
  assert.ok(children[0].killed);
  children[0].emit('exit', 0);
  assert.equal(children.length, 2);
  assert.equal(children[1].coverage.text, 'on');
  children[1].emit('listening');
  assert.equal(sup.state.kind, 'serving');
});

test('EADDRINUSE + adc /health: served elsewhere, then retaken when the port frees up', async (t) => {
  const adc = { status: 'adc', health: { adc: 'clipboard-daemon', pid: 4242, version: '0.1.0' } };
  const { sup, children, states, probes } = world(t, { probes: [adc] });
  sup.setCoverage(coverage());
  children[0].emit('exit', EXIT_ADDR_IN_USE);
  await tick();
  assert.equal(sup.state.kind, 'elsewhere');
  assert.equal(sup.state.health.pid, 4242);
  t.mock.timers.tick(5000); await tick();
  assert.equal(sup.state.kind, 'elsewhere');
  assert.equal(children.length, 1);
  probes[0] = { status: 'free' }; // the owning window closed
  t.mock.timers.tick(5000); await tick();
  assert.equal(children.length, 2);
  children[1].emit('listening');
  assert.deepEqual(states, ['starting', 'elsewhere', 'starting', 'serving']);
});

test('a coverage change while served elsewhere does not spawn: the owner restarts', async (t) => {
  const adc = { status: 'adc', health: { adc: 'clipboard-daemon', pid: 1, version: '0.1.0' } };
  const { sup, children } = world(t, { probes: [adc] });
  sup.setCoverage(coverage());
  children[0].emit('exit', EXIT_ADDR_IN_USE);
  await tick();
  sup.setCoverage(coverage({ images: 'off' }));
  assert.equal(children.length, 1);
  assert.equal(sup.state.kind, 'elsewhere');
});

test('EADDRINUSE + foreign owner: warning state, slow poll, retaken once free', async (t) => {
  const { sup, children, states, probes } = world(t, { probes: [{ status: 'foreign' }] });
  sup.setCoverage(coverage());
  children[0].emit('exit', EXIT_ADDR_IN_USE);
  await tick();
  assert.equal(sup.state.kind, 'foreign');
  t.mock.timers.tick(5000); await tick();
  assert.equal(children.length, 1); // not the fast poll
  probes[0] = { status: 'free' };
  t.mock.timers.tick(25000); await tick();
  assert.equal(children.length, 2);
  assert.deepEqual(states, ['starting', 'foreign', 'starting']);
});

test('EADDRINUSE but probed free: a race with a dying owner, retry shortly', async (t) => {
  const { sup, children } = world(t, { probes: [{ status: 'free' }] });
  sup.setCoverage(coverage());
  children[0].emit('exit', EXIT_ADDR_IN_USE);
  await tick();
  t.mock.timers.tick(500);
  assert.equal(children.length, 2);
});

test('a crash restarts with exponential backoff, reset once it serves', (t) => {
  const { sup, children } = world(t);
  sup.setCoverage(coverage());
  children[0].emit('exit', 1);
  assert.equal(sup.state.kind, 'crashed');
  assert.equal(sup.state.retryIn, 1000);
  t.mock.timers.tick(1000);
  assert.equal(children.length, 2);
  children[1].emit('exit', 1);
  assert.equal(sup.state.retryIn, 2000);
  t.mock.timers.tick(2000);
  children[2].emit('exit', 1);
  assert.equal(sup.state.retryIn, 4000); // capped
  t.mock.timers.tick(4000);
  children[3].emit('listening');
  children[3].emit('exit', 1);
  assert.equal(sup.state.retryIn, 1000); // reset after serving
});

test('after stop, exits and timers are ignored', async (t) => {
  const { sup, children } = world(t, { probes: [{ status: 'free' }] });
  sup.setCoverage(coverage());
  sup.stop();
  children[0].emit('exit', EXIT_ADDR_IN_USE);
  await tick();
  t.mock.timers.tick(60000);
  assert.equal(children.length, 1);
  assert.equal(sup.state.kind, 'stopped');
});
