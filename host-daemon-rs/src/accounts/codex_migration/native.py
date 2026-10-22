import datetime
import fcntl
import hashlib
import json
import os
import pathlib
import sqlite3
import stat
import sys
import urllib.parse
import uuid
from contextlib import contextmanager

TABLES = {
    "state_5.sqlite": [
        "thread_sections",
        "projects",
        "project_roots",
        "project_idempotency_keys",
        "threads",
        "thread_dynamic_tools",
        "thread_spawn_edges",
        "thread_attachments",
    ],
    "thread_history_1.sqlite": [
        "thread_turns",
        "thread_items",
        "thread_history_projection_state",
        "thread_realtime_items",
        "thread_item_versions",
        "thread_turn_versions",
    ],
    "queue_1.sqlite": ["queued_items"],
    "goals_1.sqlite": ["thread_goals", "thread_goal_continuation_deferrals"],
    "memories_1.sqlite": ["stage1_outputs", "jobs"],
    "memories_v2_1.sqlite": ["stage1_outputs", "jobs"],
}


def digest(value):
    return hashlib.sha256(json.dumps(value, separators=(",", ":")).encode()).hexdigest()


@contextmanager
def connect(path, readonly):
    for part in [path, *path.parents]:
        if part.is_symlink():
            raise ValueError(f"Codex adoption refuses symlink {part}")
    uri = (
        "file:"
        + urllib.parse.quote(str(path))
        + ("?mode=ro" if readonly else "?mode=rw")
    )
    connection = sqlite3.connect(uri, uri=True, timeout=30)
    try:
        connection.execute("PRAGMA foreign_keys=ON")
        yield connection
    finally:
        connection.close()


def validate(connection, expected, name):
    schema = connection.execute(
        "SELECT type,name,tbl_name,sql FROM sqlite_master "
        "WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name"
    ).fetchall()
    migrations = connection.execute(
        "SELECT version,hex(checksum),success FROM _sqlx_migrations ORDER BY version"
    ).fetchall()
    accepted = (
        expected["schema"]
        if isinstance(expected["schema"], list)
        else [expected["schema"]]
    )
    if digest(schema) not in accepted or digest(migrations) != expected["migrations"]:
        raise ValueError(
            f"Unsupported pinned Codex schema or migration checksums: {name}"
        )


def columns(connection, table):
    return connection.execute(f'PRAGMA table_info("{table}")').fetchall()


def remap(value, source, target):
    if isinstance(value, str) and value.startswith(str(source) + "/"):
        return str(target) + value[len(str(source)) :]
    return value


def same_rollout(left, right):
    if not left.exists() or not right.exists():
        return False
    with left.open("rb") as a, right.open("rb") as b:
        while True:
            x, y = a.read(65536), b.read(65536)
            if x != y:
                return False
            if not x:
                return True


def thread_plan(source, target):
    path = source / "state_5.sqlite"
    if not path.exists():
        return [], [], []
    with connect(path, True) as incoming:
        rows = incoming.execute(
            "SELECT id,rollout_path FROM threads ORDER BY id"
        ).fetchall()
    existing = {}
    if (target / "state_5.sqlite").exists():
        with connect(target / "state_5.sqlite", True) as host:
            existing = dict(host.execute("SELECT id,rollout_path FROM threads"))
    replace = []
    for thread, rollout in rows:
        path = pathlib.Path(rollout)
        if not path.is_relative_to(source):
            raise ValueError(
                f"Codex thread {thread} selects a rollout outside its source home"
            )
        if not path.is_file():
            raise ValueError(f"Codex thread {thread} has no rollout: {path}")
        previous = existing.get(thread)
        if previous is not None:
            if pathlib.Path(previous).exists() and not same_rollout(
                path, pathlib.Path(previous)
            ):
                raise ValueError(
                    f"Codex thread {thread} has divergent native histories; reconcile originals"
                )
            replace.append(thread)
    return [row[0] for row in rows], replace, sorted(existing)


def initialize(source, target):
    temporary = target.with_suffix(target.suffix + ".adopting")
    temporary.unlink(missing_ok=True)
    connection = sqlite3.connect(temporary)
    try:
        objects = source.execute(
            "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' "
            "ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'index' THEN 1 ELSE 2 END,name"
        ).fetchall()
        for (sql,) in objects:
            connection.execute(sql)
        names = [r[1] for r in columns(source, "_sqlx_migrations")]
        placeholders = ",".join("?" for _ in names)
        connection.executemany(
            f"INSERT INTO _sqlx_migrations VALUES ({placeholders})",
            source.execute("SELECT * FROM _sqlx_migrations"),
        )
        if source.execute(
            "SELECT 1 FROM sqlite_master WHERE name='backfill_state'"
        ).fetchone():
            placeholders = ",".join("?" for _ in columns(source, "backfill_state"))
            connection.executemany(
                f"INSERT INTO backfill_state VALUES ({placeholders})",
                source.execute("SELECT * FROM backfill_state"),
            )
        connection.commit()
    finally:
        connection.close()
    with temporary.open("rb") as file:
        os.fsync(file.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, target)


