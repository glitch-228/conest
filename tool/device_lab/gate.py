"""The release gate: what each lab run delivered, against the last gate
that passed. A run is named by its label (transport and order, such as
"nostr-normal"), so the same run is compared with itself.

  python3 gate.py record <out.json> <label>=<run folder> ...
  python3 gate.py check <baseline.json> <label>=<run folder> ...

`check` prints each regression and exits 1 when there is one; with no
baseline yet (the file missing) it only checks that every device reported.
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
    }
    for name, report in reports.items():
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


def regressions(current, baseline):
    """Why [current] is worse than [baseline] (both from [metrics])."""
    why = []
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
    runs = _runs(argv[2:])
    if argv[0] == "record":
        path.write_text(json.dumps(runs, indent=1, sort_keys=True))
        return 0
    baseline = json.loads(path.read_text()) if path.exists() else {}
    failed = False
    for label, current in runs.items():
        why = regressions(current, baseline.get(label))
        status = "REGRESSION" if why else "ok"
        print(f"{label}: {status}" + ("" if not why else ": " + "; ".join(why)))
        failed |= bool(why)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
