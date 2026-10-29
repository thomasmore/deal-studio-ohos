/**
 * Which parts of the intent catalogue a request needs, decided before the
 * program is generated.
 *
 * The catalogue has to be in the prompt, so this runs first, on the person's
 * own words and nothing else -- there is no program yet to look at. It asks
 * Jev, TypeSafe's System One model, one yes/no question per catalogue domain
 * and keeps the domains it did not rule out.
 *
 * Jev rather than the generating model because the shape fits: the answer is a
 * probability per domain, it cannot come back as anything but the domains that
 * were asked about, and it costs one round trip of 70-500ms against a
 * generation that takes tens of seconds. See docs/intents-design.md.
 *
 * Two rules run through everything here:
 *
 *   Erring wide is free, erring narrow is invisible. A domain kept in error
 *   costs a few hundred characters of prompt. A domain dropped in error
 *   removes a feature from the generated app, and neither the person nor the
 *   model can tell that it happened -- the app simply comes back without the
 *   navigation button. So the threshold is low and the failure path keeps
 *   everything.
 *
 *   A selector that cannot answer must not stop a generation. No key, no
 *   network, a malformed answer: all of them fall back to the whole catalogue,
 *   which is exactly how the app behaved before this file existed.
 */

import { http } from '@kit.NetworkKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { noteService, httpFailure, SERVICE_JEV } from './ServiceHealth'
import { intentDomains } from './VeraIntentCatalog'
import { registryDomains, registryEntries, RegistryEntry } from './VeraIntentRegistry'

const DOMAIN = 0x0000
const ENDPOINT: string = 'https://api.typesafe.ai/v1/systemone'
const MODEL: string = 'jev-latest'

/**
 * How sure Jev has to be before a domain is dropped.
 *
 * Read it the other way round: a domain survives on a fifth of a chance. That
 * is the asymmetry above turned into a number.
 */
const KEEP_ABOVE: number = 0.2

/** One line per domain, in the person's language rather than the platform's. */
const DOMAIN_QUESTIONS: Map<string, string> = new Map<string, string>([
  ['maps', 'Does this app need to start navigation, or show or search a place on a map?'],
  ['calendar', 'Does it need to create, remove, or open entries in the phone\'s calendar?'],
  ['clock', 'Does it need alarms, timers or a stopwatch on the phone?'],
  ['music', 'Does it need to play music or search for a song or an artist?'],
  ['settings', 'Does it need to read or change a phone setting, such as Bluetooth, volume, hotspot or power saving?'],
  ['notes', 'Does it need to write a note or a to-do on the phone?'],
  ['photos', 'Does it need the camera or the photo gallery?'],
  ['messaging', 'Does it need to send a message or place a call to another person?'],
  ['money', 'Does it need to pay, transfer money or top up a card?'],
  ['system', 'Does it need to control the phone itself: launch or close apps, change the screen, share files between devices?'],
])

export class Selection {
  /** Domains to describe in the prompt; empty means the whole catalogue. */
  domains: string[]
  /** What to put in the status line, so a wrong selection is visible early. */
  note: string
  constructor(domains: string[], note: string) {
    this.domains = domains
    this.note = note
  }
}

/** Everything in the catalogue, said the way the caller expects it. */
export function everything(note: string): Selection {
  return new Selection([], note)
}

/**
 * The request body, built here rather than inline so it can be read -- and
 * checked -- without a network or a key.
 *
 * `state` is the person's request as they typed it. The questions are named
 * after the domains, so the answer map comes back keyed by the same names and
 * nothing has to be matched up by position.
 */
export function buildRequest(prompt: string, domains: string[]): string {
  let questions: Record<string, Object> = {}
  for (let domain of domains) {
    let instruction = DOMAIN_QUESTIONS.get(domain)
    if (instruction === undefined) {
      // A domain the catalogue grew without a question written for it. Asking
      // a bad question is worse than not asking: it would answer confidently
      // about nothing. Left out here, and kept by readSelection below.
      continue
    }
    let criteria: Record<string, Object> = {}
    criteria['true'] = 'the app being described needs this'
    criteria['false'] = 'it does not'
    let question: Record<string, Object> = {}
    question['type'] = 'noul'
    question['instructions'] = instruction as string
    question['criteria'] = criteria
    questions[domain] = question
  }
  let body: Record<string, Object> = {}
  body['model'] = MODEL
  body['state'] = prompt
  body['questions'] = questions
  return JSON.stringify(body)
}

/**
 * The domains to keep, from Jev's answer.
 *
 * A domain with no question, or with an answer that does not parse, is kept:
 * the only safe direction to fail in is wider. An answer that keeps every
 * domain is reported as the whole catalogue, so the status line does not claim
 * a selection that did not narrow anything.
 */
