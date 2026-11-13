# Changelog

## Unreleased

- Preserve legacy UDP registry membership when a destination room is full.
- Notify peers in both rooms after a successful legacy UDP room switch, with
  registry and loopback relay regression coverage.

## 0.1.0 — initial open-source preview

- Native macOS, Windows and Linux screen sharing and voice clients.
- LiveKit WebRTC and a self-hosted room-token service.
- Random local credentials, loopback defaults and portable configuration.
- Ordered signaling requests and strict configuration validation.
- Dependency pins, source export, packaging, CI, MIT license and setup guides.

Known limits: unauthenticated plaintext control, no TURN setup, Linux X11 only,
Windows HEVC unavailable, unsigned/unnotarized packages. Two-device media
acceptance is separate from compilation and unit tests.
