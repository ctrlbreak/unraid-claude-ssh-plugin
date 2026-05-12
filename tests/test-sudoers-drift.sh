#!/bin/bash
# Cross-checks the claude-write category list across four sites:
#
#   1. Filter setup (CW_SIMPLE_CATEGORIES + CW_PLUGIN_CATEGORIES +
#      CW_CONTAINER_CATEGORIES in unraid-readonly-ssh-setup.sh)
#   2. Writer case statement (claude-write-setup.sh, inside the PRIV heredoc)
#   3. Sudoers grants (claude-write-setup.sh, inside the SUDO heredoc)
#   4. exec.php writes_per_category counter keys
#
# If any of these drift, the failure mode is silent: the wrapper might accept
# a category the sudoers doesn't grant (runtime broken), the dashboard might
# under-count (audit log gap), or the writer might map a category the filter
# wouldn't pass through (defence-in-depth gap). Drift check is set-equality.
#
# Also asserts argv shape in sudoers: simple categories take 2 args
# (`<cat> *`), plugin/container categories take 3 args (`<cat> * *`).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILTER_SETUP="$ROOT/src/usr/local/emhttp/plugins/claude-ssh/scripts/unraid-readonly-ssh-setup.sh"
WRITER_SETUP="$ROOT/src/usr/local/emhttp/plugins/claude-ssh/scripts/claude-write-setup.sh"
EXEC_PHP="$ROOT/src/usr/local/emhttp/plugins/claude-ssh/include/exec.php"

for f in "$FILTER_SETUP" "$WRITER_SETUP" "$EXEC_PHP"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: $f not found"
        exit 1
    fi
done

PASS=0
FAIL=0
FAILED=()

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED+=("$label: expected [$expected], got [$actual]")
    fi
}

# Normalise a space-separated category list to sorted, newline-separated.
norm() {
    tr ' ' '\n' | grep -v '^$' | sort -u
}

# --- 1. Filter categories ----------------------------------------------------
# Pull the three CW_*_CATEGORIES literals from the filter setup.
F_SIMPLE=$(grep -E '^CW_SIMPLE_CATEGORIES=' "$FILTER_SETUP" | head -1 \
    | sed -E 's/^CW_SIMPLE_CATEGORIES="([^"]*)"$/\1/')
F_PLUGIN=$(grep -E '^CW_PLUGIN_CATEGORIES=' "$FILTER_SETUP" | head -1 \
    | sed -E 's/^CW_PLUGIN_CATEGORIES="([^"]*)"$/\1/')
F_CONTAINER=$(grep -E '^CW_CONTAINER_CATEGORIES=' "$FILTER_SETUP" | head -1 \
    | sed -E 's/^CW_CONTAINER_CATEGORIES="([^"]*)"$/\1/')

if [ -z "$F_SIMPLE" ] || [ -z "$F_PLUGIN" ] || [ -z "$F_CONTAINER" ]; then
    echo "FAIL: could not extract CW_*_CATEGORIES from filter setup"
    echo "  CW_SIMPLE_CATEGORIES=[$F_SIMPLE]"
    echo "  CW_PLUGIN_CATEGORIES=[$F_PLUGIN]"
    echo "  CW_CONTAINER_CATEGORIES=[$F_CONTAINER]"
    exit 1
fi

FILTER_CATS=$(printf '%s %s %s\n' "$F_SIMPLE" "$F_PLUGIN" "$F_CONTAINER" | norm)
echo "  filter categories: $(echo "$FILTER_CATS" | tr '\n' ' ')"

# --- 2. Writer case-statement categories ------------------------------------
# Inside the PRIV heredoc (cat > "$PRIV_PATH" << 'PRIV' ... PRIV) there are two
# case statements that mention every category. We extract the FIRST one (the
# arg-validation case) and pull the case patterns. The patterns are either a
# bare token (`scratch)`) or pipe-separated (`plugin-page|plugin-include|...)`).
#
# We restrict to the PRIV heredoc body so the SUDO heredoc grants don't pollute.
WRITER_CATS=$(awk '
    /^cat > "\$PRIV_PATH" << '\''PRIV'\''$/ { in_priv=1; next }
    in_priv && /^PRIV$/ { in_priv=0; exit }
    in_priv && /^case "\$CATEGORY" in$/ { in_case=1; next }
    in_case && /^esac$/ { in_case=0 }
    in_case && /^[[:space:]]+[a-z][a-z0-9|*-]*\)/ {
        # Strip leading whitespace and the trailing `)`; pipe → newline.
        line = $0
        sub(/^[[:space:]]+/, "", line)
        sub(/\).*$/, "", line)
        gsub(/\|/, "\n", line)
        print line
    }
