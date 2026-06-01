# Troubleshooting

The most common failures, what they look like, and how to fix them. Each
entry has a **symptom** (what you see), a **likely cause**, and a **fix**.

## SSH connection: "Permission denied (publickey)"

**Symptom:**

```
$ ssh -i ~/.ssh/claude_unraid claude@nas 'claude-shell ping'
claude@nas: Permission denied (publickey).
```

**Likely cause:** the public key isn't in the SSH user's live `authorized_keys`.
The classic trigger is the **first reboot**: Unraid rebuilds `/home` from RAM on
boot, and the plugin re-seeds the live `authorized_keys` from its flash copy at
`/boot/config/plugins/claude-ssh/authorized_keys`. If that flash copy is empty
(e.g. on an older plugin the key was only ever added to the live file), the live
file comes back empty after the reboot and the server rejects your key.

**Fix:** from a root SSH session on the NAS, make sure your pubkey is in the
flash store (the source of truth), then re-apply it:

```bash
# 1. Confirm/add your pubkey to the flash copy:
grep -qF 'ssh-ed25519 AAAA...' /boot/config/plugins/claude-ssh/authorized_keys \
  || echo 'ssh-ed25519 AAAA... claude-unraid' \
       >> /boot/config/plugins/claude-ssh/authorized_keys

# 2. Re-apply it to the live file (this is also what runs on every boot):
bash /usr/local/emhttp/plugins/claude-ssh/scripts/install-runtime.sh

# 3. Verify — the live file is deliberately root:root 644 with a command= prefix:
ls -la /home/claude/.ssh/authorized_keys
#   -rw-r--r-- root root   authorized_keys
cat /home/claude/.ssh/authorized_keys
#   command="/home/claude/shell-filter.sh",no-port-forwarding,... ssh-ed25519 AAAA...
```

Don't `chown` the live file back to `claude` or `chmod 600` it — the plugin
locks it to `root:root 644` on purpose (a compromised SSH user must not be able
to rewrite its own `authorized_keys` and drop the `command=` restriction).

If the user is named something other than `claude`, substitute throughout
(`cat /boot/config/plugins/claude-ssh/username`).

## Filter rejection: "BLOCKED"

**Symptom:** any rejected SSH command produces a structured BLOCKED line on
stderr and exit code 1.

```
$ ssh claude@nas 'ls /etc/'
BLOCKED [unknown command 'ls']
```

**Likely cause:** the command isn't on the SSH filter's allowlist. `ls`,
`cat`, `grep`, etc. are accepted; editors, shells, and most write commands
are not.

**Fix:** rephrase using a command from the allowlist. See
[`filter.md`](filter.md) for the full enumeration with flag restrictions
and global rules; [`wire-protocol.md`](wire-protocol.md) covers the
`claude-write` argv shapes.

## Writer rejection: "name not in allowlist"

**Symptom:**

```
$ cat foo.sh | ssh claude@nas 'claude-write appdata-script sonarr foo.sh'
claude-write: REJECTED — container-name 'sonarr' not in allowlist
```

**Likely cause:** the allowlist doesn't have a `container sonarr` line, or
the file is missing entirely (default-deny).

**Fix:** add the entry. From the Settings UI:

- Settings → Claude SSH → Allowlist → "Containers" textarea → add `sonarr`
  on its own line → Save.

Or from the shell as root:

```bash
echo "container sonarr" >> /mnt/user/appdata/claude-ssh/allowlist.cfg
```

The writer reads the allowlist on every invocation, so the change takes
effect immediately — no service restart.

## Writer rejection: "extension not allowed"

**Symptom:**

```
$ cat program.exe | ssh claude@nas 'claude-write plugin-file foo program.exe'
claude-write: REJECTED — extension 'exe' not allowed for plugin-file (need: page php cfg sh py js css html svg txt json)
```

**Likely cause:** the basename's extension isn't in the category's
whitelist.

**Fix:** rename the file or use a category that accepts the extension. See
the [categories reference](categories.md) for the full table. Note: the
only path that accepts an extensionless basename is `plugin-file` under
`event/<hook>` (depth-1, lowercase). Everywhere else a file extension is
required.

## Status tab: filter / writer version mismatch

**Symptom:** Settings → Claude SSH → Status shows an older filter or writer
version than what the installed plugin's setup scripts declare
(`FILTER_VERSION` / `WRITER_VERSION` at the top of `scripts/*.sh`).

**Likely cause:** the live filter at `/home/<user>/shell-filter.sh` is stale.
This happens if a manual install pre-dates the plugin and the plugin's
install hook didn't re-render — usually because the `/boot/config/go` legacy
hook is still pointing at a frozen `/boot/config/claude-ssh-setup.sh`.

**Fix:** re-run the plugin's install hook. From a root SSH session:

```bash
bash /usr/local/emhttp/plugins/claude-ssh/scripts/install-runtime.sh
```

It's idempotent, so this is safe to re-run any time. After it runs, refresh
the Status tab — the version should match.

If the version still doesn't match, the migration block didn't strip the
legacy hooks. Check `/boot/config/go`:

```bash
grep -E "Claude (read-only|write deploy)" /boot/config/go
# Expected: nothing (legacy hooks should be stripped).
```

If there are legacy lines, they're getting re-applied on every boot and
overwriting the packaged filter. Manual cleanup:

