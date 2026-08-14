#!/usr/bin/env bats
# Container-only commands refuse to run on a host, where they would clobber
# the real ~/.ssh and ~/.config/git.

load test_helper

setup() {
	common_setup
	if in_container; then
		skip "host-side refusals cannot be observed inside a container"
	fi
}

@test "identity sync refuses to run on the host" {
	run adc identity sync
	assert_failure
	assert_output --partial "runs inside a container only"
}

@test "identity apply refuses to run on the host" {
	run adc identity apply
	assert_failure
	assert_output --partial "runs inside a container only"
}

@test "claude upgrade refuses to run on the host" {
	run adc claude upgrade
	assert_failure
	assert_output --partial "runs inside a container only"
}
