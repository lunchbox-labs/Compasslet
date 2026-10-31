"""Exercise duplicate runtime removal against a scripted simctl."""
import contextlib
import io
import json
import runpy
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
MODULE = runpy.run_path(str(SCRIPTS / "remove-duplicate-runtimes"))

WATCH = "com.apple.platform.watchsimulator"
IOS = "com.apple.platform.iphonesimulator"


def runtime(identifier, state, platform=WATCH, mount="/Volumes/x"):
    return {"runtimeIdentifier": identifier, "state": state, "platformIdentifier": platform,
            "mountPath": mount}


# A stand-in for `xcrun simctl`: `runtime list -j` replays the snapshots in order and
# `runtime delete` records the id and exits with the configured status.
FAKE = '''
import json, pathlib, sys
root = pathlib.Path(__file__).parent
if sys.argv[1:4] == ["runtime", "list", "-j"]:
    snapshots = json.loads((root / "snapshots.json").read_text())
    counter = root / "counter"
    index = int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(index + 1))
    print(json.dumps(snapshots[min(index, len(snapshots) - 1)]))
elif sys.argv[1:3] == ["runtime", "delete"]:
    with (root / "deleted").open("a") as log:
        log.write(sys.argv[3] + "\\n")
    sys.exit({DELETE_STATUS})
'''


class RemoveDuplicateRuntimesTests(unittest.TestCase):
    def run_removal(self, snapshots, delete_status=0, timeout=5):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "snapshots.json").write_text(json.dumps(snapshots))
            fake = root / "simctl.py"
            fake.write_text(FAKE.replace("{DELETE_STATUS}", str(delete_status)))
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                MODULE["remove_unusable"](simctl=(sys.executable, str(fake)), timeout=timeout)
            deleted = (root / "deleted").read_text().splitlines() if (root / "deleted").exists() else []
            return output.getvalue(), deleted

    def test_deletes_only_unusable_records_and_keeps_the_ready_one(self):
        before = {"dup": runtime("watchOS-27-0", "Unusable"), "ok": runtime("watchOS-27-0", "Ready"),
                  "ios": runtime("iOS-27-0", "Ready", IOS)}
        after = {"ok": before["ok"], "ios": before["ios"]}
        output, deleted = self.run_removal([before, after])
        self.assertEqual(deleted, ["dup"])
        self.assertIn("Deleting unusable runtime dup", output)
        self.assertIn("Runtime now: watchOS-27-0 Ready", output)

    def test_does_nothing_when_no_record_is_unusable(self):
        snapshot = {"ok": runtime("watchOS-27-0", "Ready"), "ios": runtime("iOS-27-0", "Ready", IOS)}
        output, deleted = self.run_removal([snapshot])
        self.assertEqual(deleted, [])
        self.assertNotIn("Deleting", output)

    def test_warns_but_continues_when_a_delete_fails(self):
        before = {"dup": runtime("watchOS-27-0", "Unusable"), "ok": runtime("watchOS-27-0", "Ready")}
        output, deleted = self.run_removal([before, before], delete_status=1)
        self.assertEqual(deleted, ["dup"])
        self.assertIn("::warning::Could not delete simulator runtime dup (status 1)", output)

    def test_waits_for_the_platform_to_show_a_ready_runtime_again(self):
        before = {"dup": runtime("watchOS-27-0", "Unusable"), "ok": runtime("watchOS-27-0", "Ready")}
        gap = {"ok": runtime("watchOS-27-0", "Copying", mount=None)}
        after = {"ok": runtime("watchOS-27-0", "Ready")}
        output, _ = self.run_removal([before, gap, after])
        self.assertIn("Runtime now: watchOS-27-0 Ready", output)

    def test_keeps_an_unusable_record_that_has_no_ready_sibling(self):
        before = {"only": runtime("watchOS-27-0", "Unusable"), "ios": runtime("iOS-27-0", "Ready", IOS)}
        output, deleted = self.run_removal([before])
        self.assertEqual(deleted, [])
        self.assertIn("Keeping unusable runtime only with no Ready sibling", output)

    def test_fails_when_the_platform_never_recovers(self):
        before = {"dup": runtime("watchOS-27-0", "Unusable"), "ok": runtime("watchOS-27-0", "Ready")}
        with self.assertRaisesRegex(RuntimeError, "No Ready runtime for com.apple.platform.watchsimulator"):
            self.run_removal([before, {}], timeout=0.1)


if __name__ == "__main__":
    unittest.main()
