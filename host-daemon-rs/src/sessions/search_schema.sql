CREATE TABLE search_document (id INTEGER PRIMARY KEY, session_key TEXT NOT NULL UNIQUE);
CREATE TABLE search_member (session_key TEXT PRIMARY KEY, root_key TEXT NOT NULL);
CREATE INDEX search_root ON search_member(root_key,session_key);
CREATE TABLE search_dirty (session_key TEXT PRIMARY KEY);
CREATE TABLE search_item (id INTEGER PRIMARY KEY, scope TEXT NOT NULL);
CREATE VIEW search_item_content AS SELECT i.rowid,i.text,m.scope FROM item i JOIN search_item m ON m.id=i.rowid;
CREATE VIRTUAL TABLE conversation_fts USING fts5(title,typed,other,cwd,content='',contentless_delete=1,tokenize='unicode61 remove_diacritics 2',prefix='2 3 4');
CREATE VIRTUAL TABLE item_word_fts USING fts5(text,scope,content='search_item_content',content_rowid='rowid',tokenize='unicode61 remove_diacritics 2',prefix='2 3 4');
CREATE TRIGGER search_item_insert AFTER INSERT ON item BEGIN
 INSERT INTO search_item VALUES(new.rowid,(SELECT 's'||source_id FROM session WHERE session_key=new.session_key));
 INSERT INTO item_word_fts(rowid,text,scope) SELECT new.rowid,new.text,scope FROM search_item WHERE id=new.rowid;
 INSERT INTO search_dirty SELECT new.session_key WHERE NOT EXISTS(SELECT 1 FROM search_dirty WHERE session_key=new.session_key);
END;
CREATE TRIGGER search_item_delete BEFORE DELETE ON item BEGIN
 INSERT INTO item_word_fts(item_word_fts,rowid,text,scope) SELECT 'delete',old.rowid,old.text,scope FROM search_item WHERE id=old.rowid;
 DELETE FROM search_item WHERE id=old.rowid;
 INSERT INTO search_dirty SELECT old.session_key WHERE NOT EXISTS(SELECT 1 FROM search_dirty WHERE session_key=old.session_key);
END;
CREATE TRIGGER search_item_update BEFORE UPDATE OF text ON item BEGIN
 INSERT INTO item_word_fts(item_word_fts,rowid,text,scope) SELECT 'delete',old.rowid,old.text,scope FROM search_item WHERE id=old.rowid;
 INSERT INTO item_word_fts(rowid,text,scope) SELECT new.rowid,new.text,scope FROM search_item WHERE id=new.rowid;
 INSERT INTO search_dirty SELECT new.session_key WHERE NOT EXISTS(SELECT 1 FROM search_dirty WHERE session_key=new.session_key);
END;
CREATE TRIGGER search_session_insert AFTER INSERT ON session BEGIN
 INSERT INTO search_dirty SELECT new.session_key WHERE NOT EXISTS(SELECT 1 FROM search_dirty WHERE session_key=new.session_key);
 INSERT INTO search_dirty SELECT session_key FROM session WHERE session_key NOT IN (SELECT session_key FROM search_dirty) AND ( (delegated_parent_known=0 AND parent_session_key=new.session_key) OR (delegated_parent_known=1 AND delegated_parent_session_key=new.session_key));
END;
CREATE TRIGGER search_session_update AFTER UPDATE OF title,cwd,last_at,parent_session_key,delegated_parent_known,delegated_parent_session_key ON session
WHEN old.title IS NOT new.title OR old.cwd IS NOT new.cwd OR old.last_at IS NOT new.last_at OR old.parent_session_key IS NOT new.parent_session_key OR old.delegated_parent_known IS NOT new.delegated_parent_known OR old.delegated_parent_session_key IS NOT new.delegated_parent_session_key BEGIN
 INSERT INTO search_dirty SELECT new.session_key WHERE NOT EXISTS(SELECT 1 FROM search_dirty WHERE session_key=new.session_key);
END;
CREATE TRIGGER search_session_delete BEFORE DELETE ON session BEGIN
 INSERT INTO search_dirty SELECT old.session_key WHERE NOT EXISTS(SELECT 1 FROM search_dirty WHERE session_key=old.session_key);
 INSERT INTO search_dirty SELECT session_key FROM search_member WHERE root_key=old.session_key AND session_key NOT IN (SELECT session_key FROM search_dirty);
END;
INSERT OR IGNORE INTO search_dirty SELECT session_key FROM session;
CREATE TRIGGER search_source_update AFTER UPDATE OF present ON source WHEN old.present IS NOT new.present BEGIN
 INSERT INTO search_dirty SELECT session_key FROM session WHERE source_id=new.source_id AND session_key NOT IN (SELECT session_key FROM search_dirty);
END;
