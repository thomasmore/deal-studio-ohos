/**
 * An on-device Jev proxy: answers the composer's selector questions with the
 * configured cloud chat-completions model instead of TypeSafe System One.
 *
 * The composer's Jev call sites (`askJev` in VeraCompose.ets, `selectEdit` in
 * VeraComposition.ets) POST a body of the shape
 *
 *   {"model": "jev-latest", "state": "<context>", "questions": {
 *     "<key>": {"type": "choice", "instructions": "...",
 *               "criteria": {"<optKey>": "<desc>", ...}},
 *     "<key>": {"type": "noul", "instructions": "..."}
 *   }}
 *
 * and read answers shaped like Jev's:
 *
 *   {"answers": {"<key>": {"choice": "<optKey>", "confidence": 0.62},
 *                "<key>": {"noul": 0.71}}}
 *
 * This module produces that same answer shape, but instead of one round trip to
 * api.typesafe.ai it fires one short chat-completions call per question
 * (concurrent), asking the model to reply with a single letter, and reads the
 * model's confidence from the top-token logprobs. It runs in-process -- there is
 * no local HTTP server and no endpoint to configure -- so the only thing that
 * turns it on is `--ps jevProxy 1` (SettingsStore.useJevProxy). The cloud
 * base/model/key come from the existing apiBase/apiModel/cloudKey settings, so
 * the proxy asks the same provider the Generate and Chat screens do.
 *
 * `askJevViaCloud` takes the Jev request body and returns the Jev response body
 * (a string, '' when nothing could be answered), the same contract `askJev`
 * already has, so the call sites swap to it with no downstream change.
 *
 * Calibration caveat: Jev is a calibrated decision model and the composer's
 * thresholds (PICK_ABOVE 0.25, FORMULA_ABOVE 0.4, ...) were tuned against that.
 * A chat model's letter-logprob is only calibrated-ish -- it tends to be
 * overconfident -- so picks will be sharper than Jev's. Re-walk a few prompts
 * against the thresholds once this proxy is the selector, rather than assuming
 * the same numbers mean the same thing.
 */

import { OperationCancellation, throwIfCancelled, cancellationError } from './OperationCancellation'
import { requestWithCancellation } from './VeraWebSearch'
import { http } from '@kit.NetworkKit'
import { noteService, SERVICE_JEV } from './ServiceHealth'
import { settings } from './SettingsStore'

const LETTERS: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
// How many alternative tokens to ask for at the decision point. 20 covers A..F
// with room for "A", "A.", " A", "A)" etc.
const TOP_LOGPROBS: number = 20
const CONNECT_TIMEOUT: number = 5000
// One question is one short letter reply, but the model can stall; give it room.
const READ_TIMEOUT: number = 20000
// How many questions to resolve at once. Each question is an independent short
// call, so a multi-question batch goes from N×latency (sequential) to roughly
// ceil(N/limit)×latency. Kept modest: dashscope answers a burst of parallel
// requests with 429 limit_burst_rate, and while cloudPick's backoff recovers a
// burst (correctness intact), too high a limit just re-earns 429s. 4 on dashscope
// stays under the burst ceiling in practice.
const JEV_CONCURRENCY: number = 4

class TokenProb {
  token: string = ''
  logprob: number = 0
}

class CloudPick {
  content: string = ''
  tokenProbs: TokenProb[] = []
}

class QAnswer {
  key: string = ''
  isNoul: boolean = false
  choice: string = ''
  confidence: number = 0
  noul: number = 0
}

function optLetters(count: number): string[] {
  let out: string[] = []
  for (let i = 0; i < count && i < LETTERS.length; i++) {
    out.push(LETTERS.charAt(i))
  }
  return out
}

/** First non-space character of `token`, upper-cased; '' if none. */
function firstLetter(token: string): string {
  let i = 0
  while (i < token.length) {
    let ch = token.charAt(i)
    if (ch !== ' ' && ch !== '\n' && ch !== '\r' && ch !== '\t') {
      return ch.toUpperCase()
    }
    i++
  }
  return ''
}

/**
 * Renormalise top-token logprobs into a probability per option letter. Tokens
 * whose first character is one of `letters` contribute; the rest are dropped,
 * and the survivors are renormalised to sum to 1 so they read like a calibrated
 * distribution over the options. Returns a record with one entry per letter when
 * there was anything to sum, or an empty record when there was not (the caller
 * then falls back to argmax with confidence 1.0).
 */
