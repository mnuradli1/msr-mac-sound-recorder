import AppKit
import Foundation
import MSRCore
import MSRServices

/// Scripted in-app scenarios for development and end-to-end checks, driven by
/// environment variables. Call `runIfRequested(viewModel:)` after `bootstrap()`
/// and before `UISnapshotCapture.runIfRequested()`.
///
/// - `MSR_UI_SCENARIO`: the scenario to run. Supported: `auto-transcribe`,
///   `soak` (long-recording soak, see `runSoak`), `quit-while-recording`
///   (see `runQuitWhileRecording`), `ui-walkthrough` and
///   `ui-walkthrough-empty` (accessibility-driven UI walkthrough, see `UIWalkthrough`).
/// - `MSR_UI_SCENARIO_SECONDS`: how long to record (default 3).
/// - `MSR_UI_SCENARIO_TIMEOUT`: how long to wait for the transcription job (default 180).
///
/// `auto-transcribe` also switches auto-summarize on (in memory); it only runs
/// with an OpenAI or DeepSeek key, and the result line's `summary` object says
/// whether it was requested, how many characters were written, by which
/// provider, and any error (a requested summary that failed fails the run).
///
/// Pair it with `MSR_FAKE_RECORDER_CLIP=/path/clip.m4a` (no microphone needed)
/// and `MSR_RECORDINGS_FOLDER=/tmp/somewhere` (keeps the user's library clean).
/// The scenario prints one JSON line to stderr, then exits with 0 (ok) or 1,
/// unless `MSR_UI_SNAPSHOT_PATH` is set, in which case it returns so the
/// snapshot hook can capture the resulting UI (and terminate the app).
/// Settings changed by a scenario stay in memory and are never persisted.
@MainActor
enum UIScenarioRunner {
    static func runIfRequested(viewModel: AppViewModel) async {
        let environment = ProcessInfo.processInfo.environment
        guard let scenario = environment["MSR_UI_SCENARIO"], !scenario.isEmpty else { return }
        switch scenario {
        case "auto-transcribe":
            await runAutoTranscribe(viewModel: viewModel, environment: environment)
        case "soak":
            await runSoak(viewModel: viewModel, environment: environment)
        case "quit-while-recording":
            await runQuitWhileRecording(viewModel: viewModel, environment: environment)
        case "ui-walkthrough":
            await UIWalkthrough.run(viewModel: viewModel)
        case "ui-walkthrough-empty":
            await UIWalkthrough.runEmpty(viewModel: viewModel)
        default:
            emit(["ok": false, "reason": "unknown scenario \(scenario)"])
            exit(2)
        }
    }

