'use strict';
// Port supervision (ADR-0012): every Dev Container window runs one of these,
// and together they keep exactly one clipboard daemon on the port. A window
// binds if it can; on EADDRINUSE it asks /health who owns the port. An adc
// daemon from another window means "served elsewhere" — keep polling so the
// port is retaken when that window closes. Anything else on the port is a
// foreign process, surfaced as a warning and polled more slowly.
//
// Everything with side effects is injected so the state machine is testable
// without sockets or processes:
//   spawn(coverage) -> EventEmitter-like child: emits 'listening' once bound,
//                      'exit' (code) when gone; has kill()
//   probe()         -> Promise<{status:'free'|'adc'|'foreign', health?}>
//   timers          -> {setTimeout, clearTimeout}
//   onState(state)  -> {kind, ...detail} on every transition
//
// Exit code 3 from the daemon is the EADDRINUSE signal (bin/adc-clipd.js).

const { equal } = require('./coverage');

const EXIT_ADDR_IN_USE = 3;

const DEFAULT_INTERVALS = Object.freeze({
  elsewherePoll: 5000, // an adc daemon owns the port: notice quickly when its window closes
  foreignPoll: 30000, // something else owns the port: nothing we can do but wait
  raceRetry: 500, // EADDRINUSE but the port probed free: the owner just died
  crashBackoffMin: 1000,
  crashBackoffMax: 30000,
});

function createSupervisor({ spawn, probe, timers = { setTimeout, clearTimeout }, onState = () => {}, log = () => {}, intervals = {} }) {
  const iv = { ...DEFAULT_INTERVALS, ...intervals };
  let coverage = null;
  let child = null;
  let timer = null;
  let stopped = false;
  let restartPending = false;
  let crashes = 0;
  let state = { kind: 'stopped' };

  function setState(next) {
    state = next;
    log(`state ${next.kind}${next.detail ? ` (${next.detail})` : ''}`);
    onState(next);
  }

  function clearTimer() {
    if (timer) { timers.clearTimeout(timer); timer = null; }
  }

  function later(ms, fn) {
    clearTimer();
    timer = timers.setTimeout(() => { timer = null; if (!stopped) fn(); }, ms);
  }

  function start() {
    if (stopped) return;
    clearTimer();
    restartPending = false;
    setState({ kind: 'starting' });
    const c = spawn(coverage);
    child = c;
    c.on('listening', () => {
      if (child !== c) return;
      crashes = 0;
      setState({ kind: 'serving', coverage });
    });
    c.on('exit', (code) => {
      if (child !== c) return;
      child = null;
      if (stopped) return;
      if (restartPending) { start(); return; }
      if (code === EXIT_ADDR_IN_USE) { claimed(); return; }
      crashes += 1;
      const wait = Math.min(iv.crashBackoffMin * 2 ** (crashes - 1), iv.crashBackoffMax);
      setState({ kind: 'crashed', code, retryIn: wait, detail: `exit ${code}, retry in ${wait} ms` });
      later(wait, start);
    });
  }

  // The port was taken when we tried to bind: find out by whom.
  async function claimed() {
    const result = await probe();
    if (stopped) return;
    switch (result.status) {
      case 'free':
        later(iv.raceRetry, start);
        break;
      case 'adc':
        setState({ kind: 'elsewhere', health: result.health, detail: `pid ${result.health.pid} v${result.health.version}` });
        later(iv.elsewherePoll, poll);
        break;
      default:
        setState({ kind: 'foreign', detail: 'port owned by a process that is not an adc clipboard daemon' });
        later(iv.foreignPoll, poll);
    }
  }

  // Watching a port someone else owns: retake it as soon as it frees up.
  async function poll() {
    const result = await probe();
    if (stopped) return;
    if (result.status === 'free') { start(); return; }
    const kind = result.status === 'adc' ? 'elsewhere' : 'foreign';
    if (kind !== state.kind) {
      setState(kind === 'elsewhere'
        ? { kind, health: result.health, detail: `pid ${result.health.pid} v${result.health.version}` }
        : { kind, detail: 'port owned by a process that is not an adc clipboard daemon' });
    }
    later(kind === 'elsewhere' ? iv.elsewherePoll : iv.foreignPoll, poll);
  }

  return {
    get state() { return state; },
    get coverage() { return coverage; },
    // First call brings the supervisor up; later calls with different
    // coverage restart a daemon we own. A daemon owned by another window is
    // that window's to restart: user-scope settings are the same everywhere.
    setCoverage(next) {
      const changed = coverage === null || !equal(coverage, next);
      coverage = next;
      if (stopped) return;
      if (state.kind === 'stopped') { start(); return; }
      if (!changed) return;
      if (child) {
        restartPending = true;
        log('coverage changed, restarting the daemon');
        child.kill();
      }
    },
    stop() {
      stopped = true;
      clearTimer();
      const c = child;
      child = null;
      if (c) c.kill();
      setState({ kind: 'stopped' });
    },
  };
}

module.exports = { createSupervisor, EXIT_ADDR_IN_USE, DEFAULT_INTERVALS };
