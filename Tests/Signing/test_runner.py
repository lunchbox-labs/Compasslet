"""Portable synthetic CMS and cleanup tests; no Apple identity or Xcode simulation."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader('testflight', str(Path(__file__).resolve().parents[2] / 'scripts/testflight'))
spec = importlib.util.spec_from_loader(loader.name, loader)
runner = importlib.util.module_from_spec(spec)
loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def test_cms_verifies_signature_and_trust(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            key, cert, payload, cms = [root / n for n in ['key.pem', 'cert.pem', 'payload.plist', 'profile.cms']]
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                            '-subj', '/CN=Apple Synthetic Provisioning Profile Signing',
                            '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
            unrelated = root / 'unrelated.pem'
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                            '-subj', '/CN=Unrelated Synthetic Root', '-keyout', str(root / 'unrelated.key'),
                            '-out', str(unrelated)], check=True, capture_output=True)
            payload.write_bytes(plistlib.dumps({'Synthetic': True}))
            subprocess.run(['openssl', 'smime', '-sign', '-binary', '-nodetach', '-in', str(payload),
                            '-signer', str(cert), '-inkey', str(key), '-outform', 'DER', '-out', str(cms)],
                           check=True, capture_output=True)
            with patch.object(runner, 'WORK', root):
                self.assertEqual(runner.profile(cms, cert), {'Synthetic': True})
                # Even a misleading Apple subject and a default trusted certificate
                # cannot bypass the explicit trust anchors supplied by the caller.
                with patch.dict(runner.os.environ, SSL_CERT_FILE=str(cert)), self.assertRaises(ValueError):
                    runner.profile(cms, unrelated)
                contents = cms.read_bytes()
                self.assertIn(b'Synthetic', contents)
                cms.write_bytes(contents.replace(b'Synthetic', b'Tamperedd', 1))
                with self.assertRaises(ValueError):
                    runner.profile(cms, cert)

    def test_cleanup_before_and_after_import(self):
        for imported in [False, True]:
            with self.subTest(imported=imported), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                work = root / 'work'
                work.mkdir()
                installed = root / 'installed.mobileprovision'
                installed.write_bytes(b'private')
                (work / 'cleanup.json').write_text(json.dumps({'keychains': ['/old.keychain'],
                                                               'profiles': [str(installed)]}))
                keychain = work / 'keychain'
                if imported:
                    keychain.write_bytes(b'private')
                def security(*args, **kwargs):
                    if args[1] == 'delete-keychain':
                        keychain.unlink(missing_ok=True)
                    return subprocess.CompletedProcess(args, 0, b'', b'')
                with patch.object(runner, 'WORK', work), patch.object(runner, 'KEYCHAIN', keychain), \
                     patch.object(runner, 'run', side_effect=security) as mocked:
                    runner.cleanup()
                    mocked.assert_any_call('security', 'list-keychains', '-d', 'user', '-s',
                                           '/old.keychain', check=False, operation='restore keychain search list')
                    self.assertFalse(work.exists())
                    self.assertFalse(installed.exists())
                    runner.cleanup()  # Always step can safely repeat cleanup.

    def test_cleanup_failure_still_removes_other_credentials(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            work = root / 'work'
            work.mkdir()
            installed = root / 'installed.mobileprovision'
            installed.write_bytes(b'private')
            for name in ['AuthKey_TEST.p8', 'identity.p12', 'app.mobileprovision', 'signing.keychain-db']:
                (work / name).write_bytes(b'private')
            (work / 'cleanup.json').write_text(json.dumps({'keychains': ['/old'],
                                                           'profiles': [str(installed)]}))
            def security(*args, **kwargs):
                return subprocess.CompletedProcess(args, 1 if args[1] == 'list-keychains' else 0, b'', b'')
            with patch.object(runner, 'WORK', work), patch.object(runner, 'KEYCHAIN', work / 'keychain'), \
                 patch.object(runner, 'run', side_effect=security) as mocked:
                with self.assertRaisesRegex(ValueError, r'restore keychain search list \(exit code 1\)'):
                    runner.cleanup()
                mocked.assert_any_call('security', 'delete-keychain', work / 'keychain', check=False, operation='delete signing keychain')
                self.assertFalse(installed.exists())
                self.assertTrue((work / 'cleanup.json').exists())
                self.assertEqual({p.name for p in work.iterdir()}, {'cleanup.json'})
                with self.assertRaises(ValueError):
                    runner.cleanup()
                self.assertEqual({p.name for p in work.iterdir()}, {'cleanup.json'})

    def test_dispatch_gate_precedes_tools_and_credentials(self):
        for event, ref, confirmation in [('push', 'refs/heads/main', 'UPLOAD INTERNAL TESTFLIGHT'),
                                         ('workflow_dispatch', 'refs/heads/topic', 'UPLOAD INTERNAL TESTFLIGHT'),
                                         ('workflow_dispatch', 'refs/heads/main', 'yes')]:
            with self.subTest(event=event, ref=ref), patch.dict(runner.os.environ,
                    GITHUB_ACTIONS='true', GITHUB_EVENT_NAME=event, GITHUB_REF=ref, UPLOAD_CONFIRMATION=confirmation), \
                    patch.object(runner, 'run') as mocked:
                with self.assertRaises(ValueError):
                    runner.publish()
                mocked.assert_not_called()


if __name__ == '__main__':
    unittest.main()
