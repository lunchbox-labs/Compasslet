"""App Review and App Store release steps for one exact uploaded build.

review    After Publish uploads a build: sync the App Review notes, replace the listing screenshots
          and submit the version for App Review with a manual release.
approved  At the start of Release: find the project version's approved build.
release   Release that approved version on the App Store.

Every write is limited to the editable or approved version matching the build. Versions,
locales and App Review contact details are never created here; they stay in App Store Connect.
"""
import hashlib
import os
from pathlib import Path
import re
import struct
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request
import zlib

import metadata_sync as metadata
from metadata_sync import MetadataError, editable, exact_one, identifier, is_version, require

ROOT = Path(__file__).resolve().parents[1]
APP_STORE = ROOT / 'app-store'
REVIEW_NOTES = 'review-notes.txt'
REVIEW_NOTES_LIMIT = 4000
# Apple's API names the 6.3-inch iPhone slot (iPhone 17's 1206 x 2622) APP_IPHONE_61.
LISTING_DISPLAY_TYPE = 'APP_IPHONE_61'
LISTING_SIZE = (1206, 2622)
# The Screenshots workflow's listing set, in the order the listing shows them.
LISTING_FILES = ('iphone-17-light-compass.png', 'iphone-17-dark-compass.png')
VERSION = re.compile(r'[0-9]+(?:\.[0-9]+){0,2}')
BUILD_NUMBER = re.compile(r'[1-9][0-9]{0,3}\.[1-9][0-9]?')
# Apple has approved the version and is holding it for a manual release.
AWAITING_RELEASE = 'PENDING_DEVELOPER_RELEASE'
RELEASED = {'PROCESSING_FOR_DISTRIBUTION', 'READY_FOR_DISTRIBUTION'}
# In a submission that hasn't been sent to Apple yet; nothing on the version can be edited.
IN_DRAFT = 'READY_FOR_REVIEW'
SUBMITTED = {'WAITING_FOR_EXPORT_COMPLIANCE', 'WAITING_FOR_REVIEW', 'IN_REVIEW', 'ACCEPTED',
             'PENDING_DEVELOPER_RELEASE', 'PENDING_APPLE_RELEASE', 'PROCESSING_FOR_DISTRIBUTION',
             'READY_FOR_DISTRIBUTION'}
SCREENSHOT_SET_LIMIT = 10
# Contact details stay in App Store Connect; these catch an email address or a phone number.
CONTACT_DETAILS = re.compile(r'[^\s@]+@[^\s@]+\.[A-Za-z]{2,}'
                             r'|(?<![\d.-])\+?\(?\d{2,4}\)?[\s-]\d{3}[\s-]\d{4}(?!\d|\.\d)')
OPEN_SUBMISSIONS = 'READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW,UNRESOLVED_ISSUES,CANCELING'
PNG_SIGNATURE = b'\x89PNG\r\n\x1a\n'
COLOUR_CHUNKS = {b'sRGB', b'iCCP', b'gAMA', b'cHRM', b'pHYs'}


def project_version(text):
    versions = set(re.findall(r'\bMARKETING_VERSION = ([^;\n]+);', text))
    require(len(versions) == 1, 'The project must set one MARKETING_VERSION for every target.')
    version = versions.pop().strip().strip('"')
    require(VERSION.fullmatch(version), 'The project MARKETING_VERSION is invalid.')
    return version


def read_review_notes(root=APP_STORE):
    """A missing file leaves the notes in App Store Connect as they are."""
    path = Path(root) / REVIEW_NOTES
    if not path.exists():
        return None
    try:
        value = path.read_text(encoding='utf-8').strip()
    except (OSError, UnicodeError):
        raise MetadataError('Cannot read the App Review notes.') from None
    require(value and len(value) <= REVIEW_NOTES_LIMIT and '\x00' not in value,
            'Empty, invalid or overlong App Review notes: ' + REVIEW_NOTES)
    require(not CONTACT_DETAILS.search(value),
            'The App Review notes look like they hold contact details; keep those in App Store Connect.')
    return value


def png_chunks(data):
    require(data.startswith(PNG_SIGNATURE), 'A listing screenshot is not a PNG image.')
    offset = len(PNG_SIGNATURE)
    while offset < len(data):
        require(offset + 12 <= len(data), 'A listing screenshot is a truncated PNG image.')
        length, kind = struct.unpack('>I4s', data[offset:offset + 8])
        body = data[offset + 8:offset + 8 + length]
        require(len(body) == length and offset + 12 + length <= len(data),
                'A listing screenshot is a truncated PNG image.')
        yield kind, body
        offset += 12 + length
        if kind == b'IEND':
            return
    raise MetadataError('A listing screenshot is a truncated PNG image.')


