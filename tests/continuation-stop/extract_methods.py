#!/usr/bin/env python3
"""Compile production methods unchanged, adapting only unavailable imports/OS."""
import pathlib
import sys
root, output = map(pathlib.Path, sys.argv[1:])
chat = root / 'src/ios/Agent/Chat'
cancel = (chat / 'AIChatViewModel+Cancel.swift').read_text()
start = cancel.index('    func cancel(resumeQueuedPrompts: Bool = true) {')
end = cancel.rindex('\n}')
method = cancel[start:end]
assert method.rstrip().endswith('}')
(output / 'ProductionCancel.swift').write_text('import Foundation\nextension AIChatViewModel {\n' + method + '\n}\n')
queue = (chat / 'AIChatViewModel+PromptQueue.swift').read_text()
# Retain the COMPLETE extension, including the real inner drain, injection,
# attachment cleanup and every await. No regex imitation of queue behavior.
start = queue.index('extension AIChatViewModel {')
(output / 'ProductionPromptQueue.swift').write_text('import Foundation\n' + queue[start:])
compact = (chat / 'AIChatViewModel+Compaction.swift').read_text()
start = compact.index('    func schedulePostCompactDrain() {')
end = compact.index('\n    /// [T-ios-compact-task-binding]', start)
(output / 'ProductionPostCompact.swift').write_text('import Foundation\nextension AIChatViewModel {\n' + compact[start:end] + '\n}\n')
rerun = (chat / 'AIChatViewModel+Rerun.swift').read_text()
start = rerun.index('extension AIChatViewModel {')
(output / 'ProductionRerun.swift').write_text('import Foundation\n' + rerun[start:])
provider = (root / 'src/ios/Providers/AgentProvider.swift').read_text()
start = provider.index('enum AgentContentPart:')
end = provider.index('\n}', start) + 2
(output / 'ProductionAgentContentPart.swift').write_text('import Foundation\n' + provider[start:end] + '\n')
print('Extracted exact production Cancel, complete PromptQueue/Rerun, post-compact drain and AgentContentPart.')
