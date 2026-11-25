//! Experimental quantized Laya. Diagnostic scores never authorize production answers.
use crate::laya_backbone::{attention, Config as EncoderConfig, ModernBert};
use crate::{parse_diagnostic_request, uncertain, Question};
use candle_core::{DType, Device, IndexOp, Tensor};
use candle_nn::LayerNorm;
use candle_transformers::{
    quantized_nn::{self as qnn, Linear},
    quantized_var_builder::VarBuilder,
};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::Path,
    time::{Duration, Instant},
};
use tokenizers::Tokenizer;

const CALL_TOKENS: usize = 8192;
const MAX_BATCH_QUESTIONS: usize = 4;
const HEAD_INSTRUCTION_RESERVE: usize = 16;
const OPTION_PAYLOAD_LIMIT: usize = 48;

#[derive(Deserialize)]
pub struct Config {
    encoder_config: EncoderConfig,
    head_layers: usize,
    max_len: usize,
    head_max_len: usize,
    temperature: Vec<f64>,
    cls_token_id: u32,
    sep_token_id: u32,
    mask_token_id: u32,
    mask_token: String,
}

struct HeadLayer {
    input: Linear,
    output: Linear,
    norm1: LayerNorm,
    norm2: LayerNorm,
    linear1: Linear,
    linear2: Linear,
}
impl HeadLayer {
    fn load(vb: VarBuilder, dim: usize) -> candle_core::Result<Self> {
        let input = Linear::from_arc(
            vb.pp("self_attn").get((dim * 3, dim), "in_proj_weight")?,
            Some(
                vb.pp("self_attn")
                    .get(dim * 3, "in_proj_bias")?
                    .dequantize(vb.device())?,
            ),
        )?;
        Ok(Self {
            input,
            output: qnn::linear(dim, dim, vb.pp("self_attn.out_proj"))?,
            norm1: qnn::layer_norm(dim, 1e-5, vb.pp("norm1"))?,
            norm2: qnn::layer_norm(dim, 1e-5, vb.pp("norm2"))?,
            linear1: qnn::linear(dim, dim * 4, vb.pp("linear1"))?,
            linear2: qnn::linear(dim * 4, dim, vb.pp("linear2"))?,
        })
    }
    fn forward(&self, x: &Tensor, lengths: Option<&[usize]>) -> candle_core::Result<Tensor> {
        let (b, n, dim) = x.dims3()?;
        let heads = dim / 64;
        let qkv = x
            .apply(&self.norm1)?
            .apply(&self.input)?
            .reshape((b, n, 3, heads, 64))?
            .permute((2, 0, 3, 1, 4))?;
        let q = (qkv.i(0)?.contiguous()? / 8.)?;
        let k = qkv.i(1)?.contiguous()?;
        let v = qkv.i(2)?.contiguous()?;
        let attention = attention(&q, &k, &v, None, lengths)?
            .transpose(1, 2)?
            .reshape((b, n, dim))?
            .apply(&self.output)?;
        let h = (x + attention)?;
        let ff = h
            .apply(&self.norm2)?
            .apply(&self.linear1)?
            .relu()?
            .apply(&self.linear2)?;
        h + ff
    }
}

struct PreparedQuestion<'a> {
    key: &'a str,
    kind: &'a str,
    ids: Vec<u32>,
    markers: Vec<usize>,
    options: Vec<String>,
    truncation: Value,
}

impl PreparedQuestion<'_> {
    fn kind_index(&self) -> u32 {
        if self.kind == "choice" {
            0
        } else {
            2
        }
    }
}

