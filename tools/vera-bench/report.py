#!/usr/bin/env python3
"""Reads a bench.sh output directory and writes OUTDIR/report.md.

Sections:
  1. one row per run -- outcome, attempts, wall time, where the time went;
  2. per prompt -- medians and first-attempt compile rate;
  3. compile errors -- every failed compile's diagnostics, grouped by message;
  4. tool calls -- per run, round by round: what the model asked for, what came
     back, and whether the final program used any of it;
  5. per-request timeline -- the raw turn numbers.

    python3 tools/vera-bench/report.py OUTDIR [--reasoning]

--reasoning also writes OUTDIR/<run>/reasoning.md with every request's
reasoning text, for reading what the model spent its time on.
"""
import csv
import json
import re
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path


def load(run_dir):
    events = []
    path = run_dir / "trace.jsonl"
    if not path.exists():
        return events
    # split("\n"), not splitlines(): tool results carry U+2028 and friends,
    # which splitlines() would cut a JSON line at.
    for line in path.read_text(errors="replace").split("\n"):
        line = line.strip()
        if line:
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return events


def result_items(text):
    """Short names for what a tool result offered the model."""
    try:
        body = json.loads(text)
    except (json.JSONDecodeError, TypeError):
        return [], (text or "")[:80]
    if not isinstance(body, dict):
        return [], ""
    names = []
    results = body.get("results") or []
    if isinstance(results, str):
        # find_ui_component answers with catalogue text: one `ui.Name(...)` line per component.
        return list(dict.fromkeys(re.findall(r"\bui\.([A-Z]\w*)\(", results))), body.get("note", "")
    for item in results:
        if isinstance(item, dict):
            name = str(item.get("target") or item.get("name") or item.get("call") or "?")
            # An intent result is a ready-made call; its address is what a program repeats.
            m = re.match(r'sdk\.call\("([^"]+)"', name)
            names.append(m.group(1) if m else name)
        else:
            names.append(str(item).split("(")[0].split(":")[0].strip()[:40])
    return names, body.get("note", "")


def used_in(name, source):
    if not source:
        return False
    short = name.split(".")[-1].split(":")[-1]
    return name in source or (len(short) > 3 and re.search(r"\b" + re.escape(short) + r"\b", source) is not None)


def first_line(errors):
    for line in errors.splitlines():
        line = line.strip()
        if line and not line.startswith("The previous attempt was cut off"):
            return line
    return errors.strip()[:120]


def error_key(line):
    """Groups diagnostics that differ only in positions, names and numbers."""
    key = re.sub(r"\b\d+(:\d+)?\b", "N", line)
    key = re.sub(r"'[^']*'", "'X'", key)
    key = re.sub(r'"[^"]*"', '"X"', key)
    key = re.sub(r"`[^`]*`", "`X`", key)
    return key[:160]


def secs(ms):
    return '—' if ms is None else f"{ms / 1000:.1f}"


def reported(turns, key):
    # Unknown usage is not zero. Include every traced model source and retry.
    known = [t for t in turns if t.get('inTok', 0) > 0 or t.get('outTok', 0) > 0]
    return sum(t.get(key, 0) for t in known) if known else None


def percentile(values, p):
    values = sorted(values)
    if not values:
        return None
    at = (len(values) - 1) * p
    lo = int(at)
    return values[lo] + (values[min(lo + 1, len(values) - 1)] - values[lo]) * (at - lo)


def aggregate(rows):
    active = [r['active_ms'] for r in rows if r['active_ms'] is not None]
    def total(key):
        values = [r[key] for r in rows if r[key] is not None]
        return sum(values) if values else None
    cached, inputs = total('cached_input_tokens'), total('input_tokens')
    return {'runs': len(rows), 'accepted': sum(r['ok'] for r in rows), 'timed_runs': len(active),
            'active_mean_ms': statistics.mean(active) if active else None,
            'active_median_ms': statistics.median(active) if active else None,
            'active_p90_ms': percentile(active, .9), 'input_tokens': inputs,
            'cached_input_tokens': cached, 'cached_ratio': cached / inputs if cached is not None and inputs else None,
            'output_tokens': total('output_tokens'),
            'calls_with_reported_usage': sum(r['calls_with_reported_usage'] for r in rows),
            'traced_model_calls': sum(r['requests'] for r in rows)}


