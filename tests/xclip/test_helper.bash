# Shared setup for the xclip shim suite (tier 1): drives images/base/xclip
# with /bin/sh against the fake clipboard daemon in tests/lib/fake-clipd.py
# and asserts on stdout, exit codes, and the requests the daemon saw.

export BATS_LIB_PATH="${BATS_LIB_PATH:-/usr/lib/bats:/usr/local/lib:/opt/homebrew/lib}"

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
XCLIP="$REPO_ROOT/images/base/xclip"
FAKE_CLIPD="$REPO_ROOT/tests/lib/fake-clipd.py"

# One daemon per file; its state dir is shared and reset by each test.
start_fake_clipd() {
	export FAKE_CLIPD_DIR="$BATS_FILE_TMPDIR/clipd"
	mkdir -p "$FAKE_CLIPD_DIR"
	python3 "$FAKE_CLIPD" &
	echo $! > "$BATS_FILE_TMPDIR/clipd.pid"
	local tries=50 port
	while [ ! -s "$FAKE_CLIPD_DIR/port" ] && [ "$tries" -gt 0 ]; do
		sleep 0.1
		tries=$((tries - 1))
	done
	[ -s "$FAKE_CLIPD_DIR/port" ] || { echo "fake clipd did not start" >&2; return 1; }
	port="$(cat "$FAKE_CLIPD_DIR/port")"
	export ADC_CLIPD_URL="http://127.0.0.1:$port"
}

stop_fake_clipd() {
	kill "$(cat "$BATS_FILE_TMPDIR/clipd.pid")" 2>/dev/null || true
	wait "$(cat "$BATS_FILE_TMPDIR/clipd.pid")" 2>/dev/null || true
}

common_setup() {
	bats_load_library bats-support
	bats_load_library bats-assert
	rm -f "$FAKE_CLIPD_DIR"/types "$FAKE_CLIPD_DIR"/png "$FAKE_CLIPD_DIR"/text \
		"$FAKE_CLIPD_DIR"/delay "$FAKE_CLIPD_DIR"/requests.log
}

# "clipboard" fixtures
clipboard_image() {
	printf 'image/png\n' > "$FAKE_CLIPD_DIR/types"
	printf '\211PNG\r\n\032\n' > "$FAKE_CLIPD_DIR/png"
	printf 'fake-png-payload-%s' "$RANDOM" >> "$FAKE_CLIPD_DIR/png"
}
clipboard_text() {
	printf 'text/plain\n' > "$FAKE_CLIPD_DIR/types"
	printf '%s' "$1" > "$FAKE_CLIPD_DIR/text"
}

# XCLIP_SH picks the interpreter (dash locally proves POSIX-ness before CI)
xclip() {
	"${XCLIP_SH:-sh}" "$XCLIP" "$@"
}

requests_seen() {
	cat "$FAKE_CLIPD_DIR/requests.log" 2>/dev/null || true
}
