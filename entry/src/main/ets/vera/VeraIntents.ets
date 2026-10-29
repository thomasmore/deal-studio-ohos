/**
 * The only place in the project that calls the platform's intent framework.
 *
 * Nothing here knows the name of any intent: the target and the parameters
 * arrive from sdk.call exactly as the program wrote them.
 *
 * insightIntentDriver is a system API, gated twice over: the provision profile
 * must carry "app-feature": "hos_system_app" (otherwise every call is 202) and
 * ohos.permission.EXECUTE_INSIGHT_INTENT must be granted through the profile's
 * acls.allowed-acls (otherwise 201). Both are signing, not code, so the
 * failures are reported as they arrive rather than hidden -- the status string
 * is what the generated program shows its user.
 */

import { insightIntentDriver, insightIntent, Want } from '@kit.AbilityKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { AbilityContext } from './VeraPermissions'
import { unreachableTarget } from './VeraIntentCatalog'

const DOMAIN = 0x0000

/**
 * One key of the payload, where a dotted name means one level of nesting.
 */
function writeParam(params: Record<string, Object>, platformName: string, value: Object): void {
  let dot = platformName.indexOf('.')
  if (dot < 0) {
    params[platformName] = value
    return
  }
  // One level is all a payload ever needs here, so this does not recurse.
  let group = platformName.substring(0, dot)
  let leaf = platformName.substring(dot + 1)
  let nested = params[group] as Record<string, Object> | undefined
  if (nested === undefined) {
    nested = {} as Record<string, Object>
    params[group] = nested as Object
  }
  nested![leaf] = value
}

/**
 * An intent target named by the program, as sdk.call passes it on.
 *
 * Nothing is translated: the parameter names and values go to the platform as
 * the program wrote them. What this function does is the part that is always
 * true: it refuses a malformed target, it reports what the platform said rather
 * than interpreting it, and it writes the whole call into the log so there is a
 * record of what a generated program asked the phone to do.
 *
 * The answer is the target's own result, as JSON.
 */
export async function runRawIntent(target: string, values: Map<string, string>, mode: string): Promise<string> {
  // An app known to accept and then ignore calls from here: say so, rather than pass on its empty 'ok'.
  if (unreachableTarget(target)) {
    hilog.info(DOMAIN, 'VERA', 'VERA-INTENT-RAW ' + target + ' refused: app does not act on calls from this app')
    return 'error 801: ' + target.split('/')[0].trim() + ' does not act on requests from this app on this phone'
  }
  let parts = target.split('/')
  // Three parts, no intent name: nothing to tell the target, so just open it.
  if (parts.length === 3) { return launchRawTarget(parts[0].trim(), parts[2].trim()) }
  if (parts.length !== 4) {
    return 'error: target must be bundle/module/ability/IntentName, or bundle/module/ability to just launch it'
  }
  // The program wrote names and values; the object is built here, so a line
  // break or a quote in someone's shopping list cannot break the payload.
  let params: Record<string, Object> = {}
  values.forEach((value: string, key: string) => { writeParam(params, key, value as Object) })
  let param: insightIntentDriver.ExecuteParam = {
    bundleName: parts[0].trim(),
    moduleName: parts[1].trim(),
    abilityName: parts[2].trim(),
    insightIntentName: parts[3].trim(),
    insightIntentParam: params,
    executeMode: mode === 'foreground'
      ? insightIntent.ExecuteMode.UI_ABILITY_FOREGROUND
      : insightIntent.ExecuteMode.UI_ABILITY_BACKGROUND
  }
  hilog.info(DOMAIN, 'VERA', 'VERA-INTENT-RAW ' + target + ' mode=' + mode +
    ' params=' + JSON.stringify(params))
  try {
    let result: insightIntent.ExecuteResult = await insightIntentDriver.execute(param)
    let payload = result.result === undefined || result.result === null
      ? '' : JSON.stringify(result.result)
    hilog.info(DOMAIN, 'VERA', 'VERA-INTENT-RAW ' + target + ' code=' +
      result.code.toString() + ' result=' + (payload.length > 0 ? payload : '(none)'))
    if (result.code !== 0) { return 'declined code=' + result.code.toString() }
    // A zero is the target saying it accepted the call, and nothing more: on
    // this phone the clock answers 0 to CreateTimer and creates no timer. The
    // program is told 'ok' and should not claim more than that either.
    return payload.length > 0 ? payload : 'ok'
  } catch (e) {
    let err = e as BusinessError
    hilog.error(DOMAIN, 'VERA', 'VERA-INTENT-RAW ' + target + ' failed ' +
      err.code.toString() + ': ' + err.message)
    return 'error ' + err.code.toString() + ': ' + err.message
  }
}

/**
 * Opens the target's ability directly, for rows that have nothing to tell it.
 *
 * This is ordinary public API -- no intent framework, no system signature -- and
 * it is the right tool when the whole request is "show me that app". Shared by
 * an sdk.call three-part target (via runRawIntent).
 */
async function launchRawTarget(bundle: string, ability: string): Promise<string> {
  let context = AbilityContext.value
  if (context === null) { return 'error: no ability context yet' }
  let want: Want = { bundleName: bundle, abilityName: ability }
  hilog.info(DOMAIN, 'VERA', 'VERA-LAUNCH ' + bundle + '/' + ability)
  try {
    await context.startAbility(want)
    return 'ok'
  } catch (e) {
    let err = e as BusinessError
    hilog.error(DOMAIN, 'VERA', 'VERA-LAUNCH failed ' + err.code.toString() + ': ' + err.message)
    return 'error ' + err.code.toString() + ': ' + err.message
  }
}
