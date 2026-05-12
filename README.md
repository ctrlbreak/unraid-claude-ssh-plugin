# claude-ssh — Unraid plugin

Give Claude (or any other AI automation) a curated, read-only shell on
your Unraid NAS so it can help you inspect, monitor, and operate the
box — plus a narrow write channel for the cases where you want it to
actually deploy something. Hand out one SSH key, and the holder can
run **only** a fixed list of safe commands (`ls`, `cat`, `grep`, `find`,
`du`, `df`, `ps`, `tar -t`, `curl` GET, `jq`, `awk`, and ~20 more) for
diagnostics and inspection. No interactive shell. No PTY. No `sed -i`,
no `find -exec`, no `curl -O`. Pipes work, scratch redirects to
`/tmp/claude-*/` work, and everything is logged.

When you want the AI to *change* something, the separate `claude-write`
channel deploys files to allowlisted locations only — hook scripts into
a container's `appdata/scripts/` dir, plugin assets into specific plugin
directories, or ephemeral files in `/tmp`. Default-deny allowlist,
regex-validated, atomic write with rotated backups, and a structured
audit trail.

Two layers of validation everywhere: an SSH-layer `command=` filter
rejects unknown commands at login (advisory, fast); a privileged writer
re-validates every write as enforcement. A Settings/Status tab in the
Unraid web UI surfaces the filter version, recent activity, the
configured allowlist (editable in-browser), and the live audit log;
a Dashboard tile mirrors install health, 24h activity, and allowlist
size at a glance. No shell needed once the plugin is installed.

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

## Versioning

Three independent version markers, each bumped only when the thing it
represents actually changes:

- **Plugin version** — date-based (`YYYY.MM.DD[a-z]`), single source in
  `claude-ssh.plg`. Bumped on every user-visible change that ships in the
  package (a source script, a page, a packaged doc). Test-only or repo-asset
  changes don't bump it.
- **Filter version** — `vN`, declared as a single `FILTER_VERSION="vN"`
  assignment at the top of `unraid-readonly-ssh-setup.sh`. Bumped **only**
  when the runtime filter heredoc — the script that ends up at
  `/home/<user>/shell-filter.sh` — changes. Setup-script edits outside the
  heredoc don't bump it. The install banner and `exec.php`'s Status-page
  parser both read this one assignment, so the printed version and the
  Status-page version can't diverge.
- **Writer version** — `vN`, declared as a single `WRITER_VERSION="vN"`
  assignment at the top of `claude-write-setup.sh`. Same rule: bumps only
  when the runtime writer (`/usr/local/sbin/claude-write-priv`) changes.

The split exists because filter and writer are **runtime contracts**, not
package metadata. The Status page surfaces all three so an operator can tell
at a glance whether the layer that actually enforces things (filter, writer)
moved, independent of cosmetic plugin churn. A release that only touches docs
or the Settings UI bumps the plugin version but leaves filter/writer at the
same numbers; a one-line change to a regex inside the filter bumps the filter
version even when nothing else moves. Bumping filter or writer version
implies bumping the plugin version too (the runtime artifact is shipping
inside a new package), but not the reverse.

The current numbers live in `claude-ssh.plg`, on the Settings → claude-ssh
page once installed, and in [`CHANGELOG.md`](CHANGELOG.md).

## Categories

### Simple

- `claude-write scratch <basename>` → `/tmp/claude-scratch/` (.sh .py .txt
  .json .log .conf .md, ephemeral, no backups)

### Plugin (3-arg, gated by plugin allowlist)

```
claude-write plugin-file <plugin-name> <rel-path>   → /usr/local/emhttp/plugins/<plugin>/<rel-path>
```

`<rel-path>` may be a basename or include up to two subdirectories
(`scripts/foo.sh`, `javascript/lib/foo.js`, `event/started`). Extension drives
mode: `.sh` / `.py` are 755, everything else (`.page .php .cfg .js .css
.html .svg .txt .json`) is 644. The Unraid event-hook convention is
honoured: an extensionless basename matching `^[a-z][a-z0-9_]{0,32}$` is
accepted under `event/` (mode 755). See [`docs/categories.md`](docs/categories.md)
for the full rel-path / extension / mode reference.

### Container (3-arg, gated by container allowlist)

```
claude-write appdata-script <container> <basename>     → /mnt/user/appdata/<container>/scripts/
```

One generic form covers any *arr-style app: Sonarr, Radarr, Bazarr,
Lidarr, Prowlarr, Tdarr, autobrr, and the long tail of containers that
keep their hooks under `/mnt/user/appdata/<container>/scripts/`.

## Runtime allowlist

Both 3-arg category families are gated by entries in:

```
/mnt/user/appdata/claude-ssh/allowlist.cfg
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
`/mnt/user/appdata/claude-ssh/allowlist.cfg` directly if you need to
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

## Documentation

Topic-specific docs live under [`docs/`](docs/):

- [`install.md`](docs/install.md) — Step-by-step install via the Unraid
  web UI or shell, plus what gets laid down where.
- [`filter.md`](docs/filter.md) — Every command the SSH filter allows,
  with flag restrictions, global rules (no chaining, no command
  substitution, restricted redirects), and useful invocation patterns.
- [`categories.md`](docs/categories.md) — Full reference for every
  `claude-write` category: argv shape, target dir, allowed extensions,
  allowlist gate, worked examples.
- [`threat-model.md`](docs/threat-model.md) — What this plugin protects
  against, what it does NOT protect against, defence-in-depth diagram.
  **Read this before granting any SSH key.**
- [`wire-protocol.md`](docs/wire-protocol.md) — Argv shapes, validation
  regex, exit codes, syslog format. The contract surface for clients.
- [`upgrading.md`](docs/upgrading.md) — Upgrade flow, what's preserved,
  rollback procedure, and migration from a manual install.
- [`troubleshooting.md`](docs/troubleshooting.md) — The most common
  failures, with symptoms and fixes.
- [`verifying.md`](docs/verifying.md) — How to run `verify-install.sh`,
  the end-to-end smoke test for a live install.
- [`releasing.md`](docs/releasing.md) — How to cut a release (maintainers).

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

# Build + scp + plugin install on a NAS (developer convenience).
NAS_HOST=root@nas.local bash deploy.sh
```

End users install from the Unraid web UI by pasting a release `.plg` URL —
see [docs/install.md](docs/install.md). `deploy.sh` is a developer-only
shortcut for iterating against a real NAS during plugin development.

## Verify your install

After installing on a real NAS, run the end-to-end verification suite to
confirm the filter, writer, sudoers, and audit log are all working:

```bash
ROOT_HOST=root@nas.local CLAUDE_HOST=claude@nas.local bash verify-install.sh
```

It runs ~35 cases across install state, filter behaviour, writer
behaviour, audit log, and version parity, with inline fix hints on
every failure. See [docs/verifying.md](docs/verifying.md) for the full
prerequisites and output format. Repo-asset only — not in the `.txz`,
runs from a checkout.

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
├── default.cfg                     # Defaults (allowlist lives in /mnt/user/appdata/claude-ssh/allowlist.cfg)
├── include/exec.php                # AJAX backend (status, audit_log, recent_writes, load/save_allowlist)
└── scripts/
    ├── install-runtime.sh              # Calls setup scripts + manages /boot/config/go
    ├── uninstall-runtime.sh            # Non-destructive cleanup
    ├── unraid-readonly-ssh-setup.sh    # SSH user + filter heredoc (canonical source)
    └── claude-write-setup.sh           # claude-write writer + sudoers (canonical source)
```
