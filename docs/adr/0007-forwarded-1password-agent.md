# Forwarded 1Password agent as the root of trust

No private keys ever enter the container. SSH auth, identity-repo sync, pushes, and commit signing all ride the host's 1Password SSH agent, reached through the Dev Containers extension's own agent forwarding (keyed off the host's `SSH_AUTH_SOCK`; the host exports the 1Password socket in `~/.zshrc` — `IdentityAgent` in ssh config is ignored by forwarding). Commit signing works over the forwarded agent via `ssh-keygen -Y sign` with a `key::` public key in the gitconfig.

## Consequences

The container gitconfig must **omit** `op-ssh-sign` — that binary only exists on the host, and referencing it breaks signing inside the container. Templates declare nothing agent-specific; forwarding is the extension's default behavior.

Decided in [issue #2](https://github.com/dbarjs/agent-devcontainer/issues/2) ([map v1](https://github.com/dbarjs/agent-devcontainer/issues/1)).
