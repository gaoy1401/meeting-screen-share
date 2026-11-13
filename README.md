# Meeting Screen Share

[![CI](https://github.com/gaoy1401/meeting-screen-share/actions/workflows/ci.yml/badge.svg)](https://github.com/gaoy1401/meeting-screen-share/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/gaoy1401/meeting-screen-share?include_prereleases&label=preview)](https://github.com/gaoy1401/meeting-screen-share/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Native screen sharing and voice rooms for macOS, Windows and Linux, built on
WebRTC and a self-hosted LiveKit SFU. **Early preview: trusted LAN / VPN use.**

[中文说明](README.zh-CN.md) · [Downloads](https://github.com/gaoy1401/meeting-screen-share/releases) · [Architecture](docs/architecture.md) ·
[Test plan](docs/test-plan.md) · [Release guide](docs/RELEASING.md)

## Download v0.1.0 preview

**[Open all downloads and SHA-256 checksums](https://github.com/gaoy1401/meeting-screen-share/releases/tag/v0.1.0)**

| Platform | Download | Installation |
| --- | --- | --- |
| macOS 13+, Apple Silicon (M series) | [Download Mac app ZIP](https://github.com/gaoy1401/meeting-screen-share/releases/download/v0.1.0/MeetingClient-0.1.0-macos-arm64.zip) | Unzip and drag `MeetingClient.app` into Applications. [Mac guide](docs/INSTALL_MAC.md) |
| Windows 10/11 x64 | [Download Windows installer (.exe)](https://github.com/gaoy1401/meeting-screen-share/releases/download/v0.1.0/MeetingClient-Setup-0.1.0-x64.exe) · [Portable ZIP](https://github.com/gaoy1401/meeting-screen-share/releases/download/v0.1.0/MeetingClient-Windows-x64.zip) | Run the installer, or follow the [portable instructions](windows-client/DISTRIBUTION.md). |
| Linux (X11) | [Linux setup guide](linux-client/README.md) | Run from source; no Linux installer is included in this release. |

The Mac and Windows client downloads do not require compiling the source.
To join an existing server, install the client and enter its address and room ID.
For your first server, follow the [Mac server setup](mac-server/README.md) or the
[manual server setup below](#manual-server-setup-linux-or-macos).
This remains a preview: macOS is not notarized and Windows packages are unsigned.

## Features and status

- macOS: SwiftUI, display/window capture, microphone and system audio.
- Windows: Win32 client, desktop capture and microphone audio.
- Linux: GTK4/GStreamer client; optional NVIDIA hardware capture.
- H.264 video and Opus audio over WebRTC, with LiveKit media routing.
- Self-hosted Node.js control service issues short-lived, room-scoped tokens.

There is **no hosted default server**. Clients initially point at
`127.0.0.1:9000`. Start your own server and enter its address on each client.

The custom control connection uses plaintext TCP and does not authenticate
users. Knowing a room ID is enough to request access. Use a trusted LAN or an
access-controlled VPN. WebRTC transport encryption does not make this
application end-to-end encrypted. See [SECURITY.md](SECURITY.md).

| Platform | Requirements | Distribution |
| --- | --- | --- |
| macOS | macOS 13+; Swift 6 / Xcode 16+ to build | Architecture-specific app ZIP |
| Windows | Windows 10/11 x64; VS 2022 C++, CMake 3.20+ to build | Portable ZIP and installer |
| Linux | Ubuntu 24.04, X11, Python 3.10+, GTK4/GStreamer | Source |

Mac preview packages are ad-hoc signed, not notarized. Windows packages are
unsigned unless a signing certificate is configured. Native Wayland screen
capture is not implemented. Use H.264 for meetings involving Windows; HEVC is
experimental. Builds and unit tests do not replace two-device media acceptance.

## Quick start: host a trusted LAN room on a Mac

Install Homebrew first, then run these commands from the repository root:

```sh
./mac-server/bin/install.sh
./mac-server/bin/start.sh
./scripts/build-client.sh
open dist/mac/MeetingClient.app
```

The server script prints its LAN address and generates random credentials.
Enter that address and the same room ID on both computers. Grant microphone
and screen-recording permission when prompted. Use headphones.

```sh
./mac-server/bin/check.sh
./mac-server/bin/stop.sh
```

The check script tests credentials and SFU reachability, not real audio/video.
See [Mac server instructions](mac-server/README.md).

## Manual server setup: Linux or macOS

Install Node.js 22+ and [LiveKit Server](https://github.com/livekit/livekit).
Replace the example address with your server's actual LAN IPv4:

```sh
npm ci --prefix server
python3 scripts/configure-server.py --ip 192.168.1.10
livekit-server --config .runtime/server/livekit.yaml
```

In another terminal, from the repository root:

```sh
set -a
. .runtime/server/control.env
set +a
node server/src/index.js
```

Omitting `--ip` creates a single-machine loopback configuration. Generated files
are private, excluded from source exports, and never overwritten automatically.

| Port | Protocol | Purpose |
| --- | --- | --- |
| 9000 | TCP | Room control and credentials; trusted network only |
| 7880 | TCP | LiveKit WebSocket signaling |
| 7881 | TCP | WebRTC ICE/TCP fallback |
| 7882 | UDP | WebRTC media |
| 9000 | UDP | Legacy diagnostic media |

See [systemd examples](deploy/systemd/README.md) and
[VPS prerequisites](deploy/public/README.md) for advanced setups.

## Client builds and packages

```sh
# macOS app + installable ZIP and checksum
./scripts/package-mac.sh
# Linux: install dependencies from linux-client/README.md first
./linux-client/run-client.sh
```

On Windows, in PowerShell:

```powershell
cd windows-client
.\scripts\build-release.ps1 -InstallInnoSetup
```

See [Mac installation](docs/INSTALL_MAC.md), [Windows](windows-client/README.md)
and [Linux](linux-client/README.md). The Mac build applies the included
[LiveKit patch](patches/livekit-macos-dynamic-apps.patch) so apps opened after
full-display sharing starts appear in the stream. Window capture stays scoped
to the selected window.

## Development

```sh
npm ci --prefix server
npm test --prefix server
PYTHONPATH=linux-client python3 linux-client/check-client.py
PYTHONPATH=linux-client python3 linux-client/check-hardware-screen.py
```

CI covers server tests, Linux protocol checks and native client builds, and
produces platform packages. The first successful push build on `main` for each
version publishes a GitHub prerelease with those verified build artifacts.
Existing release assets are never replaced automatically. A separate manual
packaging workflow is also available.
See [CONTRIBUTING.md](CONTRIBUTING.md) and the [test plan](docs/test-plan.md).

| Directory | Purpose |
| --- | --- |
| `client/` | macOS UI, WebRTC and legacy transport |
| `windows-client/` | Win32 client, build and installer scripts |
| `linux-client/` | GTK client and optional NVENC publisher |
| `server/` | TCP signaling, JWT issuer, legacy UDP relay |
| `mac-server/`, `deploy/` | Server setup and service examples |
| `scripts/`, `.github/` | Packaging, source export and CI |

## License

Original code uses the [MIT license](LICENSE). Dependencies retain their own
licenses: [third-party notices](THIRD_PARTY_NOTICES.md).
