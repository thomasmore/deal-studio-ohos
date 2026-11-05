/**
 * Ranks find_sdk_function's candidates for every case in
 * entry/src/main/resources/rawfile/sdk-selection-gold.json, under both
 * on both search paths. One hilog line per (case, path); `bonus=off` stays in
 * the line because tools/eval-sdk-selection.py keys on it -- there is no bonus. The phone only reports rankings; tools/eval-sdk-selection.py
 * scores them against the gold grades, so grades can change without rebuilding.
 *
 *   hdc shell aa start -a EntryAbility -b com.vera.probe.dyn --ps veraSdkEval 1
 *   hdc shell "hilog -x | grep VERA-SDKEVAL" > results/sdk-eval.log
 *
 * Same launch-parameter shape as VeraSearchBenchmark.ets: EntryAbility sets the
 * flag, GeneratePage.ets runs the eval once the SDK embedding cache is warm.
 */

import { hilog } from '@kit.PerformanceAnalysisKit'
import { resourceManager } from '@kit.LocalizationKit'
import { findSdkFunctionFromCache, SdkEntry } from './VeraSdkIndex'
import { findSdkFunctionByEmbedding } from './VeraSdkEmbeddingCache'
import { isSdkTargetImplemented } from './VeraSdkBackend'
import { loadRawfileText } from './LlamaEngine'

const DOMAIN = 0x0000

class EvalCase {
  id: string = ''
  split: string = ''
  need: string = ''
}

let requested = false

export function requestSdkEval(): void { requested = true }

/** Consumes the flag, same as benchmarkRequested(): true at most once. */
export function sdkEvalRequested(): boolean {
  if (!requested) { return false }
  requested = false
  return true
}

function describe(entries: SdkEntry[]): string {
  let parts: string[] = []
  for (let e of entries) {
    let target = e.kit + '.' + e.module + '.' + e.name
    parts.push(target + (isSdkTargetImplemented(target) ? ':impl' : ':stub'))
  }
  return '[' + parts.join(', ') + ']'
}

export async function runSdkEval(mgr: resourceManager.ResourceManager): Promise<void> {
  let text = await loadRawfileText(mgr, 'sdk-selection-gold.json')
  let cases = JSON.parse(text) as EvalCase[]
  hilog.info(DOMAIN, 'VERA', 'VERA-SDKEVAL start cases=' + cases.length.toString())
  for (let c of cases) {
    let token = findSdkFunctionFromCache(c.need, 8)
    hilog.info(DOMAIN, 'VERA', 'VERA-SDKEVAL id=' + c.id + ' path=token bonus=off ranks=' + describe(token))
    let embed = await findSdkFunctionByEmbedding(c.need, 8)
    hilog.info(DOMAIN, 'VERA', 'VERA-SDKEVAL id=' + c.id + ' path=embed bonus=off ranks=' +
      (embed === null ? '[]' : describe(embed)))
  }
  hilog.info(DOMAIN, 'VERA', 'VERA-SDKEVAL done')
}
