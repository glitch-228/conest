#!/usr/bin/env python3
"""Summarise a device-lab run: what each device sent and received, in each
chat and lab group, the route tests, and the errors worth reading.

    tool/device_lab/summarize.py device-lab-reports/<run>

Expected per ordered pair: 3 messages and 3 files each way; in a group,
3 messages and 3 files from every other member. With interactions: an
edit, a reply, a reaction, a deletion and a cancelled file per chat and
group.
"""
import collections
import json
import pathlib
import re
import sys

import deadlines
import energy_summary

NOISE = re.compile(r"Attachment crypto:")
WORTH = re.compile(
    r"(?i)error|fail|invalid|dropped|refus|rejected|timeout|denied|no route"
)


def main(folder: str) -> None:
    reports = {}
    for path in sorted(pathlib.Path(folder).glob("*.json")):
        # A serve run's phase reports (linux.json.p1.json) are summarised
        # in their own folders.
        if "." in path.stem:
            continue
        try:
            reports[path.stem] = json.loads(path.read_text())
        except (ValueError, OSError) as error:
            print(f"{path.name}: unreadable ({error})")
    names = {r.get("deviceId"): n for n, r in reports.items()}

    def who(device_id):
        return names.get(device_id, device_id or "?")

    for name, report in reports.items():
        print(f"===== {name}  {report.get('startedAt', '')[11:19]}"
              f" - {report.get('finishedAt', '')[11:19]}")
        failed = [s for s in report.get("steps", []) if not s.get("ok")]
        print(f"  steps: {len(report.get('steps', []))}, failed: "
              + (", ".join(f"{s['step']} ({s.get('error', '')[:80]})"
                           for s in failed) or "none"))
        carriers = report.get("carriers") or {}
        for moment in ("start", "end"):
            states = carriers.get(moment) or []
            if states:
                print(f"  carriers at {moment}: " + ", ".join(
                    f"{c['kind']} {'ready' if c.get('ready') else 'NOT READY'}"
                    + (f" ({c['error'][:60]})" if c.get("error") else "")
                    for c in states))
        for chat in report.get("chats", []):
            label = chat.get("group") or who(chat.get("deviceId"))
            sent = collections.Counter()
            got = collections.Counter()
            members = collections.Counter()
            extras = collections.Counter()
            for m in chat.get("messages", []):
                kind = "file" if m.get("file") else "text"
                if m.get("outbound"):
                    sent[(kind, m.get("state"))] += 1
                    for member, state in (m.get("recipients") or {}).items():
                        members[(kind, who(member), state)] += 1
                else:
                    got[kind] += 1
                for extra in ("edited", "replyTo", "reactions"):
                    if m.get(extra):
                        extras[(("out " if m.get("outbound") else "in ")
                                + extra)] += 1
                if "delete-me" in (m.get("body") or "") and not m.get("outbound"):
                    extras["in NOT DELETED"] += 1
            print(f"  {label}: sent {dict(sent)}; received {dict(got)}")
            if members:
                print(f"    members {dict(members)}")
            if extras:
                print(f"    {dict(extras)}")
        for contact in report.get("contacts", []):
            r = contact.get("report") or {}

            def results(side):
                return ", ".join(
                    f"{x['family']} "
                    + (f"{x['ms']}ms" if x.get("ms") is not None
                       else "stored" if x.get("stored") else "no")
                    for x in (r.get(side) or {}).get("results", []))

            print(f"  routes to {who(contact.get('deviceId'))}: "
                  f"out [{results('local')}] back [{results('remote')}]"
                  + (f" ERROR {contact['error']}" if contact.get("error") else ""))
        seen = collections.Counter()
        for line in (report.get("errorHistory") or "").splitlines():
            if line[28:].strip() and WORTH.search(line) and not NOISE.search(line):
                # Same message, different ids and numbers: counted once.
                seen[re.sub(r"[0-9a-f]{8,}|\d+", "#", line[28:200])] += 1
        for line, count in seen.most_common(12):
            print(f"    {count:4d} x {line}")
    print("===== how long things took (tool/device_lab/deadlines.py)")
    for line in deadlines.lines(reports):
        print(line)
    energy = energy_summary.lines(folder)
    if energy:
        print("===== battery and data (tool/device_lab/energy.sh)")
        for line in energy:
            print(line)


def verdict(folder: str) -> str:
    """One line: contacts each device has, and 1:1 and group texts that
    went out and were confirmed, and that came in."""
    reports = {}
    for path in sorted(pathlib.Path(folder).glob("*.json")):
        # A serve run's phase reports (linux.json.p1.json) are summarised
        # in their own folders.
        if "." in path.stem:
            continue
        try:
            reports[path.stem] = json.loads(path.read_text())
        except (ValueError, OSError):
            pass
    parts = []
    for name, report in reports.items():
        direct_out = direct_ok = direct_in = group_out = group_ok = group_in = 0
        contacts = 0
        for chat in report.get("chats", []):
            group = chat.get("group") is not None
            contacts += 0 if group else 1
            for m in chat.get("messages", []):
                if m.get("file"):
                    continue
                if m.get("outbound"):
                    ok = m.get("state") in ("delivered", "read")
                    if group:
                        group_out += 1
                        group_ok += ok
                    else:
                        direct_out += 1
                        direct_ok += ok
                elif group:
                    group_in += 1
                else:
                    direct_in += 1
        failed = sum(1 for s in report.get("steps", []) if not s.get("ok"))
        paired = report.get("pairedAfterMs") or {}
        times = sorted(
            s["result"] for s in report.get("steps", [])
            if s.get("step", "").startswith("message ")
            and isinstance(s.get("result"), int))
        timing = ""
        if paired:
            timing += f", paired after {max(paired.values()) / 1000:.1f} s"
        if times:
            timing += f", messages confirmed in {times[len(times) // 2]} ms (median)"
        parts.append(
            f"{name}: {contacts} contacts, 1:1 {direct_ok}/{direct_out} "
            f"confirmed {direct_in} in, group {group_ok}/{group_out} "
            f"confirmed {group_in} in{timing}"
            + (f", {failed} failed steps" if failed else ""))
    missing = {"android", "linux", "windows"} - set(reports)
    if missing:
        parts.append("no report from " + ", ".join(sorted(missing)))
    late = deadlines.missed(reports)
    parts.append("deadlines: " + ("all met" if not late else
                                  "MISSED " + ", ".join(late)))
    return "; ".join(parts)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--verdict":
        print(verdict(sys.argv[2]))
    elif len(sys.argv) == 2:
        main(sys.argv[1])
    else:
        sys.exit(__doc__)
