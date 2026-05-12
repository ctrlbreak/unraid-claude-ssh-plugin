#!/bin/bash
# End-to-end verification suite for a live claude-ssh install.
#
# Runs ~35 cases across five layers:
#   1. Install state (root SSH)        — files, perms, sudoers, plugin registered
#   2. Filter behaviour (claude SSH)   — allowed reads pass, blocked patterns blocked
#   3. Writer behaviour (claude SSH)   — each category writes succeed for a test
#                                        fixture, out-of-allowlist rejected
#   4. Audit log (root SSH)            — recent entries appear in syslog
#   5. Versions (root SSH)             — deployed filter/writer versions match repo
#
# Each failure prints an inline fix hint plus a docs/troubleshooting.md anchor.
#
# Usage:
#   ROOT_HOST=root@nas.local CLAUDE_HOST=claude@nas.local bash verify-install.sh
#
# Prerequisites:
#   - Passwordless root SSH to the NAS (ROOT_HOST).
#   - Constrained-user SSH to the NAS (CLAUDE_HOST). Default user is `claude`,
#     unless you set a different one via /boot/config/plugins/claude-ssh/username.
#   - Allowlist contains both:
#         plugin verify-test
#         container verify-test
#     Add via the Settings UI's Allowlist card or by editing
#     /boot/config/plugins/claude-ssh/allowlist.cfg. The pre-flight will
#     fail-fast with exact instructions if either entry is missing.
#
# Exits 0 if every case passes (skipped does not fail). Exits 1 on any failure.

set -u

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

# ---- Pre-flight: env vars --------------------------------------------------

NEED_ENV=0
if [ -z "${ROOT_HOST:-}" ]; then
    echo "ERROR: ROOT_HOST not set" >&2
    NEED_ENV=1
fi
if [ -z "${CLAUDE_HOST:-}" ]; then
    echo "ERROR: CLAUDE_HOST not set" >&2
    NEED_ENV=1
fi
if [ "$NEED_ENV" -ne 0 ]; then
    cat <<EOF >&2

Usage:
  ROOT_HOST=root@nas.local CLAUDE_HOST=claude@nas.local bash verify-install.sh

ROOT_HOST    — passwordless root SSH (used for install-state checks).
CLAUDE_HOST  — constrained-user SSH (exercises the actual filter end-to-end).

See docs/verifying.md for the full prerequisites.
EOF
    exit 1
fi

# ---- Pre-flight: SSH ControlMaster (single handshake per host) -------------

ROOT_SSH_OPTS=(-o ControlMaster=auto -o ControlPath=/tmp/verify-ssh-%r@%h -o ControlPersist=60s -o ConnectTimeout=5)
CLAUDE_SSH_OPTS=(-o ControlMaster=auto -o ControlPath=/tmp/verify-ssh-%r@%h -o ControlPersist=60s -o ConnectTimeout=5)

ssh_root() {
    ssh "${ROOT_SSH_OPTS[@]}" "$ROOT_HOST" "$1"
}

ssh_claude() {
    ssh "${CLAUDE_SSH_OPTS[@]}" "$CLAUDE_HOST" "$1"
}

echo "==> claude-ssh verification suite"
echo "==> ROOT_HOST=$ROOT_HOST  CLAUDE_HOST=$CLAUDE_HOST"
echo "==> Opening SSH master connections (password prompt may appear once)..."

# ---- Pre-flight: SSH connectivity ------------------------------------------

# stderr left attached so any password prompt is visible; ControlMaster opens
# on the first call and subsequent ssh_root/ssh_claude calls reuse the socket.
if ! ssh_root "true" >/dev/null; then
    echo "ERROR: cannot SSH to $ROOT_HOST as root" >&2
    exit 1
fi

# Filter rejects most commands with exit 1, but the SSH connection itself
# yields exit 255 only on connect failure. Run `claude-write` (an allowed
# command) and treat anything other than 255 as connectivity OK.
ssh_claude "claude-write" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 255 ]; then
    echo "ERROR: cannot SSH to $CLAUDE_HOST as the constrained user" >&2
    echo "       check the username matches /boot/config/plugins/claude-ssh/username" >&2
    echo "       and that your public key is in ~/.ssh/authorized_keys" >&2
    exit 1
fi

