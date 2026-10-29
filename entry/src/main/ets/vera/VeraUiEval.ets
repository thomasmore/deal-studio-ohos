/**
 * Development only: runs the real extraction step (DeepSeekEngine.extractUiNeeds)
 * over the gold prompts of docs/ui-gold.json and writes down, per prompt, the
 * phrases it produced and what VeraUiIndex picks for them -- so the selector's
 * recall can be scored on the host with tools/eval-ui-selection.py, against
 * the same model the phone really uses.
 *
 *   hdc shell aa start -a EntryAbility -b com.vera.probe.dyn --ps veraUiEval 1
 *   hdc shell hilog -x | grep VERA-UI-EVAL
 *
 * Needs the embedding model and the UI index warm, so GeneratePage runs it once
 * they are ready, the same consume-once-flag shape as VeraSdkEval.ets.
 */

import { hilog } from '@kit.PerformanceAnalysisKit'
import { resourceManager } from '@kit.LocalizationKit'
import { loadRawfileText } from './LlamaEngine'
import { deepseek } from './DeepSeekEngine'
import { findUiComponentsByEmbedding } from './VeraUiIndex'
import { selectUiComponents } from './VeraUiCatalog'

const DOMAIN = 0x0000
const PER_PHRASE = 2

let pending = false

export function requestUiEval(): void { pending = true }

export function uiEvalRequested(): boolean {
  let was = pending
  pending = false
  return was
}

export async function runUiEval(mgr: resourceManager.ResourceManager): Promise<void> {
  let text = await loadRawfileText(mgr, 'ui-gold.json')
  let gold = JSON.parse(text) as Record<string, Object>[]
  hilog.info(DOMAIN, 'VERA', 'VERA-UI-EVAL start prompts=' + gold.length.toString())
  for (let g of gold) {
    let id = g['id'] as string
    let prompt = g['prompt'] as string
    let needs = await deepseek.extractUiNeeds(prompt)
    let row: Record<string, Object> = {}
    row['id'] = id
    row['needs'] = needs === null ? [] : needs
    let picked: string[] = []
    if (needs !== null) {
      for (let need of needs) {
        let found = await findUiComponentsByEmbedding(need, PER_PHRASE)
        if (found !== null) { for (let n of found) { picked.push(n) } }
      }
    }
    let selected: string[] = []
    selectUiComponents(picked).forEach((n: string) => { selected.push(n) })
    row['picked'] = picked
    row['selected'] = selected
    hilog.info(DOMAIN, 'VERA', 'VERA-UI-EVAL ' + JSON.stringify(row))
  }
  hilog.info(DOMAIN, 'VERA', 'VERA-UI-EVAL done')
}
