# Build Vera’s shared-state Q8 selector from mmBERT-small

Start with the public `jhu-clsp/mmBERT-small` checkpoint and labeled requests from the Vera builders. Project the original token embeddings to 96 dimensions, train a new option ranker, and export a four-file bundle for the Rust runner. Cycle 2 weights and a trained Vera head are unnecessary. [Pinned upstream checkpoint](https://huggingface.co/jhu-clsp/mmBERT-small/tree/abc32620dd4f6ab06f5fbe905dc25f310618e09f)

The Rust runner pools the request state once, pools each question and offered option, and scores all options with a small feed-forward network. The Transformer layers are dropped. The frozen Q8 table takes 25,600,000 bytes, the tokenizer takes 13,718,521 bytes, and the trained F32 head takes about 1.74 MB. The original bundle took 41,061,517 bytes.

## Run with the archived dataset

Check out the pinned archive in the private Vera dataset repository. Run these
commands from the dataset checkout. Use a new output directory for each command.
[Dataset, scripts, and prerequisites](https://github.com/egavrin/vera-classifier-dataset/tree/1a35bcd3a9e01d40fd805c57f6c77aa53ab7ed6c/shared_q8)

```bash
python3.12 shared_q8/prepare.py --out /path/to/new-q8-inputs
bash shared_q8/reproduce.sh --app /path/to/deal-studio-ohos --out /path/to/new-q8-run
```

The launcher prepares the historical splits, trains the ranker, builds the
Rust worker, and measures the saved 22-question request. Use the steps below
to run the same recipe manually or train on new labeled requests.

## Generate fresh examples and train Q8

Run `shared_q8/fresh.sh` from the private dataset repository to generate
native requests through `dataset.py`, label them in two passes, and train Q8
on the resulting fit and selection splits. The live command requires explicit
call, token, and USD limits. The fixture command uses local responses.
[Fresh Q8 command and prerequisites](https://github.com/egavrin/vera-classifier-dataset/blob/466316b7e61246d1edeb843ef04503229b0c2a73/shared_q8/README.md#generate-fresh-training-inputs)

## 1. Download the checkpoint and pin the runner

Use Python 3.12 and Rust 1.93.1. Run these commands from a Deal Studio repository checkout that contains the pinned revision. If necessary, fetch the branch first with `git fetch origin egavrin/local-jev-playground`.

```bash
repo_root=$(git rev-parse --show-toplevel)
revision=e1d642655668a480752a9a7bb14d7c874cadca22
work=$(mktemp -d "${TMPDIR:-/tmp}/vera-shared-q8.XXXXXX")
python3.12 -m venv "$work/venv"
py="$work/venv/bin/python"
"$py" -m pip install torch==2.15.0 numpy==2.3.5 tokenizers==0.23.3 \
  safetensors==0.8.0 huggingface_hub==2.4.0
"$py" -m pip freeze > "$work/python-versions.txt"

"$work/venv/bin/hf" download jhu-clsp/mmBERT-small pytorch_model.bin \
  --revision abc32620dd4f6ab06f5fbe905dc25f310618e09f \
  --local-dir "$work/mmbert-small"
asset_path=tools/vera-playground/models/mmbert-shared-state-q8
git -C "$repo_root" archive "$revision" native/local-jev \
  "$asset_path/tokenizer.json" "$asset_path/NOTICE" "$asset_path/LICENSE-MMBERT-MIT" \
  "$asset_path/GEMMA-TERMS.md" "$asset_path/prohibited-use.md" | tar -x -C "$work"
assets="$work/$asset_path"
```

Use the tokenizer from the pinned repository revision. Its vocabulary matches the public checkpoint. Its serialization and right truncation at 48 tokens match the historical ranker, which applies outer caps of 1,024 for state, 256 for instructions, and 64 for options after tokenization. Copy the asset notices and terms when distributing a bundle. [Tokenizer provenance and notices](https://github.com/egavrin/deal-studio-ohos/blob/e1d642655668a480752a9a7bb14d7c874cadca22/tools/vera-playground/models/mmbert-shared-state-q8/README.md)

## 2. Prepare complete Vera requests and split them by scenario

Export one JSON object per line. Use the actual builder output for `request`, including its state, question IDs, instructions, and offered option IDs and descriptions. A question with a reliable single label can use a one-hot distribution. Keep an ambiguous or unavailable label absent from `gold`. A valid offered `none` option can receive probability like any other option. For a standard `noul` question, put probabilities on `false` and `true`. Keep the descriptions in explicit `noul` criteria. The trainer and runner use generic descriptions when the criteria are empty or absent.

```json
{"id":"timer-001","split_group":"countdown-explicit-minutes","language":"en","request":{"state":"Give me a two-minute countdown.","questions":{"unit.timer":{"type":"choice","instructions":"Select the time unit for the duration.","criteria":{"minutes":"Minutes","seconds":"Seconds"}}}},"gold":{"unit.timer":{"probabilities":{"minutes":1,"seconds":0}}}}
```

Save separate `fit.jsonl`, `selection.jsonl`, and `test.jsonl` files. Put related prompts, translations, paraphrases, and replays of a catalog change in the same scenario group. Seal the test before fitting. Use one or more selection cohorts for checkpoint selection. Collect labels from saved teacher responses or review. Use blind human judgments to measure accuracy. Report agreement with Jev or DeepSeek separately.

To collect new requests, follow the dataset repository's native-builder rehearsal, collection, and review instructions. Keep the exported request bodies. Map each released, valid categorical label to a one-hot distribution over its original offered keys. For a labeled standard `noul` value, put the probability on `true` and the remaining mass on `false`. The instructions require access to the private repository. [Vera dataset instructions](https://github.com/egavrin/vera-classifier-dataset/blob/487b3ded04b9fa51f1aa59721cd889386c78b6ef/README.md)

The original run used **15,399 eligible decisions** after its split exclusions. It fit on the merged historical corpus and targeted extension, with two selection cohorts. The test and saved timing requests stayed outside training. New labels can train the same architecture. Exact historical quality comparisons require the archived input bodies and labels.

To repeat the original training inputs, run `shared_q8/prepare.py` from the private archive above. For manual preparation, decompress the inputs and join `corpus-v3-train.jsonl` followed by `cycle3-train.jsonl`. Keep `corpus-v3-calibration.jsonl` and `cycle3-calibration.jsonl` as separate selection cohorts. For the fit split, exclude rows that share a scenario group or normalized state with selection or `corpus-v3-test.jsonl`. Exclude saved timing states in `requests.json` from fit and selection. Exclude test states from selection. Normalize a state with `" ".join(state.casefold().split())`. The resulting counts are 3,090 fit requests and 645 and 69 selection requests.

## 3. Project the original table, train the ranker, and export Q8

Save the following as `$work/rebuild.py`. This script starts with a random ranker and a frozen table from the public checkpoint. It fits for 12 epochs using soft cross-entropy and AdamW. It selects the epoch with the lowest median selection loss across the supplied cohorts. Training uses MPS when available and CPU otherwise.

```python
from argparse import ArgumentParser
from collections import defaultdict
from hashlib import file_digest
import json
from pathlib import Path
import random
from shutil import copyfile
from statistics import median

import numpy as np
from safetensors.torch import save_file
from tokenizers import Tokenizer
import torch
from torch import nn

SEED = 20261029
VOCAB = 256_000
WIDTH = 96


def project(checkpoint):
    state = torch.load(checkpoint, map_location="cpu", weights_only=True)
    table = state["model.embeddings.tok_embeddings.weight"].half().double()
    del state
    assert table.shape == (VOCAB, 384)
    _, vectors = torch.linalg.eigh(table.T @ table)
    basis = vectors[:, -WIDTH:].flip(1).contiguous()
    pivots = basis.abs().argmax(dim=0)
    basis *= basis[pivots, torch.arange(WIDTH)].sign()
    return (table @ basis).half().numpy()


def project_texts(tokenizer, table, specs):
    result = np.zeros((len(specs), WIDTH * 4), dtype=np.float32)
    for start in range(0, len(specs), 512):
        block = specs[start:start + 512]
        encoded = tokenizer.encode_batch([text for text, _ in block], add_special_tokens=False)
        for offset, (encoding, (_, cap)) in enumerate(zip(encoded, block)):
            ids = [token for token in encoding.ids if token != 4]
            if len(ids) > cap:
                ids = ids[:cap // 2] + ids[-(cap - cap // 2):]
            if ids:
                rows = table[ids]
                parts = (rows.mean(0), rows.max(0), rows[:8].mean(0), rows[-8:].mean(0))
                result[start + offset] = np.concatenate(
                    [part / max(float(np.linalg.norm(part)), 1e-6) for part in parts]
                )
    return result


class Ranker(nn.Module):
    def __init__(self, num_families):
        super().__init__()

        def projection():
            return nn.Sequential(
                nn.Linear(384, 192), nn.GELU(), nn.Linear(192, 128), nn.LayerNorm(128)
            )

        self.state, self.question, self.option = projection(), projection(), projection()
        self.family = nn.Embedding(num_families, 128)
        self.rank = nn.Sequential(
            nn.Linear(640, 192), nn.GELU(), nn.Dropout(0.12),
            nn.Linear(192, 64), nn.GELU(), nn.Linear(64, 1),
        )

    def forward(self, states, owners, questions, families, options):
        state = self.state(states)[owners][:, None].expand(-1, options.shape[1], -1)
        query = (self.question(questions) + self.family(families))[:, None].expand_as(state)
        option = self.option(options)
        return self.rank(torch.cat((state, query, option, query * option, state * option), -1)).squeeze(-1)


def prepare(rows, family, index):
    items = []
    for row in rows:
        request = row["request"]
        assert set(row["gold"]) <= request["questions"].keys(), row["id"]
        for key, question in sorted(request["questions"].items()):
            if key not in row["gold"]:
                continue
            if question["type"] == "choice":
                options = question["criteria"]
            else:
                assert question["type"] == "noul" and "labels" not in question, key
                options = question.get("criteria", {})
                if options == {}:
                    options = {"false": "no: the statement is false", "true": "yes: the statement is true"}
                assert isinstance(options, dict) and options.keys() == {"false", "true"}, key
            gold = row["gold"][key]["probabilities"]
            assert options and gold.keys() == options.keys(), (row["id"], key)
            keys = sorted(options)
            target = np.asarray([gold[option] for option in keys], dtype=np.float32)
            assert np.isfinite(target).all() and (target >= 0).all() and target.sum() > 0
            items.append((
                index((request["state"], 1024)), index((question["instructions"], 256)),
                family.get(key.partition(".")[0], 0),
                [index((f" {option}: {options[option]}", 64)) for option in keys],
                target / target.sum(),
            ))
    assert items, "split has no labeled decisions"
    return items


def batches(items, rng=None):
    buckets = defaultdict(list)
    for item in items:
        buckets[(len(item[3]) - 1).bit_length()].append(item)
    packed = []
    for bucket in buckets.values():
        if rng is not None:
            rng.shuffle(bucket)
        packed.extend(bucket[start:start + 128] for start in range(0, len(bucket), 128))
    if rng is not None:
        rng.shuffle(packed)
    return packed


def losses(model, batch, vectors, device):
    states, owners = np.unique([item[0] for item in batch], return_inverse=True)
    options = np.zeros((len(batch), max(len(item[3]) for item in batch)), dtype=np.int64)
    target = np.zeros_like(options, dtype=np.float32)
    padding = np.ones_like(options, dtype=bool)
    for i, (_, _, _, ids, prob) in enumerate(batch):
        options[i, :len(ids)] = ids
        target[i, :len(ids)] = prob
        padding[i, :len(ids)] = False

    def tensor(value):
        return torch.from_numpy(value).to(device)

    scores = model(
        tensor(vectors[states]), tensor(owners), tensor(vectors[[item[1] for item in batch]]),
        tensor(np.asarray([item[2] for item in batch])), tensor(vectors[options]),
    )
    return -(scores.masked_fill(tensor(padding), -1e4).log_softmax(dim=1) * tensor(target)).sum(dim=1)


def read_rows(path):
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


def digest(path):
    with path.open("rb") as stream:
        return file_digest(stream, "sha256").hexdigest()


def main():
    parser = ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--fit", type=Path, nargs="+", required=True)
    parser.add_argument("--selection", type=Path, nargs="+", required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir()
    torch.manual_seed(SEED)
    torch.set_num_threads(4)
    torch.set_num_interop_threads(1)
    rng = random.Random(SEED)
    device = "mps" if torch.backends.mps.is_available() else "cpu"

    fit = [row for path in args.fit for row in read_rows(path)]
    selection = [read_rows(path) for path in args.selection]
    fit_groups = {row["split_group"] for row in fit}
    fit_states = {" ".join(row["request"]["state"].casefold().split()) for row in fit}
    for cohort in selection:
        assert fit_groups.isdisjoint(row["split_group"] for row in cohort)
        assert fit_states.isdisjoint(" ".join(row["request"]["state"].casefold().split()) for row in cohort)
    prefixes = {key.partition(".")[0] for row in fit for key in row["request"]["questions"]}
    family = {name: i for i, name in enumerate(sorted(prefixes), start=1)}
    spec_ids = {}

    def index(spec):
        return spec_ids.setdefault(spec, len(spec_ids))

    training = prepare(fit, family, index)
    validation = [batches(prepare(cohort, family, index)) for cohort in selection]
    tokenizer = Tokenizer.from_file(str(args.tokenizer))
    table = project(args.checkpoint)
    vectors = project_texts(tokenizer, table, list(spec_ids))
    model = Ranker(len(family) + 1).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=8e-4, weight_decay=0.015)
    history = []
    best_loss = float("inf")
    print(f"Fitting {len(training)} decisions on {device}", flush=True)
    for epoch in range(1, 13):
        model.train()
        for batch in batches(training, rng):
            optimizer.zero_grad(set_to_none=True)
            losses(model, batch, vectors, device).mean().backward()
            optimizer.step()
        model.eval()
        with torch.no_grad():
            scores = [
                sum(value for batch in cohort for value in losses(model, batch, vectors, device).tolist())
                / sum(map(len, cohort))
                for cohort in validation
            ]
        assert np.isfinite(scores).all()
        history.append(scores)
        print(epoch, scores, flush=True)
        if median(scores) < best_loss:
            best_loss = median(scores)
            best_epoch = epoch
            best = {key: tensor.detach().cpu().clone() for key, tensor in model.state_dict().items()}

    copyfile(args.tokenizer, args.out / "tokenizer.json")
    save_file(best, args.out / "ranker.safetensors")
    rows = table.astype(np.float32)
    scales = np.maximum(np.abs(rows).max(axis=1), 1e-12) / 127
    q8 = np.rint(rows / scales[:, None]).clip(-127, 127).astype(np.int8)
    with (args.out / "embeddings.q8").open("wb") as stream:
        stream.write(scales.astype("<f4").tobytes())
        stream.write(q8.tobytes())
    assets = {
        name: digest(args.out / name)
        for name in ("tokenizer.json", "ranker.safetensors", "embeddings.q8")
    }
    (args.out / "model.json").write_text(json.dumps({
        "family_ids": family, "asset_sha256": assets,
    }, indent=2) + "\n", encoding="utf-8")
    args.out.with_suffix(".training.json").write_text(json.dumps({
        "input_sha256": {
            str(path): digest(path)
            for path in [args.checkpoint, args.tokenizer, *args.fit, *args.selection]
        },
        "fit_decisions": len(training), "device": device, "seed": SEED,
        "selection_soft_cross_entropy": history, "selected_epoch": best_epoch, "assets": assets,
    }, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
```

Set `fit_jsonl` to the prepared fit file. For one selection cohort, set `selection_jsonl` to its prepared file.

```bash
selection_files=("$selection_jsonl")
```

For the historical rebuild, set `historical_selection_jsonl` and `extension_selection_jsonl` to the two filtered calibration files from step 2. Pass them in the original order.

```bash
selection_files=("$historical_selection_jsonl" "$extension_selection_jsonl")
```

Run the trainer with the selected inputs.

```bash
"$py" "$work/rebuild.py" \
  --checkpoint "$work/mmbert-small/pytorch_model.bin" \
  --tokenizer "$assets/tokenizer.json" \
  --fit "$fit_jsonl" --selection "${selection_files[@]}" --out "$work/bundle"
wc -c "$work/bundle/"*
shasum -a 256 "$work/bundle/"*
```

The embedding export writes 256,000 little-endian F32 scales followed by 256,000 rows of 96 signed bytes. On the reference Mac, the table built from the public checkpoint matched the historical Q8 hash `9349e1f085cf7df69e98372ba17f1dcc5c39b17b2320c8a87fab1c5089f4abe6`. The FP16 casts reproduce the rounding of the original import and rank-96 export. Fresh labels and different training hardware can change the ranker checkpoint and its hash.

## 4. Build the Rust worker and measure one warm process

```bash
env -u JEV_BUNDLE_DIR -u LAYA_BUNDLE_DIR \
  CARGO_TARGET_DIR="$work/target" CARGO_PROFILE_RELEASE_LTO=true \
  CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 CARGO_PROFILE_RELEASE_OPT_LEVEL=3 \
  cargo build --locked --release \
  --manifest-path "$work/native/local-jev/Cargo.toml" --bin local-jev-shared
runner="$work/target/release/local-jev-shared"
```

Set `request_json` to a file containing one complete Vera request body with `state` and `questions`. To reproduce the historical measurement, use the original 22-question body with SHA-256 `64a420c4b4f334c52a9f7ffa5531ad4462798ac12b5bd5510723fa3b3d482d9c`. The preparation script writes this body verbatim to `request22.json`. Use `saved-jev.json` from the same output directory to compare with the archived Jev answers.

```bash
"$py" - "$runner" "$work/bundle" "$request_json" > "$work/timing.json" <<'PY'
from hashlib import sha256
import json
from math import ceil
import os
from pathlib import Path
from statistics import median
import subprocess
import sys
from time import perf_counter_ns

runner, bundle, path = sys.argv[1:]
raw = Path(path).read_bytes()
request = json.loads(raw)
env = os.environ | {"RAYON_NUM_THREADS": "8", "VECLIB_MAXIMUM_THREADS": "1"}
samples = []
with subprocess.Popen([runner, bundle], text=True, encoding="utf-8",
                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env) as process:
    ready = json.loads(process.stdout.readline())
    assert ready["ready"] and ready["protocol"] == 1
    expected = None
    for i in range(31):
        frame = json.dumps({"id": str(i), "request": request}, ensure_ascii=False) + "\n"
        start = perf_counter_ns()
        process.stdin.write(frame)
        process.stdin.flush()
        line = process.stdout.readline()
        wall_ms = (perf_counter_ns() - start) / 1e6
        result = json.loads(line)
        assert result["id"] == str(i)
        reply = result["response"]
        assert reply["answers"].keys() == request["questions"].keys()
        for key, answer in reply["answers"].items():
            question = request["questions"][key]
            assert answer["type"] == question["type"]
            if answer["type"] == "choice":
                assert answer["choice"] in question["criteria"]
            else:
                assert 0 <= answer["noul"] <= 1
        if expected is None:
            expected = reply
        assert reply == expected
        samples.append({"wall_ms": wall_ms, "rust_ms": result["inference_ms"]})
    process.stdin.close()
    assert process.wait(timeout=15) == 0
warm = sorted(sample["wall_ms"] for sample in samples[1:])
print(json.dumps({
    "request_sha256": sha256(raw).hexdigest(), "questions": len(request["questions"]),
    "startup_ms": ready["startup_ms"], "first_call": samples[0],
    "warm_p50_ms": median(warm), "warm_p95_ms": warm[ceil(0.95 * len(warm)) - 1],
    "raw_warm": samples[1:], "reply": expected,
}, indent=2))
PY
```

Run the frozen bundle on the sealed test and compare the typed winners with its labels. Count decision coverage and exact whole-request agreement. Check multilingual requests, similar options, new component descriptions, and long inputs. Record the model asset and runner hashes with the scores. The wall measurement includes round-trip pipe transport. Measure the native app and physical device separately.

### Reference measurement

The table compares two archived runs with a fresh rebuild on one Mac. Each run used a resident Rust process and 30 warm calls on the same saved **22-question request**.

| Bundle | Warm p50 | Warm p95 | Saved Jev agreement |
|---|---:|---:|---:|
| Original shared-state head | 1.98 ms | 2.16 ms | 19/22 |
| Retrained shared-state head | 2.02 ms | 2.31 ms | 20/22 |
| Rebuilt from the public checkpoint using this guide | 2.17 ms | 2.47 ms | 19/22 |

The rebuild trained on 15,399 archived decisions and selected epoch 10 with both selection cohorts. It produced a 41,061,517-byte bundle. The Q8 table and tokenizer match the original byte for byte. The Rust process started in 474 ms. The two archived bundles loaded in about 390 ms.

A mixed `choice` and `noul` fixture confirmed that the trainer and runner used the explicit `noul` descriptions. With the exported Q8 table, the maximum observed logit difference between Python and Rust was approximately `1.43e-6`. Phone latency and human-checked quality need separate measurements.
