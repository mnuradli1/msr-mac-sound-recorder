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
