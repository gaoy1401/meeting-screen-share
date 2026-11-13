# Validation record — 0.1.0 preview

## Published preview

Released on 2026-11-13 from commit
`fc6ef3ed147fec77b38060dd60421a939ee39318`:
[v0.1.0 downloads](https://github.com/gaoy1401/meeting-screen-share/releases/tag/v0.1.0).
All three jobs in [the release CI run](https://github.com/gaoy1401/meeting-screen-share/actions/runs/43379634175)
passed. The [publication run](https://github.com/gaoy1401/meeting-screen-share/actions/runs/43379992129)
verified the archive checksums and published artifacts from that exact CI run.

| Cloud check | Result |
| --- | --- |
| Node server tests on Ubuntu | 15 passed, including TCP/UDP integration tests |
| Linux protocol, RTP/H.264, codec and NVENC configuration checks | Passed |
| macOS ARM64 native release build and Swift protocol checks | Passed |
| macOS app ad-hoc signature | Passed deep/strict verification |
| Windows x64 native release build and CTest | Passed; 1 protocol test passed with assertions enabled |
| Windows portable ZIP and Inno Setup installer | Generated; official VC++ runtime signature verified |
| Published archive checksums | Passed before upload |
| Public source | 135 files audited; Git blob hashes and executable modes matched the local source |

Published binaries: macOS Apple Silicon app ZIP, Windows x64 portable ZIP and
Windows x64 installer, with SHA-256 checksum files. Linux is distributed as
source. Intel macOS binaries were not built for this release.

These are build and protocol results. Windows installer execution, Linux desktop
capture, and real two-device screen/audio/reconnection acceptance have not been
performed. macOS notarization and Windows publisher signing are not configured.

## Initial local validation

Date: 2026-11-13. Build host: Apple Silicon macOS, Swift 6.3.3, Node.js 26.8.2.
This is the initial local validation snapshot. Current cloud builds and packaging
results are available in [GitHub Actions](https://github.com/gaoy1401/meeting-screen-share/actions).
It is not a production certification.

| Check | Result |
| --- | --- |
| macOS release compilation from source | Passed with pinned dependencies |
| Swift packet, RTP and H.264 checks | Passed |
| Mac app ZIP, embedded framework and license files | Generated and inspected |
| macOS ad-hoc signature | Passed deep/strict verification, including after extraction outside source tree |
| macOS notarization / Developer ID | Not configured |
| Node isolated unit tests | 10 passed: config validation, tokens, packets, signaling concurrency/closure/line framing |
| Node TCP/UDP integration tests | 5 blocked by environment EPERM when binding/listening on loopback; not counted as passed |
| Linux packet/RTP/H.264/codec checks | Passed on the Mac host |
| Linux hardware-publisher configuration checks | Passed; no NVIDIA capture hardware was exercised |
| Windows control-protocol C++ check | Passed on the Mac host with NDEBUG; assertions remain active |
| Windows native build and installer | Not run here; requires Windows/CI |
| Linux GTK / GStreamer desktop runtime | Not run here |
| Python parsing and shell syntax | Passed |
| Generated server configuration | Matching credentials, private file permissions, refuses overwrite |
| Public source export | Pattern scan passed; excludes build caches, local config, private keys and binaries |
| GitHub CI / package workflow | See the completed cloud results above |
| Two-device screen/audio, reconnection and install UI | Not performed; complete test-plan.md before a validated binary release |

The host could not resolve dependency-download hosts. Existing npm and Swift
caches supplied the exact pinned versions. LiveKit's optional `protocol` schema
submodule (not used by the compiled targets, which include generated Swift
sources) was omitted for the initial offline resolution. Dependency source and
binary versions were not upgraded to work around the network restriction.

The UniFFI 0.0.5 archive lacks its license file; an unmodified upstream Apache-2.0
license supplement with provenance is included under `third-party/livekit-uniffi`.
The macOS app includes dependency notices and privacy manifests. Debug symbols
and local build-path strings are stripped from the distributed executable.

The Windows PowerShell SDK-version quoting error found in the first CI run was
fixed. The pinned Windows SDK archive also omitted LICENSE/NOTICE; exact copies
from its matching upstream tag are now included with provenance. Both fixes are
covered by the successful native build and packaging run linked above.
