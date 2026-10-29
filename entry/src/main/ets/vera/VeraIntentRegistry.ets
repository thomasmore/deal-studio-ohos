/**
 * Every intent installed on this phone, as the system itself records them.
 *
 * The catalogue in VeraIntentCatalog is what has been checked: contracts read,
 * calls watched working, values translated. This is the other thing -- the
 * phone's own list, all of it, checked by nobody. It exists so a generated
 * program can reach something the catalogue never described, through
 * intent.call, and the two are kept apart on purpose:
 *
 *   the catalogue says "this works, and here is what to write"
 *   the registry says "this exists here, at this address"
 *
 * Neither the model nor the program can turn the second into the first. What
 * the registry gives a model is an address it would otherwise have to invent,
 * and inventing addresses is how a generated program ends up calling nothing at
 * all: the platform accepts a wrong bundle name with the same silence it gives
 * a right one.
 *
 * Reading it needs ohos.permission.GET_BUNDLE_INFO_PRIVILEGED and a system
 * signature, the same pair execute() needs (see module.json5). Without them the
 * list is simply empty and everything here degrades to "the catalogue only",
 * which is what the app did before this file existed.
 */

import { insightIntentDriver } from '@kit.AbilityKit'
import { hilog } from '@kit.PerformanceAnalysisKit'

const DOMAIN = 0x0000

/** One installed intent, flattened to what a prompt can use. */
export class RegistryEntry {
  /** bundle/module/ability/IntentName -- exactly what intent.call takes. */
  target: string = ''
  intentName: string = ''
  bundle: string = ''
  /** 'background', 'foreground', or both separated by a space. */
  modes: string = ''
  /** Our own grouping, from the bundle name; the platform's domain field is mostly empty. */
  domain: string = ''
  /** Parameter names the app declares, if it declares any. Most declare none. */
  params: string[] = []
  /**
   * One line per declared parameter -- name, type, allowed values if the
   * schema gives an enum, a short description if it gives one, and whether
   * it is required -- the same quality of hint a catalogue row's own
   * IntentParam carries, built from real platform data instead of a guess.
   * Empty exactly when params is.
   */
  paramHints: string[] = []
  /** displayName or keywords, when the app bothered to write them. */
  words: string = ''
}

/**
 * One declared parameter, rendered the same way regardless of where it was
 * declared -- a live device schema (this file's own flatten(), below) or
 * celia's static tool catalogue (VeraCeliaIntentIndex.ets). Provenance-
 * agnostic on purpose: the model should not be able to tell the two apart
 * from the text alone, and a reader comparing the two tiers' hints
 * shouldn't either.
 */
export function describeParamHint(name: string, kind: string, values: string[],
    description: string, required: boolean): string {
  let desc = kind.length > 0 ? kind : 'any'
  if (values.length > 0) { desc = desc + ', one of: ' + values.join(' ') }
  if (description.length > 0) { desc = desc + ' -- ' + description }
  if (required) { desc = desc + ' (required)' }
  return name + ': ' + desc
}

/**
 * One property of a *live device's own* declared parameter schema, read the
 * same defensive way flatten() reads subIntentInfo: index into the untyped
 * record, narrow with typeof, accept absence silently -- a declared schema
 * is still just app data, not something this file can require a shape from.
 * Pulls out the primitives describeParamHint actually needs and defers to it,
 * so this device-specific parsing is the only thing that isn't shared.
 */
function describeSchemaProperty(name: string, required: boolean, schema: Record<string, Object>): string {
  let typeVal = schema['type']
  let kind = typeof typeVal === 'string' ? typeVal : 'any'
  let values: string[] = []
  let enumVal = schema['enum']
  if (Array.isArray(enumVal) && (enumVal as Object[]).length > 0) {
    for (let v of enumVal as Object[]) { values.push((v as Object).toString()) }
  }
  let descVal = schema['description']
  let description = typeof descVal === 'string' ? descVal : ''
  return describeParamHint(name, kind, values, description, required)
}

