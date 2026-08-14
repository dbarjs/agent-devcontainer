#!/usr/bin/env bats
# adc init: template write, variant auto-detection, --variant, --force.

load test_helper

setup() {
	common_setup
	project="$BATS_TEST_TMPDIR/proj"
	mkdir -p "$project"
	dest="$project/.devcontainer/devcontainer.json"
}

@test "init writes the base template into an empty project" {
	run adc init "$project"
	assert_success
	assert_line --partial "variant: base"
	assert [ -f "$dest" ]
	run cat "$dest"
	assert_output --partial '"name": "proj"'
	assert_output --partial "agent-devcontainer/base:latest"
	refute_output --partial "<project-name>"
}

@test "init auto-detects node when package.json is present" {
	echo '{}' > "$project/package.json"
	run adc init "$project"
	assert_success
	assert_line --partial "variant: node"
	run cat "$dest"
	assert_output --partial "agent-devcontainer/node:latest"
}

@test "init defaults to the current directory" {
	cd "$project"
	run adc init
	assert_success
	assert [ -f "$dest" ]
}

@test "--variant overrides auto-detection" {
	echo '{}' > "$project/package.json"
	run adc init "$project" --variant base
	assert_success
	assert_line --partial "variant: base"
	run cat "$dest"
	assert_output --partial "agent-devcontainer/base:latest"
}

@test "--variant=node equals-form works" {
	run adc init "$project" --variant=node
	assert_success
	run cat "$dest"
	assert_output --partial "agent-devcontainer/node:latest"
}

@test "init rejects an unknown variant" {
	run adc init "$project" --variant python
	assert_failure
	assert_output --partial "unknown variant 'python'"
	assert [ ! -e "$dest" ]
}

@test "init rejects --variant without a value" {
	run adc init "$project" --variant
	assert_failure
	assert_output --partial "--variant needs a value"
}

@test "init refuses to overwrite without --force" {
	mkdir -p "${dest%/*}"
	echo sentinel > "$dest"
	run adc init "$project"
	assert_failure
	assert_output --partial "already exists"
	run cat "$dest"
	assert_output "sentinel"
}

@test "init --force overwrites an existing config" {
	mkdir -p "${dest%/*}"
	echo sentinel > "$dest"
	run adc init "$project" --force
	assert_success
	run cat "$dest"
	refute_output "sentinel"
	assert_output --partial "agent-devcontainer/base:latest"
}

@test "init rejects unknown options" {
	run adc init "$project" --bogus
	assert_failure
	assert_output --partial "unknown option '--bogus'"
}

@test "init rejects a second directory argument" {
	run adc init "$project" other
	assert_failure
	assert_output --partial "at most one directory"
}

@test "init fails on a missing directory" {
	run adc init "$BATS_TEST_TMPDIR/nope"
	assert_failure
	assert_output --partial "is not a directory"
}
