# Threat model

This plugin gives a remote AI client (or any holder of the SSH key) a narrow,
audited write channel into specific directories on an Unraid NAS. The threat
model is "limit blast radius if the SSH key leaks or the AI client
misbehaves" — not "defeat a determined attacker who already has root."

## What this protects against

### A leaked SSH key

If the private key ends up somewhere it shouldn't (a stolen workstation, a
git repo, a compromised CI runner), the holder still cannot:

- Log in to a shell. The SSH user's only shell is the filter
  (`/home/<user>/shell-filter.sh`) — no PTY, no interactive shell.
- Run arbitrary commands. Only the small allowlist documented in
  [`filter.md`](filter.md) is accepted; everything else is rejected with a
  structured `BLOCKED` log.
- Write to `/boot/config/`. The SSH filter rejects any path under
  `/boot/config/` (the runtime allowlist lives there).
- Write to filesystem locations not in the category map. `claude-write`
  callers can only target the three category surfaces enumerated in
  [categories.md](categories.md): `/tmp/claude-scratch/` (ephemeral),
  `/usr/local/emhttp/plugins/<allowlisted-plugin>/<rel-path>` (depth-capped
  at 3 components, with an extension allowlist), and
  `/mnt/user/appdata/<allowlisted-container>/scripts/`.
- Escalate to root via the writer. The writer is invoked through `sudo` with
  an argv-pinned NOPASSWD rule — the wrapper is the only command the user
  can sudo. Sudo's `*` matches any sequence of characters **except `/`**,
  so each wildcard slot eats one path component, not "any string". The
  `plugin-file` rule therefore enumerates all three rel-path arities
  explicitly (`plugin-file * *`, `plugin-file * */*`, `plugin-file *
  */*/*`); the writer caps slash count at 2 so a 4-slash pattern would be
  unreachable. No shell metacharacters reach the writer, no extra-args
  injection past the enumerated patterns.

### A buggy or adversarial AI client

If the client (Claude Code, a custom agent, whatever) does something unexpected
— e.g. tries to traverse out of an allowlisted plugin dir, tries to write a
file with a malicious name, tries to overwrite something it shouldn't — the
guardrails catch it:

- **Path traversal** is blocked at parse time. For `scratch` and
  `appdata-script`, the flat basename forbids `/`, `..`, or leading `.`.
  For `plugin-file`, the rel-path forbids `..` anywhere, leading or
  trailing `/`, empty middle components (`//`), and leading-`.` on any
  component; each component must match `^[a-zA-Z0-9_][a-zA-Z0-9._-]*$`,
  and the rel-path is capped at 3 components total.
- **Allowlist bypass** is blocked by default-deny: missing or empty allowlist
  → no 3-arg writes succeed.
- **Stale filter cache vs. updated allowlist** is fine: the writer re-validates
  the allowlist on every call, so removing an entry takes effect immediately
  even if the SSH session predates the change.
- **Slow-loris stdin** (DoS by trickling bytes) is blocked by the 30-second
  stdin timeout.
- **Disk-fill via huge writes** is bounded by the 2 MiB stdin cap.

### Silent log loss

Every `claude-write` invocation logs to syslog with the `claude-write` tag and
`auth` facility. Both `WROTE` (success) and `REJECTED` (failure) lines include
the argv. The Settings → Claude SSH → Audit Log tab parses these from the
last 24h; the dashboard tile shows counters. If syslog is shipped off-box, the
audit trail is durable.

## What this does NOT protect against

### Root on the box

If an attacker has root on the NAS, this plugin doesn't matter — they can
just edit `/etc/sudoers.d/claude-write`, replace the wrapper, or write
anywhere directly. This is a "raise the bar from one credential to two"
posture, not a containment boundary against root.

### Code execution within an allowlisted directory

This is the most important caveat to internalise.

The `plugin-file` category writes anywhere under
`/usr/local/emhttp/plugins/<plugin>/` (up to 3 path components), with mode
determined by extension — `.sh` / `.py` and extensionless `event/<hook>` files
land mode 755. The `appdata-script` category writes `.sh` to
`/mnt/user/appdata/<container>/scripts/` (mode 755). **Once written, those
files are executable by whatever invokes them** — the Unraid WebUI for
plugin assets, the relevant container for appdata scripts, and Unraid
itself for `event/<hook>` files (run at system events as root).

So if you allowlist `plugin foo`, you've effectively granted the SSH user
**code-execution scope inside the foo plugin's runtime context**: any
`.sh`, `.py`, `.php` (loaded by emhttp), or `event/<hook>` file under
`/usr/local/emhttp/plugins/foo/` can become a code-execution vehicle.
Treat allowlist entries as a code-execution decision, not a "let me deploy
a config file" decision. The category names + extension allowlist are
convention-enforcement; the plugin allowlist is the real blast-radius
boundary.

Concretely:

