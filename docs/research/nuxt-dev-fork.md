# Nuxt dev fork mode: ports, orphans, and a zero-touch switch

Research for [#53](https://github.com/dbarjs/agent-devcontainer/issues/53), part of map [#52](https://github.com/dbarjs/agent-devcontainer/issues/52). Researched 2026-09-10.

Question: what exactly does Nuxt's forked dev mode do, and is there a way to disable it from the container environment without touching the project?

Sources are `@nuxt/cli`/`nuxi` source at specific tags (github.com/nuxt/cli), the published `@nuxt/cli@3.37.0` tarball (unpacked and grepped locally), the Nuxt docs, and the source of the libraries nuxi delegates to (`listhen`, `get-port-please`, `std-env`, `citty`). Every version claim below is anchored to a tag or a merged PR. "Current stable" = `@nuxt/cli@3.37.0` (npm `latest`, published 2026-07-14); `4.0.0-alpha.1` (2026-09-03) is the `alpha` tag and is the `packages/nuxt-cli` source on `main`.

## Summary / answers

1. **Mechanism.** It changed twice. **nuxi 3.7.0–3.25.1**: the parent binds `--port` (3000) and runs an `httpxy` proxy; the child (`nuxi _dev`) listens on `127.0.0.1` with `port: 0`, i.e. a **random ephemeral port**. **3.26.0–3.29.3**: same proxy, but the child listens on a **unix socket** (`get-port-please`'s `getSocketAddress({ name: 'nuxt-dev', random: true })`) — no second TCP port at all. **3.30.0 and later (incl. current 3.37.0)**: the **proxy is gone**. The parent binds the port itself and serves the app in-process; forks are a pre-warmed pool that only takes over on a *hard* restart, and the incoming fork **binds the same port** (3000). So today there is normally one TCP listener — but during a handover a second one can appear, and `listhen` will silently place it on **3001** (see §2).
2. **Versions.** Fork mode arrived in **nuxi 3.7.0** (PR [#81](https://github.com/nuxt/cli/pull/81), 2023-08-24) with **no opt-out**; `--no-fork` was added in **3.8.0** (PRs [#153](https://github.com/nuxt/cli/pull/153)/[#154](https://github.com/nuxt/cli/pull/154), 2023-09-07) and has been on by default ever since (`default: forkSupported`). It is **not deprecated**: still present, still documented, still defaulted-on in `4.0.0-alpha.1`. It is still needed, in the sense that nothing else turns forking off. Both current Nuxt 3 (`nuxt@3.21.11`) and Nuxt 4 (`nuxt@4.5.2`) depend on `@nuxt/cli: ^3.37.0`, and even `nuxt@4.0.0`'s `^3.26.1` caret resolves to 3.37.0 today — so effectively every fresh install is on the ≥3.30 direct-listening architecture.
3. **Zero-touch switch — no dedicated env var exists.** There is no `NUXT_NO_FORK`/`NUXI_*`, no `.nuxtrc` key, and citty does not read args from the environment. The complete env-var surface of `@nuxt/cli@3.37.0` is 25 names, and the only fork-related one (`__NUXT__FORK`) is set *by* the parent *on* the child. **But `--fork`'s default is computed at runtime from `std-env`'s `isTest`** (`const forkSupported = !isTest && (!isBun || isBunForkSupported())`), and `isTest = nodeENV === "test" || !!env.TEST`. So **`TEST=1` in the container environment disables fork mode with zero project changes** — with real side effects (it also makes `listhen` stop printing the dev URL and sets `nuxt.options.test = true`, so `import.meta.test` is `true` in app code). §3 enumerates that plus the `NODE_OPTIONS` preload, the PATH shim (which does *not* work for `pnpm dev`), and the rest, with downsides.
4. **Orphans.** `child_process.fork()` with no `detached`, so the child stays in the parent's process group: an interactive **Ctrl+C reaches parent and child directly** and is fine. The parent installs `process.once()` handlers for `exit`, `SIGTERM`, `SIGINT`, `SIGQUIT` only. Children are orphaned when the parent dies by **`SIGKILL`**, by **`SIGHUP`** (no handler — closed terminal, dropped SSH), or when the parent **exits normally**: the `exit` branch calls `kill(0)`, and **signal 0 does not terminate anything** — it is a liveness probe. 4.0.0-alpha fixes exactly this ("signal 0 only probes for liveness, so map the `exit` case onto a real signal") plus SIGTERM→SIGKILL escalation.
5. **What `--no-fork` costs.** Only **hard restarts**: with `--no-fork` the CLI returns before wiring `onRestart`, so a change to `nuxt.config.*` / `.nuxtrc` / `.nuxtignore` / `.config/nuxt.config.*`, a module's `callHook('restart', { hard: true })`, and crash-recovery on `uncaughtException`/`unhandledRejection` no longer restart the server — you restart by hand. HMR, soft reloads and file watching are unaffected (they run in the serving process either way). On ≤3.29 you also lose the proxy's "Nuxt is starting…" loading page during restarts. On ≥3.30 you additionally skip the pre-warmed pool (one or two idle Node processes), which is a *saving* in a container.
6. **Other frameworks.** **Next.js forks too** (`next dev` → `fork(start-server)`) but the **child binds the port and the parent binds nothing**, so there is only ever one listener — no port confusion. **Vite** and **Astro** are single-process (`createServer()` + `server.listen()` in-process). **Vitest** forks/threads its test workers, but they talk over IPC and never bind an HTTP port. The parent-listens-*and*-child-listens pattern is **Nuxt-specific**, and even in Nuxt only in 3.7–3.25 (proxy → random port) and transiently in ≥3.30 (handover).

## 1. Architecture by version

| nuxi / `@nuxt/cli` | Released | Parent | Child / fork | Second TCP port? |
| --- | --- | --- | --- | --- |
| 3.7.0 | 2023-08-25 | `listhen` on `--port`, `httpxy` proxy | `nuxi _dev`, `listen(handler, { port: 0, hostname: '127.0.0.1', showURL: false })` | yes — **random ephemeral** |
| 3.8.0 – 3.25.1 | 2023-09-07 → 2025-05-12 | same (+ `--no-fork` opt-out from 3.8.0) | same | yes — **random ephemeral** |
| 3.26.0 – 3.29.3 | 2025-07-14 → 2025-10-09 | same proxy | **unix socket** via `getSocketAddress({ name: 'nuxt-dev', random: true })` | **no** |
| 3.30.0 – 3.37.0 | 2025-11-03 → 2026-07-14 | **serves the app itself** on `--port`; `ForkPool` warms 2 idle forks | idle until a hard restart, then binds **the same port** | only during handover (→ **3001**) |
| 4.0.0-alpha.x | 2026-08-24 → | same, pool size 1, `SO_REUSEPORT` handover, `--takeover`, `--strictPort` | binds the same port, pinned (`{ port: listener.address.port, handover: true }`) | no (that is the point of `reusePort`) |

Key source lines:

- Proxy era — [`src/commands/dev.ts` @ v3.9.0](https://github.com/nuxt/cli/blob/v3.9.0/src/commands/dev.ts): `_createDevProxy()` does `const listener = await listen(handler, listenOptions)` (L135) and the IPC handler sets the proxy target from the child's reported port: ``devProxy.setAddress(`http://127.0.0.1:${message.port}`)`` (L197). The child's port comes from [`src/utils/dev.ts` @ v3.9.0](https://github.com/nuxt/cli/blob/v3.9.0/src/utils/dev.ts) L53-60: `listen(devServer.handler, listenOptions || { port: options.port ?? 0, hostname: '127.0.0.1', showURL: false })`, and [`src/commands/dev-child.ts` @ v3.9.0](https://github.com/nuxt/cli/blob/v3.9.0/src/commands/dev-child.ts) passes `port: process.env._PORT ?? undefined` — so `0`, i.e. random, unless `@nuxt/test-utils` set `_PORT`. The same wiring survives unchanged to v3.21.0 (`packages/nuxi/src/commands/dev.ts` L166-225).
- Socket era — [`packages/nuxi/src/dev/socket.ts` @ v3.29.3](https://github.com/nuxt/cli/blob/v3.29.3/packages/nuxi/src/dev/socket.ts) L33-41: `const socketPath = getSocketAddress({ name: 'nuxt-dev', random: true })` … `server.listen({ path: socketPath })`, URL formatted as `http+unix://…`. Introduced by [PR #921 "perf(dev): use socket to proxy connections to dev server"](https://github.com/nuxt/cli/pull/921) (2025-07-01, first released in v3.26.0) and refined by [#952](https://github.com/nuxt/cli/pull/952)/[#973](https://github.com/nuxt/cli/pull/973).
- Direct-listening era — [PR #1105 "refactor(dev): remove proxy server in favour of direct listening"](https://github.com/nuxt/cli/pull/1105) (2025-10-30) added `packages/nuxi/src/dev/pool.ts`; it is absent at v3.29.3 and present at v3.30.0. In [`packages/nuxi/src/commands/dev.ts` @ v3.37.0](https://github.com/nuxt/cli/blob/v3.37.0/packages/nuxi/src/commands/dev.ts) the whole flow is:

  ```ts
  // Start the initial dev server in-process with listener
  const { listener, close, onRestart, onReady } = await initialize({ cwd, args: ctx.args }, {
    data: ctx.data, listenOverrides, showBanner: true,
  })
  if (!ctx.args.fork || ctx.args.profile) { return { listener, close } }
  const pool = new ForkPool({ rawArgs: ctx.rawArgs, poolSize: 2, listenOverrides })
  onReady((_address) => { pool.startWarming() })
  onRestart(async () => { await close(); await restartWithFork() })
  ```

  The forks receive the *same* `listenOverrides` over IPC (`sendContext` → `{ type: 'nuxt:internal:dev:context', listenOverrides, context }`), and [`packages/nuxi/src/dev/utils.ts` @ v3.37.0](https://github.com/nuxt/cli/blob/v3.37.0/packages/nuxi/src/dev/utils.ts) L268 resolves `const port = overrides.port ?? nuxtConfig.devServer?.port` before `listen()`. So the incoming fork asks for 3000, not for a random port.
- **Warm forks do not listen.** [`packages/nuxi/src/dev/index.ts` @ v3.37.0](https://github.com/nuxt/cli/blob/v3.37.0/packages/nuxi/src/dev/index.ts) L22-47: the fork constructs an `IPC`, immediately sends `nuxt:internal:dev:fork-ready`, and only calls `initialize()` when a `nuxt:internal:dev:context` message arrives. A warm fork is therefore an idle Node process holding the CLI entry in memory (≈2 of them on 3.30–3.37), not a server.

## 2. Where "3001" comes from

Nuxi never picks 3001. `listhen` does, and it does so **silently by default**.

[`unjs/listhen` `src/listen.ts`](https://github.com/unjs/listhen/blob/main/src/listen.ts) L108-116:

```ts
const port = (listhenOptions.port = await getPort({
  port: Number(listhenOptions.port),
  verbose: !listhenOptions.isTest,
  host: listhenOptions.hostname,
  ...(listhenOptions.isProd ? { random: false } : { alternativePortRange: [3000, 3100] }),
  ...
}));
```

and [`unjs/get-port-please` `src/get-port.ts`](https://github.com/unjs/get-port-please/blob/main/src/get-port.ts):

```ts
let availablePort = await _findPort(portsToCheck, options.host);
// Try fallback port range
if (!availablePort && options.alternativePortRange.length > 0) {
  availablePort = await _findPort(_generateRange(...options.alternativePortRange), options.host);
  // "Unable to find an available port (tried …). Using alternative port ${availablePort}."
}
```

Because listhen passes `alternativePortRange: [3000, 3100]` explicitly in dev mode, the fallback applies **even when the port was requested explicitly** (`--port 3000`): getPort's own "user specified a port ⇒ no alternative range" default (`alternativePortRange: _userSpecifiedAnyPort ? [] : [3000, 3100]`) is overridden by listhen's spread. The first free port after a busy 3000 is **3001**.

Two ways a devcontainer gets a live 3001 while the terminal still shows 3000:

- **Handover race (nuxi ≥3.30).** On a hard restart the parent closes its listener and the incoming fork binds the same port. If the old listening socket has not been released at that instant, the fork lands on 3001 and *stays* there for the rest of the session. This failure mode is what 4.0.0-alpha's `SO_REUSEPORT` handover was written to eliminate — [`packages/nuxt-cli/src/commands/dev.ts` @ main](https://github.com/nuxt/cli/blob/main/packages/nuxt-cli/src/commands/dev.ts) L207-211: *"With `SO_REUSEPORT` an incoming fork can bind the port before this process releases it, so a hard restart never leaves the port unserved."* — and L329-334, where the handover fork is given `{ port: listener.address.port, handover: true }` so it cannot drift.
- **Stale orphan holding 3000.** An orphaned fork from an earlier session keeps 3000 bound; the next `nuxt dev` then starts on 3001. See §4.

VS Code's process-scan auto-forwarding sees the new listener and forwards 3001; when the process behind it dies (or was already dead), the forward remains as a ghost — the map's symptoms (2) and (3).

Note the fork does **not** re-print the Nuxt banner (`showBanner: ctx.showBanner !== false && !ipc.enabled`), though listhen's own `showURL` block is not suppressed for forks in 3.37.0. Exactly what the terminal shows in the drifted case should be pinned down by the repro ticket rather than inferred from source.

## 3. Zero-touch switch

### What does not exist

- **No fork-related env var.** Grepping every `process.env.X` in the published `@nuxt/cli@3.37.0` `dist/` yields exactly: `NODE_ENV`, `DEBUG`, `COREPACK_NPM_REGISTRY`, `PORT`, `NUXT_PORT`, `NUXT_LOCK`, `NITRO_PORT`, `GITHUB_TOKEN`, `_PORT`, `SERVER_PRESET`, `NUXT_SSL_KEY`, `NUXT_SSL_CERT`, `NUXT_IGNORE_LOCK`, `NUXT_HOST`, `NUXI_INIT_REGISTRY`, `NUXI_DISABLE_VITE_HMR`, `npm_config_user_agent`, `NODE_TLS_REJECT_UNAUTHORIZED`, `NODE_PATH`, `NITRO_SSL_KEY`, `NITRO_SSL_CERT`, `NITRO_PRESET`, `NITRO_HOST`, `HOST`, `CI`, `__NUXT__FORK`. `__NUXT__FORK` is set *by* the parent when forking (`env: { ...process.env, __NUXT__FORK: 'true' }`) and only read as `enabled = !!process.send && … && process.env.__NUXT__FORK` — setting it yourself does nothing in the parent (no `process.send`).
- **No config-file route.** `--fork` is a citty CLI arg; citty parses `process.argv` only and has no env-var or rc-file binding. `.nuxtrc` (and the global `~/.nuxtrc` that c12 reads) feeds `loadNuxtConfig`, i.e. `nuxt.config` keys — there is no `devServer.fork`.
- **`NUXT_DEV_FORK_POOL_SIZE` is not a kill switch.** New in 4.0.0-alpha (`resolveForkPoolSize()` in [`packages/nuxt-cli/src/commands/dev.ts`](https://github.com/nuxt/cli/blob/main/packages/nuxt-cli/src/commands/dev.ts) L505-515, commit `18979683` "perf(dev): warm a single fork by default, overridable with NUXT_DEV_FORK_POOL_SIZE"). `0` stops *pre-warming*, but `getFork()` still spawns a cold fork on a hard restart. Also: alpha only.

### What does exist: `TEST=1` (or `NODE_ENV=test`)

`--fork`'s default is not a constant. [`packages/nuxi/src/commands/dev.ts` @ v3.37.0](https://github.com/nuxt/cli/blob/v3.37.0/packages/nuxi/src/commands/dev.ts) L19-20 and L41-46:

```ts
const forkSupported = !isTest && (!isBun || isBunForkSupported())
…
fork: {
  type: 'boolean',
  description: forkSupported ? 'Disable forked mode' : 'Enable forked mode',
  negativeDescription: 'Disable forked mode',
  default: forkSupported,
  alias: ['f'],
},
```

This survives bundling — the shipped `dist/dev-Cbii5ek4.mjs` L139 is literally `const forkSupported = !isTest && (!isBun || isBunForkSupported());` with `import { isBun, isDeno, isTest } from "std-env"` at L7 — so it is evaluated at runtime from the environment, not inlined at build time. And [`unjs/std-env` `src/flags.ts`](https://github.com/unjs/std-env/blob/main/src/flags.ts) L22-23:

```ts
/** Detect if `NODE_ENV` environment variable is `test` or `TEST` environment variable is set */
export const isTest: boolean = nodeENV === "test" || !!env.TEST;
```

So `ENV TEST=1` in the image disables forking for every `nuxt dev`, with no project change. This has been the shape of the default since 3.8.0 ([#154](https://github.com/nuxt/cli/pull/154) "disable forked mode by default for bun and test").

**Downsides — this is a leaky switch.** `std-env`'s `isTest` is a shared signal:

- `listhen` defaults `isTest` from std-env and then does `if (listhenOptions.isTest) { listhenOptions.showURL = false }` (plus `open`/`clipboard` off) — **Nuxt would stop printing the dev URL**, a DX regression that also removes the only output-based signal about which port is live.
- Nuxt's schema resolves `test: { $resolve: val => typeof val === 'boolean' ? val : Boolean(isTest) }` ([`packages/schema/src/config/common.ts`](https://github.com/nuxt/nuxt/blob/main/packages/schema/src/config/common.ts) L124-126), and Vite's `define` maps that to `process.test` / `import.meta.test` ([`config/vite.ts`](https://github.com/nuxt/nuxt/blob/main/packages/schema/src/config/vite.ts) L17-27). **App code that branches on `import.meta.test` would take the test branch in normal development.**
- `TEST` is a generic name owned by nobody; setting it image-wide can confuse other tooling, and `NODE_ENV=test` is worse still (Vite/Nuxt/third-party modules all read it, even though nuxi later calls `overrideEnv('development')` for the app).

Verdict: it works and it is genuinely zero-touch, but it buys fork-disabling by telling the whole toolchain this is a test run. Only pick it if the mechanism grilling decides the side effects are acceptable.

### Container-level alternatives that leave the project untouched

| Mechanism | Works? | Downsides |
| --- | --- | --- |
| **`NODE_OPTIONS=--require /opt/adc/nuxt-no-fork.cjs`** — preload that appends `--no-fork` to `process.argv` when argv looks like `nuxi/nuxt … dev` | Yes, and it is precise (only touches `nuxt dev`) | `--require, -r` and `--import` are on Node's NODE_OPTIONS allowlist ([`doc/api/cli.md`](https://github.com/nodejs/node/blob/main/doc/api/cli.md), whose own example is `NODE_OPTIONS='--require "./my path/file.js"'`), but NODE_OPTIONS is inherited by **every** Node process in the container (vite, eslint, vitest, and the forks themselves) — the shim must be tiny, `try/catch`-wrapped and idempotent. It also silently changes what a documented command does, which is hard to debug from inside a project. Detection must key on the resolved bin path *and* the `dev` subcommand, and must not fire when the user passed `--fork` explicitly. |
| **PATH shim** (`/usr/local/bin/nuxt` wrapper adding `--no-fork`) | **No** for the common case | npm/pnpm/yarn prepend `node_modules/.bin` to `PATH` for run-scripts ([npm docs, *Scripts*](https://docs.npmjs.com/cli/v11/using-npm/scripts): "If you depend on modules that define executable scripts, like test suites, then those executables will be added to the `PATH` for executing the scripts"), so `pnpm dev` → `nuxt dev` resolves the **local** binary and never sees the shim. Only a bare `nuxt dev` typed at a shell would be intercepted. |
| **`TEST=1`** (see above) | Yes | Suppresses the dev URL banner; sets `nuxt.options.test` / `import.meta.test`; generic name with cross-tool blast radius. |
| **`NODE_ENV=test`** | Yes (same `isTest` path) | Everything above, plus every `NODE_ENV`-sniffing library in the stack. Not recommended. |
| **zsh alias / `preexec` rewrite of `pnpm dev`** | No | Interactive shells only; an agent's Bash tool and any non-interactive script bypass it entirely. |
| **`portsAttributes` / `otherPortsAttributes` with `onAutoForward: "ignore"` for 3001** in the adc template's `devcontainer.json` | Mitigates symptoms 2+3, does not fix the cause | Leaves a real server running on an unforwarded port when the drift happens; hides a genuine second listener; is a per-project surface (template), which the map only allows for genuinely per-project values. |
| **`adc` wrapper command** (`adc dev` → `nuxt dev --no-fork`) | Yes | Not zero-touch in practice: it asks the human/agent to type something other than the project's own `pnpm dev`. Fine as a backstop, not as the mechanism. |
| **Upgrade path (no image change)** | Partially | `@nuxt/cli` 4.0.0-alpha's `SO_REUSEPORT` handover removes the port-drift cause and its `killFork` reaps properly — but it is an alpha, and pinning a project's CLI version is a project change. |

## 4. Orphans

**Wiring.** [`packages/nuxi/src/dev/pool.ts` @ v3.37.0](https://github.com/nuxt/cli/blob/v3.37.0/packages/nuxi/src/dev/pool.ts) L131-138:

```ts
const childProc = fork(globalThis.__nuxt_cli__.devEntry!, this.rawArgs, {
  execArgv: ['--enable-source-maps', process.argv.find(a => a.includes('--inspect'))].filter(Boolean),
  env: { ...process.env, __NUXT__FORK: 'true' },
})
```

No `detached: true`, so the child inherits the parent's process group and session. Communication is Node's IPC channel; `stdout`/`stderr` are inherited.

**Shutdown handlers** (same file, L34-44 and L186-192):

```ts
for (const signal of ['exit', 'SIGTERM', 'SIGINT', 'SIGQUIT'] as const) {
  process.once(signal, () => { this.killAll(signal === 'exit' ? 0 : signal) })
}
…
private killFork(fork: PooledFork, signal: NodeJS.Signals | number = 'SIGTERM'): void {
  fork.state = 'dead'
  if (fork.process) { fork.process.kill(signal === 0 && isDeno ? 'SIGTERM' : signal) }
  this.removeFork(fork)
}
```

**When children survive:**

| Parent dies by | Child outcome |
| --- | --- |
| Ctrl+C in an interactive terminal | Killed. SIGINT goes to the whole foreground process group, so the child gets it directly (the parent's `killAll(SIGINT)` is belt-and-braces). |
| `kill <pid>` (SIGTERM to the parent only) | Killed by the parent's handler. |
| `kill -9 <pid>` (SIGKILL) | **Orphaned.** No handler can run. Reparented to PID 1; keeps the port. |
| SIGHUP — terminal/SSH closed, container `exec` session ends | **Orphaned.** SIGHUP is not in the handled list; Node's default action terminates the parent without running `killAll`. |
| Parent exits normally, including `process.exit(errorCode)` when an active fork crashes | **Orphaned.** The `exit` branch calls `killFork(fork, 0)` → `fork.process.kill(0)`, and signal 0 only tests for the existence of a process; on Node it kills nothing. Remaining pooled/warm forks survive. |
| A tool that SIGKILLs only the direct child of its shell (e.g. a Bash-tool timeout that does not signal the process group) | **Orphaned**, same as SIGKILL. If the tool kills the whole process group, both die. |

**Confirmed upstream.** 4.0.0-alpha rewrote precisely this. [`packages/nuxt-cli/src/dev/pool.ts` @ main](https://github.com/nuxt/cli/blob/main/packages/nuxt-cli/src/dev/pool.ts):

```ts
// last-resort for forks that outlive this process. nuxt closes forks gracefully
// on `SIGINT`/`SIGTERM`, so we skip them.
for (const signal of ['exit', 'SIGQUIT'] as const) { … }
…
// signal 0 only probes for liveness, so map the `exit` case onto a real signal
fork.process.kill(signal === 0 ? 'SIGTERM' : signal)
```

plus a SIGTERM → wait → SIGKILL escalation ([`dev/shutdown.ts`](https://github.com/nuxt/cli/blob/main/packages/nuxt-cli/src/dev/shutdown.ts): `DEV_SHUTDOWN_TIMEOUT_MS = 10_000`, `SUPERVISOR_SHUTDOWN_TIMEOUT_MS = 15_000`, `FORCE_KILL_TIMEOUT_MS = 2000`). The commit titles say it outright: `c16f02ba` "fix(dev): reap every pooled fork on shutdown", `dfef70fc` "fix(dev): track cold forks in the pool so shutdown reaps them" (both 2026-07-27, unreleased on the 3.x line).

**Bonus, directly useful to the map's port-hygiene ticket:** nuxi 3.37.0 ships a dev lock file. [`packages/nuxi/src/utils/lockfile.ts`](https://github.com/nuxt/cli/blob/v3.37.0/packages/nuxi/src/utils/lockfile.ts) writes `<buildDir>/nuxt.lock` (i.e. `.nuxt/nuxt.lock`) containing `{ pid, startedAt, command, cwd, port, hostname, url }`, uses `process.kill(pid, 0)` for liveness, and:

```ts
/**
 * Locking is enabled for agents by default. `NUXT_LOCK=1` forces it on for
 * non-agents; `NUXT_IGNORE_LOCK=1` forces it off.
 */
export function isLockEnabled(): boolean {
  if (process.env.NUXT_IGNORE_LOCK) { return false }
  if (process.env.NUXT_LOCK === '1' || process.env.NUXT_LOCK === 'true') { return true }
  return isAgent
}
```

`isAgent` comes from std-env, which detects Claude Code via `CLAUDECODE` / `CLAUDE_CODE` ([`src/agents.ts`](https://github.com/unjs/std-env/blob/main/src/agents.ts): `["claude", ["CLAUDECODE", "CLAUDE_CODE"]]`). So **inside an in-container Claude Code session the lock is on by default**, and a stale orphan makes the next `nuxt dev` fail with `Another Nuxt dev server is already running:` followed by URL / PID / Dir / Started and `Run `kill <pid>` to stop it, or connect to <url>` / `Set NUXT_IGNORE_LOCK=1 to bypass this check.` `.nuxt/nuxt.lock` is a ready-made, structured input for an `adc` port-hygiene command.

## 5. What `--no-fork` costs

In `--no-fork` mode the CLI returns immediately after starting the in-process server and never registers `onRestart`:

```ts
if (!ctx.args.fork || ctx.args.profile) { return { listener, close } }
```

`onRestart` is the only consumer of the dev server's `restart` event and of `uncaughtException`/`unhandledRejection` ([`packages/nuxi/src/dev/index.ts` @ v3.37.0](https://github.com/nuxt/cli/blob/v3.37.0/packages/nuxi/src/dev/index.ts) L151-162). The `restart` event is emitted for:

- a change to a file matching `RESTART_RE = /^(?:nuxt\.config\.[a-z0-9]+|\.nuxtignore|\.nuxtrc|\.config\/nuxt(?:\.config)?\.[a-z0-9]+)$/` (config watcher), and
- `nuxt.hooks.hook('restart', …)` with `options.hard` — a module asking for a hard restart. Non-hard restarts call `this.load(true)` in-process and are unaffected.

So the cost is: **config edits and module-requested hard restarts stop taking effect until you restart the server by hand**, and a crash is fatal instead of self-healing. Everything else — HMR, soft reload, watching, the loading page rendered by the serving process — is identical. On ≤3.29 you additionally lose the proxy's ability to hold connections open and show "Nuxt is starting…" across a restart (the `--no-fork` path had already skipped the proxy since [#207](https://github.com/nuxt/cli/pull/207) "perf(dev): avoid using proxy with `--no-fork` mode", 2023-09-20). On ≥3.30 `--no-fork` also skips the fork pool, i.e. saves one or two idle Node processes per dev server — worth having in a container.

Worth noting for the "browser DX is badly compromised" symptom: the proxy era generated a stream of devcontainer/WSL-specific bug reports — [nuxt/cli#181](https://github.com/nuxt/cli/issues/181) "Nuxt 3.7+ : net::ERR_CONTENT_LENGTH_MISMATCH with VS Code Devcontainer", [#118](https://github.com/nuxt/cli/issues/118) "3.7.0 - net::ERR_CONNECTION_RESET [WSL2, Docker]", [#209](https://github.com/nuxt/cli/issues/209) "Having issues with slow responses with `nuxi dev`", [#279](https://github.com/nuxt/cli/issues/279) "`nuxi dev` causes requests to stay 'Pending'" — all filed against the era when every request crossed an `httpxy` proxy. On ≥3.30 that proxy no longer exists, so a modern install should not show proxy-induced DX damage; if it does, that is evidence the project is pinned to an older CLI.

## 6. Other frameworks

- **Next.js — forks, but only the child listens.** [`packages/next/src/cli/next-dev.ts`](https://github.com/vercel/next.js/blob/canary/packages/next/src/cli/next-dev.ts): `import { fork } from 'child_process'`; `const startServerPath = require.resolve('../server/lib/start-server')`; `child = fork(startServerPath, { … })`, with the port handed over via IPC (`child?.send({ nextWorkerOptions: startServerOptions })`). The parent binds nothing, so there is exactly one listening port. It also reaps harder than nuxi 3.x: `process.on('SIGINT'|'SIGTERM', …)` plus an `exit` path doing `child?.kill('SIGKILL')` with the comment "Catch aggressive kills (e.g. OOM, unhandled exception) that bypass handleSessionStop".
- **Vite — single process.** [`packages/vite/src/node/cli.ts`](https://github.com/vitejs/vite/blob/main/packages/vite/src/node/cli.ts): `const { createServer } = await import('./server')` … `await server.listen()`. No `child_process` in the dev path.
- **Astro — single process.** [`packages/astro/src/cli/dev/index.ts`](https://github.com/withastro/astro/blob/main/packages/astro/src/cli/dev/index.ts) calls `devServer()` in-process (Vite underneath). Interesting prior art for this map, though: Astro's dev command has a **lock file plus `astro dev stop` / `status` / `logs`, a `--background` mode, and explicit AI-agent detection** (`isRunByAgent`, `checkExistingServer`, `killDevServer`, `removeLockFile`) — upstream has already concluded that agent-driven dev servers need an explicit stop command rather than a watcher.
- **Vitest — forks workers, no HTTP.** `packages/vitest/src/runtime/workers/forks.ts` / `vmForks.ts` run tests in forked child processes (tinypool) that communicate over IPC; the Vite server and the optional `--api` server live in the main process. No parent/child port pair.

Conclusion for the map's "generic coverage" question: a mechanism that only disables Nuxt's fork mode covers the observed problem, because none of Vite/Astro/Next/Vitest produce a second *listening* port in dev. What *is* generic is the orphan problem — any dev server killed with SIGKILL/SIGHUP leaves a listener behind — and that is the part an `adc` port-hygiene command should target, not the fork switch.

## Sources

Primary source is `github.com/nuxt/cli` at the tags named inline; secondary primaries are the libraries nuxi delegates to.

- nuxi / `@nuxt/cli` source: [`src/commands/dev.ts` @ v3.7.0](https://github.com/nuxt/cli/blob/v3.7.0/src/commands/dev.ts), [@ v3.8.0](https://github.com/nuxt/cli/blob/v3.8.0/src/commands/dev.ts), [@ v3.9.0](https://github.com/nuxt/cli/blob/v3.9.0/src/commands/dev.ts); [`src/utils/dev.ts` @ v3.9.0](https://github.com/nuxt/cli/blob/v3.9.0/src/utils/dev.ts); [`src/commands/dev-child.ts` @ v3.9.0](https://github.com/nuxt/cli/blob/v3.9.0/src/commands/dev-child.ts); [`packages/nuxi/src/commands/dev.ts` @ v3.21.0](https://github.com/nuxt/cli/blob/v3.21.0/packages/nuxi/src/commands/dev.ts); [`packages/nuxi/src/dev/socket.ts` @ v3.29.3](https://github.com/nuxt/cli/blob/v3.29.3/packages/nuxi/src/dev/socket.ts); @ v3.37.0: [`commands/dev.ts`](https://github.com/nuxt/cli/blob/v3.37.0/packages/nuxi/src/commands/dev.ts), [`commands/dev-child.ts`](https://github.com/nuxt/cli/blob/v3.37.0/packages/nuxi/src/commands/dev-child.ts), [`dev/pool.ts`](https://github.com/nuxt/cli/blob/v3.37.0/packages/nuxi/src/dev/pool.ts), [`dev/index.ts`](https://github.com/nuxt/cli/blob/v3.37.0/packages/nuxi/src/dev/index.ts), [`dev/utils.ts`](https://github.com/nuxt/cli/blob/v3.37.0/packages/nuxi/src/dev/utils.ts), [`utils/lockfile.ts`](https://github.com/nuxt/cli/blob/v3.37.0/packages/nuxi/src/utils/lockfile.ts); @ main (4.0.0-alpha.1): [`packages/nuxt-cli/src/commands/dev.ts`](https://github.com/nuxt/cli/blob/main/packages/nuxt-cli/src/commands/dev.ts), [`dev/pool.ts`](https://github.com/nuxt/cli/blob/main/packages/nuxt-cli/src/dev/pool.ts), [`dev/shutdown.ts`](https://github.com/nuxt/cli/blob/main/packages/nuxt-cli/src/dev/shutdown.ts).
- nuxi PRs / commits: [#81](https://github.com/nuxt/cli/pull/81) forked dev server (2023-08-24), [#153](https://github.com/nuxt/cli/pull/153) rewrite dev to support `--no-fork` (2023-09-07), [#154](https://github.com/nuxt/cli/pull/154) disable forked mode by default for bun and test, [#207](https://github.com/nuxt/cli/pull/207) avoid proxy with `--no-fork`, [#723](https://github.com/nuxt/cli/pull/723) enable fork for bun >=1.2 (2025-02-13), [#921](https://github.com/nuxt/cli/pull/921) socket proxy (2025-07-01), [#1105](https://github.com/nuxt/cli/pull/1105) remove proxy in favour of direct listening (2025-10-30), commits `18979683`, `c16f02ba`, `dfef70fc`, `f93bd1dc`, `9a10f713` (fork-pool fixes, 2026-07-27).
- Releases / dates: [nuxt/cli releases](https://github.com/nuxt/cli/releases) (v3.7.0 2023-08-25 … v3.30.0 2025-11-03 … v3.37.0 2026-07-14, v4.0.0-alpha.1 2026-09-03); npm `@nuxt/cli` dist-tags (`latest` 3.37.0, `alpha` 4.0.0-alpha.1) and `nuxt@4.5.2` / `nuxt@3.21.11` dependency ranges, read with `npm view` on 2026-09-10.
- Published artefact: `@nuxt/cli@3.37.0` tarball (`npm pack`), `dist/dev-Cbii5ek4.mjs`, `dist/dev-DHhrJk9w.mjs`, `dist/dev-child-CFSv-rE7.mjs` — used for the exhaustive `process.env.*` inventory.
- Docs: [Nuxt `nuxt dev` command](https://nuxt.com/docs/4.x/api/commands/dev) (lists `--no-f, --no-fork` "Disable forked mode"; port default `NUXT_PORT || NITRO_PORT || PORT || nuxtOptions.devServer.port`); [Node.js `doc/api/cli.md`](https://github.com/nodejs/node/blob/main/doc/api/cli.md) `NODE_OPTIONS` allowlist (`--require, -r`, `--import`) and signal-0 semantics; [npm docs, Scripts](https://docs.npmjs.com/cli/v11/using-npm/scripts) on `node_modules/.bin` in `PATH`.
- Libraries: [`unjs/listhen` `src/listen.ts`](https://github.com/unjs/listhen/blob/main/src/listen.ts); [`unjs/get-port-please` `src/get-port.ts`](https://github.com/unjs/get-port-please/blob/main/src/get-port.ts); [`unjs/std-env` `src/flags.ts`](https://github.com/unjs/std-env/blob/main/src/flags.ts) and [`src/agents.ts`](https://github.com/unjs/std-env/blob/main/src/agents.ts); [`unjs/citty` `src/args.ts`](https://github.com/unjs/citty/blob/main/src/args.ts).
- Nuxt core: [`packages/schema/src/config/common.ts`](https://github.com/nuxt/nuxt/blob/main/packages/schema/src/config/common.ts), [`packages/schema/src/config/vite.ts`](https://github.com/nuxt/nuxt/blob/main/packages/schema/src/config/vite.ts).
- Other frameworks: [`vercel/next.js` `packages/next/src/cli/next-dev.ts`](https://github.com/vercel/next.js/blob/canary/packages/next/src/cli/next-dev.ts); [`vitejs/vite` `packages/vite/src/node/cli.ts`](https://github.com/vitejs/vite/blob/main/packages/vite/src/node/cli.ts); [`withastro/astro` `packages/astro/src/cli/dev/index.ts`](https://github.com/withastro/astro/blob/main/packages/astro/src/cli/dev/index.ts); [`vitest-dev/vitest` `packages/vitest/src/runtime/workers/forks.ts`](https://github.com/vitest-dev/vitest/blob/main/packages/vitest/src/runtime/workers/forks.ts).
- Devcontainer-era bug reports cited in §5: nuxt/cli [#181](https://github.com/nuxt/cli/issues/181), [#118](https://github.com/nuxt/cli/issues/118), [#209](https://github.com/nuxt/cli/issues/209), [#279](https://github.com/nuxt/cli/issues/279).
