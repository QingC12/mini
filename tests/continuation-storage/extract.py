#!/usr/bin/env python3
"""Extract exact production bodies; substitute only app/platform surroundings."""
import pathlib
import sys

root, output = map(pathlib.Path, sys.argv[1:3])
# A combined suite may already expose its own shared UI logging adapter.
# This changes only wrapper declarations, never the extracted method text.
shared_logger = '--shared-logger' in sys.argv[3:]
def logger_wrapper(category):
    return '' if shared_logger else f'private let logger = AppLogger(category: "{category}")\n'
chat = root / 'src/ios/Agent/Chat'
output.mkdir(parents=True, exist_ok=True)
workspace = (chat / 'ContinuationWorkspace.swift').read_text()
body = workspace.split('#if !CONTINUATION_STORAGE_STANDALONE\nextension ChatStore {', 1)[1].rsplit('#endif', 1)[0]
# These are the production actor transaction boundaries, not async wrappers.
for name in ('continuationLiveStorageSessionIDs', 'continuationReconcileStorageOwnership',
             'continuationCompleteStorageDeletion', 'continuationProtectRestoredStorage'):
    start = body.index('func ' + name + '(')
    end = body.index('\n    }', start)
    function = body[start:end]
    assert 'await ' not in function and 'Task {' not in function, name
(output / 'Workspace.swift').write_text('import Foundation\nimport SQLite3\nextension ChatStore {' + body)
restore = (chat / 'ChatStore+BackupRestore.swift').read_text()
body = restore.split('extension ChatStore {', 1)[1].split('    // MARK: - Messages', 1)[0]
bind = restore[restore.index('    private func bindText('):].rsplit('\n}', 1)[0]
(output / 'Restore.swift').write_text('import Foundation\nimport SQLite3\n' + logger_wrapper('restore') + 'extension ChatStore {' + body + bind + '\n}\n')
deletion = (chat / 'ChatStore+SessionDeletion.swift').read_text()
body = deletion[deletion.index('    private func deleteSessionLocalRowsOnly('):].split('    /// Mark a session and all its child records', 1)[0]
(output / 'Deletion.swift').write_text('import Foundation\nimport SQLite3\n' + logger_wrapper('delete') + 'extension ChatStore {\n' + body + '\n    func testDeleteSession(_ id: String) { deleteSessionLocalRowsOnly(id) }\n}\n')
print('Extracted exact ChatStore restore/delete/storage bodies; no-await boundaries checked (not Swift execution).')
