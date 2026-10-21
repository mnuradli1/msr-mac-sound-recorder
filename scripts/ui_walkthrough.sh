#!/usr/bin/env bash
# Accessibility-driven UI walkthrough: builds the app and a fixture library,
# runs MSR_UI_SCENARIO=ui-walkthrough (presses, selects and types through the
# app's own accessibility tree and checks the view model and disk after every
# step) and the empty-library scenario, and exits non-zero if any step failed.
#
# Usage: scripts/ui_walkthrough.sh
#
# Requires ELEVENLABS_API_KEY (step 7 records via the real Record button and
# transcribes once). No Accessibility or Screen Recording permission needed;
# the app window appears on screen briefly and never takes keyboard focus.
#
# Environment:
#   MSR_UI_FIXTURE      fixture folder (default: ${TMPDIR:-/tmp}/msr-ui-walkthrough); wiped first
#   MSR_UI_SKIP_BUILD   set to skip `swift build`
#   MSR_UI_WALKTHROUGH_ONLY / MSR_UI_WALKTHROUGH_DUMP   passed through (see UIWalkthrough.swift)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}"
FIXTURE="${MSR_UI_FIXTURE:-${TMP_ROOT%/}/msr-ui-walkthrough}"
CLIP="$ROOT_DIR/Tests/Fixtures/meeting-en.m4a"
BINARY="$ROOT_DIR/.build/debug/MSRMeetingRecorder"

if [[ -z "${ELEVENLABS_API_KEY:-}" ]]; then
  echo "ELEVENLABS_API_KEY is not set; the record → transcribe step needs it." >&2
  exit 2
fi

if [[ -z "${MSR_UI_SKIP_BUILD:-}" ]]; then
  (cd "$ROOT_DIR" && swift build 2>&1 | tail -3)
fi

"$ROOT_DIR/scripts/make_ui_fixture.sh" "$FIXTURE"
EMPTY="$(mktemp -d "${TMP_ROOT%/}/msr-ui-walkthrough-empty.XXXXXX")"
trap 'rm -rf "$EMPTY"' EXIT

status=0
run() {
  local name="$1"; shift
  echo "== $name"
  local log; log="$(mktemp "${TMP_ROOT%/}/msr-ui-walkthrough-log.XXXXXX")"
  if env "$@" "$BINARY" >"$log" 2>&1; then
    grep -E '"step"|"walkthrough"' "$log" || true
  else
    grep -E '"step"|"walkthrough"' "$log" || tail -20 "$log"
    status=1
  fi
  rm -f "$log"
}

run "ui-walkthrough ($FIXTURE)" \
  MSR_RECORDINGS_FOLDER="$FIXTURE" MSR_FAKE_RECORDER_CLIP="$CLIP" MSR_UI_SCENARIO=ui-walkthrough
run "ui-walkthrough-empty" \
  MSR_RECORDINGS_FOLDER="$EMPTY" MSR_UI_SCENARIO=ui-walkthrough-empty

if [[ $status -eq 0 ]]; then
  echo "UI walkthrough passed"
else
  echo "UI walkthrough FAILED" >&2
fi
exit $status
