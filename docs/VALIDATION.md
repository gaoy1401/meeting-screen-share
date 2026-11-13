# Validation record — 0.1.0 preview

Date: 2026-11-13. Build host: Apple Silicon macOS, Swift 6.3.3, Node.js 26.8.2.
This record reports actual checks and limitations, not a production certification.

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
| GitHub CI / package workflow | Added; not executed remotely in this environment |
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

Publishing was not completed: terminal networking and project Git initialization
were blocked; the available GitHub integration could read the account but could
not create a repository, and browser control was unavailable. No existing GitHub
repository or deployed server was modified. Use the provided publication script
from a terminal with GitHub access, then complete CI and device acceptance.