' "$WRITER_SETUP" | grep -v '^\*$' | sort -u)
echo "  writer categories: $(echo "$WRITER_CATS" | tr '\n' ' ')"

# --- 3. Sudoers grants ------------------------------------------------------
# Pull the principal line and extract every category token after each
# `/usr/local/sbin/claude-write-priv ` reference.
SUDO_LINE=$(awk '
    /^cat > "\$TMP_SUDO" << SUDO$/ { in_sudo=1; next }
    in_sudo && /^SUDO$/ { in_sudo=0; exit }
    in_sudo && /\$USERNAME ALL=\(root\)/ { print; exit }
' "$WRITER_SETUP")

if [ -z "$SUDO_LINE" ]; then
    echo "FAIL: could not extract sudoers principal line from $WRITER_SETUP"
    exit 1
fi

SUDOERS_CATS=$(echo "$SUDO_LINE" \
    | grep -oE '/usr/local/sbin/claude-write-priv [a-z][a-z0-9-]*' \
    | awk '{print $2}' \
    | sort -u)
echo "  sudoers categories: $(echo "$SUDOERS_CATS" | tr '\n' ' ')"

# --- 4. exec.php writes_per_category counter keys ---------------------------
# Extract the writes_per_category array body, then pull the quoted keys.
PHP_CATS=$(awk '
    /writes_per_category.*=>.*\[/ { in_arr=1; next }
    in_arr && /^[[:space:]]*\]/ { exit }
    in_arr { print }
' "$EXEC_PHP" | grep -oE "'[a-z][a-z0-9-]*'" | tr -d "'" | sort -u)
echo "  exec.php counter keys: $(echo "$PHP_CATS" | tr '\n' ' ')"

# --- 5. Set-equality cross-check -------------------------------------------
assert_eq "filter == writer" "$FILTER_CATS" "$WRITER_CATS"
assert_eq "filter == sudoers" "$FILTER_CATS" "$SUDOERS_CATS"
assert_eq "filter == exec.php" "$FILTER_CATS" "$PHP_CATS"

# --- 6. Argv shape in sudoers ----------------------------------------------
# Simple categories take 2 args: `<cat> *`. Container takes 3: `<cat> * *`.
# plugin-file (v11+) takes 3-args with a rel-path that may contain 0, 1, or 2
# slashes — and sudo's `*` does not match `/`, so each rel-path arity must be
# enumerated as its own pattern. The writer caps rel-path depth at 3
# components; the test asserts the three required arities AND the absence of
# any 4-slash pattern (so future-proofing edits can't quietly raise the cap
# at the sudoers layer past what the writer enforces).
check_argv_shape() {
    local cat="$1" expected_shape="$2" line="$3" found_shape
    if echo "$line" | grep -qE "/usr/local/sbin/claude-write-priv $cat \* \*([,]|$)"; then
        found_shape=3
    elif echo "$line" | grep -qE "/usr/local/sbin/claude-write-priv $cat \*([,]|$)"; then
        found_shape=2
    else
        found_shape="missing"
    fi
    assert_eq "argv shape: $cat (expected ${expected_shape}-arg)" "$expected_shape" "$found_shape"
}

for cat in $F_SIMPLE; do check_argv_shape "$cat" 2 "$SUDO_LINE"; done
for cat in $F_CONTAINER; do check_argv_shape "$cat" 3 "$SUDO_LINE"; done

# plugin-file: assert all three rel-path arities are present.
for shape in 'plugin-file \* \*' 'plugin-file \* \*/\*' 'plugin-file \* \*/\*/\*'; do
    if echo "$SUDO_LINE" | grep -qE "claude-write-priv $shape([,]| |$)"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED+=("sudoers missing plugin-file arity: $shape")
    fi
done
# Negative: no 4-slash pattern (writer's depth cap is 3 components).
if echo "$SUDO_LINE" | grep -qE 'plugin-file \* \*/\*/\*/\*'; then
    FAIL=$((FAIL + 1))
    FAILED+=("sudoers has 4-slash plugin-file pattern — writer caps at 3 components")
else
    PASS=$((PASS + 1))
fi

TOTAL=$((PASS + FAIL))
echo "  cases: $PASS passed / $FAIL failed / $TOTAL total"
if [ "$FAIL" -ne 0 ]; then
    echo "FAIL: category list drift across filter / writer / sudoers / exec.php"
    for f in "${FAILED[@]}"; do echo "  - $f"; done
    exit 1
fi
echo "PASS: claude-write category list consistent across filter, writer, sudoers, and exec.php"
