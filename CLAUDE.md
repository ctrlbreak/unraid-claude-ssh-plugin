# CLAUDE.md

> **INVESTIGATION RULE**: When asked to debug or investigate something unexpected, present a plan BEFORE making code changes. Don't jump straight into editing files unless explicitly told to.

> **DOC-SYNC RULE**: When you change anything user-visible (a new test, renamed/moved file, new category, deploy command, path) check whether the README, `.plg` CHANGES, or other in-repo docs reference what changed and update them in the same commit. Don't create new docs unless asked.

> **SAFETY RULE — NO LIVE DEPLOYS WITHOUT EXPLICIT REQUEST**: This plugin is NOT yet running on a real Unraid box. Phase 5/6 changes are unit-tested but not live. Don't run `NAS_HOST=... bash deploy.sh` or any NAS-write command unless the user explicitly asks. The frozen production deployment lives in a sibling repo (see "Cross-repo context" below) and is the user's only working install today.

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

**Current state (as of 2026-05-13):** Phase 10 done. Plugin `2026.05.13b`, filter v11, writer v6. The four legacy `plugin-{page,include,script,cfg}` categories have been collapsed into a single `plugin-file <plugin> <rel-path>` form with up to 3 path components, an extension-driven mode (.sh / .py → 755, else 644), and a narrow `event/<hook>` extensionless exception (Unraid event-hook convention). Sudoers now enumerates three rel-path arities because sudo's `*` does not match `/`. 18 tests green locally (most have grown in case count to cover the new shape and the gotcha drift checks). **Breaking** for any direct callers of the old plugin-* category names (the user's own `homelab-scripts/scripts/deploy-via-claude-write.sh` consumer is the only known one — must be migrated in that repo's session before the new plugin lands on bigboi).

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

