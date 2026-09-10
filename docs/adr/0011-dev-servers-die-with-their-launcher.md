# Dev servers die with their launcher; ports are auto-forwarded

`nuxt dev` in a node-image container used to leave three symptoms behind: an orphaned dev server on 3000 after its launcher was killed, a second start silently drifting to 3001, and a VS Code forward on 3000 (or 3001) hanging with nothing behind it. The repro ([issue #55](https://github.com/dbarjs/agent-devcontainer/issues/55)) showed Nuxt itself is single-process on one port; both causes sit in the image and the template, not in any project.

**Launcher-kill orphans.** `pnpm run` and `npm run` forward a SIGTERM only to their *direct* child, and by default that child is `sh -c <script>` — dash on Debian, which exits on SIGTERM without forwarding it. The server underneath is reparented to PID 1 and keeps its port. The fix is `script-shell=/bin/bash`: bash exec's a single simple command instead of forking it, so the dev server *is* the launcher's direct child and receives the forwarded signal. The node image sets it on every surface the package managers actually read (verified per version in [issue #59](https://github.com/dbarjs/agent-devcontainer/issues/59)):

| surface (image-owned)                                   | reaches            |
| ------------------------------------------------------- | ------------------ |
| `containerEnv.npm_config_script_shell` (devcontainer.json) | npm, pnpm ≤ 10    |
| `~/.config/pnpm/rc` (`script-shell=`)                   | pnpm ≤ 10          |
| `~/.config/pnpm/config.yaml` (`scriptShell:`)           | pnpm 11            |

Env rather than a global `.npmrc` for npm because the env rides image metadata next to the other node knobs and npm does not warn on this key; the pnpm files exist already for the shared store, so the key rides along. A project can still override any of them in its own `.npmrc` / `pnpm-workspace.yaml`. Rejected: pnpm's `shell-emulator` (pnpm-only, replaces POSIX sh with a JS emulator), a `NODE_OPTIONS=--require` shim that appends `--no-fork` (Nuxt-specific and hits every Node process), a `pnpm`/`nr` wrapper on PATH (`node_modules/.bin` is prepended ahead of it), and accepting orphans with a cleanup daemon (no init system; would kill servers an agent deliberately leaves running).

**Ghost forwards.** The template's static `forwardPorts: [3000]` made VS Code hold a host listener whether or not anything listened in the container: connections completed the TCP handshake and then hung, and a second window found host 3000 busy and silently remapped to 3001 ([issue #54](https://github.com/dbarjs/agent-devcontainer/issues/54)). Nothing inside a container can close a forward, so the template no longer declares one. Under process-scan auto-forwarding a forward appears with the listener and is torn down with it, and the image pins `remote.autoForwardPortsSource: "process"` so the 20-port fallback can never flip detection to hybrid. No `portsAttributes`.

## Consequences

Run-scripts execute under bash instead of dash inside the container: bash-isms in a script work here but would fail on a dash host. Coverage is exactly "single simple command started by `pnpm run` / `npm run`" (`nuxt dev`, `vite`, `next dev`, `astro dev`, `node server.js`): a compound script (`a && b`) keeps a bash layer that forwards nothing, `nr` (ni forwards SIGINT only) and SIGKILL of the launcher never reach the server, and **pnpm ≥ 12 orphans regardless** — its native binary runs behind a JS shim and neither layer forwards SIGTERM or SIGINT to the script, so `scriptShell` only removes the `sh` layer. Those cases belong to the adc port-hygiene command ([issue #57](https://github.com/dbarjs/agent-devcontainer/issues/57)). The forward now appears only once the server is up, which is the point.

Decided in [issue #56](https://github.com/dbarjs/agent-devcontainer/issues/56) ([map v4](https://github.com/dbarjs/agent-devcontainer/issues/52)), on the kill matrix in `docs/research/launcher-signals/` (`research/nuxt-repro`); the per-version pnpm surfaces and the pnpm 12 limit were found while implementing [issue #59](https://github.com/dbarjs/agent-devcontainer/issues/59).
