/**
 * A live figure read straight from a public JSON API: `sdk.call("Vera.Source.fetch", ["url", <address>, "paths", "a.b|c[0].d",
 * "asof", "e"], handler)`. The source was found and checked while the program was generated (VeraSourceFind.ets); the program
 * holds the address and the paths as written then -- the compiler takes them only as literal strings (E2114), so nothing the
 * program keeps can go out in an address.
 *
 * The answer has the lines of Vera.Live.fetch (VeraLive.ets), so the same handler reads either:
 *
 *   ok                     (or "error: <reason>")
 *   <value 1>
 *   <value 2>
 *   <value 3>              (an empty line for a path not asked)
 *   source<TAB><domain><TAB><address>
 *   asof<TAB><the source's own time for the data, or the phone's clock>
 *
 * One GET, https only, no credentials in the address, no host on this network, a size limit and short timeouts: quick enough for
 * the home-screen card's update, which has about ten seconds.
 */

import { http } from '@kit.NetworkKit'
import { hilog } from '@kit.PerformanceAnalysisKit'

const DOMAIN = 0x0000

export const SOURCE_TARGET: string = 'Vera.Source.fetch'
export const SOURCE_MAX_FIGURES: number = 3
const SOURCE_MAX_CHARS: number = 400000
const VALUE_CHARS: number = 40

/** A source as the finder checked it: the GET, where each figure is in its answer, and what it said then. */
export class SourceSpec {
  /**
   * Set when no public API was found (searchSpec, VeraSourceFind.ets): the program reads its figures off a web search with
   * Vera.Live.fetch and this query, and the fields below are a made-up answer of that shape, for checking the program only.
   */
  query: string = ''
  url: string = ''
  labels: string[] = []
  paths: string[] = []
  units: string[] = []
  /** Where the answer says what time its data is for; '' when it does not. */
  asof: string = ''
  /** The figures read when it was checked, in the order of `paths`. */
  values: string[] = []
  asofValue: string = ''
  /** The whole answer the program gets for the check's response: what generation hands its handler to see what it shows. */
  sample: string = ''
}

export class SourceResponse {
  text: string = ''
  /** '' when `text` is the answer. */
  error: string = ''
}

export function domainOf(url: string): string {
  let m = /^https?:\/\/([^\/?#:]+)/i.exec(url)
  return m === null ? '' : m[1].toLowerCase()
}

/** '' for an address the program may fetch; else why not. */
export function sourceUrlError(url: string): string {
  if (!/^https:\/\/[^\s]+$/i.test(url)) { return 'the address must start with https:// and have no spaces' }
  if (/^https:\/\/[^\/?#]*@/i.test(url)) { return 'the address must not carry a user name or password' }
  let host = domainOf(url)
  if (host.length === 0 || host.indexOf('.') < 0 || host === 'localhost' || host.endsWith('.local') ||
      /^(10|127|0)\./.test(host) || /^192\.168\./.test(host) || /^172\.(1[6-9]|2\d|3[01])\./.test(host) || /^169\.254\./.test(host) ||
      host.indexOf(':') >= 0) {
    return 'the address must be a public internet host'
  }
  return ''
}

/** The value at `path` in a parsed JSON answer: a.b[0].c, where [-1] is the last item. undefined when it is not there. */
export function readPath(root: Object | null, path: string): Object | null | undefined {
  let cur: Object | null | undefined = root
  let parts = path.replace(/\[(-?\d+)\]/g, '.$1').split('.').filter((p: string): boolean => p.length > 0)
  if (parts.length === 0) { return undefined }
  for (let part of parts) {
    if (cur === null || cur === undefined || typeof cur !== 'object') { return undefined }
    if (Array.isArray(cur) && /^-?\d+$/.test(part)) {
      let items = cur as Object[]
      let i = Number(part)
      cur = items[i < 0 ? items.length + i : i]
    } else {
      cur = (cur as Record<string, Object>)[part]
    }
  }
  return cur
}

/** A figure as the program receives it: a number, a string or a yes/no; '' for anything else. */
export function valueText(value: Object | null | undefined): string {
  if (typeof value === 'number') { return Number.isFinite(value) ? String(value) : '' }
  if (typeof value === 'boolean') { return value ? 'true' : 'false' }
  if (typeof value === 'string') {
    let text = value.replace(/[\r\n\t]+/g, ' ').trim()
    return text.length > VALUE_CHARS ? text.substring(0, VALUE_CHARS) : text
  }
  return ''
}

/** The answer lines for one response; the first figure must be there, the others may be missing. */
export function sourceAnswer(body: string, url: string, paths: string[], asof: string, clock: string): string {
  let root: Object | null = null
  try { root = JSON.parse(body) as Object } catch (e) { return 'error: the source did not answer JSON' }
  let values: string[] = []
  for (let i = 0; i < SOURCE_MAX_FIGURES; i++) {
    values.push(i < paths.length && paths[i].length > 0 ? valueText(readPath(root, paths[i])) : '')
  }
  if (values[0].length === 0) { return 'error: the source answered without ' + paths[0] }
  let when = asof.length > 0 ? valueText(readPath(root, asof)) : ''
  return 'ok\n' + values.join('\n') + '\nsource\t' + domainOf(url) + '\t' + url + '\nasof\t' + (when.length > 0 ? when : clock)
}

/** One GET of `url` as text. Never throws. */
export async function httpGetText(url: string): Promise<SourceResponse> {
  let out = new SourceResponse()
  let bad = sourceUrlError(url)
  if (bad.length > 0) { out.error = bad; return out }
  let client = http.createHttp()
  try {
    let header: Record<string, string> = {}
    header['Accept'] = 'application/json'
    header['User-Agent'] = 'VERA'
    let resp = await client.request(url, {
      method: http.RequestMethod.GET,
      header: header,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 4000,
      readTimeout: 5000
    })
    if (resp.responseCode < 200 || resp.responseCode >= 300) { out.error = 'HTTP ' + resp.responseCode.toString(); return out }
    let text = typeof resp.result === 'string' ? resp.result as string : JSON.stringify(resp.result)
    if (text.length > SOURCE_MAX_CHARS) { out.error = 'the answer is too large'; return out }
    out.text = text
  } catch (e) {
    out.error = (e as Error).message
  } finally {
    client.destroy()
  }
  return out
}

function pad2(n: number): string { return n < 10 ? '0' + n.toString() : n.toString() }

/** The answer to one `Vera.Source.fetch` call. Never throws. */
export async function sourceFetch(params: Map<string, string>): Promise<string> {
  let started = Date.now()
  let url = (params.get('url') ?? '').trim()
  let paths = (params.get('paths') ?? '').split('|').map((p: string): string => p.trim())
  let asof = (params.get('asof') ?? '').trim()
  if (url.length === 0 || paths.length === 0 || paths[0].length === 0) { return 'error: no address or figure to read' }
  let got = await httpGetText(url)
  if (got.error.length > 0) {
    hilog.info(DOMAIN, 'VERA', 'VERA-SOURCE ' + domainOf(url) + ' failed: ' + got.error + ' ms=' + (Date.now() - started).toString())
    return 'error: ' + got.error
  }
  let now = new Date()
  let answer = sourceAnswer(got.text, url, paths, asof, pad2(now.getHours()) + ':' + pad2(now.getMinutes()) + ':' + pad2(now.getSeconds()))
  hilog.info(DOMAIN, 'VERA', 'VERA-SOURCE ' + domainOf(url) + ' ' + answer.split('\n').slice(0, 2).join(' ') + ' ms=' +
    (Date.now() - started).toString())
  return answer
}