/**
 * Which part of the phone a bundle belongs to.
 *
 * The platform has a domain field of its own and it is useless here: on this
 * device 394 of 747 intents call themselves ToolsDomain and 71 say nothing. So
 * the grouping is ours, by bundle name, and it only has to be good enough to
 * answer "does this request need that part of the phone".
 */
const DOMAIN_RULES: string[][] = [
  ['maps', 'maps|amap|navi|taxi'],
  ['calendar', 'calendar'],
  ['clock', 'clock|alarm'],
  ['music', 'music|himovie|audio'],
  ['notes', 'notepad|aidataservice|todo'],
  ['photos', 'photos|gallery|camera|screenshot'],
  ['messaging', 'meetime|mms|contacts|instantshare'],
  ['money', 'payment|wallet|alipay'],
  ['settings', 'settings|batterycare|communicationsetting|audioaccessorymanager|simcard'],
]

function domainOf(bundle: string): string {
  for (let rule of DOMAIN_RULES) {
    if (new RegExp(rule[1]).test(bundle)) { return rule[0] }
  }
  return 'system'
}

let cache: RegistryEntry[] = []
let loading: Promise<number> | null = null

/**
 * Reads the registry once and remembers it.
 *
 * Once, because it changes only when apps are installed, and the read is worth
 * hundreds of milliseconds that would otherwise sit in front of every
 * generation. Failure is not an error: an empty list means the prompt carries
 * the catalogue alone.
 */
export function loadRegistry(): Promise<number> {
  if (loading === null) { loading = loadRegistryRead() }
  return loading!
}

async function loadRegistryRead(): Promise<number> {
  try {
    let infos = await insightIntentDriver.getAllInsightIntentInfo(
      insightIntentDriver.GetInsightIntentFlag.GET_FULL_INSIGHT_INTENT)
    let entries: RegistryEntry[] = []
    for (let info of infos) {
      let entry = flatten(info)
      if (entry !== null) { entries.push(entry!) }
    }
    cache = entries
    hilog.info(DOMAIN, 'VERA', 'VERA-REGISTRY loaded ' + cache.length.toString() +
      ' of ' + infos.length.toString() + ' installed intents')
  } catch (e) {
    hilog.warn(DOMAIN, 'VERA', 'VERA-REGISTRY unavailable: ' + (e as Error).message)
    cache = []
  }
  return cache.length
}

/**
 * One record, or null when we could not call it anyway.
 *
 * Dropped here rather than filtered later: an intent that runs in a service or
 * UI extension cannot be reached by insightIntentDriver.execute as this app
 * calls it, and an address a program cannot use has no business in a prompt.
 */
