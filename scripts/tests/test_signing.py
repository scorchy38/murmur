import importlib.util
import json
import os
import pathlib
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]

def module(filename):
    spec = importlib.util.spec_from_file_location(filename.replace('-', '_'), ROOT / 'scripts' / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value

class SigningTests(unittest.TestCase):
    def test_unconfigured_release_uses_adhoc_without_reading_any_keychain(self):
        signing = module('configure-mac-signing.py')
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / 'output'
            with patch.dict(os.environ, {'GITHUB_OUTPUT': str(output)}, clear=True), patch.object(signing, 'run') as run:
                signing.main()
                run.assert_not_called()
            self.assertEqual(dict(line.split('=', 1) for line in output.read_text().splitlines()),
                             dict(identity='-', team='', runtime='NO', notarize='false', signflags='', style='Automatic'))

    def test_enabled_release_with_missing_credentials_fails_before_security_commands(self):
        signing = module('configure-mac-signing.py')
        with patch.dict(os.environ, {'MACOS_SIGNING_ENABLED': 'true'}, clear=True), patch.object(signing, 'run') as run:
            with self.assertRaisesRegex(SystemExit, 'Missing signed-release secrets'):
                signing.main()
            run.assert_not_called()

    def test_notarization_rejects_adhoc_artifacts(self):
        notarize = module('notarize-mac.py')
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory) / 'Murmur.app'; app.mkdir()
            with patch('sys.argv', ['notarize', str(app), '--identity', '-']), patch.object(notarize, 'checked') as checked:
                with self.assertRaisesRegex(SystemExit, 'Developer ID'):
                    notarize.main()
                checked.assert_not_called()

    def test_rejected_notarization_never_staples_or_assesses_artifact(self):
        notarize = module('notarize-mac.py')
        calls = []
        def checked(args):
            calls.append(args)
            if args[0:3] == ['xcrun', 'notarytool', 'submit']:
                return json.dumps({'status': 'Invalid', 'id': 'synthetic-submission'})
            return ''
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory) / 'Murmur.app'; app.mkdir()
            environment = {name: 'synthetic-only' for name in ('APPLE_NOTARY_PRIVATE_KEY', 'APPLE_NOTARY_KEY_ID', 'APPLE_NOTARY_ISSUER_ID')}
            with patch('sys.argv', ['notarize', str(app), '--identity', 'synthetic-public-identity']), patch.dict(os.environ, environment, clear=True), patch.object(notarize, 'checked', side_effect=checked):
                with self.assertRaisesRegex(SystemExit, 'did not accept'):
                    notarize.main()
        self.assertFalse(any('stapler' in args or 'spctl' in args for args in calls))

if __name__ == '__main__':
    unittest.main()
