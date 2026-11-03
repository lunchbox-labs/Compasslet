"""Offline delivery-boundary tests; no signing, upload or Apple API calls."""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

loader = importlib.machinery.SourceFileLoader('testflight', str(Path(__file__).resolve().parents[1] / 'testflight'))
spec = importlib.util.spec_from_loader(loader.name, loader)
testflight = importlib.util.module_from_spec(spec)
loader.exec_module(testflight)


class PublishIdentityTests(unittest.TestCase):
    def test_metadata_identity_is_exposed_only_after_successful_validation_and_upload(self):
        for failed_operation in ('Apple validation', 'upload', None):
            with self.subTest(failed_operation=failed_operation), tempfile.TemporaryDirectory() as temp:
                output = Path(temp) / 'outputs'
                operations = []
                def run(*args, operation, **kwargs):
                    self.assertFalse(output.exists())
                    operations.append(operation)
                    if operation == failed_operation:
                        raise testflight.ToolError(operation, 1)
                with patch.dict(os.environ, {'GITHUB_OUTPUT': str(output)}), \
                        patch.object(testflight, 'run', side_effect=run), contextlib.redirect_stdout(io.StringIO()):
                    if failed_operation:
                        with self.assertRaises(testflight.ToolError):
                            testflight.upload(['--file', 'fixture.ipa'], {}, '1.2.3', '17.2')
                        self.assertFalse(output.exists())
                    else:
                        testflight.upload(['--file', 'fixture.ipa'], {}, '1.2.3', '17.2')
                        self.assertEqual(output.read_text(), 'marketing_version=1.2.3\nbuild_number=17.2\n')
                self.assertEqual(operations, ['Apple validation'] if failed_operation == 'Apple validation'
                                 else ['Apple validation', 'upload'])

    def test_only_manual_main_runs_and_pushed_version_tags_reach_the_build(self):
        accepted = 'Workflow build number'
        cases = [
            ({'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_REF': 'refs/heads/main'}, None, accepted),
            ({'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_REF': 'refs/heads/feature'}, None, 'main'),
            ({'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/tags/v1.2.3'},
             {'ref': 'refs/tags/v1.2.3', 'created': True, 'deleted': False}, accepted),
            ({'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/tags/v1.2.3'},
             {'ref': 'refs/tags/v1.2.3', 'created': False, 'deleted': True}, 'version tag'),
            ({'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/tags/v1.2.3'},
             {'ref': 'refs/tags/v1.2.3', 'created': False, 'deleted': False}, 'version tag'),
            ({'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/heads/main'},
             {'ref': 'refs/heads/main', 'created': True, 'deleted': False}, 'version tag'),
            ({'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/tags/v1.2.3-beta'},
             {'ref': 'refs/tags/v1.2.3-beta', 'created': True, 'deleted': False}, 'X.Y.Z'),
            ({'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/tags/v1.2.4'},
             {'ref': 'refs/tags/v1.2.3', 'created': True, 'deleted': False}, 'X.Y.Z'),
            ({'GITHUB_EVENT_NAME': 'release', 'GITHUB_REF': 'refs/tags/v1.2.3'},
             {'action': 'published', 'release': {'tag_name': 'v1.2.3'}}, 'Only manual main'),
        ]
        for environment, payload, expected in cases:
            with self.subTest(environment=environment, payload=payload), \
                    tempfile.TemporaryDirectory() as temp:
                event = Path(temp) / 'event.json'
                event.write_text(json.dumps(payload or {}))
                environment = dict(environment, GITHUB_ACTIONS='true', GITHUB_EVENT_PATH=str(event),
                                   BUILD_NUMBER='')
                with patch.dict(os.environ, environment), patch.object(testflight, 'read_copy'), \
                        self.assertRaises(testflight.SigningError) as raised:
                    testflight.publish()
                self.assertIn(expected, str(raised.exception))

    def test_publish_failure_still_cleans_signing_material_and_reports_safe_error(self):
        error = testflight.MetadataError('Archived app does not match the uploaded bundle and build.')
        with patch.object(testflight, 'publish', side_effect=error), \
                patch.object(testflight, 'cleanup') as cleanup, \
                patch.object(testflight.sys, 'argv', ['scripts/testflight']), \
                contextlib.redirect_stderr(io.StringIO()) as stderr:
            self.assertEqual(testflight.main(), 1)
        cleanup.assert_called_once()
        self.assertIn(str(error), stderr.getvalue())


if __name__ == '__main__':
    unittest.main()
