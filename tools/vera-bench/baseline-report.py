#!/usr/bin/env python3
"""Aggregate device-baseline.py artifacts. No model calls; no token estimation.

Writes per-prompt results.csv, per-request turns.csv, summary.json, report.md,
and a self-contained report.html. Missing usage stays unknown, not zero.
"""
import argparse
import csv
from collections import Counter
import html
import json
import os
from pathlib import Path
import statistics


def percentile(values, fraction):
    values = sorted(values)
    if not values:
        return None
    position = (len(values) - 1) * fraction
    lo = int(position)
    hi = min(lo + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (position - lo)


def stats(values):
    values = [v for v in values if isinstance(v, (int, float))]
    if not values:
        return {'n': 0, 'sum': None, 'mean': None, 'median': None, 'p90': None, 'p95': None, 'min': None, 'max': None}
    return {'n': len(values), 'sum': sum(values), 'mean': statistics.mean(values),
            'median': statistics.median(values), 'p90': percentile(values, .90),
            'p95': percentile(values, .95), 'min': min(values), 'max': max(values)}


def aggregate(rows):
    completed = [r for r in rows if r['status'] == 'completed']
    built = [r for r in completed if r.get('built')]
    return {
        'attempted': len(rows), 'completed': len(completed), 'built': len(built),
        'built_rate': len(built) / len(rows) if rows else None,
        'statuses': dict(Counter(r['status'] for r in rows)),
        'wall_ms_all': stats([r.get('wall_ms') for r in rows]),
        'wall_ms_completed': stats([r.get('wall_ms') for r in completed]),
        'wall_ms_built': stats([r.get('wall_ms') for r in built]),
        'active_ms_completed': stats([r.get('active_ms') for r in completed]),
        'input_tokens_reported': stats([r.get('input_tokens') for r in rows]),
        'output_tokens_reported': stats([r.get('output_tokens') for r in rows]),
        'cached_input_tokens_reported': stats([r.get('cached_input_tokens') for r in rows]),
        'traced_model_calls': sum(r.get('traced_model_calls', 0) for r in rows),
        'calls_with_reported_usage': sum(r.get('calls_with_reported_usage', 0) for r in rows),
        'partial_token_cases': sum(bool(r.get('token_totals_partial')) for r in rows),
        'questions_answered': sum(r.get('questions_answered', 0) for r in rows),
    }


def fmt(value, scale=1, digits=1):
    return '—' if value is None else f'{value / scale:,.{digits}f}'


def write_csv(path, rows, fields):
    with path.open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, extrasaction='ignore')
        writer.writeheader()
        for row in rows:
            writer.writerow({k: json.dumps(v, ensure_ascii=False) if isinstance(v, (list, dict)) else v for k, v in row.items()})


