# MSR Meeting Recorder - 360 UI/UX Review

> Historical baseline review. Its P0/P1 findings informed the v1.0 workbench; referenced line numbers and screenshots describe the pre-parity UI and are not current implementation documentation.

Date: 2026-06-29  
Goal: keep the app simple, fast to understand, and trustworthy for meeting recording.

## Executive Direction

The best next visual direction is:

**Top Recording Bar + Native History Sidebar + Progressive Detail**

MSR should feel like a tiny meeting recorder first, not a file utility. The first thing users should see is whether they can record, whether audio is actually coming in, and what the next action is after saving.

Reference wireframe: `artifacts/msr-kiss-ui-wireframe.svg`  
Current UI screenshot: `artifacts/msr-current-ui.png`

## Priority Findings

### P0 - Fix Recording Trust Before More Polish

1. **The selected source can change mid-recording and produce wrong metadata.**  
   `startRecording()` starts with the current `selectedSource`, but `stopRecording()` writes metadata using the current `selectedSource` again. If the user changes the segmented picker while recording, the saved file can be labeled as a different source than what was actually captured.
   - Evidence: `Sources/MSRMeetingRecorder/AppViewModel.swift:125`
   - Evidence: `Sources/MSRMeetingRecorder/AppViewModel.swift:145`
   - Evidence: the source picker is always editable at `Sources/MSRMeetingRecorder/ContentView.swift:27`

2. **The live wave can look active even when it is not proving real audio signal.**  
   The waveform intentionally adds an animated pulse while recording, and system audio currently sends a constant level update. This looks alive, but it can create false confidence when the mic or system source is silent.
   - Evidence: animated pulse fallback at `Sources/MSRMeetingRecorder/WaveformView.swift:56`
   - Evidence: system capture level is fixed at `Sources/MSRServices/MeetingAudioRecorder.swift:325`

### P1 - Main UX Should Be One Clear Flow

1. **The primary record action is visually buried in the sidebar.**  
   Recording is the core job, but the current structure puts source, settings, record, meter, folder tools, and history all in the left column.
   - Evidence: sidebar owns source, settings, record, waveform, folder, refresh, and list at `Sources/MSRMeetingRecorder/ContentView.swift:24`

2. **The detail view starts as a file viewer instead of a recorder-ready state.**  
   The empty title says `No Recording Selected`. For a meeting recorder, the app should say it is ready to record, then show the saved recording after stop.
   - Evidence: empty title at `Sources/MSRMeetingRecorder/ContentView.swift:118`

3. **The action toolbar is too dense for a KISS app.**  
   Playback, skip, stop, transcribe, copy transcript, summarize, and copy summary all live in one row. Users must scan too much.
   - Evidence: toolbar actions at `Sources/MSRMeetingRecorder/ContentView.swift:137`

4. **Rename after stop interrupts the natural meeting flow.**  
   Auto-save is good. Forcing the rename sheet after every stop adds friction exactly when users want to confirm the recording worked or move to transcription.
   - Evidence: rename sheet forced after save at `Sources/MSRMeetingRecorder/AppViewModel.swift:155`

5. **Long-running actions do not have enough visible state.**  
   Start, stop/mixdown, transcription, summary, and credential tests use status text, but there are no dedicated starting, finalizing, transcribing, summarizing, or testing states. Duplicate taps are also not clearly blocked.
   - Evidence: transcription status only at `Sources/MSRMeetingRecorder/AppViewModel.swift:181`
   - Evidence: summary status only at `Sources/MSRMeetingRecorder/AppViewModel.swift:208`
   - Evidence: mixdown happens during stop at `Sources/MSRServices/MeetingAudioRecorder.swift:175`

6. **Transcript and summary have equal weight too early.**  
   Transcript is the main artifact after transcription. Summary should appear after summarization, as a right inspector, collapsible panel, or tab.
   - Evidence: equal split view at `Sources/MSRMeetingRecorder/ContentView.swift:207`

7. **Keyboard/menu support is incomplete for a macOS recorder.**  
   `Cmd+Shift+R` starts recording, but is disabled while recording. It should toggle start/stop. Playback, rename, transcribe, refresh, and show in Finder should also be menu-accessible.
   - Evidence: command is start-only at `Sources/MSRMeetingRecorder/MSRMeetingRecorderApp.swift:20`
   - Evidence: disabled while recording at `Sources/MSRMeetingRecorder/MSRMeetingRecorderApp.swift:24`

### P2 - Polish Without Bloated Features

1. **Settings are flat and duplicated.**  
   There is a native Settings scene plus a custom settings sheet from the gear button. The fields are currently one flat form. Keep it simple, but group by `Storage`, `Transcription`, and `Summary`.
   - Evidence: settings sheet at `Sources/MSRMeetingRecorder/ContentView.swift:17`
   - Evidence: native settings scene at `Sources/MSRMeetingRecorder/MSRMeetingRecorderApp.swift:28`
   - Evidence: flat form at `Sources/MSRMeetingRecorder/SettingsView.swift:8`

2. **Local API status is too technical for the main UI.**  
   `Local API running on 127.0.0.1...` is useful for debugging, but normal users care about whether recording/transcription is ready.
   - Evidence: status text at `Sources/MSRMeetingRecorder/AppViewModel.swift:73`

