"""Exercise the Watch test entry point with a simulated CoreSimulator service."""
import itertools
import json
import os
import runpy
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
MODULE = runpy.run_path(str(SCRIPTS / "create-watch-simulator"))

WATCH_RUNTIME = "com.apple.CoreSimulator.SimRuntime.watchOS-27-0"
IOS_RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
DEVICE_TYPES = {"devicetypes": [
    {"name": "iPhone 18 Pro Max", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max"},
    {"name": "Apple Watch Series 11 (46mm)", "identifier": "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm"},
    {"name": "Apple Watch Series 12 (42mm)", "identifier": "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-12-42mm"},
    {"name": "Apple Watch Series 12 (46mm)", "identifier": "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-12-46mm"},
    {"name": "Apple Watch Ultra 3 (49mm)", "identifier": "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Ultra-3-49mm"},
]}


def runtimes(watch_state="Ready", watch_mount="/"):
    return {"watch": {"runtimeIdentifier": WATCH_RUNTIME, "state": watch_state, "mountPath": watch_mount},
            "phone": {"runtimeIdentifier": IOS_RUNTIME, "state": "Ready", "mountPath": "/"}}


class WatchSimulatorTests(unittest.TestCase):
    HOST_NEVER_CONNECTED = ("CompassWatch (1) encountered an error (Early unexpected exit, operation never"
                            " finished bootstrapping - no restart will be attempted.)")

    def run_watch(self, runtime_snapshots, test_status=0, xcodebuild=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").symlink_to(SCRIPTS)
            (root / "runtimes.json").write_text(json.dumps(runtime_snapshots))
            (root / "devicetypes.json").write_text(json.dumps(DEVICE_TYPES))
            (root / "xcrun").write_text('''#!/usr/bin/env python3
import json, pathlib, sys
root = pathlib.Path(__file__).parent
with (root / "calls").open("a") as log:
    log.write(" ".join(sys.argv[1:]) + "\\n")
if sys.argv[1:4] == ["simctl", "runtime", "list"]:
    counter = root / "counter"
    index = int(counter.read_text()) if counter.exists() else 0
    snapshots = json.loads((root / "runtimes.json").read_text())
    print(json.dumps(snapshots[min(index, len(snapshots)-1)]))
    counter.write_text(str(index+1))
elif sys.argv[1:4] == ["simctl", "list", "devicetypes"]:
    print((root / "devicetypes.json").read_text())
elif sys.argv[1:3] == ["simctl", "create"]:
    print("watch")
elif sys.argv[1:4] == ["simctl", "list", "devices"]:
    print("== Devices ==")
''')
            (root / "xcodebuild").write_text(
                xcodebuild or f"#!/bin/sh\necho test >> '{root}/calls'\nexit {test_status}\n")
            for name in ("xcrun", "xcodebuild"):
                (root / name).chmod(0o755)
            result = subprocess.run(["bash", str(SCRIPTS / "test-watch")], cwd=root,
                                    env={**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"]},
                                    capture_output=True, text=True, timeout=20)
            return result, (root / "calls").read_text()

    def failing_host_then(self, status):
        """An xcodebuild stand-in whose first run reports the host handshake failure."""
        return ("#!/bin/sh\n"
                "echo test >> calls\n"
                "if [ \"$(grep -c '^test$' calls)\" -eq 1 ]; then\n"
                f"  echo '{self.HOST_NEVER_CONNECTED}'; exit 65\n"
                "fi\n"
                f"exit {status}\n")

    def test_creates_an_unpaired_watch_and_tests_without_an_iphone(self):
        result, calls = self.run_watch([runtimes("Copying", None), runtimes()])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Waiting for a mounted watchOS 27+ runtime", result.stderr)
        self.assertIn("simctl create CI Watch com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-12-46mm "
                      + WATCH_RUNTIME, calls)
        self.assertIn("simctl bootstatus watch -b", calls)
        self.assertIn("simctl install watch .build/watch/Build/Products/Debug-watchsimulator/CompassWatch.app", calls)
        self.assertIn("simctl launch watch dev.lunchbox-labs.carplay-compass.watchkitapp", calls)
        self.assertIn("simctl terminate watch dev.lunchbox-labs.carplay-compass.watchkitapp", calls)
        self.assertNotIn("phone", calls, "no iPhone may be booted or waited for")
        self.assertEqual(calls.count("bootstatus"), 1)
        self.assertIn("test\n", calls)
        self.assertEqual(calls.count("test\n"), 1)
        self.assertIn("simctl list devices booted", calls)

    def test_preserves_a_host_connection_failure(self):
        result, calls = self.run_watch([runtimes()], xcodebuild=self.failing_host_then(0))
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertEqual(calls.count("test\n"), 1)

    def test_does_not_hide_test_failure_alongside_host_connection_error(self):
        command = self.failing_host_then(0).replace(
            f"  echo '{self.HOST_NEVER_CONNECTED}'",
            f"  echo 'Test Case testHeading failed (0.01 seconds).'; echo '{self.HOST_NEVER_CONNECTED}'")
        result, calls = self.run_watch([runtimes()], xcodebuild=command)
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertEqual(calls.count("test\n"), 1)

    def test_preserves_native_test_failure(self):
        result, calls = self.run_watch([runtimes()], test_status=7)
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(calls.count("test\n"), 1, "a failing test must not be retried")

    def test_rejects_unmounted_transitioning_or_old_runtimes(self):
        watch_runtime = MODULE["watch_runtime"]
        self.assertIsNone(watch_runtime(runtimes("Copying", "/")))
        self.assertIsNone(watch_runtime(runtimes("Ready", "/missing-watch-mount")))
        self.assertIsNone(watch_runtime({"old": {"runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.watchOS-26-2",
                                                  "state": "Ready", "mountPath": "/"}}))
        self.assertEqual(watch_runtime(runtimes()), (WATCH_RUNTIME, "27.0"))

    def test_prefers_the_newest_mounted_watch_runtime(self):
        listed = runtimes()
        listed["newer"] = {"runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.watchOS-27-1",
                           "state": "Ready", "mountPath": "/"}
        self.assertEqual(MODULE["watch_runtime"](listed),
                         ("com.apple.CoreSimulator.SimRuntime.watchOS-27-1", "27.1"))

    def test_picks_the_newest_largest_apple_watch_device_type(self):
        self.assertEqual(MODULE["watch_device_type"](DEVICE_TYPES),
                         "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-12-46mm")
        with self.assertRaisesRegex(RuntimeError, "No Apple Watch device type"):
            MODULE["watch_device_type"]({"devicetypes": DEVICE_TYPES["devicetypes"][:1]})

    def test_missing_runtime_fails_at_deadline(self):
        clock = itertools.count(0, 2).__next__  # the deadline passes before the first poll
        with self.assertRaisesRegex(RuntimeError, "within 1 seconds"):
            MODULE["create_watch"](timeout=1, clock=clock)


if __name__ == "__main__":
    unittest.main()
