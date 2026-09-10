'use strict';
// Coverage (ADR-0012): the per-kind gate on what the host clipboard exposes
// to containers. Three keys, owned by VS Code user settings and handed to the
// clipboard daemon as spawn arguments — this module is the one place that
// knows the keys, their domains, and their defaults.

const DEFAULTS = Object.freeze({ images: 'on', files: 'any', text: 'off' });
const DOMAIN = Object.freeze({
  images: ['on', 'off'],
  files: ['off', 'workspace', 'any'],
  text: ['on', 'off'],
});

function normalize(key, value) {
  if (value === undefined || value === null) return DEFAULTS[key];
  if (typeof value === 'boolean') return value ? 'on' : 'off';
  const s = String(value).toLowerCase();
  if (s === 'true') return 'on';
  if (s === 'false') return 'off';
  return s;
}

// Build a validated coverage object from loose input (settings values, argv).
// Unknown values are an error, not a silent default: a misspelled setting
// must never widen exposure.
function coverage(input = {}) {
  const out = {};
  for (const key of Object.keys(DEFAULTS)) {
    const v = normalize(key, input[key]);
    if (!DOMAIN[key].includes(v)) {
      throw new Error(`coverage ${key} must be one of ${DOMAIN[key].join('|')}, got ${JSON.stringify(input[key])}`);
    }
    out[key] = v;
  }
  return Object.freeze(out);
}

// Spawn-argument encoding: `--images on --files any --text off`.
function toArgs(c) {
  return Object.keys(DEFAULTS).flatMap((k) => [`--${k}`, c[k]]);
}

function fromArgs(argv) {
  const input = {};
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const m = /^--(images|files|text)(?:=(.*))?$/.exec(argv[i]);
    if (!m) { rest.push(argv[i]); continue; }
    input[m[1]] = m[2] !== undefined ? m[2] : argv[++i];
  }
  return { coverage: coverage(input), rest };
}

function equal(a, b) {
  return Object.keys(DEFAULTS).every((k) => a[k] === b[k]);
}

module.exports = { DEFAULTS, DOMAIN, coverage, toArgs, fromArgs, equal };
