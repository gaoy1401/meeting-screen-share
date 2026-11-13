# Releasing

Source belongs in Git; installable binaries belong in GitHub Releases.
See [GitHub's release guide](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository).

## Automatic preview publication

The repository is public at https://github.com/gaoy1401/meeting-screen-share.
A successful CI push build on `main` creates a prerelease for the version in
`server/package.json` if that release does not already exist. It downloads only
artifacts from that CI run, verifies their checksums, and tags the tested commit.
Pull-request CI runs cannot publish releases. Existing assets remain unchanged.

These releases are explicitly marked previews: native builds, protocol tests and
checksums are verified, but real installation and two-device media acceptance
remain separate. Complete those before promoting a release as validated/stable.

## Creating another repository

Review the MIT license, public README, [security limits](../SECURITY.md), and
[validation record](VALIDATION.md). The first release is a **preview**.

From a terminal with GitHub CLI access, sign in if necessary:

```sh
gh auth login
./scripts/publish-github.sh YOUR_ACCOUNT/meeting-screen-share
```

This creates a **public** repository and publishes the allowlisted source.
It refuses to overwrite an existing repository or reuse an existing local Git
checkout. It never uploads `.runtime/`, credentials, dependencies or binaries.
If the process stops after Git initialization, inspect `git status` and continue
the existing checkout manually; do not delete `.git` and rerun blindly.

To inspect/export the source without publishing:

```sh
python3 scripts/export-source.py --check
python3 scripts/export-source.py
```

## Verification and binary packaging

1. Wait for all CI jobs on the release commit to pass.
2. Complete two-device screen/audio acceptance from [test-plan.md](test-plan.md).
3. On GitHub, run **Build preview packages** on that same commit/branch.
4. Download the resulting platform artifacts. They contain installation ZIPs,
   a Windows installer, and SHA-256 checksums. Do not rename the inner files.
5. Install each artifact on the target platform and check it outside the source
   directory. Record OS, architecture, audio/video and network coverage.

Local macOS packaging: `./scripts/package-mac.sh`. Windows packaging:
`windows-client/scripts/build-release.ps1 -InstallInnoSetup` in PowerShell.
Linux is a source distribution. No Windows or Linux installer is produced by
running the Mac build script.

## Manual release alternative

After the above checks, tag the tested commit and create a draft prerelease:

```sh
git tag -a v0.1.0 -m 'Initial preview'
git push origin v0.1.0
gh release create v0.1.0 --verify-tag --draft --prerelease \
  --title 'Meeting Screen Share 0.1.0 preview' --notes-file docs/RELEASE_NOTES.md
```

Attach the tested packages and checksum files to the draft, review the final
downloads and notes, then publish it. Never attach a package from a different
commit or claim unperformed cross-platform media tests. Ad-hoc macOS signing
does not provide Developer ID or notarization; Windows SmartScreen can also
warn for unsigned preview installers.

When bumping versions, update `server/package.json`, `server/package-lock.json`,
`client/Resources/Info.plist`, `windows-client/CMakeLists.txt`, installer defaults,
and the changelog together. Keep SDK versions and artifact hashes aligned.
