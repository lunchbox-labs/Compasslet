"""Publishing graph and archive contracts, without credentials or Apple API access."""
import copy
from pathlib import Path
import tempfile
import unittest

from test_publish_identity import testflight


def project():
    objects = {}
    for target, bundle in [('app', testflight.APP), ('activity', testflight.ACTIVITY), ('watch', testflight.WATCH)]:
        objects[target] = {'isa': 'PBXNativeTarget', 'buildConfigurationList': target + '-configs',
                           'productReference': target + '-product', 'dependencies': [], 'buildPhases': []}
        objects[target + '-configs'] = {'buildConfigurations': [target + '-debug', target + '-release']}
        for config in ('debug', 'release'):
            objects[target + '-' + config] = {'buildSettings': {'PRODUCT_BUNDLE_IDENTIFIER': bundle}}
        objects[target + '-dependency'] = {'target': target}
        objects[target + '-file'] = {'fileRef': target + '-product'}
        objects[target + '-embed'] = {'isa': 'PBXCopyFilesBuildPhase', 'files': [target + '-file']}
    objects['app']['dependencies'] = ['activity-dependency', 'watch-dependency']
    objects['app']['buildPhases'] = ['activity-embed', 'watch-embed']
    return {'objects': objects}


class PublishingProjectTests(unittest.TestCase):
    def test_release_copy_detaches_watch_and_preserves_every_other_object(self):
        data = project()
        original = copy.deepcopy(data)
        testflight.exclude_watch_from_publish(data)
        self.assertEqual(data['objects']['app']['dependencies'], ['activity-dependency'])
        self.assertEqual(data['objects']['app']['buildPhases'], ['activity-embed'])
        for key, value in original['objects'].items():
            if key != 'app':
                self.assertEqual(data['objects'][key], value)

    def test_changed_embedding_fails_closed(self):
        for mutation in ('missing_dependency', 'missing_embed', 'shared_phase', 'ambiguous_target'):
            data = project()
            objects = data['objects']
            if mutation == 'missing_dependency':
                objects['app']['dependencies'].remove('watch-dependency')
            elif mutation == 'missing_embed':
                objects['app']['buildPhases'].remove('watch-embed')
            elif mutation == 'shared_phase':
                objects['watch-embed']['files'].append('activity-file')
            else:
                objects['other-watch'] = copy.deepcopy(objects['watch'])
            with self.subTest(mutation=mutation), self.assertRaises(testflight.SigningError):
                testflight.exclude_watch_from_publish(data)

    def test_archive_requires_iphone_and_activity_without_watch(self):
        with tempfile.TemporaryDirectory() as temp:
            archive = Path(temp)
            app = archive / 'Products/Applications/Compass.app'
            with self.assertRaises(testflight.SigningError):
                testflight.validate_publish_products(archive)
            app.mkdir(parents=True)
            with self.assertRaises(testflight.SigningError):
                testflight.validate_publish_products(archive)
            (app / 'PlugIns/CompassActivity.appex').mkdir(parents=True)
            testflight.validate_publish_products(archive)
            (app / 'Watch').mkdir()
            with self.assertRaises(testflight.SigningError):
                testflight.validate_publish_products(archive)
