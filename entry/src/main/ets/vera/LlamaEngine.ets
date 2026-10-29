/**
 * ArkTS interface for the llama.cpp NAPI module.
 *
 * The native module is built from entry/src/main/cpp/ and loaded as libllama.so.
 * It exposes four functions: llamaInit, llamaGenerate, llamaStop, llamaFree.
 *
 * Model: qwen2.5-coder-3b-instruct-q4_k_m.gguf (~1.9GB)
 * Place at: {filesDir}/models/qwen2.5-coder-3b-instruct-q4_k_m.gguf
 * Transfer: downloaded from the vera-server /models endpoint (hdc file send is
 * blocked on release-provisioned installs — see GeneratePage.checkModel()).
 */

import { resourceManager } from '@kit.LocalizationKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { util } from '@kit.ArkTS'
import nativeLlama from 'libllama.so'

export class LlamaConfig {
  modelPath: string = ''
  nCtx: number = 4096
  nThreads: number = 4
  nGpuLayers: number = 0
}

export class GenerateRequest {
  systemPrompt: string = ''
  userPrompt: string = ''
  grammar: string = ''
  maxTokens: number = 2048
  temperature: number = 0.2
  topP: number = 0.95
  seed: number = 42
  previousSource: string = ''
  /** previousSource failed to compile and the reply is SEARCH/REPLACE edits to it (VeraRepair), returned raw. */
  repairByEdit: boolean = false
  /** The model may not call tools (search, SDK lookup) for this request; they stay defined so the cached prompt prefix still matches. */
  toolsOff: boolean = false
  /** std/ui components the system prompt describes; empty means all of them. */
  uiSelected: string[] = []
  /** Offer find_ui_component to the model. */
  uiTool: boolean = true
}

export type TokenCallback = (token: string) => void

export class GenerateResult {
  text: string = ''
  inputTokens: number = 0
  outputTokens: number = 0
}

/**
 * Passthroughs to the embedding half of the same native module, for
 * VeraEmbeddings.ets -- not a second `import ... from 'libllama.so'` (that
 * fails at runtime: "Load native module failed, ModuleName:
 * @normalized:Y&&&libllama.so&", confirmed on-device this session), and not
 * a forwarded reference to the module object either (confirmed separately:
 * the import only resolves to a real object at a call site inside *this*
 * file -- handing the reference itself to another file comes back
 * undefined). One import, one place; everything else calls through here.
 */
/** Loads the embedding model on a worker thread; the promise says whether it loaded. */
export function nativeEmbedInit(configJson: string): Promise<boolean> {
  return nativeLlama.llamaEmbedInit(configJson)
}

/** Embeds the texts on a worker thread, never on the UI thread (napi_llama.cpp's LlamaEmbedBatch). */
export function nativeEmbedBatch(texts: string[]): Promise<number[][]> {
  return nativeLlama.llamaEmbedBatch(texts)
}

/** "stub" for a build without llama.cpp, "llama.cpp <commit>" otherwise, "unknown" if the module predates the call. */
export function nativeBuildInfo(): string {
  try {
    return nativeLlama.llamaBuildInfo()
  } catch (_e) {
    return 'unknown'
  }
}

export function nativeEmbedFree(): void {
  nativeLlama.llamaEmbedFree()
}

/** Dot product of `query` against each of `count` `dimension`-wide rows of
 * `corpus`, in native C++ -- see napi_llama.cpp's LlamaScanCorpus for why
 * this moved out of ArkTS, and why `count` is passed explicitly rather
 * than left for the native side to infer from the typed array alone.
 * Returns one score per row, in corpus order. */
export function nativeScanCorpus(query: number[], corpus: Float32Array, dimension: number, count: number): Float32Array {
  return nativeLlama.llamaScanCorpus(query, corpus, dimension, count)
}

export class LlamaEngine {
  private initialized: boolean = false
  private generating: boolean = false

  isReady(): boolean { return this.initialized }
  isGenerating(): boolean { return this.generating }

  init(config: LlamaConfig): boolean {
    try {
      let configObj: Record<string, Object> = {}
      configObj['model_path'] = config.modelPath
      configObj['n_ctx'] = config.nCtx
      configObj['n_threads'] = config.nThreads
      configObj['n_gpu_layers'] = config.nGpuLayers
      this.initialized = nativeLlama.llamaInit(JSON.stringify(configObj))
      return this.initialized
    } catch (e) {
      console.error('LlamaEngine init failed: ' + (e as Error).message)
      return false
    }
  }

  generate(request: GenerateRequest, onToken: TokenCallback): GenerateResult {
    let gr = new GenerateResult()
    if (!this.initialized) { return gr }
    this.generating = true
    try {
      let prompt = this.buildPrompt(request)
      let paramsObj: Record<string, Object> = {}
      paramsObj['prompt'] = prompt
      paramsObj['grammar'] = request.grammar
      paramsObj['max_tokens'] = request.maxTokens
      paramsObj['temperature'] = request.temperature
      paramsObj['top_p'] = request.topP
      paramsObj['seed'] = request.seed
      let native: GenerateResult = nativeLlama.llamaGenerate(JSON.stringify(paramsObj), onToken) as GenerateResult
      gr.text = native.text
      gr.inputTokens = native.inputTokens
      gr.outputTokens = native.outputTokens
      return gr
    } catch (e) {
      console.error('LlamaEngine generate failed: ' + (e as Error).message)
      return gr
    } finally {
      this.generating = false
    }
  }

  stop(): void {
    if (this.generating) {
      try { nativeLlama.llamaStop() } catch (_e) {}
      this.generating = false
    }
  }

  free(): void {
    if (this.initialized) {
      try { nativeLlama.llamaFree() } catch (_e) {}
      this.initialized = false
    }
  }

  private buildPrompt(request: GenerateRequest): string {
    // Qwen3 chat format
    let parts: string[] = []
    parts.push('<|im_start|>system\n')
    parts.push(request.systemPrompt)
    parts.push('\n<|im_end|>\n')
    if (request.previousSource.length > 0) {
      parts.push('<|im_start|>assistant\n')
      parts.push(request.previousSource)
      parts.push('\n<|im_end|>\n')
      parts.push('<|im_start|>user\n')
      parts.push('Refine the program above: ' + request.userPrompt)
      parts.push('\n<|im_end|>\n')
    } else {
      parts.push('<|im_start|>user\n')
      parts.push(request.userPrompt)
      parts.push('\n<|im_end|>\n')
    }
    parts.push('<|im_start|>assistant\n')
    return parts.join('')
  }

  static defaultModelPath(filesDir: string): string {
    return filesDir + '/models/qwen2.5-coder-3b-instruct-q4_k_m.gguf'
  }

  static modelExists(filesDir: string): boolean {
    try {
      let stat = fs.statSync(LlamaEngine.defaultModelPath(filesDir))
      return stat.size > 0
    } catch (_e) {
      return false
    }
  }
}

export async function loadRawfileText(mgr: resourceManager.ResourceManager, name: string): Promise<string> {
  try {
    let data = await mgr.getRawFileContent(name)
    return util.TextDecoder.create('utf-8').decodeToString(data)
  } catch (e) {
    throw e as Error
  }
}

export const engine: LlamaEngine = new LlamaEngine()
