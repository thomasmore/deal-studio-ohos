/**
 * Questions to the person, only when one is blocking. The plan may name up to two, each drawn for its default answer
 * (VeraCompose.ets's SketchQuestion); Jev keeps only those a sensible default cannot stand in for, the host asks the
 * person (a card on the Generate screen, the widget's bubble in the chat), and an answer other than the default has the
 * plan drawn again with it. No answer -- no way to ask, or the person stopped -- is the default.
 */

import { SketchQuestion, JevAsk } from '../VeraCompose'
import { OperationCancellation, throwIfCancelled } from '../OperationCancellation'

/** What the host shows the person. */
export class AgentQuestion {
  text: string = ''
  options: string[] = []
  /** The answer the plan was drawn for, preselected. */
  fallback: number = 0
}

/** What the person answered: the index of an answer offered, their own words typed in, or null for the default. */
export type PersonAnswer = number | string | null

/** Asks the person a question. */
export type PersonAsk = (question: AgentQuestion) => Promise<PersonAnswer>

/** A question is asked only when Jev leans clearly toward the default being wrong; with no answer from Jev, none is. */
const ASK_ABOVE: number = 0.6

export function blockingRequest(prompt: string, questions: SketchQuestion[]): string {
  let asked: Record<string, Object> = {}
  for (let i = 0; i < questions.length; i++) {
    let q = questions[i]
    let criteria: Record<string, Object> = {}
    criteria['ask'] = 'no: the request does not say, the answer changes what the app is, and taking "' + q.options[q.fallback] +
      '" would often be wrong'
    criteria['skip'] = 'yes: the request already says, or "' + q.options[q.fallback] + '" is a sensible choice the person can change later'
    let one: Record<string, Object> = {}
    one['type'] = 'choice'
    one['instructions'] = 'Can a good app be made for this request without asking "' + q.ask + '" (' + q.options.join(' / ') +
      '), by taking "' + q.options[q.fallback] + '"?'
    one['criteria'] = criteria
    asked['blocking.' + i.toString()] = one
  }
  let body: Record<string, Object> = {}
  body['model'] = 'jev-latest'
  body['state'] = 'Request: ' + prompt
  body['questions'] = asked
  return JSON.stringify(body)
}

/** The questions Jev says must be asked, in plan order. */
export function blockingOf(answer: string, questions: SketchQuestion[]): SketchQuestion[] {
  let out: SketchQuestion[] = []
  try {
    let answers = (JSON.parse(answer) as Record<string, Object>)['answers'] as Record<string, Object>
    for (let i = 0; i < questions.length; i++) {
      let a = answers['blocking.' + i.toString()] as Record<string, Object>
      let p = a !== undefined && a !== null ? a['probabilities'] as Record<string, Object> : null
      let ask = p !== null && p !== undefined && typeof p['ask'] === 'number' ? p['ask'] as number : 0
      if (ask >= ASK_ABOVE) { out.push(questions[i]) }
    }
  } catch (_e) {
    return []
  }
  return out
}

export class Asked {
  question: string = ''
  answer: string = ''
  /** The person chose an answer other than the default the plan was drawn for. */
  changed: boolean = false
  /** How long the person took to answer: time that is theirs, not the app's. */
  waitedMs: number = 0
}

/**
 * The questions that must be asked, asked: text for the plan to be drawn again with when an answer differs from the
 * plan's default, '' when none does. `log` gets every question asked and its answer.
 */
export async function askBlocking(prompt: string, questions: SketchQuestion[], askJev: JevAsk, ask: PersonAsk,
    log: Asked[], cancellation?: OperationCancellation): Promise<string> {
  throwIfCancelled(cancellation)
  let blocking = blockingOf(await askJev(blockingRequest(prompt, questions)), questions)
  throwIfCancelled(cancellation)
  let lines: string[] = []
  for (let q of blocking) {
    throwIfCancelled(cancellation)
    let shown = new AgentQuestion()
    shown.text = q.ask
    shown.options = q.options
    shown.fallback = q.fallback
    let waitStart = Date.now()
    throwIfCancelled(cancellation)
    let picked = await ask(shown)
    throwIfCancelled(cancellation)
    let waited = Date.now() - waitStart
    let entry = new Asked()
    entry.question = q.ask
    entry.waitedMs = waited
    // Words the person typed are an answer of their own: none of the options, so the plan is always drawn again with them.
    let typed = typeof picked === 'string' ? (picked as string).trim() : ''
    if (typed.length > 0) {
      entry.answer = typed + ' (typed)'
      entry.changed = true
      log.push(entry)
      lines.push(q.ask + ' ' + typed)
      continue
    }
    let chosen = typeof picked === 'number' ? picked as number : -1
    let index = chosen < 0 || chosen >= q.options.length ? q.fallback : chosen
    entry.answer = q.options[index] + (typeof picked === 'number' ? '' : ' (default)')
    entry.changed = index !== q.fallback
    log.push(entry)
    if (entry.changed) { lines.push(q.ask + ' ' + q.options[index]) }
  }
  return lines.length > 0 ? 'The person was asked, and answered:\n- ' + lines.join('\n- ') : ''
}
