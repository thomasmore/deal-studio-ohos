#!/usr/bin/env bash
# Generation benchmark: drives the Generate screen on the connected phone, one
# prompt at a time, and keeps the app's full trace of every run.
#
#   tools/vera-bench/bench.sh [-n RUNS] [-o OUTDIR] [-p PROMPTS.tsv|json] [-e EFFORT] [-a 'LAUNCH ARGS'] [label ...]
#   python3 tools/vera-bench/report.py OUTDIR
#
# Each run: force-stop the app, open the first project in the list, open
# Generate, type the prompt, tap Generate, wait for the trace's gen-end event
# (or TIMEOUT seconds), then pull {filesDir}/vera/trace.jsonl and a screenshot
# into OUTDIR/<label>-<n>/. The trace is written by VeraTiming.ets: every model
# request with its reasoning and reply, every tool call with its arguments and
# result, every compile with its source and diagnostics.
#
# Needs: a build with the trace (VeraTiming.ets), the API key already stored,
# at least one project in the list, the phone unlocked, and a root hdc shell
# (the trace is read straight from the app sandbox). The tap coordinates are
# for a 1260x2720 screen (ALN-AL80); override them through the environment for
# another phone. The project's program is replaced by every run.
#
# -e sets DeepSeek's reasoning_effort (low, medium, high, ..., or default for
# the app's own, low) on the phone before the first run. The app keeps it, so
# it stays in force for later runs and normal use until it is set again.
#
# -a adds launch parameters to every run's app start, for flags that last one
# session, e.g. -a '--ps veraCompose 0'.
set -u

RUNS=1
OUT=bench-$(date +%Y%m%d-%H%M%S)
PROMPTS=$(dirname "$0")/prompts.tsv
EFFORT=''
LAUNCH_ARGS=''
while getopts "n:o:p:e:a:" opt; do
  case $opt in
    n) RUNS=$OPTARG ;;
    o) OUT=$OPTARG ;;
    p) PROMPTS=$OPTARG ;;
    e) EFFORT=$OPTARG ;;
    a) LAUNCH_ARGS=$OPTARG ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

# Accept the existing JSON corpora too; the device-driving behavior stays unchanged.
# Keep the original corpus beside the traces so report.py can group domains/phrasing.
mkdir -p "$OUT"
if [[ "$PROMPTS" == *.json ]]; then
  cp "$PROMPTS" "$OUT/prompts.json" || exit 1
  TSV=$(mktemp) || exit 1
  trap 'rm -f "$TSV"' EXIT
  python3 - "$PROMPTS" > "$TSV" <<'PY' || exit 1
import json, re, sys
rows = json.load(open(sys.argv[1]))
ids = set()
for row in rows:
    label, prompt = row['id'], row['prompt']
    if not re.fullmatch(r'[\w-]+', label) or label in ids or any(c in prompt for c in '\t\r\n'):
        raise ValueError('Expected unique safe IDs and single-line prompts')
    ids.add(label)
    print(label + '\t' + prompt)
PY
  PROMPTS=$TSV
fi

source "$(dirname "$0")/../../tool-paths.sh"
HDC_BIN_DIR=$(vera_hdc_dir) || exit 1
export PATH=$HDC_BIN_DIR:$PATH

BUNDLE=com.vera.probe.dyn
TRACE=/data/app/el2/100/base/$BUNDLE/haps/entry/files/vera/trace.jsonl
TIMEOUT=${TIMEOUT:-600}
PROJECT_ROW=${PROJECT_ROW:-"544 626"}
GENERATE_BTN=${GENERATE_BTN:-"282 660"}
PROMPT_FIELD=${PROMPT_FIELD:-"626 639"}
RUN_BTN=${RUN_BTN:-"332 925"}

tap() { hdc shell uinput -T -c $1 >/dev/null; sleep "${2:-3}"; }

# True once the screen shows `text` (from the UI layout dump), false after
# `secs` seconds. Fixed sleeps were not enough: when the app started slowly the
# first tap fell on the splash, every later tap landed one screen early, and
# the "prompt field" tap hit the project page's Run button.
wait_for() {
  local text=$1 secs=${2:-20} until=$(( $(date +%s) + ${2:-20} ))
  while (( $(date +%s) < until )); do
    local n=$(hdc shell "uitest dumpLayout -p /data/local/tmp/bench-layout.json >/dev/null; grep -c '$text' /data/local/tmp/bench-layout.json" | tr -dc '0-9')
    [ "${n:-0}" -gt 0 ] && return 0
    sleep 1
  done
  return 1
}

