#!/bin/bash
# =============================================================================
# Unraid: Create a read-only SSH user for Claude Code
# =============================================================================
# Filter version: v8
# Uses authorized_keys command= restriction to force all SSH commands through
# a filter script. Simpler and more secure than rbash — single enforcement
# point that blocks destructive commands, dangerous flags, and shell tricks.
#
# Run this ON your Unraid server as root.
# Idempotent — safe to re-run.
#
# Invocation modes:
#   - Manual install: copies itself to /boot/config/ and hooks /boot/config/go.
#   - Plugin install: when invoked from /usr/local/emhttp/plugins/<plugin>/,
#     auto-detects and skips self-persistence (the plugin's install-runtime.sh
#     manages /boot/config/go entries itself).
# =============================================================================

set -euo pipefail

USERNAME="claude"
HOME_DIR="/home/$USERNAME"
FILTER_SCRIPT="$HOME_DIR/shell-filter.sh"

# Auto-detect plugin invocation: skip /boot/config/ self-persist when running
# from inside a plugin path. The plugin's install-runtime.sh handles boot
# hooks separately, so two scripts don't fight over /boot/config/go entries.
SELF_PATH="$(realpath "$0" 2>/dev/null || echo "$0")"
case "$SELF_PATH" in
    /usr/local/emhttp/plugins/*) PLUGIN_INVOCATION=1 ;;
    *) PLUGIN_INVOCATION=0 ;;
esac

# --- 1. Create the user with no password login (SSH key only) ---
if id "$USERNAME" &>/dev/null; then
    echo "User '$USERNAME' already exists, skipping creation."
else
    useradd -m -d "$HOME_DIR" -s /bin/bash "$USERNAME"
    passwd -l "$USERNAME"  # Lock password (SSH key auth only)
    echo "Created user '$USERNAME'."
fi

# Add to 'users' group for read access to appdata and shares (owned by nobody:users)
if ! id -nG "$USERNAME" | grep -qw users; then
    usermod -aG users "$USERNAME"
    echo "Added $USERNAME to 'users' group."
else
    echo "$USERNAME already in 'users' group."
fi

# --- 2. Create the shell filter script ---
cat > "$FILTER_SCRIPT" << 'FILTER'
#!/bin/bash
# =============================================================================
# Shell filter: validates SSH commands against an allowlist before executing.
# Installed as command= in authorized_keys — ALL commands go through here.
#
# v2 — 2026-03-21: Quote-aware pipeline splitting, allow 2>/dev/null
# v3 — 2026-03-24: Add mkdir and ln for torrent relink workflow
# v4 — 2026-05-03: Syslog audit, xargs/tar/zcat/getent/groups/last/who,
#                   /tmp/claude-* scratch redirects, structured BLOCKED reasons
#                   (docker + nc tried but dropped — daemon perms / not installed)
# v5 — 2026-05-03: Add claude-write deploy channel (sudoers + privileged writer
#                   live in claude-write-setup.sh; this filter just gates argv).
# v6 — 2026-05-03: Security hardening — block <(..) >(..) process substitution,
#                   extend curl write-flag denylist (-K -c -D --config et al.),
#                   noglob (set -f + bash -f -c), tighten >redirect blocker.
# v7 — 2026-05-04: claude-write categories split into 2-arg (hook-sonarr,
#                   hook-radarr, scratch) and 3-arg (plugin-page, plugin-include,
#                   plugin-script, plugin-cfg) forms. Plugin categories take a
#                   plugin-name argument (allowlist: torrent-handler, claude-ssh)
#                   to support multiple plugins on one NAS. New `scratch`
#                   category writes to /tmp/claude-scratch/ for ephemeral data.
# v8 — 2026-05-06: Plugin-name allowlist moved from hardcoded list to runtime
#                   config file at /boot/config/plugins/claude-ssh/allowlist.cfg.
#                   Default-deny on missing/empty/all-invalid file. Filter is
#                   advisory; the privileged writer is the enforcer. Format:
#                   `plugin <name>` lines, name regex ^[a-z][a-z0-9-]{0,63}$.
# =============================================================================

# Disable filename globbing during validation. Filter logic uses unquoted
# expansions (e.g. `for w in $trimmed`) which would otherwise glob against
# /home/claude. The final `bash -f -c` below also runs noglob so the executed
# command sees the same arguments the filter validated.
set -f

CMD="${SSH_ORIGINAL_COMMAND:-}"

if [ -z "$CMD" ]; then
    echo "Read-only shell. Usage: ssh claude@host 'command'"
    echo "Allowed: ls, find, cat, head, tail, grep, df, du, ps, stat, curl (GET only), etc."
    exit 0
fi

# --- Audit logging (every command, allow or block) ---
# Logs to syslog (auth facility) — visible in /var/log/syslog, rotates with logrotate.
logger -t claude-shell -p auth.info "RECV: $CMD" 2>/dev/null || true
log_block() {
    logger -t claude-shell -p auth.warning "BLOCKED [$1]: $CMD" 2>/dev/null || true
    echo "BLOCKED: $1" >&2
    exit 1
}

# Allowed commands (read-only operations + the carve-outs documented above)
ALLOWED="ls find stat file tree readlink realpath basename dirname cat head tail wc md5sum sha256sum grep awk sed sort uniq cut tr diff comm df du uname uptime hostname date id whoami ps curl echo printf jq numfmt mkdir ln xargs zcat tar getent groups last who claude-write"

# Sub-allowlist: which commands xargs is allowed to invoke (xargs spawns its child
# directly, bypassing the filter, so we have to constrain it here).
XARGS_INNER="cat stat head tail grep wc ls file readlink md5sum sha256sum awk cut sort uniq"

# claude-write deploy channel: target categories. Privileged writer at
# /usr/local/sbin/claude-write-priv enforces these too (defence in depth) plus
# basename validation. See scripts/claude-write-setup.sh.
#
# v7: categories split by arity.
# Simple (2 args total: claude-write <cat> <basename>):
#   hook-sonarr, hook-radarr, scratch
# Plugin (3 args total: claude-write <cat> <plugin-name> <basename>):
#   plugin-page, plugin-include, plugin-script, plugin-cfg
CW_SIMPLE_CATEGORIES="hook-sonarr hook-radarr scratch"
CW_PLUGIN_CATEGORIES="plugin-page plugin-include plugin-script plugin-cfg"

# v8: plugin-name allowlist moved from hardcoded list to runtime config file.
# Format: `plugin <name>` lines, full-line `#` comments, blank lines ignored.
# Default-deny on missing/empty file. CLAUDE_SSH_ALLOWLIST_FILE override is
# test-only (sshd's default AcceptEnv is empty, blocking it from live SSH).
CW_ALLOWLIST_FILE="${CLAUDE_SSH_ALLOWLIST_FILE:-/boot/config/plugins/claude-ssh/allowlist.cfg}"

cw_load_plugin_allowlist() {
    [ -f "$CW_ALLOWLIST_FILE" ] || return 0
    awk 'NF == 2 && $1 == "plugin" { print $2 }' "$CW_ALLOWLIST_FILE" \
        | grep -xE '[a-z][a-z0-9-]{0,63}' \
        | sort -u
}

# --- Strip harmless stderr/stdout redirects to /dev/null before checking ---
# Allow: 2>/dev/null, >/dev/null, 2>&1, &>/dev/null (all read-only / no file output)
# Note: use [[:space:]] (POSIX) rather than \s (GNU sed only) for portability —
# this lets the filter run under macOS BSD sed for local regression testing.
SANITIZED=$(echo "$CMD" | sed -E 's/[0-9]*>&?[0-9]//g; s/&?>[>]?[[:space:]]*\/dev\/null//g')

# --- Allow redirect to /tmp/claude-* scratch namespace ---
# Lets Claude cache big query results without round-tripping over SSH.
# /tmp is tmpfs (RAM-backed) on Unraid so it auto-clears on reboot.
# Reject path traversal first — `..` anywhere in the redirect target fails.
if echo "$SANITIZED" | grep -qE '/tmp/claude-[^[:space:]]*\.\.'; then
    log_block "path traversal in /tmp/claude-* redirect"
fi
# Strip valid scratch redirects so they pass the next check.
SANITIZED=$(echo "$SANITIZED" | sed -E 's#&?>[>]?[[:space:]]*/tmp/claude-[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)*##g')

