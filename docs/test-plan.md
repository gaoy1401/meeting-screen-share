# Release verification

## Automated checks

Run from the repository root:

```sh
npm ci --prefix server
npm test --prefix server
./scripts/build-client.sh
PYTHONPATH=linux-client python3 linux-client/check-client.py
PYTHONPATH=linux-client python3 linux-client/check-hardware-screen.py
python3 scripts/export-source.py --check
```

On Windows run `windows-client/scripts/build.ps1`; CTest runs as part of the
build. A portable protocol-only check can also run on Linux/macOS:

```sh
c++ -std=c++20 -DNDEBUG -I windows-client/include \
  windows-client/src/control_protocol.cpp \
  windows-client/tests/control_protocol_test.cpp -o /tmp/meeting-control-check
/tmp/meeting-control-check
```

`npm run test:unit --prefix server` omits socket integration tests and is useful
in environments that forbid listening. It is not a substitute for `npm test`.
Do not suppress real failures or count environment-blocked tests as passed.

The legacy UDP room regressions check that a full destination rejects a room
switch without removing the endpoint's existing registry membership, that an
endpoint can rejoin its current full room, and that a successful switch updates
participant snapshots in both rooms. The registry checks use no sockets; relay
integration tests use loopback UDP and synthetic payloads. These checks do not
validate native client room switching, TCP rejoin rollback, LiveKit membership
or real audio/video playback.

## Two-device media acceptance

Use two computers on a trusted LAN or VPN and a server you control. Use its
actual address; no shared test server is supplied. Both clients join the same
room. Use headphones to avoid feedback.

| Check | Required evidence |
| --- | --- |
| Join | Both clients show the expected peer count |
| Screen A → B | B sees A's changing screen continuously, not one frozen frame |
| Screen B → A | A sees B's changing screen continuously |
| Window capture | Only the selected window appears |
| New application | A newly opened app appears in a full-display share |
| Microphone A → B | B actually hears A, with a real microphone/speaker |
| Microphone B → A | A actually hears B |
| macOS system audio | A remote participant hears audio from the selected share |
| Stop capture | Remote video/audio stops when sharing/mic is turned off |
| Leave/rejoin | Peers disappear and a later join succeeds |
| Network interruption | State changes are visible; test recovery/rejoining |
| Room isolation | A client in a different room receives no media |

Use physical audio endpoints. A published audio track or a silent virtual audio
device is not evidence of successful playback. Port checks and JWT issuance do
not prove ICE connectivity or media delivery.

## Platform and codec matrix

Test Mac ↔ Windows and Mac ↔ Linux with H.264. Record OS versions, architecture,
network type and device names without exposing credentials. Confirm real screen
motion and bidirectional speech. Linux requires X11; the separate NVENC publisher
requires NVIDIA hardware and its own acceptance run.

HEVC is experimental: only test capable endpoints, and confirm the actual codec
in track statistics. Windows 1.4.0 SDK packages are not counted as HEVC-capable.
The SFU does not transcode. If UDP is unavailable, verify the actual ICE/TCP
fallback instead of assuming a successful join implies success.

## Package acceptance

Unzip/install the archive outside the source tree on its target platform. Verify
checksums, launch, dependency loading, permissions, screen/audio behavior and
uninstall. For macOS, also run `codesign --verify --deep --strict` on the extracted
app. Ad-hoc signing is not notarization. For Windows test the installer on a clean
VM without development tools and confirm VC++ runtime installation.

Record observed results in `docs/VALIDATION.md` for each release. Never infer a
Windows installer result from the C++ protocol test on a Mac.