def adopt_database(name, source, target, expected, threads, replace):
    source_path, target_path = source / name, target / name
    if not source_path.exists():
        return 0
    with connect(source_path, True) as incoming:
        validate(incoming, expected, source_path)
        if not target_path.exists():
            initialize(incoming, target_path)
        with connect(target_path, False) as host:
            validate(host, expected, target_path)
            host.execute("PRAGMA synchronous=FULL")
            host.execute("BEGIN IMMEDIATE")
            count = 0
            for table in TABLES[name]:
                information = columns(incoming, table)
                names = [row[1] for row in information]
                selected = ",".join(f'"{name}"' for name in names)
                keys = [
                    row[1]
                    for row in sorted(information, key=lambda row: row[5])
                    if row[5]
                ]
                key_indexes = [names.index(key) for key in keys]
                where = " AND ".join(f'"{key}" IS ?' for key in keys)
                thread_column = {
                    "threads": "id",
                    "thread_spawn_edges": "child_thread_id",
                    "jobs": "job_key",
                }.get(table, "thread_id")
                if thread_column in names:
                    for thread in replace:
                        host.execute(
                            f'DELETE FROM "{table}" WHERE "{thread_column}"=?',
                            (thread,),
                        )
                for row in incoming.execute(f'SELECT * FROM "{table}"'):
                    if table == "jobs" and row[names.index("job_key")] not in threads:
                        continue
                    row = tuple(
                        remap(value, source, target)
                        if column in {"rollout_path", "path"}
                        else value
                        for column, value in zip(names, row)
                    )
                    values = tuple(row[index] for index in key_indexes)
                    previous = host.execute(
                        f'SELECT {selected} FROM "{table}" WHERE {where}', values
                    ).fetchone()
                    if previous is not None:
                        if previous != row:
                            raise ValueError(
                                f"Conflicting Codex {name}/{table} key {values}; originals preserved"
                            )
                        continue
                    host.execute(
                        f'INSERT INTO "{table}" ({selected}) VALUES ({",".join("?" for _ in row)})',
                        row,
                    )
                    count += 1
            host.commit()
            return count


def rollout_files(directory):
    with os.scandir(directory) as entries:
        for entry in entries:
            if entry.is_symlink():
                raise ValueError(f"Codex adoption refuses symlink {entry.path}")
            if entry.is_dir(follow_symlinks=False):
                yield from rollout_files(entry.path)
            elif entry.is_file(follow_symlinks=False):
                yield pathlib.Path(entry.path)
            else:
                raise ValueError(f"Codex adoption refuses nonregular entry {entry.path}")


def read_scope(home):
    threads = set()
    if (home / "state_5.sqlite").exists():
        with connect(home / "state_5.sqlite", True) as database:
            threads.update(row[0] for row in database.execute("SELECT id FROM threads"))
    for directory in [home / "sessions", home / "archived_sessions"]:
        try:
            metadata = os.stat(directory, follow_symlinks=False)
        except FileNotFoundError:
            continue
        if not stat.S_ISDIR(metadata.st_mode):
            raise ValueError(f"Codex adoption refuses non-directory rollout root {directory}")
        for path in rollout_files(directory):
            name = path.name.removesuffix(".zst")
            if not name.startswith("rollout-") or not name.endswith(".jsonl"):
                continue
            core = name[8:-6]
            try:
                datetime.datetime.strptime(core[:19], "%Y-%m-%dT%H-%M-%S")
                if core[19:20] != "-":
                    continue
                identities = core[20:].split("_")
                if len(identities) not in {1, 2}:
                    continue
                parsed = [uuid.UUID(identity) for identity in identities]
            except ValueError:
                continue
            threads.add(str(parsed[0]))
    return sorted(threads)


def main(request):
    source, target = pathlib.Path(request["source"]), pathlib.Path(request["target"])
    for name, expected in request["schema"].items():
        for path in [source / name, target / name]:
            if path.exists():
                with connect(path, True) as connection:
                    validate(connection, expected, path)
    if request["mode"] == "scope":
        return read_scope(target)
    if request["mode"] == "plan":
        threads, replace, host_threads = thread_plan(source, target)
        return {"threads": threads, "replaced": replace, "host_threads": host_threads}
    threads, replace = request["threads"], request["replaced"]
    counts = {}
    for name, expected in request["schema"].items():
        counts[name] = adopt_database(
            name,
            source,
            target,
            expected,
            set(threads),
            replace,
        )
    return {"threads": threads, "replaced": replace, "rows": counts}


if __name__ == "__main__":
    try:
        request = json.load(sys.stdin)
        lock = pathlib.Path(request["lock"])
        with os.fdopen(
            os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600), "w"
        ) as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            print(json.dumps(main(request)))
    except (OSError, ValueError, sqlite3.Error) as error:
        print(f"Codex adoption failed: {error}", file=sys.stderr)
        sys.exit(1)
