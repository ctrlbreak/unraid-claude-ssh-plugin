#!/bin/bash
# Security-invariant regression test: the filter must block every shell-level
# path that would write into /boot/config/. The runtime allowlist (v8) lives
# under /boot/config/plugins/claude-ssh/, so a vector that lets the `claude`
# SSH user write there could be used to expand their own allowlist.
#
# Scope: this verifies SHELL-LEVEL writes (the surface the filter polices).
#   - `>` / `>>` redirect to /boot/config/...
#   - `tee` (not in ALLOWED list)
#   - shell chaining (`;`, `&&`, `||`) attempting to reach a write
#   - claude-write categories — none target /boot/config/, but verify the
#     scratch redirect-strip can't be tricked into accepting /boot/config/...
#
# Out of scope (defended at the filesystem layer, not the filter):
#   - `mkdir /boot/config/foo` — filter allows mkdir; /boot/config/ is root-
#     owned so the unprivileged `claude` user can't actually write there.
#   - awk-internal `print > "/boot/config/..."` — the awk program is a
#     quoted shell argument; the filter doesn't decompose awk source.
#     FS permissions are the enforcer here.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$ROOT/src/usr/local/emhttp/plugins/claude-ssh/scripts/unraid-readonly-ssh-setup.sh"

if [ ! -f "$SETUP" ]; then
    echo "FAIL: $SETUP not found"
    exit 1
fi

FILTER_TMP=$(mktemp -t shell-filter-XXXXXX.sh)
trap 'rm -f "$FILTER_TMP"' EXIT

awk '
    /^cat > "\$FILTER_SCRIPT" << '\''FILTER'\''$/ { capturing=1; next }
    capturing && /^FILTER$/ { capturing=0; exit }
    capturing { print }
' "$SETUP" > "$FILTER_TMP"

if [ ! -s "$FILTER_TMP" ]; then
    echo "FAIL: could not extract FILTER heredoc"
    exit 1
fi

sed -i.bak 's|^exec bash -f -c "\$CMD"|echo "ALLOWED"; exit 0|' "$FILTER_TMP"
rm -f "$FILTER_TMP.bak"

PASS=0
FAIL=0
FAILED=()

run_case() {
    local expected="$1" cmd="$2"
    local out rc got
    out=$(SSH_ORIGINAL_COMMAND="$cmd" bash "$FILTER_TMP" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then got="allow"; else got="block"; fi
    if [ "$got" = "$expected" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED+=("expected=$expected got=$got cmd=$cmd  ## $out")
    fi
}

# ---- Shell-level redirects to /boot/config/ ----
run_case block 'ls > /boot/config/foo'
run_case block 'ls >> /boot/config/foo'
run_case block 'ls > /boot/config/plugins/claude-ssh/allowlist.cfg'
run_case block 'cat /etc/hosts > /boot/config/plugins/claude-ssh/allowlist.cfg'
run_case block 'find /mnt > /boot/config/foo'
run_case block 'echo plugin foo > /boot/config/plugins/claude-ssh/allowlist.cfg'
run_case block 'printf "plugin foo\n" > /boot/config/plugins/claude-ssh/allowlist.cfg'

# ---- tee / other unallowed write tools ----
run_case block 'tee /boot/config/foo'
run_case block 'echo x | tee -a /boot/config/foo'
run_case block 'cp /etc/hosts /boot/config/foo'      # cp not in ALLOWED
run_case block 'install -m 644 /etc/hosts /boot/config/foo'

# ---- Chaining tricks: even a leading allowed cmd can't escort an unallowed one ----
run_case block 'ls; tee /boot/config/foo'
run_case block 'ls && tee /boot/config/foo'
run_case block 'ls > /boot/config/x; ls'

# ---- Command/process substitution ----
run_case block 'cat $(echo /boot/config/foo)'
run_case block 'cat `echo /boot/config/foo`'
run_case block 'cat <(ls /boot/config/)'

# ---- Scratch-redirect strip must NOT be tricked into accepting /boot/config/ ----
# The filter strips redirects to /tmp/claude-*; verify a /boot/config/ target
# isn't hit by the strip regex even when paired with a scratch redirect.
run_case block 'ls > /tmp/claude-foo > /boot/config/x'   # double redirect; last wins
run_case block 'ls > /boot/config/claude-x'
run_case block 'ls > /boot/config/tmp/claude-x'

# ---- claude-write categories: none target /boot/config/ ----
# Pick a few to lock the contract. plugin-cfg writes to
# /usr/local/emhttp/plugins/<plugin>/, NOT /boot/config/.
run_case block 'claude-write plugin-cfg claude-ssh /boot/config/foo.cfg'   # path in basename → invalid
run_case block 'claude-write plugin-cfg ../config foo.cfg'                  # path traversal in plugin-name
run_case block 'claude-write plugin-cfg claude-ssh ../allowlist.cfg'        # path traversal in basename
run_case block 'claude-write scratch ../boot-config-foo'                    # leading dot blocked anyway

# ---- Read access to /boot/config IS allowed (this is intentional) ----
# The concern is writes; reads via cat/ls/grep are fine.
run_case allow 'ls /boot/config'
run_case allow 'cat /boot/config/plugins/claude-ssh/allowlist.cfg'
run_case allow 'grep ^plugin /boot/config/plugins/claude-ssh/allowlist.cfg'

TOTAL=$((PASS + FAIL))
echo "  cases: $PASS passed / $FAIL failed / $TOTAL total"

if [ "$FAIL" -ne 0 ]; then
    echo "FAIL: $FAIL boot-config-write-block case(s) failed:"
    for f in "${FAILED[@]}"; do echo "  - $f"; done
    exit 1
fi
echo "PASS: filter blocks all shell-level writes to /boot/config/"
