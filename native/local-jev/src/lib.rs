//! Experimental local Jev decisions. Missing answers preserve application safeguards.
pub mod laya;
mod laya_backbone;
pub mod shared_experimental;
use candle_core::{DType, Device, Tensor};
use candle_nn::VarBuilder;
use candle_transformers::models::bert::{BertModel, Config};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    ffi::{c_char, CString},
    path::Path,
    sync::{Mutex, OnceLock},
};
use tokenizers::Tokenizer;
mod assets {
    include!(concat!(env!("OUT_DIR"), "/assets.rs"));
}

pub const MAX_BYTES: usize = 262_144;
const MAX_TOKENS: usize = 512;
const CALL_TOKENS: usize = 8192;

type Result<T> = std::result::Result<T, String>;

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub format: u32,
    pub holdout_component: Option<String>,
    pub label_source: String,
    pub asset_sha256: BTreeMap<String, String>,
    pub training_group_hashes: Vec<String>,
    pub training_state_hashes: Vec<String>,
    pub calibration_group_hashes: Vec<String>,
    pub calibration_state_hashes: Vec<String>,
    pub base_model: String,
    pub base_revision: String,
    pub training_data_sha256: String,
    pub scale: f64,
    pub temperature: f64,
    pub min_confidence: f64,
    pub calibrated: bool,
    pub calibration_data_sha256: String,
}

#[derive(Deserialize)]
pub struct Question {
    #[serde(rename = "type")]
    pub kind: String,
    pub instructions: String,
    #[serde(default)]
    pub criteria: BTreeMap<String, String>,
}
#[derive(Deserialize)]
pub struct Request {
    pub state: String,
    pub questions: BTreeMap<String, Question>,
}

pub fn parse(body: &str) -> Result<Request> {
    parse_with_min_options(body, 2)
}
pub(crate) fn parse_with_min_options(body: &str, min_options: usize) -> Result<Request> {
    if body.len() > MAX_BYTES {
        return Err("request_too_large".into());
    }
    let r: Request = serde_json::from_str(body).map_err(|_| "invalid_request")?;
    if r.state.trim().is_empty() || r.questions.is_empty() || r.questions.len() > 128 {
        return Err("invalid_request".into());
    }
    for (key, q) in &r.questions {
        if key.is_empty()
            || q.instructions.trim().is_empty()
            || !matches!(q.kind.as_str(), "choice" | "noul")
        {
            return Err("unsupported_question".into());
        }
        if q.kind == "choice" && (q.criteria.len() < min_options || q.criteria.len() > 255) {
            return Err("unsupported_criteria".into());
        }
        if q.kind == "noul"
            && !q.criteria.is_empty()
            && (q.criteria.len() != 2
                || !q.criteria.contains_key("true")
                || !q.criteria.contains_key("false"))
        {
            return Err("unsupported_criteria".into());
        }
        if q.criteria
            .iter()
            .any(|(k, v)| k.trim().is_empty() || v.trim().is_empty())
        {
            return Err("unsupported_criteria".into());
        }
    }
    Ok(r)
}

pub(crate) fn parse_diagnostic_request(body: &str) -> Result<Request> {
    let request = parse_with_min_options(body, 1)?;
    let raw: Value = serde_json::from_str(body).map_err(|_| "invalid_request")?;
    if raw["questions"].as_object().is_some_and(|questions| {
        questions
            .values()
            .any(|question| question.get("labels").is_some())
    }) {
        return Err("unsupported_custom_noul_labels".into());
    }
    Ok(request)
}

pub fn options(q: &Question) -> Vec<(String, String)> {
    if q.kind == "noul" && q.criteria.is_empty() {
        vec![
            ("false".into(), "no: the statement is false".into()),
            ("true".into(), "yes: the statement is true".into()),
        ]
    } else {
        q.criteria
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect()
    }
}

pub fn uncertain(reason: &str) -> Value {
    json!({"answers": {}, "local": {"status": "uncertain", "reason": reason}})
}

