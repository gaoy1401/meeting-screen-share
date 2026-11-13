#!/usr/bin/env python3
"""Generate matching LiveKit/control settings for a trusted local network."""
import argparse
import ipaddress
import os
from pathlib import Path
import secrets


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ip", default="127.0.0.1", help="Server IPv4 reachable by clients")
    parser.add_argument("--output", type=Path,
                        default=Path(__file__).resolve().parents[1] / ".runtime/server")
    args = parser.parse_args()
    ip = ipaddress.IPv4Address(args.ip)
    if ip.is_unspecified or ip.is_multicast:
        parser.error("--ip must be a concrete unicast address, not 0.0.0.0")
    os.umask(0o077)
    args.output.mkdir(parents=True, exist_ok=True)
    env_path, yaml_path = args.output / "control.env", args.output / "livekit.yaml"
    if env_path.exists() or yaml_path.exists():
        parser.error("Configuration already exists; edit it or select a new --output directory.")
    key, secret = "meeting_" + secrets.token_hex(12), secrets.token_hex(32)
    env_path.write_text(
        f"MEETING_HOST={ip}\nMEETING_PORT=9000\n"
        f"MEETING_LIVEKIT_URL=ws://{ip}:7880\n"
        f"MEETING_LIVEKIT_API_KEY={key}\nMEETING_LIVEKIT_API_SECRET={secret}\n"
        "MEETING_LIVEKIT_TOKEN_TTL_SECONDS=600\n", encoding="utf-8")
    yaml_path.write_text(
        f"port: 7880\nbind_addresses:\n  - {ip}\n"
        f"rtc:\n  tcp_port: 7881\n  udp_port: 7882\n  use_external_ip: false\n  node_ip: {ip}\n"
        f"keys:\n  {key}: {secret}\nlogging:\n  level: info\n", encoding="utf-8")
    print(f"Created {env_path} and {yaml_path}; credentials were not printed.")
    print(f"Client server address: {ip}:9000")


if __name__ == "__main__":
    main()
