# MSR Meeting Recorder 360 Review

## What Was Fixed

- History list now supports right-click `Show in Finder`.
- `Mic + System` now always records mic and system separately, then exports a single mixed `.m4a` track for reliable playback and transcription.
- Recording wave indicator now animates continuously while recording and still reflects incoming input level.
- ElevenLabs key testing uses the real speech-to-text endpoint instead of an account endpoint that can fail restricted keys with `missing_permissions`.

## Verified

- `swift run MSRTestRunner`
- `swift build`
- `scripts/smoke_test.sh`
- ElevenLabs live speech-to-text key check
- OpenAI live key check
- `.app` launch smoke
- `.app` codesign verification
- `.dmg` verification
- Secret scan outside build/dist artifacts

## Remaining Manual QA

- Grant Microphone permission to `MSR Meeting Recorder.app`, then record 10 seconds of voice.
- Grant Screen Recording/System Audio permission, then record 10 seconds of system audio.
- Record `Mic + System` while speaking and playing system audio, then play the saved file inside MSR.
- Transcribe that `Mic + System` file and confirm both spoken mic audio and system audio are represented.

## Recommended Improvements

- Add a first-run permission checklist for Microphone and Screen/System Audio, with direct buttons to open macOS Settings.
- Add per-source meters for `Mic` and `System` instead of one combined wave.
- Add a short post-recording audio health check: file duration, file size, detected audio tracks, and “mic/system likely silent” warning.
- Add notarized Developer ID packaging so the app opens without Gatekeeper friction.
- Add crash recovery for `.in-progress-*.m4a` files.
- Add long-recording safeguards: file size estimate, chunking before provider upload, and retry/resume for transcription.
