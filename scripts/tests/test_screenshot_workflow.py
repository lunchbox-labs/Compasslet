"""Execute the workflow's inline shell steps without a simulator or GitHub token."""
import os
import re
import runpy
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
SETS = runpy.run_path(str(ROOT / 'scripts/screenshots'))['SETS']


def shell_step(name):
    workflow = (ROOT / '.github/workflows/screenshots.yml').read_text()
    step = workflow.split('      - name: ' + name + '\n', 1)[1]
    step = step.split('\n      - ', 1)[0]
    return textwrap.dedent(step.split('        run: |\n', 1)[1])


class ScreenshotWorkflowTests(unittest.TestCase):
    def choose_ref(self, event, ref='', head=''):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'output'
            output.touch()
            result = subprocess.run(
                ['bash', '-e', '-c', shell_step('Choose what to check out')],
                env=dict(os.environ, EVENT_NAME=event, REF_INPUT=ref,
                         PR_HEAD_SHA=head, GITHUB_OUTPUT=str(output)),
                capture_output=True, text=True)
            return result, output.read_text()

    def test_each_pr_capture_uses_its_immutable_event_head(self):
        for head in ('a1' * 20, 'b2' * 20):
            with self.subTest(head=head):
                result, output = self.choose_ref('pull_request', ref='main', head=head)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output, 'ref=' + head + '\n')

    def test_missing_or_malformed_pr_head_fails_without_output(self):
        for head in ('', 'feature', 'a' * 39, 'a' * 40 + '\nref=main'):
            with self.subTest(head=head):
                result, output = self.choose_ref('pull_request', head=head)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(output, '')

    def test_manual_refs_preserve_existing_options(self):
        for ref, expected in [('', ''), ('206', 'refs/pull/206/head'),
                              ('feature/screens', 'feature/screens'), ('v1.0', 'v1.0'),
                              ('ab' * 20, 'ab' * 20)]:
            with self.subTest(ref=ref):
                result, output = self.choose_ref('workflow_dispatch', ref=ref)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output, 'ref=' + expected + '\n')

    def test_manual_ref_cannot_inject_workflow_outputs(self):
        for ref in ('main\nref=other', 'main\rref=other'):
            with self.subTest(ref=ref):
                result, output = self.choose_ref('workflow_dispatch', ref=ref)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(output, '')

    def test_shell_metacharacters_are_passed_as_data(self):
        ref = '$(exit 42)`exit 43`;exit 44'
        result, output = self.choose_ref('workflow_dispatch', ref=ref)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, 'ref=' + ref + '\n')

    def test_source_report_uses_actual_checked_out_commit(self):
        revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        with tempfile.TemporaryDirectory() as directory:
            summary = Path(directory) / 'summary'
            result = subprocess.run(
                ['bash', '-e', '-c', shell_step('Report the captured source')], cwd=ROOT,
                env=dict(os.environ, GITHUB_STEP_SUMMARY=str(summary)),
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(revision, result.stdout)
            self.assertIn(revision, summary.read_text())

    def capture_arguments(self, capture_set):
        with tempfile.TemporaryDirectory() as directory:
            bin_directory = Path(directory) / 'bin'
            bin_directory.mkdir()
            record = Path(directory) / 'arguments'
            fake = bin_directory / 'python3'
            fake.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$RECORD"\n')
            fake.chmod(0o755)
            result = subprocess.run(
                ['bash', '-e', '-c', shell_step('Capture the screens')],
                env=dict(os.environ, PATH=str(bin_directory) + os.pathsep + os.environ['PATH'],
                         RECORD=str(record), CAPTURE_SET=capture_set, DEVICES='largest',
                         APPEARANCES='dark', SCREEN_FILTER='tour; exit 3', MAX_PARTS='3',
                         RUNNER_TEMP=directory),
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return record.read_text().splitlines()[1:]

    def test_each_set_leaves_devices_and_appearances_to_the_script(self):
        for capture_set in SETS:
            with self.subTest(capture_set=capture_set):
                arguments = self.capture_arguments(capture_set)
                self.assertEqual(arguments[:3], ['capture', '--set', capture_set])
                self.assertNotIn('--devices', arguments)
                self.assertNotIn('--appearances', arguments)
                self.assertEqual(arguments[arguments.index('--filter') + 1], 'tour; exit 3')
                self.assertEqual(arguments[arguments.index('--max-parts') + 1], '3')

    def test_the_workflow_offers_every_set_the_script_has(self):
        workflow = (ROOT / '.github/workflows/screenshots.yml').read_text()
        match = re.search(r'^      set:\n(?:        .*\n)*?        options: \[(.*)\]$', workflow,
                          re.MULTILINE)
        self.assertIsNotNone(match, 'the set input has no options list')
        options = [option.strip() for option in match.group(1).split(',')]
        self.assertEqual(options[0], 'every screen')
        self.assertEqual(sorted(options[1:]), sorted(SETS))

    def test_pull_requests_and_the_default_choice_capture_every_screen(self):
        for capture_set in ('', 'every screen'):
            with self.subTest(capture_set=capture_set):
                arguments = self.capture_arguments(capture_set)
                self.assertNotIn('--set', arguments)
                self.assertEqual(arguments[arguments.index('--devices') + 1], 'largest')
                self.assertEqual(arguments[arguments.index('--appearances') + 1], 'dark')
                self.assertEqual(arguments[arguments.index('--max-parts') + 1], '3')


if __name__ == '__main__':
    unittest.main()
