#!/bin/bash
# Validates claude-ssh.plg: well-formed XML, version entity present and in
# the date-based format we use everywhere (YYYY.MM.DD[letter]).

set -u
PLG="$(dirname "$0")/../claude-ssh.plg"

if [ ! -f "$PLG" ]; then
    echo "FAIL: $PLG not found"
    exit 1
fi

# 1. XML parses (skip if xmllint not installed).
if command -v xmllint >/dev/null 2>&1; then
    if ! xmllint --noout "$PLG" 2>/dev/null; then
        echo "FAIL: $PLG is not well-formed XML"
        xmllint --noout "$PLG"
        exit 1
    fi
    echo "  xmllint: ok"
else
    echo "  xmllint not installed; skipping XML well-formedness check"
fi

# 2. Version entity present.
if ! grep -qE '<!ENTITY[[:space:]]+version[[:space:]]+"[^"]+"' "$PLG"; then
    echo "FAIL: <!ENTITY version> missing"
    exit 1
fi
VERSION=$(grep -oE '<!ENTITY[[:space:]]+version[[:space:]]+"[^"]+"' "$PLG" \
    | sed -E 's/.*"([^"]+)".*/\1/')
echo "  version: $VERSION"

# 3. Version format check (YYYY.MM.DD or YYYY.MM.DD<letter>).
if ! echo "$VERSION" | grep -qE '^[0-9]{4}\.(0[1-9]|1[0-2])\.(0[1-9]|[12][0-9]|3[01])[a-z]?$'; then
    echo "FAIL: version '$VERSION' does not match YYYY.MM.DD[letter]"
    exit 1
fi

# 4. Required entities present.
for entity in name author version pluginURL pkgURL cfgDir emhttpDir; do
    if ! grep -qE "<!ENTITY[[:space:]]+${entity}[[:space:]]+" "$PLG"; then
        echo "FAIL: missing entity '$entity'"
        exit 1
    fi
done

# 5. Install + remove hooks present.
if ! grep -q '<FILE Run="/bin/bash">' "$PLG"; then
    echo "FAIL: install hook (<FILE Run=\"/bin/bash\">) missing"
    exit 1
fi
if ! grep -q 'Method="remove"' "$PLG"; then
    echo "FAIL: remove hook missing"
    exit 1
fi

echo "PASS: $PLG"
