import asyncio
import json
import os
import time
from pathlib import Path
from types import SimpleNamespace

from .config import _resolve_config
from .perf_replay import capture
from .rpc import _initialize, _open_gateway, _timed_rpc
from .turns import _run_probe_turn


def evidence(window: dict, events: list[list[dict]]) -> tuple[bool, list[dict]]:
    summaries = []
    for stream in events:
        starts = [e["atUnix"] for e in stream if e["frame"].get("method") == "turn/started"]
        ends = [e["atUnix"] for e in stream if e["frame"].get("method") == "turn/completed"]
        deltas = [e for e in stream if e["frame"].get("method") == "item/agentMessage/delta"
                  and window["startedAt"] <= e["atUnix"] <= window["endedAt"]]
        summaries.append({"startedAt": min(starts) if starts else None,
                          "endedAt": max(ends) if ends else None, "deltasInWindow": len(deltas),
                          "charactersInWindow": sum(len(e["frame"]["params"].get("delta", "")) for e in deltas)})
    valid = bool(summaries) and all(s["startedAt"] is not None and window["startedAt"] <= s["startedAt"] < window["endedAt"]
                                  and s["deltasInWindow"] > 0 for s in summaries)
    if valid:
        valid = max(s["startedAt"] for s in summaries) < min(s["endedAt"] or window["endedAt"] for s in summaries)
    return valid, summaries


def recorded_events(streams: list[list[dict]], started_at: float, duration: float) -> list[dict]:
    events = []
    for stream in streams:
        for entry in stream:
            frame = entry["frame"]
            offset = entry["atUnix"] - started_at
            if 0 <= offset < duration:
                events.append({"at": offset, "frame": {"method": frame["method"], "params": frame["params"]}})
                if frame["method"] in {"turn/started", "turn/completed"}:
                    events.append({"at": offset, "frame": {"method": "daemon/activeTurns/changed",
                                   "params": {"threadId": frame["params"]["threadId"]}}})
    events.sort(key=lambda event: event["at"])
    if len(events) > 20_000:
        raise ValueError("recorded calibration exceeds the replay event cap")
    return events


def prepare(args):
    destination = Path(args.out).expanduser().resolve()
    if any((parent / ".git").exists() for parent in [destination, *destination.parents]):
        raise ValueError("calibration evidence must stay outside Git checkouts")
    destination.mkdir(parents=True, exist_ok=False, mode=0o700)
    config = _resolve_config(args)
    prompt = Path(args.prompt_file).expanduser().read_text()
    if not prompt.strip() or len(prompt.encode()) > 16_384:
        raise ValueError("calibration prompt must be nonempty and at most 16 KiB")
    fixture = Path(args.fixture).expanduser().read_bytes()
    scenario = json.loads(fixture)
    required = {action["threadID"] for action in scenario["actions"] if action["kind"] == "open"}
    if len(args.thread) != len(required):
        raise ValueError("supply one source --thread for each replay stream")
    return destination, config, prompt, fixture


