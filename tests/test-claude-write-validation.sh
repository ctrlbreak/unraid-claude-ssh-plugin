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
# Phase 6: principal is now $USERNAME (interpolated at install time, not hardcoded).
SUDOERS_LINE=$(grep '^\$USERNAME ALL=' "$SETUP_WRITER")
if [ -z "$SUDOERS_LINE" ]; then
    echo "  FAIL: sudoers rule line not found in claude-write-setup.sh (expected '\$USERNAME ALL=...')"
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
# must read the SAME path with the SAME default. v10+ default lives on the
# array (mode 644 readable by the constrained SSH user); /boot was FAT and
# kernel-forced mode 700, so the filter couldn't read the allowlist there.
#   "${CLAUDE_SSH_ALLOWLIST_FILE:-/mnt/user/appdata/claude-ssh/allowlist.cfg}"
EXPECTED_PATH_FRAG='${CLAUDE_SSH_ALLOWLIST_FILE:-/mnt/user/appdata/claude-ssh/allowlist.cfg}'
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

# 5. exec.php (Settings UI backend) must reference the SAME allowlist path
# default and honour the SAME CLAUDE_SSH_ALLOWLIST_FILE env override, with the
# SAME name regex. Drift here lets the UI accept names the runtime rejects
# (or vice versa) — which silently breaks deploys.
EXEC_PHP="$ROOT/src/usr/local/emhttp/plugins/claude-ssh/include/exec.php"
if [ ! -f "$EXEC_PHP" ]; then
    echo "  FAIL: $EXEC_PHP missing"
    FAIL=1
else
    if ! grep -qF "/mnt/user/appdata/claude-ssh/allowlist.cfg" "$EXEC_PHP"; then
        echo "  FAIL: exec.php missing default allowlist path"
        FAIL=1
    fi
    if ! grep -qF "CLAUDE_SSH_ALLOWLIST_FILE" "$EXEC_PHP"; then
        echo "  FAIL: exec.php missing CLAUDE_SSH_ALLOWLIST_FILE env override"
        FAIL=1
    fi
    # Same name regex (PHP form: '/^[a-z][a-z0-9-]{0,63}$/'). Match on the
    # character-class fragment that's identical across PHP and shell-grep.
    if ! grep -qF "[a-z][a-z0-9-]{0,63}" "$EXEC_PHP"; then
        echo "  FAIL: exec.php missing name regex"
        FAIL=1
    fi
fi

# 6. Basename pattern consistent (unchanged from v7).
FILTER_PATTERN=$(grep -oE "'\\^\[a-zA-Z0-9\]\[a-zA-Z0-9\._\-\]\{0,127\}\\\$'" "$SETUP_FILTER" | head -1)
WRITER_PATTERN=$(grep -oE "'\\^\[a-zA-Z0-9\]\[a-zA-Z0-9\._\-\]\{0,127\}\\\$'" "$SETUP_WRITER" | head -1)
if [ -z "$FILTER_PATTERN" ] || [ -z "$WRITER_PATTERN" ] || [ "$FILTER_PATTERN" != "$WRITER_PATTERN" ]; then
    echo "  FAIL: basename pattern mismatch (filter='$FILTER_PATTERN' writer='$WRITER_PATTERN')"
    FAIL=1
fi

# 7. Wrapper byte-identity drift (gotcha #2). The wrapper at
# /usr/local/bin/claude-write must be a thin sudo forwarder, with the quoted
# "$@" preserved. Unquoting it would let argv re-split on the constrained
# user's IFS or shell-glob against the cwd. The body is fixed across releases.
EXPECTED_EXEC_LINE='exec sudo -n /usr/local/sbin/claude-write-priv "$@"'
if ! grep -qF "$EXPECTED_EXEC_LINE" "$SETUP_WRITER"; then
    echo "  FAIL: wrapper missing or modified — expected literal: $EXPECTED_EXEC_LINE"
    FAIL=1
