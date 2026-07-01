# Long Transcription Stability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make long ElevenLabs transcription recoverable and retryable without chunking by default.

**Architecture:** Add a small hidden transcription job JSON model in `MSRCore`, persist one job per recording while transcription runs or fails, and update `AppViewModel` to show retry-friendly state. Keep the provider request as one direct upload because ElevenLabs supports long files; increase request timeout for long uploads.

**Tech Stack:** Swift, SwiftUI, URLSession multipart upload, folder-based JSON sidecars, `MSRTestRunner`.

---

### Task 1: Transcription Job State

**Files:**
- Create: `Sources/MSRCore/TranscriptionJob.swift`
- Modify: `Sources/MSRTestRunner/main.swift`

- [ ] **Step 1: Write failing tests**

Add tests for hidden `.transcription-<recording-id>.json` round-trip, status transitions, and `RecordingLibrary.loadRecordings()` ignoring transcription job files.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift run MSRTestRunner`

Expected: compile failure because transcription job types do not exist.

- [ ] **Step 3: Implement minimal model/store**

Create `TranscriptionJob`, `TranscriptionJobStatus`, and `TranscriptionJobStore` with atomic saves and per-recording lookup.

### Task 2: Error Details And Long Timeout

**Files:**
- Create: `Sources/MSRCore/TranscriptionErrorMessage.swift`
- Modify: `Sources/MSRServices/ElevenLabsTranscriptionClient.swift`
- Modify: `Sources/MSRServices/OpenAIClient.swift`
- Modify: `Sources/MSRTestRunner/main.swift`

- [ ] **Step 1: Write failing tests**

Add tests that ElevenLabs request timeout is at least one hour and error messages distinguish API key, missing file, timeout/network, and provider rejection.

- [ ] **Step 2: Implement minimal code**

Raise transcription timeout to one hour and add a user-readable error message formatter.

### Task 3: App Wiring

**Files:**
- Modify: `Sources/MSRMeetingRecorder/AppViewModel.swift`
- Modify: `Sources/MSRMeetingRecorder/ContentView.swift`

- [ ] **Step 1: Persist job lifecycle**

Before transcription starts, save a running job. On success, save completed job. On failure, save failed job with error details.

- [ ] **Step 2: Retry whole transcription**

If the selected recording has a failed job and no transcript, primary action title becomes `Retry transcription`. Retry overwrites the failed job with a new running attempt.

- [ ] **Step 3: Keep UI simple**

Show `Transcribing with ElevenLabs`, elapsed time, and a status line for direct long upload. Do not expose chunks or queues.

### Task 4: Version And Release

**Files:**
- Modify: `README.md`
- Modify: `scripts/package_app.sh`
- Modify: `scripts/smoke_test.sh`

- [ ] **Step 1: Bump version to 0.2.1**

Update package scripts and README artifact names.

- [ ] **Step 2: Verify and release**

Run `swift run MSRTestRunner`, `swift build`, `scripts/smoke_test.sh`, create app zip, verify zip, install app, commit, push, and publish `v0.2.1`.