async def run(args, device, harness) -> None:
    destination, config, prompt, fixture = await asyncio.to_thread(prepare, args)
    report = {"valid": False, "mode": "liveCalibration"}
    threads, tasks, streams = [], [], []
    cleanup = []
    async with _open_gateway(config, timeout_s=30, method="thread/fork") as control:
        await _initialize(control, timeout_s=30)
        request_id = 20

        def next_id():
            nonlocal request_id
            request_id += 1
            return request_id

        async def rpc(method, params):
            value, _, _ = await _timed_rpc(control, req_id=next_id(), method=method, params=params, timeout_s=30)
            return value

        try:
            models = await rpc("model/list", {})
            if "luna" not in args.model or not any(m["id"] == args.model for m in models["data"]):
                raise ValueError("calibration requires an available cheap Luna model")
            device.prepare()
            status = await asyncio.to_thread(harness.fresh_launch, device)
            matches = [h for h in status["hosts"] if h["name"] == args.app_host_name]
            if len(matches) != 1:
                raise ValueError(f"choose one exact --app-host-name from {status['hosts']}")
            host = matches[0]["id"]
            for source in args.thread:
                value = await rpc("thread/fork", {"threadId": source, "excludeTurns": True,
                                  "persistExtendedHistory": True, "threadSource": "user", "serviceTier": None})
                thread = value["thread"]["id"]
                threads.append(thread)
                (destination / "threads.json").write_text(json.dumps(threads))
                await rpc("conversation/marks/update", {"changes": [{"op": "setPurpose", "threadId": thread, "purpose": "probe"}]})
            frozen = await capture(SimpleNamespace(**{**vars(args), "thread": threads}))
            supplied = json.loads(fixture)
            ordered = list(dict.fromkeys(action["threadID"] for action in supplied["actions"] if action["kind"] == "open"))
            mapping = dict(zip(ordered, threads, strict=True))
            frozen["actions"] = [{**action, "threadID": mapping[action["threadID"]]} for action in supplied["actions"]]
            frozen["duration"] = supplied["duration"]
            frozen["name"] = supplied["name"]
            opened = await asyncio.to_thread(harness.send, device, {"cmd": "open", "host": host, "thread": threads[0]}, 45)
            if not opened or "error" in opened:
                raise RuntimeError(f"live conversation did not open: {opened}")
            device.put("scenario.json", fixture)
            await asyncio.sleep(3)
            path = str(destination / "live.trace")
            with harness.tracing(device, "Time Profiler", ["Hitches", "Points of Interest"], frozen["duration"] + harness.TRACE_WARMUP + 10, path) as recorder:
                await asyncio.sleep(harness.TRACE_WARMUP)
                measurement = asyncio.create_task(asyncio.to_thread(harness.send, device,
                    {"cmd": "calibration-run", "host": host, "threads": threads}, frozen["duration"] + 90, frozen["duration"] + 1))

                async def agent(index, thread):
                    await asyncio.sleep(2 + index * 4)
                    stream = streams[index]
                    byte_count = 0
                    with (destination / f"agent-{index + 1}.jsonl").open("w") as output:
                        def observe(frame):
                            nonlocal byte_count
                            if frame.get("params", {}).get("threadId") != thread:
                                return
                            entry = {"atUnix": time.time(), "frame": frame}
                            line = json.dumps(entry)
                            byte_count += len(line.encode())
                            if byte_count > 16 * 1_048_576:
                                raise RuntimeError("live agent evidence exceeds 16 MiB")
                            stream.append(entry)
                            output.write(line + "\n")
                        async with _open_gateway(config, timeout_s=30, method="turn/start") as ws:
                            await _initialize(ws, timeout_s=30)
                            counter = iter(range(100, 100_000))
                            async with asyncio.timeout(180):
                                return await _run_probe_turn(ws, next_id=lambda: next(counter), timeout_s=30,
                                    prompt=prompt, resume=thread, model=args.model, cwd=args.cwd,
                                    approval_policy="never", sandbox="readOnly", network_access=False,
                                    effort="low", service_tier=None, resume_rpc=True, on_event=observe)

                streams = [[] for _ in threads]
                tasks = [asyncio.create_task(agent(i, thread)) for i, thread in enumerate(threads)]
                window = await measurement
                if not window or "error" in window:
                    raise RuntimeError(f"live calibration window failed: {window}")
                report.update(window)
                expected = [(action["kind"], action["threadID"], action["at"]) for action in frozen["actions"]]
                actual = [(action["kind"], action["threadID"], action["scheduled"]) for action in window["actions"]]
                if actual != expected:
                    raise RuntimeError("live and exported replay schedules differ")
                report["clockAlignment"] = {"basis": "host and device wall clocks", "offsetSeconds": None, "uncertaintySeconds": None}
                report.update(json.loads((device.derived / "perf-build-identity.json").read_text()))
                report.update(deviceUDID=device.udid, driverSHA256=harness.DRIVER_SHA256, trace=path,
                              instrumentation=harness.instrumentation(device, "Time Profiler", ["Hitches", "Points of Interest"]))
                await asyncio.to_thread(harness.finish_trace, recorder, path, report)
            outcomes = await asyncio.gather(*tasks)
            frozen["events"] = recorded_events(streams, report["startedAt"], frozen["duration"])
            frozen["capturedAt"] = int(report["startedAt"])
            frozen["provenance"] = {"content": "captured initial histories and complete per-thread agent notifications",
                                    "pacing": "recorded host arrival offsets; fixture server applies production subscription scope", "model": args.model}
            (destination / "replay.json").write_text(json.dumps(frozen, ensure_ascii=False, sort_keys=True))
            valid, summary = evidence(report, streams)
            models = [(await rpc("thread/read", {"threadId": t, "includeTurns": False}))["thread"].get("model") for t in threads]
            report["agents"] = [{"threadID": t, "requestedModel": args.model, "observedModel": model, "status": o.status, **s}
                                for t, o, s, model in zip(threads, outcomes, summary, models, strict=True)]
            report["valid"] = report.get("windowValid") is True and valid and all(o.status == "completed" for o in outcomes) \
                and all(model == args.model for model in models)
        except BaseException as error:
            report["error"] = str(error)
            raise
        finally:
            for task in tasks:
                if not task.done():
                    task.cancel()
            if tasks:
                await asyncio.gather(*tasks, return_exceptions=True)
            try:
                active = await rpc("daemon/activeTurns", {})
                for turn in active["activeTurns"]:
                    if turn["threadId"] in threads:
                        await rpc("turn/interrupt", {"threadId": turn["threadId"], "turnId": turn["turnId"]})
            except Exception as error:
                cleanup.append(f"live turn cleanup: {error}")
            for thread in threads:
                try:
                    await rpc("thread/archive", {"threadId": thread})
                except Exception as error:
                    cleanup.append(f"archive {thread}: {error}")
            for operation in [device.terminate, device.uninstall]:
                try:
                    operation()
                except Exception as error:
                    cleanup.append(f"{operation.__name__}: {error}")
            report["cleanupFailures"] = cleanup
            report["valid"] = report.get("valid") is True and not cleanup
            (destination / "report.json").write_text(json.dumps(report, sort_keys=True))
            for file in destination.glob("*.json*"):
                os.chmod(file, 0o600)
    if not report["valid"]:
        raise RuntimeError(f"live calibration was invalid; inspect {destination / 'report.json'}")
    print(json.dumps({"valid": True, "report": str(destination / "report.json")}))
