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
TIME_FROM=${TIME_FROM:-""} # e.g., 09:00 (24h)
TIME_TO=${TIME_TO:-""}   # e.g., 12:00 (24h)
DATE_WINDOW_DAYS=${DATE_WINDOW_DAYS:-""} # e.g., 14
WEEKDAYS=${WEEKDAYS:-""} # e.g., "Tuesday,Wednesday" or "2,3"
WEEK_OFFSET=${WEEK_OFFSET:-""} # integer weeks, e.g., 2
TARGET_WEEKDAY=${TARGET_WEEKDAY:-""} # e.g., Tuesday or number 2 (Mon=1..Sun=7)
NOW_EPOCH=${NOW_EPOCH:-"$(date -u +%s)"}

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
      jq -r \
        --arg time_from "$TIME_FROM" \
        --arg time_to "$TIME_TO" \
        --argjson now_epoch "$NOW_EPOCH" \
        --arg wnd "$DATE_WINDOW_DAYS" \
        --arg weekdays "$WEEKDAYS" \
        --arg woff "$WEEK_OFFSET" \
        --arg target_wd "$TARGET_WEEKDAY" '
        def to_min($s): if ($s == null or $s == "") then null else ($s | split(":") | (.[0]|tonumber)*60 + (.[1]|tonumber)) end;
        def fmt_min($m):
          ($m/60|floor) as $h | ($m%60) as $mi
          | ($h%12) as $hh | ($hh | if .==0 then 12 else . end) as $h12
          | ($mi|tostring | if length==1 then "0"+. else . end) as $mm
          | ($h >= 12 ? "PM" : "AM") as $ampm
          | "\($h12):\($mm) \($ampm)";
        def dayname_to_num($n):
          ( $n | ascii_downcase ) as $d
          | if $d == "monday" then 1
            elif $d == "tuesday" then 2
            elif $d == "wednesday" then 3
            elif $d == "thursday" then 4
            elif $d == "friday" then 5
            elif $d == "saturday" then 6
            elif $d == "sunday" then 7
            else null end;
        def avail_midnight_epoch:
          (.AvailabilityDate | strptime("%Y-%m-%dT%H:%M:%S") | mktime) as $e
          | (($e / 86400 | floor) * 86400);
        def now_midnight: (($now_epoch / 86400 | floor) * 86400);
        def within_window:
          (if ($wnd | length) == 0 then true else ($wnd|tonumber) end) as $win
          | if $win == true then true
            else ((avail_midnight_epoch - now_midnight) / 86400) as $dd | ($dd >= 0 and $dd <= $win)
            end;
        def weekday_allowed:
          if ($weekdays | length) == 0 then true
          else
            # Build allowed set from names or numbers
            ($weekdays | split(",") | map(. | gsub("^\\s+|\\s+$"; "") | ascii_downcase)) as $items
            | (.DayOfWeek | ascii_downcase) as $dn
            | ( [ $items[] | if test("^[0-9]+$") then .|tonumber else dayname_to_num(.) end ] ) as $nums
            | ( ( ( [ $dn ] | map(dayname_to_num(.)) )[0] ) ) as $cur
            | any($nums[]; . == $cur)
          end;
        def matches_target:
          if (($woff|length) == 0) or (($target_wd|length) == 0) then true
          else
            ( ($target_wd | if test("^[0-9]+$") then .|tonumber else dayname_to_num(.) end) ) as $t
            | ( ($now_epoch | strftime("%u") | tonumber) ) as $nw
            | ( ($t - $nw + 7) % 7 + (($woff|tonumber) * 7) ) as $days
            | ( now_midnight + ($days * 86400) ) as $target_epoch
            | avail_midnight_epoch == $target_epoch
          end;
        ($time_from | to_min) as $tf | ($time_to | to_min) as $tt
        .LocationAvailabilityDates[]?
        | ( .AvailableTimeSlots // [] ) as $slots
        | select(($slots | length) > 0)
        | select(within_window)
        | select(weekday_allowed)
        | select(matches_target)
        | [ $slots[]
            | (.StartDateTime | strptime("%Y-%m-%dT%H:%M:%S")) as $dt
            | ($dt[3]*60 + $dt[4]) as $start
            | (.Duration // 15) as $dur
            | {start: $start, end: ($start + $dur)}
            | select( ($tf == null or .start >= $tf) and ($tt == null or .start < $tt) )
          ] as $times
        | select(($times | length) > 0)
        | ($times | sort_by(.start)
           | reduce .[] as $s (
               [];
               if (length==0) then
                 [ {s: $s.start, e: $s.end} ]
               else
                 (.[-1]) as $last
                 | if $s.start == $last.e then
                     (.[0:-1] + [ $last | .e = $s.end ])
                   else
                     . + [ {s: $s.start, e: $s.end} ]
                   end
               end
             )
           | map( fmt_min(.s) + "–" + fmt_min(.e) )
           | join(", ")
          ) as $ranges
        | "  - " + (.FormattedAvailabilityDate // .AvailabilityDate) + " (" + (.DayOfWeek // "") + "): " + $ranges
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


