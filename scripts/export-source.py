#!/usr/bin/env python3
"""Audit and export only public source files, never local configuration or builds."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FILES = ["README.md", "README.zh-CN.md", "LICENSE", "THIRD_PARTY_NOTICES.md",
         "SECURITY.md", "CONTRIBUTING.md", "CHANGELOG.md", ".gitignore", ".gitattributes"]
DIRECTORIES = [".github", "client", "deploy", "docs", "linux-client", "mac-server",
               "patches", "scripts", "server", "third-party", "windows-client"]
SKIP_DIRS = {".git", ".build", ".runtime", "node_modules", "dist", "build", "build-cache",
             "__pycache__", ".venv", "coverage", ".idea", ".vscode"}
SKIP_SUFFIXES = {".pyc", ".pyo", ".log", ".pem", ".key", ".p12", ".pfx", ".zip", ".dmg", ".exe"}
PATTERNS = [
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(rb"gh[pousr]_[A-Za-z0-9]{30,}"),
    re.compile(rb"github_pat_[A-Za-z0-9_]{50,}"),
    re.compile(rb"AKIA[A-Z0-9]{16}"),
    re.compile(rb"/Users/[A-Za-z0-9_.-]+/"),
    re.compile(("172." + "233." + "145." + "242").encode().replace(b".", rb"\.")),
    re.compile(("192." + "168." + "2." + "113").encode().replace(b".", rb"\.")),
]


def source_files():
    paths = [ROOT / name for name in FILES]
    for directory in DIRECTORIES:
        for current, dirs, names in os.walk(ROOT / directory, followlinks=False):
            dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
            for name in sorted(names):
                p = Path(current) / name
                if name == ".DS_Store" or name == "credentials.env" or p.suffix in SKIP_SUFFIXES:
                    continue
                if name.startswith(".env") and name != ".env.example":
                    continue
                if name.endswith(".local.env"):
                    continue
                paths.append(p)
    return sorted(paths)


def audit(paths):
    errors = []
    for p in paths:
        rel = p.relative_to(ROOT)
        if not p.is_file() or p.is_symlink():
            errors.append(f"Missing source or unsupported symlink: {rel}")
            continue
        data = p.read_bytes()
        if len(data) > 2 * 1024 * 1024 or b"\x00" in data:
            errors.append(f"Unexpected binary/large file: {rel}")
        if any(pattern.search(data) for pattern in PATTERNS):
            errors.append(f"Potential credential/private endpoint/local path: {rel}")
    if errors:
        raise SystemExit("\n".join(errors))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--directory", type=Path, help="Export to a new empty directory")
    args = parser.parse_args()
    paths = source_files()
    audit(paths)
    print(f"Source audit passed: {len(paths)} text files (pattern scan, not a security proof).")
    if args.check:
        return
    if args.directory:
        dest = args.directory.resolve()
        if dest.exists() and any(dest.iterdir()):
            raise SystemExit("Destination must be empty; existing files will not be overwritten.")
        for p in paths:
            out = dest / p.relative_to(ROOT)
            out.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(p, out)
        print(f"Exported source to {dest}")
        return
    version = json.loads((ROOT / "server/package.json").read_text())["version"]
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:[-.][A-Za-z0-9.-]+)?", version):
        raise SystemExit("Invalid package version")
    name = f"meeting-screen-share-{version}-source"
    output = ROOT / "dist/releases"
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"{name}.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for p in paths:
            z.write(p, f"{name}/{p.relative_to(ROOT).as_posix()}")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix(".zip.sha256").write_text(f"{digest}  {archive.name}\n")
    print(f"Created {archive}")


if __name__ == "__main__":
    main()
