#!/bin/bash
# Cross-checks the claude-write category surface for consistency. Three
# enforcement points must agree: the filter (in unraid-readonly-ssh-setup.sh),
# the privileged writer (in claude-write-setup.sh), and the sudoers rule.
#
# v8/v3 update: plugin-name allowlist moved to a runtime config file.
# v9/v4 update: same parser is now reused for the container allowlist
# (appdata-script category). The cross-check verifies filter and writer both
# read from the SAME env-var-overrideable path, apply the SAME name regex,
# and parse via the SAME awk shape (now parametric on line-prefix).
# Behaviour-level coverage of the parser lives in test-allowlist-config.sh.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_SCRIPTS="$ROOT/src/usr/local/emhttp/plugins/claude-ssh/scripts"
SETUP_FILTER="$PLUGIN_SCRIPTS/unraid-readonly-ssh-setup.sh"
SETUP_WRITER="$PLUGIN_SCRIPTS/claude-write-setup.sh"

if [ ! -f "$SETUP_FILTER" ] || [ ! -f "$SETUP_WRITER" ]; then
    echo "FAIL: source setup scripts not found"
    exit 1
fi

FAIL=0

# Categories the filter knows about (v9: simple, plugin, container).
FILTER_SIMPLE=$(grep -E '^CW_SIMPLE_CATEGORIES=' "$SETUP_FILTER" \
    | sed -E 's/^CW_SIMPLE_CATEGORIES="([^"]*)"$/\1/')
FILTER_PLUGIN=$(grep -E '^CW_PLUGIN_CATEGORIES=' "$SETUP_FILTER" \
    | sed -E 's/^CW_PLUGIN_CATEGORIES="([^"]*)"$/\1/')
FILTER_CONTAINER=$(grep -E '^CW_CONTAINER_CATEGORIES=' "$SETUP_FILTER" \
    | sed -E 's/^CW_CONTAINER_CATEGORIES="([^"]*)"$/\1/')

if [ -z "$FILTER_SIMPLE" ] || [ -z "$FILTER_PLUGIN" ] || [ -z "$FILTER_CONTAINER" ]; then
    echo "FAIL: could not parse filter category lists"
    FAIL=1
fi

echo "  filter simple:    $FILTER_SIMPLE"
echo "  filter plugin:    $FILTER_PLUGIN"
echo "  filter container: $FILTER_CONTAINER"

# Sanity: the legacy hook-* categories must be GONE from the filter (v9 drop).
for legacy in hook-sonarr hook-radarr; do
    if echo "$FILTER_SIMPLE $FILTER_PLUGIN $FILTER_CONTAINER" | grep -qw "$legacy"; then
        echo "  FAIL: legacy category '$legacy' still present (should have been dropped in v9)"
        FAIL=1
    fi
done

# 1. Every filter category must appear in the writer's case statement.
for cat in $FILTER_SIMPLE $FILTER_PLUGIN $FILTER_CONTAINER; do
    if ! grep -qE "^[[:space:]]*${cat}\)$" "$SETUP_WRITER"; then
        echo "  FAIL: category '$cat' has no case branch in claude-write-setup.sh"
        FAIL=1
    fi
done

# 2. Every filter category must appear in the sudoers line.
SUDOERS_LINE=$(grep '^claude ALL=' "$SETUP_WRITER")
if [ -z "$SUDOERS_LINE" ]; then
    echo "  FAIL: sudoers rule line not found in claude-write-setup.sh"
    FAIL=1
else
    for cat in $FILTER_SIMPLE; do
        # Simple categories: pattern is `<cat> *`
        if ! echo "$SUDOERS_LINE" | grep -qE "claude-write-priv ${cat} \\*([,]| |$)"; then
            echo "  FAIL: simple category '$cat' missing from sudoers (expect: 'claude-write-priv $cat *')"
            FAIL=1
        fi
    done
    for cat in $FILTER_PLUGIN $FILTER_CONTAINER; do
        # 3-arg categories: pattern is `<cat> * *` (extra wildcard for target name).
        if ! echo "$SUDOERS_LINE" | grep -qE "claude-write-priv ${cat} \\* \\*([,]| |$)"; then
            echo "  FAIL: 3-arg category '$cat' missing from sudoers (expect: 'claude-write-priv $cat * *')"
            FAIL=1
        fi
    done
    # Sudoers must NOT grant the legacy hook-* categories.
    for legacy in hook-sonarr hook-radarr; do
        if echo "$SUDOERS_LINE" | grep -qE "claude-write-priv ${legacy} "; then
            echo "  FAIL: legacy sudoers grant for '$legacy' still present"
            FAIL=1
        fi
    done
fi

# 3. Plugin-name allowlist sourced from runtime config — filter and writer
# must read the SAME path with the SAME default. Both use:
#   "${CLAUDE_SSH_ALLOWLIST_FILE:-/boot/config/plugins/claude-ssh/allowlist.cfg}"
EXPECTED_PATH_FRAG='${CLAUDE_SSH_ALLOWLIST_FILE:-/boot/config/plugins/claude-ssh/allowlist.cfg}'
if ! grep -qF "$EXPECTED_PATH_FRAG" "$SETUP_FILTER"; then
    echo "  FAIL: filter does not reference allowlist path with expected default"
    FAIL=1
fi
if ! grep -qF "$EXPECTED_PATH_FRAG" "$SETUP_WRITER"; then
    echo "  FAIL: writer does not reference allowlist path with expected default"
    FAIL=1
fi

# 4. Both must use the SAME parametric awk extraction shape and the SAME
# post-validate regex. Drift here means filter and writer could disagree on
# which entries in allowlist.cfg are valid — a soft failure mode that would
# let one side accept a name the other rejects. v9: parser is parametric on
# line-prefix (-v k="$kind") to support both plugin and container allowlists.
EXPECTED_AWK_LINE='awk -v k="$kind" '"'"'NF == 2 && $1 == k { print $2 }'"'"' "$'
EXPECTED_GREP_LINE='grep -xE '"'"'[a-z][a-z0-9-]{0,63}'"'"
for f in "$SETUP_FILTER" "$SETUP_WRITER"; do
    name=$(basename "$f")
    if ! grep -qF "$EXPECTED_AWK_LINE" "$f"; then
        echo "  FAIL: $name missing expected parametric awk extraction line"
        FAIL=1
    fi
    if ! grep -qF "$EXPECTED_GREP_LINE" "$f"; then
        echo "  FAIL: $name missing expected grep regex line for allowlist"
        FAIL=1
    fi
done

# 5. Basename pattern consistent (unchanged from v7).
FILTER_PATTERN=$(grep -oE "'\\^\[a-zA-Z0-9\]\[a-zA-Z0-9\._\-\]\{0,127\}\\\$'" "$SETUP_FILTER" | head -1)
WRITER_PATTERN=$(grep -oE "'\\^\[a-zA-Z0-9\]\[a-zA-Z0-9\._\-\]\{0,127\}\\\$'" "$SETUP_WRITER" | head -1)
if [ -z "$FILTER_PATTERN" ] || [ -z "$WRITER_PATTERN" ] || [ "$FILTER_PATTERN" != "$WRITER_PATTERN" ]; then
    echo "  FAIL: basename pattern mismatch (filter='$FILTER_PATTERN' writer='$WRITER_PATTERN')"
    FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
echo "PASS: claude-write surface consistent across filter, writer, sudoers"
