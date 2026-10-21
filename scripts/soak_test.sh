#!/usr/bin/env bash
# Long-recording soak: builds the app and a fixture library, then runs
# MSR_UI_SCENARIO=soak (record → pause/resume → save, once per minute) with
# the fake recorder, alternating how each recording is saved: odd cycles via
# the system-sleep save → wake path, even cycles via a plain Stop. Tracks the
# memory footprint (and resident size), leftover temporary files, and that
# every cycle adds exactly one recording and the same number of library files.
# One JSON line per cycle plus a final {"soak":"done",…} summary are printed
# and written to artifacts/soak-<date>.jsonl.
#
# Usage: scripts/soak_test.sh [--minutes N] [--transcribe]
#
#   --minutes N    soak length; one 60 s recording per minute (default 20)
#   --transcribe   auto-transcribe + auto-title every recording (needs
#                  ELEVENLABS_API_KEY exported; one billable call per cycle)
#
# Environment:
#   MSR_SOAK_FIXTURE        fixture folder (default: a fresh temp folder, removed afterwards); wiped first
#   MSR_SOAK_RECORD_SECONDS recording seconds per cycle (default 60)
#   MSR_SOAK_MAX_GROWTH_MB  allowed memory-footprint growth first → last cycle
#                           (default 60; judged only with 3 or more cycles)
#   MSR_SOAK_SKIP_BUILD     set to skip `swift build`
#
# Exits with the scenario's status: non-zero if a cycle failed, temporary
# files were left behind, the recording or file counts are off, or memory grew
# beyond the limit. Never touches the
# real library: the app runs with MSR_RECORDINGS_FOLDER and a private TMPDIR.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}"
CLIP="$ROOT_DIR/Tests/Fixtures/meeting-en.m4a"
BINARY="$ROOT_DIR/.build/debug/MSRMeetingRecorder"

minutes=20
transcribe=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --minutes) minutes="${2:?--minutes needs a value}"; shift 2 ;;
    --minutes=*) minutes="${1#--minutes=}"; shift ;;
    --transcribe) transcribe=1; shift ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
if ! [[ "$minutes" =~ ^[0-9]+$ ]] || (( minutes < 1 )); then
  echo "--minutes must be a positive integer" >&2
  exit 2
fi
if (( transcribe )); then
  if [[ -z "${ELEVENLABS_API_KEY:-}" ]]; then
    echo "--transcribe needs ELEVENLABS_API_KEY exported." >&2
    exit 2
  fi
  key_env=()
else
  # Without --transcribe nothing is sent to a provider (the scenario forces
  # auto-transcribe/title/summary off). Placeholder keys keep the app from
  # reading the Keychain, whose access prompt blocks unsigned debug builds,
  # and guarantee that no real key could be billed.
  key_env=(ELEVENLABS_API_KEY=msr-soak-placeholder OPENAI_API_KEY=msr-soak-placeholder
           DEEPSEEK_API_KEY=msr-soak-placeholder)
fi

record_seconds="${MSR_SOAK_RECORD_SECONDS:-60}"
cycles=$(( minutes * 60 / record_seconds ))
(( cycles < 1 )) && cycles=1

if [[ -z "${MSR_SOAK_SKIP_BUILD:-}" ]]; then
  (cd "$ROOT_DIR" && swift build 2>&1 | tail -3)
fi

WORK="$(mktemp -d "${TMP_ROOT%/}/msr-soak.XXXXXX")"
FIXTURE="${MSR_SOAK_FIXTURE:-$WORK/library}"
APP_TMP="$WORK/tmp"
mkdir -p "$APP_TMP"
LOG="$WORK/app.log"
trap 'rm -rf "$WORK"' EXIT
"$ROOT_DIR/scripts/make_ui_fixture.sh" "$FIXTURE" >/dev/null

mkdir -p "$ROOT_DIR/artifacts"
OUT="$ROOT_DIR/artifacts/soak-$(date +%Y%m%d-%H%M%S).jsonl"
echo "== soak: $cycles cycle(s) × ${record_seconds}s, pause, alternating sleep/stop saves, transcribe=$transcribe → ${OUT#"$ROOT_DIR"/}"

# Watchdog: a hung app (e.g. a blocking system prompt) is killed with SIGALRM.
budget=$(( cycles * (record_seconds + 30) + 300 ))
(( transcribe )) && budget=$(( budget + cycles * 180 ))

# The app's stderr carries the JSON lines; everything else goes to the log.
# The app's stdout and the loop below both append (O_APPEND) to the same log,
# so neither overwrites what the other wrote.
: >"$LOG"
set +e
perl -e 'alarm shift @ARGV; exec @ARGV or die "exec: $!"' "$budget" \
  env ${key_env[@]+"${key_env[@]}"} TMPDIR="$APP_TMP/" \
  MSR_RECORDINGS_FOLDER="$FIXTURE" \
  MSR_FAKE_RECORDER_CLIP="$CLIP" \
  MSR_UI_SCENARIO=soak \
  MSR_SOAK_CYCLES="$cycles" \
  MSR_SOAK_RECORD_SECONDS="$record_seconds" \
  MSR_SOAK_PAUSE=1 \
  MSR_SOAK_SLEEP=1 \
  MSR_SOAK_AUTO_TRANSCRIBE="$transcribe" \
  MSR_UI_SCENARIO_TIMEOUT=180 \
  "$BINARY" 2>&1 >>"$LOG" | while IFS= read -r line; do
    if [[ "$line" == '{"soak"'* ]]; then
      printf '%s\n' "$line" | tee -a "$OUT"
    else
      printf '%s\n' "$line" >>"$LOG"
    fi
  done
pipe_status=("${PIPESTATUS[@]}")
set -e
status=${pipe_status[0]}

if ! grep -q '"soak":"done"' "$OUT" 2>/dev/null; then
  echo "Soak did not finish; last app output:" >&2
  tail -20 "$LOG" >&2
  (( status == 0 )) && status=1
fi
if [[ $status -eq 0 ]]; then
  echo "Soak passed"
else
  echo "Soak FAILED (status $status)" >&2
fi
exit "$status"