function flatten(info: insightIntentDriver.InsightIntentInfo): RegistryEntry | null {
  let entry = new RegistryEntry()
  entry.bundle = info.bundleName
  entry.intentName = info.intentName
  let ability = ''
  let modes: string[] = []
  let configured = info.subIntentInfoForConfiguration
  if (configured !== undefined && configured !== null && configured!.uiAbility !== undefined) {
    let ui = configured!.uiAbility!
    ability = ui.abilityName
    for (let mode of ui.executeMode) { modes.push(modeName(mode as number)) }
  } else {
    // An intent declared with a decorator has no configuration block; its
    // target is in subIntentInfo instead. Only the @InsightIntentEntry kind
    // names an ability and execute modes, which is what execute() needs here;
    // link, page, form and function intents are reached some other way.
    let sub = info.subIntentInfo as Object as Record<string, Object>
    if (sub !== undefined && sub !== null) {
      let name = sub['abilityName']
      let declaredModes = sub['executeMode']
      if (typeof name === 'string' && Array.isArray(declaredModes)) {
        for (let mode of declaredModes as Object[]) {
          let m = mode as number
          // Foreground and background UIAbility only: an extension ability is not reachable this way.
          if (m === 0 || m === 1) { modes.push(modeName(m)) }
        }
        if (modes.length > 0) { ability = name as string }
      }
    }
  }
  if (ability.length === 0) { return null }
  entry.target = info.bundleName + '/' + info.moduleName + '/' + ability + '/' + info.intentName
  entry.modes = modes.join(' ')
  entry.domain = domainOf(info.bundleName)
  let names: string[] = []
  let hints: string[] = []
  let declared = info.parameters
  // Confirmed on device (VERA-PARAM-SHAPE, since removed): parameters is a
  // JSON Schema object -- {type, properties, required, ...} -- not a flat
  // name/value map. Object.keys(declared) used to read the schema's OWN
  // top-level keys ("properties", "required", "type") as if they were
  // parameter names; every intent with a real schema handed the model three
  // words that are not a parameter on any intent. The names, and the typed
  // hint each one deserves, live one level down, in declared.properties.
  if (declared !== undefined && declared !== null) {
    let schema = declared as Object as Record<string, Object>
    let props = schema['properties']
    if (props !== undefined && props !== null && typeof props === 'object' && !Array.isArray(props)) {
      let required: string[] = []
      let req = schema['required']
      if (Array.isArray(req)) {
        for (let r of req as Object[]) { if (typeof r === 'string') { required.push(r as string) } }
      }
      let propsRecord = props as Record<string, Object>
      for (let key of Object.keys(propsRecord)) {
        names.push(key)
        let propSchema = propsRecord[key]
        if (propSchema !== undefined && propSchema !== null && typeof propSchema === 'object') {
          hints.push(describeSchemaProperty(key, required.indexOf(key) >= 0,
            propSchema as Record<string, Object>))
        } else {
          hints.push(key)
        }
      }
    }
  }
  entry.params = names
  entry.paramHints = hints
  let words: string[] = []
  if (info.displayName.length > 0) { words.push(info.displayName) }
  for (let keyword of info.keywords) { words.push(keyword) }
  entry.words = words.join(' ')
  return entry
}

function modeName(mode: number): string {
  // 0 foreground, 1 background, in the order the platform declares them.
  return mode === 0 ? 'foreground' : mode === 1 ? 'background' : 'other'
}

/**
 * The words of a request, for matching against an intent name.
 *
 * Splitting on spaces alone is not enough, and the difference is not small: a
 * request ending "look through my contacts, and add one" carries the token
 * "contacts," which is a substring of nothing, so all eight of the Contacts
 * app's intents score zero and none of them reaches the prompt. Every sentence
 * a person writes has commas in it, and the keyword is usually the last word of
 * its clause, which is exactly where the comma goes.
 *
 * So anything that is not a letter or a digit separates words. Short words are
 * still dropped by the caller, not here.
 */
export function requestWords(request: string): string[] {
  let cleaned = request.toLowerCase().replace(new RegExp('[^a-z0-9]+', 'g'), ' ')
  let words: string[] = []
  for (let word of cleaned.split(' ')) {
    if (word.length > 0) { words.push(word) }
  }
  return words
}

/** How many intents were found, for the log and the status line. */
export function registrySize(): number { return cache.length }

/** Everything the phone has and we can call, for the selection step. */
export function registryEntries(): RegistryEntry[] { return cache }

/**
 * The chosen addresses, then whatever lexical matches still fit.
 *
 * Chosen first because a model that was told "this one" should see it at the
 * top; the lexical tail is there because the chooser answers in the dark -- it
 * sees intent names and nothing else -- and a word the person actually typed is
 * a signal worth spending the rest of the budget on.
 *
 * Budget in characters, not lines: an address runs 70 to 110 characters
 * depending on the app, and a line count would quietly mean twice the prompt
 * for one request and half for another.
 */
