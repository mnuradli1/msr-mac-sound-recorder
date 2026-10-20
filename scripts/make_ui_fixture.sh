#!/usr/bin/env bash
# Builds a small, realistic MSR recordings library for UI snapshots.
#
# Usage: scripts/make_ui_fixture.sh [folder]
#
# The folder is wiped and recreated. Audio is real speech generated with macOS
# `say`, metadata uses the v2 `msr.recording` schema, and one recording carries
# a speaker-labelled transcript, segments and a summary. Point the app at it with
#   MSR_RECORDINGS_FOLDER=<folder> swift run MSRMeetingRecorder
# so snapshots never touch the user's real recordings.
set -euo pipefail

DEFAULT_FOLDER="/private/tmp/claude-501/-Users-nra8mac-Documents-GH-msr-mac-sound-recorder/36daa6ab-dcfd-4b8c-97ed-8976cfa86df3/scratchpad/ui-fixture"
FOLDER="${1:-$DEFAULT_FOLDER}"

case "$FOLDER" in
  ""|"/"|"$HOME"|"$HOME/Music"|"$HOME/Music/MSR Recordings")
    echo "Refusing to use '$FOLDER' as a fixture folder." >&2
    exit 1
    ;;
esac

rm -rf "$FOLDER"
mkdir -p "$FOLDER"

now=$(date +%s)
midnight=$(date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) 00:00:00" +%s)

iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }

# Today, `minutes` ago, but never before today's midnight (keeps "Today" grouping).
today_minus() {
  local value=$(( now - $1 * 60 ))
  local floor=$(( midnight + 1500 - $1 ))
  if (( value < floor )); then value=$floor; fi
  echo "$value"
}

# Local time on a day `days` before today, at `hour`:`minute`.
days_ago_at() {
  echo $(( midnight - $1 * 86400 + $2 * 3600 + $3 * 60 ))
}

storage_key() {
  echo "recording-$(echo "$1" | tr -d '-' | tr 'A-Z' 'a-z')"
}

audio_duration() {
  afinfo "$1" | awk '/estimated duration/ { printf "%.2f", $3 }'
}

