/**
 * Rigorous timing benchmark for find_sdk_function/find_intent_function's
 * two search paths (token vs embedding) -- 3 interleaved passes over the
 * same 22 real `need` strings DeepSeek actually asked during the 10 live
 * prompts in docs/embeddings-benchmark.md, calling the search functions
 * directly, with no DeepSeek round trip involved at all.
 *
 * Same "dev-only diagnostic, reachable only from a launch parameter, from
 * a shell on the device" shape as IntentProbe.ets's runProbe, with one
 * difference: unlike a raw intent call, this needs both corpus caches
 * already warm, which only happens inside GeneratePage.ets's own resource
 * loading -- so EntryAbility.ets's extractBenchmark only sets `requested`
 * here; GeneratePage.ets's ensureEmbeddingsReady() is what actually calls
 * runSearchBenchmark(), once both caches report ready.
 *
 *   hdc shell aa start -a EntryAbility -b com.vera.probe.dyn \
 *     --ps veraBenchmark 1
 *   hdc shell hilog -x | grep VERA-BENCH
 *
 * Methodology (see docs/embeddings-benchmark.md for the full writeup):
 *   - Three full passes over all 22 need-strings, not three consecutive
 *     reps of one before moving to the next -- spreads any time-based
 *     drift (thermal, GC) evenly across every need-string instead of
 *     concentrating it on whichever ones happen to run later.
 *   - No warmup pass discarded. A real generation is "cold" for these
 *     functions too; discarding a warmup rep would make this less
 *     representative of real conditions, not more.
 *   - Timed region is the search call only -- Date.now() immediately
 *     around findSdkFunctionFromCache/findSdkFunctionByEmbedding (and the
 *     intent equivalents), logging happens after the delta is captured,
 *     never inside the timed window.
 *   - No DeepSeek involved: calls the four search functions directly, so
 *     there is no network latency or model non-determinism in the need
 *     string itself (DeepSeek does not reliably repeat the same phrasing
 *     across separate real generations -- confirmed directly while
 *     collecting the first version of this benchmark).
 */

import { hilog } from '@kit.PerformanceAnalysisKit'
import { findSdkFunctionFromCache, sdkIndexSize } from './VeraSdkIndex'
import { findIntentFunction } from './VeraIntentIndex'
import { findSdkFunctionByEmbedding, sdkEmbeddingsReady } from './VeraSdkEmbeddingCache'
import { findIntentFunctionByEmbedding, intentEmbeddingsReady } from './VeraIntentEmbeddingCache'

const DOMAIN = 0x0000

class BenchCase {
  prompt: string = ''
  need: string = ''
  constructor(prompt: string, need: string) { this.prompt = prompt; this.need = need }
}

// Exactly the 22 real need-strings DeepSeek asked during the 10 live
// prompts in docs/embeddings-benchmark.md, grouped by the prompt that
// produced them -- not written fresh for this benchmark.
const SDK_CASES: BenchCase[] = [
  new BenchCase('1', 'read the current battery level'),
  new BenchCase('2', 'turn on the phone flashlight torch'),
  new BenchCase('3', 'turn Bluetooth on or off'),
  new BenchCase('4', 'take a photo with the camera'),
  new BenchCase('5', 'start turn by turn navigation to a destination address'),
  new BenchCase('6', 'read the current weather forecast for my location'),
  new BenchCase('7a', 'scan a QR code with the camera and return the decoded text'),
  new BenchCase('7b', 'scan a barcode or QR code using the camera'),
  new BenchCase('8a', 'vibrate the phone'),
  new BenchCase('8b', 'show a notification'),
  new BenchCase('9', 'check whether the phone is currently connected to WiFi'),
  new BenchCase('10a', 'record a short voice memo from the microphone'),
  new BenchCase('10b', 'play back a recorded audio file'),
]

