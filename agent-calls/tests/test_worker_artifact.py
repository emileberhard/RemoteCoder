import base64
import json
import multiprocessing
import os
import subprocess
from pathlib import Path

import pytest

from agent_calls import worker_artifact

_REAL_RUN = subprocess.run


def bundle(previous=None):
    files = {"agent-calls/pyproject.toml": b"fixture-project", "dev-tools/agent-call": b"fixture-entry"}
    identity = {"version": "dev", "commit": None, "modified": None}
    return {"identity": identity, "workerHash": worker_artifact.content_hash(identity, files),
            "previousHash": previous, "originHost": "gateway-secondary",
            "reservation": "00000000-0000-0000-0000-000000000001",
            "files": {name: base64.b64encode(data).decode() for name, data in files.items()}}


def old_worker(root, identity):
    destination = root / identity["workerHash"]
    destination.mkdir(parents=True)
    for name, raw in identity["files"].items():
        path = destination / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(base64.b64decode(raw))
    (destination / "worker-artifact.json").write_text(json.dumps({
        "identity": identity["identity"], "workerHash": identity["workerHash"], "files": sorted(identity["files"])}))
    return destination


def test_worker_hash_mismatch_rejects_before_sync_or_filesystem_activation(tmp_path, monkeypatch):
    candidate = bundle()
    candidate["files"]["dev-tools/agent-call"] = base64.b64encode(b"changed-source").decode()
    calls = []
    monkeypatch.setattr(worker_artifact.subprocess, "run", lambda *args, **kwargs: calls.append(args))
    root = tmp_path / "call-workers"
    with pytest.raises(RuntimeError, match="content hash mismatch"):
        worker_artifact.install(candidate, root)
    assert not root.exists()
    assert calls == []


def test_failed_frozen_sync_preserves_the_selected_old_worker_and_gateway(tmp_path, monkeypatch):
    root = tmp_path / "call-workers"
    source = bundle()
    selected = old_worker(root, source)
    candidate = bundle(source["workerHash"])
    candidate["identity"]["version"] = "3.99.1"
    files = {name: base64.b64decode(data) for name, data in candidate["files"].items()}
    candidate["workerHash"] = worker_artifact.content_hash(candidate["identity"], files)
    gateway = tmp_path / "gateway"
    gateway.write_bytes(b"old-gateway")
    config = tmp_path / "call-delivery.json"
    config.write_text(json.dumps({"workerPath": str(selected / "dev-tools/agent-call")}))
    calls = []

    def fail_sync(arguments, **kwargs):
        if arguments[0] == "ps":
            return _REAL_RUN(arguments, **kwargs)
        calls.append(arguments)
        return subprocess.CompletedProcess(arguments, 1, "", "fixture sync rejected")

    monkeypatch.setattr(worker_artifact.subprocess, "run", fail_sync)
    with pytest.raises(RuntimeError, match="Locked worker dependency sync failed"):
        worker_artifact.install(candidate, root)
    assert gateway.read_bytes() == b"old-gateway"
    assert json.loads(config.read_text())["workerPath"] == str(selected / "dev-tools/agent-call")
    assert worker_artifact.artifact_contract(selected)["workerHash"] == source["workerHash"]
    assert not (root / candidate["workerHash"]).exists()
    assert "--frozen" in calls[0] and "--no-build" in calls[0]


