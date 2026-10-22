import copy
import hashlib
import json
import os
import sys
from pathlib import Path

import pytest

from remotecoder_tools.external_auth_identity import (
    managed_executable,
    package_identity,
    verify_package,
    verify_requested_identity,
)
from remotecoder_tools.external_auth_probe import validate_case

FIXTURE = json.loads(
    (Path(__file__).parent / "fixtures/external-auth-matrix.json").read_text()
)
PATCHED = {row["case"]: row for row in FIXTURE["cases"]}


def test_gate_rejects_refresh_broadcast_to_consumer():
    with pytest.raises(RuntimeError, match="refresh reached consumer"):
        validate_case(FIXTURE["baseline"])


@pytest.mark.parametrize("row", PATCHED.values(), ids=PATCHED.keys())
def test_gate_accepts_valid_synthetic_matrix(row):
    validate_case(row)


@pytest.mark.parametrize(
    ("name", "field", "value", "error"),
    [
        ("timeout_late", "lateSuccessInstalled", True, "Late refresh installed"),
        ("wrong_account", "finalTokenLabel", "renewed", "retained bearer"),
        ("restart", "diskAuthAbsent", False, "persisted to disk"),
        ("owner_gone", "elapsedSeconds", 10.0, "retained pending callback"),
    ],
)
def test_gate_rejects_security_contract_regression(name, field, value, error):
    row = copy.deepcopy(PATCHED[name])
    row[field] = value
    with pytest.raises(RuntimeError, match=error):
        validate_case(row)


@pytest.mark.parametrize("mismatch", ["source", "version", "bytes", "manifest"])
def test_package_rejects_unapproved_identity(tmp_path, mismatch):
    (tmp_path / "bin").mkdir()
    binary = tmp_path / "bin/codex"
    binary.write_bytes(b"approved fixture")
    digest = hashlib.sha256(b"approved fixture").hexdigest()
    approval = {
        "codexForkCommit": "approved-source",
        "codexCliVersion": "1.2.3",
        "runtimeHashes": {"bin/codex": digest},
    }
    manifest = {
        "sourceCommit": "approved-source",
        "version": "1.2.3",
        "entrypoint": "bin/codex",
        "binaries": {"bin/codex": {"sha256": digest}},
    }
    if mismatch == "source":
        manifest["sourceCommit"] = "other-source"
    elif mismatch == "version":
        manifest["version"] = "1.2.4"
    elif mismatch == "bytes":
        binary.write_bytes(b"other fixture")
    else:
        manifest["binaries"]["bin/codex"]["sha256"] = "0" * 64
    (tmp_path / "codex-package.json").write_text(json.dumps(manifest))
    with pytest.raises(RuntimeError, match="differs|mismatch"):
        verify_package(tmp_path, approval)


def test_requested_host_match_rejects_resource_drift(tmp_path):
    package = tmp_path / "package"
    (package / "bin").mkdir(parents=True)
    for name in ("codex", "codex-code-mode-host"):
        (package / "bin" / name).write_bytes(b"approved executable")
    (package / "codex-package.json").write_text(
        json.dumps({"sourceCommit": "source", "version": "1.2.3"})
    )
    resource = package / "resource"
    resource.write_bytes(b"requested host resource")
    requested = package_identity(package)
    resource.write_bytes(b"different worker resource")
    with pytest.raises(RuntimeError, match="packageSHA256"):
        verify_requested_identity(package_identity(package), requested)


@pytest.mark.skipif(
    sys.platform != "darwin", reason="Managed executable inspection uses macOS libproc"
)
def test_managed_executable_resolves_actual_process():
    assert managed_executable(os.getpid()) == Path(sys.executable).resolve(strict=True)