fi
# Defensive: an unquoted $@ would also be a regression. Match the bare token
# followed by EOL/whitespace/closing paren and assert it's absent.
if grep -qE 'claude-write-priv [^"]*\$@[^"]*$' "$SETUP_WRITER"; then
    echo "  FAIL: wrapper appears to use unquoted \$@ — must be \"\$@\" to preserve argv"
    FAIL=1
fi

# 8. Privileged binary path drift (gotcha #3). Earlier versions installed the
# priv writer at /usr/local/sbin/claude-write (same name as the wrapper).
# Slackware's PATH puts sbin before bin, so the user's `claude-write`
# resolved to the priv path directly — bypassing sudo. v6.2 renamed it to
# claude-write-priv; this check pins the rename in place and asserts the
# legacy-path cleanup stays.
if ! grep -qE '^PRIV_PATH=/usr/local/sbin/claude-write-priv$' "$SETUP_WRITER"; then
    echo "  FAIL: PRIV_PATH must be /usr/local/sbin/claude-write-priv (PATH-shadowing fix)"
    FAIL=1
fi
if ! grep -qE '^OLD_PRIV_PATH=/usr/local/sbin/claude-write([[:space:]]|$)' "$SETUP_WRITER"; then
    echo "  FAIL: OLD_PRIV_PATH cleanup must remain (legacy v6.2 fix)"
    FAIL=1
fi
if ! grep -qF 'rm -f "$OLD_PRIV_PATH"' "$SETUP_WRITER"; then
    echo "  FAIL: legacy claude-write-priv cleanup `rm -f \$OLD_PRIV_PATH` missing"
    FAIL=1
fi

