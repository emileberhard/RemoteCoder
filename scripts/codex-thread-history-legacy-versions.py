#!/usr/bin/env python3
import argparse
import json
import sqlite3
import sys
from pathlib import Path

UPSTREAM_LIFECYCLE = (
    7,
    "9334ADB4CDA792116A47B69A19E3840AE3806B08773EF1794043FE0AA72891360ACB1A0A8431084D53C568482C5FDD20",
)
LEGACY_LIFECYCLE_CHECKSUM = "797AF21EC65D4A53AA438BB2F147203AE900F4C753B3C5CB5B8C33031BBD8AFDEBC41AFA81F327971DCD9A0508FC73A4"
PRIVATE_TO_LEGACY = (
    (
        1_000_001,
        "10932A16F620025C36FBC728435CD4A23F0CE3E4A63C73A108C9BED7DA7C2EB57CAFFDD528875CD7E5DF92FF6CA67F08",
        7,
        "thread item lifecycle",
        LEGACY_LIFECYCLE_CHECKSUM,
    ),
    (
        1_000_002,
        "F80B721E6B83601CA48FDE446D7CB8B61D7DB6FFBC47F202EDF26D28B5070FD18E78BC073D74BEC934FBF9BE222A0E04",
        8,
        "thread observation versions",
        "F80B721E6B83601CA48FDE446D7CB8B61D7DB6FFBC47F202EDF26D28B5070FD18E78BC073D74BEC934FBF9BE222A0E04",
    ),
    (
        1_000_003,
        "99F9D1AE40E67909874069780B70D60EB872758FF69332F43AB149D5EA2CDD22919999ABAC5335BB1D0C7C065AC56B67",
        9,
        "legacy projection state",
        "99F9D1AE40E67909874069780B70D60EB872758FF69332F43AB149D5EA2CDD22919999ABAC5335BB1D0C7C065AC56B67",
    ),
)
LEGACY_STARTED_AT = (
    10,
    "thread item started at",
    "C4676D588F66B243C48F5B9ECE2DCF70338475DC176D45C94DCB201BE711232C3DB6F15D62BCB16202E0C68C54DE7E69",
)


class UnexpectedHistory(RuntimeError):
    pass


def applied(connection: sqlite3.Connection) -> dict[int, str]:
    return dict(connection.execute("SELECT version, hex(checksum) FROM _sqlx_migrations"))


def restore(database: Path) -> str:
    connection = sqlite3.connect(database, isolation_level=None, timeout=30)
    try:
        connection.execute("BEGIN IMMEDIATE")
        versions = applied(connection)
        if versions.get(7) == LEGACY_LIFECYCLE_CHECKSUM:
            connection.execute("ROLLBACK")
            return "already-legacy"
        if versions.get(UPSTREAM_LIFECYCLE[0]) != UPSTREAM_LIFECYCLE[1] or any(
            versions.get(private) not in (None, checksum) for private, checksum, *_ in PRIVATE_TO_LEGACY
        ):
            raise UnexpectedHistory(f"unexpected thread history migrations: {sorted(versions)}")
        connection.execute(
            "DELETE FROM _sqlx_migrations WHERE version = ? AND hex(checksum) = ?", UPSTREAM_LIFECYCLE
        )
        for private, private_checksum, legacy, description, legacy_checksum in PRIVATE_TO_LEGACY:
            connection.execute(
                "UPDATE _sqlx_migrations SET version = ?, description = ?, checksum = ? "
                "WHERE version = ? AND hex(checksum) = ?",
                (legacy, description, bytes.fromhex(legacy_checksum), private, private_checksum),
            )
        version, description, checksum = LEGACY_STARTED_AT
        connection.execute(
            "INSERT INTO _sqlx_migrations (version, description, success, checksum, execution_time) "
            "VALUES (?, ?, TRUE, ?, 0)",
            (version, description, bytes.fromhex(checksum)),
        )
        if applied(connection).get(7) != LEGACY_LIFECYCLE_CHECKSUM:
            raise UnexpectedHistory("legacy lifecycle migration was not restored")
        connection.execute("COMMIT")
        return "restored"
    except BaseException:
        if connection.in_transaction:
            connection.execute("ROLLBACK")
        raise
    finally:
        connection.close()


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Restore pre-renumbering fork migration versions in thread_history_1.sqlite "
        "before reverse-deploying a Codex runtime that predates them."
    )
    parser.add_argument("codex_homes", nargs="+", type=Path)
    homes = parser.parse_args().codex_homes
    failed = False
    for home in homes:
        database = home / "thread_history_1.sqlite"
        try:
            status = restore(database) if database.exists() else "absent"
        except (sqlite3.Error, UnexpectedHistory) as error:
            status, failed = f"failed: {error}", True
        print(json.dumps({"database": str(database), "status": status}))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
