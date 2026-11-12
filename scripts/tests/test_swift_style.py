import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]


class SwiftStyleVersionTests(unittest.TestCase):
    def run_with_version(self, version):
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / 'swift-format'
            fake.write_text('#!/bin/sh\n[ "$1" = --version ] && echo ' + version + '\nexit 0\n')
            fake.chmod(0o755)
            return subprocess.run(['bash', str(SCRIPTS / 'swift-style'), 'check'],
                                  env={**os.environ, 'PATH': directory + ':' + os.environ['PATH']},
                                  capture_output=True, text=True, timeout=30)

    def test_accepts_any_patch_release_of_the_expected_minor(self):
        for version in ('6.4', '6.4.0', '6.4.2'):
            with self.subTest(version=version):
                result = self.run_with_version(version)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_other_minor_releases(self):
        for version in ('6.3.9', '6.5.0', '6.40.1'):
            with self.subTest(version=version):
                result = self.run_with_version(version)
                self.assertEqual(result.returncode, 2)
                self.assertIn('Expected swift-format 6.4.x', result.stderr)


if __name__ == '__main__':
    unittest.main()
