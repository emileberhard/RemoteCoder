from remotecoder_tools.perf_calibration import calibration_sources


def test_calibration_mapping_keeps_conversation_order_when_first_open_is_another_stream():
    scenario = {"conversations": [{"thread": {"id": thread}} for thread in ("first", "second", "third", "sidebar-only")],
                "actions": [{"kind": "toggleSidebar", "threadID": "first"},
                            {"kind": "open", "threadID": "second"},
                            {"kind": "open", "threadID": "first"},
                            {"kind": "open", "threadID": "third"}]}
    assert calibration_sources(scenario) == ["first", "second", "third"]