def main(source, non_negative=False):
    os.umask(0o077)
    original = json.loads((source / 'prompts.json').read_text())
    corpus = [r for r in original if r.get('negative') is False] if non_negative else original
    out = source / 'non-negative' if non_negative else source
    out.mkdir(parents=True, exist_ok=True)
    included = {r['id'] for r in corpus}
    evidence_prefix = '../' if non_negative else ''
    population = f'Non-negative cases only: {len(corpus)} included, {len(original) - len(corpus)} excluded.' if non_negative else 'All corpus cases.'
    by_id, turns = {}, []
    for directory in sorted((source / 'runs').glob('*')):
        result_file = directory / 'result.json'
        if not result_file.exists():
            continue
        row = json.loads(result_file.read_text())
        if non_negative and row['id'] not in included:
            continue
        if row['id'] in by_id:
            raise ValueError('Duplicate measured prompt ID')
        by_id[row['id']] = row
        for line in (directory / 'trace.jsonl').read_text().split('\n'):
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get('event') == 'turn':
                known = event.get('inTok', 0) > 0 or event.get('outTok', 0) > 0
                turns.append({'id': row['id'], 'src': event.get('src'), 'round': event.get('round'),
                              'at': event.get('at'), 'total_ms': event.get('totalMs'),
                              'input_tokens': event.get('inTok') if known else None,
                              'output_tokens': event.get('outTok') if known else None,
                              'cached_input_tokens': event.get('cachedTok') if known else None,
                              'reasoning_tokens': event.get('reasonTok') if known else None,
                              'finish': event.get('finish'), 'usage_reported': known})
    rows = [by_id[r['id']] for r in corpus if r['id'] in by_id]
    if set(by_id) - {r['id'] for r in corpus}:
        raise ValueError('Measured results outside frozen corpus')
    summary = {'planned': len(corpus), 'remaining': len(corpus) - len(rows), 'overall': aggregate(rows),
               'cohorts': {}, 'percentile_method': 'linear interpolation at (n-1)*p',
               'time_definition': 'device gen-start to gen-end; excludes typing, navigation and evidence capture',
               'active_time_definition': 'wall time minus device-reported clarification wait',
               'token_scope': 'reported DeepSeek input/output across every traced source and retry; input includes cached tokens; output includes reasoning',
               'limitations': ['TypeSafe selector usage is unavailable; all token totals are partial known usage, not full pipeline cost.',
                               'Built means the native pipeline accepted a program, not that all requested behavior is correct.',
                               'One pass in fixed corpus order, warm process and provider caches; not a per-prompt variance estimate.',
                               'No generated application controls are exercised; suggested planning answers are automatic.',
                               'Missing gen-end times remain unknown; timeout durations are also recorded separately.',
                               'Summed model-call durations can overlap and are not a critical-path breakdown.']}
    for key in ['domain', 'split', 'phrasing', 'negative']:
        summary['cohorts'][key] = {str(value): aggregate([r for r in rows if r.get(key) == value])
                                   for value in sorted({r.get(key) for r in rows}, key=str)}
    summary['population'] = {'filter': 'negative is false' if non_negative else 'all',
                             'source_run': str(source.resolve()), 'source_cases': len(original),
                             'included_cases': len(corpus), 'excluded_cases': len(original) - len(corpus)}
    (out / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
    phrasing_rows = []
    for name in ['terse', 'descriptive', 'computation']:
        if name not in summary['cohorts']['phrasing']:
            continue
        group = summary['cohorts']['phrasing'][name]
        entry = {'phrasing': name, 'n': group['attempted']}
        for label, key, scale in [('wall_s', 'wall_ms_completed', 1000), ('active_s', 'active_ms_completed', 1000),
                                  ('input_tokens', 'input_tokens_reported', 1), ('output_tokens', 'output_tokens_reported', 1)]:
            for stat in ['sum', 'mean', 'median', 'p90', 'p95', 'min', 'max']:
                value = group[key][stat]
                entry[f'{label}_{stat}'] = value / scale if value is not None else None
        phrasing_rows.append(entry)
    write_csv(out / 'phrasing.csv', phrasing_rows, list(phrasing_rows[0]) if phrasing_rows else ['phrasing', 'n'])
    fields = ['id', 'domain', 'split', 'phrasing', 'negative', 'status', 'built', 'wall_ms', 'active_ms', 'waited_ms',
              'input_tokens', 'output_tokens', 'cached_input_tokens', 'reasoning_tokens', 'token_totals_partial',
              'traced_model_calls', 'calls_with_reported_usage', 'compile_events', 'failed_compile_events',
              'first_preview_ms', 'questions_answered', 'fresh', 'prompt_exact', 'failure', 'note', 'prompt']
    write_csv(out / 'results.csv', rows, fields)
    write_csv(out / 'turns.csv', turns, ['id', 'src', 'round', 'at', 'total_ms', 'input_tokens', 'output_tokens',
                                      'cached_input_tokens', 'reasoning_tokens', 'finish', 'usage_reported'])
    a = summary['overall']
    commit = (source / 'commit.txt').read_text().strip() if (source / 'commit.txt').exists() else 'unknown'
    settings = json.loads((source / 'settings-redacted.json').read_text()) if (source / 'settings-redacted.json').exists() else {}
    model = settings.get('model', 'unknown')
    md = [f'# Device app-generation baseline\n\nUpstream main `{commit}`; model `{model}`.\n',
          f'{len(rows)}/{len(corpus)} attempted; {a["completed"]} completed; {a["built"]} built.\n',
          f'Median completed wall time: {fmt(a["wall_ms_completed"]["median"], 1000)} s; p90: {fmt(a["wall_ms_completed"]["p90"], 1000)} s.\n',
          f'Known input tokens: {fmt(a["input_tokens_reported"]["sum"], digits=0)}; known output tokens: {fmt(a["output_tokens_reported"]["sum"], digits=0)}. **Partial: TypeSafe usage unavailable.**\n',
          '## Measurement contract\n', summary['time_definition'] + '.\n',
          '\n'.join('- ' + s for s in summary['limitations']), '\n## Per prompt\n',
          '| ID | Domain | Status | Built | Wall s | Active s | Input* | Output* | Cached* | Calls |',
          '|---|---|---|---|---:|---:|---:|---:|---:|---:|']
    phrase_md = [population, '\n## By phrasing\n',
                 '| Phrasing | N | Mean wall s | Median wall s | p90 wall s | Mean active s | Median active s | p90 active s |',
                 '|---|---:|---:|---:|---:|---:|---:|---:|']
    for r in phrasing_rows:
        phrase_md.append('| ' + r['phrasing'] + ' | ' + str(r['n']) + ' | ' + ' | '.join(fmt(r[k], digits=2) for k in
                         ['wall_s_mean', 'wall_s_median', 'wall_s_p90', 'active_s_mean', 'active_s_median', 'active_s_p90']) + ' |')
    phrase_md += ['\n| Phrasing | Total input* | Mean input* | Median input* | Total output* | Mean output* | Median output* |',
                  '|---|---:|---:|---:|---:|---:|---:|']
    for r in phrasing_rows:
        phrase_md.append('| ' + r['phrasing'] + ' | ' + ' | '.join(fmt(r[k], digits=0) for k in
                         ['input_tokens_sum', 'input_tokens_mean', 'input_tokens_median',
                          'output_tokens_sum', 'output_tokens_mean', 'output_tokens_median']) + ' |')
    at = md.index('## Measurement contract\n')
    md[at:at] = phrase_md + ['\n']
    for row in rows:
        md.append(f'| {row["id"]} | {row.get("domain", "")} | {row["status"]} | {row["built"]} | '
                  f'{fmt(row.get("wall_ms"), 1000)} | {fmt(row.get("active_ms"), 1000)} | '
                  f'{fmt(row.get("input_tokens"), digits=0)} | {fmt(row.get("output_tokens"), digits=0)} | '
                  f'{fmt(row.get("cached_input_tokens"), digits=0)} | {row.get("traced_model_calls", 0)} |')
    md.append('\n*Reported cloud usage only; missing usage is not counted as zero.\n\n## Cohorts\n')
    for key, groups in summary['cohorts'].items():
        md += [f'### {key}\n', '| Cohort | N | Built | Median wall s | p90 wall s | Input* | Output* |',
               '|---|---:|---:|---:|---:|---:|---:|']
        for name, group in groups.items():
            md.append(f'| {name} | {group["attempted"]} | {group["built"]} | {fmt(group["wall_ms_completed"]["median"], 1000)} | '
                      f'{fmt(group["wall_ms_completed"]["p90"], 1000)} | {fmt(group["input_tokens_reported"]["sum"], digits=0)} | '
                      f'{fmt(group["output_tokens_reported"]["sum"], digits=0)} |')
    (out / 'report.md').write_text('\n'.join(md) + '\n')
    esc = lambda s: html.escape(str(s), quote=True)
    table = []
    for prompt in corpus:
        r = by_id.get(prompt['id'])
        cells = [prompt['id'], prompt['domain'], prompt['phrasing'],
                 ('built' if r.get('built') else r['status'] if r['status'] != 'completed' else 'not built') if r else 'not run',
                 fmt(r.get('wall_ms'), 1000) if r else '—', fmt(r.get('active_ms'), 1000) if r else '—',
                 fmt(r.get('input_tokens'), digits=0) if r else '—', fmt(r.get('output_tokens'), digits=0) if r else '—']
        table.append('<tr data-domain="' + esc(prompt['domain']) + '">' + ''.join('<td>' + esc(c) + '</td>' for c in cells) +
                     '<td class="prompt">' + esc(prompt['prompt']) + '</td><td>' +
                     (f'<a href="{evidence_prefix}runs/{esc(prompt["id"])}/screen.jpeg">screen</a>' if r and (source / 'runs' / prompt['id'] / 'screen.jpeg').exists()
                      else f'<a href="{evidence_prefix}runs/{esc(prompt["id"])}/ui.json">UI tree</a>' if r else '') + '</td></tr>')
    cohort_html = []
    for key, groups in summary['cohorts'].items():
        body = ''.join('<tr><td>' + esc(name) + '</td><td>' + str(g['attempted']) + '</td><td>' + str(g['built']) + '</td><td>' +
                       fmt(g['wall_ms_completed']['median'], 1000) + '</td><td>' + fmt(g['wall_ms_completed']['p90'], 1000) + '</td><td>' +
                       fmt(g['input_tokens_reported']['sum'], digits=0) + '</td><td>' + fmt(g['output_tokens_reported']['sum'], digits=0) + '</td></tr>'
                       for name, g in groups.items())
        cohort_html.append(f'<h3>{esc(key)}</h3><table><thead><tr><th>Cohort</th><th>N</th><th>Built</th><th>Median s</th><th>p90 s</th><th>Input*</th><th>Output*</th></tr></thead><tbody>{body}</tbody></table>')
    cards = [('Attempted', f'{len(rows)} / {len(corpus)}'), ('Built', str(a['built'])),
             ('Median wall', fmt(a['wall_ms_completed']['median'], 1000) + ' s'),
             ('p90 wall', fmt(a['wall_ms_completed']['p90'], 1000) + ' s'),
             ('Median active', fmt(a['active_ms_completed']['median'], 1000) + ' s'),
             ('Known input*', fmt(a['input_tokens_reported']['sum'], digits=0)),
             ('Known output*', fmt(a['output_tokens_reported']['sum'], digits=0))]
    page = '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
    if summary['remaining']:
        page += '<meta http-equiv="refresh" content="60">'
    page += '''<title>VERA · Device generation baseline</title><style>
body{margin:0;background:#f5f4ef;color:#202c37;font:16px system-ui,sans-serif}main{max-width:1500px;margin:auto;padding:40px 28px}
h1{font-size:38px;margin:5px 0 12px}h2{margin-top:38px}h3{margin:24px 0 8px}small,.sub{color:#5c6a75}.badge{color:#5945b5;font-weight:700;letter-spacing:1px;font-size:12px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:14px;margin:28px 0}.card{background:white;border:1px solid #daddd7;border-radius:14px;padding:20px}.card b{display:block;font-size:27px;margin-top:8px}
.note{border-left:4px solid #7456d9;background:#eae5fb;padding:16px 20px;line-height:1.6}a{color:#5842b1}table{border-collapse:collapse;width:100%;font-size:13px;background:#fff}td,th{text-align:left;border-bottom:1px solid #e1e4df;padding:12px 10px;vertical-align:top}th{background:#e8ebe5;white-space:nowrap}.prompt{min-width:280px;max-width:480px;line-height:1.5}.scroll{overflow:auto}input{padding:11px;border:1px solid #b8c0b7;border-radius:8px;min-width:300px;margin:12px 0}li{margin:8px 0;line-height:1.5}code{font-size:13px}footer{margin-top:30px;color:#62707a}
</style><main><div class="badge">NATIVE DEVICE · USB INTERNET · ONE PASS</div><h1>App-generation baseline</h1>'''
    page += '<p class="sub">Upstream main <code>' + esc(commit) + '</code> · ' + esc(model) + ' · approved build-profile-only SDK fix</p>'
    page += '<p><strong>' + esc(population) + '</strong> No device reruns; aggregates use the original measurements.</p>'
    page += '<p><a href="results.csv">Per-prompt CSV</a> · <a href="phrasing.csv">Phrasing CSV</a> · <a href="turns.csv">Per-call CSV</a> · <a href="summary.json">Aggregate JSON</a> · <a href="report.md">Markdown report</a></p>'
    page += '<div class="cards">' + ''.join('<div class="card">' + esc(k) + '<b>' + esc(v) + '</b></div>' for k, v in cards) + '</div>'
    page += '<div class="note"><strong>* Token totals are partial.</strong> They include reported DeepSeek turns from planning, content, code and repair. TypeSafe selector tokens are unavailable. Cached input is already included in input; reasoning is already included in output. Time is the device’s generation start → end, not UI automation time.</div>'
    page += '<h2>By phrasing: generation time</h2><p class="sub">Active time excludes clarification-answer waits. Wall time includes them.</p><div class="scroll"><table><thead><tr><th>Phrasing</th><th>N</th><th>Mean wall s</th><th>Median wall s</th><th>p90 wall s</th><th>Mean active s</th><th>Median active s</th><th>p90 active s</th></tr></thead><tbody>'
    for r in phrasing_rows:
        page += '<tr><td>' + esc(r['phrasing']) + '</td><td>' + str(r['n']) + '</td>' + ''.join('<td>' + fmt(r[k], digits=2) + '</td>' for k in
                ['wall_s_mean', 'wall_s_median', 'wall_s_p90', 'active_s_mean', 'active_s_median', 'active_s_p90']) + '</tr>'
    page += '</tbody></table></div><h2>By phrasing: reported tokens</h2><div class="scroll"><table><thead><tr><th>Phrasing</th><th>Total input*</th><th>Mean input*</th><th>Median input*</th><th>Total output*</th><th>Mean output*</th><th>Median output*</th></tr></thead><tbody>'
    for r in phrasing_rows:
        page += '<tr><td>' + esc(r['phrasing']) + '</td>' + ''.join('<td>' + fmt(r[k], digits=0) + '</td>' for k in
                ['input_tokens_sum', 'input_tokens_mean', 'input_tokens_median', 'output_tokens_sum', 'output_tokens_mean', 'output_tokens_median']) + '</tr>'
    page += '</tbody></table></div>'
    page += '<h2>Per prompt</h2><p class="sub">Results refresh every minute while the corpus is incomplete. Built ≠ semantically verified.</p><input id="filter" aria-label="Filter prompts" placeholder="Filter by prompt, ID, domain or status…"><div class="scroll"><table id="runs"><thead><tr><th>ID</th><th>Domain</th><th>Phrasing</th><th>Outcome</th><th>Wall s</th><th>Active s</th><th>Input*</th><th>Output*</th><th>Exact prompt</th><th>Evidence</th></tr></thead><tbody>'
    page += ''.join(table) + '</tbody></table></div><h2>Aggregate by cohort</h2>' + ''.join(cohort_html)
    page += '<h2>Scope and limitations</h2><ul>' + ''.join('<li>' + esc(s) + '</li>' for s in summary['limitations']) + '</ul><footer>Local, offline report. No API keys or external assets.</footer></main>'
    page += '<script>document.querySelector("#filter").addEventListener("input",e=>{const q=e.target.value.toLowerCase();document.querySelectorAll("#runs tbody tr").forEach(r=>r.hidden=!r.textContent.toLowerCase().includes(q));});</script></html>'
    # Replace atomically: the browser can refresh while the batch is running.
    temp = out / 'report.html.tmp'
    temp.write_text(page)
    temp.replace(out / 'report.html')
    print(f'{len(rows)}/{len(corpus)} attempted; {a["built"]} built; report: {out / "report.html"}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('out', type=Path, help='Original baseline evidence directory')
    parser.add_argument('--non-negative', action='store_true', help='Write a filtered report under OUT/non-negative without changing the original report')
    args = parser.parse_args()
    main(args.out, args.non_negative)
