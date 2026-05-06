#!/bin/bash
# Catches jQuery `$` shadowing in .page files. Unraid pages get jQuery in
# global scope, and pages typically call `$.post(...)` for AJAX. Defining a
# local `$` (e.g. `function $(id) { return document.getElementById(id); }`)
# inside the page's IIFE silently breaks `$.post` — the script throws a
# TypeError on the first AJAX call and the UI sits at "Loading..." forever
# with no requests visible in the browser network tab.
#
# This caught us once in v1 of ClaudeSsh.page. Don't ship it again.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PAGES=$(find "$ROOT/src" -name '*.page' 2>/dev/null)
if [ -z "$PAGES" ]; then
    echo "  no .page files found, skipping"
    exit 0
fi

FAIL=0
for p in $PAGES; do
    # Pattern 1: function $(...) — local declaration shadows jQuery.
    if grep -nE '^[[:space:]]*function[[:space:]]*\$\(' "$p"; then
        echo "  FAIL: $p — local 'function \$()' shadows jQuery"
        FAIL=1
    fi
    # Pattern 2: var $ = ... or let $ = ... or const $ = ...
    if grep -nE '^[[:space:]]*(var|let|const)[[:space:]]+\$[[:space:]]*=' "$p"; then
        echo "  FAIL: $p — local '\$ =' assignment shadows jQuery"
        FAIL=1
    fi
done

if [ "$FAIL" -ne 0 ]; then
    echo "FAIL: jQuery shadowing in .page files would break \$.post AJAX silently"
    exit 1
fi
echo "PASS: no jQuery shadowing in .page files"
