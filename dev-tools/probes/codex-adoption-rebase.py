import pathlib
import sqlite3
import sys
import tempfile

old, new = sys.argv[1:]
home = pathlib.Path(new)
temporary_roots = [pathlib.Path("/tmp").resolve(), pathlib.Path(tempfile.gettempdir()).resolve()]
if not home.is_absolute() or home.is_symlink() or not any(home.resolve().is_relative_to(root) for root in temporary_roots):
    raise ValueError("Expected an absolute, owned temporary clone home")
path = home / "state_5.sqlite"
if path.exists():
    with sqlite3.connect(path) as database:
        for table in ["threads", "rollout_migration_skipped_rollouts"]:
            if not database.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone():
                continue
            database.execute(
                f'UPDATE "{table}" SET rollout_path=? || substr(rollout_path,?) '
                'WHERE substr(rollout_path,1,?)=?',
                (new, len(old) + 1, len(old) + 1, old + "/"),
            )
