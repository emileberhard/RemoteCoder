import importlib.machinery
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import threading
import unittest
from contextlib import nullcontext, redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader("perf_trace", str(Path(__file__).resolve().parents[1] / "perf-trace"))
spec = importlib.util.spec_from_loader(loader.name, loader)
trace = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = trace
loader.exec_module(trace)


class RenderMetricsTests(unittest.TestCase):
    def test_window_clipping_refresh_gpu_and_power(self):
        import xml.etree.ElementTree as ET

        def value(tag, text):
            element = ET.Element(tag)
            element.text = str(text)
            return element

        display = value("display-name", "Built-In Display 1")
        app = ET.Element("process", fmt="RemoteCoder (12)")
        server = ET.Element("process", fmt="backboardd (42)")
        rows = {
            "display-vsyncs-interval": [
                {"timestamp": value("start-time", timestamp), "display-name": display, "event": value("vsync-event", "VSYNC")}
                for timestamp in (0, 8_333_333, 16_666_666, 33_333_333, 113_333_333)
            ],
            "metal-gpu-intervals": [
                {"process": server, "event-depth": value("depth", 0), "start": value("start", 10_000_000), "duration": value("duration", 10_000_000)},
                {"process": server, "event-depth": value("depth", 1), "start": value("start", 10_000_000), "duration": value("duration", 10_000_000)},
            ],
            "ProcessSubsystemPowerImpact": [
                {"process": app, "row-kind": value("kind", 0), "start": value("start", 0), "duration": value("duration", 20_000_000),
                 "cpu-impact": value("impact", 2), "gpu-impact": value("impact", -0.000000001), "display-impact": value("impact", 0)},
                {"process": app, "row-kind": value("kind", 0), "start": value("start", 20_000_000), "duration": value("duration", 20_000_000),
                 "cpu-impact": value("impact", 4), "gpu-impact": value("impact", -0.000000001), "display-impact": value("impact", 0)},
                {"process": app, "row-kind": value("kind", 2), "start": value("start", 0), "duration": value("duration", 40_000_000),
                 "cpu-impact": value("impact", -0.000000001), "gpu-impact": value("impact", 3), "display-impact": value("impact", -0.000000001)},
            ],
        }
        run = trace.Run(1, "Time limit reached", "iOS", frozenset(rows), "")
        with patch.object(trace, "table_rows", side_effect=lambda _trace, schema, _columns: iter(rows[schema])):
            result = trace.render_metrics("recording.trace", run, {"window": [(5_000_000, 35_000_000)]})["window"]
        refresh = result["refreshRates"]["Built-In Display 1"]
        self.assertEqual(refresh["rates"]["120"]["seconds"], 0.012)
        self.assertEqual(refresh["rates"]["60"]["seconds"], 0.017)
        self.assertEqual(refresh["unknownSeconds"], 0.002)
        self.assertEqual(result["backboardGpuChannelMs"], 20)
        self.assertEqual(result["powerImpact"]["cpu"]["average"], 1.5)
        self.assertEqual(result["powerImpact"]["gpu"]["average"], 1.5)
        self.assertEqual(result["powerImpact"]["display"]["average"], 0)

    def test_missing_data_stays_unknown(self):
        run = trace.Run(1, "Time limit reached", "iOS", frozenset(), "")
        result = trace.render_metrics("recording.trace", run, {"window": [(0, 1e9)]})["window"]
        self.assertIsNone(result["refreshRates"])
        self.assertIsNone(result["backboardGpuChannelMs"])
        self.assertIsNone(result["powerImpact"])


class ExplicitSymbolsTests(unittest.TestCase):
    def test_dsym_and_direct_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "RemoteCoder.app.dSYM"
            binary = bundle / "Contents/Resources/DWARF/RemoteCoder"
            binary.parent.mkdir(parents=True)
            binary.touch()
            self.assertEqual(trace.explicit_symbol_files(bundle), [binary])
            self.assertEqual(trace.explicit_symbol_files(binary), [binary])


class Export:
    pid = 0

    def __init__(self, xml):
        self.stdout = io.BytesIO(xml.encode())
        self.returncode = 0

    def wait(self):
        return self.returncode

    def poll(self):
        return self.returncode

    def kill(self):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.stdout.close()


class Recorder(Export):
    def __init__(self):
        self.stdout = io.BytesIO(b"Ctrl-C to stop the recording\nTime limit reached\n")
        self.returncode = 0


class WaitingExport(Export):
    def __init__(self):
        super().__init__("")
        self.returncode = None
        self.killed = threading.Event()

    def kill(self):
        self.returncode = -9
        self.killed.set()

    def wait(self):
        if not self.killed.wait(3):
            raise RuntimeError("export guard did not stop the fixture")
        return self.returncode


SWIFTUI_XML = '''<trace-query-result><node><schema name="swiftui-updates">
<col><mnemonic>description</mnemonic><engineering-type>string</engineering-type></col>
<col><mnemonic>duration</mnemonic><engineering-type>duration</engineering-type></col>
<col><mnemonic>process</mnemonic><engineering-type>process</engineering-type></col>
<col><mnemonic>update-type</mnemonic><engineering-type>swiftui-update-type</engineering-type></col>
</schema>
<row><string id="1" fmt="TranscriptBubble.body"/><duration id="2" fmt="3.00 ms">3000000</duration><process id="3" fmt="RemoteCoder (12)"/><swiftui-update-type id="4" fmt="View Body"/></row>
<row><string ref="1"/><duration ref="2"/><process ref="3"/><swiftui-update-type ref="4"/></row>
<row><string id="5">Composer</string><duration>1000000</duration><process ref="3"/><swiftui-update-type id="6">Platform View</swiftui-update-type></row>
<row><string ref="1"/><duration>900000000</duration><process fmt="OtherApp (42)"/><swiftui-update-type ref="4"/></row>
</node></trace-query-result>'''


HITCH_XML = '''<trace-query-result><node><schema name="hitches">
<col><mnemonic>narrative-description</mnemonic><engineering-type>string</engineering-type></col>
<col><mnemonic>duration</mnemonic><engineering-type>duration</engineering-type></col>
<col><mnemonic>process</mnemonic><engineering-type>process</engineering-type></col>
</schema>
<row><string id="1" fmt="Potentially expensive app update(s)">Potentially expensive app update(s)</string><duration id="2" fmt="16.67 ms">16666667</duration><process id="3" fmt="RemoteCoder (12)"/></row>
<row><string id="4">Potentially expensive app update(s), Potentially expensive render, 0 offscreen passes)</string><duration id="5" fmt="25.00 ms">25000000</duration><process ref="3"/></row>
<row><string id="6">Potentially expensive render</string><duration ref="2"/><process ref="3"/></row>
<row><sentinel/><duration id="7">8333333</duration><process ref="3"/></row>
<row><string ref="1"/><duration id="8">900000000</duration><process id="9" fmt="WindowServer (42)"/></row>
</node></trace-query-result>'''

UPDATES_XML = '''<trace-query-result><node><schema name="hitches-updates">
<col><mnemonic>surface-id</mnemonic><engineering-type>uint32</engineering-type></col>
<col><mnemonic>process</mnemonic><engineering-type>process</engineering-type></col>
<col><mnemonic>swap-id</mnemonic><engineering-type>uint32</engineering-type></col>
<col><mnemonic>display</mnemonic><engineering-type>display-name</engineering-type></col>
</schema>
<row><uint32 id="1">18</uint32><process id="2" fmt="RemoteCoder (12)"/><uint32 id="3">10</uint32><display-name id="4">Display 1</display-name></row>
<row><uint32 id="5">19</uint32><process ref="2"/><uint32 id="6">11</uint32><display-name ref="4"/></row>
<row><uint32 ref="1"/><process ref="2"/><uint32 ref="3"/><display-name ref="4"/></row>
<row><uint32 ref="1"/><process id="7" fmt="Dock (20)"/><uint32 id="8">12</uint32><display-name ref="4"/></row>
</node></trace-query-result>'''

