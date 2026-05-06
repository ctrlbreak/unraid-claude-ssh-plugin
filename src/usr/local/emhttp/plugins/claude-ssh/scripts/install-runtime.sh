#!/bin/bash
# =============================================================================
# claude-ssh plugin — runtime installer
# =============================================================================
# Called by claude-ssh.plg on plugin install/upgrade and from /boot/config/go
# at every boot. Idempotent: safe to re-run.
#
# Responsibilities:
#   1. Run the SSH user + filter setup script (auto-detected as plugin-invoked,
#      so it skips its own /boot/config self-persist).
#   2. Run the claude-write writer + sudoers setup script (same auto-detection).
#   3. Add a single hook to /boot/config/go that re-runs THIS script on boot.
#   4. Smoke-test: confirm user exists, filter present, writer present.
# =============================================================================

set -euo pipefail

PLUGIN_DIR="/usr/local/emhttp/plugins/claude-ssh"
SCRIPTS_DIR="${PLUGIN_DIR}/scripts"
GO_SCRIPT="/boot/config/go"
GO_MARKER="# Claude SSH plugin (filter + claude-write)"
LOG_TAG="claude-ssh-plugin"

log() {
    logger -t "$LOG_TAG" -p auth.info "$*" 2>/dev/null || true
    echo "[claude-ssh] $*"
}

if [ "$EUID" -ne 0 ]; then
    echo "Must run as root" >&2
    exit 1
fi

log "install-runtime.sh starting"

# --- 0. Resolve and persist SSH username (configurable, setup-time only) ---
# See unraid-readonly-ssh-setup.sh for the canonical comment block. This is a
# verbatim duplicate; test-username-configurable.sh enforces drift checks.
cs_resolve_username() {
    local _u="" _file="/boot/config/plugins/claude-ssh/username"
    if [ -n "${CLAUDE_SSH_USERNAME:-}" ]; then
        _u="$CLAUDE_SSH_USERNAME"
    elif [ -f "$_file" ]; then
        _u=$(head -n1 "$_file" 2>/dev/null | tr -d ' \t\r\n')
    fi
    [ -z "$_u" ] && _u="claude"
    if ! echo "$_u" | grep -qE '^[a-z][a-z0-9-]{0,31}$'; then
        echo "ERROR: invalid SSH username '$_u' (must match ^[a-z][a-z0-9-]{0,31}\$)" >&2
        return 1
    fi
    printf '%s\n' "$_u"
}
USERNAME=$(cs_resolve_username) || exit 1
export CLAUDE_SSH_USERNAME="$USERNAME"
log "resolved SSH username = $USERNAME"

# Persist on first install so subsequent reboots resolve the same name even
# without the env var. Never overwrite an existing file (preserves explicit
# user choice, including changes made between installs).
USERNAME_DIR="/boot/config/plugins/claude-ssh"
USERNAME_FILE="$USERNAME_DIR/username"
if [ ! -d "$USERNAME_DIR" ]; then
    mkdir -p "$USERNAME_DIR"
fi
if [ ! -f "$USERNAME_FILE" ]; then
    printf '%s\n' "$USERNAME" > "$USERNAME_FILE"
    chmod 644 "$USERNAME_FILE"
    log "seeded $USERNAME_FILE = $USERNAME"
fi

# --- 1. Run the SSH user + filter setup ---
if [ ! -x "${SCRIPTS_DIR}/unraid-readonly-ssh-setup.sh" ]; then
    log "ERROR: ${SCRIPTS_DIR}/unraid-readonly-ssh-setup.sh missing or not executable"
    exit 1
fi
log "running unraid-readonly-ssh-setup.sh"
bash "${SCRIPTS_DIR}/unraid-readonly-ssh-setup.sh"

# --- 2. Run the claude-write setup ---
if [ ! -x "${SCRIPTS_DIR}/claude-write-setup.sh" ]; then
    log "ERROR: ${SCRIPTS_DIR}/claude-write-setup.sh missing or not executable"
    exit 1
fi
log "running claude-write-setup.sh"
bash "${SCRIPTS_DIR}/claude-write-setup.sh"

# --- 2.5. Bootstrap allowlist.cfg (runtime config for plugin-name allowlist) ---
# Default-deny is the design: no plugin-* writes succeed until the user adds
# an entry. We seed a commented template on first install so the file exists
# and shows the format. Existing files are NEVER overwritten — preserves any
# entries the user has populated via Settings UI or by editing directly.
ALLOWLIST_DIR="/boot/config/plugins/claude-ssh"
ALLOWLIST_FILE="${ALLOWLIST_DIR}/allowlist.cfg"
if [ ! -d "$ALLOWLIST_DIR" ]; then
    mkdir -p "$ALLOWLIST_DIR"
    log "created ${ALLOWLIST_DIR}"