def test_worker_stage_readback_and_retention_keep_current_and_previous(tmp_path, monkeypatch):
    root = tmp_path / "call-workers"
    obsolete = bundle()
    obsolete["identity"]["version"] = "3.98.0"
    files = {name: base64.b64decode(data) for name, data in obsolete["files"].items()}
    obsolete["workerHash"] = worker_artifact.content_hash(obsolete["identity"], files)
    obsolete_path = old_worker(root, obsolete)
    previous = bundle()
    old_worker(root, previous)
    candidate = bundle(previous["workerHash"])
    candidate["identity"]["version"] = "3.99.1"
    files = {name: base64.b64decode(data) for name, data in candidate["files"].items()}
    candidate["workerHash"] = worker_artifact.content_hash(candidate["identity"], files)
    calls = []

    def sync_and_readback(arguments, **kwargs):
        if arguments[0] == "ps":
            return _REAL_RUN(arguments, **kwargs)
        calls.append(arguments)
        result = {"workerHash": candidate["workerHash"], "identity": candidate["identity"], "protocolVersion": 1}
        return subprocess.CompletedProcess(arguments, 0, json.dumps(result), "")

    monkeypatch.setattr(worker_artifact.subprocess, "run", sync_and_readback)
    result = worker_artifact.install(candidate, root)
    assert result["workerPath"] == str(root / candidate["workerHash"] / "dev-tools/agent-call")
    assert len([path for path in root.iterdir() if path.is_dir()]) == 2
    assert not obsolete_path.exists()
    assert len(calls) == 3
    assert "--no-build-isolation" in calls[1]
    assert calls[2][-1] == "--worker-contract"
    worker_artifact.install(candidate, root)
    assert calls[3][-1] == "--worker-contract"


def test_abandoned_pending_worker_build_is_rebuilt_before_readback(tmp_path, monkeypatch):
    root = tmp_path / "call-workers"
    candidate = bundle()
    destination = root / candidate["workerHash"]
    destination.mkdir(parents=True)
    (destination / "worker-build.json").write_text(json.dumps({
        "identity": candidate["identity"], "workerHash": candidate["workerHash"],
        "files": sorted(candidate["files"])}))
    worker_artifact._save_json(root / "references.json", {
        "gateway-primary": {"selected": None, "pending": None, "generation": None},
        "gateway-secondary": {"selected": None,
                              "pending": {"hash": candidate["workerHash"], "rollback": None},
                              "generation": candidate["reservation"]},
    })
    calls = []

    def complete(arguments, **kwargs):
        if arguments[0] == "ps":
            return _REAL_RUN(arguments, **kwargs)
        calls.append(arguments)
        contract = {"workerHash": candidate["workerHash"], "identity": candidate["identity"], "protocolVersion": 1}
        return subprocess.CompletedProcess(arguments, 0, json.dumps(contract), "")

    monkeypatch.setattr(worker_artifact.subprocess, "run", complete)
    result = worker_artifact.install(candidate, root)
    assert result["workerHash"] == worker_artifact.artifact_contract(destination)["workerHash"]
    assert len(calls) == 3
    assert "--frozen" in calls[0] and calls[2][-1] == "--worker-contract"


def _install_in_child(request, root, admitted, release, result, attempting):
    import contextlib
    import traceback

    original_lease = worker_artifact._lease
    if attempting is not None:
        @contextlib.contextmanager
        def queued_lease(path, operation):
            if path.name == "install.lock":
                attempting.set()
            with original_lease(path, operation):
                yield
        worker_artifact._lease = queued_lease

    def complete(arguments, **kwargs):
        if arguments[0] == "ps":
            return _REAL_RUN(arguments, **kwargs)
        if arguments[0] == "ssh":
            path = root / request["previousHash"] / "dev-tools/agent-call"
            return subprocess.CompletedProcess(arguments, 0, json.dumps(str(path)), "")
        if arguments[0] == "uv" and admitted is not None:
            admitted.set()
            assert release.wait(5)
        contract = {"workerHash": request["workerHash"], "identity": request["identity"], "protocolVersion": 1}
        return subprocess.CompletedProcess(arguments, 0, json.dumps(contract), "")

    worker_artifact.subprocess.run = complete
    try:
        result.put(worker_artifact.install(request, root))
    except Exception:
        result.put({"failure": traceback.format_exc()})


