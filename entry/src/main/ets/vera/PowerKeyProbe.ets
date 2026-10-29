import { hilog } from '@kit.PerformanceAnalysisKit'
import { inputConsumer, KeyCode } from '@kit.InputKit'
import { BusinessError } from '@kit.BasicServicesKit'

const DOMAIN = 0x0000
const TAG = 'VERA-PWR'

let started = false

function subscribe(down: boolean): void {
  let options: inputConsumer.KeyOptions = {
    preKeys: [],
    finalKey: KeyCode.KEYCODE_POWER,
    isFinalKeyDown: down,
    finalKeyDownDuration: 0
  }
  try {
    inputConsumer.on('key', options, (_: inputConsumer.KeyOptions) => {
      hilog.info(DOMAIN, TAG, 'power %{public}s t=%{public}d', down ? 'down' : 'up', Date.now())
    })
    hilog.info(DOMAIN, TAG, 'subscribed power %{public}s', down ? 'down' : 'up')
  } catch (e) {
    let err = e as BusinessError
    hilog.error(DOMAIN, TAG, 'subscribe %{public}s failed %{public}d %{public}s',
      down ? 'down' : 'up', err.code, err.message)
  }
}

/**
 * Logs every press and release of the power key, to find out whether a system
 * hotkey subscription (inputConsumer.on('key')) reaches this app with the
 * screen off and the app in the background. inputMonitor.onKeyPressed would be
 * the natural call but it exists only in static ArkTS 1.2.
 *
 * Read it with:  hdc hilog | grep VERA-PWR
 */
export function startPowerKeyProbe(): void {
  if (started) { return }
  started = true
  subscribe(true)
  subscribe(false)
}
