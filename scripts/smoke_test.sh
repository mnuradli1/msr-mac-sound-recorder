#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT_DIR/dist/MSR Meeting Recorder.app"
APP_ZIP_PATH="$ROOT_DIR/dist/MSR-Meeting-Recorder-0.2.6-app.zip"
DMG_PATH="$ROOT_DIR/dist/MSR-Meeting-Recorder-0.2.6.dmg"

cd "$ROOT_DIR"

echo "==> Unit/smoke tests"
swift run MSRTestRunner

echo "==> Debug build"
swift build

echo "==> Release package"
"$ROOT_DIR/scripts/package_app.sh"

echo "==> App bundle checks"
test -x "$APP_PATH/Contents/MacOS/MSRMeetingRecorder"
plutil -lint "$APP_PATH/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> DMG check"
test -f "$APP_ZIP_PATH"
unzip -tq "$APP_ZIP_PATH"
test -f "$DMG_PATH"
hdiutil verify "$DMG_PATH"

echo "==> Secret scan"
if rg -n 'sk_[A-Za-z0-9]+' --glob '!/.build/**' --glob '!dist/**' . >/tmp/msr-secret-scan.txt; then
  echo "Potential secret strings found:" >&2
  sed -n '1,20p' /tmp/msr-secret-scan.txt >&2
  exit 1
fi

echo "==> Optional live provider checks"
if [[ -n "${ELEVENLABS_API_KEY:-}" ]]; then
  ELEVEN_HEADERS="$(mktemp)"
  ELEVEN_AUDIO="$(mktemp -t msr-eleven-test).wav"
  trap 'rm -f "${ELEVEN_HEADERS:-}" "${ELEVEN_AUDIO:-}" "${OPENAI_HEADERS:-}"' EXIT
  chmod 600 "$ELEVEN_HEADERS"
  printf 'xi-api-key: %s\n' "$ELEVENLABS_API_KEY" > "$ELEVEN_HEADERS"
  python3 - <<'PY' "$ELEVEN_AUDIO"
import math, struct, sys, wave
path=sys.argv[1]
rate=16000
duration=0.25
with wave.open(path,'wb') as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(rate)
    for i in range(int(rate*duration)):
        sample=int(0.12*32767*math.sin(2*math.pi*440*i/rate))
        w.writeframes(struct.pack('<h', sample))
PY
  curl --fail --silent --show-error \
    -H "@$ELEVEN_HEADERS" \
    -F model_id=scribe_v2 \
    -F "file=@$ELEVEN_AUDIO;type=audio/wav" \
    https://api.elevenlabs.io/v1/speech-to-text >/dev/null
  echo "ElevenLabs live speech-to-text key check: passed"
else
  echo "ElevenLabs live key check: skipped (ELEVENLABS_API_KEY not set)"
fi

if [[ -n "${OPENAI_API_KEY:-}" ]]; then
  OPENAI_HEADERS="$(mktemp)"
  trap 'rm -f "${ELEVEN_HEADERS:-}" "${ELEVEN_AUDIO:-}" "${OPENAI_HEADERS:-}"' EXIT
  chmod 600 "$OPENAI_HEADERS"
  printf 'Authorization: Bearer %s\n' "$OPENAI_API_KEY" > "$OPENAI_HEADERS"
  curl --fail --silent --show-error \
    -H "@$OPENAI_HEADERS" \
    https://api.openai.com/v1/models >/dev/null
  echo "OpenAI live key check: passed"
else
  echo "OpenAI live key check: skipped (OPENAI_API_KEY not set)"
fi

echo "Smoke test complete"
