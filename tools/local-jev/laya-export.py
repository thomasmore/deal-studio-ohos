#!/usr/bin/env python3
"""Export mixed quantization for the complete Laya decision architecture."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('checkpoint')
    parser.add_argument('output')
    parser.add_argument('--quantizer', default='native/local-jev/target/release/laya-quantize')
    parser.add_argument('--q8-layers', help='Comma-separated encoder layer indices for an explicit precision experiment')
    parser.add_argument('--q4-embeddings', action='store_true')
    parser.add_argument('--base-revision', help='Checkpoint revision when the config has no training provenance')
    args = parser.parse_args()
    base, target = Path(args.checkpoint), Path(args.output)
    config = json.loads((base/'rl_agent_config.json').read_text())
    base_revision = config.get('application_training', {}).get('base_revision') or args.base_revision
    if not base_revision:
        parser.error('--base-revision is required for a checkpoint without training provenance')
    target.mkdir(mode=0o700, parents=True, exist_ok=False)
    encoder = json.loads((base/'encoder/config.json').read_text())
    from transformers import AutoTokenizer
    tokenizer = AutoTokenizer.from_pretrained(base/'tokenizer', local_files_only=True)
    for layer_type, key in [('full_attention','global_rope_theta'), ('sliding_attention','local_rope_theta')]:
        if layer_type in encoder.get('rope_parameters', {}):
            encoder[key] = encoder['rope_parameters'][layer_type]['rope_theta']
    exported = {**config, 'encoder_config': encoder, 'cls_token_id': tokenizer.cls_token_id,
                'sep_token_id': tokenizer.sep_token_id, 'mask_token_id': tokenizer.mask_token_id,
                'mask_token': tokenizer.mask_token}
    (target/'laya-config.json').write_text(json.dumps(exported, indent=2))
    tokenizer_json = json.loads((base/'tokenizer/tokenizer.json').read_text())
    (target/'tokenizer.json').write_text(json.dumps(tokenizer_json, ensure_ascii=False, separators=(',', ':')))
    quantizer_args = ['--q4-embeddings'] if args.q4_embeddings else []
    if args.q8_layers:
        quantizer_args += ['--q8-layers', args.q8_layers]
    subprocess.run([args.quantizer, *quantizer_args, str(base/'model.safetensors'), str(target/'model.gguf')], check=True)
    names = ('laya-config.json', 'tokenizer.json', 'model.gguf')
    manifest = {'format': 'laya-gguf-mixed-v1', 'base_model': config['encoder'],
        'base_revision': base_revision,
        'checkpoint_weights_sha256': sha(base/'model.safetensors'),
        'quantizer_sha256': sha(Path(args.quantizer)),
        'asset_sha256': {name: sha(target/name) for name in names},
        'quantization': ('Candle 0.9.2 ' + ('Q4_0' if args.q4_embeddings else 'Q6K')
                         + ' token embeddings, Q4_0 encoder projections, F16 decision matrices, other tensors F32'),
        'q8_encoder_layers':args.q8_layers,
        'runtime': 'Candle quantized matrix products; token embeddings expand to F32 in memory',
        'human_calibrated': False, 'production_enabled': False,
        'training': config.get('application_training')}
    (target/'laya-manifest.json').write_text(json.dumps(manifest, indent=2))
    size = sum(p.stat().st_size for p in target.iterdir())
    print(json.dumps({'asset_bytes': size, 'within_300MB': size <= 300000000,
                      'manifest_sha256': sha(target/'laya-manifest.json')}))
    if size > 300000000:
        raise ValueError('complete Laya bundle exceeds 300 MB')


if __name__ == '__main__':
    main()
