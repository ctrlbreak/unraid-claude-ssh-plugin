#!/bin/bash
# Round-trip test for the Settings UI save/load handlers in include/exec.php.
#
# Strategy: include/exec.php's dispatcher early-returns when SAPI is "cli", so
# we can require_once it from a tiny PHP runner and call save_allowlist_file()
# / load_allowlist_file() directly — the same code path the AJAX endpoint runs
# in production, just without the $_POST shape.
#
# Coverage:
#   - empty save creates an empty (header-only) allowlist
#   - single + multi-name saves round-trip via the awk-shape parser
#   - whitespace and comma separators both work
#   - invalid names rejected (uppercase, special chars, length, leading-digit)
#   - duplicates deduped
#   - file mode is 644 (matches install-runtime.sh seed)
#   - missing file returns exists=false with empty arrays
#   - written file is parseable by the runtime awk parser shape
#
# Skips with exit 77 if PHP isn't installed locally (matches test-php-lint.sh).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC_PHP="$ROOT/src/usr/local/emhttp/plugins/claude-ssh/include/exec.php"

if ! command -v php >/dev/null 2>&1; then
    echo "  php not installed; skipping (install via 'brew install php')"
    exit 77
fi
if [ ! -f "$EXEC_PHP" ]; then
    echo "FAIL: $EXEC_PHP not found"
    exit 1
fi

SANDBOX=$(mktemp -d -t claude-ssh-settings-XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT

# One-shot PHP runner. Reads action + inputs from env (avoids shell-quoting
# pain with names like "foo!" or multi-line textareas).
cat > "$SANDBOX/run.php" << 'RUNNER'
<?php
require_once getenv('EXEC_PHP');
$action     = getenv('ACT') ?: 'roundtrip';
// Empty/unset CFG → null, so save_/load_allowlist_file use cs_allowlist_path()
// which honours the CLAUDE_SSH_ALLOWLIST_FILE env override. This is the path
// case 14 exercises.
$cfg        = getenv('CFG');
if ($cfg === false || $cfg === '') $cfg = null;
$plugins    = getenv('PLUGINS');    if ($plugins    === false) $plugins    = '';
$containers = getenv('CONTAINERS'); if ($containers === false) $containers = '';

if ($action === 'roundtrip') {
    $save = save_allowlist_file($plugins, $containers, $cfg);
    $load = load_allowlist_file($cfg);
    echo json_encode(['save' => $save, 'load' => $load]);
} elseif ($action === 'save_only') {
    echo json_encode(save_allowlist_file($plugins, $containers, $cfg));
} elseif ($action === 'load_only') {
    echo json_encode(load_allowlist_file($cfg));
}
RUNNER

export EXEC_PHP

PASS=0
FAIL=0
FAILED=()

# Run save+load on the same path; outputs JSON to stdout.
roundtrip() {
    PLUGINS="$1" CONTAINERS="$2" CFG="$3" ACT=roundtrip \
        php "$SANDBOX/run.php"
}
load_only() {
    CFG="$1" ACT=load_only \
        php "$SANDBOX/run.php"
}

# Substring-presence assertion against JSON output. Tight enough for our
# deterministic JSON (PHP's json_encode is stable for our shapes); avoids a
# JSON-parser dependency in the test runner.
assert_in() {
    local label="$1" json="$2" needle="$3"
    if printf '%s' "$json" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED+=("$label: expected substring '$needle' in JSON")
        FAILED+=("    got: $json")
    fi
}
assert_not_in() {
    local label="$1" json="$2" needle="$3"
    if printf '%s' "$json" | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1))
        FAILED+=("$label: unexpected substring '$needle' in JSON")
        FAILED+=("    got: $json")
    else
        PASS=$((PASS + 1))
    fi
}

