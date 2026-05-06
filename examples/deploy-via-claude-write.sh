#!/bin/bash
# Sample client for the claude-write deploy channel.
#
# Demonstrates the four common categories: scratch (ephemeral), plugin-page
# (Unraid plugin asset), plugin-script (plugin's scripts dir), and
# appdata-script (container hook). Adjust the NAS / KEY / paths to your
# environment before running.
#
# Each call prints either:
#   claude-write: OK ...        on success (with sha256 + dest)
#   claude-write: REJECTED — ... on failure (reason on stderr)
#
# Exit code 0 = success, non-zero = at least one write failed.

set -euo pipefail

NAS="${NAS:-nas.local}"
USER="${USER:-claude}"
KEY="${KEY:-$HOME/.ssh/claude_unraid}"

deploy() {
    local label="$1"; shift
    echo "→ $label"
    if ssh -i "$KEY" "$USER@$NAS" "$@"; then
        echo "  ok"
    else
        echo "  FAILED ($?)" >&2
        return 1
    fi
}

# 1. scratch — ephemeral, no allowlist required.
echo "scratch demo content" \
    | deploy "scratch / hello.txt" 'claude-write scratch hello.txt'

# 2. plugin-page — requires `plugin <name>` allowlist entry.
cat <<'PAGE' \
    | deploy "plugin-page / my-plugin / Demo.page" \
        'claude-write plugin-page my-plugin Demo.page'
Title="Demo"
Type="xmenu:Tools"
Icon="info-circle"
---
<div>Hello from claude-write.</div>
PAGE

# 3. plugin-script — requires `plugin <name>` allowlist entry.
cat <<'SH' \
    | deploy "plugin-script / my-plugin / hourly.sh" \
        'claude-write plugin-script my-plugin hourly.sh'
#!/bin/bash
echo "deployed via claude-write at $(date -Is)"
SH

# 4. appdata-script — requires `container <name>` allowlist entry.
cat <<'SH' \
    | deploy "appdata-script / sonarr / post-import.sh" \
        'claude-write appdata-script sonarr post-import.sh'
#!/bin/bash
# Sonarr fires this with sonarr_eventtype + the imported file in env.
[ "$sonarr_eventtype" = "Download" ] || exit 0
logger -t sonarr-hook "imported: $sonarr_episodefile_path"
SH

echo
echo "All deploys succeeded."
