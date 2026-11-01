import argparse
import hashlib
import importlib.machinery
import importlib.util
import json
import math
import re
import statistics
import sys
from collections import Counter
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('trace', type=Path)
parser.add_argument('--repo', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--commands', type=Path, required=True)
parser.add_argument('--device', required=True)
args = parser.parse_args()
expected_counts = dict.fromkeys(('press', 'semantic', 'drawer', 'context-check'), 0)
for command in json.loads(args.commands.read_text()):
    if 'error' in command:
        raise ValueError('command receipt contains an error')
    if command['cmd'] == 'drawer-drag':
        expected_counts['drawer'] += 1
    elif command['cmd'] == 'haptic-probe':
        kind = command['kind']
        if kind == 'semantic' and expected_counts['drawer']:
            kind = 'context-check'
        if kind not in expected_counts or expected_counts[kind]:
            raise ValueError('unsupported repeated or unknown probe command')
        count = command['count']
        if type(count) is not int or count < 1:
            raise ValueError('probe count must be a positive integer')
        expected_counts[kind] = count
sys.path.insert(0, str(args.repo / 'scripts'))
loader = importlib.machinery.SourceFileLoader('haptic_report_trace', str(args.repo / 'scripts/perf-trace'))
spec = importlib.util.spec_from_loader(loader.name, loader)
pt = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = pt
loader.exec_module(pt)

def distribution(values):
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * .95
    low, high = math.floor(position), math.ceil(position)
    return {'n': len(values), 'minMs': min(values) / 1e6,
            'medianMs': statistics.median(values) / 1e6,
            'p95Ms': (ordered[low] + (ordered[high] - ordered[low]) * (position - low)) / 1e6,
            'maxMs': max(values) / 1e6, 'p95Method': 'linear interpolation'}

with pt.exclusive_host():
    with pt.guarded_export(['--input', str(args.trace), '--toc'], 'haptic toc') as export:
        toc = export.stdout.read()
        args.output.with_suffix('.toc.xml').write_bytes(toc)
    points = []
    raw_points = []
    seen = set()
    columns = {'time', 'process', 'event-type', 'name', 'subsystem', 'category', 'message'}
    for row in pt.table_rows(str(args.trace), 'os-signpost', columns):
        if pt.process_name(row.get('process')) != 'RemoteCoder':
            continue
        if pt.element_text(row.get('subsystem')) != 'RemoteCoder' or pt.element_text(row.get('category')) != 'Haptics':
            continue
        name = pt.element_text(row.get('name'))
        if name not in {'haptic-probe-input', 'drawer-gesture-end', 'feedback-intent', 'feedback-api-request'}:
            continue
        timestamp = pt.trace_number(row.get('time'))
        message = pt.element_text(row.get('message')) or ''
        raw_points.append({'ns': timestamp, 'name': name, 'message': message})
        key = (timestamp, name, message)
        if key in seen:
            continue
        seen.add(key)
        points.append({'ns': timestamp, 'name': name, 'message': message})
points.sort(key=lambda point: point['ns'])
args.output.with_suffix('.raw-events.json').write_text(json.dumps(raw_points, indent=2))
if not points:
    raise RuntimeError('no Haptics point events exported')
args.output.with_suffix('.events.json').write_text(json.dumps(points, indent=2))
boundaries = [i for i, point in enumerate(points) if point['name'] in {'haptic-probe-input', 'drawer-gesture-end'}]
trials = []
drawer_index = 0
for boundary_index, point_index in enumerate(boundaries):
    point = points[point_index]
    next_index = boundaries[boundary_index + 1] if boundary_index + 1 < len(boundaries) else len(points)
    if point['name'] == 'drawer-gesture-end':
        kind, index, expected = 'drawer', drawer_index, 'selection'
        drawer_index += 1
    else:
        match = re.fullmatch(r'(press|semantic) index=(\d+)', point['message'])
        if not match:
            raise ValueError(f"unrecognized input message: {point['message']}")
        kind, index = match[1], int(match[2])
        expected = 'buttonPress' if kind == 'press' else 'commit'
        if kind == 'semantic' and drawer_index:
            kind = 'context-check'
    candidates = points[point_index + 1:next_index]
    intents = [p for p in candidates if p['name'] == 'feedback-intent' and p['message'].split(' ')[0] == expected]
    requests = [p for p in candidates if p['name'] == 'feedback-api-request' and p['message'].split(' ')[0] == expected]
    trial = {'kind': kind, 'index': index, 'event': expected, 'inputNs': point['ns'],
             'intents': intents, 'requests': requests}
    if len(intents) != 1:
        trial['status'] = 'missing-intent' if not intents else 'ambiguous-intents'
    elif not re.search(r'\beligible=(true|false|0|1)(\s|$)', intents[0]['message']):
        trial['status'] = 'unknown-eligibility'
    elif re.search(r'\beligible=(false|0)(\s|$)', intents[0]['message']):
        trial['status'] = 'ineligible'
    elif len(requests) != 1:
        trial['status'] = 'eligible-no-request' if not requests else 'ambiguous-requests'
    else:
        trial['status'] = 'paired'
        trial['inputToRequestNs'] = requests[0]['ns'] - point['ns']
        trial['intentToRequestNs'] = requests[0]['ns'] - intents[0]['ns']
        if trial['inputToRequestNs'] < 0 or trial['intentToRequestNs'] < 0:
            raise ValueError('negative paired latency')
    trials.append(trial)
report = {'trace': str(args.trace), 'pointCounts': dict(Counter(p['name'] for p in points)),
          'deviceUDID': args.device,
          'reportScriptSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
          'commandReceipts': str(args.commands),
          'commandReceiptsSHA256': hashlib.sha256(args.commands.read_bytes()).hexdigest(),
          'rawMatchedRows': len(raw_points), 'duplicateRowsDropped': len(raw_points) - len(points),
          'expectedInputs': expected_counts,
          'pairing': 'one matching event intent/request after each input and before the next input; ineligible excluded',
          'physicalTouch': False, 'actuatorOnset': 'unmeasured', 'trials': trials, 'groups': {}}
for kind in ('press', 'semantic', 'drawer', 'context-check'):
    selected = [t for t in trials if t['kind'] == kind]
    paired = [t for t in selected if t['status'] == 'paired']
    report['groups'][kind] = {'statuses': dict(Counter(t['status'] for t in selected)),
        'observedIndices': [t['index'] for t in selected],
        'missingInputIndices': sorted(set(range(expected_counts[kind])) - {t['index'] for t in selected}),
        'missingInputCount': max(0, expected_counts[kind] - len(selected)),
        'inputToRequest': distribution([t['inputToRequestNs'] for t in paired]),
        'intentToRequest': distribution([t['intentToRequestNs'] for t in paired]),
        'firstSampleInputToRequestMs': next((t['inputToRequestNs'] / 1e6 for t in paired if t['index'] == 0), None),
        'remainingInputToRequest': distribution([t['inputToRequestNs'] for t in paired if t['index'] != 0]),
        'remainingIntentToRequest': distribution([t['intentToRequestNs'] for t in paired if t['index'] != 0])}
family = re.compile(r'UI(?:Impact|Selection|Notification)?FeedbackGenerator|_UIFeedback', re.I)
swiftui = re.compile(r'SensoryFeedback', re.I)
playback = re.compile(r'play|trigger|generate|impactOccurred|selectionChanged|notificationOccurred', re.I)
matches = []
weights = set()
app_samples = 0
unnamed_frames = 0
with pt.exclusive_host():
    for row in pt.table_rows(str(args.trace), 'time-profile', {'time', 'thread', 'process', 'weight', 'stack'}):
        if pt.process_name(row.get('process')) != 'RemoteCoder':
            continue
        app_samples += 1
        weight = pt.trace_number(row.get('weight'))
        if weight is not None:
            weights.add(weight / 1e6)
        stack = row.get('stack')
        if not isinstance(stack, tuple):
            continue
        unnamed_frames += sum(not frame.name for frame in stack)
        frames = [frame.name for frame in stack if family.search(frame.name) or
                  (swiftui.search(frame.name) and playback.search(frame.name))]
        if frames:
            matches.append({'ns': pt.trace_number(row.get('time')),
                            'thread': pt.element_text(row.get('thread')), 'frames': frames})
for index, trial in enumerate(trials):
    end = trials[index + 1]['inputNs'] if index + 1 < len(trials) else float('inf')
    intent = next(iter(trial['intents']), None)
    trial['sampledFeedback'] = next((sample | {'intentToSampleMs': (sample['ns'] - intent['ns']) / 1e6}
        for sample in sorted(matches, key=lambda sample: sample['ns'])
        if intent and intent['ns'] <= sample['ns'] < end and 'Main Thread' in (sample['thread'] or '')), None)
report['sampledFeedback'] = {'scope': 'sampled feedback-family or SwiftUI sensory-playback stack, not API onset',
                             'appSamplesScanned': app_samples, 'unnamedFrames': unnamed_frames,
                             'sampleWeightsMs': sorted(weights), 'matchingSamples': matches,
                             'coveredTrials': {kind: sum(t['kind'] == kind and t['sampledFeedback'] is not None for t in trials)
                                               for kind in ('press', 'semantic', 'drawer')}}
args.output.write_text(json.dumps(report, indent=2))
print(json.dumps(report['groups'], indent=2))
print(json.dumps(report['sampledFeedback'], indent=2))
