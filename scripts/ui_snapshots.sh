#!/usr/bin/env bash
# Captures MSR UI snapshots against a fixture library (no screen recording needed).
#
# Usage: scripts/ui_snapshots.sh <prefix> [shot ...]
#   prefix  file prefix, e.g. "before" or "after" -> artifacts/ui-<prefix>-<shot>.png
#   shot    any of the names listed in SHOTS below (default: all)
#
# Environment:
#   MSR_UI_FIXTURE      fixture folder (default: the make_ui_fixture.sh default)
#   MSR_UI_OUT_DIR      output folder (default: <repo>/artifacts)
#   MSR_UI_SKIP_BUILD   set to skip `swift build`
#
# Each shot launches the app briefly; its window appears on screen, captures
# itself via UISnapshotCapture and quits.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${1:?usage: scripts/ui_snapshots.sh <prefix> [shot ...]}"
shift || true

TMP_ROOT="${TMPDIR:-/tmp}"
DEFAULT_FIXTURE="${TMP_ROOT%/}/msr-ui-fixture"
FIXTURE="${MSR_UI_FIXTURE:-$DEFAULT_FIXTURE}"
EMPTY_FIXTURE="${FIXTURE%/}-empty"
OUT_DIR="${MSR_UI_OUT_DIR:-$ROOT_DIR/artifacts}"
mkdir -p "$OUT_DIR" "$EMPTY_FIXTURE"

if [[ ! -d "$FIXTURE" ]]; then
  "$ROOT_DIR/scripts/make_ui_fixture.sh" "$FIXTURE"
fi

