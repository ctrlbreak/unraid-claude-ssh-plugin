# Wire protocol

Reference for clients writing scripts that drive `claude-write` over SSH.
This is the contract surface — argv shapes, validation rules, exit codes,
syslog format. Treat it as authoritative; the README and category docs are
secondary.

## Invocation shape

```
ssh <flags> <user>@<host> '<command>' < <stdin>
```

Where `<command>` is one of:

```
claude-shell <args...>           # read-only inspection (out of scope here)
claude-write <category> <args> [extra-args]
```

The SSH filter parses `<command>` against a fixed grammar. Unknown commands,
extra whitespace not part of an argument, or shell metacharacters
(`; & | > < $ \` etc.) outside a quoted argument are rejected.

## `claude-write` argv shapes

### Simple (2-arg)

```
claude-write scratch <basename>
```

### Plugin (3-arg)

```
claude-write plugin-page    <plugin-name> <basename>
claude-write plugin-include <plugin-name> <basename>
claude-write plugin-script  <plugin-name> <basename>
claude-write plugin-cfg     <plugin-name> <basename>
```

### Container (3-arg)

```
claude-write appdata-script <container-name> <basename>
```

Any extra argument after the documented arity is rejected (`reject "unexpected
extra args"`).

## Argument validation

| Argument | Pattern | Notes |
|---|---|---|
| `<category>` | one of the seven listed above | unknown → reject |
| `<plugin-name>` / `<container-name>` | `^[a-z][a-z0-9-]{0,63}$` | must also be in `allowlist.cfg` |
| `<basename>` | `^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$` | no leading `.`, no `/`, no `..` |
| extension | category-specific allowlist | derived from `<basename>` after the last `.` |

## Stdin

- Read on every successful argv parse (rejects don't read stdin).
- Bounded by a **30-second** timeout (`timeout 30 head -c …`). Slow stdin
  is rejected with `stdin read failed or timed out`.
- Capped at **2 MiB** (`2 * 1024 * 1024` bytes). Larger payloads are
  rejected with `content exceeds 2097152B limit`.
- **Empty stdin is rejected.** If you need a near-empty file, write at least
  one byte (a comment, a newline-terminator, etc.).

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Write succeeded. Stdout: `claude-write: OK` plus a multi-line confirmation block (`category`, `plugin/container`, `dest`, `size`, `mode`, `sha256`, `backup`). |
| `1` | Validation rejected the request, or stdin failed, or write failed. Stdout: nothing on stdout; stderr: `claude-write: REJECTED — <reason>`. |
| `124` / `137` | Stdin timeout (rolled up into `1` by the writer's reject path). |

The SSH filter on its own can also produce its own rejections at the SSH
layer, before the writer sees the argv at all. Those produce a structured
`BLOCKED` stderr line and exit code `1`.

## Stdout on success

```
claude-write: OK
  category: <cat>
  plugin:   <name>      ← only for 3-arg categories
  dest:     <full-path-on-NAS>
  size:     <bytes>
  mode:     <octal>
  sha256:   <hex-digest>
  backup:   <path-or-(no prior file)>
```

The sha256 lets a client verify the write landed unmodified — compare against
the sha256 of what was sent. The dest is canonical (no symlink resolution
beyond what the kernel already did).

## Stderr on rejection

```
claude-write: REJECTED — <reason>
```

Common reasons:

- `missing category`
- `unknown category '<value>'`
- `missing plugin-name` / `missing container name` / `missing basename`
- `unexpected extra args`
- `<kind>-name '<value>' not in allowlist`
- `invalid basename '<value>'`
- `basename must match [a-zA-Z0-9._-], 1-128 chars`
- `basename must have extension`
- `extension '<ext>' not allowed for <cat> (need: <list>)`
- `empty stdin`
- `content exceeds 2097152B limit (got <bytes>)`
- `stdin read failed or timed out (>30s)`

The reason strings are part of the contract — they're what client error
handling can `grep` against. New rejection paths in future versions should
add new reason strings rather than rewording existing ones.

## Audit log

Every accept and reject lands in syslog (`/var/log/syslog`) with:

- **Tag:** `claude-write` (writer) or `claude-shell` (filter)
- **Facility:** `auth`
- **Priority:** `notice` for accepts, `warning` for rejects

Format on accept (writer):

```
claude-write: WROTE category=<cat> [plugin=<name>|container=<name>] dest=<path> size=<bytes> sha256=<hex> backup=<path-or-none>
```

Format on reject (writer):

```
claude-write: REJECTED [<reason>] argv: <full-argv>
```

Format on filter reject:

```
claude-shell: BLOCKED [<reason>] cmd=<command>
```

Field names are stable across patch versions. Don't rely on specific field
ordering — parse by name (`category=`, `dest=`, etc.).

## Sample client (bash)

See [`examples/deploy-via-claude-write.sh`](../examples/deploy-via-claude-write.sh)
for a 30-line working client that handles each category and surfaces both the
sha256 confirmation and the reject reason.

## Versioning

The wire protocol changes with the **writer version**. The writer comments
its version into the live script (`/usr/local/sbin/claude-write-priv`) and
the Status page reads it. Major writer-version bumps mean clients may need
updating; patch-level changes preserve argv shapes and exit codes.

| Writer version | Change |
|---|---|
| `v4` (current) | Collapsed `hook-sonarr` / `hook-radarr` into `appdata-script <container>`. |
| `v3` | Plugin-name allowlist moved to runtime config. |
| `v2` | Plugin-name parameterised; new `scratch` category. |
| `v1` | Initial. |

The filter and writer versions are coupled — every release bumps both
together when the contract surface changes.
