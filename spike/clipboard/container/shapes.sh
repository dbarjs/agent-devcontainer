set -u
m=/tmp/claude-1000/claude_cli_latest_screenshot.png
mkdir -p /tmp/claude-1000
echo "## shape1 checkImage"; t=$(date +%s%N)
sh -c 'xclip -selection clipboard -t TARGETS -o 2>/dev/null | grep -E "image/(png|jpeg|jpg|gif|webp|bmp)" || wl-paste -l 2>/dev/null | grep -E "image/(png|jpeg|jpg|gif|webp|bmp)"'; echo "exit=$? $(( ($(date +%s%N)-t)/1000000 ))ms"
echo "## shape2 saveImage"; t=$(date +%s%N)
sh -c "xclip -selection clipboard -t image/png -o > $m 2>/dev/null || wl-paste --type image/png > $m 2>/dev/null || xclip -selection clipboard -t image/bmp -o > $m 2>/dev/null || wl-paste --type image/bmp > $m"; echo "exit=$? $(( ($(date +%s%N)-t)/1000000 ))ms"; ls -l $m; head -c 8 $m | od -An -c
echo "## shape4 text/plain"; sh -c 'xclip -selection clipboard -t text/plain -o 2>/dev/null || wl-paste 2>/dev/null'; echo "exit=$?"
echo "## shape5 xclip -o (argv)"; xclip -selection clipboard -o; echo "exit=$?"
echo "## shape6 primary"; xclip -selection primary -o; echo "exit=$?"