# name|folder(fixture/empty)|key=value env pairs separated by spaces
SHOTS=(
  "light-review|fixture|MSR_UI_SNAPSHOT_APPEARANCE=light MSR_UI_SNAPSHOT_SELECT=0 MSR_UI_SNAPSHOT_TAB=review"
  "dark-review|fixture|MSR_UI_SNAPSHOT_APPEARANCE=dark MSR_UI_SNAPSHOT_SELECT=0 MSR_UI_SNAPSHOT_TAB=review"
  "light-notes|fixture|MSR_UI_SNAPSHOT_APPEARANCE=light MSR_UI_SNAPSHOT_SELECT=0 MSR_UI_SNAPSHOT_TAB=notes"
  "dark-notes|fixture|MSR_UI_SNAPSHOT_APPEARANCE=dark MSR_UI_SNAPSHOT_SELECT=0 MSR_UI_SNAPSHOT_TAB=notes"
  "light-notes-speaker-popover|fixture|MSR_UI_SNAPSHOT_APPEARANCE=light MSR_UI_SNAPSHOT_SELECT=0 MSR_UI_SNAPSHOT_TAB=notes MSR_UI_SNAPSHOT_TRANSCRIPT_MODE=read MSR_UI_SNAPSHOT_SPEAKER_POPOVER=0 MSR_UI_SNAPSHOT_SPEAKER_DRAFT=Sarah"
  "light-notes-edit|fixture|MSR_UI_SNAPSHOT_APPEARANCE=light MSR_UI_SNAPSHOT_SELECT=0 MSR_UI_SNAPSHOT_TAB=notes MSR_UI_SNAPSHOT_TRANSCRIPT_MODE=edit"
  "light-export|fixture|MSR_UI_SNAPSHOT_APPEARANCE=light MSR_UI_SNAPSHOT_SELECT=0 MSR_UI_SNAPSHOT_TAB=export"
  "dark-export|fixture|MSR_UI_SNAPSHOT_APPEARANCE=dark MSR_UI_SNAPSHOT_SELECT=0 MSR_UI_SNAPSHOT_TAB=export"
  "light-warning|fixture|MSR_UI_SNAPSHOT_APPEARANCE=light MSR_UI_SNAPSHOT_SELECT=3 MSR_UI_SNAPSHOT_TAB=review"
  "dark-failed-job|fixture|MSR_UI_SNAPSHOT_APPEARANCE=dark MSR_UI_SNAPSHOT_SELECT=2 MSR_UI_SNAPSHOT_TAB=notes"
  "light-min-size|fixture|MSR_UI_SNAPSHOT_APPEARANCE=light MSR_UI_SNAPSHOT_SELECT=1 MSR_UI_SNAPSHOT_TAB=notes MSR_UI_SNAPSHOT_SIZE=980x640"
  "light-ready|fixture|MSR_UI_SNAPSHOT_APPEARANCE=light MSR_UI_SNAPSHOT_SELECT=none"
  "light-empty|empty|MSR_UI_SNAPSHOT_APPEARANCE=light MSR_UI_SNAPSHOT_SELECT=none"
  "dark-empty|empty|MSR_UI_SNAPSHOT_APPEARANCE=dark MSR_UI_SNAPSHOT_SELECT=none"
  "light-search|fixture|MSR_UI_SNAPSHOT_APPEARANCE=light MSR_UI_SNAPSHOT_SEARCH=review MSR_UI_SNAPSHOT_SELECT=0 MSR_UI_SNAPSHOT_TAB=review"
  "light-settings|fixture|MSR_UI_SNAPSHOT_APPEARANCE=light MSR_UI_SNAPSHOT_WINDOW=settings MSR_UI_SNAPSHOT_SETTINGS_TAB=general"
  "dark-settings|fixture|MSR_UI_SNAPSHOT_APPEARANCE=dark MSR_UI_SNAPSHOT_WINDOW=settings MSR_UI_SNAPSHOT_SETTINGS_TAB=general"
  "light-settings-transcription|fixture|MSR_UI_SNAPSHOT_APPEARANCE=light MSR_UI_SNAPSHOT_WINDOW=settings MSR_UI_SNAPSHOT_SETTINGS_TAB=transcription"
  "dark-settings-transcription|fixture|MSR_UI_SNAPSHOT_APPEARANCE=dark MSR_UI_SNAPSHOT_WINDOW=settings MSR_UI_SNAPSHOT_SETTINGS_TAB=transcription"
  "light-settings-transcription-keys|fixture|MSR_UI_SNAPSHOT_APPEARANCE=light MSR_UI_SNAPSHOT_WINDOW=settings MSR_UI_SNAPSHOT_SETTINGS_TAB=transcription MSR_UI_SNAPSHOT_SETTINGS_SCROLL=bottom"
  "light-settings-advanced|fixture|MSR_UI_SNAPSHOT_APPEARANCE=light MSR_UI_SNAPSHOT_WINDOW=settings MSR_UI_SNAPSHOT_SETTINGS_TAB=advanced"
  "light-settings-health|fixture|MSR_UI_SNAPSHOT_APPEARANCE=light MSR_UI_SNAPSHOT_WINDOW=settings MSR_UI_SNAPSHOT_SETTINGS_TAB=health"
  "light-quick-recorder|fixture|MSR_UI_SNAPSHOT_APPEARANCE=light MSR_UI_SNAPSHOT_WINDOW=quick"
  "dark-quick-recorder|fixture|MSR_UI_SNAPSHOT_APPEARANCE=dark MSR_UI_SNAPSHOT_WINDOW=quick"
  "dark-quick-recorder-recording|fixture|MSR_UI_SNAPSHOT_APPEARANCE=dark MSR_UI_SNAPSHOT_WINDOW=quick MSR_UI_SNAPSHOT_QUICK_RECORDING=4"
  "light-onboarding-step1|fixture|MSR_UI_SNAPSHOT_APPEARANCE=light MSR_UI_SNAPSHOT_ONBOARDING=1 MSR_UI_SNAPSHOT_ONBOARDING_STEP=1"
  "light-onboarding-step2|fixture|MSR_UI_SNAPSHOT_APPEARANCE=light MSR_UI_SNAPSHOT_ONBOARDING=1 MSR_UI_SNAPSHOT_ONBOARDING_STEP=2"
  "light-onboarding-step3|fixture|MSR_UI_SNAPSHOT_APPEARANCE=light MSR_UI_SNAPSHOT_ONBOARDING=1 MSR_UI_SNAPSHOT_ONBOARDING_STEP=3"
  "dark-onboarding-step4|fixture|MSR_UI_SNAPSHOT_APPEARANCE=dark MSR_UI_SNAPSHOT_ONBOARDING=1 MSR_UI_SNAPSHOT_ONBOARDING_STEP=4"
)

if [[ -z "${MSR_UI_SKIP_BUILD:-}" ]]; then
  (cd "$ROOT_DIR" && swift build --product MSRMeetingRecorder >/dev/null)
fi
BINARY="$(cd "$ROOT_DIR" && swift build --show-bin-path)/MSRMeetingRecorder"

wanted=("$@")
for shot in "${SHOTS[@]}"; do
  IFS='|' read -r name folder pairs <<<"$shot"
  if (( ${#wanted[@]} > 0 )); then
    match=0
    for w in "${wanted[@]}"; do [[ "$w" == "$name" ]] && match=1; done
    (( match )) || continue
  fi
  target="$FIXTURE"
  [[ "$folder" == "empty" ]] && target="$EMPTY_FIXTURE"
  output="$OUT_DIR/ui-$PREFIX-$name.png"
  rm -f "$output"
  log="$(mktemp -t msr-ui-snapshot)"
  # shellcheck disable=SC2086
  env MSR_RECORDINGS_FOLDER="$target" MSR_UI_SNAPSHOT_PATH="$output" $pairs "$BINARY" >"$log" 2>&1 &
  pid=$!
  # Watchdog: never let a stuck launch (e.g. a system prompt) block the loop.
  for _ in $(seq 1 40); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    echo "MSR snapshot: $name timed out" >&2
  fi
  wait "$pid" 2>/dev/null || true
  grep "MSR snapshot" "$log" || echo "MSR snapshot: no output for $name" >&2
  rm -f "$log"
done
