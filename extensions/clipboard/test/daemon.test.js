'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { fakePasteboard, startDaemon, get, PNG_BYTES } = require('./helpers');
const { kinds } = require('../lib/daemon');

test('kinds: priority order, and a file reference hides the image', () => {
  assert.deepEqual(kinds([]), []);
  assert.deepEqual(kinds(['public.png', 'public.tiff']), ['image/png']);
  assert.deepEqual(kinds(['public.tiff']), ['image/png']);
  assert.deepEqual(kinds(['public.utf8-plain-text', 'public.png']), ['image/png', 'text/plain']);
  assert.deepEqual(kinds(['public.file-url', 'public.png', 'public.utf8-plain-text']), ['text/plain']);
  assert.deepEqual(kinds(['code/file-list', 'dyn.whatever']), []);
});

test('/health identifies an adc daemon and reports coverage', async (t) => {
  const { daemon, url } = await startDaemon({ cov: { text: 'on' } });
  t.after(() => daemon.close());
  const res = await get(`${url}/health`);
  assert.equal(res.status, 200);
  assert.match(res.headers['content-type'], /application\/json/);
  const h = JSON.parse(res.body);
  assert.equal(h.adc, 'clipboard-daemon');
  assert.equal(h.version, '9.9.9');
  assert.equal(h.pid, process.pid);
  assert.deepEqual(h.coverage, { images: 'on', files: 'any', text: 'on' });
});

test('/types lists what /png and /text can deliver, newline-terminated', async (t) => {
  const pb = fakePasteboard({ types: ['public.png', 'public.utf8-plain-text'] });
  const { daemon, url } = await startDaemon({ pasteboard: pb, cov: { text: 'on' } });
  t.after(() => daemon.close());
  assert.equal((await get(`${url}/types`)).body.toString(), 'image/png\ntext/plain\n');
  pb.state.types = [];
  const empty = await get(`${url}/types`);
  assert.equal(empty.status, 200);
  assert.equal(empty.body.length, 0);
  assert.deepEqual(pb.state.calls, ['types', 'types']);
});

test('/types never advertises an image when a file reference is on the pasteboard', async (t) => {
  const pb = fakePasteboard({ types: ['public.file-url', 'public.png', 'public.utf8-plain-text'], png: PNG_BYTES });
  const { daemon, url } = await startDaemon({ pasteboard: pb, cov: { text: 'on' } });
  t.after(() => daemon.close());
  assert.equal((await get(`${url}/types`)).body.toString(), 'text/plain\n');
  assert.equal((await get(`${url}/png`)).status, 404);
});

test('/png streams the bytes, 404 without an image', async (t) => {
  const pb = fakePasteboard({ types: ['public.png'], png: PNG_BYTES });
  const { daemon, url } = await startDaemon({ pasteboard: pb });
  t.after(() => daemon.close());
  const res = await get(`${url}/png`);
  assert.equal(res.status, 200);
  assert.equal(res.headers['content-type'], 'image/png');
  assert.equal(res.headers['content-length'], String(PNG_BYTES.length));
  assert.ok(res.body.equals(PNG_BYTES));
  pb.state.png = null;
  assert.equal((await get(`${url}/png`)).status, 404);
});

test('/text serves utf-8 text, 404 without text', async (t) => {
  const pb = fakePasteboard({ types: ['public.utf8-plain-text'], text: 'héllo → world' });
  const { daemon, url } = await startDaemon({ pasteboard: pb, cov: { text: 'on' } });
  t.after(() => daemon.close());
  const res = await get(`${url}/text`);
  assert.equal(res.status, 200);
  assert.equal(res.body.toString('utf8'), 'héllo → world');
  pb.state.text = null;
  assert.equal((await get(`${url}/text`)).status, 404);
});

test('coverage off: kinds vanish from /types and their endpoints answer 403 without touching the pasteboard', async (t) => {
  const pb = fakePasteboard({ types: ['public.png', 'public.utf8-plain-text'], png: PNG_BYTES, text: 'secret' });
  const { daemon, url } = await startDaemon({ pasteboard: pb, cov: { images: 'off', text: 'off' } });
  t.after(() => daemon.close());
  assert.equal((await get(`${url}/types`)).body.length, 0);
  assert.equal((await get(`${url}/png`)).status, 403);
  assert.equal((await get(`${url}/text`)).status, 403);
  assert.deepEqual(pb.state.calls, ['types']);
});

test('text is off by default', async (t) => {
  const pb = fakePasteboard({ types: ['public.utf8-plain-text'], text: 'secret' });
  const { daemon, url } = await startDaemon({ pasteboard: pb });
  t.after(() => daemon.close());
  assert.equal((await get(`${url}/types`)).body.length, 0);
  assert.equal((await get(`${url}/text`)).status, 403);
});

test('read-only surface: unknown paths 404, non-GET 405, and there is no file endpoint', async (t) => {
  const { daemon, url } = await startDaemon();
  t.after(() => daemon.close());
  assert.equal((await get(`${url}/file`)).status, 404);
  assert.equal((await get(`${url}/file/bytes`)).status, 404);
  assert.equal((await get(`${url}/`)).status, 404);
  const post = await new Promise((resolve, reject) => {
    const req = require('node:http').request(`${url}/text`, { method: 'POST' }, (res) => { res.resume(); res.on('end', () => resolve(res.statusCode)); });
    req.on('error', reject);
    req.end('pwned');
  });
  assert.equal(post, 405);
});

test('a pasteboard failure is a 500, not a hang', async (t) => {
  const pb = { types: async () => { throw new Error('osascript failed: boom'); }, png: async () => null, text: async () => null };
  const { daemon, url } = await startDaemon({ pasteboard: pb });
  t.after(() => daemon.close());
  const res = await get(`${url}/types`);
  assert.equal(res.status, 500);
  assert.match(res.body.toString(), /boom/);
});
