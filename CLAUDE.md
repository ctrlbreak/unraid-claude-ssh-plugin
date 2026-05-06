# CLAUDE.md

> **INVESTIGATION RULE**: When asked to debug or investigate something unexpected, present a plan BEFORE making code changes. Don't jump straight into editing files unless explicitly told to.

> **DOC-SYNC RULE**: When you change anything user-visible (a new test, renamed/moved file, new category, deploy command, path) check whether the README, `.plg` CHANGES, or other in-repo docs reference what changed and update them in the same commit. Don't create new docs unless asked.

> **SAFETY RULE — NO LIVE DEPLOYS WITHOUT EXPLICIT REQUEST**: This plugin is NOT yet running on a real Unraid box. Phase 5/6 changes are unit-tested but not live. Don't run `bash deploy.sh --full` or any NAS-write command unless the user explicitly asks. The frozen production deployment lives in a sibling repo (see "Cross-repo context" below) and is the user's only working install today.

## Project Overview

`claude-ssh` is an Unraid plugin packaging a constrained SSH user + a `claude-write` deploy channel. Lets a remote AI client (Claude Code, primarily) write files to a small set of pre-approved locations on the NAS without root access. Defence-in-depth: an SSH `command=` filter validates argv at the SSH layer (advisory), then a privileged sudo'd writer re-validates and atomically writes (enforcement).

This repo is the **public-distribution generalisation** of the plugin. The original lives in a sibling repo (`~/dev/cursor_projects/homelab-scripts/plugin-claude-ssh/`) and is **frozen** until cutover. Until then, all plugin work happens here.

Goals: small handful of external adopters running the plugin. No CA listing until 5+ users prove the design.

## Repo Layout

```
claude-ssh.plg              # Plugin manifest, version entity, install/remove hooks
Makefile                    # tar cJf → claude-ssh.txz, plus `make test`
deploy.sh                   # quick (claude-write) + --full (plugin install) modes
README.md                   # Public-facing docs (kept synced with code changes)
CLAUDE.md                   # This file — agent working rules + invariants
tests/                      # Lint / build / regression / idempotency / migration
src/usr/local/emhttp/plugins/claude-ssh/
├── ClaudeSsh.page                  # Settings tab (Health + Allowlist editor + Status + Audit Log)
├── ClaudeSshDashboard.page         # Dashboard tile
├── default.cfg                     # Plugin defaults (allowlist + username live in /boot/config/)
├── include/exec.php                # AJAX backend (status, audit_log, recent_activity, load/save_allowlist)
└── scripts/
    ├── install-runtime.sh              # Resolves username, runs setup scripts, manages /boot/config/go
    ├── uninstall-runtime.sh            # Non-destructive cleanup
    ├── unraid-readonly-ssh-setup.sh    # SSH user + filter heredoc (canonical filter source)
    └── claude-write-setup.sh           # claude-write writer + sudoers (canonical writer source)
```

## Phase plan + status

Active phase plan and per-phase progress live in **project memory** (NOT this file — they change too often). See:

- `~/.claude/projects/-Users-patrick-dev-cursor-projects-claude-ssh-plugin/memory/project_claude_ssh_public_plugin.md` — phase plan
- Same dir, `handoff_*.md` — per-phase handoffs with edge cases and resume prompts
- `~/.claude/plans/i-m-considering-whether-i-nifty-tiger.md` — full design memo (architecture + coupling-point inventory + classification rationale)

**Current state (as of 2026-05-06, last commit `fbce66c`):** Phases 1-6 done. Plugin `2026.05.06c`, filter v9, writer v4. 13 tests green · 1 skipped (shellcheck not installed). Phase 7 (more tests) is next. NOT yet deployed live to any NAS.

## Working style — keep doing these

The conventions below are load-bearing across phases 3-6 and should continue into 7+. Drift from them silently breaks invariants the test suite enforces.

### One phase = one commit

Commit message: `Phase N: <subject>` followed by a paragraph explaining **what + why** (not how). Example: `fbce66c Phase 6: configurable SSH username`. No Claude attribution in commit messages, ever.

### Plugin version cadence

Plugin version is date-based with letter suffix: `2026.05.06[a-z]`. Bump the entity in `claude-ssh.plg` ONLY when something user-visible changes (source script, exec.php, page, plg metadata). Test-only changes don't bump.

