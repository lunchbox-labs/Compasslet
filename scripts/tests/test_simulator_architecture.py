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
    def test_ios_entrypoint_preserves_native_failure_and_host_architecture(self):
        import json
        for entrypoint in ('test-ios',):
            for arch in ('arm64', 'x86_64'):
                with self.subTest(entrypoint=entrypoint, arch=arch), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    (root / 'scripts').symlink_to(SCRIPTS)
                    devices = {'devices': {
                        'com.apple.CoreSimulator.SimRuntime.iOS-27-0': [{'udid': 'phone', 'name': 'iPhone', 'isAvailable': True}]}}
                    runtimes = {name: {'runtimeIdentifier': 'com.apple.CoreSimulator.SimRuntime.' + platform + '-27-0', 'state': 'Ready', 'mountPath': '/'} for name, platform in [('phone', 'iOS')]}
                    (root / 'xcrun').write_text('#!/usr/bin/env python3\nimport sys, json\nif sys.argv[1:4] == ["simctl", "runtime", "list"]: print(' + repr(json.dumps(runtimes)) + ')\nelif sys.argv[1:3] == ["simctl", "list"]: print(' + repr(json.dumps(devices)) + ')\n')
                    (root / 'xcodebuild').write_text('#!/usr/bin/env python3\nimport json, sys\nfrom pathlib import Path\nPath("arguments.json").write_text(json.dumps(sys.argv[1:]))\nsys.exit(7)\n')
                    (root / 'uname').write_text('#!/bin/sh\necho ' + arch + '\n')
                    for executable in ('xcrun', 'xcodebuild', 'uname'):
                        (root / executable).chmod(0o755)
                    result = subprocess.run(['bash', str(SCRIPTS / entrypoint)], cwd=root,
                                            env={**os.environ, 'PATH': directory + ':' + os.environ['PATH']},
                                            capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 7, result.stderr)
                    arguments = json.loads((root / 'arguments.json').read_text())
                    exclusions = [arg for arg in arguments if arg.startswith('EXCLUDED_ARCHS')]
                    self.assertEqual(exclusions, ['EXCLUDED_ARCHS=x86_64'] if arch == 'arm64' else [])
                    self.assertIn('platform=iOS Simulator,id=phone', arguments)
