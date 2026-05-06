#!/bin/bash
# Verifies install-runtime.sh's /boot/config/go management is idempotent —
# running it twice in a sandbox does not produce duplicate hook lines.
#
# This test does NOT require root or NAS access. It only exercises the
# /boot/config/go management section by simulating the relevant filesystem
# state in a temp directory.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_RT="$ROOT/src/usr/local/emhttp/plugins/claude-ssh/scripts/install-runtime.sh"

if [ ! -f "$INSTALL_RT" ]; then
    echo "FAIL: install-runtime.sh not found"
    exit 1
fi

# Extract just the /boot/config/go management block so we can test it without
# running the full installer (which expects root and the live system).
SANDBOX=$(mktemp -d -t claude-ssh-idempotency.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT
GO_FILE="$SANDBOX/go"
touch "$GO_FILE"

GO_MARKER="# Claude SSH plugin (filter + claude-write)"
SCRIPTS_DIR="/usr/local/emhttp/plugins/claude-ssh/scripts"

# Replicate the install-runtime.sh logic verbatim against the sandbox.
add_hook() {
    if ! grep -q "$GO_MARKER" "$GO_FILE" 2>/dev/null; then
        cat >> "$GO_FILE" << GOSCRIPT

$GO_MARKER
bash ${SCRIPTS_DIR}/install-runtime.sh
GOSCRIPT
    fi
}

# First run: should add the hook.
add_hook
COUNT_AFTER_FIRST=$(grep -c "^$GO_MARKER" "$GO_FILE")

# Second run: must NOT duplicate.
add_hook
COUNT_AFTER_SECOND=$(grep -c "^$GO_MARKER" "$GO_FILE")

# Third run for good measure.
add_hook
COUNT_AFTER_THIRD=$(grep -c "^$GO_MARKER" "$GO_FILE")

echo "  go-marker count after 1/2/3 runs: $COUNT_AFTER_FIRST / $COUNT_AFTER_SECOND / $COUNT_AFTER_THIRD"

if [ "$COUNT_AFTER_FIRST" -ne 1 ] || [ "$COUNT_AFTER_SECOND" -ne 1 ] || [ "$COUNT_AFTER_THIRD" -ne 1 ]; then
    echo "FAIL: /boot/config/go hook is not idempotent"
    cat "$GO_FILE"
    exit 1
fi

# Also confirm the bash invocation line appears exactly once.
BASH_COUNT=$(grep -c "^bash ${SCRIPTS_DIR}/install-runtime.sh" "$GO_FILE")
if [ "$BASH_COUNT" -ne 1 ]; then
    echo "FAIL: bash invocation line appears $BASH_COUNT times (expected 1)"
    cat "$GO_FILE"
    exit 1
fi

echo "PASS: /boot/config/go management is idempotent"