fn batch_len(questions: &[PreparedQuestion<'_>]) -> usize {
    let mut real_cells = 0;
    let mut count = 0;
    for question in questions.iter().take(MAX_BATCH_QUESTIONS) {
        let n = question.ids.len();
        real_cells += n * n;
        let rows = count + 1;
        // Limit extra attention work to 25 percent for each length-sorted group.
        if rows * n > CALL_TOKENS || 4 * rows * n * n > 5 * real_cells {
            break;
        }
        count = rows;
    }
    count
}

fn allocate_options(source: &[Vec<u32>], head_max_len: usize) -> Result<Vec<Vec<u32>>, String> {
    let per = (head_max_len - HEAD_INSTRUCTION_RESERVE) / source.len();
    if per < 2 {
        return Err("head_token_budget".into());
    }
    let mut spans: Vec<_> = source
        .iter()
        .map(|tokens| tokens[..tokens.len().min(per - 1)].to_vec())
        .collect();
    let mut counts = BTreeMap::new();
    for span in &spans {
        *counts.entry(span.clone()).or_insert(0usize) += 1;
    }
    let mut used: BTreeSet<_> = counts
        .iter()
        .filter(|&(_, &count)| count == 1)
        .map(|(span, _)| span.clone())
        .collect();
    for (tokens, span) in source.iter().zip(&mut spans) {
        if counts[span] == 1 || used.insert(span.clone()) {
            continue;
        }
        let k = span.len();
        let mut replacement = None;
        'search: for prefix in (0..k).rev() {
            let tail = k - prefix;
            for start in prefix + 1..=tokens.len() - tail {
                let candidate: Vec<_> = tokens[..prefix]
                    .iter()
                    .chain(&tokens[start..start + tail])
                    .copied()
                    .collect();
                if used.insert(candidate.clone()) {
                    replacement = Some(candidate);
                    break 'search;
                }
            }
        }
        *span = replacement.ok_or("option_tokens_collapsed")?;
    }
    Ok(spans)
}

#[derive(Default)]
pub(crate) struct ScoreTimings {
    pub preparation: Duration,
    pub forward: Duration,
}

fn measure<T>(elapsed: Option<&mut Duration>, run: impl FnOnce() -> T) -> T {
    if let Some(elapsed) = elapsed {
        let start = Instant::now();
        let result = run();
        *elapsed += start.elapsed();
        result
    } else {
        run()
    }
}

pub struct Engine {
    encoder: ModernBert,
    head: Vec<HeadLayer>,
    type_embedding: Tensor,
    norm: LayerNorm,
    scorer1: Linear,
    scorer2: Linear,
    tokenizer: Tokenizer,
    config: Config,
}

