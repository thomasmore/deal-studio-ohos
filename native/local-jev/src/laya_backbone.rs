// Adapted from candle-transformers 0.9.2 models/modernbert.rs.
// Copyright Hugging Face. Licensed under MIT OR Apache-2.0.
// Uses Candle quantized matrix products and the checkpoint's two RoPE bases.
use candle_core::{DType, Device, Result, Tensor, D};
use candle_nn::{ops::softmax, Embedding, LayerNorm, Module};
use candle_transformers::quantized_nn::{layer_norm_no_bias, linear_no_bias, Linear};
use candle_transformers::quantized_var_builder::VarBuilder;
use serde::Deserialize;

use core::f32;
use std::collections::HashMap;
use std::sync::Arc;

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Config {
    pub vocab_size: usize,
    pub laya_architecture: Option<String>,
    pub embedding_size: Option<usize>,
    pub layer_types: Option<Vec<String>>,
    pub hidden_size: usize,
    pub num_hidden_layers: usize,
    pub num_attention_heads: usize,
    pub intermediate_size: usize,
    pub max_position_embeddings: usize,
    pub layer_norm_eps: f64,
    pub pad_token_id: u32,
    pub global_attn_every_n_layers: usize,
    pub global_rope_theta: f64,
    pub local_attention: usize,
    pub local_rope_theta: f64,
    #[serde(default)]
    #[serde(flatten)]
    pub classifier_config: Option<ClassifierConfig>,
}

impl Config {
    pub(crate) fn supported_architecture(&self) -> bool {
        match (
            self.laya_architecture.as_deref(),
            self.embedding_size,
            self.hidden_size,
            self.num_attention_heads,
            self.num_hidden_layers,
        ) {
            (None, None, 768, 12, 22) | (None, None, 384, 6, 22) => true,
            (Some("modernbert-rank96-depth13-v1"), Some(96), 384, 6, 13) => {
                self.layer_types.as_ref().is_some_and(|types| {
                    types.len() == 13
                        && types.iter().enumerate().all(|(i, kind)| {
                            kind == if i % 3 == 0 {
                                "full_attention"
                            } else {
                                "sliding_attention"
                            }
                        })
                })
            }
            _ => false,
        }
    }
}

#[derive(Debug, Clone, Deserialize, PartialEq, Copy, Default)]
#[serde(rename_all = "lowercase")]
pub enum ClassifierPooling {
    #[default]
    CLS,
    MEAN,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct ClassifierConfig {
    pub id2label: HashMap<String, String>,
    pub label2id: HashMap<String, String>,
    pub classifier_pooling: ClassifierPooling,
}

#[derive(Debug, Clone)]
struct RotaryEmbedding {
    sin: Tensor,
    cos: Tensor,
}

impl RotaryEmbedding {
    fn new(dtype: DType, config: &Config, rope_theta: f64, dev: &Device) -> Result<Self> {
        let dim = config.hidden_size / config.num_attention_heads;
        let inv_freq: Vec<_> = (0..dim)
            .step_by(2)
            .map(|i| 1f32 / rope_theta.powf(i as f64 / dim as f64) as f32)
            .collect();
        let inv_freq_len = inv_freq.len();
        let inv_freq = Tensor::from_vec(inv_freq, (1, inv_freq_len), dev)?.to_dtype(dtype)?;
        let max_seq_len = config.max_position_embeddings;
        let t = Tensor::arange(0u32, max_seq_len as u32, dev)?
            .to_dtype(dtype)?
            .reshape((max_seq_len, 1))?;
        let freqs = t.matmul(&inv_freq)?;
        Ok(Self {
            sin: freqs.sin()?,
            cos: freqs.cos()?,
        })
    }

    fn apply_rotary_emb_qkv(&self, q: &Tensor, k: &Tensor) -> Result<(Tensor, Tensor)> {
        let q_embed = candle_nn::rotary_emb::rope(&q.contiguous()?, &self.cos, &self.sin)?;
        let k_embed = candle_nn::rotary_emb::rope(&k.contiguous()?, &self.cos, &self.sin)?;
        Ok((q_embed, k_embed))
    }
}

pub(crate) fn attention(
    q: &Tensor,
    k: &Tensor,
    v: &Tensor,
    mask: Option<&Tensor>,
    lengths: Option<&[usize]>,
) -> Result<Tensor> {
    let attend = |q: &Tensor, k: &Tensor, v: &Tensor, mask: Option<&Tensor>| {
        let logits = q.matmul(&k.transpose(D::Minus2, D::Minus1)?)?;
        let logits = match mask {
            Some(mask) => logits.broadcast_add(mask)?,
            None => logits,
        };
        softmax(&logits, D::Minus1)?.matmul(v)
    };
    let Some(lengths) = lengths else {
        return attend(q, k, v, mask);
    };
    let padded_len = q.dim(2)?;
    // Exclude pad keys and keep the serial attention reduction lengths.
    let rows = lengths
        .iter()
        .enumerate()
        .map(|(row, &len)| {
            let crop = |x: &Tensor| x.narrow(0, row, 1)?.narrow(2, 0, len);
            let mask = mask.map(|m| crop(m)?.narrow(3, 0, len)).transpose()?;
            attend(&crop(q)?, &crop(k)?, &crop(v)?, mask.as_ref())?.pad_with_zeros(
                2,
                0,
                padded_len - len,
            )
        })
        .collect::<Result<Vec<_>>>()?;
    Tensor::cat(&rows, 0)
}

#[derive(Clone)]
struct ModernBertAttention {
    qkv: Linear,
    proj: Linear,
    num_attention_heads: usize,
    attention_head_size: usize,
    rotary_emb: Arc<RotaryEmbedding>,
}

impl ModernBertAttention {
    fn load(vb: VarBuilder, config: &Config, rotary_emb: Arc<RotaryEmbedding>) -> Result<Self> {
        let num_attention_heads = config.num_attention_heads;
        let attention_head_size = config.hidden_size / config.num_attention_heads;

        let qkv = linear_no_bias(config.hidden_size, config.hidden_size * 3, vb.pp("Wqkv"))?;
        let proj = linear_no_bias(config.hidden_size, config.hidden_size, vb.pp("Wo"))?;

        Ok(Self {
            qkv,
            proj,
            num_attention_heads,
            attention_head_size,
            rotary_emb,
        })
    }