# === 1. Empty save creates header-only allowlist ===
CFG="$SANDBOX/empty.cfg"
J=$(roundtrip '' '' "$CFG")
assert_in     "empty.save.ok"        "$J" '"save":{"ok":true'
assert_in     "empty.load.exists"    "$J" '"exists":true'
assert_in     "empty.load.plugins"   "$J" '"plugins":[]'
assert_in     "empty.load.containers" "$J" '"containers":[]'
[ -f "$CFG" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED+=("empty.save: file not created"); }

# === 2. Single plugin + container ===
CFG="$SANDBOX/single.cfg"
J=$(roundtrip 'foo' 'bar' "$CFG")
assert_in     "single.save.ok"           "$J" '"save":{"ok":true'
assert_in     "single.load.plugin"       "$J" '"plugins":["foo"]'
assert_in     "single.load.container"    "$J" '"containers":["bar"]'

# === 3. Newline-separated input ===
CFG="$SANDBOX/multi.cfg"
J=$(roundtrip $'foo\nbar\nbaz' $'sonarr\nradarr' "$CFG")
assert_in     "multi.save.ok"            "$J" '"save":{"ok":true'
assert_in     "multi.load.plugins"       "$J" '"plugins":["foo","bar","baz"]'
assert_in     "multi.load.containers"    "$J" '"containers":["sonarr","radarr"]'

# === 4. Comma-separated input ===
CFG="$SANDBOX/comma.cfg"
J=$(roundtrip 'foo, bar, baz' 'sonarr,radarr' "$CFG")
assert_in     "comma.save.ok"            "$J" '"save":{"ok":true'
assert_in     "comma.load.plugins"       "$J" '"plugins":["foo","bar","baz"]'
assert_in     "comma.load.containers"    "$J" '"containers":["sonarr","radarr"]'

# === 5. Invalid name rejected — uppercase ===
CFG="$SANDBOX/upper.cfg"
J=$(roundtrip 'Foo' '' "$CFG")
assert_in     "upper.save.fail"          "$J" '"save":{"ok":false'
assert_in     "upper.save.error"         "$J" 'invalid plugin name'
# File should NOT exist on failed save (no atomic rename happened)
if [ -f "$CFG" ]; then
    FAIL=$((FAIL+1)); FAILED+=("upper: file created despite rejected save")
else
    PASS=$((PASS+1))
fi

# === 6. Invalid name rejected — special chars ===
CFG="$SANDBOX/special.cfg"
J=$(roundtrip 'foo!' '' "$CFG")
assert_in     "special.save.fail"        "$J" '"save":{"ok":false'

CFG="$SANDBOX/special2.cfg"
J=$(roundtrip 'foo_bar' '' "$CFG")
assert_in     "special-underscore.fail"  "$J" '"save":{"ok":false'

CFG="$SANDBOX/special3.cfg"
J=$(roundtrip '' 'sonarr/v2' "$CFG")
assert_in     "special-slash-container"  "$J" '"save":{"ok":false'
assert_in     "special-slash-msg"        "$J" 'invalid container name'

# === 7. Invalid name rejected — leading digit ===
CFG="$SANDBOX/lead-digit.cfg"
J=$(roundtrip '1foo' '' "$CFG")
assert_in     "lead-digit.fail"          "$J" '"save":{"ok":false'

# === 8. Invalid name rejected — too long (65 chars > 64 cap) ===
LONG65=$(printf 'a%.0s' $(seq 1 65))
SHORT64=$(printf 'a%.0s' $(seq 1 64))
CFG="$SANDBOX/long.cfg"
J=$(roundtrip "$LONG65" '' "$CFG")
assert_in     "long65.fail"              "$J" '"save":{"ok":false'
CFG="$SANDBOX/short.cfg"
J=$(roundtrip "$SHORT64" '' "$CFG")
assert_in     "short64.ok"               "$J" '"save":{"ok":true'

