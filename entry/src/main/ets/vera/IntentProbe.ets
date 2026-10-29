/**
 * Calls one intent, named entirely on the command line, and writes down what
 * came back.
 *
 * A row in VeraIntentCatalog is only allowed to claim what somebody watched
 * happen: the platform validates no parameters, and a target is free to answer
 * 0 while ignoring what it was sent -- Maps does exactly that with
 * ViewSearchPageLocal. So every candidate row has to be called once before it
 * is written down, and this is what calls it:
 *
 *   hdc shell aa start -a EntryAbility -b com.vera.probe.dyn \
 *     --ps probeTarget com.huawei.hmos.settings/phone_settings/DefaultIntentBackgroundUiAbility/SetSettingSwitch \
 *     --ps probeParams '{"itemName":"bluetooth","switchFlag":"0"}' \
 *     --ps probeMode background
 *
 *   hdc shell hilog -x | grep VERA-PROBE
 *
 * This is development tooling that happens to live in the app, because the app
 * is the thing already signed to call intents at all. It is reachable only from
 * a launch parameter, which means only from a shell on the device: a generated
 * program cannot name an intent this way, and nothing in std/intent routes
 * here. The catalogue remains the only way a program reaches the platform.
 */

import { insightIntentDriver, insightIntent } from '@kit.AbilityKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { BusinessError } from '@kit.BasicServicesKit'

const DOMAIN = 0x0000

/**
 * bundle/module/ability/IntentName, in the order the device's own registry key
 * writes them, so a row can be copied out of insight_intent.db and pasted here.
 */
class ProbeTarget {
  bundle: string = ''
  moduleName: string = ''
  ability: string = ''
  intentName: string = ''
}

function parseTarget(text: string): ProbeTarget | null {
  let parts = text.split('/')
  if (parts.length !== 4) { return null }
  let target = new ProbeTarget()
  target.bundle = parts[0].trim()
  target.moduleName = parts[1].trim()
  target.ability = parts[2].trim()
  target.intentName = parts[3].trim()
  if (target.bundle.length === 0 || target.intentName.length === 0) { return null }
  return target
}

/**
 * The payload, as JSON, so a probe can send exactly what a catalogue row would
 * send -- including a nested object, which is how StartNavigate takes a place.
 */
function parseParams(text: string): Record<string, Object> {
  if (text.length === 0) { return {} }
  return JSON.parse(text) as Record<string, Object>
}

export async function runProbe(targetText: string, paramsText: string, modeText: string): Promise<void> {
  let target = parseTarget(targetText)
  if (target === null) {
    hilog.error(DOMAIN, 'VERA', 'VERA-PROBE bad target "' + targetText +
      '", expected bundle/module/ability/IntentName')
    return
  }
  let params: Record<string, Object>
  try {
    params = parseParams(paramsText)
  } catch (e) {
    hilog.error(DOMAIN, 'VERA', 'VERA-PROBE params are not JSON: ' + (e as Error).message)
    return
  }
  let background = modeText !== 'foreground'
  let param: insightIntentDriver.ExecuteParam = {
    bundleName: target!.bundle,
    moduleName: target!.moduleName,
    abilityName: target!.ability,
    insightIntentName: target!.intentName,
    insightIntentParam: params,
    executeMode: background
      ? insightIntent.ExecuteMode.UI_ABILITY_BACKGROUND
      : insightIntent.ExecuteMode.UI_ABILITY_FOREGROUND
  }
  hilog.info(DOMAIN, 'VERA', 'VERA-PROBE call ' + targetText + ' mode=' +
    (background ? 'background' : 'foreground') + ' params=' + JSON.stringify(params))
  let started = Date.now()
  try {
    let result: insightIntent.ExecuteResult = await insightIntentDriver.execute(param)
    // The result payload is the whole point for a Get-style intent, and for
    // every other kind it is the only thing the target says beyond a number.
    let payload = result.result === undefined ? '' : JSON.stringify(result.result)
    hilog.info(DOMAIN, 'VERA', 'VERA-PROBE done ' + target!.intentName +
      ' code=' + result.code.toString() +
      ' ms=' + (Date.now() - started).toString() +
      (payload.length > 0 ? ' result=' + payload : ' result=(none)'))
  } catch (e) {
    let err = e as BusinessError
    hilog.error(DOMAIN, 'VERA', 'VERA-PROBE failed ' + target!.intentName +
      ' error=' + err.code.toString() + ': ' + err.message)
  }
}
