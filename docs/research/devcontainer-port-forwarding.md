# VS Code Dev Containers port forwarding — auto-forward, portsAttributes, ghost forwards

Research for [#54](https://github.com/dbarjs/agent-devcontainer/issues/54) (part of map [#52](https://github.com/dbarjs/agent-devcontainer/issues/52)).

Primary sources only: VS Code docs, the Dev Container spec, the `microsoft/vscode` source
(pinned at commit [`deb0901`](https://github.com/microsoft/vscode/commit/deb09014775f6ca2e73ffd0c7e0b0331aeefd242),
fetched 2026-09-10), and `microsoft/vscode-remote-release` issues. Every claim is cited at the
bottom; inline references use `[Sn]`.

---

## Summary / answers

**1. Detection.** With the default `remote.autoForwardPortsSource: process`, the extension host inside
the container reads `/proc/net/tcp` + `/proc/net/tcp6`, maps each listening socket inode to a PID by
shelling out `ls -l /proc/[0-9]*/fd/[0-9]* | grep socket:`, and reads `/proc/<pid>/cmdline` for the
detail string. The loop is adaptive, not fixed: `Math.max(movingAverage_of_scan_ms * 20, 2000)` ms —
**a 2 s floor**, longer on a busy container. Candidates are filtered to localhost / all-interfaces
only. The only command lines excluded are VS Code Server's own. So *every* listening socket a
forked dev server opens is a candidate — a Nuxt parent on 3000 plus its fork child on its own port
are two independent candidates and both get forwarded. `forwardPorts` does **not** change detection
at all: it forwards ports up front, and its effect on the scanner is purely negative — a port already
in `tunnelModel.detected` is skipped by the auto-forwarder. [S1][S6][S11]

**2. Image metadata.** All of it works. `forwardPorts`, `portsAttributes`, `otherPortsAttributes`
and every attribute (`label`, `onAutoForward`, `protocol`, `requireLocalPort`, `elevateIfNeeded`) are
marked 🏷️ in the spec = storable in the image's `devcontainer.metadata` label. Merge rules:
`portsAttributes` merges **per port key** (last wins), `otherPortsAttributes` wholesale (last wins),
`forwardPorts` is a union — and "when the order matters, the `devcontainer.json` is considered last",
so a project can override a key but keys it never mentions survive from the image. A range key
`"3001-3009"` with `onAutoForward: "ignore"` **is** valid and is exactly the shape VS Code documents
(`"40000-55000": { "onAutoForward": "ignore" }`), and it suppresses forwarding while process scanning
stays fully on. Non-numeric, non-range, non-`host:port` keys are compiled as **regexes matched against
the candidate's process command line**, not the port — so `".*nuxt.*"` is a legal key too. [S2][S3][S7][S9]

**3. Ghost forward.** Under `process`, an auto-forwarded port **is** torn down when its process exits —
but only if the forwarder still remembers forwarding it in its in-memory `autoForwarded` set. Under
`output` it is *never* un-forwarded ("until reload or until the port is closed by the user"), under
`hybrid` it is un-forwarded by watching the process die. The browser hangs rather than getting
ECONNREFUSED because the **local** listener is an ordinary `net.createServer()` on the host that keeps
listening independently of the container: it accepts the TCP handshake, calls `localSocket.pause()`,
and only *then* awaits `connectRemoteAgentTunnel(...)`. A completed local handshake plus a stalled
remote connect = a connection that is open and silent forever. Confirmed verbatim by a user report:
"if I hit them from outside, the request never finishes (as if it's waiting for a response from the
server)". [S1][S4][S7][S12]

**4. From inside the container: nothing.** The in-container `code` CLI talks to the window over
`VSCODE_IPC_HOOK_CLI` and that protocol accepts exactly four message types — `open`, `openExternal`,
`status`, `extensionManagement`. There is no port/tunnel verb. Closing a forward is a workbench
command (`remote.tunnel.closeInline` / `remote.tunnel.closeCommandPalette`) reachable only from the UI
or from an extension host. `remote.forwardOnOpen` gives the container a lever to *open* a forward
(printing a `localhost:PORT` URL to the terminal), never to close one. **The only lever a container
process has is making sure nothing is listening on the port** — then the process-mode scanner removes
the candidate and closes the tunnel itself. [S8][S10][S5]

**5. Local port collision.** Yes, this is a real and separate cause of "3000 vs 3001". The tunnel asks
for the container's own port number locally via `findFreePortFaster(remotePort, 2, 1000, host)` —
`giveUpAfter: 2` means it tries **3000, then 3001, then gives up and takes a random OS-assigned port**.
The Ports view's *Port* column is the container port and *Local Address* is the host port, and VS Code
gives no warning when they diverge unless `requireLocalPort: true` is set (open issue
[vscode-remote-release#2249](https://github.com/microsoft/vscode-remote-release/issues/2249),
"Using forwardPorts gives no indication that a different port was used"). [S4][S7][S13]

---

## 1. Detection under `remote.autoForwardPortsSource: process`

### The scan

`NodeExtHostTunnelService` runs only when the remote is Linux
(`if (isLinux && initData.remote.isRemote && ...)`), which is why the setting's own description says
"On Windows and macOS remotes, the `process` and `hybrid` options have no effect and `output` will be
used". [S1 L192-197][S7 L232-241]

`findCandidatePorts()` [S1 L248-315]:

1. `fs.promises.readFile('/proc/net/tcp')` and `/proc/net/tcp6`; `loadListeningPorts()` keeps rows in
   state `0A` (LISTEN) and parses the hex address/port.
2. `exec("ls -l /proc/[0-9]*/fd/[0-9]* | grep socket:")` → socket inode → PID map.
3. `readdir('/proc')`, then per PID read `cwd` and `cmdline`.
4. `findPorts()` joins them; a candidate is emitted only if it has **both** a PID and a command line,
   and the command line is not `knownExcludeCmdline()` — which excludes only
   `.vscode-server-*/bin`, `out/server-main.js`, and `_productName=VSCode`. [S1 L108-115, L133-148]
5. Sockets whose inode had no owning fd (root-owned processes the server user cannot see) go through
   `tryFindRootPorts()`, a `ps -F -A -l | grep root` heuristic that matches the port number appearing
   in a command line and then walks to the **most-child** process. [S1 L150-178]

Finally the candidates are filtered to `isLocalhost(host) || isAllInterfaces(host)` [S1 L220].

### The interval

```ts
private calculateDelay(movingAverage: number) {
    // Some local testing indicated that the moving average might be between 50-100 ms.
    return Math.max(movingAverage * 20, 2000);
}
```
[S1 L238-241]

So: **minimum 2 s between scans**, growing to 20× the moving-average scan cost on a container where
`/proc` walking is slow. The first three scans are excluded from the average. New candidates are only
pushed to the workbench when the serialized list actually changes [S1 L228-231]. This 2 s floor is the
lower bound on how long a ghost can linger even in the happy path — and the upper bound on how fast a
briefly-listening child gets noticed.

### Why a forked dev server yields two forwards

Nothing in the pipeline groups sockets by process tree, and nothing knows one port proxies to another.
A `nuxt dev` parent listening on 3000 and its fork child listening on its own port are two rows in
`/proc/net/tcp` owned by two PIDs with two command lines, so `findPorts()` returns two candidates and
`forwardCandidates()` forwards both. The only same-process grouping in the code is
`pidToPortsMapping` in `getAttributes` [S6 L977-995], which is used to feed a
`PortAttributesProvider`, not to suppress siblings.

Two candidate filters *do* fire before forwarding, and both are worth knowing [S5 L743-773]:

- `initialCandidates` — anything already listening when the candidate listener started is remembered
  and never auto-forwarded, *unless* it has an explicit `onAutoForward` attribute. (A port that a
  `postStartCommand` opens before the window attaches can therefore be silently ignored.)
- `isCandidateRemappedTunnelLocalEndpoint()` — a candidate whose port equals the *local* port of an
  existing tunnel with a different remote port is skipped, to avoid forwarding VS Code's own remapped
  endpoint back on itself [S5 L45-57].

### Does `forwardPorts` change detection?

No. `forwardPorts` is applied by the Dev Containers resolver, and those tunnels land in
`tunnelModel.detected` (non-`closeable`, `source: TunnelSource.Extension`) [S6 L851-880]. The auto
forwarder then explicitly skips any candidate already in `detected` [S5 L771-773]. So `forwardPorts`
neither enables nor suppresses scanning; it just pre-empts one port. The scanner still finds and
forwards every *other* listening socket, including the fork child.

---

## 2. What a prebuilt image can declare

### Metadata support

The spec's reference states the rule up front: "Metadata properties marked with a 🏷️ can be stored in
the `devcontainer.metadata` **container image label** in addition to `devcontainer.json`. This label
can contain an array of json snippets that will be automatically merged with `devcontainer.json`
contents (if any) when a container is created." [S2 L5]

Marked 🏷️: `forwardPorts`, `portsAttributes`, `otherPortsAttributes` [S2 L12-14] and, in the port
attributes table, `label`, `protocol`, `onAutoForward`, `requireLocalPort`, `elevateIfNeeded`
[S2 L95-103]. So the whole surface this map needs is image-declarable.

### Merge logic

From the spec's merge table [S3 L80-82]:

| Property | Merge Logic |
| --- | --- |
| `portsAttributes` | Per port (not per port attribute), last value wins. |
| `otherPortsAttributes` | Last value wins (not per port attribute). |
| `forwardPorts` | Union of all ports without duplicates. Last one wins (when mapping changes). |

plus: "When the order matters, the `devcontainer.json` is considered last." [S3 L86]

Practical consequences for a node image that ships `portsAttributes`:

- Granularity is the **key**, not the attribute. If the image sets `"3000": { "label": "App" }` and the
  project sets `"3000": { "onAutoForward": "openBrowser" }`, the project's object replaces the
  image's entirely for key `3000` — the label is lost. Prefer keys the project is unlikely to use.
- A key like `"3001-3009"` set only in the image survives untouched, because no project entry has
  that key.
- `otherPortsAttributes` is all-or-nothing; a project setting it wipes the image's. It is the riskier
  surface of the two.

Note the spec table's ✓ columns mark `devcontainer.json` but not `devcontainer-feature.json` for these
three: a **Feature** cannot contribute port config, only the image metadata / devcontainer.json layer
can. That matters if the fix were ever packaged as a Feature — it could not be.

### Ranges, regexes, and `ignore`

`PortsAttributes.readSetting()` parses each key in this order [S6 L284-320]:

```ts
private static RANGE = /^(\d+)\-(\d+)$/;
private static HOST_AND_PORT = /^([a-z0-9\-]+):(\d{1,5})$/;
```

1. `Number(key)` truthy → exact port number.
2. matches `RANGE` → `{ start, end }`.
3. matches `HOST_AND_PORT` → `{ host, port }`.
4. otherwise → `RegExp(key)`; an invalid regex silently drops the entry.

Matching happens in `findNextIndex()` [S6 L263-282]: numeric and range keys compare against the port
(and are skipped entirely for non-localhost hosts), `host:port` compares both, and **a regex key is
tested against `commandLine`** — the candidate's `detail`, i.e. `/proc/<pid>/cmdline`. VS Code's own
setting description says as much: "A port, range of ports (ex. `"40000-55000"`), host and port (ex.
`"db:1234"`), or regular expression (ex. `".+\\/server.js"`). … Attributes which use a regular
expression will apply to ports whose associated process command line matches the expression."
[S7 L258-262]

The documented example in the setting's own markdown is precisely the pattern this map wants
[S7 L304]:

```json
"remote.portsAttributes": {
  "3000": { "label": "Application" },
  "40000-55000": { "onAutoForward": "ignore" },
  ".+\\/server.js": { "onAutoForward": "openPreview" }
}
```

Precedence when several keys match one port [S6 L217-252]: an **exact port key overwrites**, while a
range or regex match only fills attributes that are still `undefined` — regardless of declaration
order. So a project's `"3000": {...}` always beats an image's `"3000-3010": {...}` for port 3000, which
is the desired direction. If nothing matches at all, `otherPortsAttributes` is consulted.

And `ignore` is honoured before any tunnel is created [S5 L775-778]:

```ts
if (portAttributes?.onAutoForward === OnPortForward.Ignore) {
    this.logService.trace(`ForwardedPorts: (ProcForwarding) Port ${value.port} is ignored`);
    continue;
}
```

`ignore` therefore suppresses the *forward*, not the *scan*. `remote.autoForwardPortsSource` stays
`process`, `remote.autoForwardPorts` stays `true`, detection keeps running — the port is simply never
tunnelled. This satisfies the map's "process-scan auto-forwarding must stay on" constraint exactly.

One caveat: `ignore`d candidates are also never added to `autoForwarded`, so if such a port somehow
*is* forwarded later (manually, or restored — see §3), the auto-forwarder will not clean it up.

---

## 3. Ghost forwards: what happens when the process exits

### The model layer never closes anything

`TunnelModel.updateInResponseToCandidates()` diffs the new candidate set against the old. For ports
that disappeared it does **not** close the tunnel — it only downgrades the metadata [S6 L897-935]:

```ts
const forwardedValue = mapHasAddressLocalhostOrAllInterfaces(this.forwarded, parsedAddress.host, parsedAddress.port);
if (forwardedValue) {
    forwardedValue.runningProcess = undefined;
    forwardedValue.hasRunningProcess = false;
    forwardedValue.pid = undefined;
}
```

It then fires `onCandidatesChanged(removedCandidates)` and leaves the decision to a listener. This is
why a forwarded port can sit in the Ports view with an empty "Running Process" column — that state is
a first-class, expected representation, not a bug.

### The listener: `ProcAutomaticPortForwarding.handleCandidateUpdate`

[S5 L798-830]

```ts
if (this.unforwardOnly) {
    autoForwarded = new Map();
    for (const entry of this.remoteExplorerService.tunnelModel.forwarded.entries()) {
        if (entry[1].source.source === TunnelSource.Auto) { autoForwarded.set(entry[0], entry[1]); }
    }
} else {
    autoForwarded = new Map(this.autoForwarded.entries());
}
for (const removedPort of removed) {
    ...
    if (forwardedValue) { await this.remoteExplorerService.close(value, TunnelCloseReason.AutoForwardEnd); }
}
```

So per mode [S5 L336-347, S7 L232-241]:

| `remote.autoForwardPortsSource` | forwarder(s) constructed | un-forward on process exit? |
| --- | --- | --- |
| `process` (default, Linux) | `ProcAutomaticPortForwarding(unforwardOnly = false)` + an `OutputAutomaticPortForwarding` gated by `useProc()` | **Yes** — but only ports in the forwarder's own `autoForwarded` set |
| `hybrid` | `ProcAutomaticPortForwarding(unforwardOnly = true)` + output forwarder | **Yes** — any tunnel in the model with `source === TunnelSource.Auto` (a *wider* net than `process`) |
| `output` | output forwarder only | **No** — "will not be 'un-forwarded' until reload or until the port is closed by the user in the Ports view" |
| non-Linux remote | forced to `output` | No |

Ports from `forwardPorts` are never touched: they are in `detected`, not `forwarded`, and are
`closeable: false` [S6 L851-880] — they are *supposed* to be permanent for the session.

A VS Code maintainer's own repro on
[vscode-remote-release#7731](https://github.com/microsoft/vscode-remote-release/issues/7731) shows the
happy path working: start `node server.js` on 1234 → forwarded; Ctrl+C → "Ports panel is again empty" →
`curl` from the host gets connection refused. [S12]

### Two real ways the cleanup misses

**(a) The port is still listening.** The scanner is truth. An orphaned fork child that survives its
parent keeps its `/proc/net/tcp` row, so the candidate never disappears and the forward is correctly
kept. This is the map's working hypothesis and it needs no VS Code bug to explain the Ports view — but
it does not on its own explain a *hang*, since a live child would answer. What hangs is the port whose
listener is gone but whose tunnel outlived it.

**(b) Restored tunnels are unreachable by the process-mode cleanup.** `remote.restoreForwardedPorts`
defaults to `true` [S7 L222-226]. `storeForwarded()` persists **every** entry of `this.forwarded`,
including `TunnelSource.Auto` ones — there is no source filter [S6 L646-664]. `restoreForwarded()`
re-forwards each stored tunnel whose source is not `Extension`, again including `Auto`, with a 2-week
expiry [S6 L28-30, L591-614] — *without checking that anything is listening*. After a window reload the
fresh `ProcAutomaticPortForwarding` starts with an **empty** `autoForwarded` set (it is seeded from a
previous instance only across a source-mode switch, via the `alreadyAutoForwarded` argument
[S5 L323-348]). In `process` mode the cleanup path consults exactly that empty set, so a restored
auto-forward can never be closed by candidate removal.

The asymmetry is worth stating plainly: **`hybrid` cleans up restored auto-tunnels (it scans the model
for `TunnelSource.Auto`); `process` does not.** A ghost forward that survives a reload is therefore an
expected outcome of the default configuration, not a race.

### Why the browser hangs instead of refusing

`RemoteTunnel` in `src/vs/platform/tunnel/node/tunnelService.ts` is a plain Node TCP server on the
**host** [S4 L58-69, L86-120]:

```ts
this._server = net.createServer();
this._server.on('connection', this._connectionListener);
...
private async _onConnection(localSocket: net.Socket): Promise<void> {
    // pause reading on the socket until we have a chance to forward its data
    localSocket.pause();
    const protocol = await connectRemoteAgentTunnel(this._options, tunnelRemoteHost, this.tunnelRemotePort);
    ...
}
```

Three facts combine:

1. The listening socket lives entirely on the host and knows nothing about the container. As long as
   the tunnel object exists, `listen()` is in effect, so the kernel **completes the TCP handshake** for
   any client. A refused connection is impossible by construction.
2. `_onConnection` accepts, pauses the socket, and *only then* awaits the remote connect. Nothing is
   written to the client until the remote side answers.
3. There is no `try`/`catch` and no timeout around that `await`. If `connectRemoteAgentTunnel` stalls
   or rejects, the local socket is left paused, open, and unwritten — no `end()`, no `destroy()`. The
   browser has an established connection that will never produce a byte, which is exactly "infinite
   loading" rather than `ERR_CONNECTION_REFUSED`.

The user report in #7731 describes precisely this: "When I try to access these ports within the
container, they're closed, but if I hit them from outside, the request never finishes (as if it's
waiting for a response from the server)." [S12]

(Note the deliberate comment at [S4 L152-153] — "Need to end instead of unpipe, otherwise whatever is
connected locally could end up 'stuck' with whatever state it had until manually exited" — showing the
authors were aware of the stuck-client failure mode on the teardown path, but the pre-`await` path has
no equivalent guard.)

### Adjacent hazard: the fallback to `hybrid`

If more than `remote.autoForwardPortsFallback` (default **20**) ports are auto-forwarded while the
source is `process` *by default*, VS Code silently rewrites the setting to `hybrid` and notifies:
"Over 20 ports have been automatically forwarded. The `process` based automatic port forwarding has
been switched to `hybrid` in settings. Some ports may no longer be detected." [S5 L278-310][S7 L243-247]

Two things follow for this repo. First, a dev server that churns through ports can flip the setting
behind the user's back — which would violate the map's "process-scan stays on" constraint without
anyone editing anything. Second, the fallback is disabled entirely if
`remote.autoForwardPortsSource` has been configured explicitly ("When `remote.autoForwardPortsFallback`
hasn't been configured, but `remote.autoForwardPortsSource` has, `remote.autoForwardPortsFallback` will
be treated as though it's set to `0`") — so *pinning* `remote.autoForwardPortsSource: "process"` in the
image is itself a way to guarantee the mode never changes. That is a settings-level change, not a
`portsAttributes` one, and is worth weighing against the map's "don't change the source" constraint —
it pins the current default rather than departing from it.

---

## 4. Can anything inside the container close a forward?

**No supported mechanism exists.**

The `code` command inside a dev container is a shim that connects to the socket named by
`VSCODE_IPC_HOOK_CLI` and posts a JSON message. `ExtHostCLIServer` accepts exactly four types
[S8 L15-42, L98-115]:

```ts
case 'open':               // open files/folders
case 'openExternal':       // open a URI
case 'status':             // print status
case 'extensionManagement':// install/list/uninstall extensions
default:
    sendResponse(404, `Unknown message type: ${data.type}`);
```

No tunnel or port verb. Closing a port is a workbench command — `ClosePortAction.INLINE_ID`
(`remote.tunnel.closeInline`) and `ClosePortAction.COMMANDPALETTE_ID`
(`remote.tunnel.closeCommandPalette`), labelled "Stop Forwarding Port" — which calls
`remoteExplorerService.close(..., TunnelCloseReason.User)` [S10 L1266-1316]. Commands are reachable
from the UI, from a keybinding, or from an extension via `vscode.commands.executeCommand`, none of
which a plain container process can reach through the CLI socket. The command palette variant also
filters to `tunnel.closeable`, so `forwardPorts` entries cannot be closed even by the user.

What the container *can* influence:

- **Stop listening.** This is the supported lever. Once the socket is gone from `/proc/net/tcp`, the
  next scan (≥2 s later) drops the candidate and `process` mode closes the tunnel — subject to the
  `autoForwarded`-set limitation in §3. Killing the whole process tree (so no orphan child holds the
  port) is therefore the actual fix, and matches the map's root-cause-first stance.
- **Open a forward, not close one.** `remote.forwardOnOpen` (default `true`) — "Controls whether local
  URLs with a port will be forwarded when opened from the terminal and the debug console" [S7 L248-252]
  — plus the `openExternal` CLI verb, give the container ways to *create* forwards. There is no inverse.
- **Nothing via `portsAttributes` at runtime.** Attributes are read from configuration, so changing
  them requires writing settings files, and `onAutoForward: ignore` only affects *future* auto-forward
  decisions — it does not close an existing tunnel (`updateAttributes()` re-applies only `protocol`
  and `label` to live tunnels [S6 L946-974]).

**Implication for an `adc` port-hygiene command:** it can only be a process-side command — find and
kill whatever still holds the port (and its orphaned children), then wait out one scan interval.
It cannot ask VS Code to drop a tunnel. And for the restored-tunnel ghost of §3(b), killing the
listener is not enough, because there is no listener; that ghost can only be cleared from the UI
("Stop Forwarding Port") or by a window reload with the stored value expired/cleared. That is a hard
limit worth recording in the map before designing the command.

---

## 5. Local port collision — the second "3000 vs 3001"

`RemoteTunnel.waitForReady()` [S4 L86-108]:

```ts
const startPort = this.suggestedLocalPort ?? this.tunnelRemotePort;
// try to get the same port number as the remote port number...
let localPort = await findFreePortFaster(startPort, 2, 1000, hostname);
// if that fails, the method above returns 0, which works out fine below...
```

`findFreePortFaster(startPort, giveUpAfter, timeout, hostname)` starts with `countTried = 1` and, on
`EADDRINUSE`/`EACCES`, increments the port while `countTried < giveUpAfter` [S13 L161-199]. With
`giveUpAfter = 2` that is: try **3000**, then try **3001**, then resolve `0` → `listen(0)` → a random
OS-assigned high port. There is also a 1000 ms overall timeout that likewise resolves `0`.

So when host port 3000 is occupied — by another container, another project's dev server, or a
*previous* ghost tunnel from this very repo's failure mode — the container's port 3000 is presented at
`localhost:3001` on the host. The Ports view shows *Port* = 3000 (container) and *Local Address* =
`localhost:3001` (host), and there is no notification: this is
[vscode-remote-release#2249](https://github.com/microsoft/vscode-remote-release/issues/2249), still
open, filed by the Dev Containers maintainers themselves — "I hit a problem where I had port 3000
running locally, and then opened a dev container with `"forwardPorts": [3000]`. Since the port
conflicted, the port was actually mapped to 3001 locally. However, I had no idea… Expected: Notified
that a different local port was used, or it errors. Actual: No notice, no error." [S14]

The opt-in guard is `requireLocalPort` — "Dictates when port forwarding is required to map the port in
the container to the same port locally or not. If set to `false`, the `devcontainer.json` supporting
services / tools will attempt to use the specified port forward to `localhost`, and silently map to a
different one if it is unavailable. If set to `true`, you will be notified if it is not possible to use
the same port. Defaults to `false`." [S2 L102]; VS Code's phrasing: "When true, a modal dialog will
show if the chosen local port isn't used for forwarding" [S7 L289]. `requireLocalPort` is 🏷️
metadata-supported, so the node image can set `"3000": { "requireLocalPort": true }` to convert a
silent remap into a visible modal.

Note also `requireLocalPort` is the one attribute *not* inherited from range/regex matches — in
`getAttributes` a non-exact match explicitly resets it to `undefined` [S6 L239]. It must be declared on
an exact port key to have any effect.

### Disambiguating the two explanations

For the map's symptom "Nuxt prints `localhost:3000` but VS Code forwards 3001", both mechanisms are
live and they are distinguishable in the Ports view:

| | *Port* column (container) | *Local Address* column (host) | Cause |
| --- | --- | --- | --- |
| Local remap | 3000 | `localhost:3001` | Host 3000 busy → `findFreePortFaster` |
| Extra container port | 3000 **and** a second row | matching | Fork child listening on its own port |

If the Ports view shows **one** row whose container port is 3000, it is the remap (§5) and the culprit
is on the host — quite possibly a previous ghost tunnel still holding 3000. If it shows **two** rows,
it is the fork child (§1). The two can also compound: a ghost holding host 3000 forces the next
session's real 3000 to land on 3001.

---

## Sources

- **[S1]** `microsoft/vscode` — `src/vs/workbench/api/node/extHostTunnelService.ts` @ `deb0901` —
  `loadListeningPorts` (L49), `knownExcludeCmdline` (L108-115), `findPorts` (L133-148),
  `tryFindRootPorts` (L150-178), constructor Linux guard (L192-197), scan loop (L214-236),
  `calculateDelay` (L238-241), `findCandidatePorts` (L248-315).
  https://github.com/microsoft/vscode/blob/deb09014775f6ca2e73ffd0c7e0b0331aeefd242/src/vs/workbench/api/node/extHostTunnelService.ts
- **[S2]** Dev Container spec — `devcontainer.json` reference, `devcontainers/spec` @ `main`,
  `docs/specs/devcontainerjson-reference.md` — 🏷️ rule (L5), `forwardPorts`/`portsAttributes`/
  `otherPortsAttributes` (L12-14), port attributes table incl. `onAutoForward` (L101) and
  `requireLocalPort` (L102).
  https://containers.dev/implementors/json_reference/ ·
  https://github.com/devcontainers/spec/blob/main/docs/specs/devcontainerjson-reference.md
- **[S3]** Dev Container spec — `docs/specs/devcontainer-reference.md`, "Image Metadata" and
  "Merge Logic" — `devcontainer.metadata` label (L52), merge table (L58-88, port rows L80-82),
  "devcontainer.json is considered last" (L86).
  https://containers.dev/implementors/spec/ ·
  https://github.com/devcontainers/spec/blob/main/docs/specs/devcontainer-reference.md
- **[S4]** `microsoft/vscode` — `src/vs/platform/tunnel/node/tunnelService.ts` @ `deb0901` —
  `net.createServer()` (L58-69), `waitForReady` / `findFreePortFaster(startPort, 2, 1000, …)` (L86-108),
  `_onConnection` with `localSocket.pause()` (L110-155), mirror helpers (L157-175).
  https://github.com/microsoft/vscode/blob/deb09014775f6ca2e73ffd0c7e0b0331aeefd242/src/vs/platform/tunnel/node/tunnelService.ts
- **[S5]** `microsoft/vscode` — `src/vs/workbench/contrib/remote/browser/remoteExplorer.ts` @ `deb0901` —
  `isCandidateRemappedTunnelLocalEndpoint` (L45-57), `AutomaticPortForwarding` (L211+), fallback
  process→hybrid (L278-310), `setup()` mode wiring (L323-348), `OnAutoForwardedAction` (L353-568),
  `OutputAutomaticPortForwarding` (L569-645), `ProcAutomaticPortForwarding` (L646-844) incl.
  `forwardCandidates` (L743-796) and `handleCandidateUpdate` (L798-830).
  https://github.com/microsoft/vscode/blob/deb09014775f6ca2e73ffd0c7e0b0331aeefd242/src/vs/workbench/contrib/remote/browser/remoteExplorer.ts
- **[S6]** `microsoft/vscode` — `src/vs/workbench/services/remote/common/tunnelModel.ts` @ `deb0901` —
  restore storage keys/expiry (L28-30), `TunnelCloseReason` (L76), `PortsAttributes` (L192-330) incl.
  `RANGE`/`HOST_AND_PORT` (L195-196), `getAttributes` precedence (L217-252), `findNextIndex` (L263-282),
  `readSetting` (L284-330); `close()` (L828-840), `addEnvironmentTunnels` (L851-880),
  `setCandidates`/`updateInResponseToCandidates` (L884-935), `updateAttributes` (L946-974),
  model `getAttributes` (L976-1000), `restoreForwarded` (L591-618), `storeForwarded` (L646-670).
  https://github.com/microsoft/vscode/blob/deb09014775f6ca2e73ffd0c7e0b0331aeefd242/src/vs/workbench/services/remote/common/tunnelModel.ts
- **[S7]** `microsoft/vscode` — `src/vs/workbench/contrib/remote/common/remote.contribution.ts` @
  `deb0901` — settings registration: `remote.restoreForwardedPorts` (L222-226),
  `remote.autoForwardPorts` (L227-231), `remote.autoForwardPortsSource` + enum descriptions
  (L232-242), `remote.autoForwardPortsFallback` default 20 (L243-247), `remote.forwardOnOpen`
  (L248-252), `remote.portsAttributes` schema + key description + example (L256-310),
  `remote.otherPortsAttributes` (L311-357), `remote.localPortHost` (L358-363).
  https://github.com/microsoft/vscode/blob/deb09014775f6ca2e73ffd0c7e0b0331aeefd242/src/vs/workbench/contrib/remote/common/remote.contribution.ts
- **[S8]** `microsoft/vscode` — `src/vs/workbench/api/node/extHostCLIServer.ts` @ `deb0901` —
  pipe arg interfaces (L15-42), dispatch `switch` with the four accepted types and the 404 default
  (L98-115).
  https://github.com/microsoft/vscode/blob/deb09014775f6ca2e73ffd0c7e0b0331aeefd242/src/vs/workbench/api/node/extHostCLIServer.ts
- **[S9]** VS Code docs — Developing inside a Container, "Forwarding or publishing a port"
  (always-forward via `forwardPorts`, temporary forwarding, "your container's port 3000 might be
  mapped to localhost:4123", `remote.restoreForwardedPorts`, publishing vs forwarding).
  https://code.visualstudio.com/docs/devcontainers/containers
- **[S10]** `microsoft/vscode` — `src/vs/workbench/contrib/remote/browser/tunnelView.ts` @ `deb0901` —
  `ClosePortAction` ("Stop Forwarding Port", `remote.tunnel.closeInline` /
  `remote.tunnel.closeCommandPalette`, `closeable` filter) L1266-1316; command registration L1601-1635.
  https://github.com/microsoft/vscode/blob/deb09014775f6ca2e73ffd0c7e0b0331aeefd242/src/vs/workbench/contrib/remote/browser/tunnelView.ts
- **[S11]** VS Code docs — Local port forwarding / Ports view background.
  https://code.visualstudio.com/docs/editor/port-forwarding
- **[S12]** `microsoft/vscode-remote-release` #7731 — "Forwarded ports are sometimes held open on the
  host after the process in the container is closed" (CLOSED, info-needed). Reporter: "if I hit them
  from outside, the request never finishes (as if it's waiting for a response from the server)";
  maintainer repro of the working path (Ctrl+C → Ports panel empty → connection refused).
  https://github.com/microsoft/vscode-remote-release/issues/7731
- **[S13]** `microsoft/vscode` — `src/vs/base/node/ports.ts` @ `deb0901` — `findFreePortFaster`
  (L161-199): `countTried` starts at 1, increments `startPort` while `countTried < giveUpAfter`,
  otherwise resolves `0`.
  https://github.com/microsoft/vscode/blob/deb09014775f6ca2e73ffd0c7e0b0331aeefd242/src/vs/base/node/ports.ts
- **[S14]** `microsoft/vscode-remote-release` #2249 — "Using forwardPorts gives no indication that a
  different port was used" (OPEN, Backlog; filed by Chuxel, assigned chrmarti).
  https://github.com/microsoft/vscode-remote-release/issues/2249
