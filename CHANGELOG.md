# Changelog

Mirror of the `<CHANGES>` block in `claude-ssh.plg`. The `.plg` is the
canonical source — this file is for readability and git-friendly diffs.

Format: each section is a plugin version. Plugin versions are date-based
(`YYYY.MM.DD[a-z]`) — the suffix increments when multiple releases happen on
the same day. The filter and writer have independent version markers
(see [docs/upgrading.md](docs/upgrading.md)).

## 2026.06.05b — 2026-06-05

- **Security fix (filter `v14`): SSH command-separator bypass closed.** The
  filter's chaining check was a regex denylist that only caught `;` followed
  by whitespace, `&&`, and `||`. It missed `;` with no trailing space
  (`ls ;rm`), a bare `&` background operator (`ls & rm`), and embedded
  newlines — all of which bash honours as command separators. Because the
  filter validates a tokenised approximation but executes the raw command via
  `bash -c`, those forms ran an arbitrary second command (as the constrained
  user) while the per-segment allowlist only inspected the benign first token.
  This defeated the read-only containment for any SSH-key holder.
- **Fix:** the separator check is now a quote- and backslash-aware scanner
  that flags `;`, `&`, newline (and `||`) only when bash would act on them.
  Quoted or escaped forms stay allowed — `curl "https://h/?a=1&b=2"`,
  `grep "a;b" file`, `find . \( -name x \)`. A single `|` remains the
  pipeline separator (each segment is allowlist-checked).
- **Hardening (filter `v14`): tighter `dmesg` flag guard.** Beyond the
  buffer/console mutators already blocked, `dmesg` now also rejects `-F`/
  `--file` (reads an arbitrary file via dmesg), `-w`/`-W`/`--follow` (never
  returns — hangs the session), and `-H`/`--human` (invokes a pager). Plain
  reads (`dmesg`, `-T`, `-x`, `-e`, `-f`, `| grep ...`) still pass.
- **Hardening (writer `v9`): symlink-safe writes.** The privileged writer no
  longer follows a symlink planted at the destination or used as the target
  directory, and it now writes through an unpredictable `mktemp` name (the old
  predictable temp name was a symlink-follow vector). This matters most for the
  `appdata-script` category, whose target dir can be container-owned and
  group-writable. Defence-in-depth on top of the target-dir-ownership
  assumption documented in the threat model.
- **Hardening: CSRF token on the allowlist save.** The Settings page's
  "Save allowlist" action (which controls the SSH write blast radius) now
  requires Unraid's per-session `csrf_token`, so it can't be driven
  cross-site from a logged-in admin's browser. Read-only views are unchanged.

## 2026.06.05a — 2026-06-05

- **Filter `v12`: a few read-only diagnostics are now allowed.** `which`
  (locate a binary), `iostat` and `smbstatus` (read-only stats), and
  `dmesg` (kernel ring buffer) join the SSH command allowlist. These were
  common, legitimate read-only commands that previously tripped
  `command not in allowlist`.
- **`dmesg` is read-only.** The buffer/console mutators (`-C`/`-c`/`-D`/
  `-E`/`-n` and `--clear`/`--read-clear`/`--console-*`) are blocked; plain
  reads (`dmesg`, `dmesg -T`, `dmesg | grep ...`) pass.
- `command` was deliberately NOT added: `command rm` would run `rm`, so
  allowing it as a command name would bypass the per-segment allowlist.
  `which` covers the actual need.
- `iostat` ships in the `sysstat` package, which may not be installed on a
  stock system; the allowlist entry is harmless if the binary is absent.
- Writer unchanged (`v8`).

## 2026.06.01a — 2026-06-01

- **Fix: SSH public key now survives a reboot.** Unraid rebuilds `/home`
  from RAM on every boot, and earlier versions only ever wrote the pubkey
  to the live `/home/<user>/.ssh/authorized_keys` — so the first reboot
  wiped it and every client got `Permission denied (publickey)`. The
  pubkey is now persisted on flash at
  `/boot/config/plugins/claude-ssh/authorized_keys` and re-applied (with
  the `command=` filter restriction, `root:root 644`) on every boot.
