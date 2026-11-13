#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h:h}
source "$ROOT_DIR/mac-server/lib/common.sh"

require_macos
require_command node

if [[ -f "$STATE_FILE" ]]; then
  set -a
  source "$STATE_FILE"
  set +a
fi

host="${MEETING_MAC_SERVER_IP:-127.0.0.1}"
node "$ROOT_DIR/server/tools/check-webrtc-server.js" "$host" 9000

print -- ""
"$ROOT_DIR/mac-server/bin/status.sh"