function letterProbs(probs: TokenProb[], letters: string[]): Record<string, number> {
  let weights: Record<string, number> = {}
  let allowed: Record<string, boolean> = {}
  for (let l of letters) {
    weights[l] = 0
    allowed[l] = true
  }
  let seen = false
  for (let p of probs) {
    let letter = firstLetter(p.token)
    if (!allowed[letter]) { continue }
    weights[letter] = weights[letter] + Math.exp(p.logprob)
    seen = true
  }
  if (!seen) { return {} }
  let total = 0
  for (let l of letters) { total += weights[l] }
  if (total <= 0) { return {} }
  let out: Record<string, number> = {}
  for (let l of letters) { out[l] = weights[l] / total }
  return out
}

/**
 * The top-token logprobs, across the provider shapes that matter. OpenAI returns
 * choices[0].logprobs.content[0].top_logprobs (a list of {token, logprob}); some
 * OpenAI-compatible providers return choices[0].logprobs.top_logprobs instead,
 * as either the same list-of-dicts shape or the older per-token map shape
 * ({token: logprob}). All three are normalised into a flat TokenProb list. []
 * when the provider returned no logprobs at all.
 */
function appendTokenProbs(arr: Object[], out: TokenProb[]): void {
  for (let entryObj of arr) {
    let entry = entryObj as Record<string, Object>
    let tok = entry['token']
    if (tok !== undefined && tok !== null && typeof tok === 'string') {
      let lp = entry['logprob']
      let tp = new TokenProb()
      tp.token = tok as string
      tp.logprob = (lp !== undefined && lp !== null && typeof lp === 'number') ? lp as number : 0
      out.push(tp)
    } else {
      // Older map shape: the entry itself maps token -> logprob.
      let keys = Object.keys(entry)
      for (let k of keys) {
        let v = entry[k]
        if (v !== undefined && v !== null && typeof v === 'number') {
          let tp = new TokenProb()
          tp.token = k
          tp.logprob = v as number
          out.push(tp)
        }
      }
    }
  }
}

function extractTopLogprobs(logprobsObj: Record<string, Object>): TokenProb[] {
  let out: TokenProb[] = []
  let content = logprobsObj['content']
  if (content instanceof Array) {
    let arr = content as Object[]
    if (arr.length > 0) {
      let first = arr[0] as Record<string, Object>
      let tl = first['top_logprobs']
      if (tl instanceof Array) {
        appendTokenProbs(tl as Object[], out)
      }
    }
  }
  if (out.length > 0) { return out }
  let tl2 = logprobsObj['top_logprobs']
  if (tl2 instanceof Array) {
    appendTokenProbs(tl2 as Object[], out)
  }
  return out
}

function parseChoice(cloud: Record<string, Object>): CloudPick {
  let out = new CloudPick()
  let choices = cloud['choices']
  if (!(choices instanceof Array)) { return out }
  let arr = choices as Object[]
  if (arr.length === 0) { return out }
  let choice = arr[0] as Record<string, Object>
  let messageRaw = choice['message']
  if (messageRaw !== null && messageRaw !== undefined) {
    let message = messageRaw as Record<string, Object>
    let c = message['content']
    if (typeof c === 'string') { out.content = c }
  }
  let lpRaw = choice['logprobs']
  if (lpRaw !== null && lpRaw !== undefined) {
    let lp = lpRaw as Record<string, Object>
    out.tokenProbs = extractTopLogprobs(lp)
  }
  return out
}

function buildMessages(state: string, userText: string): Record<string, Object>[] {
  let systemText = 'You are a decision selector. Pick exactly one option by its letter. Reply with only the letter.'
  if (state.length > 0) { systemText = state + '\n\n' + systemText }
  let sys: Record<string, Object> = {}
  sys['role'] = 'system'
  sys['content'] = systemText
  let usr: Record<string, Object> = {}
  usr['role'] = 'user'
  usr['content'] = userText
  let arr: Record<string, Object>[] = []
  arr.push(sys)
  arr.push(usr)
  return arr
}

