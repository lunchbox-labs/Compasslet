"""Exercise the change classifier against pull request merge commits."""
import io
import os
import runpy
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
MODULE = runpy.run_path(str(SCRIPTS / "ci-scope"))

DOCUMENTATION = ["README.md", "AGENTS.md", ".github/CODEOWNERS",
                 "docs/superpowers/specs/2026-10-30-widget-history.md",
                 "app-store/en-US/description.txt"]
CODE = ["App/Heading/CompassView.swift", "Tests/CompassCoreTests/CompassCoreTests.swift",
        "Package.swift", "Compass.xcodeproj/project.pbxproj", ".github/workflows/check.yml",
        "scripts/test-ios", ".swift-format", "docs-site/index.md", "README.md.bak"]


class ClassificationTests(unittest.TestCase):
    def test_documentation_only_changes_skip_the_simulator_checks(self):
        self.assertFalse(MODULE["simulator_checks_required"](["README.md"]))
        self.assertFalse(MODULE["simulator_checks_required"](DOCUMENTATION))

    def test_every_other_change_keeps_the_simulator_checks(self):
        for path in CODE:
            with self.subTest(path=path):
                self.assertTrue(MODULE["simulator_checks_required"]([path]))
                self.assertTrue(MODULE["simulator_checks_required"](["README.md", path]))

    def test_an_empty_comparison_runs_every_check(self):
        self.assertTrue(MODULE["simulator_checks_required"]([]))


class MergeCommitTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.repository = Path(self.directory.name)

    def git(self, *arguments):
        return subprocess.run(
            ["git", "-c", "user.name=Test", "-c", "user.email=test@example.com",
             "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", *arguments],
            check=True, capture_output=True, text=True, cwd=self.repository).stdout.strip()

    def commit(self, path, content, message):
        file = self.repository / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(content)
        self.git("add", "--all")
        self.git("commit", "--quiet", "--message", message)

    def scope(self, **environment):
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            result = os.path.join(directory, "output")
            MODULE["main"]({"GITHUB_EVENT_NAME": "pull_request", "GITHUB_OUTPUT": result,
                            **environment}, cwd=self.repository, out=output)
            with open(result, encoding="utf-8") as written:
                return written.read(), output.getvalue()

    def test_pushes_run_every_check_without_inspecting_the_checkout(self):
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            result = os.path.join(directory, "output")
            MODULE["main"]({"GITHUB_EVENT_NAME": "push", "GITHUB_OUTPUT": result},
                           cwd=self.repository, out=output)
            with open(result, encoding="utf-8") as written:
                self.assertEqual(written.read(), "simulators=true\n")
        self.assertIn("push runs every check", output.getvalue())

    def test_changes_are_read_from_the_merge_commit_against_its_base(self):
        self.git("init", "--quiet", "--initial-branch=main")
        self.commit("App/Compass.swift", "// base\n", "base")
        self.commit("README.md", "# Base\n", "readme")
        self.git("checkout", "--quiet", "-b", "docs")
        self.commit("README.md", "# Updated\n", "update the readme")
        head = self.git("rev-parse", "HEAD")
        self.git("checkout", "--quiet", "main")
        self.commit("App/Compass.swift", "// base moves on\n", "base moves on")
        # GitHub tests the merge of the pull request into the current base, exactly as
        # actions/checkout provides it: base first, pull request head second.
        self.git("merge", "--quiet", "--no-ff", "--no-edit", "docs")

        self.assertEqual(MODULE["pull_request_changes"](head, self.repository), ["README.md"])
        self.assertEqual(self.scope(PULL_REQUEST_HEAD=head)[0], "simulators=false\n")
        with self.assertRaisesRegex(SystemExit, "PULL_REQUEST_HEAD"):
            self.scope()

        # A merge commit of an older head, or no merge commit at all, proves nothing about
        # the pull request, so every check runs.
        stale = self.git("rev-parse", "main^1")
        self.assertIsNone(MODULE["pull_request_changes"](stale, self.repository))
        written, printed = self.scope(PULL_REQUEST_HEAD=stale)
        self.assertEqual(written, "simulators=true\n")
        self.assertIn("::warning::", printed)
        self.git("checkout", "--quiet", "docs")
        self.assertIsNone(MODULE["pull_request_changes"](head, self.repository))
        self.assertEqual(self.scope(PULL_REQUEST_HEAD=head)[0], "simulators=true\n")


if __name__ == "__main__":
    unittest.main()