# === 9. Duplicates deduped ===
CFG="$SANDBOX/dups.cfg"
J=$(roundtrip $'foo\nfoo\nfoo' $'sonarr\nsonarr' "$CFG")
assert_in     "dups.save.ok"             "$J" '"save":{"ok":true'
assert_in     "dups.load.plugins"        "$J" '"plugins":["foo"]'
assert_in     "dups.load.containers"     "$J" '"containers":["sonarr"]'

# === 10. File mode is 644 ===
CFG="$SANDBOX/mode.cfg"
roundtrip 'foo' 'bar' "$CFG" >/dev/null
MODE=$(stat -f '%A' "$CFG" 2>/dev/null || stat -c '%a' "$CFG" 2>/dev/null)
if [ "$MODE" = "644" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1)); FAILED+=("mode.cfg: expected 644 got '$MODE'")
fi

# === 11. Missing file → exists=false, empty arrays ===
J=$(load_only "$SANDBOX/nope.cfg")
assert_in     "missing.exists.false"     "$J" '"exists":false'
assert_in     "missing.plugins.empty"    "$J" '"plugins":[]'
assert_in     "missing.containers.empty" "$J" '"containers":[]'

# === 12. Written file parses cleanly under the runtime awk shape ===
# This is the same line the filter and writer use:
#   awk -v k=plugin    'NF == 2 && $1 == k { print $2 }' allowlist.cfg
#   awk -v k=container 'NF == 2 && $1 == k { print $2 }' allowlist.cfg
CFG="$SANDBOX/awk.cfg"
roundtrip $'qux\nbaz' $'sonarr\nradarr' "$CFG" >/dev/null
PLUGINS_AWK=$(awk -v k=plugin    'NF == 2 && $1 == k { print $2 }' "$CFG" | sort | tr '\n' ',')
CONTAINERS_AWK=$(awk -v k=container 'NF == 2 && $1 == k { print $2 }' "$CFG" | sort | tr '\n' ',')
if [ "$PLUGINS_AWK" = "baz,qux," ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1)); FAILED+=("awk plugin parse: expected 'baz,qux,' got '$PLUGINS_AWK'")
fi
if [ "$CONTAINERS_AWK" = "radarr,sonarr," ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1)); FAILED+=("awk container parse: expected 'radarr,sonarr,' got '$CONTAINERS_AWK'")
fi

# === 13. Header is preserved on save (so users see the format hint) ===
CFG="$SANDBOX/header.cfg"
roundtrip 'foo' 'bar' "$CFG" >/dev/null
if grep -qF 'claude-ssh allowlist' "$CFG" && grep -qF '^[a-z][a-z0-9-]{0,63}$' "$CFG"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1)); FAILED+=("header.cfg: expected header comment block")
fi

# === 14. Env-var override ===
# CLAUDE_SSH_ALLOWLIST_FILE should redirect cs_allowlist_path() → custom path.
CFG="$SANDBOX/env-override.cfg"
J=$(CLAUDE_SSH_ALLOWLIST_FILE="$CFG" \
    PLUGINS='via-env' CONTAINERS='' CFG='' ACT=roundtrip \
    php "$SANDBOX/run.php")
# When CFG env var is empty, save_allowlist_file($,$,'') falls through to
# cs_allowlist_path() which honours CLAUDE_SSH_ALLOWLIST_FILE.
# We pass CFG='' explicitly to test that path; the file should land at $CFG.
# NB: the wrapper is awkward here, but it's a real test of the env override.
if [ -f "$CFG" ] && grep -qF 'plugin via-env' "$CFG"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1)); FAILED+=("env-override: expected file at $CFG with 'plugin via-env'")
    FAILED+=("    got JSON: $J")
fi

TOTAL=$((PASS + FAIL))
echo "  cases: $PASS passed / $FAIL failed / $TOTAL total"
if [ "$FAIL" -ne 0 ]; then
    echo "FAIL: $FAIL settings save/load case(s) failed:"
    for f in "${FAILED[@]}"; do echo "  - $f"; done
    exit 1
fi
echo "PASS: settings save/load round-trip"
