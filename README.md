# MSR Mac Meeting Recorder

MSR is a simple macOS meeting recorder built with SwiftUI. V1 records microphone audio, system audio, or both, keeps a folder-based history, lets recordings be renamed after stopping, and can transcribe with ElevenLabs or OpenAI through a local API proxy.

## Current Shape

- Native SwiftUI app target: `MSRMeetingRecorder`
- Core library/history target: `MSRCore`
- Audio/provider/local API services target: `MSRServices`
- Lightweight verification runner: `MSRTestRunner`

The default transcription provider is ElevenLabs. Summary generation uses OpenAI.

## Run

```bash
swift run MSRMeetingRecorder
```

The app starts a local API on `127.0.0.1:47837` automatically.

## Package as a Clickable Mac App

```bash
chmod +x scripts/package_app.sh
./scripts/package_app.sh
open dist/MSR\ Meeting\ Recorder.app
```

The script also creates `dist/MSR-Meeting-Recorder-0.1.7.dmg`.

## API Keys

Keys are never stored in source. Use the Settings window to save keys into Keychain, or launch with environment variables:

```bash
export ELEVENLABS_API_KEY="..."
export OPENAI_API_KEY="..."
swift run MSRMeetingRecorder
```

## Verify

```bash
swift run MSRTestRunner
swift build
```

For the broader package/release smoke test:

```bash
chmod +x scripts/smoke_test.sh
./scripts/smoke_test.sh
```

If `ELEVENLABS_API_KEY` or `OPENAI_API_KEY` are present in the shell environment, the smoke test also validates those provider credentials without printing the key values.

## macOS Permissions

V1 needs Microphone permission for mic recording and Screen Recording/System Audio permission for system audio capture. A full Xcode app bundle should use the permission strings in `Config/MSRMeetingRecorder-Info.plist`.

## Notes

- macOS 14 supports system audio capture through ScreenCaptureKit.
- ScreenCaptureKit microphone capture is macOS 15+, so on macOS 14 the app records mic and system audio through separate native capture paths and merges them after stop.
- This repo was scaffolded as a Swift Package because the current machine has Command Line Tools but not full Xcode selected for `xcodebuild`.
