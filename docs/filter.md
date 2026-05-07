# The shell filter — allowed commands

This is the read-side companion to [`wire-protocol.md`](wire-protocol.md)
(which covers `claude-write`). The filter is what enforces "AI can run only
*safe* commands" — it sits between the SSH session and the kernel, parsing
every command before exec.

## Principle

The filter is **allowlist-based, not denylist-based**. A command is rejected
unless its first token appears in a fixed list (currently 35 commands), and
even allowed commands have specific flags blocked when those flags would let
the caller write files, exec arbitrary code, or escape the read-only
posture. The filter is content with rejecting too much; that's the right
side to err on.

The filter is also **deliberately small in capability surface**. It does not
allow:

- Interactive shells, PTYs, or `bash -i`-style escapes.
- Editors (`vim`, `nano`, `emacs`).
- Anything that runs an arbitrary subprocess (`xargs <untrusted-cmd>`,
  `find -exec`, `awk 'system(...)'`, `curl ... | sh`).
- Any flag that writes to disk (`sed -i`, `curl -O`, `tar -c`).
- Any flag that opens a non-HTTP network channel (`curl ftp://`, `nc`).

What it allows is essentially: **read files, walk the filesystem, parse
text, query system state, fetch data over HTTP(S), assemble pipelines**.
That's enough for an AI agent to investigate, monitor, and explain a NAS;
it's not enough to break it.

## Security model in one diagram

```
ssh user@nas '<command>'
        │
        ▼
┌────────────────────────────────────────────────┐
│ command="..." in authorized_keys forces every  │
│ login to run /home/<user>/shell-filter.sh      │
│ — no shell choice for the SSH user             │
└────────────────────────────────────────────────┘
        │
        ▼
┌────────────────────────────────────────────────┐
│ Filter (set -f noglob, no $SSH_TTY)            │
│ 1. Sanitise harmless redirects (>/dev/null)    │
│ 2. Permit redirects to /tmp/claude-*/          │
│ 3. Reject shell chaining, $(), backticks,      │
│    <(...), >(...), other > redirects           │
│ 4. Quote-aware split on |                      │
│ 5. Per-segment: command in ALLOWED + flag      │
│    safety check                                │
│ 6. xargs: inner command in XARGS_INNER         │
│ 7. claude-write: argv shape + allowlist        │
│ 8. Log RECV / BLOCKED to syslog (auth tag)     │
└────────────────────────────────────────────────┘
        │
        ▼
exec bash -f -c "$CMD"   ← noglob preserved into the executed command
```

The filter is **advisory** — fast, runs at SSH layer, catches obvious
mistakes early. The privileged `claude-write-priv` writer re-validates
every write as **enforcement** (defence-in-depth). The two layers are
unit-tested for lockstep behaviour
([`tests/test-sudoers-drift.sh`](../tests/test-sudoers-drift.sh)).

If the filter wedges (rare; usually requires a malformed update), root
SSH is the escape hatch — the filter only applies to the constrained
SSH user.

## Allowed commands

Grouped by use case. Each entry says what it's used for and notes any
flag restrictions.

### Filesystem inspection

| Command | Use | Restrictions |
|---|---|---|
| `ls` | List directory contents | none |
| `find` | Recursive search by name, type, time, size | **no `-exec`, `-execdir`, `-delete`, `-ok`** (these execute commands or modify files) |
| `stat` | File metadata | none |
| `file` | Detect file type from contents | none |
| `tree` | Directory tree visualisation | none |
| `readlink` | Resolve a single symlink | none |
| `realpath` | Resolve to absolute path | none |
| `basename` | Strip directory from a path | none |
| `dirname` | Strip filename from a path | none |
| `ln` | Create **hard** links only | **no `-s` (symbolic), `-f` (force), `-n`** |

### File contents

| Command | Use | Restrictions |
|---|---|---|
| `cat` | Read a file | none |
| `head` | Read first N lines / bytes | none |
| `tail` | Read last N lines / bytes (no `-f` semantically blocked since pipelines complete; works fine for finite tails) | none |
| `wc` | Line / word / byte count | none |
| `md5sum`, `sha256sum` | Compute checksums | none |
| `zcat` | Read gzip-compressed files | none |

### Text processing / pipelines

| Command | Use | Restrictions |
|---|---|---|
| `grep` | Pattern match (basic / extended / Perl regex) | none |
| `awk` | Field processing, summarisation | **no `> "file"`** (file output redirection inside the awk script) |
| `sed` | Stream editing | **no `-i`** (in-place edit) |
| `sort` | Sort lines | none |
| `uniq` | Deduplicate adjacent lines | none |
| `cut` | Extract columns by character / field | none |
| `tr` | Translate / squeeze / delete characters | none |
| `diff` | Compare two files | none |
| `comm` | Compare two **sorted** files line-by-line | none |
| `xargs` | Build commands from stdin | **inner command must be in `XARGS_INNER` sub-allowlist** (see below) |

### System / monitoring

