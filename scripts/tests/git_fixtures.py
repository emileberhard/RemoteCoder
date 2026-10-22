import subprocess


def empty_commit(repository, message):
    subprocess.run(
        [
            "git", "-C", str(repository),
            "-c", "user.name=Fixture",
            "-c", "user.email=fixture@example.test",
            "commit", "-q", "--allow-empty", "-m", message,
        ],
        check=True,
    )
    return subprocess.check_output(
        ["git", "-C", str(repository), "rev-parse", "HEAD"], text=True
    ).strip()


def init_repository(repository):
    subprocess.run(["git", "init", "-q", str(repository)], check=True)
    return empty_commit(repository, "fixture")


def point_origin_main_at_head(repository):
    subprocess.run(
        ["git", "-C", str(repository), "update-ref", "refs/remotes/origin/main", "HEAD"],
        check=True,
    )