- **Add keys by editing the flash file**, not the live file:
  `echo 'ssh-ed25519 AAAA... comment' >> /boot/config/plugins/claude-ssh/authorized_keys`
  then reinstall or reboot. The live file is regenerated from flash, so
  direct edits to it are lost on the next boot.
- **Upgrade auto-rescue:** if a pre-existing key is found only in the live
  file, it is captured to the flash store on the next setup run (before a
  reboot can wipe it). The flash copy is authoritative thereafter.
- No filter/writer version bump — runtime artifacts unchanged (filter
  `v11`, writer `v8`). The change is in the setup script's key handling,
  outside the filter/writer heredocs.

## 2026.05.13g — 2026-05-13

- **Simplify the Plugins-page icon.** The PNG-shipping approach from
  `2026.05.13d/e` is gone. The `.plg` now declares `icon="key"` as a
  `<PLUGIN>` attribute, which Unraid's `ShowPlugins.php` resolves to
  the FontAwesome `fa-key` glyph directly — the same library and the
  same glyph the Dashboard tile and Settings tab already render via
  `Icon="key"` in their `.page` headers. The icon attribute path
  (`plugin('icon',$plugin_file)`) wins over the disk-PNG fallback and
  treats any non-`.png` value as a FontAwesome class name. Net
  effect: same key visual across all three surfaces, no
  rasterization, no qlmanage workaround, no CC BY 4.0 attribution.
- Drops the PNG (`claude-ssh.png`), the FontAwesome attribution
  from README's License section, and the `test-build.sh` assertion
  that the PNG is packaged.
- No filter/writer version bump — runtime artifacts (the heredoc'd
  filter and writer) are byte-identical with `2026.05.13b/c/d/e/f`
  (filter v11, writer v6).

## 2026.05.13f — 2026-05-13

- **Restore plugin name on the Plugins page.** The in-tree
  `README.md` shipped in `2026.05.13e` was a single description
  paragraph. Unraid's `dynamix.plugin.manager/include/ShowPlugins.php`
  uses the rendered README verbatim and only falls back to a
  `**<name>**` bold-name line when the file is absent — so adding our
  description silently swallowed the title. Every other plugin on the
  page showed bold-name-then-description; ours showed just the
  description.
- Fix: prepend `**Claude SSH**` as its own line in the README so the
  rendered Markdown carries the title AND the blurb (matching the
  Appdata Backup / CA / Dynamix style).
- No filter/writer version bump — runtime artifacts (the heredoc'd
  filter and writer) are byte-identical with `2026.05.13b/c/d/e`
  (filter v11, writer v6).

## 2026.05.13e — 2026-05-13

- **Plugin icon: black on transparent.** The icon shipped in
  `2026.05.13d` rendered onto an opaque white canvas (qlmanage
  thumbnailer rendered the SVG with `(R,G,B,A)=(255,255,255,255)` for
  empty regions instead of `(0,0,0,0)` transparency), producing a green
  key inside a visible white box on the Plugins page. The Dashboard
  tile, by contrast, renders FontAwesome `fa-key` in the page's text
  colour against the tile background — no visible bounding box. This
  release re-renders the FontAwesome `fa-key` glyph in pure black and
  post-processes the PNG alpha so the background is genuinely
  transparent (`A=0` everywhere outside the key; anti-aliased edges
  retain proportional alpha). The Plugins page now shows a black key
  flush against the row background, matching the Settings tab and
  Dashboard tile.
- **Plugins-page description.** Ships a short `README.md` at
  `/usr/local/emhttp/plugins/claude-ssh/README.md` so the Unraid
  plugin manager renders a description line under the plugin name
  (the way Community Applications, Dynamix, and Unraid Connect entries
  carry summaries on the Plugins page). The mechanism is built into
  Unraid core: `dynamix.plugin.manager/include/ShowPlugins.php` reads
  `plugins/<name>/README.md` as Markdown and falls back to just the
  bold plugin name when absent. Text mirrors the GitHub repo
  description so all three surfaces (GitHub About, Plugins page,
  README intro) stay aligned.
