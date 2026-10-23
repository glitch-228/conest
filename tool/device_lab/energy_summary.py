#!/usr/bin/env python3
"""What a lab run cost, per device and per hour (see energy.sh).

    tool/device_lab/energy_summary.py device-lab-reports/<run>
"""
import csv
import datetime
import pathlib
import re
import sys

def android(text):
    """CPU seconds, wakeup alarms, bytes and the span in hours, from the
    app's lines of `dumpsys batterystats --checkin` (energy.sh's file):
      9,UID,l,cpu,USER_MS,SYSTEM_MS,…
      9,UID,l,nt,MOBILE_RX,MOBILE_TX,WIFI_RX,WIFI_TX,…
      9,UID,l,wua,NAME,COUNT"""
    span = re.search(r"from (\S+) to (\S+)", text)
    hours = None
    if span:
        start, end = (datetime.datetime.fromisoformat(t.replace("Z", "+00:00"))
                      for t in span.groups())
        hours = max((end - start).total_seconds() / 3600, 1 / 3600)
    cpu = rx = tx = 0.0
    wakeups = 0
    measured = False
    for line in text.splitlines():
        fields = line.split(",")
        if len(fields) < 5 or fields[0] != "9" or fields[2] != "l":
            continue
        kind, values = fields[3], fields[4:]
        try:
            if kind == "cpu":
                cpu += (int(values[0]) + int(values[1])) / 1000
                measured = True
            elif kind == "nt":
                rx += int(values[0]) + int(values[2])
                tx += int(values[1]) + int(values[3])
            elif kind == "wua":
                wakeups += int(values[-1])
        except (ValueError, IndexError):
            continue
    return {"hours": hours, "cpu_s": cpu, "wakeups": wakeups,
            "rx": rx, "tx": tx, "measured": measured}


def desktop(path):
    """CPU seconds used, the span in hours, and the largest memory. A
    counter that goes down is a restarted process: its count starts over."""
    rows = list(csv.DictReader(open(path)))
    rows = [r for r in rows if r.get("time")]
    if len(rows) < 2:
        return None
    times = [datetime.datetime.fromisoformat(r["time"].replace("Z", "+00:00")
                                             .split("+")[0]) for r in rows]
    cpu = [float(r["cpu_seconds"]) for r in rows]
    memory = [float(list(r.values())[2]) for r in rows]
    hours = max((times[-1] - times[0]).total_seconds() / 3600, 1 / 3600)
    used = sum(b - a if b >= a else b for a, b in zip(cpu, cpu[1:]))
    return {"hours": hours, "cpu_s": used,
            "max_memory_mb": max(memory) / 1024}


def lines(folder):
    folder = pathlib.Path(folder)
    out = []
    for phone in sorted(folder.glob("energy-android*.txt")):
        if phone.name.endswith("-start.txt"):
            continue
        a = android(phone.read_text(errors="replace"))
        h = a["hours"] or 1
        name = phone.stem.removeprefix("energy-")
        if not a["measured"]:
            # No CPU line at all: Android counted nothing (a charging
            # phone, or stats reset under the run), which is not zero.
            out.append(f"  {name}: {h * 60:.0f} min, NOT MEASURED "
                       "(no CPU line in batterystats)")
            continue
        out.append(
            f"  {name}: {h * 60:.0f} min, CPU {a['cpu_s'] / h:.0f} s/h, "
            f"{a['wakeups'] / h:.0f} wakeups/h, "
            f"{(a['rx'] + a['tx']) / h / 1024 ** 2:.1f} MB/h")
    for side in ("android", "android2", "linux", "windows"):
        path = folder / f"energy-{side}.csv"
        if path.exists():
            d = desktop(path)
            if d:
                name = f"{side} (process)" if side.startswith("android") \
                    else side
                out.append(
                    f"  {name}: {d['hours'] * 60:.0f} min, CPU "
                    f"{d['cpu_s'] / d['hours']:.0f} s/h, memory up to "
                    f"{d['max_memory_mb']:.0f} MB")
    return out


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    print("===== battery and data (tool/device_lab/energy.sh)")
    for line in lines(sys.argv[1]):
        print(line)