# --- Block shell metacharacters (on sanitized command) ---
if echo "$SANITIZED" | grep -qE ';[[:space:]]|;[[:space:]]*$|&&|\|\|'; then
    log_block "shell chaining (; && ||) is not allowed"
fi
if echo "$SANITIZED" | grep -qE '`|\$\('; then
    log_block "command substitution (\$(), backticks) is not allowed"
fi
# Block process substitution <(cmd) and >(cmd). These spawn arbitrary commands
# in subshells, bypassing the per-segment allowlist entirely (v6 fix).
if echo "$SANITIZED" | grep -qE '<\(|>\('; then
    log_block "process substitution <(...) >(...) is not allowed"
fi
# File redirects: only /dev/null or /tmp/claude-*/ allowed (both pre-stripped above).
# Match `>` or `>>` followed by anything that looks like the start of a path or
# another redirect target — including ` >(`-style which would otherwise slip past
# the [/a-zA-Z.] anchor. The `(` here closes the gap that v5 missed.
if echo "$SANITIZED" | grep -qE '>{1,2}[[:space:]]*[/a-zA-Z.(]'; then
    log_block "file redirects only allowed to /dev/null or /tmp/claude-*/"
fi

# --- Quote-aware pipeline split ---
# Split on | characters that are NOT inside single or double quotes.
# This allows grep patterns like "A\|B" and 'foo|bar' to work.
# Pure awk — no external dependencies. Read-loop instead of mapfile so the
# filter works on bash 3.2 (e.g. macOS for local regression testing).
SEGMENTS=()
while IFS= read -r _segment; do
    SEGMENTS+=("$_segment")
