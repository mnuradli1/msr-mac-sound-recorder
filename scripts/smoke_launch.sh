#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/dist/MSR Meeting Recorder.app}"
SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/msr-smoke.XXXXXX")"
SMOKE_APP="$SMOKE_ROOT/MSR Smoke.app"
SMOKE_HOME="$SMOKE_ROOT/home"
LOG_FILE="$SMOKE_ROOT/launch.log"
APP_PID=""
cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  # This directory is created exclusively by mktemp above, never supplied by a caller.
  if [[ -d "$SMOKE_ROOT" && "$(basename "$SMOKE_ROOT")" == msr-smoke.* ]]; then
    rm -rf -- "$SMOKE_ROOT"
  fi
}
trap cleanup EXIT

test -x "$APP_PATH/Contents/MacOS/MSRMeetingRecorder"
ditto "$APP_PATH" "$SMOKE_APP"
# A separate bundle identity prevents the single-instance guard from turning an
# immediate exit into a false positive when the user's installed MSR is open.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.msr.meeting-recorder.smoke.$(uuidgen)" "$SMOKE_APP/Contents/Info.plist"
codesign --force --deep --sign - "$SMOKE_APP" >/dev/null 2>&1
mkdir -p "$SMOKE_HOME"
BINARY="$SMOKE_APP/Contents/MacOS/MSRMeetingRecorder"
# Foundation and UserDefaults must not read/recover the user's real library.
CFFIXED_USER_HOME="$SMOKE_HOME" "$BINARY" >"$LOG_FILE" 2>&1 &
APP_PID=$!

for _ in 1 2 3 4 5; do
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    wait "$APP_PID" 2>/dev/null || true
    APP_PID=""
    sed -n '1,120p' "$LOG_FILE" >&2
    echo "MSR app exited before the isolated smoke-launch window completed" >&2
    exit 1
  fi
  sleep 1
done

kill "$APP_PID"
wait "$APP_PID" 2>/dev/null || true
APP_PID=""
echo "MSR app remained healthy for the isolated smoke-launch window"