WAIT_XML = '''<trace-query-result><node><schema name="hitches-framewait">
<col><mnemonic>duration</mnemonic><engineering-type>duration</engineering-type></col>
<col><mnemonic>surface-id</mnemonic><engineering-type>uint32</engineering-type></col>
<col><mnemonic>start</mnemonic><engineering-type>start-time</engineering-type></col>
<col><mnemonic>display</mnemonic><engineering-type>display-name</engineering-type></col>
<col><mnemonic>swap-id</mnemonic><engineering-type>uint32</engineering-type></col>
</schema>
<row><duration id="1">2000000</duration><uint32 id="2">18</uint32><start-time id="3">8000000</start-time><display-name id="4">Display 1</display-name><uint32 id="5">10</uint32></row>
<row><duration id="6">1000000</duration><uint32 id="7">19</uint32><start-time id="8">17333333</start-time><display-name ref="4"/><uint32 id="9">11</uint32></row>
<row><duration ref="1"/><uint32 ref="2"/><start-time ref="3"/><display-name ref="4"/><uint32 ref="5"/></row>
<row><duration ref="1"/><uint32 ref="2"/><start-time id="10">40000000</start-time><display-name ref="4"/><uint32 id="11">12</uint32></row>
</node></trace-query-result>'''


PROFILE_XML = '''<trace-query-result><node><schema name="time-profile">
<col><mnemonic>time</mnemonic><engineering-type>sample-time</engineering-type></col>
<col><mnemonic>process</mnemonic><engineering-type>process</engineering-type></col>
<col><mnemonic>thread</mnemonic><engineering-type>thread</engineering-type></col>
<col><mnemonic>weight</mnemonic><engineering-type>duration</engineering-type></col>
<col><mnemonic>stack</mnemonic><engineering-type>backtrace</engineering-type></col>
</schema>
<row><sample-time id="1">1200000000</sample-time><process id="2" fmt="RemoteCoder (12)"/><thread id="3" fmt="Main Thread 0x1 (RemoteCoder, pid: 12)"/><duration id="4">4000000</duration><tagged-backtrace id="5"><frame id="6" name="AXUIElementCopyAttributeValue" addr="0x2000"><binary id="7" name="AXRuntime" UUID="A" arch="arm64e" load-addr="0x1000" path="/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime"/></frame><frame id="8" name="__XCTPerformOnMainRunLoop_block_invoke" addr="0x4000"><binary id="9" name="XCTAutomationSupport" UUID="B" arch="arm64e" load-addr="0x3000" path="/System/Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework/XCTAutomationSupport"/></frame></tagged-backtrace></row>
<row><sample-time id="10">2500000000</sample-time><process ref="2"/><thread ref="3"/><duration id="11">3000000</duration><backtrace/></row>
<row><sample-time id="12">1100000000</sample-time><process fmt="backboardd (42)"/><thread/><duration ref="4"/><backtrace/></row>
</node></trace-query-result>'''

SIGNPOST_XML = '''<trace-query-result><node><schema name="OSSignpostIntervals">
<col><mnemonic>start</mnemonic><engineering-type>start-time</engineering-type></col>
<col><mnemonic>duration</mnemonic><engineering-type>duration</engineering-type></col>
<col><mnemonic>name</mnemonic><engineering-type>string</engineering-type></col>
<col><mnemonic>subsystem</mnemonic><engineering-type>subsystem</engineering-type></col>
<col><mnemonic>process</mnemonic><engineering-type>process</engineering-type></col>
</schema>
<row><start-time id="1">1000000000</start-time><duration id="2">300000000</duration><string id="3" fmt="TranscriptScroll">TranscriptScroll</string><subsystem id="4" fmt="RemoteCoder">RemoteCoder</subsystem><process id="5" fmt="RemoteCoder (12)"/></row>
<row><start-time id="6">1200000000</start-time><duration ref="2"/><string ref="3"/><subsystem ref="4"/><process ref="5"/></row>
<row><start-time id="7">2400000000</start-time><duration ref="2"/><string ref="3"/><subsystem ref="4"/><process fmt="OtherApp (13)"/></row>
</node></trace-query-result>'''

MOTION_HITCH_XML = '''<trace-query-result><node><schema name="hitches">
<col><mnemonic>start</mnemonic><engineering-type>start-time</engineering-type></col>
<col><mnemonic>duration</mnemonic><engineering-type>duration</engineering-type></col>
<col><mnemonic>process</mnemonic><engineering-type>process</engineering-type></col>
<col><mnemonic>narrative-description</mnemonic><engineering-type>string</engineering-type></col>
</schema>
<row><start-time id="1">1400000000</start-time><duration id="2">25000000</duration><process id="3" fmt="RemoteCoder (12)"/><string id="4">Potentially expensive app update(s)</string></row>
<row><start-time id="5">3000000000</start-time><duration ref="2"/><process ref="3"/><string ref="4"/></row>
</node></trace-query-result>'''

MOTION_UPDATES_XML = '''<trace-query-result><node><schema name="hitches-updates">
<col><mnemonic>start</mnemonic><engineering-type>start-time</engineering-type></col>
<col><mnemonic>process</mnemonic><engineering-type>process</engineering-type></col>
</schema>
<row><start-time id="1">1100000000</start-time><process id="2" fmt="RemoteCoder (12)"/></row>
<row><start-time id="3">2000000000</start-time><process ref="2"/></row>
</node></trace-query-result>'''


NO_AUTOMATION = {"app": {"automation": {"samples": 0}, "cpuUnavailableReason": None}}


