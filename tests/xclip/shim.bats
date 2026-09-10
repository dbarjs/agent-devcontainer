#!/usr/bin/env bats
# The xclip shim against Claude Code's Linux clipboard contract (ADR-0012,
# docs/research/claude-clipboard-contract.md section 6): the nine argv
# shapes, the fail-fast rules, and the read-only guarantee.

bats_require_minimum_version 1.5.0

load test_helper

setup_file() {
	start_fake_clipd
}

teardown_file() {
	stop_fake_clipd
}

setup() {
	common_setup
}

# --- shape 1: -t TARGETS -o -------------------------------------------------

@test "TARGETS advertises image/png when the daemon lists an image" {
	clipboard_image
	run xclip -selection clipboard -t TARGETS -o
	assert_success
	assert_output "image/png"
}

@test "TARGETS advertises text targets, never an image, for text" {
	clipboard_text "hello"
	run xclip -selection clipboard -t TARGETS -o
	assert_success
	assert_line --index 0 "text/plain"
	assert_line --index 1 "UTF8_STRING"
	refute_line --partial "image/"
}

@test "TARGETS prints nothing for an empty clipboard" {
	run xclip -selection clipboard -t TARGETS -o
	assert_success
	assert_output ""
}

@test "TARGETS passes through only targets the shim can deliver" {
	printf 'image/png\ntext/plain\nfile\npublic.tiff\n' > "$FAKE_CLIPD_DIR/types"
	run xclip -selection clipboard -t TARGETS -o
	assert_success
	assert_output $'image/png\ntext/plain\nUTF8_STRING'
}

# --- shape 2/3: -t image/png -o, -t image/bmp -o ----------------------------

@test "image/png streams the PNG bytes and exits 0" {
	clipboard_image
	run --separate-stderr xclip -selection clipboard -t image/png -o
	assert_success
	[ "$output" = "$(cat "$FAKE_CLIPD_DIR/png")" ]
}

@test "image/png without an image prints nothing and exits 1" {
	clipboard_text "not an image"
	run --separate-stderr xclip -selection clipboard -t image/png -o
	assert_failure 1
	assert_output ""
}

@test "image/png refuses an empty 200 body (no silent empty screenshot)" {
	printf 'image/png\n' > "$FAKE_CLIPD_DIR/types"
	: > "$FAKE_CLIPD_DIR/png"
	run --separate-stderr xclip -selection clipboard -t image/png -o
	assert_failure 1
	assert_output ""
}

@test "image/bmp is not offered" {
	clipboard_image
	run --separate-stderr xclip -selection clipboard -t image/bmp -o
	assert_failure 1
	assert_output ""
	run requests_seen
	refute_output --partial "/png"
}

# --- shape 4/5: text reads --------------------------------------------------

@test "-o prints the clipboard text byte for byte" {
	clipboard_text $'two lines\n  with indent and a trailing newline\n'
	run --separate-stderr xclip -selection clipboard -o
	assert_success
	[ "$output" = $'two lines\n  with indent and a trailing newline' ] # bats strips one trailing newline
	[ "$(xclip -selection clipboard -o | wc -c | tr -d ' ')" -eq 47 ]
}

@test "-t text/plain -o reads the same text" {
	clipboard_text "/workspaces/repo/shot.png"
	run --separate-stderr xclip -selection clipboard -t text/plain -o
	assert_success
	assert_output "/workspaces/repo/shot.png"
}

@test "text read with no text on the clipboard exits 1 with empty stdout" {
	clipboard_image
	run --separate-stderr xclip -selection clipboard -o
	assert_failure 1
	assert_output ""
}

# --- shape 6-9: primary and writes are no-ops --------------------------------

@test "-selection primary -o prints nothing and exits non-zero without a request" {
	clipboard_text "secret"
	run --separate-stderr xclip -selection primary -o
	assert_failure
	assert_output ""
	run requests_seen
	assert_output ""
}

@test "stdin write to clipboard is refused and never reaches the daemon" {
	run --separate-stderr sh -c "printf 'copied' | ${XCLIP_SH:-sh} '$XCLIP' -selection clipboard"
	assert_failure
	assert_output ""
	run requests_seen
	assert_output ""
}

@test "stdin write to primary is refused" {
	run --separate-stderr sh -c "printf 'copied' | ${XCLIP_SH:-sh} '$XCLIP' -selection primary"
	assert_failure
	assert_output ""
}

@test "-t image/png -i <file> is refused and never reaches the daemon" {
	printf 'png' > "$BATS_TEST_TMPDIR/shot.png"
	run --separate-stderr xclip -selection clipboard -t image/png -i "$BATS_TEST_TMPDIR/shot.png"
	assert_failure
	assert_output ""
	run requests_seen
	assert_output ""
}

# --- fail fast ----------------------------------------------------------------

@test "a daemon that is not listening fails instantly" {
	local started ended
	started=$(date +%s)
	ADC_CLIPD_URL="http://127.0.0.1:1" run --separate-stderr xclip -selection clipboard -t TARGETS -o
	ended=$(date +%s)
	assert_failure 1
	assert_output ""
	[ $((ended - started)) -le 1 ]
}

@test "a daemon that hangs is abandoned within about 1.5 s" {
	clipboard_image
	printf '10' > "$FAKE_CLIPD_DIR/delay"
	local started ended
	started=$(date +%s)
	run --separate-stderr xclip -selection clipboard -t image/png -o
	ended=$(date +%s)
	assert_failure 1
	assert_output ""
	[ $((ended - started)) -le 3 ]
}

@test "default daemon address is host.docker.internal:47820 with ADC_CLIPD_URL as the override" {
	run grep -c 'ADC_CLIPD_URL:-http://host.docker.internal:47820' "$XCLIP"
	assert_output "1"
	# override honoured: with a bad override nothing answers
	ADC_CLIPD_URL="http://127.0.0.1:1/" run --separate-stderr xclip -selection clipboard -o
	assert_failure 1
}

@test "failures report on stderr, never on stdout" {
	run --separate-stderr xclip -selection clipboard -t image/png -o
	assert_failure
	assert_output ""
	[ -n "$stderr" ]
}