def test_queued_peer_installer_cannot_prune_a_read_back_pending_worker(tmp_path):
    import multiprocessing

    context = multiprocessing.get_context("spawn")
    root = tmp_path / "call-workers"
    source = bundle()
    old_worker(root, source)
    (root.parent / "call-delivery.json").write_text(json.dumps({"workerPath": str(root / source["workerHash"] / "dev-tools/agent-call")}))
    worker_artifact._save_json(root / "references.json", {
        host: {"selected": source["workerHash"], "pending": None, "generation": None}
        for host in ["gateway-primary", "gateway-secondary"]
    })
    candidate = bundle(source["workerHash"])
    candidate["identity"]["version"] = "3.99.1"
    files = {name: base64.b64decode(data) for name, data in candidate["files"].items()}
    candidate["workerHash"] = worker_artifact.content_hash(candidate["identity"], files)
    peer = bundle(source["workerHash"])
    peer["originHost"] = "gateway-primary"
    peer["reservation"] = "00000000-0000-0000-0000-000000000002"
    admitted, release, attempting = context.Event(), context.Event(), context.Event()
    result = context.Queue(maxsize=2)
    first = context.Process(target=_install_in_child, args=(candidate, root, admitted, release, result, None))
    queued = context.Process(target=_install_in_child, args=(peer, root, None, release, result, attempting))
    try:
        first.start()
        assert admitted.wait(3)
        queued.start()
        assert attempting.wait(3)
        release.set()
        replies = [result.get(timeout=5), result.get(timeout=5)]
        assert all("failure" not in reply for reply in replies), replies
        first.join(3)
        queued.join(3)
        assert first.exitcode == queued.exitcode == 0
        destination = root / candidate["workerHash"]
        assert worker_artifact.artifact_contract(destination)["workerHash"] == candidate["workerHash"]
        references = json.loads((root / "references.json").read_text())
        assert references["gateway-secondary"]["pending"]["hash"] == candidate["workerHash"]
        worker_artifact.finish_reference({"originHost": candidate["originHost"],
                                          "reservation": candidate["reservation"],
                                          "sourceHash": candidate["previousHash"],
                                          "targetHash": candidate["workerHash"],
                                          "selectedHash": candidate["workerHash"]}, root)
        assert worker_artifact.artifact_contract(destination)["workerHash"] == candidate["workerHash"]
    finally:
        release.set()
        for process in [first, queued]:
            if process.pid is not None:
                if process.is_alive():
                    process.terminate()
                process.join(3)
        result.close()


def _persist_intent_in_child(request, path, ready, release):
    worker_artifact._save_json(path, request)
    ready.set()
    release.recv()


def _finish(candidate, selected):
    return {"originHost": candidate["originHost"], "reservation": candidate["reservation"],
            "sourceHash": candidate["previousHash"], "targetHash": candidate["workerHash"],
            "selectedHash": selected}


def _commands_for(candidate):
    def complete(arguments, **kwargs):
        if arguments[0] == "ps" or Path(arguments[0]).name == "remote-coder-codex-gateway":
            return _REAL_RUN(arguments, **kwargs)
        if arguments[0] == "ssh":
            return subprocess.CompletedProcess(arguments, 0, '{"path": null}', "")
        contract = {"workerHash": candidate["workerHash"], "identity": candidate["identity"], "protocolVersion": 1}
        return subprocess.CompletedProcess(arguments, 0, json.dumps(contract), "")
    return complete


