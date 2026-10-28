CREATE VIEW IF NOT EXISTS v_tool_calls AS
 SELECT i.item_key,i.session_key,i.at,c.call_id,c.tool,c.input_json,
 r.is_error,r.exit_code,r.duration_ms,r.sidecar_ref
 FROM tool_call c JOIN item i USING(item_key)
 LEFT JOIN tool_result r ON r.item_key=(
 SELECT ri.item_key FROM tool_result ri JOIN item ii ON ii.item_key=ri.item_key
 WHERE ri.call_id=c.call_id AND ii.session_key=i.session_key ORDER BY ii.seq DESC LIMIT 1);
CREATE VIEW IF NOT EXISTS v_skill_use AS SELECT * FROM skill_observation;
CREATE VIEW IF NOT EXISTS v_sessions AS
 SELECT s.*,src.present AS source_present,src.failure AS source_failure
 FROM session s JOIN source src USING(source_id);
