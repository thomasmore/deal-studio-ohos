/**
 * A second opinion on a weak pick. When Jev named a block but not sharply enough to build from (a section answer
 * between WEAK_FROM and SECTION_PICK_ABOVE) and nothing was vetoed, the request would otherwise go to generation from
 * scratch, the most expensive route. One short DeepSeek call, with no tools and no thinking, is asked whether the
 * named block alone does what the request asks. It may only confirm kinds Jev already named; it cannot add blocks.
 * Any failure answers "nothing confirmed", which is what happens today.
 */

import { hilog } from '@kit.PerformanceAnalysisKit'
import { fragments, FragmentSpec } from './VeraTemplates'
import { deepseek } from './DeepSeekEngine'

const DOMAIN = 0x0000

/** Turns the second opinion on or off; off means weak picks go to generation as before. */
export const VERIFY_WEAK_PICKS: boolean = false

export class VerifyAnswer {
  confirmed: string[] = []
  /** What the model says is missing, '' when it said nothing. */
  missing: string = ''
  /** True when no answer came back (no key, network, unreadable): nothing was checked. */
  failed: boolean = false
}

const SYSTEM: string = 'A selector proposes ready-made screen blocks for an app request, but it was not sure. ' +
  'Each block is a fixed part: the person can type values and tap buttons, and the text on it is filled in, but the ' +
  'block does nothing else. For each candidate, decide whether that block on its own does what the request asks for, ' +
  'with nothing important missing. Be strict: reject a block when the request needs a calculation, a conversion, ' +
  'scaling by a number, real or searched data, media, or another app, and the block cannot do it. Accept a plain list, ' +
  'form or display when that is all the request asks for. Answer with JSON only: ' +
  '{"confirm": ["kind", ...], "missing": "a few words naming what the blocks cannot do, or an empty string"}'

export function buildVerifyUser(prompt: string, kinds: string[]): string {
  let lines: string[] = []
  let specs: FragmentSpec[] = fragments()
  for (let kind of kinds) {
    for (let spec of specs) {
      if (spec.kind === kind) { lines.push('- ' + kind + ': ' + spec.criteria) }
    }
  }
  return 'Request: ' + prompt + '\nCandidate blocks:\n' + lines.join('\n')
}

/** The kinds the model confirmed, never one that was not a candidate. Anything unreadable confirms nothing. */
export function readVerifyAnswer(text: string, candidates: string[]): VerifyAnswer {
  let out = new VerifyAnswer()
  try {
    let start = text.indexOf('{')
    let end = text.lastIndexOf('}')
    if (start < 0 || end <= start) { return out }
    let parsed = JSON.parse(text.substring(start, end + 1)) as Record<string, Object>
    let confirm = parsed['confirm']
    if (Array.isArray(confirm)) {
      for (let item of confirm as Object[]) {
        if (typeof item === 'string' && candidates.indexOf(item as string) >= 0 && out.confirmed.indexOf(item as string) < 0) {
          out.confirmed.push(item as string)
        }
      }
    }
    let missing = parsed['missing']
    if (typeof missing === 'string') { out.missing = (missing as string).trim().substring(0, 80) }
  } catch (_e) {
    return new VerifyAnswer()
  }
  return out
}

/** One call, never throws. */
export async function verifyWeakPick(prompt: string, candidates: string[]): Promise<VerifyAnswer> {
  let started = Date.now()
  let answer = new VerifyAnswer()
  try {
    let text = await deepseek.extractTemplateContent(SYSTEM, buildVerifyUser(prompt, candidates), 200, 'Second opinion on a weak pick')
    if (text !== null) { answer = readVerifyAnswer(text, candidates) } else { answer.failed = true }
  } catch (_e) {
    answer = new VerifyAnswer()
    answer.failed = true
  }
  hilog.info(DOMAIN, 'VERA', 'VERA-VERIFY ms=' + (Date.now() - started).toString() + ' weak=' + candidates.join(',') +
    ' confirm=' + (answer.confirmed.length > 0 ? answer.confirmed.join(',') : 'none') + ' missing=' + answer.missing)
  return answer
}
