# Native generation measurements

`bench.sh` is the older coordinate-based runner. It force-stops the app and uses
the first existing project. **Do not use those defaults for a USB-VPN baseline or
on a phone whose saved projects must remain untouched.** `device-jev-sweep.py`
elsewhere measures selector answers and deliberately stops generation early; it
is not an end-to-end generation benchmark.

## Full generation, with USB internet

`device-baseline.py` drives the installed app's native **unsaved creation flow**.
It never opens a saved project, saves a generated app, force-stops the bundle,
changes provider settings, or taps generated application controls. After saving
evidence, it discards the unsaved result through the native editor's leave dialog.
The USB VPN remains running across requests.

Before starting:

1. Build/install the revision you intend to measure, using the repository's safe
   in-place update workflow. A host runner does not establish the installed build.
2. Start `./usb-net.sh` and enable **Settings > USB network** in the demo. The
   runner requires both a connected status and the `vpn-tun` IPv4 interface.
3. Keep the phone unlocked on the app's home screen in App mode. Do not use it
   during the batch. Provider/model/key settings must already be configured.
4. Create a private output directory outside the repository; freeze the corpus
   there as `prompts.json`. Each entry needs an `id` and an exact `prompt`;
   `docs/prompts/coverage-gold.json` additionally provides cohort labels.
5. Record the upstream commit, build-only patch if any, HAP hash, corpus hash,
   redacted model/provider settings, device, native dependency revision and order.
   Never copy API keys into evidence files.

```bash
python3 tools/vera-bench/device-baseline.py \
  --out /private/baseline \
  --corpus /private/baseline/prompts.json \
  --hdc /path/to/hdc --serial DEVICE_SERIAL

python3 tools/vera-bench/baseline-report.py /private/baseline
```

The current UI driver targets the upstream native home-screen flow. It verifies
that typed text exactly matches the corpus and that the trace contains exactly
one **fresh**, non-refinement generation of that prompt. A UI mismatch pauses the
batch rather than silently measuring another input. Suggested answers on native
planning question cards are selected and recorded. Neither prompt wording nor
length is normalized or truncated.

`--limit 3` selects the first three corpus entries for an initial collector check;
these remain measured cases. Re-running without a limit resumes: existing
`result.json` files are never rerun. An existing `capture.json` without a result
adopts that generation's trace offset, rather than submitting the prompt again.
Do not delete evidence to retry a measured case without labeling it a new run.

Timeouts (default 600 seconds) retain partial evidence and pause the batch. A USB
failure, navigation mismatch, or three consecutive failures with no traced model
turns also pause it. Inspect `batch.log`/the runner output before resuming.

## Outputs and definitions

Each `runs/<id>/` contains the exact prompt, trace, capture offset, UI tree,
screenshot when available, clarification answers, USB-network checks and result.
The reporter produces:

- `results.csv`: one row per measured prompt;
- `turns.csv`: one row per traced cloud request, including side calls and retries;
- `summary.json`: totals and mean/median/p90/p95/range, by domain, split, phrasing
  and positive/negative case;
- `phrasing.csv`: one aggregate row per phrasing, with wall/active timing and
  input/output token totals, means, medians, percentiles and ranges;
- `report.md` and offline `report.html`: human-readable tables. The HTML refreshes
  every minute while the frozen corpus is incomplete.

To analyze only explicitly non-negative cases without rerunning anything:

```bash
python3 tools/vera-bench/baseline-report.py /private/baseline --non-negative
```

This writes a separate `non-negative/` report and exports, leaving the original
full-corpus report and evidence untouched. Phrasing timing/token tables appear
near the top of the HTML report; each aggregate uses only the selected population.

**Time** is device `gen-start` to `gen-end`: planning, generation and retries, but
not typing, UI navigation or evidence collection. **Active time** subtracts the
app's reported time waiting for clarification. Missing end events remain unknown;
observed timeout duration is separate. Summed request durations may overlap and
must not be presented as a critical-path breakdown.

**Tokens** sum API-reported usage across *all* traced request sources, not just
`src=gen`. Cached input is already included in input, and reasoning is already
included in output. Missing usage remains unknown, not zero. On the current
DeepSeek + TypeSafe configuration, TypeSafe selector token usage is unavailable,
so reported token totals are explicitly **partial known cloud usage**. No full
pipeline token/cost estimate is inferred from them.

**Built** means the native generation pipeline accepted a program, not that all
requested behavior works. Negative/unsupported cases are separate cohorts. One
pass in fixed corpus order with warm process/provider caches is exploratory, not
a per-prompt variance estimate or a controlled quality comparison.
