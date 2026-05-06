# claude-ssh — Unraid plugin

Packages the `claude` SSH user, filter v9, and `claude-write` deploy channel
(writer v4) into a single Unraid plugin. Replaces the manual two-script
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

- **Plugin:** `2026.05.06c` (date-based, single source in `claude-ssh.plg`)
- **Filter:** `v9` — parsed from a `# Filter version:` comment in the setup script
- **Writer:** `v4` — parsed from a `# Writer version:` comment in the setup script

Bumping plugin version: edit one entity in `claude-ssh.plg`. Bumping filter or
writer version: edit the comment + the relevant logic, then bump plugin version
too. The Status page surfaces all three.

## Categories (v9)

### Simple

- `claude-write scratch <basename>` → `/tmp/claude-scratch/` (.sh .py .txt
  .json .log .conf .md, ephemeral, no backups)

### Plugin (3-arg, gated by plugin allowlist)

```
claude-write plugin-page    <plugin-name> <basename>   → /usr/local/emhttp/plugins/<plugin>/
claude-write plugin-include <plugin-name> <basename>   → /usr/local/emhttp/plugins/<plugin>/include/
claude-write plugin-script  <plugin-name> <basename>   → /usr/local/emhttp/plugins/<plugin>/scripts/
claude-write plugin-cfg     <plugin-name> <basename>   → /usr/local/emhttp/plugins/<plugin>/
```

### Container (3-arg, gated by container allowlist) — v9

```
claude-write appdata-script <container> <basename>     → /mnt/user/appdata/<container>/scripts/
```

Replaces v7's `hook-sonarr` / `hook-radarr` categories with one generic
form. Useful for any *arr-style app: Sonarr, Radarr, Bazarr, Lidarr,
Prowlarr, Tdarr, autobrr, and the long tail of containers that keep their
hooks under `/mnt/user/appdata/<container>/scripts/`.

## Runtime allowlist

Both 3-arg category families are gated by entries in:

```
/boot/config/plugins/claude-ssh/allowlist.cfg
```

Format:

```
# claude-ssh allowlist
plugin torrent-handler
plugin claude-ssh
container sonarr
container radarr
```

Comments start with `#`; blank lines ignored. Names must match
`^[a-z][a-z0-9-]{0,63}$`. Invalid entries silently dropped.

**Default-deny:** if the file is missing, empty, or contains no valid
entries of the relevant kind, the corresponding writes are rejected. The
plugin seeds a commented template on first install; existing files are
never overwritten.

The filter and the privileged writer both read this file on every
invocation. The filter is advisory (early rejection at the SSH layer); the
writer is the enforcer (defence in depth — a stale filter cache can't
bypass the writer). Both reuse the same parametric parser, so plugin and
container parsing stay in lockstep.

### Editing via the Settings UI

The Settings/Status tab has an **Allowlist** card with two textareas (one for
plugins, one for containers) and Save / Reload buttons. The save handler
validates each name against `^[a-z][a-z0-9-]{0,63}$` server-side and rejects
the whole save with a clear error if any name is invalid. On success the
allowlist is rewritten atomically (temp file plus rename in the same
directory).

Saving from the UI regenerates the file with a fixed header comment block —
custom comments and unrelated lines are **not preserved**. Edit
`/boot/config/plugins/claude-ssh/allowlist.cfg` directly if you need to
keep them. The header advertises the format and name regex so even a
hand-edited file is self-documenting.

## Configurable SSH username

Default username is `claude`. To use a different name, set it **before** the
plugin runs `install-runtime.sh` (i.e. before plugin install, or before the
first reboot if installing manually):

```bash
# Either env var (transient):
CLAUDE_SSH_USERNAME=ops bash install-runtime.sh

# Or persist to flash so reboots resolve the same name without the env var:
mkdir -p /boot/config/plugins/claude-ssh
echo ops > /boot/config/plugins/claude-ssh/username
chmod 644 /boot/config/plugins/claude-ssh/username
```

Precedence: `CLAUDE_SSH_USERNAME` env var → `/boot/config/plugins/claude-ssh/username`
file → default `claude`. The file is seeded on first install with the
resolved value and is **never overwritten** afterwards, so explicit user
choices survive plugin upgrades.

