// Playground-only model selection and legacy Laya diagnostic decisions.
'use strict'
const fs = require('node:fs')
const path = require('node:path')
const crypto = require('node:crypto')
const root = path.resolve(__dirname, '../..')
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex')
const sharedManifestSha256 = '4d40ff9d998cb139df51104bcf3c3d9a23f8bf609bc74c25819b5017e1eec7d5'
const shared = {
  id: 'mmbert-shared-state-q8-experimental',
  label: 'mmBERT shared-state Q8',
  model: 'jhu-clsp/mmBERT-small',
  revision: 'abc32620dd4f6ab06f5fbe905dc25f310618e09f',
  quantization: 'Q8 token embeddings, F32 ranker',
}
const labels = new Map([['jhu-clsp/mmBERT-small', 'mmBERT-small Q4'], ['jhu-clsp/mmBERT-base', 'Laya Multilingual Q4']])
function specification() {
  const laya = Boolean(process.env.VERA_LAYA_MANIFEST || process.env.VERA_LAYA_CLI)
  const cli = process.env.VERA_LAYA_CLI ||
    path.join(root, 'native/local-jev/target/release', laya ? 'local-laya' : 'local-jev-shared')
  const manifestFile = laya
    ? process.env.VERA_LAYA_MANIFEST || path.join(root, '.local-jev/bundle-q4/laya-manifest.json')
    : path.join(__dirname, 'models/mmbert-shared-state-q8/model.json')
  const bundle = path.dirname(manifestFile)
  const assets = laya
    ? ['laya-config.json', 'tokenizer.json', 'model.gguf']
    : ['tokenizer.json', 'embeddings.q8', 'ranker.safetensors']
  let manifest = null, manifestSha256
  try {
    const bytes = fs.readFileSync(manifestFile)
    manifestSha256 = sha(bytes)
    if (laya || manifestSha256 === sharedManifestSha256) manifest = JSON.parse(bytes.toString('utf8'))
  } catch (_) {}
  const args = laya ? ['--bundle', bundle, '--experimental-decisions', '--framed'] : [bundle]
  const identity = laya
    ? {id: 'mmbert-q4', label: labels.get(manifest?.base_model) || 'Local Rust Q4', model: manifest?.base_model,
        revision: manifest?.base_revision, quantization: manifest?.quantization}
    : shared
  const available = Boolean(manifest) && fs.existsSync(cli) && assets.every(name => fs.existsSync(path.join(bundle, name))) &&
    (!laya || (labels.has(identity.model) && String(identity.quantization).includes('Q4_0 token embeddings') &&
      String(identity.quantization).includes('Q4_0 encoder projections')))
  return {...identity, laya, cli, bundle, args, assets, available, manifestFile, manifest, manifestSha256}
}
function metadata(spec) {
  const {id, label, model, revision, quantization, manifest} = spec
  const bundleBytes = fs.statSync(spec.manifestFile).size + spec.assets.reduce((sum, file) => sum + fs.statSync(path.join(spec.bundle, file)).size, 0)
  return {id, label, provider: 'Local Rust', model, revision, quantization, bundleBytes,
    binarySha256: sha(fs.readFileSync(spec.cli)), manifestSha256: spec.manifestSha256,
    checkpointSha256: spec.laya ? manifest.checkpoint_weights_sha256 : manifest.asset_sha256['ranker.safetensors'],
    assetSha256: manifest.asset_sha256,
    training: manifest.training ? {groups: manifest.training.train_groups, decisions: manifest.training.train_decisions} : null,
    diagnostic: true, calibrated: false, productionAllowed: false}
}
// The Rust --experimental-decisions entry point owns score validation and softmax.
module.exports={specification,metadata}
