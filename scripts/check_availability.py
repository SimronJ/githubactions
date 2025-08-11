#!/usr/bin/env python3

import os
import sys
import json
import urllib.request
import urllib.error
from datetime import datetime, timezone, timedelta
from typing import Dict, List, Tuple, Optional


def read_env(name: str, default: Optional[str] = None) -> Optional[str]:
    return os.environ.get(name, default)


def parse_location_ids(raw: str) -> List[str]:
    raw = raw.replace(",", " ")
    result: List[str] = []
    for piece in (s.strip() for s in raw.split()):
        if not piece:
            continue
        # strip surrounding quotes and keep only digits
        piece = piece.strip("\"'")
        digits = "".join(ch for ch in piece if ch.isdigit())
        if digits:
            result.append(digits)
    return result


def iso_now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def to_minutes_24h(hhmm: Optional[str]) -> Optional[int]:
    if not hhmm:
        return None
    try:
        parts = hhmm.split(":")
        if len(parts) != 2:
            return None
        h = int(parts[0])
        m = int(parts[1])
        if not (0 <= h <= 23 and 0 <= m <= 59):
            return None
        return h * 60 + m
    except Exception:
        return None


def weekday_to_num(name_or_num: str) -> Optional[int]:
    n = name_or_num.strip().lower()
    names = {
        "monday": 1,
        "tuesday": 2,
        "wednesday": 3,
        "thursday": 4,
        "friday": 5,
        "saturday": 6,
        "sunday": 7,
    }
    if n.isdigit():
        x = int(n)
        return x if 1 <= x <= 7 else None
    return names.get(n)


def allowed_weekdays_set(raw: Optional[str]) -> Optional[set]:
    if not raw:
        return None
    items = [s.strip() for s in raw.split(",") if s.strip()]
    result = set()
    for it in items:
        num = weekday_to_num(it)
        if num:
            result.add(num)
    return result or None


def date_midnight_epoch(dt: datetime) -> int:
    midnight = datetime(dt.year, dt.month, dt.day, tzinfo=timezone.utc)
    return int(midnight.timestamp())


def parse_api_datetime(value: str) -> datetime:
    # API format: 2025-09-17T13:30:00
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)


def fetch_location(base_url: str, token: str, origin: str, user_agent: str, location_id: str, type_id: str, start_date: str) -> Optional[dict]:
    url = f"{base_url}?locationId={location_id}&typeId={type_id}&startDate={start_date}"
    req = urllib.request.Request(url)
    req.add_header("Accept", "application/json, text/plain, */*")
    req.add_header("Accept-Language", "en-US,en;q=0.9")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Connection", "keep-alive")
    req.add_header("Origin", origin)
    req.add_header("Referer", origin + "/")
    req.add_header("Sec-Fetch-Dest", "empty")
    req.add_header("Sec-Fetch-Mode", "cors")
    req.add_header("Sec-Fetch-Site", "same-site")
    req.add_header("User-Agent", user_agent)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            if resp.status != 200:
                return None
            return json.loads(resp.read().decode("utf-8"))
    except Exception:
        return None


def merge_ranges(slots: List[Tuple[int, int]]) -> List[Tuple[int, int]]:
    if not slots:
        return []
    slots = sorted(slots, key=lambda x: x[0])
    merged = [slots[0]]
    for start, end in slots[1:]:
        last_start, last_end = merged[-1]
        if start == last_end:
            merged[-1] = (last_start, end)
        else:
            merged.append((start, end))
    return merged


def fmt_24(m: int) -> str:
    h = m // 60
    mi = m % 60
    return f"{h:02d}:{mi:02d}"