def png_chunk(kind, body):
    return (struct.pack('>I', len(body)) + kind + body
            + struct.pack('>I', zlib.crc32(kind + body) & 0xffffffff))


def unfilter(raw, width, height, pixel_bytes):
    stride = width * pixel_bytes
    require(len(raw) == height * (stride + 1), 'A listing screenshot has corrupt image data.')
    rows, previous = [], bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        kind, row = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        if kind == 1:
            for i in range(pixel_bytes, stride):
                row[i] = (row[i] + row[i - pixel_bytes]) & 0xff
        elif kind == 2:
            row = bytearray((a + b) & 0xff for a, b in zip(row, previous))
        elif kind == 3:
            for i in range(stride):
                left = row[i - pixel_bytes] if i >= pixel_bytes else 0
                row[i] = (row[i] + ((left + previous[i]) >> 1)) & 0xff
        elif kind == 4:
            for i in range(stride):
                left = row[i - pixel_bytes] if i >= pixel_bytes else 0
                above = previous[i]
                corner = previous[i - pixel_bytes] if i >= pixel_bytes else 0
                estimate = left + above - corner
                distances = abs(estimate - left), abs(estimate - above), abs(estimate - corner)
                if distances[0] <= distances[1] and distances[0] <= distances[2]:
                    predictor = left
                elif distances[1] <= distances[2]:
                    predictor = above
                else:
                    predictor = corner
                row[i] = (row[i] + predictor) & 0xff
        else:
            require(kind == 0, 'A listing screenshot has corrupt image data.')
        rows.append(bytes(row))
        previous = row
    return rows


def listing_png(data):
    """Apple wants flattened RGB screenshots; simulator captures are opaque RGBA."""
    chunks = list(png_chunks(data))
    require(chunks and chunks[0][0] == b'IHDR' and len(chunks[0][1]) == 13,
            'A listing screenshot has no valid PNG header.')
    width, height, depth, color, compression, filtering, interlace = struct.unpack(
        '>IIBBBBB', chunks[0][1])
    require((width, height) == LISTING_SIZE,
            'A listing screenshot is not ' + 'x'.join(map(str, LISTING_SIZE)) + ' pixels.')
    require(depth == 8 and color in (2, 6) and compression == 0 and filtering == 0
            and interlace == 0, 'A listing screenshot must be a non-interlaced 8-bit RGB PNG.')
    if color == 2:
        return data
    try:
        raw = zlib.decompress(b''.join(body for kind, body in chunks if kind == b'IDAT'))
    except zlib.error:
        raise MetadataError('A listing screenshot has corrupt image data.') from None
    flattened = bytearray()
    for row in unfilter(raw, width, height, 4):
        require(row[3::4] == b'\xff' * width, 'A listing screenshot has transparent pixels.')
        flattened.append(0)
        flattened += bytes(value for index, value in enumerate(row) if index % 4 != 3)
    header = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
    # Keep only how the colours are meant. Any other metadata, such as a content credential
    # signed over the original pixels, would no longer describe this image.
    kept = [png_chunk(kind, body) for kind, body in chunks[1:] if kind in COLOUR_CHUNKS]
    return (PNG_SIGNATURE + png_chunk(b'IHDR', header) + b''.join(kept)
            + png_chunk(b'IDAT', zlib.compress(bytes(flattened), 9)) + png_chunk(b'IEND', b''))


def read_listing(directory):
    shots = []
    for name in LISTING_FILES:
        path = Path(directory) / name
        require(path.is_file(), 'Missing listing screenshot: ' + name)
        payload = listing_png(path.read_bytes())
        shots.append((name, payload, hashlib.md5(payload).hexdigest()))
    return shots


def find_app(client, bundle_id=metadata.BUNDLE_ID):
    apps, _ = client.collection('/v1/apps', {'filter[bundleId]': bundle_id, 'limit': 200})
    app = exact_one(apps, lambda r: r.get('type') == 'apps'
                    and r.get('attributes', {}).get('bundleId') == bundle_id, 'app bundle ID')
    return identifier(app['id'])


