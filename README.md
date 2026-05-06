# claude-ssh — Unraid plugin

Packages the `claude` SSH user, filter v7, and `claude-write` deploy channel
into a single Unraid plugin. Replaces the manual two-script install flow with
one `.plg` URL, plus a Settings/Status tab for visibility into filter version,
recent activity, and audit logs.

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

- **Plugin:** `2026.05.04` (date-based, single source in `claude-ssh.plg`)
- **Filter:** `v7` — parsed from a `# Filter version:` comment in the setup script
- **Writer:** `v2` — parsed from a `# Writer version:` comment in the setup script

Bumping plugin version: edit one entity in `claude-ssh.plg`. Bumping filter or
writer version: edit the comment + the relevant logic, then bump plugin version
too. The Status page surfaces all three.

## Filter v7 changes

Two reasons for the v7 bump:

1. **Plugin-name parameterisation.** `plugin-page` / `plugin-include` /
   `plugin-script` / `plugin-cfg` categories now take a plugin-name argument:
   ```
   claude-write plugin-page <plugin-name> <basename>
   ```
   Plugin-name allowlist: `torrent-handler`, `claude-ssh`. Existing
   single-plugin shape (no plugin-name) no longer works — clients must pass
   `torrent-handler` explicitly.

2. **New `scratch` category** for `/tmp/` writes:
   ```
   claude-write scratch <basename>
   ```
   Target: `/tmp/claude-scratch/<basename>`. Allowed extensions:
   `.sh .py .txt .json .log .conf .md`. No backup retention (`/tmp` is
   ephemeral). Useful for staging analysis scripts and data files.

## Build & deploy

```bash
# Run the local test suite (lint, build, filter regression, idempotency, ...)
make -C plugin-claude-ssh test

# Build the .txz package
make -C plugin-claude-ssh

# Quick deploy (UI tweaks only — no install hook re-run)
bash plugin-claude-ssh/deploy.sh

# Full deploy (rebuild + plugin install — needed when setup scripts change)
bash plugin-claude-ssh/deploy.sh --full
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
plugin-claude-ssh/
├── claude-ssh.plg              # Plugin manifest, version entity, install/remove hooks
├── Makefile                    # tar cJf → claude-ssh.txz, plus `make test`
├── deploy.sh                   # quick (claude-write) + --full (plugin install) modes
├── tests/                      # Local lint / build / regression / idempotency suite
├── README.md                   # This file
└── src/usr/local/emhttp/plugins/claude-ssh/
    ├── ClaudeSsh.page                  # Settings tab (Status + collapsible Audit Log)
    ├── ClaudeSshDashboard.page         # Dashboard tile
    ├── default.cfg                     # Defaults (empty for v1)
    ├── include/exec.php                # AJAX backend (status, audit_log, recent_writes)
    └── scripts/
        ├── install-runtime.sh          # Calls setup scripts + manages /boot/config/go
        ├── uninstall-runtime.sh        # Non-destructive cleanup
        ├── unraid-readonly-ssh-setup.sh    # Copied from repo's scripts/ at build time
        └── claude-write-setup.sh           # Same — single source of truth in repo
```
