# Recording Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make long recording sessions recoverable across sleep, pause, and app crashes using a hidden session manifest.

**Architecture:** Add a small `RecordingSessionManifest` model and `RecordingSessionManifestStore` in `MSRCore`. `AppViewModel` persists the current in-memory session after start, pause, resume, and final save. `RecordingRecoveryService` recovers manifest sessions before falling back to older orphan `.m4a` recovery.

**Tech Stack:** Swift, SwiftUI, AVFoundation, folder-based JSON sidecars, `MSRTestRunner`.

---

### Task 1: Manifest Model And Store

**Files:**
- Create: `Sources/MSRCore/RecordingSessionManifest.swift`
- Modify: `Sources/MSRTestRunner/main.swift`

- [ ] **Step 1: Write failing tests**

Add tests that create a manifest, persist it to `.session-<id>.json`, reload it, and verify hidden manifest JSON files are ignored by `RecordingLibrary.loadRecordings()`.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift run MSRTestRunner`

Expected: compile failure because `RecordingSessionManifest` and `RecordingSessionManifestStore` do not exist.

- [ ] **Step 3: Implement minimal model/store**

Create a Codable manifest with source, requested name, started time, accumulated active duration, completed segments, optional active segment, and optional pause reason. Store writes atomically and lists hidden session manifests.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift run MSRTestRunner`

Expected: all tests pass.

### Task 2: Manifest-Driven Recovery

**Files:**
- Modify: `Sources/MSRServices/RecordingRecoveryService.swift`
- Modify: `Sources/MSRTestRunner/main.swift`

- [ ] **Step 1: Write failing tests**

Add tests that recover a manifest with two completed segments into one recording with `segmentCount == 2`, and fail a manifest with a missing segment without producing a shorter recording.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift run MSRTestRunner`

Expected: failure because recovery ignores `.session-*.json`.

- [ ] **Step 3: Implement manifest recovery**

Recover session manifests before orphan files. Merge all completed plus active segment paths in manifest order. If any listed segment is missing or unreadable, move existing manifest leftovers to `recovery-failed` and report failure.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift run MSRTestRunner`

Expected: all tests pass.

### Task 3: AppViewModel Manifest Wiring

**Files:**
- Modify: `Sources/MSRMeetingRecorder/AppViewModel.swift`

- [ ] **Step 1: Persist after every state transition**

Create a manifest when recording starts, update it when pause/resume changes segments, and remove it only after final recording save succeeds.

- [ ] **Step 2: Keep UI KISS**

Reuse existing user-facing states: `Recording`, `Paused by sleep`, `Resume`, `Saving`, `Recovered`. Do not expose manifests, temp files, or chunk lists.

- [ ] **Step 3: Verify behavior**

Run: `swift run MSRTestRunner`

Expected: all tests pass.

### Task 4: Version, Package, Release

**Files:**
- Modify: `README.md`
- Modify: `scripts/package_app.sh`
- Modify: `scripts/smoke_test.sh`

- [ ] **Step 1: Bump version to 0.2.0**

Update package scripts and README artifact names to `0.2.0`.

- [ ] **Step 2: Verify**

Run:

```bash
swift run MSRTestRunner
swift build
scripts/smoke_test.sh
ditto -c -k --sequesterRsrc --keepParent "dist/MSR Meeting Recorder.app" "dist/MSR-Meeting-Recorder-0.2.0-app.zip"
unzip -t "dist/MSR-Meeting-Recorder-0.2.0-app.zip"
```

Expected: all commands pass.

- [ ] **Step 3: Commit and release**

Commit, push `main`, and create GitHub release `v0.2.0` with the DMG and app zip.
