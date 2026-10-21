# Performance & footprint findings (main @ b80f405)

Measured 2026-10-21 (Apple Silicon, macOS 26, Swift 6.3.3 CLT, release build). Synthetic libraries: per recording a v2 `.json`, a 28 s m4a, a 32 KB transcript, 51 KB segments (150), a summary; `.json.bak` on 20 %, a completed job on 10 %. App runs used `MSR_UI_SNAPSHOT_*` (window on screen, Notes tab, first row selected) with `*_API_KEY` unset, so no network. Micro-benchmarks came from a temporary swift-testing file (now deleted).

## TL;DR

One bug dominates: **each sidebar row reads the whole library folder.** The row (RecordingSidebar.swift:211) calls `jobChip`, then `job(for:)` (AppViewModel.swift:2616). Without an in-memory job, that falls back to `TranscriptionJobStore.loadAll()` (TranscriptionJob.swift:306/317), which lists the folder and decodes every job: **15.1 ms at N=1000**, 0.58 ms at N=50. NSOutlineView evaluates every row for heights, and the sidebar re-renders on every `@Published` change, so each render does O(N × files) main-thread I/O. In `sample` output, `jobChip` is **88 % of main-thread samples during startup at N=1000, 99 % after startup, and 99 % while recording.**

## 1. Measurements

### App-level (release binary, 3 runs for cold start)

| N | Cold start to snapshot (s) | Busy after snapshot | Idle CPU once settled | Steady footprint / RSS | Peak footprint | CPU while recording (fake recorder, 10 s) | RSS while recording |
|---|---|---|---|---|---|---|---|
| 0 | 0.33 / 0.36 / 0.43 | none | 0.2 % | 29 MB / 70 MB | 40 MB | **18 %** | 101 MB |
| 50 | 0.67 / 0.67 / 0.70 | none | 0.1 % | 56 MB / 90 MB | 80 MB | **74.5 %** | 140 MB |
| 300 | 3.67 / 3.73 / 3.79 | ~10 CPU-s at 100 % | 0.0 % (after ~1 s) | 72 MB / 88 MB | **523 MB** | **99.5 %** (main thread pegged) | 595 MB |
| 1000 | 14.2 / 14.3 / 16.7 (26 s in one keep-running run) | ~18 s at 100 % (fully idle only ~33 s after launch) | 0.0 % | 133 MB / 1.69 GB RSS | **1.6 GB** | **100 %**; recording starts 12 s after launch | 0.8 to 1.7 GB |

Once settled, the app is truly idle: the 5 s `sample` shows every thread parked. The 0.5 to 1.6 GB peaks are autoreleased `NSURL`/`Data` from `contentsOfDirectory` (5,300 entries) run once per row in one run-loop turn. `NSTableView` warns of reentrant delegate calls at N ≥ 300. Playback uses the same path (4 Hz timer, 2 writes per tick), so expect about 25 % CPU at N=50 and a pegged main thread at N ≥ 300 (not measured).

### Micro-benchmarks (release, min/median of 10 unless noted)

| Operation | Result |
|---|---|
| `RecordingLibrary.loadRecordings()` at N = 50 / 300 / 1000 | 11.7 / 71.0 / **258** ms (median 12.0 / 72.0 / 260) |
| Same with no `.transcript.segments.json` present, N=1000 | **120 ms** (−54 %) |
| `finishRecording`, N=1000 (2 internal loads + durable write) | **676 ms** |
| `rename`, N=1000 (1 internal load + durable write) | ≈430 ms |
| `TranscriptionJobStore.loadAll()` at N = 50 / 1000 | 0.58 / **15.1** ms |
| `RecordingSearchIndexer.documents` for 1000 recordings, as shipped (LRU capacity 64) | 126 to 171 ms (re-reads ~all files every pass) |
| Same, warm cache with capacity ≥ N | 54 ms |
| Search text held in memory, N=1000 | **33.4 MB** (`Swift.StringStorage` is 37.6 MB of 80 MB malloc) |
| `RecordingSearch.filter`, 1000 docs: `budget` (all hit) / `zzqx` (no hit) / `2026-10` | 117 / **843** / 707 ms |
| `filter` over metadata-only docs | 58 ms (`DateFormatter` per doc is 18.6 ms of that) |
| Sidebar sections replica (dict + sort + 3 calendar filters), 1000 rows | 6.8 ms per render |
| `rowBadges`: 2 × `fileExists` per row, 1000 rows | 19.8 ms per full row pass |
| `TranscriptParser.readableTranscript` (32 KB, 150 segments), run in every `TranscriptPanel` body | 3.8 ms |
| `WaveformAnalyzer.samples`: 28 s clip / 60 min 48 kHz stereo AAC | 8.9 ms / **1,882 ms** (cache is memory-only) |
| `RecordingConfidenceAnalyzer.analyze`, 60 min | 1,406 ms (streams 4,096-frame buffers; memory bounded) |
| `AVAudioPlayer` init + `prepareToPlay`, 60 min | 18 ms |
| Keychain miss (`SecItemCopyMatching`) | median 0.14 ms (first call 6.5 ms) |
| Export preview, markdown / srt | < 0.1 / 0.47 ms |

### Bundle (`dist/MSR Meeting Recorder.app`, 9.4 MB)

| Item | Size |
|---|---|
| `MacOS/MSRMeetingRecorder` (not stripped) | 7.85 MB: `__TEXT` 3.06 MB, `__LINKEDIT` 4.67 MB |
| Same, `strip` | **3.54 MB** |
| `-Osize` + `strip` | **2.88 MB** (`__text` 2.57 MB → 1.93 MB, −25 %) |
| `MSRMeetingRecorder.icns` | 1.9 MB, of which the 1024 px PNG is 1.15 MB |
| Resource bundle / duplicated `en.lproj` + `id.lproj` | 36 KB / 32 KB (`package_app.sh` copies the lproj folders twice) |
| DMG / zip | 4.37 MB / 3.94 MB |

`otool -L`: system frameworks and Swift overlays only. ZIPFoundation is statically linked (804 symbols, about 213 KB object text) for the DOCX writer only (TranscriptExporter.swift:238); MSRPresentation adds about 46 KB. No `-Osize`, no library evolution; SwiftPM dead-strips by default (link line not checked).

## 2. CodeGraph hot-path map

