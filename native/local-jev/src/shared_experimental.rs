use crate::{assets, options, parse_diagnostic_request, uncertain};
use candle_core::{DType, Device, Tensor};
use candle_nn::{embedding, func, layer_norm, linear, Func, Module, VarBuilder};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, path::Path};
use tokenizers::Tokenizer;

const WIDTH: usize = 96;
const VOCAB: usize = 256_000;
const FEATURE: usize = 4 * WIDTH;
pub(crate) const MODEL_ID: &str = "mmbert-shared-state-q8-experimental";
pub(crate) const MANIFEST_SHA256: &str =
    "4d40ff9d998cb139df51104bcf3c3d9a23f8bf609bc74c25819b5017e1eec7d5";

#[derive(Deserialize)]
struct Config {
    family_ids: BTreeMap<String, u32>,
    asset_sha256: BTreeMap<String, String>,
}

pub struct Ranker {
    tokenizer: Tokenizer,
    scales: Vec<f32>,
    table: Vec<u8>,
    families: BTreeMap<String, u32>,
    state: Func<'static>,
    question: Func<'static>,
    option: Func<'static>,
    family: candle_nn::Embedding,
    rank: Func<'static>,
}

fn projection(vb: VarBuilder) -> candle_core::Result<Func<'static>> {
    let input = linear(FEATURE, 192, vb.pp("0"))?;
    let output = linear(192, 128, vb.pp("2"))?;
    let norm = layer_norm(128, 1e-5, vb.pp("3"))?;
    Ok(func(move |xs| {
        let hidden = input.forward(xs)?.gelu_erf()?;
        norm.forward(&output.forward(&hidden)?)
    }))
}

fn rank_head(vb: VarBuilder) -> candle_core::Result<Func<'static>> {
    let input = linear(640, 192, vb.pp("0"))?;
    let middle = linear(192, 64, vb.pp("3"))?;
    let output = linear(64, 1, vb.pp("5"))?;
    Ok(func(move |xs| {
        let hidden = input.forward(xs)?.gelu_erf()?;
        let hidden = middle.forward(&hidden)?.gelu_erf()?;
        output.forward(&hidden)
    }))
}

impl Ranker {
    pub fn load(dir: &Path) -> Result<Self, Box<dyn std::error::Error>> {
        let read = |name: &str| std::fs::read(dir.join(name));
        Self::from_bytes(
            &read("model.json")?,
            &read("tokenizer.json")?,
            &read("embeddings.q8")?,
            &read("ranker.safetensors")?,
        )
    }

    pub(crate) fn embedded() -> Result<Self, Box<dyn std::error::Error>> {
        if format!("{:x}", Sha256::digest(assets::SHARED_MANIFEST)) != MANIFEST_SHA256 {
            return Err("Shared model manifest hash mismatch".into());
        }
        Self::from_bytes(
            assets::SHARED_MANIFEST,
            assets::SHARED_TOKENIZER,
            assets::SHARED_EMBEDDINGS,
            assets::SHARED_WEIGHTS,
        )
    }

    fn from_bytes(
        manifest: &[u8],
        tokenizer: &[u8],
        table: &[u8],
        weights: &[u8],
    ) -> Result<Self, Box<dyn std::error::Error>> {
        let config: Config = serde_json::from_slice(manifest)?;
        for (name, bytes) in [
            ("tokenizer.json", tokenizer),
            ("embeddings.q8", table),
            ("ranker.safetensors", weights),
        ] {
            if config.asset_sha256.get(name) != Some(&format!("{:x}", Sha256::digest(bytes))) {
                return Err(format!("Asset hash mismatch: {name}").into());
            }
        }
        let tokenizer = Tokenizer::from_bytes(tokenizer).map_err(|error| error.to_string())?;
        if table.len() != VOCAB * (4 + WIDTH) {
            return Err("Invalid embedding table size".into());
        }
        let (scale_bytes, rows) = table.split_at(VOCAB * 4);
        let scales: Vec<_> = scale_bytes
            .chunks_exact(4)
            .map(|bytes| f32::from_le_bytes(bytes.try_into().unwrap()))
            .collect();
        if scales.iter().any(|v| !v.is_finite() || *v <= 0.0) {
            return Err("Invalid embedding table scales".into());
        }
        let weights = candle_core::safetensors::load_buffer(weights, &Device::Cpu)?;
        let vb = VarBuilder::from_tensors(weights, DType::F32, &Device::Cpu);
        let families = config.family_ids;
        if families
            .values()
            .any(|&id| id == 0 || id as usize > families.len())
        {
            return Err("Invalid question family ID".into());
        }
        Ok(Self {
            tokenizer,
            scales,
            table: rows.to_vec(),
            state: projection(vb.pp("state"))?,
            question: projection(vb.pp("question"))?,
            option: projection(vb.pp("option"))?,
            family: embedding(families.len() + 1, 128, vb.pp("family"))?,
            families,
            rank: rank_head(vb.pp("rank"))?,
        })
    }

