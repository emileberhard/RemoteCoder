import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release_tag import validate


class ReleaseTagTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / 'source'
        self.remote = Path(temporary.name) / 'origin.git'
        subprocess.run(['git', 'init', '--quiet', '--bare', str(self.remote)], check=True)
        subprocess.run(['git', 'init', '--quiet', '-b', 'main', str(self.root)], check=True)
        self.git('config', 'user.name', 'Release Test')
        self.git('config', 'user.email', 'release@example.test')
        self.git('commit', '--quiet', '--allow-empty', '-m', 'Initial')
        self.commit = self.git('rev-parse', 'HEAD')
        self.git('remote', 'add', 'origin', str(self.remote))
        self.git('push', '--quiet', 'origin', 'main')

    def git(self, *arguments):
        return subprocess.check_output(['git', *arguments], cwd=self.root, text=True, stderr=subprocess.PIPE).strip()

    def tag(self, version='1.2.3', *, annotated=True):
        self.git('tag', *(['-a', '-m', 'User-visible change.'] if annotated else []), version)
        self.git('push', '--quiet', 'origin', version)

    def test_annotated_highest_tag_on_main_is_admitted(self):
        self.tag()
        validate(self.root, '1.2.3', self.commit)

    def test_invalid_version_and_commit_are_rejected_before_remote_access(self):
        for version in ['v1.2.3', '01.2.3', '1.2.3-beta', '1000.0.0', 'bad;echo injected']:
            with self.subTest(version=version), self.assertRaises(ValueError):
                validate(self.root, version, self.commit)
        with self.assertRaisesRegex(ValueError, 'full commit'):
            validate(self.root, '1.2.3', 'main')

    def test_lightweight_tag_has_no_release_notes_and_is_rejected(self):
        self.tag(annotated=False)
        with self.assertRaisesRegex(ValueError, 'annotated'):
            validate(self.root, '1.2.3', self.commit)

    def test_higher_remote_tag_blocks_an_older_release(self):
        self.tag()
        self.tag('1.10.0')
        with self.assertRaisesRegex(ValueError, 'highest'):
            validate(self.root, '1.2.3', self.commit)

    def test_side_branch_tag_never_reaches_deployment(self):
        self.git('checkout', '--quiet', '-b', 'unreviewed')
        self.git('commit', '--quiet', '--allow-empty', '-m', 'Outside main')
        self.tag()
        with self.assertRaisesRegex(ValueError, 'not on origin/main'):
            validate(self.root, '1.2.3', self.git('rev-parse', 'HEAD'))

    def test_requested_commit_must_match_remote_tag_and_checkout(self):
        self.tag()
        with self.assertRaisesRegex(ValueError, 'remote release tag'):
            validate(self.root, '1.2.3', 'f' * 40)
        self.git('commit', '--quiet', '--allow-empty', '-m', 'Later')
        with self.assertRaisesRegex(ValueError, 'checkout'):
            validate(self.root, '1.2.3', self.commit)

    def test_shallow_tag_checkout_fetches_main_ancestry(self):
        self.tag()
        clone = self.root.parent / 'shallow'
        subprocess.run(['git', 'clone', '--quiet', '--depth', '1', '--branch', '1.2.3', self.remote.as_uri(), str(clone)], check=True, stderr=subprocess.PIPE)
        validate(clone, '1.2.3', self.commit)


if __name__ == '__main__':
    unittest.main()
