import importlib.machinery
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import threading
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader("perf_trace", str(Path(__file__).resolve().parents[1] / "perf-trace"))
spec = importlib.util.spec_from_loader(loader.name, loader)
trace = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = trace
loader.exec_module(trace)


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
        self.stdout = io.StringIO("Ctrl-C to stop the recording\nTime limit reached\n")
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


NO_AUTOMATION = {"app": {"automation": {"samples": 0}}}


class PerfTraceTests(unittest.TestCase):
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
        for target, stub in (("sysctl_number", memory.__getitem__), ("resident_bytes", lambda pid: 0)):
            patcher = patch.object(trace, target, side_effect=stub)
            patcher.start()
            self.addCleanup(patcher.stop)

    def frames(self, run, scroll):
        _, keys, _ = trace.hitch_updates("recording.trace")
        return trace.presented_frames("recording.trace", run, scroll, keys)

    def summary(self, schemas, gpu_rows="", swiftui_xml=SWIFTUI_XML, platform="macOS", tables=None):
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
            result = trace.summarize("recording.trace", 0, [], [])
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
            patch.object(trace, "resident_bytes", side_effect=blocked_probe),
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
            ("resident_bytes", subprocess.TimeoutExpired(["ps"], 2)),
            ("resident_bytes", subprocess.CalledProcessError(1, ["ps"])),
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
            ("memory", patch.object(trace, "resident_bytes", return_value=17 * 2**30), "GiB"),
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

    def test_collected_empty_tables_remain_measured_zero(self):
        result, exported = self.summary({"time-profile", "hitches-updates", "metal-gpu-intervals"})
        for key in ("commits", "commitsPerSecond", "gpuMs"):
            self.assertEqual(result["app"][key], 0)
        self.assertIsNone(result["app"]["commitsUnavailableReason"])
        self.assertIsNone(result["app"]["gpuMsUnavailableReason"])
        self.assertEqual(result["renderServer"]["gpuMs"], 0)
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
    def test_monitoring_commands_timeout_and_reap_delayed_children(self):
        run = subprocess.run

        def delayed_command(command, **kwargs):
            return run([sys.executable, "-c", "import time; time.sleep(0.2); print(0)"], **kwargs)

        for probe, value in ((trace.sysctl_number, "hw.memsize"), (trace.resident_bytes, 123)):
            with (
                self.subTest(probe=probe.__name__),
                patch.object(trace, "PROBE_TIMEOUT_SECONDS", 0.01),
                patch.object(trace.subprocess, "run", side_effect=delayed_command),
                self.assertRaises(subprocess.TimeoutExpired),
            ):
                probe(value)


if __name__ == "__main__":
    unittest.main()
