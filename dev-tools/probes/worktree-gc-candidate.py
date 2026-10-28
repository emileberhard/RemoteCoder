import argparse
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import sys
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--env-file", type=Path, required=True)
    parser.add_argument("--isolated-home", type=Path, required=True)
    parser.add_argument("--configs", type=Path, required=True)
    args = parser.parse_args()
    binary, env_file, isolated_home, configs = (
        path.resolve() for path in (args.binary, args.env_file, args.isolated_home, args.configs)
    )
    source = configs / "skills/github/scripts/worktree-gc"
    gateway_cli = Path(__file__).resolve().parents[1] / "rc-gateway"
    loader = importlib.machinery.SourceFileLoader("candidate_worktree_gc", str(source))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    if spec is None:
        raise RuntimeError("Cannot load the actual worktree-gc source")
    module = importlib.util.module_from_spec(spec)
    sys.modules[loader.name] = module
    loader.exec_module(module)
    observations = []
    original_read_activity = module.read_activity

    def observe_activity():
        activity = original_read_activity()
        observations.append(activity)
        return activity

    vars(module)["read_activity"] = observe_activity
    with tempfile.TemporaryDirectory(prefix="worktree-gc-routes-", dir=isolated_home) as directory:
        root = Path(directory)
        routes = {
            "LIST_AGENTS": [str(binary), "--env-file", str(env_file), "agent", "list"],
            "GATEWAY_CLI": [str(gateway_cli), "--ssh-env-path", str(env_file), "--scheme", "ws", "--local-config", ""],
        }
        for name, command in routes.items():
            wrapper = root / name.lower()
            environment = {"HOME": str(isolated_home), "PATH": os.environ["PATH"]}
            wrapper.write_text(
                f"#!{sys.executable}\nimport os, sys\n"
                f"command = {command!r} + sys.argv[1:]\n"
                f"os.execve(command[0], command, {environment!r})\n"
            )
            wrapper.chmod(0o700)
            setattr(module, name, wrapper)
        output = io.StringIO()
        previous_directory, previous_argv = Path.cwd(), sys.argv
        try:
            os.chdir(configs)
            sys.argv = [str(source), "--json"]
            with contextlib.redirect_stdout(output):
                status = module.main()
        finally:
            os.chdir(previous_directory)
            sys.argv = previous_argv
    plan = json.loads(output.getvalue())
    if status != 0 or not observations or any(activity.error for activity in observations):
        raise RuntimeError(f"Candidate worktree-gc activity failed: {[activity.error for activity in observations]}")
    if plan["applied"]:
        raise RuntimeError("Candidate worktree-gc must remain a dry run")
    print(json.dumps({
        "source": str(source), "routeOverrides": routes, "activityKnown": True,
        "activeAgentIds": len(observations[-1].agent_ids), "plan": plan,
    }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
