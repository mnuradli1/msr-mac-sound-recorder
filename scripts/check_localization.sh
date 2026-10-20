#!/usr/bin/env bash
# Fails when the English and Indonesian Localizable.strings files do not have
# exactly the same set of keys, contain duplicate keys, or do not parse.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RES="$ROOT_DIR/Sources/MSRMeetingRecorder/Resources"
EN="$RES/en.lproj/Localizable.strings"
ID="$RES/id.lproj/Localizable.strings"

status=0

for file in "$EN" "$ID"; do
  if ! plutil -lint "$file" >/dev/null; then
    echo "error: $file does not parse" >&2
    plutil -lint "$file" >&2 || true
    status=1
  fi
done

keys() {
  # Key = first quoted string on each `"key" = "value";` line.
  sed -nE 's/^[[:space:]]*"((\\.|[^"\\])*)"[[:space:]]*=.*$/\1/p' "$1"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
keys "$EN" | sort > "$tmp/en.all"
keys "$ID" | sort > "$tmp/id.all"

for lang in en id; do
  dupes="$(uniq -d "$tmp/$lang.all")"
  if [[ -n "$dupes" ]]; then
    echo "error: duplicate keys in $lang.lproj:" >&2
    echo "$dupes" | sed 's/^/  /' >&2
    status=1
  fi
  sort -u "$tmp/$lang.all" > "$tmp/$lang"
done

only_en="$(comm -23 "$tmp/en" "$tmp/id")"
only_id="$(comm -13 "$tmp/en" "$tmp/id")"
if [[ -n "$only_en" ]]; then
  echo "error: keys missing from id.lproj:" >&2
  echo "$only_en" | sed 's/^/  /' >&2
  status=1
fi
if [[ -n "$only_id" ]]; then
  echo "error: keys missing from en.lproj:" >&2
  echo "$only_id" | sed 's/^/  /' >&2
  status=1
fi

if [[ $status -eq 0 ]]; then
  echo "Localization OK: $(wc -l < "$tmp/en" | tr -d ' ') keys in en and id"
fi
exit $status
