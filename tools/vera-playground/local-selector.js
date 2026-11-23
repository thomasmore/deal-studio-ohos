// Playground-only Laya bundles and uncalibrated diagnostic decisions.
'use strict'
const fs = require('node:fs')
const path = require('node:path')
const crypto = require('node:crypto')
const root = path.resolve(__dirname, '../..')
const sha = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')
const id = 'mmbert-q4'
const labels = new Map([['jhu-clsp/mmBERT-small', 'mmBERT-small Q4'], ['jhu-clsp/mmBERT-base', 'Laya Multilingual Q4']])
const assets = ['laya-config.json', 'tokenizer.json', 'model.gguf']
function specification() {
  const cli = process.env.VERA_LAYA_CLI || path.join(root, 'native/local-jev/target/release/local-laya')
  const manifestFile = process.env.VERA_LAYA_MANIFEST || path.join(root, '.local-jev/bundle-q4/laya-manifest.json')
  const bundle = path.dirname(manifestFile)
  let manifest = null
  try { manifest = JSON.parse(fs.readFileSync(manifestFile,'utf8')) } catch (_) {}
  const quantization = String(manifest?.quantization)
  const q4Profile = quantization.includes('Q4_0 token embeddings') && quantization.includes('Q4_0 encoder projections')
  const label = labels.get(manifest?.base_model)
  return {id,label:label || 'Local Rust Q4',cli,bundle,args:['--bundle',bundle,'--diagnostic-scores','--framed'],
    available:fs.existsSync(cli)&&Boolean(label)&&q4Profile&&assets.every(name => fs.existsSync(path.join(bundle, name))),manifestFile,manifest}
}
function metadata(spec) {
  const manifest = spec.manifest
  const bundleBytes = fs.statSync(spec.manifestFile).size + assets.reduce((sum, file) => sum + fs.statSync(path.join(spec.bundle,file)).size, 0)
  return {id:spec.id,label:spec.label,provider:'Local Rust',model:manifest.base_model,revision:manifest.base_revision,
    quantization:manifest.quantization,bundleBytes,binarySha256:sha(spec.cli),manifestSha256:sha(spec.manifestFile),
    checkpointSha256:manifest.checkpoint_weights_sha256,assetSha256:manifest.asset_sha256,
    training:manifest.training?{groups:manifest.training.train_groups,decisions:manifest.training.train_decisions}:null,
    diagnostic:true,calibrated:false,productionAllowed:false}
}
function diagnosticDecisions(raw, request) {
  if (!raw.scores) return raw
  const questions = request.questions, answers = {}
  if (!questions || Object.keys(raw.scores).length !== Object.keys(questions).length) throw Error('Incomplete diagnostic scores')
  for (const [key,q] of Object.entries(questions)) {
    const scored=raw.scores[key], logits=scored?.logits
    const ids=q.type==='noul'?['false','true']:Object.keys(q.criteria||{}).sort()
    if (!['choice','noul'].includes(q.type)||scored?.type!==q.type||ids.length<1||!logits||Object.keys(logits).length!==ids.length||ids.some(id=>!Number.isFinite(logits[id]))) throw Error('Invalid diagnostic scores')
    const max=Math.max(...ids.map(id=>logits[id])), weights=ids.map(id=>Math.exp(logits[id]-max)), total=weights.reduce((a,b)=>a+b,0)
    const probabilities=Object.fromEntries(ids.map((id,i)=>[id,weights[i]/total]))
    const choice=ids.reduce((best,id)=>probabilities[id]>probabilities[best]?id:best,ids[0])
    answers[key]=q.type==='noul'?{type:'noul',noul:probabilities.true,probabilities}:{type:'choice',choice,probabilities}
  }
  return {...raw,answers,local:{...raw.local,status:'diagnostic',reason:'playground_uncalibrated_logits',
    productionReason:raw.local?.reason,diagnostic:true,calibrated:false,productionAllowed:false,scoreTemperature:1}}
}
module.exports={specification,metadata,diagnosticDecisions}
