'use strict';
const http = require('node:http');
const { createDaemon } = require('../lib/daemon');
const { coverage } = require('../lib/coverage');

// A pasteboard whose contents a test sets directly.
function fakePasteboard(initial = {}) {
  const pb = { types: [], png: null, text: null, calls: [], ...initial };
  return {
    state: pb,
    types: async () => { pb.calls.push('types'); return pb.types; },
    png: async () => { pb.calls.push('png'); return pb.types.includes('public.file-url') ? null : pb.png; },
    text: async () => { pb.calls.push('text'); return pb.text; },
  };
}

// The PNG signature plus some bytes: enough for anything that sniffs magic.
const PNG_BYTES = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.from('fake-png-payload')]);

async function startDaemon({ cov = {}, pasteboard = fakePasteboard(), version = '9.9.9' } = {}) {
  const d = createDaemon({ coverage: coverage(cov), pasteboard, version });
  const addr = await d.listen(0);
  return { daemon: d, pasteboard, url: `http://127.0.0.1:${addr.port}`, port: addr.port };
}

function get(url) {
  return new Promise((resolve, reject) => {
    http.get(url, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }));
      res.on('error', reject);
    }).on('error', reject);
  });
}

module.exports = { fakePasteboard, startDaemon, get, PNG_BYTES };