- `test-build.sh` asserts both the icon PNG and the in-tree
  `README.md` are in the `.txz`.
- No filter/writer version bump — runtime artifacts (the heredoc'd
  filter and writer) are byte-identical with `2026.05.13b/c/d` (filter
  v11, writer v6).

## 2026.05.13d — 2026-05-13

- **Plugin icon on the Plugins page.** Ships a 128x128 PNG at
  `/usr/local/emhttp/plugins/claude-ssh/claude-ssh.png` so the Unraid
  plugin manager shows a key icon instead of the default green puzzle.
  Visually matches the FontAwesome `fa-key` icon the Settings tab and
  Dashboard tile already use (via `Icon="key"` in the `.page` headers).
  The Plugins page uses a different convention from `.page` files —
  it loads a PNG from disk at `<plugin>.png` matching the plugin name,
  not a FontAwesome reference.
- **Icon attribution.** Derived from FontAwesome Free 5's `fa-key` glyph
  ([CC BY 4.0](https://fontawesome.com/license/free)), rasterized to
  PNG and recoloured to match Unraid's healthy-state green. Attribution
  added to README's License section.
- `test-build.sh` asserts the icon is in the `.txz`.
- No filter/writer version bump — runtime artifacts (the heredoc'd
  filter and writer) are byte-identical with `2026.05.13b/c` (filter
  v11, writer v6).

## 2026.05.13c — 2026-05-13

- **MIT LICENSE shipped in the package.** The repo gained an MIT LICENSE
  at the previous release boundary; this release stages it into the
  plugin tree at build time so installed copies carry the license at
  `/usr/local/emhttp/plugins/claude-ssh/LICENSE`. Makefile copies the
  repo-root `LICENSE` into the plugin tree just before tarring and
  cleans up after; `.gitignore` covers the staged copy. `tests/test-
  build.sh` asserts the file is in the `.txz`.
- No filter/writer version bump — runtime artifacts (the heredoc'd
  filter and writer) are byte-identical with `2026.05.13b` (filter v11,
  writer v6).

## 2026.05.13b — 2026-05-13

- **Collapse `plugin-{page,include,script,cfg}` into a single
  `plugin-file` category.** New argv shape:
  `claude-write plugin-file <plugin> <rel-path>` where `<rel-path>` is a
  relative path under `/usr/local/emhttp/plugins/<plugin>/` with up to 3
  components (basename, `subdir/basename`, or `subdir/subdir/basename`).
  Each component matches `^[a-zA-Z0-9_][a-zA-Z0-9._-]*$`; `..` /
  leading-`/` / trailing-`/` / `//` / leading-`.` all reject. Filter
  bumped to `v11`, writer to `v6`.
- **Extension allowlist on the writer**: `.page .php .cfg .sh .py .js
  .css .html .svg .txt .json`. Mode is driven by extension —
  `.sh` / `.py` → **755**, everything else → 644.
- **Narrow `event/<hook>` extensionless exception** for the Unraid
  event-hook convention. When the rel-path is exactly `event/<hook>`
  (depth-1) and the basename matches `^[a-z][a-z0-9_]{0,32}$`
  (lowercase only), the writer accepts the extensionless basename at
  mode **755**. Nothing else may be extensionless.
- **Sudoers enumerates three rel-path arities** because sudo's `*`
  wildcard does **not** match `/`. The new rule lists
  `plugin-file * *`, `plugin-file * */*`, and `plugin-file * */*/*`
  explicitly. The writer caps depth at 3 components, so a 4-slash
  pattern would be unreachable by construction.
- **Old `plugin-{page,include,script,cfg}` grants and code paths are
  removed in the same commit — no transitional alias.** Direct callers
  of the old category names will fail on first invocation after the
  upgrade. Migrate as follows:
  ```
  claude-write plugin-page    foo Bar.page              ⇒ claude-write plugin-file foo Bar.page
  claude-write plugin-include foo bar.php               ⇒ claude-write plugin-file foo include/bar.php
  claude-write plugin-script  foo bar.py                ⇒ claude-write plugin-file foo scripts/bar.py
  claude-write plugin-cfg     foo bar.cfg               ⇒ claude-write plugin-file foo bar.cfg
  ```
- **Audit log** gains a `rel=<rel-path>` field on `plugin-file` WROTE
  entries; the legacy `category=plugin-{page,include,script,cfg}` keys
  in `exec.php`'s counters are collapsed into the single
  `category=plugin-file` row.
- **Settings UI** label updated (Plugins textarea now lists just
  `plugin-file`); a stale `/boot/config/...` reference on the Allowlist
  heading swapped for the real `/mnt/user/appdata/...` path.
- **Tests**: `test-filter-regression.sh` (rewrite for `plugin-file`
  rel-path shape + 4-component reject), `test-claude-write-validation.sh`
  (cross-check + new drift checks for wrapper byte-identity, priv-binary
  name, env_keep absence, sudoers arity coverage, AND behavioural writer
  cases for every accepted extension and the `event/<hook>` exception),
  `test-sudoers-drift.sh` (asserts all three rel-path arities present and
  no 4-slash pattern), `test-boot-config-write-block.sh` (refreshed to
  use `plugin-file`).

## 2026.05.13a — 2026-05-12

- **Dashboard tile redesign.** Adopts the Unraid 7.x `$mytiles[column1]`
  API so the tile now sits inside the dashboard's column grid (half-width
  like every other tile) instead of rendering as a full-width banner above
  the columns. Gated on Unraid 6.12+ via the `Cond=` page header; older
  versions silently skip the tile.
- **Richer tile content.** Shows installation health (user, filter, writer,
  sudoers, SSH-key count) as inline tick/cross badges, 24h activity broken
  out into accepted / blocked / writes / rejected, and the allowlist size
  (plugins + containers). Status verdict pill (Healthy / Healthy · activity
  blocked / Not installed) sits in the tile-header subtitle. SSH-key label
  correctly pluralises ("1 SSH key" vs "2 SSH keys").
- **Backend `dashboard` action** returns one richer JSON blob per 60s poll
  — same single AJAX call, no extra backend load. Allowlist counts derive
  from the same `load_allowlist_file()` the Settings UI uses, so the tile
  and editor cannot disagree on the count. The legacy `writes_24h` /
  `blocked_24h` aliases are dropped (only the dashboard tile consumed them).
- **New `tests/test-dashboard-action.sh`** pins the JSON shape (19 cases).
  Sandbox-only PHP test; skips with `exit 77` if `php` is missing.
- No filter/writer version bump — runtime artifacts (the heredoc'd filter
  and writer) are byte-identical with `2026.05.12c`.

## 2026.05.12e — 2026-05-12

- **Simplified install banners.** The SSH-setup script's "Setup
  complete!" block dropped from ~30 lines to ~10. The 14-line filter-
  rule summary (Allowlist / Blocked / Flags / xargs / Shell / Allowed /
  Splitting / Forwarding) moved to `docs/filter.md` where it can stay
  comprehensive without dominating every install dialog. The 6 test
  examples shrunk to 2 (one allowed, one blocked) — enough to
  communicate the shape of the filter; the rest live in the docs. The
  claude-write banner dropped from ~42 lines to ~10 in the same
  spirit: the 16-line categories table moved to `docs/categories.md`,
  and the two workstation-usage examples merged into one.
- **Dropped the obsolete "NEXT: redeploy unraid-readonly-ssh-setup.sh"
  line** from the writer banner. It was a leftover from the
  standalone-install workflow. Under the plugin, `install-runtime.sh`
  calls both setup scripts in sequence — so the filter is already
  redeployed by the time the user reads the writer banner. The hint
  was at best redundant, at worst confusing.
- **`install-runtime.sh` now prints a closing summary** with three
  concrete next steps (add an SSH key, edit `allowlist.cfg`, check
  Settings → Claude SSH) plus a pointer to `verify-install.sh` for
  deeper end-to-end verification.
- No filter/writer version bump — runtime artifacts (the heredoc'd
  filter and writer) are byte-identical with `2026.05.12d`.

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
