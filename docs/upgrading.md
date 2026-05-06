# Upgrading

How upgrades work, what's preserved, what's reset, and how to roll back.

## How upgrades work

The Unraid plugin manager pulls the new `.plg` and `.txz`, runs `upgradepkg
--reinstall` to overlay the new payload, then runs the install hook
(`install-runtime.sh`) again. The install hook is **idempotent** — running it
twice is safe — so the upgrade flow is functionally identical to a fresh
install except that:

- Any prior runtime artifacts get re-rendered from the new setup scripts
  (filter, writer, sudoers, sshd snippet).
- The `/boot/config/go` hook is left unchanged (the marker grep deduplicates).
- Persistent flash files (`username`, `allowlist.cfg`) are preserved
  byte-for-byte. The seed step skips them when they already exist.

The same idempotent re-run also fires on every boot via the `/boot/config/go`
hook, so unattended reboots heal partial-install states.

## What's preserved across upgrades

These files survive every upgrade:

| Path | What it is |
|---|---|
| `/boot/config/plugins/claude-ssh/username` | Configured SSH username (single line) |
| `/boot/config/plugins/claude-ssh/allowlist.cfg` | Plugin + container allowlist with all your entries |
| `/home/<user>/` | The SSH user's home, including `.ssh/authorized_keys` and key fingerprint trust |
| `/mnt/cache/appdata/claude-write-backups/` | Rotated backups of every write that overwrote a prior file |
| `/var/log/syslog` (subject to Unraid's rotation) | Audit trail |

Both invariants are tested:
[`test-upgrade-path.sh`](../tests/test-upgrade-path.sh) asserts the seed-and-
preserve behaviour for `username` and `allowlist.cfg`.

## What's regenerated on every upgrade

These get re-rendered from the new setup scripts:

| Path | What it is |
|---|---|
| `/usr/local/emhttp/plugins/claude-ssh/` | The plugin tree (page, exec.php, scripts) |
| `/usr/local/bin/claude-write` | Wrapper |
| `/usr/local/sbin/claude-write-priv` | Privileged writer |
| `/etc/sudoers.d/claude-write` | Sudoers grant (with the configured username principal) |
| `/home/<user>/shell-filter.sh` | The SSH filter |
| sshd_config additions | The `AllowUsers` and `Match User` blocks |

Anything you customised in these files **will be overwritten on upgrade**.
Customise the source scripts in the repo and rebuild instead.

## Version-bump cadence

The plugin uses three independent version markers:

- **Plugin version** (`<!ENTITY version "...">` in `claude-ssh.plg`) — bumps
  when anything user-visible changes (script edits, page tweaks, plg metadata).
- **Filter version** (`# Filter version: vN` in `unraid-readonly-ssh-setup.sh`)
  — bumps when the live `/home/<user>/shell-filter.sh` content changes.
- **Writer version** (`# Writer version: vN` in `claude-write-setup.sh`) —
  bumps when the live `/usr/local/sbin/claude-write-priv` content changes.

The Settings → Claude SSH → Status pane reads all three live and shows them.
After an upgrade, the Status pane is the fastest way to confirm the new
artifacts are in place.

## Upgrade walkthrough

From the Unraid web UI:

1. **Plugins → Installed Plugins → Check for Updates** (or wait for the
   per-day check).
2. The plugin entry shows a new version. Click **Update**.
3. After the install hook runs, refresh **Settings → Claude SSH** and confirm:
   - Health KPI green.
   - Filter / writer version match what the new release ships.
   - Allowlist contents unchanged (cross-check by counting lines or doing a
     `diff` against your last known-good copy).

From the shell:

```bash
# Re-pull the .plg + .txz onto flash (the install hook reads from /boot/config/plugins/claude-ssh/).
curl -fsSL <new-plg-url> -o /boot/config/plugins/claude-ssh/claude-ssh.plg
curl -fsSL <new-txz-url> -o /boot/config/plugins/claude-ssh/claude-ssh.txz

# Re-run the .plg's install block.
plugin install /boot/config/plugins/claude-ssh/claude-ssh.plg
```

## Rolling back

Plugin removal is non-destructive — it tears down runtime artifacts but
preserves user state. To roll back:

```bash
# 1. Remove the current version.
plugin remove claude-ssh

# 2. Reinstall the prior .plg URL (release tag is preferable over a moving ref).
plugin install <old-plg-url>
```

Because `username`, `allowlist.cfg`, `authorized_keys`, and the SSH user
account all survive removal, the rollback comes back up in the same logical
state — same SSH user, same allowlist, same key trust.

If you also want to fully purge user state before rolling back:

```bash
plugin remove claude-ssh
userdel claude
rm -rf /home/claude /mnt/cache/appdata/claude-write-backups \
       /boot/config/plugins/claude-ssh
plugin install <old-plg-url>
```

## Migrating from filter v7 / v8 (`hook-sonarr` / `hook-radarr`)

v9 (writer v4) collapsed the `hook-sonarr` and `hook-radarr` categories into
`appdata-script <container>`. Existing client scripts need updating:

```bash
# Old (v7 / v8)
ssh claude@nas 'claude-write hook-sonarr foo.sh' < foo.sh
ssh claude@nas 'claude-write hook-radarr foo.sh' < foo.sh

# New (v9)
ssh claude@nas 'claude-write appdata-script sonarr foo.sh' < foo.sh
ssh claude@nas 'claude-write appdata-script radarr foo.sh' < foo.sh
```

And add the matching `container <name>` lines to your allowlist:

```
container sonarr
container radarr
```

The old hook categories are not aliased — there's no compatibility shim. The
benefit is that any new container can be allowlisted without a code change.

## Migrating from manual install (pre-plugin)

If you previously ran the two setup scripts directly (from
`homelab-scripts/plugin-claude-ssh/` or similar), the plugin's install hook
**migrates** on first run:

- Strips the legacy `# Claude read-only SSH user setup` and `# Claude write
  deploy channel` markers from `/boot/config/go` along with their `bash …`
  invocation lines.
- Removes `/boot/config/claude-ssh-setup.sh` and
  `/boot/config/claude-write-setup.sh` from flash.
- Leaves the plugin's own `# Claude SSH plugin (filter + claude-write)` hook
  in place.

Migration is one-shot and idempotent (covered by
[`test-migration.sh`](../tests/test-migration.sh)). The user account and
`/home/claude/` are unaffected — your existing key still works.