@pytest.mark.parametrize("origin", ["gateway-primary", "gateway-secondary"])
@pytest.mark.parametrize("source", [None, "a" * 64])
@pytest.mark.parametrize("cache_exists", [False, True])
def test_killed_unregistered_intent_reconciles_first_cache_and_source_selection(tmp_path, monkeypatch, origin, source, cache_exists):
    root = tmp_path / "call-workers"
    if cache_exists:
        root.mkdir()
    candidate = bundle(source)
    candidate["originHost"] = origin
    request = _finish(candidate, source)
    intent = tmp_path / "worker-activation.json"
    context = multiprocessing.get_context("spawn")
    ready = context.Event()
    release, resume = context.Pipe(duplex=False)
    child = context.Process(target=_persist_intent_in_child, args=(request, intent, ready, release))
    try:
        child.start()
        assert ready.wait(5)
        child.kill()
        child.join(5)
        assert child.exitcode is not None and child.exitcode < 0
        monkeypatch.setattr(worker_artifact.subprocess, "run", _commands_for(candidate))
        resumed = json.loads(intent.read_text())
        worker_artifact.finish_reference(resumed, root)
        references = json.loads((root / "references.json").read_text())
        assert references[origin]["selected"] == source
        assert references[origin]["pending"] is None
        worker_artifact.finish_reference(resumed, root)
        assert json.loads((root / "references.json").read_text()) == references
        candidate["reservation"] = "00000000-0000-0000-0000-000000000002"
        worker_artifact.install(candidate, root)
        registered = (root / "references.json").read_bytes()
        with pytest.raises(RuntimeError, match="acknowledgement is stale"):
            worker_artifact.finish_reference(resumed, root)
        assert (root / "references.json").read_bytes() == registered
    finally:
        if child.pid is not None:
            if child.is_alive():
                child.kill()
            child.join(5)
        release.close()
        resume.close()


def _publish_worker_in_child(candidate, root, phase, ready, release):
    destination = root / candidate["workerHash"]
    mkdir, write_text, dump, save_json = Path.mkdir, Path.write_text, json.dump, worker_artifact._save_json

    def pause():
        ready.set()
        release.recv()

    def interrupted_mkdir(path, *args, **kwargs):
        result = mkdir(path, *args, **kwargs)
        if path == destination and phase == "mkdir":
            pause()
        return result

    def interrupted_write(path, value, *args, **kwargs):
        if path == destination / "worker-build.json" and phase == "claim":
            write_text(path, '{"identity":', encoding="utf-8")
            pause()
        return write_text(path, value, *args, **kwargs)

    def interrupted_dump(value, handle, *args, **kwargs):
        handle.write('{"identity":')
        handle.flush()
        os.fsync(handle.fileno())
        pause()
        handle.seek(0)
        handle.truncate()
        return dump(value, handle, *args, **kwargs)

    def interrupted_save(path, value):
        if path == destination / "worker-build.json" and phase == "claim":
            json.dump = interrupted_dump
        try:
            return save_json(path, value)
        finally:
            json.dump = dump

    Path.mkdir, Path.write_text = interrupted_mkdir, interrupted_write
    worker_artifact._save_json = interrupted_save
    worker_artifact.subprocess.run = _commands_for(candidate)
    worker_artifact.install(candidate, root)


@pytest.mark.parametrize("phase", ["mkdir", "claim"])
def test_killed_worker_publication_rebuilds_missing_or_partial_claim(tmp_path, monkeypatch, phase):
    root = tmp_path / "call-workers"
    source = bundle()
    selected = old_worker(root, source)
    worker_artifact._save_json(root / "references.json", {
        host: {"selected": source["workerHash"], "pending": None, "generation": None}
        for host in ["gateway-primary", "gateway-secondary"]
    })
    candidate = bundle(source["workerHash"])
    candidate["identity"]["version"] = "3.99.1"
    files = {name: base64.b64decode(data) for name, data in candidate["files"].items()}
    candidate["workerHash"] = worker_artifact.content_hash(candidate["identity"], files)
    context = multiprocessing.get_context("spawn")
    ready = context.Event()
    release, resume = context.Pipe(duplex=False)
    child = context.Process(target=_publish_worker_in_child, args=(candidate, root, phase, ready, release))
    try:
        child.start()
        assert ready.wait(5)
        assert (root / candidate["workerHash"]).is_dir()
        child.kill()
        child.join(5)
        assert child.exitcode is not None and child.exitcode < 0
        monkeypatch.setattr(worker_artifact.subprocess, "run", _commands_for(candidate))
        worker_artifact.finish_reference(_finish(candidate, source["workerHash"]), root)
        candidate["reservation"] = "00000000-0000-0000-0000-000000000002"
        installed = worker_artifact.install(candidate, root)
        assert installed["workerHash"] == candidate["workerHash"]
        assert worker_artifact.artifact_contract(root / candidate["workerHash"])["workerHash"] == candidate["workerHash"]
        assert worker_artifact.artifact_contract(selected)["workerHash"] == source["workerHash"]
        assert not (root / "worker-build.json").exists()
    finally:
        if child.pid is not None:
            if child.is_alive():
                child.kill()
            child.join(5)
        release.close()
        resume.close()


