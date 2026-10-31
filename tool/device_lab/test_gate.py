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


def report(messages=(), steps=(), trouble=None, perf=None):
    calls = []
    if trouble is not None:
        calls.append({"groupCall": "g", "frames": {"trouble": trouble}})
    out = {"chats": [{"contact": "x", "messages": list(messages)}],
           "steps": list(steps), "calls": calls}
    if perf is not None:
        out["performance"] = perf
    return out


def perf(frames=1000, slow_share=0.0, p95=8.0, handling=10.0):
    return {"frames": {"frames": frames, "slowShare": slow_share,
                       "buildP95Ms": p95, "rasterP95Ms": p95 / 2},
            "handling": {"count": 50, "p95Ms": handling}}


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

    def test_budgets_judge_the_app_itself(self):
        smooth = self.three(perf=perf())
        self.assertEqual(gate.over_budget(smooth), [])
        janky = self.run_folder(
            android=report(perf=perf(slow_share=0.05, p95=20.0)),
            linux=report(perf=perf(slow_share=0.02)),
            windows=report(perf=perf(handling=80.0)))
        why = gate.over_budget(janky)
        # The phone may drop more frames, and 20 ms is within its 32 ms.
        self.assertFalse(any(w.startswith("android") for w in why))
        self.assertIn("linux: 2.0% of frames slow", why)
        self.assertTrue(any(w.startswith("windows: messages handled") for w in why))
        few = self.three(perf=perf(frames=50, slow_share=0.5, p95=90.0))
        self.assertEqual(gate.over_budget(few), [], "too few frames to judge")

    def test_slower_handling_than_last_time_is_a_regression(self):
        base = self.three(perf=perf(handling=10.0))
        self.assertEqual(gate.regressions(self.three(perf=perf(handling=14.0)), base), [])
        why = gate.regressions(self.three(perf=perf(handling=45.0)), base)
        self.assertTrue(any("messages handled in 45 ms" in w for w in why))

    def test_budgets_apply_only_when_asked(self):
        base = self.three(perf=perf())
        slow = self.three(perf=perf(handling=60.0, p95=8.0))
        self.assertEqual(
            [w for w in gate.regressions(slow, None) if "handled" in w], [])
        self.assertTrue(gate.regressions(slow, None, budgets=True))
        self.assertTrue(gate.regressions(slow, base, budgets=True))

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