done < <(awk 'BEGIN {
    cmd = ARGV[1]; ARGV[1] = ""
    n = length(cmd)
    sq = 0; dq = 0; start = 1
    for (i = 1; i <= n; i++) {
        c = substr(cmd, i, 1)
        if (c == "\"" && !sq) dq = !dq
        else if (c == "\047" && !dq) sq = !sq
        else if (c == "|" && !sq && !dq) {
            print substr(cmd, start, i - start)
            start = i + 1
        }
    }
    print substr(cmd, start)
}' "$CMD")

for segment in "${SEGMENTS[@]}"; do
    # Trim leading whitespace and get the command name
    trimmed="${segment#"${segment%%[![:space:]]*}"}"
    cmd_name="${trimmed%% *}"

    # Skip empty segments
    [ -z "$cmd_name" ] && continue

    # Check command is in the allowlist
    allowed=0
    for a in $ALLOWED; do
        if [ "$cmd_name" = "$a" ]; then
            allowed=1
            break
        fi
    done

    if [ "$allowed" -eq 0 ]; then
        log_block "command '$cmd_name' is not in allowlist"
    fi

    # --- Command-specific dangerous flag checks ---
    case "$cmd_name" in
        find)
            if echo "$segment" | grep -qiE '(\s|^)-(exec|execdir|delete|ok)\b'; then
                log_block "find -exec/-delete/-ok is not allowed"
            fi
            ;;
        sed)
            if echo "$segment" | grep -qE '(\s|^)-i\b|(\s|^)-i[.a-z]'; then
                log_block "sed -i (in-place edit) is not allowed"
            fi
            ;;
        curl)
            # Deny ALL flags that can write to disk or initiate non-GET methods.
            # v6: extends v5 list with -K/--config, -c/--cookie-jar, -D/--dump-header,
            # --output-dir, -O/--remote-name, -J/--remote-header-name, --trace*,
            # -b/--cookie (when value is a file path).
            if echo "$segment" | grep -qiE '(\s|^)(-X|--request|--data[^[:space:]]*|-d|--form-string|--form|-F|--upload-file|-T|-o|--output|--output-dir|-O|--remote-name|--remote-name-all|-J|--remote-header-name|-K|--config|-c|--cookie-jar|-D|--dump-header|--trace|--trace-ascii|--trace-time|--next|--parallel|--libcurl)\b'; then
                log_block "curl write/mutation flag is not allowed (read-only GET only)"
            fi
            # Block schemes that read local files (file://) or remote scripts
            # via gopher/dict/scp/sftp/smb/ldap. We only want http(s).
            if echo "$segment" | grep -qiE '(file|gopher|dict|scp|sftp|smb|smbs|ldap|ldaps|tftp|imap|imaps|smtp|smtps|pop3|pop3s|telnet|rtmp|rtsp)://'; then
                log_block "curl scheme not allowed (http/https only)"
            fi
            ;;
        awk)
            # Block awk's built-in file output redirection (bypasses shell)
            if echo "$segment" | grep -qE '>\s*"[/a-zA-Z]'; then
                log_block "awk file output redirection is not allowed"
            fi
            ;;
        mkdir)
            # Only allow -p flag (create parents); block -m (permissions) and others
            if echo "$segment" | grep -qE '(\s|^)-[^p[:space:]]'; then
                log_block "only mkdir -p is allowed"
            fi
            ;;
        ln)
            # Only allow hard links — block -s (symbolic), -f (force), -n
            if echo "$segment" | grep -qiE '(\s|^)-[sfn]'; then
                log_block "only hard links allowed (no -s, -f, -n flags)"
            fi
            ;;
        tar)
            # Block extract/create/append/update/delete; require -t (list) somewhere.
            if echo "$segment" | grep -qE '(\s|^)-[a-zA-Z]*[xcrAuU]\b|--(extract|get|create|append|update|catenate|concatenate|delete)\b'; then
                log_block "tar extract/create/modify is not allowed (list mode only)"
            fi
            if ! echo "$segment" | grep -qE '(\s|^)-[a-zA-Z]*t|--list\b'; then
                log_block "tar requires -t (list mode only)"
            fi
            ;;
        claude-write)
            # v7: arity depends on category.
            #   2-arg form: claude-write <cat> <basename>
            #   3-arg form: claude-write <cat> <plugin-name> <basename>
            # Iterate positional args (skip the command itself).
            args=()
            for w in $trimmed; do
                args+=("$w")
            done
            if [ "${#args[@]}" -lt 2 ]; then
                log_block "claude-write missing category"
            fi
            cw_cat="${args[1]}"

            # Determine category arity (or reject unknown).
            cw_arity=0
            for c in $CW_SIMPLE_CATEGORIES; do
                if [ "$cw_cat" = "$c" ]; then cw_arity=2; break; fi
            done
            if [ "$cw_arity" -eq 0 ]; then
                for c in $CW_PLUGIN_CATEGORIES; do
                    if [ "$cw_cat" = "$c" ]; then cw_arity=3; break; fi
                done
            fi
            if [ "$cw_arity" -eq 0 ]; then
                log_block "claude-write category '$cw_cat' not allowed"
            fi

            # Validate arity and extract args.
            if [ "$cw_arity" -eq 2 ]; then
                if [ "${#args[@]}" -ne 3 ]; then
                    log_block "claude-write $cw_cat expects 1 arg (basename)"
                fi
                cw_name="${args[2]}"
            else
                if [ "${#args[@]}" -ne 4 ]; then
                    log_block "claude-write $cw_cat expects 2 args (plugin-name, basename)"
                fi
                cw_plugin="${args[2]}"
                cw_name="${args[3]}"
                # Plugin-name must be in runtime allowlist (whitelist, not pattern).
                # Default-deny: empty/missing config → loop body never executes.
                plugin_ok=0
                for p in $(cw_load_plugin_allowlist); do
                    if [ "$cw_plugin" = "$p" ]; then plugin_ok=1; break; fi
                done
                if [ "$plugin_ok" -eq 0 ]; then
                    log_block "claude-write plugin-name '$cw_plugin' not in allowlist"
                fi
            fi

            # Basename: alphanumerics + . _ - only, no leading dot, no path bits.
            case "$cw_name" in
                .*|*/*|*..*) log_block "claude-write basename '$cw_name' invalid" ;;
            esac
            if ! echo "$cw_name" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$'; then
                log_block "claude-write basename '$cw_name' fails pattern"
            fi
            ;;
        xargs)
            # xargs spawns its inner command directly, bypassing the filter — so
            # we extract the inner command name and validate against XARGS_INNER.
            inner=""
            skip_next=0
            for w in $trimmed; do
                if [ "$w" = "xargs" ]; then continue; fi
                if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
                case "$w" in
                    # Flags that take a value
                    -n|-I|-P|-d|-E|-L|-s|-a|--max-args|--max-procs|--replace|--delimiter|--max-chars|--arg-file)
                        skip_next=1; continue ;;
                    # Flags without a value (or with =value combined)
                    -*) continue ;;
                    *) inner="$w"; break ;;
                esac
            done
            if [ -z "$inner" ]; then
                log_block "xargs requires an explicit command (stdin-as-command not allowed)"
            fi
            allowed_inner=0
            for c in $XARGS_INNER; do
                if [ "$inner" = "$c" ]; then allowed_inner=1; break; fi
            done
            if [ "$allowed_inner" -eq 0 ]; then
                log_block "xargs inner command '$inner' not in xargs allowlist"
            fi
            ;;
    esac
done

# All checks passed — execute under bash with -f (noglob) so the executed
# command sees the same args the filter validated. -f is critical: without it,
# a command containing `*` would be globbed by bash -c against /home/claude.
exec bash -f -c "$CMD"
FILTER

chown root:root "$FILTER_SCRIPT"
chmod 755 "$FILTER_SCRIPT"
echo "Installed shell filter at $FILTER_SCRIPT."

# --- 3. Set up SSH key authentication with command= restriction ---
mkdir -p "$HOME_DIR/.ssh"
chmod 700 "$HOME_DIR/.ssh"

if [ -f "$HOME_DIR/.ssh/authorized_keys" ]; then
    # Preserve existing public key(s) but ensure command= prefix is set
    # Strip any existing command= prefix, then re-add it
    if grep -q "ssh-" "$HOME_DIR/.ssh/authorized_keys"; then
        # Extract just the key(s) without any existing options
        KEYS=$(grep -oE 'ssh-[a-z0-9-]+ [A-Za-z0-9+/=]+ ?.*' "$HOME_DIR/.ssh/authorized_keys")
        : > "$HOME_DIR/.ssh/authorized_keys"
        while IFS= read -r key; do
            echo "command=\"$FILTER_SCRIPT\",no-port-forwarding,no-agent-forwarding,no-X11-forwarding $key" >> "$HOME_DIR/.ssh/authorized_keys"
        done <<< "$KEYS"
        echo "Updated authorized_keys with command= restriction."
    fi
else
    touch "$HOME_DIR/.ssh/authorized_keys"
    echo ""
    echo "=========================================="
    echo "  NEXT STEP: Add your public key"
    echo "=========================================="
    echo "From your Mac, run:"
    echo "  ssh-keygen -t ed25519 -C 'claude-unraid' -f ~/.ssh/claude_unraid"
    echo ""
    echo "Then paste the public key here. The script will add the command= prefix."
    echo ""
fi

# v6 hardening: lock SSH config to root so a compromised `claude` can't
# rewrite authorized_keys (e.g. via `curl -K cfg` with `output=...`) to drop
# the command= restriction for future logins. sshd reads as root before drop,
# so root-owned auth files still authenticate normally; StrictModes accepts
# either user-owned or root-owned auth files as long as group/other can't write.
chown root:root "$HOME_DIR/.ssh"
chmod 755 "$HOME_DIR/.ssh"
chown root:root "$HOME_DIR/.ssh/authorized_keys"
chmod 644 "$HOME_DIR/.ssh/authorized_keys"
# Filter script must stay root-owned so the user can't modify it
chown root:root "$FILTER_SCRIPT"
echo "SSH key auth configured with command= restriction (auth files locked to root)."

# --- 4. Add claude to SSH AllowUsers ---
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CHANGED=0

if grep -q "^AllowUsers" "$SSHD_CONFIG"; then
    if ! grep -q "AllowUsers.*$USERNAME" "$SSHD_CONFIG"; then
        sed -i "s/^AllowUsers.*/& $USERNAME/" "$SSHD_CONFIG"
        echo "Added $USERNAME to AllowUsers."
        SSHD_CHANGED=1
    else
        echo "$USERNAME already in AllowUsers."
    fi