# 9. Sudoers must NOT set env_keep on the claude-write rule (gotcha #4).
# sudo's env_reset already strips CLAUDE_SSH_ALLOWLIST_FILE, LD_*, IFS, etc.,
# before invoking the writer; the writer's `unset` line is belt-and-braces on
# top. Adding env_keep would weaken that.
SUDOERS_BLOCK=$(awk '
    /^cat > "\$TMP_SUDO" << SUDO$/ { in_sudo=1; next }
    in_sudo && /^SUDO$/ { in_sudo=0; exit }
    in_sudo { print }
' "$SETUP_WRITER")
if echo "$SUDOERS_BLOCK" | grep -qiE 'env_keep'; then
    echo "  FAIL: sudoers block must not contain env_keep — env_reset is doing real defence"
    FAIL=1
fi

# 10. Sudoers must enumerate all three plugin-file rel-path arities (gotcha #1)
# and must NOT enumerate a 4-slash form. sudo's `*` does not match `/`, so a
# single `plugin-file * *` would silently reject subdir writes. The writer
# also caps slash_count at 2 so a 4-slash pattern would be unreachable —
# we want the absence-check to surface any well-intentioned future-proofing.
for shape in 'plugin-file \* \*' 'plugin-file \* \*/\*' 'plugin-file \* \*/\*/\*'; do
    if ! echo "$SUDOERS_BLOCK" | grep -qE "claude-write-priv $shape([,]| |$)"; then
        echo "  FAIL: sudoers missing plugin-file rel-path arity: $shape"
        FAIL=1
    fi
done
if echo "$SUDOERS_BLOCK" | grep -qE 'plugin-file \* \*/\*/\*/\*'; then
    echo "  FAIL: sudoers has unexpected 4-slash plugin-file pattern (depth cap is 3)"
    FAIL=1
fi

# ----------------------------------------------------------------------------
# Behavioural writer tests — extract the PRIV heredoc and run it with sandbox-
# rooted target paths so the writer can be exercised without root or NAS.
# ----------------------------------------------------------------------------
SANDBOX=$(mktemp -d -t claude-write-priv-XXXXXX)
PRIV_TMP="$SANDBOX/claude-write-priv"
trap 'rm -rf "$SANDBOX"' EXIT

awk '
    /^cat > "\$PRIV_PATH" << '\''PRIV'\''$/ { capturing=1; next }
    capturing && /^PRIV$/ { capturing=0; exit }
    capturing { print }
' "$SETUP_WRITER" > "$PRIV_TMP"

# Re-root target paths into the sandbox so the writer's mkdir/cp/mv actually
# succeed against tmpdir-owned files instead of failing on /mnt/user/... or
# /usr/local/emhttp/...  Also point BACKUP_DIR at the sandbox so backup
# rotation can be observed in tests.
#
# Patch PATH: the production writer hardens PATH to /usr/sbin:/usr/bin:/sbin:
# /bin, which excludes Homebrew's `timeout` (from coreutils) on macOS test
# hosts. We splice the host PATH back in so the test can find timeout. On a
# Slackware/Unraid runtime the hardened PATH already contains everything the
# writer needs — this patch is sandbox-only.
sed -i.bak \
    -e "s|^BACKUP_DIR=/mnt/cache/appdata/claude-write-backups|BACKUP_DIR=$SANDBOX/backups|" \
    -e "s|TARGET_DIR=/mnt/user/appdata/\$PLUGIN_NAME/scripts|TARGET_DIR=$SANDBOX/appdata/\$PLUGIN_NAME/scripts|" \
    -e "s|TARGET_DIR=/usr/local/emhttp/plugins/\$PLUGIN_NAME/\$SUBDIR_PATH|TARGET_DIR=$SANDBOX/emhttp/plugins/\$PLUGIN_NAME/\$SUBDIR_PATH|" \
    -e "s|TARGET_DIR=/usr/local/emhttp/plugins/\$PLUGIN_NAME|TARGET_DIR=$SANDBOX/emhttp/plugins/\$PLUGIN_NAME|" \
    -e "s|TARGET_DIR=/tmp/claude-scratch|TARGET_DIR=$SANDBOX/scratch|" \
    -e 's|^if ! timeout "\$STDIN_TIMEOUT" head -c|if ! head -c|' \
    "$PRIV_TMP"

# BSD/macOS: GNU `stat -c %s` becomes `stat -f %z`. Unraid (Slackware) has GNU
# coreutils so we only patch when we're running on a BSD-stat host.
if ! echo "" > "$SANDBOX/_st" && stat -c %s "$SANDBOX/_st" >/dev/null 2>&1; then
    : # shouldn't reach
fi
if stat -c %s "$SANDBOX/_st" >/dev/null 2>&1; then
    : # GNU stat — no patch needed
else
    sed -i.bak -e 's|stat -c %s|stat -f %z|g' "$PRIV_TMP"
fi
rm -f "$PRIV_TMP.bak" "$SANDBOX/_st"
chmod +x "$PRIV_TMP"

# Seed allowlist for the behavioural cases — `verify-test` for both kinds.
cat > "$SANDBOX/allowlist.cfg" << 'ALLOW'
plugin verify-test
plugin torrent-handler
plugin claude-ssh
container sonarr
ALLOW
export CLAUDE_SSH_ALLOWLIST_FILE="$SANDBOX/allowlist.cfg"

BPASS=0
BFAIL=0
BFAILED=()

# Run the writer with the given argv. Expected:
#   accept|MODE|DEST   — writer writes successfully and DEST is created at MODE.
#   reject             — writer exits non-zero (REJECTED).
b_case() {
    local label="$1" expected="$2" content="$3"
    shift 3
    local out rc
    out=$(printf '%s' "$content" | bash "$PRIV_TMP" "$@" 2>&1)
    rc=$?

    case "$expected" in
        reject)
            if [ "$rc" -ne 0 ]; then
                BPASS=$((BPASS + 1))
            else
                BFAIL=$((BFAIL + 1))
                BFAILED+=("$label: expected reject, got accept (argv: $*; out: $out)")
            fi
            ;;
        accept:*)
            local want_mode="${expected#accept:}"
            local want_path="${want_mode#*:}"
            want_mode="${want_mode%%:*}"
            if [ "$rc" -ne 0 ]; then
                BFAIL=$((BFAIL + 1))
                BFAILED+=("$label: expected accept, got reject (argv: $*; out: $out)")
            elif [ ! -f "$want_path" ]; then
                BFAIL=$((BFAIL + 1))
                BFAILED+=("$label: expected file at $want_path; not created (out: $out)")
            else
                local got_mode
                got_mode=$(stat -c '%a' "$want_path" 2>/dev/null || stat -f '%Lp' "$want_path" 2>/dev/null)
                if [ "$got_mode" != "$want_mode" ]; then
                    BFAIL=$((BFAIL + 1))
                    BFAILED+=("$label: expected mode $want_mode, got $got_mode (path: $want_path)")
                else
                    BPASS=$((BPASS + 1))
                fi
            fi
            ;;
    esac
}

