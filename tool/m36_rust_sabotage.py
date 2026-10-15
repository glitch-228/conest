"""CI-only negative checks for the M36 audio tests. Never builds locally."""
from pathlib import Path
import subprocess


def fails_when_broken(path, before, after, test):
    original = path.read_text()
    assert original.count(before) == 1, f"Sabotage anchor changed: {path}"
    try:
        path.write_text(original.replace(before, after))
        result = subprocess.run(
            ["cargo", "test", "-p", "conest_native", "--locked", test],
            capture_output=True, text=True)
        # A compile error is not evidence that the behavioral test works.
        assert result.returncode != 0 and "test result: FAILED" in result.stdout, (
            f"Sabotage did not fail the test: {test}\n{result.stdout}\n{result.stderr}")
        print(f"PASS negative check: {test} fails with behavior removed")
    finally:
        path.write_text(original)


fails_when_broken(
    Path("native/conest_native/src/audio.rs"),
    "config.noise_suppression = enabled.then(",
    "config.noise_suppression = false.then(",
    "noise_suppression_reduces_noise_and_preserves_changing_voiced_signal")
fails_when_broken(
    Path("native/conest_native/src/audio_remote.rs"),
    "*sample = sample.clamp(-1.0, 1.0);",
    "*sample = *sample;",
    "mixes_all_streams_and_clamps_only_the_final_sum")
fails_when_broken(
    Path("native/conest_native/src/audio_remote.rs"),
    "self.streams.remove(&participant);",
    "// Sabotage: retain the departed participant's state.",
    "leaving_discards_decoder_jitter_pcm_and_level")
