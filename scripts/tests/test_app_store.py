"""Offline App Review and App Store release tests against a stateful App Store Connect fake."""
import contextlib
import copy
import hashlib
import io
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import app_store
import metadata_sync as metadata

SIZE = (5, 3)


def resource(kind, identity, **attributes):
    return {'type': kind, 'id': identity, 'attributes': attributes}


def chunk(kind, body):
    return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body))


def paeth(left, above, corner):
    estimate = left + above - corner
    distances = abs(estimate - left), abs(estimate - above), abs(estimate - corner)
    if distances[0] <= distances[1] and distances[0] <= distances[2]:
        return left
    return above if distances[1] <= distances[2] else corner


def filtered(rows, pixel_bytes):
    """Encode each row with a different PNG filter, as encoders choose them per row."""
    encoded, previous = b'', bytes(len(rows[0]))
    for index, row in enumerate(rows):
        kind = index % 5
        out = bytearray()
        for i, value in enumerate(row):
            left = row[i - pixel_bytes] if i >= pixel_bytes else 0
            corner = previous[i - pixel_bytes] if i >= pixel_bytes else 0
            predictor = [0, left, previous[i], (left + previous[i]) >> 1,
                         paeth(left, previous[i], corner)][kind]
            out.append((value - predictor) & 0xff)
        encoded += bytes([kind]) + bytes(out)
        previous = row
    return encoded


def png(pixels, color=6, extra=(), width=SIZE[0], height=SIZE[1]):
    pixel_bytes = 4 if color == 6 else 3
    rows = [bytes(pixels[y * width * pixel_bytes:(y + 1) * width * pixel_bytes]) for y in range(height)]
    header = struct.pack('>IIBBBBB', width, height, 8, color, 0, 0, 0)
    return (app_store.PNG_SIGNATURE + chunk(b'IHDR', header) + b''.join(extra)
            + chunk(b'IDAT', zlib.compress(filtered(rows, pixel_bytes))) + chunk(b'IEND', b''))


def rgba(seed=0):
    values = []
    for index in range(SIZE[0] * SIZE[1]):
        values += [(index * 37 + seed) % 256, (index * 91 + 7) % 256, (index * 13 + seed * 3) % 256, 255]
    return values


def decoded(data):
    chunks = dict(app_store.png_chunks(data))
    width, height, depth, color = struct.unpack('>IIBB', chunks[b'IHDR'][:10])
    raw = zlib.decompress(chunks[b'IDAT'])
    stride = width * (4 if color == 6 else 3)
    return color, [raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)] for y in range(height)]


