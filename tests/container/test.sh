#!/bin/bash
# Tier 2 — container assertions against a built image (spec: issue #28).
# Successor to .github/scripts/smoke-test.sh, refactored onto the shared
# check/reportResults vocabulary. Runs in two modes with the same checks:
# post-publish against the freshly pushed GHCR date tag (--pull), and on
# image-touching PRs against a locally built image (no --pull).
# Usage: tests/container/test.sh [--pull] <image-ref> <base|node>
set -euo pipefail

pull=0
if [ "${1:-}" = "--pull" ]; then
    pull=1
    shift
fi
if [ $# -ne 2 ]; then
    echo "Usage: $0 [--pull] <image-ref> <base|node>" >&2
    exit 1
fi
IMAGE_REF="$1"
VARIANT="$2"

# shellcheck source=tests/lib/test-utils.sh
. "$(cd "$(dirname "$0")" && pwd)/../lib/test-utils.sh"

run() {
    docker run --rm -e TERM=xterm-256color "$IMAGE_REF" "$@"
}

check_base_toolchain() {
    run zsh -ilc 'whoami && sheldon --version && starship --version \
        && gh --version && git --version && git-lfs --version \
        && python3 --version && fzf --version && zoxide --version \
        && docker --version'
}

check_node_toolchain() {
    run zsh -ilc 'node --version && npm --version \
        && command -v ni && command -v pnpm && command -v yarn'
}

# pnpm's same-disk store rule: a real install must land in the shared store
# volume path and leave the project free of a local .pnpm-store (issue #22)
check_pnpm_shared_store() {
    run zsh -ilc 'set -e; cd "$(mktemp -d)" \
        && printf "{\"name\":\"smoke\",\"version\":\"0.0.0\"}" > package.json \
        && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 pnpm add is-odd \
        && [ -n "$(ls /home/vscode/.local/share/pnpm-store)" ] \
        && [ ! -e .pnpm-store ]'
}

check_zsh_startup_silent() {
    local startup_output
    startup_output="$(run zsh -ilc 'true' 2>&1 || true)"
    if [ -n "$startup_output" ]; then
        echoStderr "unexpected output from interactive zsh startup:"
        echoStderr "$startup_output"
        return 1
    fi
}

check_env_brief() {
    run test -s /etc/claude-code/CLAUDE.md || return 1
    if [ "$VARIANT" = "node" ]; then
        run grep -q '^## Node toolchain' /etc/claude-code/CLAUDE.md || return 1
    fi
}

check_adc_baked() {
    run adc --help > /dev/null || return 1
    run test -f /usr/local/share/adc/templates/base/devcontainer.json || return 1
    run test -f /usr/local/share/adc/templates/node/devcontainer.json || return 1
}

check_flat_verb_pointer() {
    local flat_verb_output
    flat_verb_output="$(run adc sync 2>&1 || true)"
    if ! grep -q "adc identity sync" <<< "$flat_verb_output"; then
        echoStderr "expected 'adc sync' to point at 'adc identity sync', got:"
        echoStderr "$flat_verb_output"
        return 1
    fi
}

check_metadata_label() {
    local metadata needles needle
    metadata="$(docker inspect --format '{{ index .Config.Labels "devcontainer.metadata" }}' "$IMAGE_REF")"
    echo "$metadata" | jq -e . > /dev/null || {
        echoStderr "devcontainer.metadata label is not valid JSON"
        return 1
    }
    needles="command-history identity claude-bootstrap docker-in-docker anthropic.claude-code"
    if [ "$VARIANT" = "node" ]; then
        needles="$needles pnpm-store dbaeumer.vscode-eslint NI_DEFAULT_AGENT"
    fi
    for needle in $needles; do
        if ! grep -q "$needle" <<< "$metadata"; then
            echoStderr "devcontainer.metadata label is missing '$needle':"
            echoStderr "$metadata"
            return 1
        fi
    done
}

if [ "$pull" -eq 1 ]; then
    echo "(*) Pulling $IMAGE_REF"
    docker pull "$IMAGE_REF"
fi

check "toolchain versions ($VARIANT)" check_base_toolchain
if [ "$VARIANT" = "node" ]; then
    check "node toolchain" check_node_toolchain
    check "pnpm install lands in the shared store, not the project" check_pnpm_shared_store
fi
check "interactive zsh starts with zero output" check_zsh_startup_silent
check "environment brief baked at /etc/claude-code/CLAUDE.md" check_env_brief
check "claude-bootstrap.sh present and executable" \
    run test -x /usr/local/share/agent-devcontainer/claude-bootstrap.sh
check "adc CLI baked in with both templates" check_adc_baked
check "v1 flat verbs hard-error with a pointer to the v2 name" check_flat_verb_pointer
check "devcontainer.metadata label valid with expected needles" check_metadata_label

reportResults
