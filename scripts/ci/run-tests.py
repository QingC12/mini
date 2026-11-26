#!/usr/bin/env python3
"""Execute real Swift programs; a missing compiler or exit 77 is a CI failure."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
# A compiler invoked by its absolute toolchain path does not always infer the
# host SDK (unlike xcrun). Never let the iOS device SDK leak into host tests.
if sys.platform == 'darwin' and shutil.which('xcrun'):
    os.environ['SDKROOT'] = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    os.environ['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
    print('Host-test SDK: ' + os.environ['SDKROOT'], flush=True)
OUT = Path(os.environ.get('CI_OUTPUT_DIR', ROOT / 'build/ci'))
(OUT / 'logs').mkdir(parents=True, exist_ok=True)
(OUT / 'reports').mkdir(parents=True, exist_ok=True)
# Parse the feature files even if a later push changes only a test/document.
feature_paths = [
    'Agent/Chat/AIChatViewModel+AgentLoop.swift',
    'Agent/Chat/AIChatViewModel+PromptQueue.swift',
    'Agent/Chat/ChatLifecycleSupport.swift',
    'Agent/Chat/ChatStore+Continuation.swift',
    'Agent/Chat/ContinuationCoordinator.swift',
    'Agent/Chat/ContinuationPolicy.swift',
    'Agent/Chat/ContinuationRecord.swift',
    'Agent/Chat/ContinuationStorageBindings.swift',
    'Agent/Chat/ContinuationWorkspace.swift',
    'Agent/Chat/ContinuationQueueFence.swift',
    'Agent/Chat/AIChatViewModel+Cancel.swift',
    'Agent/Chat/AIChatViewModel+Send.swift',
    'Agent/Chat/AIChatViewModel+ProgrammaticPrompt.swift',
    'Agent/Chat/AIChatViewModel+Compaction.swift',
    'Agent/Chat/ChatStore+BackupRestore.swift',
    'Agent/Chat/ChatStore+Media.swift',
    'Agent/Chat/ChatStore+SessionDeletion.swift',
    'Agent/Chat/SessionDeletionSupport.swift',
    'Agent/ISH/MinisFsRouter.swift',
    'Views/Chat/NativeContinuationBanner.swift',
    'Providers/ConversationTurnLimit.swift',
    'Providers/LLMError.swift',
    'Providers/OpenAI/OpenAIAgentProvider.swift',
    'Providers/OpenAI/OpenAIProvider.swift',
    'Shared/Config/ConfigRegistry+Builtins.swift',
    'Views/Settings/AppearanceSettingsView.swift',
]
paths = {str(Path('src/ios') / p) for p in feature_paths}
# Also cover newly modified production Swift files from this commit. Root
# commits fall back to all files in that commit; tests themselves are excluded.
for command in (['git', 'diff', '--name-only', 'HEAD^', 'HEAD'],
                ['git', 'show', '--pretty=format:', '--name-only', 'HEAD']):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode == 0:
        paths.update(result.stdout.splitlines())
        break
paths = sorted(p for p in paths if p.startswith('src/ios/') and p.endswith('.swift')
               and 'Tests/' not in p and (ROOT / p).is_file())
(OUT / 'reports/parsed-production-swift.json').write_text(json.dumps(paths, indent=2) + '\n')
swiftc = os.environ.get('SWIFTC') or shutil.which('swiftc')
if not swiftc and shutil.which('xcrun'):
    swiftc = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
swift = str(Path(swiftc).with_name('swift')) if swiftc else 'swift'
cases = [
    ('native-continuation-policy', ['sh', 'tests/run_native_continuation_tests.sh']),
    ('conversation-turn-limit', [swift, 'src/ios/MinisTests/Standalone/ConversationTurnLimitTests.swift']),
    ('production-swift-syntax-only', [swiftc or 'swiftc', '-frontend', '-parse', '-swift-version', '6', *paths]),
]
for name, path in (
    ('continuation-storage', 'tests/run_continuation_storage_tests.sh'),
    ('continuation-reliability', 'tests/run_continuation_reliability_tests.sh'),
    ('continuation-router', 'tests/run_continuation_router_tests.sh'),
    ('continuation-stop', 'tests/run_continuation_stop_tests.sh'),
):
    # Required gates in both workflows: a deleted/missing runner must fail,
    # never silently lower the suite count and let an IPA through.
    cases.append((name, ['sh', path]))
suite = ET.Element('testsuite', name='Minis standalone Swift', tests=str(len(cases)))
failures = 0
summary = []
for name, command in cases:
    started = time.monotonic()
    logfile = OUT / 'logs' / (name + '.log')
    print('+ ' + ' '.join(command), flush=True)
    with logfile.open('w') as log:
        try:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       text=True, env={**os.environ, **({'SWIFTC': swiftc} if swiftc else {})})
            for line in process.stdout:
                print(line, end='', flush=True)
                log.write(line)
            code = process.wait()
        except OSError as error:
            code = 127
            log.write(str(error) + '\n')
            print(error, file=sys.stderr)
    seconds = time.monotonic() - started
    case = ET.SubElement(suite, 'testcase', classname='NativeContinuation', name=name,
                         time=f'{seconds:.3f}')
    text = logfile.read_text(errors='replace')
    ET.SubElement(case, 'system-out').text = text[-200000:]
    if code:
        failures += 1
        ET.SubElement(case, 'failure', message=f'exit {code}; SKIP is not PASS').text = text[-200000:]
    summary.append({'name': name, 'exit_code': code, 'seconds': seconds})
suite.set('failures', str(failures))
ET.ElementTree(suite).write(OUT / 'reports/standalone-tests.junit.xml', encoding='utf-8', xml_declaration=True)
(OUT / 'reports/standalone-tests.json').write_text(json.dumps(summary, indent=2) + '\n')
print(f'Real Swift checks: {len(cases) - failures}/{len(cases)} passed; syntax parse is NOT app type-checking.')
sys.exit(1 if failures else 0)
