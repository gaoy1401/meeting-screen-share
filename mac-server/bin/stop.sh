#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h:h}
source "$ROOT_DIR/mac-server/lib/common.sh"

stop_service() {
  local label="$1"
  local service_label="$2"
  if launchd_service_is_loaded "$service_label"; then
    print -- "正在停止 $label..."
    launchctl bootout "$LAUNCHD_DOMAIN/$service_label"
  else
    print -- "$label 未运行。"
  fi
}

require_macos
require_command launchctl
stop_service "控制服务" "$CONTROL_LABEL"
stop_service "LiveKit SFU" "$LIVEKIT_LABEL"
print -- "Mac 会议服务器已停止。"
