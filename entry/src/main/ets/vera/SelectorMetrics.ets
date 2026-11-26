import { OperationCancellation } from './OperationCancellation'
import { Stage, WHO_JEV } from './RunStages'

/** One shared-boundary selector invocation, not one question or paid request.
 * No request bodies, credentials, answers or model weights are retained here.
 * Weak ownership keeps late completions attached to their original operation.
 */
export class SelectorCall {
  backend: string = ''
  model: string = ''
  ms: number = 0
  startedAt: number = Date.now()
  finished: boolean = false
  questions: number = 0
  answered: number = 0
  /** Actual HTTP attempts, including retries; zero for native inference. */
  requests: number = 0
  ok: boolean = false
  cancelled: boolean = false
  error: string = ''
  inputTokens: number = -1
  cacheHitTokens: number = -1
  outputTokens: number = -1
  estimatedUsd: number = -1
  partial: boolean = false
}

const calls: WeakMap<OperationCancellation, SelectorCall[]> = new WeakMap<OperationCancellation, SelectorCall[]>()
const questionIds: WeakMap<SelectorCall, string[]> = new WeakMap<SelectorCall, string[]>()

export function selectorLabel(backend: string): string {
  if (backend === 'local-experimental') { return 'Local Jev (experimental)' }
  if (backend === 'llm') { return 'Cloud LLM Jev approximation' }
  return 'TypeSafe Jev'
}

export function beginSelectorCall(backend: string, model: string, body: string,
    owner?: OperationCancellation): SelectorCall {
  let call = new SelectorCall()
  call.backend = backend
  call.model = model
  try {
    let root = JSON.parse(body) as Record<string, Object>
    if (root['questions'] !== undefined && root['questions'] !== null) {
      let ids = Object.keys(root['questions'])
      call.questions = ids.length
      questionIds.set(call, ids)
    }
  } catch (_e) {}
  if (backend === 'local-experimental') {
    call.inputTokens = 0
    call.cacheHitTokens = 0
    call.outputTokens = 0
    call.estimatedUsd = 0
  }
  if (owner !== undefined) {
    let list = calls.get(owner)
    if (list === undefined) { list = []; calls.set(owner, list) }
    list.push(call)
  }
  return call
}

/** Snapshots, never live references: cancellation/late replies cannot rewrite a finished run. */
export function selectorCalls(owner: OperationCancellation): SelectorCall[] {
  let out: SelectorCall[] = []
  let list = calls.get(owner)
  if (list === undefined) { return out }
  for (let call of list) {
    let copy = JSON.parse(JSON.stringify(call)) as SelectorCall
    if (!copy.finished) {
      copy.ms = Math.max(0, Date.now() - copy.startedAt)
      copy.partial = true
      if (owner.isCancelled()) { copy.cancelled = true }
    }
    out.push(copy)
  }
  return out
}

function tokens(raw: Record<string, Object>, key: string): number {
  let value = raw[key]
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value as number : -1
}

function plus(total: number, value: number): number {
  return value < 0 ? total : Math.max(0, total) + value
}

/** Called for EVERY HTTP attempt. Missing usage/pricing is unknown, never free.
 * Published estimates: TypeSafe $0.042/M input, output free; official DeepSeek
 * Flash $0.15/$0.003/$0.60 per M fresh/cached/output, doubled at weekday peaks.
 * Other OpenAI-compatible endpoints have no assumed tariff.
 */