class FakeAppStore:
    """App Store Connect's resources for one app and version; uploads go to an Apple blob host."""
    def __init__(self):
        self.app = resource('apps', 'app1', bundleId=metadata.BUNDLE_ID)
        self.version = resource('appStoreVersions', 'version1', versionString='1.1', platform='IOS',
                                appVersionState='PREPARE_FOR_SUBMISSION', releaseType='AFTER_APPROVAL')
        self.linked_build = None
        self.build = resource('builds', 'build1', version='34.1', processingState='VALID')
        self.build['relationships'] = {
            'app': {'data': {'type': 'apps', 'id': 'app1'}},
            'preReleaseVersion': {'data': {'type': 'preReleaseVersions', 'id': 'pre1'}}}
        self.pre = resource('preReleaseVersions', 'pre1', version='1.1', platform='IOS')
        self.review = resource('appStoreReviewDetails', 'review1', notes='Old notes',
                               contactFirstName='Kept')
        self.localization = resource('appStoreVersionLocalizations', 'loc1', locale='en-US')
        self.sets = [resource('appScreenshotSets', 'large1', screenshotDisplayType='APP_IPHONE_67')]
        self.screenshots = {'large1': ['big1']}
        self.records = {'big1': resource('appScreenshots', 'big1', fileName='large.png',
                                         sourceFileChecksum='aa', assetDeliveryState={'state': 'COMPLETE'})}
        self.uploads = {}
        self.submissions = []
        self.items = {}
        self.writes = []
        self.counter = 0

    def add_listing(self, names_and_checksums):
        self.sets.append(resource('appScreenshotSets', 'set1', screenshotDisplayType='APP_IPHONE_61'))
        self.screenshots['set1'] = []
        for name, checksum in names_and_checksums:
            identity = self.next_id('old')
            self.records[identity] = resource('appScreenshots', identity, fileName=name,
                                              sourceFileChecksum=checksum,
                                              assetDeliveryState={'state': 'COMPLETE'})
            self.screenshots['set1'].append(identity)

    def next_id(self, prefix):
        self.counter += 1
        return prefix + str(self.counter)

    def respond(self, value):
        return io.BytesIO(b'' if value is None else json.dumps(value).encode())

    def open(self, request, timeout):
        url = urlsplit(request.full_url)
        method, path = request.method, url.path
        if url.hostname != 'api.appstoreconnect.apple.com':
            assert request.get_header('Authorization') is None, 'token sent to an upload host'
            self.uploads.setdefault(path, b'')
            self.uploads[path] += request.data
            return self.respond(None)
        body = json.loads(request.data)['data'] if request.data else None
        if method != 'GET':
            self.writes.append((method, path, copy.deepcopy(body)))
        query = parse_qs(url.query)
        return self.respond(self.route(method, path, query, body))

    def route(self, method, path, query, body):
        version_path = '/v1/appStoreVersions/version1'
        if (method, path) == ('GET', '/v1/apps'):
            return {'data': [self.app]}
        if (method, path) == ('GET', '/v1/apps/app1/appStoreVersions'):
            version = copy.deepcopy(self.version)
            included = []
            if self.linked_build:
                version['relationships'] = {'build': {'data': {'type': 'builds', 'id': self.linked_build}}}
                included = [self.build] if self.linked_build == 'build1' else [
                    resource('builds', self.linked_build, version='33.1')]
            return {'data': [version], 'included': included}
        if (method, path) == ('GET', version_path):
            return {'data': self.version}
        if (method, path) == ('PATCH', version_path):
            self.version['attributes'].update(body['attributes'])
            return {'data': self.version}
        if path == version_path + '/relationships/build':
            if method == 'PATCH':
                self.linked_build = body['id']
                return None
            return {'data': {'type': 'builds', 'id': self.linked_build} if self.linked_build else None}
        if (method, path) == ('GET', version_path + '/appStoreReviewDetail'):
            return {'data': self.review}
        if (method, path) == ('PATCH', '/v1/appStoreReviewDetails/review1'):
            self.review['attributes'].update(body['attributes'])
            return {'data': self.review}
        if (method, path) == ('GET', version_path + '/appStoreVersionLocalizations'):
            return {'data': [self.localization]}
        if (method, path) == ('GET', '/v1/appStoreVersionLocalizations/loc1/appScreenshotSets'):
            return {'data': self.sets}
        if (method, path) == ('POST', '/v1/appScreenshotSets'):
            created = resource('appScreenshotSets', 'set1', **body['attributes'])
            self.sets.append(created)
            self.screenshots['set1'] = []
            return {'data': created}
        if path.startswith('/v1/appScreenshotSets/') and path.endswith('/appScreenshots'):
            set_id = path.split('/')[3]
            return {'data': [self.records[i] for i in self.screenshots[set_id]]}
        if path.startswith('/v1/appScreenshotSets/') and path.endswith('/relationships/appScreenshots'):
            set_id = path.split('/')[3]
            assert sorted(i['id'] for i in body) == sorted(self.screenshots[set_id])
            self.screenshots[set_id] = [i['id'] for i in body]
            return None
        if (method, path) == ('POST', '/v1/appScreenshots'):
            identity = self.next_id('shot')
            size = body['attributes']['fileSize']
            half = size // 2
            record = resource('appScreenshots', identity, fileName=body['attributes']['fileName'],
                              assetDeliveryState={'state': 'AWAITING_UPLOAD'}, uploadOperations=[
                                  {'method': 'PUT', 'url': 'https://blob.example.apple.com/' + identity,
                                   'offset': half, 'length': size - half,
                                   'requestHeaders': [{'name': 'Content-Type', 'value': 'image/png'}]},
                                  {'method': 'PUT', 'url': 'https://blob.example.apple.com/' + identity,
                                   'offset': 0, 'length': half, 'requestHeaders': []}])
            self.records[identity] = record
            self.screenshots[body['relationships']['appScreenshotSet']['data']['id']].append(identity)
            return {'data': record}
        if path.startswith('/v1/appScreenshots/'):
            identity = path.split('/')[3]
            record = self.records[identity]
            if method == 'DELETE':
                for ids in self.screenshots.values():
                    if identity in ids:
                        ids.remove(identity)
                return None
            if method == 'PATCH':
                uploaded = self.uploads.get('/' + identity, b'')
                assert body['attributes']['sourceFileChecksum'] == hashlib.md5(uploaded).hexdigest()
                record['attributes'].update(body['attributes'])
                record['attributes']['assetDeliveryState'] = {'state': 'UPLOAD_COMPLETE'}
                return {'data': record}
            delivered = copy.deepcopy(record)
            record['attributes']['assetDeliveryState'] = {'state': 'COMPLETE'}
            return {'data': delivered}
        if (method, path) == ('GET', '/v1/builds'):
            return {'data': [self.build], 'included': [self.pre]}
        if (method, path) == ('GET', '/v1/reviewSubmissions'):
            assert query['filter[app]'] == ['app1'] and query['filter[platform]'] == ['IOS']
            wanted = query['filter[state]'][0].split(',')
            return {'data': [s for s in self.submissions if s['attributes']['state'] in wanted]}
        if (method, path) == ('POST', '/v1/reviewSubmissions'):
            created = resource('reviewSubmissions', self.next_id('submission'), platform='IOS',
                               state='READY_FOR_REVIEW')
            self.submissions.append(created)
            self.items[created['id']] = []
            return {'data': created}
        if path.startswith('/v1/reviewSubmissions/') and path.endswith('/items'):
            return {'data': [{'type': 'reviewSubmissionItems', 'id': 'item-' + v, 'relationships': {
                'appStoreVersion': {'data': {'type': 'appStoreVersions', 'id': v}}}}
                for v in self.items[path.split('/')[3]]]}
        if (method, path) == ('POST', '/v1/reviewSubmissionItems'):
            submission = body['relationships']['reviewSubmission']['data']['id']
            self.items[submission].append(body['relationships']['appStoreVersion']['data']['id'])
            return {'data': {'type': 'reviewSubmissionItems', 'id': 'item1'}}
        if method == 'PATCH' and path.startswith('/v1/reviewSubmissions/'):
            submission = next(s for s in self.submissions if s['id'] == path.split('/')[3])
            assert body['attributes'] == {'submitted': True} and self.items[submission['id']]
            submission['attributes']['state'] = 'WAITING_FOR_REVIEW'
            self.version['attributes']['appVersionState'] = 'WAITING_FOR_REVIEW'
            return {'data': submission}
        if (method, path) == ('POST', '/v1/appStoreVersionReleaseRequests'):
            assert body['relationships']['appStoreVersion']['data']['id'] == 'version1'
            self.version['attributes']['appVersionState'] = 'PROCESSING_FOR_DISTRIBUTION'
            return {'data': {'type': 'appStoreVersionReleaseRequests', 'id': 'request1'}}
        raise AssertionError('Unexpected App Store Connect request: ' + method + ' ' + path)


