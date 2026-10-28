import copy
import datetime as dt
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts/signing'))
from validation import APP, validate_profile, validate_build, validate_product


class ValidationTests(unittest.TestCase):
    def setUp(self):
        self.profile = {'UUID': '12345678-1234-1234-1234-123456789ABC',
                        'TeamIdentifier': ['TEAM123456'],
                        'ExpirationDate': dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=1),
                        'DeveloperCertificates': [b'certificate'],
                        'Entitlements': {'application-identifier': 'TEAM123456.' + APP,
                                         'com.apple.developer.team-identifier': 'TEAM123456',
                                         'get-task-allow': False,
                                         'beta-reports-active': True,
                                         'com.apple.developer.carplay-driving-task': True}}

    def check(self, p):
        validate_profile(p, 'TEAM123456', APP, b'certificate')

    def test_valid(self):
        self.check(self.profile)

    def test_profile_rejections(self):
        mutations = [lambda p: p.update(TeamIdentifier=['OTHER']),
                     lambda p: p['Entitlements'].update({'application-identifier': 'TEAM123456.*'}),
                     lambda p: p.update(DeveloperCertificates=[b'wrong']),
                     lambda p: p.update(ExpirationDate=dt.datetime(2000, 1, 1)),
                     lambda p: p.update(ProvisionedDevices=['device']),
                     lambda p: p.update(ProvisionsAllDevices=True),
                     lambda p: p['Entitlements'].update({'get-task-allow': True}),
                     lambda p: p['Entitlements'].pop('beta-reports-active'),
                     lambda p: p['Entitlements'].pop('com.apple.developer.carplay-driving-task')]
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                p = copy.deepcopy(self.profile)
                mutate(p)
                with self.assertRaises(ValueError):
                    self.check(p)

    def test_build_numbers(self):
        for good in ['1.0.0', '9999.99.99', '42.1.2']:
            validate_build(good)
        for bad in ['', '0.0.0', '10000.0.0', '1.100.0', '1.0', '01.0.0', '1.0.0b1', '1.0.0\n']:
            with self.subTest(build=bad), self.assertRaises(ValueError):
                validate_build(bad)

    def test_product_consistency(self):
        ent = self.profile['Entitlements']
        info = {'CFBundleIdentifier': APP, 'CFBundleVersion': '2.0.0'}
        validate_product(info, ent, self.profile, APP, '2.0.0')
        for key, bad in [('CFBundleIdentifier', APP + '.activity'), ('CFBundleVersion', '1.0.0')]:
            with self.assertRaises(ValueError):
                validate_product(dict(info, **{key: bad}), ent, self.profile, APP, '2.0.0')
        with self.assertRaises(ValueError):
            validate_product(info, dict(ent, **{'get-task-allow': True}), self.profile, APP, '2.0.0')

if __name__ == '__main__':
    unittest.main()
