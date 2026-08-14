# Shared setup for the adc black-box suite (tier 1): every test drives the
# CLI as `zsh cli/adc ...` and asserts on output + exit codes only.

# bats-support/bats-assert live wherever the harness put them: bats-action
# exports BATS_LIB_PATH in CI; the fallbacks cover common local installs.
export BATS_LIB_PATH="${BATS_LIB_PATH:-/usr/lib/bats:/usr/local/lib:/opt/homebrew/lib}"

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
ADC="$REPO_ROOT/cli/adc"

common_setup() {
	bats_load_library bats-support
	bats_load_library bats-assert
	# these would flip adc's in_container detection on a dev host
	unset REMOTE_CONTAINERS CODESPACES
}

adc() {
	zsh "$ADC" "$@"
}

in_container() {
	[[ -f /.dockerenv || -f /run/.containerenv ]]
}
