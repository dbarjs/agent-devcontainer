'use strict';
// Real processes and sockets: the daemon entry point as the extension spawns
// it, and the /health probe's three verdicts. Nothing here touches the
// pasteboard, so it runs on Linux CI too.
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const net = require('node:net');
const { spawnDaemon, probeHealth } = require('../lib/host');
const { coverage } = require('../lib/coverage');
const { startDaemon, get } = require('./helpers');

const freePort = () => new Promise((resolve) => {
  const s = net.createServer().listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => resolve(port)); });
});
const once = (em, ev) => new Promise((resolve) => em.once(ev, resolve));

test('probeHealth: free / adc / foreign', async (t) => {
  assert.deepEqual(await probeHealth({ port: await freePort() }), { status: 'free' });

  const { daemon, port } = await startDaemon({ cov: { text: 'on' } });
  t.after(() => daemon.close());
  const adc = await probeHealth({ port });
  assert.equal(adc.status, 'adc');
  assert.equal(adc.health.coverage.text, 'on');

  const other = http.createServer((req, res) => res.end('hello')).listen(0, '127.0.0.1');
  await once(other, 'listening');
  t.after(() => other.close());
  assert.deepEqual(await probeHealth({ port: other.address().port }), { status: 'foreign' });

  const silent = net.createServer(() => {}).listen(0, '127.0.0.1');
  await once(silent, 'listening');
  t.after(() => silent.close());
  assert.deepEqual(await probeHealth({ port: silent.address().port }), { status: 'foreign' });
});

test('spawnDaemon: binds, announces, answers /health with the spawn coverage, dies with stdin', async (t) => {
  const port = await freePort();
  const lines = [];
  const child = spawnDaemon(coverage({ images: 'off' }), { port, log: (l) => lines.push(l) });
  const addr = await once(child, 'listening');
  assert.equal(addr, `127.0.0.1:${port}`);
  const res = await get(`http://127.0.0.1:${port}/health`);
  const h = JSON.parse(res.body);
  assert.equal(h.adc, 'clipboard-daemon');
  assert.equal(h.pid, child.pid);
  assert.deepEqual(h.coverage, { images: 'off', files: 'any', text: 'off' });
  assert.equal((await get(`http://127.0.0.1:${port}/png`)).status, 403);
  child.kill();
  assert.equal(await once(child, 'exit'), 0);
  assert.ok(lines.some((l) => /coverage images=off/.test(l)), lines.join('\n'));
});

test('spawnDaemon: exit 3 when the port is taken', async (t) => {
  const { daemon, port } = await startDaemon();
  t.after(() => daemon.close());
  const child = spawnDaemon(coverage(), { port });
  assert.equal(await once(child, 'exit'), 3);
});

test('the daemon dies when its stdin closes (the extension host is gone)', async () => {
  const { spawn } = require('node:child_process');
  const { DAEMON_SCRIPT } = require('../lib/host');
  const port = await freePort();
  const child = spawn(process.execPath, [DAEMON_SCRIPT, '--port', String(port), '--exit-with-stdin'], { stdio: ['pipe', 'pipe', 'pipe'] });
  await new Promise((resolve) => child.stdout.once('data', resolve));
  assert.equal((await get(`http://127.0.0.1:${port}/health`)).status, 200);
  child.stdin.end();
  const code = await new Promise((resolve) => child.once('exit', resolve));
  assert.equal(code, 0);
  assert.deepEqual(await probeHealth({ port }), { status: 'free' });
});
