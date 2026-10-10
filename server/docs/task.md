# DJOneHub v1.2.9 Public Release

## Current phase

Prepare and publish the approved v1.2.9 release. The source and packages keep
module-side runtime files external; first use remains confirmation-gated.

### Active follow-up: MaVo parity call route

- [x] Freeze the MaVo Audio Parity Contract before further audio changes.
- [ ] Move production call media ownership into the Swift App using the
  MaVo-derived UAC host; remove the Go/Objective-C media bridge from the
  production path.

- [ ] Vendor the MIT-licensed MaVo UAC probe with its license notice.
- [ ] Replace DJOneHub's module audio callbacks with the verified 8 kHz PCM16
  SPSC UAC bridge and AVAudioEngine host route.
- [ ] Start media only after active CLCC and preserve call-control behavior.
- [ ] Fix first-use setup to provision ADB + UAC and IMS/VoLTE with exact
  read-back verification.
- [ ] Preserve mute, recording, diagnostics and cleanup behavior.
- [ ] Build, test, install and complete one real call A/B against MaVo.
- [ ] Keep `edcf611` as the rollback point until the real-call test passes.

## Tasks

- [x] Separate the final adopted call implementation from failed bridge experiments.
- [x] Update product documentation to match the actual v1.0 feature set.
- [x] Build and verify the macOS Universal backend and SwiftUI App.
- [x] Produce a complete macOS Universal DMG with installer and uninstaller.
- [x] Add a Windows amd64 desktop package and deployment scripts.
- [x] Cross-compile and inspect the Windows artifacts.
- [x] Generate SHA-256 checksums and a private release manifest.
- [x] Run automated tests and App self-tests.
- [x] Request independent Claude review; fix P0/P1 findings only.
- [x] Prepare screenshots and a private review summary for Jamie.
- [x] Receive Jamie approval for push, tag and Release.
- [ ] Verify the one-confirmation upstream-runtime bootstrap against the pinned
  source and a real QDC507 call before representing it as download-and-call.
- [x] Add first-module inspection, confirmation-gated initialization and
  recovery status to the macOS App.
- [x] Preserve the original USB composition before any initialization write;
  verify re-enumeration and existing SMS/4G after the operation.
- [x] Verify the full first-initialization workflow on a factory-default module:
  detect original tuple, require confirmation, write/read back the complete
  audio tuple, restart, provision and reach the ready state.
- [x] Verify controlled recovery from a complete legacy UAC tuple back to the
  standard audio tuple, including local backup creation and ready-state
  validation.
- [x] Make legacy UAC configurations eligible for the same confirmation-gated
  recovery flow, with a terminal rollback state rather than an initialization loop.
- [x] Add retry and official GitHub Contents API fallback for pinned runtime
  downloads while retaining SHA-256 verification.

## Public-release boundaries

- Exclude `qdc507_aprv3.ko`, `qdc507_voice.ko` and `mavo-pcm-bridge.armv7`
  from source, Git history, DMG and Windows ZIP. The macOS App may obtain the
  pinned upstream copy only after an explicit user confirmation and SHA-256
  verification; no background download is permitted.
- Keep the application, controls and MaVo MIT audio adaptation open source.
- State that Intel Mac and Windows packages are structurally verified but not
  runtime-validated on matching hardware.

## Acceptance criteria

- macOS DMG contains the complete backend, App and deployment files.
- Both Mach-O executables in the macOS candidate contain arm64 and x86_64.
- The current Apple Silicon Mac can install/start the candidate and pass health checks.
- Windows package contains an application entry point, backend, deployment files,
  notices and checksum; unsupported capabilities are visible and documented.
- Source tree contains no real phone numbers, SMS content, contacts, recordings,
  device identifiers, local paths or credentials in release-facing files.
- The release candidate is reproducible from committed scripts.
- No GitHub write occurs before Jamie's approval.
