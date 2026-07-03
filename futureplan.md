# MSR Future Plan

Date: 2026-07-03

This plan summarizes the seven-lane review of MSR Meeting Recorder across UI/UX, recording reliability, transcription, architecture, testing, release/security, and product roadmap.

## Product Principle

Keep MSR local-first, trust-first, and KISS.

The core flow should stay:

```text
Record -> confirm audio -> transcribe -> useful notes -> copy/export
```

If a feature does not make that flow safer or faster for one person, postpone it.

## Recommended Priority Order

### 1. Recording Reliability Hardening

This is the highest priority because losing a long recording is the worst possible failure.

Work items:

- Fix Mic + System session manifests so recovery tracks the actual mic/system source files, not only a merged output file that exists after a clean stop.
- Make sleep pause safer when macOS proceeds to sleep before async stop/finalize work completes.
- Recover valid segments even when one manifest segment is missing or unreadable.
- Make final save more transactional across audio move, metadata write, and manifest delete.
- Surface clearer recovery notes when a recording is partially recovered.

Target release: `v0.2.7 Trust Hardening`

### 2. Local API Privacy And Cost Guard

MSR auto-starts a local API. That is useful, but it can trigger paid provider calls using saved API keys.

Work items:

- Add an unguessable per-run bearer token for local API requests, or disable the local API unless explicitly enabled.
- Restrict transcription audio paths to the recordings folder or user-approved imports.
- Let internal app workflows call provider services directly instead of routing through `LocalAPIProxy`.
- Keep `LocalAPIProxy` only as an external/local automation boundary.
- Add tests for rejected unauthorized local API calls.

### 3. AppViewModel Testability And Fake-Recorder E2E

`AppViewModel` has become the operations desk for recording, recovery, playback, settings, AI queueing, and macOS windows. The app is not over-engineered overall, but this file is too large to safely grow.

Work items:

- Extract recording-session orchestration from `AppViewModel`.
- Add fake-recorder tests for start, pause, resume, sleep pause, stop, final save, and manifest cleanup.
- Add failure tests for start failure, stop failure, missing segment, and failed finalization.
- Add transcription queue integration tests with fake AI.
- Extend `scripts/smoke_test.sh` to launch the packaged app, check the local health endpoint, and terminate cleanly.

### 4. Long Transcription Guardrails

ElevenLabs can handle long audio, but MSR should not make long uploads fragile or surprising.

Work items:

- Make multipart upload file-backed instead of loading the entire audio plus multipart body into memory.
- Add size, duration, and estimated upload preflight before long transcription.
- Add retry with capped backoff for transient `429`, `5xx`, timeout, and network failures.
- Fail fast for auth and invalid-request errors.
- Preserve partial diarization instead of dropping words without `speaker_id`.
- Make OpenAI summaries long-transcript-aware with chunking or staged summaries when needed.

### 5. Trust-First UI Strip

The app should make readiness visible before the user clicks Record.

Work items:

- Add an inline readiness strip for mic permission, system audio permission, writable folder, and ElevenLabs key.
- Add direct fix buttons for macOS Privacy settings where possible.
- Improve post-recording confidence review: playable file saved, mic captured, system audio silent, duration, and source warning.
- Demote secondary actions like Finder, refresh, import, and retranscribe so the main flow stays obvious.
- Make transcript the dominant artifact and show summary progressively.

### 6. One-Click Meeting Note Export

This is the best next product feature because it turns a recording into useful meeting memory without adding cloud workflow bloat.

Work items:

- Add a Markdown export/copy that includes title, date, duration, source, summary, action items, and transcript.
- Add a dedicated "Copy Meeting Notes" action after summary exists.
- Keep transcript export available, but make full notes the primary handoff.

### 7. Trusted Distribution Polish

This matters if MSR is shared outside the local machine.

Work items:

- Add Developer ID signing and notarization.
- Add hardened runtime and explicit entitlements policy.
- Verify releases with `spctl` for both `.app` and `.dmg`.
- Generate SHA-256 checksums per release.
- Use one version source instead of hard-coding versions across scripts.
- Strengthen secret scanning beyond the current basic token pattern.
- Add a concise privacy note explaining local storage, Keychain use, and when audio/transcripts are sent to providers.

## Product Features To Consider Later

These are useful, but should come after trust hardening:

- Local speaker rename per recording.
- Action items as a first-class local artifact with copy/checklist support.
- Better long-meeting status and "safe to retry later" messaging.
- Manual update check or Sparkle-based update flow.

## Avoid For Now

Do not build these yet:

- Calendar integration.
- Cloud sync.
- Team sharing.
- Dashboards.
- Tags and CRM-style organization.
- Live captions.
- Bot meeting attendance.
- Prompt-template libraries.
- Automatic publishing.
- Global/multi-user speaker identity.
- Fully automatic post-recording AI chains.

These add complexity before the recorder foundation is boringly reliable.

## Suggested Next Implementation Package

`v0.2.7 Trust Hardening`

Scope:

1. Fix Mic + System manifest/recovery correctness.
2. Harden or disable unauthenticated local API access.
3. Add packaged-app launch smoke coverage.
4. Add the first AppViewModel fake-recorder lifecycle tests.

This package is not glamorous, but it is the right next layer before adding more visible features.
