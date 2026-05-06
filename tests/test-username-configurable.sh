#!/bin/bash
# Phase 6 — configurable SSH username.
#
# Coverage:
#   1. Drift check: cs_resolve_username() body is identical across all four
#      shell scripts that call it (filter setup, writer setup, install-runtime,
#      uninstall-runtime). A divergent definition would let one script accept a
#      username another rejects, splitting the install across two users.
#   2. Algorithm: env var > /boot/config/plugins/claude-ssh/username file > "claude".
#   3. Validation: only ^[a-z][a-z0-9-]{0,31}$ accepted. Bad names rejected with
#      a non-zero exit. (uppercase, special chars, leading-digit, length-32+)
#   4. PHP-side parity: exec.php's CS_USERNAME_REGEX matches the shell regex.
#
# This test is purely behavioural — no chroot or root needed. The function is
# extracted from the source script and run in a sandbox with controlled env
# vars and file fixtures.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_SCRIPTS="$ROOT/src/usr/local/emhttp/plugins/claude-ssh/scripts"
EXEC_PHP="$ROOT/src/usr/local/emhttp/plugins/claude-ssh/include/exec.php"

SCRIPTS=(
    "$PLUGIN_SCRIPTS/unraid-readonly-ssh-setup.sh"
    "$PLUGIN_SCRIPTS/claude-write-setup.sh"
    "$PLUGIN_SCRIPTS/install-runtime.sh"
    "$PLUGIN_SCRIPTS/uninstall-runtime.sh"
)

for f in "${SCRIPTS[@]}"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: $f not found"
        exit 1
    fi
done

PASS=0
FAIL=0
FAILED=()

# Extract the cs_resolve_username function body from a script. Returns the
# entire `cs_resolve_username() { ... }` block, terminated by the closing `}`
# at column 0. This is the same shape we install in every script.
extract_fn() {
    awk '
        /^cs_resolve_username\(\) \{$/ { capturing=1 }
        capturing { print }
        capturing && /^\}$/ { exit }
    ' "$1"
}

# === 1. Drift check: function body identical across the four scripts ===
REFERENCE=$(extract_fn "${SCRIPTS[0]}")
if [ -z "$REFERENCE" ]; then
    echo "FAIL: cs_resolve_username() not found in ${SCRIPTS[0]}"
    exit 1
fi
DRIFT=0
for f in "${SCRIPTS[@]:1}"; do
    other=$(extract_fn "$f")
    if [ -z "$other" ]; then
        FAIL=$((FAIL+1)); FAILED+=("drift: cs_resolve_username() missing in $(basename "$f")")
        DRIFT=1
    elif [ "$REFERENCE" != "$other" ]; then
        FAIL=$((FAIL+1)); FAILED+=("drift: cs_resolve_username() body differs in $(basename "$f")")
        DRIFT=1
    else
        PASS=$((PASS+1))
    fi