impl Engine {
    pub fn from_dir(path: &Path) -> Result<Self, String> {
        let names = [
            "laya-config.json",
            "tokenizer.json",
            "model.gguf",
            "laya-manifest.json",
        ];
        let size = names
            .iter()
            .try_fold(0u64, |total, name| {
                std::fs::metadata(path.join(name)).map(|m| total + m.len())
            })
            .map_err(|e| e.to_string())?;
        if size > 300_000_000 {
            return Err("assets_exceed_budget".into());
        }
        let data: Vec<_> = names
            .iter()
            .map(|name| std::fs::read(path.join(name)))
            .collect::<std::io::Result<_>>()
            .map_err(|e| e.to_string())?;
        Self::from_bytes(&data[0], &data[1], &data[2], &data[3])
    }
    pub fn embedded() -> Result<Self, String> {
        Self::from_bytes(
            crate::assets::LAYA_CONFIG,
            crate::assets::LAYA_TOKENIZER,
            crate::assets::LAYA_WEIGHTS,
            crate::assets::LAYA_MANIFEST,
        )
    }
    fn from_bytes(
        config: &[u8],
        tokenizer: &[u8],
        weights: &[u8],
        manifest: &[u8],
    ) -> Result<Self, String> {
        let load = || -> Result<Self, Box<dyn std::error::Error>> {
            if config.len() + tokenizer.len() + weights.len() + manifest.len() > 300_000_000 {
                return Err("assets_exceed_budget".into());
            }
            let manifest: Value = serde_json::from_slice(manifest)?;
            if manifest["format"] != "laya-gguf-mixed-v1"
                && manifest["format"] != "laya-gguf-q4k-v1"
                && manifest["format"] != "laya-gguf-q4_0-v1"
            {
                return Err("unsupported_manifest".into());
            }
            for (name, bytes) in [
                ("laya-config.json", config),
                ("tokenizer.json", tokenizer),
                ("model.gguf", weights),
            ] {
                if manifest["asset_sha256"][name].as_str()
                    != Some(format!("{:x}", Sha256::digest(bytes)).as_str())
                {
                    return Err("asset_hash_mismatch".into());
                }
            }
            let cfg: Config = serde_json::from_slice(config)?;
            let ec = &cfg.encoder_config;
            if !ec.supported_architecture()
                || ec.vocab_size != 256000
                || ec.intermediate_size != 1152
                || ec.global_attn_every_n_layers != 3
                || ec.local_attention != 128
                || !ec.layer_norm_eps.is_finite()
                || ec.layer_norm_eps <= 0.
                || !ec.global_rope_theta.is_finite()
                || ec.global_rope_theta <= 0.
                || !ec.local_rope_theta.is_finite()
                || ec.local_rope_theta <= 0.
                || cfg.max_len == 0
                || cfg.max_len > 1024
                || ec.max_position_embeddings > 8192
                || cfg.max_len > ec.max_position_embeddings
                || cfg.head_max_len < HEAD_INSTRUCTION_RESERVE
                || cfg.head_max_len > cfg.max_len
                || [cfg.cls_token_id, cfg.sep_token_id, cfg.mask_token_id]
                    .iter()
                    .any(|id| *id as usize >= ec.vocab_size)
            {
                return Err("unsupported_laya_architecture".into());
            }
            if cfg.temperature.len() != 3
                || cfg.temperature.iter().any(|x| !x.is_finite() || *x <= 0.)
                || cfg.head_layers != 2
            {
                return Err("invalid_laya_config".into());
            }
            let mut tok = Tokenizer::from_bytes(tokenizer).map_err(|e| e.to_string())?;
            // Upstream training can persist the last per-option truncation setting in tokenizer.json.
            tok.with_truncation(None).map_err(|e| e.to_string())?;
            tok.with_padding(None);
            let vb = VarBuilder::from_gguf_buffer(weights, &Device::Cpu)?;
            let dim = cfg.encoder_config.hidden_size;
            let encoder = ModernBert::load(vb.clone(), &cfg.encoder_config)?;
            let head = (0..cfg.head_layers)
                .map(|i| HeadLayer::load(vb.pp(format!("head.layers.{i}")), dim))
                .collect::<candle_core::Result<_>>()?;
            let type_embedding = vb
                .get((3, dim), "type_emb.weight")?
                .dequantize(&Device::Cpu)?;
            Ok(Self {
                encoder,
                head,
                type_embedding,
                norm: qnn::layer_norm(dim, 1e-5, vb.pp("scorer.0"))?,
                scorer1: qnn::linear(dim, dim, vb.pp("scorer.1"))?,
                scorer2: qnn::linear(dim, 1, vb.pp("scorer.3"))?,
                tokenizer: tok,
                config: cfg,
            })
        };
        load().map_err(|e| e.to_string())
    }
    fn tokens(&self, text: &str) -> Result<Vec<u32>, String> {
        self.tokenizer
            .encode(text.replace(&self.config.mask_token, " "), false)
            .map(|x| x.get_ids().to_vec())
            .map_err(|e| e.to_string())
    }
    fn sequence<'a>(
        &self,
        state_tokens: &[u32],
        key: &'a str,
        q: &'a Question,
        capped: bool,
    ) -> Result<PreparedQuestion<'a>, String> {
        let options: Vec<_> = if q.kind == "noul" {
            [
                ("false", "no, the statement does not hold"),
                ("true", "yes, the statement holds"),
            ]
            .iter()
            .map(|(k, default)| {
                (
                    k.to_string(),
                    q.criteria.get(*k).cloned().unwrap_or(default.to_string()),
                )
            })
            .collect()
        } else {
            q.criteria
                .iter()
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect()
        };
        let mut instruction = self.tokens(&format!("{} question: {}", q.kind, q.instructions))?;
        let original_instruction = instruction.len();
        let mut original_options = 0;
        let mut option_tokens = Vec::new();
        for (id, description) in &options {
            let mut tokens = self.tokens(&format!(" {id}: {description}"))?;
            // Upstream caps option descriptions at 48 tokens. Decline if information would be lost.
            original_options += tokens.len();
            if tokens.len() > OPTION_PAYLOAD_LIMIT && !capped {
                return Err("option_token_budget".into());
            }
            if capped {
                tokens.truncate(OPTION_PAYLOAD_LIMIT);
            }
            option_tokens.push(tokens);
        }
        let head = self.config.head_max_len;
        let mut spans: Vec<_> = option_tokens.iter().map(Vec::as_slice).collect();
        let mut used: usize = spans.iter().map(|tokens| tokens.len() + 1).sum();
        let mut budget = head.saturating_sub(used);
        if budget < HEAD_INSTRUCTION_RESERVE {
            if !capped {
                return Err("head_token_budget".into());
            }
            let per = ((head - HEAD_INSTRUCTION_RESERVE) / spans.len()).max(4);
            for tokens in &mut spans {
                *tokens = &tokens[..tokens.len().min(per - 1)];
            }
            used = spans.iter().map(|tokens| tokens.len() + 1).sum();
            budget = head.saturating_sub(used);
        }
        if instruction.len() > budget.max(8) && !capped {
            return Err("head_token_budget".into());
        }
        let collapsed = spans.iter().copied().collect::<BTreeSet<_>>().len() != spans.len();
        let repaired = capped && (collapsed || used + instruction.len().min(budget.max(8)) > head);
        let repaired_options;
        if repaired {
            repaired_options = allocate_options(&option_tokens, head)?;
            spans = repaired_options.iter().map(Vec::as_slice).collect();
            used = spans.iter().map(|tokens| tokens.len() + 1).sum();
            budget = head - used;
        } else if collapsed {
            return Err("option_tokens_collapsed".into());
        }
        if capped {
            instruction.truncate(budget.max(8));
        }
        let kept_instruction = instruction.len();
        let mut ids = vec![self.config.cls_token_id];
        ids.append(&mut instruction);
        ids.push(self.config.sep_token_id);
        let mut markers = Vec::new();
        for tokens in spans {
            markers.push(ids.len());
            ids.push(self.config.mask_token_id);
            ids.extend_from_slice(tokens);
        }
        ids.push(self.config.sep_token_id);
        let original_state = state_tokens.len();
        let room = self.config.max_len.saturating_sub(ids.len() + 1);
        if original_state > room && !capped {
            return Err("state_token_budget".into());
        }
        let kept_state = original_state.min(room);
        ids.extend_from_slice(&state_tokens[..kept_state]);
        ids.push(self.config.sep_token_id);
        if ids.len() > self.config.max_len {
            return Err("option_token_budget".into());
        }
        let kept_options = used - options.len();
        let mut truncation = json!({"instruction_tokens_dropped":original_instruction-kept_instruction,
            "option_tokens_dropped":original_options-kept_options,"state_tokens_dropped":original_state-kept_state,
            "truncated": original_instruction>kept_instruction || original_options>kept_options || original_state>kept_state});
        if repaired {
            truncation["option_budget_repaired"] = json!(true);
        }
        Ok(PreparedQuestion {
            key,
            kind: &q.kind,
            ids,
            markers,
            options: options.into_iter().map(|(k, _)| k).collect(),
            truncation,
        })
    }
    pub fn scores(&self, body: &str) -> Result<Value, String> {
        self.score(body, false, false, None, None)
    }
    pub fn diagnostic_scores(&self, body: &str) -> Result<Value, String> {
        self.score(body, true, false, None, None)
    }
    pub fn batched_scores(
        &self,
        body: &str,
        capped: bool,
        batch_lengths: Option<&mut Vec<Vec<usize>>>,
    ) -> Result<Value, String> {
        self.score(body, capped, true, batch_lengths, None)
    }
    pub(crate) fn benchmark_scores(
        &self,
        body: &str,
        batched: bool,
        batch_lengths: &mut Vec<Vec<usize>>,
        timings: &mut ScoreTimings,
    ) -> Result<Value, String> {
        self.score(body, true, batched, Some(batch_lengths), Some(timings))
    }
    fn score(
        &self,
        body: &str,
        capped: bool,
        batched: bool,
        mut batch_lengths: Option<&mut Vec<Vec<usize>>>,
        mut timings: Option<&mut ScoreTimings>,
    ) -> Result<Value, String> {
        let started = timings.as_ref().map(|_| Instant::now());
        let request = parse_diagnostic_request(body)?;
        // Preflight every question before model execution.
        let state_tokens = self.tokens(&request.state)?;
        let mut sequences = request
            .questions
            .iter()
            .map(|(key, q)| self.sequence(&state_tokens, key, q, capped))
            .collect::<Result<Vec<_>, _>>()?;
        if sequences.iter().map(|q| q.ids.len()).sum::<usize>() > CALL_TOKENS {
            return Err("call_token_budget".into());
        }
        if batched {
            sequences.sort_by_key(|q| q.ids.len());
        }
        if let (Some(timings), Some(started)) = (&mut timings, started) {
            timings.preparation = started.elapsed();
        }
        let mut output = BTreeMap::new();
        let mut truncations = BTreeMap::new();
        let mut remaining = sequences.as_slice();
        while !remaining.is_empty() {
            let count = if batched { batch_len(remaining) } else { 1 };
            let (group, rest) = remaining.split_at(count);
            remaining = rest;
            if let Some(report) = &mut batch_lengths {
                report.push(group.iter().map(|q| q.ids.len()).collect());
            }
            let hidden = measure(timings.as_deref_mut().map(|t| &mut t.forward), || {
                self.infer_group(group)
            })
            .map_err(|e| e.to_string())?;
            for (row, question) in group.iter().enumerate() {
                let values = measure(timings.as_deref_mut().map(|t| &mut t.forward), || {
                    self.marker_scores(&hidden, row, &question.markers)
                })
                .map_err(|e| e.to_string())?;
                if values.iter().any(|v| !v.is_finite()) {
                    return Err("nonfinite_scores".into());
                }
                truncations.insert(question.key, &question.truncation);
                let logits = question
                    .options
                    .iter()
                    .zip(values)
                    .collect::<BTreeMap<_, _>>();
                output.insert(question.key, json!({"type":question.kind,"logits":logits}));
            }
        }
        Ok(
            json!({"answers":{},"scores":output,"local":{"status":"uncertain","reason":"laya_not_human_calibrated","model":"laya-multilingual-quantized","input_policy":if capped {"playground-upstream-token-caps"}else{"strict-no-truncation"},"truncation":truncations}}),
        )
    }
    fn infer_group(&self, group: &[PreparedQuestion<'_>]) -> candle_core::Result<Tensor> {
        let device = &Device::Cpu;
        if let [question] = group {
            let n = question.ids.len();
            let input = Tensor::from_slice(&question.ids, (1, n), device)?;
            let mask = Tensor::ones((1, n), DType::U32, device)?;
            let kind = self.type_embedding.i(question.kind_index() as usize)?;
            return self.forward(&input, &mask, &kind, None);
        }

        let b = group.len();
        let n = group[b - 1].ids.len();
        let mut ids = Vec::with_capacity(b * n);
        let mut mask = Vec::with_capacity(b * n);
        let mut kinds = Vec::with_capacity(b);
        let mut lengths = Vec::with_capacity(b);
        for (row, question) in group.iter().enumerate() {
            ids.extend_from_slice(&question.ids);
            // Use a validated token ID for padding that the attention masks hide.
            ids.resize((row + 1) * n, self.config.cls_token_id);
            mask.resize(row * n + question.ids.len(), 1u32);
            mask.resize((row + 1) * n, 0);
            kinds.push(question.kind_index());
            lengths.push(question.ids.len());
        }
        let input = Tensor::from_vec(ids, (b, n), device)?;
        let mask = Tensor::from_vec(mask, (b, n), device)?;
        let kinds = self
            .type_embedding
            .index_select(&Tensor::new(kinds, device)?, 0)?;
        let padded = lengths[0] < n;
        self.forward(&input, &mask, &kinds, padded.then_some(lengths.as_slice()))
    }
    fn forward(
        &self,
        input: &Tensor,
        mask: &Tensor,
        kinds: &Tensor,
        lengths: Option<&[usize]>,
    ) -> candle_core::Result<Tensor> {
        let b = input.dim(0)?;
        let kinds = kinds.reshape((b, 1, self.config.encoder_config.hidden_size))?;
        let mut hidden = self
            .encoder
            .forward(input, mask, lengths)?
            .broadcast_add(&kinds)?;
        for layer in &self.head {
            hidden = layer.forward(&hidden, lengths)?;
        }
        Ok(hidden)
    }
    fn marker_scores(
        &self,
        hidden: &Tensor,
        row: usize,
        markers: &[usize],
    ) -> candle_core::Result<Vec<f32>> {
        let selected = markers
            .iter()
            .map(|i| hidden.i((row, *i)))
            .collect::<candle_core::Result<Vec<_>>>()?;
        Tensor::stack(&selected, 0)?
            .apply(&self.norm)?
            .apply(&self.scorer1)?
            .gelu_erf()?
            .apply(&self.scorer2)?
            .flatten_all()?
            .to_vec1::<f32>()
    }
    pub fn predict(&self, _body: &str) -> Value {
        uncertain("laya_not_human_calibrated")
    }
}

