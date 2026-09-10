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

TESTS_LIB="$(cd "$(dirname "$0")" && pwd)/../lib"
# shellcheck source=tests/lib/test-utils.sh
. "$TESTS_LIB/test-utils.sh"

run() {
    docker run --rm -e TERM=xterm-256color "$IMAGE_REF" "$@"
}

# containerEnv from the image metadata is applied by `devcontainer up`, not by
# plain `docker run`, so replay it as -e flags: the launcher-kill checks then
# prove both the mechanism and that the image actually ships it. $1 = a key
# to leave out (negative control), optional.
metadata_env_args() {
    local exclude="${1:-}"
    docker inspect --format '{{ index .Config.Labels "devcontainer.metadata" }}' "$IMAGE_REF" \
        | jq -r --arg exclude "$exclude" \
            '[.[] | .containerEnv // {}] | add // {} | to_entries[]
             | select(.key != $exclude) | "-e", "\(.key)=\(.value)"'
}

# tests/lib/launcher-kill.sh inside the container, with the image's own
# containerEnv (minus $1) and node on PATH via the login zshrc
run_launcher_kill() {
    local exclude="$1" arg
    local -a env_args=()
    shift
    while IFS= read -r arg; do env_args+=("$arg"); done < <(metadata_env_args "$exclude")
    docker run --rm -e TERM=xterm-256color "${env_args[@]}" \
        -v "$TESTS_LIB:/tests-lib:ro" "$IMAGE_REF" \
        zsh -ilc 'bash /tests-lib/launcher-kill.sh "$@"' _ "$@"
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
    run grep -q '^- Host clipboard:' /etc/claude-code/CLAUDE.md || return 1
    if [ "$VARIANT" = "node" ]; then
        run grep -q '^## Node toolchain' /etc/claude-code/CLAUDE.md || return 1
    fi
}

# ADR-0012: the xclip shim is the only clipboard tool on PATH — wl-paste and
# xsel would be picked ahead of it by Claude Code's paste path
check_xclip_shim_baked() {
    local which_xclip
    which_xclip="$(run zsh -ilc 'command -v xclip')" || return 1
    if [ "$which_xclip" != "/usr/local/bin/xclip" ]; then
        echoStderr "xclip resolves to '$which_xclip', expected /usr/local/bin/xclip"
        return 1
    fi
    run test -x /usr/local/bin/xclip || return 1
    run head -c 200 /usr/local/bin/xclip | grep -q '^#!/bin/sh' || return 1
    local stray
    if stray="$(run zsh -ilc 'command -v wl-paste wl-copy xsel')"; then
        echoStderr "clipboard tools on PATH that would shadow the shim: $stray"
        return 1
    fi
}

# ADR-0012: with no daemon reachable (plain docker run, no OrbStack host
# service) every read shape must fail within the 1.5 s cap, print nothing on
# stdout, and never leave Claude's paste spinner hanging. Both TARGETS
# (shape 1, exit code irrelevant to Claude but stdout must be empty) and the
# PNG save (shape 2, exit must be non-zero) are timed under dash, the
# image's /bin/sh.
check_xclip_shim_fails_fast() {
    local out started ended
    started=$(date +%s)
    out="$(run timeout 10 xclip -selection clipboard -t TARGETS -o 2>/dev/null || true)"
    ended=$(date +%s)
    if [ -n "$out" ]; then
        echoStderr "TARGETS printed '$out' with no daemon"
        return 1
    fi
    if [ $((ended - started)) -gt 4 ]; then
        echoStderr "TARGETS took $((ended - started)) s with no daemon"
        return 1
    fi
    started=$(date +%s)
    if out="$(run timeout 10 xclip -selection clipboard -t image/png -o 2>/dev/null)"; then
        echoStderr "image/png exited 0 with no daemon"
        return 1
    fi
    ended=$(date +%s)
    if [ -n "$out" ] || [ $((ended - started)) -gt 4 ]; then
        echoStderr "image/png printed '$out' / took $((ended - started)) s with no daemon"
        return 1
    fi
    # writes are refused outright, no daemon involved
    if run sh -c 'printf x | xclip -selection clipboard' 2>/dev/null; then
        echoStderr "stdin write to xclip exited 0"
        return 1
    fi
}

check_adc_baked() {
    run adc --help > /dev/null || return 1
    run test -f /usr/local/share/adc/templates/base/devcontainer.json || return 1
    run test -f /usr/local/share/adc/templates/node/devcontainer.json || return 1
}

# ADR-0011: the node template declares no static forward — a forwardPorts
# entry would hold a hanging host listener with nothing behind it
check_node_template_no_forward_ports() {
    if run grep -q '"forwardPorts"' /usr/local/share/adc/templates/node/devcontainer.json; then
        echoStderr "baked node template still declares forwardPorts"
        return 1
    fi
}

# ADR-0011: a SIGTERM to the launcher must reach the dev server. Each pnpm
# major reads script-shell from a different place (rc ini <=10, config.yaml
# 11, npm_config_* env for npm), so each is pinned and proved on its own.
# pnpm >=12 is a known orphan (native binary forwards nothing) and is not
# asserted here.
check_launcher_kill_pnpm10() {
    run_launcher_kill "" --pm pnpm@10.15.0 node pnpm run dev
}
check_launcher_kill_pnpm11() {
    run_launcher_kill "" --pm pnpm@11.21.0 node pnpm run dev
}
check_launcher_kill_npm() {
    run_launcher_kill "" node npm run dev
}
# negative control: without the env npm's script runs behind `sh -c`, whose
# dash swallows SIGTERM — proves the probe can see an orphan at all
check_launcher_kill_npm_control() {
    run_launcher_kill npm_config_script_shell --expect orphan node npm run dev
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
        needles="$needles npm_config_script_shell remote.autoForwardPortsSource"
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
check "xclip shim on PATH, no wl-paste/wl-copy/xsel" check_xclip_shim_baked
check "xclip shim fails fast without a clipboard daemon" check_xclip_shim_fails_fast
check "adc CLI baked in with both templates" check_adc_baked
if [ "$VARIANT" = "node" ]; then
    check "node template declares no forwardPorts" check_node_template_no_forward_ports
    check "SIGTERM to 'pnpm run dev' (pnpm 10) takes the server down" check_launcher_kill_pnpm10
    check "SIGTERM to 'pnpm run dev' (pnpm 11) takes the server down" check_launcher_kill_pnpm11
    check "SIGTERM to 'npm run dev' takes the server down" check_launcher_kill_npm
    check "control: 'npm run dev' without script-shell leaves an orphan" check_launcher_kill_npm_control
fi
check "v1 flat verbs hard-error with a pointer to the v2 name" check_flat_verb_pointer
check "devcontainer.metadata label valid with expected needles" check_metadata_label

reportResults
