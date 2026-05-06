# claude-ssh — Unraid plugin

Packages the `claude` SSH user, filter v8, and `claude-write` deploy channel
(writer v3) into a single Unraid plugin. Replaces the manual two-script
install flow with one `.plg` URL, plus a Settings/Status tab for visibility
into filter version, recent activity, and audit logs.

## What it does

On install, the plugin:

1. Lays down the plugin tree at `/usr/local/emhttp/plugins/claude-ssh/`
2. Runs `install-runtime.sh`, which:
   - Calls `unraid-readonly-ssh-setup.sh` — creates `claude` user, deploys the
     filter, configures sshd
   - Calls `claude-write-setup.sh` — installs `/usr/local/bin/claude-write` +
     `/usr/local/sbin/claude-write-priv`, sudoers fragment, backup directory
   - Adds a single `/boot/config/go` hook so the plugin re-applies on reboot
3. Registers the Settings/Status tab + Dashboard tile in the Unraid web UI

The setup scripts auto-detect plugin invocation (path starts with
`/usr/local/emhttp/plugins/`) and skip their own self-persistence — boot
hooks are managed by the plugin so there's a single source of truth.

## Versions

- **Plugin:** `2026.05.06` (date-based, single source in `claude-ssh.plg`)
- **Filter:** `v8` — parsed from a `# Filter version:` comment in the setup script
- **Writer:** `v3` — parsed from a `# Writer version:` comment in the setup script

Bumping plugin version: edit one entity in `claude-ssh.plg`. Bumping filter or
writer version: edit the comment + the relevant logic, then bump plugin version
too. The Status page surfaces all three.

## Plugin-name allowlist (v8)

The plugin-* categories (`plugin-page`, `plugin-include`, `plugin-script`,
`plugin-cfg`) require a plugin-name argument:

```
claude-write plugin-page <plugin-name> <basename>
```

The list of allowed plugin-names is configured at runtime via:

```
/boot/config/plugins/claude-ssh/allowlist.cfg
```

Format: one `plugin <name>` line per allowed plugin. Comments start with `#`;
blank lines ignored. Names must match `^[a-z][a-z0-9-]{0,63}$`. Example:

```
# claude-ssh allowlist
plugin torrent-handler
plugin claude-ssh
```

**Default-deny:** if the file is missing, empty, or contains no valid entries,
all `plugin-*` writes are rejected. The plugin seeds a commented template on
first install; existing files are never overwritten.

The filter and the privileged writer both read this file on every invocation.
The filter is advisory (early rejection at the SSH layer); the writer is the
enforcer (defence in depth — a stale filter cache can't bypass the writer).

## Other categories (v7, unchanged)

- `claude-write hook-sonarr <basename>` → `/mnt/user/appdata/sonarr/scripts/`
- `claude-write hook-radarr <basename>` → `/mnt/user/appdata/radarr/scripts/`
- `claude-write scratch <basename>` → `/tmp/claude-scratch/`
  (`.sh .py .txt .json .log .conf .md`, ephemeral, no backups)

## Build & deploy

```bash
# Run the local test suite (lint, build, filter regression, allowlist
# parser, idempotency, migration, ...)
make test

# Build the .txz package
make

# Quick deploy (UI tweaks only — no install hook re-run)
bash deploy.sh

# Full deploy (rebuild + plugin install — needed when setup scripts change)
bash deploy.sh --full
```

For a fresh NAS install, host the `.plg` and `.txz` somewhere reachable
(GitHub raw URL or a release tag) and run from the Unraid web UI:

```
plugin install <plg-url>
```

## Uninstall

```
plugin remove claude-ssh
```

This is non-destructive by default — removes the plugin tree, sudoers
fragment, sshd_config additions, and `/boot/config/go` hook, but **preserves**:

- `/home/claude/` (authorized_keys, key fingerprint trust)
- `/mnt/cache/appdata/claude-write-backups/` (history of past writes)
- The `claude` user account

To fully purge:

```
userdel claude && rm -rf /home/claude /mnt/cache/appdata/claude-write-backups
```

## Layout

```
claude-ssh.plg              # Plugin manifest, version entity, install/remove hooks
Makefile                    # tar cJf → claude-ssh.txz, plus `make test`
deploy.sh                   # quick (claude-write) + --full (plugin install) modes
tests/                      # Local lint / build / regression / idempotency suite
README.md                   # This file
src/usr/local/emhttp/plugins/claude-ssh/
├── ClaudeSsh.page                  # Settings tab (Status + collapsible Audit Log)
├── ClaudeSshDashboard.page         # Dashboard tile
├── default.cfg                     # Defaults (empty for v1)
├── include/exec.php                # AJAX backend (status, audit_log, recent_writes)
└── scripts/
    ├── install-runtime.sh              # Calls setup scripts + manages /boot/config/go
    ├── uninstall-runtime.sh            # Non-destructive cleanup
    ├── unraid-readonly-ssh-setup.sh    # SSH user + filter heredoc (canonical source)
    └── claude-write-setup.sh           # claude-write writer + sudoers (canonical source)
```
