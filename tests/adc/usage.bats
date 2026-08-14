#!/usr/bin/env bats
# Usage output and exit codes for the noun-grouped v2 command surface.

load test_helper

setup() {
	common_setup
}

@test "no arguments prints usage and exits 1" {
	run adc
	assert_failure 1
	assert_output --partial "Usage: adc <command>"
}

@test "--help exits 0 with usage" {
	run adc --help
	assert_success
	assert_output --partial "Usage: adc <command>"
}

@test "help subcommand exits 0 with usage" {
	run adc help
	assert_success
	assert_output --partial "Usage: adc <command>"
}

@test "unknown command errors with a pointer to --help" {
	run adc frobnicate
	assert_failure
	assert_output --partial "unknown command 'frobnicate'"
	assert_output --partial "adc --help"
}

@test "identity with no subcommand prints identity usage" {
	run adc identity
	assert_success
	assert_output --partial "Usage: adc identity <command>"
}

@test "identity --help prints identity usage" {
	run adc identity --help
	assert_success
	assert_output --partial "Usage: adc identity <command>"
}

@test "unknown identity subcommand errors" {
	run adc identity bogus
	assert_failure
	assert_output --partial "unknown command 'identity bogus'"
}

@test "claude with no subcommand prints claude usage" {
	run adc claude
	assert_success
	assert_output --partial "Usage: adc claude <command>"
}

@test "unknown claude subcommand errors" {
	run adc claude bogus
	assert_failure
	assert_output --partial "unknown command 'claude bogus'"
}
