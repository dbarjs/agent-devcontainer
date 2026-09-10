# PROTOTYPE — fake `xclip` shim + host clipboard daemon (issue #50)

Throwaway spike for [map #46](https://github.com/dbarjs/agent-devcontainer/issues/46). Not the implementation.
Question: does a shim `xclip` in the container, proxying over TCP to a host clipboard daemon at
`host.docker.internal:47820`, make Claude Code CLI's **Ctrl+V** attach a host screenshot inside a live adc
devcontainer — with zero Claude Code changes?

**Answer: yes.** Verified 2026-09-10 on macOS 15.7.5 / OrbStack 2.2.3 against a live Dev Containers
container (`ghcr.io/dbarjs/agent-devcontainer/node:latest`, Claude Code 2.1.267 Linux arm64), driving
`claude` in a pty and sending `\x16`.

## Run it

```sh
# host — foreground, Ctrl+C to stop; logs every request + latency to stderr
python3 spike/clipboard/host/adc-clipd

# container — install the shim (throwaway: goes to /usr/local/bin, not the claude-bin volume)
docker cp spike/clipboard/container/xclip <container>:/usr/local/bin/xclip
docker exec -u root <container> chmod 755 /usr/local/bin/xclip

# container — Claude's exact shell strings (contract §1a/§1b/§1c), no TUI
docker exec <container> sh spike/clipboard/container/shapes.sh     # copy it in first; /tmp is tmpfs, docker cp can't land there

# container — the real thing: run claude in a pty, press Ctrl+V, report the chip + latency
docker cp spike/clipboard/container/drive-ctrl-v.py <container>:/usr/local/bin/drive.py
docker exec -e ADC_XCLIP_LOG=/tmp/xclip.log <container> sh -c 'PATH=$HOME/.local/bin:$PATH python3 /usr/local/bin/drive.py; cat /tmp/xclip.log'
```

`ADC_XCLIP_LOG=<file>` makes the shim append one line per invocation (argv + what it did).

## Results

| Host clipboard | Ctrl+V in `claude` (pty) | Ctrl+V → chip visible | shim calls |
|---|---|---|---|
| PNG set programmatically | `[Image #1]` | 0.18 s | `TARGETS` → `image/png -o` |
| **real `screencapture -c`** (Cmd+Ctrl+Shift+4 equivalent) | `[Image #1]` | 0.15 s | same |
| plain text (`pbcopy`) | text pasted into the prompt | — | `TARGETS` → `-o` |
| Finder-style file copy, **inside** workspace (`public.file-url`) | `[Image #1]`, `sourcePath` = `/workspaces/<repo>/<file>` (mapped via mountinfo, no copy) | 0.23 s | `TARGETS` → `-o` |
| Finder-style file copy, **outside** workspace (`~/Desktop/adc spike outside.png`) | `[Image #1]`, file transferred to `/tmp/adc-clipboard/<name>` | 0.31 s | `TARGETS` → `-o` → `/file/bytes` |
| daemon down | toast "No image found in clipboard" | 0.05 s (ECONNREFUSED is instant) | both fail fast |

Writes: shape 7 (`xclip -selection clipboard` ← stdin) lands in `pbpaste`; shape 9 (`-t image/png -i f`)
puts `«class PNGf»` on the pasteboard. Shapes 3/6/8 exit non-zero / no-op as the contract allows.

Daemon latency per request (one `osascript -l JavaScript` each): `/types` ≈57 ms, `/png` ≈44 ms, `/text` ≈38 ms,
`/file` ≈54 ms. Container→host TCP adds ~2 ms. A full Ctrl+V is two round trips ≈ 120 ms.

Facts learned on the way:

- `/proc/self/mountinfo` inside an OrbStack container shows the **host source path** of every virtiofs bind mount
  (`/Users/dbarjs/dev/x /workspaces/x … - virtiofs mac rw`), so host→container path mapping needs no config.
- Optional mountinfo fields vary in count: parse the fs type after the ` - ` separator, not positionally.
- `docker cp` cannot write into the container's `/tmp` (tmpfs).
- Text read via `xclip -selection clipboard -o` (argv, 2 s timeout) is what fires for **every** non-image Ctrl+V, so the
  Finder-file transfer must complete inside that window; a 38 KB file took ~300 ms end to end.
- macOS 15.7.5 shows no pasteboard-privacy prompt for `osascript` reads from a foreground daemon (launchd agent still
  unverified — that's macOS 16 territory anyway).

## Not verified by this spike (needs a human at the VS Code integrated terminal)

1. Ctrl+V in `claude` in the **VS Code integrated terminal** of the Dev Container window (does the terminal pass `\x16` through?).
2. Cmd+V after a **Finder** Cmd+C: VS Code pastes the bare filename — the `basename` branch then calls
   `xclip -t text/plain -o` and should attach the file. Explorer Cmd+C pastes nothing (#49) — that gesture is #58.
3. `/copy` → OSC 52 → macOS clipboard from a Dev Container terminal. If it works, shim shapes 7/8 (and `DISPLAY`) are unnecessary.