3. **Folder and refresh are maintenance actions, not primary workflow.**  
   Folder is already a setting. Refresh should be automatic or menu-level. Keeping both beside the Record button makes the app feel like a utility panel.
   - Evidence: folder/refresh row at `Sources/MSRMeetingRecorder/ContentView.swift:62`

## Best Visual Recommendation

### Layout

Use three calm zones:

1. **Top recording bar**
   - Source segmented control: `Mic`, `System`, `Mic + System`
   - Honest signal rows for the selected sources
   - Timer and recording state
   - One large primary button: `Record` or `Stop`
   - Small settings icon at the far right

2. **Left history sidebar**
   - Native selectable list of saved recordings
   - Date, duration, source
   - Right-click actions: `Play`, `Rename`, `Show in Finder`, `Delete`
   - Folder/refresh moved out of the main surface

3. **Main detail area**
   - Empty state: `Ready to record`
   - After save: playback strip first
   - Then one primary next action:
     - no transcript: `Transcribe`
     - transcript exists, no summary: `Summarize`
     - summary exists: `Copy Summary`
   - Transcript gets the largest area
   - Summary is secondary and only prominent after it exists

### Text Wireframe

```text
+------------------------------------------------------------------------------+
| Source: [ Mic | System | Mic + System ]   Mic: ||||||  System: |||    00:12  |
|                                               [ Stop Recording ]        [gear]|
+------------------------------+-----------------------------------------------+
| Recordings                   | Meeting 2026-06-29 14.05                       |
|                              | Mic + System - 12:42                           |
| Today                        |                                               |
| > Client weekly sync         | [play] 00:00 / 12:42 -----                    |
|   Mic + System - 12:42       |                                               |
|   Product discussion         | [ Transcribe with ElevenLabs ]                |
|   Mic - 05:31                |                                               |
|                              | Transcript                                    |
| Yesterday                    | +-------------------------------------------+ |
|   Standup                   | | editable transcript text...                | |
|   System - 09:10            | |                                           | |
|                              | +-------------------------------------------+ |
|                              | Summary                                       |
|                              | +-------------------------------------------+ |
|                              | | key decisions, action items...             | |
|                              | +-------------------------------------------+ |
+------------------------------+-----------------------------------------------+
```

## Recording Trust Design

The wave should not be just decorative. It should answer: "Is the source I selected actually being recorded?"

Recommended simple behavior:

- `Mic` selected: show one mic meter.
- `System` selected: show one system meter.
- `Mic + System` selected: show two compact rows, one for each source.
- Green means signal detected.
- Yellow means selected but quiet for 2-3 seconds.
- Red means permission or capture failed.
- Gray means source is not selected.

Do not show a fake moving wave as proof. If a decorative wave remains, it should sit behind honest per-source status, not replace it.

## KISS Interaction Flow

### First Launch

1. User sees `Ready to record`.
2. If permissions or keys are missing, show a compact readiness strip only when needed:
   - Microphone permission
   - System audio permission
   - ElevenLabs key
   - OpenAI key for summary
3. User clicks `Record`.

### Recording

1. Source picker locks.
2. Timer starts immediately.
3. Meters show selected source health.
4. Primary button becomes `Stop Recording`.

### After Stop

1. App shows `Finalizing...` while mixdown/save finishes.
2. Recording auto-saves and becomes selected.
3. No forced rename sheet.
4. User can rename inline from title or context menu.
5. Primary next action becomes `Transcribe with ElevenLabs`.

### After Transcription

1. Transcript appears.
2. Primary next action becomes `Summarize`.
3. Copy actions are available, but secondary.

### After Summary

1. Summary appears in a smaller secondary panel.
2. Primary next action can become `Copy Summary`.

## What To Remove Or Hide

Keep the first version intentionally small:

- Hide local API host/port from normal status.
- Move provider switching to advanced settings. ElevenLabs should be the default transcription path.
- Remove forced rename after every stop.
- Move folder selection to settings.
- Make refresh automatic or menu-only.
- Avoid dashboards, tags, search, calendar integration, team sharing, cloud sync, live captions, prompt templates, and automatic transcription for now.

## Implementation Roadmap

### Phase 1 - Trust And State

- Lock `selectedSource` when recording starts and save that locked source in metadata.
- Add explicit states: `ready`, `starting`, `recording`, `finalizing`, `saved`, `transcribing`, `summarizing`, `failed`.
- Disable duplicate actions during async work.
- Change `Cmd+Shift+R` to toggle start/stop.
- Remove forced rename sheet after stop.

### Phase 2 - Best KISS Layout

- Move recording controls to a full-width top bar.
- Convert the recording history to a native selectable sidebar.
- Move folder/refresh out of the primary sidebar.
- Change the empty state to `Ready to record`.
- Collapse actions to one primary next action based on current state.

### Phase 3 - Honest Audio Feedback

- Replace single combined level with per-source health.
- Compute real system audio level from sample buffers instead of sending a fixed value.
- Show selected-source silence warnings after 2-3 seconds.
- Add a post-recording health check: duration, file size, and likely silent source warning.

### Phase 4 - macOS Polish

- Route gear to the native Settings window or keep only one custom settings surface.
- Add accessibility labels and hints for icon-only controls.
- Add menu commands for playback, rename, transcribe, summarize, refresh, and show in Finder.
- Add app icon, Developer ID signing, and notarization for distribution.

## Final Product Principle

The app should always make the next step obvious:

**Record -> Confirm saved audio -> Transcribe -> Summarize -> Copy**

Everything else should be secondary, hidden in settings, or postponed.