- Don't allowlist plugins you didn't write or audit.
- Don't allowlist a container's scripts dir if the container runs as root.
- A plugin whose `.php` files run on every WebUI request, or whose
  `event/<hook>` files run on system events as root, is *especially*
  high-value — only allowlist if you trust the writer of the file content.

### Replay / forgery of audit logs

Syslog is local-write. An attacker with root can edit / truncate syslog. For
durable audit, ship syslog to a remote collector before granting any keys.

### Supply-chain attacks on the plugin itself

The `.plg` and `.txz` are built from this repo. If the repo is compromised
between releases, install/upgrade pulls compromised payload. Pin to a specific
release tag rather than `main` for production. Verify the `.plg`'s signed
checksums if a release-signing key gets set up later.

### Username collision with an existing system user

If you set `CLAUDE_SSH_USERNAME` to a name that's already a system user (e.g.
`root`, `nobody`, `bin`), the install will fail at `useradd` — but the resolver
itself doesn't pre-check for collisions. Pick a name that doesn't already
exist on stock Unraid.

## Defence-in-depth layers

```
┌──────────────────────────────────────────────────┐
│  SSH layer: command="" filter (advisory)         │
│  - argv parse                                    │
│  - category enum                                 │
│  - basename / target-name regex                  │
│  - allowlist read                                │
│  - reject /boot/config/ writes                   │
│  → exec the wrapper if pass                      │
└──────────────────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────┐
│  Wrapper: /usr/local/bin/claude-write            │
│  - exec sudo -n claude-write-priv "$@"           │
└──────────────────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────┐
│  sudo: NOPASSWD rule for the SSH user            │
│  - argv-pinned to specific patterns              │
│  - one whole arg per `*` (no metacharacter exec) │
└──────────────────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────┐
│  Privileged writer (enforcement)                 │
│  - re-validate category, target name, basename   │
│  - re-read allowlist                             │
│  - hardened env (PATH pinned, LD_* dropped)      │
│  - stdin 30s timeout, 2 MiB cap                  │
│  - atomic tempfile + rename                      │
│  - backup with rotation                          │
│  - syslog WROTE / REJECTED                       │
└──────────────────────────────────────────────────┘
```

The filter is fast-path; the writer is correctness. If the filter and the
writer ever diverge on whether a request is acceptable, the writer wins. The
test suite (`test-sudoers-drift.sh`, `test-claude-write-validation.sh`)
enforces lockstep between them.

### Load-bearing assumption: target-dir perms

The writer runs as root, so it must never follow a symlink out of the
category's target tree. Since writer `v9` it actively guards against this:

- It **refuses a symlink at the destination** basename (so a planted
  `foo.sh -> /etc/cron.d/x` is rejected before the backup-read or the write).
- It **refuses a symlink at the target-directory leaf** (re-checked after
  `mkdir -p`), so a `scripts -> /etc` swap can't redirect the write.
- It writes through an **unpredictable `mktemp` name** created inside the
  target dir, closing the older predictable-temp-name vector (an attacker
  could previously pre-plant a symlink at `<dest>.claude-write.<ts>.tmp`).

This is defence-in-depth on top of the dir-ownership assumption — the writer
still relies on the **target directory's ancestry** being controlled by root
/ the admin, not the constrained SSH user:

- `/usr/local/emhttp/plugins/<plugin>/` directories are root-owned 755 by
  Unraid; the SSH user is in `users`, not root. No ancestor is a symlink.
- `/mnt/user/appdata/<container>/scripts/` is often container-owned and
  group-writable — which is exactly why the destination / leaf symlink
  guards above matter. **Residual:** the guards do not walk the full
  ancestry (walking to `/` would false-reject exotic layouts and is brittle
  across the `/mnt/user` FUSE mount), so an attacker who can write to the
  appdata *share root* could still replace a not-yet-created allowlisted
  `<container>` dir with a symlink. Existing allowlisted container dirs are
  real and not trivially replaceable; don't allowlist a container whose
  appdata parent is writable by the SSH user.
- `/tmp/claude-scratch/` is created by the writer (root-owned).

A fully TOCTOU-proof writer would need `openat2(RESOLVE_NO_SYMLINKS)`, which
isn't reachable from a shell writer. The category model is
convention-enforcement on top of the plugin allowlist; **the plugin allowlist
is the real blast-radius boundary**.

## What to do before granting your first SSH key

1. Pick a non-root username and persist it (`/boot/config/plugins/claude-ssh/username`).
2. Audit the categories in [categories.md](categories.md). Decide which
   directories you're comfortable with the SSH user reaching.
3. Configure the allowlist conservatively — start empty, add entries one at a
   time as you confirm the use case.
4. Generate a dedicated key (don't reuse a key you use for human SSH).
5. Limit the key's reachability: `from="ip-address-of-AI-client"` in
   `authorized_keys` is a useful additional gate.
6. If shipping audit logs is feasible, set that up before issuing the key.

If any of these feel uncomfortable, this plugin probably isn't the right
solution for your environment.
