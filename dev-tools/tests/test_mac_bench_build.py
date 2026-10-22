import json
import subprocess
import sys
from pathlib import Path
from unittest.mock import Mock

import pytest

from remotecoder_tools import mac_bench


@pytest.mark.parametrize("options", [[], ["--lab-config", "/tmp/private-book-lab/config.json"]])
def test_build_cli_preserves_default_and_forwards_only_the_lab_path(monkeypatch, capsys, options):
    run = Mock(return_value=subprocess.CompletedProcess([], 0, json.dumps({"app": "/tmp/private-book-lab/bench/app"})))
    monkeypatch.setattr(mac_bench.subprocess, "run", run)
    monkeypatch.setattr(sys, "argv", ["mac-bench", "build", *options])

    mac_bench.main()

    assert run.call_args.args[0] == [sys.executable, "scripts/remote-build.py", "mac-bench", *options]
    assert json.loads(capsys.readouterr().out)["app"] == "/tmp/private-book-lab/bench/app"


def test_build_cli_refuses_a_relative_lab_path_before_submitting(monkeypatch):
    run = Mock()
    monkeypatch.setattr(mac_bench.subprocess, "run", run)
    monkeypatch.setattr(sys, "argv", ["mac-bench", "build", "--lab-config", str(Path("config.json"))])

    with pytest.raises(SystemExit, match="absolute path on the MacBook"):
        mac_bench.main()

    run.assert_not_called()