/**
 * Set true once a cloud call comes back rejected for sending logprobs -- dashscope's
 * deepseek-v4-flash answers 400 "The parameters `logprobs` is not supported". Once
 * seen, subsequent calls omit logprobs and rely on the argmax-on-text fallback.
 * Not reset per call: the provider does not change within a session, and re-probing
 * every call would only re-earn the 400. It IS reset when the model changes
 * (resetLogprobsProbe, called from the model picker and the apiModel launch param),
 * because whether logprobs is supported is per model, not per provider: glm-5.2 on
 * the same dashscope endpoint returns logprobs fine, so switching to it should
 * re-probe rather than inherit the rejection a deepseek model earned.
 */
let logprobsRejected: boolean = false

/**
 * Drop the cached logprobs-rejection so the next proxy call probes logprobs again.
 * Call this whenever the model changes: support is per model (glm-5.2 supports
 * logprobs on dashscope, deepseek-v4-flash does not), so a rejection earned under
 * one model must not suppress logprobs under another.
 */
export function resetLogprobsProbe(): void {
  logprobsRejected = false
  console.info('VERA-JEVPROXY logprobs probe reset (model changed)')
}

class CloudReply {
  status: number = 0
  bodyText: string = ''
}

function buildPayload(model: string, messages: Record<string, Object>[], withLogprobs: boolean): string {
  let payload: Record<string, Object> = {}
  payload['model'] = model
  payload['messages'] = messages
  payload['temperature'] = 0
  payload['max_tokens'] = 5
  payload['stream'] = false
  if (withLogprobs) {
    payload['logprobs'] = true
    payload['top_logprobs'] = TOP_LOGPROBS
  }
  // Thinking off for a fast letter pick, mirroring DeepSeekEngine.buildBody's
  // dialect discipline: `thinking` is DeepSeek-only, `enable_thinking` is the
  // dashscope/glm switch; endpoints that know neither ignore it.
  if (settings.isDeepSeek()) {
    let thinking: Record<string, Object> = {}
    thinking['type'] = 'disabled'
    payload['thinking'] = thinking
  } else {
    payload['enable_thinking'] = false
  }
  return JSON.stringify(payload)
}

async function sendCloud(base: string, cloudKey: string, payloadJson: string,
    cancellation?: OperationCancellation): Promise<CloudReply> {
  throwIfCancelled(cancellation)
  let reply = new CloudReply()
  try {
    let header: Record<string, string> = {}
    header['Content-Type'] = 'application/json'
    header['Authorization'] = 'Bearer ' + cloudKey
    let url = base
    while (url.length > 0 && url.charAt(url.length - 1) === '/') {
      url = url.substring(0, url.length - 1)
    }
    url = url + '/chat/completions'
    let response = await requestWithCancellation(url, {
      method: http.RequestMethod.POST,
      header: header,
      extraData: payloadJson,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: CONNECT_TIMEOUT,
      readTimeout: READ_TIMEOUT
    }, cancellation)
    throwIfCancelled(cancellation)
    reply.status = response.responseCode as number
    reply.bodyText = String(response.result)
  } catch (e) {
    throwIfCancelled(cancellation)
    if ((e as Error).name === 'OperationCancelledError') { throw (e as Error) }
    console.warn('VERA-JEVPROXY cloud failed: ' + (e as Error).message)
    reply.status = 0
    reply.bodyText = ''
  }
  return reply
}

/**
 * One short chat-completions call. Tries logprobs first (for calibrated
 * confidence); if the provider rejects logprobs, retries without them and the
 * caller's argmax-on-text fallback supplies the pick at confidence 1.0. Retries
 * on 429 (dashscope's burst rate limit when many questions fire at once) with a
 * short backoff. Never throws; {} on any failure.
 */