def find_version(client, app_id, marketing_version):
    versions, included = client.collection('/v1/apps/' + app_id + '/appStoreVersions', {
        'filter[platform]': 'IOS', 'filter[versionString]': marketing_version,
        'include': 'build', 'limit': 200})
    version = exact_one(versions, lambda r: is_version(r, marketing_version),
                        'iOS marketing version', optional=True)
    if not version:
        return None, None
    build = (version.get('relationships', {}).get('build', {}).get('data') or {}).get('id')
    numbers = {r['id']: r.get('attributes', {}).get('version') for r in included
               if r.get('type') == 'builds' and isinstance(r.get('id'), str)}
    return version, ((identifier(build), numbers.get(build)) if build else None)


def current_version(client, version_id, marketing_version):
    current = client.request('GET', '/v1/appStoreVersions/' + version_id).get('data', {})
    require(is_version(current, marketing_version), 'The App Store version no longer matches.')
    return current


def state(record):
    return record.get('attributes', {}).get('appVersionState')


def resource(kind, identity):
    return {'data': {'type': kind, 'id': identity}}


def send_parts(opener, operations, payload):
    """Send a reserved asset's parts to Apple's upload hosts, never with the API token."""
    require(isinstance(operations, list) and operations, 'Apple returned no upload operations.')
    covered = 0
    for operation in sorted(operations, key=lambda o: o.get('offset', -1)):
        url, method = operation.get('url'), operation.get('method')
        offset, length = operation.get('offset'), operation.get('length')
        parsed = urlsplit(url if isinstance(url, str) else '')
        require(parsed.scheme == 'https' and (parsed.hostname or '').endswith('.apple.com')
                and not parsed.username and not parsed.password and method in ('PUT', 'POST')
                and offset == covered and isinstance(length, int) and length > 0,
                'Unexpected screenshot upload operation; nothing was sent.')
        headers = {h['name']: h['value'] for h in operation.get('requestHeaders') or []
                   if isinstance(h, dict) and isinstance(h.get('name'), str)
                   and isinstance(h.get('value'), str) and h['name'].lower() != 'authorization'}
        request = Request(url, method=method, headers=headers,
                          data=payload[offset:offset + length])
        try:
            with opener.open(request, timeout=60) as response:
                response.read(1)
        except HTTPError as error:
            raise MetadataError('Screenshot upload HTTP ' + str(error.code) + '.') from None
        except (URLError, TimeoutError, OSError) as error:
            if isinstance(error, MetadataError):
                raise
            raise MetadataError('Screenshot upload failed.') from None
        covered += length
    require(covered == len(payload), 'Apple asked for only part of a screenshot; nothing committed.')


def sync_screenshots(client, localization_id, locale, shots, report, ready, attempts=40,
                     sleep=time.sleep):
    sets, _ = client.collection('/v1/appStoreVersionLocalizations/' + localization_id
                                + '/appScreenshotSets', {'limit': 200})
    screenshot_set = exact_one(sets, lambda r: r.get('type') == 'appScreenshotSets'
                               and r.get('attributes', {}).get('screenshotDisplayType')
                               == LISTING_DISPLAY_TYPE, 'listing screenshot set', optional=True)
    existing = []
    if screenshot_set:
        set_id = identifier(screenshot_set['id'])
        existing, _ = client.collection('/v1/appScreenshotSets/' + set_id + '/appScreenshots',
                                        {'limit': 200})
        current = [(r.get('attributes', {}).get('fileName'),
                    r.get('attributes', {}).get('sourceFileChecksum'),
                    (r.get('attributes', {}).get('assetDeliveryState') or {}).get('state'))
                   for r in existing]
        if current == [(name, checksum, 'COMPLETE') for name, _, checksum in shots]:
            report('UNCHANGED listing screenshots ' + locale)
            return
    if not ready():
        report('SKIP listing screenshots ' + locale + ': the version is no longer editable.')
        return
    if not screenshot_set:
        created = client.request('POST', '/v1/appScreenshotSets', payload={'data': {
            'type': 'appScreenshotSets',
            'attributes': {'screenshotDisplayType': LISTING_DISPLAY_TYPE},
            'relationships': {'appStoreVersionLocalization': resource(
                'appStoreVersionLocalizations', localization_id)}}})
        set_id = identifier(created.get('data', {}).get('id'))
    # Replace the whole set so it holds exactly the supplied images; other sizes are untouched.
    # The old images go once the new ones are in, unless the set has no room for both.
    def remove_existing():
        for record in existing:
            client.request('DELETE', '/v1/appScreenshots/' + identifier(record.get('id')))

    if len(existing) + len(shots) > SCREENSHOT_SET_LIMIT:
        remove_existing()
        existing = []
    uploaded = []
    for name, payload, checksum in shots:
        reserved = client.request('POST', '/v1/appScreenshots', payload={'data': {
            'type': 'appScreenshots', 'attributes': {'fileName': name, 'fileSize': len(payload)},
            'relationships': {'appScreenshotSet': resource('appScreenshotSets', set_id)}}})
        data = reserved.get('data', {})
        screenshot_id = identifier(data.get('id'))
        send_parts(client.opener, data.get('attributes', {}).get('uploadOperations'), payload)
        client.request('PATCH', '/v1/appScreenshots/' + screenshot_id, payload={'data': {
            'type': 'appScreenshots', 'id': screenshot_id,
            'attributes': {'uploaded': True, 'sourceFileChecksum': checksum}}})
        uploaded.append(screenshot_id)
    for screenshot_id in uploaded:
        for attempt in range(attempts):
            delivery = (client.request('GET', '/v1/appScreenshots/' + screenshot_id)
                        .get('data', {}).get('attributes', {}).get('assetDeliveryState') or {})
            if delivery.get('state') == 'COMPLETE':
                break
            require(delivery.get('state') != 'FAILED', 'Apple could not process a listing screenshot.')
            if attempt + 1 < attempts:
                sleep(15)
        else:
            raise MetadataError('Apple is still processing a listing screenshot; check App Store Connect.')
    remove_existing()
    client.request('PATCH', '/v1/appScreenshotSets/' + set_id + '/relationships/appScreenshots',
                   payload={'data': [{'type': 'appScreenshots', 'id': i} for i in uploaded]})
    report('UPDATED listing screenshots ' + locale + ': ' + ', '.join(n for n, _, _ in shots))


