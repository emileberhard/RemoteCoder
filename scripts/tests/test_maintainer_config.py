import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import maintainer_config


class MaintainerConfigTests(unittest.TestCase):
    def test_public_build_needs_no_operator_configuration(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True), patch.object(maintainer_config.Path, 'home', return_value=Path(directory)):
            root = Path(directory) / 'source'
            maintainer_config.configure(root)
            self.assertFalse((root / 'Config/Local.xcconfig').exists())
            with self.assertRaisesRegex(ValueError, 'require maintainer'):
                maintainer_config.configure(root, required=True)

    def test_operator_identity_is_written_without_overwriting_local_edits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / 'maintainer.json'
            config.write_text(json.dumps({'xcodeSettings': {'DEVELOPMENT_TEAM': 'ABCDEFGHIJ', 'RC_BUNDLE_ID': 'test.operator.RemoteCoder', 'RC_NOTIFICATION_SOUND_ORIGINS': 'https://audio.example.test'}}))
            with patch.dict(os.environ, {'RC_MAINTAINER_CONFIG': str(config)}):
                maintainer_config.configure(root, required=True)
                local = root / 'Config/Local.xcconfig'
                self.assertIn('https:/$()/audio.example.test', local.read_text())
                local.write_text('local override\n')
                maintainer_config.configure(root)
                self.assertEqual(local.read_text(), 'local override\n')

    def test_signed_release_rejects_example_identity(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(maintainer_config, 'load', return_value={'xcodeSettings': {'DEVELOPMENT_TEAM': 'ABCDEFGHIJ', 'RC_BUNDLE_ID': 'com.example.RemoteCoder'}}):
            with self.assertRaisesRegex(ValueError, 'real development team'):
                maintainer_config.configure(Path(directory), required=True)


if __name__ == '__main__':
    unittest.main()
