# mmBERT shared-state Q8

This experimental scorer uses one state representation for each request.
The Rust scorer returns choice and noul probabilities at temperature 1.
The probabilities have no human calibration.
The tokenizer keeps up to the first 48 tokens of each state, question, and
option text before the worker applies its outer caps.
The selector log records scores and uncertainty.

The tokenizer and compressed token embeddings derive from
`jhu-clsp/mmBERT-small` at `abc32620dd4f6ab06f5fbe905dc25f310618e09f`.
The embedding table uses 96 dimensions and signed 8-bit values with one scale
per token. The Vera experiment fine-tuned the F32 ranker on Vera selector
decisions and selected epoch 8 by validation loss.
The upstream model card declares the MIT license.
[Pinned mmBERT model and license](https://huggingface.co/jhu-clsp/mmBERT-small/tree/abc32620dd4f6ab06f5fbe905dc25f310618e09f)
[MIT license text and attribution](LICENSE-MMBERT-MIT)

The mmBERT configuration names `google/gemma-2-9b` as the tokenizer source.
The Vera tokenizer retains the mmBERT vocabulary and changes the serialized
special tokens, tokenization settings, and model fields.
[mmBERT training configuration](https://github.com/JHU-CLSP/mmBERT/blob/main/configs/mmBERT-small.yaml)

Use and distribution of `tokenizer.json` are subject to Section 3.2 of the
Gemma Terms of Use. Keep the notice and terms with the tokenizer.
[Notice](NOTICE)
[Gemma Terms of Use](GEMMA-TERMS.md)
[Gemma Prohibited Use Policy](prohibited-use.md)

The four runtime files total 41,061,517 bytes. The Rust worker checks the
three asset SHA-256 values in `model.json` before it accepts requests.
The SHA-256 of `model.json` is
`4d40ff9d998cb139df51104bcf3c3d9a23f8bf609bc74c25819b5017e1eec7d5`.
