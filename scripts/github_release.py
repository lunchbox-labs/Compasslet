"""GitHub side of the Release workflow, using only the workflow's own token.

source   Find the Publish run that uploaded the approved build, the commit it built, and check
         that the version's tag is free (or already on that commit) and not yet released.
publish  Create a draft GitHub Release with the screenshots attached, tag the commit, then
         publish the release. Published releases are immutable, so every asset goes on first.
"""
import json
import os
from pathlib import Path
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

import app_store
from metadata_sync import MetadataError, require, run_safely

API = 'https://api.github.com'
PUBLISH_WORKFLOW = '.github/workflows/publish.yml'
PROJECT = 'Compass.xcodeproj/project.pbxproj'
COMMIT = re.compile(r'[0-9a-f]{40}')
TAG = re.compile(r'v[0-9]+(?:\.[0-9]+){0,2}')
REPOSITORY = re.compile(r'[A-Za-z0-9-]+/[A-Za-z0-9._-]+')
RUN_PAGES = 10


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise MetadataError('Unexpected GitHub API redirect; the token was not forwarded.')


class GitHub:
    def __init__(self, token, repository, opener=None):
        require(bool(token), 'Missing GitHub token.')
        require(REPOSITORY.fullmatch(repository or ''), 'Missing or invalid repository name.')
        self.token, self.repository = token, repository
        self.opener = opener or build_opener(NoRedirects())

    def request(self, method, path, params=None, payload=None, data=None, content_type=None,
                accept='application/vnd.github+json', missing_ok=False):
        url = path if path.startswith('https://') else API + '/repos/' + self.repository + path
        parsed = urlsplit(url)
        require(parsed.scheme == 'https' and parsed.netloc in ('api.github.com', 'uploads.github.com')
                and parsed.path.startswith('/repos/' + self.repository + '/'),
                'Unexpected GitHub API URL; the token was not forwarded.')
        if params:
            url += ('&' if parsed.query else '?') + urlencode(params)
        if payload is not None:
            data, content_type = json.dumps(payload).encode(), 'application/json'
        headers = {'Authorization': 'Bearer ' + self.token, 'Accept': accept,
                   'X-GitHub-Api-Version': '2022-11-28'}
        if content_type:
            headers['Content-Type'] = content_type
        try:
            with self.opener.open(Request(url, method=method, headers=headers, data=data),
                                  timeout=60) as response:
                body = response.read(5_000_001)
        except HTTPError as error:
            if missing_ok and error.code == 404:
                return None
            raise MetadataError('GitHub API HTTP ' + str(error.code) + ' for ' + method + ' '
                                + parsed.path.split('/', 4)[-1].split('/')[0] + '.') from None
        except (URLError, TimeoutError, OSError) as error:
            if isinstance(error, MetadataError):
                raise
            raise MetadataError('GitHub API request failed.') from None
        require(len(body) <= 5_000_000, 'GitHub API response exceeded the size limit.')
        if accept == 'application/vnd.github.raw':
            return body
        try:
            return json.loads(body) if body else {}
        except ValueError:
            raise MetadataError('Invalid GitHub API response.') from None


def publish_run(github, build_number):
    """The manual main Publish run whose attempt uploaded this build."""
    run_number, attempt = (int(part) for part in build_number.split('.'))
    for page in range(1, RUN_PAGES + 1):
        runs = github.request('GET', '/actions/workflows/publish.yml/runs', params={
            'event': 'workflow_dispatch', 'branch': 'main', 'per_page': 100, 'page': page})
        batch = runs.get('workflow_runs')
        require(isinstance(batch, list), 'Invalid Publish run listing.')
        matches = [r for r in batch if r.get('run_number') == run_number]
        if matches:
            break
        if len(batch) < 100:
            raise MetadataError('No Publish run ' + str(run_number) + ' made build ' + build_number + '.')
    else:
        raise MetadataError('No Publish run ' + str(run_number) + ' in the recent runs.')
    require(len(matches) == 1, 'Ambiguous Publish run for build ' + build_number + '.')
    run = matches[0]
    require(run.get('event') == 'workflow_dispatch' and run.get('head_branch') == 'main'
            and run.get('path') == PUBLISH_WORKFLOW
            and (run.get('head_repository') or {}).get('full_name') == github.repository
            and isinstance(run.get('run_attempt'), int) and run['run_attempt'] >= attempt
            and COMMIT.fullmatch(run.get('head_sha') or ''),
            'Publish run ' + str(run_number) + ' is not a manual run from main.')
    jobs = github.request('GET', '/actions/runs/' + str(int(run['id'])) + '/attempts/'
                          + str(attempt) + '/jobs', params={'per_page': 100}).get('jobs')
    require(isinstance(jobs, list) and any(j.get('name') == 'publish' and j.get('conclusion') == 'success'
                                           for j in jobs),
            'Attempt ' + str(attempt) + ' of Publish run ' + str(run_number) + ' did not upload a build.')
    return run['head_sha']