**`RecordingLibrary.loadRecordings`** (RecordingLibrary.swift:78) lists the folder twice (once for journal replay). It decodes every `*.json`, including segments files, which fail decoding three times: `readRecording` (:498), `readRecoveringBackup`, then `.bak`. It also does a `fileExists` and 2 symlink resolutions per item. Full loads per action, on main unless noted (VM = `AppViewModel`):

| Action | Full loads |
|---|---|
| Startup (`bootstrap` → VM `loadRecordings`, then `recoverInterruptedRecordings` → VM `loadRecordings`) | 2, plus 2 indexer passes |
| Stop recording (`finalizeRecordingSession` → `finishRecording` [`uniqueDisplayName` + `ensureRecordingIDAvailable`] → VM) | 3, plus 1 from the watcher |
| Rename (`onDiskRecording` → VM) / import (`uniqueDisplayName` → VM) | 2, plus 1 from the watcher |
| Transcript publish (`TranscriptPublisher.onDisk`, `renameIfTitleIsDefault`, `summarize` off main; then `performTranscriptionJob` + `applyPublishedTranscript` on main) | about 5 or 6, plus 1 from the watcher |
| Speaker rename/reset, delete, folder change | 1 or 2, plus 1 from the watcher |
| Transcript or summary autosave (`flushTranscriptEdits`) | 1 from the watcher, about 600 ms after every save |

Each VM load also re-reads all transcripts (indexer capacity 64 < N), runs a job `loadAll`, runs `refreshSetupHealth` (about 5 Keychain lookups), and republishes `recordings` (a full row pass). The watcher (600 ms debounce) fires on the app's own writes.

**Tick-driven work.** Every write below invalidates every view holding the model:

| Source | Rate | Writes per event |
|---|---|---|
| Mic meter (`MeetingAudioRecorder.startMetering`) | 80 ms timer | 2 main-actor Tasks writing 6 values (AppViewModel.swift:2921–2939); `inputLevel` and `waveform` are **never read by any view** |
| System audio (`SCStream` output) | one per sample buffer (~10 to 50 Hz) | same as the mic meter |
| Fake recorder | 100 ms | same, for each channel |
| Recording timer | 0.25 s | `recordingElapsed` |
| Playback timer | 0.25 s | `playbackPosition` and `playbackDuration` |
| `TimelineView(.animation)` overlays (NotesTab.swift:434/459) | 2.8 / 30 fps while queued or transcribing | local only; does not touch the model |
| Search | 300 ms debounce | filter runs detached; `filteredRecordingIDs` then triggers a full row pass |
| Settings `onChange` → `scheduleSettingsSave` | 600 ms debounce | `settings` changes on every keystroke |
| Window resize (`persistWindowSize`) | every resize event | `settings.window*` |

**SwiftUI invalidation.** 52 `@Published` properties on one `ObservableObject`, observed whole by `ContentView`, `RecordingBar`, `RecordingSidebar`, `TranscriptionQueueBlock`, `RecordingDetailView`, `NextStepActions`, `ReviewTab`, `ExportTab`, `NotesTab`, `TranscriptPanel`, `SummaryPanel`, `ReadyStateView`, `ReadinessChecklist`, `StatusBar` and 5 Settings tabs. **`MSRMeetingRecorderApp` holds it as `@StateObject`**, so commands and `MenuBarExtra` rebuild every tick; their `.disabled` reads `transcriptText.trimmingCharacters` and `canRunPrimaryAction`, which calls `job(for:)` and can hit the disk. Each tick, the sidebar recomputes `filteredRecordings` and `recordingSections` and evaluates **every** row (`rowBadges` does 2 stats, `jobChip` hits the disk), and `TranscriptPanel` re-parses the transcript (3.8 ms).

**`MSRPresentation`** is still write-only. `bindPresentationModels` (AppViewModel.swift:249) keeps 28 Combine `assign` pipelines; nothing reads `presentation`, and no test imports the module.

**Startup.** The window draws before `.task`. Then `bootstrap` runs on main: `microphones()`, hotkey, watcher, `loadRecordings` (with job `loadAll` and health), `loadTranscriptionJobs`, `refreshSetupHealth`, then `recoverInterruptedRecordings` and another `loadRecordings`. Indexing, waveform and confidence run off main; the cost lands in the layout passes that follow.

## 3. Ranked opportunities

| # | What | Evidence | Expected gain | Risk | Effort |
|---|---|---|---|---|---|
| 1 | Make `job(for:)` memory-only (`transcriptionJobs` already holds `loadAll()`); precompute row chips and badges per recording ID in `loadRecordings`; no disk access from view getters. | jobChip is 88 to 99 % of main samples; `loadAll` 15 ms × 1000 rows | Startup at N=1000 from 14 to 30 s to an estimated < 1.5 s; recording CPU at N=50 from 74 % to about 20 %; 1.6 GB peak gone | Low (the jobs list is already complete; keep `loadIfExists` for non-UI callers) | **S** |
| 2 | Move meters, elapsed, playback position and review waveform into small separate observables read only by `RecordingBar`/`ReviewTab`; drop the dead `inputLevel`/`waveform` writes and the duplicate level Task; keep the model out of the App scene. | N=0 recording is 18 % CPU for a 30 Hz meter; rows re-evaluated per tick | Recording or playback CPU of about 2 to 5 % regardless of N | Medium (view plumbing; UI walkthrough covers it) | M |
| 3 | Skip non-metadata JSON by name before decoding; keep an in-memory index updated by the library's own writes; ignore watcher events caused by own writes; reuse the index for name/ID checks in `finishRecording`/`rename`; move library I/O off main. | 260 → 120 ms from the name filter alone; finish 676 ms, rename 430 ms on main; 3 to 6 loads per action | Stop/rename/publish under 50 ms at N=1000; no duplicate reloads | Medium (durability semantics; journal replay must still run once at launch) | M |
| 4 | Search: index capacity ≥ N, or lazy/persisted. Store pre-folded lowercase text once. Hoist `DateFormatter`s. Do not hold full transcripts for every recording. | filter 117 to 843 ms; 33 MB of text; indexer re-reads ~all files per reload | Filter under 30 ms; −30 MB RSS at N=1000 | Low | S–M |
| 5 | Waveform: persist peaks per recording in a small sidecar or cache dir; decode mono at a low sample rate via `AVAssetReader` output settings; avoid the double copy (`Data` then `Array`). | 1.88 s per 60 min file on each first selection in a session | Under 50 ms for revisits; about 3× faster first decode (estimate) | Low | S |
| 6 | Cache `readModeTranscript` (keyed by transcript and segments) instead of re-parsing in `body`. | 3.8 ms per render of `TranscriptPanel` | Removes about 100 ms/s of CPU at 25 renders/s on the Notes tab | Low | S |
| 7 | Release flags and packaging: `-Osize` (via `unsafeFlags` or the packaging script), `strip`, no duplicate lproj copy, a lighter icon. | 7.85 → 2.88 MB binary; icns 1.9 MB | App about 9.4 → 4.5 MB (−50 %) | Low (`-Osize` was measured for size only, not speed) | S |
| 8 | Delete MSRPresentation and `bindPresentationModels`. | Write-only; 28 pipelines; 46 KB of text | Small CPU/size win; less code | Low | S |
| 9 | Drop the `swift-testing` 0.12 package dependency (Testing ships with the toolchain; Swift 6.3 CLT has `Testing.framework`). | Pulls in swift-syntax 600; the test build took 4 min of CPU | Faster test builds; app size unchanged | Low (CI toolchain must provide Testing) | S |
| 10 | Make ZIPFoundation optional: a tiny stored-ZIP writer for DOCX, or a separate target. | 213 KB of object text; used only by DOCX | About 0.1 to 0.2 MB | Low–Medium (DOCX correctness) | M |