pub struct Engine {
    model: BertModel,
    tokenizer: Tokenizer,
    pub manifest: Manifest,
}
impl Engine {
    pub fn from_dir(dir: &Path) -> Result<Self> {
        let mut size = 0u64;
        for name in [
            "config.json",
            "tokenizer.json",
            "model.safetensors",
            "manifest.json",
        ] {
            size = size
                .checked_add(
                    std::fs::metadata(dir.join(name))
                        .map_err(|_| "missing_asset")?
                        .len(),
                )
                .ok_or("bundle_too_large")?;
        }
        if size > 300_000_000 {
            return Err("bundle_too_large".into());
        }
        let read = |file| std::fs::read(dir.join(file)).map_err(|_| "missing_asset".to_string());
        Self::from_bytes(
            &read("config.json")?,
            &read("tokenizer.json")?,
            &read("model.safetensors")?,
            &read("manifest.json")?,
        )
    }
    pub fn embedded() -> Result<Self> {
        Self::from_bytes(
            assets::CONFIG,
            assets::TOKENIZER,
            assets::WEIGHTS,
            assets::MANIFEST,
        )
    }
    pub fn from_bytes(
        config: &[u8],
        tokenizer: &[u8],
        weights: &[u8],
        manifest: &[u8],
    ) -> Result<Self> {
        if weights.is_empty() {
            return Err("model_unavailable".into());
        }
        if config.len() + tokenizer.len() + weights.len() + manifest.len() > 300_000_000 {
            return Err("bundle_too_large".into());
        }
        let manifest: Manifest =
            serde_json::from_slice(manifest).map_err(|_| "invalid_manifest")?;
        for (name, bytes) in [
            ("config.json", config),
            ("tokenizer.json", tokenizer),
            ("model.safetensors", weights),
        ] {
            let actual = format!("{:x}", Sha256::digest(bytes));
            if manifest.asset_sha256.get(name) != Some(&actual) {
                return Err("asset_hash_mismatch".into());
            }
        }
        if manifest.format != 1
            || !manifest.scale.is_finite()
            || manifest.scale <= 0.
            || !manifest.temperature.is_finite()
            || manifest.temperature <= 0.
            || !(0.5..=1.).contains(&manifest.min_confidence)
        {
            return Err("invalid_calibration".into());
        }
        if manifest.calibrated
            && (manifest.training_data_sha256.len() != 64
                || manifest.calibration_data_sha256.len() != 64)
        {
            return Err("missing_provenance".into());
        }
        let config: Config = serde_json::from_slice(config).map_err(|_| "invalid_config")?;
        if config.max_position_embeddings < MAX_TOKENS {
            return Err("unsupported_context".into());
        }
        let mut tokenizer = Tokenizer::from_bytes(tokenizer).map_err(|_| "invalid_tokenizer")?;
        tokenizer
            .with_truncation(None)
            .map_err(|_| "invalid_tokenizer")?;
        tokenizer.with_padding(None);
        let vb = VarBuilder::from_slice_safetensors(weights, DType::F32, &Device::Cpu)
            .map_err(|e| e.to_string())?;
        let model = BertModel::load(vb, &config).map_err(|e| e.to_string())?;
        Ok(Self {
            model,
            tokenizer,
            manifest,
        })
    }
    fn encode(&self, text: &str) -> Result<Vec<u32>> {
        let ids = self
            .tokenizer
            .encode(text, true)
            .map_err(|_| "tokenization_failed")?
            .get_ids()
            .to_vec();
        if ids.is_empty() || ids.len() > MAX_TOKENS {
            return Err("text_too_long".into());
        }
        Ok(ids)
    }
    fn embed(&self, ids: &[u32]) -> Result<Vec<f32>> {
        let ids = Tensor::new(ids, &Device::Cpu)
            .and_then(|x| x.unsqueeze(0))
            .map_err(|e| e.to_string())?;
        let types = ids.zeros_like().map_err(|e| e.to_string())?;
        let hidden = self
            .model
            .forward(&ids, &types, None)
            .map_err(|e| e.to_string())?;
        let pooled = hidden
            .mean(1)
            .and_then(|x| x.squeeze(0))
            .and_then(|x| x.to_vec1::<f32>())
            .map_err(|e| e.to_string())?;
        let norm = pooled.iter().map(|v| v * v).sum::<f32>().sqrt();
        if !norm.is_finite() || norm <= 0. {
            return Err("nonfinite_embedding".into());
        }
        Ok(pooled.iter().map(|v| v / norm).collect())
    }
    pub fn scores(&self, body: &str) -> Result<Value> {
        let r = parse(body)?;
        let mut encoded = Vec::new();
        let mut total = 0;
        // Validate every text before any inference. No truncation or partial long-input answer.
        for (key, q) in &r.questions {
            let query = self.encode(&format!("query: {}\n{}", r.state, q.instructions))?;
            let mut candidates = Vec::new();
            for (id, desc) in options(q) {
                let ids = self.encode(&format!("passage: {desc}"))?;
                total += ids.len();
                candidates.push((id, ids));
            }
            total += query.len();
            if total > CALL_TOKENS {
                return Err("call_too_large".into());
            }
            encoded.push((key, q, query, candidates));
        }
        let mut scores = BTreeMap::new();
        for (key, q, query, candidates) in encoded {
            let query = self.embed(&query)?;
            let mut logits = BTreeMap::new();
            for (id, ids) in candidates {
                let passage = self.embed(&ids)?;
                let score = query
                    .iter()
                    .zip(passage)
                    .map(|(a, b)| (*a as f64) * (b as f64))
                    .sum::<f64>()
                    * self.manifest.scale;
                if !score.is_finite() {
                    return Err("nonfinite_score".into());
                }
                logits.insert(id, score);
            }
            scores.insert(key, json!({"type": q.kind, "logits": logits}));
        }
        Ok(json!({"scores": scores}))
    }
    pub fn predict(&self, body: &str) -> Value {
        if !self.manifest.calibrated {
            return uncertain("uncalibrated_model");
        }
        match self.scores(body) {
            Ok(raw) => decisions(
                &raw,
                self.manifest.temperature,
                self.manifest.min_confidence,
            ),
            Err(_) => uncertain("unsupported_or_failed_inference"),
        }
    }
}

