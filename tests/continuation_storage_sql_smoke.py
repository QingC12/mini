#!/usr/bin/env python3
"""SQLite-template smoke only; NOT a Swift/iOS compile or app integration test."""
import pathlib
import re
import sqlite3

root = pathlib.Path(__file__).resolve().parents[1]
settings = (root / 'src/ios/Agent/Chat/ContinuationSettings.swift').read_text()
workspace = (root / 'src/ios/Agent/Chat/ContinuationWorkspace.swift').read_text()
assert 'await db.bulkReplace' not in settings
assert 'store.configRevision == revision' in settings
assert 'isBooted' not in workspace
assert 'copyItem' not in workspace
assert 'ContinuationStorageBindings' in workspace
sqls = re.findall(r'let sql = "(INSERT OR REPLACE INTO .+?VALUES \(\?, \?, \?\))"', settings)
assert len(sqls) == 2, sqls
conn = sqlite3.connect(':memory:')
conn.executescript('''
CREATE TABLE provider_instances (id TEXT PRIMARY KEY, sentinel TEXT);
INSERT INTO provider_instances VALUES ('existing-provider', 'do-not-touch');
CREATE TABLE provider_session_bindings (session_id TEXT PRIMARY KEY, binding_json TEXT, updated_at REAL);
CREATE TABLE provider_session_inference_configs (session_id TEXT PRIMARY KEY, config_json TEXT, updated_at REAL);
CREATE TABLE session_skill_overrides (session_id TEXT, skill_id TEXT, is_enabled INTEGER, PRIMARY KEY(session_id, skill_id));
CREATE TABLE mcp_session_overrides (session_id TEXT, server_id TEXT, is_enabled INTEGER, PRIMARY KEY(session_id, server_id));
CREATE TABLE sessions (id TEXT PRIMARY KEY, parent_session_id TEXT, remote_origin_device_id TEXT, memory_enabled INTEGER);
CREATE TABLE messages (session_id TEXT);
INSERT INTO sessions VALUES ('source', NULL, NULL, 0);
INSERT INTO sessions VALUES ('target', NULL, NULL, 1);
INSERT INTO provider_session_bindings VALUES ('unrelated-chat', 'retain-user-edits', 1);
''')
checks = 0
for template in sqls:
    if r'\(idColumn)' in template:
        rows = [('session_skill_overrides', 'skill_id', 0), ('mcp_session_overrides', 'server_id', 1)]
        column_key = r'\(idColumn)'
    else:
        rows = [('provider_session_bindings', 'binding_json', '{"actual":"entry"}'), ('provider_session_inference_configs', 'config_json', '{"thinkingLevel":"max"}')]
        column_key = r'\(column)'
    for table, column, value in rows:
        sql = template.replace(r'\(table)', table).replace(column_key, column)
        arguments = ('target', 'item', value) if column_key == r'\(idColumn)' else ('target', value, 10)
        conn.execute(sql, arguments)
        conn.execute(sql, arguments)  # idempotent retry uses the same primary key
        assert conn.execute(f'SELECT count(*) FROM {table} WHERE session_id=?', ('target',)).fetchone()[0] == 1
        checks += 1
query = re.search(r'let query = "(SELECT id, parent_session_id.+?)"', workspace).group(1)
assert len(conn.execute(query, ('source', 'target')).fetchall()) == 2
checks += 1
update = re.search(r'sqlite3_prepare_v2\(db, "(UPDATE sessions SET memory_enabled.+?)"', settings).group(1)
conn.execute(update, (0, 'target'))
assert conn.execute('SELECT memory_enabled FROM sessions WHERE id="target"').fetchone()[0] == 0
assert conn.execute('SELECT sentinel FROM provider_instances').fetchone()[0] == 'do-not-touch'
assert conn.execute('SELECT binding_json FROM provider_session_bindings WHERE session_id="unrelated-chat"').fetchone()[0] == 'retain-user-edits'
checks += 3
print(f'PASS: {checks} SQLite-template smoke assertions + source safety guards (not Swift compilation).')