export function readSelection(body: string, domains: string[]): Selection {
  let answers: Record<string, Object> = {}
  try {
    let parsed = JSON.parse(body) as Record<string, Object>
    let found = parsed['answers']
    if (found !== null && found !== undefined) {
      answers = found as Record<string, Object>
    }
  } catch (_e) {
    return everything('all intents (answer unreadable)')
  }
  let kept: string[] = []
  let scores: string[] = []
  for (let domain of domains) {
    let answer = answers[domain] as Record<string, Object> | undefined
    if (answer === undefined) { kept.push(domain); continue }
    let value = answer['noul']
    if (value === null || value === undefined || typeof value !== 'number') {
      kept.push(domain)
      continue
    }
    let probability = value as number
    if (probability > KEEP_ABOVE) {
      kept.push(domain)
      scores.push(domain + ' ' + probability.toFixed(2))
    }
  }
  if (kept.length === 0 || kept.length === domains.length) {
    return everything('all intents')
  }
  return new Selection(kept, 'intents: ' + scores.join(', '))
}

/**
 * How many intents go into one Choice question.
 *
 * Jev takes up to 255 options; 160 leaves room and keeps each question small
 * enough to answer well. The registry of this phone is 646 entries, so four
 * questions cover it, and they travel in one request.
 */
const BATCH: number = 160

/** Below this the pick is treated as "it was guessing" and dropped. */
const PICK_ABOVE: number = 0.25

export class TargetChoice {
  /** bundle/module/ability/IntentName of each intent worth showing. */
  targets: string[]
  note: string
  constructor(targets: string[], note: string) {
    this.targets = targets
    this.note = note
  }
}

/**
 * The body for the intent-level question, built here so it can be read and
 * checked without a key.
 *
 * One Choice per batch, with an option per intent and a "none" that has to be
 * there -- without it the model is forced to name something, and a forced
 * answer on a batch of unrelated intents is worse than silence.
 *
 * The option key is an index, not the address: an address is 90 characters of
 * bundle path that says nothing the description does not already say, and
 * paying for it 646 times per generation is paying for punctuation. The
 * description is the intent name and the app -- all the phone gives us, since
 * not one of the 640 reachable entries carries a displayName or a keyword.
 */
export function buildTargetRequest(prompt: string, entries: RegistryEntry[], from: number): string {
  let questions: Record<string, Object> = {}
  let batch = 0
  for (let start = from; start < entries.length; start = start + BATCH) {
    let criteria: Record<string, Object> = {}
    for (let i = start; i < entries.length && i < start + BATCH; i++) {
      let entry = entries[i]
      criteria['i' + i.toString()] = entry.intentName + ' (' + shortBundle(entry.bundle) + ')'
    }
    criteria['none'] = 'none of these fits the request'
    let question: Record<string, Object> = {}
    question['type'] = 'choice'
    question['instructions'] = 'Which of these intents installed on the phone does this ' +
      'app need in order to do what the person asked? Answer none unless one of them is ' +
      'clearly what the request is about.'
    question['criteria'] = criteria
    questions['b' + batch.toString()] = question
    batch = batch + 1
  }
  let body: Record<string, Object> = {}
  body['model'] = MODEL
  body['state'] = prompt
  body['questions'] = questions
  return JSON.stringify(body)
}

/** com.huawei.hmos.settings -> settings; the part a person would recognise. */
function shortBundle(bundle: string): string {
  let parts = bundle.split('.')
  return parts.length === 0 ? bundle : parts[parts.length - 1]
}

/** The addresses Jev picked, in the order the batches answered. */
export function readTargets(body: string, entries: RegistryEntry[]): TargetChoice {
  let answers: Record<string, Object> = {}
  try {
    let parsed = JSON.parse(body) as Record<string, Object>
    let found = parsed['answers']
    if (found !== null && found !== undefined) { answers = found as Record<string, Object> }
  } catch (_e) {
    return new TargetChoice([], 'no pick (answer unreadable)')
  }
  let targets: string[] = []
  let notes: string[] = []
  for (let key of Object.keys(answers)) {
    let answer = answers[key] as Record<string, Object>
    let choice = answer['choice']
    if (choice === undefined || choice === null || typeof choice !== 'string') { continue }
    let picked = choice as string
    if (picked === 'none' || !picked.startsWith('i')) { continue }
    let confidence = answer['confidence']
    let sure = confidence !== undefined && confidence !== null && typeof confidence === 'number'
      ? confidence as number : 1
    if (sure < PICK_ABOVE) { continue }
    let index = Number.parseInt(picked.substring(1), 10)
    if (Number.isNaN(index) || index < 0 || index >= entries.length) { continue }
    targets.push(entries[index].target)
    notes.push(entries[index].intentName + ' ' + sure.toFixed(2))
  }
  return new TargetChoice(targets, notes.length > 0 ? notes.join(', ') : 'no pick')
}