pub fn decisions(raw: &Value, temperature: f64, threshold: f64) -> Value {
    let Some(scores) = raw["scores"].as_object() else {
        return uncertain("invalid_scores");
    };
    let mut answers = BTreeMap::new();
    for (key, q) in scores {
        let Some(logits) = q["logits"].as_object() else {
            continue;
        };
        let vals: Vec<_> = logits
            .iter()
            .filter_map(|(k, v)| v.as_f64().map(|v| (k, v / temperature)))
            .collect();
        if vals.len() < 2 || vals.iter().any(|(_, v)| !v.is_finite()) {
            continue;
        }
        let max = vals
            .iter()
            .map(|(_, v)| *v)
            .fold(f64::NEG_INFINITY, f64::max);
        let sum = vals.iter().map(|(_, v)| (v - max).exp()).sum::<f64>();
        let Some((id, best)) = vals.iter().max_by(|a, b| a.1.total_cmp(&b.1)) else {
            continue;
        };
        let confidence = (*best - max).exp() / sum;
        if confidence < threshold {
            continue;
        }
        if q["type"] == "noul" {
            if let Some((_, v)) = vals.iter().find(|(k, _)| k.as_str() == "true") {
                answers.insert(key, json!({"noul": (*v-max).exp()/sum}));
            }
        } else {
            answers.insert(key, json!({"choice": id, "confidence": confidence}));
        }
    }
    json!({"answers": answers, "local": {"status": if answers.len() == scores.len() {"answered"} else {"uncertain"}}})
}