def build_summary(
    resp: dict,
    tf: Optional[int],
    tt: Optional[int],
    now_epoch: int,
    window_days: Optional[int],
    weekdays_allowed: Optional[set],
    target_weekday: Optional[int],
    week_offset: Optional[int],
) -> Tuple[List[str], Optional[datetime]]:
    # Collect per-day entries first so we can sort by date (latest → oldest)
    lines: List[str] = []
    entries: List[Tuple[datetime, str]] = []
    dates = resp.get("LocationAvailabilityDates") or []
    if not isinstance(dates, list):
        return lines, None

    now_midnight = (now_epoch // 86400) * 86400

    for day in dates:
        slots = day.get("AvailableTimeSlots") or []
        if not slots:
            continue

        # Window filter
        try:
            avail_date = parse_api_datetime(day.get("AvailabilityDate"))
        except Exception:
            continue
        avail_midnight = date_midnight_epoch(avail_date)

        if window_days is not None:
            dd = (avail_midnight - now_midnight) // 86400
            if dd < 0 or dd > window_days:
                continue

        # Weekday filter
        dow_name = (day.get("DayOfWeek") or "").strip().lower()
        dow_map = {"monday":1,"tuesday":2,"wednesday":3,"thursday":4,"friday":5,"saturday":6,"sunday":7}
        dow_num = dow_map.get(dow_name)
        if weekdays_allowed is not None and dow_num is not None:
            if dow_num not in weekdays_allowed:
                continue

        # Exact target weekday in future week offset
        if target_weekday is not None and week_offset is not None:
            # Compute target midnight from now
            now_dt = datetime.fromtimestamp(now_epoch, tz=timezone.utc)
            now_wd = int(now_dt.strftime("%u"))  # 1..7
            days = (target_weekday - now_wd + 7) % 7 + (week_offset * 7)
            target_midnight = date_midnight_epoch(now_dt + timedelta(days=days))
            if avail_midnight != target_midnight:
                continue

        # Collect ranges
        ranges: List[Tuple[int, int]] = []
        for s in slots:
            try:
                start_dt = parse_api_datetime(s.get("StartDateTime"))
                dur = int(s.get("Duration") or 15)
                start_min = start_dt.hour * 60 + start_dt.minute
                end_min = start_min + dur
                if (tf is None or start_min >= tf) and (tt is None or start_min < tt):
                    ranges.append((start_min, end_min))
            except Exception:
                continue

        ranges = merge_ranges(ranges)
        if not ranges:
            continue

        # Example: Monday, Sep 30: 07:30-16:45  (two spaces at end for Discord line break)
        dow_mon_day = f"{avail_date.strftime('%A, %b')} {avail_date.day}"
        times_str = ", ".join(f"{fmt_24(a)}-{fmt_24(b)}" for a, b in ranges)
        entries.append((avail_date, f"{dow_mon_day}: {times_str}  "))
    # Sort newest first for easier scanning and limit to top 5
    entries.sort(key=lambda x: x[0], reverse=True)
    entries = entries[:5]
    lines = [line for _, line in entries]
    latest_dt: Optional[datetime] = entries[0][0] if entries else None
    return lines, latest_dt


def main() -> int:
    os.makedirs(".availability", exist_ok=True)
    summary_path = ".availability/summary.txt"
    found_path = ".availability/found"

    base_url = read_env("BASE_URL", "https://publicwebsiteapi.nydmvreservation.com/api/AvailableLocationDates")
    type_id = read_env("TYPE_ID", "204")
    start_date = read_env("START_DATE", iso_now_utc())
    location_ids_raw = read_env("LOCATION_IDS", "") or ""
    token = read_env("BEARER_TOKEN", "") or ""
    origin = read_env("ORIGIN", "https://public.nydmvreservation.com")
    user_agent = read_env("USER_AGENT", "python-urllib/3 (GitHub Actions)")

    if not token or not location_ids_raw:
        with open(found_path, "w") as f:
            f.write("false")
        with open(summary_path, "w") as f:
            f.write("Missing BEARER_TOKEN or LOCATION_IDS\n")
        return 0

    location_ids = parse_location_ids(location_ids_raw)
    
    # Hardcoded location name mapping
    name_map = {
        "22": "Bethpage",
        "29": "Garden City", 
        "33": "Springfield",
        "19": "Jamaica",
        "36": "College Point"
    }

    tf = to_minutes_24h(read_env("TIME_FROM"))
    tt = to_minutes_24h(read_env("TIME_TO"))
    try:
        window_days = int(read_env("DATE_WINDOW_DAYS") or 0) or None
    except Exception:
        window_days = None
    
    # If no window_days specified, default to 60 days to capture more appointments
    if window_days is None:
        window_days = 60
    weekdays_allowed = allowed_weekdays_set(read_env("WEEKDAYS"))
    try:
        week_offset = int(read_env("WEEK_OFFSET") or 0) if read_env("WEEK_OFFSET") else None
    except Exception:
        week_offset = None
    target_weekday = weekday_to_num(read_env("TARGET_WEEKDAY") or "") if read_env("TARGET_WEEKDAY") else None
    now_epoch = int(read_env("NOW_EPOCH", str(int(datetime.now(timezone.utc).timestamp()))))

    # Build per-location blocks so we can sort locations by their latest available date
    all_lines: List[str] = []
    location_blocks: List[Tuple[Optional[datetime], str]] = []
    found_any = False

    for loc in location_ids:
        resp = fetch_location(base_url, token, origin, user_agent, loc, type_id, start_date)
        
        if not resp:
            display_name = name_map.get(str(loc)) or "Location"
            display_id = str(loc)
            all_lines.append(f"**{display_name} {display_id}**\n")
            continue

        lines, latest_dt = build_summary(
            resp, tf, tt, now_epoch, window_days, weekdays_allowed, target_weekday, week_offset
        )
        
        if lines:
            found_any = True
            # Discord supports markdown; make the header bold as "Name ID"
            display_name = name_map.get(str(loc)) or "Location"
            display_id = str(loc)
            block_text = f"**{display_name} {display_id}**\n" + "\n".join(lines) + "\n"
            location_blocks.append((latest_dt, block_text))
        else:
            display_name = name_map.get(str(loc)) or "Location"
            display_id = str(loc)
            all_lines.append(f"**{display_name} {display_id}**\n")

    # Sort locations by their latest available date ascending (earlier latest first),
    # then append any locations with no availability at the end in original order.
    if location_blocks:
        # Sort by latest date descending (latest latest first). Keep None at the end.
        location_blocks.sort(key=lambda x: (x[0] is None, -(x[0].timestamp() if x[0] else 0)))
        sorted_blocks = [blk for _, blk in location_blocks]
    else:
        sorted_blocks = []

    summary_parts: List[str] = []
    if sorted_blocks:
        summary_parts.append("\n".join(sorted_blocks).rstrip())
    if all_lines:
        summary_parts.append("\n".join(all_lines).rstrip())

    # Title and footer link for convenience
    body = "\n\n".join([p for p in summary_parts if p]).rstrip()
    title = "**📅 DMV Appointments Available**\n\n" if body else ""
    footer = "\n\n🔗 https://public.nydmvreservation.com/"
    summary = (title + body + footer).rstrip() + "\n"

    with open(summary_path, "w") as f:
        f.write(summary)
    with open(found_path, "w") as f:
        f.write("true" if found_any else "false")

    # Also print to stdout for local runs
    sys.stdout.write(summary)
    sys.stdout.flush()

    return 0


if __name__ == "__main__":
    sys.exit(main())


