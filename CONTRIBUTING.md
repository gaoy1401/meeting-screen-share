# Contributing

Issues should include OS and app versions, reproduction steps, expected behavior
and sanitized logs. Never include API secrets or room tokens.

Run `npm ci --prefix server` and `npm test --prefix server` for server changes;
the Linux checks for Python changes; `scripts/build-client.sh` for macOS; and
`windows-client/scripts/build.ps1` on Windows for Windows changes.

For capture, audio, transport and codec changes, also complete the relevant
steps in [docs/test-plan.md](docs/test-plan.md). State exactly what was tested.
A green build does not prove working cross-device media.

Dependency changes must update lockfiles, notices and binary checksums. Keep
SDK downloads, local configuration and build products out of source control.
Contributions of original code use the project MIT license. Preserve upstream
licenses and identify adapted third-party code.
