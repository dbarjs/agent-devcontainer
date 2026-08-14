# The container is the sandbox: YOLO agents, no network firewall

Claude Code runs with `--dangerously-skip-permissions` and there is no network allowlist or firewall inside the container — a deliberate rejection of the Anthropic reference devcontainer's firewall approach. The container boundary itself is the safety mechanism: agents get full autonomy inside it (including spawning further containers), and anything the host must protect stays outside it. Adding a network filter would buy defense-in-depth at the cost of constantly maintaining an allowlist that breaks legitimate agent work.

## Consequences

Everything else follows from taking this boundary seriously: no host docker socket ([ADR-0004](0004-docker-in-docker-not-host-socket.md)), no private keys in the container ([ADR-0007](0007-forwarded-1password-agent.md)).

Decided while charting [map v1](https://github.com/dbarjs/agent-devcontainer/issues/1); the firewall rejection is recorded in its Out-of-scope section.
