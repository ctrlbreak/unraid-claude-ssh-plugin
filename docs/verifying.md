# Verifying your install

`verify-install.sh` is an end-to-end smoke test for a live `claude-ssh`
install. Point it at your NAS, and it runs ~35 cases across five layers,
prints a pass/fail line per case, and on every failure includes a
one-line fix hint plus a pointer to the relevant
[`troubleshooting.md`](troubleshooting.md) section.

It complements (does not replace) the local unit suite under `tests/`.
The unit suite covers source-side invariants in a sandbox; this script
exercises the actually-deployed filter, writer, sudoers, and audit log.

## What it verifies

| Layer | What | Where it runs |
|---|---|---|
| 1 | Install state — files, perms, sudoers, plugin registered | root SSH |
| 2 | Filter behaviour — allowed reads succeed, blocked patterns blocked | constrained-user SSH |
| 3 | Writer behaviour — every category writes for a test fixture; out-of-allowlist rejected | constrained-user SSH |
| 4 | Audit log — recent entries appear in `/var/log/syslog` | root SSH |
| 5 | Versions — deployed filter/writer match local repo, Settings/Status endpoint reports same | root SSH |

What it does **not** verify:
- Settings UI rendering / theme (manual; run a browser).
- Performance.
- Anything beyond the filter/writer pair (no broader system audit).

## Prerequisites

1. **Root SSH** to the NAS — key auth (passwordless) or password auth both
   work. Same shape as `deploy.sh`. The suite opens an SSH master connection
   on the first call (you'll be prompted for the password once if you use
   password auth) and reuses it via `ControlMaster` for every subsequent
   call, so you only enter the password once per run.

2. **Constrained-user SSH** to the NAS, using the SSH key you'd hand to
   an AI agent. The default user is `claude`; if you've changed it via
   `/boot/config/plugins/claude-ssh/username`, use that name.

3. **Test fixture entries in your allowlist.** The suite needs both:

   ```
   plugin verify-test
   container verify-test
   ```

   Add them via the **Settings UI's Allowlist card** (claude-ssh tab) or
   by editing `/mnt/user/appdata/claude-ssh/allowlist.cfg` directly
   as root. The script's pre-flight will fail-fast with exact
   instructions if either is missing.

   The suite writes test files under
   `/usr/local/emhttp/plugins/verify-test/` and
   `/mnt/user/appdata/verify-test/scripts/`. After Layer 5 finishes, the
   suite **prints the exact `rm` command** it would run as root via SSH
   and **prompts before executing it** (default no). You can let the
   suite clean up, or copy the printed command and run it yourself. The
   directories themselves are left in place; `rm -rf` them after if you
   want, and remove the two allowlist entries.

## Running it

```bash
ROOT_HOST=root@nas.local CLAUDE_HOST=claude@nas.local bash verify-install.sh
```

If `ssh` doesn't pick the right keys automatically, point it at them
explicitly:

```bash
ROOT_HOST=root@nas.local CLAUDE_HOST=claude@nas.local \
ROOT_SSH_KEY=~/.ssh/id_ed25519 \
CLAUDE_SSH_KEY=~/.ssh/claude_unraid \
bash verify-install.sh
```

Either env var is optional — omit it and `ssh` uses its default key
search (or prompts for a password, which `ControlMaster` will then
reuse for the rest of the run).

Expected runtime: a few seconds. SSH ControlMaster is set up so the
script reuses one connection per host instead of doing ~40 handshakes.

Exit code: `0` if every case passes (skipped does not fail), `1` on any
failure.

## Reading the output

```
==> claude-ssh verification suite
==> ROOT_HOST=root@nas.local  CLAUDE_HOST=claude@nas.local
==> Expected versions: filter=$FILTER_VERSION writer=$WRITER_VERSION
==> Pre-flight: SSH connectivity OK · username=claude · allowlist has verify-test entries OK

[Layer 1 — Install state]
  PASS  1.1 plugin metadata registered (/var/log/plugins/claude-ssh.plg)
  PASS  1.2 filter script at /home/claude/shell-filter.sh (root:root 755)
  ...

[Layer 2 — Filter behaviour]
  PASS  2.1 allowed: ls /mnt/user/
  ...

[Layer 3 — Writer behaviour]
  PASS  3.1 scratch write → /tmp/claude-scratch/verify-1715120000-1.txt (mode 644)
  ...

==========================================
  37 passed · 0 failed · 0 skipped
==========================================

==> Cleanup needed: 6 test file(s) were written on the NAS.
    Files:
      /tmp/claude-scratch/verify-1715120000-1.txt
      /usr/local/emhttp/plugins/verify-test/scripts/verify-1715120000-2.sh
      ... (4 more)

    Proposed cleanup command (runs as root via SSH):
      ssh root@nas.local rm -f /tmp/claude-scratch/verify-... /usr/local/emhttp/plugins/verify-test/scripts/verify-... ...

    Run this cleanup now? [y/N]
```

The cleanup prompt appears regardless of whether the suite passed or
failed — files written during a partial Layer 3 run are still listed.
Pressing Enter (or anything other than `y` / `yes`) skips cleanup; the
exact `rm` command is left on screen for you to copy and run manually.
Non-interactive invocations (no controlling terminal) skip the prompt
and print the command without executing it.

When something fails, you get an inline fix hint and a doc anchor:

```
  FAIL  1.5 sudoers entry missing at /etc/sudoers.d/claude-write
        Fix:  re-run claude-write-setup.sh as root, or reinstall the plugin
        See:  docs/troubleshooting.md#writer-fails-silently-sudo-a-password-is-required
```

`SKIP` lines indicate the case couldn't run for a reason that isn't a
failure — e.g. case 5.3 is skipped if the Unraid web server isn't
reachable from `localhost` on the NAS.

## What to do on failure

Each failure includes a `Fix:` one-liner that resolves most cases. If it
doesn't, follow the `See:` link to the matching section of
[`troubleshooting.md`](troubleshooting.md), which has full symptom →
cause → fix entries.

If the suite itself seems wrong (e.g. it reports a failure that isn't
actually a problem), that's a bug — open an issue. The suite is
defence-against-regression on a live install, not a perfect oracle.

## When to run it

- **First live install.** The smoke test you run after the very first
  deploy to a real Unraid box.
- **After upgrades.** Rerun after `plugin install` on a new release to
  confirm nothing regressed.
- **After config changes.** Rerun if you've edited the allowlist,
  changed the SSH username, or touched any of the deployed files
  manually.
- **As part of incident triage.** If a write started failing in
  production, run the suite — it will tell you whether the problem is
  install state, filter, writer, or audit pipeline.
