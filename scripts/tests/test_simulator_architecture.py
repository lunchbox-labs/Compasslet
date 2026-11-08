import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]

class SimulatorArchitectureTests(unittest.TestCase):
    def test_architecture_wrapper_preserves_arguments_and_status(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'xcodebuild').write_text('#!/bin/sh\nprintf "%s\\n" "$@"\nexit 7\n')
            (root / 'xcodebuild').chmod(0o755)
            for arch in ('arm64', 'x86_64'):
                (root / 'uname').write_text('#!/bin/sh\necho ' + arch + '\n')
                (root / 'uname').chmod(0o755)
                result = subprocess.run(['bash', str(SCRIPTS / 'simulator-xcodebuild'), '-destination', 'a b', 'test'], env={**os.environ, 'PATH': directory + ':' + os.environ['PATH']}, capture_output=True, text=True)
                self.assertEqual(result.returncode, 7)
                self.assertEqual(result.stdout.splitlines()[:3], ['-destination', 'a b', 'test'])
                self.assertEqual('EXCLUDED_ARCHS=x86_64' in result.stdout, arch == 'arm64')
    @staticmethod
    def action(call):
        actions = [arg for arg in call if arg in ('build-for-testing', 'test-without-building', 'test')]
        return actions[0] if len(actions) == 1 else actions

    def run_test_ios(self, directory, *options, arch='arm64', build_status=0, boot_status=0):
        """Run test-ios against fake simctl and xcodebuild tools that log their calls.

        Each tool keeps its own log, since the boot and the build run at the same time.

        The fake boot records that it started and then waits for the build to finish, and the
        fake build waits for the boot to start, so a run only passes if the two overlap.
        """
        import json
        root = Path(directory)
        (root / 'scripts').symlink_to(SCRIPTS)
        devices = {'devices': {
            'com.apple.CoreSimulator.SimRuntime.iOS-27-0': [{'udid': 'phone', 'name': 'iPhone', 'isAvailable': True}]}}
        common = ('import json, sys, time\nfrom pathlib import Path\n'
                  'def log(name, call):\n'
                  '    path = Path(name)\n'
                  '    calls = json.loads(path.read_text()) if path.exists() else []\n'
                  '    path.write_text(json.dumps(calls + [call]))\n'
                  'def wait_for(name):\n'
                  '    for _ in range(100):\n'
                  '        if Path(name).exists(): return\n'
                  '        time.sleep(0.05)\n'
                  '    sys.exit("timed out waiting for " + name)\n')
        (root / 'xcrun').write_text(
            '#!/usr/bin/env python3\n' + common +
            'if sys.argv[1:3] == ["simctl", "list"]: print(' + repr(json.dumps(devices)) + ')\n'
            'elif sys.argv[1:3] == ["simctl", "bootstatus"]:\n'
            '    log("boot-calls.json", sys.argv[1:])\n'
            '    Path("boot-started").write_text("")\n'
            '    wait_for("built")\n'
            '    print("boot progress")\n'
            '    sys.exit(' + str(boot_status) + ')\n')
        (root / 'xcodebuild').write_text(
            '#!/usr/bin/env python3\n' + common +
            'log("build-calls.json", sys.argv[1:])\n'
            'if "build-for-testing" in sys.argv:\n'
            '    wait_for("boot-started")\n'
            '    Path("built").write_text("")\n'
            '    sys.exit(' + str(build_status) + ')\n')
        (root / 'uname').write_text('#!/bin/sh\necho ' + arch + '\n')
        for executable in ('xcrun', 'xcodebuild', 'uname'):
            (root / executable).chmod(0o755)
        result = subprocess.run(['bash', str(SCRIPTS / 'test-ios'), *options], cwd=root,
                                env={**os.environ, 'PATH': directory + ':' + os.environ['PATH']},
                                capture_output=True, text=True, timeout=20)
        def calls(name):
            path = root / name
            return json.loads(path.read_text()) if path.exists() else []
        return result, calls('boot-calls.json'), calls('build-calls.json')

    def test_ios_entrypoint_boots_during_the_build_then_tests_on_that_device(self):
        for arch in ('arm64', 'x86_64'):
            with self.subTest(arch=arch), tempfile.TemporaryDirectory() as directory:
                result, boots, builds = self.run_test_ios(directory, arch=arch)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(boots, [['simctl', 'bootstatus', 'phone', '-b']])
                self.assertEqual([self.action(call) for call in builds], ['build-for-testing', 'test-without-building'])
                for call in builds:
                    self.assertIn('platform=iOS Simulator,id=phone', call)
                    exclusions = [arg for arg in call if arg.startswith('EXCLUDED_ARCHS')]
                    self.assertEqual(exclusions, ['EXCLUDED_ARCHS=x86_64'] if arch == 'arm64' else [])
                self.assertNotIn('-resultBundlePath', builds[0])
                self.assertIn('-resultBundlePath', builds[1])
                self.assertNotIn('boot progress', result.stdout + result.stderr)

    def test_ios_entrypoint_preserves_a_build_failure_and_does_not_test(self):
        with tempfile.TemporaryDirectory() as directory:
            result, _, builds = self.run_test_ios(directory, build_status=7)
            self.assertEqual(result.returncode, 7, result.stderr)
            self.assertEqual([self.action(call) for call in builds], ['build-for-testing'])

    def test_ios_entrypoint_reports_a_failed_boot_and_does_not_test(self):
        with tempfile.TemporaryDirectory() as directory:
            result, _, builds = self.run_test_ios(directory, boot_status=3)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('boot progress', result.stderr)
            self.assertIn('did not boot', result.stderr)
            self.assertEqual([self.action(call) for call in builds], ['build-for-testing'])

    def test_ios_entrypoint_passes_test_options_to_the_test_run_only(self):
        with tempfile.TemporaryDirectory() as directory:
            result, _, builds = self.run_test_ios(directory, '-test-iterations', '20', '-run-tests-until-failure')
            self.assertEqual(result.returncode, 0, result.stderr)
            build, test = builds
            self.assertNotIn('-test-iterations', build)
            test = [arg for arg in test if not arg.startswith('EXCLUDED_ARCHS')]
            self.assertEqual(test[-4:], ['-test-iterations', '20', '-run-tests-until-failure', 'test-without-building'])
