/**
 * Intent rows loaded from a file on the phone, next to the ones written here.
 *
 * The rows in VeraIntentCatalog come from Huawei's published standard-intent
 * specification: they are about the platform, they are the same on every phone
 * that has those apps, and they belong in the repository. Everything else does
 * not. A row for the settings app names a constant like itemName "bluetooth",
 * an ability called DefaultIntentBackgroundUiAbility and a versionCode -- facts
 * about one device and one firmware, established by reading what is installed
 * on it. That is the operator's material, not the product's, so it lives in a
 * file they keep and push themselves:
 *
 *   {filesDir}/vera/intent-catalog.json
 *
 *   hdc file send intent-catalog.json \
 *     /data/app/el2/100/base/com.vera.probe.dyn/haps/entry/files/vera/
 *
 * Nothing about that file is in this repository, and nothing here reads it at
 * build time. Without it the app works exactly as it did: the built-in rows,
 * plus intent.call for everything else the phone has.
 *
 * One rule is not negotiable, and it is enforced below rather than trusted.
 * A row from the file may not be quieter than 'act': it may add an intent and
 * give it a name a person can read, but it cannot grant itself the right to
 * run without asking. Only rows that were reviewed in the repository have that,
 * because "runs without asking" is a claim about evidence, and a file has none.
 */

import { fileIo as fs } from '@kit.CoreFileKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { INTENT_CATALOG, IntentSpec, IntentParam } from './VeraIntentCatalog'

const DOMAIN = 0x0000

/** What the load did, for the log and for the Generate screen's status line. */
export class CatalogLoad {
  added: number = 0
  rejected: number = 0
  /** One line per rejected row, naming the row and what was wrong with it. */
  problems: string[] = []
  /** '' when there was no file at all, which is the ordinary case. */
  path: string = ''
}

let loadedOnce = false

function readText(path: string): string {
  try {
    let stat = fs.statSync(path)
    if (stat.size === 0) { return '' }
    return fs.readTextSync(path)
  } catch (_e) {
    return ''
  }
}

function stringField(row: Record<string, Object>, name: string): string {
  let value = row[name]
  return value !== undefined && value !== null && typeof value === 'string' ? value as string : ''
}

function mapField(row: Record<string, Object>, name: string): Map<string, string> {
  let out = new Map<string, string>()
  let value = row[name]
  if (value === undefined || value === null) { return out }
  let record = value as Record<string, Object>
  for (let key of Object.keys(record)) {
    let item = record[key]
    if (typeof item === 'string') { out.set(key, item as string) }
  }
  return out
}

function stringList(value: Object | undefined): string[] {
  let out: string[] = []
  if (value === undefined || value === null) { return out }
  let items = value as Object[]
  for (let item of items) {
    if (typeof item === 'string') { out.push(item as string) }
  }
  return out
}

/**
 * One row, or null with a reason.
 *
 * Rejected rather than repaired: a row the loader had to guess at would be a
 * row nobody has checked, sent to an app that validates nothing.
 */
function parseRow(row: Record<string, Object>, problems: string[]): IntentSpec | null {
  let name = stringField(row, 'name')
  if (name.length === 0) { problems.push('a row with no name'); return null }
  let target = stringField(row, 'target')
  let parts = target.split('/')
  if (parts.length !== 4) {
    problems.push(name + ': target must be bundle/module/ability/IntentName')
    return null
  }
  let mode = stringField(row, 'mode')
  if (mode !== 'foreground' && mode !== 'background') {
    problems.push(name + ': mode must be foreground or background')
    return null
  }
  // The rule this file exists to enforce. A file may describe an intent; it may
  // not decide that the intent runs without the person seeing it.
  let risk = stringField(row, 'risk')
  if (risk !== 'critical') { risk = 'act' }

  let params: IntentParam[] = []
  let declared = row['params']
  if (declared !== undefined && declared !== null) {
    let items = declared as Object[]
    for (let item of items) {
      let p = item as Record<string, Object>
      let field = stringField(p, 'name')
      let platformName = stringField(p, 'platformName')
      if (field.length === 0 || platformName.length === 0) {
        problems.push(name + ': a parameter needs name and platformName')
        return null
      }
      let kind = stringField(p, 'kind')
      params.push(new IntentParam(field, kind === 'int' ? 'int' : 'string', platformName,
        stringList(p['values']), mapField(p, 'valueMap'), stringField(p, 'summary'),
        stringField(p, 'defaultValue')))
    }
  }
  return new IntentSpec(name, capitalise(name) + 'Params', parts[0].trim(), parts[1].trim(),
    parts[2].trim(), parts[3].trim(), params, stringField(row, 'summary'),
    'probed', mode, stringField(row, 'via') === 'launch' ? 'launch' : 'intent',
    mapField(row, 'fixed'), risk, stringField(row, 'domain'),
    stringField(row, 'titleForUser'), stringField(row, 'verifiedVersion'),
    stringField(row, 'resultField'), mapField(row, 'resultMap'))
}

function capitalise(name: string): string {
  return name.length === 0 ? name : name.substring(0, 1).toUpperCase() + name.substring(1)
}

/**
 * Reads the file and appends what it holds to the catalogue.
 *
 * Once per run: the compiler builds its std/intent module from the catalogue
 * every time it compiles, so a row that arrived after a program was written
 * would change what that program is allowed to say. Loading before anything is
 * generated keeps the vocabulary steady for the life of the app's run.
 *
 * A row whose name is already taken is skipped rather than allowed to replace
 * the built-in one -- otherwise a file could redefine a reviewed row while
 * keeping its name and its quiet risk class.
 */
export function loadCatalogFile(filesDir: string): CatalogLoad {
  let load = new CatalogLoad()
  if (loadedOnce) { return load }
  loadedOnce = true
  let path = filesDir + '/vera/intent-catalog.json'
  let text = readText(path)
  if (text.length === 0) {
    hilog.info(DOMAIN, 'VERA', 'VERA-CATALOG no file at ' + path + ', built-in rows only')
    return load
  }
  load.path = path
  let rows: Object[] = []
  try {
    let parsed = JSON.parse(text) as Record<string, Object>
    let found = parsed['rows']
    if (found === undefined || found === null) {
      load.problems.push('the file has no "rows" array')
    } else {
      rows = found as Object[]
    }
  } catch (e) {
    load.problems.push('the file is not JSON: ' + (e as Error).message)
    hilog.error(DOMAIN, 'VERA', 'VERA-CATALOG ' + load.problems[0])
    return load
  }
  for (let item of rows) {
    let spec = parseRow(item as Record<string, Object>, load.problems)
    if (spec === null) { load.rejected = load.rejected + 1; continue }
    let taken = false
    for (let existing of INTENT_CATALOG) {
      if (existing.name === spec!.name) { taken = true }
    }
    if (taken) {
      load.rejected = load.rejected + 1
      load.problems.push(spec!.name + ': a built-in row already has this name')
      continue
    }
    INTENT_CATALOG.push(spec!)
    load.added = load.added + 1
  }
  hilog.info(DOMAIN, 'VERA', 'VERA-CATALOG ' + load.added.toString() + ' rows from file, ' +
    load.rejected.toString() + ' rejected')
  for (let problem of load.problems) {
    hilog.warn(DOMAIN, 'VERA', 'VERA-CATALOG ' + problem)
  }
  return load
}
