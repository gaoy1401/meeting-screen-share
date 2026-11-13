#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h:h}
source "$ROOT_DIR/mac-server/lib/common.sh"

require_macos
ensure_runtime_dirs

if [[ -f "$STATE_FILE" ]]; then
  set -a
  source "$STATE_FILE"
  set +a
fi

livekit_state="$(launchd_service_state "$LIVEKIT_LABEL")"
control_state="$(launchd_service_state "$CONTROL_LABEL")"
if [[ "$livekit_state" == "running" ]]; then
  livekit_ok=1
  print -- "LiveKit SFU：运行中（PID $(launchd_service_pid "$LIVEKIT_LABEL")）"
else
  livekit_ok=0
  print -- "LiveKit SFU：${livekit_state:-未运行}"
fi
if [[ "$control_state" == "running" ]]; then
  control_ok=1
  print -- "控制服务：运行中（PID $(launchd_service_pid "$CONTROL_LABEL")）"
else
  control_ok=0
  print -- "控制服务：${control_state:-未运行}"
fi

print -- ""
if [[ -n "${MEETING_CONTROL_ENDPOINT:-}" ]]; then
  print -- "客户端服务器地址：$MEETING_CONTROL_ENDPOINT"
fi
print -- "端口监听："
for endpoint in TCP:7880 TCP:7881 TCP:9000 UDP:7882 UDP:9000; do
  protocol="${endpoint%%:*}"
  port="${endpoint##*:}"
  if /usr/sbin/lsof -nP "-i${protocol}:$port" 2>/dev/null |
     grep -q .; then
    print -- "  $port/$protocol  已监听"
  else
    print -- "  $port/$protocol  未监听"
  fi
done

if (( livekit_ok == 1 && control_ok == 1 )); then
  exit 0
fi
exit 1