The username must match `^[a-z][a-z0-9-]{0,31}$` (POSIX-ish: lowercase
letter followed by lowercase/digit/hyphen, max 32 chars). Invalid values
abort the install with a clear error.

Where the username flows:

- `useradd` / `passwd -l` / `usermod -aG users` (user creation)
- `/home/<user>/shell-filter.sh` and `/home/<user>/.ssh/authorized_keys`
- `AllowUsers <user>` in `/etc/ssh/sshd_config`
- Sudoers principal in `/etc/sudoers.d/claude-write`
- Smoke tests, uninstall stripping, Settings/Status tab Health KPI

The filter, the privileged writer, and the `claude-write` binary names are
not the SSH username — they stay constant regardless of what username you
pick. Only the user creation and the sudoers principal change.

**Switching the username on an existing install:** uninstall the plugin
(non-destructive — preserves `/home/<old-user>/`), update the username
file, then reinstall. The old user account stays around; remove it
manually with `userdel <old-user>` if no longer needed.

## Migrating from filter v7 / v8 (`hook-sonarr` / `hook-radarr`)

If you were using the legacy hook categories:

```
# Old (v7 / v8)
ssh claude@nas 'claude-write hook-sonarr foo.sh' < foo.sh
ssh claude@nas 'claude-write hook-radarr foo.sh' < foo.sh

# New (v9)
ssh claude@nas 'claude-write appdata-script sonarr foo.sh' < foo.sh
ssh claude@nas 'claude-write appdata-script radarr foo.sh' < foo.sh
```

Add `container sonarr` / `container radarr` (or whichever you need) to
`/boot/config/plugins/claude-ssh/allowlist.cfg`.

## Documentation

Topic-specific docs live under [`docs/`](docs/):

- [`install.md`](docs/install.md) — Step-by-step install via the Unraid
  web UI or shell, plus what gets laid down where.
- [`categories.md`](docs/categories.md) — Full reference for every
  `claude-write` category: argv shape, target dir, allowed extensions,
  allowlist gate, worked examples.
- [`threat-model.md`](docs/threat-model.md) — What this plugin protects
  against, what it does NOT protect against, defence-in-depth diagram.
  **Read this before granting any SSH key.**
- [`wire-protocol.md`](docs/wire-protocol.md) — Argv shapes, validation
  regex, exit codes, syslog format. The contract surface for clients.
- [`upgrading.md`](docs/upgrading.md) — Upgrade flow, what's preserved,
  rollback procedure, migration from v7/v8 and from manual install.
- [`troubleshooting.md`](docs/troubleshooting.md) — The most common
  failures, with symptoms and fixes.

Sample client + allowlist:

- [`examples/deploy-via-claude-write.sh`](examples/deploy-via-claude-write.sh)
  — 30-line bash client demonstrating the four common categories.
- [`examples/allowlist.cfg.example`](examples/allowlist.cfg.example) — A
  populated allowlist showing the format.

Project meta:

- [`CHANGELOG.md`](CHANGELOG.md) — Per-release changes (mirrors `.plg`'s
  `<CHANGES>` block).
- [`SECURITY.md`](SECURITY.md) — How to report a vulnerability.

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
docs/                       # Topic-specific docs (install, categories, threat-model, ...)
examples/                   # Sample client + allowlist
.github/                    # Issue templates, security advisory contact
README.md                   # This file
CHANGELOG.md                # Per-release changes (mirror of <CHANGES> in .plg)
SECURITY.md                 # Vulnerability reporting policy
CLAUDE.md                   # Agent working rules + active invariants
src/usr/local/emhttp/plugins/claude-ssh/
├── ClaudeSsh.page                  # Settings tab (Health + Allowlist editor + Status + Audit Log)
├── ClaudeSshDashboard.page         # Dashboard tile
├── default.cfg                     # Defaults (allowlist lives in /boot/config/plugins/claude-ssh/allowlist.cfg)
├── include/exec.php                # AJAX backend (status, audit_log, recent_writes, load/save_allowlist)
└── scripts/
    ├── install-runtime.sh              # Calls setup scripts + manages /boot/config/go
    ├── uninstall-runtime.sh            # Non-destructive cleanup
    ├── unraid-readonly-ssh-setup.sh    # SSH user + filter heredoc (canonical source)
    └── claude-write-setup.sh           # claude-write writer + sudoers (canonical source)
```
