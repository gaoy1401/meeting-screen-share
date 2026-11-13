#!/bin/zsh

: "${ROOT_DIR:?ROOT_DIR must be set before loading common.sh}"

RUNTIME_DIR="${MEETING_MAC_RUNTIME_DIR:-$ROOT_DIR/.runtime/mac-server}"
LOG_DIR="$RUNTIME_DIR/logs"
LIVEKIT_CONFIG="$RUNTIME_DIR/livekit.yaml"
CREDENTIALS_FILE="$RUNTIME_DIR/credentials.env"
STATE_FILE="$RUNTIME_DIR/server.env"
LIVEKIT_LOG="$LOG_DIR/livekit.log"
LIVEKIT_ERROR_LOG="$LOG_DIR/livekit-error.log"
CONTROL_LOG="$LOG_DIR/control.log"
CONTROL_ERROR_LOG="$LOG_DIR/control-error.log"
LIVEKIT_PLIST="$RUNTIME_DIR/com.meeting.mac.livekit.plist"
CONTROL_PLIST="$RUNTIME_DIR/com.meeting.mac.control.plist"
LIVEKIT_LABEL="com.meeting.mac.livekit"
CONTROL_LABEL="com.meeting.mac.control"
LAUNCHD_DOMAIN="gui/$(id -u)"

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

die() {
  print -u2 -- "错误：$*"
  exit 1
}

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "Mac 服务器脚本只能在 macOS 上运行。"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

ensure_runtime_dirs() {
  mkdir -p "$LOG_DIR"
  chmod 700 "$RUNTIME_DIR"
}

detect_lan_ip() {
  if [[ -n "${MEETING_MAC_SERVER_IP:-}" ]]; then
    print -- "$MEETING_MAC_SERVER_IP"
    return
  fi

  local interface=""
  local address=""
  interface="$(/sbin/route -n get default 2>/dev/null |
    awk '/interface:/{print $2; exit}')" || true
  if [[ -n "$interface" ]]; then
    address="$(/usr/sbin/ipconfig getifaddr "$interface" 2>/dev/null)" || true
  fi

  if [[ -z "$address" ]]; then
    local candidate
    for candidate in en0 en1 en2 en3; do
      address="$(/usr/sbin/ipconfig getifaddr "$candidate" 2>/dev/null)" || true
      [[ -n "$address" ]] && break
    done
  fi

  if [[ -z "$address" ]]; then
    address="$(/sbin/ifconfig |
      awk '
        $1 == "inet" &&
        $2 !~ /^127\./ &&
        ($2 ~ /^10\./ ||
         $2 ~ /^192\.168\./ ||
         $2 ~ /^172\.(1[6-9]|2[0-9]|3[01])\./) {
          print $2
          exit
        }
      ')" || true
  fi

  [[ -n "$address" ]] ||
    die "无法识别局域网 IPv4 地址。可设置 MEETING_MAC_SERVER_IP 后重试。"
  print -- "$address"
}

ensure_credentials() {
  if [[ ! -f "$CREDENTIALS_FILE" ]]; then
    require_command openssl
    local api_key="meeting$(openssl rand -hex 6)"
    local api_secret="$(openssl rand -hex 32)"
    {
      print -- "MEETING_LIVEKIT_API_KEY=$api_key"
      print -- "MEETING_LIVEKIT_API_SECRET=$api_secret"
    } >"$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"
  fi
}

load_credentials() {
  ensure_credentials
  set -a
  source "$CREDENTIALS_FILE"
  set +a
  [[ -n "${MEETING_LIVEKIT_API_KEY:-}" ]] ||
    die "credentials.env 缺少 MEETING_LIVEKIT_API_KEY。"
  [[ -n "${MEETING_LIVEKIT_API_SECRET:-}" ]] ||
    die "credentials.env 缺少 MEETING_LIVEKIT_API_SECRET。"
}

wait_for_tcp() {
  local host="$1"
  local port="$2"
  local attempts="${3:-50}"
  local index=1
  while (( index <= attempts )); do
    if /usr/bin/nc -z "$host" "$port" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
    (( index += 1 ))
  done
  return 1
}

port_is_listening() {
  local protocol="$1"
  local port="$2"
  /usr/sbin/lsof -nP "-i${protocol}:$port" 2>/dev/null |
    grep -q LISTEN
}

show_log_tail() {
  local label="$1"
  local path="$2"
  if [[ -f "$path" ]]; then
    print -- ""
    print -- "---- $label 日志 ----"
    tail -n 30 "$path"
  fi
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  print -r -- "$value"
}

launchd_service_is_loaded() {
  launchctl print "$LAUNCHD_DOMAIN/$1" >/dev/null 2>&1
}

launchd_service_state() {
  launchctl print "$LAUNCHD_DOMAIN/$1" 2>/dev/null |
    awk -F' = ' '/^[[:space:]]*state = / { print $2; exit }' || true
}

launchd_service_pid() {
  launchctl print "$LAUNCHD_DOMAIN/$1" 2>/dev/null |
    awk -F' = ' '/^[[:space:]]*pid = / { print $2; exit }' || true
}