    fn forward(
        &self,
        hidden_states: &Tensor,
        attention_mask: &Tensor,
        lengths: Option<&[usize]>,
    ) -> Result<Tensor> {
        let xs = hidden_states.clone();
        let (b, seq_len, d) = xs.dims3()?;
        let qkv = xs
            .apply(&self.qkv)?
            .reshape((
                b,
                seq_len,
                3,
                self.num_attention_heads,
                self.attention_head_size,
            ))?
            .permute((2, 0, 3, 1, 4))?;

        let q = qkv.get(0)?;
        let k = qkv.get(1)?;
        let v = qkv.get(2)?;

        let (q, k) = self.rotary_emb.apply_rotary_emb_qkv(&q, &k)?;

        let scale = (self.attention_head_size as f64).powf(-0.5);
        let q = (q * scale)?;

        let xs = attention(&q, &k, &v, Some(attention_mask), lengths)?;
        let xs = xs.transpose(1, 2)?.reshape((b, seq_len, d))?;
        let xs = xs.apply(&self.proj)?;
        let xs = xs.reshape((b, seq_len, d))?;

        Ok(xs)
    }
}

#[derive(Clone)]
pub struct ModernBertMLP {
    wi: Linear,
    wo: Linear,
}

impl ModernBertMLP {
    fn load(vb: VarBuilder, config: &Config) -> Result<Self> {
        let wi = linear_no_bias(
            config.hidden_size,
            config.intermediate_size * 2,
            vb.pp("Wi"),
        )?;
        let wo = linear_no_bias(config.intermediate_size, config.hidden_size, vb.pp("Wo"))?;
        Ok(Self { wi, wo })
    }
}

impl Module for ModernBertMLP {
    fn forward(&self, xs: &Tensor) -> Result<Tensor> {
        let xs = xs.apply(&self.wi)?;
        let xs = xs.chunk(2, D::Minus1)?;
        let xs = (&xs[0].gelu_erf()? * &xs[1])?.apply(&self.wo)?; // GeGLU
        Ok(xs)
    }
}

#[derive(Clone)]
pub struct ModernBertLayer {
    attn: ModernBertAttention,
    mlp: ModernBertMLP,
    attn_norm: Option<LayerNorm>,
    mlp_norm: LayerNorm,
    uses_local_attention: bool,
}

impl ModernBertLayer {
    fn load(
        vb: VarBuilder,
        config: &Config,
        rotary_emb: Arc<RotaryEmbedding>,
        uses_local_attention: bool,
    ) -> Result<Self> {
        let attn = ModernBertAttention::load(vb.pp("attn"), config, rotary_emb)?;
        let mlp = ModernBertMLP::load(vb.pp("mlp"), config)?;
        let attn_norm = layer_norm_no_bias(
            config.hidden_size,
            config.layer_norm_eps,
            vb.pp("attn_norm"),
        )
        .ok();
        let mlp_norm =
            layer_norm_no_bias(config.hidden_size, config.layer_norm_eps, vb.pp("mlp_norm"))?;
        Ok(Self {
            attn,
            mlp,
            attn_norm,
            mlp_norm,
            uses_local_attention,
        })
    }

