# adc clipboard

The **clipboard extension** of [ADR-0012](../../docs/adr/0012-host-clipboard-readable-from-containers.md): a private, UI-side VS Code extension that gives Claude Code CLI inside an adc devcontainer the host's paste gestures. This folder is the daemon half (issue #62); the Cmd+V handler (issue #63) lands next to it.

## What it does

In every Dev Container window (`vscode.env.remoteName` starts with `dev-container`) the extension:

- reads the **coverage** settings `adc.clipboard.images` (default on), `adc.clipboard.files` (default `any`), `adc.clipboard.text` (default off) at **user scope**;
- runs the **clipboard daemon**, `bin/adc-clipd.js`, on `127.0.0.1:47820` with that coverage as spawn arguments, and restarts it when the settings change;
- when the port is taken, asks `GET /health` who owns it: another window's adc daemon means this window stands by and retakes the port when that window closes; anything else is a status-bar warning.

The daemon dies with the window: it exits when its stdin pipe closes, so no window means no daemon.

## The daemon

Stateless and read-only. One `osascript -l JavaScript` call per request reads NSPasteboard.

| Request | Answer |
| --- | --- |
| `GET /health` | `200` JSON: `adc: "clipboard-daemon"`, `version`, `pid`, `coverage` |
| `GET /types` | `200` newline list of `image/png` and/or `text/plain`; empty body when nothing is served |
| `GET /png` | `200` PNG bytes (TIFF converted host-side); `404` no image; `403` images not covered |
| `GET /text` | `200` UTF-8 text; `404` no text; `403` text not covered |

A file reference on the pasteboard (`public.file-url`) hides any image: a Finder copy carries the file's icon as `public.png`, and copied files are the extension's business, not the daemon's. There is no file endpoint and no write endpoint. Coverage is enforced here because every container process can reach the port, not only Claude Code.

Run it by hand for a look:

```sh
node bin/adc-clipd.js --images on --files any --text off
curl -s http://127.0.0.1:47820/health
docker run --rm ghcr.io/dbarjs/agent-devcontainer/base:latest xclip -selection clipboard -t TARGETS -o
```

## Layout

```
extension.js        activation: Dev Container gate, settings, status bar, supervisor wiring
bin/adc-clipd.js    daemon entry point (spawned by the extension)
lib/coverage.js     the three keys, their domains, defaults, argv encoding
lib/daemon.js       the HTTP server and its contract
lib/pasteboard.js   JXA reads of NSPasteboard (macOS only)
lib/supervisor.js   port supervision state machine, side effects injected
lib/host.js         real spawn and /health probe
test/               node --test; runs on Linux too (pasteboard is faked)
```

`npm test` runs the suite, including the real `images/base/xclip` shim under `sh` against this daemon. No dependencies, no build step.
