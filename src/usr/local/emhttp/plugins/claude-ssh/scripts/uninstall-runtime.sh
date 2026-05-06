#!/bin/bash
# =============================================================================
# claude-ssh plugin — runtime uninstaller
# =============================================================================
# Called by claude-ssh.plg on plugin remove. Non-destructive by default:
# tears down runtime artifacts but PRESERVES the claude user, /home/claude/
# (authorized_keys), and /mnt/cache/appdata/claude-write-backups/.
#
# To fully purge after this runs:
#   userdel claude
#   rm -rf /home/claude
#   rm -rf /mnt/cache/appdata/claude-write-backups
# =============================================================================

set -uo pipefail   # not -e — best-effort cleanup; some files may already be gone

GO_SCRIPT="/boot/config/go"
PLUGIN_MARKER="# Claude SSH plugin (filter + claude-write)"
LEGACY_SSH_MARKER="# Claude read-only SSH user setup"
LEGACY_WRITE_MARKER="# Claude write deploy channel"
SUDOERS_PATH=/etc/sudoers.d/claude-write
LOG_TAG="claude-ssh-plugin"

log() {
    logger -t "$LOG_TAG" -p auth.info "$*" 2>/dev/null || true
    echo "[claude-ssh] $*"
}

if [ "$EUID" -ne 0 ]; then
    echo "Must run as root" >&2
    exit 1
fi

log "uninstall-runtime.sh starting"

# --- 1. Strip /boot/config/go hook (plugin's marker + legacy markers) ---
if [ -f "$GO_SCRIPT" ]; then
    TMP_GO=$(mktemp)
    # Remove any block headed by one of our markers and the line(s) that follow,
    # up to the next blank line or marker. Conservative: only strip exact matches.
    awk -v p="$PLUGIN_MARKER" -v s="$LEGACY_SSH_MARKER" -v w="$LEGACY_WRITE_MARKER" '
        BEGIN { skipping = 0 }
        # End the skip block at a blank line or a new comment that is not our marker
        skipping && /^[[:space:]]*$/ { skipping = 0; next }
        # When skipping, drop the bash invocation line that follows the marker
        skipping && /^bash / { next }
        skipping { skipping = 0 }
        # Detect markers — drop the marker line and start skipping the next line
        $0 == p || $0 == s || $0 == w { skipping = 1; next }
        { print }
    ' "$GO_SCRIPT" > "$TMP_GO"
    if ! cmp -s "$GO_SCRIPT" "$TMP_GO"; then
        cp "$TMP_GO" "$GO_SCRIPT"
        log "stripped claude-ssh hooks from /boot/config/go"
    else
        log "/boot/config/go had no claude-ssh hooks"
    fi
    rm -f "$TMP_GO"
fi

# --- 2. Remove the legacy boot-persisted setup scripts (no longer the source of truth) ---
for f in /boot/config/claude-ssh-setup.sh /boot/config/claude-write-setup.sh; do
    if [ -f "$f" ]; then
        rm -f "$f"
        log "removed legacy $f"
    fi
done

# --- 3. Remove sudoers fragment ---
if [ -f "$SUDOERS_PATH" ]; then
    rm -f "$SUDOERS_PATH"
    log "removed $SUDOERS_PATH"
fi
# Strip claude-write block from main /etc/sudoers if it was appended there.
if grep -q "claude-write deploy channel — managed by claude-write-setup.sh" /etc/sudoers 2>/dev/null; then
    sed -i '/# claude-write deploy channel — managed by claude-write-setup\.sh/,/# END claude-write/d' /etc/sudoers
    log "stripped claude-write block from /etc/sudoers"
fi

# --- 4. Remove writer binaries ---
for f in /usr/local/bin/claude-write /usr/local/sbin/claude-write-priv /usr/local/sbin/claude-write; do
    if [ -e "$f" ]; then
        rm -f "$f"
        log "removed $f"
    fi
done

# --- 5. Strip AllowUsers claude from sshd_config ---
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CHANGED=0
for cfg in "$SSHD_CONFIG" /boot/config/ssh/sshd_config; do
    [ -f "$cfg" ] || continue
    if grep -qE "^AllowUsers.*\bclaude\b" "$cfg"; then
        # If `claude` is the only user in AllowUsers, drop the whole line.
        # Otherwise just remove the token.
        if grep -qE "^AllowUsers[[:space:]]+claude[[:space:]]*$" "$cfg"; then
            sed -i '/^AllowUsers[[:space:]]\+claude[[:space:]]*$/d' "$cfg"
        else
            sed -i 's/\(^AllowUsers.*\)[[:space:]]\+claude\b/\1/' "$cfg"
        fi
        log "stripped 'claude' from AllowUsers in $cfg"
        [ "$cfg" = "$SSHD_CONFIG" ] && SSHD_CHANGED=1
    fi
done
if [ "$SSHD_CHANGED" -eq 1 ]; then
    /etc/rc.d/rc.sshd restart 2>/dev/null || log "sshd restart failed (will pick up on next boot)"
fi

# --- 6. Final message ---
log "uninstall-runtime.sh complete"
log "PRESERVED: /home/claude (authorized_keys), claude user, claude-write-backups"
log "To fully purge: userdel claude && rm -rf /home/claude /mnt/cache/appdata/claude-write-backups"