```bash
sed -i '/^# Claude read-only SSH user setup$/,/^$/d; /^# Claude write deploy channel$/,/^$/d' /boot/config/go
```

Then re-run `install-runtime.sh`.

## Status tab: "User claude not ready"

**Symptom:** Health KPI red. Status payload says the user doesn't exist or
the filter file is missing.

**Likely cause:** the install hook failed partway through. Most common
reason is a username collision — `useradd` refused because the chosen
username already exists as a system user.

**Fix:** check syslog for the install error:

```bash
grep claude-ssh-plugin /var/log/syslog | tail -50
```

If you see `useradd: user '<name>' already exists` and the `<name>` is one
you set via `CLAUDE_SSH_USERNAME`, pick a different name and re-run:

```bash
echo myaibot > /boot/config/plugins/claude-ssh/username
bash /usr/local/emhttp/plugins/claude-ssh/scripts/install-runtime.sh
```

## Filter wedged: lockout from the SSH user

**Symptom:** `ssh claude@nas '<anything>'` immediately disconnects with no
output, or hangs indefinitely.

**Likely cause:** the filter script has been overwritten by something
malformed (rare; usually requires manual editing as root). The SSH login
runs `bash /home/claude/shell-filter.sh "$SSH_ORIGINAL_COMMAND"` and a
broken filter exits before producing output.

**Fix:** root SSH is your escape hatch — it bypasses the filter entirely.

```bash
ssh root@nas
# Re-render the filter from the plugin source:
bash /usr/local/emhttp/plugins/claude-ssh/scripts/install-runtime.sh
```

If you want to test the filter without going through SSH:

```bash
SSH_ORIGINAL_COMMAND='claude-shell ping' bash /home/claude/shell-filter.sh
```

## Writer fails silently: "sudo: a password is required"

**Symptom:** logs show:

```
sudo: a password is required
```

The wrapper exits 1 but the SSH connection itself succeeded.

**Likely cause:** the sudoers grant isn't installed or has the wrong
principal (e.g. you switched the SSH username but the sudoers fragment still
references the old name).

**Fix:** check the sudoers file:

```bash
cat /etc/sudoers.d/claude-write
# Expected: <username> ALL=(root) NOPASSWD: /usr/local/sbin/claude-write-priv ...
```

Re-render if the principal is wrong:

```bash
bash /usr/local/emhttp/plugins/claude-ssh/scripts/install-runtime.sh
```

If `/etc/sudoers.d/` isn't honoured by your sudo build (very rare on Unraid),
the setup script falls back to appending to `/etc/sudoers` directly with a
managed marker block. Look for `# claude-write deploy channel — managed by
claude-write-setup.sh` in `/etc/sudoers`.

## Writer rejection: "stdin read failed or timed out"

**Symptom:**

```
claude-write: REJECTED — stdin read failed or timed out (>30s)
```

**Likely cause:** the client took longer than 30 seconds to send all of stdin.
This is the slow-loris guard, intentional.

**Fix:** make the client send stdin promptly. If you're piping a `curl`
download, fetch it locally first and pipe from disk. If you genuinely need to
write a file > 2 MiB, this plugin is the wrong tool — use `rsync` over a
separate channel (with its own access control).

## Writer rejection: "content exceeds 2097152B limit"

**Symptom:**

```
claude-write: REJECTED — content exceeds 2097152B limit (got 3145728)
```

**Likely cause:** the payload is > 2 MiB. Bounded by design — this writer is
for hooks and small plugin assets, not bulk data.

**Fix:** split the file or use a different transport. The 2 MiB cap is set
in `claude-write-setup.sh` (`MAX_SIZE`) — if you genuinely need to raise it
for a custom deployment, edit the source, bump the writer version, and
rebuild.

## Plugin install fails: "smoke tests FAILED"

**Symptom:** plugin install output ends with:

```
[claude-ssh] SMOKE FAIL: ...
[claude-ssh] install-runtime.sh: smoke tests FAILED — see above
```

**Likely cause:** one of the four runtime artifacts (user, filter, wrapper,
priv-writer, sudoers grant) didn't land. The lines above the SMOKE FAIL show
which.

**Fix:** read the syslog for the underlying error:

```bash
grep claude-ssh-plugin /var/log/syslog | tail -100
```

Common upstream reasons:
- `useradd` failed (username collision — see above).
- `visudo -c` rejected the sudoers fragment (almost always means the
  username has invalid characters; the resolver should have caught this but
  if you bypassed it manually, fix the username).
- `chown / chmod` failed on `/usr/local/bin/claude-write` (filesystem mounted
  read-only? out of inodes?).

## Last-resort recovery

If everything is wedged and you can't even SSH as root, the recovery path is
the same as for any Unraid issue:

1. Plug a keyboard + monitor into the NAS, log in as root at the console.
2. Disable the plugin's go-script entry by commenting it out:
   ```bash
   sed -i 's|^bash /usr/local/emhttp/plugins/claude-ssh/scripts/install-runtime.sh|# &|' /boot/config/go
   ```
3. Reboot. The plugin's runtime artifacts won't re-render — you have a clean
   recovery state.
4. Investigate, fix, re-enable the line, reboot.

If `/boot/config/go` itself is corrupted, restore from a flash backup. Unraid's
`Tools → My Servers / Flash Backup` (or any rsync of `/boot/`) is the
authoritative source.
