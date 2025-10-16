# apps/scheduler/main.py
import os
import time
from datetime import datetime, timedelta, timezone

# IMPORTANT: import via the full package path from the repo root
from apps.workers.jobs import youtube_rss_poll


def main() -> None:
    channels = [c.strip() for c in os.getenv("YT_CHANNELS", "").split(",") if c.strip()]
    poll_min = int(os.getenv("POLL_INTERVAL_MIN", "15"))
    published_after_hours = int(os.getenv("PUBLISHED_AFTER_HOURS", "72"))

    if not channels:
        print("[scheduler] YT_CHANNELS is empty; nothing to poll.")
        while True:
            time.sleep(300)

    while True:
        since = datetime.now(timezone.utc) - timedelta(hours=published_after_hours)
        for ch in channels:
            try:
                youtube_rss_poll(ch, published_after=since, max_items=15)
            except Exception as e:
                print(f"[scheduler] poll error channel={ch}: {e}")
        time.sleep(poll_min * 60)


if __name__ == "__main__":
    main()
