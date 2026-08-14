# Claude Code system-level CLAUDE.md loading

Research for [issue #32](https://github.com/dbarjs/agent-devcontainer/issues/32): can the image bake always-loaded instructions into `/etc/claude-code/CLAUDE.md`, and how does that interact with `CLAUDE_CONFIG_DIR` and the `claude-config` volume mounted over `~/.claude`? All claims below are from the official Claude Code docs at code.claude.com (checked 2026-08-13) and the `anthropics/claude-code` changelog.

## Verdict

`/etc/claude-code/CLAUDE.md` **is** a supported, first-class memory location on Linux — the "managed policy" scope. It is loaded in every session, concatenated (not overriding) before user and project CLAUDE.md, is unaffected by `CLAUDE_CONFIG_DIR`, and cannot be excluded by user settings. It is the correct image-owned home for always-loaded instructions: it lives outside `~/.claude`, so the `claude-config` named volume never shadows it.

## 1. Is `/etc/claude-code/CLAUDE.md` loaded on Linux?

Yes. The [memory doc](https://code.claude.com/docs/en/memory#choose-where-to-put-claude-md-files) lists the **Managed policy** scope with per-OS paths:

- macOS: `/Library/Application Support/ClaudeCode/CLAUDE.md`
- **Linux and WSL: `/etc/claude-code/CLAUDE.md`**
- Windows: `C:\Program Files\ClaudeCode\CLAUDE.md`

Purpose: "Organization-wide instructions managed by IT/DevOps", scope "every Claude Code session on the machine, in every repository" ([Deploy organization-wide CLAUDE.md](https://code.claude.com/docs/en/memory#deploy-organization-wide-claude-md)). In a container image, "the machine" is the container — exactly the scope we want.

## 2. Precedence: merged, not overriding

CLAUDE.md files at different scopes are **all loaded and concatenated** — none overrides another. The memory doc is explicit: "All discovered files are concatenated into context rather than overriding each other" ([How CLAUDE.md files load](https://code.claude.com/docs/en/memory#how-claude-md-files-load)). Load order is broadest scope first, so more specific instructions appear later (last-read) in context:

1. Managed policy (`/etc/claude-code/CLAUDE.md`) — "Loads before user and project CLAUDE.md"
2. User (`~/.claude/CLAUDE.md`)
3. Project (`./CLAUDE.md` or `./.claude/CLAUDE.md`, walking up the directory tree)
4. Local (`./CLAUDE.local.md`)

Two managed-only guarantees ([memory doc](https://code.claude.com/docs/en/memory#exclude-specific-claude-md-files)): "This file cannot be excluded by individual settings" and "Managed policy CLAUDE.md files cannot be excluded" via `claudeMdExcludes` — that setting "only applies to user, project, and local memory" ([settings reference](https://code.claude.com/docs/en/settings#available-settings)).

Note this is memory precedence, not settings precedence — *settings* at higher scopes do override lower ones ([settings precedence](https://code.claude.com/docs/en/settings#settings-precedence)); *memory* files merge.

## 3. `CLAUDE_CONFIG_DIR` does not touch system paths

Per the [env-vars reference](https://code.claude.com/docs/en/env-vars): `CLAUDE_CONFIG_DIR` — "Override the configuration directory (default: `~/.claude`). All settings, session history, and plugins are stored under this path, as are credentials on Linux and Windows." The [.claude directory doc](https://code.claude.com/docs/en/claude-directory) confirms the blast radius: "If you set `CLAUDE_CONFIG_DIR`, every `~/.claude` path on this page lives under that directory instead."

It relocates only the **user** config dir. The managed paths are documented as fixed system directories (`/etc/claude-code/` on Linux) with no environment override ([settings files](https://code.claude.com/docs/en/settings#settings-files)). Our devcontainer's `CLAUDE_CONFIG_DIR=/home/vscode/.claude` (the default location anyway, made explicit for the volume mount per [ADR-0005](../adr/0005-shared-volumes-for-auth-and-claude-install.md)) has no effect on `/etc/claude-code/*`.

## 4. Interplay with `/etc/claude-code/managed-settings.json`

Same directory, complementary mechanisms ([settings files](https://code.claude.com/docs/en/settings#settings-files), [memory doc](https://code.claude.com/docs/en/memory#deploy-organization-wide-claude-md)):

- `managed-settings.json` is **enforced configuration** — highest settings precedence, "cannot be overridden by user or project settings". A drop-in directory `/etc/claude-code/managed-settings.d/*.json` merges on top of it, systemd-style (alphabetical, later scalars win, arrays concatenate).
- Managed `CLAUDE.md` is **behavioral guidance** — context the model reads, not client-enforced policy. The docs draw the line: "Use settings for technical enforcement and CLAUDE.md for behavioral guidance."
- Bridge: the **`claudeMd` settings key** embeds managed CLAUDE.md content directly inside `managed-settings.json` — "same as a managed CLAUDE.md file. Loads before user and project CLAUDE.md." It is honored **only** in managed/policy settings; in user, project, or local settings it is ignored ([settings reference](https://code.claude.com/docs/en/settings#available-settings)).

Caveat: anything placed in `managed-settings.json` becomes un-overridable policy inside the container — fine for an image we own, but restrictive settings there would bind every project using the image.

## 5. Image-baking recommendation

The premise of the fallback question is moot: `/etc/claude-code/CLAUDE.md` is supported, and it is the best option precisely because of our volume layout — `~/.claude` is the `claude-config` named volume ([ADR-0005](../adr/0005-shared-volumes-for-auth-and-claude-install.md)), so image content there is shadowed at first mount, while `/etc/claude-code/` is plain image filesystem that every container sees as built.

- **Preferred**: bake `/etc/claude-code/CLAUDE.md` into the base image. Always loaded, first in context, no bootstrap script, no volume interaction, survives `claude update` (install lives on its own volume).
- **Equivalent**: a `claudeMd` key in a baked `/etc/claude-code/managed-settings.json` — one file for both policy and memory, same precedence. Use this if we ever ship managed settings anyway.
- **Rejected alternatives**: bootstrap script writing into the volume (racy across concurrent containers, drifts after image updates); `--append-system-prompt` wrapper (must be passed on every invocation — the docs position it for scripts/automation, not interactive use, [memory troubleshooting](https://code.claude.com/docs/en/memory#claude-isn%E2%80%99t-following-my-claude-md)); output styles (deprecated in the [changelog](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md): "Deprecated output styles. Review options in `/output-style` and use --system-prompt-file, --system-prompt, --append-system-prompt, CLAUDE.md, or plugins instead").

Two operational notes: keep it short — CLAUDE.md content loads into every session's context, docs recommend under 200 lines total across files ([write effective instructions](https://code.claude.com/docs/en/memory#write-effective-instructions)); and verify with `/context`, which lists loaded files under **Memory files**.