class PerfTraceTests(unittest.TestCase):
    def test_processor_calls_use_uuid_matched_symbols_and_preserve_inline_locations(self):
        xml = """<trace-query-result><node><schema name="processor-trace-intervals">
        <col><mnemonic>process</mnemonic><engineering-type>process</engineering-type></col>
        <col><mnemonic>name</mnemonic><engineering-type>text-location</engineering-type></col>
        <col><mnemonic>self-duration</mnemonic><engineering-type>duration</engineering-type></col>
        <col><mnemonic>self-cycles</mnemonic><engineering-type>uint64</engineering-type></col>
        <col><mnemonic>self-instructions</mnemonic><engineering-type>uint64</engineering-type></col>
        <col><mnemonic>backtrace</mnemonic><engineering-type>text-backtrace</engineering-type></col>
        </schema><row><process id="1" fmt="RemoteCoder (12)"/><text-location id="2" fmt="0x1010 RemoteCoder"/>
        <duration id="3">2000000</duration><uint64 id="4">100</uint64><uint64 id="5">50</uint64>
        <text-backtrace id="6"><frame id="7" name="0x1010" addr="0x1010"><binary id="8" name="RemoteCoder"
        UUID="A" arch="arm64" load-addr="0x1000" path="/RemoteCoder.app/RemoteCoder"/></frame></text-backtrace></row>
        <row><process ref="1"/><text-location ref="2"/><duration ref="3"/><uint64 ref="4"/>
        <uint64 ref="5"/><text-backtrace id="9"><frame id="10" name="0x1010" addr="0x1010"><binary ref="8"/></frame></text-backtrace></row></node></trace-query-result>"""
        from symbols import SymbolFile
        lines = ("inner (in RemoteCoder) (Parser.swift:10)", "parse (in RemoteCoder) (Parser.swift:20)")
        run = trace.Run(2, "Time limit reached", "iOS", frozenset({"processor-trace-intervals"}), "now")
        with (patch.object(trace.subprocess, "Popen", return_value=Export(xml)),
              patch.object(trace, "symbol_files", return_value={"A": SymbolFile(Path("/matching-dsym"), "arm64")}),
              patch.object(trace, "atos", return_value=[lines]) as atos):
            result = trace.processor_trace("x.trace", run, 10, [])
        self.assertEqual(result["topAppFunctions"], {"parse (in RemoteCoder)": {
            "callIntervals": 2, "selfMs": 4, "selfCycles": 200, "selfInstructions": 100}})
        self.assertEqual(result["symbolLocations"]["parse (in RemoteCoder)"][0]["inlineFrames"], list(lines))
        self.assertEqual(result["symbolLocations"]["parse (in RemoteCoder)"][0]["selfCycles"], 200)
        self.assertEqual(atos.call_args.args[2], [0x1010])

    def test_accessibility_snapshot_ancestors_count_as_automation_without_developer_frames(self):
        for name in ("-[NSObject(UIAccessibilityAutomation) _accessibilityUserTestingSnapshotWithOptions:]",
                     "_AXXMIGCopyParameterizedAttributeValue"):
            xml = PROFILE_XML.replace("__XCTPerformOnMainRunLoop_block_invoke", name)
            xml = xml.replace("/System/Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework/XCTAutomationSupport",
                              "/System/Library/AccessibilityBundles/UIKit.axbundle/UIKit")
            result, _ = self.summary({"time-profile"}, tables={"time-profile": xml})
            self.assertEqual(result["app"]["mainThreadCpuMs"], 7)
            self.assertEqual(result["app"]["mainThreadCpuMsExcludingAutomation"], 3)
            self.assertEqual(result["app"]["automation"]["cpuMs"], 4)
            with self.assertRaises(SystemExit):
                trace.reject_automation(result)

    def test_automation_rejection_uses_app_and_main_thread_cpu_shares(self):
        cases = [(4, 20000, 18491, "main", 0, False), (1, 99, 0, "main", 0, False),
                 (2, 98, 10000, "main", 0, True), (2, 98, 0, "worker", 0, True),
                 (4, 20000, 0, "main", 1, True)]
        for automated, clean, background, thread, unweighted, reject in cases:
            with self.subTest(case=(automated, clean, background, thread, unweighted)):
                samples = [trace.Sample(0, thread, automated, (), True),
                           trace.Sample(1, thread, clean, (), False),
                           trace.Sample(2, "background", background, (), False)]
                automation = trace.automation_summary(samples, trace.Counter({thread: 1}), unweighted)
                summary = {"trace": "fixture.trace", "app": {"automation": automation}}
                if reject:
                    with self.assertRaises(SystemExit):
                        trace.reject_automation(summary)
                else:
                    trace.reject_automation(summary)
                    self.assertLessEqual(automation["cpuSharePercent"], 1)

    def test_processor_only_trace_preserves_unknown_sampled_cpu_and_automation(self):
        xml = """<trace-query-result><node><schema name="processor-trace-intervals">
        <col><mnemonic>process</mnemonic><engineering-type>process</engineering-type></col>
        <col><mnemonic>name</mnemonic><engineering-type>text-location</engineering-type></col>
        <col><mnemonic>self-duration</mnemonic><engineering-type>duration</engineering-type></col>
        <col><mnemonic>self-cycles</mnemonic><engineering-type>uint64</engineering-type></col>
        <col><mnemonic>self-instructions</mnemonic><engineering-type>uint64</engineering-type></col>
        </schema><row><process fmt="RemoteCoder (12)"/><text-location fmt="encode"/>
        <duration>500000</duration><uint64>17</uint64><uint64>12</uint64></row></node></trace-query-result>"""
        summary, _ = self.summary({"processor-trace-intervals"}, tables={"processor-trace-intervals": xml})
        self.assertEqual(summary["processorTrace"]["topFunctions"]["encode"]["selfCycles"], 17)
        self.assertIsNone(summary["app"]["cpuMs"])
        self.assertIsNone(summary["app"]["automation"]["samples"])
        with redirect_stdout(io.StringIO()):
            trace.report(summary, "retry")

    def test_single_process_attach_failure_explains_debug_signing(self):
        recorder = Recorder()
        recorder.stdout = io.BytesIO(b"")
        recorder.returncode = 19
        with (patch.object(trace.subprocess, "Popen", return_value=recorder),
              self.assertRaisesRegex(SystemExit, "debuggable.*get-task-allow.*distribution"),
              trace.recording(Path("x.trace"), 5, ["--attach", "RemoteCoder"], [], "Allocations")):
            pass

    def test_new_template_tables_preserve_unknown_metrics_and_filter_other_apps(self):
        import xml.etree.ElementTree as ET

        def value(tag, text):
            element = ET.Element(tag)
            element.text = text
            return element

        app = ET.Element("process", fmt="RemoteCoder (12)")
        other = ET.Element("process", fmt="OtherApp (13)")
        rows = [
            {"process": app, "name": value("text-location", "encode"),
             "self-duration": value("duration", "2000000"), "self-cycles": value("uint64", "100"),
             "self-instructions": value("uint64", "50")},
            {"process": app, "name": value("text-location", "encode"),
             "self-duration": ET.Element("sentinel"), "self-cycles": value("uint64", "10"),
             "self-instructions": value("uint64", "5")},
            {"process": other, "name": value("text-location", "unrelated"), "self-cycles": value("uint64", "999")},
        ]
        run = trace.Run(2, "Time limit reached", "iOS", frozenset({"processor-trace-intervals"}), "now")
        with patch.object(trace, "table_rows", return_value=iter(rows)):
            result = trace.processor_trace("x.trace", run, 10, [])
        self.assertEqual(result["topFunctions"], {"encode": {"callIntervals": 2, "selfMs": None,
                                                           "selfCycles": 110, "selfInstructions": 55}})
        self.assertEqual(result["unavailableValueRows"], {"self-duration": 1})
        with patch.object(trace, "table_rows", return_value=iter([
            {"process": app, "path": value("file-path", "/db-wal"), "syscall": value("syscall", "pwrite"),
             "type": value("string", "Write"), "lwrites": value("size-in-bytes", "4096"),
             "duration": value("duration", "1000000")},
            {"process": app, "path": value("file-path", "/db-wal"), "syscall": value("syscall", "pwrite"),
             "type": value("string", "Write"), "lwrites": ET.Element("sentinel"),
             "duration": value("duration", "2000000")},
        ])):
            result = trace.file_activity("x.trace", frozenset({"FsSyscall"}))
        self.assertIsNone(result["paths"]["/db-wal"]["writtenBytes"])
        self.assertEqual(result["paths"]["/db-wal"]["durationMs"], 3)

    def test_unknown_blocked_and_task_durations_invalidate_only_affected_buckets(self):
        import xml.etree.ElementTree as ET
        def value(tag, text):
            element = ET.Element(tag)
            element.text = text
            return element
        app = ET.Element("process", fmt="RemoteCoder (12)")
        rows = [{"process": app, "thread": value("thread", "main"), "state": value("state", state),
                 "note": value("note", reason), "actor": value("actor", "actor"),
                 "resume-function": value("function", reason), "duration": value("duration", duration)}
                for state, reason, duration in [("Blocked", "IPC", "1000000"), ("Blocked", "IPC", ""),
                                                ("Blocked", "lock", "2000000")]]
        with patch.object(trace, "table_rows", return_value=iter(rows)):
            system = trace.system_trace("x.trace", frozenset({"thread-state"}))
        self.assertEqual(system["blockedMsByThreadAndReason"]["main"], {"IPC": None, "lock": 2})
        self.assertEqual(system["unavailableDurationRows"], 1)
        rows[2]["state"] = value("state", "Running")
        with patch.object(trace, "table_rows", return_value=iter(rows)):
            tasks = trace.swift_concurrency("x.trace", frozenset({"SwiftTaskStateTable"}))
        self.assertEqual(tasks["taskStateMs"], {"Blocked": None, "Running": 2})
        self.assertEqual(tasks["taskStateMsByActor"]["actor"], {"Blocked": None, "Running": 2})
        self.assertEqual(tasks["resumeFunctionStateMs"], {"IPC": None, "lock": 2})

    def test_file_byte_counts_need_evidence_when_type_is_unavailable(self):
        import xml.etree.ElementTree as ET
        app = ET.Element("process", fmt="RemoteCoder (12)")
        rows = [{"process": app, "path": ET.Element("path", fmt=path),
                 "syscall": ET.Element("syscall", fmt=operation), "type": ET.Element("sentinel"),
                 "lwrites": ET.Element("sentinel"), "lreads": ET.Element("sentinel")}
                for path, operation in [("/write", "pwrite"), ("/unknown", "unknown"), ("/stat", "stat64")]]
        with patch.object(trace, "table_rows", return_value=iter(rows)):
            paths = trace.file_activity("x.trace", frozenset({"FsSyscall"}))["paths"]
        self.assertIsNone(paths["/write"]["writtenBytes"])
        self.assertEqual(paths["/write"]["readBytes"], 0)
        self.assertEqual(paths["/write"]["unavailableByteRows"], 1)
        self.assertIsNone(paths["/unknown"]["readBytes"])
        self.assertIsNone(paths["/unknown"]["writtenBytes"])
        self.assertEqual(paths["/unknown"]["unavailableByteRows"], 1)
        self.assertEqual(paths["/stat"]["writtenBytes"], 0)
        self.assertEqual(paths["/stat"]["unavailableByteRows"], 0)

    def test_export_limits_leave_other_measurements_and_json_available(self):
        schemas = {"time-profile", "swiftui-updates", "FsSyscall", "thread-state", "SwiftTaskStateTable",
                   "metal-gpu-intervals", "hitches-updates", "hitches", "hitches-framewait", "OSSignpostIntervals", "processor-trace-intervals"}
        boundaries = {"time-profile": "time-profile", "swiftui-updates": "swiftui", "FsSyscall": "fileActivity",
                      "thread-state": "systemTrace", "SwiftTaskStateTable": "swiftConcurrency",
                      "metal-gpu-intervals": "metal-gpu-intervals", "hitches-updates": "hitches-updates",
                      "hitches": "hitches", "hitches-framewait": "presentedFrames", "OSSignpostIntervals": "TranscriptScroll",
                      "processor-trace-intervals": "processorTrace"}
        original = trace.table_rows
        for schema, boundary in boundaries.items():
            with self.subTest(schema=schema):
                def rows(path, requested, columns):
                    if requested == schema:
                        raise trace.ExportLimitExceeded("fixture export exceeded its budget")
                    return original(path, requested, columns)
                with patch.object(trace, "table_rows", side_effect=rows):
                    result, _ = self.summary(schemas)
                self.assertEqual(result["exportFailures"][boundary]["status"], "exceeds export limit")
                self.assertIn("budget", result["exportFailures"][boundary]["unavailableReason"])
                if schema == "time-profile":
                    self.assertIsNone(result["app"]["cpuMs"])
                    self.assertIsNone(result["app"]["automation"]["samples"])
                    self.assertIsNone(result["appFramesInclusiveMs"])
                else:
                    self.assertEqual(result["app"]["cpuMs"], 1)
                if schema != "swiftui-updates":
                    self.assertEqual(result["swiftui"]["updates"], 3)
                if schema == "processor-trace-intervals":
                    self.assertIsNone(result["processorTrace"]["topAppFunctions"])
                json.dumps(result)

    def test_frame_memory_overflow_preserves_cpu_totals_after_symbolication_or_journey_reduction(self):
        original = trace.frame_statistics
        for stage in ("symbolicate", "journey"):
            with self.subTest(stage=stage):
                exceeded = False
                def symbols(frames, apps):
                    nonlocal exceeded
                    if stage == "symbolicate":
                        exceeded = True
                    return {}, {}
                def statistics(samples, names):
                    nonlocal exceeded
                    if stage == "journey" and len(samples) == 1 and samples[0].time_ns == 1.2e9:
                        exceeded = True
                    return original(samples, names)
                with (patch.object(trace, "symbolicate", side_effect=symbols),
                      patch.object(trace, "frame_statistics", side_effect=statistics),
                      patch.object(trace, "memory_bytes", side_effect=lambda pid: 17 * 2**30 if exceeded else 0)):
                    result, _ = self.summary({"time-profile", "OSSignpostIntervals"}, frames=10, tables={
                        "time-profile": PROFILE_XML,
                        "OSSignpostIntervals": SIGNPOST_XML.replace("TranscriptScroll", "ReplayJourney"),
                    })
                self.assertTrue(exceeded)
                self.assertEqual(result["app"]["cpuMs"], 7)
                self.assertEqual(result["app"]["mainThreadCpuMs"], 7)
                self.assertEqual(result["app"]["automation"]["cpuMs"], 4)
                self.assertEqual(result["exportFailures"]["sampledFrames"]["status"], "exceeds export limit")
                self.assertIn("Python reached", result["frameAnalysisUnavailableReason"])
                for key in ("appFramesInclusiveMs", "mainTopFunctionsSelfMs", "symbolLocations", "journey"):
                    self.assertIsNone(result[key])
                json.dumps(result)

    def test_parser_detaches_rows_and_stops_at_its_python_memory_budget(self):
        original = trace.ET.iterparse
        nodes = []
        def parse(*args, **kwargs):
            for event, element in original(*args, **kwargs):
                if event == "end" and element.tag == "node":
                    nodes.append(element)
                yield event, element
        with patch.object(trace.ET, "iterparse", side_effect=parse), patch.object(trace.subprocess, "Popen", return_value=Export(PROFILE_XML)):
            rows = list(trace.table_rows("x.trace", "time-profile", {"process", "weight", "stack"}))
        self.assertEqual(len(rows), 3)
        self.assertEqual(len(nodes[0].findall("row")), 0)
        self.assertEqual(trace.process_name(rows[1]["process"]), "RemoteCoder")
        with (patch.object(trace.subprocess, "Popen", return_value=Export(PROFILE_XML)),
              patch.object(trace, "memory_bytes", return_value=17 * 2**30),
              self.assertRaisesRegex(trace.ExportLimitExceeded, "Python reached")):
            list(trace.table_rows("x.trace", "time-profile", {"process"}))

    def test_python_memory_alone_can_stop_and_reap_the_export(self):
        child = WaitingExport()
        with (patch.object(trace.subprocess, "Popen", return_value=child),
              patch.object(trace, "memory_bytes", side_effect=lambda pid: 17 * 2**30 if pid == trace.os.getpid() else 0),
              self.assertRaisesRegex(trace.ExportLimitExceeded, "Python reached"),
              trace.guarded_export(["--input", "ios.trace", "--toc"], "profile")):
            child.wait()
        self.assertTrue(child.killed.is_set())

    def test_no_app_samples_are_unavailable_and_fail_recording_report(self):
        result, _ = self.summary({"time-profile"}, tables={"time-profile": PROFILE_XML.replace("RemoteCoder", "OtherApp")})
        self.assertIsNone(result["app"]["cpuMs"])
        self.assertIsNone(result["app"]["cpuMsByThread"])
        with redirect_stdout(io.StringIO()), self.assertRaisesRegex(SystemExit, "no samples for RemoteCoder"):
            trace.report(result, "retry")

    def test_app_frames_survive_renamed_comparison_bundles(self):
        for executable in ("RemoteCoder", "RemoteCoder.debug.dylib"):
            for root in ("/baseline.app", "/baseline.app/Contents/MacOS"):
                main = trace.Frame(0, trace.Binary(executable, "A", "arm64", 0, f"{root}/{executable}"), "parse")
                framework = trace.Frame(0, trace.Binary("WebRTC", "B", "arm64", 0,
                    "/baseline.app/Frameworks/WebRTC.framework/WebRTC"), "decode")
                extension = trace.Frame(0, trace.Binary("Share", "C", "arm64", 0,
                    "/baseline.app/PlugIns/Share.appex/Share"), "share")
                system = trace.Frame(0, trace.Binary("SwiftUICore", "D", "arm64", 0, "/System/SwiftUICore"), "layout")
                unrelated = trace.Frame(0, trace.Binary("Other", "E", "arm64", 0, "/other.app/Other"), "other")
                roots = trace.app_bundle_roots([main, framework, extension, system, unrelated])
                for frame in (main, framework, extension):
                    self.assertEqual(trace.frame_owner(frame, roots), "app")
                for frame in (system, unrelated):
                    self.assertEqual(trace.frame_owner(frame, roots), "system")

    def setUp(self):
        memory = {"hw.memsize": 64 * 2**30, "kern.memorystatus_level": 90}
        for target, stub in (("sysctl_number", memory.__getitem__), ("memory_bytes", lambda pid: 0)):
            patcher = patch.object(trace, target, side_effect=stub)
            patcher.start()
            self.addCleanup(patcher.stop)

    def frames(self, run, scroll):
        _, keys, _ = trace.hitch_updates("recording.trace")
        return trace.presented_frames("recording.trace", run, scroll, keys)

    def summary(self, schemas, gpu_rows="", swiftui_xml=SWIFTUI_XML, platform="macOS", tables=None, frames=0):
        toc = '<trace-toc><run number="1"><info><summary><duration>2</duration><end-reason>Time limit reached</end-reason><start-date>2026-10-08T00:00:00+02:00</start-date></summary><target><device platform="macOS"/><environment><item key="SENTINEL_SECRET" value="fixture-secret-must-not-reach-summary"/></environment></target></info><data>'
        toc = toc.replace('platform="macOS"', f'platform="{platform}"')
        toc += ''.join(f'<table schema="{name}"/>' for name in schemas)
        toc += '</data></run></trace-toc>'
        exported = []

        def export(command, **kwargs):
            if '--toc' in command:
                return Export(toc)
            xpath = command[-1]
            exported.append(xpath)
            for schema, xml in (tables or {}).items():
                if f'"{schema}"' in xpath:
                    return Export(xml)
            if 'swiftui-updates' in xpath:
                return Export(swiftui_xml)
            if 'time-profile' in xpath:
                return Export('''<trace-query-result><node><schema name="time-profile">
<col><mnemonic>process</mnemonic><engineering-type>process</engineering-type></col>
<col><mnemonic>thread</mnemonic><engineering-type>thread</engineering-type></col>
<col><mnemonic>weight</mnemonic><engineering-type>duration</engineering-type></col>
<col><mnemonic>stack</mnemonic><engineering-type>backtrace</engineering-type></col>
</schema><row><process fmt="RemoteCoder (12)"/><thread fmt="Main Thread"/><duration>1000000</duration><backtrace/></row>
<row><process fmt="WindowServer (42)"/><thread/><duration>2000000</duration><backtrace/></row>
</node></trace-query-result>''')
            if 'metal-gpu-intervals' in xpath:
                return Export('''<trace-query-result><node><schema name="metal-gpu-intervals">
<col><mnemonic>process</mnemonic><engineering-type>process</engineering-type></col>
<col><mnemonic>event-depth</mnemonic><engineering-type>uint32</engineering-type></col>
<col><mnemonic>duration</mnemonic><engineering-type>duration</engineering-type></col>
</schema>''' + gpu_rows + '</node></trace-query-result>')
            return Export('<trace-query-result><node/></trace-query-result>')

        with patch.object(trace.subprocess, "Popen", side_effect=export), patch.object(trace, "scroll_receipt", return_value=None):
            result = trace.summarize("recording.trace", frames, [], [])
        return result, exported

    def test_device_swiftui_cli_preflights_then_records_and_reports(self):
        commands = []
        checks = []

        def record(command, **kwargs):
            commands.append(command)
            return Recorder()

        def check(command, **kwargs):
            checks.append(command)
            return subprocess.CompletedProcess(command, 0, '{"SwiftUI":{"enableLayoutTracing":false}}', '')

        with (
            tempfile.TemporaryDirectory() as temporary,
            patch.object(sys, "argv", ["perf-trace", "--host", "local", "record", "ios-swiftui",
                                     "--device", "ipad-udid", "--seconds", "5", "--swiftui"]),
            patch.object(Path, "home", return_value=Path(temporary)),
            patch.object(trace.subprocess, "run", side_effect=check),
            patch.object(trace.subprocess, "Popen", side_effect=record),
            patch.object(trace, "summarize", return_value={"endReason": "Time limit reached", "swiftui": {"updates": 3}, **NO_AUTOMATION}),
            redirect_stdout(io.StringIO()) as output,
        ):
            trace.main()
        self.assertEqual(json.loads(output.getvalue())["swiftui"]["updates"], 3)
        self.assertEqual(len(checks), 1)
        self.assertIn("--show-recording-options", checks[0])
        self.assertEqual(checks[0][checks[0].index("--device") + 1], "ipad-udid")
        self.assertEqual(len(commands), 1)
        self.assertEqual(commands[0][commands[0].index("--device") + 1], "ipad-udid")
        self.assertIn("--all-processes", commands[0])
        self.assertEqual(commands[0].count("SwiftUI"), 1)

    def test_remote_device_swiftui_argument_is_forwarded(self):
        with (
            patch.object(trace, "TEST_DEVICE_HOST", "workstation"),
            patch.object(sys, "argv", ["perf-trace", "record", "ios-swiftui", "--device", "ipad-udid", "--swiftui"]),
            patch.object(trace, "is_local", return_value=False),
            patch.object(trace, "remote", return_value=0) as remote,
            self.assertRaises(SystemExit) as stopped,
        ):
            trace.main()
        self.assertEqual(stopped.exception.code, 0)
        host, arguments = remote.call_args.args
        self.assertEqual(host, "workstation")
        self.assertIn("--swiftui", arguments)
        self.assertEqual(arguments[:2], ["--host", "local"])

    def test_mac_trace_defaults_to_the_mac_gui_host(self):
        with (
            patch.object(trace, "MAC_GUI_HOST", "laptop"),
            patch.object(sys, "argv", ["perf-trace", "record", "mac", "--mac"]),
            patch.object(trace, "is_local", return_value=False),
            patch.object(trace, "remote", return_value=0) as remote,
            self.assertRaises(SystemExit),
        ):
            trace.main()
        self.assertEqual(remote.call_args.args[0], "laptop")

    def test_unsupported_swiftui_template_never_starts_recording(self):
        outcomes = (
            subprocess.CompletedProcess([], 1, '', 'Instrument SwiftUI is unavailable'),
            subprocess.CompletedProcess([], 0, '{"Time Profiler":{}}', ''),
            subprocess.CompletedProcess([], 0, 'invalid JSON', ''),
            subprocess.TimeoutExpired([], 30),
        )
        for outcome in outcomes:
            with (
                self.subTest(outcome=outcome),
                patch.object(trace.subprocess, "run", **({"side_effect": outcome} if isinstance(outcome, Exception)
                                                        else {"return_value": outcome})),
                patch.object(trace.subprocess, "Popen", side_effect=AssertionError("unsupported template must not record")),
                self.assertRaisesRegex(SystemExit, "SwiftUI.*Xcode.*--swiftui"),
                trace.recording(Path("ios.trace"), 5, ["--device", "ipad-udid", "--all-processes"], ["SwiftUI"]),
            ):
                pass

    def test_requested_device_swiftui_without_app_data_fails_with_remedy(self):
        with (
            patch.object(trace.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, '{"SwiftUI":{}}', '')),
            patch.object(trace.subprocess, "Popen", return_value=Recorder()),
            patch.object(trace, "new_trace", return_value=Path("ios.trace")),
            patch.object(trace, "summarize", return_value={"endReason": "Time limit reached", "swiftui": None, **NO_AUTOMATION}),
            redirect_stdout(io.StringIO()),
            self.assertRaisesRegex(SystemExit, "swiftui-updates.*RemoteCoder.*foreground"),
        ):
            trace.record_device("ipad-udid", "ios", 5, 0, [], [], True)

    def test_ios_swiftui_export_resolves_references_filters_process_and_attributes_nanoseconds(self):
        result, exported = self.summary({"time-profile", "swiftui-updates"}, platform="iOS")
        swiftui = result["swiftui"]
        self.assertEqual(swiftui["updates"], 3)
        self.assertEqual(swiftui["updatesPerSecond"], 1.5)
        self.assertEqual(swiftui["updatesByType"], {"View Body": 2, "Platform View": 1})
        self.assertEqual(swiftui["updateMs"], 7)
        self.assertEqual(swiftui["updateMsByType"], {"View Body": 6, "Platform View": 1})
        self.assertEqual(swiftui["topDescriptionsByUpdateMs"], {"TranscriptBubble.body": 6, "Composer": 1})
        self.assertEqual(swiftui["topDescriptions"], {"TranscriptBubble.body": 2, "Composer": 1})
        self.assertEqual(sum('swiftui-updates' in xpath for xpath in exported), 1)

    def test_unavailable_swiftui_duration_stays_unknown_for_its_type_and_view(self):
        for duration in ("<sentinel/>", "<duration/>", "<duration>nan</duration>", "<duration>-1</duration>"):
            with self.subTest(duration=duration):
                xml = SWIFTUI_XML.replace('<duration>1000000</duration>', duration)
                result, _ = self.summary({"time-profile", "swiftui-updates"}, swiftui_xml=xml, platform="iOS")
                self.assertEqual(result["swiftui"]["updates"], 3)
                self.assertIsNone(result["swiftui"]["updateMs"])
                self.assertIsNone(result["swiftui"]["updateMsByType"]["Platform View"])
                self.assertIsNone(result["swiftui"]["topDescriptionsByUpdateMs"]["Composer"])
                self.assertEqual(result["swiftui"]["updatesWithUnavailableDuration"], 1)
                self.assertEqual(result["swiftui"]["updateMsByType"]["View Body"], 6)

    def test_export_deadline_stops_export_while_memory_probe_is_blocked(self):
        export = WaitingExport()
        entered = threading.Event()
        release = threading.Event()
        failures = []

        def blocked_probe(pid):
            entered.set()
            release.wait(3)
            return 0

        def summarize():
            try:
                with trace.guarded_export(["--input", "ios.trace", "--toc"], "SwiftUI"):
                    pass
            except SystemExit as error:
                failures.append(error)

        with (
            patch.object(trace, "EXPORT_TIMEOUT_SECONDS", 0.7),
            patch.object(trace, "memory_bytes", side_effect=blocked_probe),
            patch.object(trace.subprocess, "Popen", return_value=export),
        ):
            owner = threading.Thread(target=summarize)
            owner.start()
            try:
                self.assertTrue(entered.wait(1))
                self.assertTrue(export.killed.wait(0.6), "a blocked memory probe defeated the export deadline")
            finally:
                release.set()
                owner.join(3)
        self.assertFalse(owner.is_alive())
        self.assertEqual(len(failures), 1)
        self.assertIsInstance(failures[0], SystemExit)
        self.assertIn("seconds", str(failures[0]))

    def test_memory_probe_error_or_timeout_stops_and_reaps_export(self):
        for probe, error in (
            ("memory_bytes", subprocess.TimeoutExpired(["ps"], 2)),
            ("memory_bytes", subprocess.CalledProcessError(1, ["ps"])),
            ("sysctl_number", ValueError("invalid memory level")),
        ):
            with self.subTest(probe=probe, error=error):
                export = WaitingExport()

                def fail_probe(value, error=error):
                    if value == "hw.memsize":
                        return 64 * 2**30
                    raise error

                with (
                    patch.object(trace, probe, side_effect=fail_probe),
                    patch.object(trace.subprocess, "Popen", return_value=export),
                    self.assertRaisesRegex(SystemExit, "memory probe.*failed"),
                    trace.guarded_export(["--input", "ios.trace", "--toc"], "SwiftUI"),
                ):
                    pass
                self.assertEqual(export.returncode, -9)

    def test_guard_start_failure_kills_reaps_export_and_joins_started_guards(self):
        thread = threading.Thread
        for failed_guard in (0, 1):
            with self.subTest(failed_guard=failed_guard):
                child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"], stdout=subprocess.PIPE)
                kill = child.kill
                rescue = threading.Timer(1, kill)
                guards = []

                def start_failure():
                    raise RuntimeError("guard start failed")

                def create_guard(*args, guards=guards, failed_guard=failed_guard, **kwargs):
                    guard = thread(*args, **kwargs)
                    if len(guards) == failed_guard:
                        guard.start = start_failure
                    guards.append(guard)
                    return guard

                rescue.start()
                try:
                    with (
                        patch.object(trace.subprocess, "Popen", return_value=child),
                        patch.object(trace.threading, "Thread", side_effect=create_guard),
                        patch.object(child, "kill", wraps=kill) as owned_kill,
                        self.assertRaisesRegex(RuntimeError, "guard start failed"),
                        trace.guarded_export(["--input", "ios.trace", "--toc"], "SwiftUI"),
                    ):
                        pass
                    owned_kill.assert_called_once()
                    self.assertIsNotNone(child.returncode)
                    self.assertLess(child.returncode, 0)
                    self.assertTrue(all(not guard.is_alive() for guard in guards))
                finally:
                    rescue.cancel()
                    rescue.join()
                    kill()
                    child.wait()
                    for guard in guards:
                        if guard.ident is not None:
                            guard.join(2)

    def test_guarded_export_kills_and_reaps_on_time_or_memory_limit(self):
        popen = subprocess.Popen
        for constraint, override, diagnostic in (
            ("time", patch.object(trace, "EXPORT_TIMEOUT_SECONDS", 0.01), "seconds"),
            ("memory", patch.object(trace, "memory_bytes", return_value=17 * 2**30), "GiB"),
        ):
            with self.subTest(constraint=constraint):
                child = popen([sys.executable, "-c", "import time; time.sleep(30)"], stdout=subprocess.PIPE)
                self.addCleanup(child.kill)
                with (
                    override,
                    patch.object(trace.subprocess, "Popen", return_value=child),
                    self.assertRaisesRegex(SystemExit, diagnostic),
                    trace.guarded_export(["--input", "ios.trace", "--toc"], "SwiftUI") as export,
                ):
                    export.stdout.read()
                self.assertIsNotNone(child.returncode)
                self.assertLess(child.returncode, 0)

    def test_summary_output_excludes_the_toc_launch_environment(self):
        with redirect_stdout(io.StringIO()) as output, redirect_stderr(io.StringIO()) as diagnostics:
            result, _ = self.summary({"time-profile"})
            trace.report(result, "record again")
        self.assertEqual(json.loads(output.getvalue())["app"]["cpuMs"], 1)
        emitted = output.getvalue() + diagnostics.getvalue() + json.dumps(result)
        self.assertNotIn("SENTINEL_SECRET", emitted)
        self.assertNotIn("fixture-secret-must-not-reach-summary", emitted)
        self.assertNotIn("<environment>", emitted)

    def test_xctest_automation_samples_are_attributed_and_reject_the_trace(self):
        result, _ = self.summary({"time-profile"}, tables={"time-profile": PROFILE_XML})
        self.assertEqual(result["app"]["cpuMs"], 7)
        self.assertEqual(result["app"]["automation"]["cpuMs"], 4)
        self.assertEqual(result["app"]["automation"]["cpuMsByThread"], {"main": 4})
        with self.assertRaises(SystemExit) as stop:
            trace.reject_automation(result)
        self.assertIn("XCTest automation", str(stop.exception.code))
        clean, _ = self.summary({"time-profile"})
        self.assertEqual(clean["app"]["automation"]["cpuMs"], 0)
        trace.reject_automation(clean)

    def test_motion_windows_select_samples_hitches_and_commits_inside_scroll_signposts(self):
        tables = {"time-profile": PROFILE_XML, "OSSignpostIntervals": SIGNPOST_XML, "hitches": MOTION_HITCH_XML,
                  "hitches-updates": MOTION_UPDATES_XML}
        result, _ = self.summary(set(tables), tables=tables, platform="iOS")
        motion = result["motion"]
        self.assertEqual(motion["intervals"], 1)
        self.assertEqual(motion["seconds"], 0.5)
        self.assertEqual(motion["mainThreadCpuMs"], 4)
        self.assertEqual(motion["automationCpuMs"], 4)
        self.assertEqual(motion["hitches"], 1)
        self.assertEqual(motion["hitchMs"], 25.0)
        self.assertEqual(motion["hitchRateMsPerSecond"], 50.0)
        self.assertEqual(motion["hitchRateRating"], "critical")
        self.assertEqual(motion["commits"], 1)
        self.assertEqual(result["app"]["hitches"], 2)
        self.assertIsNone(result["motionUnavailableReason"])

    def test_motion_counts_only_the_hitch_time_inside_its_windows(self):
        windows = [(1e9, 2e9)]
        crossing = [trace.Hitch(0.9e9, 0.2e9, None), trace.Hitch(1.9e9, 1e9, None), trace.Hitch(2.5e9, 0.1e9, None)]
        motion = trace.motion_summary(windows, [], None, crossing, [], {}, 0)
        self.assertEqual(motion["hitches"], 2)
        self.assertEqual(motion["hitchMs"], 200.0)
        self.assertEqual(motion["hitchRateMsPerSecond"], 200.0)
        self.assertEqual(motion["hitchRateRating"], "severe")

    def test_replay_journey_excludes_samples_outside_its_signpost(self):
        tables = {"time-profile": PROFILE_XML,
                  "OSSignpostIntervals": SIGNPOST_XML.replace("TranscriptScroll", "ReplayJourney")}
        result, _ = self.summary(set(tables), tables=tables, platform="iOS")
        self.assertEqual(result["app"]["cpuMs"], 7)
        self.assertEqual(result["journey"]["mainThreadCpuMs"], 4)
        self.assertEqual(sum(result["journey"]["cpuMsByThread"].values()), 4)
        self.assertNotIn("hitchRateRating", result["journey"])
        self.assertIsNone(result["motion"])

    def test_motion_rows_without_timestamps_make_their_metrics_unknown(self):
        samples = [trace.Sample(None, "main", 100, (), False)]
        motion = trace.motion_summary([(1e9, 2e9)], samples, None, [trace.Hitch(None, 1e8, None)], [None], {}, 0)
        self.assertNotIn("mainThreadCpuMs", motion)
        self.assertIn("1 app samples", motion["cpuUnavailableReason"])
        self.assertNotIn("commits", motion)
        self.assertIn("1 app commits", motion["commitsUnavailableReason"])
        self.assertNotIn("hitchRateMsPerSecond", motion)
        self.assertIn("1 app hitch rows", motion["hitchesUnavailableReason"])

    def test_samples_without_a_weight_make_cpu_unknown(self):
        tables = {"time-profile": PROFILE_XML.replace('<duration id="11">3000000</duration>', '<duration id="11"/>'),
                  "OSSignpostIntervals": SIGNPOST_XML}
        result, _ = self.summary(set(tables), tables=tables, platform="iOS")
        self.assertIsNone(result["app"]["cpuMs"])
        self.assertIsNone(result["app"]["cpuMsByThread"])
        self.assertIn("1 samples without a weight", result["app"]["cpuUnavailableReason"])
        self.assertNotIn("mainThreadCpuMs", result["motion"])
        self.assertEqual(result["motion"]["cpuUnavailableReason"], result["app"]["cpuUnavailableReason"])
        tables["time-profile"] = PROFILE_XML.replace('<duration id="4">4000000</duration>', '<duration id="4"/>')
        result, _ = self.summary(set(tables), tables=tables, platform="iOS")
        self.assertEqual(result["app"]["automation"]["samples"], 1)
        self.assertIsNone(result["app"]["automation"]["cpuMs"])
        with self.assertRaises(SystemExit):
            trace.reject_automation(result)

    def test_missing_motion_signposts_stay_unknown(self):
        result, _ = self.summary({"time-profile"})
        self.assertIsNone(result["motion"])
        self.assertIn("OSSignpostIntervals", result["motionUnavailableReason"])
        result, _ = self.summary({"time-profile", "OSSignpostIntervals"},
                                 tables={"OSSignpostIntervals": SIGNPOST_XML.replace("TranscriptScroll", "Other")})
        self.assertIsNone(result["motion"])
        self.assertIn("TranscriptScroll", result["motionUnavailableReason"])

    def test_time_profiler_only_summary_keeps_uncollected_commit_and_gpu_metrics_unknown(self):
        result, exported = self.summary({"time-profile"})
        self.assertEqual(result["app"]["cpuMs"], 1)
        self.assertIsNone(result["app"]["commits"])
        self.assertIsNone(result["app"]["commitsPerSecond"])
        self.assertIn("hitches-updates", result["app"]["commitsUnavailableReason"])
        self.assertIsNone(result["app"]["gpuMs"])
        self.assertIn("metal-gpu-intervals", result["app"]["gpuMsUnavailableReason"])
        self.assertIsNone(result["renderServer"]["gpuMs"])
        self.assertEqual(result["renderServer"]["gpuMsUnavailableReason"], result["app"]["gpuMsUnavailableReason"])
        self.assertIsNone(result["swiftui"])
        self.assertFalse(any("hitches-updates" in xpath or "metal-gpu-intervals" in xpath or "swiftui-updates" in xpath
                             for xpath in exported))

    def test_empty_gpu_table_is_unknown_while_empty_commits_are_zero(self):
        result, exported = self.summary({"time-profile", "hitches-updates", "metal-gpu-intervals"})
        for key in ("commits", "commitsPerSecond"):
            self.assertEqual(result["app"][key], 0)
        self.assertIsNone(result["app"]["gpuMs"])
        self.assertIsNone(result["app"]["commitsUnavailableReason"])
        self.assertIn("no rows", result["app"]["gpuMsUnavailableReason"])
        self.assertIsNone(result["renderServer"]["gpuMs"])
        self.assertTrue(any("hitches-updates" in xpath for xpath in exported))
        self.assertTrue(any("metal-gpu-intervals" in xpath for xpath in exported))

    def test_unavailable_contributing_gpu_durations_make_each_process_total_unknown(self):
        for duration in ("", "<duration/>", "<sentinel/>", "<duration>nan</duration>"):
            with self.subTest(duration=duration):
                rows = ''.join(
                    f'<row><process fmt="{process} (12)"/><uint32>0</uint32><duration>1000000</duration></row>'
                    f'<row><process fmt="{process} (12)"/><uint32>0</uint32>{duration}</row>'
                    for process in ("RemoteCoder", "WindowServer")
                )
                result, _ = self.summary({"time-profile", "metal-gpu-intervals"}, rows)
                for process, key in (("RemoteCoder", "app"), ("WindowServer", "renderServer")):
                    self.assertIsNone(result[key]["gpuMs"])
                    self.assertIn("unavailable duration", result[key]["gpuMsUnavailableReason"])
                    self.assertIn(process, result[key]["gpuMsUnavailableReason"])

    def test_known_gpu_durations_preserve_zero_and_ignore_nested_intervals(self):
        rows = '''<row><process fmt="RemoteCoder (12)"/><uint32>0</uint32><duration>0</duration></row>
<row><process fmt="RemoteCoder (12)"/><uint32>1</uint32><sentinel/></row>
<row><process fmt="WindowServer (42)"/><uint32>0</uint32><duration>2000000</duration></row>'''
        result, _ = self.summary({"time-profile", "metal-gpu-intervals"}, rows)
        self.assertEqual(result["app"]["gpuMs"], 0)
        self.assertEqual(result["renderServer"]["gpuMs"], 2)
        for key in ("app", "renderServer"):
            self.assertIsNone(result[key]["gpuMsUnavailableReason"])

    def test_hitch_columns_references_units_and_process_filter(self):
        with patch.object(trace.subprocess, "Popen", return_value=Export(HITCH_XML)):
            result = trace.app_hitches(trace.app_hitch_rows("recording.trace", frozenset({"hitches"})))
        self.assertEqual(result["hitches"], 4)
        self.assertEqual(result["hitchMs"], 66.7)
        self.assertEqual(result["hitchesByType"], {
            "commit": {"count": 1, "ms": 16.7}, "commit+render": {"count": 1, "ms": 25.0},
            "render": {"count": 1, "ms": 16.7}, "unknown": {"count": 1, "ms": 8.3},
        })

    def test_missing_hitch_duration_or_table_is_unknown(self):
        with patch.object(trace.subprocess, "Popen", return_value=Export(HITCH_XML.replace('<duration id="7">8333333</duration>', '<sentinel/>'))):
            result = trace.app_hitches(trace.app_hitch_rows("recording.trace", frozenset({"hitches"})))
        self.assertEqual(result["hitches"], 4)
        self.assertIsNone(result["hitchMs"])
        self.assertIsNone(result["hitchesByType"]["unknown"]["ms"])
        with patch.object(trace.subprocess, "Popen", side_effect=AssertionError("missing table must not export")):
            self.assertIsNone(trace.app_hitches(trace.app_hitch_rows("recording.trace", frozenset()))["hitches"])

    def test_subset_wait_rows_never_claim_presentation_cadence(self):
        run = trace.Run(1, "Time limit reached", "macOS", frozenset({"hitches-updates", "hitches-framewait"}), "2026-10-05T10:00:00+02:00")
        scroll = {"status": "completed", "startedAt": "2026-10-05T08:00:00.009+00:00", "endedAt": "2026-10-05T08:00:00.020+00:00"}
        with patch.object(trace.subprocess, "Popen", side_effect=[Export(UPDATES_XML), Export(WAIT_XML)]):
            result = self.frames(run, scroll)
        for key in ("medianMs", "p95Ms", "within120HzShare", "within60HzShare", "effectiveFpsWhileScrolling"):
            self.assertIsNone(result[key])
        waits = result["frameWait"]["wholeTrace"]["Display 1"]
        self.assertEqual(waits["waitDurations"], {"count": 2, "medianMs": 1.5, "p95Ms": 2.0})
        self.assertEqual(waits["observedWaitEndIntervals"], {"count": 1, "medianMs": 8.333, "p95Ms": 8.333})
        self.assertEqual(result["frameWait"]["whileScrolling"]["Display 1"], waits)

    def test_scroll_window_filters_wait_ends_using_trace_origin_and_timezone(self):
        run = trace.Run(1, "Time limit reached", "macOS", frozenset({"hitches-updates", "hitches-framewait"}), "2026-10-05T10:00:00+02:00")
        scroll = {"status": "completed", "startedAt": "2026-10-05T08:00:00.015+00:00", "endedAt": "2026-10-05T08:00:00.020+00:00"}
        with patch.object(trace.subprocess, "Popen", side_effect=[Export(UPDATES_XML), Export(WAIT_XML)]):
            result = self.frames(run, scroll)
        waits = result["frameWait"]["whileScrolling"]["Display 1"]
        self.assertEqual(waits["waitDurations"], {"count": 1, "medianMs": 1, "p95Ms": 1})
        self.assertIsNone(waits["observedWaitEndIntervals"])

    def test_nanosecond_distribution_p95_and_missing_values(self):
        result = trace.interval_statistics([8333333, 16666667, 25000000, 8333333])
        self.assertEqual(result, {"count": 4, "medianMs": 12.5, "p95Ms": 25})
        self.assertIsNone(trace.interval_statistics([]))
        run = trace.Run(1, "Time limit reached", "macOS", frozenset(), "2026-10-05T10:00:00+02:00")
        with patch.object(trace.subprocess, "Popen", side_effect=AssertionError("missing table must not export")):
            result = trace.presented_frames("recording.trace", run, None, set())
        self.assertIsNone(result["frameWait"])
        self.assertIsNone(result["effectiveFpsWhileScrolling"])