def _live_build_owner_in_child(candidate, root, metadata, ready, release):
    os.environ["TZ"] = "UTC"
    manifest = {"workerHash": candidate["workerHash"], "identity": candidate["identity"], "files": sorted(candidate["files"])}
    owner = worker_artifact._process_owner(os.getpid())
    worker_artifact._save_json(root / "worker-build.json", {"owner": owner, "manifest": manifest})
    if metadata:
        (root / f"references.json.{owner['pid']}.{owner['birth']}.{candidate['reservation']}").write_bytes(b'{"partial":')
    (root / candidate["workerHash"]).mkdir()
    ready.set()
    release.recv()


@pytest.mark.parametrize("metadata", [False, True])
def test_live_recorded_worker_owner_retains_staging_without_holding_install_lock(tmp_path, monkeypatch, metadata):
    monkeypatch.setenv("TZ", "Europe/Stockholm")
    root = tmp_path / "call-workers"
    root.mkdir()
    candidate = bundle()
    context = multiprocessing.get_context("spawn")
    ready = context.Event()
    release, resume = context.Pipe(duplex=False)
    child = context.Process(target=_live_build_owner_in_child, args=(candidate, root, metadata, ready, release))
    try:
        child.start()
        assert ready.wait(5)
        claim = (root / "worker-build.json").read_bytes()
        staged = {path: path.read_bytes() for path in root.glob("references.json.*")}
        monkeypatch.setattr(worker_artifact.subprocess, "run", _commands_for(candidate))
        with pytest.raises(RuntimeError, match="live process owns"):
            worker_artifact.install(candidate, root)
        assert (root / "worker-build.json").read_bytes() == claim
        assert (root / candidate["workerHash"]).is_dir()
        assert {path: path.read_bytes() for path in root.glob("references.json.*")} == staged
        child.kill()
        child.join(5)
        result = worker_artifact.install(candidate, root)
        assert result["workerHash"] == candidate["workerHash"]
    finally:
        if child.pid is not None:
            if child.is_alive():
                child.kill()
            child.join(5)
        release.close()
        resume.close()


def test_initial_peer_reference_uses_binary_identity_without_call_configuration(tmp_path, monkeypatch):
    root = tmp_path / ".remote-coder/call-workers"
    source = bundle()
    selected = old_worker(root, source)
    binary = tmp_path / "localbin/remote-coder-gateway/remote-coder-codex-gateway"
    binary.parent.mkdir(parents=True)
    binary.write_text("#!/bin/sh\nprintf '%s\\n' '" + json.dumps({"workerHash": source["workerHash"]}) + "'\n")
    binary.chmod(0o755)
    candidate = bundle(source["workerHash"])
    candidate["identity"]["version"] = "3.99.1"
    files = {name: base64.b64decode(data) for name, data in candidate["files"].items()}
    candidate["workerHash"] = worker_artifact.content_hash(candidate["identity"], files)
    monkeypatch.setattr(worker_artifact.subprocess, "run", _commands_for(candidate))
    worker_artifact.finish_reference(_finish(candidate, source["workerHash"]), root)
    worker_artifact.install(candidate, root)
    worker_artifact.finish_reference(_finish(candidate, candidate["workerHash"]), root)
    peer = bundle(source["workerHash"])
    peer["originHost"] = "gateway-primary"
    peer["reservation"] = "00000000-0000-0000-0000-000000000002"
    monkeypatch.setattr(worker_artifact.subprocess, "run", _commands_for(peer))
    assert worker_artifact.install(peer, root)["workerHash"] == source["workerHash"]
    assert worker_artifact.artifact_contract(selected)["workerHash"] == source["workerHash"]


