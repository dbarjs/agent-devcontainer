#!/usr/bin/env node
'use strict';
// Entry point of the clipboard daemon. The clipboard extension spawns this
// with the effective user-scope coverage as arguments:
//
//   adc-clipd.js --images on --files any --text off [--port 47820] [--exit-with-stdin]
//
// stdout carries one line, `listening <host>:<port>`, once the port is
// bound; stderr carries the request log. Exit codes: 3 when the port is
// already taken (the supervisor then asks /health who owns it), 2 on bad
// arguments, 1 on anything else. With --exit-with-stdin the daemon quits
// when its stdin closes, i.e. when the extension host that spawned it is
// gone — so it dies with the window even if deactivate() never ran.

const path = require('node:path');
const { fromArgs } = require('../lib/coverage');
const { createDaemon } = require('../lib/daemon');
const pasteboard = require('../lib/pasteboard');

const { version } = require(path.join(__dirname, '..', 'package.json'));

function usage(msg) {
  process.stderr.write(`adc-clipd: ${msg}\n`);
  process.exit(2);
}

let coverage, rest;
try {
  ({ coverage, rest } = fromArgs(process.argv.slice(2)));
} catch (e) {
  usage(e.message);
}

let port = 47820;
let host = '127.0.0.1';
let exitWithStdin = false;
for (let i = 0; i < rest.length; i++) {
  switch (rest[i]) {
    case '--port': port = Number(rest[++i]); break;
    case '--host': host = rest[++i]; break;
    case '--exit-with-stdin': exitWithStdin = true; break;
    default: usage(`unknown argument ${rest[i]}`);
  }
}
if (!Number.isInteger(port) || port < 0 || port > 65535) usage(`bad port ${port}`);

const log = (line) => process.stderr.write(`[adc-clipd ${new Date().toISOString().slice(11, 19)}] ${line}\n`);
const daemon = createDaemon({ coverage, pasteboard, version, log });

daemon.listen(port, host).then(
  (addr) => {
    process.stdout.write(`listening ${addr.address}:${addr.port}\n`);
    log(`coverage images=${coverage.images} files=${coverage.files} text=${coverage.text}`);
  },
  (err) => {
    if (err.code === 'EADDRINUSE') {
      log(`port ${host}:${port} is already in use`);
      process.exit(3);
    }
    log(`cannot listen on ${host}:${port}: ${err.message}`);
    process.exit(1);
  },
);

function shutdown(why) {
  log(`shutting down (${why})`);
  daemon.close().then(() => process.exit(0));
  setTimeout(() => process.exit(0), 500).unref();
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
if (exitWithStdin) {
  process.stdin.on('end', () => shutdown('stdin closed'));
  process.stdin.on('close', () => shutdown('stdin closed'));
  process.stdin.on('error', () => shutdown('stdin closed'));
  process.stdin.resume();
}
