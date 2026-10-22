import argparse
import fnmatch
import plistlib
import subprocess
import tempfile
import zipfile
from pathlib import Path

from maintainer_config import load
from xcode_settings import resolve

ROOT = Path(__file__).resolve().parents[1]


def require_entitlements(required, actual, owner, *, profile=False):
    for name, value in required.items():
        if profile and not (name.startswith('com.apple.developer.') or name in {'aps-environment', 'com.apple.security.application-groups'}):
            continue
        allowed = actual.get(name)
        if profile:
            required_values = value if isinstance(value, list) else [value]
            allowed_values = allowed if isinstance(allowed, list) else [allowed]
            valid = all(any(fnmatch.fnmatchcase(item, candidate) if isinstance(item, str) and isinstance(candidate, str) else item == candidate for candidate in allowed_values) for item in required_values)
        elif isinstance(value, list):
            valid = isinstance(allowed, list) and all(item in allowed for item in value)
        else:
            valid = value == allowed
        if not valid:
            raise ValueError(f'{owner}: missing or mismatched requested entitlement {name}')


def verify_bundle(bundle: Path, declared: Path | None, settings: dict, platform: str, distribution: str) -> None:
    contents = bundle / 'Contents' if platform == 'mac' else bundle
    info = plistlib.loads((contents / 'Info.plist').read_bytes())
    profile_path = contents / ('embedded.provisionprofile' if platform == 'mac' else 'embedded.mobileprovision')
    profile = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(profile_path)], stderr=subprocess.DEVNULL))
    team = settings['DEVELOPMENT_TEAM']
    if team not in profile.get('TeamIdentifier', []):
        raise ValueError(f'{bundle}: provisioning profile belongs to another team')
    profile_entitlements = profile['Entitlements']
    identity_key = 'com.apple.application-identifier' if platform == 'mac' else 'application-identifier'
    identity = team + '.' + info['CFBundleIdentifier']
    if not fnmatch.fnmatchcase(identity, profile_entitlements.get(identity_key, '')):
        raise ValueError(f'{bundle}: provisioning profile does not authorize its exact application identifier')
    required = resolve(plistlib.loads(declared.read_bytes()), settings) if declared else {}
    signed = plistlib.loads(subprocess.check_output(['codesign', '--display', '--entitlements', '-', '--xml', str(bundle)], stderr=subprocess.DEVNULL))
    require_entitlements(required, signed, bundle)
    require_entitlements(required, profile_entitlements, profile_path, profile=True)
    if 'com.apple.developer.icloud-services' in required:
        environment_key = 'com.apple.developer.icloud-container-environment'
        environment = {environment_key: 'Production'}
        require_entitlements(environment, profile_entitlements, profile_path, profile=True)
        if platform != 'mac' or distribution != 'app-store' or environment_key in signed:
            require_entitlements(environment, signed, bundle)
    for entitlement, key in [('com.apple.developer.icloud-container-identifiers', 'RemoteCoderDictationContainer'), ('com.apple.security.application-groups', 'RemoteCoderAppGroup')]:
        if bundle.suffix == '.app' and entitlement in required and info.get(key) not in required[entitlement]:
            raise ValueError(f'{bundle}: {key} differs from its requested entitlement')


def verify_app(app: Path, platform: str, distribution: str) -> None:
    settings = load()['xcodeSettings'] | {'RC_APNS_ENVIRONMENT': 'production'}
    source = ROOT / 'RemoteCoder/Entitlements' / ('RemoteCoderMac.Release.entitlements' if platform == 'mac' else 'RemoteCoder.Release.entitlements')
    verify_bundle(app, source, settings, platform, distribution)
    if platform == 'ios':
        for extension in sorted([*(app / 'PlugIns').glob('*.appex'), *(app / 'Extensions').glob('*.appex')]):
            source = ROOT / extension.stem / (extension.stem + '.entitlements')
            if not source.parent.is_dir():
                raise ValueError(f'{extension}: no declared extension target')
            verify_bundle(extension, source if source.is_file() else None, settings, platform, distribution)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--platform', choices=('ios', 'mac'), required=True)
    parser.add_argument('--distribution', choices=('app-store', 'ad-hoc', 'developer-id'), required=True)
    artifact = parser.add_mutually_exclusive_group(required=True)
    artifact.add_argument('--app', type=Path)
    artifact.add_argument('--ipa', type=Path)
    arguments = parser.parse_args()
    if arguments.ipa:
        with tempfile.TemporaryDirectory(prefix='release-entitlements-') as directory:
            with zipfile.ZipFile(arguments.ipa) as archive:
                archive.extractall(directory)
            apps = list((Path(directory) / 'Payload').glob('*.app'))
            if len(apps) != 1:
                raise ValueError('Release IPA must contain exactly one app')
            verify_app(apps[0], arguments.platform, arguments.distribution)
    else:
        verify_app(arguments.app, arguments.platform, arguments.distribution)
    print('Release entitlements match current declarations and embedded provisioning profiles.')


if __name__ == '__main__':
    main()
