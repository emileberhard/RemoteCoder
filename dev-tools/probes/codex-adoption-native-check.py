import hashlib
import json
import pathlib
import sqlite3
import sys
import urllib.parse

source, target = [pathlib.Path(value).resolve(strict=True) for value in sys.argv[1:]]
counts = {}
for database in ["thread_history_1.sqlite", "queue_1.sqlite", "goals_1.sqlite"]:
    if not (source / database).exists():
        continue
    path = urllib.parse.quote(str(target / database))
    incoming = urllib.parse.quote(str(source / database))
    with sqlite3.connect(f"file:{path}?mode=ro", uri=True) as connection:
        connection.execute("ATTACH DATABASE ? AS incoming", (f"file:{incoming}?mode=ro",))
        tables = connection.execute(
            "SELECT name FROM incoming.sqlite_master WHERE type='table' AND name NOT LIKE '_sqlx%' AND name NOT LIKE 'sqlite_%' AND name NOT IN ('thread_history_projection_state','queued_thread_revisions')"
        ).fetchall()
        for (table,) in tables:
            quoted = '"' + table.replace('"', '""') + '"'
            columns = [row[1] for row in connection.execute(f"PRAGMA incoming.table_info({quoted})")]
            names = ",".join('"' + column.replace('"', '""') + '"' for column in columns)
            different = connection.execute(
                f"SELECT count(*) FROM (SELECT {names} FROM incoming.{quoted} EXCEPT SELECT {names} FROM main.{quoted})"
            ).fetchone()[0]
            assert different == 0, f"{database}/{table}: {different} native source rows changed or missing"
            counts[f"{database}/{table}"] = connection.execute(f"SELECT count(*) FROM incoming.{quoted}").fetchone()[0]
def digest(path):
    result = hashlib.sha256()
    with open(path, "rb") as stream:
        while block := stream.read(1048576):
            result.update(block)
    return result.digest()

with sqlite3.connect(f"file:{urllib.parse.quote(str(source / 'state_5.sqlite'))}?mode=ro", uri=True) as incoming:
    source_paths = incoming.execute("SELECT id,rollout_path FROM threads").fetchall()
with sqlite3.connect(f"file:{urllib.parse.quote(str(target / 'state_5.sqlite'))}?mode=ro", uri=True) as adopted:
    target_paths = dict(adopted.execute("SELECT id,rollout_path FROM threads"))
for thread, path in source_paths:
    assert digest(path) == digest(target_paths[thread]), f"Native rollout changed: {thread}"
print(json.dumps({"passed": True, "nativeSourceRows": counts, "byteIdenticalNativeRollouts": len(source_paths)}))
