#!/bin/bash
# Filter regression test. Extracts the FILTER heredoc from
# scripts/unraid-readonly-ssh-setup.sh, runs it under bash with each test's
# SSH_ORIGINAL_COMMAND, and asserts ALLOW (exit 0) vs BLOCK (exit 1).
#
# 30+ cases covering known-good, known-bad, and v7-specific behaviour
# (plugin-name parameterisation, scratch category).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$ROOT/src/usr/local/emhttp/plugins/claude-ssh/scripts/unraid-readonly-ssh-setup.sh"

if [ ! -f "$SETUP" ]; then
    echo "FAIL: $SETUP not found"
    exit 1
fi

# v8: plugin-name allowlist now lives in a runtime config file. Seed a
# sandbox copy so the existing allow cases for torrent-handler / claude-ssh
# still pass; the env-var override keeps production /boot/config/ untouched.
SANDBOX_DIR=$(mktemp -d -t claude-ssh-filter-XXXXXX)
trap 'rm -rf "$SANDBOX_DIR" "${FILTER_TMP:-}"' EXIT
cat > "$SANDBOX_DIR/allowlist.cfg" << 'EOF'
plugin torrent-handler
plugin claude-ssh
EOF
export CLAUDE_SSH_ALLOWLIST_FILE="$SANDBOX_DIR/allowlist.cfg"

# Extract the heredoc (lines between `cat > "$FILTER_SCRIPT" << 'FILTER'`
# and the bare `FILTER` line). Strip the marker lines themselves.
FILTER_TMP=$(mktemp -t shell-filter-XXXXXX.sh)
awk '
    /^cat > "\$FILTER_SCRIPT" << '\''FILTER'\''$/ { capturing=1; next }
    capturing && /^FILTER$/ { capturing=0; exit }
    capturing { print }
' "$SETUP" > "$FILTER_TMP"

if [ ! -s "$FILTER_TMP" ]; then
    echo "FAIL: could not extract FILTER heredoc from $SETUP"
    rm -f "$FILTER_TMP"
    exit 1
fi
chmod +x "$FILTER_TMP"
echo "  extracted filter heredoc → $(wc -l < "$FILTER_TMP" | tr -d ' ') lines"

# Replace the final `exec bash -f -c "$CMD"` with `echo "ALLOWED" && exit 0`
# so the test doesn't actually execute the command — we only care whether
# the filter would have allowed it through.
sed -i.bak 's|^exec bash -f -c "\$CMD"|echo "ALLOWED"; exit 0|' "$FILTER_TMP"
rm -f "$FILTER_TMP.bak"

# Test runner: $1=expected (allow|block), $2=command
PASS=0
FAIL=0
FAILED=()

run_case() {
    local expected="$1"
    local cmd="$2"
    local out rc
    out=$(SSH_ORIGINAL_COMMAND="$cmd" bash "$FILTER_TMP" 2>&1)
    rc=$?
    local got
    if [ "$rc" -eq 0 ]; then got="allow"; else got="block"; fi

    if [ "$got" = "$expected" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED+=("expected=$expected got=$got cmd=$cmd  ## $out")
    fi
}

# ---------------- ALLOW cases ----------------
run_case allow 'ls /mnt/user'
run_case allow 'cat /etc/hostname'
run_case allow 'find /mnt -type f'
run_case allow 'df -h'
run_case allow 'du -sh /mnt/user'
run_case allow 'ps aux'
run_case allow 'curl https://example.com'
run_case allow 'echo hello'
run_case allow 'ls /mnt | wc -l'
run_case allow 'find /mnt | xargs cat'
run_case allow 'mkdir -p /tmp/claude-foo'
run_case allow 'ln /a /b'
run_case allow 'find /mnt -type f > /tmp/claude-out.txt'
run_case allow 'grep "A\|B" /etc/hosts'
run_case allow 'ls 2>/dev/null'
run_case allow 'ls > /dev/null'
run_case allow 'tar -tf /tmp/foo.tar'
# v7 simple categories
run_case allow 'claude-write hook-sonarr foo.sh'
run_case allow 'claude-write hook-radarr foo.sh'
run_case allow 'claude-write scratch foo.txt'
# v7 plugin categories with plugin-name allowlist
run_case allow 'claude-write plugin-page torrent-handler Foo.page'
run_case allow 'claude-write plugin-page claude-ssh ClaudeSsh.page'
run_case allow 'claude-write plugin-include claude-ssh exec.php'
run_case allow 'claude-write plugin-script claude-ssh install-runtime.sh'

# ---------------- BLOCK cases ----------------
run_case block 'rm /tmp/x'
run_case block 'mv a b'
run_case block 'chmod 755 file'
run_case block 'chown root file'
run_case block 'ls; rm /tmp/x'
run_case block 'ls && rm /tmp/x'
run_case block 'ls || rm /tmp/x'
run_case block 'cat $(echo /etc)'
run_case block 'cat `echo /etc`'
run_case block 'find /mnt -delete'
run_case block 'find /mnt -exec rm {} ;'
run_case block 'sed -i s/x/y/ /etc/hosts'
run_case block 'curl -X DELETE http://example.com'
run_case block 'curl -o /etc/foo http://x'
run_case block 'curl -K cfg http://x'
run_case block 'mkdir -m 777 /a'
run_case block 'ln -s /a /b'
run_case block 'ln -f /a /b'
run_case block 'tar -xf /tmp/foo.tar'
run_case block 'tar -cf /tmp/out.tar /etc'
run_case block 'find /mnt | xargs rm'
run_case block 'find /mnt | xargs sh'
run_case block 'cat <(echo hi)'
run_case block 'cat >(echo hi)'
run_case block 'ls > /etc/foo'
run_case block 'find /mnt > /tmp/claude-../etc/foo'
# v7 claude-write rejections
run_case block 'claude-write hook-sonarr'
run_case block 'claude-write hook-sonarr foo.sh extra'
run_case block 'claude-write hook-sonarr ../foo.sh'
run_case block 'claude-write hook-sonarr .hidden.sh'
run_case block 'claude-write plugin-page badplugin Foo.page'
run_case block 'claude-write plugin-page torrent-handler'
run_case block 'claude-write plugin-page torrent-handler Foo.page extra'
run_case block 'claude-write unknown-cat foo.txt'

# v8 allowlist behaviour: the sandbox allows torrent-handler + claude-ssh
# (already covered above). With an empty allowlist, even those should block.
EMPTY_ALLOWLIST="$SANDBOX_DIR/empty.cfg"
: > "$EMPTY_ALLOWLIST"
CLAUDE_SSH_ALLOWLIST_FILE_BACKUP="$CLAUDE_SSH_ALLOWLIST_FILE"
export CLAUDE_SSH_ALLOWLIST_FILE="$EMPTY_ALLOWLIST"
run_case block 'claude-write plugin-page torrent-handler Foo.page'
run_case block 'claude-write plugin-page claude-ssh ClaudeSsh.page'
# Restore for any subsequent cases.
export CLAUDE_SSH_ALLOWLIST_FILE="$CLAUDE_SSH_ALLOWLIST_FILE_BACKUP"

rm -f "$FILTER_TMP"

TOTAL=$((PASS + FAIL))
echo "  cases: $PASS passed / $FAIL failed / $TOTAL total"

if [ "$FAIL" -ne 0 ]; then
    echo "FAIL: $FAIL filter regression case(s) failed:"
    for f in "${FAILED[@]}"; do echo "  - $f"; done
    exit 1
fi
echo "PASS: filter regression"
