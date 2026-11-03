"""Exercise simulator selection, releases and the wiki page of the screenshot script."""
import contextlib
import io
import json
import plistlib
import runpy
import tempfile
import time
import subprocess
import unittest
from unittest.mock import patch
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
MODULE = runpy.run_path(str(SCRIPTS / "screenshots"))
RUNTIME_27 = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
RUNTIME_27_1 = "com.apple.CoreSimulator.SimRuntime.iOS-27-1"
RUNTIME_26 = "com.apple.CoreSimulator.SimRuntime.iOS-26-4"


class DeviceSelectionTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.types = [self.device_type("max", 1320, 2868), self.device_type("pro", 1206, 2622),
                      self.device_type("e", 1170, 2532), self.device_type("wide", 1398, 2034),
                      {"identifier": "unsized"}]

    def device_type(self, name, width, height):
        bundle = self.root / (name + ".simdevicetype")
        (bundle / "Contents/Resources").mkdir(parents=True)
        with (bundle / "Contents/Resources/capabilities.plist").open("wb") as file:
            plistlib.dump({"capabilities": {"displays": [
                {"width": width, "height": height, "scale": 3.0},
                {"width": 720, "height": 480, "scale": 1.0}]}}, file)
        return {"identifier": name, "bundlePath": str(bundle)}

    @staticmethod
    def device(name, device_type, available=True):
        return {"udid": name + "-id", "name": name, "deviceTypeIdentifier": device_type,
                "isAvailable": available}

    def phones(self):
        devices = {
            RUNTIME_26: [self.device("iPhone 16e", "e")],
            RUNTIME_27_1: [self.device("iPhone Duo", "wide")],
            RUNTIME_27: [self.device("iPhone 17 Pro Max", "max"),
                         self.device("iPhone 17 Pro", "pro"), self.device("iPhone 17e", "e"),
                         self.device("iPhone Unknown", "unsized"),
                         self.device("iPhone Offline", "max", available=False),
                         self.device("iPad Pro", "max")],
        }
        return MODULE["available_iphones"](devices, self.types)

    def test_available_iphones_on_every_supported_runtime_are_offered(self):
        names = [phone["name"] for phone in self.phones()]
        self.assertEqual(names, ["iPhone Duo", "iPhone 17 Pro Max", "iPhone 17 Pro",
                                 "iPhone 17e", "iPhone Unknown"])

    def test_runtimes_older_than_the_deployment_target_are_never_used(self):
        devices = {RUNTIME_26: [self.device("iPhone 16e", "e")]}
        self.assertEqual(MODULE["available_iphones"](devices, self.types), [])

    def test_aliases_pick_the_largest_screen_and_the_narrowest_one(self):
        selected = MODULE["select_devices"](["largest", "smallest"], self.phones())
        self.assertEqual([(item["name"], item["label"]) for item in selected],
                         [("iPhone 17 Pro Max", "largest"), ("iPhone 17e", "smallest")])

    def test_exact_names_are_labelled_by_name_and_duplicates_are_dropped(self):
        selected = MODULE["select_devices"](["iPhone 17 Pro", "iPhone 17 Pro"], self.phones())
        self.assertEqual([item["label"] for item in selected], ["iphone-17-pro"])

    def test_an_unknown_name_lists_the_available_simulators(self):
        with self.assertRaises(SystemExit) as raised:
            MODULE["select_devices"](["iPhone 99"], self.phones())
        self.assertIn("iPhone 17 Pro Max", str(raised.exception))


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        (self.directory / "largest-light-compass.png").write_bytes(b"png")
        (self.directory / "screenshots.json").write_text(json.dumps(
            [{"screen": "compass", "file": "largest-light-compass.png"}]), encoding="utf-8")
        self.calls = []
        self.arguments = []

    def publish(self, releases):
        def run(arguments, **options):
            self.calls.append(arguments[1:3])
            self.arguments.append(arguments)
            output = json.dumps([releases]) if arguments[1] == "api" else ""
            return subprocess.CompletedProcess(arguments, 0, output, "")
        with patch("subprocess.run", side_effect=run), contextlib.redirect_stdout(io.StringIO()):
            MODULE["main"](["release", "--tag", "v1.2.3", "--repository", "o/r",
                            "--directory", str(self.directory)])

    def test_a_new_release_is_drafted_from_the_tag_and_published_after_its_assets(self):
        self.publish([{"tag_name": "v1.2.2", "draft": False}])
        self.assertEqual(self.calls, [["api", "--paginate"], ["release", "create"],
                                      ["release", "upload"], ["release", "edit"]])
        self.assertIn("--verify-tag", self.arguments[1])
        self.assertIn("--draft", self.arguments[1])
        self.assertIn(str(self.directory / "screenshots.json"), self.arguments[2])
        self.assertIn("--draft=false", self.arguments[3])

    def test_an_existing_draft_is_finished(self):
        self.publish([{"tag_name": "v1.2.3", "draft": True}])
        self.assertEqual(self.calls, [["api", "--paginate"], ["release", "upload"],
                                      ["release", "edit"]])

    def test_an_older_version_never_becomes_the_latest_release(self):
        self.publish([{"tag_name": "v1.10.0", "draft": False}])
        self.assertIn("--latest=false", self.arguments[3])
        self.arguments.clear()
        self.publish([{"tag_name": "v1.2.2", "draft": False}, {"tag_name": "v2.0.0", "draft": True}])
        self.assertIn("--latest", self.arguments[3])
        self.assertNotIn("--latest=false", self.arguments[3])

    def test_a_published_release_is_never_changed(self):
        with self.assertRaises(SystemExit):
            self.publish([{"tag_name": "v1.2.3", "draft": False}])
        self.assertEqual(self.calls, [["api", "--paginate"]])


