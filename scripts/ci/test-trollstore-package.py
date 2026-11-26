#!/usr/bin/env python3
"""Packaging regressions; on macOS also sign/unzip/verify a real 12-image IPA.

Pure tests use fixtures/mocks and are NOT evidence of real signing. The macOS
smoke test compiles arm64 iOS images with Xcode and uses the real codesign/ditto.
No compiled iOS executable or TrollStore code is ever executed.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('trollstore_package', Path(__file__).with_name('trollstore-package.py'))
pack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pack)


def write_plist(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(value))


def image(signed=False, filetype=2, minimum=0x110000):
    build = struct.pack('<6I', 0x32, 24, 2, minimum, 0x1a0200, 0)
    if not signed:
        return struct.pack('<8I', 0xfeedfacf, 0x0100000c, 0, filetype, 1, 24, 0, 0) + build
    identifier = b'com.openminis.fixture\0'
    cd_size = 44 + len(identifier) + 32
    length = 20 + cd_size
    code = struct.pack('<8I', 0xfeedfacf, 0x0100000c, 0, filetype, 2, 40, 0, 0) + build
    code += struct.pack('<4I', 0x1d, 16, 128, length)
    code = code.ljust(128, b'\0')
    cd = struct.pack('>9I4BI', 0xfade0c02, cd_size, 0x20001, 2, 44 + len(identifier),
                     44, 0, 1, 128, 32, 2, 0, 12, 0)
    cd += identifier + hashlib.sha256(code).digest()
    return code + struct.pack('>5I', 0xfade0cc0, length, 1, 0, 20) + cd


def fixture(base):
    root, app = base / 'source', base / 'input/Minis.app'
    sources = ['Minis.entitlements', *(ent for _, _, ent in pack.EXTENSIONS)]
    for relative in sources:
        dest = root / 'src/ios' / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / 'src/ios' / relative, dest)
    targets = [(f'Frameworks/{n}.framework', n, f'org.fixture.{n}', 'FMWK') for n in pack.FRAMEWORKS]
    targets += [(f'PlugIns/{n}.appex', n, bid, 'XPC!') for n, bid, _ in pack.EXTENSIONS]
    targets.append(('.', 'Minis', 'com.openminis.app', 'APPL'))
    for relative, executable, identifier, kind in targets:
        bundle = app / relative
        info = {'CFBundleIdentifier': identifier, 'CFBundleExecutable': executable,
                'CFBundlePackageType': kind, 'CFBundleVersion': '2',
                'CFBundleShortVersionString': '1.0', 'MinimumOSVersion': '17.0',
                'CFBundleSupportedPlatforms': ['iPhoneOS']}
        if executable == 'MinisFileProvider':
            info['NSExtension'] = {'NSExtensionFileProviderDocumentGroup': pack.APP_GROUP,
                                  'NSExtensionPointIdentifier': 'com.apple.fileprovider-nonui'}
        write_plist(bundle / 'Info.plist', info)
        binary = bundle / executable
        binary.write_bytes(image(filetype=6 if kind == 'FMWK' else 2))
        binary.chmod(0o755)
    return root, app


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='minis-trollstore-unit-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.root, self.app = fixture(self.base)

    def plan(self):
        return pack.bundle_plan(self.app, self.root)

    def test_exact_twelve_inside_out(self):
        plan = self.plan()
        self.assertEqual(len(plan), 12)
        self.assertTrue(all(b['relative'].startswith('Frameworks/') for b in plan[:8]))
        self.assertTrue(all(b['relative'].startswith('PlugIns/') for b in plan[8:11]))
        self.assertEqual(plan[-1]['relative'], '.')
        self.assertTrue(all(b['entitlements'] == {} for b in plan[:8]))

    def test_source_permissions_preserved_without_fake_team_or_debug_grants(self):
        for b in self.plan()[8:]:
            original = pack.read_plist(b['source'])
            actual = b['entitlements']
            self.assertEqual({k: actual[k] for k in original}, original)
            self.assertEqual(actual['com.apple.security.application-groups'], [pack.APP_GROUP])
            self.assertEqual(actual['application-identifier'], b['info']['CFBundleIdentifier'])
            self.assertEqual(actual['com.apple.private.security.container-required'], b['info']['CFBundleIdentifier'])
            self.assertIs(actual['get-task-allow'], False)
            self.assertNotIn('com.apple.developer.team-identifier', actual)
            self.assertNotIn('keychain-access-groups', actual)
            self.assertFalse(set(actual) & pack.FORBIDDEN)
            self.assertEqual(pack.read_plist(b['source']), original)

    def test_group_metadata_drift_fails(self):
        path = self.app / 'PlugIns/MinisFileProvider.appex/Info.plist'
        info = pack.read_plist(path)
        info['NSExtension']['NSExtensionFileProviderDocumentGroup'] = 'group.wrong'
        write_plist(path, info)
        with self.assertRaisesRegex(ValueError, 'FileProvider metadata'):
            self.plan()

    def test_missing_group_entitlement_fails(self):
        path = self.root / 'src/ios/Minis.entitlements'
        ent = pack.read_plist(path)
        ent.pop('com.apple.security.application-groups')
        write_plist(path, ent)
        with self.assertRaisesRegex(ValueError, 'App Group'):
            self.plan()

    def test_forbidden_privileges_and_fake_team_fail(self):
        path = self.root / 'src/ios/Minis.entitlements'
        original = pack.read_plist(path)
        for key in sorted(pack.FORBIDDEN | {'com.apple.developer.team-identifier'}):
            with self.subTest(key=key):
                write_plist(path, {**original, key: True})
                with self.assertRaises(ValueError):
                    self.plan()

    def test_identity_or_container_conflict_fails(self):
        path = self.root / 'src/ios/Minis.entitlements'
        original = pack.read_plist(path)
        for key, value in [('application-identifier', 'fake.*'), ('get-task-allow', True),
                           ('com.apple.private.security.container-required', False)]:
            write_plist(path, {**original, key: value})
            with self.assertRaisesRegex(ValueError, 'Conflicting'):
                self.plan()

    def test_renamed_identifier_fails(self):
        path = self.app / 'Info.plist'
        write_plist(path, {**pack.read_plist(path), 'CFBundleIdentifier': 'com.wrong.app'})
        with self.assertRaisesRegex(ValueError, 'Bundle ID mismatch'):
            self.plan()

    def test_extension_version_drift_fails(self):
        path = self.app / 'PlugIns/MinisShare.appex/Info.plist'
        write_plist(path, {**pack.read_plist(path), 'CFBundleVersion': '1'})
        with self.assertRaisesRegex(ValueError, 'CFBundleVersions'):
            self.plan()

    def test_newer_os_metadata_fails(self):
        path = self.app / 'Info.plist'
        write_plist(path, {**pack.read_plist(path), 'MinimumOSVersion': '26.0'})
        with self.assertRaisesRegex(ValueError, 'Newer minimum iOS'):
            self.plan()

    def test_unreviewed_thirteenth_image_fails(self):
        (self.app / 'surprise').write_bytes(image())
        with self.assertRaisesRegex(ValueError, 'exactly main'):
            self.plan()

    def test_profile_fails(self):
        (self.app / 'embedded.mobileprovision').write_text('not a profile')
        with self.assertRaisesRegex(ValueError, 'No provisioning'):
            self.plan()

    def test_signing_commands_bind_each_entitlement_only_to_its_target(self):
        calls, signed_entitlements = [], []
        def fake_codesign(*args):
            calls.append(args)
            self.assertNotIn('--deep', args)
            self.assertEqual(args[args.index('--sign') + 1], '-')
            if '--entitlements' in args:
                path = args[args.index('--entitlements') + 1]
                signed_entitlements.append(pack.read_plist(path))
            else:
                signed_entitlements.append({})
            return SimpleNamespace(stdout=b'', stderr=b'')
        temporary = self.base / 'entitlements'
        temporary.mkdir()
        plan = self.plan()
        with patch.object(pack, 'codesign', side_effect=fake_codesign), \
             patch.object(pack, 'verify_bundle', side_effect=lambda item: {'sha256': 'fixture'}):
            records = pack.sign_plan(plan, temporary, self.root)
        self.assertEqual(len(records), 12)
        self.assertEqual([c[-1] for c in calls], [b['path'] for b in plan])
        self.assertEqual(signed_entitlements, [b['entitlements'] for b in plan])
        self.assertEqual(len({c[c.index('--entitlements') + 1] for c in calls if '--entitlements' in c}), 4)

    def test_actual_embedded_entitlements_are_required_not_loose_plists(self):
        item = self.plan()[-1]
        with patch.object(pack, 'codesign'), patch.object(pack, 'embedded_entitlements', return_value={}):
            with self.assertRaisesRegex(ValueError, 'Embedded entitlements differ'):
                pack.verify_bundle(item)

    def test_structural_signed_macho_and_reject_unsigned_or_newer_os(self):
        path = self.base / 'binary'
        path.write_bytes(image(signed=True))
        metadata = pack.signature_metadata(path)
        self.assertEqual(metadata['minimum_ios'], ['17.0.0'])
        self.assertEqual(metadata['code_directories'][0]['hash_type'], 2)
        self.assertEqual(metadata['code_directories'][0]['code_slots'], 1)
        for data in (image(), image(signed=True, minimum=0x1a0000)):
            path.write_bytes(data)
            with self.assertRaises(ValueError):
                pack.signature_metadata(path)

    def test_missing_macos_tools_never_produce_unsigned_substitute(self):
        out = self.base / 'out'
        with patch.object(pack.shutil, 'which', return_value=None):
            with self.assertRaisesRegex(ValueError, 'Real macOS codesign'):
                pack.create_package(self.app, out, self.root)
        self.assertFalse((out / 'artifacts/trollstore/Minis-TrollStore.ipa').exists())

    def test_unsigned_packager_invokes_separate_channel(self):
        source = Path(__file__).with_name('package-ipa.py').read_text()
        self.assertIn("ART / 'Minis-unsigned.ipa'", source)
        self.assertIn("ROOT / 'scripts/ci/trollstore-package.py'", source)
        self.assertIn("'--output', str(OUT)", source)


def macos_smoke():
    """Real signatures on 12 Xcode-built iOS images, plus delivered-ZIP checks."""
    print('macOS smoke: compiling iOS arm64 main/dylib, then real nested codesign and IPA verification.', flush=True)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    with tempfile.TemporaryDirectory(prefix='minis-trollstore-real-signing-') as tmp:
        base = Path(tmp)
        root, app = fixture(base)
        executable, dylib = base / 'fixture-main', base / 'fixture-dylib'
        command = ['xcrun', '--sdk', 'iphoneos', 'clang', '-target', 'arm64-apple-ios17.0',
                   '-isysroot', sdk, '-x', 'c', '-']
        subprocess.run([*command, '-o', str(executable)], input='int main(void) { return 0; }\n', text=True, check=True)
        subprocess.run([*command, '-dynamiclib', '-Wl,-install_name,@rpath/Fixture.framework/Fixture',
                        '-o', str(dylib)], input='int fixture(void) { return 1; }\n', text=True, check=True)
        for item in pack.bundle_plan(app, root):
            binary = item['path'] / item['info']['CFBundleExecutable']
            shutil.copyfile(dylib if item['relative'].startswith('Frameworks/') else executable, binary)
            binary.chmod(0o755)
        out = base / 'out'
        (out / 'artifacts').mkdir(parents=True)
        (out / 'artifacts/BUILD-INFO.json').write_text(json.dumps({'fixture': True, 'signing': 'unsigned'}))
        (out / 'artifacts/SHA256SUMS').write_text('unsigned-channel-sentinel\n')
        manifest = pack.create_package(app, out, root)
        assert manifest['macho_count'] == 12 and manifest['verified_after_ipa_roundtrip']
        assert (out / 'artifacts/SHA256SUMS').read_text() == 'unsigned-channel-sentinel\n'
        artifact = out / 'artifacts/trollstore'
        for line in (artifact / 'SHA256SUMS').read_text().splitlines():
            digest, name = line.split('  ', 1)
            assert pack.sha256(artifact / name) == digest
        assert len(list(artifact.glob('*.ipa'))) == 1
    print('macOS REAL SIGNING SMOKE PASS (fixture only, no device execution).', flush=True)


if __name__ == '__main__':
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(PackagingTests))
    if not result.wasSuccessful():
        sys.exit(1)
    if sys.platform == 'darwin':
        macos_smoke()
    else:
        print('Pure regression PASS. Real codesign smoke requires macOS; no real-signing claim on this host.')
