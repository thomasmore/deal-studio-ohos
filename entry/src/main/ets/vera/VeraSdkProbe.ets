/**
 * Calls one sdk.call target, named entirely on the command line, and writes
 * down what came back -- the same role IntentProbe.ets plays for the intent
 * registry, for VeraSdkBackend.ets's ADAPTERS instead. Also runs
 * find_sdk_function's own search directly (both token and embedding), so a
 * ranking change can be checked without going through a real generation.
 *
 *   hdc shell aa start -a EntryAbility -b com.vera.probe.dyn \
 *     --ps probeSdkTarget AudioKit.AudioManager.getVolume \
 *     --ps probeSdkParams '{"volumeType":"3"}'
 *
 *   hdc shell aa start -a EntryAbility -b com.vera.probe.dyn \
 *     --ps probeSdkSearch "play an audio file or music"
 *
 *   hdc shell hilog -x | grep VERA-SDK-PROBE
 *
 * Reachable only from a launch parameter -- a generated program cannot name
 * a target this way, and nothing in std/sdk routes here. Params are a flat
 * JSON object of strings, matching what sdk.call itself hands an adapter
 * (Map<string, string>), not the nested-object shape IntentProbe.ets takes
 * for the intent registry.
 */

import { hilog } from '@kit.PerformanceAnalysisKit'
import { runSdkAdapter, isSdkTargetImplemented } from './VeraSdkBackend'
import { findSdkFunctionFromCache, SdkEntry } from './VeraSdkIndex'
import { findSdkFunctionByEmbedding } from './VeraSdkEmbeddingCache'

const DOMAIN = 0x0000

function describe(entries: SdkEntry[]): string {
  let parts: string[] = []
  for (let e of entries) {
    let target = e.kit + '.' + e.module + '.' + e.name
    parts.push(target + (isSdkTargetImplemented(target) ? '[impl]' : '[stub]'))
  }
  return '[' + parts.join(', ') + ']'
}

export async function runSdkSearchProbe(need: string): Promise<void> {
  let token = findSdkFunctionFromCache(need, 8)
  hilog.info(DOMAIN, 'VERA', 'VERA-SDK-PROBE token need="' + need + '" ' + describe(token))
  let embedding = await findSdkFunctionByEmbedding(need, 8)
  hilog.info(DOMAIN, 'VERA', 'VERA-SDK-PROBE embedding need="' + need + '" ' +
    (embedding === null ? 'n/a' : describe(embedding)))
}

// Embedding search needs the SDK corpus cache already warm, which only
// happens inside GeneratePage.ets's own resource loading -- same reasoning,
// same consume-once-flag shape as VeraSearchBenchmark.ets's
// requestBenchmark/benchmarkRequested (and the same bug that pattern fixed:
// reading the flag without clearing it let a page whose resource-loading
// path runs more than once per process run this more than once too).
let pendingSearch: string | null = null

export function requestSdkSearch(need: string): void { pendingSearch = need }

export function sdkSearchRequested(): string | null {
  let need = pendingSearch
  pendingSearch = null
  return need
}

function parseParams(text: string): Map<string, string> {
  let params = new Map<string, string>()
  if (text.length === 0) { return params }
  let obj = JSON.parse(text) as Record<string, string>
  for (let key of Object.keys(obj)) { params.set(key, obj[key]) }
  return params
}

export async function runSdkProbe(targetText: string, paramsText: string): Promise<void> {
  let params: Map<string, string>
  try {
    params = parseParams(paramsText)
  } catch (e) {
    hilog.error(DOMAIN, 'VERA', 'VERA-SDK-PROBE params are not JSON: ' + (e as Error).message)
    return
  }
  hilog.info(DOMAIN, 'VERA', 'VERA-SDK-PROBE call ' + targetText + ' params=' + paramsText)
  let started = Date.now()
  let result = await runSdkAdapter(targetText, params)
  hilog.info(DOMAIN, 'VERA', 'VERA-SDK-PROBE done ' + targetText +
    ' ms=' + (Date.now() - started).toString() + ' result=' + result)
}
