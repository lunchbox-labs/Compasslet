"""Exercise simulator selection and screenshot answers of the screenshot script."""
import plistlib
import re
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


class CaptureSetTests(unittest.TestCase):
    def test_every_screen_in_a_set_is_one_the_test_can_show(self):
        source = (SCRIPTS.parent / "AppTests/ScreenshotTests.swift").read_text()
        known = set(re.findall(r'Screen\(name: "([^"]+)"', source))
        for set_name, passes in MODULE["SETS"].items():
            for item in passes:
                with self.subTest(set=set_name, device=item.device, tag=item.tag):
                    self.assertTrue(item.screens or item.captures_launch)
                    self.assertEqual(set(item.screens) - known, set())
                    self.assertEqual(set(item.system_settings) - set(MODULE["SYSTEM_SETTINGS"]),
                                     set())

    def test_the_location_prompt_runs_last_on_its_simulator(self):
        passes = MODULE["SETS"]["accessibility"]
        for index, item in enumerate(passes):
            if item.undecided_location:
                later = [other for other in passes[index + 1:] if other.device == item.device]
                self.assertEqual(later, [])

    def test_a_filter_narrows_each_pass_and_drops_empty_ones(self):
        passes = MODULE["passes_for"]("accessibility", "live-activity")
        self.assertTrue(passes)
        for item in passes:
            self.assertFalse(item.captures_launch)
            self.assertTrue(all(screen.startswith("live-activity") for screen in item.screens))

    def test_the_launch_frame_is_kept_only_when_the_filter_matches_it(self):
        passes = MODULE["passes_for"]("accessibility", "launch")
        self.assertEqual([(item.screens, item.captures_launch) for item in passes], [((), True)])

    def test_a_filter_that_matches_nothing_stops_before_building(self):
        with self.assertRaises(SystemExit):
            MODULE["passes_for"]("accessibility", "no-such-screen")

    def test_a_set_refuses_its_own_devices_and_appearances(self):
        for option in (["--devices", "largest"], ["--appearances", "dark"]):
            with self.subTest(option=option), tempfile.TemporaryDirectory() as output, \
                    patch("subprocess.run") as run:
                with self.assertRaises(SystemExit):
                    MODULE["main"](["capture", "--set", "accessibility", "--output", output,
                                    *option])
                run.assert_not_called()

    def test_tagged_images_name_the_setting_after_the_appearance(self):
        self.assertEqual(MODULE["image_name"]("iphone-17", "dark", "settings", "increase-contrast"),
                         "iphone-17-dark-increase-contrast-settings.png")
        self.assertEqual(MODULE["image_name"]("largest", "light", "settings"),
                         "largest-light-settings.png")


class CreatableDeviceTests(unittest.TestCase):
    @staticmethod
    def runtime(identifier, names, available=True):
        return {"identifier": identifier, "isAvailable": available,
                "supportedDeviceTypes": [{"name": name, "identifier": "type." + name}
                                         for name in names]}

    def test_missing_iphones_are_created_on_the_newest_supported_runtime(self):
        offered = MODULE["creatable_iphones"]([
            self.runtime(RUNTIME_26, ["iPhone SE (3rd generation)", "iPhone 16e"]),
            self.runtime(RUNTIME_27, ["iPhone 13 mini", "iPhone 17", "iPad Pro"]),
            self.runtime(RUNTIME_27_1, ["iPhone 17"]),
            self.runtime("com.apple.CoreSimulator.SimRuntime.iOS-27-2", ["iPhone Duo"],
                         available=False),
        ])
        self.assertEqual(offered, {"iPhone 17": ("type.iPhone 17", RUNTIME_27_1),
                                   "iPhone 13 mini": ("type.iPhone 13 mini", RUNTIME_27)})


if __name__ == "__main__":
    unittest.main()
