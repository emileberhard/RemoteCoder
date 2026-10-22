import gzip
import json
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import UUID


def collect_trace(status: dict, log_directory: Path, carrier_directory: Path) -> dict:
    call_id = str(UUID(status["callId"]))
    start = status["createdAt"]
    end = status.get("endedAt") or datetime.now(UTC).timestamp()
    first_day = datetime.fromtimestamp(start, UTC).date()
    last_day = datetime.fromtimestamp(end, UTC).date()
    paths = [
        log_directory / "journal" / f"gateway-{(first_day + timedelta(days=offset)):%Y%m%d}.jsonl"
        for offset in range((last_day - first_day).days + 1)
    ]
    app_directory = log_directory / "app-logs"
    if app_directory.is_dir():
        for device in app_directory.iterdir():
            if not device.is_dir():
                continue
            for path in device.glob("*.jsonl.gz"):
                pieces = path.name.split("-")
                if len(pieces) > 1 and pieces[1].isdigit():
                    recorded = int(pieces[1]) / 1_000
                    if start - 120 <= recorded <= end + 120:
                        paths.append(path)

    events = []
    gaps = []
    bytes_read = 0
    files_read = 0
    app_records = 0
    previous_status = None
    for path in sorted(paths):
        if not path.exists():
            gaps.append({"source": str(path), "reason": "missing"})
            continue
        try:
            opener = gzip.open if path.suffix == ".gz" else open
            with opener(path, "rt", encoding="utf-8") as file:
                files_read += 1
                for number, line in enumerate(file, 1):
                    bytes_read += len(line)
                    if bytes_read > 128 * 1024 * 1024:
                        gaps.append({"reason": "128 MiB scan limit reached"})
                        break
                    if call_id not in line.lower():
                        continue
                    record = json.loads(line)
                    source = f"{path}:{number}"
                    if record.get("recordType") == "agentCall":
                        app_records += 1
                        events.append({"source": source, **record})
                    elif "message" in record:
                        events.append(
                            {
                                "source": source,
                                **{
                                    key: record[key]
                                    for key in ("ts", "category", "message")
                                    if key in record
                                },
                            }
                        )
                    else:
                        method = record.get("method", "")
                        payload = record.get("payload", {})
                        body = payload.get("result") or payload.get("params") or {}
                        if method == "calls/status":
                            state = (body.get("state"), body.get("reason"))
                            if "state" not in body or state == previous_status:
                                continue
                            previous_status = state
                        event = {
                            key: record[key]
                            for key in (
                                "ts",
                                "kind",
                                "method",
                                "event",
                                "mediaEvent",
                                "status",
                                "direction",
                                "elapsedMs",
                                "clientId",
                                "ok",
                            )
                            if key in record
                        }
                        event.update(
                            {
                                key: body[key]
                                for key in (
                                    "state",
                                    "reason",
                                    "deliveryReceipt",
                                    "realtimeSessionId",
                                )
                                if key in body
                            }
                        )
                        events.append({"source": source, **event})
        except (OSError, EOFError, UnicodeError, json.JSONDecodeError) as error:
            gaps.append({"source": str(path), "reason": type(error).__name__})
        if bytes_read > 128 * 1024 * 1024:
            break

    receipt_path = carrier_directory / call_id / "receipt.json"
    carrier = {"coverage": "not present on this host"}
    if receipt_path.exists():
        try:
            receipt = json.loads(receipt_path.read_text())
            carrier = {
                "source": str(receipt_path),
                "coverage": "present",
                "receipt": receipt,
            }
        except (OSError, json.JSONDecodeError) as error:
            carrier = {"coverage": "unreadable", "reason": type(error).__name__}
    if status.get("recipient") == "self" and app_records == 0:
        gaps.append(
            {
                "reason": "No call-specific iPhone diagnostics uploaded to this host; check the other configured host or the phone's pending app-logs. Absence does not prove non-delivery."
            }
        )
    events.sort(key=lambda event: event.get("ts", ""))
    if len(events) > 200:
        gaps.append(
            {
                "reason": "Showing the latest 200 correlated events",
                "totalEvents": len(events),
            }
        )
    return {
        "call": status,
        "events": events[-200:],
        "carrier": carrier,
        "coverage": {
            "filesRead": files_read,
            "bytesRead": bytes_read,
            "appRecords": app_records,
            "gaps": gaps,
        },
    }
