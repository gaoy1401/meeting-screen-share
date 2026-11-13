#!/usr/bin/env python3
"""Collect actual dependency license/notice texts into a binary distribution."""
import argparse
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]


def collect(source, destination):
    count = 0
    for p in source.rglob("*"):
        if not p.is_file() or p.is_symlink() or ".git" in p.parts:
            continue
        name = p.name.lower()
        if name.startswith(("license", "licence", "copying", "notice")):
            out = destination / p.relative_to(source)
            out.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(p, out)
            count += 1
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=["macos", "windows"], required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sdk", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    for name in ["LICENSE", "THIRD_PARTY_NOTICES.md"]:
        shutil.copy2(ROOT / name, args.output / name)
    if args.platform == "macos":
        source = ROOT / "client/.build/checkouts"
        for dependency in ["client-sdk-swift", "swift-protobuf", "webrtc-xcframework", "livekit-uniffi-xcframework"]:
            if collect(source / dependency, args.output / dependency) == 0:
                if dependency == "livekit-uniffi-xcframework":
                    shutil.copytree(ROOT / "third-party/livekit-uniffi", args.output / dependency,
                                    dirs_exist_ok=True)
                else:
                    raise SystemExit(f"Missing license texts for {dependency}; stop packaging.")
        collect(ROOT / "client/.build/artifacts", args.output / "artifacts")
    else:
        if not args.sdk or collect(args.sdk, args.output / "livekit-sdk") == 0:
            raise SystemExit("Pass --sdk with an extracted SDK containing its license texts.")
    print(f"Collected license notices in {args.output}")


if __name__ == "__main__":
    main()
