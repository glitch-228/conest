"""How long each task took in a device-lab run, against the deadlines.

Deadlines (user, 2026-10-20), at the 95th percentile:

  route group   small message   contact added/removed, member   1 MB file
  fast          2 s             15 s                            15 s
  mid           15 s            15 s                            15 s
  carrier       30 s            30 s                            -
  exempt        measured only

fast: LAN, Iroh, Conest relays; mid: Tor, Nostr; carrier: email, Matrix;
exempt: Reticulum, the Bluetooth mesh, radios, forwarding through a
contact. Larger files are measured as throughput, without a deadline.

Times come from the reports (debug_auto_run.dart): a sent message's
marks, in ms after it was written, on the sender's own clock; contacts
and members coming and going from each device's events, against the
other device's clock (the lab devices are NTP-synced).
"""
import datetime

ROUTE_GROUPS = {
    "lanDirect": "fast", "lanRelay": "fast", "lanLobby": "fast",
    "internetDirect": "fast", "irohDirect": "fast", "irohRelay": "fast",
    "conestRelay": "fast",
    "torOnion": "mid", "nostrCarrier": "mid",
    "emailCarrier": "carrier", "matrixCarrier": "carrier",
    "plainMatrix": "carrier",
}

TRANSPORT_GROUPS = {
    "lan": "fast", "iroh": "fast", "conestRelay": "fast",
    "tor": "mid", "nostr": "mid",
    "deltaChat": "carrier", "matrix": "carrier",
}

DEADLINES_MS = {
    "message": {"fast": 2_000, "mid": 15_000, "carrier": 30_000},
    "contact": {"fast": 15_000, "mid": 15_000, "carrier": 30_000},
    "file 1 MB": {"fast": 15_000, "mid": 15_000},
}

ONE_MB = 1024 * 1024


def route_group(route):
    return ROUTE_GROUPS.get(route, "exempt")


def run_group(report):
    """The deadline group of a whole run: its one transport, or fast."""
    only = report.get("onlyTransport")
    return TRANSPORT_GROUPS.get(only, "exempt") if only else "fast"


def _at(text):
    return datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))


def _confirmed(message):
    """{device or None: (ms, route)}: when each recipient confirmed it."""
    best = {}
    for trace in message.get("traces") or []:
        if trace.get("mark") not in ("confirmed", "reachedDevice"):
            continue
        key = trace.get("device")
        ms = trace.get("ms")
        if ms is None:
            continue
        if key not in best or ms < best[key][0]:
            best[key] = (ms, trace.get("route"))
    return best


def samples(reports):
    """{(task, group): [ms or None (never)]} over every report."""
    out = {}

    def add(task, group, ms):
        out.setdefault((task, group), []).append(ms)

    by_device = {r.get("deviceId"): r for r in reports.values()}
    for report in reports.values():
        group_of_run = run_group(report)
        for chat in report.get("chats", []):
            in_group = chat.get("group") is not None
            for m in chat.get("messages", []):
                if not m.get("outbound"):
                    # Group files: one way, from when it was written to
                    # when it arrived here (two clocks).
                    if in_group and m.get("file") and m.get("arrivedAt"):
                        ms = (_at(m["arrivedAt"]) - _at(m["at"])) / \
                            datetime.timedelta(milliseconds=1)
                        size = m.get("bytes") or 0
                        task = "file 1 MB" if size <= ONE_MB else \
                            f"file {size // ONE_MB} MB"
                        add(task, group_of_run, int(ms))
                    continue
                if m.get("body", "") == "lab-done":
                    continue
                confirmed = _confirmed(m)
                size = m.get("bytes")
                if m.get("file"):
                    task = "file 1 MB" if (size or 0) <= ONE_MB else \
                        f"file {(size or 0) // ONE_MB} MB"
                else:
                    task = "message"
                if not confirmed:
                    add(task, group_of_run, None)
                    continue
                for ms, route in confirmed.values():
                    add(task, route_group(route), ms)
        for alias, ms in (report.get("pairedAfterInviteMs") or {}).items():
            add("contact", group_of_run, ms)
        # Removals and additions, against the other side's events.
        for timing in report.get("timings") or []:
            task = timing.get("task")
            other = by_device.get(timing.get("deviceId"))
            if task == "add-back":
                add("contact", group_of_run, timing.get("ms"))
                continue
            if task == "message-after-add-back":
                add("message", group_of_run, timing.get("ms"))
                continue
            wanted = {
                "remove": ("contact-gone", "deviceId", report.get("deviceId")),
                "remove-member": ("member-gone", "group", timing.get("group")),
                "add-member": ("member", "group", timing.get("group")),
            }.get(task)
            if wanted is None or other is None or not timing.get("at"):
                if wanted is not None:
                    add("contact", group_of_run, None)
                continue
            event, field, value = wanted
            since = _at(timing["at"])
            seen = [
                (_at(e["at"]) - since) / datetime.timedelta(milliseconds=1)
                for e in other.get("events") or []
                if e.get("event") == event and e.get(field) == value
                and _at(e["at"]) >= since
            ]
            add("contact", group_of_run, int(min(seen)) if seen else None)
    return out


def percentile(values, fraction):
    """Of [ms or None]: None (never happened) counts as longest."""
    ordered = sorted(values, key=lambda v: float("inf") if v is None else v)
    if not ordered:
        return None
    return ordered[min(len(ordered) - 1, int(fraction * len(ordered)))]


def evaluate(reports):
    """Rows: (task, group, n, p50, p95, max, deadline or None, ok)."""
    rows = []
    for (task, group), values in sorted(samples(reports).items()):
        deadline = DEADLINES_MS.get(task, {}).get(group)
        p95 = percentile(values, 0.95)
        ok = deadline is None or (p95 is not None and p95 <= deadline)
        rows.append((task, group, len(values), percentile(values, 0.5), p95,
                     percentile(values, 1.0), deadline, ok))
    return rows


def _fmt(ms):
    return "never" if ms is None else f"{ms / 1000:.1f}s"


def lines(reports):
    out = []
    for task, group, n, p50, p95, top, deadline, ok in evaluate(reports):
        limit = f" (deadline {_fmt(deadline)})" if deadline else ""
        mark = "" if deadline is None else (" ok" if ok else " MISSED")
        out.append(f"  {task:<10} {group:<8} n={n:<3} p50 {_fmt(p50)}"
                   f"  p95 {_fmt(p95)}  max {_fmt(top)}{limit}{mark}")
    return out


def missed(reports):
    return [f"{task} {group} p95 {_fmt(p95)} > {_fmt(deadline)}"
            for task, group, _, _, p95, _, deadline, ok in evaluate(reports)
            if not ok]
