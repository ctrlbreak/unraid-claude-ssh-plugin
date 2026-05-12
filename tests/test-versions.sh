#!/bin/bash
# Verifies that the version markers used by exec.php's `readVersionMarker`
# are present and parse cleanly. This is the contract the Status page relies on.
#
# Markers checked:
#   scripts/unraid-readonly-ssh-setup.sh:  FILTER_VERSION="vN"
#   scripts/claude-write-setup.sh:         WRITER_VERSION="vN"
#   claude-ssh.plg:                        <!ENTITY version "YYYY.MM.DD[letter]">

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_SCRIPTS="$ROOT/src/usr/local/emhttp/plugins/claude-ssh/scripts"
FAIL=0

# Same regex as exec.php readVersionMarker (anchored, case-sensitive).
parse_marker() {
    local file="$1" var="$2"
    grep -m1 -E "^[[:space:]]*${var}=\"?v[0-9]+(\\.[0-9]+)*\"?[[:space:]]*$" "$file" \
        | sed -E "s/^[[:space:]]*${var}=\"?(v[0-9]+(\\.[0-9]+)*)\"?[[:space:]]*$/\\1/"
}

FILTER_VER=$(parse_marker "$PLUGIN_SCRIPTS/unraid-readonly-ssh-setup.sh" "FILTER_VERSION")
WRITER_VER=$(parse_marker "$PLUGIN_SCRIPTS/claude-write-setup.sh"        "WRITER_VERSION")

if [ -z "$FILTER_VER" ]; then
    echo "  FAIL: FILTER_VERSION=\"vN\" assignment not found in scripts/unraid-readonly-ssh-setup.sh"
    FAIL=1
else
    echo "  filter version: $FILTER_VER"
fi

if [ -z "$WRITER_VER" ]; then
    echo "  FAIL: WRITER_VERSION=\"vN\" assignment not found in scripts/claude-write-setup.sh"
    FAIL=1
else
    echo "  writer version: $WRITER_VER"
fi

PLUGIN_VER=$(grep -oE '<!ENTITY[[:space:]]+version[[:space:]]+"[^"]+"' "$ROOT/claude-ssh.plg" \
    | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$PLUGIN_VER" ]; then
    echo "  FAIL: <!ENTITY version> not found in claude-ssh.plg"
    FAIL=1
else
    echo "  plugin version: $PLUGIN_VER"
fi

# Sanity: the heredoc-internal filter changelog has an entry for the current
# FILTER_VERSION. The runtime filter at /home/<user>/shell-filter.sh has its
# own per-version changelog block; the latest entry MUST match the marker.
if [ -n "$FILTER_VER" ]; then
    if ! grep -qE "^# ${FILTER_VER} " "$PLUGIN_SCRIPTS/unraid-readonly-ssh-setup.sh"; then
        echo "  FAIL: heredoc-internal '# ${FILTER_VER} ' changelog entry missing"
        FAIL=1
    fi
fi

# Sanity: the install banner uses the variable (no bare v[0-9] literal where
# it claims to print the filter version). This is the bug class that produced
# the historical "stale v7 banner".
if grep -qE 'Filter:[[:space:]]+\$FILTER_SCRIPT v[0-9]+' "$PLUGIN_SCRIPTS/unraid-readonly-ssh-setup.sh"; then
    echo "  FAIL: install banner has a bare vN literal — should interpolate \$FILTER_VERSION"
    FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
echo "PASS: version markers parse cleanly"
