#!/bin/bash
# Asserts that current-tense filter/writer version mentions in user-facing
# files match the canonical FILTER_VERSION / WRITER_VERSION declared in the
# setup scripts.
#
# Scope: README.md, docs/*.md, and verify-install.sh (the sibling parser
# that was missed in the 2026.05.12d centralisation pass — `11ab7e5` fixed
# it, but the drift test now covers it so a future regression here would
# fail CI). The setup scripts themselves are excluded — they ARE the
# canonical source.
#
# Targeted, not exhaustive: catches drift in specific phrase shapes that are
# unambiguously current-tense claims:
#
#   - "**Filter version:** `vN`"  (badge in install.md / verify lists)
#   - "**Writer version:** `vN`"  (same)
#   - "← filter vN"               (threat-model.md diagram annotation)
#   - "← writer vN"               (same)
#   - "filter=vN"                 (verifying.md sample output, verify-install.sh)
#   - "writer=vN"                 (same)
#
# Historical / example mentions in prose ("the v9 release added X", a
# troubleshooting example that names a stale version on purpose) are NOT
# matched by these patterns and don't trigger the test. Likewise CHANGELOG.md
# and claude-ssh.plg's <CHANGES> block are not scanned — they're release
# history by design.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_SCRIPTS="$ROOT/src/usr/local/emhttp/plugins/claude-ssh/scripts"

FILTER_VER=$(grep -m1 -E '^FILTER_VERSION="?v[0-9]+(\.[0-9]+)*"?[[:space:]]*$' \
    "$PLUGIN_SCRIPTS/unraid-readonly-ssh-setup.sh" \
    | sed -E 's/^FILTER_VERSION="?(v[0-9]+(\.[0-9]+)*)"?.*$/\1/')
WRITER_VER=$(grep -m1 -E '^WRITER_VERSION="?v[0-9]+(\.[0-9]+)*"?[[:space:]]*$' \
    "$PLUGIN_SCRIPTS/claude-write-setup.sh" \
    | sed -E 's/^WRITER_VERSION="?(v[0-9]+(\.[0-9]+)*)"?.*$/\1/')

if [ -z "$FILTER_VER" ] || [ -z "$WRITER_VER" ]; then
    echo "FAIL: could not parse canonical FILTER_VERSION/WRITER_VERSION from setup scripts"
    exit 1
fi
echo "  canonical: filter=$FILTER_VER writer=$WRITER_VER"

SCAN_FILES=(
    "README.md"
    "docs/install.md"
    "docs/categories.md"
    "docs/filter.md"
    "docs/threat-model.md"
    "docs/troubleshooting.md"
    "docs/upgrading.md"
    "docs/verifying.md"
    "docs/wire-protocol.md"
    "docs/releasing.md"
    "verify-install.sh"
)

PASS=0
FAIL=0
FAILED=()

# Each call asserts: for every line in $file matching $pattern, the version
# inside the matched substring equals $expected. Lines without a match are
# skipped silently.
assert_phrase() {
    local file="$1" pattern="$2" expected="$3" label="$4"
    local matches
    matches=$(grep -nE "$pattern" "$file" 2>/dev/null || true)
    [ -z "$matches" ] && return 0
    while IFS= read -r match; do
        local line_no found
        line_no=${match%%:*}
        found=$(printf '%s' "$match" | grep -oE "$pattern" | head -1 \
                                     | grep -oE 'v[0-9]+(\.[0-9]+)*' | head -1)
        [ -z "$found" ] && continue
        if [ "$found" != "$expected" ]; then
            FAIL=$((FAIL + 1))
            FAILED+=("$file:$line_no — $label says $found, canonical is $expected")
        else
            PASS=$((PASS + 1))
        fi
    done <<< "$matches"
}

for f in "${SCAN_FILES[@]}"; do
    fp="$ROOT/$f"
    [ -r "$fp" ] || continue

    assert_phrase "$fp" '\*\*Filter version:\*\*[[:space:]]*`v[0-9]+' "$FILTER_VER" "**Filter version:** badge"
    assert_phrase "$fp" '← filter v[0-9]+'                            "$FILTER_VER" "← filter vN (diagram)"
    assert_phrase "$fp" 'filter=v[0-9]+'                              "$FILTER_VER" "filter=vN (sample output)"

    assert_phrase "$fp" '\*\*Writer version:\*\*[[:space:]]*`v[0-9]+' "$WRITER_VER" "**Writer version:** badge"
    assert_phrase "$fp" '← writer v[0-9]+'                            "$WRITER_VER" "← writer vN (diagram)"
    assert_phrase "$fp" 'writer=v[0-9]+'                              "$WRITER_VER" "writer=vN (sample output)"
done

TOTAL=$((PASS + FAIL))
echo "  cases: $PASS passed / $FAIL failed / $TOTAL total"
if [ "$FAIL" -ne 0 ]; then
    echo "FAIL: doc version drift detected"
    for entry in "${FAILED[@]}"; do echo "  - $entry"; done
    echo ""
    echo "Fix: update the doc to match canonical, or rephrase the mention to"
    echo "     not claim a specific current version. Historical examples can"
    echo "     be reshaped so the targeted patterns above don't match."
    exit 1
fi
echo "PASS: doc filter/writer version mentions match canonical"