def sync_review_notes(client, version_id, notes, report):
    detail = client.request('GET', '/v1/appStoreVersions/' + version_id
                            + '/appStoreReviewDetail').get('data')
    require(isinstance(detail, dict) and detail.get('type') == 'appStoreReviewDetails',
            'The version has no App Review details; add the contact details in App Store Connect.')
    if detail.get('attributes', {}).get('notes') == notes:
        report('UNCHANGED App Review notes')
        return
    detail_id = identifier(detail.get('id'))
    client.request('PATCH', '/v1/appStoreReviewDetails/' + detail_id, payload={'data': {
        'type': 'appStoreReviewDetails', 'id': detail_id, 'attributes': {'notes': notes}}})
    report('UPDATED App Review notes')


def open_submission(client, app_id, version_id):
    submissions, _ = client.collection('/v1/reviewSubmissions', {
        'filter[app]': app_id, 'filter[platform]': 'IOS', 'filter[state]': OPEN_SUBMISSIONS,
        'limit': 200})
    # A draft, or a submission Apple sent back with issues, is resubmitted once it holds only
    # this version; anything already with Apple is left alone.
    drafts = []
    for submission in submissions:
        submission_state = submission.get('attributes', {}).get('state')
        require(submission_state in ('READY_FOR_REVIEW', 'UNRESOLVED_ISSUES'),
                'Another iOS submission is ' + str(submission_state)
                + ' in App Store Connect; resolve it there first.')
        drafts.append(submission)
    require(len(drafts) <= 1, 'More than one open iOS submission; resolve it in App Store Connect.')
    if not drafts:
        return None, False
    submission_id = identifier(drafts[0]['id'])
    items, _ = client.collection('/v1/reviewSubmissions/' + submission_id + '/items',
                                 {'include': 'appStoreVersion', 'limit': 200})
    versions = [(i.get('relationships', {}).get('appStoreVersion', {}).get('data') or {}).get('id')
                for i in items]
    require(all(v == version_id for v in versions),
            'The open iOS submission holds other items; resolve it in App Store Connect.')
    return submission_id, bool(versions)


