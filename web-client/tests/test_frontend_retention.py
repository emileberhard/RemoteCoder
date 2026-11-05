import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[2] / "web-client/scripts/deploy.py"
spec = importlib.util.spec_from_file_location("web_frontend_deploy", SOURCE)
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)


class WebFrontendRetentionTests(unittest.TestCase):
    def test_recording_preserves_current_and_previous_across_stage_pruning(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            releases = root / "releases"
            releases.mkdir()
            with (
                patch.object(deploy, "ROOT", root),
                patch.object(deploy, "RELEASES", releases),
                patch.object(deploy, "runtime"),
            ):
                for index in range(3):
                    revision = str(index) * 40
                    release = releases / revision
                    (release / "dist").mkdir(parents=True)
                    (release / "dist/deployment.json").write_text(json.dumps({"revision": revision}))
                    deploy.point("staged", release)
                    with contextlib.redirect_stdout(io.StringIO()):
                        deploy.record_frontend(revision)
                self.assertEqual({path.name for path in releases.iterdir()}, {"1" * 40, "2" * 40})
                self.assertEqual((root / "frontend-current").resolve().name, "2" * 40)
                self.assertEqual((root / "frontend-previous").resolve().name, "1" * 40)
                with contextlib.redirect_stdout(io.StringIO()):
                    deploy.record_frontend("2" * 40)
                self.assertEqual((root / "frontend-previous").resolve().name, "1" * 40)

    def test_wrong_revision_preserves_the_existing_frontend(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            release = root / "releases" / ("1" * 40)
            (release / "dist").mkdir(parents=True)
            (release / "dist/deployment.json").write_text(json.dumps({"revision": "1" * 40}))
            with (
                patch.object(deploy, "ROOT", root),
                patch.object(deploy, "RELEASES", release.parent),
                patch.object(deploy, "runtime"),
            ):
                deploy.point("staged", release)
                deploy.point("frontend-current", release)
                with self.assertRaisesRegex(RuntimeError, "does not match"):
                    deploy.record_frontend("2" * 40)
                self.assertEqual((root / "frontend-current").resolve(), release)
                self.assertFalse((root / "frontend-previous").exists())
