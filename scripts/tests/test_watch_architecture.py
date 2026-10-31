import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]

class WatchArchitectureTests(unittest.TestCase):
    def test_architecture_wrapper_preserves_arguments_and_status(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'xcodebuild').write_text('#!/bin/sh\nprintf "%s\\n" "$@"\nexit 7\n')
            (root / 'xcodebuild').chmod(0o755)
            for arch in ('arm64', 'x86_64'):
                (root / 'uname').write_text('#!/bin/sh\necho ' + arch + '\n')
                (root / 'uname').chmod(0o755)
                result = subprocess.run(['bash', str(SCRIPTS / 'watch-xcodebuild'), '-destination', 'a b', 'test'], env={**os.environ, 'PATH': directory + ':' + os.environ['PATH']}, capture_output=True, text=True)
                self.assertEqual(result.returncode, 7)
                self.assertEqual(result.stdout.splitlines()[:3], ['-destination', 'a b', 'test'])
                self.assertEqual('EXCLUDED_ARCHS[sdk=watchsimulator*]=x86_64' in result.stdout, arch == 'arm64')