def submit(client, app_id, version, build_id, report):
    version_id = identifier(version['id'])
    linked = client.request('GET', '/v1/appStoreVersions/' + version_id
                            + '/relationships/build').get('data') or {}
    if linked.get('id') != build_id:
        client.request('PATCH', '/v1/appStoreVersions/' + version_id + '/relationships/build',
                       payload=resource('builds', build_id))
        report('UPDATED App Store version build')
    if version.get('attributes', {}).get('releaseType') != 'MANUAL':
        client.request('PATCH', '/v1/appStoreVersions/' + version_id, payload={'data': {
            'type': 'appStoreVersions', 'id': version_id, 'attributes': {'releaseType': 'MANUAL'}}})
        report('UPDATED App Store version release: manual')
    submission_id, has_item = open_submission(client, app_id, version_id)
    if not submission_id:
        created = client.request('POST', '/v1/reviewSubmissions', payload={'data': {
            'type': 'reviewSubmissions', 'attributes': {'platform': 'IOS'},
            'relationships': {'app': resource('apps', app_id)}}})
        submission_id = identifier(created.get('data', {}).get('id'))
    if not has_item:
        client.request('POST', '/v1/reviewSubmissionItems', payload={'data': {
            'type': 'reviewSubmissionItems', 'relationships': {
                'reviewSubmission': resource('reviewSubmissions', submission_id),
                'appStoreVersion': resource('appStoreVersions', version_id)}}})
    send_for_review(client, submission_id, version['attributes']['versionString'], report)


def send_for_review(client, submission_id, marketing_version, report):
    client.request('PATCH', '/v1/reviewSubmissions/' + submission_id, payload={'data': {
        'type': 'reviewSubmissions', 'id': submission_id, 'attributes': {'submitted': True}}})
    report('SUBMITTED version ' + marketing_version
           + ' for App Review; release it with the Release workflow once Apple approves it.')


def resume_draft(client, app_id, version, linked, build_number, report):
    """A version already in an unsent submission, as after a run that stopped partway."""
    marketing_version = version['attributes']['versionString']
    require(linked and linked[1] == build_number, 'Version ' + marketing_version
            + ' is in a draft submission with another build; remove it from the submission in '
            'App Store Connect, then run again.')
    # Sending it with an automatic release would let Apple release it before Release runs.
    require(version['attributes'].get('releaseType') == 'MANUAL', 'Version ' + marketing_version
            + ' is in a draft submission without a manual release; set it to release manually '
            'in App Store Connect, then run again.')
    submission_id, has_item = open_submission(client, app_id, identifier(version['id']))
    require(submission_id and has_item, 'Version ' + marketing_version
            + ' is waiting in a submission this run cannot find; check App Store Connect.')
    report('SKIP App Review notes and listing screenshots: version ' + marketing_version
           + ' is already in a draft submission, so they can no longer change.')
    send_for_review(client, submission_id, marketing_version, report)


def review(client, marketing_version, build_number, notes, shots, wants_submit, locales,
           report=print, attempts=40, sleep=time.sleep):
    """Notes, then screenshots, then submission, each only while the version stays editable."""
    app_id = find_app(client)
    version, linked = find_version(client, app_id, marketing_version)
    if version and wants_submit and state(version) == IN_DRAFT:
        resume_draft(client, app_id, version, linked, build_number, report)
        return
    if version and not editable(version):
        if wants_submit and state(version) in SUBMITTED and linked and linked[1] == build_number:
            report('ALREADY SUBMITTED version ' + marketing_version + ' with build ' + build_number + '.')
            return
        require(not wants_submit, 'App Store version ' + marketing_version + ' is '
                + str(state(version)) + ', not editable; nothing was submitted.')
        version = None
    if not version:
        require(not wants_submit, 'No editable iOS App Store version ' + marketing_version
                + '; create it in App Store Connect.')
        report('SKIP App Review notes and listing screenshots: version ' + marketing_version
               + ' is absent or not editable.')
        return
    version_id = identifier(version['id'])

    def ready():
        return editable(current_version(client, version_id, marketing_version))

    if notes is None:
        report('SKIP App Review notes: no ' + REVIEW_NOTES + ' supplied.')
    elif ready():
        sync_review_notes(client, version_id, notes, report)
    if shots:
        rows, _ = client.collection('/v1/appStoreVersions/' + version_id
                                    + '/appStoreVersionLocalizations', {'limit': 200})
        for locale in locales:
            localization = exact_one(rows, lambda r: r.get('type') == 'appStoreVersionLocalizations'
                                     and r.get('attributes', {}).get('locale') == locale,
                                     'App Store version locale', optional=True)
            if not localization:
                report('SKIP listing screenshots ' + locale + ': locale is absent; create it in App Store Connect.')
                continue
            sync_screenshots(client, identifier(localization['id']), locale, shots, report, ready,
                             sleep=sleep)
    if wants_submit:
        build_id = metadata.processed_build(client, app_id, marketing_version, build_number,
                                            attempts, sleep)
        current = current_version(client, version_id, marketing_version)
        require(editable(current), 'The App Store version stopped being editable; nothing was submitted.')
        submit(client, app_id, current, build_id, report)


