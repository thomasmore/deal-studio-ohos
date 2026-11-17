#!/usr/bin/env python3
"""Measure fresh generations through the installed native app, without force-stop.

The app's USB VPN remains up. Each request starts from the unsaved home creation
flow; no saved project is opened or overwritten. Only app-shell controls and
suggested planning answers are tapped, never controls in the generated program.
Provider/model configuration is not changed. Raw traces stay in the private outdir.

Example:
  python3 tools/vera-bench/device-baseline.py --out /private/baseline \
    --corpus /private/baseline/prompts.json --hdc /path/to/hdc

Run baseline-report.py on the same directory to regenerate CSV/JSON/HTML reports.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time

BUNDLE = 'com.vera.probe.dyn'
FILES = f'/data/app/el2/100/base/{BUNDLE}/haps/entry/files'
TRACE = f'{FILES}/vera/trace.jsonl'


def atomic_json(path, value):
    tmp = path.with_suffix(path.suffix + '.tmp')
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    tmp.replace(path)


def walk(value):
    if isinstance(value, dict):
        if 'attributes' in value:
            yield value['attributes']
        for item in value.values():
            if isinstance(item, (dict, list)):
                yield from walk(item)
    elif isinstance(value, list):
        for item in value:
            yield from walk(item)


def center(node):
    x1, y1, x2, y2 = map(int, re.findall(r'-?\d+', node['bounds']))
    return (x1 + x2) // 2, (y1 + y2) // 2


def parse_trace(raw):
    events = []
    for line in raw.split('\n'):
        if line.strip():
            try:
                event = json.loads(line)
                if isinstance(event, dict):
                    events.append(event)
            except json.JSONDecodeError:
                # A write may be in flight. A final malformed line is recorded separately.
                pass
    return events


def summarize(row, events, status, elapsed, questions):
    starts = [e for e in events if e.get('event') == 'gen-start']
    start = starts[0] if starts else None
    end = next((e for e in reversed(events) if e.get('event') == 'gen-end'), None)
    turns = [e for e in events if e.get('event') == 'turn']  # All sources, not just src=gen.
    measured = [e for e in turns if e.get('inTok', 0) > 0 or e.get('outTok', 0) > 0]
    compiles = [e for e in events if e.get('event') == 'compile']
    compose = next((e for e in reversed(events) if e.get('event') == 'compose'), {})
    wall = end['at'] - start['at'] if start and end else None
    waited = end.get('waitedMs', 0) if end else 0
    sources = sorted({e.get('src', 'unknown') for e in turns})
    known = lambda key: sum(e.get(key, 0) for e in measured) if measured else None
    return {
        **{k: row.get(k) for k in ['id', 'prompt', 'domain', 'split', 'phrasing', 'negative', 'intentId', 'expect']},
        'status': status, 'built': bool(end and end.get('ok')),
        'wall_ms': wall, 'active_ms': max(0, wall - waited) if wall is not None else None,
        'waited_ms': waited, 'observed_until_stop_ms': round(elapsed * 1000),
        'input_tokens': known('inTok'), 'output_tokens': known('outTok'),
        'cached_input_tokens': known('cachedTok'), 'reasoning_tokens': known('reasonTok'),
        'token_scope': 'reported DeepSeek turns, every source and retry; TypeSafe selector usage unavailable',
        'token_totals_partial': True,
        'traced_model_calls': len(turns), 'calls_with_reported_usage': len(measured),
        'model_sources': sources, 'sum_model_call_ms': sum(e.get('totalMs', 0) for e in turns),
        'compile_events': len(compiles), 'failed_compile_events': sum(not e.get('ok') for e in compiles),
        'first_preview_ms': compose.get('firstPreviewMs') or None,
        'route': (end or {}).get('via', ''), 'failure': (end or {}).get('failure', ''),
        'note': compose.get('note', ''), 'questions_answered': len(questions),
        'generation_starts': len(starts), 'fresh': bool(start and not start.get('refining')),
        'prompt_exact': bool(start and start.get('prompt') == row['prompt']),
        'dropped': (end or {}).get('dropped', ''),
    }


class Device:
    def __init__(self, hdc, serial, out):
        self.command = [hdc] + (['-t', serial] if serial else [])
        self.out = out

    def call(self, *args, timeout=25):
        p = subprocess.run(self.command + list(args), capture_output=True, text=True, timeout=timeout)
        if p.returncode:
            raise RuntimeError(f'hdc {args[0]} failed: {p.stderr.strip()[:200]}')
        return p.stdout

    def shell(self, command):
        return self.call('shell', command)

    def layout(self):
        self.shell('uitest dumpLayout -p /data/local/tmp/vera-baseline-ui.json >/dev/null')
        local = self.out / 'ui-current.json'
        local.unlink(missing_ok=True)
        self.call('file', 'recv', '/data/local/tmp/vera-baseline-ui.json', str(local))
        return list(walk(json.loads(local.read_text())))

    def tap(self, node):
        x, y = center(node)
        self.shell(f'uitest uiInput click {x} {y}')

    def network(self):
        status = self.shell(f'cat {FILES}/usbnet-status.txt 2>/dev/null').strip()
        interface = self.shell('ip -o -4 addr show vpn-tun 2>/dev/null').strip()
        return {'status': status, 'interface': interface,
                'ok': 'connected' in status and '10.0.0.2/32' in interface}

    def home(self):
        for _ in range(6):
            rows = self.layout()
            if any(a.get('hint') == 'Describe the app…' for a in rows) and any(a.get('text') == 'What shall we make?' for a in rows):
                return rows
            texts = {a.get('text') for a in rows}
            if 'Save this app?' in texts or 'Leave without generating?' in texts:
                discard = next((a for a in rows if a.get('text') == 'Discard'), None)
                if discard is None:
                    raise RuntimeError('Native leave dialog has no Discard control')
                self.tap(discard)
            else:
                self.shell('uitest uiInput keyEvent Back')
            time.sleep(.4)
        raise RuntimeError('Cannot reach unsaved app creation flow safely')

    def submit(self, row, directory):
        rows = self.home()
        field = next(a for a in rows if a.get('hint') == 'Describe the app…')
        x, y = center(field)
        self.shell(f'uitest uiInput inputText {x} {y} ' + shlex.quote(row['prompt']))
        rows = self.layout()
        field = next((a for a in rows if a.get('type') == 'TextArea' and a.get('text') == row['prompt']), None)
        if field is None:
            raise RuntimeError('Typed prompt differs from corpus; refusing to submit')
        buttons = [a for a in rows if a.get('type') == 'Button' and a.get('enabled') == 'true'
                   and a.get('hostWindowId') == field.get('hostWindowId') and center(a)[1] > center(field)[1]]
        if len(buttons) != 1:
            raise RuntimeError(f'Expected one native submit button below home prompt, found {len(buttons)}')
        offset = int(self.shell(f'wc -c < {TRACE} 2>/dev/null || echo 0').strip())
        capture = {'trace_offset': offset, 'submission_host_time': time.time(),
                   'submission_button': buttons[0]['bounds']}
        atomic_json(directory / 'capture.json', capture)
        self.tap(buttons[0])
        return capture

    def suggested_answer(self, questions):
        rows = self.layout()
        if not any(a.get('hint') == 'Or type your own answer' for a in rows):
            return
        suggestion = next((a for a in rows if a.get('text', '').endswith(' (suggested)')
                           and a.get('type') == 'Button'), None)
        if suggestion:
            questions.append({'at_host': time.time(), 'answer': suggestion['text']})
            self.tap(suggestion)

    def screenshot(self, directory):
        self.shell('snapshot_display -f /data/local/tmp/vera-baseline.jpeg >/dev/null')
        target = directory / 'screen.jpeg'
        target.unlink(missing_ok=True)
        self.call('file', 'recv', '/data/local/tmp/vera-baseline.jpeg', str(target))
        if not target.exists() or target.stat().st_size == 0:
            raise RuntimeError('Device screenshot was not produced')


def run_case(device, row, out, timeout):
    directory = out / 'runs' / row['id']
    directory.mkdir(parents=True, exist_ok=True)
    atomic_json(directory / 'prompt.json', row)
    net = device.network()
    atomic_json(directory / 'network-before.json', net)
    if not net['ok']:
        raise RuntimeError('USB VPN is not connected; batch paused before generation')
    capture_file = directory / 'capture.json'
    capture = json.loads(capture_file.read_text()) if capture_file.exists() else device.submit(row, directory)
    began = time.monotonic()
    questions, raw, events = [], '', []
    status = 'timeout'
    last_ui = last_wake = -100.0
    while time.monotonic() - began < timeout:
        raw = device.shell(f'tail -c +{capture["trace_offset"] + 1} {TRACE}')
        events = parse_trace(raw)
        starts = [e for e in events if e.get('event') == 'gen-start']
        if starts and (len(starts) != 1 or starts[0].get('prompt') != row['prompt'] or starts[0].get('refining')):
            raise RuntimeError('Trace is not exactly one fresh generation of the frozen prompt; batch paused')
        if any(e.get('event') == 'gen-end' for e in events):
            status = 'completed'
            break
        elapsed = time.monotonic() - began
        if not starts and elapsed > 20:
            status = 'submission_failed'
            break
        if elapsed - last_wake >= 20:
            device.shell('power-shell wakeup >/dev/null')
            last_wake = elapsed
        if elapsed - last_ui >= 6:
            device.suggested_answer(questions)
            atomic_json(directory / 'questions.json', questions)
            last_ui = elapsed
        time.sleep(2)
    # Capture before navigation; do not discard a timed-out run until evidence is safe.
    (directory / 'trace.jsonl').write_text(raw)
    atomic_json(directory / 'questions.json', questions)
    rows = device.layout()
    atomic_json(directory / 'ui.json', rows)
    try:
        device.screenshot(directory)
    except Exception as error:
        (directory / 'screenshot-error.txt').write_text(str(error))
    after = device.network()
    atomic_json(directory / 'network-after.json', after)
    if status == 'timeout':
        device.home()  # The native Discard action cancels it, without killing the VPN.
        time.sleep(2)
        raw = device.shell(f'tail -c +{capture["trace_offset"] + 1} {TRACE}')
        (directory / 'trace.jsonl').write_text(raw)
        events = parse_trace(raw)
    result = summarize(row, events, status, time.monotonic() - began, questions)
    result['usb_network_before'] = net['ok']
    result['usb_network_after'] = after['ok']
    result['trace_parse_errors'] = sum(1 for line in raw.split('\n') if line.strip()) - len(events)
    atomic_json(directory / 'result.json', result)
    if not after['ok']:
        raise RuntimeError('USB VPN went down during a case; result retained and batch paused')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--corpus', required=True, type=Path)
    parser.add_argument('--hdc', default=os.environ.get('HDC', 'hdc'))
    parser.add_argument('--serial', default='')
    parser.add_argument('--timeout', type=int, default=600)
    parser.add_argument('--limit', type=int)
    args = parser.parse_args()
    os.umask(0o077)
    args.out.mkdir(parents=True, exist_ok=True)
    rows = json.loads(args.corpus.read_text())
    assert len({r['id'] for r in rows}) == len(rows)
    assert all(re.fullmatch(r'[\w-]+', r['id']) and isinstance(r['prompt'], str) for r in rows)
    if args.limit:
        rows = rows[:args.limit]
    targets = subprocess.check_output([args.hdc, 'list', 'targets'], text=True).split()
    if not args.serial and len(targets) != 1:
        raise RuntimeError('Exactly one phone required, or select --serial')
    device = Device(args.hdc, args.serial, args.out)
    report_script = Path(__file__).with_name('baseline-report.py')
    metadata = {'runner_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                'corpus_sha256': hashlib.sha256(args.corpus.read_bytes()).hexdigest(),
                'timeout_s': args.timeout, 'order': 'frozen corpus order, one pass; provider caches are not cleared',
                'clarifications': 'choose the native planning card suggested answer',
                'device': args.serial or targets[0], 'argv': sys.argv}
    atomic_json(args.out / 'runner.json', metadata)
    unmetered_failures = 0
    for i, row in enumerate(rows, 1):
        result_file = args.out / 'runs' / row['id'] / 'result.json'
        if result_file.exists():
            continue  # Resume only; never silently rerun a measured case.
        atomic_json(args.out / 'progress.json', {'state': 'running', 'current': row['id'], 'index': i, 'planned': len(rows)})
        result = run_case(device, row, args.out, args.timeout)
        print(f'{i:03}/{len(rows)} {row["id"]:28} {result["status"]:10} built={result["built"]} '
              f'wall_ms={result["wall_ms"]} in={result["input_tokens"]} out={result["output_tokens"]}', flush=True)
        subprocess.run([sys.executable, str(report_script), str(args.out)], check=True, stdout=subprocess.DEVNULL)
        if result['status'] == 'submission_failed':
            raise RuntimeError('Navigation/submission failure; stopped rather than measuring different input')
        if result['status'] == 'timeout':
            raise RuntimeError('Case timed out; evidence retained, batch paused without silently rerunning it')
        unmetered_failures = unmetered_failures + 1 if not result['built'] and not result['traced_model_calls'] else 0
        if unmetered_failures >= 3:
            raise RuntimeError('Three consecutive failures without any model turns; check provider/network before resuming')
    device.home()
    atomic_json(args.out / 'progress.json', {'state': 'complete', 'planned': len(rows)})
    print('Batch complete:', args.out, flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('BATCH PAUSED:', error, file=sys.stderr, flush=True)
        sys.exit(1)