# ---- Pre-flight: read expected versions from local repo --------------------

FILTER_SRC="$REPO_ROOT/src/usr/local/emhttp/plugins/claude-ssh/scripts/unraid-readonly-ssh-setup.sh"
WRITER_SRC="$REPO_ROOT/src/usr/local/emhttp/plugins/claude-ssh/scripts/claude-write-setup.sh"

EXPECTED_FILTER_VERSION=$(grep -m1 -E '^# Filter version:' "$FILTER_SRC" 2>/dev/null | awk '{print $4}')
EXPECTED_WRITER_VERSION=$(grep -m1 -E '^# Writer version:' "$WRITER_SRC" 2>/dev/null | awk '{print $4}')

if [ -z "$EXPECTED_FILTER_VERSION" ] || [ -z "$EXPECTED_WRITER_VERSION" ]; then
    echo "ERROR: could not read expected versions from local repo" >&2
    echo "       expected '# Filter version: vN' / '# Writer version: vN' headers" >&2
    exit 1
fi

echo "==> Expected versions: filter=$EXPECTED_FILTER_VERSION writer=$EXPECTED_WRITER_VERSION"

# ---- Pre-flight: resolve username + assert verify-test entries -------------

USERNAME=$(ssh_root "cat /boot/config/plugins/claude-ssh/username 2>/dev/null || echo claude" | tr -d '[:space:]')
if [ -z "$USERNAME" ]; then USERNAME="claude"; fi

ALLOWLIST_REMOTE="/boot/config/plugins/claude-ssh/allowlist.cfg"
ALLOWLIST_CONTENT=$(ssh_root "cat $ALLOWLIST_REMOTE 2>/dev/null" || true)

has_plugin_verify=$(printf '%s\n' "$ALLOWLIST_CONTENT" | awk 'NF == 2 && $1 == "plugin" && $2 == "verify-test"' | head -1)
has_container_verify=$(printf '%s\n' "$ALLOWLIST_CONTENT" | awk 'NF == 2 && $1 == "container" && $2 == "verify-test"' | head -1)

if [ -z "$has_plugin_verify" ] || [ -z "$has_container_verify" ]; then
    cat <<EOF >&2
ERROR: allowlist is missing the verify-test fixture entries.

The verification suite needs both of these in $ALLOWLIST_REMOTE:

  plugin verify-test
  container verify-test

Add them via the Settings UI (Allowlist card on the claude-ssh tab) or by
editing the file directly as root, then re-run this script. The suite
writes & cleans up files under /usr/local/emhttp/plugins/verify-test/
and /mnt/user/appdata/verify-test/scripts/.

Found:
  plugin verify-test:    $([ -n "$has_plugin_verify" ] && echo yes || echo MISSING)
  container verify-test: $([ -n "$has_container_verify" ] && echo yes || echo MISSING)
EOF
    exit 1
fi

echo "==> Pre-flight: SSH connectivity OK · username=$USERNAME · allowlist has verify-test entries OK"
echo

# ---- Result tracking + cleanup ---------------------------------------------

PASS=0
FAIL=0
SKIP=0
FAILED=()
WRITTEN_FILES=()

record_pass() {
    PASS=$((PASS + 1))
    printf '  PASS  %s %s\n' "$1" "$2"
}

record_fail() {
    FAIL=$((FAIL + 1))
    FAILED+=("$1 $2")
    printf '  FAIL  %s %s\n' "$1" "$2"
    [ -n "${3:-}" ] && printf '        Fix:  %s\n' "$3"
    [ -n "${4:-}" ] && printf '        See:  docs/troubleshooting.md%s\n' "$4"
}

record_skip() {
    SKIP=$((SKIP + 1))
    printf '  SKIP  %s %s (%s)\n' "$1" "$2" "$3"
}

section() {
    echo
    echo "[$1]"
}

