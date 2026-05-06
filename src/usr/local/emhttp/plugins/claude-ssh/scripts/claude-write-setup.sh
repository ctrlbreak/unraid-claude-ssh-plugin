#!/bin/bash
# =============================================================================
# Unraid: Install the `claude-write` deploy channel
# =============================================================================
# Writer version: v4
# Lets the read-only `claude` SSH user write specific files (hooks, plugin
# assets) to a small set of pre-approved locations on the NAS.
#
# Architecture:
#   /usr/local/bin/claude-write       — thin wrapper, callable by `claude` user
#   /usr/local/sbin/claude-write-priv — privileged writer, root-owned (DIFFERENT
#                                       NAME because Unraid's PATH has sbin BEFORE
#                                       bin, so a same-named priv binary would
#                                       resolve first and shadow the wrapper)
#   /etc/sudoers.d/claude-write       — NOPASSWD rule for `claude` -> privileged
#
# Flow:
#   ssh claude@nas 'claude-write hook-sonarr foo.sh' < hook.sh
#     -> filter v5 validates command + category + basename (claude-shell log)
#     -> bash resolves `claude-write` to /usr/local/bin/claude-write (wrapper)
#     -> wrapper execs `sudo /usr/local/sbin/claude-write-priv hook-sonarr foo.sh`
#     -> sudoers permits exactly that pattern (no shell, no extra args)
#     -> privileged writer re-validates, backs up old file, atomic write,
#        logs WROTE/REJECTED to syslog (claude-write tag)
#
# Run on the NAS as root. Idempotent — safe to re-run.
#
# Invocation modes:
#   - Manual install: copies itself to /boot/config/ and hooks /boot/config/go.
#   - Plugin install: when invoked from /usr/local/emhttp/plugins/<plugin>/,
#     auto-detects and skips self-persistence (plugin manages boot hooks).
# =============================================================================

set -euo pipefail

