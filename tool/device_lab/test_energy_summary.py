"""Tests for energy_summary.py:
python3 -m unittest tool/device_lab/test_energy_summary.py"""
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import energy_summary  # noqa: E402

SPAN = "from 2026-10-23T13:00:00Z to 2026-10-23T14:00:00Z\nuid 10384\n"


class AndroidEnergyTest(unittest.TestCase):
    def summary(self, text):
        with tempfile.TemporaryDirectory() as folder:
            (pathlib.Path(folder) / "energy-android.txt").write_text(text)
            return energy_summary.lines(folder)

    def test_counted_hour(self):
        out = self.summary(SPAN + "9,10384,l,cpu,30000,6000,0\n"
                           "9,10384,l,wua,*alarm*,12\n"
                           "9,10384,l,nt,0,0,1048576,1048576\n")
        self.assertEqual(
            out, ["  android: 60 min, CPU 36 s/h, 12 wakeups/h, 2.0 MB/h"])

    def test_nothing_counted_is_not_zero(self):
        # A charging phone: batterystats has the app's lines but no CPU.
        out = self.summary(SPAN + "9,10384,l,pwi,uid,0,0,0,0\n"
                           "9,10384,l,awl,0,0\n")
        self.assertEqual(len(out), 1)
        self.assertIn("NOT MEASURED", out[0])
        self.assertNotIn("CPU 0 s/h", out[0])


class ProcessSamplesTest(unittest.TestCase):
    def test_a_restart_does_not_lose_or_invent_cpu(self):
        with tempfile.TemporaryDirectory() as folder:
            (pathlib.Path(folder) / "energy-android.csv").write_text(
                "time,cpu_seconds,rss_kb\n"
                "2026-10-23T13:00:00Z,100,50000\n"
                "2026-10-23T13:30:00Z,130,60000\n"
                # The app restarted: its counter starts again from 0.
                "2026-10-23T13:40:00Z,5,40000\n"
                "2026-10-23T14:00:00Z,25,45000\n")
            out = energy_summary.lines(folder)
        # 30 s, then 5 s in the new process, then 20 s: 55 s in an hour.
        self.assertEqual(
            out, ["  android (process): 60 min, CPU 55 s/h, memory up to 59 MB"])


if __name__ == "__main__":
    unittest.main()
