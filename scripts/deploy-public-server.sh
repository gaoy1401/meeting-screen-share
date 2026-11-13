#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PUBLIC_IP=${MEETING_PUBLIC_IP:?Set MEETING_PUBLIC_IP to your own server IPv4 address}
SSH_TARGET=${MEETING_SSH_TARGET:-root@$PUBLIC_IP}
REMOTE_STAGE=${MEETING_REMOTE_STAGE:-/tmp/meeting-public-deploy}

# Values below enter a remote shell command. Accept only simple addresses and
# paths; no shell metacharacters or arbitrary command fragments.
[[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
[[ "$SSH_TARGET" =~ ^[a-zA-Z0-9_.@-]+$ ]] || exit 2
[[ "$REMOTE_STAGE" =~ ^/tmp/[a-zA-Z0-9_-]+$ ]] || exit 2

ssh_options=(
    -o BatchMode=yes
    -o StrictHostKeyChecking=yes
    -o ConnectTimeout=8
)
if [[ -n "${MEETING_SSH_KEY:-}" ]]; then
    [[ "$MEETING_SSH_KEY" != *"'"* ]] || exit 2
    ssh_options+=(-i "$MEETING_SSH_KEY")
fi
rsync_ssh="ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8"
if [[ -n "${MEETING_SSH_KEY:-}" ]]; then
    rsync_ssh+=" -i '$MEETING_SSH_KEY'"
fi

ssh "${ssh_options[@]}" "$SSH_TARGET" \
    "install -d -m 0700 '$REMOTE_STAGE/server' '$REMOTE_STAGE/public'"

rsync -az --delete \
    -e "$rsync_ssh" \
    --exclude node_modules \
    "$ROOT/server/" "$SSH_TARGET:$REMOTE_STAGE/server/"

rsync -az --delete \
    -e "$rsync_ssh" \
    "$ROOT/deploy/public/" "$SSH_TARGET:$REMOTE_STAGE/public/"

ssh "${ssh_options[@]}" "$SSH_TARGET" \
    "PUBLIC_IP='$PUBLIC_IP' STAGE_DIR='$REMOTE_STAGE' bash '$REMOTE_STAGE/public/install-public-server.sh'"
