# shellcheck shell=bash
# Shared check/reportResults vocabulary for tiers 2 and 3, adapted from the
# devcontainers/images smoke-test idiom. Sourced, not executed.
#
# check runs a command (or function), records a failure instead of aborting,
# and always returns 0 — so callers are free to `set -euo pipefail` for their
# own bugs while a failing check still lets the remaining checks run.
# reportResults prints the verdict and exits nonzero if anything failed.

FAILED=()

echoStderr() {
    echo "$@" >&2
}

check() {
    local label="$1"
    shift
    echo "(*) $label"
    if "$@"; then
        echo "    ok"
    else
        echoStderr "    FAIL: $label"
        FAILED+=("$label")
    fi
    return 0
}

reportResults() {
    if [ ${#FAILED[@]} -ne 0 ]; then
        echoStderr ""
        echoStderr "(!) ${#FAILED[@]} check(s) failed:"
        local label
        for label in "${FAILED[@]}"; do
            echoStderr "    - $label"
        done
        exit 1
    fi
    echo ""
    echo "(*) All checks passed."
}
