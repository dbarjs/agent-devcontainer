# Shared named volumes for auth and the Claude Code install

Host credentials can't be projected in — macOS Keychain auth is unreachable from a Linux container — so instead of logging in per project, auth state lives on shared named volumes mounted into every container at the same home subpaths: `~/.claude` (with `CLAUDE_CONFIG_DIR`) and `~/.config/gh`. Log in once inside any container; every container is logged in. The Claude Code install itself sits on its own shared volumes (`~/.local/share/claude` + `~/.local/bin`, `DISABLE_AUTOUPDATER=1`, first-run bootstrap when empty) so a single `claude update` upgrades all containers at once.

## Consequences

Concurrent containers share `~/.claude.json`, so a concurrent-write clobber is possible — known and accepted as recoverable (worst case: log in again).

Decided in [issue #4](https://github.com/dbarjs/agent-devcontainer/issues/4) ([map v1](https://github.com/dbarjs/agent-devcontainer/issues/1)); the volumes are declared in the base image metadata so consumers inherit them per [ADR-0001](0001-prebuilt-image-suite-plus-template.md).
