"""Offline Release workflow tests against a stateful GitHub REST fake."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import github_release
import metadata_sync as metadata

REPO = 'lunchbox-labs/compasslet'
BUILD_SHA = 'a' * 40
OTHER_SHA = 'b' * 40
PROJECT = b'MARKETING_VERSION = 1.0;\nMARKETING_VERSION = 1.0;\n'


def missing(url):
    return HTTPError(url, 404, 'Not Found', {}, None)


class FakeGitHub:
    """Workflow runs, contents, tags and releases of one repository."""
    def __init__(self):
        self.runs = [{'id': 900 + n, 'run_number': n, 'run_attempt': 1, 'event': 'workflow_dispatch',
                      'head_branch': 'main', 'path': '.github/workflows/publish.yml',
                      'head_sha': BUILD_SHA if n == 33 else OTHER_SHA,
                      'head_repository': {'full_name': REPO}} for n in range(40, 0, -1)]
        self.jobs = {(933, 1): [{'name': 'publish', 'conclusion': 'success'},
                                {'name': 'metadata', 'conclusion': 'success'}]}
        self.files = {BUILD_SHA: PROJECT}
        self.tags = {}
        self.annotated = {}
        self.releases = []
        self.assets = {}
        self.calls = []
        self.counter = 0

    def respond(self, value):
        return io.BytesIO(value if isinstance(value, bytes) else json.dumps(value).encode())

    def open(self, request, timeout):
        url = urlsplit(request.full_url)
        assert request.get_header('Authorization') == 'Bearer test-token'
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        method, path = request.method, url.path
        self.calls.append((method, url.netloc, path))
        body = request.data
        value = self.route(method, url.netloc, path, query, body, request)
        if value is None:
            raise missing(request.full_url)
        return self.respond(value)

    def route(self, method, host, path, query, body, request):
        base = '/repos/' + REPO
        if host == 'uploads.github.com':
            release_id = int(path.split('/')[-2])
            self.assets.setdefault(release_id, []).append((query['name'], body))
            return {'id': 1}
        if (method, path) == ('GET', base + '/actions/workflows/publish.yml/runs'):
            assert query['event'] == 'workflow_dispatch' and query['branch'] == 'main'
            page, size = int(query['page']), int(query['per_page'])
            return {'workflow_runs': self.runs[(page - 1) * size:page * size]}
        if method == 'GET' and path.startswith(base + '/actions/runs/'):
            parts = path.split('/')
            return {'jobs': self.jobs.get((int(parts[6]), int(parts[8])), [])}
        if (method, path) == ('GET', base + '/contents/Compass.xcodeproj/project.pbxproj'):
            assert request.get_header('Accept') == 'application/vnd.github.raw'
            return self.files.get(query['ref'])
        if method == 'GET' and path.startswith(base + '/git/ref/tags/'):
            tag = path.rsplit('/', 1)[1]
            if tag in self.annotated:
                return {'object': {'type': 'tag', 'sha': 'c' * 40}}
            return {'object': {'type': 'commit', 'sha': self.tags[tag]}} if tag in self.tags else None
        if method == 'GET' and path == base + '/git/tags/' + 'c' * 40:
            return {'object': {'type': 'commit', 'sha': next(iter(self.annotated.values()))}}
        if (method, path) == ('POST', base + '/git/refs'):
            payload = json.loads(body)
            tag = payload['ref'].removeprefix('refs/tags/')
            assert tag not in self.tags
            self.tags[tag] = payload['sha']
            return {'ref': payload['ref']}
        if method == 'GET' and path.startswith(base + '/releases/tags/'):
            tag = path.rsplit('/', 1)[1]
            return next((r for r in self.releases if r['tag_name'] == tag and not r['draft']), None)
        if (method, path) == ('GET', base + '/releases'):
            return self.releases[(int(query['page']) - 1) * 100:int(query['page']) * 100]
        if (method, path) == ('POST', base + '/releases'):
            payload = json.loads(body)
            self.counter += 1
            created = dict(payload, id=self.counter, html_url='https://github.com/' + REPO + '/releases',
                           upload_url='https://uploads.github.com/repos/' + REPO + '/releases/'
                           + str(self.counter) + '/assets{?name,label}')
            self.releases.append(created)
            return created
        if path.startswith(base + '/releases/'):
            release_id = int(path.rsplit('/', 1)[1])
            found = next(r for r in self.releases if r['id'] == release_id)
            if method == 'DELETE':
                self.releases.remove(found)
                return b''
            if method == 'PATCH':
                assert found['tag_name'] in self.tags, 'published before the tag existed'
                found.update(json.loads(body))
                return found
        raise AssertionError('Unexpected GitHub request: ' + method + ' ' + host + path)


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.fake = FakeGitHub()
        self.github = github_release.GitHub('test-token', REPO, opener=self.fake)

    def source(self, build='33.1'):
        return github_release.source(self.github, '1.0', build, 'v1.0')

    def test_finds_the_commit_the_publish_attempt_built(self):
        self.assertEqual(self.source(), (BUILD_SHA, False))

    def test_finds_runs_beyond_the_first_page(self):
        self.fake.runs = [dict(self.fake.runs[0], id=2000 + n, run_number=200 + n) for n in range(150)] \
            + self.fake.runs
        self.assertEqual(self.source()[0], BUILD_SHA)

    def test_refuses_runs_that_did_not_upload_this_build(self):
        cases = {
            'missing run': lambda f: f.runs.__setitem__(slice(None), [r for r in f.runs if r['run_number'] != 33]),
            'failed upload': lambda f: f.jobs.__setitem__((933, 1), [{'name': 'publish', 'conclusion': 'failure'}]),
            'other branch': lambda f: f.runs[7].__setitem__('head_branch', 'feature'),
            'fork': lambda f: f.runs[7].__setitem__('head_repository', {'full_name': 'someone/compasslet'}),
            'other workflow': lambda f: f.runs[7].__setitem__('path', '.github/workflows/check.yml'),
            'other version': lambda f: f.files.__setitem__(BUILD_SHA, b'MARKETING_VERSION = 1.1;'),
        }
        for name, change in cases.items():
            with self.subTest(name):
                self.fake = FakeGitHub()
                self.github = github_release.GitHub('test-token', REPO, opener=self.fake)
                self.assertEqual(self.fake.runs[7]['run_number'], 33)
                change(self.fake)
                with self.assertRaises(metadata.MetadataError):
                    self.source()
        with self.assertRaises(metadata.MetadataError):
            self.source('33.2')

    def test_refuses_a_published_release_or_a_tag_elsewhere(self):
        self.fake.tags['v1.0'] = OTHER_SHA
        with self.assertRaises(metadata.MetadataError):
            self.source()
        self.fake.tags['v1.0'] = BUILD_SHA
        self.fake.releases.append({'id': 5, 'tag_name': 'v1.0', 'draft': False})
        with self.assertRaises(metadata.MetadataError):
            self.source()

    def test_a_tag_already_on_the_build_commit_resumes(self):
        self.fake.tags['v1.0'] = BUILD_SHA
        self.assertEqual(self.source(), (BUILD_SHA, True))
        self.fake.tags.clear()
        self.fake.annotated['v1.0'] = BUILD_SHA
        self.assertEqual(self.source(), (BUILD_SHA, True))


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.fake = FakeGitHub()
        self.github = github_release.GitHub('test-token', REPO, opener=self.fake)
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        for name in ('iphone-17-pro-max-light-compass.png', 'iphone-se-dark-settings.png'):
            (self.directory / name).write_bytes(name.encode())
        self.messages = []

    def publish(self, files=None):
        files = github_release.assets(self.directory) if files is None else files
        github_release.publish(self.github, '1.0', 'v1.0', BUILD_SHA, files, report=self.messages.append)

    def test_assets_go_on_a_draft_before_the_tag_and_publication(self):
        self.publish()
        release = self.fake.releases[0]
        self.assertFalse(release['draft'])
        self.assertEqual((release['tag_name'], release['target_commitish'], release['name']),
                         ('v1.0', BUILD_SHA, 'Compasslet 1.0'))
        self.assertEqual(self.fake.tags, {'v1.0': BUILD_SHA})
        self.assertEqual(sorted(n for n, _ in self.fake.assets[release['id']]),
                         ['iphone-17-pro-max-light-compass.png', 'iphone-se-dark-settings.png'])
        writes = [c for c in self.fake.calls if c[0] != 'GET']
        self.assertEqual([(m, h) for m, h, _ in writes],
                         [('POST', 'api.github.com'), ('POST', 'uploads.github.com'),
                          ('POST', 'uploads.github.com'), ('POST', 'api.github.com'),
                          ('PATCH', 'api.github.com')])
        self.assertTrue(writes[3][2].endswith('/git/refs'))

    def test_without_screenshots_the_release_has_no_assets(self):
        self.publish(files=[])
        self.assertEqual(self.fake.assets, {})
        self.assertFalse(self.fake.releases[0]['draft'])

    def test_a_stopped_run_is_finished_from_a_fresh_draft(self):
        self.fake.releases.append({'id': 77, 'tag_name': 'v1.0', 'draft': True,
                                   'name': 'Compasslet 1.0', 'target_commitish': BUILD_SHA})
        self.fake.releases.append({'id': 78, 'tag_name': 'v0.9', 'draft': True})
        self.fake.tags['v1.0'] = BUILD_SHA
        self.publish()
        self.assertEqual(sorted(r['id'] for r in self.fake.releases), [1, 78])
        self.assertNotIn(('POST', 'api.github.com', '/repos/' + REPO + '/git/refs'), self.fake.calls)
        self.assertFalse(next(r for r in self.fake.releases if r['id'] == 1)['draft'])

    def test_a_draft_someone_else_wrote_is_left_alone(self):
        for draft in ({'name': 'Compasslet 1.0', 'target_commitish': 'main'},
                      {'name': 'Big launch', 'target_commitish': BUILD_SHA}):
            with self.subTest(draft=draft):
                self.fake = FakeGitHub()
                self.github = github_release.GitHub('test-token', REPO, opener=self.fake)
                self.fake.releases.append(dict(draft, id=77, tag_name='v1.0', draft=True))
                with self.assertRaises(metadata.MetadataError):
                    self.publish()
                self.assertEqual([c for c in self.fake.calls if c[0] != 'GET'], [])

    def test_a_tag_made_elsewhere_during_the_run_stops_publication(self):
        upload = self.fake.route

        def route(method, host, path, query, body, request):
            if host == 'uploads.github.com':
                self.fake.tags['v1.0'] = OTHER_SHA
            return upload(method, host, path, query, body, request)

        self.fake.route = route
        with self.assertRaises(metadata.MetadataError):
            self.publish()
        self.assertTrue(self.fake.releases[0]['draft'])
        self.assertEqual(self.fake.tags, {'v1.0': OTHER_SHA})

    def test_a_published_release_is_never_replaced(self):
        self.fake.tags['v1.0'] = BUILD_SHA
        self.fake.releases.append({'id': 5, 'tag_name': 'v1.0', 'draft': False})
        with self.assertRaises(metadata.MetadataError):
            self.publish()
        self.assertEqual([c for c in self.fake.calls if c[0] != 'GET'], [])

    def test_an_empty_screenshot_folder_is_refused(self):
        with tempfile.TemporaryDirectory() as empty, self.assertRaises(metadata.MetadataError):
            github_release.assets(empty)
        self.assertEqual(github_release.assets(''), [])


class ClientTests(unittest.TestCase):
    def test_the_token_only_goes_to_this_repository_on_github(self):
        fake = FakeGitHub()
        github = github_release.GitHub('test-token', REPO, opener=fake)
        for url in ('https://example.com/repos/' + REPO + '/releases',
                    'https://api.github.com/repos/someone/else/releases',
                    'http://uploads.github.com/repos/' + REPO + '/releases/1/assets'):
            with self.subTest(url=url), self.assertRaises(metadata.MetadataError):
                github.request('GET', url)
        self.assertEqual(fake.calls, [])

    def test_commands_refuse_runs_that_are_not_manual_runs_from_main(self):
        for event, ref in (('push', 'refs/heads/main'), ('workflow_dispatch', 'refs/heads/feature')):
            with self.subTest(event=event, ref=ref), \
                    patch.dict('os.environ', {'GITHUB_ACTIONS': 'true', 'GITHUB_EVENT_NAME': event,
                                              'GITHUB_REF': ref, 'GITHUB_REPOSITORY': REPO,
                                              'GH_TOKEN': 'test-token', 'RELEASE_VERSION': '1.0',
                                              'RELEASE_TAG': 'v1.0', 'RELEASE_SHA': BUILD_SHA,
                                              'RELEASE_ASSETS': ''}), \
                    patch.object(github_release, 'publish') as publish, \
                    contextlib.redirect_stderr(io.StringIO()) as stderr:
                self.assertEqual(github_release.main(['publish']), 1)
                publish.assert_not_called()
                self.assertIn('Run manually from main.', stderr.getvalue())

    def test_the_tag_must_name_the_version(self):
        with patch.dict('os.environ', {'RELEASE_VERSION': '1.0', 'RELEASE_TAG': 'v1.1'}), \
                self.assertRaises(metadata.MetadataError):
            github_release.release_inputs()


if __name__ == '__main__':
    unittest.main()
