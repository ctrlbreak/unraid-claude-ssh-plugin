#!/bin/bash
# Cross-checks the claude-write category surface for consistency. Three
# enforcement points must agree: the filter (in unraid-readonly-ssh-setup.sh),
# the privileged writer (in claude-write-setup.sh), and the sudoers rule.

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

# Categories the filter knows about (v7).
FILTER_SIMPLE=$(grep -E '^CW_SIMPLE_CATEGORIES=' "$SETUP_FILTER" \
    | sed -E 's/^CW_SIMPLE_CATEGORIES="([^"]*)"$/\1/')
FILTER_PLUGIN=$(grep -E '^CW_PLUGIN_CATEGORIES=' "$SETUP_FILTER" \
    | sed -E 's/^CW_PLUGIN_CATEGORIES="([^"]*)"$/\1/')
FILTER_PLUGINS=$(grep -E '^CW_PLUGIN_NAMES=' "$SETUP_FILTER" \
    | sed -E 's/^CW_PLUGIN_NAMES="([^"]*)"$/\1/')

if [ -z "$FILTER_SIMPLE" ] || [ -z "$FILTER_PLUGIN" ] || [ -z "$FILTER_PLUGINS" ]; then
    echo "FAIL: could not parse filter category lists"
    FAIL=1
fi

echo "  filter simple: $FILTER_SIMPLE"
echo "  filter plugin: $FILTER_PLUGIN"
echo "  filter plugins allowlist: $FILTER_PLUGINS"

# 1. Every filter category must appear in the writer's case statement.
for cat in $FILTER_SIMPLE $FILTER_PLUGIN; do
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
        if ! echo "$SUDOERS_LINE" | grep -qE "claude-write-priv ${cat} \\*([,]| )"; then
            echo "  FAIL: simple category '$cat' missing from sudoers (expect: 'claude-write-priv $cat *')"
            FAIL=1
        fi
    done
    for cat in $FILTER_PLUGIN; do
        # Plugin categories: pattern is `<cat> * *` (extra wildcard for plugin-name).
        if ! echo "$SUDOERS_LINE" | grep -qE "claude-write-priv ${cat} \\* \\*([,]| |$)"; then
            echo "  FAIL: plugin category '$cat' missing from sudoers (expect: 'claude-write-priv $cat * *')"
            FAIL=1
        fi
    done
fi

# 3. Plugin-name allowlist in filter must match the writer's allowlist.
# Match the line shaped `    torrent-handler|claude-ssh) ;;` — case body trails
# the closing paren, so anchor on `)` not on end-of-line.
WRITER_PLUGINS=$(grep -E '^[[:space:]]+[a-z|-]+\)[[:space:]]+;;[[:space:]]*$' "$SETUP_WRITER" \
    | grep 'torrent-handler' \
    | head -1 \
    | sed -E 's/^[[:space:]]+([a-z|-]+)\).*/\1/' | tr '|' ' ')
if [ -z "$WRITER_PLUGINS" ]; then
    echo "  FAIL: writer plugin-name allowlist not parseable"
    FAIL=1
else
    # Compare as space-separated sorted sets.
    fp=$(echo "$FILTER_PLUGINS" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    wp=$(echo "$WRITER_PLUGINS" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    if [ "$fp" != "$wp" ]; then
        echo "  FAIL: plugin-name allowlist mismatch — filter='$fp' writer='$wp'"
        FAIL=1
    fi
fi

# 4. Basename pattern consistent.
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