cleanup() {
    [ ${#WRITTEN_FILES[@]} -eq 0 ] && return

    local rm_args
    rm_args="rm -f"
    for f in "${WRITTEN_FILES[@]}"; do
        rm_args="$rm_args $(printf '%q' "$f")"
    done

    echo
    echo "==> Cleanup needed: ${#WRITTEN_FILES[@]} test file(s) were written on the NAS."
    echo "    Files:"
    for f in "${WRITTEN_FILES[@]}"; do
        printf '      %s\n' "$f"
    done
    echo
    echo "    Proposed cleanup command (runs as root via SSH):"
    printf '      ssh %s %s\n' "$ROOT_HOST" "$rm_args"
    echo

    if [ ! -t 0 ]; then
        echo "    (non-interactive shell — skipping cleanup; copy the command above to run it manually)"
        return
    fi

    printf '    Run this cleanup now? [y/N] '
    local answer=""
    read -r answer || true
    case "$answer" in
        [yY]|[yY][eE][sS])
            if ssh_root "$rm_args" >/dev/null 2>&1; then
                printf '    Removed %d files.\n' "${#WRITTEN_FILES[@]}"
            else
                echo "    WARN: cleanup command failed — some files may remain. Re-run the command above manually."
            fi
            ;;
        *)
            echo "    Skipped — copy the command above to remove the files manually."
            ;;
    esac
}
trap cleanup EXIT

# Capture a "test run started" marker for syslog filtering in Layer 4.
RUN_START=$(ssh_root "date +%s")
TS="$RUN_START"

# ===========================================================================
# Layer 1 — Install state (root SSH)
# ===========================================================================

section "Layer 1 — Install state"

# 1.1 plugin metadata registered
if ssh_root "test -f /var/log/plugins/claude-ssh.plg"; then
    record_pass "1.1" "plugin metadata registered (/var/log/plugins/claude-ssh.plg)"
else
    record_fail "1.1" "plugin not registered with the plugin manager" \
        "install via the release URL — see docs/install.md" \
        "#plugin-install-fails-smoke-tests-failed"
fi

# 1.2 filter script present, owned root, mode 755
filter_path="/home/$USERNAME/shell-filter.sh"
fstat=$(ssh_root "stat -c '%U:%G %a' '$filter_path' 2>/dev/null" || true)
if [ "$fstat" = "root:root 755" ]; then
    record_pass "1.2" "filter script at $filter_path (root:root 755)"
else
    record_fail "1.2" "filter script missing or wrong perms at $filter_path (got: ${fstat:-not found})" \
        "re-run install-runtime.sh as root, or reinstall the plugin" \
        "#status-tab-filter--writer-version-mismatch"
fi

# 1.3 claude-write wrapper present, mode 755
wstat=$(ssh_root "stat -c '%U:%G %a' /usr/local/bin/claude-write 2>/dev/null" || true)
if [ "$wstat" = "root:root 755" ]; then
    record_pass "1.3" "writer wrapper at /usr/local/bin/claude-write (root:root 755)"
else
    record_fail "1.3" "writer wrapper missing or wrong perms (got: ${wstat:-not found})" \
        "re-run claude-write-setup.sh as root, or reinstall the plugin" \
        "#status-tab-filter--writer-version-mismatch"
fi

# 1.4 privileged writer present, root-owned, mode 755
pstat=$(ssh_root "stat -c '%U:%G %a' /usr/local/sbin/claude-write-priv 2>/dev/null" || true)
if [ "$pstat" = "root:root 755" ]; then
    record_pass "1.4" "privileged writer at /usr/local/sbin/claude-write-priv (root:root 755)"
else
    record_fail "1.4" "privileged writer missing or wrong perms (got: ${pstat:-not found})" \
        "re-run claude-write-setup.sh as root, or reinstall the plugin" \
        "#status-tab-filter--writer-version-mismatch"
fi

# 1.5 sudoers entry present (either /etc/sudoers.d/claude-write or marker in /etc/sudoers)
if ssh_root "test -f /etc/sudoers.d/claude-write || grep -q '^# claude-write deploy channel' /etc/sudoers"; then
    record_pass "1.5" "sudoers entry present"
else
    record_fail "1.5" "sudoers entry missing at /etc/sudoers.d/claude-write" \
        "re-run claude-write-setup.sh as root, or reinstall the plugin" \
        "#writer-fails-silently-sudo-a-password-is-required"
fi

# 1.6 SSH user exists in /etc/passwd with home /home/<user>
pwline=$(ssh_root "getent passwd '$USERNAME' 2>/dev/null" || true)
if printf '%s' "$pwline" | grep -q ":/home/$USERNAME:"; then
    record_pass "1.6" "SSH user $USERNAME exists with home /home/$USERNAME"
