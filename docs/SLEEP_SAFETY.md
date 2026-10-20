# MSR 1.0B — automatic save on sleep

## Expected behavior

Closing the laptop lid or putting the Mac to sleep ends the current recording
and saves it automatically. This also applies to a manually paused recording.
Waking the Mac does not automatically start a new recording.

If sleep arrives during Start, Pause, Resume, or Save, the sleep request is
retained until that transition finishes. Repeated events must not stop the
recorder or publish the recording twice.

Long recordings can take longer to export than macOS allows before sleeping.
In that case, retained audio remains on disk and export/recovery continues
automatically after wake or relaunch. The app must report Saved only after
library publication succeeds.

## Changes

- An IOKit system-power observer holds the sleep acknowledgement during saving.
  An independent 25-second deadline releases it even if app work stalls.
  Completion and the deadline share an exactly-once acknowledgement.
- A recording-action coordinator retains sleep intent during in-flight actions.
  Sleep and wake callbacks are delivered in order.
- Active capture uses uncompressed PCM CAF intermediates. They do not depend on
  an M4A movie index being written at the end of the session.
- System audio is written and closed on its sample queue. PCM is closed before
  waiting for ScreenCaptureKit's bounded stop callback.
- Deterministic raw filenames are persisted before capture starts, allowing
  recovery after an interrupted start or resume.
- Finished recordings remain M4A, preserving playback, transcription and export
  compatibility. Raw files are retained until publication succeeds.
- The launch smoke test uses a temporary home and a copied bundle with a unique
  identity. An early clean exit no longer passes as a successful launch.

Apple documents a finite window for sleep handling and distinguishes forced
sleep (including lid close) from idle sleep:
[sleep/wake notifications](https://developer.apple.com/library/archive/qa/qa1340/_index.html)
and [willSleepNotification](https://developer.apple.com/documentation/appkit/nsworkspace/willsleepnotification).

## Limits and storage

- PCM intermediates consume more space than AAC. At 48 kHz, 32-bit float,
  microphone plus stereo system audio is approximately 2.07 GB per recording
  hour, plus export space. Normal completion removes those intermediates after
  the published recording is safe.
- No audio is recorded while the Mac is asleep.
- A sudden process kill or power failure can lose buffered samples that have not
  reached disk. The change protects accumulated audio; it does not promise zero
  lost samples under every hardware or storage failure.
- A synthetic 3-second PCM writer killed without closing produced 2.986667
  seconds of readable audio on this machine. This is one measured fixture, not
  a universal bound.
- Old AAC files already missing their movie index still require separate repair.
  They must not prevent recovery of newer valid sessions.

## Verification record

All automated capture tests use synthetic audio, fake recorders, and temporary
libraries. They make no provider calls and do not record the user's microphone.

- Initial `swift test` attempt: interrupted by a source edit during compilation
  (`MeetingAudioRecorder.swift was modified during the build`); not counted as
  a baseline pass.
- Synthetic abrupt-termination CAF experiment: passed AVAudioFile and AVURLAsset
  reads, `afinfo`, and full FFmpeg decoding.
- Isolated launch harness checked against the pre-update packaged app: passed.
- Final `swift test`: 34 tests passed, including 10 AppViewModel lifecycle tests.
- `swift run MSRTestRunner`: all tests passed.
- Debug build and full `swift build -c release`: passed.
- Full `scripts/smoke_test.sh`: passed with provider credentials unset. ZIP,
  DMG, SHA-256 checksums, bundle plist, ad-hoc signature, secret scan, and
  isolated five-second launch checks passed. Live provider calls were skipped.
- Installed `/Applications/MSR Meeting Recorder.app`: version 1.0B, build 24.
  Installed executable matches the packaged executable:
  `1ccb71f32c71083b98b4dabda1932dbc47afc089fbf0b639bc5b35a12a76b8c6`.
- Installed-app launch and relaunch passed. An existing recovered library item
  remained playable, unchanged by checksum, and was not duplicated.
- A separate pre-existing damaged legacy session produced a warning without
  blocking the valid library item. Damaged source inputs were retained.

## Upgrade and rollback precautions

Before replacing an installed build, keep a copy of the previous app and a
checksummed backup of any interrupted-session manifests and raw audio. Store
these outside the source repository. Never include recordings, transcripts,
credentials, or user-specific recovery evidence in a public source commit.

This update delivers the sleep-safety fix, not every item in the broader 1.0B
UX brief.

## Physical lid-close acceptance check

Not performed automatically: putting the user's whole Mac to sleep would
interrupt their session.

1. Select Mic, record a short test, close the lid, reopen it, and wait for Saved.
   Play the beginning and end; confirm one new library item and no active timer.
2. Repeat with System while playing known audio, then with Both.
3. Pause a recording manually, close/reopen the lid, and confirm it is saved.
4. Close/reopen during Start and during Save. Confirm the operation finishes,
   the UI recovers, and no duplicate item appears.
5. Repeat with a longer recording. If export crosses sleep, wait after wake and
   confirm automatic publication and playable duration.
6. Quit/relaunch and confirm the item is still available, with no repeated
   recovery or duplicate. Keep any genuinely incomplete-capture warning.
