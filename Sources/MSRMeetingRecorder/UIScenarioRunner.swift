import Foundation
import MSRCore
import MSRServices

/// Scripted in-app scenarios for development and end-to-end checks, driven by
/// environment variables. Call `runIfRequested(viewModel:)` after `bootstrap()`
/// and before `UISnapshotCapture.runIfRequested()`.
///
/// - `MSR_UI_SCENARIO`: the scenario to run. Supported: `auto-transcribe`,
///   `ui-walkthrough` and `ui-walkthrough-empty` (accessibility-driven UI
///   walkthrough, see `UIWalkthrough`).
/// - `MSR_UI_SCENARIO_SECONDS`: how long to record (default 3).
/// - `MSR_UI_SCENARIO_TIMEOUT`: how long to wait for the transcription job (default 180).
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
        // The title is applied right after the job is checkpointed as completed;
        // give the publisher a moment to finish before reading the final state.
        try? await Task.sleep(for: .milliseconds(500))
        job = latestJob(for: recording.id, in: viewModel)

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
            }
        }
        report.ok = report.error == nil && report.jobStatus == TranscriptionJobStatus.completed.rawValue
            && report.transcriptCharacters > 0
        if report.ok == false, report.error == nil {
            report.error = "transcript is empty"
        }
        emit(report.dictionary)
        if ProcessInfo.processInfo.environment["MSR_UI_SNAPSHOT_PATH"]?.isEmpty == false {
            return
        }
        exit(report.ok ? 0 : 1)
    }

    private static func emit(_ object: [String: Any]) {
        let keys = ["ok", "reason", "recordingID", "titleBefore", "titleAfter", "titleSource",
                    "jobStatus", "jobOrigin", "transcriptCharacters", "error"]
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
                "error": error ?? NSNull()
            ]
        }
    }
}
