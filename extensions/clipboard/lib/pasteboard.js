'use strict';
// The macOS pasteboard, read through one `osascript -l JavaScript` (JXA)
// process per call. AppKit's NSPasteboard is the only reader that sees every
// type at once (pbpaste is text-only); each function below is one osascript
// spawn and returns plain JS values, so the daemon stays stateless and the
// pasteboard is never held open between requests.

const { execFile } = require('node:child_process');

const PRELUDE = 'ObjC.import("AppKit"); ObjC.import("Foundation"); const pb = $.NSPasteboard.generalPasteboard;';
const TIMEOUT_MS = 5000; // the shim gives up at 1.5 s; this only bounds a wedged osascript
const MAX_BUFFER = 256 * 1024 * 1024; // base64 of a large screenshot

const TYPES_SNIPPET = 'JSON.stringify(ObjC.deepUnwrap(pb.types) || [])';

// PNG bytes as base64, or null. A file reference on the pasteboard wins over
// an image (a Finder copy also exposes the file icon as public.png, issue #49),
// so this snippet re-checks the types in the same read rather than trusting a
// previous /types answer. TIFF-only images are converted host-side.
const PNG_SNIPPET = `
  const types = ObjC.deepUnwrap(pb.types) || [];
  let out = null;
  if (!types.includes("public.file-url")) {
    let d = pb.dataForType("public.png");
    if (!d || d.isNil()) {
      const tiff = pb.dataForType("public.tiff");
      if (tiff && !tiff.isNil()) {
        const rep = $.NSBitmapImageRep.imageRepWithData(tiff);
        if (rep && !rep.isNil()) d = rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $());
      }
    }
    if (d && !d.isNil() && d.length > 0) out = ObjC.unwrap(d.base64EncodedStringWithOptions(0));
  }
  JSON.stringify(out)`;

const TEXT_SNIPPET = 'const s = pb.stringForType("public.utf8-plain-text"); JSON.stringify(s.isNil() ? null : ObjC.unwrap(s))';

function jxa(snippet) {
  return new Promise((resolve, reject) => {
    execFile(
      'osascript',
      ['-l', 'JavaScript', '-e', PRELUDE + snippet],
      { timeout: TIMEOUT_MS, maxBuffer: MAX_BUFFER, encoding: 'utf8' },
      (err, stdout, stderr) => {
        if (err) return reject(new Error(`osascript failed: ${(stderr || err.message).trim()}`));
        try { resolve(JSON.parse(stdout)); } catch (e) { reject(new Error(`osascript returned no JSON: ${stdout.slice(0, 200)}`)); }
      },
    );
  });
}

// Raw NSPasteboard type identifiers, e.g. ["public.png", "public.tiff"].
async function types() {
  const t = await jxa(TYPES_SNIPPET);
  return Array.isArray(t) ? t : [];
}

// Buffer of PNG bytes, or null when the pasteboard holds no image (or a file).
async function png() {
  const b64 = await jxa(PNG_SNIPPET);
  return typeof b64 === 'string' && b64.length > 0 ? Buffer.from(b64, 'base64') : null;
}

// Plain-text string, or null.
async function text() {
  const s = await jxa(TEXT_SNIPPET);
  return typeof s === 'string' ? s : null;
}

module.exports = { types, png, text };
