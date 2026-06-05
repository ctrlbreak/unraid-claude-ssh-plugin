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

# v8/v9: plugin- and container-name allowlists live in a runtime config file.
# Seed a sandbox copy so the existing allow cases pass; env-var override
# keeps production /boot/config/ untouched.
SANDBOX_DIR=$(mktemp -d -t claude-ssh-filter-XXXXXX)
trap 'rm -rf "$SANDBOX_DIR" "${FILTER_TMP:-}"' EXIT
cat > "$SANDBOX_DIR/allowlist.cfg" << 'EOF'
plugin torrent-handler
plugin claude-ssh
container sonarr
container radarr
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
# v12 read-only diagnostics
run_case allow 'which bash'
run_case allow 'iostat -x 2 3'
run_case allow 'smbstatus -L'
run_case allow 'dmesg'
run_case allow 'dmesg -T'
run_case allow 'dmesg -e'                 # lowercase reltime is read-only (vs -E console-on)
run_case allow 'dmesg | grep -i error'
# v14 dmesg: read flags must stay allowed (case-sensitive guard)
run_case allow 'dmesg -f kern'            # lowercase -f (facility) is read-only (vs -F file)
run_case allow 'dmesg -P'                 # -P (nopager) is read-only
run_case allow 'dmesg -x -T'
# Simple category
run_case allow 'claude-write scratch foo.txt'
# v11 plugin-file: top-level files, 1-component rel-path
run_case allow 'claude-write plugin-file torrent-handler Foo.page'
run_case allow 'claude-write plugin-file claude-ssh ClaudeSsh.page'
run_case allow 'claude-write plugin-file claude-ssh default.cfg'
# v11 plugin-file: 2-component rel-path (typical subdir layouts)
run_case allow 'claude-write plugin-file claude-ssh include/exec.php'
run_case allow 'claude-write plugin-file claude-ssh scripts/install-runtime.sh'
run_case allow 'claude-write plugin-file torrent-handler javascript/foo.js'
run_case allow 'claude-write plugin-file torrent-handler sheets/style.css'
run_case allow 'claude-write plugin-file torrent-handler images/icon.svg'
# v11 plugin-file: 3-component rel-path (vendored python package case)
run_case allow 'claude-write plugin-file torrent-handler scripts/torrent_handler/relink.py'
run_case allow 'claude-write plugin-file torrent-handler scripts/torrent_handler/__init__.py'
run_case allow 'claude-write plugin-file torrent-handler javascript/lib/foo.js'
# v11 plugin-file: event/<hook> extensionless exception (depth-1, lowercase)
run_case allow 'claude-write plugin-file claude-ssh event/started'
run_case allow 'claude-write plugin-file claude-ssh event/stopping_svcs'
run_case allow 'claude-write plugin-file claude-ssh event/disks_mounted'
# v9 container category (appdata-script) with container allowlist
run_case allow 'claude-write appdata-script sonarr foo.sh'
run_case allow 'claude-write appdata-script radarr cleanup-old.sh'
# v13: separator check is quote/backslash-aware — ; & inside quotes or escaped
# are literal data, not command separators, and must still pass.
run_case allow 'curl "https://example.com/?a=1&b=2"'   # & inside double quotes (query string)
run_case allow 'grep "a;b" /etc/hosts'                 # ; inside double quotes (literal pattern)
run_case allow "grep 'a & b' /etc/hosts"               # & inside single quotes
run_case allow 'find /mnt \( -name a -o -name b \)'    # escaped parens, no separator

