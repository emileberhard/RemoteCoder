import json

import pytest

from remotecoder_tools import mac_bench


@pytest.mark.parametrize("truncated,expected_spans", [(False, []), (None, None), (True, None)])
def test_sparse_frame_marks_preserve_span_coverage(tmp_path, truncated, expected_spans):
    report = {
        "label": "idle",
        "build": {},
        "messages": 0,
        "loadMs": 0,
        "display": {},
        "window": {},
        "transcript": {},
        "frames": [
            [0, 0.01, 0, 1, 1, 0, 0, 100],
            [0.01, 0.02, 0.01, 1, 1, 0, 0, 100],
            [0.02, 0.03, 0.02, 1, 1, 0, 0, 100],
        ],
        "events": [],
        "marks": [],
        "measureStart": 0,
        "measureEnd": 0.03,
        "analysisScope": "window",
        "processCPUms": 3,
        "mainThreadCPUms": 3,
        "footprintStartMB": 10,
        "footprintEndMB": 10,
        "thermalState": 0,
    }
    if truncated is not None:
        report["spanRecording"] = {
            "capacity": 65536,
            "retained": 0,
            "overwritten": 0,
            "busyIntervalCapacity": 65536,
            "busyIntervalsDropped": 1 if truncated else 0,
            "truncated": truncated,
        }
    (tmp_path / "report.json").write_text(json.dumps(report))

    summary = mac_bench.analyze_run(tmp_path)

    assert len(summary["slowPasses"]) == 3
    assert all(row["marks"] == {} for row in summary["slowPasses"])
    assert all(row["spans"] == expected_spans for row in summary["slowPasses"])