# Taps through to the Generate screen and starts a generation, checking each
# screen before tapping on it. Succeeds once the trace shows gen-start.
start_generation() {
  local prompt=$1
  hdc shell aa force-stop $BUNDLE >/dev/null
  hdc shell "rm -f $TRACE" >/dev/null
  hdc shell power-shell wakeup >/dev/null
  hdc shell aa start -a EntryAbility -b $BUNDLE $LAUNCH_ARGS >/dev/null
  wait_for 'New Project' 30 || { echo "  project list did not appear" >&2; return 1; }
  tap "$PROJECT_ROW" 1
  wait_for '"Pin"' || { echo "  project page did not appear" >&2; return 1; }
  tap "$GENERATE_BTN" 1
  wait_for 'Metrics' || { echo "  Generate screen did not appear" >&2; return 1; }
  tap "$PROMPT_FIELD" 2
  # uitest takes the text as one quoted argument; the prompts use apostrophes
  # but no double quotes. The keyboard stays up: Generate sits above it.
  hdc shell "uitest uiInput inputText ${PROMPT_FIELD} \"$prompt\"" >/dev/null; sleep 2
  tap "$RUN_BTN" 0
  for _ in $(seq 1 8); do
    sleep 5
    local starts=$(hdc shell "grep -c gen-start $TRACE 2>/dev/null" | tr -dc '0-9')
    [ "${starts:-0}" -gt 0 ] && return 0
  done
  return 1
}

screenshot() {
  hdc shell snapshot_display -f /data/local/tmp/bench.jpeg >/dev/null
  hdc file recv /data/local/tmp/bench.jpeg "$1" >/dev/null
}

run_one() {
  local label=$1 prompt=$2 dir=$3
  mkdir -p "$dir"
  printf '%s\n' "$prompt" > "$dir/prompt.txt"
  local started=$(date +%s)
  local status=timeout
  if ! start_generation "$prompt"; then
    screenshot "$dir/nav-failed-1.jpeg"
    started=$(date +%s)
    if ! start_generation "$prompt"; then
      screenshot "$dir/nav-failed-2.jpeg"
      printf '%-10s %-8s %4ss  %s\n' "$label" "nav-fail" "$(( $(date +%s) - started ))" "$dir"
      return
    fi
  fi
  while (( $(date +%s) - started < TIMEOUT )); do
    sleep 5
    local ends=$(hdc shell "grep -c gen-end $TRACE 2>/dev/null" | tr -dc '0-9')
    if [ "${ends:-0}" -gt 0 ]; then status=done; break; fi
  done
  sleep 3   # let the first render land before the screenshot
  hdc file recv "$TRACE" "$dir/trace.jsonl" >/dev/null
  screenshot "$dir/screen.jpeg"
  printf '%-10s %-8s %4ss  %s\n' "$label" "$status" "$(( $(date +%s) - started ))" "$dir"
}

mkdir -p "$OUT"
[ "$(hdc list targets | grep -vc '^\s*$')" = "1" ] || { echo "need exactly one connected phone" >&2; exit 1; }
git -C "$(dirname "$0")" log -1 --format='%h %s' > "$OUT/build.txt" 2>/dev/null
[ -n "$LAUNCH_ARGS" ] && printf 'launch: %s\n' "$LAUNCH_ARGS" >> "$OUT/build.txt"
if [ -n "$EFFORT" ]; then
  hdc shell aa start -a EntryAbility -b $BUNDLE --ps reasoningEffort "$EFFORT" >/dev/null
  sleep 3
fi
for n in $(seq 1 "$RUNS"); do
  while IFS=$'\t' read -r label prompt; do
    [[ -z "$label" || "$label" == \#* ]] && continue
    if [ $# -gt 0 ] && [[ ! " $* " == *" $label "* ]]; then continue; fi
    # An existing trace means this run already happened: rerunning into the
    # same OUTDIR resumes rather than repeats.
    [ -s "$OUT/$label-$n/trace.jsonl" ] && continue
    run_one "$label" "$prompt" "$OUT/$label-$n"
  done < "$PROMPTS"
done
echo "report: python3 $(dirname "$0")/report.py $OUT"