    fn forward(
        &self,
        xs: &Tensor,
        global_attention_mask: &Tensor,
        local_attention_mask: &Tensor,
        lengths: Option<&[usize]>,
    ) -> Result<Tensor> {
        let residual = xs.clone();
        let mut xs = xs.clone();
        if let Some(norm) = &self.attn_norm {
            xs = xs.apply(norm)?;
        }

        let attention_mask = if self.uses_local_attention {
            &global_attention_mask.broadcast_add(local_attention_mask)?
        } else {
            global_attention_mask
        };
        let xs = self.attn.forward(&xs, attention_mask, lengths)?;
        let xs = (xs + residual)?;
        let mlp_out = xs.apply(&self.mlp_norm)?.apply(&self.mlp)?;
        let xs = (xs + mlp_out)?;
        Ok(xs)
    }
}

// Global attention mask calculated from padded token inputs
fn prepare_4d_attention_mask(
    mask: &Tensor,
    dtype: DType,
    tgt_len: Option<usize>,
) -> Result<Tensor> {
    let bsz = mask.dim(0)?;
    let src_len = mask.dim(1)?;
    let tgt_len = tgt_len.unwrap_or(src_len);

    let expanded_mask = mask
        .unsqueeze(1)?
        .unsqueeze(2)?
        .expand((bsz, 1, tgt_len, src_len))?
        .to_dtype(dtype)?;

    let inverted_mask = (1.0 - expanded_mask)?;

    (inverted_mask * f32::MIN as f64)?.to_dtype(dtype)
}

// Attention mask caused by the sliding window
fn get_local_attention_mask(
    seq_len: usize,
    max_distance: usize,
    device: &Device,
) -> Result<Tensor> {
    let mask: Vec<_> = (0..seq_len)
        .flat_map(|i| {
            (0..seq_len).map(move |j| {
                if (j as i32 - i as i32).abs() > max_distance as i32 {
                    f32::NEG_INFINITY
                } else {
                    0.
                }
            })
        })
        .collect();
    Tensor::from_slice(&mask, (seq_len, seq_len), device)
}

// ModernBERT backbone
#[derive(Clone)]
pub struct ModernBert {
    word_embeddings: Embedding,
    embedding_projection: Option<Linear>,
    norm: LayerNorm,
    layers: Vec<ModernBertLayer>,
    final_norm: LayerNorm,
    local_attention_size: usize,
}

impl ModernBert {
    pub fn load(vb: VarBuilder, config: &Config) -> Result<Self> {
        let width = config.embedding_size.unwrap_or(config.hidden_size);
        let shape = (config.vocab_size, width);
        let table = vb.get_no_shape("encoder.embeddings.tok_embeddings.weight")?;
        let dims = table.shape().dims();
        // Original Q6K blocks span token rows in the small encoder's embedding table.
        let flat_legacy = config.embedding_size.is_none()
            && config.hidden_size == 384
            && dims == [shape.0 * shape.1];
        if dims != [shape.0, shape.1] && !flat_legacy {
            candle_core::bail!("unexpected token embedding shape {dims:?}");
        }
        let embedding_projection = if config.embedding_size.is_some() {
            if vb.contains_key("encoder.embeddings.projection.bias") {
                candle_core::bail!("unexpected embedding projection bias");
            }
            Some(linear_no_bias(
                width,
                config.hidden_size,
                vb.pp("encoder.embeddings.projection"),
            )?)
        } else {
            None
        };
        let word_embeddings = Embedding::new(table.dequantize(vb.device())?.reshape(shape)?, width);
        let norm = layer_norm_no_bias(
            config.hidden_size,
            config.layer_norm_eps,
            vb.pp("encoder.embeddings.norm"),
        )?;
        let global_rotary_emb = Arc::new(RotaryEmbedding::new(
            DType::F32,
            config,
            config.global_rope_theta,
            vb.device(),
        )?);
        let local_rotary_emb = Arc::new(RotaryEmbedding::new(
            DType::F32,
            config,
            config.local_rope_theta,
            vb.device(),
        )?);

        let mut layers = Vec::with_capacity(config.num_hidden_layers);
        for layer_id in 0..config.num_hidden_layers {
            let layer_uses_local_attention = layer_id % config.global_attn_every_n_layers != 0;
            layers.push(ModernBertLayer::load(
                vb.pp(format!("encoder.layers.{layer_id}")),
                config,
                if layer_uses_local_attention {
                    local_rotary_emb.clone()
                } else {
                    global_rotary_emb.clone()
                },
                layer_uses_local_attention,
            )?);
        }

        let final_norm = layer_norm_no_bias(
            config.hidden_size,
            config.layer_norm_eps,
            vb.pp("encoder.final_norm"),
        )?;

        Ok(Self {
            word_embeddings,
            embedding_projection,
            norm,
            layers,
            final_norm,
            local_attention_size: config.local_attention,
        })
    }

    pub fn forward(&self, xs: &Tensor, mask: &Tensor, lengths: Option<&[usize]>) -> Result<Tensor> {
        let seq_len = xs.shape().dims()[1];
        let global_attention_mask =
            prepare_4d_attention_mask(mask, DType::F32, None)?.to_device(xs.device())?;
        let local_attention_mask =
            get_local_attention_mask(seq_len, self.local_attention_size / 2, xs.device())?;
        let mut xs = xs.apply(&self.word_embeddings)?;
        if let Some(projection) = &self.embedding_projection {
            xs = xs.apply(projection)?;
        }
        xs = xs.apply(&self.norm)?;
        for layer in self.layers.iter() {
            xs = layer.forward(&xs, &global_attention_mask, &local_attention_mask, lengths)?;
        }
        let xs = xs.apply(&self.final_norm)?;
        Ok(xs)
    }
}
