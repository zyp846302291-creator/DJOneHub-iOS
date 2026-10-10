# DJOneHub v1.2.8 Public Release Decisions

## Accepted

- Use MaVo v0.1.2 as the concrete behavior baseline now that the same physical
  module, SIM and Mac completed a clean real call. Port its MIT-licensed UAC
  binding, PCM16 SPSC and AVAudioEngine scheduling model rather than continuing
  parameter tuning on DJOneHub's old router.
- The exact implementation boundary is frozen in
  `docs/mavo-audio-parity-contract.md`: the Swift MaVo-derived host owns all
  production media scheduling; Go owns call control only. No local audio
  approximation may be substituted without an explicit contract revision.
- Treat `AT+QCFG="ims"` as a two-field state: configuration `2` means forced
  disabled even though it is nonzero. A usable voice setup must read back
  configuration `1` and VoLTE capability `1` after restart.
- Do not start the D4/UAC media route before ATD/ATA succeeds. Match MaVo by
  waiting for an active voice CLCC before starting module and host audio.

- Treat the public MaVo PCM bridge as a reference for real-time ownership and
  lifecycle, not as proof that PCM16 conversion alone fixes call noise. The
  first migration phase is a bounded lock-free SPSC bridge with small buffers;
  the existing route remains recoverable until a matched hardware call test
  confirms an improvement.

- V1.1 treats first-use voice preparation as a one-time App-guided operation,
  not a background mutation on module insertion. It must retain an exact local
  USB configuration backup and expose progress/recovery status.
- Treat the known legacy UAC tuple as an eligible recoverable state, not as a
  new module. The user-confirmed recovery path must either end ready or restore
  the captured tuple and leave an actionable retry state.
- A transient upstream runtime failure is not proof of an incompatible module:
  try the pinned GitHub Raw endpoint, the pinned Contents API endpoint, and one
  Raw retry; accept only data matching the fixed SHA-256.
- Treat `2CA3:4006` with the complete `1,1,1,1,1,1,1` flag tuple as an
  already audio-capable DJI identity. Do not offer initialization just because
  it is not rewritten to Quectel's VID/PID.

- Use one macOS Universal DMG for Apple Silicon and Intel.
- Ship the independent SwiftUI App together with the Go backend.
- Keep the web console as a local diagnostic and compatibility surface.
- Treat the current bidirectional call path as adopted, while documenting the
  remaining intermittent audio noise.
- Exclude intermediate failed audio bridge variants from the final candidate.
- Prepare Windows as a separate platform package with honest capability flags.
- Keep all release work private until Jamie approves the preview.
- Publish DJOneHub as an open-source project while excluding module-side voice
  runtime binaries from all public artifacts. A user-confirmed, pinned upstream
  bootstrap may cache and use the upstream runtime locally after SHA-256
  validation. Do not describe a public package as a download-and-call bundle
  until that exact path passes a real QDC507 call test.

## Rejected

- Treating every nonzero IMS configuration as enabled.
- Keeping the module voice route permanently active before or between calls.
- Continuing isolated gain/filter/buffer tuning on the legacy audio router.

- Publishing the dirty development tree directly.
- Calling a cross-compiled EXE a verified Windows release.
- Claiming feature parity where Windows platform implementations do not exist.
- Replacing the macOS SwiftUI App with the old browser-only workflow.

## Open decisions

- Windows desktop shell technology is constrained by the available macOS build
  host. Prefer a reproducible Go-based amd64 launcher; Windows hardware runtime
  validation is still required before public release.
- Final version/tag name will be selected only after local review passes.
- The two embedded MaVo kernel modules identify themselves as GPL v2, while the
  available upstream snapshot contains only the module binaries. They may remain
  in the private test candidate, but public redistribution is blocked until
  their corresponding source or another compliant distribution basis exists.
