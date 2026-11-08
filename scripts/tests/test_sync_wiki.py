"""Sync a folder into a local wiki repository, as the Wiki workflow does on GitHub."""
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/sync-wiki'
IDENTITY = ['-c', 'user.name=Test', '-c', 'user.email=test@example.invalid']


def git(*arguments, cwd):
    return subprocess.run(['git', *IDENTITY, *arguments], check=True, capture_output=True,
                          text=True, cwd=cwd).stdout


class SyncWikiTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.remote = self.root / 'wiki.git'
        git('init', '--quiet', '--bare', '--initial-branch=master', str(self.remote),
            cwd=self.root)
        # The wiki's history must survive every sync, so the remote refuses rewrites.
        git('config', 'receive.denyNonFastForwards', 'true', cwd=self.remote)
        seed = self.root / 'seed'
        git('clone', '--quiet', str(self.remote), str(seed), cwd=self.root)
        (seed / 'Home.md').write_text('Old home\n')
        (seed / 'Removed-Page.md').write_text('Gone soon\n')
        git('add', '--all', cwd=seed)
        git('commit', '--quiet', '-m', 'Edit on the wiki', cwd=seed)
        git('push', '--quiet', 'origin', 'HEAD', cwd=seed)
        self.source = self.root / 'source'
        self.source.mkdir()

    def sync(self, *extra):
        return subprocess.run(['bash', str(SCRIPT), str(self.source), str(self.remote), *extra],
                              capture_output=True, text=True, cwd=self.root)

    def wiki_files(self):
        listing = git('ls-tree', '-r', '--name-only', 'master', cwd=self.remote)
        return sorted(listing.split())

    def wiki_file(self, name):
        return git('show', 'master:' + name, cwd=self.remote)

    def log(self):
        return git('log', '--format=%s', 'master', cwd=self.remote).splitlines()

    def test_wiki_matches_the_folder_on_top_of_its_history(self):
        (self.source / 'Home.md').write_text('New home\n')
        (self.source / '_Sidebar.md').write_text('[Home](Home)\n')
        result = self.sync('lunchbox-labs/compasslet@abc1234')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.wiki_files(), ['Home.md', '_Sidebar.md'])
        self.assertEqual(self.wiki_file('Home.md'), 'New home\n')
        self.assertEqual(self.log(), ['Sync the wiki from lunchbox-labs/compasslet@abc1234',
                                      'Edit on the wiki'])

    def test_replacing_edits_made_on_the_wiki_warns(self):
        (self.source / 'Home.md').write_text('New home\n')
        result = self.sync()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('::warning::The wiki was last edited outside this sync', result.stdout)
        (self.source / 'Home.md').write_text('Newer home\n')
        result = self.sync()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('::warning::', result.stdout)

    def test_a_folder_with_symbolic_links_leaves_the_wiki_alone(self):
        (self.source / 'Home.md').write_text('New home\n')
        (self.source / 'Link.md').symlink_to(self.source / 'Home.md')
        result = self.sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('symbolic links', result.stderr)
        self.assertEqual(self.log(), ['Edit on the wiki'])

    def test_an_unchanged_folder_adds_no_commit(self):
        (self.source / 'Home.md').write_text('Old home\n')
        (self.source / 'Removed-Page.md').write_text('Gone soon\n')
        result = self.sync()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('already matches', result.stdout)
        self.assertEqual(self.log(), ['Edit on the wiki'])

    def test_a_folder_without_a_home_page_leaves_the_wiki_alone(self):
        (self.source / 'Other.md').write_text('Not a wiki\n')
        result = self.sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Home.md is missing', result.stderr)
        self.assertEqual(self.wiki_files(), ['Home.md', 'Removed-Page.md'])
        self.assertEqual(self.log(), ['Edit on the wiki'])

    def test_wrong_arguments_fail_without_touching_the_wiki(self):
        result = subprocess.run(['bash', str(SCRIPT), str(self.source)], capture_output=True,
                                text=True, cwd=self.root)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.log(), ['Edit on the wiki'])


class RepositoryWikiTests(unittest.TestCase):
    wiki = ROOT / 'wiki'

    def assert_page_exists(self, page):
        self.assertTrue((self.wiki / (page + '.md')).is_file(), page + '.md is not in wiki/')

    def test_every_link_between_wiki_pages_names_a_page_in_the_folder(self):
        pages = sorted(self.wiki.glob('*.md'))
        self.assertIn(self.wiki / 'Home.md', pages)
        for page in pages:
            for target in re.findall(r'\]\(([^)\s]+)\)', page.read_text()):
                if re.match(r'[a-z]+:', target) or target.startswith('#'):
                    continue
                target = target.split('#')[0]
                with self.subTest(page=page.name, target=target):
                    if Path(target).suffix:
                        self.assertTrue((self.wiki / target).is_file())
                    else:
                        self.assert_page_exists(target)

    def test_links_into_the_published_wiki_name_a_page_in_the_folder(self):
        files = [ROOT / 'README.md', ROOT / 'AGENTS.md', *sorted((ROOT / 'website').rglob('*.md'))]
        pattern = r'github\.com/lunchbox-labs/compasslet/wiki/([A-Za-z0-9_-]+)'
        found = 0
        for path in files:
            for page in re.findall(pattern, path.read_text(), flags=re.IGNORECASE):
                found += 1
                with self.subTest(file=str(path.relative_to(ROOT)), page=page):
                    self.assert_page_exists(page)
        self.assertGreater(found, 0)


if __name__ == '__main__':
    unittest.main()
