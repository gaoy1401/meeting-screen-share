#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h:h}
source "$ROOT_DIR/mac-server/lib/common.sh"

require_macos
require_command brew

if ! command -v livekit-server >/dev/null 2>&1; then
  print -- "正在通过 Homebrew 安装 LiveKit Server..."
  brew install livekit
else
  print -- "LiveKit Server 已安装：$(command -v livekit-server)"
fi

if ! command -v node >/dev/null 2>&1; then
  print -- "正在通过 Homebrew 安装 Node.js..."
  brew install node
fi

local_node_major="$(node -p 'Number(process.versions.node.split(".")[0])')"
if (( local_node_major < 22 )); then
  die "Node.js 版本必须不低于 22，当前为 $(node --version)。"
fi

print -- "正在安装控制服务器依赖..."
(
  cd "$ROOT_DIR/server"
  npm ci
)

print -- ""
print -- "Mac 服务器依赖安装完成。"
print -- "启动命令：$ROOT_DIR/mac-server/bin/start.sh"
