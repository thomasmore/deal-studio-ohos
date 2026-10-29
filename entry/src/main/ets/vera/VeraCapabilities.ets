/** Shared index readiness and background embedding preparation for both generators. */
import { common } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { request } from '@kit.BasicServicesKit'
import { loadDiscovery } from './VeraDiscovery'
import { loadEmbeddingModel, embedModelExists, embedModelPath, EMBED_MODEL_URL } from './VeraEmbeddings'
import { ensureSdkEmbeddings, sdkEmbeddingsReady } from './VeraSdkEmbeddingCache'
import { ensureIntentEmbeddings, intentEmbeddingsReady } from './VeraIntentEmbeddingCache'
import { ensureCeliaIntentEmbeddings, celiaIntentEmbeddingsReady } from './VeraCeliaIntentEmbeddingCache'

const INDEX_WAIT_MS: number = 10000
let readiness: Promise<void> | null = null
let embeddings: Promise<void> | null = null

async function downloadModel(context: common.Context): Promise<void> {
  try {
    fs.mkdirSync(context.filesDir + '/models', true)
  } catch (_e) {}
  console.info('VERA-EMBED downloading model (one-time, ~236MB)...')
  try {
    if (canIUse('SystemCapability.Request.FileTransferAgent')) {
      if (canIUse('SystemCapability.MiscServices.Download')) {
        let task = await request.downloadFile(context, {
          url: EMBED_MODEL_URL, filePath: embedModelPath(context.filesDir)
        })
        await new Promise<void>((resolve, reject) => {
          task.on('complete', (): void => { resolve() })
          task.on('fail', (err: number): void => { reject(new Error('download failed, code ' + err.toString())) })
        })
        return
      }
      throw new Error('SystemCapability.MiscServices.Download is not supported')
    }
    throw new Error('SystemCapability.Request.FileTransferAgent is not supported')
  } catch (e) {
    console.warn('VERA-EMBED model unavailable: ' + (e as Error).message)
  }
}

async function warmEmbeddings(context: common.Context): Promise<void> {
  if (!embedModelExists(context.filesDir)) { await downloadModel(context) }
  if (!embedModelExists(context.filesDir)) { return }
  if (!await loadEmbeddingModel(context.filesDir)) { return }
  await Promise.all([
    ensureSdkEmbeddings(context.filesDir, context.resourceManager),
    ensureIntentEmbeddings(context.filesDir, context.resourceManager),
    ensureCeliaIntentEmbeddings(context.filesDir, context.resourceManager)
  ])
  console.info('VERA-CAPABILITIES sdkEmbedding=' + sdkEmbeddingsReady().toString() +
    ' intentEmbedding=' + intentEmbeddingsReady().toString() +
    ' celiaIntentEmbedding=' + celiaIntentEmbeddingsReady().toString())
}

/** Resolve when indexes settle, or after the bounded wait. Downloads never block this promise. */
export function ensureCapabilities(context: common.Context): Promise<void> {
  if (readiness === null) {
    let indexes = loadDiscovery(context.filesDir, context.resourceManager).catch((e: Error): void => {
      console.warn('VERA-CAPABILITIES degraded indexes: ' + e.message)
    })
    // This continuation also runs after a timeout, once late indexes arrive.
    embeddings = indexes.then(() => warmEmbeddings(context)).catch((e: Error): void => {
      console.warn('VERA-CAPABILITIES keyword fallback: ' + e.message)
    })
    readiness = new Promise<void>((resolve) => {
      let timer = setTimeout((): void => {
        console.warn('VERA-CAPABILITIES index timeout; use available catalogue and keyword search')
        resolve()
      }, INDEX_WAIT_MS)
      indexes.then((): void => { clearTimeout(timer); resolve() })
    })
  }
  return readiness!
}

/** Diagnostic consumers can await the background work without delaying ordinary generation. */
export function prepareCapabilityEmbeddings(context: common.Context): Promise<void> {
  ensureCapabilities(context)
  return embeddings!
}