# ---------------- BLOCK cases ----------------
run_case block 'rm /tmp/x'
run_case block 'mv a b'
run_case block 'chmod 755 file'
run_case block 'chown root file'
run_case block 'ls; rm /tmp/x'
run_case block 'ls && rm /tmp/x'
run_case block 'ls || rm /tmp/x'
# v13 regression: command-separator forms the pre-v13 regex denylist MISSED.
# Each ran an arbitrary second command under the final `bash -c` while the
# per-segment allowlist only ever saw the benign first token.
run_case block 'ls ;rm /tmp/x'                  # semicolon, no trailing space
run_case block 'ls ;env'                         # semicolon -> disallowed cmd
run_case block 'ls & rm /tmp/x'                  # bare & (background) separator
run_case block 'ls&rm /tmp/x'                    # & with no surrounding spaces
run_case block 'cat /etc/hostname & env'         # & -> disallowed cmd
run_case block 'ls /mnt | grep x ;env'           # separator after a pipe segment
run_case block "$(printf 'ls /mnt\nrm /tmp/x')"  # embedded newline separator
run_case block "$(printf 'ls /mnt\nls /etc')"    # newline separator, BOTH sides allowed
                                                 # (proves the separator itself is blocked,
                                                 #  not just a disallowed 2nd command)
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
# v12 dmesg buffer/console mutators (read-only allowed, these are not)
run_case block 'dmesg -C'
run_case block 'dmesg --clear'
run_case block 'dmesg -c'
run_case block 'dmesg --read-clear'
run_case block 'dmesg -n 1'
run_case block 'dmesg -E'
run_case block 'dmesg -D'
# v14 dmesg: GTFOBins read-escape / nuisance flags now blocked
run_case block 'dmesg -F /etc/passwd'     # read arbitrary file via dmesg
run_case block 'dmesg --file=/etc/passwd'
run_case block 'dmesg -w'                  # follow — never returns, hangs session
run_case block 'dmesg --follow'
run_case block 'dmesg -W'                  # follow-new
run_case block 'dmesg -H'                  # pager invoke
run_case block 'find /mnt | xargs rm'
run_case block 'find /mnt | xargs sh'
run_case block 'cat <(echo hi)'
run_case block 'cat >(echo hi)'
run_case block 'ls > /etc/foo'
run_case block 'find /mnt > /tmp/claude-../etc/foo'
# v9 claude-write rejections
# Legacy hook-* categories removed — must now reject as unknown.
run_case block 'claude-write hook-sonarr foo.sh'
run_case block 'claude-write hook-radarr foo.sh'
# v11: old plugin-* category names are no longer accepted.
run_case block 'claude-write plugin-page torrent-handler Foo.page'
run_case block 'claude-write plugin-include torrent-handler exec.php'
run_case block 'claude-write plugin-script torrent-handler relink.py'
run_case block 'claude-write plugin-cfg torrent-handler default.cfg'
# Plugin allowlist enforcement (v11 form).
run_case block 'claude-write plugin-file badplugin Foo.page'
run_case block 'claude-write plugin-file torrent-handler'
run_case block 'claude-write plugin-file torrent-handler Foo.page extra'
# v11 plugin-file rel-path SHAPE rejections (filter enforces structure;
# extension allowlist + event/<hook> semantics belong to the writer).
run_case block 'claude-write plugin-file torrent-handler ../escape.sh'         # parent traversal
run_case block 'claude-write plugin-file torrent-handler scripts/../escape.sh' # mid-path traversal
run_case block 'claude-write plugin-file torrent-handler /etc/passwd'          # leading slash
run_case block 'claude-write plugin-file torrent-handler scripts/'             # trailing slash
run_case block 'claude-write plugin-file torrent-handler scripts//foo.py'      # empty middle component
run_case block 'claude-write plugin-file torrent-handler .hidden.sh'           # leading dot
run_case block 'claude-write plugin-file torrent-handler scripts/.hidden.sh'   # leading dot in component
run_case block 'claude-write plugin-file torrent-handler a/b/c/d.py'           # 4 components > max 3
# appdata-script container allowlist enforcement.
run_case block 'claude-write appdata-script bazarr foo.sh'        # not in sandbox allowlist
run_case block 'claude-write appdata-script sonarr'                # missing basename
run_case block 'claude-write appdata-script sonarr foo.sh extra'   # extra arg
run_case block 'claude-write appdata-script sonarr ../foo.sh'      # path traversal in basename
run_case block 'claude-write appdata-script sonarr .hidden.sh'     # leading dot
run_case block 'claude-write appdata-script ../etc foo.sh'         # path traversal in container
# Unknown category catch-all.
run_case block 'claude-write unknown-cat foo.txt'

# v8/v9 allowlist behaviour: empty allowlist → both plugin-* and
# appdata-script writes default-deny.
EMPTY_ALLOWLIST="$SANDBOX_DIR/empty.cfg"
: > "$EMPTY_ALLOWLIST"
CLAUDE_SSH_ALLOWLIST_FILE_BACKUP="$CLAUDE_SSH_ALLOWLIST_FILE"
export CLAUDE_SSH_ALLOWLIST_FILE="$EMPTY_ALLOWLIST"
run_case block 'claude-write plugin-file torrent-handler Foo.page'
run_case block 'claude-write plugin-file claude-ssh ClaudeSsh.page'
run_case block 'claude-write appdata-script sonarr foo.sh'
run_case block 'claude-write appdata-script radarr foo.sh'
# Cross-isolation: container line in plugin slot doesn't grant plugin access,
# and vice versa.
PLUGIN_ONLY="$SANDBOX_DIR/plugin-only.cfg"
echo "plugin foo" > "$PLUGIN_ONLY"
export CLAUDE_SSH_ALLOWLIST_FILE="$PLUGIN_ONLY"
run_case allow 'claude-write plugin-file foo Foo.page'
run_case block 'claude-write appdata-script foo bar.sh'   # plugin lines don't authorise containers
CONTAINER_ONLY="$SANDBOX_DIR/container-only.cfg"
echo "container foo" > "$CONTAINER_ONLY"
export CLAUDE_SSH_ALLOWLIST_FILE="$CONTAINER_ONLY"
run_case allow 'claude-write appdata-script foo bar.sh'
run_case block 'claude-write plugin-file foo Foo.page'    # container lines don't authorise plugins
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