Filter version (`v9`) and writer version (`v4`) are **runtime contracts** — they bump only when the runtime artifact changes (`/home/<user>/shell-filter.sh` or `/usr/local/sbin/claude-write-priv`). Setup-script changes that don't alter the heredoc'd runtime don't bump those versions.

### `.plg` CHANGES entries

Every plugin version bump gets a `###<version>` entry near the top of `<CHANGES>` in `claude-ssh.plg`. Entries summarise what changed, in user-visible terms, with bullets for each meaningful change. See existing entries for tone — short, factual, no marketing.

### Tests: sandbox-only

No root, no NAS, no docker. Pattern: extract heredoc / function from the source file with `awk`, swap `exec` lines for `echo+exit`, run with controlled env vars + `mktemp -d` fixtures + `trap cleanup EXIT`. PHP is optional (skip via `exit 77` when missing — matches `test-php-lint.sh` and `test-settings-save.sh`).

### Drift-check tests for anything duplicated across files

The most dangerous failure mode in this plugin is silent divergence between the filter, the writer, and `exec.php` (or between four scripts that share a function body). Phase 3 added the cross-check between filter and writer for the allowlist parser. Phase 6 added it for `cs_resolve_username` across 4 shell scripts. New duplications get new drift checks.

When adding or modifying a duplicated block:
1. Update **all** sites in the same commit.
2. Add a drift-check assertion in the appropriate test file (`test-claude-write-validation.sh` for filter/writer/exec.php triples, `test-username-configurable.sh` for the four-script helper).
3. Drift checks must be content-equality, not just presence.

### Test runner shape

Every test file follows this skeleton:

```bash
#!/bin/bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# ... setup ...

PASS=0
FAIL=0
FAILED=()

run_case() {
    # ... assertions ...
    if [ pass ]; then PASS=$((PASS + 1))
    else FAIL=$((FAIL + 1)); FAILED+=("..."); fi
}

# ... cases ...

TOTAL=$((PASS + FAIL))
echo "  cases: $PASS passed / $FAIL failed / $TOTAL total"
if [ "$FAIL" -ne 0 ]; then
    echo "FAIL: ..."
    for f in "${FAILED[@]}"; do echo "  - $f"; done
    exit 1
fi
echo "PASS: <one-line summary>"
```

Register new tests in `tests/run-all.sh` (`TESTS=( ... )` array). The runner converts exit 77 to SKIP, anything else to FAIL.

### Update everything in the same commit

When code changes:
- README updated (DOC-SYNC rule)
- `.plg` CHANGES entry added
- `tests/run-all.sh` registry updated (if a new test file was added)
- Cross-check tests updated (if a duplicated block changed)
- Plugin version bumped (if user-visible)

If you find yourself wanting to "land the code now and clean up docs later" — don't. Same commit.

### Handoff at end of phase

At the end of every phase, write a handoff to `~/.claude/projects/.../memory/handoff_<date>_claude_ssh_phase<N>.md` with these sections:
1. What was accomplished (specific files, line-of-thinking changes, version bumps)
2. Test counts before / after
3. Edge cases worth remembering (hidden constraints found during the work)
4. What's still pending (link back to project doc)
5. Resume prompt (copy-paste-able to start next session)

Update `MEMORY.md` index in the same dir. Update `project_claude_ssh_public_plugin.md` to flip the phase from ⏳ to ✅ with commit hash.

Use the `phase 5` and `phase 6` handoffs as canonical templates.

## Active invariants — DON'T silently violate

Each of these is enforced by at least one test. If a test fails because of one, fix the code, not the test (unless the user explicitly agreed to weaken the invariant).

1. **Filter / writer / exec.php parser lockstep.** Same allowlist path default (`/boot/config/plugins/claude-ssh/allowlist.cfg`), same `CLAUDE_SSH_ALLOWLIST_FILE` env override, same awk shape (`awk -v k="$kind" 'NF == 2 && $1 == k { print $2 }'`), same name regex (`^[a-z][a-z0-9-]{0,63}$`). Enforced by `test-claude-write-validation.sh`.

2. **`cs_resolve_username()` body byte-identical** across `unraid-readonly-ssh-setup.sh`, `claude-write-setup.sh`, `install-runtime.sh`, `uninstall-runtime.sh`. Enforced by `test-username-configurable.sh` drift check.

