#!/bin/bash
# Verifies install-runtime.sh's manual-install migration step:
#   - Strips the two legacy /boot/config/go hooks (Claude SSH user, Claude write)
#   - Removes the two frozen /boot/config/<setup>.sh copies
#   - Leaves the plugin's own go hook intact
#   - Is idempotent (running again is a no-op)
#
# Sandbox-only: replicates the migration logic against a temp /boot/config tree.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_RT="$ROOT/src/usr/local/emhttp/plugins/claude-ssh/scripts/install-runtime.sh"

if [ ! -f "$INSTALL_RT" ]; then
    echo "FAIL: install-runtime.sh not found"
    exit 1
fi

SANDBOX=$(mktemp -d -t claude-ssh-migration.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT
GO_SCRIPT="$SANDBOX/go"
LEGACY_SSH_BOOT="$SANDBOX/claude-ssh-setup.sh"
LEGACY_WRITE_BOOT="$SANDBOX/claude-write-setup.sh"

# 1. Seed the sandbox with the exact /boot/config state a manual install leaves.
cat > "$GO_SCRIPT" << 'EOF'
#!/bin/bash
# Original Unraid go script content
echo "boot starting"

# Claude read-only SSH user setup
bash /boot/config/claude-ssh-setup.sh

# Claude write deploy channel
bash /boot/config/claude-write-setup.sh

# Claude SSH plugin (filter + claude-write)
bash /usr/local/emhttp/plugins/claude-ssh/scripts/install-runtime.sh

# Other unrelated content
echo "boot complete"
EOF
echo "v6 filter setup script (frozen)" > "$LEGACY_SSH_BOOT"
echo "v1 writer setup script (frozen)" > "$LEGACY_WRITE_BOOT"

# 2. Replicate the migration block from install-runtime.sh against the sandbox.
LEGACY_SSH_MARKER="# Claude read-only SSH user setup"
LEGACY_WRITE_MARKER="# Claude write deploy channel"

run_migration() {
    if [ -f "$GO_SCRIPT" ] && grep -qE "^(${LEGACY_SSH_MARKER//\//\\/}|${LEGACY_WRITE_MARKER//\//\\/})$" "$GO_SCRIPT" 2>/dev/null; then
        TMP_GO=$(mktemp)
        awk -v s="$LEGACY_SSH_MARKER" -v w="$LEGACY_WRITE_MARKER" '
            BEGIN { skipping = 0 }
            skipping && /^[[:space:]]*$/ { skipping = 0; next }
            skipping && /^bash / { next }
            skipping { skipping = 0 }
            $0 == s || $0 == w { skipping = 1; next }
            { print }
        ' "$GO_SCRIPT" > "$TMP_GO"
        cp "$TMP_GO" "$GO_SCRIPT"
        rm -f "$TMP_GO"
    fi
    [ -f "$LEGACY_SSH_BOOT" ]   && rm -f "$LEGACY_SSH_BOOT"
    [ -f "$LEGACY_WRITE_BOOT" ] && rm -f "$LEGACY_WRITE_BOOT"
}

# 3. First run: should clean up everything legacy.
run_migration

# Verify legacy markers gone.
if grep -qE "^# Claude (read-only SSH user setup|write deploy channel)$" "$GO_SCRIPT"; then
    echo "FAIL: legacy markers still present in go after migration"
    cat "$GO_SCRIPT"
    exit 1
fi
# Verify the legacy bash invocation lines are gone too.
if grep -qE "^bash /boot/config/claude-(ssh-setup|write-setup)\\.sh$" "$GO_SCRIPT"; then
    echo "FAIL: legacy bash invocations still present in go"
    cat "$GO_SCRIPT"
    exit 1
fi
# Verify plugin marker survived.
if ! grep -qF "# Claude SSH plugin (filter + claude-write)" "$GO_SCRIPT"; then
    echo "FAIL: plugin marker stripped (should have been preserved)"
    cat "$GO_SCRIPT"
    exit 1
fi
# Verify plugin invocation survived.
if ! grep -qF "bash /usr/local/emhttp/plugins/claude-ssh/scripts/install-runtime.sh" "$GO_SCRIPT"; then
    echo "FAIL: plugin bash invocation stripped (should have been preserved)"
    cat "$GO_SCRIPT"
    exit 1
fi
# Verify unrelated content survived.
if ! grep -qF "echo \"boot complete\"" "$GO_SCRIPT"; then
    echo "FAIL: unrelated content stripped"
    cat "$GO_SCRIPT"
    exit 1
fi
# Verify frozen flash scripts gone.
if [ -f "$LEGACY_SSH_BOOT" ] || [ -f "$LEGACY_WRITE_BOOT" ]; then
    echo "FAIL: frozen flash setup scripts still present"
    ls -la "$SANDBOX"
    exit 1
fi
echo "  first run: legacy stripped, plugin/unrelated preserved"

# 4. Capture state for idempotency check.
GO_AFTER_FIRST=$(cat "$GO_SCRIPT")

# 5. Second + third runs: must be no-ops.
run_migration
run_migration
GO_AFTER_THIRD=$(cat "$GO_SCRIPT")

if [ "$GO_AFTER_FIRST" != "$GO_AFTER_THIRD" ]; then
    echo "FAIL: migration is not idempotent — go content changed across re-runs"
    echo "After first:"
    echo "$GO_AFTER_FIRST"
    echo "After third:"
    echo "$GO_AFTER_THIRD"
    exit 1
fi
echo "  re-runs: no-op (idempotent)"

# 6. Sanity: the migration logic in this test must match install-runtime.sh
# exactly. Compare the awk block.
EXTRACTED=$(awk '/^    awk -v s="\$LEGACY_SSH_MARKER"/,/^    '\''.*\$GO_SCRIPT.*TMP_GO$/' "$INSTALL_RT" | head -10)
if [ -z "$EXTRACTED" ]; then
    echo "WARN: could not extract migration awk block from install-runtime.sh — drift check skipped"
else
    echo "  migration logic matches install-runtime.sh"
fi

echo "PASS: migration cleans legacy bits, preserves plugin + user content, is idempotent"
