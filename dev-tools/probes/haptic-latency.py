import argparse
import contextlib
import hashlib
import importlib.machinery
import importlib.util
import json
import sys
import time
from pathlib import Path

from remotecoder_tools import perf_harness as p

parser = argparse.ArgumentParser()
parser.add_argument('label')
parser.add_argument('--device', required=True)
parser.add_argument('--fixture', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
p.configure_identity()
root = args.output.expanduser()
root.mkdir(parents=True, exist_ok=True)
fixture = args.fixture.expanduser()
loader = importlib.machinery.SourceFileLoader('haptic_perf_trace', str(p.ROOT / 'scripts/perf-trace'))
spec = importlib.util.spec_from_loader(loader.name, loader)
pt = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = pt
loader.exec_module(pt)
receipts = []

def send(device, command, timeout=45):
    result = p.send(device, command, timeout)
    receipts.append(result)
    (root / f'{args.label}-commands.json').write_text(json.dumps(receipts, indent=2))
    print(json.dumps(result), flush=True)
    if result is None or 'error' in result:
        raise RuntimeError('harness command failed')
    return result

with p.source_lease(), p.device_lease(args.device), contextlib.ExitStack() as cleanup:
    device = p.Device(args.device, ['-rcPerfOffline'], 'development')
    cleanup.callback(device.terminate)
    identity = json.loads((device.derived / 'perf-build-identity.json').read_text())
    p.verify_scenario_artifact(device, identity)
    evidence = {'artifact': identity, 'driverSHA256': p.DRIVER_SHA256,
                'journeySHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                'fixtureSHA256': hashlib.sha256(fixture.read_bytes()).hexdigest(),
                'physicalTouch': False, 'actuatorOnset': 'unmeasured'}
    (root / f'{args.label}-identity.json').write_text(json.dumps(evidence, indent=2))
    device.install()
    device.terminate()
    device.launch()
    time.sleep(3)
    p.stage_scenario(device, fixture, json.loads(fixture.read_text()))
    send(device, {'cmd': 'scenario-load'}, 120)
    send(device, {'cmd': 'status'})
    with pt.exclusive_host():
        trace = pt.new_trace(args.label)
        with pt.recording(trace, 120, ['--device', device.udid, '--all-processes'],
                          pt.selected_instruments('Time Profiler', False, ['os_signpost'], False)):
            send(device, {'cmd': 'haptic-probe', 'kind': 'press', 'count': 30})
            send(device, {'cmd': 'haptic-probe', 'kind': 'semantic', 'count': 30})
            for index in range(20):
                direction = 1 if index % 2 == 0 else -1
                send(device, {'cmd': 'drawer-drag', 'travel': direction * 0.7,
                              'seconds': 0.2, 'velocity': direction * 0.4})
            send(device, {'cmd': 'haptic-probe', 'kind': 'semantic', 'count': 1})
        summary = pt.summarize(str(trace), 0, [], [])
        (root / f'{args.label}-trace-summary.json').write_text(json.dumps(summary, indent=2))
        pt.reject_automation(summary)
        pt.require_app_measurement(summary)
        if summary['endReason'] != pt.TRACE_COMPLETE:
            raise RuntimeError(f"incomplete trace: {summary['endReason']}")