const INTENT_CASES: BenchCase[] = [
  new BenchCase('2', 'turn on the phone flashlight torch'),
  new BenchCase('3', 'open Bluetooth settings'),
  new BenchCase('4', 'take a photo with the camera'),
  new BenchCase('5', 'start turn by turn navigation to an address'),
  new BenchCase('6', 'send a text message to a contact'),
  new BenchCase('7a', 'open a web link in the browser'),
  new BenchCase('7b', 'open a URL or web page in the web browser'),
  new BenchCase('9', 'open the WiFi settings screen'),
  new BenchCase('10', 'record a voice memo with the sound recorder app'),
]

let requestedFlag = false

/** Set by EntryAbility.extractBenchmark when `--ps veraBenchmark 1` is
 * present; checked by GeneratePage.ensureEmbeddingsReady() once both
 * corpus caches are confirmed warm. */
export function requestBenchmark(): void { requestedFlag = true }

/** Consumes the flag: true at most once per launch parameter, even if
 * ensureEmbeddingsReady() itself runs more than once in the same process
 * (confirmed on-device: a single `--ps veraBenchmark 1` launch produced
 * two full, interleaved runSearchBenchmark() passes under the same pid --
 * GeneratePage's own page lifecycle invoking its resource-loading path
 * twice, not a benchmark-specific bug). Checking requestedFlag without
 * clearing it let every one of those calls see "requested" and start its
 * own full run; clearing it here on first read makes a second call see
 * false no matter how many times ensureEmbeddingsReady() itself runs. */
export function benchmarkRequested(): boolean {
  if (!requestedFlag) { return false }
  requestedFlag = false
  return true
}

async function benchSdk(c: BenchCase, pass: number): Promise<void> {
  let t0 = Date.now()
  let tokenResults = findSdkFunctionFromCache(c.need, 8)
  let tokenMs = Date.now() - t0
  let t1 = Date.now()
  let embedResults = await findSdkFunctionByEmbedding(c.need, 8)
  let embeddingFullMs = Date.now() - t1
  hilog.info(DOMAIN, 'VERA', 'VERA-BENCH-SDK prompt=' + c.prompt + ' pass=' + pass.toString() +
    ' need="' + c.need + '" tokenMs=' + tokenMs.toString() +
    ' embeddingFullMs=' + embeddingFullMs.toString() +
    ' tokenFound=' + tokenResults.length.toString() +
    ' embeddingFound=' + (embedResults === null ? 0 : embedResults.length).toString())
}

async function benchIntent(c: BenchCase, pass: number): Promise<void> {
  let t0 = Date.now()
  let tokenResults = findIntentFunction(c.need, 8)
  let tokenMs = Date.now() - t0
  let t1 = Date.now()
  let embedResults = await findIntentFunctionByEmbedding(c.need, 8)
  let embeddingFullMs = Date.now() - t1
  hilog.info(DOMAIN, 'VERA', 'VERA-BENCH-INTENT prompt=' + c.prompt + ' pass=' + pass.toString() +
    ' need="' + c.need + '" tokenMs=' + tokenMs.toString() +
    ' embeddingFullMs=' + embeddingFullMs.toString() +
    ' tokenFound=' + tokenResults.length.toString() +
    ' embeddingFound=' + (embedResults === null ? 0 : embedResults.length).toString())
}

export async function runSearchBenchmark(): Promise<void> {
  hilog.info(DOMAIN, 'VERA', 'VERA-BENCH start sdkReady=' + sdkEmbeddingsReady().toString() +
    ' intentReady=' + intentEmbeddingsReady().toString() + ' sdkCorpusSize=' + sdkIndexSize().toString())
  for (let pass = 1; pass <= 3; pass++) {
    for (let c of SDK_CASES) { await benchSdk(c, pass) }
    for (let c of INTENT_CASES) { await benchIntent(c, pass) }
  }
  hilog.info(DOMAIN, 'VERA', 'VERA-BENCH done')
}