async function cloudPick(base: string, model: string, cloudKey: string,
    messages: Record<string, Object>[], cancellation?: OperationCancellation): Promise<Record<string, Object>> {
  throwIfCancelled(cancellation)
  let withLogprobs = !logprobsRejected
  let payload = buildPayload(model, messages, withLogprobs)
  let reply = await sendCloud(base, cloudKey, payload, cancellation)
  throwIfCancelled(cancellation)
  if (reply.status === 400 && reply.bodyText.indexOf('logprobs') >= 0) {
    logprobsRejected = true
    payload = buildPayload(model, messages, false)
    reply = await sendCloud(base, cloudKey, payload, cancellation)
    throwIfCancelled(cancellation)
  }
  let backoff = 500
  for (let attempt = 0; attempt < 3 && reply.status === 429; attempt++) {
    throwIfCancelled(cancellation)
    await sleep(backoff, cancellation)
    throwIfCancelled(cancellation)
    backoff *= 2
    reply = await sendCloud(base, cloudKey, payload, cancellation)
    throwIfCancelled(cancellation)
  }
  if (reply.status !== 200) {
    if (reply.bodyText.length > 0) {
      console.warn('VERA-JEVPROXY cloud ' + reply.status.toString() + ' ' + reply.bodyText.substring(0, 300))
    }
    return {}
  }
  try {
    return JSON.parse(reply.bodyText) as Record<string, Object>
  } catch (_e) {
    console.warn('VERA-JEVPROXY non-JSON reply: ' + reply.bodyText.substring(0, 300))
    return {}
  }
}

function sleep(ms: number, cancellation?: OperationCancellation): Promise<void> {
  throwIfCancelled(cancellation)
  return new Promise<void>((resolve, reject): void => {
    let settled = false
    let unsubscribe = (): void => {}
    let timer = setTimeout((): void => {
      if (settled) { return }
      settled = true
      unsubscribe()
      resolve()
    }, ms)
    if (cancellation !== undefined) {
      unsubscribe = cancellation.onCancel((): void => {
        if (settled) { return }
        settled = true
        clearTimeout(timer)
        reject(cancellationError())
        unsubscribe()
      })
      if (settled) { unsubscribe() }
    }
  })
}

async function answerQuestion(key: string, q: Record<string, Object>, state: string,
    base: string, model: string, cloudKey: string, cancellation?: OperationCancellation): Promise<QAnswer> {
  throwIfCancelled(cancellation)
  let ans = new QAnswer()
  ans.key = key
  let typeRaw = q['type']
  let qtype = (typeRaw !== undefined && typeRaw !== null && typeof typeRaw === 'string') ? typeRaw as string : 'choice'
  let instrRaw = q['instructions']
  let instructions = (instrRaw !== undefined && instrRaw !== null && typeof instrRaw === 'string') ? instrRaw as string : ''
  ans.isNoul = qtype === 'noul'
  try {
    if (ans.isNoul) {
      // A noul question is a yes/no probability: A = yes, B = no, matching the
      // composer's readNoulProbability (values[1] is the branch taken when the
      // probability clears the threshold).
      let userText = instructions + '\nReply with a single letter: A for yes, B for no. Nothing else.'
      let cloud = await cloudPick(base, model, cloudKey, buildMessages(state, userText), cancellation)
      throwIfCancelled(cancellation)
      let pick = parseChoice(cloud)
      let letters: string[] = ['A', 'B']
      let probs = letterProbs(pick.tokenProbs, letters)
      if (Object.keys(probs).length > 0) {
        ans.noul = probs['A']
      } else {
        ans.noul = firstLetter(pick.content) === 'A' ? 1.0 : 0.0
      }
    } else {
      let critRaw = q['criteria']
      if (critRaw === null || critRaw === undefined) { return ans }
      let criteria = critRaw as Record<string, string>
      let criteriaKeys = Object.keys(criteria)
      if (criteriaKeys.length === 0) { return ans }
      let letters = optLetters(criteriaKeys.length)
      let lines: string[] = []
      lines.push(instructions)
      lines.push('Reply with a single letter and nothing else.')
      for (let i = 0; i < criteriaKeys.length; i++) {
        let desc = criteria[criteriaKeys[i]]
        lines.push(letters[i] + ') ' + criteriaKeys[i] + ' — ' + (desc !== undefined ? desc : ''))
      }
      let cloud = await cloudPick(base, model, cloudKey, buildMessages(state, lines.join('\n')), cancellation)
      throwIfCancelled(cancellation)
      let pick = parseChoice(cloud)
      let probs = letterProbs(pick.tokenProbs, letters)
      if (Object.keys(probs).length > 0) {
        let best = letters[0]
        let bestP = probs[best]
        for (let l of letters) {
          if (probs[l] > bestP) { bestP = probs[l]; best = l }
        }
        let idx = letters.indexOf(best)
        ans.choice = criteriaKeys[idx]
        ans.confidence = bestP
      } else {
        // No logprobs: trust the text, mark fully confident so the caller's
        // threshold gates it the same way.
        let letter = firstLetter(pick.content)
        let idx = letters.indexOf(letter)
        if (idx >= 0) {
          ans.choice = criteriaKeys[idx]
          ans.confidence = 1.0
        }
      }
    }
  } catch (_e) {
    throwIfCancelled(cancellation)
    if ((_e as Error).name === 'OperationCancelledError') { throw (_e as Error) }
    // One bad question must not sink the batch; defaults stand.
  }
  throwIfCancelled(cancellation)
  return ans
}

