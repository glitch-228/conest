"""The release gate: what each lab run delivered, against the last gate
that passed. A run is named by its label (transport and order, such as
"nostr-normal"), so the same run is compared with itself.

  python3 gate.py record <out.json> <label>=<run folder> ...
  python3 gate.py check <baseline.json> [--budgets] <label>=<run folder> ...

`check` prints each regression and exits 1 when there is one; with no
baseline yet (the file missing) it only checks that every device reported.
With --budgets (the full gate, before a stable) the app's own stutter and
latency must also stay within fixed budgets, whatever the baseline.
"""
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import deadlines  # noqa: E402

DEVICES = ("android", "linux", "windows")
# Confirmed texts may fall this much (as a share) before it is a regression:
# a carrier's timing varies from run to run.
TEXT_SLACK = 0.05
# Frame trouble in calls is noisy: a regression only above twice the
# baseline and this many more.
TROUBLE_FLOOR = 50
# Frames are judged only with enough of them drawn.
MIN_FRAMES = 100
# The full gate's budgets for the app itself (not the network).
DESKTOP_SLOW_SHARE = 0.01
DESKTOP_FRAME_P95_MS = 16.0
PHONE_FRAME_P95_MS = 32.0
HANDLING_P95_MS = 50.0


def _reports(folder):
    reports = {}
    for path in sorted(pathlib.Path(folder).glob("*.json")):
        if "." in path.stem:
            continue
        try:
            reports[path.stem] = json.loads(path.read_text())
        except (ValueError, OSError):
            pass
    return reports


def metrics(folder):
    """The numbers one run is judged by."""
    reports = _reports(folder)
    out = {
        "devices": sorted(reports),
        "texts_out": 0,
        "texts_confirmed": 0,
        "texts_in": 0,
        "files_in": 0,
        "files_complete": 0,
        "failed_steps": [],
        # Which deadlines were missed (task and group, not the times).
        "missed_deadlines": sorted({
            f"{task} {group}"
            for task, group, _, _, _, _, _, ok in deadlines.evaluate(reports)
            if not ok}),
        "frame_trouble": 0,
        # Per device: the app's own frames and message handling.
        "performance": {},
    }
    for name, report in reports.items():
        perf = report.get("performance") or {}
        frames = perf.get("frames") or {}
        handling = perf.get("handling") or {}
        out["performance"][name] = {
            "frames": frames.get("frames", 0),
            "slow_share": frames.get("slowShare", 0.0),
            "frame_p95_ms": max(frames.get("buildP95Ms", 0.0),
                                frames.get("rasterP95Ms", 0.0)),
            "handling_p95_ms": handling.get("p95Ms", 0.0),
        }
        for chat in report.get("chats", []):
            for m in chat.get("messages", []):
                if m.get("file"):
                    if not m.get("outbound"):
                        out["files_in"] += 1
                        out["files_complete"] += bool(m.get("available"))
                    continue
                if m.get("outbound"):
                    out["texts_out"] += 1
                    out["texts_confirmed"] += m.get("state") in ("delivered", "read")
                else:
                    out["texts_in"] += 1
        for step in report.get("steps", []):
            if not step.get("ok"):
                out["failed_steps"].append(f"{name}: {step.get('step')}")
        calls = list(report.get("calls", [])) + [
            t for t in report.get("timings", []) if t.get("task") == "group-call"]
        for call in calls:
            out["frame_trouble"] += sum(
                (call.get("frames") or {}).get("trouble", {}).values())
    out["failed_steps"].sort()
    return out


def over_budget(current):
    """Where the app itself stutters or is slow, whatever the baseline."""
    why = []
    for device, perf in sorted(current.get("performance", {}).items()):
        phone = device.startswith("android")
        if perf["frames"] >= MIN_FRAMES:
            if not phone and perf["slow_share"] > DESKTOP_SLOW_SHARE:
                why.append(f"{device}: {perf['slow_share']:.1%} of frames slow")
            limit = PHONE_FRAME_P95_MS if phone else DESKTOP_FRAME_P95_MS
            if perf["frame_p95_ms"] > limit:
                why.append(f"{device}: p95 frame {perf['frame_p95_ms']:.1f} ms")
        if perf["handling_p95_ms"] > HANDLING_P95_MS:
            why.append(f"{device}: messages handled in "
                       f"{perf['handling_p95_ms']:.0f} ms (p95)")
    return why