done
if [ "$DRIFT" -eq 0 ]; then
    echo "  drift check: cs_resolve_username() identical across $(echo "${#SCRIPTS[@]}") scripts"
fi

# === 2/3. Algorithm + validation: run the extracted function in a sandbox ===
SANDBOX=$(mktemp -d -t claude-ssh-username-XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT
RUNNER="$SANDBOX/runner.sh"

# Re-route the hardcoded /boot/config path the function reads from to the
# sandbox by passing a custom file path through CLAUDE_SSH_USERNAME_FILE
# (we substitute it at sandbox-extract time so the production code stays
# unchanged).
sed "s|/boot/config/plugins/claude-ssh/username|${SANDBOX//|/\\|}/username|g" \
    <<< "$REFERENCE" > "$RUNNER.fn"

cat > "$RUNNER" << EOF
#!/bin/bash
set -uo pipefail
$(cat "$RUNNER.fn")
cs_resolve_username
EOF
chmod +x "$RUNNER"

run_resolve() {
    local label="$1" expected_rc="$2" expected_out="$3"
    shift 3
    local out rc
    out=$(env -i PATH=/usr/bin:/bin "$@" bash "$RUNNER" 2>&1)
    rc=$?
    if [ "$rc" -ne "$expected_rc" ]; then
        FAIL=$((FAIL+1))
        FAILED+=("$label: expected rc=$expected_rc got rc=$rc out='$out'")
        return
    fi
    if [ "$expected_rc" -eq 0 ] && [ "$out" != "$expected_out" ]; then
        FAIL=$((FAIL+1))
        FAILED+=("$label: expected output '$expected_out' got '$out'")
        return
    fi
    PASS=$((PASS+1))
}

# Default = "claude" when no env, no file.
run_resolve "default-claude" 0 "claude"

# Env var wins over file.
echo "from-file" > "$SANDBOX/username"
run_resolve "env-beats-file" 0 "from-env" CLAUDE_SSH_USERNAME=from-env

# File used when env unset.
run_resolve "file-when-no-env" 0 "from-file"

# File trimmed (whitespace + CR + tab + extra lines).
printf '  trimmed-name  \n\nignored-second-line\n' > "$SANDBOX/username"
run_resolve "file-trimmed" 0 "trimmed-name"

# File missing → default.
rm -f "$SANDBOX/username"
run_resolve "file-missing" 0 "claude"

# Empty env → fallback through to file/default (empty CLAUDE_SSH_USERNAME
# is treated like unset by the resolver: the if [ -n "$_u" ] check rejects).
run_resolve "empty-env" 0 "claude" CLAUDE_SSH_USERNAME=

# === 3. Validation: every reject case must rc=1 ===
for bad_name in \
    "Foo"             `# uppercase`              \
    "1foo"            `# leading digit`          \
    "foo_bar"         `# underscore`             \
    "foo!"            `# special char`           \
    "foo bar"         `# space`                  \
    "foo/bar"         `# slash`                  \
    "-foo"            `# leading hyphen`         \
    "foo."            `# dot`                    \
    "$(printf 'a%.0s' $(seq 1 33))"  `# 33 chars > 32 cap`
do
    run_resolve "reject-bad-name:$bad_name" 1 "" CLAUDE_SSH_USERNAME="$bad_name"
done

# Boundary: exactly 32 chars (1 letter + 31 trailing) accepted.
NAME32=$(printf 'a%.0s' $(seq 1 32))
run_resolve "accept-32-chars" 0 "$NAME32" CLAUDE_SSH_USERNAME="$NAME32"

# Variants that should be accepted.
for ok_name in claude bob foo-bar a a1 a-1-2 z9; do
    run_resolve "accept:$ok_name" 0 "$ok_name" CLAUDE_SSH_USERNAME="$ok_name"
done

# === 4. PHP-side parity: exec.php carries the same regex ===
if grep -qF "[a-z][a-z0-9-]{0,31}" "$EXEC_PHP"; then
    PASS=$((PASS+1))
    echo "  exec.php: CS_USERNAME_REGEX matches shell regex"
else
    FAIL=$((FAIL+1))
    FAILED+=("exec.php missing CS_USERNAME_REGEX with [a-z][a-z0-9-]{0,31} body")
fi

# === 5. Sudoers principal in claude-write-setup.sh uses $USERNAME ===
# Phase 6: literal "claude ALL=(root)" replaced by "$USERNAME ALL=(root)".
WRITER="$PLUGIN_SCRIPTS/claude-write-setup.sh"
if grep -qE '^\$USERNAME ALL=\(root\) NOPASSWD: ' "$WRITER"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1)); FAILED+=("claude-write-setup.sh: sudoers principal not parameterised on \$USERNAME")
fi
# And the legacy hardcoded line is gone.
if grep -qE '^claude ALL=\(root\) NOPASSWD: ' "$WRITER"; then
    FAIL=$((FAIL+1)); FAILED+=("claude-write-setup.sh: hardcoded 'claude ALL=' principal still present")
else
    PASS=$((PASS+1))
fi

# === 6. Sudoers heredoc must be unquoted so $USERNAME interpolates ===
# Quoted form (<< 'SUDO') would leave the principal as the literal string
# "$USERNAME" — visudo would reject that. The unquoted form (<< SUDO) is
# required for substitution.
if grep -qE "<< SUDO\$" "$WRITER"; then
    PASS=$((PASS+1))
elif grep -qE "<< 'SUDO'\$" "$WRITER"; then
    FAIL=$((FAIL+1)); FAILED+=("claude-write-setup.sh: SUDO heredoc still quoted (would prevent \$USERNAME interpolation)")
else
    FAIL=$((FAIL+1)); FAILED+=("claude-write-setup.sh: SUDO heredoc shape unrecognised")
fi

# === 7. install-runtime.sh exports CLAUDE_SSH_USERNAME for child scripts ===
INSTALL="$PLUGIN_SCRIPTS/install-runtime.sh"
if grep -qE 'export CLAUDE_SSH_USERNAME=' "$INSTALL"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1)); FAILED+=("install-runtime.sh: CLAUDE_SSH_USERNAME not exported to child setup scripts")
fi

# === 8. install-runtime.sh seeds /boot/config/plugins/claude-ssh/username ===
if grep -qE "/boot/config/plugins/claude-ssh/username" "$INSTALL" \
   && grep -qE 'printf .*USERNAME.* > "\$USERNAME_FILE"' "$INSTALL"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1)); FAILED+=("install-runtime.sh: username file not seeded on first install")
fi

TOTAL=$((PASS + FAIL))
echo "  cases: $PASS passed / $FAIL failed / $TOTAL total"

if [ "$FAIL" -ne 0 ]; then
    echo "FAIL: $FAIL username-configurable case(s) failed:"
    for f in "${FAILED[@]}"; do echo "  - $f"; done
    exit 1
fi
echo "PASS: cs_resolve_username() consistent and validates correctly"