class ImageTests(unittest.TestCase):
    def setUp(self):
        patcher = patch.object(app_store, 'LISTING_SIZE', SIZE)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_opaque_capture_is_flattened_to_the_same_rgb_pixels(self):
        pixels = rgba()
        color, rows = decoded(app_store.listing_png(png(pixels)))
        self.assertEqual(color, 2)
        expected = bytes(v for i, v in enumerate(pixels) if i % 4 != 3)
        self.assertEqual(b''.join(rows), expected)

    def test_colour_profile_is_kept_and_other_metadata_dropped(self):
        source = png(rgba(), extra=[chunk(b'sRGB', b'\x00'), chunk(b'caBX', b'credential'),
                                    chunk(b'eXIf', b'MM\x00*')])
        kinds = [kind for kind, _ in app_store.png_chunks(app_store.listing_png(source))]
        self.assertEqual(kinds, [b'IHDR', b'sRGB', b'IDAT', b'IEND'])

    def test_rgb_capture_is_uploaded_unchanged(self):
        source = png([v for i, v in enumerate(rgba()) if i % 4 != 3], color=2)
        self.assertEqual(app_store.listing_png(source), source)

    def test_transparency_wrong_size_and_non_png_are_refused(self):
        transparent = rgba()
        transparent[7] = 128
        for source in (png(transparent), png(rgba(), width=4), b'not a png'):
            with self.subTest(source=source[:10]), self.assertRaises(metadata.MetadataError):
                app_store.listing_png(source)


