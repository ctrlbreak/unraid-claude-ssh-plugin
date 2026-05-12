# Categories reference

Every `claude-write` invocation specifies a **category** as its first argument.
Categories map to a fixed target directory, an allowed-extensions whitelist, a
file mode, and an optional allowlist gate. The set is intentionally small and
flat — adding a new category is a deliberate decision, not a config knob.

## At a glance

| Category | Argv shape | Target directory | Allowed extensions | Mode | Allowlist gate |
|---|---|---|---|---|---|
| `scratch` | `scratch <basename>` | `/tmp/claude-scratch/` | `.sh .py .txt .json .log .conf .md` | 644 (755 for `.sh` / `.py`) | none |
| `plugin-page` | `plugin-page <plugin> <basename>` | `/usr/local/emhttp/plugins/<plugin>/` | `.page` | 644 | `plugin <name>` |
| `plugin-include` | `plugin-include <plugin> <basename>` | `/usr/local/emhttp/plugins/<plugin>/include/` | `.php .sh` | 644 (755 for `.sh`) | `plugin <name>` |
| `plugin-script` | `plugin-script <plugin> <basename>` | `/usr/local/emhttp/plugins/<plugin>/scripts/` | `.py .sh` | 755 | `plugin <name>` |
| `plugin-cfg` | `plugin-cfg <plugin> <basename>` | `/usr/local/emhttp/plugins/<plugin>/` | `.cfg` | 644 | `plugin <name>` |
| `appdata-script` | `appdata-script <container> <basename>` | `/mnt/user/appdata/<container>/scripts/` | `.sh` | 755 | `container <name>` |

## Common rules

**Basename validation** (applies to every category):

- Must match `^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$` (1-128 chars).
- Must have an extension (no `.` prefix, no path separators, no `..`).
- The extension must be in the allowed list for the category.

**Target name validation** (`<plugin>` / `<container>` for 3-arg categories):

- Must match `^[a-z][a-z0-9-]{0,63}$` (lowercase letter then lowercase / digit /
  hyphen, 1-64 chars).
- Must appear as a `plugin <name>` or `container <name>` line in
  `/mnt/user/appdata/claude-ssh/allowlist.cfg`. Default-deny: missing or
  empty allowlist rejects every 3-arg write.

**Stdin** (content for the file being written):

- Bounded by a 30-second read timeout.
- Capped at 2 MiB. Larger payloads are rejected.
- Empty stdin is rejected (use a placeholder character if you really want a
  near-empty file).

**Atomicity:** every successful write is a tempfile-then-rename within the
target directory. Either the new file is fully on disk or the old file is
intact — never half-written.

**Backups:** every write to a non-`scratch` category that overwrites an
existing file backs the prior version up to
`/mnt/cache/appdata/claude-write-backups/` first, with timestamped filenames
and rotation to the last 10 entries per `<category>__<target>__<basename>`.

## Worked examples

### `scratch` — ephemeral

```bash
echo "hello" | ssh claude@nas 'claude-write scratch hello.txt'
# → /tmp/claude-scratch/hello.txt   mode 644
```

No allowlist required. Files survive in `/tmp` until reboot. Useful for ad-hoc
deploys where you don't want a permanent home, or for piping data through the
NAS as a one-off.

### `plugin-page` — Unraid web UI tab

```bash
allowlist=/mnt/user/appdata/claude-ssh/allowlist.cfg
echo "plugin torrent-handler" | ssh root@nas "tee -a ${allowlist}"

cat my-tab.page | ssh claude@nas \
  'claude-write plugin-page torrent-handler MyTab.page'
# → /usr/local/emhttp/plugins/torrent-handler/MyTab.page   mode 644
```

The web UI re-scans `.page` files on next request — no service restart needed.

### `plugin-script` — plugin's `scripts/` directory

```bash
cat my-cron.sh | ssh claude@nas \
  'claude-write plugin-script torrent-handler nightly.sh'
# → /usr/local/emhttp/plugins/torrent-handler/scripts/nightly.sh   mode 755
```

### `appdata-script` — container hook directory

```bash
echo "container sonarr" | ssh root@nas \
  'tee -a /mnt/user/appdata/claude-ssh/allowlist.cfg'

cat my-hook.sh | ssh claude@nas \
  'claude-write appdata-script sonarr post-import.sh'
# → /mnt/user/appdata/sonarr/scripts/post-import.sh   mode 755
```

Works for any container that keeps hooks under
`/mnt/user/appdata/<container>/scripts/`.

## Why these categories?

The category set reflects what the original deployment needed: write hooks
into Sonarr / Radarr appdata, write plugin assets into a few in-development
plugins, and an escape hatch (`scratch`) for ad-hoc deploys. Each category is
defence-in-depth: the SSH filter rejects unrecognised categories at the SSH
layer (advisory), and the privileged writer rejects them again (enforcement).

If you need a category that doesn't fit the table:

- Patch `unraid-readonly-ssh-setup.sh` (filter source), `claude-write-setup.sh`
  (writer source), and `include/exec.php` (counter row).
- Update `tests/test-sudoers-drift.sh` — the cross-check ensures all four
  sites stay in lockstep.
- Bump `WRITER_VERSION` (and `FILTER_VERSION` if the filter side changed too)
  at the top of the setup script — the runtime contract just moved.
- Add an entry to `CHANGELOG.md` and `claude-ssh.plg`'s `<CHANGES>` block.

That's a deliberate barrier — categories are a security surface, not a config
field.
