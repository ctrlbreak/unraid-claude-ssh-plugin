# Changelog

Mirror of the `<CHANGES>` block in `claude-ssh.plg`. The `.plg` is the
canonical source — this file is for readability and git-friendly diffs.

Format: each section is a plugin version. Plugin versions are date-based
(`YYYY.MM.DD[a-z]`) — the suffix increments when multiple releases happen on
the same day. The filter and writer have independent version markers
(see [docs/upgrading.md](docs/upgrading.md)).

## 2026.05.12d — 2026-05-12

- **Centralise filter/writer version literals.** Each setup script now
  declares its runtime-contract version as a single shell variable at
  the top (`FILTER_VERSION` / `WRITER_VERSION`). Install banners and
  `exec.php`'s Status-page parser both read that one assignment, so a
  hardcoded `vN` literal in an install banner can no longer go stale
  after a bump (the bug class that produced "stale v7 banner" in
  `2026.05.12a`).
- **New `tests/test-version-drift.sh`.** Scans user-facing docs for
  current-tense filter/writer version claims (badges, diagram
  annotations, sample-output lines) and fails CI if any disagrees
  with canonical. Targeted patterns only — release-history files
  (`CHANGELOG.md`, `.plg` `<CHANGES>`) and prose mentions of past
  versions are not scanned.
- **Drift-affected docs cleaned up.** `docs/install.md`,
  `docs/threat-model.md`, `docs/verifying.md`,
  `docs/troubleshooting.md`, `docs/wire-protocol.md`, and
  `docs/categories.md` now reference `FILTER_VERSION` /
  `WRITER_VERSION` (or omit the version) rather than naming a
  specific value that drifts. The README "Versions" section was
  replaced with a "Versioning" rationale in the same pass.
- No filter/writer version bump — runtime artifacts unchanged.

## 2026.05.12c — 2026-05-12

- **Move allowlist off `/boot/config`.** Filter `v9 → v10`, writer
  `v4 → v5`. The constrained SSH user could never read the allowlist
  when it lived in `/boot/config/plugins/claude-ssh/` because `/boot`
  is FAT-mounted with `dmask=0077` — the kernel forces every directory
  on that mount to mode 700 regardless of chmod. New canonical
  location: `/mnt/user/appdata/claude-ssh/allowlist.cfg`, on the array
  with normal Unix perms (mode 644). The previous attempted fix in
  `2026.05.12b` (`chmod 755` on the dir) was a silent no-op because
  the FAT mask overrides chmod.
- **One-shot migration on upgrade.** `install-runtime.sh` copies any
  existing `/boot/config/plugins/claude-ssh/allowlist.cfg` to the new
  location and renames the legacy file to
  `*.migrated-pre-v2026.05.12c` so it's clearly out of service.
  Settings UI saves go to the new path atomically.
- **Username file stays put** at
  `/boot/config/plugins/claude-ssh/username`. Only read by root
  (install-runtime.sh, claude-write-setup.sh, exec.php) — the FAT mask
  doesn't affect that path's usability.
- Banner version labels in setup scripts caught up (`v7 → v10`,
  `v2 → v5`) — were stale from earlier filter/writer version bumps.

## 2026.05.12b — 2026-05-12

- **Fix allowlist unreadable by constrained user.** `install-runtime.sh`
  now explicitly `chmod 755 /boot/config/plugins/claude-ssh/`
  (idempotent — fixes existing installs where the dir was created with
  mode 700 from an earlier root umask). Without world-execute on the
  dir, the SSH filter silently default-denies every
  `claude-write plugin-*` and `claude-write appdata-script` invocation
  because it can't stat `allowlist.cfg`. Surfaced during first live
  deploy: every Layer-3 write in `verify-install.sh` was rejected as
  "not in allowlist" despite the entries being present.
- `verify-install.sh` improvements: read version markers from the
  setup-script headers in `/usr/local/emhttp/plugins/.../scripts/`
  (matches `exec.php`); expect `authorized_keys` as `root:root 644`
  (the plugin's deliberately-locked posture, not the stock
  `claude:users 600`); accept both `BLOCKED` (filter) and `REJECTED`
  (writer) as valid rejection signals in Layer 3; new case 1.11
  exercises the constrained user actually reading `allowlist.cfg`;
  Layer 5.3 skips instead of failing when the bare-curl status
  endpoint isn't reachable without a web-UI session.
- No filter/writer version bump — runtime artifacts unchanged.

## 2026.05.12a — 2026-05-12

- **Fix `.plg` FILE block ordering.** The `&pkgURL;` download block now
  precedes the install script, so `upgradepkg` runs against the
  freshly-downloaded `.txz` instead of whatever was cached on flash.
  Previously the install script ran first and used a stale (or missing)
  cached `.txz`, causing silent regressions on upgrades and outright
  install failures for fresh adopters.
- **Filter version banner fixed.** `unraid-readonly-ssh-setup.sh`'s
  install-time output line said "Filter: ... v7" — a stale label not
  bumped when filter went v7 → v8 → v9. Now reads v9. Runtime artifact
  unchanged (the deployed filter has always carried the correct
  `# Filter version:` marker; this was install-stdout cosmetic only).
