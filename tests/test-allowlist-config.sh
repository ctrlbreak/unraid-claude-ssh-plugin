#!/bin/bash
# Behavioural test for the runtime plugin-name allowlist (filter v8 / writer v3).
#
# Exercises the parser via the live filter: for each fixture allowlist.cfg, we
# run the filter with a `claude-write plugin-page <name> foo.page` command and
# assert ALLOW vs BLOCK. This tests the parser through the same code path the
# live SSH filter uses on the NAS.
#
# Coverage matches the plan's test spec:
#   - Missing/empty file            → default-deny
#   - Comments-only                 → default-deny
#   - Whitespace tolerance          → still parses valid lines
#   - Malformed entries             → silently dropped at parse, valid pass
#   - Duplicates                    → deduplicated
#   - Container-prefixed lines      → ignored by plugin parser (phase 4 fwd-compat)
#   - Names failing regex           → dropped (uppercase, special chars, too long)

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$ROOT/src/usr/local/emhttp/plugins/claude-ssh/scripts/unraid-readonly-ssh-setup.sh"

if [ ! -f "$SETUP" ]; then
    echo "FAIL: $SETUP not found"
    exit 1
fi

# Extract the filter heredoc, same trick as test-filter-regression.sh.
FILTER_TMP=$(mktemp -t shell-filter-XXXXXX.sh)
SANDBOX_DIR=$(mktemp -d -t claude-ssh-allowlist-XXXXXX)
trap 'rm -rf "$SANDBOX_DIR" "$FILTER_TMP"' EXIT

awk '
    /^cat > "\$FILTER_SCRIPT" << '\''FILTER'\''$/ { capturing=1; next }
    capturing && /^FILTER$/ { capturing=0; exit }
    capturing { print }
' "$SETUP" > "$FILTER_TMP"

if [ ! -s "$FILTER_TMP" ]; then
    echo "FAIL: could not extract FILTER heredoc"
    exit 1
fi

# Stub `exec bash -f -c "$CMD"` to a no-op success so we test "would the filter
# have allowed?" not "does the wrapped command succeed?".
sed -i.bak 's|^exec bash -f -c "\$CMD"|echo "ALLOWED"; exit 0|' "$FILTER_TMP"
rm -f "$FILTER_TMP.bak"

PASS=0
FAIL=0
FAILED=()