    fn features(&self, text: &str, cap: usize) -> Result<[f32; FEATURE], String> {
        let e = self
            .tokenizer
            .encode(text, false)
            .map_err(|e| e.to_string())?;
        let ids: Vec<_> = e.get_ids().iter().copied().filter(|&id| id != 4).collect();
        let mut out = [0.0; FEATURE];
        if ids.is_empty() {
            return Ok(out);
        }
        let cropped;
        let ids = if ids.len() > cap {
            cropped = [&ids[..cap / 2], &ids[ids.len() - (cap - cap / 2)..]].concat();
            cropped.as_slice()
        } else {
            ids.as_slice()
        };
        let edge = ids.len().min(8);
        out[WIDTH..2 * WIDTH].fill(f32::NEG_INFINITY);
        for (position, &id) in ids.iter().enumerate() {
            let id = id as usize;
            let scale = *self.scales.get(id).ok_or("token_out_of_range")?;
            let row = &self.table[id * WIDTH..(id + 1) * WIDTH];
            for (j, &encoded) in row.iter().enumerate() {
                let value = f32::from(encoded as i8) * scale;
                out[j] += value;
                out[WIDTH + j] = out[WIDTH + j].max(value);
                if position < edge {
                    out[2 * WIDTH + j] += value;
                }
                if position >= ids.len() - edge {
                    out[3 * WIDTH + j] += value;
                }
            }
        }
        for (i, part) in out.chunks_exact_mut(WIDTH).enumerate() {
            let count = [ids.len(), 1, edge, edge][i] as f32;
            for x in part.iter_mut() {
                *x /= count;
            }
            let len = part.iter().map(|x| x * x).sum::<f32>().sqrt().max(1e-6);
            for x in part {
                *x /= len;
            }
        }
        Ok(out)
    }

    pub(crate) fn raw_scores(&self, body: &str) -> Result<Value, String> {
        let parsed = parse_diagnostic_request(body)?;
        let mut qv = Vec::new();
        let mut ov = Vec::new();
        let mut groups = Vec::new();
        let mut families = Vec::new();
        let mut owners = Vec::new();
        let mut cache = BTreeMap::new();
        let state = self.features(&parsed.state, 1024)?;
        for (row, (name, question)) in parsed.questions.iter().enumerate() {
            qv.extend(self.features(&question.instructions, 256)?);
            families.push(
                self.families
                    .get(name.split('.').next().unwrap_or(name))
                    .copied()
                    .unwrap_or(0),
            );
            let items = options(question);
            for (key, description) in &items {
                let text = format!(" {key}: {description}");
                let data = match cache.entry(text) {
                    std::collections::btree_map::Entry::Occupied(entry) => entry.into_mut(),
                    std::collections::btree_map::Entry::Vacant(entry) => {
                        let features = self.features(entry.key(), 64)?;
                        entry.insert(features)
                    }
                };
                ov.extend(data.iter().copied());
                owners.push(row as u32);
            }
            groups.push((name, question.kind.as_str(), items));
        }
        let device = &Device::Cpu;
        let predict = || -> candle_core::Result<Vec<f32>> {
            let n = owners.len();
            let state = self
                .state
                .forward(&Tensor::from_slice(&state, (1, FEATURE), device)?)?
                .broadcast_as((n, 128))?
                .contiguous()?;
            let indexed = Tensor::from_slice(&owners, n, device)?;
            let labels = Tensor::from_slice(&families, families.len(), device)?;
            let query = (self.question.forward(&Tensor::from_vec(
                qv,
                (groups.len(), FEATURE),
                device,
            )?)? + self.family.forward(&labels)?)?
            .index_select(&indexed, 0)?;
            let option = self
                .option
                .forward(&Tensor::from_vec(ov, (n, FEATURE), device)?)?;
            let interact_q = (&query * &option)?;
            let interact_s = (&state * &option)?;
            let inputs = Tensor::cat(&[state, query, option, interact_q, interact_s], 1)?;
            self.rank.forward(&inputs)?.flatten_all()?.to_vec1::<f32>()
        };
        let values = predict().map_err(|error| error.to_string())?;
        let mut scores = BTreeMap::new();
        let mut offset = 0;
        for (name, kind, options) in groups {
            let end = offset + options.len();
            let logits: BTreeMap<_, _> = options
                .iter()
                .zip(&values[offset..end])
                .map(|((key, _), value)| (key, *value))
                .collect();
            if logits.values().any(|value| !value.is_finite()) {
                return Err("nonfinite_scores".into());
            }
            scores.insert(name, json!({"type":kind,"logits":logits}));
            offset = end;
        }
        Ok(json!({"answers":{},"scores":scores,"local":{
            "status":"uncertain","reason":"shared_state_not_human_calibrated",
            "model":MODEL_ID
        }}))
    }

    pub fn decisions(&self, body: &str) -> Value {
        match self.raw_scores(body) {
            Ok(scores) => crate::experimental_decisions(scores, body),
            Err(reason) => uncertain(&reason),
        }
    }
}