def _perf_regressions(current, baseline):
    why = []
    before = baseline.get("performance", {})
    for device, perf in sorted(current.get("performance", {}).items()):
        old = before.get(device)
        if not old:
            continue
        if (perf["frames"] >= MIN_FRAMES and old["frames"] >= MIN_FRAMES
                and perf["slow_share"] > 2 * old["slow_share"]
                and perf["slow_share"] > old["slow_share"] + 0.01):
            why.append(f"{device}: slow frames {perf['slow_share']:.1%}"
                       f" (was {old['slow_share']:.1%})")
        if (perf["handling_p95_ms"] > 1.5 * old["handling_p95_ms"]
                and perf["handling_p95_ms"] > old["handling_p95_ms"] + 20):
            why.append(f"{device}: messages handled in "
                       f"{perf['handling_p95_ms']:.0f} ms p95"
                       f" (was {old['handling_p95_ms']:.0f})")
    return why


def regressions(current, baseline, budgets=False):
    """Why [current] is worse than [baseline] (both from [metrics]); with
    [budgets], also where it is over the app's own budgets."""
    why = over_budget(current) if budgets else []
    missing = sorted(set(DEVICES) - set(current["devices"]))
    if missing:
        why.append("no report from " + ", ".join(missing))
    if baseline is None:
        return why

    def share(m):
        return m["texts_confirmed"] / m["texts_out"] if m["texts_out"] else 1.0

    if share(current) < share(baseline) - TEXT_SLACK:
        why.append(
            f"texts confirmed {current['texts_confirmed']}/{current['texts_out']}"
            f" (was {baseline['texts_confirmed']}/{baseline['texts_out']})")
    if current["texts_in"] < baseline["texts_in"] * (1 - TEXT_SLACK):
        why.append(f"texts received {current['texts_in']}"
                   f" (was {baseline['texts_in']})")
    if current["files_complete"] < baseline["files_complete"]:
        why.append(
            f"files complete {current['files_complete']}/{current['files_in']}"
            f" (was {baseline['files_complete']}/{baseline['files_in']})")
    new_steps = sorted(set(current["failed_steps"]) - set(baseline["failed_steps"]))
    if new_steps:
        why.append("steps failing now: " + "; ".join(new_steps))
    new_late = sorted(
        set(current["missed_deadlines"]) - set(baseline["missed_deadlines"]))
    if new_late:
        why.append("deadlines missed now: " + ", ".join(new_late))
    if (current["frame_trouble"] > 2 * baseline["frame_trouble"]
            and current["frame_trouble"] > baseline["frame_trouble"] + TROUBLE_FLOOR):
        why.append(f"call frame trouble {current['frame_trouble']}"
                   f" (was {baseline['frame_trouble']})")
    why.extend(_perf_regressions(current, baseline))
    return why


def _runs(args):
    runs = {}
    for arg in args:
        label, _, folder = arg.partition("=")
        if not folder:
            raise SystemExit(f"not label=folder: {arg}")
        runs[label] = metrics(folder)
    return runs


def main(argv):
    if len(argv) < 3 or argv[0] not in ("record", "check"):
        raise SystemExit(__doc__)
    path = pathlib.Path(argv[1])
    rest = argv[2:]
    budgets = "--budgets" in rest
    runs = _runs([arg for arg in rest if arg != "--budgets"])
    if argv[0] == "record":
        path.write_text(json.dumps(runs, indent=1, sort_keys=True))
        return 0
    baseline = json.loads(path.read_text()) if path.exists() else {}
    failed = False
    for label, current in runs.items():
        why = regressions(current, baseline.get(label), budgets=budgets)
        status = "REGRESSION" if why else "ok"
        print(f"{label}: {status}" + ("" if not why else ": " + "; ".join(why)))
        failed |= bool(why)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