#[cfg(test)]
mod option_budget_tests {
    use super::*;

    #[test]
    fn allocation_reserves_unique_prefixes_and_uses_source_windows() {
        let shared = vec![1, 2, 3, 4];
        let source = [
            shared.clone(),
            shared.clone(),
            shared,
            vec![1, 3],
            vec![1, 4],
            vec![8],
        ];
        assert_eq!(
            allocate_options(&source, 34).unwrap(),
            [
                vec![1, 2],
                vec![2, 3],
                vec![3, 4],
                vec![1, 3],
                vec![1, 4],
                vec![8]
            ],
        );
        assert_eq!(
            allocate_options(&[vec![1, 2], vec![1, 2, 3, 4]], 22).unwrap(),
            [vec![1, 2], vec![1, 3]],
        );
    }

    #[test]
    fn allocation_rejects_insufficient_space_or_exhausted_spans() {
        let source = [vec![1, 2], vec![1, 2]];
        assert_eq!(
            allocate_options(&source, 19).unwrap_err(),
            "head_token_budget"
        );
        assert_eq!(allocate_options(&source, 20).unwrap(), [vec![1], vec![2]]);
        assert_eq!(
            allocate_options(&source, 22).unwrap_err(),
            "option_tokens_collapsed",
        );
    }

