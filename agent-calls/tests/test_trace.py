import gzip
import json
from datetime import UTC, datetime

from agent_calls.trace import collect_trace

CALL = "60d3ffc1-b4f7-4111-ad89-341578cb2748"


def status():
    return {
        "callId": CALL,
        "recipient": "self",
        "createdAt": 1_800_000_000,
        "endedAt": 1_800_000_060,
    }


def test_trace_correlates_durable_app_failure_and_redacts_gateway_payload(tmp_path):
    logs = tmp_path / "logs"
    journal = logs / "journal"
    journal.mkdir(parents=True)
    (journal / "gateway-20270115.jsonl").write_text(
        json.dumps(
            {
                "ts": "2027-01-15T08:00:00.000Z",
                "method": "calls/request",
                "payload": {
                    "result": {
                        "callId": CALL,
                        "state": "requested",
                        "brief": "private context",
                    }
                },
            }
        )
        + "\n"
    )
    app = logs / "app-logs" / "phone"
    app.mkdir(parents=True)
    entries = [
        {
            "recordType": "agentCall",
            "callId": CALL.upper(),
            "stage": "reportIncomingFailed",
            "ts": "2027-01-15T08:00:01.000Z",
            "failure": {
                "domain": "com.apple.CallKit.error.incomingcall",
                "code": 3,
                "reason": "filteredByDoNotDisturb",
            },
        },
        {"recordType": "agentCall", "callId": "unrelated", "stage": "unrelated"},
    ]
    (app / "20270116-001800000002000-test-call.jsonl.gz").write_bytes(
        gzip.compress("\n".join(json.dumps(entry) for entry in entries).encode())
    )
    trace = collect_trace(status(), logs, tmp_path / "carrier")
    assert len(trace["events"]) == 2
    assert trace["events"][0]["state"] == "requested"
    assert trace["events"][1]["failure"]["reason"] == "filteredByDoNotDisturb"
    assert trace["coverage"]["appRecords"] == 1
    assert trace["coverage"]["gaps"] == []
    assert "private context" not in json.dumps(trace)


def test_trace_reports_missing_evidence_as_unknown(tmp_path):
    trace = collect_trace(status(), tmp_path / "logs", tmp_path / "carrier")
    assert trace["events"] == []
    assert trace["coverage"]["filesRead"] == 0
    assert trace["coverage"]["appRecords"] == 0
    assert len(trace["coverage"]["gaps"]) == 2
    assert trace["carrier"]["coverage"] == "not present on this host"


def test_trace_reads_every_utc_day_spanned_by_call(tmp_path):
    journal = tmp_path / "logs" / "journal"
    journal.mkdir(parents=True)
    for day in (15, 16, 17):
        (journal / f"gateway-202701{day}.jsonl").write_text(
            json.dumps(
                {"callId": CALL, "event": "callMedia", "mediaEvent": f"day-{day}"}
            )
            + "\n"
        )
    trace = collect_trace(
        status()
        | {
            "createdAt": datetime(2027, 1, 15, 23, tzinfo=UTC).timestamp(),
            "endedAt": datetime(2027, 1, 17, 1, tzinfo=UTC).timestamp(),
        },
        tmp_path / "logs",
        tmp_path / "carrier",
    )
    assert [event["mediaEvent"] for event in trace["events"]] == [
        "day-15", "day-16", "day-17"
    ]
    assert trace["coverage"]["filesRead"] == 3
    assert [gap for gap in trace["coverage"]["gaps"] if "source" in gap] == []


def test_telephone_trace_does_not_expect_native_app_diagnostics(tmp_path):
    journal = tmp_path / "journal"
    journal.mkdir()
    (journal / "gateway-20270115.jsonl").write_text("")
    trace = collect_trace(
        status() | {"recipient": "…1709"}, tmp_path, tmp_path / "carrier"
    )
    assert trace["coverage"]["gaps"] == []


def test_trace_keeps_worker_phase_and_failure_class(tmp_path):
    journal = tmp_path / "journal"
    journal.mkdir()
    entries = [
        {
            "event": "callMedia",
            "callId": CALL,
            "mediaEvent": "phase",
            "status": "subscription voice attachment",
        },
        {
            "event": "callMedia",
            "callId": CALL,
            "mediaEvent": "failed",
            "status": "GatewayError",
        },
    ]
    (journal / "gateway-20270115.jsonl").write_text(
        "\n".join(json.dumps(entry) for entry in entries)
    )
    events = collect_trace(status(), tmp_path, tmp_path / "carrier")["events"]
    assert [(event["mediaEvent"], event["status"]) for event in events] == [
        ("phase", "subscription voice attachment"),
        ("failed", "GatewayError"),
    ]