export function describeTargetsForPrompt(chosen: string[], request: string,
    budgetChars: number = 2000): string {
  if (cache.length === 0) { return '' }
  let lines: string[] = []
  let used = 0
  let taken: string[] = []
  for (let target of chosen) {
    for (let entry of cache) {
      if (entry.target !== target || taken.indexOf(target) >= 0) { continue }
      let line = renderEntry(entry)
      if (used + line.length > budgetChars) { continue }
      lines.push(line); used = used + line.length; taken.push(target)
    }
  }
  // The lexical tail: every word of the request that is long enough to mean
  // something, scored against the name and the bundle.
  let words = requestWords(request)
  let scored: RegistryEntry[] = []
  let scores: Map<string, number> = new Map<string, number>()
  for (let entry of cache) {
    if (taken.indexOf(entry.target) >= 0) { continue }
    let haystack = (entry.intentName + ' ' + entry.bundle).toLowerCase()
    let score = 0
    for (let word of words) {
      if (word.length < 4) { continue }
      if (haystack.indexOf(word) >= 0) { score = score + 1 }
    }
    if (score === 0) { continue }
    if (entry.params.length > 0) { score = score + 1 }
    scores.set(entry.target, score)
    scored.push(entry)
  }
  scored.sort((a: RegistryEntry, b: RegistryEntry) => {
    let sa = scores.get(a.target) as number
    let sb = scores.get(b.target) as number
    if (sa !== sb) { return sb - sa }
    return a.target < b.target ? -1 : 1
  })
  for (let entry of scored) {
    let line = renderEntry(entry)
    if (used + line.length > budgetChars) { break }
    lines.push(line); used = used + line.length
  }
  return lines.join('\n')
}

function renderEntry(entry: RegistryEntry): string {
  let line = '  ' + entry.target + '  [' + entry.modes + ']'
  if (entry.params.length > 0) { line = line + '  parameters: ' + entry.params.join(' ') }
  return line + '\n'
}

/** Every domain the registry has anything in, for the questions Jev is asked. */
export function registryDomains(): string[] {
  let seen: string[] = []
  for (let entry of cache) {
    if (seen.indexOf(entry.domain) < 0) { seen.push(entry.domain) }
  }
  return seen
}

/**
 * The intents worth showing for this request, as prompt lines.
 *
 * Two filters, cheapest first. The domains come from the selection step, which
 * asked a model one question per domain. Inside a domain the entries are ranked
 * by how many words of the request they echo -- a poor signal on its own, and a
 * perfectly good tiebreaker once the domain is already right.
 *
 * Capped, because the point of selecting was to keep the prompt affordable: 30
 * lines is about 3 KB against a prompt of 22 KB.
 */
export function describeRegistryForPrompt(domains: string[], request: string, limit: number = 30): string {
  if (cache.length === 0) { return '' }
  let wanted: RegistryEntry[] = []
  for (let entry of cache) {
    if (domains.length === 0 || domains.indexOf(entry.domain) >= 0) { wanted.push(entry) }
  }
  if (wanted.length === 0) { return '' }
  let words = requestWords(request)
  let scored: RegistryEntry[] = []
  let scores: Map<string, number> = new Map<string, number>()
  for (let entry of wanted) {
    let haystack = (entry.intentName + ' ' + entry.bundle + ' ' + entry.words).toLowerCase()
    let score = 0
    for (let word of words) {
      if (word.length < 4) { continue }
      if (haystack.indexOf(word) >= 0) { score = score + 1 }
    }
    // A declared parameter list is worth more than a bare name: it is the only
    // contract the phone offers, and the 13 intents that have one are exactly
    // the ones a model can call correctly without being told anything else.
    if (entry.params.length > 0) { score = score + 1 }
    scores.set(entry.target, score)
    scored.push(entry)
  }
  scored.sort((a: RegistryEntry, b: RegistryEntry) => {
    let sa = scores.get(a.target) as number
    let sb = scores.get(b.target) as number
    if (sa !== sb) { return sb - sa }
    return a.target < b.target ? -1 : 1
  })
  let lines: string[] = []
  for (let i = 0; i < scored.length && i < limit; i++) {
    let entry = scored[i]
    let line = '  ' + entry.target + '  [' + entry.modes + ']'
    if (entry.params.length > 0) { line = line + '  parameters: ' + entry.params.join(' ') }
    lines.push(line)
  }
  return lines.join('\n')
}
