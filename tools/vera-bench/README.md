# Generation benchmarks

Reuse the existing native runner and reporter:

```bash
tools/vera-bench/bench.sh -n 1 -o /private/bench -p docs/prompts/coverage-gold.json
python3 tools/vera-bench/report.py /private/bench
```

`-p` accepts the existing label/tab/prompt TSV or a JSON array with unique `id` and `prompt` fields. JSON cohort metadata is copied into the output directory. Other options remain unchanged; see `bench.sh`.

**The runner force-stops the app and replaces the first project's program.** Use a disposable project; it is not suitable when that project's contents or the app's USB VPN must remain active. Do not change provider settings during a run. Keep raw traces private: they contain prompts, generated sources and tool results. Existing trace files are skipped on resume.

`report.py` reads both the original `OUT/<label>-<run>/trace.jsonl` layout and archived `OUT/runs/<id>/trace.jsonl` evidence. It writes `report.md`, `results.csv`, `turns.csv` and `summary.json`, including domain/phrasing cohorts when `prompts.json` is present. It makes no model calls.

- Active time is device `gen-start` to `gen-end`, minus reported clarification wait; missing end times remain unknown.
- Token totals include all reported model sources and retries. Cached input is already part of input; reasoning is already part of output. Missing usage is unknown. TypeSafe usage is unavailable, so totals are partial, not full pipeline cost.
- Accepted means the pipeline served a program, not that every requested behavior works.
- A sequential pass with uncleared caches is not a controlled speedup or variance estimate.

For host prompt generation, reuse `tools/vera-harness/agent-run.js` (`-r` for the full route, `-w` for Chat). Host calls do not establish device behavior.