# Auto-detect plugin invocation (see unraid-readonly-ssh-setup.sh for rationale).
SELF_PATH="$(realpath "$0" 2>/dev/null || echo "$0")"
case "$SELF_PATH" in
    /usr/local/emhttp/plugins/*) PLUGIN_INVOCATION=1 ;;
    *) PLUGIN_INVOCATION=0 ;;
esac

# --- Resolve SSH username (configurable, setup-time only) ----------------
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

WRAPPER_PATH=/usr/local/bin/claude-write
PRIV_PATH=/usr/local/sbin/claude-write-priv
OLD_PRIV_PATH=/usr/local/sbin/claude-write   # leftover from earlier versions
SUDOERS_PATH=/etc/sudoers.d/claude-write
BOOT_BACKUP=/boot/config/claude-write-setup.sh
GO_SCRIPT=/boot/config/go
GO_MARKER="# Claude write deploy channel"

if [ "$EUID" -ne 0 ]; then
    echo "Must run as root" >&2
    exit 1
fi

# --- 0. Clean up old name from earlier versions (PATH-shadowing bug fix) ---
# Earlier versions of this script installed the privileged writer at
# /usr/local/sbin/claude-write. Slackware's PATH puts /usr/local/sbin before
# /usr/local/bin, so `claude-write` typed by the user resolved to the priv
# script directly — bypassing sudo entirely. v6.2 renames the priv script to
# claude-write-priv so the wrapper is the only `claude-write` on PATH.
if [ -e "$OLD_PRIV_PATH" ] && [ "$OLD_PRIV_PATH" != "$WRAPPER_PATH" ]; then
    rm -f "$OLD_PRIV_PATH"
    echo "Removed legacy $OLD_PRIV_PATH (was shadowing the wrapper)"
fi

# --- 1. Wrapper (callable by claude via SSH filter) ---
cat > "$WRAPPER_PATH" << 'WRAPPER'
#!/bin/bash
# Thin wrapper — forwards to privileged /usr/local/sbin/claude-write-priv via sudo.
# Sudoers rule pins exact argv patterns so the wrapper can't be subverted.
exec sudo -n /usr/local/sbin/claude-write-priv "$@"
WRAPPER
chmod 755 "$WRAPPER_PATH"
chown root:root "$WRAPPER_PATH"
echo "Installed wrapper at $WRAPPER_PATH"

# --- 2. Privileged writer ---
cat > "$PRIV_PATH" << 'PRIV'
#!/bin/bash
# =============================================================================
# claude-write — privileged file writer for the read-only `claude` user.
# =============================================================================
# Usage:
#   claude-write <category> <basename>      # content on stdin
#
# Categories map to fixed target directories with allowed extensions and modes.
# Basename is strictly validated to prevent path traversal or hidden files.
# Existing files are backed up to /mnt/cache/appdata/claude-write-backups/ first
# (NOT /boot — flash wear-leveling concerns). Backups are rotated to last 10
# per <category>__<basename>. Writes are atomic (tempfile + rename within
# same directory). Every accept/reject is logged to syslog (tag claude-write,
# auth facility). Stdin reads are bounded by a 30s timeout and a 2 MiB size cap.
# =============================================================================

# Hardened env (v6): explicit PATH, drop loaders that could inject code, drop
# IFS in case something exported a malicious value to the env.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
unset LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT IFS BASH_ENV ENV CDPATH

set -euo pipefail

MAX_SIZE=$((2 * 1024 * 1024))   # 2 MiB cap on stdin content
STDIN_TIMEOUT=30                # seconds; protects against slow-loris stdin
BACKUPS_KEPT=10                 # per category+basename
BACKUP_DIR=/mnt/cache/appdata/claude-write-backups
LOG_TAG=claude-write

reject() {
    local reason="$1"
    logger -t "$LOG_TAG" -p auth.warning "REJECTED [$reason] argv: $*" 2>/dev/null || true
    echo "claude-write: REJECTED — $reason" >&2
    exit 1
}

# v3/v4: plugin- and container-name allowlists read from runtime config (was
# hardcoded in v2; container kind added in v4). Format mirrors the filter
# parser exactly — both must agree on which entries from allowlist.cfg are
# accepted. Default-deny on missing/empty/all-invalid file.
# CLAUDE_SSH_ALLOWLIST_FILE env override is test-only; in production, sudo's
# env_reset strips this var before the writer runs.
ALLOWLIST_FILE="${CLAUDE_SSH_ALLOWLIST_FILE:-/boot/config/plugins/claude-ssh/allowlist.cfg}"

load_allowlist() {
    local kind="$1"
    [ -f "$ALLOWLIST_FILE" ] || return 0
    awk -v k="$kind" 'NF == 2 && $1 == k { print $2 }' "$ALLOWLIST_FILE" \
        | grep -xE '[a-z][a-z0-9-]{0,63}' \
        | sort -u
}

# Audit trap: catch unexpected exits (set -e tripped, signals, etc.) and log
# them so the audit trail isn't silent. Reject path uses exit 1 explicitly,
# which still triggers this trap; that's fine — the reject log already fired.
on_error() {
    local rc=$?
    [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ] && \
        logger -t "$LOG_TAG" -p auth.warning "UNEXPECTED-EXIT rc=$rc line=$BASH_LINENO argv: $0 $*" 2>/dev/null || true
    return 0
}
trap on_error ERR

# --- Parse and validate args (v2: arity depends on category) ---
# Simple: claude-write-priv <cat>             <basename>
# Plugin: claude-write-priv <cat> <plugin>    <basename>
CATEGORY="${1:-}"
[ -n "$CATEGORY" ] || reject "missing category"

# PLUGIN_NAME holds the second-arg value for any 3-arg category — either a
# plugin name (plugin-* categories) or a container name (appdata-script).
# Variable name kept for path-of-least-change; ALLOW_KIND records the
# allowlist kind for the lookup and for the WROTE log field naming.
PLUGIN_NAME=""
ALLOW_KIND=""
case "$CATEGORY" in
    scratch)
        BASENAME="${2:-}"
        EXTRA="${3:-}"
        [ -n "$BASENAME" ] || reject "missing basename"
        [ -z "$EXTRA" ]    || reject "unexpected extra args"
        ;;
    plugin-page|plugin-include|plugin-script|plugin-cfg)
        ALLOW_KIND=plugin
        PLUGIN_NAME="${2:-}"
        BASENAME="${3:-}"
        EXTRA="${4:-}"
        [ -n "$PLUGIN_NAME" ] || reject "missing plugin-name"
        [ -n "$BASENAME" ]    || reject "missing basename"
        [ -z "$EXTRA" ]       || reject "unexpected extra args"
        ;;
    appdata-script)
        ALLOW_KIND=container
        PLUGIN_NAME="${2:-}"
        BASENAME="${3:-}"
        EXTRA="${4:-}"
        [ -n "$PLUGIN_NAME" ] || reject "missing container name"
        [ -n "$BASENAME" ]    || reject "missing basename"
        [ -z "$EXTRA" ]       || reject "unexpected extra args"
        ;;
    *)
        reject "unknown category '$CATEGORY'"
        ;;
esac

# 3-arg categories: validate the target name against its runtime allowlist.
# Default-deny: empty/missing/all-invalid config → loop body never executes
# → target_ok stays 0.
if [ -n "$ALLOW_KIND" ]; then
    target_ok=0
    for p in $(load_allowlist "$ALLOW_KIND"); do
        if [ "$PLUGIN_NAME" = "$p" ]; then target_ok=1; break; fi
    done
    [ "$target_ok" -eq 1 ] || reject "${ALLOW_KIND}-name '$PLUGIN_NAME' not in allowlist"
fi

# Basename: alphanumerics, dot, underscore, hyphen only.
# No leading dot (no hidden files). No path separators.
case "$BASENAME" in
    .*|*/*|*..*) reject "invalid basename '$BASENAME'" ;;
