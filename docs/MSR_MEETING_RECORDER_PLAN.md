# MSR Mac Meeting Recorder - KISS V1 Plan

> Historical pre-1.0 design note. The implemented v1.0 architecture and storage/API contracts are documented in the root README and `WSR_PARITY_MATRIX.md`; display-name storage and the mandatory internal proxy described below are intentionally superseded.

## Summary

Build a native macOS 14+ desktop meeting recorder. V1 records microphone audio, system audio, or both; keeps a simple history list; lets the user rename recordings after stopping; and optionally transcribes/summarizes through a bundled local API proxy using OpenAI or ElevenLabs.

References:

- Apple ScreenCaptureKit: https://developer.apple.com/documentation/screencapturekit
- OpenAI Speech-to-Text: https://developers.openai.com/api/docs/guides/speech-to-text
- ElevenLabs Speech-to-Text: https://elevenlabs.io/docs/eleven-api/guides/cookbooks/speech-to-text

## Key Changes

- Main flow: choose source `Mic`, `System`, or `Mic + System`; click `Record`; click `Stop`; rename; optionally `Transcribe`.
- UI stays simple: one main window with record controls, selected source, history list, selected recording detail, transcript panel, and summary panel.
- History is local and folder-based: audio files plus sidecar files live in a user-selected recordings folder.
- File pattern:
  - `<recording-name>.m4a`
  - `<recording-name>.json` for metadata
  - `<recording-name>.transcript.txt`
  - `<recording-name>.summary.md`
- System audio uses native macOS capture only via ScreenCaptureKit-style APIs. No BlackHole or virtual audio driver in v1.
- Local API runs on `127.0.0.1` as a bundled proxy for provider calls and API keys.
- Local API endpoints:
  - `GET /health`
  - `POST /transcribe` with audio file path/provider
  - `POST /summarize` with transcript text
- Provider setting: user chooses OpenAI or ElevenLabs once in Settings. ElevenLabs is the default and main provider.
- OpenAI is used for summaries unless configured otherwise.
- V1 excludes live captions, calendar integration, cloud sync, speaker diarization as a required feature, team sharing, and advanced tagging.

## Test Plan

- Record mic-only, system-only, and mic+system meetings.
- Stop recording, rename it, and confirm all sidecar files follow the new name.
- Restart app and confirm history rebuilds from the recordings folder.
- Transcribe a recording with ElevenLabs and OpenAI provider settings.
- Copy transcript and summary from the UI.
- Verify clear errors for missing mic permission, missing screen/system audio permission, missing API key, provider failure, and oversized audio.
- Confirm normal users never need to start the local API manually.

## Assumptions

- Minimum OS is macOS 14+.
- Native system audio capture is required in v1; virtual audio drivers are intentionally out of scope.
- Transcription is manual after recording, not automatic.
- Summary is manual after transcript, using a concise meeting format: brief summary, key points, and action items.
- ElevenLabs is the primary transcription provider.
