# Container-to-host clipboard channel on OrbStack

Research for [#47](https://github.com/dbarjs/agent-devcontainer/issues/47), part of map [#46](https://github.com/dbarjs/agent-devcontainer/issues/46). Researched 2026-09-10.

Question: how can a process inside an adc devcontainer (OrbStack on macOS, started by the VS Code Dev Containers extension) reach a clipboard service on the host, and which channel is the most robust for a shim `xclip` to call on every Ctrl+V?

Everything below is either quoted from a primary source (linked) or the output of a local experiment on this machine, labelled **[experiment]**. Anything neither documented nor tested is marked **UNVERIFIED**.

Test machine: macOS 15.7.5 (24G624), Apple M4 Pro, OrbStack 2.2.3 (Docker Engine 29.4.0, `docker context show` → `orbstack`), VS Code Dev Containers with the published `ghcr.io/dbarjs/agent-devcontainer/{base,node}:latest` images. OrbStack's docs source repo is not public (`orbstack/docs` → 404), so OrbStack quotes are from the rendered pages at docs.orbstack.dev.

## TL;DR

| # | Question | Answer |
|---|---|---|
| 1 | Loopback reachability | **A host service bound to `127.0.0.1` is reachable from containers via `host.docker.internal` (and legacy `host.internal`) under OrbStack** — verified live, in bridge mode, in `--network host`, and from a DinD child. The host sees the client as `127.0.0.1`. Not documented by OrbStack or Docker; the Dev Containers extension adds no `--add-host`. Do **not** use `--add-host host.docker.internal:host-gateway` in DinD children — it resolves to the outer container. |
| 2 | Unix socket bind mounts | **Not on OrbStack.** The socket inode crosses VirtioFS (`S_ISSOCK` true) but `connect()` → `ECONNREFUSED`; maintainer: "Sharing Unix sockets between Linux and macOS is not supported" (orbstack#601; #62 still open). Only the SSH-agent socket is special-cased. devcontainer.json `mounts` and the `devcontainer.metadata` label *can* express such a mount (`${localEnv:HOME}` resolves on the developer's Mac), but a missing source makes the container fail to start and the spec has no optional mounts. |
| 3 | VS Code channels | Dev Containers forwards git credentials, SSH agent, GPG, and container→host TCP ports; there is **no** host→container socket/port forwarding API (SSH-agent is a bespoke in-container helper socket). A UI extension **can** write into the container with `vscode.workspace.fs` (remote URIs) and inject into the terminal with `Terminal.sendText(text, false)`. `vscode.env.clipboard` is text-only. An extension keybinding `cmd+v` / `when: terminalFocus` outranks the built-in `workbench.action.terminal.paste`, which itself ignores images and only pastes `file:`-scheme resources (so Explorer copies in a Dev Container window paste nothing). `extensionKind: ["ui"]` = must run locally; install with `code --install-extension foo.vsix` on the Mac; `customizations.vscode.extensions` installs into the container only. |
| 4 | Host service shape | `~/Library/LaunchAgents/<label>.plist`, bootstrapped into `gui/$UID` (default session is Aqua; a `gui/501` agent reads the pasteboard fine — verified). Two viable shapes: **socket-activated** (`Sockets` + `inetdCompatibility.Wait=false`, launchd holds `127.0.0.1:<port>` and spawns one zsh process per connection with the connected socket on stdin/stdout — verified; no listener code needed, but the man page says "For new projects, this key should be avoided") or **always-on** (`KeepAlive=true`, own listener). launchd gives the agent no shell PATH (`/usr/bin:/bin:/usr/sbin:/sbin` + a couple of stray prefixes) — absolute paths everywhere. Idempotent install: `launchctl print gui/$UID/<label>` (exit 0 loaded / 113 not) → `bootout` if loaded → `enable` → `bootstrap gui/$UID <plist>`; duplicate `bootstrap` exits 5. Sheldon clones to `~/.local/share/sheldon/repos/github.com/<owner>/<repo>` and sources `adc.plugin.zsh` by absolute path, so `${0:A:h}` at source time gives adc its own install dir for the plist. |
| 5 | Reading/writing the macOS clipboard | Detect with `osascript -s s -e 'clipboard info for «class PNGf»'` (`{}` when absent, ~65 ms), dump with `the clipboard as «class PNGf»` + `write` (byte-identical round trip), text with `pbpaste` (~7 ms, empty + exit 0 when no text). `the clipboard as «class furl»` returns only the **first** file and false-positives on plain text — gate on `clipboard info for «class furl»`. Write path: `pbcopy` for text, `set the clipboard to (read … as «class PNGf»)` for images; a file reference **cannot** be set from pure AppleScript — use JXA `NSPasteboard.writeObjects([NSURL])`. `pngpaste` is optional (0.2.3, last commit 2020) and not needed. |

**Recommendation for the mechanism ticket**: TCP to `host.docker.internal:<port>` with the host service bound to `127.0.0.1` is the only channel that is (a) verified to work under OrbStack from the devcontainer *and* DinD children, (b) needs no per-container mount, and (c) costs ~1.5 ms round trip. A Unix-socket mount is a dead end on OrbStack. A UI-side VS Code extension is a viable *complement* for the Cmd+V copied-file gesture (it is the only party that sees VS Code's private `code/file-list` clipboard format), but cannot replace the host service for the shim's Ctrl+V path because the shim runs in the shell, not in VS Code.

## 1. Loopback reachability

### 1a. What Docker documents (Docker Desktop, not OrbStack)

The Docker docs never say whether a loopback-bound host service is reachable; they only say the name "resolves to the internal IP address of your host", and their example server binds all interfaces.

- [Networking how-tos › Connect a container to a service on the host](https://docs.docker.com/desktop/features/networking/networking-how-tos/#connect-a-container-to-a-service-on-the-host): "To connect to services running on your host, use the special DNS name:" — "`host.docker.internal` | Resolves to the internal IP address of your host". Example: "`python -m http.server 8000`" then "`curl http://host.docker.internal:8000`". (CPython [http.server](https://docs.python.org/3/library/http.server.html): "By default, the server binds itself to all interfaces.")
- [Docker Desktop networking](https://docs.docker.com/desktop/features/networking/): "All outbound container network traffic originates from the `com.docker.backend` process." — a user-space proxy on the Mac, which is why loopback *could* be reachable, but not stated.
- [`docker run --add-host`](https://docs.docker.com/reference/cli/docker/container/run/#add-host): "The `--add-host` flag supports a special `host-gateway` value that resolves to the internal IP address of the host." — "It's conventional to use `host.docker.internal` as the hostname referring to `host-gateway`. Docker Desktop automatically resolves this hostname".
- [`dockerd --host-gateway-ip`](https://docs.docker.com/reference/cli/dockerd/#configure-host-gateway-ip): "By default, `host-gateway` resolves to the IPv4 address of the default bridge, and its IPv6 address if it has one." (This is what bites DinD children — §1d.)

### 1b. What OrbStack documents

- [Docker networking](https://docs.orbstack.dev/docker/network): "You can use the host.docker.internal domain to connect to a server running on Mac." — "OrbStack uses a custom-built virtual network stack designed to be seamless. It implements all common networking features, including IPv6, ping, and traceroute, and follows your VPN and DNS settings." — "For containers, IPv6 is disabled by default for compatibility." — "OrbStack uses IP addresses in the 192.168.x.x range for containers."
- [Host networking](https://docs.orbstack.dev/docker/host-networking): "Any servers you run in the container will be accessible from Mac on localhost. The reverse is also true: any servers running on Mac will be accessible from the container on localhost. This removes the need to use host.docker.internal or configure port forwards."
- [Machines networking](https://docs.orbstack.dev/machines/network) (Linux machines, not Docker): "You can use the host.orb.internal hostname to connect to a server running on Mac." and "To avoid surprising behavior, connecting directly from machines to localhost macOS servers is not supported. (It is, however, supported for Docker host networking.)" — this is about using the *name* `localhost`, not about the Mac service's bind address.
- [Architecture](https://docs.orbstack.dev/architecture): "NAT is used for IPv4 and IPv6, and a custom DNS server forwards DNS queries to macOS." — "Containers and machines are connected to unified bridge networks, allowing them to communicate with each other and with macOS directly by IP address."
- [Release notes](https://docs.orbstack.dev/release-notes): v0.1.9 "Added host.docker.internal and other domains for compatibility with Docker Desktop"; v0.7.0 "2-way localhost integration in Docker host networking mode".
- `host.internal` appears on no current docs page. Maintainer kdrag0n in [orbstack#988](https://github.com/orbstack/orbstack/issues/988): "host.internal has not been needed for a very long time. host.docker.internal should work fine in OrbStack." It originated in [orbstack#12](https://github.com/orbstack/orbstack/issues/12): "Yes, you can use `host.internal` instead. I'll document this and add an alias for `host.docker.internal`."
- **No OrbStack doc states whether a Mac service bound to `127.0.0.1` is reachable via `host.docker.internal` in bridge mode.** The only issue evidence is a *user* report in [orbstack#2413](https://github.com/orbstack/orbstack/issues/2413) (Linux machine, `host.orb.internal`): "it reaches even localhost-only services. For example, postgres bound to `127.0.0.1`" — the maintainer did not dispute it and answered "You could consider using Little Snitch on the host to prevent OrbStack Helper from connecting to LAN IPs" (i.e. a Mac-side helper process makes the connection).

### 1c. [experiment] Loopback-bound host service, from the devcontainer

Host: `python3 -m http.server 47811 --bind 127.0.0.1` (lsof: `TCP 127.0.0.1:47811 (LISTEN)`) and a second on `47812 --bind 0.0.0.0`. Container: `docker run --rm curlimages/curl`.

```
host.docker.internal resolves to: 0.250.250.254
  host.docker.internal:47811 -> hello-from-host      # 127.0.0.1-bound: reachable
  host.docker.internal:47812 -> hello-from-host
host.internal resolves to: 0.250.250.254 + fd07:b51a:cc66:f0::fe
  host.internal:47811 -> hello-from-host
  host.internal:47812 -> hello-from-host
/etc/hosts: (no host.docker.internal entry)
/etc/resolv.conf: nameserver 0.250.250.200   # "Generated by Docker Engine"
```

Host-side access log for both listeners: `127.0.0.1 - - "GET / HTTP/1.1" 200` — **the host sees every container connection as coming from `127.0.0.1`**, so a loopback-bound service cannot tell container clients from host clients (relevant to the ADR-0003 exception on the map: any container, YOLO or not, gets the same access).

Same result inside the real image: `docker run --rm ghcr.io/dbarjs/agent-devcontainer/base:latest bash -c 'curl -s http://host.docker.internal:47811/'` → `hello-from-host`. The base image has `curl` and `python3`, no `xclip`/`wl-paste`/`nc`/`socat`, and `DISPLAY`/`WAYLAND_DISPLAY` unset.

- `--network host`: `curl http://127.0.0.1:47811/` and `host.docker.internal:47811` both → `hello-from-host` (matches the host-networking doc).
- `--add-host host.docker.internal:host-gateway` (outer container): `/etc/hosts` gets `0.250.250.254 host.docker.internal` → reachable. Harmless but unnecessary.
- Round trip, 10 sequential `curl` from the container to the 127.0.0.1 listener: `mean=0.0015s max=0.0047s`.

### 1d. Dev Containers extension and DinD children

**Dev Containers adds no `--add-host`.** The extension is closed-source; the reference [devcontainers/cli `singleContainer.ts`](https://github.com/devcontainers/cli/blob/main/src/spec-node/singleContainer.ts) builds `docker run` from `runArgs`, mounts, env and labels only — a grep of `src/` for `add-host`, `host-gateway`, `host.docker.internal` returns nothing. [experiment] `docker inspect` of a live Dev Containers-created container here: `HostConfig.ExtraHosts = null`, `NetworkMode = bridge`. The [devcontainer.json reference](https://containers.dev/implementors/json_reference/) lists `--add-host` only as a user example for `build.options` and offers `runArgs` ("An array of Docker CLI arguments that should be used when running the container").

**DinD children.** The [docker-in-docker feature](https://github.com/devcontainers/features/tree/main/src/docker-in-docker) runs a plain moby `dockerd` inside the container ("Create child containers *inside* a container, independent from the host's docker instance") with an optional `dockerHostGatewayIP` ("Set the IP used to resolve the special 'host-gateway' value in --add-host"); nothing about `host.docker.internal`. Per [Docker Engine DNS docs](https://docs.docker.com/engine/network/#dns-services), "By default, containers inherit the DNS settings as defined in the `/etc/resolv.conf` configuration file."

[experiment] `docker:dind` (inner dockerd 29.8.0) as a stand-in for the feature:

```
== outer container: host.docker.internal:47811 -> hello-from-host
== DinD child (no add-host):
   host.docker.internal -> 0.250.250.254   (resolv.conf: nameserver 0.250.250.200, inherited)
   host.internal        -> 0.250.250.254
   host.docker.internal:47811 -> hello-from-host      # reaches the Mac
== DinD child with --add-host host.docker.internal:host-gateway:
   /etc/hosts: 172.17.0.1 host.docker.internal        # inner docker0 = the OUTER container
   curl -> FAIL (exit 7, connection refused)
```

So: children reach the Mac through inherited OrbStack DNS; `host-gateway` in a child is wrong unless `dockerHostGatewayIP` is set to the Mac-side address. Caveat from issue history (not doc-guaranteed): anything that replaces `/etc/resolv.conf` (e.g. a container DNS at `127.0.0.11`, [orbstack#988](https://github.com/orbstack/orbstack/issues/988)) breaks the name; it regressed once in v1.7.3 ([orbstack#1466](https://github.com/orbstack/orbstack/issues/1466), "Fixed in v1.7.4"); several reports implicate IPv6 selection ([orbstack#549](https://github.com/orbstack/orbstack/issues/549), [orbstack#2608](https://github.com/orbstack/orbstack/issues/2608) "Try `curl -4`") — prefer IPv4 (`host.docker.internal` has only an A record here; `host.internal` also has an AAAA).

### 1e. Reverse direction (host → container), briefly

- [Docker networking](https://docs.orbstack.dev/docker/network): "You can also connect to containers by IP, directly from Mac!" and `-p` forwarding "will be available on localhost, just like Linux." "By default, forwarded ports are also reachable from other devices on your network. To limit them to your Mac, turn off Expose ports to LAN".
- [Container domains](https://docs.orbstack.dev/docker/domains): "Each container in OrbStack has a domain name, container-name.orb.local" — "Container domains currently depend on the direct IP access feature".
- Not needed for the shim design (the container initiates every request), but it means a host service *could* push to a container-side listener if a later design wants it.

## 2. Unix socket bind mounts

### 2a. OrbStack: not supported (maintainer) — and what actually happens in 2.2.3

Docs: [File sharing](https://docs.orbstack.dev/docker/file-sharing): "When running containers, you can bind mount Mac files into the container." — "You don't need to do anything special with the paths; bind mounts work seamlessly as they would on Linux." — "OrbStack uses the latest VirtioFS technology with additional tuning for speed". **The page says nothing about Unix sockets.** The only documented Mac-socket→container path is the SSH agent ([Docker › SSH agent forwarding](https://docs.orbstack.dev/docker/#ssh-agent-forwarding)): "you can forward your SSH agent from Mac to the container: `docker run -it --rm -v /run/host-services/ssh-auth.sock:/agent.sock -e SSH_AUTH_SOCK=/agent.sock alpine`" — "You can also use `-v $SSH_AUTH_SOCK:/agent.sock` in most cases, but this will not work if you're using 1Password's agent." The [release notes](https://docs.orbstack.dev/release-notes) v0.1.6 → v2.2.3 contain no entry about general Unix-socket bind mounts.

Maintainer statements (kdrag0n):
- [orbstack#62 "Support for bind mounting Unix sockets"](https://github.com/orbstack/orbstack/issues/62) — **OPEN** since 2023-03-28: "Similar to WSL, Unix sockets are not supported on the shared macOS file system. I wouldn't say it's impossible, but Unix sockets across OS boundaries is a **very** difficult problem".
- [orbstack#601](https://github.com/orbstack/orbstack/issues/601): "Sharing Unix sockets between Linux and macOS is not supported, so you'll have to use socat to forward it over TCP. Subscribe to #62 for updates."
- [orbstack#1062](https://github.com/orbstack/orbstack/issues/1062): "`$SSH_AUTH_SOCK` currently only works for macOS' default ssh-agent started by launchd. This limitation will be removed by #62".

[experiment] Host: Python `AF_UNIX` echo server on `$TMPDIR/adc-research/clip.sock`. Container: `python:3-alpine`, socket file and directory bind-mounted, root and `-u 1000:1000`:

```
mode: 0o140755 is_socket: True   (inode visible, virtiofs mount: "mac on /x type virtiofs (rw,relatime)")
s.connect("/run/clip.sock") -> ConnectionRefusedError: [Errno 111] Connection refused
```

In 2.2.3 the mount succeeds (no "operation not supported" as in #1062) but there is no listener on the Linux side, so `connect()` is refused. Contrast: `-v /var/run/docker.sock:/var/run/docker.sock` and even `-v $HOME/.orbstack/run/docker.sock:/var/run/docker.sock` both work (`docker version` → server 29.4.0) because those are OrbStack's own special-cased paths. A related gotcha found on the way: macOS `sun_path` is 104 bytes — `bind()` on a long path fails with `AF_UNIX path too long`; `~/.local/state/adc/clipboard.sock` is fine (~50 bytes) but a deep `$TMPDIR`-style path is not.

For contrast, Docker Desktop *does* support this: [release notes](https://docs.docker.com/desktop/release-notes/) 4.40.0 "Docker Desktop now allows Unix domain sockets to be shared with containers via `docker run -v /path/to/unix.sock:/unix.sock`. The full socket path must be specified in the bind-mount." and 4.86.0 "AF_UNIX sockets shared over VirtioFS now work in both directions". Out of scope for this map (macOS + OrbStack only), but it is the one thing that would differ if the runtime changed.

### 2b. devcontainer.json `mounts` — supported syntax

[devcontainer.json reference](https://containers.dev/implementors/json_reference/): "`mounts` 🏷️ | string or object | Defaults to unset. Cross-orchestrator way to add additional mounts to a container. Each value is a string that accepts the same values as the Docker CLI `--mount` flag. Environment and pre-defined variables may be referenced in the value." Variables: "`${localEnv:VARIABLE_NAME}` | Any | Value of an environment variable on the **host machine** ... A default value for when the environment variable is not set can be given with `${localEnv:VARIABLE_NAME:default_value}`." and "`${localWorkspaceFolder}` | Any | Path of the local folder that was opened".

[Schema](https://github.com/devcontainers/spec/blob/main/schemas/devContainer.base.schema.json): object form is `{type: "bind"|"volume", source, target}` with `additionalProperties: false` — options like `readonly`/`bind-create-src` need the string form. [CLI `dockerfileUtils.ts`](https://github.com/devcontainers/cli/blob/main/src/spec-node/dockerfileUtils.ts) emits `--mount type=…,src=…,dst=…` (object) or passes the string verbatim.

[VS Code: Add another local file mount](https://code.visualstudio.com/remote/advancedcontainers/add-local-file-mount) example: `"source=${localEnv:HOME}${localEnv:USERPROFILE},target=/host-home-folder,type=bind,consistency=cached"`.

Spec-valid snippet (works on Docker Desktop ≥ 4.40; on OrbStack mounts but is not connectable, §2a):

```jsonc
"mounts": [
  { "source": "${localEnv:HOME}/.local/state/adc/clipboard.sock",
    "target": "/run/adc/clipboard.sock",
    "type": "bind" }
]
```

Missing source: the CLI uses `--mount`, and per [Docker bind mounts](https://docs.docker.com/engine/storage/bind-mounts/) "By default, `--mount` does not automatically create a directory if the specified mount path does not exist on the host. Instead, it produces an error: `docker: Error response from daemon: invalid mount config for type "bind": bind source path does not exist`". (`bind-create-src`, Engine 29.3+, creates a *directory* — wrong for a socket.) So if the host service is down when the container starts, **the container does not start**. There is no optional/conditional mount: [devcontainers/spec#132 "Proposal: enable optional bind mounts"](https://github.com/devcontainers/spec/issues/132) is open since 2022 ("By default, if the `src` doesn't exist on the host the dev container start fails."); the usual workaround is an `initializeCommand` that pre-creates the source.

### 2c. Expressing the mount in `devcontainer.metadata`

[Spec › Image metadata](https://containers.dev/implementors/spec/#image-metadata): "The metadata is added to the image as a `devcontainer.metadata` label with a JSON string value representing the above array or single object." Merge table: "`mounts` | `(string \| { type, src, dst })[]` | Collected list of all mountpoints. Conflicts: Last source wins." Substitution: "Variables in string values will be substituted at the time the value is applied. When the order matters, the `devcontainer.json` is considered last."

[CLI `imageMetadata.ts`](https://github.com/devcontainers/cli/blob/main/src/spec-node/imageMetadata.ts): the label is read from the image at `up` time and substituted with the *consumer's* context (`cliHost.env`, `localWorkspaceFolder`), so **`${localEnv:HOME}` in a metadata mount resolves on the developer's Mac at container creation, not in CI**. `mergeMounts` dedups by `target` (later entry wins — devcontainer.json beats the label); different targets are unioned; a consumer cannot *remove* an inherited mount, only override the same target.

For this repo (label written from `images/*/devcontainer.json` at publish time): keep the literal `${localEnv:HOME}` in the JSON; consuming templates that are just `{"image": "ghcr.io/…"}` inherit it. This is the same mechanism the existing named-volume mounts already ride.

## 3. VS Code channels

### 3a. What Dev Containers forwards host → container

[Sharing Git credentials](https://code.visualstudio.com/remote/advancedcontainers/sharing-git-credentials): "The extension will automatically copy your local `.gitconfig` file into the container on startup" — "If you use HTTPS to clone your repositories and **have a credential helper configured in your local OS, no further setup is required.**" — SSH: "the extension will automatically forward your **local SSH agent if one is running**." — GPG: "If you want to GPG sign your commits, you can share your local keys with your container as well."

[experiment] How the SSH agent materialises inside a live Dev Containers container here: terminal env has `SSH_AUTH_SOCK=/tmp/vscode-ssh-auth-<id>.sock`, `REMOTE_CONTAINERS_SOCKETS=["/tmp/vscode-ssh-auth-<id>.sock"]`, `REMOTE_CONTAINERS_IPC=/tmp/vscode-remote-containers-ipc-<id>.sock`, `REMOTE_CONTAINERS=true`; the listening socket is held by `node /tmp/vscode-remote-containers-server-<id>.js` — the extension's own in-container helper relays it over its exec channel. It is **not** a bind mount and there is no public API to add sockets to that list (UNVERIFIED whether `REMOTE_CONTAINERS_SOCKETS` is honoured for anything but the agent; the extension is closed-source).

Ports go the other way only. [devcontainer.json reference](https://containers.dev/implementors/json_reference/): `forwardPorts` — "should always be forwarded from inside the primary container to the local machine"; `appPort` — "published locally when the container is running … your application may need to listen on all interfaces (`0.0.0.0`)". Extension API: [`env.asExternalUri`](https://code.visualstudio.com/api/references/vscode-api) "automatically establishes a port forwarding tunnel from the local machine to `target` on the remote" (remote→local); `workspace.openTunnel` is **proposed only** ([`vscode.proposed.tunnels.d.ts`](https://github.com/microsoft/vscode/blob/main/src/vscode-dts/vscode.proposed.tunnels.d.ts), TCP, remote→local); `registerRemoteAuthorityResolver` is proposed and reserved for the resolver (Dev Containers itself). [Using proposed API](https://code.visualstudio.com/api/advanced-topics/using-proposed-api): "you should not publish extensions using the proposed API on the Marketplace" and it needs `--enable-proposed-api=<id>` on Insiders.

**Bottom line**: no documented host→container socket or reverse-port forwarding; everything usable from an extension is TCP container→host.

### 3b. UI extension writing into the container: yes, via `vscode.workspace.fs`

[`workspace.fs`](https://code.visualstudio.com/api/references/vscode-api#workspace.fs): "A file system instance that allows to interact with local and remote files". [`FileSystem`](https://code.visualstudio.com/api/references/vscode-api#FileSystem): "It allows extensions to work with files from the local disk as well as files from remote places, like the remote extension host or ftp-servers." — `writeFile(uri: Uri, content: Uint8Array)`. [Remote extensions](https://code.visualstudio.com/api/advanced-topics/remote-extensions): "The VS Code APIs are designed to automatically run on the correct machine (either local or remote) when called from both UI or Workspace Extensions." and "**UI Extensions** … cannot directly access files in the remote workspace, or run scripts/tools installed in that workspace" — i.e. Node `fs` in a UI extension is the Mac; `workspace.fs` with a `vscode-remote://` URI (e.g. `Uri.joinPath(workspaceFolders[0].uri, …)`) is the container. The `vscode-remote` scheme is defined in source ([`network.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/base/common/network.ts)) and not in the API docs — the combination is inferred from the two doc statements, not stated verbatim.

### 3c. Typing into the terminal, clipboard API, intercepting Cmd+V

- [`Terminal.sendText(text, shouldExecute?)`](https://code.visualstudio.com/api/references/vscode-api#Terminal): "Send text to the terminal. The text is written to the stdin of the underlying pty process (shell) of the terminal." — `shouldExecute` "defaults to `true`"; pass `false` to insert without a newline. [`window.activeTerminal`](https://code.visualstudio.com/api/references/vscode-api#window.activeTerminal): "the one that currently has focus or most recently had focus."
- [`env.clipboard`](https://code.visualstudio.com/api/references/vscode-api#env.clipboard): interface `Clipboard` has exactly `readText()` and `writeText()`. **No image or file-list API for extensions** (VS Code's internal `NativeClipboardService` has `readImage()`/`readResources()` but they are not exposed). Remote-extensions doc: "The VS Code clipboard API … is always run locally, regardless of the type of extension that calls it." — so even a container-side extension reads the *host* clipboard, text only.
- Default macOS binding, from source [`terminal.clipboard.contribution.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/terminalContrib/clipboard/browser/terminal.clipboard.contribution.ts): `workbench.action.terminal.paste`, `primary: CtrlCmd+V`, `when: TerminalContextKeys.focus`. Its implementation: `readText()`; if empty, `readResources()` and paste `resource.fsPath` **only if `resource.scheme === Schemas.file`**; then `xterm.paste`. **Images: nothing is pasted.** Explorer Cmd+C ([`explorerService.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/files/browser/explorerService.ts)) calls `clipboardService.writeResources(...)` only — private `code/file-list` format, no `text/plain`; in a Dev Container window those resources are `vscode-remote://…`, so the `file` branch does not fire (inferred from the scheme check, not run). Drag-and-drop *is* path-aware (`terminalInstance.ts` `onDrop` → `sendPath`).
- Intercepting: [`contributes.keybindings`](https://code.visualstudio.com/api/references/contribution-points#contributes.keybindings) with [`when: terminalFocus`](https://code.visualstudio.com/api/references/when-clause-contexts) ("An integrated terminal has focus"). [Keybindings](https://code.visualstudio.com/docs/configure/keybindings): "Rules are evaluated from **bottom** to **top**." Source weights ([`keybindingsRegistry.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/platform/keybinding/common/keybindingsRegistry.ts)): built-in terminal paste is `WorkbenchContrib = 200`, extension bindings get `ExternalExtension = 400` — the extension wins. On macOS any resolved `cmd+…` binding bypasses xterm ([`terminalInstance.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/terminal/browser/terminalInstance.ts): "Skip processing by xterm.js of keyboard events that resolve to commands defined in the commandsToSkipShell setting, or that use the Meta"); for Ctrl+V on other hosts the command would need [`terminal.integrated.commandsToSkipShell`](https://code.visualstudio.com/docs/terminal/advanced#_keyboard-shortcuts-and-the-shell).
- Images in the terminal ([Terminal advanced](https://code.visualstudio.com/docs/terminal/advanced#_image-support)) are output-only (Sixel/iTerm protocols, `terminal.integrated.enableImages`) — unrelated to paste.

Pattern that follows: bind `cmd+v` / `terminalFocus` to a private command; inspect the Mac clipboard host-side (Node/`osascript`, since `env.clipboard` is text-only); default to `executeCommand('workbench.action.terminal.paste')`; otherwise `workspace.fs.writeFile(<vscode-remote uri>)` and `activeTerminal.sendText(path, false)`. Note this only helps the **VS Code** Cmd+V gesture; Claude Code's Ctrl+V runs `xclip` inside the shell and never involves VS Code.

### 3d. `extensionKind: ["ui"]` and installing a private extension

[Extension host › Preferred extension location](https://code.visualstudio.com/api/advanced-topics/extension-host#preferred-extension-location): "`"extensionKind": ["ui"]` — Indicates the extension **must** run close to the UI because it requires access to local assets, devices, or capabilities or because low latency is required." — "`["ui", "workspace"]` — Indicates the extension **prefers** to run as a UI extension … the user does not have to install the extension on the remote." — "`["workspace"]` … Most extensions fall into this category."

[Dev Containers › Managing extensions](https://code.visualstudio.com/docs/devcontainers/containers#_managing-extensions): "VS Code runs extensions in one of two places: locally on the UI / client side, or in the container." — "Local extensions that actually need to run remotely will appear **Disabled** in the **Local - Installed** category." [Forcing an extension to run locally or remotely](https://code.visualstudio.com/docs/devcontainers/containers#_advanced-forcing-an-extension-to-run-locally-or-remotely): `"remote.extensionKind": { "<id>": ["ui"] }` — "Typically, this should only be used for testing unless otherwise noted in the extension's documentation since it **can break extensions**."

`customizations.vscode.extensions` ([supporting tools](https://containers.dev/supporting)): "An array of extension IDs that specify the extensions that should be installed inside the container when it is created." — no documented way to force a UI-side install from devcontainer.json. A private VSIX goes on the Mac with [`code --install-extension <vsix>`](https://code.visualstudio.com/docs/configure/command-line) ("Install or update an extension. Provide either the full extension name `publisher.extension` or the path to a VSIX file"); with `["ui"]` it runs in the local host and VS Code does not try to install it remotely (consequence of the kind rules; not a verbatim doc sentence). [Remote extensions › Installing a development version](https://code.visualstudio.com/api/advanced-topics/remote-extensions): "Use the **Install from VSIX...** command available in the Extensions view **More Actions** (`...`) menu to install the extension in this specific window" and "**Developer: Show Running Extensions** command to see whether VS Code is running the extension locally or remotely."

### 3e. UI ↔ workspace extension communication

[Remote extensions](https://code.visualstudio.com/api/advanced-topics/remote-extensions): "VS Code automatically routes any executed commands to the correct extension regardless of its location. You can freely invoke any command (including those provided by other extensions)" — "any objects you pass in as parameters will be "stringified" (`JSON.stringify`)". `getExtension(...).exports` "will not work between UI and Workspace Extensions". Also: "`vscode.env.openExternal` **does automatic localhost port forwarding!**" and `asExternalUri` "may not reference localhost at all, so you should use it in its entirety." So a container-side extension can call a UI-extension command (and vice versa) with JSON-serialisable args (a PNG would go base64 or via `workspace.fs`).

## 4. Host service shape (launchd user agent)

Man pages quoted are the ones shipped on macOS 15.7.5: `launchd.plist(5)` (dated 2019-07-30), `launchctl(1)` (2014-10-01), `launch(3)` (2014-03-31). Throwaway experiments used label `dev.adc.research-test` in `gui/501` and were booted out afterwards; nothing remains in `~/Library/LaunchAgents`.

### 4a. Location, agent vs daemon, keys

- Location. [Creating Launch Daemons and Agents](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html): "You indicate whether it describes a daemon or agent by the directory you place it in. Property list files describing daemons are installed in /Library/LaunchDaemons, and those describing agents are installed in /Library/LaunchAgents or in the LaunchAgents subdirectory of an individual user's Library directory." `launchctl(1)` FILES: "`~/Library/LaunchAgents` Per-user agents provided by the user." Naming (`launchd.plist(5)`): "it is the expected convention for launchd property list files to be named <Label>.plist". Ownership (`launchctl(1)`): LaunchAgents in `$HOME` "must be owned by … the user loading them" and "must disallow group and world writes."
- Why an agent, not a daemon. [Designing Daemons and Services](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/DesigningDaemons.html): "daemons also have no access to the window server" — "Agents are managed by launchd, but are run on behalf of the currently logged-in user (that is, in the user context)." Creating guide: "A user agent is essentially identical to a daemon, but is specific to a given logged-in user and executes only while that user is logged in."
- Keys (`launchd.plist(5)`): `Label` "This required key uniquely identifies the job to launchd." `Program` "must be an absolute path"; a relative `ProgramArguments[0]` "is resolved using _PATH_STDPATH" (`/usr/bin:/bin:/usr/sbin:/sbin`). `RunAtLoad` "The default is false. This key should be avoided, as speculative job launches have an adverse effect". `KeepAlive` "The default is false and therefore only demand will start the job. The value may be set to true to unconditionally keep the job alive." — "Jobs that exit quickly and frequently when configured to be kept alive will be throttled" — "The use of this key implicitly implies RunAtLoad". Dict forms: `SuccessfulExit` ("restarted as long as the program exits and with an exit status of zero … If false, the job will be restarted in the inverse condition"), `Crashed`, `PathState` ("Filesystem monitoring mechanisms are inherently race-prone and lossy. This option should be avoided in favor of demand-based alternatives using IPC."), `OtherJobEnabled` ("Use of this key is highly discouraged."). `ThrottleInterval` "by default, jobs will not be spawned more than once every 10 seconds." `StandardOutPath`/`StandardErrorPath` (created on demand). `EnvironmentVariables` "additional environmental variables to be set before running the job … Values other than strings will be ignored." `WorkingDirectory` "a directory to chdir(2) to before running the job." `LimitLoadToSessionType` "This key only applies to jobs which are agents." — the plist man page does **not** enumerate values; `launchctl(1)` (`load -S`) does: "Relevant sessions are Aqua (the default), Background and LoginWindow. … Aqua agents are loaded only when a user has logged in at the GUI." `StandardIO`/`System` as values: UNVERIFIED (absent from both man pages).
- EXPECTATIONS (`launchd.plist(5)`): "A daemon or agent launched by launchd MUST NOT … Call daemon(3)" and "SHOULD: Launch on demand … Handle the SIGTERM signal".
- Does Aqua give clipboard access? Not documented anywhere. [experiment] a `/bin/zsh` agent bootstrapped into `gui/501` ran `/usr/bin/osascript -e 'clipboard info'` and got the live clipboard's flavours (`«class PNGf», 83179, … TIFF picture, 5567182 …`), same as the interactive shell; `launchctl managername` inside the agent printed `Aqua` both with and without `LimitLoadToSessionType`. One earlier run saw `pbpaste` return 0 bytes while the terminal had text — attributed to the clipboard changing during the test (the repeat agreed in both contexts); re-verify with a controlled clipboard before relying on it.

### 4b. Socket activation and the script-friendly `inetdCompatibility` path

`launchd.plist(5)` `Sockets`: "launch on demand sockets that can be used to let launchd know when to run the job. The job must check-in to get a copy of the file descriptors using the launch_activate_socket(3) API." Sub-keys: `SockType` ("default is "stream""), `SockPassive` ("default is true, to listen for new connections"), `SockNodeName` ("the node to connect(2) or bind(2) to"), `SockServiceName` ("a port number represented as an integer or a service name"), `SockFamily` ("IPv4" / "IPv6" / "IPv4v6"), `SockPathName` ("implies SockFamily is set to "Unix""), `SockPathMode` ("Property lists don't support octal, so please convert the value to decimal."). `launch(3)`: `int launch_activate_socket(const char *name, int **fds, size_t *cnt);` — "allows a launchd(8) job to retrieve a set of file descriptors corresponding to a socket service that launchd(8) has created and advertised on behalf of the job" — a C API; no shell wrapper is documented, so a zsh service cannot call it.

`inetdCompatibility` (`launchd.plist(5)`): "The presence of this key specifies that the daemon expects to be run as if it were launched from inetd. For new projects, this key should be avoided." `Wait`: "If true, then the listening socket is passed via the stdio(3) file descriptors. If false, then accept(2) is called on behalf of the job, and the result is passed via the stdio(3) descriptors." Apple's guide (Table 5-1): "This causes launchd to behave like inetd, passing each daemon a single socket that is already connected to the incoming client."

[experiment] plist with `Sockets.Listener = {SockType stream, SockNodeName 127.0.0.1, SockServiceName 47123, SockFamily IPv4}` + `inetdCompatibility.Wait=false` + `ProgramArguments [/bin/zsh, echo.zsh]` where the script does `IFS= read -r line; print -r -- "hello from launchd agent pid=$$ you said: $line"`: `bootstrap` exit 0; `launchctl print` → `state = not running`, `properties = inetd-compatible | …`; two `nc 127.0.0.1 47123` clients got replies from pids 31303 and 31306 (one process per connection); after `bootout` the port was closed. **A plain zsh script can serve a launchd-held `127.0.0.1` port with zero listener code** — at the cost of a zsh spawn per Ctrl+V (which then runs `osascript`, §5e) and the "should be avoided" caveat. `Wait=true` (listening socket on fd 0) needs `accept(2)` and is not doable from zsh.

### 4c. `launchctl` and an idempotent install/uninstall

Targets (`launchctl(1)`): "gui/<uid>/[service-name] … targets the domain based on which user it is associated with and is generally more convenient." — "domain-target is gui/501/, service-name is com.apple.example, and service-target is gui/501/com.apple.example." Subcommands: `bootstrap | bootout domain-target [service-path …] | service-target` "Bootstraps or removes domains and services."; `enable | disable service-target` "Once a service is disabled, it cannot be loaded in the specified domain until it is once again enabled. This state persists across boots"; `kickstart [-kp] service-target` "run the specified service immediately, regardless of its configured launch conditions. -k If the service is already running, kill the running instance before restarting"; `print` "IMPORTANT: This output is NOT API in any sense at all." Legacy: "load | unload … Recommended alternative subcommands: bootstrap | bootout | enable | disable" and "the load and unload subcommands will only return a non-zero exit code due to improper usage. Otherwise, zero is always returned." — useless for idempotency checks. `launchctl error <code>` decodes exit codes.

[experiment] exit codes on 15.7.5 (`gui/501`):

| Command | Output | Exit |
|---|---|---|
| `launchctl print gui/501/<label>` (not loaded) | `Could not find service "…" in domain for user gui: 501` | 113 |
| `launchctl bootstrap gui/501 <plist>` (first) | — | 0 |
| `launchctl bootstrap gui/501 <plist>` (already loaded) | `Bootstrap failed: 5: Input/output error` | 5 |
| `launchctl print gui/501/<label>` (loaded) | `state = running`, `path = …`, `runs = 1` | 0 |
| `launchctl bootout gui/501/<label>` (loaded) | — | 0 |
| `launchctl bootout gui/501/<label>` (not loaded) | `Boot-out failed: 3: No such process` | 3 |
| `launchctl bootout gui/501 <plist-path>` (not loaded) | `Boot-out failed: 5: Input/output error` | 5 |

Exit codes are observed, not documented per situation. Sequence for `adc`:

```zsh
label=dev.adc.clipboard
plist=~/Library/LaunchAgents/$label.plist
adc_svc_loaded() { launchctl print "gui/$UID/$label" >/dev/null 2>&1; }   # 0 loaded, 113 not

# install / reinstall
install -d -m 755 ~/Library/LaunchAgents
print -r -- "$PLIST_XML" > "$plist"; chmod 644 "$plist"     # user-owned, not group/world-writable
if adc_svc_loaded; then launchctl bootout "gui/$UID/$label"; fi
launchctl enable "gui/$UID/$label"                            # clears a persisted 'disable'
launchctl bootstrap "gui/$UID" "$plist"
# KeepAlive-style service only: launchctl kickstart -k "gui/$UID/$label"

# uninstall
if adc_svc_loaded; then launchctl bootout "gui/$UID/$label"; fi
rm -f "$plist"
```

### 4d. Environment, absolute paths, and where Sheldon puts `adc`

- `launchd.plist(5)` documents no default PATH beyond `_PATH_STDPATH`; `launchctl(1)`: `getenv key` "Print the value of an environment variable that launchd would set for all processes launched into the caller's context."; `config user path` "Sets the PATH environment variable for all services within the target domain … A reboot is required". [experiment] `launchctl getenv PATH` printed an empty line; the agent received 13 variables (`HOME LOGNAME OLDPWD PATH PWD=/ SHELL SHLVL SSH_AUTH_SOCK TMPDIR USER XPC_FLAGS XPC_SERVICE_NAME _`), cwd `/`, and `PATH=/Users/dbarjs/.cargo/bin:/Users/dbarjs/.vite-plus/bin:/usr/bin:/bin:/usr/sbin:/sbin` (the two prefixes are of UNVERIFIED origin; no Homebrew, no `~/.local/bin`, no rc files). **The plist must use `/bin/zsh` and the absolute `adc` path, and set `EnvironmentVariables.PATH` if it shells out to anything outside the standard path.** Note `SSH_AUTH_SOCK` *is* set in the gui domain (the launchd ssh-agent) — the 1Password socket from the user's zshrc is not.
- Sheldon ([CLI](https://sheldon.cli.rs/Command-line-interface.html)): "`SHELDON_DATA_DIR` — Set the data directory where plugins will be downloaded to. This defaults to `$XDG_DATA_HOME/sheldon` or `~/.local/share/sheldon`." [Configuration](https://sheldon.cli.rs/Configuration.html): "Git sources specify a remote Git repository that will be cloned to the Sheldon data directory." Layout `repos/github.com/<owner>/<repo>` per the [Examples](https://sheldon.cli.rs/Examples.html) (`$HOME/.local/share/sheldon/repos/github.com/ohmyzsh/ohmyzsh`); verified locally (`~/.local/share/sheldon/repos/github.com/dbarjs/…` exists, `sheldon source` emits `source "/Users/dbarjs/.local/share/sheldon/repos/github.com/…/x.plugin.zsh"`). Default `match` includes `"{{ name }}.plugin.zsh"`, so `adc.plugin.zsh` is sourced by **absolute** path.
- Self-locating: zsh [`$0`](https://zsh.sourceforge.io/Doc/Release/Parameters.html#index-0): "If the FUNCTION_ARGZERO option is set, $0 is set … upon entry to a sourced script to the name of the script". [`FUNCTION_ARGZERO`](https://zsh.sourceforge.io/Doc/Release/Options.html) is on by default in native zsh mode (off under sh/ksh emulation). [experiment] `zsh -f`, sourcing `./argzero.zsh` → `${0:A:h}` = the script's directory. Capture `${0:A:h}` at the top of `adc.plugin.zsh` (before any `emulate`) to get the clone dir for `ProgramArguments`.

### 4e. On-demand vs always-on, `ProcessType`, SMAppService

- On demand: Apple's guide, Table 5-1 `KeepAlive` row: "It is recommended that you design your daemon to be launched on-demand." `launchctl(1)`: "A service may be thought of as a virtual process that is always available to be spawned in response to demand." Verified in §4b (`state = not running` until a client connects).
- Always-on: `KeepAlive=true` (§4a) with the script owning the listener — which in zsh means an external listener (`nc -l`, `socat`, python3 `socketserver` …); Homebrew tools are not on the agent's PATH (§4d).
- `ProcessType` (`launchd.plist(5)`): "If left unspecified, the system will apply light resource limits to the job, throttling its CPU usage and I/O bandwidth." `Background` "intended to prevent them from disrupting the user experience"; `Interactive` "run with the same resource limitations as apps, that is to say, none … should only be used if an app's ability to be responsive depends on it"; `Adaptive` moves between the two "based on activity over XPC connections". For a per-keystroke service, `Interactive` or `Standard` is the honest choice.
- [`SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice) (macOS 13+): "An object the framework uses to control helper executables that live inside an app's main bundle." — "the register() and unregister() methods provide a replacement for installing property lists in ~/Library/LaunchAgents". `launchd.plist(5)` `BundleProgram`: "an app-bundle relative path … only supported for plists that are installed using SMAppService." A Sheldon-installed script has no bundle → `~/Library/LaunchAgents` + `launchctl bootstrap` is the applicable path.

### 4f. Privacy under a launchd agent

See §5f for the `NSPasteboard.AccessBehavior` / "upcoming feature" quotes. Additional facts for the agent context: Apple's macOS release-notes index (61 pages incl. 15.4, 26, 26.1) contains no "pasteboard" entry; the only related item is [macOS Tahoe 26 security content](https://support.apple.com/en-us/125110) CVE-2025-43310 ("An app may be able to trick a user into copying sensitive data to the pasteboard"), a fix not the alert feature. [experiment] `osascript -e 'clipboard info'` and `pbpaste` from the `gui/501` agent ran with no alert on 15.7.5. Whether the alert applies to un-bundled CLI tools or launchd agents, and whether it ships on by default in macOS 26.x: UNVERIFIED.

## 5. Reading and writing the macOS clipboard from a script

Primary doc: [AppleScript Language Guide › StandardAdditions](https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/reference/ASLR_cmds.html#//apple_ref/doc/uid/TP40000983-CH216-SW7): `the clipboard` — "Returns the contents of the clipboard." (`as class` "Specifies the desired class for the returned data."); `clipboard info` — "A list containing one entry {class, size} for each type of data on the clipboard." (`for class` "Restricts returned information to only this data type."); `set the clipboard to value` — "Places data on the clipboard." The guide does not name `«class PNGf»`/`«class furl»`; their behaviour below is from experiments. `/usr/bin/osascript`, `pbcopy`, `pbpaste` ship with macOS (no Xcode/CLT).

### 5a. `pbpaste` / `pbcopy` (text)

`man pbpaste` (PBCOPY(1)): "pbcopy takes the standard input and places it in the specified pasteboard … The input is placed in the pasteboard as plain text data unless it begins with the Encapsulated PostScript (EPS) file header or the Rich Text Format (RTF) file header" — "If none of those types is present in the pasteboard, pbpaste produces no output." — BUGS: "There is no way to tell pbpaste to get only a specified data type." Encoding: "setting the environment variable LANG=en_US.UTF-8 will cause pbcopy and pbpaste to use UTF-8".

[experiment] Image-only clipboard: `pbpaste | wc -c` → `0`, exit **0** (cannot distinguish "no text" from empty text — use `clipboard info`). `pbcopy < x.png` does **not** set an image: 70 bytes in → `«class utf8», 86` out, no `PNGf` flavour, round trip not byte-identical.

### 5b. Images and files with `osascript`

Detect (cheap, no error when absent):

```
$ osascript -s s -e 'clipboard info for «class PNGf»'     # -s s = recompilable output
{}                                  # no image, exit 0
{{«class PNGf», 83179}}             # image present, exit 0
```

Unrestricted `clipboard info` on an image lists every auto-converted flavour (`PNGf, 8BPS, GIF, jp2, JPEG, TIFF, BMP, TPIC`) and is ~2x slower (§5e). Reading an absent flavour errors: `the clipboard as «class PNGf»` on text → `execution error: Can't make some data into the expected type. (-1700)`, exit 1.

Dump (byte-identical round trip verified with `cmp`, also on a real 2664x522 screenshot):

```sh
osascript -e 'set png to the clipboard as «class PNGf»' \
  -e 'set f to open for access (POSIX file "/abs/out.png") with write permission' \
  -e 'set eof f to 0' -e 'write png to f' -e 'close access f'
```

Files. `«class furl»` in `clipboard info` corresponds to `public.file-url` on the NSPasteboard ([`UTType.fileURL`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype/fileurl): "The identifier for this type is public.file-url."; [`NSPasteboard.PasteboardType.fileURL`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype/fileurl): "A file URL."). [experiment] with two file URLs written to the pasteboard:

- `osascript -e 'POSIX path of (the clipboard as «class furl»)'` → **first file only**; `clipboard info` also reports a single `«class furl»` entry.
- All files: JXA `pb.readObjectsForClassesOptions([$.NSURL], {NSPasteboardURLReadingFileURLsOnlyKey: true})` → one path per line (script in the appendix).
- **False positive**: on a plain-text clipboard `the clipboard as «class furl»` does not error — `echo 'hello clipboard' | pbcopy` then the coercion returns `/hello clipboard`. Gate on `clipboard info for «class furl»` ≠ `{}`, never on the coercion succeeding. (This is also a latent bug in Claude Code's own macOS path, worth knowing when reproducing its behaviour in the shim.)
- What Finder Cmd+C puts on the clipboard: UNVERIFIED by experiment (driving Finder needs an Automation TCC grant); Apple's docs establish `public.file-url` as the file-reference type and the JXA write reproduces AppKit's type set (`public.file-url`, `NSFilenamesPboardType`, `Apple URL pasteboard type`).

Precedence: `clipboard info` lists all flavours; a browser copy can carry both `PNGf`/`TIFF` and `utf8`. PNGf → furl → text, as Claude Code does, is consistent with everything above.

### 5c. `pngpaste` (optional dep)

[jcsalterego/pngpaste](https://github.com/jcsalterego/pngpaste): "Paste PNG into files on MacOS, much like `pbpaste` does for text." — "`brew install pngpaste`" — "`pngpaste hooray.png`" — "Supported input formats are PNG, PDF, GIF, TIF, JPEG." — "Error Handling — Minimal :'(". Flags from `pngpaste.m` `usage()`: `-` (stdout), `-b` (base64 to stdout), `-v`. It builds an `NSImage` from the pasteboard and re-encodes, which is why a TIFF-only clipboard comes out as PNG. Maintenance: 0.2.3, last commit 2020-05-04, no GitHub releases, `brew info` "stable 0.2.3 (bottled)". Not installed here. **Not needed**: the osascript dump above covers PNGf; the only gain would be TIFF-only clipboards (rare; `the clipboard as TIFF picture` reads those too, conversion to PNG then needs `sips`).

### 5d. Write path (for `/copy`)

| Want | Command | Verified |
|---|---|---|
| Text | `printf '%s' "$text" \| pbcopy` | yes |
| PNG | `osascript -e 'set the clipboard to (read (POSIX file "/abs/p.png") as «class PNGf»)'` | yes — PNGf + auto TIFF/JPEG/… flavours, read-back byte-identical |
| File reference(s) | JXA `NSPasteboard.generalPasteboard.writeObjects([NSURL.fileURLWithPath(p)…])` (appendix) | yes — yields `public.file-url`; `the clipboard as «class furl»` reads it back |
| File reference, pure AppleScript | `set the clipboard to (POSIX file …)` / `as «class furl»` / `as alias` / list | **does not work** — empty pasteboard, or `com.apple.alias-record` / opaque list only |

Whether pasting the JXA-written file URL into Finder produces a copy: UNVERIFIED (GUI). Claude Code's `/copy` today writes text, so text + PNG cover the map's stated `/copy` need; file refs are a bonus.

### 5e. Cost per call (macOS 15.7.5, M4 Pro, 5 warm runs)

| Command | text clipboard | image clipboard (83 KB PNG, 5.5 MB TIFF flavour) |
|---|---|---|
| `pbpaste` | ~7 ms | ~6 ms |
| `osascript -e '1'` (bare startup) | ~17 ms | — |
| `osascript -e 'clipboard info for «class PNGf»'` | ~63 ms | ~66 ms |
| `osascript -e 'clipboard info'` (unrestricted) | ~72 ms | **~150 ms** |
| JXA type dump (`NSPasteboard.types`) | ~32 ms | ~30 ms |
| full PNG read to file | — | ~157 ms |

Host-side detection + dump therefore lands around 200–250 ms per Ctrl+V, dominated by osascript, not by the container→host hop (~1.5 ms, §1c).

### 5f. TCC / pasteboard privacy

- [experiment] ~60 `osascript`/`pbpaste`/`pbcopy` runs from a VS Code-spawned shell: no prompt, no denial. tccd logs an attribution check on each `osascript` launch (service name redacted) and nothing for `pbpaste`/`pbcopy`. The scripts use StandardAdditions and the ObjC bridge only — no `tell application`, so no Automation consent was requested ([`NSAppleEventsUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription): "This key is required if your app uses APIs that send Apple events."). That StandardAdditions-only scripts never need it is consistent with observation but UNVERIFIED as a documented guarantee; launchd-context behaviour untested.
- macOS pasteboard privacy: [`NSPasteboard.AccessBehavior`](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum) (macOS 15.4+): `.ask` — "The system will notify the user and ask for permission before granting pasteboard access. However, access that is both user originated and paste related will always be allowed"; "The user can customize this behavior per-app in System Settings for any app that has triggered a pasteboard access alert in the past." [AppKit updates › April 2025](https://developer.apple.com/documentation/updates/appkit): "Prepare your app for an upcoming feature in macOS that alerts a person using a device when your app programmatically reads the general pasteboard." — "New detect methods in NSPasteboard and NSPasteboardItem make it possible for an app to examine the kinds of data on the pasteboard without actually reading them" — opt-in on 15.x via `defaults write <bundle id> EnablePasteboardPrivacyDeveloperPreview -bool yes`. Whether it is on by default in a later macOS, and how `osascript`/`pbpaste` reads under a launchd agent get attributed: UNVERIFIED. If it bites, the fix is per-app "Always Allow" in System Settings for whichever responsible app the service runs under.

## Left open for the mechanism ticket

- Socket-activated (`inetdCompatibility`, one zsh per request, "should be avoided" per the man page) vs always-on (`KeepAlive`, needs a listener the agent can find on its PATH). Both verified to serve `127.0.0.1` from `gui/$UID`.
- Port choice and discovery: fixed port baked into the image vs written to a file the shim reads; several containers and DinD children all hit the same `host.docker.internal:<port>` and the host cannot distinguish them (all `127.0.0.1`).
- The Cmd+V copied-file gesture: VS Code's terminal paste ignores images and only pastes `file:`-scheme resources, so Explorer copies in a Dev Container window need a UI-side extension keybinding on `cmd+v`/`terminalFocus`; Finder copies (`public.file-url`) can be read host-side by the service. Where transferred files land in the container is undecided.
- macOS pasteboard-privacy alert behaviour for `osascript`/`pbpaste` under a launchd agent (UNVERIFIED; opt-in on 15.x).
- Whether `the clipboard as «class furl»` false-positive on text (§5b) needs a workaround in the shim's furl path.

## Appendix: JXA helpers (verified)

```js
// pbfiles.js — osascript -l JavaScript pbfiles.js → one POSIX path per line for every file URL
ObjC.import('AppKit');
var pb = $.NSPasteboard.generalPasteboard;
var opts = $.NSDictionary.dictionaryWithObjectForKey(true, $.NSPasteboardURLReadingFileURLsOnlyKey);
var urls = pb.readObjectsForClassesOptions($([$.NSURL]), opts);
var out = []; if (!urls.isNil()) for (var i = 0; i < urls.count; i++) out.push(ObjC.unwrap(urls.objectAtIndex(i).path));
out.join('\n');
```

```js
// pbsetfiles.js — osascript -l JavaScript pbsetfiles.js /abs/a /abs/b → sets public.file-url items
ObjC.import('AppKit');
function run(argv) {
  var pb = $.NSPasteboard.generalPasteboard; pb.clearContents;
  var urls = argv.map(function (p) { return $.NSURL.fileURLWithPath(p); });
  return 'writeObjects=' + pb.writeObjects($(urls)) + ' changeCount=' + pb.changeCount;
}
```
