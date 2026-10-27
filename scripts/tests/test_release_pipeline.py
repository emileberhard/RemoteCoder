import importlib.machinery
import importlib.util
import json
import os
import unittest
from unittest.mock import patch
from pathlib import Path
import tempfile


def load(name):
    loader = importlib.machinery.SourceFileLoader(name.replace('-', '_'), str(Path(__file__).resolve().parents[1] / name))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


asc = load('app-store-connect')


class StorePreparationTests(unittest.TestCase):
    def test_pending_release_is_preserved_without_any_store_mutation(self):
        record = {'id': 'pending', 'attributes': {'versionString': '3.73.0', 'appVersionState': 'PENDING_DEVELOPER_RELEASE'}}
        with patch.dict(os.environ, {'ASC_PLATFORM': 'IOS'}), patch.object(asc, 'api', return_value=[record]) as api:
            self.assertEqual(asc.draft_version('app', 'IOS', '3.73.1'), (None, False))
        self.assertEqual([call.args[0] for call in api.call_args_list], ['GET'])

    def test_numbers_include_uploads_that_are_not_processed_builds_yet(self):
        with patch.object(asc, 'api', side_effect=[
            [{'attributes': {'version': '3073000'}}, {'attributes': {'version': '1.5.12'}}],
            [{'attributes': {'cfBundleVersion': '3073002'}}],
        ]):
            self.assertEqual(asc.next_build_number('app'), 3073003)

    def test_upload_reconciliation_uses_exact_version_number_and_platform(self):
        upload = {'attributes': {'cfBundleVersion': '3073001', 'cfBundleShortVersionString': '3.73.1', 'platform': 'IOS'}}
        with patch.dict(os.environ, {'APP_STORE_CONNECT_KEY_ID': 'fixture', 'APP_STORE_CONNECT_ISSUER_ID': 'fixture',
                'APP_STORE_CONNECT_KEY_PATH': 'fixture', 'APP_BUNDLE_ID': 'example', 'ASC_PLATFORM': 'IOS'}), \
                patch.object(asc, 'api', side_effect=[[{'id': 'app'}], [], [upload]]), patch('builtins.print') as output:
            asc.main('upload-state', 'IOS', '3.73.1', '3073001')
            output.assert_called_once_with('present')
