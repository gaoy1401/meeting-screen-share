#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"
VENV_PYTHON="$SCRIPT_DIR/../.venv/bin/python"
if [ -x "$VENV_PYTHON" ]; then
    exec "$VENV_PYTHON" -m meeting_linux
fi
exec python3 -m meeting_linux