/**
 * Which installed intents this request needs, decided by meaning rather than by
 * shared letters.
 *
 * The domain pass this replaces failed on the first request it met that a
 * person phrased their own way: "enable and disable torch" was sorted into
 * photos, while the torch lives in the launcher, and "flashlight" found the
 * camera, which accepted invented parameters and answered 0 without doing
 * anything. Names are the only text the phone offers -- and they are English
 * and descriptive, OpenFlashlight, CreateNote, TakePhoto -- so the question to
 * ask is about the intents themselves.
 */
export async function selectTargets(prompt: string, apiKey: string): Promise<TargetChoice> {
  let entries = registryEntries()
  if (entries.length === 0 || apiKey.length === 0 || prompt.trim().length === 0) {
    return new TargetChoice([], 'no pick')
  }
  let client = http.createHttp()
  try {
    let headers: Record<string, string> = {}
    headers['Content-Type'] = 'application/json'
    headers['Authorization'] = 'Bearer ' + apiKey
    let started = Date.now()
    let response = await client.request(ENDPOINT, {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: buildTargetRequest(prompt, entries, 0),
      connectTimeout: 5000,
      readTimeout: 15000
    })
    let code = response.responseCode as number
    if (code !== 200) {
      hilog.warn(DOMAIN, 'VERA', 'VERA-PICK http ' + code.toString())
      noteService(SERVICE_JEV, false, httpFailure(code, String(response.result)))
      return new TargetChoice([], 'no pick (selector answered ' + code.toString() + ')')
    }
    noteService(SERVICE_JEV, true)
    let choice = readTargets(response.result as string, entries)
    hilog.info(DOMAIN, 'VERA', 'VERA-PICK ms=' + (Date.now() - started).toString() +
      ' of=' + entries.length.toString() + ' picked=' +
      (choice.targets.length === 0 ? 'none' : choice.targets.join(' ')))
    return choice
  } catch (e) {
    hilog.warn(DOMAIN, 'VERA', 'VERA-PICK failed: ' + (e as Error).message)
    noteService(SERVICE_JEV, false, (e as Error).message)
    return new TargetChoice([], 'no pick (selector unreachable)')
  } finally {
    client.destroy()
  }
}

/**
 * Asks Jev which domains this request needs.
 *
 * Never throws and never rejects: a selector that fails has to leave the
 * generation exactly as it was.
 */
export async function selectDomains(prompt: string, apiKey: string): Promise<Selection> {
  // Both lists, because the prompt carries both: the catalogue rows that were
  // checked, and the addresses of everything else the phone has. A domain the
  // registry knows and the catalogue does not is exactly where intent.call is
  // the only way through, so leaving it out of the question would quietly put
  // that part of the phone out of reach.
  let domains = intentDomains()
  for (let domain of registryDomains()) {
    if (domains.indexOf(domain) < 0) { domains.push(domain) }
  }
  if (domains.length === 0) { return everything('all intents') }
  if (apiKey.length === 0) {
    return everything('all intents (no TypeSafe key)')
  }
  if (prompt.trim().length === 0) { return everything('all intents') }

  let client = http.createHttp()
  try {
    let headers: Record<string, string> = {}
    headers['Content-Type'] = 'application/json'
    headers['Authorization'] = 'Bearer ' + apiKey
    let started = Date.now()
    let response = await client.request(ENDPOINT, {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: buildRequest(prompt, domains),
      connectTimeout: 5000,
      readTimeout: 8000
    })
    let code = response.responseCode as number
    if (code !== 200) {
      hilog.warn(DOMAIN, 'VERA', 'VERA-SELECT http ' + code.toString())
      noteService(SERVICE_JEV, false, httpFailure(code, String(response.result)))
      return everything('all intents (selector answered ' + code.toString() + ')')
    }
    noteService(SERVICE_JEV, true)
    let selection = readSelection(response.result as string, domains)
    hilog.info(DOMAIN, 'VERA', 'VERA-SELECT ms=' + (Date.now() - started).toString() +
      ' domains=' + (selection.domains.length === 0 ? 'all' : selection.domains.join(' ')))
    return selection
  } catch (e) {
    hilog.warn(DOMAIN, 'VERA', 'VERA-SELECT failed: ' + (e as Error).message)
    noteService(SERVICE_JEV, false, (e as Error).message)
    return everything('all intents (selector unreachable)')
  } finally {
    client.destroy()
  }
}
