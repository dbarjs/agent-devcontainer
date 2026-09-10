# Nuxt dev repro in a live node container (ticket #55, 2026-09-10)

Ground-truth observations for [map #52](https://github.com/dbarjs/agent-devcontainer/issues/52).
Scratch project: `package.json` + `nuxt.config.ts` here, opened with `adc init --variant node`
and `devcontainer up` against `ghcr.io/dbarjs/agent-devcontainer/node:latest` (pulled 2026-09-10).

## Versions

| what | version |
| --- | --- |
| node (image, NVM) | v24.20.0 |
| pnpm | 10.15.0 |
| nuxt | 4.5.2 (Nitro 2.13.4, Vite 8.3.0) |
| @nuxt/cli | 3.37.0 |
| listhen | 1.10.1 |

Image has **no `ss`, `lsof`, `fuser`, or `netstat`** — `listeners.sh` parses `/proc/net/tcp*` and maps inodes via `/proc/*/fd`.

## Process shapes

`pnpm dev` (default, forked) — all in one process group, the **parent** is the only TCP listener:

```
pnpm dev                       (pid A, pgid A)
└─ sh -c nuxt dev
   └─ node nuxt.mjs dev        ← listens :3000 (tcp6 ::), owns /tmp/nuxt-vite-*/nuxt.sock
      ├─ node @nuxt/cli/dist/dev/index.mjs   (fork worker, no TCP listener)
      └─ node @nuxt/cli/dist/dev/index.mjs   (warm spare, no TCP listener)
```

`pnpm dev --no-fork` — same chain, no children, same single listener on 3000.
`nr dev` adds one more layer on top (`nr` → `pnpm run dev` → `sh -c` → `nuxt.mjs`).

Never observed: a child listening on TCP, or any listener on 3001, while 3000 was free.
`curl :3001` → connection refused during a healthy run. Matches the research: ≥3.30 serves in-process.

## Kill matrix (forked mode unless noted; +4 s and +20 s snapshots identical)

| # | signal → target | nuxt.mjs survives? | listener :3000 survives? |
| --- | --- | --- | --- |
| 1 | SIGINT → process group (Ctrl+C) | no | no |
| 2 | SIGTERM → `nuxt.mjs` | no | no |
| 3 | SIGKILL → `nuxt.mjs` | no (fork children exit with it, within 4 s) | no |
| 4 | **SIGTERM → `pnpm dev`** | **yes** (reparented to PID 1, both fork children alive) | **yes, still 200** |
| 5 | **SIGKILL → `pnpm dev`** | **yes** (plus the `sh -c` shim) | **yes, still 200** |
| 6 | SIGHUP → process group | no | no |
| 7 | SIGTERM → `pnpm dev --no-fork` | **yes** | **yes** |
| 11 | SIGTERM → `nr dev` | **yes** (pnpm, sh, nuxt, 2 children all alive) | **yes** |

The orphan is produced by killing the **launcher** (pnpm / nr / the `sh -c` shim), not by Nuxt's fork.
`--no-fork` does not change the outcome. Signals aimed at `nuxt.mjs` itself, or at the whole process group, are clean.

## "3001" reproduction (run 8)

With the run-4 orphan still holding 3000, a second `pnpm dev` prints `➜ Local: http://localhost:3001/`
with **no warning**; both 3000 and 3001 answer 200 from two different `nuxt.mjs` pids. That is listhen's
alternativePortRange drift (symptom 2). Under VS Code `process` auto-forward this is two rows in the Ports view.

## `.nuxt/nuxt.lock` (runs 9–10)

- Not written unless `CLAUDECODE` is set in the env of `nuxt dev`. With `CLAUDECODE=1`:
  `{"pid","startedAt","command":"dev","cwd","port":3000,"hostname":"::","url":"http://localhost:3000"}`
- Killing the launcher leaves the lock **and** the orphan; a second `nuxt dev` then refuses with
  `Another Nuxt dev server is already running … Run kill <pid> … Set NUXT_IGNORE_LOCK=1 to bypass` (exit 1) —
  it points at the exact orphan pid. Under an agent, the 3001 drift is replaced by this error.
- SIGKILL of the lock's pid leaves a stale lock; the next `nuxt dev` detects the dead pid, starts on 3000 and rewrites it.
- Lock gone after a clean stop. A stale lock is harmless.

## Host-side observations (this Mac, same day, no repro container running)

- `lsof -iTCP -sTCP:LISTEN` shows **VS Code's Code Helper listening on 127.0.0.1:3000 and :3001**.
- Two node-image devcontainers were open (blueprint-nuxt-module, validador-cultural); **both** declare
  `forwardPorts: [3000]` (the adc node template default). Nothing listened on 3000/3001 inside either container.
- Both host listeners **accept the TCP connection and hang** — `curl --max-time 20` times out (rc 28), no reset,
  no empty reply. This is symptom 3 ("infinite loading with no server") produced by the **static** forward alone:
  `forwardPorts` opens the host listener at container start regardless of a remote listener, and a second window with
  the same `forwardPorts` gets remapped to host 3001 (`findFreePortFaster`). No orphan required.
- In the blueprint-nuxt-module container: `nuxt.mjs dev --port 3471` reparented to PID 1 for ~32 h (no listener left),
  and `node .output/server/index.mjs` under PID 1 listening on 3460 for ~12 h — real orphans from launcher kills.

## Not done

Step 5 (watching the Ports view during runs 2–8 in a VS Code window) is HITL and was not performed; the host-side
lsof/curl observation above stands in for it. Which window holds 3000 vs 3001 is inferable but unverified.