class ResponderTests(unittest.TestCase):
    def test_a_screenshot_that_wasnt_saved_is_reported_and_still_answered(self):
        with tempfile.TemporaryDirectory() as requests, tempfile.TemporaryDirectory() as output:
            requests, output = Path(requests), Path(output)
            (requests / "compass.request").touch()
            (requests / "settings.request").touch()

            def screenshot(arguments, **options):
                path = Path(arguments[-1])
                if "compass" in path.name:
                    path.write_bytes(b"png")
                    return subprocess.CompletedProcess(arguments, 0)
                return subprocess.CompletedProcess(arguments, 1)

            responder = MODULE["ScreenshotResponder"]("id", requests, output, "largest", "dark")
            with patch("subprocess.run", side_effect=screenshot):
                responder.start()
                for _ in range(100):
                    if (requests / "settings.done").exists():
                        break
                    time.sleep(0.05)
                responder.stop()
            self.assertEqual(responder.captured,
                             [{"screen": "compass", "file": "largest-dark-compass.png"}])
            self.assertEqual(responder.failed, ["largest-dark-settings.png"])
            self.assertTrue((requests / "compass.done").exists())
            self.assertTrue((requests / "settings.done").exists())


class WikiPageTests(unittest.TestCase):
    MANIFEST = [
        {"screen": "compass", "file": "largest-light-compass.png", "device": "iPhone 17 Pro Max",
         "label": "largest", "appearance": "light"},
        {"screen": "settings", "file": "largest-light-settings.png",
         "device": "iPhone 17 Pro Max", "label": "largest", "appearance": "light"},
        {"screen": "compass", "file": "largest-dark-compass.png", "device": "iPhone 17 Pro Max",
         "label": "largest", "appearance": "dark"},
        {"screen": "compass", "file": "smallest-light-compass.png", "device": "iPhone 17e",
         "label": "smallest", "appearance": "light"},
    ]

    def test_the_page_groups_screens_by_device_and_links_the_latest_release(self):
        page = MODULE["wiki_page"](self.MANIFEST, "lunchbox-labs/compasslet")
        self.assertLess(page.index("## iPhone 17 Pro Max"), page.index("## iPhone 17e"))
        self.assertLess(page.index("### compass"), page.index("### settings"))
        self.assertIn('<img src="https://github.com/lunchbox-labs/compasslet/releases/latest/'
                      'download/largest-light-compass.png" alt="compass, light" width="300"> '
                      '<img src="https://github.com/lunchbox-labs/compasslet/releases/latest/'
                      'download/largest-dark-compass.png" alt="compass, dark" width="300">', page)

    def test_an_unchanged_page_is_not_rewritten(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "screenshots.json"
            manifest.write_text(json.dumps(self.MANIFEST), encoding="utf-8")
            page = Path(directory) / MODULE["WIKI_PAGE"]
            page.write_text(MODULE["wiki_page"](self.MANIFEST, "o/r"), encoding="utf-8")
            before = page.stat().st_mtime_ns
            MODULE["main"](["wiki-page", "--manifest", str(manifest), "--repository", "o/r",
                            "--wiki", directory])
            self.assertEqual(page.stat().st_mtime_ns, before)


if __name__ == "__main__":
    unittest.main()
