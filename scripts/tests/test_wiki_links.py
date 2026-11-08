"""Check that links to wiki pages, inside the wiki folder and from the rest of the repository, name pages that exist."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


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