def _release(version, previous, origin="gateway-primary"):
    candidate = bundle(previous)
    candidate["identity"]["version"] = version
    candidate["originHost"] = origin
    candidate["reservation"] = f"00000000-0000-0000-0000-{version.replace('.', '').zfill(12)}"
    files = {name: base64.b64decode(data) for name, data in candidate["files"].items()}
    candidate["workerHash"] = worker_artifact.content_hash(candidate["identity"], files)
    return candidate


def test_mini_releases_continue_while_the_macbook_keeps_an_older_worker(tmp_path, monkeypatch):
    root = tmp_path / "call-workers"
    macbook = _release("3.50.0", None)
    mini = _release("3.51.0", macbook["workerHash"])
    macbook_path = old_worker(root, macbook)
    old_worker(root, mini)
    worker_artifact._save_json(root / "references.json", {
        "gateway-primary": {"selected": mini["workerHash"], "pending": None, "generation": None},
        "gateway-secondary": {"selected": macbook["workerHash"], "pending": None, "generation": None},
    })
    selected = mini
    for version in ["3.52.0", "3.53.0", "3.54.0"]:
        candidate = _release(version, selected["workerHash"])
        monkeypatch.setattr(worker_artifact.subprocess, "run", _commands_for(candidate))
        worker_artifact.install(candidate, root)
        worker_artifact.finish_reference(_finish(candidate, candidate["workerHash"]), root)
        selected = candidate
    references = json.loads((root / "references.json").read_text())
    assert references["gateway-secondary"]["selected"] == macbook["workerHash"]
    assert references["gateway-primary"]["selected"] == selected["workerHash"]
    assert worker_artifact.artifact_contract(macbook_path)["workerHash"] == macbook["workerHash"]
    assert len([path for path in root.iterdir() if path.is_dir()]) <= worker_artifact.MAX_PROTECTED_WORKERS


def test_both_origins_can_hold_overlapping_pending_activations(tmp_path, monkeypatch):
    root = tmp_path / "call-workers"
    macbook = _release("3.50.0", None, "gateway-secondary")
    mini = _release("3.51.0", macbook["workerHash"])
    old_worker(root, macbook)
    old_worker(root, mini)
    worker_artifact._save_json(root / "references.json", {
        "gateway-primary": {"selected": mini["workerHash"], "pending": None, "generation": None},
        "gateway-secondary": {"selected": macbook["workerHash"], "pending": None, "generation": None},
    })
    mini_next = _release("3.52.0", mini["workerHash"])
    macbook_next = _release("3.51.1", macbook["workerHash"], "gateway-secondary")
    for candidate in (mini_next, macbook_next):
        monkeypatch.setattr(worker_artifact.subprocess, "run", _commands_for(candidate))
        worker_artifact.install(candidate, root)
    references = json.loads((root / "references.json").read_text())
    assert len(worker_artifact._protected(references)) == 4
    for candidate in (mini_next, macbook_next):
        worker_artifact.finish_reference(_finish(candidate, candidate["workerHash"]), root)
    references = json.loads((root / "references.json").read_text())
    assert references["gateway-primary"]["selected"] == mini_next["workerHash"]
    assert references["gateway-secondary"]["selected"] == macbook_next["workerHash"]
    for candidate in (mini_next, macbook_next):
        assert worker_artifact.artifact_contract(root / candidate["workerHash"])["workerHash"] == candidate["workerHash"]
    assert len([path for path in root.iterdir() if path.is_dir()]) <= worker_artifact.MAX_PROTECTED_WORKERS
