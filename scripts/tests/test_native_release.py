import importlib.machinery
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch


def load(name, filename):
    loader = importlib.machinery.SourceFileLoader(name, str(Path(__file__).resolve().parents[1] / filename))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


asc = load('release_asc', 'app-store-connect')
state = load('release_state', 'release-state')


class NativeReleaseTests(unittest.TestCase):
    def test_a_newer_tag_after_processing_blocks_all_store_mutations(self):
        for operation in [asc.testflight, asc.app_store]:
            with self.subTest(operation=operation.__name__), patch.dict(os.environ, {'GITHUB_SHA': 'a' * 40}), \
                patch.object(asc, 'wait', return_value='processed-build'), patch.object(asc, 'api') as api, \
                patch.object(asc.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, ['release_tag.py'])), \
                self.assertRaises(subprocess.CalledProcessError):
                operation('app', 'IOS', '3.73.1', '3073001', 'Notes')
            api.assert_not_called()

    def test_same_run_reservation_reuses_an_unexpired_artifact_without_an_age_cutoff(self):
        archive = io.BytesIO()
        receipt = {'version': '3.73.1', 'commit': 'a' * 40, 'build': '3073001'}
        with zipfile.ZipFile(archive, 'w') as stream:
            stream.writestr('build-number.json', json.dumps(receipt))
        artifacts = {'artifacts': [{'name': 'release-numbers', 'expired': False, 'id': 77}]}
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {'GITHUB_REPOSITORY': 'owner/repo', 'GITHUB_RUN_ID': '42'}), \
            patch.object(sys, 'argv', ['release-state', 'release-numbers', directory]), \
            patch.object(state, 'api', side_effect=[json.dumps(artifacts).encode(), archive.getvalue()]) as api:
            state.main()
            self.assertEqual(json.loads((Path(directory) / 'build-number.json').read_text()), receipt)
            self.assertEqual(api.call_args_list[0].args, ('repos/owner/repo/actions/runs/42/artifacts?per_page=100',))

    def test_expired_or_ambiguous_reservations_cannot_be_replaced(self):
        artifact = {'name': 'release-numbers', 'expired': False, 'id': 77}
        for artifacts in [[artifact | {'expired': True}], [artifact, artifact | {'id': 78}]]:
            with self.subTest(artifacts=artifacts), tempfile.TemporaryDirectory() as directory, \
                patch.dict(os.environ, {'GITHUB_REPOSITORY': 'owner/repo', 'GITHUB_RUN_ID': '42'}), \
                patch.object(sys, 'argv', ['release-state', 'release-numbers', directory]), \
                patch.object(state, 'api', return_value=json.dumps({'artifacts': artifacts}).encode()), self.assertRaises(SystemExit):
                state.main()


if __name__ == '__main__':
    unittest.main()
