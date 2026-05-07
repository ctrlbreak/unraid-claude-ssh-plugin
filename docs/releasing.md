# Releasing

Cutting a new release of `claude-ssh`. Audience: maintainers + contributors
with push access. End users should never need this doc.

## TL;DR

```bash
# 1. Decide the new version (date-based).
NEW=2026.05.07a

# 2. Bump version + changelog in three places.
sed -i.bak -E "s/<!ENTITY version[[:space:]]+\"[^\"]+\">/<!ENTITY version   \"$NEW\">/" claude-ssh.plg
rm claude-ssh.plg.bak
$EDITOR claude-ssh.plg     # add a ###<version> entry near the top of <CHANGES>
$EDITOR CHANGELOG.md       # add a matching ## <version> — YYYY-MM-DD section

# 3. Verify locally.
make test                  # all tests pass
make                       # builds claude-ssh.txz

# 4. Commit, tag, push.
git add claude-ssh.plg CHANGELOG.md
git commit -m "Release $NEW"
git tag "v$NEW"
git push origin main
git push origin "v$NEW"

# 5. CI takes it from here. Watch the run on GitHub Actions; the release
#    appears at https://github.com/ctrlbreak/unraid-claude-ssh-plugin/releases
#    a few minutes later with claude-ssh.plg + claude-ssh.txz attached.
```

## What CI does on tag push

The `.github/workflows/release.yml` workflow triggers on any tag matching
`v*`. It:

1. Installs `shellcheck` and runs the full sandbox test suite (`make test`).
   A failing test aborts the release.
2. **Verifies the tag matches `<!ENTITY version>` in `claude-ssh.plg`.**
   If you tag `v2026.05.07a` but the .plg still says `2026.05.06c`, the
   workflow refuses to build. This catches the most common release goof.
3. Builds `claude-ssh.txz` via `make`.
4. Computes `md5sum claude-ssh.txz` and substitutes the `__MD5__` placeholder
   in the in-repo `.plg`. The rendered `.plg` is what ships in the release.
5. Extracts the matching section from `CHANGELOG.md` for the release notes.
   Looks for `## <version> — ` and reads to the next `## `.
6. Creates the GitHub release with both files attached.

## Version-bump rules

- **Plugin version** (`<!ENTITY version>` in `claude-ssh.plg`) bumps when
  anything user-visible changes. See [upgrading.md](upgrading.md#version-bump-cadence).
- **Filter version** (`# Filter version: vN` in `unraid-readonly-ssh-setup.sh`)
  bumps when the live filter content changes — i.e. the heredoc that gets
  installed at `/home/<user>/shell-filter.sh` changes, not just the wrapper
  script around it.
- **Writer version** (`# Writer version: vN` in `claude-write-setup.sh`)
  bumps when the live writer content changes — i.e. the heredoc that gets
  installed at `/usr/local/sbin/claude-write-priv` changes.

Test-only or docs-only releases bump nothing — but if there's nothing
user-visible to release, just don't tag.

## Tag format

Tags use a `v` prefix: `v2026.05.06c`, `v2026.05.07a`, etc. The `v` is
stripped before comparing against the `.plg`'s `<!ENTITY version>`. Tags
without `v` are not picked up by the release workflow.

## What gets attached to a release

- `claude-ssh.plg` — rendered with the real MD5 substituted in. This is the
  URL users paste into the Unraid plugin manager.
- `claude-ssh.txz` — the package payload. Referenced by the rendered `.plg`
  at `releases/download/v<version>/claude-ssh.txz`.

`releases/latest/download/claude-ssh.plg` always serves the most recent
release's `.plg`. `releases/download/v<version>/claude-ssh.plg` serves a
specific tagged version.

## When CI fails

- **`make test` fails:** fix the underlying test break, push to main first,
  then re-tag (delete the old tag locally + remotely, push the new one).
- **Tag/version mismatch:** either bump the .plg version on `main` and push
  before tagging, or delete and recreate the tag at the right version.
  Re-running CI by re-pushing the same tag is a no-op (GitHub doesn't fire
  the trigger on tag-already-exists pushes).
- **MD5 placeholder check fails:** the in-repo `.plg` is missing the
  `__MD5__` placeholder. Check that `<MD5>&md5;</MD5>` is present in
  `claude-ssh.plg` and that `<!ENTITY md5 "__MD5__">` is in the entity
  block.

## Manual release (workflow disabled)

Should the workflow ever break and a release still needs cutting:

```bash
make test && make
md5=$(md5sum claude-ssh.txz | awk '{print $1}')
sed "s/__MD5__/$md5/g" claude-ssh.plg > claude-ssh.plg.rendered
gh release create "v$NEW" \
    --title "v$NEW" \
    --notes-file <(awk -v v="$NEW" '$0 ~ "^## " v " " { f=1; next } f && /^## / { exit } f' CHANGELOG.md) \
    claude-ssh.plg.rendered#claude-ssh.plg \
    claude-ssh.txz
```

(The `claude-ssh.plg.rendered#claude-ssh.plg` syntax tells `gh release`
to upload the file under the second name — so the release asset is named
`claude-ssh.plg`, not `claude-ssh.plg.rendered`.)

## Yanking a release

If a release ships broken:

1. Mark the GitHub release as "pre-release" (or delete it outright) so the
   `releases/latest/download/...` URL stops pointing at it.
2. Cut a fresh release with the fix. Don't reuse the broken version number
   — bump the letter suffix (`2026.05.07a` → `2026.05.07b`).
3. Mention the yanked version in the next release's `<CHANGES>` and
   `CHANGELOG.md` entries.

The Unraid plugin manager caches `.plg` content per-URL; users who already
installed the broken version need an explicit "Check for Updates" or a
manual re-install to pick up the fix.
