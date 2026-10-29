"""Synthetic subprocess and Actions masking tests; no Apple credentials."""
import contextlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_runner import runner


class DiagnosticTests(unittest.TestCase):
    def test_mask_escapes_whole_value_and_each_nonempty_line(self):
        output = io.StringIO()
        with patch.dict(os.environ, GITHUB_ACTIONS='true'), contextlib.redirect_stdout(output):
            runner.mask('first%line\r\nsecond\n')
        self.assertEqual(output.getvalue(),
                         '::add-mask::first%25line%0D%0Asecond%0A\n'
                         '::add-mask::first%25line\n::add-mask::second\n')

    def test_mask_never_prints_values_outside_actions(self):
        output = io.StringIO()
        with patch.dict(os.environ, GITHUB_ACTIONS='false'), contextlib.redirect_stdout(output), \
                self.assertRaises(runner.SigningError):
            runner.mask('PRIVATE')
        self.assertEqual(output.getvalue(), '')

    def test_mask_flushes_before_next_tool(self):
        class Output(io.StringIO):
            flushed = False
            def flush(self):
                self.flushed = True
                super().flush()
        output = Output()
        def tool(*args, **kwargs):
            self.assertTrue(output.flushed)
            self.assertEqual(output.getvalue(), '::add-mask::synthetic-password\n')
            return subprocess.CompletedProcess(args, 0)
        with patch.dict(os.environ, GITHUB_ACTIONS='true'), contextlib.redirect_stdout(output), \
                patch.object(runner.subprocess, 'run', side_effect=tool):
            runner.mask('synthetic-password')
            runner.run('xcodebuild', operation='archive')

    def test_decoded_key_is_masked_before_tools_can_use_it(self):
        import base64
        key = b'-----BEGIN PRIVATE KEY-----\nSYNTHETIC-KEY\n-----END PRIVATE KEY-----\n'
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as temporary, patch.object(runner, 'WORK', Path(temporary)), \
                patch.dict(os.environ, GITHUB_ACTIONS='true', ASC_API_PRIVATE_KEY_BASE64=base64.b64encode(key).decode()), \
                contextlib.redirect_stdout(output):
            path = runner.decode('ASC_API_PRIVATE_KEY_BASE64', 'synthetic.p8')
            self.assertEqual(path.read_bytes(), key)
            self.assertIn('::add-mask::SYNTHETIC-KEY\n', output.getvalue())
            self.assertIn('KEY-----%0ASYNTHETIC-KEY%0A', output.getvalue())

    def test_build_output_streams_while_credential_output_is_captured(self):
        # A real executable named xcodebuild exercises inherited file descriptors,
        # not a mocked CompletedProcess pretending to stream.
        with tempfile.TemporaryDirectory() as temporary:
            tool = Path(temporary) / 'xcodebuild'
            tool.write_text('#!/bin/sh\nprintf "compiler stdout\\n"\nprintf "compiler stderr\\n" >&2\nexit 65\n')
            tool.chmod(0o700)
            script = ("import sys; sys.path.insert(0, 'Tests/Signing'); from test_runner import runner; "
                      "runner.sys.argv=['testflight']; "
                      "runner.cleanup=lambda: print('cleanup complete'); "
                      "runner.publish=lambda: runner.run('xcodebuild', operation='archive'); "
                      "sys.exit(runner.main())")
            result = subprocess.run([sys.executable, '-c', script], capture_output=True, text=True,
                                    env=dict(os.environ, PATH=temporary + os.pathsep + os.environ['PATH']))
            self.assertEqual(result.returncode, 65)
            self.assertIn('compiler stdout', result.stdout)
            self.assertIn('compiler stderr', result.stderr)
            self.assertIn('archive failed (exit code 65)', result.stderr)
            self.assertIn('cleanup complete', result.stdout)
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output), \
                self.assertRaises(runner.SigningError) as caught:
            runner.run(sys.executable, '-c', "print('PRIVATE'); raise SystemExit(23)", operation='verify signature')
        self.assertEqual(output.getvalue(), '')
        self.assertEqual(str(caught.exception), 'verify signature failed (exit code 23).')

    def test_only_selected_build_calls_stream(self):
        for command, operation, streams in [('xcodebuild', 'archive', True), ('xcodebuild', 'export archive', True),
                                             ('xcodebuild', 'read Xcode version', False),
                                             ('security', 'archive', False), ('xcrun', 'upload', False)]:
            with self.subTest(command=command, operation=operation), \
                    patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as tool:
                runner.run(command, operation=operation)
                self.assertEqual(tool.call_args.kwargs['stdout'], None if streams else subprocess.PIPE)
                self.assertEqual(tool.call_args.kwargs['stderr'], None if streams else subprocess.PIPE)

    def test_cleanup_failure_supersedes_tool_status_without_leaking_arguments(self):
        output = io.StringIO()
        with patch.object(runner.sys, 'argv', ['testflight']), \
                patch.object(runner, 'publish', side_effect=runner.ToolError('archive', 65)), \
                patch.object(runner, 'cleanup', side_effect=runner.SigningError('Cleanup failed.')), \
                contextlib.redirect_stderr(output):
            self.assertEqual(runner.main(), 1)
        self.assertIn('Cleanup failed.', output.getvalue())

    def test_non_actions_publish_rejected_before_credentials_or_tools(self):
        with patch.dict(os.environ, GITHUB_ACTIONS='false', GITHUB_EVENT_NAME='workflow_dispatch',
                        GITHUB_REF='refs/heads/main', UPLOAD_CONFIRMATION='UPLOAD INTERNAL TESTFLIGHT',
                        BUILD_NUMBER='1.0.0', APPLE_TEAM_ID='TEAM123456', ASC_API_KEY_ID='KEY123',
                        ASC_API_ISSUER_ID='12345678-1234-1234-1234-123456789abc',
                        IOS_DISTRIBUTION_P12_PASSWORD='synthetic'), \
                patch.object(runner, 'capabilities', side_effect=AssertionError('Passed Actions gate')), \
                patch.object(runner, 'run') as tool, self.assertRaises(runner.SigningError):
            runner.publish()
        tool.assert_not_called()

    def test_launch_failure_hides_exception_and_command(self):
        with patch.object(runner.subprocess, 'run', side_effect=OSError('SECRET')), \
                self.assertRaises(runner.SigningError) as caught:
            runner.run('security', 'SECRET', operation='import signing identity')
        self.assertEqual(str(caught.exception), 'import signing identity could not start.')
