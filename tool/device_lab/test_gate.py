"""Tests for gate.py:  python3 -m unittest tool/device_lab/test_gate.py"""
import json
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import gate  # noqa: E402


def text(outbound=True, state="delivered"):
    return {"outbound": outbound, "body": "lab burst 1", "file": None,
            "state": state, "traces": []}


def file(available=True):
    return {"outbound": False, "body": "", "file": "lab-1048576.bin",
            "available": available, "state": "delivered", "traces": []}


def report(messages=(), steps=(), trouble=None):
    calls = []
    if trouble is not None:
        calls.append({"groupCall": "g", "frames": {"trouble": trouble}})
    return {"chats": [{"contact": "x", "messages": list(messages)}],
            "steps": list(steps), "calls": calls}


class GateTest(unittest.TestCase):
    def run_folder(self, **reports):
        folder = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(lambda: [p.unlink() for p in folder.glob("*")]
                        and folder.rmdir())
        for name, content in reports.items():
            (folder / f"{name}.json").write_text(json.dumps(content))
        return gate.metrics(folder)

    def three(self, **each):
        return self.run_folder(android=report(**each), linux=report(**each),
                               windows=report(**each))

    def test_a_run_like_the_last_passes(self):
        base = self.three(messages=[text()] * 10 + [file()])
        now = self.three(messages=[text()] * 10 + [file()])
        self.assertEqual(gate.regressions(now, base), [])

    def test_a_missing_device_fails_even_without_a_baseline(self):
        now = self.run_folder(android=report(), linux=report())
        self.assertEqual(gate.regressions(now, None), ["no report from windows"])

    def test_fewer_confirmed_texts_fail(self):
        base = self.three(messages=[text()] * 20)
        now = self.three(messages=[text()] * 15 + [text(state="sent")] * 5)
        self.assertTrue(any("texts confirmed" in why
                            for why in gate.regressions(now, base)))

    def test_one_late_text_in_twenty_is_within_slack(self):
        base = self.three(messages=[text()] * 20)
        now = self.three(messages=[text()] * 19 + [text(state="sent")])
        self.assertEqual(gate.regressions(now, base), [])

    def test_a_file_that_never_finished_fails(self):
        base = self.three(messages=[file()])
        now = self.three(messages=[file(available=False)])
        self.assertTrue(any("files complete" in why
                            for why in gate.regressions(now, base)))

    def test_a_step_failing_now_fails(self):
        base = self.three(steps=[{"step": "carrier tor", "ok": False}])
        now = self.three(steps=[{"step": "carrier tor", "ok": False},
                                {"step": "carrier email", "ok": False}])
        why = gate.regressions(now, base)
        self.assertEqual(len(why), 1)
        self.assertIn("carrier email", why[0])
        self.assertNotIn("carrier tor", why[0])

    def test_call_trouble_counts_only_when_much_worse(self):
        base = self.three(trouble={"a: sends backed up": 40})
        self.assertEqual(gate.regressions(
            self.three(trouble={"a: sends backed up": 70}), base), [])
        self.assertTrue(gate.regressions(
            self.three(trouble={"a: sends backed up": 400}), base))

    def test_check_exits_1_on_a_regression(self):
        folder = pathlib.Path(tempfile.mkdtemp())
        for name in gate.DEVICES:
            (folder / f"{name}.json").write_text(
                json.dumps(report(messages=[file()])))
        baseline = folder / "gate-baseline.out"
        self.assertEqual(gate.main(["record", str(baseline), f"lan={folder}"]), 0)
        self.assertEqual(gate.main(["check", str(baseline), f"lan={folder}"]), 0)
        for name in gate.DEVICES:
            (folder / f"{name}.json").write_text(
                json.dumps(report(messages=[file(available=False)])))
        self.assertEqual(gate.main(["check", str(baseline), f"lan={folder}"]), 1)


if __name__ == "__main__":
    unittest.main()