export function selectorUsage(call: SelectorCall, text: string, status: number,
    base: string = '', model: string = '', at: number = Date.now()): void {
  let input = -1
  let cached = -1
  let output = -1
  try {
    let root = JSON.parse(text) as Record<string, Object>
    let usage = root['usage'] as Record<string, Object>
    if (usage !== undefined && usage !== null) {
      input = tokens(usage, call.backend === 'typesafe' ? 'input_tokens' : 'prompt_tokens')
      output = tokens(usage, call.backend === 'typesafe' ? 'output_tokens' : 'completion_tokens')
      cached = call.backend === 'typesafe' ? 0 : tokens(usage, 'prompt_cache_hit_tokens')
      if (cached < 0 && usage['prompt_tokens_details'] !== undefined && usage['prompt_tokens_details'] !== null) {
        cached = tokens(usage['prompt_tokens_details'] as Record<string, Object>, 'cached_tokens')
      }
    }
  } catch (_e) {}
  call.inputTokens = plus(call.inputTokens, input)
  call.cacheHitTokens = plus(call.cacheHitTokens, cached)
  call.outputTokens = plus(call.outputTokens, output)
  let usd = -1
  if (call.backend === 'typesafe' && input >= 0) { usd = input * 0.042 / 1000000 }
  if (call.backend === 'llm' && base.replace(/\/+$/, '') === 'https://api.deepseek.com' &&
      model === 'deepseek-flash' && input >= 0 && cached >= 0 && cached <= input && output >= 0) {
    let date = new Date(at)
    let day = date.getUTCDay()
    let hour = date.getUTCHours()
    let peak = day >= 1 && day <= 5 && ((hour >= 1 && hour < 4) || (hour >= 6 && hour < 10))
    usd = ((input - cached) * 0.15 + cached * 0.003 + output * 0.60) * (peak ? 2 : 1) / 1000000
  }
  call.estimatedUsd = plus(call.estimatedUsd, usd)
  if (status !== 200 || input < 0 || cached < 0 || output < 0 || usd < 0) { call.partial = true }
}

/** Validate only answer presence for accounting, not correctness/confidence. */
export function finishSelectorCall(call: SelectorCall, reply: string): void {
  let ids = questionIds.get(call)
  questionIds.delete(call)
  try {
    let root = JSON.parse(reply) as Record<string, Object>
    let answers = root['answers'] as Record<string, Object>
    if (answers !== undefined && answers !== null && ids !== undefined) {
      for (let key of ids) {
        let answer = answers[key] as Record<string, Object>
        if (answer !== null && answer !== undefined &&
            ((typeof answer['choice'] === 'string' && (answer['choice'] as string).length > 0) ||
            (typeof answer['noul'] === 'number' && Number.isFinite(answer['noul'] as number)))) { call.answered++ }
      }
    }
    let local = root['local'] as Record<string, Object>
    if (local !== undefined && local !== null && local['status'] === 'uncertain') {
      call.error = typeof local['reason'] === 'string' ? local['reason'] as string : 'uncertain'
    }
    call.ok = call.error.length === 0 && call.answered === call.questions && call.questions > 0
  } catch (_e) {}
  if (!call.ok && call.error.length === 0) { call.error = 'incomplete or missing selector answer' }
}

export class SelectorTotals {
  calls: number = 0
  requests: number = 0
  localCalls: number = 0
  ms: number = 0
  inputTokens: number = -1
  cacheHitTokens: number = -1
  outputTokens: number = -1
  estimatedUsd: number = -1
  partial: boolean = false
}

export function selectorTotals(list: SelectorCall[]): SelectorTotals {
  let out = new SelectorTotals()
  for (let call of list) {
    out.calls++
    out.requests += call.requests
    if (call.backend === 'local-experimental') { out.localCalls++ }
    out.ms += call.ms
    out.inputTokens = plus(out.inputTokens, call.inputTokens)
    out.cacheHitTokens = plus(out.cacheHitTokens, call.cacheHitTokens)
    out.outputTokens = plus(out.outputTokens, call.outputTokens)
    out.estimatedUsd = plus(out.estimatedUsd, call.estimatedUsd)
    if (call.partial || call.estimatedUsd < 0) { out.partial = true }
  }
  return out
}

/** Replace coarse agent Jev stages, not add to them. Retain sub-50ms calls,
 * even a call rounded to 0ms, so a fast local selector never disappears.
 */
export function selectorStages(stages: Stage[], list: SelectorCall[]): Stage[] {
  if (list.length === 0) { return stages.slice() }
  let out = stages.filter((s: Stage): boolean => s.who !== WHO_JEV)
  let backends: string[] = []
  for (let call of list) { if (backends.indexOf(call.backend) < 0) { backends.push(call.backend) } }
  for (let backend of backends) {
    let group = list.filter((c: SelectorCall): boolean => c.backend === backend)
    let totals = selectorTotals(group)
    out.push(new Stage(selectorLabel(backend), WHO_JEV, totals.ms,
      totals.calls.toString() + ' selector call(s), ' + totals.requests.toString() + ' HTTP request(s)'))
  }
  return out
}