def write_exports(out, runs, corpus):
    metadata = {row['id']: row for row in corpus}
    rows, turns = [], []
    for r in runs:
        label, suffix = r['name'].rsplit('-', 1) if '-' in r['name'] else (r['name'], '')
        label = label if suffix.isdigit() else r['name']
        meta = metadata.get(r['name'], metadata.get(label, {}))
        rows.append({**{k: meta.get(k) for k in ['domain', 'phrasing', 'split', 'negative']},
                     'name': r['name'], 'prompt': (r['start'] or {}).get('prompt', meta.get('prompt', '')),
                     **{k: r[k] for k in ['ok', 'active_ms', 'input_tokens', 'cached_input_tokens', 'output_tokens',
                                          'requests', 'calls_with_reported_usage']}})
        for t in r['turns']:
            turns.append({'name': r['name'], 'src': t.get('src'), 'round': t.get('round'),
                          'total_ms': t.get('totalMs'),
                          **{key: reported([t], field) for key, field in
                             [('input_tokens', 'inTok'), ('cached_input_tokens', 'cachedTok'), ('output_tokens', 'outTok')]}})
    for filename, data in [('results.csv', rows), ('turns.csv', turns)]:
        with (out / filename).open('w', newline='') as stream:
            if data:
                writer = csv.DictWriter(stream, fieldnames=list(data[0]))
                writer.writeheader(); writer.writerows(data)
    summary = {'overall': aggregate(rows),
               'non_negative': aggregate([r for r in rows if r['negative'] is False]),
               'cohorts': {key: {str(v): aggregate([r for r in rows if r[key] == v])
                                   for v in sorted({r[key] for r in rows if r[key] is not None}, key=str)}
                           for key in ['domain', 'phrasing', 'split', 'negative']},
               'limitations': ['Pipeline acceptance is not functional correctness.',
                               'All traced model sources/retries counted; TypeSafe usage unavailable, totals partial.',
                               'Cached tokens are a subset of input, not additional tokens.',
                               'Active time excludes reported clarification wait; missing gen-end stays unknown.']}
    (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')


def summarize(name, events):
    turns = [e for e in events if e["event"] == "turn"]
    tools = [e for e in events if e["event"] == "tool"]
    compiles = [e for e in events if e["event"] == "compile"]
    start = next((e for e in events if e["event"] == "gen-start"), None)
    end = next((e for e in events if e["event"] == "gen-end"), None)
    ui = next((e for e in events if e["event"] == "ui-select"), None)
    compose = next((e for e in events if e["event"] == "compose"), None)
    wall = (end["at"] - start["at"]) if start and end else (events[-1]["at"] - start["at"] if start and events else 0)
    final_source = next((c["source"] for c in reversed(compiles) if c.get("ok")), compiles[-1]["source"] if compiles else "")
    served = bool(compose and (compose.get('served') or ((end or {}).get('ok') and (end or {}).get('via') == 'compose')))
    if served:
        final_source = compose.get("source", "")
    route = "off" if not compose else ("composed" if served else "fell through")
    return {
        "name": name, "turns": turns, "tools": tools, "compiles": compiles, "start": start, "end": end,
        "ui": ui, "compose": compose, "route": route,
        "first_preview": (compose or {}).get("firstPreviewMs", 0), "wall": wall, "ok": bool(end and end.get("ok")),
        "failure": (end or {}).get("failure", "no gen-end" if not end else ""),
        "attempts": len(compiles), "first_ok": bool(compiles and compiles[0].get("ok")),
        "reason_ms": sum(t.get("reasonMs", 0) for t in turns), "reason_tok": sum(t.get("reasonTok", 0) for t in turns),
        "content_ms": sum(t.get("contentMs", 0) for t in turns), "model_ms": sum(t.get("totalMs", 0) for t in turns),
        "active_ms": max(0, wall - end.get('waitedMs', 0)) if start and end else None,
        "input_tokens": reported(turns, 'inTok'), "cached_input_tokens": reported(turns, 'cachedTok'),
        "output_tokens": reported(turns, 'outTok'),
        "calls_with_reported_usage": sum(t.get('inTok', 0) > 0 or t.get('outTok', 0) > 0 for t in turns),
        "tool_ms": sum(t["ms"] for t in tools), "requests": len(turns),
        "final_source": final_source,
    }


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    out = Path(sys.argv[1])
    want_reasoning = "--reasoning" in sys.argv
    runs = []
    run_root = out / 'runs' if (out / 'runs').is_dir() else out
    for d in sorted(p for p in run_root.iterdir() if p.is_dir()):
        events = load(d)
        if events:
            runs.append(summarize(d.name, events))
            if want_reasoning:
                write_reasoning(d, events)
    corpus = json.loads((out / 'prompts.json').read_text()) if (out / 'prompts.json').exists() else []
    write_exports(out, runs, corpus)
    md = []
    build = (out / "build.txt").read_text().strip() if (out / "build.txt").exists() else ""
    efforts = sorted({(r["start"] or {}).get("effort", "") or "default" for r in runs})
    md.append(f"# Generation benchmark: {out.name}\n\nBuild: `{build}`. {len(runs)} runs. "
              f"Reasoning effort: {', '.join(efforts)}.\n")

    md.append('Pipeline acceptance is not functional correctness. Tokens include every reported model source/retry; '
              'TypeSafe usage is unavailable, so totals are partial. Cached input is a subset of input.\n')
    md.append('## Active time and reported tokens\n')
    md.append('| run | active s | input | cached (ratio) | output |')
    md.append('|---|---|---|---|---|')
    for r in runs:
        inputs, cached = r['input_tokens'], r['cached_input_tokens']
        ratio = f'{cached / inputs:.1%}' if inputs and cached is not None else '—'
        md.append(f"| {r['name']} | {secs(r['active_ms'])} | {inputs if inputs is not None else '—'} | "
                  f"{cached if cached is not None else '—'} ({ratio}) | {r['output_tokens'] if r['output_tokens'] is not None else '—'} |")
    md.append("\n## 1. Runs\n")
    md.append("| run | ok | route | first preview s | attempts | wall s | requests | model s | reasoning s | reasoning tok | code s | tool calls | tools s |")
    md.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in runs:
        ok = "yes" if r["ok"] else "**no** " + r["failure"][:40]
        md.append(f"| {r['name']} | {ok} | {r['route']} | {secs(r['first_preview'])} | {r['attempts']} | {secs(r['wall'])} | {r['requests']} | {secs(r['model_ms'])} | "
                  f"{secs(r['reason_ms'])} | {r['reason_tok']} | {secs(r['content_ms'])} | {len(r['tools'])} | {secs(r['tool_ms'])} |")

    md.append("\n## 2. Per prompt\n")
    md.append("| prompt | runs | ok | first-attempt compile | median wall s | min–max s | median reasoning tok | median requests |")
    md.append("|---|---|---|---|---|---|---|---|")
    by_label = defaultdict(list)
    for r in runs:
        by_label[r["name"].rsplit("-", 1)[0]].append(r)
    for label, rs in by_label.items():
        walls = [r["wall"] for r in rs]
        md.append(f"| {label} | {len(rs)} | {sum(r['ok'] for r in rs)} | {sum(r['first_ok'] for r in rs)}/{len(rs)} | "
                  f"{secs(statistics.median(walls))} | {secs(min(walls))}–{secs(max(walls))} | "
                  f"{int(statistics.median(r['reason_tok'] for r in rs))} | {statistics.median(r['requests'] for r in rs)} |")

    composed = [r for r in runs if r["compose"]]
    if composed:
        md.append("\n### Composer\n")
        md.append("| run | route | sketch s | Jev s | previews | note |")
        md.append("|---|---|---|---|---|---|")
        for r in composed:
            c = r["compose"]
            md.append(f"| {r['name']} | {r['route']} | {secs(c.get('sketchMs', 0))} | {secs(c.get('jevMs', 0))} | "
                      f"{c.get('previews', 0)} | {c.get('note', '').replace('|', '/')[:160]} |")

    md.append("\n## 3. Compile errors\n")
    failed = [(r["name"], c) for r in runs for c in r["compiles"] if not c.get("ok")]
    if not failed:
        md.append("No compile failed.\n")
    else:
        groups = Counter(error_key(first_line(c["errors"])) for _, c in failed)
        md.append(f"{len(failed)} failed compiles out of {sum(len(r['compiles']) for r in runs)}. By first diagnostic:\n")
        md.append("| count | diagnostic (positions and names masked) |")
        md.append("|---|---|")
        for key, n in groups.most_common():
            md.append(f"| {n} | `{key.replace('|', '/')}` |")
        md.append("")
        for name, c in failed:
            md.append(f"**{name}, attempt {c['attempt']}**\n\n```\n{c['errors'].strip()[:1500]}\n```\n")

    md.append("## 4. Tool calls\n")
    totals = Counter()
    offered_used = [0, 0]
    for r in runs:
        md.append(f"### {r['name']}\n")
        if r["ui"]:
            md.append(f"UI described up front ({len(r['ui']['described'])}): {', '.join(r['ui']['described'])}\n")
        if not r["tools"]:
            md.append("No tool calls.\n")
            continue
        md.append("| round | tool | need | ms | returned | used in program |")
        md.append("|---|---|---|---|---|---|")
        for t in r["tools"]:
            totals[t["name"]] += 1
            names, note = result_items(t["result"])
            used = [n for n in names if used_in(n, r["final_source"])]
            offered_used[0] += len(names)
            offered_used[1] += len(used)
            returned = ", ".join(names) if names else f"*none* {note[:60]}"
            md.append(f"| {t['round']} | {t['name']} | {t['need'].replace('|', '/')} | {t['ms']} | {returned.replace('|', '/')} | "
                      f"{', '.join(used) or '—'} |")
        md.append("")
    md.append(f"Calls by tool: {dict(totals)}. Results offered {offered_used[0]} items, final programs used {offered_used[1]}.\n")

    md.append("## 5. Per-request timeline\n")
    md.append("| run | source | round | tools offered | first byte s | reasoning s | reasoning tok | code s | total s | in tok | cached | finish | calls |")
    md.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in runs:
        for t in r["turns"]:
            calls = ", ".join(c["name"].replace("find_", "") for c in t.get("calls", []))
            md.append(f"| {r['name']} | {t.get('src', 'unknown')} | {t['round']} | {'yes' if t['toolsOffered'] else 'no'} | {secs(t['firstByteMs'])} | "
                      f"{secs(t['reasonMs'])} | {t['reasonTok']} | {secs(t['contentMs'])} | {secs(t['totalMs'])} | "
                      f"{t['inTok']} | {t['cachedTok']} | {t['finish']} | {calls} |")

    text = "\n".join(md) + "\n"
    (out / "report.md").write_text(text)
    print(text)


def write_reasoning(run_dir, events):
    parts = []
    for e in events:
        if e["event"] == "turn":
            parts.append(f"## {e['src']} round {e['round']} ({secs(e['reasonMs'])} s, {e['reasonTok']} tok, finish={e['finish']})\n")
            parts.append(e.get("reasoning") or "*no reasoning*")
            for c in e.get("calls", []):
                parts.append(f"\n→ `{c['name']}` {c['arguments']}")
            parts.append("")
        elif e["event"] == "compile" and not e.get("ok"):
            parts.append(f"## compile attempt {e['attempt']} failed\n\n```\n{e['errors']}\n```\n")
    (run_dir / "reasoning.md").write_text("\n".join(parts))


if __name__ == "__main__":
    main()
