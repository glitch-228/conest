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

NOISE = re.compile(r"Attachment crypto:")
WORTH = re.compile(
    r"(?i)error|fail|invalid|dropped|refus|rejected|timeout|denied|no route"
)


def main(folder: str) -> None:
    reports = {}
    for path in sorted(pathlib.Path(folder).glob("*.json")):
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


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
