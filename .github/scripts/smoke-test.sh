#!/bin/bash
# Slim post-publish smoke test (adapted from devcontainer-images' smoke-test
# action). Pulls the just-published image and checks, on the runner's native
# arch, that the agent toolchain is present, an interactive zsh starts
# warning-free, and the devcontainer metadata labels made it into the image.
# Usage: smoke-test.sh <image-ref> <base|node>
set -euo pipefail

IMAGE_REF="$1"
VARIANT="$2"

run() {
    docker run --rm -e TERM=xterm-256color "$IMAGE_REF" "$@"
}

echo "(*) Pulling $IMAGE_REF"
docker pull "$IMAGE_REF"

echo "(*) Toolchain versions"
run zsh -ilc 'whoami && sheldon --version && starship --version \
    && gh --version && git --version && git-lfs --version \
    && python3 --version && fzf --version && zoxide --version \
    && docker --version'

if [ "$VARIANT" = "node" ]; then
    echo "(*) Node toolchain"
    run zsh -ilc 'node --version && npm --version \
        && command -v ni && command -v pnpm && command -v yarn'

    echo "(*) pnpm install lands in the shared store, not the project"
    run zsh -ilc 'set -e; cd "$(mktemp -d)" \
        && printf "{\"name\":\"smoke\",\"version\":\"0.0.0\"}" > package.json \
        && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 pnpm add is-odd \
        && [ -n "$(ls /home/vscode/.local/share/pnpm-store)" ] \
        && [ ! -e .pnpm-store ]'
fi

echo "(*) Interactive zsh starts warning-free"
startup_output="$(run zsh -ilc 'true' 2>&1 || true)"
if [ -n "$startup_output" ]; then
    echo "unexpected output from interactive zsh startup:"
    echo "$startup_output"
    exit 1
fi

echo "(*) Claude bootstrap script present"
run test -x /usr/local/share/agent-devcontainer/claude-bootstrap.sh

echo "(*) adc CLI baked in with its template"
run adc --help
run test -f /usr/local/share/adc/templates/devcontainer.json

echo "(*) Devcontainer metadata label"
metadata="$(docker inspect --format '{{ index .Config.Labels "devcontainer.metadata" }}' "$IMAGE_REF")"
echo "$metadata" | jq -e . > /dev/null # valid JSON
needles="command-history identity claude-bootstrap docker-in-docker"
if [ "$VARIANT" = "node" ]; then
    needles="$needles pnpm-store"
fi
for needle in $needles; do
    if ! grep -q "$needle" <<< "$metadata"; then
        echo "devcontainer.metadata label is missing '$needle':"
        echo "$metadata"
        exit 1
    fi
done

echo "(*) Smoke test passed for $IMAGE_REF ($VARIANT)"
