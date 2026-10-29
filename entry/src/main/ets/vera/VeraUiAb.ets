/**
 * Development only: generates the same prompts under each UI selection mode
 * (VeraUiSelect.ets) with one attempt each, compiles the result and writes
 * down what it used, so the modes can be compared on the same requests.
 *
 *   hdc shell aa start -a EntryAbility -b com.vera.probe.dyn --ps veraUiAb 1
 *   hdc shell hilog -x | grep 'VERA-UI-AB {'
 *
 * One attempt and no retry on purpose: a retry hides exactly the failures that
 * differ between modes. Run from GeneratePage once the embedding index is warm.
 */

import { hilog } from '@kit.PerformanceAnalysisKit'
import { resourceManager } from '@kit.LocalizationKit'
import { loadRawfileText, GenerateRequest, GenerateResult } from './LlamaEngine'
import { deepseek } from './DeepSeekEngine'
import { compileVeraSource } from './VeraCompiler'
import { describeCatalogForPrompt, componentsUsedIn } from './VeraUiCatalog'
import { UI_TOOL_NOTE } from './VeraUiSelect'

const DOMAIN = 0x0000
const IDS: string[] = ['stopwatch', 'gear', 'face', 'ttt', 'arkanoid', 'trip', 'workout', 'settings',
  'tip', 'recipe', 'quiz', 'clockface', 'pomodoro', 'roadtrip', 'counter']
// legacy: the skill as it was before this session's rewrite, no UI tool.
// notool: today's skill and catalogue, without find_ui_component.
// full:   today's skill and catalogue, with it.
const ARMS: string[] = ['legacy', 'notool', 'full']
const REPEATS = 2

let pending = false

export function requestUiAb(): void { pending = true }

export function uiAbRequested(): boolean {
  let was = pending
  pending = false
  return was
}

export async function runUiAb(mgr: resourceManager.ResourceManager): Promise<void> {
  let skill = await loadRawfileText(mgr, 'vera-skill.txt')
  let legacy = await loadRawfileText(mgr, 'vera-skill-legacy.txt')
  let gold = JSON.parse(await loadRawfileText(mgr, 'ui-gold.json')) as Record<string, Object>[]
  hilog.info(DOMAIN, 'VERA', 'VERA-UI-AB start')
  for (let g of gold) {
    let id = g['id'] as string
    if (IDS.indexOf(id) < 0) { continue }
    for (let rep = 0; rep < REPEATS; rep++) {
    for (let arm of ARMS) {
      let startedAt = Date.now()
      let row: Record<string, Object> = {}
      row['id'] = id
      row['arm'] = arm
      row['rep'] = rep
      try {
        let selected: Set<string> | null = null
        let request = new GenerateRequest()
        request.uiTool = arm === 'full'
        let text = arm === 'legacy' ? legacy : skill
        // The skill's own sentence about the tool goes with the tool.
        request.systemPrompt = text.replace('{{UI_CATALOG}}', describeCatalogForPrompt(selected))
          .replace('{{UI_TOOL_NOTE}}\n', arm === 'full' ? UI_TOOL_NOTE : '')
        let names: string[] = []
        request.userPrompt = g['prompt'] as string
        request.maxTokens = 8192
        request.temperature = 0.2
        deepseek.setThinking(false)
        let result: GenerateResult = await deepseek.generate(request, (_t: string): void => {})
        row['promptChars'] = request.systemPrompt.length
        row['rounds'] = deepseek.lastToolRounds()
        row['inTokens'] = result.inputTokens
        row['cacheHit'] = deepseek.lastCacheHitTokens()
        row['finish'] = deepseek.lastFinishReason()
        row['outTokens'] = result.outputTokens
        row['used'] = componentsUsedIn(result.text)
        try {
          compileVeraSource(result.text)
          row['ok'] = true
          row['error'] = ''
        } catch (e) {
          row['ok'] = false
          row['error'] = (e as Error).message.split('\n')[0]
        }
      } catch (e) {
        row['ok'] = false
        row['error'] = 'request: ' + (e as Error).message
      }
      row['ms'] = Date.now() - startedAt
      hilog.info(DOMAIN, 'VERA', 'VERA-UI-AB ' + JSON.stringify(row))
    }
    }
  }
  hilog.info(DOMAIN, 'VERA', 'VERA-UI-AB done')
}
