# Cloud Jev and Local Rust playground

Run the same mini-app request with Cloud Jev and the local mmBERT shared-state Q8 selector. DeepSeek
makes one plan and both paths verify and use that plan. DeepSeek still writes
section content and code in both paths. The host runs the app's compiler and VM
to draw each preview.

## Start from a fresh checkout

Use Node.js 22 or later and Rust 1.93.1 or later. Run these commands from
the repository root.

```sh
npm install --no-save --package-lock=false typescript@5.9.3
cargo build --locked --release --manifest-path native/local-jev/Cargo.toml \
  --bin local-jev-shared
```

The repository supplies the shared-state Q8 bundle in `tools/vera-playground/models`.
[Bundle provenance and license notices](models/mmbert-shared-state-q8/README.md)

[Rebuild and benchmark the shared-state Q8 selector from public mmBERT-small](../../docs/local-jev-shared-q8-reproduction.md)

### Start the playground

Set `DEEPSEEK_API_KEY` and `TYPESAFE_API_KEY` in your environment or
`~/.env`. Search in section fill also uses `EXA_API_KEY` when set in the
environment.

```sh
node tools/vera-playground/server.js
```

Open the playground. Set `VERA_PLAYGROUND_PORT` if port 4173 is in use.
[Playground](http://127.0.0.1:4173/)

## Select a Laya Q4 bundle

Build the runners first. Set `VERA_LAYA_MANIFEST` to select an existing
Q4 bundle. Set `VERA_LAYA_CLI` to select an alternate Laya runner.
If you set only `VERA_LAYA_CLI`, the server reads the manifest from
`.local-jev/bundle-q4/laya-manifest.json`. Restart the server after a change.

```sh
cargo build --locked --release --manifest-path native/local-jev/Cargo.toml \
  --bin local-laya --bin laya-quantize
```

### Use the 49 MB Cycle 2 bundle

If you have `mmbert-small-cycle2-q4.tar.gz`, extract it into a new directory.
Replace `/path/to` with the archive location.

```sh
mkdir -p .local-jev
mkdir .local-jev/mmbert-small-cycle2-q4 &&
  tar -xzf /path/to/mmbert-small-cycle2-q4.tar.gz -C .local-jev/mmbert-small-cycle2-q4
export VERA_LAYA_MANIFEST="$PWD/.local-jev/mmbert-small-cycle2-q4/laya-manifest.json"
```

The archive provides `laya-config.json`, `laya-manifest.json`, `model.gguf`,
and `tokenizer.json`. Keep the four files together. If you have the unpacked
bundle, set `VERA_LAYA_MANIFEST` to its absolute manifest path. The same
directory works for the [embedded app build](../../native/local-jev/README.md).

### Export the public Laya Multilingual Q4 bundle

Use Python 3.11 or later to export this model. The download uses about 678 MB.
This model uses mmBERT-base.
[Pinned Apache-2.0 checkpoint](https://huggingface.co/convaiinnovations/laya-multilingual/tree/1720e3e3357cfe1e281542e223f8273b0890ca34)

```sh
python3 -m venv .local-jev/venv
. .local-jev/venv/bin/activate
python -m pip install 'huggingface_hub==2.4.0' 'transformers==5.22.0'
revision=1720e3e3357cfe1e281542e223f8273b0890ca34
hf download convaiinnovations/laya-multilingual --revision "$revision" \
  --local-dir .local-jev/laya-base --include model.safetensors rl_agent_config.json \
  encoder/config.json 'tokenizer/*'
python tools/local-jev/laya-export.py .local-jev/laya-base .local-jev/bundle-q4 \
  --base-revision "$revision" --q4-embeddings
export VERA_LAYA_MANIFEST="$PWD/.local-jev/bundle-q4/laya-manifest.json"
```

## Run a comparison

1. Enter `A tip calculator with a bill amount, tip percent, and split per person.`
   Select **Run comparison**. The two panels show the generated screens.
2. Open **Notes** and check that both paths consumed the same plan hash.
   **Selector time** covers decision calls. **Total generation time** includes
   writing and compiling the path. Shared planning time and Rust startup
   appear separately. The server keeps the Rust model loaded across runs.
3. Open **Matched selector requests** to compare both selectors on identical
   decision inputs. The generated paths can ask different questions after their
   first decision. The match rate measures agreement with Jev.
4. Use **Random prompt** for a new DeepSeek-written draft, or **Start auto** to
   generate and run requests in sequence. The server uses exact matching and a
   DeepSeek novelty check against saved prompts. **Stop** ends automatic runs.

The local model supplies uncalibrated scores for this experiment. The previews
use approximate host SVG layout. Wide requests with the public Laya model can
take tens of seconds on a CPU. Use the same bundle and machine when comparing
results.

Reports, decision logs, and plan hashes are saved under `.local-jev/playground/`.
A custom port uses `.local-jev/playground-<port>/`.
These records can contain prompt text and generated code.

## Verify without API keys

Run the HTTP and Auto checks first. The last two checks also use the selected
bundle and compiled Rust worker. All four use fixtures for cloud replies.

```sh
node tools/vera-playground/check.js
node tools/vera-playground/prompt-check.js
node tools/vera-playground/laya-check.js
node tools/vera-playground/pipeline-check.js
```

The last two checks print their report paths. The reports record the shared-plan
hash and Rust worker identity. The pipeline check also covers restart, request
matching, uncertainty, and failed providers. Run the same checks with
`VERA_LAYA_MANIFEST` set to test the explicit Laya path.

See [OpenHarmony integration](../../native/local-jev/README.md) for the
embedded build, C ABI verification, and the app call sites.

## Run the shared Qwen prototype on a Mac

The [19.7 MB archive](models/vera-qwen-shared-q8-macos-arm64.zip) includes the
Apple Silicon CLI, the Qwen tokenizer, the compressed embedding table, and a
sample request. The CLI uses the same table for UI selection and Vera formula
generation.

Run these commands from the repository root.

```sh
unzip tools/vera-playground/models/vera-qwen-shared-q8-macos-arm64.zip -d .local-jev
cd .local-jev/vera-qwen-shared-q8-macos-arm64
./local-jev-shared bundle < example.jsonl
```

The example returns `(billAmount * (tipPercent / 100))`. On an M4 Pro, the
median warm formula call took 0.30 ms. In the replay, 513 of 603 formulas passed
the Vera VM numeric checks, including one of three formulas from a saved app plan.
The UI scorer reproduced 45 of 45 decisions from the earlier Qwen scorer.

The archive includes a standalone CLI that accepts framed Jev-shaped requests.
The playground uses the mmBERT shared-state Q8 bundle described above.
The OpenHarmony build uses Laya-compatible bundles.