else
    echo "AllowUsers $USERNAME" >> "$SSHD_CONFIG"
    echo "Added AllowUsers line."
    SSHD_CHANGED=1
fi

# Remove PermitUserEnvironment if we added it previously (no longer needed)
if grep -q "^PermitUserEnvironment yes" "$SSHD_CONFIG"; then
    sed -i 's/^PermitUserEnvironment yes/PermitUserEnvironment no/' "$SSHD_CONFIG"
    echo "Reverted PermitUserEnvironment to no (no longer needed)."
    SSHD_CHANGED=1
fi

# Save to /boot/config/ssh/ for persistence (Unraid copies this to /etc/ssh/ on boot)
mkdir -p /boot/config/ssh
cp "$SSHD_CONFIG" /boot/config/ssh/sshd_config
echo "Saved sshd_config to flash drive."

# --- 5. Persist across Unraid reboots ---
# Skip when running under the plugin — the plugin's install-runtime.sh manages
# /boot/config/go entries itself (single source of truth, avoids duplicate hooks).
if [ "$PLUGIN_INVOCATION" -eq 1 ]; then
    echo "Plugin invocation detected — skipping /boot/config/ self-persist."
else
    GO_SCRIPT="/boot/config/go"
    MARKER="# Claude read-only SSH user setup"

    # Always update the flash copy with the latest version (skip if already running from there)
    DEST="/boot/config/claude-ssh-setup.sh"
    if [ "$SELF_PATH" != "$DEST" ]; then
        cp "$SELF_PATH" "$DEST"
        chmod +x "$DEST"
    fi
    echo "Updated /boot/config/claude-ssh-setup.sh on flash drive."

    if ! grep -q "$MARKER" "$GO_SCRIPT" 2>/dev/null; then
        cat >> "$GO_SCRIPT" << GOSCRIPT

