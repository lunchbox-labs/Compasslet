"""Exercise simulator selection and screenshot answers of the screenshot script."""
import json
import os
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
TWO_DISPLAYS = ("An error was encountered processing the command (domain=NSPOSIXErrorDomain, "
                "code=22):\nCannot choose between 2 displays. Specify one with --display:\n"
                "    --display=3  LCD-1 (primary-1) 2007x2853\n"
                "    --display=1  LCD (primary) 1398x2034\nInvalid argument\n")


def bitmap(pixels, bits=32):
    """A bottom-up BMP of one row with the given pixels, each a tuple of its channel values."""
    row = b"".join(bytes(pixel) for pixel in pixels)
    row += b"\0" * (-len(row) % 4)
    header = bytearray(54)
    header[0:2] = b"BM"
    header[10:14] = (54).to_bytes(4, "little")
    header[14:18] = (40).to_bytes(4, "little")
    header[18:22] = len(pixels).to_bytes(4, "little")
    header[22:26] = (1).to_bytes(4, "little")
    header[28:30] = bits.to_bytes(2, "little")
    return bytes(header) + row


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


class DisplayTests(unittest.TestCase):
    def test_the_smallest_display_shows_apps_closed_and_the_largest_open_flat(self):
        displays = MODULE["displays_from"](TWO_DISPLAYS)
        self.assertEqual([(item.name, item.identifier, item.hinge) for item in displays],
                         [("outer", "1", 0), ("inner", "3", 180)])

    def test_displays_between_the_smallest_and_largest_are_left_out(self):
        listing = ("    --display=5  LCD-2 (primary-2) 1600x2400\n" + TWO_DISPLAYS)
        self.assertEqual([item.identifier for item in MODULE["displays_from"](listing)],
                         ["1", "3"])

    def test_an_error_that_lists_fewer_than_two_displays_means_one_display(self):
        self.assertEqual(MODULE["displays_from"]("Invalid device\n"), [])
        self.assertEqual(MODULE["displays_from"]("    --display=1  LCD (primary) 1398x2034\n"),
                         [])

    def test_a_simulator_whose_plain_screenshot_works_has_one_display(self):
        with patch("subprocess.run",
                   return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
            self.assertEqual(MODULE["find_displays"]("id"), [])
        self.assertNotIn("--display", " ".join(run.call_args.args[0]))

    def test_a_display_is_dark_only_when_no_colour_is_brighter_than_the_dark_level(self):
        dark = MODULE["DARK_LEVEL"] - 1
        self.assertTrue(MODULE["is_dark_bitmap"](bitmap([(0, 0, 0, 255), (dark, dark, 0, 255)])))
        self.assertFalse(MODULE["is_dark_bitmap"](bitmap([(0, 0, 0, 255), (0, 90, 0, 255)])))
        self.assertTrue(MODULE["is_dark_bitmap"](bitmap([(0, 0, 0), (dark, 0, 0)], bits=24)))
        self.assertFalse(MODULE["is_dark_bitmap"](bitmap([(0, 0, 0), (0, 0, 200)], bits=24)))

    def test_a_display_whose_brightness_cant_be_checked_counts_as_lit(self):
        def commands(arguments, **options):
            if arguments[0] == "sips":
                return subprocess.CompletedProcess(arguments, 1)
            Path(arguments[-1]).write_bytes(b"png")
            return subprocess.CompletedProcess(arguments, 0)

        inner = MODULE["Display"]("inner", "3", 180)
        with patch("subprocess.run", side_effect=commands), patch("sys.stderr"):
            self.assertTrue(MODULE["display_is_lit"]("id", inner))

    def test_images_of_one_display_end_in_its_name(self):
        inner = MODULE["Display"]("inner", "3", 180)
        self.assertEqual(MODULE["image_name"]("iphone-duo", "light", "compass-part2", "", inner),
                         "iphone-duo-light-compass-part2-inner.png")


class PartNameTests(unittest.TestCase):
    def test_a_part_suffix_is_split_from_the_screen_it_continues(self):
        self.assertEqual(MODULE["split_part"]("settings-part2"), ("settings", 2))
        self.assertEqual(MODULE["split_part"]("settings-ax5-bold-part9"), ("settings-ax5-bold", 9))

    def test_the_first_part_and_unscrolled_names_keep_their_own_name(self):
        for name in ("settings", "settings-part1", "settings-part", "settings-part10",
                     "tour-shortcuts-carplay"):
            with self.subTest(name=name):
                self.assertEqual(MODULE["split_part"](name), (name, 1))


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

    def test_the_listing_set_is_the_compass_in_light_and_dark_on_iphone_17_and_duo(self):
        passes = MODULE["SETS"]["listing"]
        self.assertEqual([(item.device, item.appearance) for item in passes],
                         [("iPhone 17", "light"), ("iPhone 17", "dark"),
                          ("iPhone Duo", "light"), ("iPhone Duo", "dark")])
        for item in passes:
            with self.subTest(appearance=item.appearance):
                self.assertEqual(item.screens, ("compass",))
                self.assertEqual((item.text_variants, item.system_settings, item.tag), ((), (), ""))
                self.assertFalse(item.undecided_location or item.captures_launch)

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


class FakeSimulators:
    """Answers the simctl and xcodebuild commands capture() runs, and records each one."""

    def __init__(self, test_result=0, requests=(), displays=1, inner_lights=True,
                 failed_boots=0):
        self.test_result, self.requests = test_result, requests
        self.failed_boots = failed_boots
        self.displays, self.inner_lights = displays, inner_lights
        self.devices = [{"udid": "17-id", "name": "iPhone 17", "isAvailable": True,
                         "deviceTypeIdentifier": "type.17"}]
        self.commands = []
        self.environments = []
        # The hinge angle, and the angle each test run started at.
        self.hinge = 0
        self.test_hinges = []

    def lit(self, arguments):
        """Whether the display a screenshot names shows anything at the current hinge angle."""
        if "--display=1" in arguments:
            return self.hinge == 0
        return "--display=3" in arguments and self.hinge == 180 and self.inner_lights

    def __call__(self, arguments, **options):
        self.commands.append(list(arguments))
        stdout = ""
        if arguments[:4] == ["xcrun", "simctl", "list", "--json"]:
            stdout = json.dumps({
                "devicetypes": {"devicetypes": []},
                "devices": {"devices": {RUNTIME_27: self.devices}},
                "runtimes": {"runtimes": [
                    {"identifier": RUNTIME_27, "isAvailable": True, "supportedDeviceTypes": [
                        {"name": "iPhone SE (3rd generation)", "identifier": "type.se"},
                        {"name": "iPhone 17", "identifier": "type.17"}]}]},
            }[arguments[4]])
        elif arguments[:3] == ["xcrun", "simctl", "create"]:
            self.devices.append({"udid": "se-id", "name": arguments[3], "isAvailable": True,
                                 "deviceTypeIdentifier": arguments[4]})
            stdout = "se-id\n"
        elif arguments[0].endswith("simulator-hinge"):
            self.hinge = int(arguments[2])
        elif arguments[:3] == ["xcrun", "simctl", "status_bar"] and self.failed_boots:
            self.failed_boots -= 1
            if options.get("check"):
                raise subprocess.CalledProcessError(1, arguments)
            return subprocess.CompletedProcess(arguments, 1, "", "")
        elif arguments[:4] == ["xcrun", "simctl", "io", arguments[3]]:
            if self.displays > 1 and not any(part.startswith("--display=") for part in arguments):
                return subprocess.CompletedProcess(arguments, 22, "", TWO_DISPLAYS)
            Path(arguments[-1]).write_bytes(b"lit" if self.lit(arguments)
                                            or self.displays == 1 else b"dark")
        elif arguments[0] == "sips":
            lit = Path(arguments[7]).read_bytes() == b"lit"
            Path(arguments[-1]).write_bytes(bitmap([(0, 200 if lit else 0, 0, 255)]))
        elif arguments[-1] == "test-without-building":
            self.environments.append(options["env"])
            self.test_hinges.append(self.hinge)
            directory = Path(options["env"]["TEST_RUNNER_SCREENSHOT_DIRECTORY"])
            for name in self.requests:
                (directory / (name + ".request")).touch()
                for _ in range(200):
                    if (directory / (name + ".done")).exists():
                        break
                    time.sleep(0.01)
            return subprocess.CompletedProcess(arguments, self.test_result, "", "")
        return subprocess.CompletedProcess(arguments, 0, stdout, "")

    def index(self, *fragment):
        matches = [index for index, command in enumerate(self.commands)
                   if all(part in command for part in fragment)]
        return matches


class CaptureRunTests(unittest.TestCase):
    PASS = MODULE["CapturePass"]("iPhone SE (3rd generation)", "dark", ("settings",),
                                 text_variants=("ax3", "ax3-bold"),
                                 system_settings=("increase-contrast",), tag="increase-contrast",
                                 undecided_location=True)

    def capture(self, simulators, *options, capture_pass=None):
        output = tempfile.TemporaryDirectory()
        self.addCleanup(output.cleanup)
        self.output = Path(output.name)
        globals_ = MODULE["capture"].__globals__
        with patch.dict(globals_, {"SETS": {"test": (capture_pass or self.PASS,)},
                                   "DISPLAY_WAIT_SECONDS": 0, "DISPLAY_SETTLE_SECONDS": 0}), \
                patch("subprocess.run", side_effect=simulators):
            try:
                MODULE["main"](["capture", "--set", "test", "--output", output.name, *options])
                error = None
            except SystemExit as raised:
                error = raised
        manifest = json.loads((Path(output.name) / "screenshots.json").read_text())
        return error, manifest

    def test_each_image_records_its_own_text_variant_and_settings(self):
        simulators = FakeSimulators(requests=("settings-ax3", "settings-ax3-bold"))
        error, manifest = self.capture(simulators)
        self.assertIsNone(error)
        self.assertEqual(
            [(entry["file"], entry["screen"], entry["text_variant"]) for entry in manifest],
            [("iphone-se-3rd-generation-dark-increase-contrast-settings-ax3.png", "settings",
              "ax3"),
             ("iphone-se-3rd-generation-dark-increase-contrast-settings-ax3-bold.png",
              "settings", "ax3-bold")])
        self.assertTrue(all(entry["system_settings"] == ["increase-contrast"]
                            and entry["runtime"] == RUNTIME_27 for entry in manifest))

    def test_scrolled_parts_are_numbered_after_their_screen_and_text_variant(self):
        simulators = FakeSimulators(requests=("settings-ax3", "settings-ax3-part2",
                                              "settings-ax3-part3", "settings-ax3-bold"))
        error, manifest = self.capture(simulators)
        self.assertIsNone(error)
        self.assertEqual(
            [(entry["file"], entry["screen"], entry["text_variant"], entry.get("part"))
             for entry in manifest],
            [("iphone-se-3rd-generation-dark-increase-contrast-settings-ax3.png", "settings",
              "ax3", 1),
             ("iphone-se-3rd-generation-dark-increase-contrast-settings-ax3-part2.png",
              "settings", "ax3", 2),
             ("iphone-se-3rd-generation-dark-increase-contrast-settings-ax3-part3.png",
              "settings", "ax3", 3),
             ("iphone-se-3rd-generation-dark-increase-contrast-settings-ax3-bold.png",
              "settings", "ax3-bold", None)])

    def test_the_part_limit_reaches_the_test(self):
        simulators = FakeSimulators()
        self.capture(simulators, "--max-parts", "2")
        self.assertEqual(simulators.environments[0]["TEST_RUNNER_SCREENSHOT_MAX_PARTS"], "2")
        simulators = FakeSimulators()
        self.capture(simulators)
        self.assertEqual(simulators.environments[0]["TEST_RUNNER_SCREENSHOT_MAX_PARTS"], "9")

    def test_a_part_limit_out_of_range_stops_before_anything_runs(self):
        for value in ("0", "10", "two"):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as output, \
                    patch("subprocess.run") as run, patch("sys.stderr"):
                with self.assertRaises(SystemExit):
                    MODULE["main"](["capture", "--max-parts", value, "--output", output])
                run.assert_not_called()

    def test_a_failed_test_run_still_restores_the_simulator_and_deletes_what_it_created(self):
        simulators = FakeSimulators(test_result=65)
        error, manifest = self.capture(simulators)
        self.assertIsNotNone(error)
        self.assertEqual(manifest, [])
        test_run = simulators.index("test-without-building")[0]
        self.assertGreater(simulators.index("increase_contrast", "disabled")[-1], test_run)
        self.assertGreater(simulators.index("privacy", "grant")[-1], test_run)
        self.assertLess(simulators.index("privacy", "reset")[0], test_run)
        self.assertEqual(simulators.commands[-1], ["xcrun", "simctl", "delete", "se-id"])

    def test_images_from_a_failed_pass_are_marked_in_the_manifest(self):
        simulators = FakeSimulators(test_result=65, requests=("settings-ax3",))
        error, manifest = self.capture(simulators)
        self.assertIsNotNone(error)
        self.assertEqual([(entry["screen"], entry.get("pass_failed")) for entry in manifest],
                         [("settings", True)])

    def test_a_simulator_with_two_displays_runs_each_pass_closed_then_open(self):
        simulators = FakeSimulators(requests=("settings-ax3",), displays=2)
        error, manifest = self.capture(simulators)
        self.assertIsNone(error)
        self.assertEqual(simulators.test_hinges, [0, 180])
        self.assertEqual(
            [(entry["file"], entry["display"], entry["text_variant"]) for entry in manifest],
            [("iphone-se-3rd-generation-dark-increase-contrast-settings-ax3-outer.png", "outer",
              "ax3"),
             ("iphone-se-3rd-generation-dark-increase-contrast-settings-ax3-inner.png", "inner",
              "ax3")])
        self.assertEqual({path.read_bytes() for path in self.output.glob("*.png")}, {b"lit"})
        self.assertEqual(len(simulators.index("clang")), 1)
        # The simulator is left closed before it shuts down.
        self.assertEqual(simulators.hinge, 0)
        hinges = [index for index, command in enumerate(simulators.commands)
                  if command[0].endswith("simulator-hinge")]
        self.assertEqual([simulators.commands[index][2] for index in hinges], ["0", "180", "0"])
        self.assertLess(hinges[-1], simulators.index("shutdown")[-1])

    def test_the_launch_frame_is_saved_on_each_display(self):
        launch_pass = MODULE["CapturePass"]("iPhone SE (3rd generation)", "light", (),
                                            captures_launch=True)
        # The pass runs no test, so nothing else waits on the clock.
        with patch("time.sleep"):
            error, manifest = self.capture(FakeSimulators(displays=2), capture_pass=launch_pass)
        self.assertIsNone(error)
        self.assertEqual([(entry["file"], entry["display"]) for entry in manifest],
                         [("iphone-se-3rd-generation-light-launch-first-frame-outer.png", "outer"),
                          ("iphone-se-3rd-generation-light-launch-first-frame-inner.png",
                           "inner")])

    def test_a_display_that_stays_dark_is_reported_and_the_other_is_kept(self):
        simulators = FakeSimulators(requests=("settings-ax3",), displays=2, inner_lights=False)
        with patch("sys.stderr"):
            error, manifest = self.capture(simulators)
        self.assertIsNotNone(error)
        self.assertEqual(simulators.test_hinges, [0])
        self.assertEqual([(entry["display"], entry.get("pass_failed")) for entry in manifest],
                         [("outer", None)])

    def test_nothing_is_captured_open_when_the_hinge_tool_wont_build(self):
        def simulators(arguments, **options):
            if arguments[:2] == ["xcrun", "clang"]:
                return subprocess.CompletedProcess(arguments, 1, "", "")
            return fake(arguments, **options)

        fake = FakeSimulators(requests=("settings-ax3",), displays=2)
        with patch("sys.stderr"):
            error, manifest = self.capture(simulators)
        self.assertIsNotNone(error)
        self.assertEqual(fake.test_hinges, [0])
        self.assertEqual([entry["display"] for entry in manifest], ["outer"])
        self.assertFalse(any(command[0].endswith("simulator-hinge")
                             for command in fake.commands))

    def test_a_simulator_that_stops_while_starting_is_booted_once_more(self):
        simulators = FakeSimulators(requests=("settings-ax3",), failed_boots=1)
        with patch("sys.stderr"):
            error, manifest = self.capture(simulators)
        self.assertIsNone(error)
        self.assertEqual(len(simulators.index("simctl", "boot")), 2)
        self.assertLess(simulators.index("shutdown")[0], simulators.index("simctl", "boot")[1])
        self.assertEqual(len(manifest), 1)

    def test_a_simulator_that_stops_twice_while_starting_ends_the_run(self):
        simulators = FakeSimulators(requests=("settings-ax3",), failed_boots=2)
        with patch("sys.stderr"), self.assertRaises(subprocess.CalledProcessError):
            self.capture(simulators)
        self.assertEqual(simulators.index("test-without-building"), [])
        self.assertEqual(simulators.commands[-1], ["xcrun", "simctl", "delete", "se-id"])

    def test_no_simulator_is_created_when_any_requested_name_cant_be(self):
        simulators = FakeSimulators()
        with tempfile.TemporaryDirectory() as output, \
                patch("subprocess.run", side_effect=simulators):
            with self.assertRaises(SystemExit) as raised:
                MODULE["main"](["capture", "--devices",
                                "iPhone SE (3rd generation),iPhone Typo", "--output", output])
        self.assertIn("iPhone Typo", str(raised.exception))
        self.assertEqual(simulators.index("create"), [])


if __name__ == "__main__":
    unittest.main()
