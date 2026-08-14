#!/usr/bin/env bats
# v1 flat verbs hard-error with a pointer at their v2 home (spec: issue #27).

load test_helper

setup() {
	common_setup
}

@test "adc sync points at 'adc identity sync'" {
	run adc sync
	assert_failure
	assert_output --partial "'sync' moved"
	assert_output --partial "adc identity sync"
}

@test "adc apply points at 'adc identity apply'" {
	run adc apply
	assert_failure
	assert_output --partial "'apply' moved"
	assert_output --partial "adc identity apply"
}

@test "adc upgrade points at 'adc claude upgrade'" {
	run adc upgrade
	assert_failure
	assert_output --partial "'upgrade' moved"
	assert_output --partial "adc claude upgrade"
}