# --- Accept: every plugin-file extension at top level (mode 644) ---
b_case "pf-page-top"        "accept:644:$SANDBOX/emhttp/plugins/verify-test/Foo.page"  "page-body"  plugin-file verify-test Foo.page
b_case "pf-php-top"         "accept:644:$SANDBOX/emhttp/plugins/verify-test/foo.php"   "<?php"      plugin-file verify-test foo.php
b_case "pf-cfg-top"         "accept:644:$SANDBOX/emhttp/plugins/verify-test/default.cfg" "k=v"      plugin-file verify-test default.cfg
b_case "pf-txt-top"         "accept:644:$SANDBOX/emhttp/plugins/verify-test/note.txt"  "hello"      plugin-file verify-test note.txt
b_case "pf-json-top"        "accept:644:$SANDBOX/emhttp/plugins/verify-test/data.json" "{}"         plugin-file verify-test data.json
b_case "pf-sh-top"          "accept:755:$SANDBOX/emhttp/plugins/verify-test/run.sh"    "#!/bin/sh"  plugin-file verify-test run.sh
b_case "pf-py-top"          "accept:755:$SANDBOX/emhttp/plugins/verify-test/run.py"    "print(1)"   plugin-file verify-test run.py

# --- Accept: 2-component rel-paths covering the common subdir conventions ---
b_case "pf-include-php"     "accept:644:$SANDBOX/emhttp/plugins/verify-test/include/exec.php"  "<?php" plugin-file verify-test include/exec.php
b_case "pf-scripts-sh"      "accept:755:$SANDBOX/emhttp/plugins/verify-test/scripts/install.sh" "#!/bin/sh" plugin-file verify-test scripts/install.sh
b_case "pf-scripts-py"      "accept:755:$SANDBOX/emhttp/plugins/verify-test/scripts/run.py"   "print" plugin-file verify-test scripts/run.py
b_case "pf-js-js"           "accept:644:$SANDBOX/emhttp/plugins/verify-test/javascript/app.js" "//js" plugin-file verify-test javascript/app.js
b_case "pf-sheets-css"      "accept:644:$SANDBOX/emhttp/plugins/verify-test/sheets/style.css" "/*c*/" plugin-file verify-test sheets/style.css
b_case "pf-images-svg"      "accept:644:$SANDBOX/emhttp/plugins/verify-test/images/icon.svg" "<svg/>" plugin-file verify-test images/icon.svg
b_case "pf-html"            "accept:644:$SANDBOX/emhttp/plugins/verify-test/templates/page.html" "<html/>" plugin-file verify-test templates/page.html