esac
if ! echo "$BASENAME" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$'; then
    reject "basename must match [a-zA-Z0-9._-], 1-128 chars"
fi

# --- Category mapping ---
# Each category resolves to: TARGET_DIR, ALLOWED_EXTS (space-separated), MODE.
case "$CATEGORY" in
    appdata-script)
        # PLUGIN_NAME holds the container name; allowlist already validated above.
        TARGET_DIR=/mnt/user/appdata/$PLUGIN_NAME/scripts
        ALLOWED_EXTS="sh"
        MODE=755
        ;;
    plugin-script)
        TARGET_DIR=/usr/local/emhttp/plugins/$PLUGIN_NAME/scripts
        ALLOWED_EXTS="py sh"
        MODE=755
        ;;
    plugin-page)
        TARGET_DIR=/usr/local/emhttp/plugins/$PLUGIN_NAME
        ALLOWED_EXTS="page"
        MODE=644
        ;;
    plugin-include)
        TARGET_DIR=/usr/local/emhttp/plugins/$PLUGIN_NAME/include
        ALLOWED_EXTS="php sh"
        MODE=644   # overridden to 755 below for .sh
        ;;
    plugin-cfg)
        TARGET_DIR=/usr/local/emhttp/plugins/$PLUGIN_NAME
        ALLOWED_EXTS="cfg"
        MODE=644
        ;;
    scratch)
        # Ephemeral /tmp namespace. No backups, broader extensions, .sh/.py 755.
        TARGET_DIR=/tmp/claude-scratch
        ALLOWED_EXTS="sh py txt json log conf md"
        MODE=644   # overridden to 755 below for .sh / .py
        ;;
esac

# --- Extension check ---
EXT="${BASENAME##*.}"
if [ "$EXT" = "$BASENAME" ]; then
    reject "basename must have extension"
fi
ext_ok=0
for e in $ALLOWED_EXTS; do
    if [ "$EXT" = "$e" ]; then ext_ok=1; break; fi
done
[ "$ext_ok" -eq 1 ] || reject "extension '$EXT' not allowed for $CATEGORY (need: $ALLOWED_EXTS)"

# Promote .sh to 755 inside plugin-include
if [ "$CATEGORY" = "plugin-include" ] && [ "$EXT" = "sh" ]; then
    MODE=755
fi
# Promote .sh / .py to 755 in scratch
if [ "$CATEGORY" = "scratch" ] && { [ "$EXT" = "sh" ] || [ "$EXT" = "py" ]; }; then
    MODE=755
fi

DEST="$TARGET_DIR/$BASENAME"

# --- Read stdin into a tempfile with size cap ---
TMP_INPUT="$(mktemp /tmp/claude-write.XXXXXX)"
TMP_DEST=""
cleanup() {
    rm -f "$TMP_INPUT" 2>/dev/null || true
    [ -n "$TMP_DEST" ] && rm -f "$TMP_DEST" 2>/dev/null || true
}
trap cleanup EXIT

# Read up to MAX_SIZE+1 bytes so we can detect overflow. Bounded by
# STDIN_TIMEOUT to protect against a slow client (slow-loris DoS as root).
# `timeout` exit codes: 124 = timed out, 137 = killed. Anything non-zero ⇒ reject.
if ! timeout "$STDIN_TIMEOUT" head -c "$((MAX_SIZE + 1))" > "$TMP_INPUT"; then
    reject "stdin read failed or timed out (>${STDIN_TIMEOUT}s)"
fi
SIZE_IN=$(stat -c %s "$TMP_INPUT")

[ "$SIZE_IN" -gt 0 ]         || reject "empty stdin"
[ "$SIZE_IN" -le "$MAX_SIZE" ] || reject "content exceeds ${MAX_SIZE}B limit (got $SIZE_IN)"

