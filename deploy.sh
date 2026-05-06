#!/bin/bash
# Deploy the claude-ssh plugin to the NAS.
#
# Usage:
#   bash plugin-claude-ssh/deploy.sh          # quick: claude-write the plugin assets
#   bash plugin-claude-ssh/deploy.sh --full   # full:  build .txz, install via plugin manager
#
# Quick mode goes through the existing claude-write channel (filter v7+) and
# only updates the page/include/cfg files — no install hook runs, so changes
# to install-runtime.sh / setup scripts are NOT picked up. Good for iterating
# on the UI.
#
# Full mode rebuilds the .txz and runs `plugin install` as root, which:
#   - extracts the package (overwriting any older version)
#   - runs the .plg install hook (re-runs install-runtime.sh)
#   - registers the plugin in /var/log/plugins/
# Use --full when: install-runtime.sh changed, setup scripts changed,
#   .plg changed, or any structural change that needs the install hook.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ "${1:-}" = "--full" ]; then
    echo "==> Building .txz package..."
    make -C "$REPO_ROOT/plugin-claude-ssh"

    echo "==> Uploading .txz and .plg to NAS via root SSH..."
    NAS="root@192.168.0.3"
    PLG="/boot/config/plugins/claude-ssh/claude-ssh.plg"
    SSH_OPTS="-o ControlMaster=auto -o ControlPath=/tmp/ssh-deploy-%r@%h -o ControlPersist=30s"

    # Note: root SSH from this Mac sometimes fails (key-agent issues). If scp
    # fails, fall through to a copy-paste path the user can run interactively.
    if ! ssh $SSH_OPTS "$NAS" "mkdir -p /boot/config/plugins/claude-ssh"; then
        cat <<'EOF' >&2

ERROR: root SSH to NAS failed. Run this manually from a console with key access:

  scp plugin-claude-ssh/claude-ssh.txz root@192.168.0.3:/boot/config/plugins/claude-ssh/
  scp plugin-claude-ssh/claude-ssh.plg root@192.168.0.3:/boot/config/plugins/claude-ssh/
  ssh root@192.168.0.3 'plugin install /boot/config/plugins/claude-ssh/claude-ssh.plg forced'
EOF
        exit 1
    fi
    scp $SSH_OPTS "$REPO_ROOT/plugin-claude-ssh/claude-ssh.txz" "$NAS:/boot/config/plugins/claude-ssh/"
    scp $SSH_OPTS "$REPO_ROOT/plugin-claude-ssh/claude-ssh.plg" "$NAS:$PLG"

    echo "==> Running plugin install..."
    ssh $SSH_OPTS "$NAS" "plugin install $PLG forced"
else
    echo "==> Quick deploy via claude-write..."
    bash "$REPO_ROOT/scripts/deploy-via-claude-write.sh" claude-ssh-quick
fi

echo "==> Done"