# --- Accept: 3-component rel-paths (vendored python package) ---
b_case "pf-pkg-relink"      "accept:755:$SANDBOX/emhttp/plugins/torrent-handler/scripts/torrent_handler/relink.py" "print" plugin-file torrent-handler scripts/torrent_handler/relink.py
b_case "pf-js-lib"          "accept:644:$SANDBOX/emhttp/plugins/torrent-handler/javascript/lib/foo.js" "//x" plugin-file torrent-handler javascript/lib/foo.js
# Tiny-content __init__.py (writer rejects truly-empty stdin so we pass a
# single comment byte to exercise the depth-3 path with a near-empty file).
b_case "pf-pkg-init"        "accept:755:$SANDBOX/emhttp/plugins/torrent-handler/scripts/torrent_handler/__init__.py" "#" plugin-file torrent-handler scripts/torrent_handler/__init__.py

# --- Accept: event/<hook> extensionless exception (mode 755) ---
b_case "pf-event-started"   "accept:755:$SANDBOX/emhttp/plugins/claude-ssh/event/started"          "#!/bin/bash" plugin-file claude-ssh event/started
b_case "pf-event-stopping"  "accept:755:$SANDBOX/emhttp/plugins/claude-ssh/event/stopping_svcs"   "#!/bin/bash" plugin-file claude-ssh event/stopping_svcs

# --- Reject: old plugin-* category names removed ---
b_case "pf-old-page"        "reject" "x" plugin-page    verify-test Foo.page
b_case "pf-old-include"     "reject" "x" plugin-include verify-test exec.php
b_case "pf-old-script"      "reject" "x" plugin-script  verify-test foo.sh
b_case "pf-old-cfg"         "reject" "x" plugin-cfg     verify-test default.cfg

# --- Reject: depth + traversal + bad-extension shapes ---
b_case "pf-too-many"        "reject" "x" plugin-file verify-test a/b/c/d.py
b_case "pf-parent"          "reject" "x" plugin-file verify-test ../escape.sh
b_case "pf-mid-parent"      "reject" "x" plugin-file verify-test scripts/../escape.sh
b_case "pf-abs"             "reject" "x" plugin-file verify-test /etc/passwd
b_case "pf-trailing"        "reject" "x" plugin-file verify-test scripts/
b_case "pf-empty-mid"       "reject" "x" plugin-file verify-test scripts//foo.py
b_case "pf-leading-dot"     "reject" "x" plugin-file verify-test .hidden.sh
b_case "pf-leading-dot-sub" "reject" "x" plugin-file verify-test scripts/.hidden.sh
b_case "pf-bad-ext"         "reject" "x" plugin-file verify-test program.exe
b_case "pf-extless-top"     "reject" "x" plugin-file verify-test started      # extensionless outside event/
b_case "pf-extless-other"   "reject" "x" plugin-file verify-test notevent/started
b_case "pf-event-upper"     "reject" "x" plugin-file verify-test event/Started
b_case "pf-event-nested"    "reject" "x" plugin-file verify-test event/sub/hook
b_case "pf-bad-plugin"      "reject" "x" plugin-file not-allowlisted Foo.page

# --- Reject: scratch / appdata-script keep their flat-basename rules ---
b_case "scratch-leading-dot" "reject" "x" scratch .hidden.txt
b_case "appdata-traversal"   "reject" "x" appdata-script sonarr ../foo.sh

# --- Accept: scratch + appdata-script behaviour unchanged ---
b_case "scratch-txt"         "accept:644:$SANDBOX/scratch/foo.txt"          "hello" scratch foo.txt
b_case "scratch-sh"          "accept:755:$SANDBOX/scratch/run.sh"           "#!/bin/sh" scratch run.sh
b_case "scratch-yaml"        "accept:644:$SANDBOX/scratch/conf.yaml"        "a: 1" scratch conf.yaml
b_case "appdata-sh"          "accept:755:$SANDBOX/appdata/sonarr/scripts/foo.sh" "#!/bin/sh" appdata-script sonarr foo.sh

echo "  behavioural cases: $BPASS passed / $BFAIL failed"
if [ "$BFAIL" -ne 0 ]; then
    for f in "${BFAILED[@]}"; do echo "  - $f"; done
    exit 1
fi

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
echo "PASS: claude-write surface consistent across filter, writer, sudoers"
