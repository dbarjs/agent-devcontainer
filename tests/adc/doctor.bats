#!/usr/bin/env bats
# Host-side `adc doctor` shape: the check names and summary line, not their
# pass/fail state — CI runners legitimately fail the 1Password checks.

load test_helper

setup() {
	common_setup
	if in_container; then
		skip "host-mode doctor cannot be observed inside a container"
	fi
}

@test "doctor runs the host checks" {
	run adc doctor
	assert [ "$status" -le 1 ]
	assert_line --partial "adc doctor (host)"
	assert_line --partial "SSH_AUTH_SOCK points at the 1Password socket"
	assert_line --partial "SSH agent alive"
	assert_line --partial "Docker running"
}

@test "doctor ends on a summary line" {
	run adc doctor
	assert [ "$status" -le 1 ]
	if [ "$status" -eq 0 ]; then
		assert_line "all checks passed"
	else
		assert_line --partial "check(s) failed"
	fi
}
