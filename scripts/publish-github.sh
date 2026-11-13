#!/usr/bin/env bash
# Run from an ordinary terminal with GitHub CLI access after reviewing the source.
# This publishes source only; binary releases are a separate, reviewed step.
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
REPO=${1:?Usage: ./scripts/publish-github.sh OWNER/NEW_REPOSITORY}
[[ "$REPO" =~ ^[a-zA-Z0-9_-]+/[a-zA-Z0-9_.-]+$ ]] || { echo "Invalid OWNER/REPOSITORY" >&2; exit 2; }
command -v gh >/dev/null
command -v git >/dev/null
gh auth status
python3 "$ROOT/scripts/export-source.py" --check
if gh repo view "$REPO" >/dev/null 2>&1; then
    echo "Repository already exists; no existing repository will be overwritten: $REPO" >&2
    exit 1
fi
if [[ -e "$ROOT/.git" ]]; then
    echo "A Git checkout already exists. Use its normal review/push workflow." >&2
    exit 1
fi
# Initialize the actual project so future work uses the same Git repository.
# Stage only the allowlisted source paths; never use a broad 'git add .'.
git -C "$ROOT" init -b main
python3 - "$ROOT" <<'PY'
import importlib.util
from pathlib import Path
import subprocess
import sys
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("export_source", root / "scripts/export-source.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
paths = module.source_files()
module.audit(paths)
subprocess.run(["git", "-C", str(root), "add", "--"] +
               [str(p.relative_to(root)) for p in paths], check=True)
PY
git -C "$ROOT" diff --cached --stat
git -C "$ROOT" commit -m "Initial open-source preview"
gh repo create "$REPO" --public --source "$ROOT" --remote origin \
    --description "Native screen sharing and voice rooms for macOS, Windows and Linux using LiveKit/WebRTC" \
    --push
echo "Published https://github.com/$REPO"
echo "Check Actions → CI, then follow docs/RELEASING.md before publishing binaries."