else
    record_fail "1.6" "SSH user $USERNAME missing or has wrong home (got: ${pwline:-not found})" \
        "re-run install-runtime.sh as root, or reinstall the plugin" \
        "#status-tab-user-claude-not-ready"
fi

# 1.7 authorized_keys present, mode 600
akstat=$(ssh_root "stat -c '%U:%G %a' /home/$USERNAME/.ssh/authorized_keys 2>/dev/null" || true)
if [ "${akstat##* }" = "600" ] && [ "${akstat%% *}" = "$USERNAME:users" ]; then
    record_pass "1.7" "authorized_keys present ($USERNAME:users 600)"
else
    record_fail "1.7" "authorized_keys missing or wrong perms (got: ${akstat:-not found})" \
        "chown $USERNAME:users + chmod 600 the file as root" \
        "#ssh-connection-permission-denied-publickey"
fi

# 1.8 allowlist file exists at the expected path
if ssh_root "test -f $ALLOWLIST_REMOTE"; then
    record_pass "1.8" "allowlist file at $ALLOWLIST_REMOTE"
else
    record_fail "1.8" "allowlist file missing at $ALLOWLIST_REMOTE" \
        "re-run install-runtime.sh as root to seed the file" \
        "#status-tab-user-claude-not-ready"
fi

# 1.9 username file exists
if ssh_root "test -f /boot/config/plugins/claude-ssh/username"; then
    record_pass "1.9" "username file at /boot/config/plugins/claude-ssh/username"
else
    record_fail "1.9" "username file missing" \
        "re-run install-runtime.sh as root to seed the file" \
        "#status-tab-user-claude-not-ready"
fi

# 1.10 deployed filter/writer versions match local repo
deployed_filter_v=$(ssh_root "grep -m1 -E '^# Filter version:' /home/$USERNAME/shell-filter.sh 2>/dev/null | awk '{print \$4}'" || true)
deployed_writer_v=$(ssh_root "grep -m1 -E '^# Writer version:' /usr/local/sbin/claude-write-priv 2>/dev/null | awk '{print \$4}'" || true)

if [ "$deployed_filter_v" = "$EXPECTED_FILTER_VERSION" ] && [ "$deployed_writer_v" = "$EXPECTED_WRITER_VERSION" ]; then
    record_pass "1.10" "deployed versions match repo (filter=$deployed_filter_v writer=$deployed_writer_v)"
else
    record_fail "1.10" "version mismatch (deployed: filter=${deployed_filter_v:-?} writer=${deployed_writer_v:-?}; expected: filter=$EXPECTED_FILTER_VERSION writer=$EXPECTED_WRITER_VERSION)" \
        "re-run install-runtime.sh as root, or reinstall the plugin" \
        "#status-tab-filter--writer-version-mismatch"
fi

# ===========================================================================
# Layer 2 — Filter behaviour (constrained-user SSH)
# ===========================================================================

section "Layer 2 — Filter behaviour"

filter_doc_anchor="#filter-rejection-blocked"
filter_hint_allow="filter rejected a command that should be allowed — the filter file may be the wrong version (re-run install-runtime.sh as root) or have been hand-edited"
filter_hint_block="filter accepted a command that should be blocked — the filter file may be missing or incorrect; re-run install-runtime.sh as root"

# 2.1 allowed: ls /mnt/user/
if ssh_claude "ls /mnt/user/" >/dev/null 2>&1; then
    record_pass "2.1" "allowed: ls /mnt/user/"
else
    record_fail "2.1" "allowed read 'ls /mnt/user/' rejected" "$filter_hint_allow" "$filter_doc_anchor"
fi

# 2.2 allowed: cat /var/log/syslog | tail -n 1  (pipe through xargs-allowed inner)
if ssh_claude "cat /var/log/syslog | tail -n 1" >/dev/null 2>&1; then
    record_pass "2.2" "allowed: cat /var/log/syslog | tail -n 1"
else
    record_fail "2.2" "allowed pipe 'cat | tail -n 1' rejected" "$filter_hint_allow" "$filter_doc_anchor"
fi