# Run filter with a given allowlist and command. $1=expected (allow|block),
# $2=allowlist file path (or empty for missing-file scenario), $3=plugin name
# to test, $4=optional override basename.
run_case() {
    local label="$1" expected="$2" cfg_path="$3" plugin_name="$4" basename="${5:-Foo.page}"
    local cmd="claude-write plugin-page $plugin_name $basename"
    local out rc got
    out=$(CLAUDE_SSH_ALLOWLIST_FILE="$cfg_path" \
        SSH_ORIGINAL_COMMAND="$cmd" \
        bash "$FILTER_TMP" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then got="allow"; else got="block"; fi
    if [ "$got" = "$expected" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED+=("$label: expected=$expected got=$got cfg=$cfg_path name=$plugin_name  ## $out")
    fi
}

# Helper: write fixture content and return its path. Use mktemp under sandbox.
seed_fixture() {
    local name="$1"; shift
    local p="$SANDBOX_DIR/$name.cfg"
    printf '%s\n' "$@" > "$p"
    echo "$p"
}

# === 1. Missing file → default-deny ===
run_case "missing-file"        block "$SANDBOX_DIR/does-not-exist.cfg" foo
run_case "missing-file-known"  block "$SANDBOX_DIR/does-not-exist.cfg" claude-ssh

# === 2. Empty file → default-deny ===
EMPTY=$(seed_fixture empty)
run_case "empty-file"          block "$EMPTY" foo
run_case "empty-file-known"    block "$EMPTY" claude-ssh

# === 3. Comments-only → default-deny ===
COMMENTS=$(seed_fixture comments \
    "# this is a comment" \
    "# plugin foo (commented out — should not allow foo)" \
    "")
run_case "comments-only"       block "$COMMENTS" foo

# === 4. Single valid entry ===
SINGLE=$(seed_fixture single \
    "plugin foo")
run_case "single-listed"       allow "$SINGLE" foo
run_case "single-other-blocked" block "$SINGLE" bar

# === 5. Multiple valid entries ===
MULTI=$(seed_fixture multi \
    "plugin foo" \
    "plugin bar" \
    "plugin torrent-handler")
run_case "multi-foo"           allow "$MULTI" foo
run_case "multi-bar"           allow "$MULTI" bar
run_case "multi-torrent"       allow "$MULTI" torrent-handler
run_case "multi-other-blocked" block "$MULTI" baz

# === 6. Whitespace tolerance ===
WS=$(seed_fixture whitespace \
    "" \
    "plugin foo" \
    "  plugin bar  " \
    $'\tplugin\tbaz\t' \
    "")
run_case "ws-leading-trailing" allow "$WS" foo
run_case "ws-spaces-around"    allow "$WS" bar
run_case "ws-tabs"             allow "$WS" baz

# === 7. Invalid: uppercase ===
UPPER=$(seed_fixture upper \
    "plugin Foo" \
    "plugin BAR")
run_case "upper-Foo-blocked"   block "$UPPER" Foo
run_case "upper-foo-blocked"   block "$UPPER" foo
run_case "upper-BAR-blocked"   block "$UPPER" BAR

# === 8. Invalid: special chars ===
SPECIAL=$(seed_fixture special \
    "plugin foo!" \
    "plugin foo_bar" \
    "plugin foo.bar" \
    "plugin foo/bar" \
    "plugin foo bar")
run_case "special-bang"        block "$SPECIAL" 'foo!'
run_case "special-underscore"  block "$SPECIAL" foo_bar
run_case "special-dot"         block "$SPECIAL" foo.bar
run_case "special-slash"       block "$SPECIAL" foo/bar
run_case "special-three-words" block "$SPECIAL" foo
run_case "special-leading-digit-in-name" block "$SPECIAL" 1foo

# === 9. Invalid: too long (65 chars > 64 cap) ===
LONG_NAME=$(printf 'a%.0s' $(seq 1 65))
SHORT_64=$(printf 'a%.0s' $(seq 1 64))
TOOLONG=$(seed_fixture toolong \
    "plugin $LONG_NAME" \
    "plugin $SHORT_64")
run_case "toolong-65-blocked"  block "$TOOLONG" "$LONG_NAME"
run_case "toolong-64-allowed"  allow "$TOOLONG" "$SHORT_64"

# === 10. Invalid: empty name ===
NOVALUE=$(seed_fixture novalue \
    "plugin " \
    "plugin" \
    "plugin   ")
run_case "novalue-empty-blocked" block "$NOVALUE" foo

# === 11. Duplicates → dedup, single still works ===
DUPS=$(seed_fixture dups \
    "plugin foo" \
    "plugin foo" \
    "plugin foo")
run_case "dups-still-allowed"  allow "$DUPS" foo

# === 12. Container-prefixed lines ignored by plugin parser ===
CONT=$(seed_fixture container \
    "container sonarr" \
    "container radarr" \
    "plugin claude-ssh")
run_case "container-not-plugin"  block "$CONT" sonarr
run_case "plugin-still-allowed"  allow "$CONT" claude-ssh

# === 13. Mixed valid + invalid → valid still pass ===
MIXED=$(seed_fixture mixed \
    "plugin foo" \
    "plugin BAR" \
    "plugin baz!" \
    "" \
    "# plugin commented" \
    "plugin qux")
run_case "mixed-foo"             allow "$MIXED" foo
run_case "mixed-qux"             allow "$MIXED" qux
run_case "mixed-BAR-blocked"     block "$MIXED" BAR
run_case "mixed-bang-blocked"    block "$MIXED" 'baz!'
run_case "mixed-commented-blocked" block "$MIXED" commented

# Report.
TOTAL=$((PASS + FAIL))
echo "  cases: $PASS passed / $FAIL failed / $TOTAL total"

if [ "$FAIL" -ne 0 ]; then
    echo "FAIL: $FAIL allowlist parser case(s) failed:"
    for f in "${FAILED[@]}"; do echo "  - $f"; done
    exit 1
fi
echo "PASS: allowlist.cfg parser behaves correctly"
