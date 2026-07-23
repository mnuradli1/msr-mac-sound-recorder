# MSR Mac Meeting Recorder

MSR 1.0 is a native macOS meeting-recording workbench built with SwiftUI. It records microphone audio, all Mac system audio, or both; safely recovers interrupted sessions; and turns recordings into editable, searchable, exportable meeting notes with ElevenLabs or OpenAI.

## Current Shape

- Native SwiftUI app target: `MSRMeetingRecorder`
- Core library/history target: `MSRCore`
- Audio/provider/local API services target: `MSRServices`
- Coordinated recording, library, playback, queue, notes/export, and settings models: `MSRPresentation`
- SwiftPM unit/integration tests plus the `MSRTestRunner` E2E fake-provider harness
- Immutable recording storage with lazy migration from pre-1.0 libraries
- Review waveform, seeking, playback speeds, non-destructive trim, and selected-range transcription
- English/Indonesian UI resources, themes, menu-bar control, and Control–Option–R global recording shortcut
- TXT, Markdown, SRT, and DOCX export

The default transcription provider is ElevenLabs. Summary generation uses OpenAI.

## Run

```bash
swift run MSRMeetingRecorder
```

The local API is disabled by default. Advanced settings can enable a loopback-only server on `127.0.0.1:47837`; every endpoint except `/health` requires the per-run bearer token shown there. File requests are limited to the active recordings library.

## Package as a Clickable Mac App

```bash
chmod +x scripts/package_app.sh
./scripts/package_app.sh
open dist/MSR\ Meeting\ Recorder.app
```

The script creates `dist/MSR-Meeting-Recorder-1.0A-app.zip`, `dist/MSR-Meeting-Recorder-1.0A.dmg`, SHA-256 checksums, provenance metadata, and a generated Homebrew cask. Set `APPLE_SIGNING_IDENTITY` and `APPLE_NOTARY_PROFILE` for Developer ID signing and notarization; otherwise it produces a hardened ad-hoc build.

## API Keys

Keys are never stored in source. New keys are session-only by default; enable “Remember credentials” to use the existing Keychain identifiers. Environment variables remain supported:

```bash
export ELEVENLABS_API_KEY="..."
export OPENAI_API_KEY="..."
swift run MSRMeetingRecorder
```

## Verify

```bash
swift run MSRTestRunner
swift build
swift test
codegraph status . --json
```

For the broader package/release smoke test:

```bash
chmod +x scripts/smoke_test.sh
./scripts/smoke_test.sh
```

If `ELEVENLABS_API_KEY` or `OPENAI_API_KEY` are present in the shell environment, the smoke test also validates those provider credentials without printing the key values.

## macOS Permissions

MSR needs Microphone permission for mic recording and Screen Recording/System Audio permission for system audio capture. Permission strings are defined in `Config/MSRMeetingRecorder-Info.plist`.

## Notes

- macOS 14 supports system audio capture through ScreenCaptureKit.
- ScreenCaptureKit microphone capture is macOS 15+, so on macOS 14 the app records mic and system audio through separate native capture paths and merges them after stop.
- Custom recording folders are persisted as security-scoped bookmarks with a legacy path fallback.
- Crash diagnostics retain at most ten privacy-safe logs in `~/Library/Logs/MSR`; audio, transcripts, tokens, and API keys are never logged.
- The WSR parity audit lives in `docs/WSR_PARITY_MATRIX.md`.