# --- Backup existing target (with rotation) ---
# Skipped entirely for the scratch category — /tmp is ephemeral by design.
# For plugin-* categories the backup filename includes the plugin-name so two
# plugins with same-named files don't share a rotation slot.
# Note: don't chmod $BACKUP_DIR here — /mnt/user FUSE rejects chmod on existing
# dirs from sudo'd root. Setup script set perms once; we just need the dir present.
TS=$(date +%Y%m%d-%H%M%S)
BACKUP=""
if [ "$CATEGORY" != "scratch" ] && [ -f "$DEST" ]; then
    mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    if [ -n "$PLUGIN_NAME" ]; then
        BACKUP_KEY="${CATEGORY}__${PLUGIN_NAME}__${BASENAME}"
    else
        BACKUP_KEY="${CATEGORY}__${BASENAME}"
    fi
    BACKUP="$BACKUP_DIR/${BACKUP_KEY}.${TS}.bak"
    cp "$DEST" "$BACKUP"
    # Rotate: keep only the most recent BACKUPS_KEPT for this key.
    # Basenames + plugin-names are strictly validated so plain ls is safe.
    ls -t "$BACKUP_DIR/${BACKUP_KEY}".*.bak 2>/dev/null \
        | tail -n "+$((BACKUPS_KEPT + 1))" \
        | xargs -r rm -f
fi

# --- Atomic write (tempfile in target dir, then rename) ---
# Note: we cp through a tempfile in the same dir so the final mv is atomic.
# chown is best-effort: /mnt/user FUSE rejects ownership changes silently in
# some cases, and cp already creates as root (we run as root via sudo).
mkdir -p "$TARGET_DIR" 2>/dev/null || true
TMP_DEST="${DEST}.claude-write.${TS}.tmp"
cp "$TMP_INPUT" "$TMP_DEST"
chmod "$MODE" "$TMP_DEST" || reject "chmod on tempfile failed (FS or perms issue)"
chown root:root "$TMP_DEST" 2>/dev/null || true
mv -f "$TMP_DEST" "$DEST"
TMP_DEST=""   # disarm cleanup for the moved file

# --- Audit log ---
HASH=$(sha256sum "$DEST" | awk '{print $1}')
SIZE=$(stat -c %s "$DEST")
TARGET_FIELD=""
[ -n "$PLUGIN_NAME" ] && TARGET_FIELD=" ${ALLOW_KIND}=$PLUGIN_NAME"
logger -t "$LOG_TAG" -p auth.notice \
    "WROTE category=$CATEGORY${TARGET_FIELD} dest=$DEST size=$SIZE sha256=$HASH backup=${BACKUP:-none}" \
    2>/dev/null || true

# --- Confirmation to caller ---
echo "claude-write: OK"
echo "  category: $CATEGORY"
[ -n "$PLUGIN_NAME" ] && echo "  plugin:   $PLUGIN_NAME"
echo "  dest:     $DEST"
echo "  size:     $SIZE bytes"
echo "  mode:     $MODE"
echo "  sha256:   $HASH"
[ -n "$BACKUP" ] && echo "  backup:   $BACKUP" || echo "  backup:   (no prior file)"
PRIV
chmod 755 "$PRIV_PATH"
chown root:root "$PRIV_PATH"
echo "Installed privileged writer at $PRIV_PATH"

# --- 3. Sudoers rule (with visudo validation) ---
# USERNAME is interpolated into the principal so a non-default SSH user gets
# the right sudo grants. Categories list is fixed (no shell metacharacters
# from $USERNAME — the resolver enforces ^[a-z][a-z0-9-]{0,31}$).
TMP_SUDO=$(mktemp)
cat > "$TMP_SUDO" << SUDO
# Allow the read-only \`$USERNAME\` user to invoke claude-write for specific
# categories only. Each pattern matches the exact argv shape — sudo's wildcard
# \`*\` matches one whole argument, blocking extra-args injection. The privileged
# script re-validates everything as defence in depth.
#
# v9: plugin-* and appdata-script take a 2nd-arg target (* *). The simple
# scratch category keeps its 2-arg shape. (hook-sonarr/hook-radarr removed in
# v9 — replaced by appdata-script <container>.)
$USERNAME ALL=(root) NOPASSWD: /usr/local/sbin/claude-write-priv scratch *, /usr/local/sbin/claude-write-priv plugin-script * *, /usr/local/sbin/claude-write-priv plugin-page * *, /usr/local/sbin/claude-write-priv plugin-include * *, /usr/local/sbin/claude-write-priv plugin-cfg * *, /usr/local/sbin/claude-write-priv appdata-script * *
SUDO

# Validate before installing
if ! visudo -c -f "$TMP_SUDO" >/dev/null 2>&1; then
    echo "ERROR: sudoers rule failed validation:" >&2
    visudo -c -f "$TMP_SUDO"
    rm -f "$TMP_SUDO"
    exit 1