class MemoryProbeTests(unittest.TestCase):
    def test_memory_counts_compressed_footprint_and_resident_pages(self):
        for resident, footprint in ((4, 62), (14, 8)):
            def read(pid, flavor, pointer):
                usage = trace.ctypes.cast(pointer, trace.ctypes.POINTER(trace.ProcessUsage)).contents
                usage.resident_size = resident * 2**30
                usage.phys_footprint = footprint * 2**30
                return 0

            with self.subTest(resident=resident, footprint=footprint), patch.object(trace, "process_usage_reader", return_value=read):
                self.assertEqual(trace.memory_bytes(123), max(resident, footprint) * 2**30)

    def test_failed_native_probe_does_not_report_zero_memory(self):
        with (patch.object(trace, "process_usage_reader", return_value=lambda *args: -1),
              patch.object(trace.ctypes, "get_errno", return_value=3),
              self.assertRaises(OSError)):
            trace.memory_bytes(123)

    def test_monitoring_commands_timeout_and_reap_delayed_children(self):
        run = subprocess.run

        def delayed_command(command, **kwargs):
            return run([sys.executable, "-c", "import time; time.sleep(0.2); print(0)"], **kwargs)

        with (patch.object(trace, "PROBE_TIMEOUT_SECONDS", 0.01),
              patch.object(trace.subprocess, "run", side_effect=delayed_command),
              self.assertRaises(subprocess.TimeoutExpired)):
            trace.sysctl_number("hw.memsize")


