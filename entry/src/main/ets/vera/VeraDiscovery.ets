/** Shared discovery indexes. VeraCapabilities owns background model and cache preparation. */
import { resourceManager } from '@kit.LocalizationKit'
import { loadIntentSummaries } from './VeraIntentIndex'
import { loadRegistry } from './VeraIntentRegistry'
import { loadSdkIndex } from './VeraSdkIndex'
import { loadCeliaIntentIndex } from './VeraCeliaIntentIndex'

let discovery: Promise<void> | null = null

/** Concurrent screens share one load. Index readiness does not wait for the embedding model. */
export function loadDiscovery(_filesDir: string, mgr: resourceManager.ResourceManager): Promise<void> {
  if (discovery === null) {
    let intents = loadIntentSummaries(mgr).then(() => loadRegistry()).then((count: number): void => {
      console.info('VERA-REGISTRY ' + count.toString() + ' intents available to find_intent_function')
    })
    let sdk = loadSdkIndex(mgr).then((count: number): void => {
      console.info('VERA-SDK ' + count.toString() + ' sdk functions available to search')
    })
    // Independent of the registry load above: celia's own static corpus
    // never depends on this device's registry, only on allEntries() later
    // joining the two by bundle/intentName once both have loaded.
    let celia = loadCeliaIntentIndex(mgr).then((count: number): void => {
      console.info('VERA-CELIA ' + count.toString() + ' celia intent candidates loaded')
    })
    discovery = Promise.all([intents, sdk, celia]).then((): void => {})
  }
  return discovery!
}
