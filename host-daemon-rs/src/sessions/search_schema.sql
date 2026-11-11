CREATE TABLE search_document (
 id INTEGER PRIMARY KEY, session_key TEXT NOT NULL UNIQUE,
 refreshed_ms INTEGER NOT NULL, cooldown_ms INTEGER NOT NULL, capped INTEGER NOT NULL);
CREATE INDEX search_document_capped ON search_document(capped) WHERE capped=1;
CREATE TABLE search_member (session_key TEXT PRIMARY KEY, root_key TEXT NOT NULL);
CREATE INDEX search_root ON search_member(root_key,session_key);
CREATE TABLE search_dirty (
 session_key TEXT PRIMARY KEY, relink INTEGER NOT NULL DEFAULT 0, backfill INTEGER NOT NULL DEFAULT 0);
CREATE INDEX search_backfill ON search_dirty(backfill) WHERE backfill=1;
CREATE TABLE search_item (
 id INTEGER PRIMARY KEY, scope TEXT NOT NULL, document_column TEXT NOT NULL, text_bytes INTEGER NOT NULL);
CREATE INDEX search_item_scope ON search_item(scope,document_column,id DESC,text_bytes);
CREATE VIEW searchable_item AS
 SELECT i.rowid, i.session_key, i.text, i.text_bytes, 's'||s.source_id AS scope,
        CASE i.kind WHEN 'user' THEN 'typed' ELSE 'assistant' END AS document_column
 FROM item i JOIN session s USING(session_key)
 WHERE i.kind IN ('user','assistant') AND i.text_bytes>0;
CREATE VIEW search_item_content AS
 SELECT i.rowid,i.text,m.scope FROM item i JOIN search_item m ON m.id=i.rowid;
CREATE VIRTUAL TABLE conversation_fts USING fts5(title,typed,assistant,cwd,content='',contentless_delete=1,tokenize='unicode61 remove_diacritics 2',prefix='2 3 4');
CREATE VIRTUAL TABLE item_word_fts USING fts5(text,scope,content='search_item_content',content_rowid='rowid',tokenize='unicode61 remove_diacritics 2',prefix='2 3 4');
CREATE TRIGGER search_item_insert AFTER INSERT ON item
WHEN EXISTS(SELECT 1 FROM searchable_item WHERE rowid=new.rowid) BEGIN
 INSERT INTO search_item SELECT rowid,scope,document_column,text_bytes FROM searchable_item WHERE rowid=new.rowid;
 INSERT INTO item_word_fts(rowid,text,scope) SELECT new.rowid,new.text,scope FROM search_item WHERE id=new.rowid;
 INSERT INTO search_dirty(session_key) SELECT new.session_key WHERE NOT EXISTS(SELECT 1 FROM search_dirty WHERE session_key=new.session_key);
END;
CREATE TRIGGER search_item_delete BEFORE DELETE ON item
WHEN EXISTS(SELECT 1 FROM search_item WHERE id=old.rowid) BEGIN
 INSERT INTO item_word_fts(item_word_fts,rowid,text,scope) SELECT 'delete',old.rowid,old.text,scope FROM search_item WHERE id=old.rowid;
 DELETE FROM search_item WHERE id=old.rowid;
 INSERT INTO search_dirty(session_key) SELECT old.session_key WHERE NOT EXISTS(SELECT 1 FROM search_dirty WHERE session_key=old.session_key);
END;
CREATE TRIGGER search_item_update_before BEFORE UPDATE OF text,kind,text_bytes ON item
WHEN EXISTS(SELECT 1 FROM search_item WHERE id=old.rowid) BEGIN
 INSERT INTO item_word_fts(item_word_fts,rowid,text,scope) SELECT 'delete',old.rowid,old.text,scope FROM search_item WHERE id=old.rowid;
 DELETE FROM search_item WHERE id=old.rowid;
 INSERT INTO search_dirty(session_key) SELECT old.session_key WHERE NOT EXISTS(SELECT 1 FROM search_dirty WHERE session_key=old.session_key);
END;
CREATE TRIGGER search_item_update_after AFTER UPDATE OF text,kind,text_bytes ON item
WHEN EXISTS(SELECT 1 FROM searchable_item WHERE rowid=new.rowid) BEGIN
 INSERT INTO search_item SELECT rowid,scope,document_column,text_bytes FROM searchable_item WHERE rowid=new.rowid;
 INSERT INTO item_word_fts(rowid,text,scope) SELECT new.rowid,new.text,scope FROM search_item WHERE id=new.rowid;
 INSERT INTO search_dirty(session_key) SELECT new.session_key WHERE NOT EXISTS(SELECT 1 FROM search_dirty WHERE session_key=new.session_key);
END;
CREATE TRIGGER search_session_insert AFTER INSERT ON session BEGIN
 INSERT INTO search_dirty(session_key,relink) VALUES(new.session_key,1)
 ON CONFLICT(session_key) DO UPDATE SET relink=1;
END;
CREATE TRIGGER search_session_update AFTER UPDATE OF title,cwd,parent_session_key,delegated_parent_known,delegated_parent_session_key ON session
WHEN old.title IS NOT new.title OR old.cwd IS NOT new.cwd OR old.parent_session_key IS NOT new.parent_session_key OR old.delegated_parent_known IS NOT new.delegated_parent_known OR old.delegated_parent_session_key IS NOT new.delegated_parent_session_key BEGIN
 INSERT INTO search_dirty(session_key,relink)
 VALUES(new.session_key,old.parent_session_key IS NOT new.parent_session_key OR old.delegated_parent_known IS NOT new.delegated_parent_known OR old.delegated_parent_session_key IS NOT new.delegated_parent_session_key)
 ON CONFLICT(session_key) DO UPDATE SET relink=max(relink,excluded.relink);
END;
CREATE VIEW search_ancestry AS
 SELECT session_key,parent_session_key AS parent FROM session WHERE delegated_parent_known=0 AND parent_session_key IS NOT NULL
 UNION ALL
 SELECT session_key,delegated_parent_session_key FROM session WHERE delegated_parent_known=1 AND delegated_parent_session_key IS NOT NULL;
CREATE TRIGGER search_session_delete BEFORE DELETE ON session BEGIN
 INSERT INTO search_dirty(session_key,relink) VALUES(old.session_key,1)
 ON CONFLICT(session_key) DO UPDATE SET relink=1;
 INSERT INTO search_dirty(session_key,relink) SELECT session_key,1 FROM search_ancestry WHERE parent=old.session_key
 ON CONFLICT(session_key) DO UPDATE SET relink=1;
END;
CREATE TRIGGER search_source_update AFTER UPDATE OF present ON source WHEN old.present IS NOT new.present BEGIN
 INSERT INTO search_dirty(session_key,relink) SELECT session_key,1 FROM session WHERE source_id=new.source_id
 UNION ALL SELECT a.session_key,1 FROM search_ancestry a JOIN session s ON s.session_key=a.parent WHERE s.source_id=new.source_id
 ON CONFLICT(session_key) DO UPDATE SET relink=1;
END;
INSERT INTO search_dirty SELECT session_key,1,1 FROM session;
