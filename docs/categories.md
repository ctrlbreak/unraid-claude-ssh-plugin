# Categories reference

Every `claude-write` invocation specifies a **category** as its first argument.
Categories map to a fixed target directory, an allowed-extensions whitelist, a
file mode, and an optional allowlist gate. The set is intentionally small and
flat — adding a new category is a deliberate decision, not a config knob.

## At a glance

| Category | Argv shape | Target directory | Allowed extensions | Mode | Allowlist gate |
|---|---|---|---|---|---|
| `scratch` | `scratch <basename>` | `/tmp/claude-scratch/` | `.sh .py .txt .json .log .conf .md` | 644 (755 for `.sh` / `.py`) | none |
| `plugin-file` | `plugin-file <plugin> <rel-path>` | `/usr/local/emhttp/plugins/<plugin>/<rel-path>` | `.page .php .cfg .sh .py .js .css .html .svg .txt .json` (plus extensionless `event/<hook>`) | 644, or 755 for `.sh` / `.py` / `event/<hook>` | `plugin <name>` |
| `appdata-script` | `appdata-script <container> <basename>` | `/mnt/user/appdata/<container>/scripts/` | `.sh` | 755 | `container <name>` |

## Common rules

**Basename / rel-path validation:**

- `scratch` and `appdata-script` accept a flat basename matching
  `^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$` (1-128 chars, must have an extension,
  no leading dot, no path separators).
- `plugin-file` accepts a **rel-path** under `/usr/local/emhttp/plugins/
  <plugin>/`:
  - Up to **3 path components** (basename, `subdir/basename`, or
    `subdir/subdir/basename`).
  - Each component matches `^[a-zA-Z0-9_][a-zA-Z0-9._-]*$` (leading char
    alnum or `_`; the trailing component carries the extension).
  - Total length ≤ 128 chars.
  - Reject explicitly: `..` anywhere, leading `/`, trailing `/`, empty
    middle component (`//`), leading `.` on any component, any control
    char.
- Every basename must have an extension in the category's allowed list,
  **except** the extensionless `event/<hook>` exception (see below).

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
and rotation to the last 10 entries per
`<category>__<target>[__<subdir-flat>]__<basename>`. For `plugin-file`
writes into a subdirectory the subdir's `/` is flattened to `__` in the
backup key, e.g. `plugin-file__torrent-handler__scripts__nightly.sh`.

## `plugin-file` — extension allowlist & mode

| Extension | Mode |
|---|---|
| `.sh` `.py` | **755** (executable) |
| `.page` `.php` `.cfg` `.js` `.css` `.html` `.svg` `.txt` `.json` | 644 |
| (none) — only under `event/<hook>` | **755** |

Other extensions are rejected.

### The `event/<hook>` exception

Unraid invokes plugin event hooks via files like
`/usr/local/emhttp/plugins/<plugin>/event/started`, `event/stopping_svcs`,
`event/disks_mounted`. By convention these are **extensionless** bash
scripts. `plugin-file` allows an extensionless basename only when:

- The rel-path is exactly `event/<hook>` (depth-1, no further nesting).
- The basename matches `^[a-z][a-z0-9_]{0,32}$` (lowercase letter, then
  lowercase / digit / underscore — case-sensitive).
- Mode is set to **755**.

Nothing else is permitted to be extensionless. `notevent/started` (wrong
subdir), `event/Started` (uppercase), and `event/sub/hook` (nested) all
reject.

## Worked examples

### `scratch` — ephemeral

```bash
echo "hello" | ssh claude@nas 'claude-write scratch hello.txt'
# → /tmp/claude-scratch/hello.txt   mode 644
```

No allowlist required. Files survive in `/tmp` until reboot. Useful for ad-hoc
deploys where you don't want a permanent home, or for piping data through the
NAS as a one-off.

### `plugin-file` — top-level `.page`

```bash
allowlist=/mnt/user/appdata/claude-ssh/allowlist.cfg
echo "plugin torrent-handler" | ssh root@nas "tee -a ${allowlist}"

cat my-tab.page | ssh claude@nas \
  'claude-write plugin-file torrent-handler MyTab.page'
# → /usr/local/emhttp/plugins/torrent-handler/MyTab.page   mode 644
```

The web UI re-scans `.page` files on next request — no service restart needed.

### `plugin-file` — into `scripts/`

```bash
cat my-cron.sh | ssh claude@nas \
  'claude-write plugin-file torrent-handler scripts/nightly.sh'
# → /usr/local/emhttp/plugins/torrent-handler/scripts/nightly.sh   mode 755
```

### `plugin-file` — vendored Python package (3-component)

```bash
cat relink.py | ssh claude@nas \
  'claude-write plugin-file torrent-handler scripts/torrent_handler/relink.py'
# → /usr/local/emhttp/plugins/torrent-handler/scripts/torrent_handler/relink.py
#   mode 755
```

### `plugin-file` — event hook (extensionless)

```bash
cat my-hook.sh | ssh claude@nas \
  'claude-write plugin-file claude-ssh event/started'
# → /usr/local/emhttp/plugins/claude-ssh/event/started   mode 755
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

The category set reflects what real Unraid plugins need: write hooks into
Sonarr / Radarr appdata, write plugin assets (pages, includes, scripts,
configs, JS, CSS, images, event hooks) into in-development plugins, and an
escape hatch (`scratch`) for ad-hoc deploys.

The earlier release (filter v10) had four separate plugin-* categories —
`plugin-page`, `plugin-include`, `plugin-script`, `plugin-cfg` — that each
mapped to a single subdirectory and a single extension. Filter v11 collapsed
those into a single `plugin-file` with a rel-path argument because real
plugins use many subdirectory conventions (`scripts/`, `include/`,
`javascript/`, `sheets/`, `images/`, `event/`, etc.) and the per-subdir
categories left most of them unreachable. The security boundary is the
**plugin allowlist** plus the extension allowlist — not the category name.

If you need a new category (or a new extension under `plugin-file`):

- Patch `unraid-readonly-ssh-setup.sh` (filter source), `claude-write-setup.sh`
  (writer source), and `include/exec.php` (counter row, if adding a category).
- Update `tests/test-sudoers-drift.sh` — the cross-check ensures all four
  sites stay in lockstep.
- Bump `WRITER_VERSION` (and `FILTER_VERSION` if the filter side changed too)
  at the top of the setup script — the runtime contract just moved.
- Add an entry to `CHANGELOG.md` and `claude-ssh.plg`'s `<CHANGES>` block.

That's a deliberate barrier — categories are a security surface, not a config
field.
