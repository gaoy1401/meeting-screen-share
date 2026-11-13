#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
cd "$ROOT_DIR/server"
exec node src/index.js