fi
if [ ! -f "$ALLOWLIST_FILE" ]; then
    cat > "$ALLOWLIST_FILE" << 'ALLOWLIST'
# claude-ssh allowlist — runtime config for the claude-write deploy channel.
#
# Controls which plugins and containers the SSH user is allowed to write
# into. Both the SSH filter and the privileged writer read this file
# on every invocation; default-deny when empty or malformed.
#
# Format:
#   plugin <name>      Allow claude-write plugin-page/plugin-include/
#                      plugin-script/plugin-cfg writes for /usr/local/emhttp/
#                      plugins/<name>/.
#   container <name>   Allow claude-write appdata-script writes for
#                      /mnt/user/appdata/<name>/scripts/.
#
# Names must match: ^[a-z][a-z0-9-]{0,63}$  (lowercase, digits, hyphen)
# Comments start with #. Blank lines ignored. Invalid entries dropped silently.
#
# Examples (uncomment to enable):
# plugin torrent-handler
# plugin claude-ssh
# container sonarr
# container radarr
ALLOWLIST
    chmod 644 "$ALLOWLIST_FILE"
    log "seeded ${ALLOWLIST_FILE} (default-deny — uncomment entries to enable)"
fi

# --- 3. Boot hook in /boot/config/go ---
# Single entry that re-runs this installer on every boot. The setup scripts
# are idempotent so re-running is cheap (~few seconds), and this avoids the
# dual /boot/config/go entries the standalone scripts would otherwise add.
if ! grep -q "$GO_MARKER" "$GO_SCRIPT" 2>/dev/null; then
    cat >> "$GO_SCRIPT" << GOSCRIPT

$GO_MARKER
bash ${SCRIPTS_DIR}/install-runtime.sh
GOSCRIPT
    log "added /boot/config/go hook"
else
    log "/boot/config/go hook already present"
fi

# --- 4. Smoke tests ---
SMOKE_FAILED=0
if ! id "$USERNAME" >/dev/null 2>&1; then
    log "SMOKE FAIL: user '$USERNAME' does not exist"
    SMOKE_FAILED=1
fi
if [ ! -f "/home/$USERNAME/shell-filter.sh" ]; then
    log "SMOKE FAIL: /home/$USERNAME/shell-filter.sh missing"
    SMOKE_FAILED=1
fi
if [ ! -x /usr/local/bin/claude-write ]; then
    log "SMOKE FAIL: /usr/local/bin/claude-write missing"
    SMOKE_FAILED=1
fi
if [ ! -x /usr/local/sbin/claude-write-priv ]; then
    log "SMOKE FAIL: /usr/local/sbin/claude-write-priv missing"
    SMOKE_FAILED=1
fi
if [ ! -f /etc/sudoers.d/claude-write ] && ! grep -q "^$USERNAME ALL=" /etc/sudoers 2>/dev/null; then
    log "SMOKE FAIL: claude-write sudoers rule not installed"
    SMOKE_FAILED=1
fi

if [ "$SMOKE_FAILED" -ne 0 ]; then
    log "install-runtime.sh: smoke tests FAILED — see above"
    exit 1
fi
log "install-runtime.sh: smoke tests passed"

# --- 5. Migrate from a manual install (one-shot, idempotent) ---
# If the box was previously set up by running the two scripts in scripts/
# directly, /boot/config/ has frozen copies of those scripts and /boot/config/go
# has hooks that re-run them on every boot. With the plugin in charge, those
# legacy artifacts re-deploy stale v6/v1 logic on every reboot and the plugin
# hook then corrects it — eventually consistent, but ugly. Strip them here.
#
# This runs AFTER smoke tests so a failed setup can't leave the box in a
# half-migrated state (legacy gone but new bits broken).
LEGACY_SSH_BOOT=/boot/config/claude-ssh-setup.sh
LEGACY_WRITE_BOOT=/boot/config/claude-write-setup.sh
LEGACY_SSH_MARKER="# Claude read-only SSH user setup"
LEGACY_WRITE_MARKER="# Claude write deploy channel"

migrated=0
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
    if ! cmp -s "$GO_SCRIPT" "$TMP_GO"; then
        cp "$TMP_GO" "$GO_SCRIPT"
        log "migrated: stripped legacy hooks from /boot/config/go"
        migrated=1
    fi
    rm -f "$TMP_GO"
fi
for f in "$LEGACY_SSH_BOOT" "$LEGACY_WRITE_BOOT"; do
    if [ -f "$f" ]; then
        rm -f "$f"
        log "migrated: removed legacy $f"
        migrated=1
    fi
done
if [ "$migrated" -eq 1 ]; then
    log "migration from manual install complete — /boot/config/go now has only the plugin hook"
fi

log "install-runtime.sh complete"
