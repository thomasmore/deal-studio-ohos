import { fileIo as fs } from '@kit.CoreFileKit'
import { util } from '@kit.ArkTS'
import { SelectorCall } from './SelectorMetrics'

/**
 * An append-only record of one completed generation run, kept so that
 * latency, token use, cost and correctness can be tracked across runs
 * without scraping the Metrics screen off the device.
 *
 * The file is {filesDir}/vera/run-log.jsonl -- one JSON object per line,
 * appended at the end of every run (GeneratePage.finishMetrics). A record
 * is written whether the run compiled, fell through or was not built, so the
 * file is also the failure log. Never throws: a logging failure is logged to
 * hilog and swallowed, because metrics must never break a generation.
 */
export class RunLogRecord {
  /** Epoch milliseconds at the end of the run. */
  ts: number = 0
  /** The request text that produced the run (empty for some refinements). */
  prompt: string = ''
  /** deepseek | server | local (SettingsStore.MODE_*). */
  mode: string = ''
  /** Human label for the provider this run used (the session totals say "Mixed" instead). */
  provider: string = ''
  /** The model this run used. */
  model: string = ''
  /** compose | generate | not-built: compose = a template screen the model did not rewrite;
   *  generate = the model wrote or rewrote the program; not-built = nothing compiled. */
  path: string = ''
  /** True if the run ended with a compiled program on screen. */
  compiled: boolean = false
  /** The status line the run ended on, verbatim ('Ready in 12.3 s', 'Not built ...', ...). */
  verdict: string = ''
  /** Wall-clock milliseconds the run charged to itself (excludes time waiting for a person's answer). */
  elapsedMs: number = 0
  /** How many compile attempts the run made (1 on a clean first try; 0 when
   *  the agent composed the screen without one). */
  attempts: number = 0
  /** How many model requests the run sent: program attempts and compile
   *  repairs, tool round trips inside them, the agent's auxiliary calls, selector
   *  HTTP attempts (including retries), local selector invocations, and one for a server run's /compile request. Not the number of user
   *  requests -- each record is already one of those. */
  modelCalls: number = 0
  /** Writer-only requests, separate from paid selector HTTP and native inference. */
  writerCalls: number = 0
  selectorMs: number = 0
  selectorHttpRequests: number = 0
  localSelectorCalls: number = 0
  selectorCalls: SelectorCall[] = []
  /** Prompt tokens (-1 when the provider did not report usage). */
  inputTokens: number = -1
  /** Prompt tokens reported as a cache hit (-1 when not reported). */
  cacheHitTokens: number = -1
  /** Completion tokens (-1 when not reported). */
  outputTokens: number = -1
  /** Estimated USD for the run (-1 when not priced). */
  estimatedUsd: number = -1
  /** True if any usage field is missing or approximate. */
  partial: boolean = true
}

/** Append one record to the run log. Creates the vera/ directory if needed. */
export function appendRunLog(filesDir: string, rec: RunLogRecord): void {
  try {
    let dir = filesDir + '/vera'
    try { fs.mkdirSync(dir, true) } catch (_e) {}
    let path = dir + '/run-log.jsonl'
    let file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.APPEND)
    try {
      fs.writeSync(file.fd, JSON.stringify(rec) + '\n')
    } finally {
      fs.closeSync(file)
    }
  } catch (e) {
    console.warn('VERA-RUNLOG append failed: ' + (e as Error).message)
  }
}

/** Read the whole run log as parsed records (newest last). Empty list on any error. */
export function readRunLog(filesDir: string): RunLogRecord[] {
  let out: RunLogRecord[] = []
  try {
    let path = filesDir + '/vera/run-log.jsonl'
    let file = fs.openSync(path, fs.OpenMode.READ_ONLY)
    try {
      let stat = fs.statSync(path)
      let buf = new ArrayBuffer(stat.size)
      fs.readSync(file.fd, buf)
      let text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf))
      for (let line of text.split('\n')) {
        let s = line.trim()
        if (s.length === 0) { continue }
        try { out.push(JSON.parse(s) as RunLogRecord) } catch (_e) {}
      }
    } finally {
      fs.closeSync(file)
    }
  } catch (_e) {}
  return out
}
