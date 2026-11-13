"""Offline delivery-boundary tests; no signing, upload or Apple API calls."""
import contextlib
import importlib.machinery
import importlib.util
import io
import os
from pathlib import Path
import plistlib
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
    def export_options(self, release_candidate):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            archive = work / 'Compass.xcarchive'
            exported = work / 'export'
            exports = []

            def run(*args, operation, **kwargs):
                self.assertEqual(operation, 'export archive')
                self.assertEqual(args[:5], ('xcodebuild', '-exportArchive', '-archivePath', archive, '-exportPath'))
                self.assertEqual(args[5], exported)
                self.assertEqual(args[6], '-exportOptionsPlist')
                exports.append(plistlib.loads(Path(args[7]).read_bytes()))

            with patch.object(testflight, 'WORK', work), patch.object(testflight, 'run', side_effect=run):
                testflight.export_archive(archive, exported, 'TEAM123456', ['app-profile', 'activity-profile'],
                                          release_candidate)
            self.assertEqual(len(exports), 1)
            return exports[0]

    def test_export_keeps_signing_and_build_numbers_for_both_kinds_of_build(self):
        for release_candidate in (False, True):
            with self.subTest(release_candidate=release_candidate):
                options = self.export_options(release_candidate)
                self.assertEqual(options['method'], 'app-store-connect')
                self.assertEqual(options['destination'], 'export')
                self.assertEqual(options['teamID'], 'TEAM123456')
                self.assertEqual(options['signingStyle'], 'manual')
                self.assertEqual(options['signingCertificate'], 'Apple Distribution')
                self.assertEqual(options['provisioningProfiles'], {
                    'dev.lunchbox-labs.carplay-compass': 'app-profile',
                    'dev.lunchbox-labs.carplay-compass.activity': 'activity-profile',
                })
                self.assertFalse(options['manageAppVersionAndBuildNumber'])

    def test_only_release_candidates_can_be_submitted_to_the_app_store(self):
        self.assertTrue(self.export_options(release_candidate=False)['testFlightInternalTestingOnly'])
        self.assertNotIn('testFlightInternalTestingOnly', self.export_options(release_candidate=True))

    def test_only_test_builds_record_their_commit_for_the_app(self):
        commit = 'a' * 40
        original = {'CFBundleName': 'Compasslet', 'UISceneDelegateClassName': '$(PRODUCT_MODULE_NAME).Delegate'}
        for release_candidate in (False, True):
            with self.subTest(release_candidate=release_candidate), tempfile.TemporaryDirectory() as temporary:
                info_plist = Path(temporary) / 'Info.plist'
                info_plist.write_bytes(plistlib.dumps(original))
                testflight.mark_build(info_plist, commit, release_candidate)
                expected = original if release_candidate else dict(original, CompassletTestBuildCommit=commit)
                self.assertEqual(plistlib.loads(info_plist.read_bytes()), expected)

    def test_a_committed_commit_key_stops_the_build(self):
        with tempfile.TemporaryDirectory() as temporary:
            info_plist = Path(temporary) / 'Info.plist'
            info_plist.write_bytes(plistlib.dumps({'CompassletTestBuildCommit': 'b' * 40}))
            for release_candidate in (False, True):
                with self.subTest(release_candidate=release_candidate), \
                        self.assertRaises(testflight.SigningError):
                    testflight.mark_build(info_plist, 'a' * 40, release_candidate)

    def test_the_app_source_does_not_mark_itself_as_a_test_build(self):
        info = plistlib.loads((Path(__file__).resolve().parents[2] / 'App/Info.plist').read_bytes())
        self.assertNotIn(testflight.TEST_BUILD_COMMIT_KEY, info)

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

    def test_publish_needs_the_build_kind_and_commit(self):
        valid = {'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_REF': 'refs/heads/main', 'GITHUB_ACTIONS': 'true',
                 'BUILD_NUMBER': '17.1', 'RELEASE_CANDIDATE': 'false', 'SOURCE_COMMIT': 'a' * 40,
                 'APPLE_TEAM_ID': ''}
        cases = [
            ({'RELEASE_CANDIDATE': ''}, 'RELEASE_CANDIDATE'),
            ({'RELEASE_CANDIDATE': 'yes'}, 'RELEASE_CANDIDATE'),
            ({'SOURCE_COMMIT': ''}, 'SOURCE_COMMIT'),
            ({'SOURCE_COMMIT': 'abc1234'}, 'SOURCE_COMMIT'),
            # Both kinds of build get past these checks to the next required input.
            ({}, 'APPLE_TEAM_ID'),
            ({'RELEASE_CANDIDATE': 'true'}, 'APPLE_TEAM_ID'),
        ]
        for changes, expected in cases:
            with self.subTest(changes=changes):
                with patch.dict(os.environ, dict(valid, **changes)), patch.object(testflight, 'read_copy'), \
                        contextlib.redirect_stdout(io.StringIO()), \
                        self.assertRaises(testflight.SigningError) as raised:
                    testflight.publish()
                self.assertIn(expected, str(raised.exception))

    def test_only_manual_runs_from_main_reach_the_build(self):
        cases = [
            ({'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_REF': 'refs/heads/main'}, 'Workflow build number'),
            ({'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_REF': 'refs/heads/feature'}, 'main'),
            ({'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/tags/v1.2.3'}, 'Only manual builds'),
            ({'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/heads/main'}, 'Only manual builds'),
            ({'GITHUB_EVENT_NAME': 'release', 'GITHUB_REF': 'refs/tags/v1.2.3'}, 'Only manual builds'),
        ]
        for environment, expected in cases:
            with self.subTest(environment=environment):
                environment = dict(environment, GITHUB_ACTIONS='true', BUILD_NUMBER='')
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
