import { Want } from '@kit.AbilityKit'

// Who started this ability?
//
// The ability manager writes the caller's identity into want.parameters on every
// start and replaces whatever a caller put under these keys (see the Want reference,
// "keys assigned by the system"). An app caller therefore always carries its bundle
// name, app id and uid; a native caller such as the shell's `aa` tool has none of
// them (it has callerNativeName instead).
const CALLER_BUNDLE_NAME = 'ohos.aafwk.param.callerBundleName'
const CALLER_APP_ID = 'ohos.aafwk.param.callerAppId'
const CALLER_NATIVE_NAME = 'ohos.aafwk.param.callerNativeName'
const CALLER_UID = 'ohos.aafwk.param.callerUid'

// Application uids start at 10000 (20000000 and up for users other than 0);
// root, shell and the system services are below.
const FIRST_APP_UID = 10000

// The launch parameters meant for development, given as
// `hdc shell aa start -a EntryAbility -b com.vera.probe.dyn --ps <name> <value>`:
// keys, the server address, probes, benchmarks and behaviour flags. Only the names
// are listed here, to report an ignored attempt; which parameters are acted on is
// decided by EntryAbility.extractDevParameters, which runs none of them for an app
// caller. The navigation parameters (projectId, launchMode, veraRun) are not listed:
// the launcher, the widget and shortcuts send those.
export const DEV_PARAMETER_NAMES: string[] = [
  'deepseekKey', 'typesafeKey', 'exaKey', 'reasoningEffort', 'veraServer',
  'probeTarget', 'probeParams', 'probeMode', 'probeSdkTarget', 'probeSdkParams',
  'probeSdkSearch', 'veraBenchmark', 'veraSdkEval', 'veraUiEval', 'veraUiAb',
  'veraCompose', 'veraComposePlan', 'veraCustom', 'veraAlign', 'veraWhole',
  'veraTemplateSelect', 'worldFloorGain'
]

function textParam(params: Record<string, Object>, key: string): string {
  const value = params[key]
  return typeof value === 'string' ? value : ''
}

function callerUid(params: Record<string, Object>): number {
  const value = params[CALLER_UID]
  if (typeof value === 'number') {
    return value
  }
  if (typeof value === 'string' && value.length > 0) {
    const parsed = Number(value)
    return Number.isFinite(parsed) ? parsed : -1
  }
  return -1
}

/**
 * True when an app (any app, this one included) started the ability. A start with no
 * app identity comes from a native process, for example `hdc shell aa start`.
 */
export function startedByApp(want: Want): boolean {
  if (want.parameters === null || want.parameters === undefined) {
    return false
  }
  const params = want.parameters as Record<string, Object>
  if (textParam(params, CALLER_BUNDLE_NAME).length > 0) {
    return true
  }
  if (textParam(params, CALLER_APP_ID).length > 0) {
    return true
  }
  return callerUid(params) >= FIRST_APP_UID
}

/** The development parameters present in the want (names only, never values). */
export function presentDevParameters(want: Want): string[] {
  const names: string[] = []
  if (want.parameters === null || want.parameters === undefined) {
    return names
  }
  const params = want.parameters as Record<string, Object>
  for (const name of DEV_PARAMETER_NAMES) {
    if (params[name] !== undefined && params[name] !== null) {
      names.push(name)
    }
  }
  return names
}

/** One log line about the caller; contains no secrets. */
export function describeCaller(want: Want): string {
  if (want.parameters === null || want.parameters === undefined) {
    return 'no parameters'
  }
  const params = want.parameters as Record<string, Object>
  const bundle = textParam(params, CALLER_BUNDLE_NAME)
  const native = textParam(params, CALLER_NATIVE_NAME)
  const uid = callerUid(params)
  return 'bundle=' + (bundle.length > 0 ? bundle : '-') +
    ' native=' + (native.length > 0 ? native : '-') +
    ' uid=' + (uid >= 0 ? uid.toString() : '-')
}