### The ten candidates

1. Cache / filename filter: **confirmed**; the filter alone saves 54 %, and fewer loads per action matters more (#3).
2. Split state: **confirmed**; 18 % CPU with zero rows, and per-tick row passes multiply the jobChip bug (#2).
3. Lazy, off-main search: **partly**. It is already off main; the costs are the capacity-64 cache, per-query folding, 33 MB held, and the row pass on results (#4, #1).
4. Waveform/confidence off main: **refuted** (already off main and cancellable). Cost and caching: **confirmed**, 1.9 s and 1.4 s per hour; the cache is memory-only (#5).
5. MSRPresentation: **confirmed dead** (#8).
6. swift-testing redundant (#9); ZIPFoundation used only for DOCX (#10); `-Osize` + strip is the size lever (#7); library evolution is off (refuted).
7. Timers/`TimelineView`: **mostly refuted** as a direct cost; the harm is publishing on the shared model (#2).
8. Keychain: **refuted**, about 15 lookups at 0.14 ms each.
9. Startup ordering: **partly refuted**. The window already comes first; the block is main-thread I/O plus O(N²) row passes. Deferring recovery and health checks still saves an estimated 50 to 300 ms.
10. Bundle: **confirmed** (#7).

## 4. Suggested order

- **Phase 1, about one day:** #1 with precomputed badges, #6, #7, #8. Expect N=1000 cold start under about 1.5 s and recording CPU independent of N.
- **Phase 2 (structure):** #2, splitting the observable state and removing the App-level `@StateObject` dependency, and #3, the library cache, the name filter, no self-triggered watcher reloads, and off-main I/O.
- **Phase 3 (polish and footprint):** #4 (search memory and folding), #5 (persisted, cheaper waveform), #9, #10, icon optimization, and deferring recovery and health checks until after the first frame.

## Not measured

Playback CPU, real `SCStream`/microphone metering (the fake recorder was used), `TimelineView` overlays (need a running job), occluded-window behaviour, runtime speed under `-Osize`, and settings/resize jank (inferred from code).

## Phase 1 results

Measured 2026-10-21 on the same machine with the same harness (`harness.py`), libraries and fake recorder, `*_API_KEY` unset. "Before" is HEAD e0bff47 rebuilt and re-measured today. "After" is this branch's plain `swift build -c release` (-O, unstripped), so the comparison isolates the code changes. The packaged `-Osize` + `strip -x` binary was measured too and is within noise of "After" (cold start at N=1000 0.91 to 0.99 s, recording CPU 34 / 42 / 48 %), so `-Osize` costs no measurable speed here.

### App-level

| N | Cold start to snapshot (s), before → after | Busy CPU-s after launch | Peak footprint | Steady footprint | CPU while recording (fake recorder, 10 s) | RSS while recording |
|---|---|---|---|---|---|---|
| 50 | 1.22 / 0.69 / 0.75 → 1.16 / 0.61 / 0.64 | 0.68 → 0.50 | 127 → 115 MB (back-to-back rerun; one-off runs vary from 80 to 147 MB) | 77 → 65 MB | 77.8 → **36.4 %** | 140 → 129 MB |
| 300 | 4.66 / 3.96 / 3.89 → **0.77 / 0.70 / 0.76** | 5.6 → 0.64 | 522 → **123 MB** | 84 → 94 MB | 97.1 → **42.1 %** | 596 → 148 MB |
| 1000 | 20.1 / 13.2 / 16.6 → **1.07 / 1.01 / 0.94** | 16.0 (still 93 % busy 8 s after the snapshot) → **1.1** | 1.6 GB → **201 MB** | 133 → 132 MB | 100.7 % (recording starts 10.7 s after launch) → **47.0 %** (starts 0.8 s after launch) | 1.69 GB → 200 MB |

Idle CPU once settled is 0.0 to 0.2 % before and after. The 2 to 20 s startup stall and the 0.5 to 1.6 GB peaks are gone. Recording CPU is no longer pegged, but it still grows with N (36 → 47 %). A 4 s `sample` at N=1000 while recording shows no disk access left in the render path (`jobChip` + `rowBadges` are about 5 of 2,896 main-thread samples). The remainder is the per-tick sidebar pass: `recordingSections` (about 210 samples, mostly `Calendar.isDateInToday` over 1000 rows, three times) and SwiftUI `OutlineList` diffing and layout. Each meter tick still publishes on the shared model. This is opportunity #2 (Phase 2): split the meter/elapsed state into its own observable.

### Micro-benchmarks (release, median of 10; finish and rename are the median of 5 on a hard-link copy of `lib1000`)

| Operation | Before | After |
|---|---|---|
| `RecordingLibrary.loadRecordings()` N = 50 / 300 / 1000 | 14.2 / 83.1 / 325.6 ms | **8.7 / 49.6 / 175.3 ms** (−40 to −46 %) |
| `finishRecording`, N=1000 | 740 ms | **179 ms** (1 internal load instead of 2, each 46 % cheaper) |
| `rename`, N=1000 | 436 ms | **176 ms** (still 1 internal load; the name filter makes it cheaper) |
| `LibraryFolderSnapshot.capture`, N = 50 / 1000 (new: 265 / 5,300 entries) | — | 1.3 / 28.5 ms (dominated by per-file attribute reads; `getattrlistbulk` measured no faster) |
| Sidebar `rowBadges`, 1000 rows | 19.8 ms per pass (2,000 `stat`s) | dictionary lookups only |
| `job(for:)` per row without an in-memory job | up to 15.1 ms (`loadAll`) | dictionary lookup |
| Read-mode parse (`readableTranscript`, 32 KB) | 3.8 ms per `TranscriptPanel` render | once per transcript/segments change |

### Bundle

| Item | Before | After |
|---|---|---|
| `MSR Meeting Recorder.app` (`du`) | 9.4 MB | **3.4 MB** |
| `Contents/MacOS/MSRMeetingRecorder` | 7,853,280 B (-O, not stripped) | **3,007,936 B** (`-Osize`, `strip -x`; the unstripped -O build is 7,738,800 B without MSRPresentation) |
| `MSRMeetingRecorder.icns` | 1,895,707 B | **481,679 B** |
| Localizations | resource bundle (36 KB) + top-level `en.lproj`/`id.lproj` | top-level `en.lproj`/`id.lproj` only |
| App zip / DMG | 3,942,225 / 4,367,862 B | **1,779,173 / 2,223,302 B** |

A dSYM (`dist/MSRMeetingRecorder.dSYM`, same UUID as the shipped binary) is written next to the artifacts for symbolication; it is not part of the app, zip or DMG.

### What changed

1. **Render paths never touch the disk.**
   - `job(for:)` is memory-only, reading a `jobsByRecordingID` index that `transcriptionJobs.didSet` rebuilds. Only actions use the disk fallback, via `jobReadingDiskIfNeeded(for:)` and `hasPendingTranscriptionReadingDiskIfNeeded(for:)`: enqueue/retry, cancel, delete.
   - Sidebar badges come from `recordingRowFacts: [UUID: RecordingRowFacts]`, built once per load from the folder listing. `noteSidecarsChanged(for:)` updates the entry after the app writes a transcript or summary (autosave, Summarize, auto-summary).
   - The Read-mode transcript is cached (`readModeCache`) and cleared by `transcriptText`/`transcriptSegments` `didSet`.
   - The unread `inputLevel`/`waveform` properties are gone, and `onLevelUpdate` is no longer installed (one main-actor hop less per meter report). `TitleBadge` already read metadata only.
2. **`loadRecordings` cost and frequency.**
   - Segments sidecars (`<base>.transcript.segments.json` next to `<base>.json`) are skipped by name. Hidden job/session/journal JSON was already skipped by `.skipsHiddenFiles`. Orphan or lookalike files are still decoded and ignored as before.
   - `finishRecording` lists the library once for both the unique name and the duplicate-ID check.
   - The folder watcher takes a `LibraryFolderSnapshot` (name, size and mtime of every entry) off the main thread. It skips the reload when the snapshot equals the one kept from the last load, patched for the app's own writes (sidecars, job files, each with its `.bak`). External changes still reload. This replaces a "suppress until" timestamp, which could swallow an external change landing inside the window.
   - Launch skips the second full load when recovery found nothing and the folder is unchanged.
3. **Packaging.**
   - `-Xswiftc -Osize`, plus `strip -x` before codesigning.
   - Only the `*.lproj` folders are copied (once). `Bundle.main` serves them: verified by launching the packaged app with `-AppleLanguages (id)`, and the UI renders in Indonesian without the SwiftPM bundle.
   - The icon was rebuilt from the same artwork. Redundant 1x entries are dropped (16, 16@2x, 32@2x, 128, 128@2x, 256@2x, 512@2x remain), and the 512 and 1024 px images are 256-colour palette PNGs (median cut).
   - `MSRPresentation`, its product and `bindPresentationModels` are deleted.
4. **Kept:** the `swift-testing` package dependency. Without it, `swift test` on this machine (Command Line Tools only, Swift 6.3.3) fails with `no such module 'Testing'`: SwiftPM does not add the CLT `Testing.framework` search path. CI's Xcode 16.2 would likely be fine, but local runs would break.

### Deferred to Phase 2

- Split the meter/elapsed/playback state out of `AppViewModel`; this is the remaining N-dependent recording cost.
- An in-memory library index, and library I/O plus the snapshot capture off the main thread (about 28 ms per load at N=1000).
- Fewer full loads inside `TranscriptPublisher` and the speaker-reset loop (one load per speaker).
- Multi-file import still reloads once per file.

## Phase 2 results

Measured 2026-10-21 with the same harness, libraries and fake recorder, `*_API_KEY` unset, both binaries a plain `swift build -c release`. The machine was busy with other apps during this session (load average 5 to 15), and one uninterleaved run came out 3 to 8 times slower for *both* binaries. So "before" is the Phase 1 binary (this branch's base, 64d2c53) re-measured **interleaved** with the Phase 2 binary, one run each in turn, at load average 5 to 7.5. Absolute times are a little higher than in "Phase 1 results"; the comparison is like for like.

### App-level

| N | Cold start to snapshot, median (s), before → after | CPU while recording (fake recorder, 10 s, 2 runs) | RSS at end of recording window | Peak / steady footprint | Idle CPU once settled | CPU-s to settle after launch |
|---|---|---|---|---|---|---|
| 50 | 0.68 → 0.64 | 38.2 / 38.2 % → **10.0 / 7.1 %** | 115 / 123 → 118 / 96 MB | 152 / 61 → 154 / 63 MB | 0.2 → 0.0 % | 0.71 → 0.58 |
| 300 | 0.78 → 0.73 (8 runs each) | 47.0 / 45.9 % → **8.0 / 6.1 %** | 122 / 128 → 96 / 103 MB | 173 / 82 → 170 / 80 MB | 0.2 → 0.0 % | 0.77 → 0.73 |
| 1000 | 1.18 → 1.03 | 53.1 / 50.5 % → **6.7 / 6.9 %** | 137 / 138 → 97 / 98 MB | 167 / 101 → 164 / 101 MB | 0.4 → 0.0 % | 1.08 → 1.04 |

Recording CPU no longer depends on N and is under the 10 % target at N=1000. Cold start is unchanged or slightly better: the launch load now runs off the main actor, but the snapshot still waits for it. Peak and steady footprint are unchanged (the Phase 1 peak of about 200 MB at N=1000 measured on a quiet machine is in the same range; peaks vary from run to run). A 4 s `sample` at N=1000 while recording has **no** library frames on any thread: no `loadRecordings`, `LibraryFolderSnapshot`, `TranscriptionJobStore`, `recordingSections` or row code. About 3 % of main-thread samples are SwiftUI updating the meters.

### Body evaluations per second while recording

Counted with a temporary counter in each `body` (`MSR_RENDER_PROBE`, removed again), 5 s windows after the recording started:

| View | Before (N = 50 / 1000) | After (N = 50 / 300 / 1000) |
|---|---|---|
| `ContentView` | 13.6 / 13.4 | 0 / 0 / 0 |
| `RecordingSidebar` (recomputes `recordingSections`, diffs the list) | 13.6 / 13.4 | 0 / 0 / 0 |
| `RecordingDetailView` | 13.6 / 13.4 | 0 / 0 / 0 |
| `RecordingBar` | 13.6 / 13.4 | 0 / 0 / 0 |
| `RecordingRow` (skipped by SwiftUI's equality check before too) | 0 / 0 | 0 / 0 / 0 |
| `RecordingMeters` (new; the two source meters) | n/a | 24.8 / 24.2 / 24.2 |
| `RecordingTimerText` (new) | n/a | 13.8 / 13.6 / 13.6 |

With the split, the sidebar no longer re-renders on ticks, so no separate `LibraryState` observable was needed. The timer re-renders with the meters because both observe `RecordingLiveState` (one `Text`, negligible cost).

### What changed

1. **High-frequency state is out of `AppViewModel`** (LiveState.swift).
   - `RecordingLiveState` holds `microphoneLevel`, `systemLevel` and `recordingElapsed`. It publishes only real changes.
   - `PlaybackState` holds `isPlaying`, `playbackPosition`, `playbackDuration`, `reviewWaveform`, `trimStartSeconds` and `trimEndSeconds`. The playback timer writes only values that changed.
   - Both are owned by the model (`let live`, `let playback`) and written by the existing timers and callbacks. The model keeps forwarding properties (trim read/write), so `transcribeSelectedRange`, `saveTrimmedCopy` and the scripts compile unchanged.
   - Only these views observe them:
     - `RecordingMeters` and `RecordingTimerText` in `RecordingBar`.
     - `MiniRecordingIndicator` in `ContentView`.
     - `ReviewTab` (strip, waveform, trim sliders bound to `$playback`).
     - `PlayPauseCommand`, the Recording → Play/Pause menu item, which the scene would otherwise not refresh.
   - `UISnapshotCapture`, `UIScenarioRunner` and `UIWalkthrough` read none of the moved properties.
2. **Library I/O off the main actor.**
   - `refreshLibrary()` runs `LibraryLoader.performLoad` (folder snapshot, `loadRecordings`, row facts, job `loadAll`) on the `LibraryLoader` actor and publishes on the main actor. A generation counter drops a result when a newer load (sync or async) started meanwhile. A superseded caller waits for the newer load to finish. The newest caller continues in the same main-actor turn as the publish, so no frame shows the new list with an old workflow state (the walkthrough checks this on stop). Jobs read by a load are dropped when a job was saved in memory meanwhile.
   - Bootstrap, the folder watcher (dropped if a recording or busy state began meanwhile), recovery (its folder snapshot too), finalize, import, delete, publish, folder change and both Refresh buttons use it. `loadRecordings()` stays as the synchronous variant, for the scenario's final read and for tests.
   - **Stop recording:** `finishRecording`, the raw/segment file removal and the reload run off the main actor while the bar shows "Saving". The workflow stays `.finalizing` until the reload has published, then the recording is selected and auto-transcribe queues; the order is unchanged. `AudioTrackMixer`, `RecordingConfidenceAnalyzer` and recovery were already off main (nonisolated async).
   - **Rename** and **speaker rename/reset** keep the library call synchronous, so the result shows at once. The full reload after it is replaced by an in-memory patch: list, row facts, search document, selection, own-write snapshot entries, and a restarted index pass if one was running. A legacy recording that a rename moves to immutable storage still reloads, off main.
   - **Delete** removes the item from memory at once. Deleting its job files and the reload run off main.
   - **Import** copies each file off main and reloads once for the batch. The mutation policy is still checked per file.
   - **Jobs:** each save puts the job into `transcriptionJobs`, read back from its own file so dates match the store's encoding, in `loadAll` order. This replaces about 5 `loadAll` folder listings per transcription. The queue re-reads jobs off main before picking the next one.
   - **`TranscriptPublisher`:** every library step (migrate, transcript bundle write, clear/reset, re-reads, `renameIfTitleIsDefault`, the summary's check-then-write) runs off the main actor, in the same order. Two loads are gone: the re-read after `writeSummary`, and the re-read after `resetSpeakerNames` when replacing. A job now does 2 loads in `publish`, 2 in `summarize` and 1 refresh, all off main (before: about 6, mostly on main).
   - **`RecordingLibrary.resetAllSpeakerNames(for:)`** reads the library once. Before, it read once per speaker plus once for the reset.
   - **`LibraryIO`** (DurableFile.swift) is a process-wide recursive lock. Every `RecordingLibrary` and `TranscriptionJobStore` operation, `DurableFile.write` and `readRecoveringBackup` take it. `DurableFile.write` moves the primary to `.bak` before the new file lands. Without the lock, a load on another thread can find the primary missing, "recover" the stale backup over the new file, and quarantine it. A new test reproduces that: it fails 3 out of 3 with the lock disabled. The lock also keeps journal replay from running during an in-flight publish. A main-thread library call can now wait for a running background load: at most one load (about 175 ms at N=1000), no worse than when the load itself ran on main.
3. **Tests:** 172 → 179 (`LiveStateAndLoaderTests`, plus a `resetAllSpeakerNames` case). They cover:
   - ticks publish on `live` only;
   - stop publishes before it returns;
   - a stale async load is dropped;
   - batched import;
   - job upserts match `loadAll`;
   - the durable read/write race.

### Library loads per action, Phase 1 → Phase 2

| Action | Phase 1 | Phase 2 |
|---|---|---|
| Launch | 1 VM load on main (2 when recovery changed the folder) | same, off main |
| Stop recording | `finishRecording` (1 internal) + 1 VM load, on main | same, off main |
| Rename / speaker rename | 1 internal + 1 VM load, on main | 1 internal on main, patched in memory |
| Reset k speaker names | k + 1 internal + 1 VM load, on main | 1 internal on main, patched |
| Import m files | m internal + m VM loads, on main | m internal + 1 VM load, off main |
| Delete | job `loadAll` + 1 VM load, on main | off main |
| One transcription (auto-title + auto-summary) | about 6 loads, mostly on main, plus about 5 job `loadAll`s | 5 loads, off main; job checkpoints read one file |
| Folder watcher, external change | 1 VM load on main | 1, off main |

### Still on the main thread

These calls are rare, user-triggered and not tick-driven:
- the `rename`/`renameSpeaker` library call (1 full load, about 175 ms at N=1000);
- the journaled `delete` (no load);
- transcript/summary autosave writes, and reads of the saved file to compare;
- the selection's sidecar reads;
- `TranscriptPublisher.recoverIfPublished` (crash recovery only).

### Deferred

- An in-memory library index inside `RecordingLibrary`, so `rename`, `renameSpeaker`, `onDisk` and `uniqueDisplayName` need not decode every metadata file (175 ms at N=1000). This would also make rename fully cheap on main.
- The App scene still holds the model as `@StateObject`. Commands rebuild only on real model changes now (not on ticks), so this was left as is.
- Phase 3 items are unchanged: search memory and folding, persisted waveform peaks, `swift-testing`/ZIPFoundation, deferring health checks.

## Phase 3 results

Measured 2026-10-21 with the same harness, libraries and fake recorder, `*_API_KEY` unset. "Before" is the Phase 2 binary (86687d8), re-measured **interleaved** with the Phase 3 binary, one run each in turn, both a plain `swift build -c release`. Load average was 3.4 to 5.7. Micro-benchmarks came from a temporary swift-testing file (release, `-enable-testing`; now deleted), median of 7 unless noted. Phase 3 writes one `.waveform` sidecar per selected recording; the scratch libraries were cleaned before each A/B pass.

### App-level

| N | Cold start, median of 3 (s) | Steady footprint (2 to 3 runs) | Peak footprint | CPU-s to settle after launch | CPU while recording (2 runs) | RSS at end of recording |
|---|---|---|---|---|---|---|
| 50 | 0.59 → 0.58 | 80 → **79 MB** | 151 → 150 MB | 0.50 → 0.49 | 8.0 / 11.3 → 9.9 / 11.8 % | 131 → 132 MB |
| 300 | 0.64 → 0.67 | 96 → **90 MB** | 168 → 159 MB | 0.66 → 0.75 | 5.6 / 4.9 → 4.6 / 4.9 % | 148 → 142 MB |
| 1000 | 0.83 → 0.81 | 123 to 129 → **98 to 99 MB** | 191 to 196 → **170 MB** | 1.0 to 1.1 → 1.3 to 1.4 | 8.9 / 11.4 → 10.6 / 10.6 % | 192 → **168 MB** |

Idle CPU once settled is 0.0 to 0.2 % for both. Cold start and recording CPU are unchanged (the recording numbers are noisy on this busy machine for both binaries). The footprint drops by about 25 MB at N=1000: the live heap shrinks from 76.7 to 48.3 MB (`heap`: `Swift.StringStorage` 38.0 → 0.9 MB, replaced by 7.3 MB of `[UInt8]` index storage). The background indexing pass costs about 0.3 to 0.4 CPU-s more at launch at N=1000 (folding, sketches and LZFSE on 4 workers at utility priority); it is done well before the snapshot window ends.

### Micro-benchmarks

| Operation | Before | After |
|---|---|---|
| Search text held in memory, N=1000 | 33.4 MB (every transcript and summary as `String`) | **7.3 MB** in total: metadata 0.16 MB, sketches 0.54 MB, LZFSE text 6.6 MB (932 of 1000 documents cached, 31 MB folded) |
| Indexing pass, N=1000 | 276 ms cold, 82 ms warm (`documents(for:)`, re-reads all files) | 190 ms cold on 4 workers; 9 ms warm (a `stat` per sidecar, nothing re-read) |
| Query `budget` (matches all 1000) | 76 ms | **3.7 ms** to the first (in-memory) results, **7.6 ms** complete (61 uncached documents read) |
| Query `zzqx` (no match) | 572 ms | **0.2 ms** (every sketch rules it out; no reads) |
| Query `2026-10` (date, 71 hits) | 572 ms | **0.3 ms** (metadata only) |
| Query `speaker 2 budget` | 78 ms | 3.8 ms first, 8.0 ms complete |
| N = 300 / 50, any query above | n/a | ≤ 1.3 ms; everything cached (2.3 / 0.4 MB) |
| "Realistic" N=1000 (Zipf-distributed words from 8,000 dictionary words, 32 KB each; more n-grams, compresses 3.1×) | n/a | 7.3 MB resident (sketches 2.1 MB, 492 documents cached). No match: **0.2 ms**. Match-all: **3.3 ms** first, **22 ms** complete (457 documents read from disk) |
| `WaveformAnalyzer.samples`, 60 min 48 kHz stereo AAC | 1,723 / 1,757 ms (3,641 ms on a cold first run) | **322 ms** (8 parallel ranges; 1,470 ms on one thread); peaks equal to the old ones within 0.00013 |
| Same, recording just finished or imported | separate decode on first selection | **0 ms**: computed by the confidence pass |
| Waveform on revisit / later launch | analysis again (memory cache only) | **0.03 ms** (`.waveform` sidecar read) |
| `RecordingConfidenceAnalyzer`, 60 min | 1,310 to 1,396 ms | **291 ms**; peak 0.35539487, average 0.12105823 and duration 3600 s identical |
| `rename`, N=1000 (hard-link copy of `lib1000`) | 171 ms (one full load on main) | **5.8 ms** (index check: one folder `stat` and 1000 file `stat`s, one metadata read, durable write) |
| DOCX export (32 KB transcript) | 1.8 ms, 8,463 B (deflate) | 1.6 ms, 60,231 B (stored entries) |

### Bundle

| Item | Before | After |
|---|---|---|
| `Contents/MacOS/MSRMeetingRecorder` (`-Osize`, `strip -x`) | 3,075,088 B | **3,049,360 B** (−25.7 KB net, after adding the scanner, index and ZIP writer) |
| `MSR Meeting Recorder.app` (`du`) | 3,520 KB | 3,496 KB |
| App zip / DMG | 1,806,921 / 2,254,471 B | 1,790,459 / 2,243,772 B |
| Package dependencies | ZIPFoundation 0.9.20, swift-testing 0.12.0 | swift-testing 0.12.0 (test target only) |

The Phase 0 estimate of about 213 KB for ZIPFoundation was its object text; in the dead-stripped `-Osize` build only about 25 KB of it was linked. `otool -L` lists no zip library before or after (it was linked statically).

### What changed

1. **Search: folded, compressed, bounded, streamed.**
   - `SearchFolding` / `FoldBuffer` (RecordingSearch.swift:15, :45): lowercase, diacritics folded, whitespace collapsed, NFC UTF-8, once per document. ASCII is folded byte by byte; each non-ASCII run (plus the ASCII character before it, for combining marks) goes through Foundation's folding as before. The one deliberate difference is that ASCII `I` always folds to `i`, also in a Turkish locale; queries fold the same way.
   - `RecordingSearchDocument` (:167) holds `metadataText` and `contentText` bytes. Matching is `memmem` per token: metadata first, then the text, so a token never spans fields. Dates use 5 formatters made once (`SearchDateText`, :197) instead of one `DateFormatter` per document per query. `RecordingSearch.filter` keeps its semantics (all tokens, case- and diacritic-insensitive, name/source/date/duration/transcript/summary); its `calendar:` parameter is gone (the date text is computed when a document is made).
   - `SearchSketch` (:273): an exact set of the bytes present plus a one-hash Bloom filter of every 2- and 3-byte sequence. It is 160 B to 2 KB, folded in half while at most 30 % full. It can only rule tokens out.
   - `RecordingSearchIndexer` (RecordingSearchIndexer.swift:22) is rewritten.
     - It keeps metadata text and sketches resident for every recording.
     - Transcript + summary text is held LZFSE-compressed in an LRU cache. A byte budget (default 7 MB) covers metadata, sketches and text.
     - `update` (:95) mirrors the library without disk access. `indexContent` (:147) re-reads only files whose size or mtime changed, on 4 workers at utility priority. `refresh` (:123) re-reads one recording after the app writes its sidecars.
     - `search` (:171) decides from metadata, then sketches, then cached text (decompressed in parallel), and delivers those matches first. It then reads only uncached documents whose sketch allows a match, one worker per core (:567), in chunks of 256, delivering after each chunk. Cancellation stops it between chunks.
     - Text read by a query is cached only while it fits without evicting (:207, scan resistance). Indexing passes and `refresh` evict LRU. Files are read with `open`/`read` into per-worker reusable buffers (`LoadWorkspace`, :380), so a pass leaves one allocation per document. Before that change, transient buffers kept about 25 MB of freed heap in the footprint.
   - `AppViewModel` no longer holds search documents. `filteredRecordings` (AppViewModel.swift:481) maps the streamed IDs onto `recordings`. `scheduleRecordingSearch` (:863) bumps a generation, debounces 150 ms (was 300), and runs the query in a detached task that streams `Progress` through an `AsyncStream`; results of an older generation are dropped. An empty partial result is not published, so "no results" does not flash before disk-backed matches arrive. `startSearchIndexing` (:824) and `refreshSearchDocument` (:3134) feed the indexer.
2. **Waveform: one shared scanner, sidecar cache.**
   - `AudioLevelScanner` (AudioLevelScanner.swift:17) decodes with `AVAudioFile` into 32K-frame chunks, using vDSP clip, max-magnitude and sum-of-squares per channel, plus per-bucket peaks split at exact bucket boundaries. Files of 60 s or more (AAC/M4A/WAV/CAF/AIFF) are split into up to 8 frame ranges, each decoded by its own `AVAudioFile`, with sample-accurate seeks: the frame totals match exactly, and parallel and single-threaded buckets are bit-identical in the tests. Cancellation is checked per chunk.
   - **Why not `AVAssetReader` at 8 kHz mono, as planned:** measured on `long60.m4a`:
     - `AVAssetReader` at native rate took 1,748 ms, at 8 kHz 1,454 ms, and 8 kHz mono 1,441 ms. The AAC decoder still runs at 48 kHz.
     - 4 or 8 `AVAssetReader`s with time ranges took 2,026 / 2,063 ms: they do not run concurrently within a process (user time equalled wall time).
     - `AVAudioFile` was 1,275 ms on one thread and **297 ms** with 8 ranges.
     - A mono downmix also changes the peaks (0.497 vs 0.355 here), and the strip is not normalized.
   - `RecordingConfidenceAnalyzer` (RecordingConfidenceAnalyzer.swift:27, :94) now uses the same scanner. It decoded the same way (`AVAudioFile`, full rate, clipped peak/RMS), so its results are unchanged: identical on `long60.m4a`, and the existing tolerance tests pass. `analyzeWithWaveform` returns the 96 review peaks from the same decode.
   - `WaveformCacheFile` (WaveformCacheFile.swift) is binary: a 32-byte header (magic, version, bucket count, audio size, mtime in ns) plus `UInt16` peaks, 224 B for 96 buckets. A stale or foreign file reads as `nil`. It is written as a hidden temp file plus `rename`, with no `.bak`.
   - `RecordingItem.waveformURL` (RecordingModels.swift:194) is `<base>.waveform`. `RecordingLibraryServing` gains `loadWaveformCache` / `storeWaveformCache` (RecordingLibrary.swift:74/77, with default implementations at :81/:85, so test fakes compile). The library's own versions are at :670/:676. `ownedURLs` (:870) includes the file, so delete removes it and legacy migration moves it (tested).
   - Producers:
     - Finalize stores the peaks from the confidence pass after `finishRecording`, off main (AppViewModel.swift:1501, :1548).
     - Import stores them from its level check (:1075).
     - Selection reads the sidecar off main (`reviewWaveform(for:)`, :3077). On a miss it analyzes (cancellable), stores, and records the write as the app's own for the folder watcher.
3. **ZIPFoundation replaced.** `ZipArchiveWriter` (ZipArchiveWriter.swift) writes stored entries with local headers, a central directory, an end record, a table CRC-32 and UTF-8 names (flag bit 11). There is no ZIP64; it throws past 4 GiB. It rejects duplicate and `..` names. `TranscriptExporter.writeDOCX` (TranscriptExporter.swift:238) uses it and writes the file atomically. `Package.swift` and `Package.resolved` no longer list ZIPFoundation. `THIRD_PARTY_NOTICES.md` and the README are updated.
   - Verified with `unzip -t` ("No errors detected") and `textutil -convert txt -stdout`. The round trip includes `&`/`<>` escaping and non-ASCII text, and both checks are now tests.
   - Trade-off: stored entries make a DOCX about 7× larger (60 KB for a 32 KB transcript). If that matters, raw DEFLATE is available from the system Compression framework (`COMPRESSION_ZLIB` emits RFC 1951 data, which is ZIP method 8) without a dependency.
4. **Metadata index for rename and speaker rename.** `RecordingLibrary.loadRecordings` (RecordingLibrary.swift:99) now records a process-wide `MetadataIndex` (:995) per folder: the result, the folder's `stat`, and each metadata file's path and `stat` (device, inode, size, mtime and ctime in ns; `FileStamp`, :961), taken before the listing and before each read. It is shared by every `RecordingLibrary` on the folder (the app makes one per call), lives under `LibraryIO`, and is capped at 4 folders.
   - Who uses it:
     - `validIndex()` (:160) accepts the index only when the folder `stat` and every metadata file's `stat` are unchanged. That is a `stat` per file and no listing.
     - `onDiskRecording` (:690), used by rename, renameIfTitleIsDefault, renameSpeaker, resetSpeakerNames and resetAllSpeakerNames, takes the uniqueness list from a valid index and still re-reads the target's own metadata file.
     - `finishRecording` and `importRecording` use it via `currentRecordings()` (:152).
     - Otherwise every one of them falls back to a full load.
   - `indexedWrite` (:177) wraps each library write. When the index matched the folder just before the write, it patches the changed recordings and re-stamps them and the folder. Otherwise, or on any throw, it drops the index. Writes by other code (job files, sessions) or other processes change the folder `stat` and so invalidate it.
   - Journal replay: a journal is a new folder entry, so it always forces a full load, which replays it (tested with an interrupted delete). Duplicate IDs are excluded exactly as in a full load (tested via `finishRecording(recordingID:)`).
   - Residual window: an external change that lands *during* one of the library's own writes is absorbed into the patched stamp until the next full load. The folder watcher's reload rebuilds the index about 600 ms later.
5. **Tests:** 179 → 199 swift-testing tests, all passing 3 out of 3 runs. The `MSRTestRunner` suite passes, including `testRecordingSearch*` unchanged.
   - The two old indexer tests asserted the capacity-64 cache. They are replaced by 4 tests:
     - unchanged files are not re-read;
     - eviction, then lazy reload of an evicted document for a query, with no reads for ruled-out or metadata-only queries;
     - zero budget;
     - streaming order and cancellation.
   - `Phase3PerformanceTests.swift` covers:
     - folding, including decomposed accents, NBSP and expansion growth;
     - sketch soundness on 2,000 random substrings;
     - the waveform cache (round trip, stale, wrong bucket count, delete, migration);
     - parallel vs single scan;
     - confidence + waveform from one decode;
     - scan cancellation;
     - CRC-32 check value;
     - `unzip -t`;
     - the DOCX `textutil` round trip;
     - the metadata index (patched renames, in-place external edit, external add, journal replay, duplicate ID, deleted recording, speaker rename).
   - `scripts/ui_walkthrough.sh`: 18 + 2 steps passed (one real ElevenLabs transcription).

### Deferred

- `finishRecording` at N=1000 with the index was not re-measured. The index replaces its full load when the index is current. After a recording session, though, the session manifests have changed the folder, so the load usually still happens (off main).
- The DOCX container could use raw DEFLATE from the Compression framework (see above).
- With high-diversity text the sketches take 2 KB per long transcript, so at N=1000 about half the text fits the 7 MB budget, and match-all queries read about 450 files (22 ms, streamed after a 3 ms first batch). Raising `defaultByteBudget` trades memory for that.
- Deferring the health checks until after the first frame (from the Phase 3 list) was not done; cold start is already 0.6 to 0.8 s.
- The App scene still holds the model as `@StateObject` (unchanged from Phase 2).

## Overall

Baseline is main @ b80f405 ("Measurements" above); Phase 3 is this branch, measured in this session.

| Metric (N=1000 unless noted) | Baseline | Phase 3 |
|---|---|---|
| Cold start to snapshot | 14.2 to 16.7 s | **0.81 s** |
| Cold start, N=300 / N=50 | 3.7 / 0.67 s | 0.67 / 0.58 s |
| CPU while recording (fake recorder) | 100 % (main thread pegged) | 5 to 11 % (independent of N) |
| Peak footprint | 1.6 GB | **170 MB** |
| Steady footprint | 133 MB | **99 MB** |
| `rename` | ≈430 ms on main | **5.8 ms** |
| `finishRecording` | 676 ms on main | 179 ms (Phase 1), off main since Phase 2 |
| Search filter, match / no match | 117 / 843 ms | **7.6 / 0.2 ms** (first results 3.7 ms) |
| Search text held in memory | 33.4 MB | **7.3 MB** (bounded) |
| Waveform, 60 min file: first view / revisit | 1,882 ms / memory cache only | **322 ms** (0 for new recordings) / **0.03 ms** from disk |
| Confidence analysis, 60 min | 1,406 ms | **291 ms** |
| App bundle / binary | 9.4 MB / 7.85 MB | **3.4 MB / 3.05 MB** |
| App zip / DMG | 3.94 / 4.37 MB | **1.79 / 2.24 MB** |
| Runtime dependencies | ZIPFoundation | none |
