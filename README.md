# agent-devcontainer

Prebuilt, agent-ready devcontainer images and a per-project template so any dbarjs repo opens in VS Code with a Mac-matching zsh terminal, authenticated Claude Code + gh, and YOLO agents that can spawn containers.

Images live on GHCR: `ghcr.io/dbarjs/agent-devcontainer/base` (stack-agnostic) and `ghcr.io/dbarjs/agent-devcontainer/node` (adds NVM, Node LTS, `ni`). Everything a project needs beyond the image reference — auth volumes, `remoteUser`, the VS Code extension baseline, docker-in-docker — is embedded in the image metadata, so the template stays tiny.

## Apply the template to a project

### With `adc init`

`adc` is this repo's CLI. On the host, install it as a Sheldon plugin — add to `~/.config/sheldon/plugins.toml`:

```toml
[plugins.adc]
github = "dbarjs/agent-devcontainer"
```

Then, from the project you want to containerize:

```sh
adc init            # or: adc init path/to/repo
```

This writes `.devcontainer/devcontainer.json` from the vendored template, setting `name` to the repo directory name. It picks the template variant automatically — `package.json` present → `node`, otherwise `base` — and prints the reason; `--variant base|node` overrides. It refuses to overwrite an existing file unless you pass `--force`.

Then open the project in VS Code and **Reopen in Container**.

### Copy-paste fallback

Copy [`templates/node/devcontainer.json`](templates/node/devcontainer.json) (or [`templates/base/devcontainer.json`](templates/base/devcontainer.json) for non-Node projects) into the project as `.devcontainer/devcontainer.json` and replace `<project-name>` with the project's name.

## Inside the container

`adc` is baked into the images at `/usr/local/bin`, with noun-grouped container-only commands plus a diagnostic:

- `adc identity sync` — clone-or-pull the private identity repo (`git@github.com:dbarjs/identity.git`, override with `ADC_IDENTITY_REPO`) onto the shared `identity` volume, then apply. Runs over the forwarded 1Password SSH agent, so it needs `SSH_AUTH_SOCK` exported on the host. One sync serves every container: the volume is shared, and the vendored zshrc auto-applies it in fresh containers.
- `adc identity apply` — offline copy from the volume into place: `ssh/` → `~/.ssh` (700/600), `git/` → `~/.config/git/`. Normally you never run it by hand — the zshrc self-heal does.
- `adc claude upgrade` — bootstrap Claude Code onto the shared install volume if it's empty, otherwise `claude update`. Either way, every container sharing the volume gets it.
- `adc doctor` — pass/fail checks with fixes. In a container: agent forwarded, identity applied, Claude Code installed, `gh` authenticated, docker reachable. On the host (via the Sheldon plugin): `SSH_AUTH_SOCK` → 1Password socket, agent alive, Docker running.

Bare `adc identity` or `adc claude` prints that group's help. The v1 flat verbs (`sync`, `apply`, `upgrade`) hard-error with a pointer to their new names. The container-only commands refuse to run on the host — there they would overwrite the real `~/.ssh` and `~/.config/git`.

## Repo layout

- `templates/` — the vendored per-project devcontainer templates (`base/`, `node/`).
- `images/` — prebuild definitions for the `base` and `node` images.
- `dotfiles/` — container-adapted rc files (zshrc, Sheldon plugins, Starship) baked into the images.
- `cli/` — the `adc` CLI (`init`, `identity sync|apply`, `claude upgrade`, `doctor`).
- `CONTEXT.md` — domain glossary; `docs/adr/` — decisions.
