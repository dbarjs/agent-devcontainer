'use strict';
// Real-process adapters for the supervisor: spawn bin/adc-clipd.js as a child
// of the extension host, and probe /health on the port. No vscode import, so
// these run under plain node too.

const { spawn } = require('node:child_process');
const { EventEmitter } = require('node:events');
const http = require('node:http');
const path = require('node:path');
const { toArgs } = require('./coverage');
const { NAME } = require('./daemon');

const DAEMON_SCRIPT = path.join(__dirname, '..', 'bin', 'adc-clipd.js');
const PORT = 47820;
const HEALTH_TIMEOUT_MS = 1000;

// Spawn the daemon with the coverage as arguments. Inside a VS Code
// extension host process.execPath is Electron, which runs as plain node only
// with ELECTRON_RUN_AS_NODE set; outside VS Code it is node itself and the
// variable is harmless. stdin is a pipe the daemon watches (--exit-with-stdin)
// so it cannot outlive us.
function spawnDaemon(coverage, { port = PORT, execPath = process.execPath, log = () => {} } = {}) {
  const args = [DAEMON_SCRIPT, ...toArgs(coverage), '--port', String(port), '--exit-with-stdin'];
  const child = spawn(execPath, args, {
    stdio: ['pipe', 'pipe', 'pipe'],
    env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
  });
  const out = new EventEmitter();
  out.pid = child.pid;
  let listening = false;
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    for (const line of chunk.split('\n')) {
      if (line.startsWith('listening ') && !listening) { listening = true; out.emit('listening', line.slice(10)); }
      else if (line) log(line);
    }
  });
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', (chunk) => { for (const line of chunk.split('\n')) if (line) log(line); });
  child.on('error', (err) => { log(`spawn failed: ${err.message}`); out.emit('exit', 1); });
  child.on('exit', (code, signal) => out.emit('exit', code === null ? (signal === 'SIGTERM' ? 0 : 1) : code));
  out.kill = () => { try { child.kill('SIGTERM'); } catch { /* already gone */ } };
  return out;
}

// GET /health on the loopback port. 'free' on connection refused (nobody
// listening), 'adc' when an adc clipboard daemon answers, 'foreign' for any
// other answer, non-answer, or timeout.
function probeHealth({ port = PORT } = {}) {
  return new Promise((resolve) => {
    const req = http.get({ host: '127.0.0.1', port, path: '/health', timeout: HEALTH_TIMEOUT_MS }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (d) => { if (body.length < 65536) body += d; });
      res.on('end', () => {
        try {
          const health = JSON.parse(body);
          resolve(health && health.adc === NAME ? { status: 'adc', health } : { status: 'foreign' });
        } catch { resolve({ status: 'foreign' }); }
      });
      res.on('error', () => resolve({ status: 'foreign' }));
    });
    req.on('timeout', () => { req.destroy(); resolve({ status: 'foreign' }); });
    req.on('error', (err) => resolve({ status: err.code === 'ECONNREFUSED' ? 'free' : 'foreign' }));
  });
}

module.exports = { spawnDaemon, probeHealth, PORT, DAEMON_SCRIPT };
