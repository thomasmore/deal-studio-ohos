/**
 * Harness stub for VeraSdkIndex.ets.
 *
 * VeraCompiler.ts needs exactly one export from the real module --
 * isValidSdkTarget, used only to validate an std/sdk.call target string. The
 * real module pulls in @ohos.resourceManager, @ohos.hilog, LlamaEngine.ets
 * (which itself pulls in @ohos.file.fs and libllama.so) and
 * VeraIntentRegistry.ets (@ohos.app.ability.insightIntentDriver) -- none of
 * it reachable under plain Node, and none of it exercised by a std/ui-only
 * program, which is all this harness compiles.
 *
 * A std/ui-only program never calls std/sdk, so this function's real
 * behaviour is never on the path being checked here. Returning true for
 * anything of the right shape is enough to keep the compiler's own
 * std/sdk.call diagnostic (VeraCompiler.ts, the isValidSdkTarget call site)
 * from firing on a program this harness was never asked to validate that
 * part of.
 */
export function isValidSdkTarget(target: string): boolean {
  // A check can stand in for the bundled index by setting globalThis.__sdkTargetHook (template-suite.js does).
  const hook = (globalThis as any).__sdkTargetHook
  if (typeof hook === 'function') { return hook(target) }
  return typeof target === 'string' && target.length > 0
}

import { requestWords } from '../../../entry/src/main/ets/vera/VeraIntentRegistry'

// Copies of the real tokenizers: VeraIntentIndex.ets (the intent panel's candidate search) needs them on the host.
const STOPWORDS: string[] = ['the', 'and', 'for', 'are', 'was', 'her', 'its',
  'but', 'not', 'you', 'all', 'can', 'has', 'had', 'out', 'who', 'why', 'how',
  'did', 'does', 'own', 'too', 'any', 'may', 'say', 'she', 'his', 'him', 'our',
  'per', 'via', 'with', 'from', 'that', 'this', 'have', 'been', 'were', 'they',
  'them', 'what', 'when', 'then', 'than', 'into', 'onto', 'over', 'will',
  'would', 'could', 'should', 'about']

export function needWords(need: string): string[] {
  let words: string[] = []
  for (let w of requestWords(need)) {
    if (w.length >= 3 && STOPWORDS.indexOf(w) < 0) { words.push(w) }
  }
  return words
}

export function identifierTokens(name: string): string[] {
  let matches = name.match(/[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z0-9]+|[A-Z]+/g)
  if (matches === null) { return [] }
  let tokens: string[] = []
  for (let m of matches) { tokens.push(m.toLowerCase()) }
  return tokens
}
