# Local validation record — 0.1.0 preview

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
| GitHub CI / package workflow | Source published; cloud validation is now running (see Actions above) |
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

Source is now published at https://github.com/gaoy1401/meeting-screen-share.
Remote server tests (including the five socket tests blocked locally) passed in
the first CI run. A Windows PowerShell SDK-version quoting error found in that
run was fixed. The current cloud build is the authority for native build status.
The release workflow only publishes packages after all CI jobs for their exact
source commit pass. It does not imply a Windows installation or real media test.