def approved(client, marketing_version, releasing):
    """The version's build number: approved and held for release, or already live when not releasing."""
    app_id = find_app(client)
    version, linked = find_version(client, app_id, marketing_version)
    require(version, 'No iOS App Store version ' + marketing_version + '.')
    if releasing:
        require(state(version) == AWAITING_RELEASE, 'Version ' + marketing_version + ' is '
                + str(state(version)) + ', not approved and waiting for release.')
    else:
        # Tagging a version that isn't live yet would block its App Store release later.
        require(state(version) in RELEASED, 'Version ' + marketing_version + ' is '
                + str(state(version)) + ', not on the App Store; turn app-store-release on.')
    require(linked and isinstance(linked[1], str) and BUILD_NUMBER.fullmatch(linked[1]),
            'The approved version has no build from the Publish workflow.')
    return linked[1]


def release(client, marketing_version, build_number, report=print):
    app_id = find_app(client)
    version, linked = find_version(client, app_id, marketing_version)
    require(version and linked and linked[1] == build_number,
            'Version ' + marketing_version + ' no longer has build ' + build_number + '.')
    if state(version) in RELEASED:
        report('ALREADY RELEASED version ' + marketing_version + ' on the App Store.')
        return
    require(state(version) == AWAITING_RELEASE, 'Version ' + marketing_version + ' is '
            + str(state(version)) + ', not approved and waiting for release.')
    client.request('POST', '/v1/appStoreVersionReleaseRequests', payload={'data': {
        'type': 'appStoreVersionReleaseRequests', 'relationships': {
            'appStoreVersion': resource('appStoreVersions', identifier(version['id']))}}})
    report('RELEASED version ' + marketing_version + ' on the App Store.')


def manual_run_from_main():
    environment = os.environ
    require(environment.get('GITHUB_ACTIONS') == 'true', 'Run in GitHub Actions.')
    require(environment.get('GITHUB_EVENT_NAME') == 'workflow_dispatch'
            and environment.get('GITHUB_REF') == 'refs/heads/main', 'Run manually from main.')


def write_outputs(**values):
    with Path(os.environ['GITHUB_OUTPUT']).open('a', encoding='utf-8') as output:
        for name, value in values.items():
            output.write(name + '=' + value + '\n')


def locale_directories(root=APP_STORE):
    return sorted(d.name for d in Path(root).iterdir() if d.is_dir())


def command_review():
    version, build = metadata.workflow_identity()
    wants_submit = os.environ.get('SUBMIT') == 'true'
    notes = read_review_notes()
    directory = os.environ.get('LISTING_SCREENSHOTS', '')
    require(bool(directory) == wants_submit,
            'Listing screenshots are supplied exactly when the version is submitted.')
    shots = read_listing(directory) if directory else []
    with metadata.api_client() as client:
        review(client, version, build, notes, shots, wants_submit, locale_directories())


def command_approved():
    manual_run_from_main()
    releasing = os.environ.get('RELEASE_APP_STORE')
    require(releasing in ('true', 'false'), 'Missing app-store-release choice.')
    version = project_version((ROOT / 'Compass.xcodeproj/project.pbxproj').read_text('utf-8'))
    with metadata.api_client() as client:
        build = approved(client, version, releasing == 'true')
    print('Version ' + version + ' is approved with build ' + build + '.')
    write_outputs(version=version, build_number=build, tag='v' + version)


def command_release():
    manual_run_from_main()
    version = os.environ.get('RELEASE_VERSION', '')
    build = os.environ.get('RELEASE_BUILD_NUMBER', '')
    require(VERSION.fullmatch(version) and BUILD_NUMBER.fullmatch(build),
            'Missing or invalid approved version and build.')
    with metadata.api_client() as client:
        release(client, version, build)


COMMANDS = {'review': command_review, 'approved': command_approved, 'release': command_release}


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1 or argv[0] not in COMMANDS:
        print('Usage: python3 scripts/app_store.py ' + '|'.join(COMMANDS), file=sys.stderr)
        return 2
    return metadata.run_safely(COMMANDS[argv[0]], 'App Store ' + argv[0] + ' failed')


if __name__ == '__main__':
    sys.exit(main())