| Command | Use | Restrictions |
|---|---|---|
| `df` | Filesystem free space | none |
| `du` | Directory tree usage | none |
| `uname` | Kernel / OS info | none |
| `uptime` | Load averages, time since boot | none |
| `hostname` | Host's name | none |
| `date` | Current time / formatted output | none |
| `id`, `whoami` | Current effective user | none |
| `ps` | Process listing | none |
| `getent` | Name-service lookups (`passwd`, `group`, `hosts`, `services`) | none |
| `groups` | Group membership for a user | none |
| `last` | Login history from `/var/log/wtmp` | none |
| `who` | Currently logged-in users | none |

### Network (read-only)

| Command | Use | Restrictions |
|---|---|---|
| `curl` | HTTP(S) GET requests | **GET only — no `-X`/`--request`, `-d`/`--data*`, `-F`/`--form*`, `-T`/`--upload-file`, `-o`/`--output`, `-O`/`--remote-name`, `-J`/`--remote-header-name`, `-K`/`--config`, `-c`/`--cookie-jar`, `-D`/`--dump-header`, `--trace*`, `--next`, `--parallel`, `--libcurl`. Schemes: only `http://` and `https://` — no `file://`, `gopher://`, `dict://`, `scp://`, `sftp://`, `smb://`, `ldap://`, `tftp://`, `imap://`, `smtp://`, `pop3://`, `telnet://`, `rtmp://`, `rtsp://`** |

### Archive inspection

| Command | Use | Restrictions |
|---|---|---|
| `tar` | List archive contents | **must include `-t` or `--list` — `-x` / `-c` / `-r` / `-A` / `-u` / `-U` / `--extract` / `--get` / `--create` / `--append` / `--update` / `--catenate` / `--concatenate` / `--delete` blocked** |

### Output / formatting

