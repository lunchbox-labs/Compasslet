"""Synthetic tool output only: never needs Apple credentials or Xcode."""
import contextlib
import io
import subprocess
import sys
import unittest
from unittest.mock import patch

from test_runner import runner


class DiagnosticTests(unittest.TestCase):
    def failure(self, operation, output, command='xcodebuild'):
        result = subprocess.CompletedProcess([command], 65, output, output)
        with patch.object(runner.subprocess, 'run', return_value=result), \
                self.assertRaises(runner.SigningError) as caught:
            runner.run(command, operation=operation)
        return str(caught.exception)

    def test_archive_keeps_actionable_error_and_redacts_variable_fields(self):
        message = self.failure('archive', b"/private/user/SECRET.swift:42:7: error: cannot find 'PRIVATE_VALUE' in scope\n")
        self.assertIn('archive failed (exit code 65)', message)
        self.assertIn("[source]:42:7: error: cannot find '[redacted]' in scope", message)
        self.assertNotIn('PRIVATE_VALUE', message)
        self.assertNotIn('/private/user', message)

    def test_project_and_signing_errors_keep_reason_without_identifiers(self):
        for output, reason in [
            (b"xcodebuild: error: Unable to open project 'SECRET.xcodeproj'.\n", 'Unable to open project'),
            (b'error: Provisioning profile "SECRET" doesn\'t include signing certificate "PRIVATE".\n', "doesn't include signing certificate"),
            (b"error: No profiles for 'PRIVATE' were found\n", 'No profiles for'),
        ]:
            with self.subTest(output=output):
                message = self.failure('export archive', output)
                self.assertIn(reason, message)
                self.assertNotIn('SECRET', message)
                self.assertNotIn('PRIVATE', message)

    def test_credential_and_other_tools_never_emit_captured_output(self):
        for operation, command in [('import signing identity', 'security'), ('verify profile CMS', 'openssl'),
                                   ('verify signature', 'codesign'), ('Apple validation', 'xcrun'),
                                   ('upload', 'xcrun'), ('convert project', 'plutil'), ('archive', 'security')]:
            with self.subTest(operation=operation, command=command):
                message = self.failure(operation, b"error: no such module 'SECRET'\n", command)
                self.assertNotIn('no such module', message)
                self.assertNotIn('SECRET', message)
                self.assertIn('exit code 65', message)

    def test_unknown_payloads_and_controls_fail_closed(self):
        output = (b'error: SECRET=private-token\n::error::PRIVATE\n'
                  b'error: no such module \'SECRET\'\x1b[31m\n'
                  b'error: no such module \'SECRET\'\r::add-mask::PRIVATE\n'
                  b'-----BEGIN PRIVATE KEY-----\nPRIVATEKEYBASE64\n-----END PRIVATE KEY-----\n'
                  b'<plist><data>PROFILEBASE64</data></plist>\n'
                  b'export PASSWORD=SECRET\nsecurity import -P SECRET\n')
        message = self.failure('archive', output)
        self.assertIn('No recognized safe build diagnostics', message)
        for forbidden in ['SECRET', 'PRIVATE', 'PROFILEBASE64', '\x1b', '\r', '::', 'security import']:
            self.assertNotIn(forbidden, message)

    def test_multiline_variable_payload_is_not_reconstructed(self):
        output = b"error: no such module '-----BEGIN PRIVATE KEY-----\nPAYLOAD\n-----END PRIVATE KEY-----'\n"
        message = self.failure('archive', output)
        self.assertNotIn('PAYLOAD', message)
        self.assertNotIn('BEGIN', message)
        self.assertIn('No recognized safe build diagnostics', message)

    def test_diagnostics_are_bounded_and_deduplicated(self):
        output = b''.join(f"/secret.swift:{i}:1: error: no such module 'SECRET'\n".encode() for i in range(1000))
        message = self.failure('archive', output)
        self.assertLessEqual(len(message), 4096)
        self.assertLessEqual(message.count('error:'), 20)
        message = self.failure('archive', b"error: no such module 'SECRET'\n" * 1000)
        self.assertEqual(message.count('no such module'), 1)
        message = self.failure('archive', b"error: no such module '" + b'S' * 20000 + b"'\n")
        self.assertIn('No recognized safe build diagnostics', message)

    def test_failed_build_command_kind_without_paths_or_arguments(self):
        output = (b"The following build commands failed:\n"
                  b"\tSwiftCompile normal arm64 /private/SECRET.swift (in target 'PRIVATE' from project 'SECRET')\n"
                  b"\tCodeSign /private/SECRET.app PASSWORD=PRIVATE\n"
                  b"(2 failures)\n")
        message = self.failure('archive', output)
        self.assertIn('Failed build command: SwiftCompile', message)
        self.assertIn('Failed build command: CodeSign', message)
        self.assertNotIn('PRIVATE', message)
        self.assertNotIn('SECRET', message)

    def test_payload_wrappers_do_not_become_diagnostics(self):
        output = (b'<string>error: no such module \'PRIVATE\'</string>\n'
                  b'{"error": "no such module \'PRIVATE\'"}\n'
                  b'-----BEGIN CERTIFICATE-----\nerror: no such module \'PRIVATE\'\n-----END CERTIFICATE-----\n')
        message = self.failure('archive', output)
        self.assertIn('No recognized safe build diagnostics', message)

    def test_success_and_unchecked_calls_preserve_result_without_logging(self):
        for code, check in [(0, True), (65, False)]:
            result = subprocess.CompletedProcess(['security'], code, b'PRIVATE', b'SECRET')
            captured = io.StringIO()
            with patch.object(runner.subprocess, 'run', return_value=result), \
                    contextlib.redirect_stdout(captured), contextlib.redirect_stderr(captured):
                actual = runner.run('security', operation='import signing identity', check=check)
            self.assertIs(actual, result)
            self.assertEqual(captured.getvalue(), '')

    def test_real_subprocess_failure_keeps_exit_code_without_output(self):
        with self.assertRaises(runner.SigningError) as caught:
            runner.run(sys.executable, '-c',
                       "import sys; print('PRIVATE'); print('SECRET', file=sys.stderr); sys.exit(23)",
                       operation='verify signature')
        self.assertEqual(str(caught.exception), 'verify signature failed (exit code 23).')

    def test_launch_failure_hides_exception_and_command(self):
        with patch.object(runner.subprocess, 'run', side_effect=OSError('SECRET')), \
                self.assertRaises(runner.SigningError) as caught:
            runner.run('security', 'SECRET', operation='import signing identity')
        self.assertEqual(str(caught.exception), 'import signing identity could not start.')