class RecordingGuardTests(unittest.TestCase):
    def setUp(self):
        memory = {"hw.memsize": 64 * 2**30, "kern.memorystatus_level": 90}
        patcher = patch.object(trace, "sysctl_number", side_effect=memory.__getitem__)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_recording_post_processing_is_bounded_and_owned_scratch_is_removed(self):
        popen = subprocess.Popen
        exceeded = threading.Event()
        children = []
        scratch_paths = []

        def launch(command, **kwargs):
            scratch_paths.append(Path(kwargs["env"]["TMPDIR"]))
            program = ("import os,time; from pathlib import Path; "
                       "Path(os.environ['TMPDIR'], 'instruments.ktrace').write_bytes(b'trace'); "
                       "print('Ctrl-C to stop the recording', flush=True); "
                       "print('Time limit reached', flush=True); time.sleep(30)")
            child = popen([sys.executable, "-c", program], **kwargs)
            children.append(child)
            return child

        def memory(pid):
            return 17 * 2**30 if exceeded.is_set() and pid != trace.os.getpid() else 0

        with tempfile.TemporaryDirectory() as unrelated:
            retained = Path(unrelated) / "instruments-other.ktrace"
            retained.write_bytes(b"other capture")
            with (patch.object(trace.subprocess, "Popen", side_effect=launch),
                  patch.object(trace, "memory_bytes", side_effect=memory),
                  self.assertRaisesRegex(trace.ExportLimitExceeded, "recording.*GiB")):
                with trace.recording(Path("fixture.trace"), 1, ["--attach", "RemoteCoder"], []):
                    self.assertTrue((scratch_paths[0] / "instruments.ktrace").exists())
                    rescue = threading.Timer(3, children[0].kill)
                    rescue.start()
                    self.addCleanup(rescue.cancel)
                    exceeded.set()
            self.assertEqual(children[0].returncode, -9)
            self.assertFalse(scratch_paths[0].exists())
            self.assertEqual(retained.read_bytes(), b"other capture")
            rescue.cancel()
            rescue.join()

    def test_scratch_is_removed_after_success_and_consumer_failure(self):
        for fail in (False, True):
            paths = []

            def launch(command, **kwargs):
                scratch = Path(kwargs["env"]["TMPDIR"])
                (scratch / "instruments.ktrace").touch()
                paths.append(scratch)
                return Recorder()

            with (self.subTest(fail=fail), patch.object(trace.subprocess, "Popen", side_effect=launch),
                  patch.object(trace, "memory_bytes", return_value=0)):
                expected = self.assertRaisesRegex(ValueError, "consumer failed") if fail else nullcontext()
                with expected, trace.recording(Path("fixture.trace"), 1, [], []):
                    if fail:
                        raise ValueError("consumer failed")
                self.assertFalse(paths[0].exists())


if __name__ == "__main__":
    unittest.main()