    private static func runAutoTranscribe(viewModel: AppViewModel, environment: [String: String]) async {
        viewModel.settingsPersistenceSuspended = true
        viewModel.settings.autoTranscribe = true
        viewModel.settings.autoTitle = true
        // Takes effect only with an OpenAI or DeepSeek key (`autoSummarizeIsEffective`).
        viewModel.settings.autoSummarize = true

        guard viewModel.credentialAvailable(for: viewModel.settings.provider) else {
            emit(["ok": false, "reason": "no credential"])
            exit(2)
        }

        let recordSeconds = Double(environment["MSR_UI_SCENARIO_SECONDS"] ?? "") ?? 3
        let timeout = Double(environment["MSR_UI_SCENARIO_TIMEOUT"] ?? "") ?? 180

        let existingIDs = Set(viewModel.recordings.map(\.id))
        await viewModel.toggleRecording()
        guard viewModel.isRecording else {
            finish(Report(error: "recording did not start: \(viewModel.statusMessage)"))
            return
        }
        try? await Task.sleep(for: .seconds(recordSeconds))
        await viewModel.toggleRecording()

        guard viewModel.workflowErrorMessage == nil,
              let recording = viewModel.recordings.first(where: { !existingIDs.contains($0.id) }) else {
            finish(Report(error: "recording was not saved: \(viewModel.statusMessage)"))
            return
        }
        var report = Report(recordingID: recording.id.uuidString, titleBefore: recording.displayName)

        let deadline = Date().addingTimeInterval(timeout)
        var job = latestJob(for: recording.id, in: viewModel)
        if job == nil {
            report.error = "no transcription job was queued: \(viewModel.statusMessage)"
            finish(report, viewModel: viewModel, recordingID: recording.id)
            return
        }
        while Date() < deadline {
            job = latestJob(for: recording.id, in: viewModel)
            if let status = job?.status, [.completed, .failed, .cancelled].contains(status) { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        // The title (and summary) are applied right after the job is checkpointed
        // as completed; give the publisher a moment to finish before reading the final state.
        try? await Task.sleep(for: .milliseconds(500))
        job = latestJob(for: recording.id, in: viewModel)
        report.summaryRequested = job?.autoSummarizeRequested ?? false
        if report.summaryRequested, job?.status == .completed {
            while Date() < deadline, viewModel.autoSummaryOutcomes[recording.id] == nil {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if let outcome = viewModel.autoSummaryOutcomes[recording.id] {
                report.summaryProvider = outcome.provider?.displayName
                report.summaryError = outcome.error
            } else {
                report.summaryError = "no auto-summary outcome after \(Int(timeout)) s"
            }
        }

        report.jobStatus = job?.status.rawValue
        report.jobOrigin = job?.origin.rawValue
        if let job {
            switch job.status {
            case .completed:
                break
            case .failed, .cancelled:
                report.error = job.errorMessage ?? "job ended as \(job.status.rawValue)"
            case .queued, .running:
                report.error = "timed out after \(Int(timeout)) s"
            }
        } else {
            report.error = "job disappeared"
        }
        finish(report, viewModel: viewModel, recordingID: recording.id)
    }

    private static func latestJob(for recordingID: UUID, in viewModel: AppViewModel) -> TranscriptionJob? {
        viewModel.transcriptionJobs
            .filter { $0.recordingID == recordingID }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private static func finish(_ report: Report, viewModel: AppViewModel? = nil, recordingID: UUID? = nil) {
        var report = report
        if let viewModel, let recordingID {
            viewModel.loadRecordings()
            if let recording = viewModel.recordings.first(where: { $0.id == recordingID }) {
                report.titleAfter = recording.displayName
                report.titleSource = recording.effectiveTitleSource.rawValue
                let transcript = (try? String(contentsOf: recording.transcriptURL, encoding: .utf8)) ?? ""
                report.transcriptCharacters = transcript.trimmingCharacters(in: .whitespacesAndNewlines).count
                let summary = (try? String(contentsOf: recording.summaryURL, encoding: .utf8)) ?? ""
                report.summaryCharacters = summary.trimmingCharacters(in: .whitespacesAndNewlines).count
            }
        }
        // A requested summary must have been written; it never fails the job itself.
        let summaryOK = !report.summaryRequested || (report.summaryError == nil && report.summaryCharacters > 0)
        report.ok = report.error == nil && report.jobStatus == TranscriptionJobStatus.completed.rawValue
            && report.transcriptCharacters > 0 && summaryOK
        if report.ok == false, report.error == nil {
            report.error = report.transcriptCharacters == 0 ? "transcript is empty" : "auto-summary failed: \(report.summaryError ?? "empty summary")"
        }
        emit(report.dictionary)
        if ProcessInfo.processInfo.environment["MSR_UI_SNAPSHOT_PATH"]?.isEmpty == false {
            return
        }
        exit(report.ok ? 0 : 1)
    }

    fileprivate static func emitLine(_ pairs: KeyValuePairs<String, Any>) {
        FileHandle.standardError.write(Data((jsonLiteral(pairs) + "\n").utf8))
    }

    private static func emit(_ object: [String: Any]) {
        let keys = ["ok", "reason", "recordingID", "titleBefore", "titleAfter", "titleSource",
                    "jobStatus", "jobOrigin", "transcriptCharacters", "summary", "error"]
        let parts = keys.compactMap { key -> String? in
            guard let value = object[key] else { return nil }
            return "\"\(key)\":\(jsonLiteral(value))"
        }
        FileHandle.standardError.write(Data(("{" + parts.joined(separator: ",") + "}\n").utf8))
    }

    private static func jsonLiteral(_ value: Any) -> String {
        switch value {
        case is NSNull:
            return "null"
        case let bool as Bool:
            return bool ? "true" : "false"
        case let int as Int:
            return String(int)
        case let double as Double:
            return double.isFinite ? String(format: "%.1f", double) : "null"
        case let pairs as KeyValuePairs<String, Any>:
            return "{" + pairs.map { "\"\($0.key)\":\(jsonLiteral($0.value))" }.joined(separator: ",") + "}"
        case let string as String:
            let data = (try? JSONSerialization.data(withJSONObject: [string], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
            let array = String(decoding: data, as: UTF8.self)
            return String(array.dropFirst().dropLast())
        default:
            return "null"
        }
    }

    private struct Report {
        var ok = false
        var recordingID: String?
        var titleBefore: String?
        var titleAfter: String?
        var titleSource: String?
        var jobStatus: String?
        var jobOrigin: String?
        var transcriptCharacters = 0
        var summaryRequested = false
        var summaryCharacters = 0
        var summaryProvider: String?
        var summaryError: String?
        var error: String?

        var dictionary: [String: Any] {
            [
                "ok": ok,
                "recordingID": recordingID ?? NSNull(),
                "titleBefore": titleBefore ?? NSNull(),
                "titleAfter": titleAfter ?? NSNull(),
                "titleSource": titleSource ?? NSNull(),
                "jobStatus": jobStatus ?? NSNull(),
                "jobOrigin": jobOrigin ?? NSNull(),
                "transcriptCharacters": transcriptCharacters,
                "summary": [
                    "requested": summaryRequested,
                    "characters": summaryCharacters,
                    "provider": summaryProvider ?? NSNull(),
                    "error": summaryError ?? NSNull()
                ] as KeyValuePairs<String, Any>,
                "error": error ?? NSNull()
            ]
        }
    }
}

// MARK: - Quit while recording

extension UIScenarioRunner {
    /// `MSR_UI_SCENARIO=quit-while-recording`: starts a recording, records for
    /// `MSR_UI_SCENARIO_SECONDS` (default 3), then quits through
    /// `MSRApplicationDelegate.requestTermination()` like the quick recorder's Quit.
    /// `applicationShouldTerminate` must save the session before the process
    /// exits; the caller then checks that the library holds one more
    /// recording and no `.in-progress-*` file. Prints
    /// `{"quit":"requested",…}` before quitting (exit status 0 from AppKit) or
    /// `{"quit":"error",…}` and exits 1.
    static func runQuitWhileRecording(viewModel: AppViewModel, environment: [String: String]) async {
        viewModel.settingsPersistenceSuspended = true
        viewModel.settings.autoTranscribe = false
        viewModel.settings.autoTitle = false
        viewModel.settings.autoSummarize = false
        let recordSeconds = Double(environment["MSR_UI_SCENARIO_SECONDS"] ?? "") ?? 3
        let before = viewModel.recordings.count
        await viewModel.startRecording()
        guard viewModel.isRecording else {
            emitLine(["quit": "error", "reason": "recording did not start: \(viewModel.statusMessage)"])
            exit(1)
        }
        try? await Task.sleep(for: .seconds(recordSeconds))
        emitLine([
            "quit": "requested", "recordingsBefore": before,
            "needsFinalize": viewModel.needsFinalizeBeforeQuit
        ])
        MSRApplicationDelegate.requestTermination()
    }
}

// MARK: - Soak

/// `MSR_UI_SCENARIO=soak`: repeated record → (pause → resume) → save cycles
/// with memory and temporary-file tracking, for long-running checks of the
/// capture/save/transcription pipeline. Run it with `scripts/soak_test.sh`.
///
/// - `MSR_SOAK_CYCLES` (default 6), `MSR_SOAK_RECORD_SECONDS` (default 60):
///   cycles and active recording time per cycle.
/// - `MSR_SOAK_PAUSE=1`: pause for 3 s halfway through and resume.
/// - `MSR_SOAK_SLEEP=1`: include sleep cycles. Odd cycles then save through
///   the system-sleep path the `SystemSleepCoordinator` drives
///   (`suspendForSystemSleep()`, which saves the active session), wait 2 s,
///   then run the wake path (`resumeAfterSystemWake()`, which runs
///   interrupted-recording recovery and must not duplicate the save); even
///   cycles save with a plain `stopRecording()`. Without it every cycle stops.
/// - `MSR_SOAK_AUTO_TRANSCRIBE=1`: auto-transcribe + auto-title each recording
///   and wait for the job (needs the provider's key exported); default off.
/// - `MSR_SOAK_MAX_GROWTH_MB` (default 60): allowed growth of the memory
///   footprint (`phys_footprint`) from the first to the last cycle; judged
///   only with 3 or more cycles.
/// - `MSR_UI_SCENARIO_TIMEOUT` (default 180): per-cycle transcription wait.
///
/// One JSON line per cycle goes to stderr, then a `{"soak":"done",…}` summary;
/// the process exits 1 if any cycle failed, temporary files remain, the
/// library did not grow by exactly one recording and a constant number of
/// files per cycle, or memory grew beyond the limit. Use with
/// `MSR_FAKE_RECORDER_CLIP` and `MSR_RECORDINGS_FOLDER`; settings are never
/// persisted.
extension UIScenarioRunner {
    fileprivate struct SoakOptions {
        var cycles: Int
        var recordSeconds: Double
        var pause: Bool
        var sleep: Bool
        var transcribe: Bool
        var maxGrowthMB: Double
        var timeout: Double

        init(_ environment: [String: String]) {
            cycles = max(1, Int(environment["MSR_SOAK_CYCLES"] ?? "") ?? 6)
            recordSeconds = max(1, Double(environment["MSR_SOAK_RECORD_SECONDS"] ?? "") ?? 60)
            pause = environment["MSR_SOAK_PAUSE"] == "1"
            sleep = environment["MSR_SOAK_SLEEP"] == "1"
            transcribe = environment["MSR_SOAK_AUTO_TRANSCRIBE"] == "1"
            maxGrowthMB = Double(environment["MSR_SOAK_MAX_GROWTH_MB"] ?? "") ?? 60
            timeout = Double(environment["MSR_UI_SCENARIO_TIMEOUT"] ?? "") ?? 180
        }
    }

    fileprivate struct SoakCycle {
        /// "sleep" (sleep-save + wake) or "stop" (plain `stopRecording()`).
        var path = "stop"
        var error: String?
        var recordingID: UUID?
        var jobStatus: String?
        var transcriptCharacters = 0
    }

    static func runSoak(viewModel: AppViewModel, environment: [String: String]) async {
        let options = SoakOptions(environment)
        viewModel.settingsPersistenceSuspended = true
        viewModel.settings.autoTranscribe = options.transcribe
        viewModel.settings.autoTitle = options.transcribe
        viewModel.settings.autoSummarize = false
        if options.transcribe {
            let provider = viewModel.settings.provider
            let variable = provider == .openAI ? "OPENAI_API_KEY" : "ELEVENLABS_API_KEY"
            guard environment[variable]?.isEmpty == false, viewModel.credentialAvailable(for: provider) else {
                emitLine(["soak": "error", "reason": "MSR_SOAK_AUTO_TRANSCRIBE=1 needs \(variable) exported"])
                exit(2)
            }
        }

        let startedAt = Date()
        let baseline = memoryMegabytes()
        let folder = viewModel.recordingsFolderURL
        let startRecordings = viewModel.recordings.count
        emitLine([
            "soak": "start", "cycles": options.cycles, "recordSeconds": options.recordSeconds,
            "pause": options.pause, "sleep": options.sleep, "transcribe": options.transcribe,
            "rssBaselineMB": baseline.resident, "footprintBaselineMB": baseline.footprint,
            "recordings": startRecordings
        ])
        var footprints: [Double] = []
        var residents: [Double] = []
        var fileDeltas: [Int] = []
        var fileCount = soakLibraryFileCount(folder)
        var failures = 0
        for index in 1...options.cycles {
            let cycleStart = Date()
            // With sleep cycles included, odd cycles save through sleep, even ones through Stop.
            let useSleep = options.sleep && index % 2 == 1
            let cycle = await soakCycle(viewModel: viewModel, options: options, useSleep: useSleep)
            // Let deferred cleanup (upload bodies, job checkpoints) settle before sampling.
            try? await Task.sleep(for: .seconds(1))
            let memory = memoryMegabytes()
            footprints.append(memory.footprint)
            residents.append(memory.resident)
            let files = soakLibraryFileCount(folder)
            fileDeltas.append(files - fileCount)
            fileCount = files
            let leftovers = soakLeftovers(folder: folder, since: startedAt).count
            if cycle.error != nil { failures += 1 }
            emitLine([
                "soak": "cycle", "cycle": index, "path": cycle.path, "ok": cycle.error == nil,
                "recordingID": cycle.recordingID?.uuidString ?? NSNull(),
                "jobStatus": cycle.jobStatus ?? NSNull(),
                "transcriptCharacters": cycle.transcriptCharacters,
                "seconds": Date().timeIntervalSince(cycleStart),
                "rssMB": memory.resident, "footprintMB": memory.footprint,
                "libraryFiles": files, "libraryFilesAdded": fileDeltas[fileDeltas.count - 1],
                "recordings": viewModel.recordings.count,
                "leftoverFiles": leftovers,
                "error": cycle.error ?? NSNull()
            ])
        }

        try? await Task.sleep(for: .seconds(2))
        let remaining = soakLeftovers(folder: folder, since: startedAt)
        let first = footprints.first ?? baseline.footprint
        let last = footprints.last ?? baseline.footprint
        let peak = footprints.max() ?? baseline.footprint
        let growth = last - first
        let canJudgeGrowth = options.cycles >= 3
        var reasons: [String] = []
        if failures > 0 { reasons.append("\(failures) cycle(s) failed") }
        if !remaining.isEmpty { reasons.append("leftover files: " + remaining.prefix(5).joined(separator: ", ")) }
        let expectedRecordings = startRecordings + options.cycles
        if viewModel.recordings.count != expectedRecordings {
            reasons.append("\(viewModel.recordings.count) recordings, expected \(expectedRecordings)")
        }
        if let mismatch = soakFileDeltaMismatch(fileDeltas) { reasons.append(mismatch) }
        if canJudgeGrowth, growth > options.maxGrowthMB {
            reasons.append("memory footprint grew \(Int(growth)) MB (limit \(Int(options.maxGrowthMB)))")
        }
        let note: Any = canJudgeGrowth
            ? NSNull()
            : "fewer than 3 cycles: memory growth not judged (ok reflects failures, files and recordings only)"
        let minutes: Double = Date().timeIntervalSince(startedAt) / 60
        emitLine([
            "soak": "done", "cycles": options.cycles,
            "footprintStartMB": first, "footprintEndMB": last, "footprintPeakMB": peak,
            "rssStartMB": residents.first ?? baseline.resident, "rssEndMB": residents.last ?? baseline.resident,
            "rssPeakMB": residents.max() ?? baseline.resident,
            "recordings": viewModel.recordings.count, "expectedRecordings": expectedRecordings,
            "libraryFilesAddedPerCycle": fileDeltas.map(String.init).joined(separator: ","),
            "leftoverFiles": remaining.count, "failures": failures,
            "minutes": minutes, "ok": reasons.isEmpty,
            "note": note,
            "reason": reasons.isEmpty ? NSNull() : reasons.joined(separator: "; ")
        ])
        exit(reasons.isEmpty ? 0 : 1)
    }

    /// Every cycle must add the same number of library files as cycle 1
    /// (audio + sidecars; more with transcription), ±1 for caches written
    /// lazily. Returns why not, or `nil`.
    static func soakFileDeltaMismatch(_ deltas: [Int]) -> String? {
        guard let expected = deltas.first else { return nil }
        guard expected > 0 else { return "cycle 1 added \(expected) library files" }
        let off = deltas.enumerated().filter { abs($0.element - expected) > 1 }
        guard !off.isEmpty else { return nil }
        let list = off.prefix(5).map { "cycle \($0.offset + 1): \($0.element)" }.joined(separator: ", ")
        return "library files per cycle differ from cycle 1 (\(expected)): " + list
    }

    private static func soakCycle(viewModel: AppViewModel, options: SoakOptions, useSleep: Bool) async -> SoakCycle {
        var cycle = SoakCycle()
        cycle.path = useSleep ? "sleep" : "stop"
        let existingIDs = Set(viewModel.recordings.map(\.id))
        await viewModel.startRecording()
        guard viewModel.isRecording else {
            cycle.error = "recording did not start: \(viewModel.statusMessage)"
            return cycle
        }
        if options.pause {
            try? await Task.sleep(for: .seconds(options.recordSeconds / 2))
            await viewModel.pauseRecording()
            guard viewModel.workflowState.isPaused else {
                cycle.error = "pause failed: \(viewModel.statusMessage)"
                return await abandon(cycle, viewModel: viewModel)
            }
            try? await Task.sleep(for: .seconds(3))
            await viewModel.toggleRecording()
            guard viewModel.isRecording else {
                cycle.error = "resume failed: \(viewModel.statusMessage)"
                return await abandon(cycle, viewModel: viewModel)
            }
            try? await Task.sleep(for: .seconds(options.recordSeconds / 2))
        } else {
            try? await Task.sleep(for: .seconds(options.recordSeconds))
        }
        if useSleep {
            await viewModel.suspendForSystemSleep()
            guard viewModel.workflowState == .saved else {
                cycle.error = "sleep did not save the session: \(viewModel.statusMessage)"
                return await abandon(cycle, viewModel: viewModel)
            }
            let savedBySleep = viewModel.recordings.filter { !existingIDs.contains($0.id) }.count
            try? await Task.sleep(for: .seconds(2))
            await viewModel.resumeAfterSystemWake()
            if savedBySleep != 1 {
                cycle.error = "sleep save added \(savedBySleep) recordings, expected 1"
                return cycle
            }
        } else {
            await viewModel.stopRecording()
            guard viewModel.workflowState == .saved else {
                cycle.error = "stop did not save the session (\(viewModel.workflowState)): \(viewModel.statusMessage)"
                return await abandon(cycle, viewModel: viewModel)
            }
        }
        if viewModel.isRecording || viewModel.workflowState.isPaused {
            cycle.error = "session still active after the \(cycle.path) save"
            return await abandon(cycle, viewModel: viewModel)
        }
        if let message = viewModel.workflowErrorMessage {
            cycle.error = "save failed: \(message)"
            return cycle
        }
        let added = viewModel.recordings.filter { !existingIDs.contains($0.id) }
        guard added.count == 1, let recording = added.first else {
            cycle.error = "expected 1 new recording via \(cycle.path), found \(added.count): \(viewModel.statusMessage)"
            return cycle
        }
        cycle.recordingID = recording.id
        if options.transcribe {
            await waitForSoakJob(&cycle, recording: recording, viewModel: viewModel, timeout: options.timeout)
        }
        return cycle
    }

    private static func waitForSoakJob(_ cycle: inout SoakCycle, recording: RecordingItem, viewModel: AppViewModel, timeout: Double) async {
        let deadline = Date().addingTimeInterval(timeout)
        var job = latestSoakJob(for: recording.id, in: viewModel)
        while Date() < deadline {
            job = latestSoakJob(for: recording.id, in: viewModel)
            if let status = job?.status, [.completed, .failed, .cancelled].contains(status) { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        // The title is applied right after the job is checkpointed as completed.
        try? await Task.sleep(for: .milliseconds(750))
        job = latestSoakJob(for: recording.id, in: viewModel)
        cycle.jobStatus = job?.status.rawValue
        let transcript = (try? String(contentsOf: recording.transcriptURL, encoding: .utf8)) ?? ""
        cycle.transcriptCharacters = transcript.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard let job else {
            cycle.error = "no transcription job was queued"
            return
        }
        if job.status != .completed {
            cycle.error = job.errorMessage ?? "job ended as \(job.status.rawValue)"
        } else if cycle.transcriptCharacters == 0 {
            cycle.error = "transcript is empty"
        }
    }

    private static func latestSoakJob(for recordingID: UUID, in viewModel: AppViewModel) -> TranscriptionJob? {
        viewModel.transcriptionJobs
            .filter { $0.recordingID == recordingID }
            .max { $0.updatedAt < $1.updatedAt }
    }

    /// Stops whatever is left of a failed cycle so the next one starts clean.
    private static func abandon(_ cycle: SoakCycle, viewModel: AppViewModel) async -> SoakCycle {
        if viewModel.isRecording || viewModel.workflowState.isPaused {
            await viewModel.stopRecording()
        }
        return cycle
    }

    /// Resident set size (`mach_task_basic_info.resident_size`) in MiB.
    static func residentMegabytes() -> Double {
        var info = mach_task_basic_info()
        let wordSize = MemoryLayout<natural_t>.size
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / wordSize)
        // `mach_task_self_` is a global var that Swift 6.0's strict concurrency
        // rejects; the trap returns the same port without touching shared state.
        let task: mach_port_t = task_self_trap()
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(task, task_flavor_t(MACH_TASK_BASIC_INFO), raw, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576
    }

    /// Memory footprint (`task_vm_info.phys_footprint`, what Activity Monitor
    /// shows as Memory) in MiB. Unlike the resident size it counts compressed
    /// and swapped dirty memory and not clean file-backed pages, so it is the
    /// figure the soak's growth check uses.
    static func footprintMegabytes() -> Double {
        var info = task_vm_info_data_t()
        let wordSize = MemoryLayout<natural_t>.size
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / wordSize)
        let task: mach_port_t = task_self_trap()
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(task, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    static func memoryMegabytes() -> (resident: Double, footprint: Double) {
        (residentMegabytes(), footprintMegabytes())
    }

    /// Regular files in the library folder (recursively, hidden files included).
    private static func soakLibraryFileCount(_ folder: URL) -> Int {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: Set(keys)))?.isRegularFile == true { count += 1 }
        }
        return count
    }

    /// Capture/finalize temporaries and session manifests left in the library,
    /// files moved aside into `recovery-failed/` or `.corrupt/` folders and
    /// atomic-write temporaries (`.<name>.<uuid>.tmp`) anywhere in it, plus
    /// upload/prepare temporaries in the process temp directory and `/tmp`
    /// (only those modified since the soak started, so other processes' files
    /// are not counted; `/tmp` and `/private/tmp` are scanned once).
    static func soakLeftovers(folder: URL, since start: Date) -> [String] {
        let libraryPrefixes = [".in-progress-", ".final-"]
        var found: [String] = []
        let fileManager = FileManager.default
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let isTemporary = libraryPrefixes.contains { name.hasPrefix($0) }
            if isTemporary || RecordingSessionManifestStore.isManifestFileName(name) { found.append(name) }
        }
        found += soakSetAsideFiles(in: folder)
        let candidates = [fileManager.temporaryDirectory.path, "/tmp", "/private/tmp"]
        let temporaryFolders = Set(candidates.map(canonicalPath))
        for path in temporaryFolders.sorted() {
            found += soakTemporaryLeftovers(in: path, since: start)
        }
        return found
    }

    /// `recovery-failed/` and `.corrupt/` contents and atomic-write
    /// temporaries anywhere under the library, as paths relative to it.
    private static func soakSetAsideFiles(in folder: URL) -> [String] {
        let root = canonicalPath(folder.path)
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
        var found: [String] = []
        for case let relative as String in enumerator {
            let components = relative.split(separator: "/").map(String.init)
            guard let name = components.last else { continue }
            let setAside = components.dropLast().contains { $0 == "recovery-failed" || $0 == ".corrupt" }
            var isDirectory: ObjCBool = false
            let full = (root as NSString).appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            if setAside || isAtomicWriteTemporary(name) { found.append(relative) }
        }
        return found
    }

    /// `.<name>.<UUID>.tmp`, as written by `DurableFile` and `WaveformCacheFile`.
    static func isAtomicWriteTemporary(_ name: String) -> Bool {
        guard name.hasPrefix("."), name.hasSuffix(".tmp") else { return false }
        let parts = name.dropFirst().dropLast(4).split(separator: ".")
        guard parts.count >= 2, let last = parts.last else { return false }
        return UUID(uuidString: String(last)) != nil
    }

    /// The path with symlinks resolved (`/tmp` → `/private/tmp`), so one
    /// folder reached by two names is scanned once.
    nonisolated static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func soakTemporaryLeftovers(in path: String, since start: Date) -> [String] {
        let prefixes = ["msr-upload-", "msr-prepared-", ".in-progress-", ".final-"]
        let fileManager = FileManager.default
        var found: [String] = []
        let names = (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
        for name in names where prefixes.contains(where: { name.hasPrefix($0) }) {
            let attributes = try? fileManager.attributesOfItem(atPath: (path as NSString).appendingPathComponent(name))
            let modified = attributes?[.modificationDate] as? Date ?? .distantPast
            if modified >= start { found.append(name) }
        }
        return found
    }
}