| Command | Use | Restrictions |
|---|---|---|
| `echo`, `printf` | Emit text | none |
| `numfmt` | Format / parse human-readable numbers | none |
| `jq` | JSON parse / filter / transform | none (jq's `--rawfile` and similar are file *reads* only; jq cannot write) |

### Filesystem mutation (limited)

| Command | Use | Restrictions |
|---|---|---|
| `mkdir` | Create directory | **only `-p` flag** (block `-m` for permissions and others) |
| `ln` | Create hard links | (see Filesystem inspection above) |

### The deploy channel

| Command | Use | Where |
|---|---|---|
| `claude-write` | Atomic file deploy to allowlisted locations | full reference in [`wire-protocol.md`](wire-protocol.md) and [`categories.md`](categories.md) |

## xargs sub-allowlist

`xargs` is a special case: it spawns its inner command directly via
`execvp`, bypassing the filter that validated the surrounding pipeline.
The filter compensates by validating the inner command name against a
**stricter** sub-allowlist:

```
cat stat head tail grep wc ls file readlink md5sum sha256sum awk cut sort uniq
```

This is intentionally narrower than the main allowlist — only commands
that read files / process text. Specifically excluded from the inner
allowlist: `find`, `sed`, `curl`, `tar`, `xargs` itself, every system /
monitoring command, and `claude-write`. Reason: even with the main
allowlist's flag restrictions, `xargs <cmd>` lets the caller invoke
`<cmd>` with arguments derived from stdin — so a sub-allowlist of "things
where the worst case is reading a file" keeps the surface tight.

`xargs` also requires an **explicit inner command** — `cat foo | xargs`
(stdin-as-command) is rejected.

## Global rules

Beyond the per-command checks, the filter applies these rules to every
command before per-segment validation runs:

### Globbing is disabled

`set -f` means `*`, `?`, `[abc]` etc. don't expand against the SSH user's
home directory during validation. `exec bash -f -c "$CMD"` preserves
noglob into the executed command, so the executed pipeline sees the same
arguments the filter validated. Pattern: `find /mnt/user -name '*.log'`
works because the `*` is inside quotes; `cat *.log` would fail because the
unquoted `*` would have globbed before reaching the filter — but wouldn't
glob *here* because of `-f`, so the literal `*.log` is what's checked,
which would fail file existence. Either way, you don't get unintended
file expansion.

### Pipelines are quote-aware

`|` inside single or double quotes is treated as data, not a pipeline
separator. So `grep 'foo|bar' file` works (treated as one segment with a
regex containing `|`), and `cmd1 | cmd2` is split into two segments,
each validated independently.

### Shell chaining is blocked

`;`, `&&`, `||` between commands → rejected. The filter doesn't try to
parse "what's the next command after `;`"; it just refuses to allow the
construct. Use a single pipeline or call separately.

### Command substitution is blocked

`$(...)` and backticks → rejected. Reason: the inner command would run
*before* the filter can validate it.

### Process substitution is blocked

`<(...)` and `>(...)` → rejected. Reason: same as command substitution —
the inner command runs in a subshell that bypasses the per-segment
validation entirely. (This was a v6 fix; earlier versions missed it.)

### File redirects are restricted

The filter strips harmless redirects (`>/dev/null`, `2>/dev/null`,
`2>&1`, `&>/dev/null`) before validation runs, so they're effectively
free.

The only file redirect *target* allowed is `/tmp/claude-*/<path>` — a
scratch namespace under tmpfs (RAM-backed, cleared on reboot). This lets
clients cache big query results without round-tripping over SSH:

```
find /mnt/user -name '*.log' -newer /tmp/claude-cache/marker > /tmp/claude-cache/logs.txt
```

Path traversal (`..`) anywhere in the redirect target is rejected before
the strip step runs.

Any other `>` or `>>` redirect → rejected. Even to a directory the SSH
user could write to anyway. The filter is conservative.

### Audit log

Every command, accepted or rejected, lands in syslog with the
`claude-shell` tag and `auth` facility:

```
claude-shell: RECV: <command>                    (info — every received command)
claude-shell: BLOCKED [<reason>]: <command>      (warning — every rejection)
```

Visible from the Settings → Claude SSH → Audit Log tab in the Unraid web
UI, or via `grep claude-shell /var/log/syslog` in a root SSH session.

## What's blocked (categories)

Beyond what's already enumerated above, a non-exhaustive list of common
shell idioms the filter rejects. Each is here because it would let a
caller escape the read-only posture or run unvalidated code.

| What | Why blocked |
|---|---|
| Editors (`vim`, `nano`, `emacs`, `vi`) | They drop into PTYs and modify files |
| `bash`, `sh`, `zsh`, `python`, `perl`, `node` | Spawn arbitrary code |
| `chmod`, `chown` | Modify file permissions / ownership |
| `rm`, `cp`, `mv` (outside `claude-write`) | Modify files |
| `kill`, `killall`, `pkill` | Affect running processes |
| `systemctl`, `service`, `rc-service` | Affect system services |
| `docker`, `podman` | Affect containers (ps via `ps` is allowed) |
| `nc`, `ncat`, `socat` | Open arbitrary network channels |
| `wget` | A `curl` alternative without the careful flag-blocking; better to enforce one tool's safe flags than two |
| `ssh`, `scp`, `sftp`, `rsync` | Pivot to other hosts |
| `mount`, `umount`, `losetup` | Filesystem manipulation |
| `dd` | Bulk-copy / overwrite blocks |
| `apt`, `pkg`, `yum`, `slackpkg` | Install / remove packages |
| `iptables`, `nft`, `ip` | Modify networking |

These don't need explicit denylist entries — they're rejected by virtue
of not being on the allowlist.

## Adding a command to the allowlist

The allowlist is **source-controlled**, not config. Adding a command
requires a code change:

1. Edit `ALLOWED` in
   [`src/usr/local/emhttp/plugins/claude-ssh/scripts/unraid-readonly-ssh-setup.sh`](../src/usr/local/emhttp/plugins/claude-ssh/scripts/unraid-readonly-ssh-setup.sh).
2. If the command has flags that need blocking, add a `case` arm.
3. If `xargs` should be able to invoke it, add to `XARGS_INNER`.
4. Bump the filter version (`# Filter version: vN` near the top of the
   file).
5. Update [`tests/test-filter-regression.sh`](../tests/test-filter-regression.sh)
   with a new accept case.
6. Bump the plugin version + add a `<CHANGES>` entry per
   [`releasing.md`](releasing.md).

This is a deliberate barrier — every allowlist entry is a security
surface, and config-driven extensions would mean an installed plugin
could be widened by an attacker who got write access to `/boot/config/`
(which the filter explicitly blocks today). Code-only changes pin the
allowlist to whatever was reviewed and released.

## Useful invocation patterns

A few pipelines that work and are worth bookmarking. Useful for AI
clients writing diagnostic code; useful for humans verifying the filter
allows what you'd expect.

```bash
# Disk usage of every appdata container, sorted descending.
du -sh /mnt/user/appdata/* | sort -hr

# Look for recently-modified files under a plugin's scripts dir.
find /usr/local/emhttp/plugins/claude-ssh/scripts -mmin -60 -type f

# Health-check a webhook by HTTP HEAD via curl GET (no -I needed).
curl -sS -o /dev/null -w '%{http_code}\n' https://example.com/webhook

# JSON inspection of a Sonarr API response (assuming you've set up an
# unauthenticated localhost endpoint or stored a key in syslog).
curl -sS http://localhost:8989/api/v3/series | jq '.[].title' | sort

# Cache a big find result in /tmp/claude-cache/ for later filtering.
mkdir -p /tmp/claude-cache
find /mnt/user -name '*.mkv' > /tmp/claude-cache/mkvs.txt
wc -l /tmp/claude-cache/mkvs.txt

# Tail the audit log for claude-write activity.
tail -n 200 /var/log/syslog | grep claude-write

# Hash a config file before and after a deploy to confirm no drift.
sha256sum /usr/local/emhttp/plugins/claude-ssh/scripts/install-runtime.sh
```

If you find yourself wanting a command that's not on the allowlist for a
read-only diagnostic, file an issue against the repo — the bar is
"defensible read-only behaviour" not "this would be convenient".