# 2.3 allowed: find /mnt/user/appdata -maxdepth 1 -type d
if ssh_claude "find /mnt/user/appdata -maxdepth 1 -type d" >/dev/null 2>&1; then
    record_pass "2.3" "allowed: find /mnt/user/appdata -maxdepth 1 -type d"
else
    record_fail "2.3" "allowed 'find -maxdepth' rejected" "$filter_hint_allow" "$filter_doc_anchor"
fi

# 2.4 claude-write with no args reaches the writer (passes filter, exits non-zero with usage)
out=$(ssh_claude "claude-write" 2>&1 || true)
if printf '%s' "$out" | grep -qi 'usage\|claude-write'; then
    record_pass "2.4" "claude-write (no args) reaches writer through filter"
else
    record_fail "2.4" "claude-write usage line not seen — filter or writer broken" "$filter_hint_allow" "$filter_doc_anchor"
fi

# 2.5 blocked: rm /tmp/foo (unknown command)
out=$(ssh_claude "rm /tmp/foo" 2>&1 || true)
if printf '%s' "$out" | grep -q 'BLOCKED'; then
    record_pass "2.5" "blocked: rm (unknown command)"
else
    record_fail "2.5" "rm not blocked by filter (got: $out)" "$filter_hint_block" "$filter_doc_anchor"
fi

# 2.6 blocked: semicolon chaining
out=$(ssh_claude "ls /etc/; cat /etc/passwd" 2>&1 || true)
if printf '%s' "$out" | grep -q 'BLOCKED'; then
    record_pass "2.6" "blocked: ; chaining"
else
    record_fail "2.6" "semicolon chaining not blocked" "$filter_hint_block" "$filter_doc_anchor"
fi

# 2.7 blocked: command substitution
# shellcheck disable=SC2016  # intentional — sending literal $(...) through filter
out=$(ssh_claude 'echo $(id)' 2>&1 || true)
if printf '%s' "$out" | grep -q 'BLOCKED'; then
    record_pass "2.7" "blocked: \$(...) command substitution"
else
    record_fail "2.7" "command substitution not blocked" "$filter_hint_block" "$filter_doc_anchor"
fi

# 2.8 blocked: write to /boot/config/...
out=$(ssh_claude "cat /etc/passwd > /boot/config/x" 2>&1 || true)
if printf '%s' "$out" | grep -q 'BLOCKED'; then
    record_pass "2.8" "blocked: redirect to /boot/config/"
else
    record_fail "2.8" "write to /boot/config/ not blocked (invariant violation)" "$filter_hint_block" "$filter_doc_anchor"
fi

# 2.9 blocked: find -exec
out=$(ssh_claude 'find /etc -exec cat {} \;' 2>&1 || true)
if printf '%s' "$out" | grep -q 'BLOCKED'; then
    record_pass "2.9" "blocked: find -exec"
else
    record_fail "2.9" "find -exec not blocked" "$filter_hint_block" "$filter_doc_anchor"
fi

# 2.10 blocked: curl POST
out=$(ssh_claude "curl -X POST https://example.com" 2>&1 || true)
if printf '%s' "$out" | grep -q 'BLOCKED'; then
    record_pass "2.10" "blocked: curl -X POST"
else
    record_fail "2.10" "curl POST not blocked" "$filter_hint_block" "$filter_doc_anchor"
fi

# ===========================================================================
# Layer 3 — Writer behaviour (constrained-user SSH via claude-write)
# ===========================================================================

section "Layer 3 — Writer behaviour"

writer_hint_accept="writer accepted what should have been rejected — your install may be running an old writer version, re-run claude-write-setup.sh as root"
writer_hint_reject="writer rejected what should have succeeded — check the verify-test entries are still in your allowlist and the writer is up to date"
writer_doc_accept="#status-tab-filter--writer-version-mismatch"
writer_doc_reject="#writer-rejection-name-not-in-allowlist"

