# Launcher signal forwarding in the node image (ticket #56, 2026-09-10)

Experiment behind the mechanism decision on [map #52](https://github.com/dbarjs/agent-devcontainer/issues/52):
does a SIGTERM aimed at the *launcher* (`pnpm dev`, `npm run dev`, `nr dev`) reach the dev server, and
which image-owned setting makes it? Run inside `ghcr.io/dbarjs/agent-devcontainer/node:latest`
(node 24.20.0, pnpm 10.15.0, npm 11.19.0, ni 30.5.0, `/bin/sh` = dash 0.5.12), see `nuxt-matrix.sh`
(real Nuxt 4.5.2 / `@nuxt/cli` 3.37.0, launched `setsid nohup pnpm run …` like the #55 repro) and
`sleeper-matrix.sh` (plain node sleeper; its `pgrep -f 'node srv.js'` also matches the `sh -c` line, so
read its "survives" column as the *shell* layer's survival, not the server's).

## Results (SIGTERM → the launcher pid; "survives" = server still listening on 3000 after 4 s)

| launcher | default (`sh -c`) | `script-shell=/bin/bash` | `shell-emulator=true` |
| --- | --- | --- | --- |
| `pnpm run dev` (forked) | **orphan** | clean | clean |
| `pnpm run dev` (`--no-fork` via `TEST=1`) | **orphan** | — | — |
| `npm run dev` | **orphan** (same `sh -c` shape) | clean (bash exec's the command) | n/a (pnpm-only key; npm warns) |
| `nr dev` | **orphan** | **orphan** | **orphan** |
| SIGKILL → any launcher | **orphan** | **orphan** | **orphan** |

## Why

- pnpm's lifecycle runner (`@pnpm/npm-lifecycle` bundled in `pnpm.cjs`) installs
  `process.once('SIGTERM', procKill)` → `proc.kill()`: it forwards SIGTERM to its **direct child only**.
- By default that child is `sh -c <script>`; dash dies on SIGTERM without forwarding anything, so the
  server (dash's child) is orphaned. Verified directly: `sh -c 'node s.js'` + SIGTERM to sh → node keeps
  running and receives no signal at all.
- With `script-shell=/bin/bash`, bash exec's a single simple command, so the server *is* pnpm's direct
  child and gets the forwarded SIGTERM; Nuxt handles it and exits (fork children exit with it).
  `npm_config_script_shell` is honoured from env by both npm 11 and pnpm 10, and npm does **not** warn
  on it (it warns only on keys it doesn't know, e.g. `shell-emulator`).
- `shell-emulator=true` works for pnpm the same way (no shell at all) but is pnpm-only and swaps POSIX
  sh for a JS emulator.
- `nr` (ni 30.5, tinyexec) handles only SIGINT; SIGTERM kills `nr` and leaves `pnpm run` + server alive.
  `nr dev ?` prints the resolved command without running it (an exec wrapper is possible; not chosen).
- SIGKILL cannot be forwarded by anyone; those orphans are the hygiene command's domain.