speak() {
  local voice="$1" output="$2" text="$3"
  if ! say -v "$voice" -o "$output" --file-format=m4af --data-format=aac "$text" 2>/dev/null; then
    local aiff="${output%.m4a}.aiff"
    say -v "$voice" -o "$aiff" "$text"
    afconvert -f m4af -d aac "$aiff" "$output"
    rm -f "$aiff"
  fi
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# write_recording ID NAME SOURCE START_EPOCH VOICE TEXT [EXTRA_JSON]
write_recording() {
  local id="$1" name="$2" source="$3" start="$4" voice="$5" text="$6" extra="${7:-}"
  local key; key=$(storage_key "$id")
  local audio="$FOLDER/$key.m4a"
  speak "$voice" "$audio" "$text"
  local duration; duration=$(audio_duration "$audio")
  local end; end=$(awk -v s="$start" -v d="$duration" 'BEGIN { printf "%d", s + d }')
  local updated=$(( end + 5 ))
  cat > "$FOLDER/$key.json" <<JSON
{
  "schema" : "msr.recording",
  "schemaVersion" : 2,
  "id" : "$id",
  "storageKey" : "$key",
  "displayName" : "$(json_escape "$name")",
  "source" : "$source",
  "audioFileName" : "$key.m4a",
  "startedAt" : "$(iso "$start")",
  "endedAt" : "$(iso "$end")",
  "durationSeconds" : $duration,
  "createdAt" : "$(iso "$end")",
  "updatedAt" : "$(iso "$updated")"${extra}
}
JSON
  echo "$duration"
}

# 1. Today: product sync with transcript, speaker segments and summary.
SYNC_ID="6F1C2A8E-4B3D-4E5F-9A1B-2C3D4E5F6A01"
SYNC_KEY=$(storage_key "$SYNC_ID")
SEG_SPEAKERS=("Speaker 1" "Speaker 2" "Speaker 1" "Speaker 3" "Speaker 2")
SEG_TEXTS=(
  "Good morning everyone. Let's start the weekly product sync. The main topic today is the release plan for version one point one."
  "Thanks. The recording reliability fixes are merged, and the sleep safety work passed QA yesterday. We still need to finish the export polish."
  "Great. Can we commit to shipping the beta on Friday, with the transcript export and the new summary layout included?"
  "From the design side, the new layout is ready. I would like one more review of the dark mode colors before we freeze it."
  "Okay. Action items: I will prepare the release notes, and we will schedule the dark mode review for Wednesday afternoon."
)
SYNC_TEXT="${SEG_TEXTS[*]}"
SYNC_START=$(today_minus 55)
SYNC_DURATION=$(write_recording "$SYNC_ID" "Weekly product sync" "micAndSystem" "$SYNC_START" "Samantha" "$SYNC_TEXT" ',
  "confidenceReport" : {
    "checkedAt" : "'"$(iso $(( SYNC_START + 60 )))"'",
    "durationSeconds" : 60,
    "peakLevel" : 0.62,
    "averageLevel" : 0.18,
    "issues" : []
  }')

total_chars=0
for t in "${SEG_TEXTS[@]}"; do total_chars=$(( total_chars + ${#t} )); done
transcript=""
segments="["
offset_chars=0
for i in "${!SEG_TEXTS[@]}"; do
  t="${SEG_TEXTS[$i]}"
  start=$(awk -v o="$offset_chars" -v c="$total_chars" -v d="$SYNC_DURATION" 'BEGIN { printf "%.1f", o / c * d }')
  offset_chars=$(( offset_chars + ${#t} ))
  end=$(awk -v o="$offset_chars" -v c="$total_chars" -v d="$SYNC_DURATION" 'BEGIN { printf "%.1f", o / c * d }')
  stamp=$(awk -v s="$start" 'BEGIN { printf "%02d:%02d", int(s / 60), int(s) % 60 }')
  transcript+="[$stamp] ${SEG_SPEAKERS[$i]}:"$'\n'"$t"$'\n\n'
  seg_id=$(printf "0C0FFEE0-0000-4000-8000-%012d" "$i")
  [[ $i -gt 0 ]] && segments+=","
  segments+=$'\n  { "id" : "'"$seg_id"'", "speaker" : "'"${SEG_SPEAKERS[$i]}"'", "startTime" : '"$start"', "endTime" : '"$end"', "text" : "'"$(json_escape "$t")"'" }'
done
segments+=$'\n]\n'
printf '%s' "${transcript%$'\n\n'}" > "$FOLDER/$SYNC_KEY.transcript.txt"
printf '%s' "$segments" > "$FOLDER/$SYNC_KEY.transcript.segments.json"
cat > "$FOLDER/$SYNC_KEY.summary.md" <<'MD'
## Summary
The team confirmed the v1.1 release plan. Reliability and sleep-safety fixes are merged and QA-approved; export polish is the last open item.

## Decisions
- Ship the beta on Friday with transcript export and the new summary layout.

## Action items
- Prepare the release notes.
- Schedule the dark mode color review for Wednesday afternoon.
MD

# 2. Today: long title, system audio only, not transcribed yet.
write_recording "8A2B3C4D-5E6F-4A1B-8C2D-3E4F5A6B7C02" \
  "Client onboarding call with Northwind Traders – implementation timeline, data migration and training plan" \
  "system" "$(today_minus 190)" "Daniel" \
  "Welcome to the onboarding call. Today we will walk through the implementation timeline, the data migration steps, and the training plan for your team. Please stop me at any point if you have questions." >/dev/null

# 3. Yesterday: stand-up with a confidence warning (system source silent).
write_recording "1B2C3D4E-5F6A-4B7C-8D9E-0F1A2B3C4D03" "Engineering stand-up" "micAndSystem" \
  "$(days_ago_at 1 9 30)" "Karen" \
  "Quick stand-up. Yesterday I finished the waveform view. Today I am pairing on the transcription queue. No blockers." ',
  "confidenceReport" : {
    "checkedAt" : "'"$(iso "$(days_ago_at 1 9 32)")"'",
    "durationSeconds" : 9,
    "peakLevel" : 0.41,
    "averageLevel" : 0.09,
    "issues" : [
      { "kind" : "missingExpectedSource", "severity" : "warning", "message" : "System audio signal was not detected." }
    ]
  }' >/dev/null

# 4. Yesterday: design review whose transcription failed (shows retry + queue).
DESIGN_ID="2C3D4E5F-6A7B-4C8D-9E0F-1A2B3C4D5E04"
DESIGN_KEY=$(storage_key "$DESIGN_ID")
DESIGN_START=$(days_ago_at 1 15 0)
write_recording "$DESIGN_ID" "Design review: onboarding flow" "micAndSystem" "$DESIGN_START" "Samantha" \
  "Let's review the onboarding flow. The first screen explains permissions. The second screen asks for the ElevenLabs key. I think we can merge these two steps." >/dev/null
cat > "$FOLDER/.transcription-5D6E7F80-9A0B-4C1D-8E2F-3A4B5C6D7E04.json" <<JSON
{
  "id" : "5D6E7F80-9A0B-4C1D-8E2F-3A4B5C6D7E04",
  "recordingID" : "$DESIGN_ID",
  "recordingName" : "Design review: onboarding flow",
  "audioFileName" : "$DESIGN_KEY.m4a",
  "provider" : "elevenlabs",
  "status" : "failed",
  "attemptCount" : 1,
  "startedAt" : "$(iso $(( DESIGN_START + 600 )))",
  "queuedAt" : "$(iso $(( DESIGN_START + 600 )))",
  "updatedAt" : "$(iso $(( DESIGN_START + 640 )))",
  "errorMessage" : "ElevenLabs key is missing. Add it in Settings, then retry.",
  "replacingExistingTranscript" : false,
  "usedUncompressedAudioFallback" : false
}
JSON

# 5. Earlier: imported customer interview.
INTERVIEW_START=$(days_ago_at 5 11 0)
write_recording "3D4E5F6A-7B8C-4D9E-8F0A-1B2C3D4E5F05" "Customer interview – Dana" "microphone" "$INTERVIEW_START" "Karen" \
  "Thanks for joining. Can you tell me how you currently take notes during meetings, and what usually goes wrong?" ',
  "importedAt" : "'"$(iso $(( INTERVIEW_START + 3600 )))"'",
  "confidenceReport" : {
    "checkedAt" : "'"$(iso $(( INTERVIEW_START + 3600 )))"'",
    "durationSeconds" : 7,
    "peakLevel" : 0.5,
    "averageLevel" : 0.12,
    "issues" : [
      { "kind" : "missingExpectedSource", "severity" : "info", "message" : "Imported file source is external. Confirm it contains the meeting audio you expect." }
    ]
  }' >/dev/null

# 6. Earlier: recovered budget meeting with a plain (unlabelled) transcript.
BUDGET_ID="4E5F6A7B-8C9D-4E0F-9A1B-2C3D4E5F6A06"
BUDGET_KEY=$(storage_key "$BUDGET_ID")
BUDGET_START=$(days_ago_at 12 14 0)
write_recording "$BUDGET_ID" "Q4 budget planning" "microphone" "$BUDGET_START" "Daniel" \
  "For the fourth quarter budget, we keep hiring flat, move two hundred thousand into infrastructure, and revisit marketing spend in November." ',
  "recoveredAt" : "'"$(iso $(( BUDGET_START + 7200 )))"'",
  "recoveryNote" : "Recovered after the app quit unexpectedly.",
  "segmentCount" : 2' >/dev/null
printf '%s' "For the fourth quarter budget, we keep hiring flat, move two hundred thousand into infrastructure, and revisit marketing spend in November." \
  > "$FOLDER/$BUDGET_KEY.transcript.txt"

count=$(ls "$FOLDER"/recording-*.json | grep -vc "\.transcript\.")
echo "Fixture library ready: $FOLDER ($count recordings)"
