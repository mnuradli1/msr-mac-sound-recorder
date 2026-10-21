# MSR Mac Meeting Recorder

MSR 1.1A is a native macOS meeting-recording workbench built with SwiftUI. It records microphone audio, all Mac system audio, or both; saves automatically on sleep; and turns recordings into editable, searchable, exportable meeting notes with ElevenLabs or OpenAI.

The 1.0B sleep-safety update retains PCM audio until the final M4A is published.
See [automatic save on sleep](docs/SLEEP_SAFETY.md) for behavior, verification,
temporary storage requirements, and the physical lid-close acceptance checklist.

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
- Optional auto-transcribe after every finished recording, and auto-title from the transcript

The default transcription provider is ElevenLabs. Summaries and remote titles use OpenAI or DeepSeek (see API Keys).

## Auto-Transcribe and Auto-Title

Settings → Transcription & AI has two switches:

- **Auto-transcribe new recordings** (off by default): every recording you stop is queued for transcription immediately, using the selected provider's saved key. Recordings that are empty or shorter than three seconds are skipped, and the status bar says why. Imported and recovered recordings are never auto-transcribed.
- **Auto-title recordings from the transcript** (on by default): when a transcript arrives for a recording that still has its default `Meeting yyyy-MM-dd HH.mm` name, the title is replaced with one derived from the transcript. With an OpenAI key the title comes from the model; without one a local heuristic picks the first substantive sentence (English and Indonesian filler is skipped). A title you typed yourself is never overwritten, even if you rename while transcription is running. Auto-titled recordings show an "Auto-titled" badge; renaming keeps your title from then on.

Both switches work with ElevenLabs or OpenAI as the transcription provider. With an OpenAI key saved, the beginning of each transcript is sent to OpenAI to name the recording; without one the title is generated on this Mac.

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

The script creates `dist/MSR-Meeting-Recorder-1.1A-app.zip`, `dist/MSR-Meeting-Recorder-1.1A.dmg`, SHA-256 checksums, provenance metadata, and a generated Homebrew cask. Set `APPLE_SIGNING_IDENTITY` and `APPLE_NOTARY_PROFILE` for Developer ID signing and notarization; otherwise it produces a hardened ad-hoc build.

## API Keys

Keys are never stored in source. New keys are session-only by default; enable “Remember credentials” to use the existing Keychain identifiers. Environment variables remain supported. Lookup order is: a key entered in Settings during this run, then an exported environment variable, then the Keychain. “Forget” clears the session value and the Keychain item; an exported variable still applies until you unset it.

```bash
export ELEVENLABS_API_KEY="..."
export OPENAI_API_KEY="..."     # transcription (optional), summaries, titles
export DEEPSEEK_API_KEY="..."   # summaries and titles (optional alternative to OpenAI)
swift run MSRMeetingRecorder
```

Summaries and remote titles use the selected text-model provider (OpenAI or DeepSeek). If that provider has no key, the other one is used when it has a key; with neither, summaries are unavailable and titles fall back to the on-device heuristic. DeepSeek uses `deepseek-chat` via `https://api.deepseek.com/chat/completions` (override the model with `DEEPSEEK_SUMMARY_MODEL`, like `OPENAI_SUMMARY_MODEL` for OpenAI). The DeepSeek key is stored under the Keychain account `deepseek`; the existing `elevenlabs` and `openai` accounts are unchanged.

## Verify

```bash
swift run MSRTestRunner
swift build
swift test
bash scripts/check_localization.sh
codegraph status . --json
```

With `ELEVENLABS_API_KEY` exported, `MSR_LIVE_E2E=1 swift run MSRTestRunner` also transcribes a real speech clip (`Tests/Fixtures/meeting-en.m4a`, synthetic `say` speech; override with `MSR_LIVE_E2E_CLIP`) through ElevenLabs and checks that the recording is auto-titled (billable, one short request).

### Developer hooks

The app reads a few environment variables for scripted verification; none of them do anything in normal use:

| Variable | Effect |
|---|---|
| `MSR_RECORDINGS_FOLDER` | Use this folder as the library instead of the configured one (keeps fixtures away from real recordings). |
| `MSR_FAKE_RECORDER_CLIP` | Replace the audio recorder with one that "records" the given `.m4a` clip, so the full save → transcribe → title pipeline runs without microphone or screen permission. |
| `MSR_UI_SCENARIO=auto-transcribe` | Record for `MSR_UI_SCENARIO_SECONDS`, stop, wait for the automatic transcription, print a JSON result line to stderr, and exit non-zero on failure. |
| `MSR_UI_SCENARIO=ui-walkthrough` | Click through the redesigned UI via the app's own accessibility tree (rows, tabs, Read/Edit, search, inline rename, Settings toggles, Record → auto-transcribe, ⋯ and menu-bar items, delete confirmation, status bar), checking the view model and disk after each step; `ui-walkthrough-empty` checks the empty-library readiness view. One JSON line per step on stderr, exit 1 on failure. Run both with `scripts/ui_walkthrough.sh` (needs `ELEVENLABS_API_KEY`; no Accessibility permission). |
| `MSR_UI_SNAPSHOT_PATH` | Render the main (or `MSR_UI_SNAPSHOT_WINDOW=settings`) window to a PNG and quit; see `scripts/ui_snapshots.sh` for the state variables (`TAB`, `SELECT`, `APPEARANCE`, `SIZE`, …). |

`scripts/make_ui_fixture.sh` builds a synthetic library (speech from `say`) for snapshots, by default in `${TMPDIR:-/tmp}/msr-ui-fixture`; `scripts/ui_snapshots.sh` writes PNGs to `artifacts/` (override with `MSR_UI_FIXTURE` / `MSR_UI_OUT_DIR`). An exported API key is used before the Keychain, so these runs never trigger a Keychain prompt.

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