# Helper: succeed-and-track.  $1=id  $2=name  $3=full claude-write argv  $4=expected_path  $5=expected_mode
write_ok_case() {
    local id="$1" name="$2" argv="$3" path="$4" mode="$5"
    local out rc actual
    out=$(echo "verify-suite $TS" | ssh_claude "claude-write $argv" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        record_fail "$id" "$name (rc=$rc: $out)" "$writer_hint_reject" "$writer_doc_reject"
        return
    fi
    WRITTEN_FILES+=("$path")
    actual=$(ssh_root "stat -c '%a' '$path' 2>/dev/null" || true)
    if [ "$actual" = "$mode" ]; then
        record_pass "$id" "$name → $path (mode $mode)"
    else
        record_fail "$id" "$name wrote but wrong mode (expected $mode, got: ${actual:-not found at $path})" \
            "writer mode-handling may be off; re-run claude-write-setup.sh as root" \
            "$writer_doc_accept"
    fi
}

# Helper: must-reject case.  $1=id  $2=name  $3=full claude-write argv  $4=expected reject substring (optional)
write_reject_case() {
    local id="$1" name="$2" argv="$3" expect="${4:-REJECTED}"
    local out rc
    out=$(echo "verify-suite $TS" | ssh_claude "claude-write $argv" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        record_fail "$id" "$name unexpectedly succeeded" "$writer_hint_accept" "$writer_doc_accept"
        return
    fi
    if printf '%s' "$out" | grep -qi "$expect"; then
        record_pass "$id" "$name (rejected as expected)"
    else
        record_fail "$id" "$name rejected but message unexpected (got: $out)" \
            "writer rejection messages may have changed; verify writer version" \
            "$writer_doc_accept"
    fi
}

# 3.1 scratch write (2-arg category)
write_ok_case "3.1" "scratch write" \
    "scratch verify-${TS}-1.txt" \
    "/tmp/claude-scratch/verify-${TS}-1.txt" "644"

# 3.2 plugin-script (.sh → 755)
write_ok_case "3.2" "plugin-script (allowlisted)" \
    "plugin-script verify-test verify-${TS}-2.sh" \
    "/usr/local/emhttp/plugins/verify-test/scripts/verify-${TS}-2.sh" "755"

# 3.3 plugin-page (.page → 644)
write_ok_case "3.3" "plugin-page (allowlisted)" \
    "plugin-page verify-test verify-${TS}-3.page" \
    "/usr/local/emhttp/plugins/verify-test/verify-${TS}-3.page" "644"

# 3.4 plugin-include (.php → 644)
write_ok_case "3.4" "plugin-include (allowlisted)" \
    "plugin-include verify-test verify-${TS}-4.php" \
    "/usr/local/emhttp/plugins/verify-test/include/verify-${TS}-4.php" "644"

# 3.5 plugin-cfg (.cfg → 644)
write_ok_case "3.5" "plugin-cfg (allowlisted)" \
    "plugin-cfg verify-test verify-${TS}-5.cfg" \
    "/usr/local/emhttp/plugins/verify-test/verify-${TS}-5.cfg" "644"

# 3.6 appdata-script (.sh → 755)
write_ok_case "3.6" "appdata-script (allowlisted)" \
    "appdata-script verify-test verify-${TS}-6.sh" \
    "/mnt/user/appdata/verify-test/scripts/verify-${TS}-6.sh" "755"

# 3.7 non-allowlisted plugin must reject
write_reject_case "3.7" "non-allowlisted plugin" \
    "plugin-script not-in-allowlist verify-${TS}-7.sh"

# 3.8 non-allowlisted container must reject
write_reject_case "3.8" "non-allowlisted container" \
    "appdata-script not-in-allowlist verify-${TS}-8.sh"

# 3.9 path traversal in basename must reject
write_reject_case "3.9" "path traversal in basename" \
    "plugin-script verify-test ../verify-${TS}-9.sh"

# 3.10 bad extension must reject
write_reject_case "3.10" "bad extension (.exe)" \
    "plugin-script verify-test verify-${TS}-10.exe"

# ===========================================================================
# Layer 4 — Audit log (root SSH)
# ===========================================================================

section "Layer 4 — Audit log"

audit_doc_anchor="#status-tab-user-claude-not-ready"
audit_hint="syslog may not be reaching the auth.* facility; check rsyslog config (entries should normally land in /var/log/syslog within seconds)"

# Capture syslog snapshot (last 1000 lines is plenty given runs take seconds).
SYSLOG_TAIL=$(ssh_root "tail -n 1000 /var/log/syslog 2>/dev/null | grep -E 'claude-(shell|write)' || true")

count_recv=$(printf '%s' "$SYSLOG_TAIL" | grep -c 'claude-shell.*RECV:' || true)
count_blocked=$(printf '%s' "$SYSLOG_TAIL" | grep -c 'claude-shell.*BLOCKED' || true)
count_wrote=$(printf '%s' "$SYSLOG_TAIL" | grep -c 'claude-write.*WROTE' || true)
count_rejected=$(printf '%s' "$SYSLOG_TAIL" | grep -c 'claude-write.*REJECTED' || true)

if [ "$count_recv" -gt 0 ]; then
    record_pass "4.1" "claude-shell RECV entries present ($count_recv in tail)"
else
    record_fail "4.1" "no claude-shell RECV entries in syslog" "$audit_hint" "$audit_doc_anchor"
fi

if [ "$count_blocked" -gt 0 ]; then
    record_pass "4.2" "claude-shell BLOCKED entries present ($count_blocked in tail)"
else
    record_fail "4.2" "no claude-shell BLOCKED entries (Layer 2 should have produced these)" "$audit_hint" "$audit_doc_anchor"
fi

if [ "$count_wrote" -gt 0 ]; then
    record_pass "4.3" "claude-write WROTE entries present ($count_wrote in tail)"
else
    record_fail "4.3" "no claude-write WROTE entries (Layer 3 should have produced these)" "$audit_hint" "$audit_doc_anchor"
fi

if [ "$count_rejected" -gt 0 ]; then
    record_pass "4.4" "claude-write REJECTED entries present ($count_rejected in tail)"
else
    record_fail "4.4" "no claude-write REJECTED entries (Layer 3 should have produced these)" "$audit_hint" "$audit_doc_anchor"
fi

# ===========================================================================
# Layer 5 — Versions / status
# ===========================================================================

section "Layer 5 — Versions / status"

# 5.1 + 5.2 already covered by 1.10 — but also assert deployed file headers parse cleanly
if [ "$deployed_filter_v" = "$EXPECTED_FILTER_VERSION" ]; then
    record_pass "5.1" "deployed filter version $deployed_filter_v matches local repo"
else
    record_fail "5.1" "filter version mismatch (deployed=$deployed_filter_v expected=$EXPECTED_FILTER_VERSION)" \
        "re-run install-runtime.sh as root" \
        "#status-tab-filter--writer-version-mismatch"
fi

if [ "$deployed_writer_v" = "$EXPECTED_WRITER_VERSION" ]; then
    record_pass "5.2" "deployed writer version $deployed_writer_v matches local repo"
else
    record_fail "5.2" "writer version mismatch (deployed=$deployed_writer_v expected=$EXPECTED_WRITER_VERSION)" \
        "re-run claude-write-setup.sh as root" \
        "#status-tab-filter--writer-version-mismatch"
fi

# 5.3 status endpoint reports same versions (soft-fail / skip if Unraid web server unreachable)
status_json=$(ssh_root "curl -s -m 5 'http://localhost/plugins/claude-ssh/include/exec.php?action=status' 2>/dev/null" || true)
if [ -z "$status_json" ]; then
    record_skip "5.3" "Settings/Status endpoint reports versions" "Unraid web server not reachable from localhost on the NAS"
else
    api_filter_v=$(printf '%s' "$status_json" | grep -oE '"filter_version":"[^"]+"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    api_writer_v=$(printf '%s' "$status_json" | grep -oE '"writer_version":"[^"]+"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    if [ "$api_filter_v" = "$EXPECTED_FILTER_VERSION" ] && [ "$api_writer_v" = "$EXPECTED_WRITER_VERSION" ]; then
        record_pass "5.3" "Settings/Status endpoint reports filter=$api_filter_v writer=$api_writer_v"
    else
        record_fail "5.3" "Settings/Status endpoint version mismatch (api: filter=${api_filter_v:-?} writer=${api_writer_v:-?})" \
            "exec.php may be reading the wrong version-marker line" \
            "#status-tab-filter--writer-version-mismatch"
    fi
fi

# ===========================================================================
# Summary
# ===========================================================================

echo
echo "==========================================="
printf '  %d passed · %d failed · %d skipped\n' "$PASS" "$FAIL" "$SKIP"
echo "==========================================="
if [ "$FAIL" -gt 0 ]; then
    echo "FAILED:"
    for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
exit 0