1. **Filter / writer / exec.php category + parser lockstep.** Categories are `scratch` (simple, 2-arg), `plugin-file` (3-arg, plugin allowlist, rel-path), and `appdata-script` (3-arg, container allowlist, basename). Same allowlist path default (`/mnt/user/appdata/claude-ssh/allowlist.cfg` — on the array because `/boot` is FAT and the kernel forces dirs to 700 there, blocking the constrained user from reading), same `CLAUDE_SSH_ALLOWLIST_FILE` env override, same awk shape (`awk -v k="$kind" 'NF == 2 && $1 == k { print $2 }'`), same name regex (`^[a-z][a-z0-9-]{0,63}$`). The `plugin-file` rel-path rules — max 3 components, each `^[a-zA-Z0-9_][a-zA-Z0-9._-]*$`, total ≤ 128 chars, no `..` / leading-`/` / trailing-`/` / `//` / leading-`.` — and the extension-driven mode mapping (.sh/.py → 755, else 644) live in the writer, with the filter doing rel-path SHAPE validation only (the filter is advisory; the writer enforces extension allowlist + the event/<hook> exception). The `event/<hook>` exception is depth-1 only, basename `^[a-z][a-z0-9_]{0,32}$`, mode 755. Enforced by `test-claude-write-validation.sh` (cross-check + behavioural cases) and `test-sudoers-drift.sh` (set-equality + argv-shape).

   **Sudoers wildcards** (gotcha #1, v6+). Sudo's `*` matches one whole arg and does **not** match `/`. The `plugin-file` rel-path must therefore be enumerated as three explicit sudoers patterns: `plugin-file * *`, `plugin-file * */*`, `plugin-file * */*/*`. The writer additionally caps slash count at 2, so a 4-slash pattern would be unreachable by construction — drift test asserts both the presence of all three patterns AND the absence of any 4-slash form.

   **Wrapper body byte-identical** (gotcha #2). `/usr/local/bin/claude-write` is exactly `exec sudo -n /usr/local/sbin/claude-write-priv "$@"`. The quoted `"$@"` is load-bearing — preserves argv boundaries against shell-split / glob. Drift test asserts the wrapper body byte-for-byte; unquoting `$@` is a hard fail.

   **PATH-shadowing** (gotcha #3). The privileged writer **must** be named `claude-write-priv`, not `claude-write`. Slackware's PATH puts `/usr/local/sbin` before `/usr/local/bin`, so a same-named priv binary would resolve first and bypass sudo. The OLD_PRIV_PATH cleanup in claude-write-setup.sh removes the legacy `/usr/local/sbin/claude-write` on upgrade. Drift test asserts the priv binary name + wrapper exec target + cleanup-rm line.

   **No `env_keep` on the claude-write sudoers rule** (gotcha #4). Sudo's default `env_reset` strips `CLAUDE_SSH_ALLOWLIST_FILE`, `LD_PRELOAD`, `LD_LIBRARY_PATH`, `LD_AUDIT`, `IFS`, `BASH_ENV`, `ENV`, `CDPATH` before the writer runs. The writer's `unset` line is belt-and-braces. The `CLAUDE_SSH_ALLOWLIST_FILE` env override is test-only — relies on `env_reset` stripping it in production. Adding `env_keep` for any var to the claude-write sudoers rule weakens this. Drift test asserts no `env_keep` directive in the writer's sudoers heredoc body.

   **Plugin allowlist is the gate.** Category names + extension allowlist are convention-enforcement. A widened `plugin-file` contract (any file inside an allowlisted plugin's tree, subject to extension allowlist + 3-component depth cap) does **not** open a structurally new attack class — once `plugin foo` is allowlisted, the SSH user already had code-execution scope inside foo's runtime context via `.sh` / `.py` / `.php` / `event/<hook>` writes. The blast-radius boundary is `plugin <name>` in `allowlist.cfg`, not the category symbol.

2. **`cs_resolve_username()` body byte-identical** across `unraid-readonly-ssh-setup.sh`, `claude-write-setup.sh`, `install-runtime.sh`, `uninstall-runtime.sh`. Enforced by `test-username-configurable.sh` drift check.

3. **User-edited config files are NEVER overwritten** on plugin upgrade. The two files: `/mnt/user/appdata/claude-ssh/allowlist.cfg` (the plugin/container allowlist — on the array since v10/2026.05.12c because /boot is FAT and kernel-forces dir mode 700) and `/boot/config/plugins/claude-ssh/username` (the configured SSH username — stays on /boot because only root reads it). Both are seeded on first install (when the file is missing) and respected forever after. Plugin `2026.05.12c` install-runtime.sh does a one-shot migration of any existing legacy `/boot/config/plugins/claude-ssh/allowlist.cfg` to the new array location.

4. **Sudoers heredoc must be unquoted** (`<< SUDO`, not `<< 'SUDO'`) so `$USERNAME` interpolates into the principal. Quoted form would leave the literal string `$USERNAME` in the file, which visudo would reject. Enforced by `test-username-configurable.sh` case #6.

5. **No filter/writer runtime changes without bumping the version marker** in the script header (`# Filter version: vN` / `# Writer version: vN`). The marker is what `exec.php`'s `readVersionMarker` reads to display on the Status tab.

6. **Default-deny on missing/empty allowlist.** The parser must produce no entries when the file is missing, empty, or all-invalid — never accept everything as a fallback. Enforced by `test-allowlist-config.sh`.

7. **`/boot/config/` is read-only at the SSH layer.** The filter must reject every shell-level path that would write to `/boot/config/...` (because the runtime allowlist lives there). Enforced by `test-boot-config-write-block.sh`. The writer cannot target `/boot/config/` either — categories don't map there.

## Build / Test / Deploy

```bash
make test                    # run the full local test suite
make                         # build claude-ssh.txz
make clean                   # rm the built archive

NAS_HOST=root@nas.local bash deploy.sh   # build + scp + plugin install

ROOT_HOST=root@nas CLAUDE_HOST=claude@nas bash verify-install.sh   # end-to-end verification (live NAS)
```

`deploy.sh` writes to a real NAS — only run when explicitly authorised. Currently no NAS has this version of the plugin installed; the user's NAS runs `homelab-scripts/plugin-claude-ssh/`. End users install via the release `.plg` URL, not via `deploy.sh`.

`verify-install.sh` is the end-to-end smoke test for a live install — repo-asset only (not in `.txz`), reads-only against the NAS apart from a few claude-write test files it cleans up. Same "only run when explicitly authorised" rule applies. Documented in [`docs/verifying.md`](docs/verifying.md).

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
