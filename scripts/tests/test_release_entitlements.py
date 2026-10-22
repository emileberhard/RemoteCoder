import importlib.util
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
spec = importlib.util.spec_from_file_location('release_entitlements', Path(__file__).resolve().parents[1] / 'verify-release-entitlements.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReleaseEntitlementsTests(unittest.TestCase):
    def verify_cloudkit_bundle(self, platform, distribution, signed_environment, profile_environments):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle = root / 'Fixture.app'
            contents = bundle / 'Contents' if platform == 'mac' else bundle
            contents.mkdir(parents=True)
            (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'example.Fixture'}))
            declared = root / 'Fixture.entitlements'
            declared.write_bytes(plistlib.dumps({'com.apple.developer.icloud-services': ['CloudKit']}))
            profile = {'TeamIdentifier': ['TEAM'], 'Entitlements': {
                'com.apple.application-identifier' if platform == 'mac' else 'application-identifier': 'TEAM.example.Fixture',
                'com.apple.developer.icloud-services': '*',
                'com.apple.developer.icloud-container-environment': profile_environments,
            }}
            signed = {'com.apple.developer.icloud-services': ['CloudKit']}
            if signed_environment is not None:
                signed['com.apple.developer.icloud-container-environment'] = signed_environment
            with patch.object(module.subprocess, 'check_output', side_effect=[plistlib.dumps(profile), plistlib.dumps(signed)]):
                module.verify_bundle(bundle, declared, {'DEVELOPMENT_TEAM': 'TEAM'}, platform, distribution)

    def test_mac_app_store_archive_may_omit_the_environment_but_cannot_use_development(self):
        self.verify_cloudkit_bundle('mac', 'app-store', None, ['Production', 'Development'])
        with self.assertRaisesRegex(ValueError, 'icloud-container-environment'):
            self.verify_cloudkit_bundle('mac', 'app-store', 'Development', ['Production', 'Development'])

    def test_direct_mac_and_ios_exports_require_a_signed_production_environment(self):
        for platform, distribution in [('mac', 'developer-id'), ('ios', 'app-store'), ('ios', 'ad-hoc')]:
            with self.subTest(platform=platform, distribution=distribution):
                self.verify_cloudkit_bundle(platform, distribution, 'Production', ['Production'])
                for environment in [None, 'Development']:
                    with self.assertRaisesRegex(ValueError, 'icloud-container-environment'):
                        self.verify_cloudkit_bundle(platform, distribution, environment, ['Production', 'Development'])

    def test_mac_app_store_profile_must_authorize_production_even_without_a_signed_environment(self):
        with self.assertRaisesRegex(ValueError, 'icloud-container-environment'):
            self.verify_cloudkit_bundle('mac', 'app-store', None, ['Development'])

    def test_source_identity_is_resolved_and_missing_cloudkit_fails(self):
        requested = module.resolve({'com.apple.developer.icloud-container-identifiers': ['$(RC_ICLOUD_CONTAINER)'], 'com.apple.developer.icloud-services': ['CloudKit']}, {'RC_ICLOUD_CONTAINER': 'iCloud.example.RemoteCoder'})
        with self.assertRaisesRegex(ValueError, 'icloud-container-identifiers'):
            module.require_entitlements(requested, {}, 'signed app')
        module.require_entitlements(requested, requested, 'signed app')

    def test_stale_profile_cannot_authorize_cloudkit(self):
        requested = {'com.apple.developer.icloud-services': ['CloudKit']}
        with self.assertRaisesRegex(ValueError, 'icloud-services'):
            module.require_entitlements(requested, {}, 'current profile', profile=True)

    def test_cloudkit_profile_string_wildcard_and_environment_array_are_valid(self):
        requested = {'com.apple.developer.icloud-services': ['CloudKit'], 'com.apple.developer.icloud-container-environment': 'Production'}
        module.require_entitlements(requested, {'com.apple.developer.icloud-services': '*', 'com.apple.developer.icloud-container-environment': ['Development', 'Production']}, 'profile', profile=True)

    def test_profile_wildcards_authorize_requested_values_but_do_not_hide_missing_rights(self):
        requested = {'com.apple.developer.icloud-container-identifiers': ['iCloud.example.RemoteCoder'], 'com.apple.security.app-sandbox': True}
        module.require_entitlements(requested, {'com.apple.developer.icloud-container-identifiers': ['iCloud.example.*']}, 'profile', profile=True)
        with self.assertRaises(ValueError):
            module.require_entitlements(requested, {'com.apple.developer.icloud-container-identifiers': ['iCloud.other.*']}, 'profile', profile=True)


if __name__ == '__main__':
    unittest.main()