class ProjectAndNotesTests(unittest.TestCase):
    def test_project_version_needs_one_value_for_every_target(self):
        self.assertEqual(app_store.project_version('MARKETING_VERSION = 1.0;\nMARKETING_VERSION = 1.0;'), '1.0')
        for text in ('MARKETING_VERSION = 1.0;\nMARKETING_VERSION = 1.1;', 'nothing', 'MARKETING_VERSION = beta;'):
            with self.subTest(text=text), self.assertRaises(metadata.MetadataError):
                app_store.project_version(text)

    def test_review_notes_are_optional_but_never_blank_or_overlong(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertIsNone(app_store.read_review_notes(root))
            (root / 'review-notes.txt').write_text('  Open the app from CarPlay.\n')
            self.assertEqual(app_store.read_review_notes(root), 'Open the app from CarPlay.')
            for value in ('\n', 'x' * 4001):
                (root / 'review-notes.txt').write_text(value)
                with self.subTest(length=len(value)), self.assertRaises(metadata.MetadataError):
                    app_store.read_review_notes(root)

    def test_the_repository_notes_fit_when_present(self):
        app_store.read_review_notes()


class ReviewTests(unittest.TestCase):
    def setUp(self):
        patcher = patch.object(app_store, 'LISTING_SIZE', SIZE)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.apple = FakeAppStore()
        self.client = metadata.Client(lambda: 'fake-token', opener=self.apple)
        self.messages = []
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        for seed, name in enumerate(app_store.LISTING_FILES):
            (self.directory / name).write_bytes(png(rgba(seed)))
        self.shots = app_store.read_listing(self.directory)

    def review(self, notes='New notes', shots=None, submit=True):
        app_store.review(self.client, '1.1', '34.1', notes, self.shots if shots is None else shots,
                         submit, ['en-US'], report=self.messages.append, attempts=2,
                         sleep=lambda _: None)

    def listing(self):
        return [(self.apple.records[i]['attributes']['fileName'],
                 self.apple.records[i]['attributes']['sourceFileChecksum'])
                for i in self.apple.screenshots['set1']]

    def test_publish_replaces_the_listing_syncs_notes_and_submits_the_build(self):
        self.apple.add_listing([('stale.png', 'bb')])
        self.review()
        self.assertEqual(self.apple.review['attributes']['notes'], 'New notes')
        self.assertEqual(self.apple.review['attributes']['contactFirstName'], 'Kept')
        self.assertEqual(self.listing(), [(name, checksum) for name, _, checksum in self.shots])
        for name, payload, _ in self.shots:
            identity = next(i for i in self.apple.screenshots['set1']
                            if self.apple.records[i]['attributes']['fileName'] == name)
            self.assertEqual(self.apple.uploads['/' + identity], payload)
        self.assertEqual(self.apple.screenshots['large1'], ['big1'])
        self.assertEqual(self.apple.linked_build, 'build1')
        self.assertEqual(self.apple.version['attributes']['releaseType'], 'MANUAL')
        self.assertEqual(self.apple.submissions[0]['attributes']['state'], 'WAITING_FOR_REVIEW')
        self.assertEqual(self.apple.items[self.apple.submissions[0]['id']], ['version1'])
        writes = [(m, p) for m, p, _ in self.apple.writes]
        self.assertLess(writes.index(('PATCH', '/v1/appStoreReviewDetails/review1')),
                        writes.index(('POST', '/v1/appScreenshots')))
        self.assertEqual(writes[-1][0], 'PATCH')
        self.assertTrue(writes[-1][1].startswith('/v1/reviewSubmissions/'))

    def test_a_missing_listing_set_is_created(self):
        self.review(submit=False, shots=self.shots)
        self.assertEqual(self.listing(), [(name, checksum) for name, _, checksum in self.shots])
        self.assertIn('POST', [m for m, p, _ in self.apple.writes if p == '/v1/appScreenshotSets'])
        self.assertEqual(self.apple.submissions, [])

    def test_matching_listing_and_notes_are_left_alone(self):
        self.apple.add_listing([(name, checksum) for name, _, checksum in self.shots])
        self.apple.review['attributes']['notes'] = 'New notes'
        self.review(submit=False)
        self.assertEqual(self.apple.writes, [])
        self.assertIn('UNCHANGED listing screenshots en-US', self.messages)
        self.assertIn('UNCHANGED App Review notes', self.messages)

    def test_missing_notes_file_leaves_the_notes_in_app_store_connect(self):
        self.review(notes=None, shots=[], submit=False)
        self.assertEqual(self.apple.review['attributes']['notes'], 'Old notes')
        self.assertEqual(self.apple.writes, [])

    def test_a_draft_submission_holding_this_version_is_reused(self):
        draft = resource('reviewSubmissions', 'draft1', platform='IOS', state='READY_FOR_REVIEW')
        self.apple.submissions.append(draft)
        self.apple.items['draft1'] = ['version1']
        self.review()
        self.assertEqual(len(self.apple.submissions), 1)
        self.assertEqual(self.apple.items['draft1'], ['version1'])
        self.assertEqual(draft['attributes']['state'], 'WAITING_FOR_REVIEW')

    def test_a_submission_apple_sent_back_is_resubmitted_with_the_new_build(self):
        self.apple.version['attributes']['appVersionState'] = 'REJECTED'
        self.apple.linked_build = 'build0'
        returned = resource('reviewSubmissions', 'returned1', platform='IOS', state='UNRESOLVED_ISSUES')
        self.apple.submissions.append(returned)
        self.apple.items['returned1'] = ['version1']
        self.review()
        self.assertEqual(len(self.apple.submissions), 1)
        self.assertEqual(self.apple.linked_build, 'build1')
        self.assertEqual(returned['attributes']['state'], 'WAITING_FOR_REVIEW')

    def test_another_open_submission_stops_before_submitting(self):
        for submission_state, items in (('WAITING_FOR_REVIEW', ['version0']),
                                        ('IN_REVIEW', ['version1']),
                                        ('UNRESOLVED_ISSUES', ['other-version']),
                                        ('READY_FOR_REVIEW', ['other-version'])):
            with self.subTest(state=submission_state):
                self.apple = FakeAppStore()
                self.client = metadata.Client(lambda: 'fake-token', opener=self.apple)
                self.apple.submissions.append(resource('reviewSubmissions', 's1', platform='IOS',
                                                       state=submission_state))
                self.apple.items['s1'] = items
                with self.assertRaises(metadata.MetadataError):
                    self.review()
                self.assertFalse(any(p.startswith('/v1/reviewSubmissions/') for _, p, _ in self.apple.writes))
                self.assertEqual(self.apple.version['attributes']['appVersionState'], 'PREPARE_FOR_SUBMISSION')

    def test_a_rerun_after_submitting_succeeds_without_writing(self):
        self.review()
        self.apple.writes.clear()
        self.review()
        self.assertEqual(self.apple.writes, [])
        self.assertIn('ALREADY SUBMITTED version 1.1 with build 34.1.', self.messages)

    def test_a_version_submitted_with_another_build_is_not_touched(self):
        self.apple.version['attributes']['appVersionState'] = 'WAITING_FOR_REVIEW'
        self.apple.linked_build = 'build0'
        with self.assertRaises(metadata.MetadataError):
            self.review()
        self.assertEqual(self.apple.writes, [])

    def test_without_an_editable_version_only_a_testflight_build_continues(self):
        self.apple.version['attributes']['versionString'] = '1.0'
        with self.assertRaises(metadata.MetadataError):
            self.review()
        self.review(shots=[], submit=False)
        self.assertEqual(self.apple.writes, [])
        self.assertTrue(any(m.startswith('SKIP App Review notes and listing') for m in self.messages))

    def test_an_unprocessed_build_is_never_submitted(self):
        self.apple.build['attributes']['processingState'] = 'PROCESSING'
        with self.assertRaises(metadata.MetadataError):
            self.review()
        self.assertEqual(self.apple.submissions, [])
        self.assertIsNone(self.apple.linked_build)

    def test_upload_operations_off_apple_hosts_are_refused_before_sending(self):
        opener = FakeAppStore()
        for url in ('https://blob.example.com/x', 'http://blob.example.apple.com/x',
                    'https://user:pass@blob.example.apple.com/x'):
            with self.subTest(url=url), self.assertRaises(metadata.MetadataError):
                app_store.send_parts(opener, [{'method': 'PUT', 'url': url, 'offset': 0, 'length': 3}], b'abc')
        self.assertEqual(opener.uploads, {})
        with self.assertRaises(metadata.MetadataError):
            app_store.send_parts(opener, [{'method': 'PUT', 'url': 'https://blob.example.apple.com/x',
                                           'offset': 0, 'length': 2}], b'abc')


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.apple = FakeAppStore()
        self.apple.linked_build = 'build1'
        self.client = metadata.Client(lambda: 'fake-token', opener=self.apple)
        self.messages = []

    def test_releasing_needs_a_version_apple_is_holding_for_release(self):
        self.apple.version['attributes']['appVersionState'] = 'PENDING_DEVELOPER_RELEASE'
        self.assertEqual(app_store.approved(self.client, '1.1', True), '34.1')
        for version_state in ('PREPARE_FOR_SUBMISSION', 'WAITING_FOR_REVIEW', 'READY_FOR_DISTRIBUTION'):
            with self.subTest(state=version_state):
                self.apple.version['attributes']['appVersionState'] = version_state
                with self.assertRaises(metadata.MetadataError):
                    app_store.approved(self.client, '1.1', True)

    def test_a_live_version_can_be_tagged_without_releasing_it_again(self):
        self.apple.version['attributes']['appVersionState'] = 'READY_FOR_DISTRIBUTION'
        self.assertEqual(app_store.approved(self.client, '1.1', False), '34.1')
        self.apple.version['attributes']['appVersionState'] = 'IN_REVIEW'
        with self.assertRaises(metadata.MetadataError):
            app_store.approved(self.client, '1.1', False)

    def test_builds_not_made_by_publish_are_refused(self):
        self.apple.version['attributes']['appVersionState'] = 'READY_FOR_DISTRIBUTION'
        self.apple.build['attributes']['version'] = '7'
        with self.assertRaises(metadata.MetadataError):
            app_store.approved(self.client, '1.1', False)

    def test_release_requests_the_approved_version_once(self):
        self.apple.version['attributes']['appVersionState'] = 'PENDING_DEVELOPER_RELEASE'
        app_store.release(self.client, '1.1', '34.1', report=self.messages.append)
        self.assertEqual([p for _, p, _ in self.apple.writes], ['/v1/appStoreVersionReleaseRequests'])
        app_store.release(self.client, '1.1', '34.1', report=self.messages.append)
        self.assertEqual(len(self.apple.writes), 1)
        self.assertIn('ALREADY RELEASED version 1.1 on the App Store.', self.messages)

    def test_release_refuses_another_build_or_an_unapproved_version(self):
        self.apple.version['attributes']['appVersionState'] = 'PENDING_DEVELOPER_RELEASE'
        with self.assertRaises(metadata.MetadataError):
            app_store.release(self.client, '1.1', '35.1')
        self.apple.version['attributes']['appVersionState'] = 'IN_REVIEW'
        with self.assertRaises(metadata.MetadataError):
            app_store.release(self.client, '1.1', '34.1')
        self.assertEqual(self.apple.writes, [])


class CommandTests(unittest.TestCase):
    def test_commands_refuse_runs_that_are_not_manual_runs_from_main(self):
        for event, ref in (('push', 'refs/heads/main'), ('workflow_dispatch', 'refs/heads/feature'),
                           ('workflow_dispatch', 'refs/tags/v1.0')):
            for command in ('approved', 'release'):
                with self.subTest(event=event, ref=ref, command=command), \
                        patch.dict('os.environ', {'GITHUB_ACTIONS': 'true', 'GITHUB_EVENT_NAME': event,
                                                  'GITHUB_REF': ref, 'RELEASE_APP_STORE': 'true',
                                                  'RELEASE_VERSION': '1.0', 'RELEASE_BUILD_NUMBER': '33.1',
                                                  'ASC_METADATA_API_PRIVATE_KEY_BASE64': 'unused'}), \
                        patch.object(metadata, 'api_client') as client, \
                        contextlib.redirect_stderr(io.StringIO()) as stderr:
                    self.assertEqual(app_store.main([command]), 1)
                    client.assert_not_called()
                    self.assertIn('Run manually from main.', stderr.getvalue())


    def test_review_needs_listing_screenshots_exactly_when_submitting(self):
        for submit, directory in (('true', ''), ('false', '/tmp/listing')):
            with self.subTest(submit=submit), \
                    patch.dict('os.environ', {'SUBMIT': submit, 'LISTING_SCREENSHOTS': directory}), \
                    patch.object(metadata, 'workflow_identity', return_value=('1.1', '34.1')), \
                    patch.object(metadata, 'api_client') as client, \
                    contextlib.redirect_stderr(io.StringIO()) as stderr:
                self.assertEqual(app_store.main(['review']), 1)
                client.assert_not_called()
                self.assertIn('exactly when the version is submitted', stderr.getvalue())

    def test_unknown_commands_print_usage(self):
        with contextlib.redirect_stderr(io.StringIO()) as stderr:
            self.assertEqual(app_store.main(['ship']), 2)
        self.assertIn('review|approved|release', stderr.getvalue())

if __name__ == '__main__':
    unittest.main()
