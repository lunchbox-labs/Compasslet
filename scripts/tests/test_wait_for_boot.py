"""Exercise the simulator boot wait against scripted bootstatus output."""
import contextlib
import io
import runpy
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
MODULE = runpy.run_path(str(SCRIPTS / "wait-for-boot"))

PHASE = "[2026-10-31 02:35:24 +0000] Status=2, isTerminal=NO, Elapsed=00:{:02d}."
MIGRATION = "\tWaiting on Data Migration\n\t\tReason:{}\n\t\tMigration Elapsed:00:{:02d} seconds"


def scripted(*steps):
    """Build a command that prints each (delay, text) step, then exits with the last value."""
    *lines, status = steps
    source = "import sys, time\n"
    for delay, text in lines:
        source += "time.sleep(" + repr(delay) + "); print(" + repr(text) + ", flush=True)\n"
    source += "sys.exit(" + repr(status) + ")\n"
    return [sys.executable, "-c", source]


class WaitForBootTests(unittest.TestCase):
    def wait(self, command, stall_seconds, deadline_seconds=60):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            MODULE["wait_for_boot"]("device", stall_seconds, deadline_seconds, command=command)
        return output.getvalue()

    def test_treats_only_phase_changes_as_progress(self):
        normalize = MODULE["normalize"]
        self.assertEqual(normalize(PHASE.format(5)), normalize(PHASE.format(59)))
        self.assertEqual(normalize(MIGRATION.format("Siri.migrator", 1)),
                         normalize(MIGRATION.format("Siri.migrator", 40)))
        self.assertNotEqual(normalize(MIGRATION.format("Siri.migrator", 1)),
                            normalize(MIGRATION.format("MCProfile.migrator", 1)))
        self.assertNotEqual(normalize(PHASE.format(5)),
                            normalize("[x] Status=4, isTerminal=NO, Elapsed=00:05."))

    def test_outlives_a_slow_boot_that_keeps_changing_phase(self):
        command = scripted((0.3, PHASE.format(1)), (0.3, "\tBooting"),
                           (0.3, MIGRATION.format("Siri.migrator", 1)),
                           (0.3, "\tWaiting on System App"), (0.3, "\tFinished"), 0)
        output = self.wait(command, stall_seconds=0.5)
        self.assertIn("Waiting for simulator boot: device", output)
        self.assertIn("Finished", output)

    def test_fails_when_the_same_phase_repeats_past_the_stall_limit(self):
        command = scripted((0.1, "\tWaiting on System App"), (0.1, "\tWaiting on System App"),
                           (0.1, "\tWaiting on System App"), (2, "\tFinished"), 0)
        with self.assertRaisesRegex(RuntimeError, "no progress for 0.5 seconds: device"):
            self.wait(command, stall_seconds=0.5)

    def test_fails_when_bootstatus_prints_nothing_for_too_long(self):
        with self.assertRaisesRegex(RuntimeError, "no progress for 0.5 seconds"):
            self.wait(scripted((2, "\tFinished"), 0), stall_seconds=0.5)

    def test_fails_at_the_overall_deadline_despite_progress(self):
        steps = [(0.2, PHASE.format(index)[:-1] + " phase " + str(index)) for index in range(20)]
        with self.assertRaisesRegex(RuntimeError, "did not finish within 1 seconds"):
            self.wait(scripted(*steps, 0), stall_seconds=5, deadline_seconds=1)

    def test_reports_a_failed_boot(self):
        with self.assertRaisesRegex(RuntimeError, "failed with status 3: device"):
            self.wait(scripted((0, "\tBooting"), 3), stall_seconds=5)


if __name__ == "__main__":
    unittest.main()
