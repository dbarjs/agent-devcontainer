'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { coverage, toArgs, fromArgs, equal, DEFAULTS } = require('../lib/coverage');

test('defaults: images on, files any, text off', () => {
  assert.deepEqual(coverage(), DEFAULTS);
  assert.deepEqual(coverage({}), { images: 'on', files: 'any', text: 'off' });
});

test('booleans from VS Code settings map to on/off', () => {
  assert.deepEqual(coverage({ images: false, text: true }), { images: 'off', files: 'any', text: 'on' });
});

test('an unknown value is an error, never a silent default', () => {
  assert.throws(() => coverage({ files: 'everything' }), /files must be one of off\|workspace\|any/);
  assert.throws(() => coverage({ images: 'yes' }), /images must be one of on\|off/);
});

test('spawn arguments round-trip', () => {
  const c = coverage({ images: 'off', files: 'workspace', text: 'on' });
  const args = toArgs(c);
  assert.deepEqual(args, ['--images', 'off', '--files', 'workspace', '--text', 'on']);
  const parsed = fromArgs([...args, '--port', '1234']);
  assert.deepEqual(parsed.coverage, c);
  assert.deepEqual(parsed.rest, ['--port', '1234']);
  assert.deepEqual(fromArgs(['--images=off']).coverage.images, 'off');
});

test('equal compares the three keys', () => {
  assert.ok(equal(coverage(), coverage({ images: true })));
  assert.ok(!equal(coverage(), coverage({ text: true })));
});