- No runtime behaviour changes from `2026.05.07a` — filter `v9`, writer
  `v4` unchanged.

## 2026.05.07a — 2026-05-07

- **First public release.** Repo published at
  [github.com/ctrlbreak/unraid-claude-ssh-plugin](https://github.com/ctrlbreak/unraid-claude-ssh-plugin).
  Install from the Unraid web UI by pasting the release `.plg` URL:
  `https://github.com/ctrlbreak/unraid-claude-ssh-plugin/releases/latest/download/claude-ssh.plg`.
- `.plg` now points at the GitHub release for the matching version (rather
  than expecting a side-loaded `.txz` on flash) and declares an `<MD5>` so
  the plugin manager verifies integrity before extracting. CI substitutes
  the real md5 into the in-repo `__MD5__` placeholder on tag push.
- The Unraid plugin update check now resolves against
  `releases/latest/download/claude-ssh.plg`, so installed instances detect
  new releases automatically.
- No runtime behaviour changes from `2026.05.06c` — filter `v9` and writer
  `v4` unchanged. This release is the publishing event, not a feature.

## 2026.05.06c — 2026-05-06

- Configurable SSH username (setup-time only). Setup scripts read
  `CLAUDE_SSH_USERNAME` from env or `/boot/config/plugins/claude-ssh/username`
  (single-line file), defaulting to `claude`. Validated against
  `^[a-z][a-z0-9-]{0,31}$`. Existing installs unaffected — defaults match
  prior behaviour.
- `install-runtime.sh` resolves the username, exports it for child setup
  scripts, and seeds the persisted file on first install (never overwritten,
  so explicit user choice survives upgrades).
- `claude-write-setup.sh` substitutes the resolved username into the sudoers
  principal so a non-default SSH user receives the matching grants.
- `exec.php` derives `/home/<user>/` paths and the `/etc/passwd` existence
  check from the same source. Status payload exposes the configured username
  so the Settings page surfaces it on the Health KPI.
- New `test-username-configurable.sh` (32 cases) — drift check across the
  four shell scripts, env/file/default precedence, validation rejects,
  sudoers principal parameterisation, install-runtime seeding.

## 2026.05.06b — 2026-05-06

- Settings UI: Allowlist editor on the Settings/Status tab. Two textareas for
  plugin and container names, Save and Reload buttons, status pane.
  Server-side validation against the same name regex used by the filter and
  writer. Atomic write to `allowlist.cfg` via temp-file plus rename. Header
  comment block is regenerated on every save (manual edits to comments and
  unrelated lines are not preserved through the UI).
- `exec.php`: new `load_allowlist` and `save_allowlist` routes; helper
  functions `load_allowlist_file` and `save_allowlist_file` are also callable
  directly from PHP CLI for tests (dispatcher early-returns under cli SAPI).
- New `test-settings-save.sh` exercises the save/load round-trip with a
  35-case sandbox suite (skips if php is not installed).
- `test-claude-write-validation.sh` extended to assert `exec.php` uses the
  same allowlist path default, env-var override, and name regex as the
  shell side.

## 2026.05.06a — 2026-05-06

- **Filter v9 + writer v4:** `hook-sonarr` / `hook-radarr` categories
  collapsed into a generic `appdata-script` category. New 3-arg form:
  container name plus basename, target
  `/mnt/user/appdata/<container>/scripts/`. Container allowlist added to
  `allowlist.cfg` as `container <name>` lines (same parser and name regex
  as the plugin allowlist; default-deny when empty). Allowlist parser is
  now parametric on line-prefix; filter and writer both reuse it.
- **BREAKING:** `hook-sonarr` / `hook-radarr` no longer accepted. Migrate to
  `appdata-script sonarr` / `appdata-script radarr` and add the matching
  `container` lines to `allowlist.cfg`.
- `exec.php` counters: dropped `hook-sonarr` / `hook-radarr` rows; added
  `appdata-script`.
- `install-runtime.sh` seed template extended with container examples.

## 2026.05.06 — 2026-05-06

- **Filter v8 + writer v3:** plugin-name allowlist moved to runtime config at
  `/boot/config/plugins/claude-ssh/allowlist.cfg`. Default-deny when empty.
- `install-runtime.sh` seeds a commented-template `allowlist.cfg` on first
  install (existing files never overwritten).
- New tests: `test-allowlist-config.sh` (parser behaviour) +
  `test-boot-config-write-block.sh` (filter blocks writes to `/boot/config/`).

## 2026.05.04 — 2026-05-04

- Initial release: packages claude SSH filter v7 + claude-write writer v2.
- Single-tab Status page with collapsible Audit Log section.
- Dashboard tile showing filter version + 24h activity.
- Filter v7: plugin-name parameterised plugin-* categories, new `scratch`
  category.
- Idempotent install/upgrade — re-runs setup scripts, single
  `/boot/config/go` entry.
- Non-destructive uninstall — preserves `/home/claude/`, backups, user
  account.
