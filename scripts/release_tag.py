import argparse
import re
import subprocess
from pathlib import Path


VERSION = r"(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})"


def git(root: Path, *arguments: str) -> str:
    return subprocess.check_output(["git", *arguments], cwd=root, text=True).strip()


def require_main_ancestor(root: Path, commit: str) -> None:
    arguments = ["fetch", "--no-tags", "origin", "+refs/heads/main:refs/remotes/origin/main"]
    if git(root, "rev-parse", "--is-shallow-repository") == "true":
        arguments.append("--unshallow")
    git(root, *arguments)
    result = subprocess.run(["git", "merge-base", "--is-ancestor", commit, "refs/remotes/origin/main"], cwd=root, check=False)
    if result.returncode == 1:
        raise ValueError(f"Release commit {commit} is not on origin/main")
    result.check_returncode()


def validate(root: Path, version: str, commit: str) -> None:
    if re.fullmatch(VERSION, version) is None:
        raise ValueError("Release tags must be X.Y.Z, each part 0-999, without leading zeros")
    if re.fullmatch(r"[0-9a-f]{40}", commit) is None:
        raise ValueError("A release requires the full commit SHA")
    tags = {}
    for line in git(root, "ls-remote", "--tags", "origin").splitlines():
        sha, reference = line.split("\t")
        name = reference.removeprefix("refs/tags/").removesuffix("^{}")
        if re.fullmatch(VERSION, name) and (reference.endswith("^{}") or name not in tags):
            tags[name] = sha
    if tags.get(version) != commit:
        raise ValueError("The remote release tag does not name the requested commit")
    if max(tags, key=lambda value: tuple(map(int, value.split(".")))) != version:
        raise ValueError("Release the highest stable version tag")
    if git(root, "rev-parse", "HEAD") != commit:
        raise ValueError("The checkout does not match the release commit")
    if git(root, "cat-file", "-t", f"refs/tags/{version}") != "tag":
        raise ValueError("Release tags must be annotated with user-visible release notes")
    require_main_ancestor(root, commit)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("version")
    parser.add_argument("commit")
    parser.add_argument("--repository", type=Path, default=Path.cwd())
    arguments = parser.parse_args()
    validate(arguments.repository, arguments.version, arguments.commit)


if __name__ == "__main__":
    main()