3. **`/boot/config/plugins/claude-ssh/{allowlist.cfg,username}` are NEVER overwritten** on plugin upgrade. They're seeded on first install (when the file is missing) and respected forever after. User-edited content survives upgrades.

4. **Sudoers heredoc must be unquoted** (`<< SUDO`, not `<< 'SUDO'`) so `$USERNAME` interpolates into the principal. Quoted form would leave the literal string `$USERNAME` in the file, which visudo would reject. Enforced by `test-username-configurable.sh` case #6.

5. **No filter/writer runtime changes without bumping the version marker** in the script header (`# Filter version: vN` / `# Writer version: vN`). The marker is what `exec.php`'s `readVersionMarker` reads to display on the Status tab.

6. **Default-deny on missing/empty allowlist.** The parser must produce no entries when the file is missing, empty, or all-invalid — never accept everything as a fallback. Enforced by `test-allowlist-config.sh`.

7. **`/boot/config/` is read-only at the SSH layer.** The filter must reject every shell-level path that would write to `/boot/config/...` (because the runtime allowlist lives there). Enforced by `test-boot-config-write-block.sh`. The writer cannot target `/boot/config/` either — categories don't map there.

## Build / Test / Deploy

```bash
make test                    # run the full local test suite
make                         # build claude-ssh.txz
make clean                   # rm the built archive

bash deploy.sh               # quick deploy (UI tweaks only — no plugin reinstall)
bash deploy.sh --full        # full deploy (rebuild + plugin install hook re-run)
```

`deploy.sh` writes to a real NAS — only run when explicitly authorised. Currently no NAS has this version of the plugin installed; the user's NAS runs `homelab-scripts/plugin-claude-ssh/`.

## Commit message style

- Subject line: `Phase N: <subject>` for phase commits, otherwise imperative verb (`Fix ...`, `Add ...`, `Refactor ...`).
- Body explains **what + why**, not how. The diff shows how.
- No Claude attribution. No `Co-Authored-By: Claude ...` lines.
- Prefer one commit per phase. Don't split a phase across multiple commits unless the user asks.
- HEREDOC syntax for the body so formatting survives:

```bash
git commit -m "$(cat <<'EOF'
Phase N: subject

Body explaining what changed and why. Specific files / behaviours.
Test count before / after.
EOF
)"
```

## What NOT to do

- **Don't backport to `homelab-scripts/plugin-claude-ssh/`.** That repo is frozen until cutover. The user runs that version on their NAS today.
- **Don't deploy live without permission.** No NAS has this version installed yet; first live install will probably surface CSS/theme tweaks (the Settings UI hasn't been seen against a real Unraid theme).
- **Don't bump filter/writer versions for setup-script-only changes** — only bump when the runtime artifact (the heredoc'd filter or the heredoc'd writer) changes.
- **Don't construct raw `ssh`/`scp` to the NAS from this repo.** If live testing becomes necessary, switch back to the homelab-scripts session which has the `/unraid-ssh` skill.
- **Don't add comments that explain WHAT the code does** — variable names already do that. Comments are for WHY: hidden constraints, subtle invariants, workarounds for specific bugs.
- **Don't introduce abstraction for hypothetical future requirements.** Three similar lines is better than a premature abstraction.

## Cross-repo context

This repo (`claude-ssh-plugin`) and `homelab-scripts` (a sibling repo at `~/dev/cursor_projects/homelab-scripts/`) have a frozen-vs-active relationship:

| Concern | Where |
|---|---|
| Plugin source of truth (active development) | This repo |
| Frozen production deployment | `homelab-scripts/plugin-claude-ssh/` |
| `/unraid-ssh` skill (raw NAS access) | homelab-scripts session |
| Other unrelated homelab work | homelab-scripts session |

When the user wants to switch contexts (e.g. "let me check the live NAS state") they switch back to a homelab-scripts session. Don't try to ssh into the NAS from a session running here.

## Useful pointers

- **Phase plan / status:** `~/.claude/projects/-Users-patrick-dev-cursor-projects-claude-ssh-plugin/memory/project_claude_ssh_public_plugin.md`
- **Latest handoff:** `~/.claude/projects/-Users-patrick-dev-cursor-projects-claude-ssh-plugin/memory/handoff_2026-05-06_claude_ssh_phase6.md`
- **Design memo (architecture + coupling-point inventory):** `~/.claude/plans/i-m-considering-whether-i-nifty-tiger.md`
- **Public-facing docs:** `README.md` in this repo
