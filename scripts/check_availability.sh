#!/usr/bin/env bash

# Strict mode without exiting on curl failures; we handle them per-request
set -uo pipefail

mkdir -p .availability
summary_file=.availability/summary.txt
found_file=.availability/found
> "$summary_file"

# Config
BASE_URL=${BASE_URL:-"https://publicwebsiteapi.nydmvreservation.com/api/AvailableLocationDates"}
TYPE_ID=${TYPE_ID:-"204"}
START_DATE=${START_DATE:-"$(date -u +"%Y-%m-%dT%H:%M:%SZ")"}
LOCATION_IDS=${LOCATION_IDS:-""}
BEARER_TOKEN=${BEARER_TOKEN:-""}
ORIGIN=${ORIGIN:-"https://public.nydmvreservation.com"}
USER_AGENT=${USER_AGENT:-"curl/8 (GitHub Actions)"}
LOCATION_NAME_MAP=${LOCATION_NAME_MAP:-""}
WEBHOOK_URL=${WEBHOOK_URL:-""}
WEBHOOK_FORMAT=${WEBHOOK_FORMAT:-"text"} # supported: text, json
WEBHOOK_JSON_KEY=${WEBHOOK_JSON_KEY:-"text"}

if [[ -z "$BEARER_TOKEN" ]]; then
  echo "BEARER_TOKEN is required (set it as a repository secret)." >&2
  echo "false" > "$found_file"
  exit 0
fi

if [[ -z "$LOCATION_IDS" ]]; then
  echo "LOCATION_IDS is empty; set repository variable LOCATION_IDS (comma or space separated)." >&2
  echo "false" > "$found_file"
  exit 0
fi

# Normalize separators: allow commas or spaces
ids_str=${LOCATION_IDS//,/ }

found_any=false

get_location_label() {
  local id="$1"
  local name=""
  if [[ -n "$LOCATION_NAME_MAP" ]] && command -v jq >/dev/null 2>&1; then
    name=$(jq -r --arg id "$id" 'try .[$id] catch ""' <<< "$LOCATION_NAME_MAP" 2>/dev/null || echo "")
  fi
  if [[ -n "$name" && "$name" != "null" ]]; then
    echo "$name ($id)"
  else
    echo "$id"
  fi
}

for id in $ids_str; do
  url="${BASE_URL}?locationId=${id}&typeId=${TYPE_ID}&startDate=${START_DATE}"

  # Fetch JSON
  http_code=$(curl -sS -w "%{http_code}" -o .availability/resp.json \
    -H "Accept: application/json, text/plain, */*" \
    -H "Accept-Language: en-US,en;q=0.9" \
    -H "Authorization: Bearer ${BEARER_TOKEN}" \
    -H "Connection: keep-alive" \
    -H "Origin: ${ORIGIN}" \
    -H "Referer: ${ORIGIN}/" \
    -H "Sec-Fetch-Dest: empty" \
    -H "Sec-Fetch-Mode: cors" \
    -H "Sec-Fetch-Site: same-site" \
    -H "User-Agent: ${USER_AGENT}" \
    "$url" || true)

  if [[ "$http_code" != "200" ]]; then
    echo "[Location ${id}] Request failed with HTTP ${http_code}" >&2
    continue
  fi

  # Guard: ensure jq is available
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required but not installed" >&2
    echo "false" > "$found_file"
    exit 0
  fi

  # Extract available dates that have at least one time slot
  has_any=$(jq -r '[.LocationAvailabilityDates[]? | select((.AvailableTimeSlots // []) | length > 0)] | length > 0' .availability/resp.json 2>/dev/null || echo false)

  if [[ "$has_any" == "true" ]]; then
    found_any=true
    {
      echo "Location $(get_location_label "$id") — available time slots found:"
      jq -r '
        .LocationAvailabilityDates[]? 
        | select((.AvailableTimeSlots // []) | length > 0)
        | "  - "
          + (.FormattedAvailabilityDate // .AvailabilityDate)
          + " (" + (.DayOfWeek // "") + ")"
          + ": "
          + ((.AvailableTimeSlots // []) | map(.FormattedTime // .StartDateTime) | join(", "))
      ' .availability/resp.json
      echo "  API URL: ${url}"
      echo
    } >> "$summary_file"
  else
    echo "Location $(get_location_label "$id") — no available time slots." >> "$summary_file"
  fi
done

if [[ "$found_any" == "true" ]]; then
  echo "true" > "$found_file"
  # Optionally notify webhook
  if [[ -n "$WEBHOOK_URL" ]]; then
    case "$WEBHOOK_FORMAT" in
      json)
        if command -v jq >/dev/null 2>&1; then
          payload=$(jq -Rs --arg k "$WEBHOOK_JSON_KEY" '{($k): .}' < "$summary_file")
          curl -sS -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" >/dev/null || true
        else
          # Fallback to plain text if jq is unavailable
          curl -sS -X POST -H "Content-Type: text/plain" --data-binary @"$summary_file" "$WEBHOOK_URL" >/dev/null || true
        fi
        ;;
      text|*)
        curl -sS -X POST -H "Content-Type: text/plain" --data-binary @"$summary_file" "$WEBHOOK_URL" >/dev/null || true
        ;;
    esac
  fi
else
  echo "false" > "$found_file"
fi

exit 0


