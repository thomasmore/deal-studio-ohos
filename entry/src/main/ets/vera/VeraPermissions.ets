/**
 * What the host needs from the platform before a generated program can reach
 * it: the ability context, and the user_grant permissions that cannot come from
 * the signature. Asked at startup rather than at the first call, because a
 * dialog appearing in the middle of a generated program's handler would arrive
 * with no explanation of what asked for it.
 */

import { abilityAccessCtrl, Permissions, common } from '@kit.AbilityKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { BusinessError } from '@kit.BasicServicesKit'

const DOMAIN = 0x0000

/**
 * The ability context. Needed to ask for the permissions, and to launch another
 * app from VeraIntents and to reach the SDK from VeraSdkBackend. EntryAbility
 * fills it in; until it does, a call reports that rather than throwing.
 */
export class AbilityContext {
  static value: common.UIAbilityContext | null = null
}

/** READ_CALENDAR and WRITE_CALENDAR are user_grant, so they have to be asked for. */
export async function requestCalendarPermissions(context: common.UIAbilityContext): Promise<void> {
  AbilityContext.value = context
  let permissions: Permissions[] = ['ohos.permission.READ_CALENDAR', 'ohos.permission.WRITE_CALENDAR']
  try {
    await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, permissions)
    hilog.info(DOMAIN, 'VERA', 'VERA-CALENDAR permissions requested')
  } catch (e) {
    let err = e as BusinessError
    hilog.error(DOMAIN, 'VERA', 'VERA-CALENDAR permission request failed ' + err.code.toString())
  }
}

export async function requestMicrophonePermission(context: common.UIAbilityContext): Promise<void> {
  AbilityContext.value = context
  let permissions: Permissions[] = ['ohos.permission.MICROPHONE']
  try {
    let result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, permissions)
    if (result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
      hilog.info(DOMAIN, 'VERA', 'VERA-AUDIO microphone permission granted')
    } else {
      hilog.info(DOMAIN, 'VERA', 'VERA-AUDIO microphone permission declined')
    }
  } catch (e) {
    let err = e as BusinessError
    hilog.error(DOMAIN, 'VERA', 'VERA-AUDIO permission request failed ' + err.code.toString())
  }
}
