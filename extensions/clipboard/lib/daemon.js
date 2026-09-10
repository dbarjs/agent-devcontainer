'use strict';
// The clipboard daemon (ADR-0012): a stateless, read-only HTTP server on the
// Mac's loopback that answers the xclip shim baked into every adc image
// (images/base/xclip). OrbStack exposes 127.0.0.1 to containers as
// host.docker.internal, so any container process can reach it — which is why
// coverage is enforced here, per content kind, and not in the shim.
//
//   GET /health  200 JSON  {adc:"clipboard-daemon", version, pid, coverage}
//   GET /types   200 text  newline list of what /png and /text can deliver
//                         (image/png, text/plain); empty body = nothing
//   GET /png     200 image/png bytes | 404 no image (or a file reference is
//                         on the pasteboard) | 403 images not covered
//   GET /text    200 text/plain utf-8 | 404 no text | 403 text not covered
//
// Anything else is 404; non-GET is 405. There are no write endpoints and no
// file endpoint: the clipboard extension is the sole translator of copied
// files, and /copy reaches the host through OSC 52 without us.

const http = require('node:http');

const NAME = 'clipboard-daemon';

// Which content kinds a raw NSPasteboard type list amounts to, in priority
// order. A file reference hides the image: Finder copies also expose the
// file icon as public.png (issue #49) and the extension pastes the path.
function kinds(types) {
  const out = [];
  const hasFile = types.includes('public.file-url');
  if (!hasFile && (types.includes('public.png') || types.includes('public.tiff'))) out.push('image/png');
  if (types.includes('public.utf8-plain-text') || types.includes('NSStringPboardType')) out.push('text/plain');
  return out;
}

function createDaemon({ coverage, pasteboard, version = '0.0.0', log = () => {} }) {
  const startedAt = Date.now();

  function send(res, code, body, type = 'text/plain; charset=utf-8') {
    res.writeHead(code, {
      'Content-Type': type,
      'Content-Length': Buffer.byteLength(body),
      'Cache-Control': 'no-store',
    });
    res.end(body);
  }

  async function handle(req, res) {
    const url = req.url.split('?')[0];
    if (req.method !== 'GET') return send(res, 405, 'read-only\n');
    switch (url) {
      case '/health':
        return send(res, 200, JSON.stringify({
          adc: NAME, version, pid: process.pid, coverage, uptime: Math.round((Date.now() - startedAt) / 1000),
        }), 'application/json');
      case '/types': {
        const types = await pasteboard.types();
        const served = kinds(types).filter((k) =>
          (k === 'image/png' && coverage.images === 'on') || (k === 'text/plain' && coverage.text === 'on'));
        log(`types raw=${JSON.stringify(types)} -> ${JSON.stringify(served)}`);
        return send(res, 200, served.length ? served.join('\n') + '\n' : '');
      }
      case '/png': {
        if (coverage.images !== 'on') return send(res, 403, 'images are not covered\n');
        const bytes = await pasteboard.png();
        if (!bytes) return send(res, 404, 'no image on the clipboard\n');
        log(`png ${bytes.length} bytes`);
        return send(res, 200, bytes, 'image/png');
      }
      case '/text': {
        if (coverage.text !== 'on') return send(res, 403, 'text is not covered\n');
        const s = await pasteboard.text();
        if (s === null || s === undefined) return send(res, 404, 'no text on the clipboard\n');
        log(`text ${Buffer.byteLength(s)} bytes`);
        return send(res, 200, s);
      }
      default:
        return send(res, 404, 'unknown\n');
    }
  }

  const server = http.createServer((req, res) => {
    const t0 = process.hrtime.bigint();
    handle(req, res)
      .catch((err) => {
        log(`ERROR ${req.method} ${req.url}: ${err.message}`);
        if (!res.headersSent) send(res, 500, `${err.message}\n`);
        else res.destroy();
      })
      .finally(() => {
        const ms = Number(process.hrtime.bigint() - t0) / 1e6;
        log(`${req.method} ${req.url} ${res.statusCode} ${ms.toFixed(0)}ms`);
      });
  });
  server.keepAliveTimeout = 1000;

  return {
    server,
    listen(port, host = '127.0.0.1') {
      return new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(port, host, () => {
          server.off('error', reject);
          resolve(server.address());
        });
      });
    },
    close() {
      return new Promise((resolve) => {
        server.closeAllConnections?.();
        server.close(() => resolve());
      });
    },
  };
}

module.exports = { NAME, createDaemon, kinds };
