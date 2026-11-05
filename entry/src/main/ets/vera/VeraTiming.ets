/**
 * Where the time between a prompt and a running program goes, one log line per
 * step, all tagged VERA-T so a single grep gives the whole timeline:
 *
 *   hdc shell "hilog -x | grep VERA-T"
 *
 * A model request is logged as a `turn` with its moments relative to when it
 * was sent -- first byte, reasoning start and end, first program text, first
 * tool call, last byte -- and its token counts. Everything else (tool lookups,
 * UI selection, compiling, the first render) is a `step` with a duration.
 * Nothing reads these back; they are for measuring on a device.
 *
 * Alongside the log lines, `trace()` appends the full story to
 * {filesDir}/vera/trace.jsonl, one JSON object per line: every request's
 * reasoning and reply text, each tool call with its arguments and the result
 * handed back, and each compile with its source and diagnostics. hilog cuts
 * long lines, so anything that must be read whole goes there. The benchmark
 * (tools/vera-bench) clears the file before a run and pulls it after.
 */

import { fileIo as fs } from '@kit.CoreFileKit'

let tracePath: string = ''

/** Called once a page knows its filesDir; until then trace() does nothing. */
export function initTrace(filesDir: string): void {
  tracePath = filesDir + '/vera/trace.jsonl'
}

/** Appends one event. Never throws: a trace that cannot be written is simply missing. */
export function trace(event: string, fields: Record<string, Object>): void {
  if (tracePath.length === 0) { return }
  fields['event'] = event
  fields['at'] = Date.now()
  try {
    let file = fs.openSync(tracePath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.APPEND)
    fs.writeSync(file.fd, JSON.stringify(fields) + '\n')
    fs.closeSync(file)
  } catch (e) {
    console.warn('VERA-T trace write failed: ' + (e as Error).message)
  }
}

/** Moments in one streamed model request, as Date.now() values; 0 = never happened. */
export class TurnTiming {
  sentAt: number = 0
  firstByteAt: number = 0
  firstReasoningAt: number = 0
  lastReasoningAt: number = 0
  firstContentAt: number = 0
  lastContentAt: number = 0
  firstToolAt: number = 0
  endAt: number = 0
  bodyChars: number = 0
  inputTokens: number = 0
  cachedTokens: number = 0
  outputTokens: number = 0
  reasoningTokens: number = 0
  finishReason: string = ''
  toolCalls: number = 0

  /** Marks a delta of the given kind arriving now. */
  saw(kind: string): void {
    let now = Date.now()
    if (this.firstByteAt === 0) { this.firstByteAt = now }
    if (kind === 'reasoning') {
      if (this.firstReasoningAt === 0) { this.firstReasoningAt = now }
      this.lastReasoningAt = now
    } else if (kind === 'content') {
      if (this.firstContentAt === 0) { this.firstContentAt = now }
      this.lastContentAt = now
    } else if (kind === 'tool') {
      if (this.firstToolAt === 0) { this.firstToolAt = now }
    }
  }

  /** Reads usage, including the reasoning share of the output when the API reports it. */
  readUsage(usage: Record<string, Object>): void {
    let input = usage['prompt_tokens']
    if (typeof input === 'number') { this.inputTokens = input as number }
    let output = usage['completion_tokens']
    if (typeof output === 'number') { this.outputTokens = output as number }
    let cached = usage['prompt_cache_hit_tokens']
    if (typeof cached === 'number') { this.cachedTokens = cached as number }
    let details = usage['completion_tokens_details'] as Record<string, Object>
    if (details !== null && details !== undefined) {
      let reasoning = details['reasoning_tokens']
      if (typeof reasoning === 'number') { this.reasoningTokens = reasoning as number }
    }
  }
}

function rel(at: number, from: number): string {
  return at > 0 ? (at - from).toString() : '-'
}

/** One line per model request: `src` says who asked (gen, chat, uineeds), `round` which round of its loop. */
export function logTurn(src: string, round: number, t: TurnTiming): void {
  console.info('VERA-T turn src=' + src + ' round=' + round.toString() +
    ' firstByte=' + rel(t.firstByteAt, t.sentAt) +
    ' reason=' + rel(t.firstReasoningAt, t.sentAt) + '..' + rel(t.lastReasoningAt, t.sentAt) +
    ' content=' + rel(t.firstContentAt, t.sentAt) + '..' + rel(t.lastContentAt, t.sentAt) +
    ' tool=' + rel(t.firstToolAt, t.sentAt) +
    ' end=' + rel(t.endAt, t.sentAt) +
    ' bodyChars=' + t.bodyChars.toString() +
    ' in=' + t.inputTokens.toString() + ' cached=' + t.cachedTokens.toString() +
    ' out=' + t.outputTokens.toString() + ' reasonTok=' + t.reasoningTokens.toString() +
    ' finish=' + t.finishReason + ' calls=' + t.toolCalls.toString())
}

/** The trace event for one compile: the exact source and, when it failed, the diagnostics. */
export function traceCompile(src: string, attempt: number, source: string, errors: string): void {
  let f: Record<string, Object> = {}
  f['src'] = src
  f['attempt'] = attempt
  f['ok'] = errors.length === 0
  f['errors'] = errors
  f['source'] = source
  trace('compile', f)
}

/** The trace event for one model request: its timing plus what it said. */
export function traceTurn(src: string, round: number, t: TurnTiming, reasoning: string, content: string,
    calls: Object[], tools: boolean): void {
  let f: Record<string, Object> = {}
  f['src'] = src
  f['round'] = round
  f['toolsOffered'] = tools
  f['firstByteMs'] = t.firstByteAt > 0 ? t.firstByteAt - t.sentAt : -1
  f['reasonMs'] = t.firstReasoningAt > 0 ? t.lastReasoningAt - t.firstReasoningAt : 0
  f['contentMs'] = t.firstContentAt > 0 ? t.lastContentAt - t.firstContentAt : 0
  f['totalMs'] = t.endAt - t.sentAt
  f['bodyChars'] = t.bodyChars
  f['inTok'] = t.inputTokens
  f['cachedTok'] = t.cachedTokens
  f['outTok'] = t.outputTokens
  f['reasonTok'] = t.reasoningTokens
  f['finish'] = t.finishReason
  f['calls'] = calls
  f['reasoning'] = reasoning
  f['content'] = content
  trace('turn', f)
}

/** One line per non-model step, with how long it took and anything worth knowing about it. */
export function logStep(name: string, startedAt: number, detail: string = ''): void {
  console.info('VERA-T step ' + name + ' ms=' + (Date.now() - startedAt).toString() +
    (detail.length > 0 ? ' ' + detail : ''))
}

/** A moment worth lining the rest up against, such as the tap on Generate or Send. */
export function logMark(name: string, detail: string = ''): void {
  console.info('VERA-T mark ' + name + ' at=' + Date.now().toString() + (detail.length > 0 ? ' ' + detail : ''))
}
