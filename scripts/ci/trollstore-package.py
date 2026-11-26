#!/usr/bin/env python3
"""Create an entitlement-bearing ad-hoc IPA; TrollStore supplies device trust.

No Apple identity/profile, fake team, or pre-applied CoreTrust exploit is used.
This module is importable by the platform-independent packaging regression tests.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import zipfile

APP_GROUP = 'group.com.openminis.app'
TROLLSTORE_SOURCE = '88424f683b2a08f34a3f88985f790f97d84ce1df'
FRAMEWORKS = ('FFmpeg', 'libavcodec', 'libavformat', 'libavutil', 'libavfilter',
              'libswresample', 'libswscale', 'RealTimeCutVADCXXLibrary')
EXTENSIONS = (
    ('MinisShare', 'com.openminis.app.ShareExtension', 'ShareExtension/ShareExtension.entitlements'),
    ('MinisFileProvider', 'com.openminis.app.FileProvider', 'FileProvider/FileProvider.entitlements'),
    ('AgentWidgetExtension', 'com.openminis.app.AgentWidget', 'AgentWidget/AgentWidget.entitlements'),
)
# These are not needed for Minis. Three are explicitly launch-fatal on affected
# A12+ systems according to TrollStore's README; do not "fix" sandboxing with them.
FORBIDDEN = {
    'com.apple.private.cs.debugger', 'dynamic-codesigning',
    'com.apple.private.skip-library-validation', 'platform-application',
    'com.apple.private.security.no-container', 'com.apple.private.security.no-sandbox',
    'com.apple.private.persona-mgmt', 'task_for_pid-allow',
    'com.apple.system-task-ports', 'com.apple.system-task-ports.control',
    'com.apple.system-task-ports.token.control', 'jb.pmap_cs.custom_trust',
    'com.apple.private.security.system-application',
}
MACHO_MAGICS = (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
                b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def read_plist(path):
    return plistlib.loads(Path(path).read_bytes())


def version(value):
    parts = tuple(int(p) for p in value.split('.'))
    return (parts + (0, 0, 0))[:3]


def macho_files(app):
    result = []
    for path in sorted(app.rglob('*')):
        if path.is_file() and not path.is_symlink():
            with path.open('rb') as stream:
                if stream.read(4) in MACHO_MAGICS:
                    result.append(path)
    return result


def signature_metadata(path):
    """Check signed thin arm64 iOS image and enumerate its CodeDirectories.

    codesign --verify --strict checks the actual code/resource hashes; this
    parser is an extra structural gate and manifest, not a replacement for it.
    """
    data = Path(path).read_bytes()
    require(data[:4] == b'\xcf\xfa\xed\xfe', f'Not thin arm64: {path}')
    _, cpu, _, filetype, count, size, _, _ = struct.unpack_from('<8I', data)
    require(cpu == 0x0100000c and filetype in (2, 6), f'Wrong iOS image: {path}')
    require(32 + size <= len(data), f'Invalid load commands: {path}')
    pos, signatures, builds = 32, [], []
    for _ in range(count):
        cmd, length = struct.unpack_from('<II', data, pos)
        require(length >= 8 and pos + length <= 32 + size, f'Invalid command: {path}')
        if cmd == 0x1d:
            signatures.append(struct.unpack_from('<II', data, pos + 8))
        elif cmd == 0x32:
            platform, minimum, _, _ = struct.unpack_from('<4I', data, pos + 8)
            v = (minimum >> 16, (minimum >> 8) & 255, minimum & 255)
            require(platform == 2 and v <= (17, 3, 1), f'Incompatible iOS image: {path}')
            builds.append('.'.join(map(str, v)))
        pos += length
    require(pos == 32 + size and builds, f'No iOS build version: {path}')
    require(len(signatures) == 1, f'Missing/duplicate LC_CODE_SIGNATURE: {path}')
    offset, length = signatures[0]
    require(length >= 12 and offset + length <= len(data), f'Invalid signature range: {path}')
    magic, total, slots = struct.unpack_from('>III', data, offset)
    require(magic == 0xfade0cc0 and 12 + slots * 8 <= total <= length,
            f'Invalid signature superblob: {path}')
    directories = []
    for i in range(slots):
        slot, relative = struct.unpack_from('>II', data, offset + 12 + i * 8)
        require(12 + slots * 8 <= relative <= total - 8, f'Invalid signature slot: {path}')
        start = offset + relative
        blob_magic, blob_size = struct.unpack_from('>II', data, start)
        require(8 <= blob_size <= total - relative, f'Invalid signature blob: {path}')
        if blob_magic == 0xfade0c02:
            require(blob_size >= 44, f'Short CodeDirectory: {path}')
            flags = struct.unpack_from('>I', data, start + 12)[0]
            require(flags & 2, f'Expected ad-hoc CodeDirectory: {path}')
            directories.append({'slot': slot, 'sha256': hashlib.sha256(data[start:start + blob_size]).hexdigest(),
                                'flags': flags, 'code_slots': struct.unpack_from('>I', data, start + 28)[0],
                                'hash_type': data[start + 37], 'page_size_log2': data[start + 39]})
    require(directories and all(d['code_slots'] > 0 for d in directories), f'No code pages: {path}')
    require(any(d['hash_type'] == 2 for d in directories), f'No SHA-256 CodeDirectory: {path}')
    return {'minimum_ios': builds, 'signature_offset': offset, 'signature_size': length,
            'code_directories': directories, 'sha256': hashlib.sha256(data).hexdigest()}


def entitlement_plan(source, bundle_id):
    entitlements = read_plist(source)
    require(isinstance(entitlements, dict), f'Not an entitlement dictionary: {source}')
    require(not (set(entitlements) & FORBIDDEN), f'Unreviewed privileged entitlements: {source}')
    require(entitlements.get('com.apple.security.application-groups') == [APP_GROUP],
            f'Unexpected App Group: {source}')
    require('com.apple.developer.team-identifier' not in entitlements,
            'Do not fabricate or import an Apple team for this ad-hoc artifact')
    # Existing entitlements suppress TrollStore's nil-only fallback. Use the real
    # owned bundle namespace, no TROLLTROLL/Apple team, wildcard keychain, token
    # group, or debugger grant. The string container binding matches its signer.
    for key, value in {'application-identifier': bundle_id, 'get-task-allow': False,
                       'com.apple.private.security.container-required': bundle_id}.items():
        require(key not in entitlements or entitlements[key] == value, f'Conflicting {key}: {source}')
        entitlements[key] = value
    return entitlements


def bundle_plan(app, root):
    plan = []
    for name in FRAMEWORKS:
        relative = f'Frameworks/{name}.framework'
        info = read_plist(app / relative / 'Info.plist')
        plan.append((relative, info.get('CFBundleIdentifier'), None))
    plan += [(f'PlugIns/{name}.appex', identifier, ent) for name, identifier, ent in EXTENSIONS]
    plan.append(('.', 'com.openminis.app', 'Minis.entitlements'))
    result = []
    for relative, identifier, entitlement_source in plan:
        path = app / relative
        info = read_plist(path / 'Info.plist')
        require(identifier and info.get('CFBundleIdentifier') == identifier, f'Bundle ID mismatch: {path}')
        require(info.get('CFBundleExecutable') and (path / info['CFBundleExecutable']).is_file(),
                f'Bundle executable missing: {path}')
        require(version(info['MinimumOSVersion']) <= (17, 3, 1), f'Newer minimum iOS: {path}')
        source = root / 'src/ios' / entitlement_source if entitlement_source else None
        entitlements = entitlement_plan(source, identifier) if source else {}
        if relative == 'PlugIns/MinisFileProvider.appex':
            require(info.get('NSExtension', {}).get('NSExtensionFileProviderDocumentGroup') == APP_GROUP,
                    'FileProvider metadata and signing App Group must match')
        result.append({'path': path, 'relative': relative, 'info': info, 'source': source,
                       'entitlements': entitlements})
    require(read_plist(app / 'Info.plist').get('MinimumOSVersion') == '17.0', 'Main deployment target must remain 17.0')
    expected = {b['path'] / b['info']['CFBundleExecutable'] for b in result}
    require(set(macho_files(app)) == expected and len(expected) == 12,
            'Expected exactly main + 3 extensions + 8 dynamic frameworks; review new images explicitly')
    require(not list(app.rglob('embedded.mobileprovision')), 'No provisioning profiles are allowed')
    main_version = result[-1]['info']['CFBundleVersion']
    require(all(b['info']['CFBundleVersion'] == main_version for b in result if b['source']),
            'Main and extension CFBundleVersions must match')
    return result


def codesign(*arguments):
    command = ['codesign', *map(str, arguments)]
    print('+ ' + ' '.join(command), flush=True)
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        print((result.stdout + result.stderr).decode('utf-8', errors='replace'), flush=True)
    result.check_returncode()
    return result


def embedded_entitlements(path):
    output = codesign('--display', '--entitlements', ':-', path).stdout
    if not output.strip():
        return {}
    # --display's diagnostics go to stderr, never into the parsed plist.
    return plistlib.loads(output)


def verify_bundle(item):
    path = item['path']
    codesign('--verify', '--strict', '--verbose=2', path)
    actual = embedded_entitlements(path)
    require(actual == item['entitlements'], f'Embedded entitlements differ from plan: {path}')
    display = codesign('--display', '--verbose=4', path)
    details = (display.stdout + display.stderr).decode('utf-8', errors='replace')
    require('Signature=adhoc' in details, f'Not an ad-hoc signature: {path}')
    require('TeamIdentifier=not set' in details, f'Unexpected signing team: {path}')
    executable = path / item['info']['CFBundleExecutable']
    require((path / '_CodeSignature/CodeResources').is_file(), f'Missing bundle resource seal: {path}')
    return {'bundle': item['relative'], 'bundle_id': item['info']['CFBundleIdentifier'],
            'executable': item['info']['CFBundleExecutable'],
            'bundle_version': item['info']['CFBundleVersion'],
            'entitlements': actual, 'strict_verification': True,
            **signature_metadata(executable)}


def sign_plan(plan, temporary, root):
    records = []
    for index, item in enumerate(plan):
        args = ['--force', '--sign', '-', '--timestamp=none',
                '--identifier', item['info']['CFBundleIdentifier']]
        if item['source']:
            entitlement_file = temporary / f'entitlements-{index}.plist'
            entitlement_file.write_bytes(plistlib.dumps(item['entitlements'], sort_keys=True))
            args += ['--generate-entitlement-der', '--entitlements', entitlement_file]
        # Do not use --deep to SIGN: it can copy the main entitlements to every
        # nested executable. Frameworks intentionally receive no entitlements.
        codesign(*args, item['path'])
        record = verify_bundle(item)
        if item['source']:
            record['source_entitlements'] = str(item['source'].relative_to(root))
            record['source_entitlements_sha256'] = sha256(item['source'])
            record['packaging_added_keys'] = ['application-identifier', 'get-task-allow',
                                              'com.apple.private.security.container-required']
        records.append(record)
    return records


def create_package(unsigned_app, out, root):
    require(shutil.which('codesign') and Path('/usr/bin/ditto').is_file(),
            'Real macOS codesign and ditto are required; no mock/unsigned substitute is allowed')
    require(unsigned_app.is_dir() and unsigned_app.name == 'Minis.app', 'Unsigned staged Minis.app is required')
    original_hashes = {str(p.relative_to(unsigned_app)): sha256(p) for p in macho_files(unsigned_app)}
    stage = out / 'trollstore-ipa-stage'
    if stage.exists():
        shutil.rmtree(stage)
    payload = stage / 'Payload'
    payload.mkdir(parents=True)
    app = payload / unsigned_app.name
    shutil.copytree(unsigned_app, app, symlinks=True)
    plan = bundle_plan(app, root)
    for item in plan:
        require(not item['info'].get('TSBundlePreSigned') and not item['info'].get('TSPreAppliedExploitType'),
                'Do not declare a pre-applied TrollStore exploit in an ad-hoc package')
    with tempfile.TemporaryDirectory(prefix='trollstore-entitlements-', dir=out) as tmp:
        records = sign_plan(plan, Path(tmp), root)
    codesign('--verify', '--strict', '--deep', '--verbose=2', app)
    artifact_dir = out / 'artifacts/trollstore'
    artifact_dir.mkdir(parents=True, exist_ok=True)
    ipa = artifact_dir / 'Minis-TrollStore.ipa'
    if ipa.exists():
        ipa.unlink()
    subprocess.run(['/usr/bin/ditto', '-c', '-k', '--keepParent', '--norsrc', str(payload), str(ipa)], check=True)
    with zipfile.ZipFile(ipa) as archive:
        require(archive.testzip() is None, 'Corrupt TrollStore IPA')
        names = archive.namelist()
        require('Payload/Minis.app/_CodeSignature/CodeResources' in names, 'Missing app resource seal in IPA')
        require(not any(n.endswith('embedded.mobileprovision') for n in names), 'Unexpected provisioning profile in IPA')
        require(not any(n.endswith('.entitlements') for n in names), 'Entitlements must be embedded, not loose ZIP files')
    # Validate the DELIVERED ZIP, not only its staging input, with correct Unix
    # permissions/symlinks restored by ditto. Any signing/ZIP damage is fatal.
    with tempfile.TemporaryDirectory(prefix='trollstore-unzip-verify-', dir=out) as tmp:
        subprocess.run(['/usr/bin/ditto', '-x', '-k', str(ipa), tmp], check=True)
        restored = Path(tmp) / 'Payload/Minis.app'
        delivered_records = [verify_bundle(item) for item in bundle_plan(restored, root)]
        require([r['sha256'] for r in delivered_records] == [r['sha256'] for r in records],
                'ZIP round-trip changed a signed image')
        codesign('--verify', '--strict', '--deep', '--verbose=2', restored)
    require(original_hashes == {str(p.relative_to(unsigned_app)): sha256(p) for p in macho_files(unsigned_app)},
            'Unsigned input was modified')
    manifest = {
        'format_version': 1, 'artifact': ipa.name, 'sha256': sha256(ipa),
        'signing': 'ad-hoc codesign -s -; original per-target entitlements plus owned identity/container bindings',
        'apple_identity_used': False, 'provisioning_profile_used': False, 'pre_applied_exploit': False,
        'source_entitlements_preserved': True, 'device_tested': False,
        'app_group': APP_GROUP, 'macho_count': len(records), 'framework_count': 8, 'extension_count': 3,
        'main_bundle_id': 'com.openminis.app', 'bundle_version': plan[-1]['info']['CFBundleVersion'],
        'strict_verified_all_bundles': True, 'deep_verified_app': True, 'verified_after_ipa_roundtrip': True,
        'trollstore_source_reference': f'https://github.com/opa334/TrollStore/tree/{TROLLSTORE_SOURCE}',
        'official_trollstore_support_note': 'Official non-jailbroken TrollStore supports <= iOS 17.0, not 17.3.1. Lite/jailbroken/other installer trust must be established separately.',
        'bundles': records,
    }
    common = json.loads((out / 'artifacts/BUILD-INFO.json').read_text())
    info = {**common, 'artifact': ipa.name, 'artifact_kind': 'trollstore-ad-hoc-entitlement-bearing',
            'signing': manifest['signing'], 'installable_as_is': False,
            'requires_installer_resigning_or_jailbreak_trust': True,
            'apple_identity_used': False, 'provisioning_profile_used': False,
            'pre_applied_exploit': False, 'device_tested': False,
            'bundle_version': manifest['bundle_version'], 'manifest': 'TROLLSTORE-MANIFEST.json'}
    (artifact_dir / 'BUILD-INFO.json').write_text(json.dumps(info, indent=2) + '\n')
    (artifact_dir / 'TROLLSTORE-MANIFEST.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (artifact_dir / 'TROLLSTORE-INSTALL.txt').write_text(
        'Minis-TrollStore.ipa contains real ad-hoc signatures and embedded per-target entitlements.\n'
        'Give this IPA, not Minis-unsigned.ipa, to your existing compatible TrollStore/Lite installation environment.\n'
        'TrollStore or the jailbroken installer must establish device trust/re-signing; no exploit is pre-applied here.\n'
        'No Apple private key, signing identity, fabricated Apple team, or provisioning profile was used.\n'
        'This is NOT Apple ad-hoc distribution, App Store/TestFlight, or a generally installable stock-iOS IPA.\n'
        'Official non-jailbroken TrollStore supports up to iOS 17.0; iOS 17.3.1 requires a separately valid environment (e.g. jailbreak/Lite).\n'
        'Bundle IDs and group.com.openminis.app are unchanged. Source HealthKit/HomeKit/NFC/cloud/APNs/weather entitlements are preserved,\n'
        'but signatures do not guarantee server-backed capabilities, consent, or minimum-OS API availability.\n'
        'Device installation/launch and existing-data/keychain migration have NOT been tested by this packager.\n')
    with (artifact_dir / 'SHA256SUMS').open('w') as sums:
        for path in (ipa, artifact_dir / 'BUILD-INFO.json', artifact_dir / 'TROLLSTORE-MANIFEST.json', artifact_dir / 'TROLLSTORE-INSTALL.txt'):
            sums.write(f'{sha256(path)}  {path.name}\n')
    (out / 'reports').mkdir(parents=True, exist_ok=True)
    (out / 'reports/trollstore-validation.json').write_text(json.dumps({'valid': True, **manifest}, indent=2) + '\n')
    print(f'Validated entitlement-bearing TrollStore IPA: {ipa} ({ipa.stat().st_size} bytes); device trust/launch NOT tested.')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('unsigned_app', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    create_package(args.unsigned_app.resolve(), args.output.resolve(), args.source_root.resolve())


if __name__ == '__main__':
    main()