def tagged_commit(github, tag):
    ref = github.request('GET', '/git/ref/tags/' + quote(tag), missing_ok=True)
    if ref is None:
        return None
    target = ref.get('object') or {}
    if target.get('type') == 'tag':
        target = github.request('GET', '/git/tags/' + quote(target.get('sha', ''))).get('object') or {}
    require(target.get('type') == 'commit' and COMMIT.fullmatch(target.get('sha') or ''),
            'Tag ' + tag + ' does not point at a commit.')
    return target['sha']


def check_unreleased(github, tag, commit):
    """Refuse a published release or a tag elsewhere; a tag on this commit resumes a stopped run."""
    published = github.request('GET', '/releases/tags/' + quote(tag), missing_ok=True)
    require(published is None or published.get('draft') is True,
            'GitHub Release ' + tag + ' is already published.')
    existing = tagged_commit(github, tag)
    require(existing in (None, commit), 'Tag ' + tag + ' already points at another commit.')
    return existing is not None


def source(github, version, build_number, tag):
    commit = publish_run(github, build_number)
    project = github.request('GET', '/contents/' + PROJECT, params={'ref': commit},
                             accept='application/vnd.github.raw')
    try:
        text = project.decode('utf-8')
    except UnicodeError:
        raise MetadataError('Cannot read the project at the build commit.') from None
    require(app_store.project_version(text) == version,
            'The build commit is not version ' + version + '.')
    resuming = check_unreleased(github, tag, commit)
    return commit, resuming


def assets(directory):
    if not directory:
        return []
    files = sorted(Path(directory).glob('*.png'))
    require(files, 'No screenshots to attach.')
    return files


def publish(github, version, tag, commit, files, report=print):
    check_unreleased(github, tag, commit)
    # A draft from an earlier run that stopped partway is this workflow's own; start it afresh.
    for page in range(1, RUN_PAGES + 1):
        releases = github.request('GET', '/releases', params={'per_page': 100, 'page': page})
        require(isinstance(releases, list), 'Invalid release listing.')
        for leftover in releases:
            if leftover.get('draft') is True and leftover.get('tag_name') == tag:
                github.request('DELETE', '/releases/' + str(int(leftover['id'])))
                report('Removed an unpublished draft of ' + tag + ' from an earlier run.')
        if len(releases) < 100:
            break
    draft = github.request('POST', '/releases', payload={
        'tag_name': tag, 'target_commitish': commit, 'name': 'Compasslet ' + version,
        'draft': True, 'generate_release_notes': True})
    release_id = int(draft['id'])
    upload = urlsplit((draft.get('upload_url') or '').split('{', 1)[0])
    require(upload.scheme == 'https' and upload.netloc == 'uploads.github.com',
            'Unexpected release upload address.')
    for path in files:
        github.request('POST', upload.geturl(), params={'name': path.name},
                       data=path.read_bytes(), content_type='image/png')
    report('Attached ' + str(len(files)) + ' screenshots to the draft.')
    if tagged_commit(github, tag) is None:
        github.request('POST', '/git/refs', payload={'ref': 'refs/tags/' + tag, 'sha': commit})
        report('Tagged ' + commit + ' as ' + tag + '.')
    published = github.request('PATCH', '/releases/' + str(release_id), payload={'draft': False})
    require(published.get('draft') is False and published.get('tag_name') == tag,
            'GitHub did not publish release ' + tag + '.')
    report('Published GitHub Release ' + tag + ': ' + str(published.get('html_url')))


def client():
    app_store.manual_run_from_main()
    return GitHub(os.environ.pop('GH_TOKEN', ''), os.environ.get('GITHUB_REPOSITORY', ''))


def release_inputs():
    version = os.environ.get('RELEASE_VERSION', '')
    tag = os.environ.get('RELEASE_TAG', '')
    require(app_store.VERSION.fullmatch(version) and tag == 'v' + version and TAG.fullmatch(tag),
            'Missing or invalid release version and tag.')
    return version, tag


def command_source():
    version, tag = release_inputs()
    build = os.environ.get('RELEASE_BUILD_NUMBER', '')
    require(app_store.BUILD_NUMBER.fullmatch(build), 'Missing or invalid approved build.')
    commit, resuming = source(client(), version, build, tag)
    print('Build ' + build + ' came from ' + commit + '.'
          + (' Tag ' + tag + ' is already there, so this run finishes its release.' if resuming else ''))
    app_store.write_outputs(sha=commit)


def command_publish():
    version, tag = release_inputs()
    commit = os.environ.get('RELEASE_SHA', '')
    require(COMMIT.fullmatch(commit), 'Missing or invalid release commit.')
    publish(client(), version, tag, commit, assets(os.environ.get('RELEASE_ASSETS', '')))


COMMANDS = {'source': command_source, 'publish': command_publish}


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1 or argv[0] not in COMMANDS:
        print('Usage: python3 scripts/github_release.py ' + '|'.join(COMMANDS), file=sys.stderr)
        return 2
    return run_safely(COMMANDS[argv[0]], 'GitHub release ' + argv[0] + ' failed')


if __name__ == '__main__':
    sys.exit(main())
