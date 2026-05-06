#!/bin/bash
# Verifies that the version markers used by exec.php's `readVersionMarker`
# are present and parse cleanly. This is the contract the Status page relies on.
#
# Markers checked:
#   scripts/unraid-readonly-ssh-setup.sh:  # Filter version: vN
#   scripts/claude-write-setup.sh:         # Writer version: vN
#   plugin-claude-ssh/claude-ssh.plg:      <!ENTITY version "YYYY.MM.DD[letter]">

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_SCRIPTS="$ROOT/src/usr/local/emhttp/plugins/claude-ssh/scripts"
FAIL=0

# Same regex as exec.php readVersionMarker (anchored, case-sensitive).
parse_marker() {
    local file="$1" marker="$2"
    grep -m1 -E "^[[:space:]]*#[[:space:]]*${marker}[[:space:]]*:[[:space:]]*v[0-9]+(\\.[0-9]+)*[[:space:]]*$" "$file" \
        | sed -E "s/^[[:space:]]*#[[:space:]]*${marker}[[:space:]]*:[[:space:]]*(v[0-9]+(\\.[0-9]+)*)[[:space:]]*$/\\1/"
}

FILTER_VER=$(parse_marker "$PLUGIN_SCRIPTS/unraid-readonly-ssh-setup.sh" "Filter version")
WRITER_VER=$(parse_marker "$PLUGIN_SCRIPTS/claude-write-setup.sh"        "Writer version")

if [ -z "$FILTER_VER" ]; then
    echo "  FAIL: '# Filter version: vN' marker not found in scripts/unraid-readonly-ssh-setup.sh"
    FAIL=1
else
    echo "  filter version: $FILTER_VER"
fi

if [ -z "$WRITER_VER" ]; then
    echo "  FAIL: '# Writer version: vN' marker not found in scripts/claude-write-setup.sh"
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

# Also confirm the filter heredoc has a v9 entry (sanity check that
# the changelog inside the runtime filter agrees with the marker).
if ! grep -qE '^# v9 ' "$PLUGIN_SCRIPTS/unraid-readonly-ssh-setup.sh"; then
    echo "  FAIL: heredoc-internal v9 changelog entry missing"
    FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
echo "PASS: version markers parse cleanly"
