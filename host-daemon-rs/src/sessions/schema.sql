CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT OR IGNORE INTO meta VALUES ('epoch', lower(hex(randomblob(16))));
INSERT OR IGNORE INTO meta VALUES ('floor', '0');
CREATE TABLE IF NOT EXISTS source (
 source_id INTEGER PRIMARY KEY, origin_host TEXT NOT NULL, provider TEXT NOT NULL,
 provider_home TEXT NOT NULL, path TEXT NOT NULL, local_path TEXT NOT NULL,
 file_identity TEXT NOT NULL, size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL,
 ingested_offset INTEGER NOT NULL, revision INTEGER NOT NULL, present INTEGER NOT NULL,
 prefix_hash TEXT NOT NULL, parser_state TEXT NOT NULL, failure TEXT,
 UNIQUE(origin_host,path));
CREATE TABLE IF NOT EXISTS session (
 session_key TEXT PRIMARY KEY, origin_host TEXT NOT NULL, provider TEXT NOT NULL,
 provider_home TEXT NOT NULL, thread_id TEXT NOT NULL, thread_id_reversed BLOB NOT NULL, cwd TEXT, title TEXT,
 started_at TEXT, last_at TEXT, parent_session_key TEXT,
 source_id INTEGER NOT NULL UNIQUE REFERENCES source);
CREATE INDEX IF NOT EXISTS session_thread ON session(thread_id,origin_host);
CREATE INDEX IF NOT EXISTS session_thread_suffix ON session(origin_host,thread_id_reversed);
CREATE TABLE IF NOT EXISTS turn (
 session_key TEXT NOT NULL REFERENCES session ON DELETE CASCADE, turn_id TEXT NOT NULL,
 seq INTEGER NOT NULL, started_at TEXT, ended_at TEXT, status TEXT, model TEXT,
 effort TEXT, job_id TEXT, tokens_in INTEGER, tokens_out INTEGER,
 PRIMARY KEY(session_key,turn_id));
CREATE TABLE IF NOT EXISTS item (
 item_key TEXT PRIMARY KEY, session_key TEXT NOT NULL REFERENCES session ON DELETE CASCADE,
 turn_id TEXT, seq INTEGER NOT NULL, at TEXT, kind TEXT NOT NULL CHECK(kind IN
 ('user','assistant','reasoning','tool_call','tool_result','system')),
 text TEXT, text_bytes INTEGER NOT NULL, source_ref TEXT NOT NULL, revision INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS item_session_seq ON item(session_key,seq);
CREATE INDEX IF NOT EXISTS item_at ON item(at);
CREATE TABLE IF NOT EXISTS tool_call (
 item_key TEXT PRIMARY KEY REFERENCES item ON DELETE CASCADE, call_id TEXT,
 tool TEXT NOT NULL, input_json TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS call_identity ON tool_call(call_id);
CREATE TABLE IF NOT EXISTS tool_result (
 item_key TEXT PRIMARY KEY REFERENCES item ON DELETE CASCADE, call_id TEXT,
 is_error INTEGER, exit_code INTEGER, duration_ms INTEGER, sidecar_ref TEXT);
CREATE INDEX IF NOT EXISTS result_identity ON tool_result(call_id);
CREATE TABLE IF NOT EXISTS skill_observation (
 item_key TEXT NOT NULL REFERENCES item ON DELETE CASCADE,
 session_key TEXT NOT NULL, skill TEXT NOT NULL,
 via TEXT NOT NULL CHECK(via IN ('skill_tool','skill_md_read')),
 outcome TEXT NOT NULL CHECK(outcome IN ('ok','failed','unknown')), at TEXT,
 PRIMARY KEY(item_key,skill,via));
CREATE INDEX IF NOT EXISTS skill_recent ON skill_observation(skill,outcome,at);
CREATE TABLE IF NOT EXISTS skill (
 name TEXT PRIMARY KEY, path TEXT NOT NULL, first_seen TEXT NOT NULL, present INTEGER NOT NULL);
CREATE VIRTUAL TABLE IF NOT EXISTS item_fts USING fts5(text,content='item',content_rowid='rowid',tokenize='trigram');
CREATE TRIGGER IF NOT EXISTS item_ai AFTER INSERT ON item BEGIN
 INSERT INTO item_fts(rowid,text) VALUES(new.rowid,new.text);
END;
CREATE TRIGGER IF NOT EXISTS item_ad AFTER DELETE ON item BEGIN
 INSERT INTO item_fts(item_fts,rowid,text) VALUES('delete',old.rowid,old.text);
END;
CREATE TRIGGER IF NOT EXISTS item_au AFTER UPDATE OF text ON item BEGIN
 INSERT INTO item_fts(item_fts,rowid,text) VALUES('delete',old.rowid,old.text);
 INSERT INTO item_fts(rowid,text) VALUES(new.rowid,new.text);
END;
CREATE TABLE IF NOT EXISTS dependency (
 source_id INTEGER NOT NULL REFERENCES source ON DELETE CASCADE, path TEXT NOT NULL,
 local_path TEXT NOT NULL, kind TEXT NOT NULL, identity TEXT, present INTEGER NOT NULL,
 PRIMARY KEY(source_id,path));
CREATE TABLE IF NOT EXISTS change (
 seq INTEGER PRIMARY KEY AUTOINCREMENT, entity TEXT NOT NULL, key TEXT NOT NULL,
 op TEXT NOT NULL CHECK(op IN ('upsert','tombstone')), revision INTEGER NOT NULL,
 committed_at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%fZ','now')));
CREATE INDEX IF NOT EXISTS change_age ON change(committed_at);
CREATE TABLE IF NOT EXISTS coverage (
 origin_host TEXT PRIMARY KEY, mode TEXT NOT NULL CHECK(mode IN ('local','mirror')),
 indexed_through TEXT, complete_through TEXT, stale_reason TEXT,
 parse_failures INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS mirror_file (
 origin_host TEXT NOT NULL, path TEXT NOT NULL, identity TEXT NOT NULL,
 size INTEGER NOT NULL, received INTEGER NOT NULL, local_path TEXT NOT NULL,
 PRIMARY KEY(origin_host,path));

CREATE INDEX IF NOT EXISTS dependency_path ON dependency(path,source_id);
CREATE INDEX IF NOT EXISTS source_failures ON source(origin_host) WHERE failure IS NOT NULL;
CREATE INDEX IF NOT EXISTS dependency_missing ON dependency(source_id) WHERE present=0;