    #[test]
    #[ignore = "requires LAYA_TEST_BUNDLE pointing to a real bundle"]
    fn sequence_preserves_legacy_layout_and_bounds_the_fallback() {
        let bundle = std::env::var("LAYA_TEST_BUNDLE").expect("set LAYA_TEST_BUNDLE");
        let engine = Engine::from_dir(Path::new(&bundle)).unwrap();
        let config = &engine.config;
        let normal = Question {
            kind: "choice".into(),
            instructions: "Pick one".into(),
            criteria: BTreeMap::from([("a".into(), "one".into()), ("b".into(), "two".into())]),
        };
        let mut expected = vec![config.cls_token_id];
        expected.extend(engine.tokens("choice question: Pick one").unwrap());
        expected.push(config.sep_token_id);
        let mut markers = Vec::new();
        for (key, text) in &normal.criteria {
            markers.push(expected.len());
            expected.push(config.mask_token_id);
            expected.extend(engine.tokens(&format!(" {key}: {text}")).unwrap());
        }
        expected.push(config.sep_token_id);
        let state_tokens = engine.tokens("small state").unwrap();
        expected.extend_from_slice(&state_tokens);
        expected.push(config.sep_token_id);
        for capped in [true, false] {
            let prepared = engine
                .sequence(&state_tokens, "normal", &normal, capped)
                .unwrap();
            assert_eq!(prepared.ids, expected);
            assert_eq!(prepared.markers, markers);
            assert_eq!(prepared.options, ["a", "b"]);
            assert_eq!(
                prepared.truncation,
                json!({
                    "instruction_tokens_dropped": 0, "option_tokens_dropped": 0,
                    "state_tokens_dropped": 0, "truncated": false,
                })
            );
        }

        let wide = Question {
            kind: "choice".into(),
            instructions: "Pick one of these many different options from the list.".repeat(10),
            criteria: (0..65)
                .map(|i| {
                    (
                        format!("left {i:02}"),
                        format!("right {i:02} {}", " long".repeat(60)),
                    )
                })
                .collect(),
        };
        let state = " long state".repeat(1200);
        let state_tokens = engine.tokens(&state).unwrap();
        let prepared = engine.sequence(&state_tokens, "wide", &wide, true).unwrap();
        assert_eq!(
            prepared.options,
            wide.criteria.keys().cloned().collect::<Vec<_>>()
        );
        assert_eq!(prepared.markers.len(), wide.criteria.len());
        let head_end = prepared.markers.last().unwrap() + 3;
        assert_eq!(prepared.ids[head_end], config.sep_token_id);
        assert_eq!(head_end - 2, config.head_max_len);
        assert_eq!(prepared.ids.len(), config.max_len);
        let original_instruction = engine
            .tokens(&format!("choice question: {}", wide.instructions))
            .unwrap()
            .len();
        let original_options: usize = wide
            .criteria
            .iter()
            .map(|(key, text)| engine.tokens(&format!(" {key}: {text}")).unwrap().len())
            .sum();
        assert_eq!(
            prepared.truncation,
            json!({
                "instruction_tokens_dropped": original_instruction - (config.head_max_len - 65 * 3),
                "option_tokens_dropped": original_options - 65 * 2,
                "state_tokens_dropped": state_tokens.len() - (config.max_len - head_end - 2),
                "truncated": true, "option_budget_repaired": true,
            })
        );
        let mut unique = std::collections::BTreeSet::new();
        for (marker, (key, text)) in prepared.markers.iter().copied().zip(&wide.criteria) {
            assert_eq!(prepared.ids[marker], config.mask_token_id);
            let payload = &prepared.ids[marker + 1..marker + 3];
            assert!(unique.insert(payload));
            let source = engine.tokens(&format!(" {key}: {text}")).unwrap();
            assert!(
                source[..48].windows(2).any(|pair| pair == payload)
                    || (source[0] == payload[0] && source[2..48].contains(&payload[1]))
            );
        }
        assert_eq!(
            engine
                .sequence(&state_tokens, "wide", &wide, false)
                .err()
                .unwrap(),
            "option_token_budget"
        );
        let questions: BTreeMap<_, _> = (0..9).map(|i| (
            i.to_string(),
            json!({"type": wide.kind, "instructions": wide.instructions, "criteria": wide.criteria}),
        )).collect();
        assert_eq!(
            engine
                .diagnostic_scores(&json!({"state": state, "questions": questions}).to_string())
                .unwrap_err(),
            "call_token_budget",
        );
    }
}