/// Developer-only temperature-1 decisions. Never called by regular prediction.
/// Keep this in Rust so host and phone use exactly the same validation and policy.
pub fn experimental_decisions(mut raw: Value, body: &str) -> Value {
    if raw.get("scores").is_none() {
        return raw;
    }
    let request = match parse_with_min_options(body, 1) {
        Ok(request) => request,
        Err(reason) => return uncertain(&reason),
    };
    let Some(scores) = raw["scores"].as_object() else {
        return uncertain("invalid_scores");
    };
    if scores.len() != request.questions.len() {
        return uncertain("invalid_scores");
    }
    let mut answers = serde_json::Map::new();
    for (key, question) in &request.questions {
        let score = &scores.get(key).unwrap_or(&Value::Null);
        let Some(logits) = score["logits"].as_object() else {
            return uncertain("invalid_scores");
        };
        let ids: Vec<String> = if question.kind == "noul" {
            vec!["false".into(), "true".into()]
        } else {
            question.criteria.keys().cloned().collect()
        };
        if score["type"] != question.kind || logits.len() != ids.len() {
            return uncertain("invalid_scores");
        }
        let mut values = Vec::new();
        for id in &ids {
            match logits.get(id).and_then(Value::as_f64) {
                Some(value) if value.is_finite() => values.push(value),
                _ => return uncertain("invalid_scores"),
            }
        }
        let max = values.iter().copied().fold(f64::NEG_INFINITY, f64::max);
        let total: f64 = values.iter().map(|value| (value - max).exp()).sum();
        let mut probabilities = serde_json::Map::new();
        let mut best = 0;
        for (i, id) in ids.iter().enumerate() {
            probabilities.insert(id.clone(), json!((values[i] - max).exp() / total));
            // Deterministic ties: first lexicographic ID, matching BTreeMap request order.
            if values[i] > values[best] {
                best = i;
            }
        }
        let answer = if question.kind == "noul" {
            json!({"type":"noul", "noul":probabilities["true"], "probabilities":probabilities})
        } else {
            json!({"type":"choice", "choice":ids[best], "probabilities":probabilities})
        };
        answers.insert(key.clone(), answer);
    }
    let production_reason = raw["local"]["reason"].clone();
    raw["answers"] = Value::Object(answers);
    raw["local"]["status"] = json!("diagnostic");
    raw["local"]["reason"] = json!("playground_uncalibrated_logits");
    raw["local"]["productionReason"] = production_reason;
    raw["local"]["diagnostic"] = json!(true);
    raw["local"]["calibrated"] = json!(false);
    raw["local"]["productionAllowed"] = json!(false);
    raw["local"]["scoreTemperature"] = json!(1);
    raw
}

static ENGINE: OnceLock<Mutex<Result<Engine>>> = OnceLock::new();
static LAYA: OnceLock<Mutex<Result<laya::Engine>>> = OnceLock::new();

/// Input is UTF-8 bytes. Release the returned allocation with local_jev_free.
#[no_mangle]
pub unsafe extern "C" fn local_jev_predict(data: *const u8, len: usize) -> *mut c_char {
    reply(data, len, |body| {
        if !assets::LAYA_CONFIG.is_empty() {
            // Laya remains disabled until independent human calibration and release acceptance exist.
            return uncertain("laya_not_human_calibrated");
        }
        let engine = ENGINE
            .get_or_init(|| Mutex::new(Engine::embedded()))
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        match &*engine {
            Ok(engine) => engine.predict(body),
            Err(_) => uncertain("model_unavailable"),
        }
    })
}

/// Experimental logits for an embedded Laya bundle. This never supplies app answers.
#[no_mangle]
pub unsafe extern "C" fn local_jev_diagnostic_scores(data: *const u8, len: usize) -> *mut c_char {
    reply(data, len, |body| {
        let engine = LAYA
            .get_or_init(|| Mutex::new(laya::Engine::embedded()))
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        match &*engine {
            Ok(engine) => engine
                .diagnostic_scores(body)
                .unwrap_or_else(|reason| uncertain(&reason)),
            Err(_) => uncertain("laya_model_unavailable"),
        }
    })
}

unsafe fn reply(
    data: *const u8,
    len: usize,
    run: impl FnOnce(&str) -> Value + std::panic::UnwindSafe,
) -> *mut c_char {
    let output = std::panic::catch_unwind(|| {
        if data.is_null() || len > MAX_BYTES {
            return uncertain("invalid_request");
        }
        let Ok(body) = std::str::from_utf8(std::slice::from_raw_parts(data, len)) else {
            return uncertain("invalid_utf8");
        };
        run(body)
    })
    .unwrap_or_else(|_| uncertain("inference_failed"));
    CString::new(output.to_string()).unwrap().into_raw()
}
#[no_mangle]
pub unsafe extern "C" fn local_jev_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}
/// ABI probe for build and packaging checks.
#[no_mangle]
pub extern "C" fn local_jev_abi() -> u32 {
    1
}
