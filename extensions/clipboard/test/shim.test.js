'use strict';
// The contract that matters: the xclip shim baked into the images
// (images/base/xclip), run under /bin/sh with curl, against this daemon.
// tests/xclip proves the shim against a fake daemon; this proves the daemon
// against the real shim.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { fakePasteboard, startDaemon, PNG_BYTES } = require('./helpers');

const XCLIP = path.join(__dirname, '..', '..', '..', 'images', 'base', 'xclip');

function xclip(url, args) {
  return new Promise((resolve) => {
    execFile('sh', [XCLIP, ...args], { env: { ...process.env, ADC_CLIPD_URL: url }, encoding: 'buffer', maxBuffer: 64 * 1024 * 1024 },
      (err, stdout, stderr) => resolve({ code: err ? err.code : 0, stdout, stderr: stderr.toString() }));
  });
}

test('screenshot on the pasteboard: TARGETS advertises image/png and the PNG streams through', async (t) => {
  const pb = fakePasteboard({ types: ['public.png', 'public.tiff', 'public.utf8-plain-text'], png: PNG_BYTES, text: 'ignored' });
  const { daemon, url } = await startDaemon({ pasteboard: pb });
  t.after(() => daemon.close());
  const targets = await xclip(url, ['-selection', 'clipboard', '-t', 'TARGETS', '-o']);
  assert.equal(targets.code, 0);
  assert.equal(targets.stdout.toString(), 'image/png\n'); // text off by default
  const png = await xclip(url, ['-selection', 'clipboard', '-t', 'image/png', '-o']);
  assert.equal(png.code, 0);
  assert.ok(png.stdout.equals(PNG_BYTES));
});

test('Finder copy (file reference + icon): nothing to attach through the shim', async (t) => {
  const pb = fakePasteboard({ types: ['public.file-url', 'public.png'], png: PNG_BYTES });
  const { daemon, url } = await startDaemon({ pasteboard: pb });
  t.after(() => daemon.close());
  const targets = await xclip(url, ['-selection', 'clipboard', '-t', 'TARGETS', '-o']);
  assert.equal(targets.code, 0);
  assert.equal(targets.stdout.length, 0);
  assert.equal((await xclip(url, ['-selection', 'clipboard', '-t', 'image/png', '-o'])).code, 1);
});

test('text coverage on: xclip -o returns the clipboard text', async (t) => {
  const pb = fakePasteboard({ types: ['public.utf8-plain-text'], text: 'pasted line' });
  const { daemon, url } = await startDaemon({ pasteboard: pb, cov: { text: 'on' } });
  t.after(() => daemon.close());
  const targets = await xclip(url, ['-selection', 'clipboard', '-t', 'TARGETS', '-o']);
  assert.equal(targets.stdout.toString(), 'text/plain\nUTF8_STRING\n');
  const out = await xclip(url, ['-selection', 'clipboard', '-o']);
  assert.equal(out.code, 0);
  assert.equal(out.stdout.toString(), 'pasted line');
});

test('coverage enforced at the daemon: images off means no image for any container process', async (t) => {
  const pb = fakePasteboard({ types: ['public.png'], png: PNG_BYTES });
  const { daemon, url } = await startDaemon({ pasteboard: pb, cov: { images: 'off' } });
  t.after(() => daemon.close());
  assert.equal((await xclip(url, ['-selection', 'clipboard', '-t', 'TARGETS', '-o'])).stdout.length, 0);
  const png = await xclip(url, ['-selection', 'clipboard', '-t', 'image/png', '-o']);
  assert.equal(png.code, 1);
  assert.equal(png.stdout.length, 0);
});

test('writes never reach the daemon', async (t) => {
  const pb = fakePasteboard({ types: ['public.png'], png: PNG_BYTES });
  const { daemon, url } = await startDaemon({ pasteboard: pb });
  t.after(() => daemon.close());
  const w = await xclip(url, ['-selection', 'clipboard', '-t', 'image/png', '-i', '/dev/null']);
  assert.equal(w.code, 1);
  assert.deepEqual(pb.state.calls, []);
});