function emptyAnswersBody(): string {
  let answers: Record<string, Object> = {}
  let wrapper: Record<string, Object> = {}
  wrapper['answers'] = answers
  return JSON.stringify(wrapper)
}

/**
 * Translate a Jev request body into Jev-shaped answers via the configured cloud
 * model. Returns the response body string ({"answers": {...}}), or '' when no
 * cloud key is set or the body could not be parsed. Never throws; failures are
 * noted through ServiceHealth so the Generate UI's service chip reflects them.
 */
export async function askJevViaCloud(body: string, cancellation?: OperationCancellation): Promise<string> {
  throwIfCancelled(cancellation)
  let cloudKey = settings.getApiKey()
  if (cloudKey.length === 0) {
    noteService(SERVICE_JEV, false, 'no cloud key for Jev proxy')
    return ''
  }
  let base = settings.getBaseUrl()
  let model = settings.getModel()
  let root: Record<string, Object>
  try {
    root = JSON.parse(body) as Record<string, Object>
  } catch (_e) {
    noteService(SERVICE_JEV, false, 'bad Jev body')
    return ''
  }
  let stateRaw = root['state']
  let state = (stateRaw !== undefined && stateRaw !== null && typeof stateRaw === 'string') ? stateRaw as string : ''
  let questionsRaw = root['questions']
  if (questionsRaw === null || questionsRaw === undefined) { return emptyAnswersBody() }
  let questions = questionsRaw as Record<string, Object>
  let keys = Object.keys(questions)
  if (keys.length === 0) { return emptyAnswersBody() }
  // Bounded concurrency: each question is one short independent call, so a
  // multi-question batch resolves in ~ceil(N/JEV_CONCURRENCY) round-trips instead
  // of N. The bound stays modest (see JEV_CONCURRENCY): dashscope bursts 429 on
  // too many simultaneous requests, and each call still retries 429 with backoff
  // (cloudPick), so a burst is recovered, not lost. Answers are keyed, so order
  // does not affect correctness; temperature=0 keeps each call deterministic.
  let batchStart = Date.now()
  let results: QAnswer[] = new Array<QAnswer>(keys.length)
  let cursor = 0
  let worker = async (): Promise<void> => {
    while (true) {
      throwIfCancelled(cancellation)
      let i = cursor
      cursor++
      if (i >= keys.length) { return }
      let q = questions[keys[i]] as Record<string, Object>
      results[i] = await answerQuestion(keys[i], q, state, base, model, cloudKey, cancellation)
      throwIfCancelled(cancellation)
    }
  }
  let slotCount = Math.min(JEV_CONCURRENCY, keys.length)
  let workers: Promise<void>[] = []
  for (let w = 0; w < slotCount; w++) { workers.push(worker()) }
  await Promise.all(workers)
  throwIfCancelled(cancellation)
  let answers: Record<string, Object> = {}
  let calibrated = 0
  for (let ans of results) {
    let entry: Record<string, Object> = {}
    if (ans.isNoul) {
      entry['noul'] = ans.noul
    } else {
      entry['choice'] = ans.choice
      entry['confidence'] = ans.confidence
      // A confidence other than exactly 1.0 could only come from logprobs (the
      // argmax fallback sets 1.0), so counting these shows whether the provider's
      // logprobs actually flowed this batch -- the diagnostic for the reset/re-probe.
      if (ans.confidence !== 1.0) { calibrated++ }
    }
    answers[ans.key] = entry
  }
  console.info('VERA-JEVPROXY batch model=' + model + ' questions=' + results.length.toString() +
    ' calibrated=' + calibrated.toString() + ' elapsedMs=' + (Date.now() - batchStart).toString())
  noteService(SERVICE_JEV, true)
  let wrapper: Record<string, Object> = {}
  wrapper['answers'] = answers
  return JSON.stringify(wrapper)
}
