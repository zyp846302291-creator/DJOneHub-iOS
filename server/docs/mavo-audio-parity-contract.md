# MaVo Audio Parity Contract

## Reference

- Reference application: MaVo macOS `0.1.2 (3)`.
- Reference source revision: `0443dfdaf8aec086fd76ba2ee9152fd908114524`.
- Reference implementation: `Sources/MaVo/VoiceAudioService.swift` and
  `Sources/CUACProbe/CUACProbe.c`.
- The UAC probe copied into DJOneHub must remain byte-identical to the
  reference unless MaVo itself changes it. Its SHA-256 is
  `478b62fe559d0ec48c077d0dadb872bb33c6ed4a3d20336e52fa467648e3e0bc`.

## Non-negotiable runtime rules

1. DJOneHub call media on macOS must be hosted by the Swift implementation
   derived directly from MaVo `VoiceAudioService.startUAC`, `runUACLoop`,
   `schedulePlayback`, microphone capture/resampling and UAC cleanup logic.
2. The Go backend may control AT calls, module D4/UAC route start/stop, UI
   state and recording requests only. It must not own a second UAC pump,
   AVAudioEngine graph, AudioQueue path, sample-rate converter, DSP filter or
   playback queue.
3. A media session starts only after the backend confirms exactly one active
   CLCC voice call. The Swift host must validate the UAC pair by USB
   VID/PID/location and preserve MaVo's preferred UID selection.
4. The Swift host must preserve MaVo's session generation, state lock,
   bounded 400 ms playback queue, 5 ms UAC loop cadence, 3-second callback
   stall detection and deferred UAC cleanup behavior.
5. No DJOneHub-specific gain, LPF, resampler, timer callback, recording write
   or mutex may run in the UAC loop or CoreAudio callback path.
6. Recording is optional post-copy observation. Failure, backlog or disabled
   recording must never change media scheduling, playback, capture or UAC
   progress.
7. The previous Go/Objective-C bridge is retained only as a Git rollback
   artifact. It must not be reachable in the V1.2.1+ production media path.

## Allowed integration boundary

- DJOneHub supplies an active-call token and validated module USB identity to
  the Swift media host.
- The Swift media host reports started, failed and stopped states back to the
  backend through a local loopback API/IPC boundary.
- UI mute and recording controls are forwarded to the Swift host; they must
  use MaVo's state transition semantics.

## Acceptance gate

- Build proves the App embeds the Swift MaVo-derived host and exact UAC probe.
- A matched call on the same Mac/module/SIM must be compared with MaVo using
  a 30-second call and separate far/near captures.
- A failure to match MaVo leaves this feature marked experimental and cannot
  be described as solved.
