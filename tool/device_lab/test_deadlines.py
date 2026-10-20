"""Tests for deadlines.py:  python3 -m unittest tool/device_lab/test_deadlines.py"""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import deadlines  # noqa: E402


def message(ms, route="irohDirect", mark="confirmed", device=None, **extra):
    trace = {"route": route, "mark": mark, "ms": ms}
    if device:
        trace["device"] = device
    return {"outbound": True, "body": "lab burst", "traces": [trace], **extra}


def report(device, messages=(), only=None, **extra):
    return {"deviceId": device, "onlyTransport": only,
            "chats": [{"contact": "x", "messages": list(messages)}], **extra}


class DeadlinesTest(unittest.TestCase):
    def rows(self, reports):
        return {(t, g): (n, p95, ok) for t, g, n, _, p95, _, _, ok
                in deadlines.evaluate(reports)}

    def test_fast_messages_meet_two_seconds(self):
        rows = self.rows({"a": report("A", [message(300)] * 19
                                      + [message(1900)])})
        self.assertEqual(rows[("message", "fast")], (20, 1900, True))

    def test_a_slow_fast_message_misses(self):
        rows = self.rows({"a": report("A", [message(300)] * 18
                                      + [message(2500)] * 2)})
        self.assertFalse(rows[("message", "fast")][2])

    def test_a_message_never_confirmed_counts_as_late(self):
        never = {"outbound": True, "body": "lab 1", "traces": []}
        rows = self.rows({"a": report("A", [message(100, "nostrCarrier")] * 10
                                      + [never], only="nostr")})
        self.assertEqual(rows[("message", "mid")][0], 11)
        self.assertFalse(rows[("message", "mid")][2])

    def test_carriers_get_thirty_seconds(self):
        rows = self.rows({"a": report("A", [message(25_000, "emailCarrier")])})
        self.assertEqual(rows[("message", "carrier")], (1, 25_000, True))

    def test_exempt_routes_have_no_deadline(self):
        rows = self.rows({"a": report("A", [message(90_000, "bitchat")])})
        self.assertTrue(rows[("message", "exempt")][2])

    def test_group_members_each_count(self):
        m = message(500, device="B")
        m["traces"].append({"route": "conestRelay", "mark": "confirmed",
                            "ms": 3000, "device": "C"})
        rows = self.rows({"a": report("A", [m])})
        self.assertEqual(rows[("message", "fast")][0], 2)
        self.assertFalse(rows[("message", "fast")][2])

    def test_a_removal_is_timed_by_the_other_side(self):
        a = report("A", timings=[{"task": "remove", "deviceId": "B",
                                  "at": "2026-10-20T10:00:00Z"}])
        b = report("B", events=[{"event": "contact-gone", "deviceId": "A",
                                 "at": "2026-10-20T10:00:20Z"}])
        rows = self.rows({"a": a, "b": b})
        self.assertEqual(rows[("contact", "fast")], (1, 20_000, False))

    def test_an_earlier_departure_does_not_count(self):
        a = report("A", timings=[{"task": "remove", "deviceId": "B",
                                  "at": "2026-10-20T10:00:00Z"}])
        b = report("B", events=[{"event": "contact-gone", "deviceId": "A",
                                 "at": "2026-10-20T09:59:00Z"}])
        rows = self.rows({"a": a, "b": b})
        self.assertEqual(rows[("contact", "fast")][1], None)

    def test_a_removal_never_seen_misses(self):
        a = report("A", timings=[{"task": "remove", "deviceId": "B",
                                  "at": "2026-10-20T10:00:00Z"}])
        rows = self.rows({"a": a, "b": report("B")})
        self.assertEqual(rows[("contact", "fast")][1], None)
        self.assertFalse(rows[("contact", "fast")][2])

    def test_a_one_megabyte_file_has_fifteen_seconds(self):
        f = message(16_000, file="lab-1048576.bin", bytes=1048576)
        rows = self.rows({"a": report("A", [f])})
        self.assertFalse(rows[("file 1 MB", "fast")][2])
        big = message(60_000, file="lab-52428800.bin", bytes=52428800)
        rows = self.rows({"a": report("A", [big])})
        self.assertTrue(rows[("file 50 MB", "fast")][2])

    def test_pairing_is_timed_from_the_invite(self):
        rows = self.rows({"a": report("A", pairedAfterInviteMs={"lab-1": 9000},
                                      only="deltaChat")})
        self.assertEqual(rows[("contact", "carrier")], (1, 9000, True))


if __name__ == "__main__":
    unittest.main()
