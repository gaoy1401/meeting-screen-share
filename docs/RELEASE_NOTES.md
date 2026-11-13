# Meeting Screen Share 0.1.0 preview

Native screen sharing and voice rooms for macOS, Windows and Linux using
WebRTC and a self-hosted LiveKit SFU. No hosted server is included.

This preview is for trusted LANs or access-controlled VPNs. The custom control
connection is plaintext and unauthenticated. Do not expose it as an unrestricted
public service. Use H.264 for Windows interoperability; Linux capture requires X11.

Choose the package matching your platform and architecture. macOS ZIPs contain
an app to drag into Applications; Windows offers a portable ZIP and installer;
Linux runs from source. Verify SHA-256 checksums before installing.

macOS previews are ad-hoc signed and not notarized. Windows previews may be
unsigned. See the platform installation guides and THIRD_PARTY_NOTICES.md.

Maintainer: add actual cross-device validation results before publishing this
draft. Do not describe compilation/unit tests as successful audio/video acceptance.
