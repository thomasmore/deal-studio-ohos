//! Quantize Laya with Q6K embeddings, Q4_0 encoder projections, and an F16 decision head.
const EMBEDDING: &str = "encoder.embeddings.tok_embeddings.weight";

use candle_core::{
    quantized::{gguf_file, GgmlDType, QTensor},
    Device,
};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args: Vec<_> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("--dequantize") && args.len() == 3 {
        if std::path::Path::new(&args[2]).exists() {
            return Err("output exists".into());
        }
        let mut file = std::fs::File::open(&args[1])?;
        let content = gguf_file::Content::read(&mut file)?;
        let mut weights = std::collections::HashMap::new();
        for name in content.tensor_infos.keys() {
            let mut value = content
                .tensor(&mut file, name, &Device::Cpu)?
                .dequantize(&Device::Cpu)?;
            if name == EMBEDDING && value.dims() == [256_000 * 384] {
                value = value.reshape((256_000, 384))?;
            }
            weights.insert(name.clone(), value);
        }
        candle_core::safetensors::save(&weights, &args[2])?;
        return Ok(());
    }
    let q4_embeddings = args.first().map(String::as_str) == Some("--q4-embeddings");
    if q4_embeddings {
        args.remove(0);
    }
    let mut q8_layers = Vec::new();
    if args.first().map(String::as_str) == Some("--q8-layers") && args.len() == 4 {
        q8_layers = args[1]
            .split(',')
            .map(str::parse::<usize>)
            .collect::<Result<Vec<_>, _>>()?;
        if q8_layers.iter().any(|n| *n >= 22) {
            return Err("encoder layer outside 0..22".into());
        }
        args.drain(0..2);
    }
    if args.len() != 2 {
        return Err(
            "usage: laya-quantize [--dequantize | --q4-embeddings | --q8-layers IDS] INPUT OUTPUT"
                .into(),
        );
    }
    let tensors = candle_core::safetensors::load(&args[0], &Device::Cpu)?;
    let mut weights: Vec<_> = tensors.into_iter().collect();
    weights.sort_by(|a, b| a.0.cmp(&b.0));
    let mut quantized = Vec::new();
    for (name, mut tensor) in weights {
        let dtype = if name == EMBEDDING && !q4_embeddings {
            if tensor.dims() == [256_000, 384] {
                tensor = tensor.flatten_all()?;
            }
            GgmlDType::Q6K
        } else if name.starts_with("encoder.layers.")
            && tensor.rank() == 2
            && name
                .split('.')
                .nth(2)
                .and_then(|n| n.parse::<usize>().ok())
                .is_some_and(|n| q8_layers.contains(&n))
        {
            GgmlDType::Q8_0
        } else if name.starts_with("encoder.") && tensor.rank() == 2 && tensor.dim(1)? % 32 == 0 {
            GgmlDType::Q4_0
        } else if tensor.rank() == 2 {
            GgmlDType::F16
        } else {
            GgmlDType::F32
        };
        quantized.push((
            name,
            QTensor::quantize(&tensor.to_dtype(candle_core::DType::F32)?, dtype)?,
        ));
    }
    let refs: Vec<_> = quantized.iter().map(|(n, t)| (n.as_str(), t)).collect();
    let mut output = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&args[1])?;
    gguf_file::write(&mut output, &[], &refs)?;
    println!(
        "{}",
        serde_json::json!({"format":if q4_embeddings {"gguf-q4-f16"} else {"gguf-q6-q4-f16-mixed"}, "tensors":refs.len(), "bytes":output.metadata()?.len()})
    );
    Ok(())
}
