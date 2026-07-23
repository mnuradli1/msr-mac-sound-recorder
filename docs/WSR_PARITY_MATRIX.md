# WSR v4 → MSR v1.0 Parity Matrix

Reference: WSR commit `4cd02b5cb9fdf8d4c919556ba52f41fbe47d3d1f` and MSR upgrade baseline `635cfcb499cdbe61242fd0eb7309d8ea2bf59bc0`.

| Capability | MSR v1.0 implementation | Verification |
| --- | --- | --- |
| Immutable recording storage | `msr.recording` schema v2 and `recording-<32hex>` keys | SwiftPM migration tests |
| Atomic recovery | `.bak`, `.corrupt`, `.publish`, `.migrate`, `.delete` | Fault/migration tests and legacy runner |
| Recording lifecycle | Starting/capturing/paused/finalizing/completed/failed manifest | State and recovery tests |
| Mic/system capture | AVFoundation plus ScreenCaptureKit, retaining MSR confidence analysis | Hardware smoke matrix |
| Durable AI queue | Independent job IDs, queued time, trim/preparation fields and publication hash | Queue restart/checkpoint tests |
| Upload hardening | File-backed multipart, neutral names, timeouts, response cap | URLProtocol integration tests |
| Long summaries and titles | 60k chunking; OpenAI-only default-name titles | Fake provider tests |
| Library workspace | Search, six sorts, multi-import/drop, status badges and context actions | Presentation/model tests |
| Review and trim | Cached 96-bucket waveform, seek, speeds, non-destructive trim | Audio fixture tests |
| Editable notes | Transcript and summary autosave, explicit save and read-only timestamp segments | Autosave/selection tests |
| Export | TXT, Markdown, SRT, DOCX preview/export/reveal | Fixture and archive tests |
| UI shell | Resizable sidebar, Review/Notes/Export, capture dock, global queue banner | Wide/compact screenshots |
| macOS integration | Theme, EN/ID resources, VoiceOver labels, Control–Option–R, MenuBarExtra | Accessibility/manual matrix |
| Local API | Opt-in, loopback-only, per-run bearer token, contained file access | HTTP integration tests |
| Release | v1.0A source, CI, ZIP/DMG/checksums/provenance/cask, optional hardened signing/notary | Release smoke test |

Windows-only device/session APIs are intentionally replaced by native macOS equivalents. The app does not add telemetry, accounts, cloud sync, calendar, team collaboration, or live captions.