fi

# Check if /etc/sudoers.d/ is honoured (most modern sudo configs include it)
if grep -qE '^[[:space:]]*#includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers \
   || grep -qE '^[[:space:]]*@includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers; then
    install -m 440 -o root -g root "$TMP_SUDO" "$SUDOERS_PATH"
    echo "Installed sudoers rule at $SUDOERS_PATH"
else
    # Fallback: append to /etc/sudoers directly with a marker so we can update
    SUDO_MARKER="# claude-write deploy channel — managed by claude-write-setup.sh"
    if grep -q "$SUDO_MARKER" /etc/sudoers; then
        # Replace existing block (between marker and END marker)
        sed -i "/$SUDO_MARKER/,/# END claude-write/d" /etc/sudoers
    fi
    {
        echo ""
        echo "$SUDO_MARKER"
        cat "$TMP_SUDO"
        echo "# END claude-write"
    } >> /etc/sudoers
    # Re-validate full file
    if ! visudo -c -f /etc/sudoers >/dev/null 2>&1; then
        echo "ERROR: /etc/sudoers failed validation after edit — manual fix needed" >&2
        exit 1
    fi
    echo "Appended sudoers rule to /etc/sudoers (no sudoers.d include found)"
fi
rm -f "$TMP_SUDO"

# --- 4. Persist on flash for boot ---
# Skip when running under the plugin — install-runtime.sh manages boot hooks.
if [ "$PLUGIN_INVOCATION" -eq 1 ]; then
    echo "Plugin invocation detected — skipping /boot/config/ self-persist."
else
    if [ "$SELF_PATH" != "$BOOT_BACKUP" ]; then
        cp "$SELF_PATH" "$BOOT_BACKUP"
        chmod 755 "$BOOT_BACKUP"
    fi

    if ! grep -q "$GO_MARKER" "$GO_SCRIPT" 2>/dev/null; then
        cat >> "$GO_SCRIPT" << GOSCRIPT

$GO_MARKER
bash $BOOT_BACKUP
GOSCRIPT
        echo "Added boot persistence to $GO_SCRIPT"
    else
        echo "Boot persistence already configured in $GO_SCRIPT"
    fi
fi

# --- 5. Backup dir (on array, NOT flash — wear-leveling) ---
mkdir -p /mnt/cache/appdata/claude-write-backups
chown root:root /mnt/cache/appdata/claude-write-backups
chmod 750 /mnt/cache/appdata/claude-write-backups

echo ""
echo "=========================================="
echo "  claude-write deploy channel installed"
echo "=========================================="
echo ""
echo "Categories (v9):"
echo "  Simple — claude-write <cat> <basename>:"
echo "    scratch         -> /tmp/claude-scratch/               (.sh .py .txt .json .log .conf .md)"
echo ""
echo "  Plugin — claude-write <cat> <plugin-name> <basename>"
echo "    (allowlist: 'plugin <name>' lines in /boot/config/plugins/claude-ssh/allowlist.cfg)"
echo "    plugin-script   -> /usr/local/emhttp/plugins/<plugin>/scripts/  (.py .sh, 755)"
echo "    plugin-page     -> /usr/local/emhttp/plugins/<plugin>/          (.page, 644)"
echo "    plugin-include  -> /usr/local/emhttp/plugins/<plugin>/include/  (.php .sh)"
echo "    plugin-cfg      -> /usr/local/emhttp/plugins/<plugin>/          (.cfg, 644)"
echo ""
echo "  Container — claude-write <cat> <container> <basename>"
echo "    (allowlist: 'container <name>' lines in /boot/config/plugins/claude-ssh/allowlist.cfg)"
echo "    appdata-script  -> /mnt/user/appdata/<container>/scripts/       (.sh, 755)"
echo ""
echo "Both allowlists default-deny when empty. Edit allowlist.cfg to enable."
echo ""
echo "Usage from a workstation:"
echo "  cat my-hook.sh \\"
echo "    | ssh -i ~/.ssh/${USERNAME}_unraid $USERNAME@nas \\"
echo "      'claude-write appdata-script sonarr my-hook.sh'"
echo ""
echo "  cat my-plugin/src/.../Foo.page \\"
echo "    | ssh -i ~/.ssh/${USERNAME}_unraid $USERNAME@nas \\"
echo "      'claude-write plugin-page my-plugin Foo.page'"
echo ""
echo "Audit log:"
echo "  grep claude-write /var/log/syslog"
echo ""
echo "NEXT: redeploy unraid-readonly-ssh-setup.sh (filter v9 matches writer v4)"
