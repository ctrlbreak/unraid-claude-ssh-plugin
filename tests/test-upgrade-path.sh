#!/bin/bash
# Verifies install-runtime.sh's upgrade-path behaviour for the two sticky
# /boot/config/plugins/claude-ssh/ files: `username` and `allowlist.cfg`.
#
# Invariants under test (CLAUDE.md #3):
#   - On first install (file missing), seed with the resolved/template value.
#   - On subsequent installs (file present), NEVER overwrite — preserves any
#     user edits made via Settings UI or by editing the file directly.
#   - Pre-Phase-6 installs (no username file at all) come up with username =
#     "claude", so behaviour for existing deployments is byte-identical to v6b.
#
# Sandbox-only: replicates the seed logic against a temp /boot/config tree.
# Drift check at the end asserts the seed guards still exist in
# install-runtime.sh — a future refactor that drops them would fail here.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_RT="$ROOT/src/usr/local/emhttp/plugins/claude-ssh/scripts/install-runtime.sh"

if [ ! -f "$INSTALL_RT" ]; then
    echo "FAIL: install-runtime.sh not found at $INSTALL_RT"
    exit 1
fi

SANDBOX=$(mktemp -d -t claude-ssh-upgrade.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0
FAILED=()

# Replicates the relevant blocks of install-runtime.sh against $SANDBOX as a
# fake /boot/config/plugins/claude-ssh/. The cs_resolve_username() body is
# verbatim from install-runtime.sh — drift is enforced by
# test-username-configurable.sh.
run_install() {
    local username_dir="$SANDBOX/plugins/claude-ssh"
    local username_file="$username_dir/username"
    local allowlist_file="$username_dir/allowlist.cfg"

    cs_resolve_username() {
        local _u="" _file="$username_file"
        if [ -n "${CLAUDE_SSH_USERNAME:-}" ]; then
            _u="$CLAUDE_SSH_USERNAME"
        elif [ -f "$_file" ]; then
            _u=$(head -n1 "$_file" 2>/dev/null | tr -d ' \t\r\n')
        fi
        [ -z "$_u" ] && _u="claude"
        if ! echo "$_u" | grep -qE '^[a-z][a-z0-9-]{0,31}$'; then
            echo "ERROR: invalid SSH username '$_u'" >&2
            return 1
        fi
        printf '%s\n' "$_u"
    }
    local USERNAME
    USERNAME=$(cs_resolve_username) || return 1

    [ -d "$username_dir" ] || mkdir -p "$username_dir"
    if [ ! -f "$username_file" ]; then
        printf '%s\n' "$USERNAME" > "$username_file"
        chmod 644 "$username_file"
    fi

    if [ ! -f "$allowlist_file" ]; then
        cat > "$allowlist_file" << 'ALLOWLIST'
# claude-ssh allowlist — runtime config for the claude-write deploy channel.
#
# Format:
#   plugin <name>      Allow plugin-* writes for /usr/local/emhttp/plugins/<name>/.
#   container <name>   Allow appdata-script writes for /mnt/user/appdata/<name>/scripts/.
#
# Examples (uncomment to enable):
# plugin torrent-handler
# container sonarr
ALLOWLIST
        chmod 644 "$allowlist_file"
    fi
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED+=("$label: expected [$expected], got [$actual]")
    fi
}

assert_file_contains() {
    local label="$1" file="$2" needle="$3"
    if [ -f "$file" ] && grep -qF "$needle" "$file"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED+=("$label: '$needle' not found in $file")
    fi
}

reset_sandbox() {
    rm -rf "$SANDBOX"
    mkdir -p "$SANDBOX"
    unset CLAUDE_SSH_USERNAME
}

USERNAME_FILE="$SANDBOX/plugins/claude-ssh/username"
ALLOWLIST_FILE="$SANDBOX/plugins/claude-ssh/allowlist.cfg"

# --- Case 1: first install on empty sandbox seeds username = "claude" ----
reset_sandbox
run_install
assert_eq "case1: username seeded to 'claude'" "claude" "$(cat "$USERNAME_FILE" 2>/dev/null)"

# --- Case 2: same first install seeds the allowlist template ------------
assert_file_contains "case2: allowlist template seeded" "$ALLOWLIST_FILE" "# claude-ssh allowlist"

# --- Case 3: env-driven first install seeds the configured value --------
reset_sandbox
export CLAUDE_SSH_USERNAME=ops
run_install
assert_eq "case3: env-driven seed = 'ops'" "ops" "$(cat "$USERNAME_FILE" 2>/dev/null)"
unset CLAUDE_SSH_USERNAME

# --- Case 4: pre-existing username file is NEVER overwritten ------------
reset_sandbox
mkdir -p "$SANDBOX/plugins/claude-ssh"
printf 'admin\n' > "$USERNAME_FILE"
run_install
assert_eq "case4: pre-existing username preserved" "admin" "$(cat "$USERNAME_FILE")"

# --- Case 5: env at install time does NOT overwrite an existing file ----
# (env beats file in the resolver, so the running install resolves to "root2",
# but the seed step is a no-op because the file already exists. The next
# install with no env will re-read the file and resolve to "admin" — env is
# transient by design, file is sticky.)
reset_sandbox
mkdir -p "$SANDBOX/plugins/claude-ssh"
printf 'admin\n' > "$USERNAME_FILE"
export CLAUDE_SSH_USERNAME=root2
run_install
assert_eq "case5: env doesn't overwrite existing file" "admin" "$(cat "$USERNAME_FILE")"
unset CLAUDE_SSH_USERNAME

# --- Case 6: pre-existing allowlist with user edits is preserved --------
reset_sandbox
mkdir -p "$SANDBOX/plugins/claude-ssh"
cat > "$ALLOWLIST_FILE" << 'USERCFG'
# my custom edits
plugin torrent-handler
container sonarr
container radarr
USERCFG
ALLOWLIST_HASH_BEFORE=$(shasum "$ALLOWLIST_FILE" | awk '{print $1}')
run_install
ALLOWLIST_HASH_AFTER=$(shasum "$ALLOWLIST_FILE" | awk '{print $1}')
assert_eq "case6: user-edited allowlist preserved byte-for-byte" "$ALLOWLIST_HASH_BEFORE" "$ALLOWLIST_HASH_AFTER"

# --- Case 7: idempotency — second run leaves both files untouched -------
reset_sandbox
run_install
USERNAME_AFTER_FIRST=$(stat -f '%m %z' "$USERNAME_FILE" 2>/dev/null || stat -c '%Y %s' "$USERNAME_FILE")
ALLOWLIST_AFTER_FIRST=$(stat -f '%m %z' "$ALLOWLIST_FILE" 2>/dev/null || stat -c '%Y %s' "$ALLOWLIST_FILE")
USERNAME_HASH_FIRST=$(shasum "$USERNAME_FILE" | awk '{print $1}')
ALLOWLIST_HASH_FIRST=$(shasum "$ALLOWLIST_FILE" | awk '{print $1}')
sleep 1
run_install
run_install
USERNAME_HASH_THIRD=$(shasum "$USERNAME_FILE" | awk '{print $1}')
ALLOWLIST_HASH_THIRD=$(shasum "$ALLOWLIST_FILE" | awk '{print $1}')
assert_eq "case7a: username content stable across re-runs" "$USERNAME_HASH_FIRST" "$USERNAME_HASH_THIRD"
assert_eq "case7b: allowlist content stable across re-runs" "$ALLOWLIST_HASH_FIRST" "$ALLOWLIST_HASH_THIRD"

# --- Case 8: drift check — install-runtime.sh still has the seed guards ---
# Both seed blocks must check `[ ! -f ... ]` before writing. A regression that
# drops the guard would silently start clobbering user edits on every upgrade.
if grep -qE '\[ ! -f "\$USERNAME_FILE" \]' "$INSTALL_RT" \
   && grep -qE '\[ ! -f "\$ALLOWLIST_FILE" \]' "$INSTALL_RT"; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    FAILED+=("case8: install-runtime.sh missing [ ! -f ] seed guards")
fi

TOTAL=$((PASS + FAIL))
echo "  cases: $PASS passed / $FAIL failed / $TOTAL total"
if [ "$FAIL" -ne 0 ]; then
    echo "FAIL: upgrade-path invariants broken"
    for f in "${FAILED[@]}"; do echo "  - $f"; done
    exit 1
fi
echo "PASS: install-runtime.sh seeds username + allowlist on first install, never overwrites on upgrade"