$MARKER
bash /boot/config/claude-ssh-setup.sh
GOSCRIPT
        echo "Added to /boot/config/go for persistence across reboots."
    else
        echo "/boot/config/go already has startup entry."
    fi
fi

# --- 6. Clean up old rbash approach if present ---
# Remove artifacts from the previous rbash-based setup
[ -d "$HOME_DIR/bin" ] && rm -rf "$HOME_DIR/bin" && echo "Removed old restricted bin directory."
[ -f "$HOME_DIR/.ssh/environment" ] && rm -f "$HOME_DIR/.ssh/environment" && echo "Removed old .ssh/environment."
[ -e /bin/rbash ] && rm -f /bin/rbash && echo "Removed rbash symlink."
# Switch shell from rbash to bash (command= handles restriction now)
if grep -q "$USERNAME.*rbash" /etc/passwd; then
    sed -i "s|$USERNAME\(.*\)/bin/rbash|$USERNAME\1/bin/bash|" /etc/passwd
    echo "Switched shell from rbash to bash."
fi

echo ""
echo "=========================================="
echo "  Setup complete!"
echo "=========================================="
echo ""
echo "Security:"
echo "  Auth:       SSH key only (password locked)"
echo "  Filter:     $FILTER_SCRIPT v7 (root-owned, validates every command)"
echo "  Audit:      every command logged to syslog (tag: claude-shell)"
echo "  Allowlist:  ls, find, cat, grep, df, du, ps, curl (GET), jq, numfmt, mkdir,"
echo "              ln, xargs, zcat, tar, getent, groups, last, who, etc."
echo "  Blocked:    rm, mv, chmod, chown, reboot, shutdown, kill, docker, etc."
echo "  Flags:      find -exec, sed -i, curl -X/-d, awk file writes, ln -s/-f, tar -x/-c"
echo "  xargs:      inner command must be in XARGS_INNER allowlist (cat/stat/grep/...)"
echo "  Shell:      ;, &&, ||, \$(), backticks, file redirects (> to most paths)"
echo "  Allowed:    pipes, grep regex (\\|), 2>/dev/null, >/dev/null,"
echo "              redirect to /tmp/claude-*/ scratch (no .. traversal)"
echo "  Splitting:  quote-aware pipeline parsing (awk-based)"
echo "  Forwarding: port/agent/X11 all disabled"
echo ""
echo "Audit log:"
echo "  tail -f /var/log/syslog | grep claude-shell"
echo ""
echo "Test:"
echo "  ssh $USERNAME@\$(hostname) 'ls /mnt/user'                                 # Should work"
echo "  ssh $USERNAME@\$(hostname) 'find /mnt -type f > /tmp/claude-scan/files.txt' # Should work"
echo "  ssh $USERNAME@\$(hostname) 'rm /tmp/test'                                  # BLOCKED: not allowed"
echo "  ssh $USERNAME@\$(hostname) 'find / -delete'                                # BLOCKED: dangerous flag"
echo "  ssh $USERNAME@\$(hostname) 'curl -X DELETE http://x'                       # BLOCKED: mutation flag"
echo "  ssh $USERNAME@\$(hostname) 'find /mnt | xargs rm'                          # BLOCKED: xargs inner"

# Restart sshd if config changed
if [ "$SSHD_CHANGED" -eq 1 ]; then
    echo ""
    echo "Restarting sshd to apply config changes..."
    /etc/rc.d/rc.sshd restart
fi
