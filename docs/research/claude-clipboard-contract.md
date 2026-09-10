# Claude Code's Linux clipboard contract (v2.1.267)

Research for [issue #48](https://github.com/dbarjs/agent-devcontainer/issues/48) (map [#46](https://github.com/dbarjs/agent-devcontainer/issues/46)): what a shim `xclip` (and/or `wl-paste`) inside the container must do so that Claude Code CLI's Ctrl+V image paste, copied-file path paste, and `/copy` behave as on macOS, with zero changes to Claude Code.

## Sources and method

Primary source is the Claude Code binary itself, reconstructed from `strings -n 6` dumps. Two builds were read:

- **Linux arm64 build, v2.1.267** — `/versions/2.1.267` on the shared `claude-install` Docker volume (ELF aarch64, sha256 `226a4e00…95fefb`). **This is the authoritative build for everything below.**
- **macOS arm64 build, v2.1.267** — `/opt/homebrew/Caskroom/claude-code@latest/2.1.267/claude` (sha256 `a681f300…3d2558`). Used only for the macOS reference behaviour (§5).

The builds are **platform-specialised at bundle time**: the macOS build contains `commands: x.darwin || x.linux`, the Linux build `commands: x.linux || x.linux`, i.e. `process.platform` was inlined and dead branches removed. One consequence matters: the macOS build tries `Bun.Image.fromClipboard()` first and only falls back to shell commands when that call *throws*, while the Linux build has no `Bun.Image` clipboard path at all (its `hasClipboardImage` wrapper is compiled to `return false`). Reading only the macOS binary would wrongly suggest the `xclip` path is unreachable on Linux (Bun's `fromClipboard()` returns `null`, never throws, on Linux — [Bun `Image.rs`](https://github.com/oven-sh/bun/blob/main/src/runtime/image/Image.rs), "Linux returns `null` unconditionally"). Everything in §1–§4 was verified against the Linux build.

Code is minified; identifiers below are the Linux build's. Secondary sources: [code.claude.com docs](https://code.claude.com/docs), [anthropics/claude-code issues](https://github.com/anthropics/claude-code/issues), Bun source, VS Code issue trackers. Anything not verified from the binary is flagged **[unverified]**.

## Verdict

- Image paste on Linux is a `/bin/sh` pipeline of exactly three string commands (`checkImage`, `saveImage`, `deleteFile`) that only ever reference `xclip` and `wl-paste`. A shim `xclip` that answers `-t TARGETS -o` and `-t image/png -o` correctly is sufficient; `wl-paste` need not exist (a missing binary makes each `||` branch fail and the chain move on).
- The image path is **not** gated by `DISPLAY`, `WAYLAND_DISPLAY`, or SSH. The clipboard *text* read (used as the Ctrl+V fallback, and for `xclip -o` / `wl-paste --no-newline`) is gated by SSH only. The clipboard *write* probe is the only place `DISPLAY`/`WAYLAND_DISPLAY` matter: `xclip` is selected for writes only if `DISPLAY` is set (any value) and `xclip` is on `PATH`.
- Copied-file paste is a pure text mechanism: whatever text the terminal pastes is split into fragments; any fragment ending in `.png/.jpg/.jpeg/.gif/.webp` (case-insensitive, quotes stripped, backslash escapes removed) that is an **absolute path to an existing, readable, magic-byte-valid image file** is attached as an image. A bare filename works only if `xclip -selection clipboard -t text/plain -o` returns a path whose basename equals it — that is the Linux twin of macOS's `«class furl»` flow.
- `/copy` always emits OSC 52 to stdout and writes a copy under the temp dir, and additionally pipes the text into `xclip -selection clipboard` **and** `xclip -selection primary` when the write probe picked `xclip`. Whether OSC 52 alone already reaches the macOS clipboard through VS Code's terminal in a Dev Container is **[unverified]** and is the first thing the spike should test.

## 1. Every clipboard invocation on Linux

All Linux clipboard invocations found in the v2.1.267 Linux build. Nothing else in the binary references `xclip`, `xsel`, `wl-paste` or `wl-copy`.

### 1a. Image paste — `checkImage` / `saveImage` / `deleteFile`

Built by `Re()` and run by `AV()` (the `chat:imagePaste` reader). `${m}` is the shell-quoted temp path from §4.

```sh
# checkImage
xclip -selection clipboard -t TARGETS -o 2>/dev/null | grep -E "image/(png|jpeg|jpg|gif|webp|bmp)" || wl-paste -l 2>/dev/null | grep -E "image/(png|jpeg|jpg|gif|webp|bmp)"

# saveImage
xclip -selection clipboard -t image/png -o > ${m} 2>/dev/null || wl-paste --type image/png > ${m} 2>/dev/null || xclip -selection clipboard -t image/bmp -o > ${m} 2>/dev/null || wl-paste --type image/bmp > ${m}

# deleteFile
rm -f -- ${m}
```

(On WSL only, `checkImage` and `saveImage` get an extra `|| powershell.exe …` tail; not relevant here.)

How they run (`L(cmd)` → `J_(cmd,{reject:false})` → execa with `shell:true`):

- Each is one **string** passed to a shell (`shell:true`; Node/Bun semantics → `/bin/sh -c`, [Node docs](https://nodejs.org/api/child_process.html#child_processspawncommand-args-options); the `$SHELL`/fish theory in [claude-code#64208](https://github.com/anthropics/claude-code/issues/64208) was retracted by its author after an strace — **[unverified]** that Bun's `shell:true` is byte-for-byte Node's, but the strace in that issue shows the plain `||` chain running).
- No timeout, `reject:false`, cwd = Claude's `process.cwd()`, env = Claude's `process.env` (so `PATH` is whatever the shell that launched `claude` had). Stdout is captured (`maxBuffer` 100 MB); only `exitCode` is inspected.
- Sequence in `AV()`:
  1. `checkImage` → if `exitCode !== 0` return `null` (no telemetry, silent).
  2. `mkdir -p` the temp dir with mode `0700` (EEXIST tolerated).
  3. `saveImage` → if `exitCode !== 0` return `null` ("save_failed").
  4. `readFileBytes(screenshotPath)`; if the first two bytes are `BM` the BMP is converted to PNG; then the image is resized/compressed (throws on undecodable bytes → "read_failed" → `null`).
  5. `deleteFile` is fired **without awaiting**; the result is `{ base64, mediaType (sniffed from bytes), dimensions }`.

Exit-code semantics the shim must satisfy:

- `checkImage`'s exit status is `grep`'s (last command of the pipeline; `sh` has no pipefail). The shim's own exit code for `-t TARGETS -o` is irrelevant; **its stdout must contain a line matching `image/(png|jpeg|jpg|gif|webp|bmp)` iff an image is on the clipboard**, and nothing matching otherwise. Advertise `image/png` — it is the only type the save step actually asks for besides `image/bmp`.
- `saveImage` is an `||` chain: the first command exiting **0** wins, regardless of what it wrote. `xclip -t image/png -o` must therefore **exit 0 only after writing a complete PNG to stdout**, and exit non-zero (any code) when there is no PNG. If it exits 0 with empty/garbage output, the chain stops, and the later decode fails ("read_failed") — a silent failure. This exact failure mode is reported for WSLg's `wl-paste` in [claude-code#89223](https://github.com/anthropics/claude-code/issues/89223) and [#64208](https://github.com/anthropics/claude-code/issues/64208).
- `2>/dev/null` everywhere: stderr is free for diagnostics.
- `wl-paste` absent → `sh` exits 127 for that branch → chain continues. A missing `wl-paste` is fine; a **present-but-broken** `wl-paste` is harmful ([claude-code#85284](https://github.com/anthropics/claude-code/issues/85284), fixed by the reporter with a PATH shim — precedent for this design).

### 1b. Clipboard text read — Ctrl+V fallback, mouse paste

`o1e(selection="clipboard")`, Linux branch:

```js
if (isSSH()) return "";                       // SSH_CONNECTION set, or attacher reports ssh
for (const [cmd, args] of [
  ["wl-paste", primary ? ["--primary","--no-newline"] : ["--no-newline"]],
  ["xclip",    ["-selection", primary ? "primary" : "clipboard", "-o"]],
  ["xsel",     [primary ? "--primary" : "--clipboard", "--output"]],
]) { const r = await execFileNoThrow(cmd, args, {useCwd:false, timeout:2000}); if (r.code === 0) return r.stdout; }
return (await nativeAddon()?.getLinuxClipboardText?.(primary, 2000)) ?? "";   // addon only if DISPLAY =~ /^(unix)?:/ or WAYLAND_DISPLAY
```

- argv exec (no shell), **2000 ms timeout**, `maxBuffer` 1 MB, final newline stripped (execa `stripFinalNewline`), no cwd.
- **First tool with exit code 0 wins, even if stdout is empty** — an empty result ends the fallback with "No image found in clipboard". A missing tool (ENOENT) counts as non-zero and falls through.
- No `DISPLAY` check before running the tools; only the native addon (`clipboard-napi.node`, bundled for `arm64-linux` and `arm64-linux-musl`) is gated on `DISPLAY`/`WAYLAND_DISPLAY`.
- `isSSH()` = `attacherCaps()?.ssh ?? !!process.env.SSH_CONNECTION`. A Dev Container terminal does not set `SSH_CONNECTION`, so the read runs. (Over real SSH the read returns `""` before touching any tool — that is why plain-text Ctrl+V shows "No image found in clipboard" over SSH, [claude-code#93188](https://github.com/anthropics/claude-code/issues/93188).)

Callers: the `chat:imagePaste` handler (§2) after the image read returned `null`; right-click in the TUI when mouse tracking is on (Linux/Windows/WSL) reads `clipboard`; middle-click on Linux reads `primary`.

### 1c. Path resolution for a pasted bare filename — `getPath`

```sh
xclip -selection clipboard -t text/plain -o 2>/dev/null || wl-paste 2>/dev/null
```

Run as a shell string (same `L()` path as 1a, no timeout). Used only by `csr()` when a pasted image-looking fragment is **not** an absolute path (§3): stdout is trimmed and, if its `basename` equals the pasted fragment, that path is read. Note the `-t text/plain` here versus plain `-o` in 1b — the shim must accept both.

### 1d. Clipboard write — `/copy` and every other "copy" affordance

`v_(text)` (setClipboard):

1. If not SSH: `N(text)` — the native write, fire-and-forget (result never checked):
   - Linux tool selection (`probe()`, cached per process): `WAYLAND_DISPLAY` set and `wl-copy` on `PATH` → `wl-copy`; else **`DISPLAY` set (any non-empty value) and `xclip` on `PATH` → `xclip`**; else `xsel`; else the native addon if `DISPLAY =~ /^(unix)?:/` or `WAYLAND_DISPLAY`; else none. `PATH` lookup is `Bun.which`.
   - With `xclip`: `xclip -selection clipboard` **and** `xclip -selection primary`, text on **stdin**, argv exec, 2000 ms timeout, stdout/stderr captured but ignored. Both are spawned concurrently.
2. `tmux load-buffer -w -` if inside tmux.
3. Returns the OSC 52 sequence (`ESC ] 52 ; c ; <base64> BEL`, DCS-wrapped inside tmux/screen); every caller does `process.stdout.write(seq)`.

`/copy` specifically (`v(text, filename)`): calls `v_`, writes the sequence to stdout, **also writes the text to `<tmpdir>/<filename>`** and reports `Copied to clipboard (N characters, M lines)` + `Also written to <path>`. It never inspects whether any write succeeded. The docs describe the picker and the `w` shortcut only ([commands reference](https://code.claude.com/docs/en/commands)). The `/terminal-setup` note that iTerm2's "Applications in terminal may access clipboard" is enabled "so the `/copy` command can write to your system clipboard" ([terminal-config](https://code.claude.com/docs/en/terminal-config#enable-option-key-shortcuts-on-macos)) confirms OSC 52 is the intended cross-terminal route; a VS Code 1.123/1.124 OSC 52 mojibake warning in the binary confirms VS Code's terminal is a targeted OSC 52 consumer.

### 1e. `/stats` "copy as image"

`xclip -selection clipboard -t image/png -i <file>` — argv exec, `detached:true`, `stdio:"ignore"`, killed after 5 s; success iff exit code 0, else "Failed to copy to clipboard. Please install xclip". Not part of the parity goal but it is an `xclip` shape the shim will receive if someone presses the key.

### 1f. Not used on Linux

`pbcopy`/`pbpaste`/`osascript` (macOS), `powershell` (Windows/WSL), `Bun.Image.fromClipboard()` (absent from the Linux build).

## 2. When each path fires

- **Key**: the `chat:imagePaste` action is bound to **`ctrl+v`** on Linux and macOS, `alt+v` on Windows, and both `alt+v` and `ctrl+v` on WSL (default keybinding table, context `Chat`; remappable via `keybindings.json`). Docs: "`Ctrl+V` or `Cmd+V` (iTerm2) or `Alt+V` (Windows and WSL) — Paste image from clipboard … Inserts an `[Image #N]` chip" ([interactive mode](https://code.claude.com/docs/en/interactive-mode)). [claude-code#92312](https://github.com/anthropics/claude-code/issues/92312) confirms Alt+V does nothing on Linux.
- **Handler** (`chat:imagePaste`), in order:
  1. `AV()` — §1a. Success → image attached, done.
  2. Otherwise `o1e("clipboard")` — §1b text read. If non-empty and not "binary garbage" (contains NUL, or >5 % U+FFFD in the first 4096 chars when ≥32 chars), the text is dispatched as a **synthetic paste event** — the same event the bracketed-paste parser produces — so it goes through §3 path detection and may still become an attached image.
  3. Otherwise the toast "No image found in clipboard. Use ctrl+v to paste images." (or "You're SSH'd; try scp?").
- **Bracketed paste** (Cmd+V in VS Code's terminal, drag-and-drop) enters `A(text, rawEmpty, …)`:
  - `rawEmpty && (macOS || WSL)` → triggers the clipboard image read. **Not on Linux**: an empty paste does nothing there.
  - A pasted macOS `…/TemporaryItems/…screencaptureui…/Screenshot…` path with no readable file triggers the image read on macOS only.
  - Everything else → §3.
- A single key event longer than 800 chars (non-bracketed terminals) is treated as a paste.
- `onImagePaste` must be wired (it is whenever the prompt supports images); no platform gating on it.
- **Env gating summary**: `DISPLAY`/`WAYLAND_DISPLAY` gate only the write-tool probe and the native addon; `SSH_CONNECTION` gates the text read and the native write; nothing gates the image commands.

## 3. Pasted-path detection

From `A()` and `lsr()`/`Fe()`/`csr()` in the Linux build:

1. The pasted text (focus-tail `[I`/`[O` stripped) is split with `/ (?=\/|[A-Za-z]:\\)/` — i.e. **at a space immediately followed by `/`** — and then on newlines; blank fragments are dropped. So `"/a/1.png /b/2.png"` and one-path-per-line both yield multiple candidates.
2. Each fragment: `trim()`; if wrapped in matching `"…"` or `'…'`, the quotes are stripped; then backslash-unescaped (`\\` → `\`, `\x` → `x` — Finder/Terminal-style `Screen\ Shot.png` becomes `Screen Shot.png`); then tested with **`/\.(png|jpe?g|gif|webp)$/i`**. Matching fragments become image candidates; the rest are re-pasted as text (joined by `\n`). SVG, BMP, PDF etc. never match.
3. For each candidate (`csr`):
   - `path.isAbsolute(p)` → `readFileBytes(p)` directly. **No** cwd/workspace containment check was found on this path.
   - Not absolute → run §1c `getPath`; if its trimmed stdout `g` satisfies `basename(g) === p`, read `g`. Otherwise no bytes → `null`.
   - Any read error (ENOENT, EACCES…) is logged and yields `null`; an empty file yields `null`.
   - Bytes starting `BM` are converted to PNG; then the **magic bytes must be PNG/JPEG/GIF/WebP** or the candidate is rejected ("Pasted path has image extension but content is not a supported image").
   - Result: `{ path, base64, mediaType, dimensions }`; the prompt gets an `[Image #N]` chip with `filename = basename(path)` and `sourcePath = path` recorded.
4. If **every** candidate came back `null`, the original fragments are pasted back as plain text (so a bad path degrades to text, never to an error).

Consequences for the shim design: the file must exist **inside the container filesystem** at paste time and be readable by the `claude` process; the terminal must paste either the container-absolute path or a bare filename that matches `basename` of what `xclip -t text/plain -o` returns; quoting and `\ ` escapes are tolerated; multiple files work; relative paths like `./x.png` do not (they are neither absolute nor equal to a basename).

**[unverified]** What VS Code's integrated terminal actually pastes on Cmd+V after Cmd+C in the Explorer (host vs. container path, one per line?) and after Cmd+C in Finder (bare filename vs. full path) — host-side behaviour, belongs to the channel/spike tickets. Claude Code's macOS `basename` branch (§5) exists precisely because some terminals paste only the filename for a Finder-copied file.

## 4. Temp path

- `screenshotPath = join(tmpRoot(), "claude_cli_latest_screenshot.png")` where `tmpRoot()` = `join(CLAUDE_CODE_TMPDIR || os.tmpdir(), "claude-<uid>")` (`Al()`/`xb()`). `os.tmpdir()` honours `TMPDIR`/`TMP`/`TEMP`, default `/tmp`. So by default: **`/tmp/claude-1000/claude_cli_latest_screenshot.png`** for the `vscode` user.
- The `claude-<uid>` directory is created `0700` and validated (`gZ`): opened with `O_NOFOLLOW|O_DIRECTORY`, refused if it is a symlink or owned by another uid ("Set CLAUDE_CODE_TMPDIR to a directory you control…"). Diskless sessions throw ("The temp directory is unavailable in a diskless session"), which `AV()` reports as "construct_failed".
- The path is single-quote shell-escaped (`$o`) into the command strings; the **shell** does the `> path` redirection and Claude reads the file with `fs`. The shim never sees the path and never needs write access to it — it only writes PNG bytes to stdout. The path is necessarily inside the container (same process, same mount namespace).
- `rm -f -- path` runs after a successful read (not awaited). On `saveImage` failure the shell has already created/truncated the file and nobody deletes it; harmless.
- Override: `CLAUDE_CODE_TMPDIR`. The binary's own error strings say "the screenshot temp path (override with CLAUDE_CODE_TMPDIR)"; the variable is **not** listed on the [env vars](https://code.claude.com/docs/en/env-vars) docs page as of 2026-09-10.
- `/copy`'s "Also written to" file lands in the same `claude-<uid>` directory.

## 5. macOS reference behaviour (for parity)

From the macOS build's command table (identical strings appear in the Linux build's dead `darwin` branch):

```sh
# checkImage — exit 0 iff the pasteboard has a PNG representation
osascript -e 'the clipboard as «class PNGf»'
# saveImage — write that PNG to the same temp path
osascript -e 'set png_data to (the clipboard as «class PNGf»)' -e 'set fp to open for access POSIX file "<path>" with write permission' -e 'write png_data to fp' -e 'close access fp'
# getPath — POSIX path of a copied file (Finder / Explorer copy)
osascript -e 'get POSIX path of (the clipboard as «class furl»)'
# text read / write
pbpaste            # exit 0 → stdout
pbcopy             # text on stdin
```

The macOS build additionally tries `Bun.Image.fromClipboard()` first (native NSPasteboard read of PNG/TIFF/HEIC/JPEG/WebP/GIF/BMP) and only falls back to the osascript commands if that throws; `hasClipboardImage()` drives the "image in clipboard, press Ctrl+V" hint.

The `«class furl»` flow end to end: the user copies a file in Finder and presses Cmd+V in the terminal. The terminal pastes text; Claude Code's `A()` sees a fragment ending in an image extension. If the terminal pasted the full POSIX path, the absolute branch reads it. If it pasted only the file name, `csr()` runs `getPath` (`furl` → POSIX path) and, because `basename(path) === pasted`, reads that file. Either way the image is attached with `sourcePath` and shown as `[Image #N]`; the file's *bytes* never travel through the clipboard-image path. (`pbpaste` returning the bare file name for a Finder copy is **[unverified]** here; the existence of the basename branch is the binary-side evidence that some terminal/pasteboard combination does this.)

Linux twin: `getPath` is §1c. So for parity the shim's `xclip -selection clipboard -t text/plain -o` must return the **container-side absolute path** of the copied file; then both a bare-filename paste (basename branch) and a full-path paste (absolute branch) attach it. Making plain `xclip -selection clipboard -o` (§1b) return the same path also makes **Ctrl+V** on a copied file attach it (macOS: `pbpaste` → text fallback → same detection).

## 6. Shim contract

Every invocation shape the container's `xclip` must handle, with what Claude Code requires of it. `wl-paste`, `wl-copy` and `xsel` should **not** exist on `PATH` (a missing binary is harmless; a present one changes tool selection — `wl-paste` is tried *before* `xclip` for text reads, `wl-copy` before `xclip` for writes when `WAYLAND_DISPLAY` is set).

| # | argv (exact) | stdin | Must do | Exit code | Timing / notes |
|---|---|---|---|---|---|
| 1 | `xclip -selection clipboard -t TARGETS -o` | – | Print `image/png\n` (optionally more targets, one per line, e.g. `text/plain`, `UTF8_STRING`) **iff** the host clipboard holds an image; print nothing image-like otherwise. | Irrelevant (piped into `grep`); exit 0 for good measure | Shell string, no timeout; stderr discarded. Any line matching `image/(png\|jpeg\|jpg\|gif\|webp\|bmp)` triggers the save step, so only advertise `image/png` if you can deliver PNG. |
| 2 | `xclip -selection clipboard -t image/png -o` | – | Write the **complete PNG bytes** to stdout. | **0 only if a PNG was written**; non-zero (e.g. 1) when the clipboard has no image | Shell string, no timeout; stdout is redirected to `/tmp/claude-<uid>/claude_cli_latest_screenshot.png` by the shell. Exiting 0 with empty output is a silent failure. Convert host TIFF/JPEG to PNG host-side. |
| 3 | `xclip -selection clipboard -t image/bmp -o` | – | Same as 2 for BMP, or simply exit non-zero (Claude only reaches this if 2 failed). | 0 iff BMP written | Optional. |
| 4 | `xclip -selection clipboard -t text/plain -o` | – | Print the clipboard text. For a copied file: the **container-absolute path** of the file (one path; multiple copied files → **[unverified]** which one Claude would match; return the first or newline-separated list — only `basename(trimmed stdout)` is compared, so a list will not match). For plain text: the text. | 0 with output; non-zero if nothing | Shell string (`\|\| wl-paste`), no timeout, used only for the bare-filename branch (§3). Trailing newline is trimmed. |
| 5 | `xclip -selection clipboard -o` | – | Print the clipboard text (same content rule as 4; for an image-only clipboard print nothing and exit non-zero so the fallback reports "No image found" instead of pasting an empty string — either works, but exit 0 with empty stdout ends the search). | 0 with output | argv exec, **2000 ms timeout**, 1 MB max, final newline stripped. Runs on every Ctrl+V whose image check failed, and on right-click paste. |
| 6 | `xclip -selection primary -o` | – | Print the PRIMARY selection or nothing. | 0 or non-zero | argv exec, 2000 ms. Middle-click paste when mouse tracking is on. Returning the clipboard text or nothing are both acceptable. |
| 7 | `xclip -selection clipboard` | text (UTF-8) | Set the host clipboard to stdin. Print nothing. | Ignored | argv exec, 2000 ms timeout, then killed. Only reached when `DISPLAY` is set and `xclip` is on `PATH` (§1d). Spawned concurrently with 8. |
| 8 | `xclip -selection primary` | text | Set PRIMARY (no-op acceptable). | Ignored | As 7. |
| 9 | `xclip -selection clipboard -t image/png -i <file>` | – | Put the PNG file on the host clipboard as an image. | **0 on success** | argv exec, detached, stdio ignored, killed after 5 s. `/stats` copy-as-image only; optional. |

General requirements:

- Executable named exactly `xclip`, on the `PATH` of the shell that starts `claude` (VS Code's integrated terminal, `devcontainer exec`), resolvable by `Bun.which`.
- Argument parsing: at minimum `-selection {clipboard|primary}`, `-t <target>`, `-o`, `-i <file>`; real `xclip` also accepts `-sel`, `-selection` abbreviations and `-target`, but Claude Code never uses them.
- Never write diagnostics to stdout; stderr is safe everywhere (shell strings use `2>/dev/null`; argv execs capture but ignore it).
- Shape 2 has no timeout on Claude's side but blocks the prompt (`isPasting` spinner) until it returns — keep host round-trips fast; shapes 5–8 are killed at 2 s.
- Environment: for `/copy` to reach the shim, `DISPLAY` must be non-empty in Claude's environment. A value not starting with `:`/`unix:` (e.g. `DISPLAY=adc-clipboard`) satisfies the probe without also enabling the native X11 addon or convincing other tools that a real X server exists — **[unverified]** side effects on other programs; the mechanism ticket should weigh this against relying on OSC 52 alone.
- `/copy` fallback: independent of the shim, `/copy` writes OSC 52 to the terminal. Whether VS Code's terminal honours it from inside a Dev Container is **[unverified]**: xterm.js/VS Code added OSC 52 in 2024 ([vscode#193508](https://github.com/microsoft/vscode/issues/193508)), Remote-SSH reportedly drops it ([vscode-remote-release#11475](https://github.com/microsoft/vscode-remote-release/issues/11475), open), and a Dev Container user reports an OSC 52 `xclip` wrapper working ([opencode#8237](https://github.com/anomalyco/opencode/issues/8237)). Test first; if it works, shapes 7–8 are redundant.
- A copied-file transfer (Finder → container) happens outside the shim's visible contract: shape 4/5 must return a path that already exists in the container, so the host side has to materialise the file *before* answering the text read (the read is synchronous from Claude's point of view, ≤ 2 s for shape 5).

Minimal decision table for the host service behind the shim:

| Host clipboard content | 1 (`TARGETS`) | 2 (`image/png -o`) | 4/5 (text) |
|---|---|---|---|
| Image (screenshot) | `image/png` | PNG bytes, exit 0 | nothing, exit 1 (or empty) |
| Copied file(s) (Finder / VS Code Explorer) | nothing (unless you want a copied *image file* to paste as an attachment via the image path — but path paste already does that with `sourcePath`, prefer that) | exit 1 | container path of the transferred/mapped file, exit 0 |
| Plain text | nothing | exit 1 | the text, exit 0 |
| Empty | nothing | exit 1 | nothing, exit 1 |

## 7. Corroboration from anthropics/claude-code issues

- [#85284](https://github.com/anthropics/claude-code/issues/85284) — X11 user fixed image paste with a `wl-paste` PATH shim; confirms plain `Ctrl+V` attaches images on Linux once the underlying read succeeds, and that a broken `wl-paste` earlier in the chain breaks it.
- [#64208](https://github.com/anthropics/claude-code/issues/64208) — strace of the `saveImage` `||` chain; the first exit-0 command wins even when its output is unusable.
- [#89223](https://github.com/anthropics/claude-code/issues/89223) — `wl-paste` returning BMP bytes into the `.png` path; consistent with the `BM` sniff + conversion in `AV()`.
- [#92312](https://github.com/anthropics/claude-code/issues/92312) — Alt+V unbound on Linux; consistent with the keybinding table.
- [#93188](https://github.com/anthropics/claude-code/issues/93188) — over SSH, plain-text Ctrl+V shows "No image found"; consistent with the `isSSH()` short-circuit in the text read.
- [#79482](https://github.com/anthropics/claude-code/issues/79482) — `/copy` non-ASCII mojibake; the `VTt` VS Code 1.123/1.124 warning in the binary is the fix's user-facing half.

## 8. Open / unverified

- Whether OSC 52 from a Dev Container terminal reaches the macOS clipboard in current VS Code (decides if `/copy` needs the shim at all).
- What text VS Code's terminal pastes for an Explorer-copied file inside a Dev Container (container path? host path?) and for a Finder-copied file (name vs. full path) — determines whether the basename branch or the absolute branch fires.
- Whether Bun's `child_process` `shell:true` is exactly `/bin/sh -c` (Node semantics assumed; only the `||`/`|` behaviour matters and is corroborated by strace in #64208).
- The macOS build's DCE inference (`x.darwin||x.linux`) — strong evidence, not a build log.
