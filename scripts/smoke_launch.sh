#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/dist/MSR Meeting Recorder.app}"
BINARY="$APP_PATH/Contents/MacOS/MSRMeetingRecorder"
LOG_FILE="$(mktemp -t msr-smoke-launch).log"
trap 'rm -f "$LOG_FILE"' EXIT

test -x "$BINARY"
"$BINARY" >"$LOG_FILE" 2>&1 &
APP_PID=$!

for _ in 1 2 3 4 5; do
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    if wait "$APP_PID"; then
      echo "MSR app completed a clean smoke launch"
      exit 0
    fi
    sed -n '1,120p' "$LOG_FILE" >&2
    echo "MSR app exited during smoke launch" >&2
    exit 1
  fi
  sleep 1
done

kill "$APP_PID"
wait "$APP_PID" 2>/dev/null || true
echo "MSR app remained healthy for the smoke-launch window"
