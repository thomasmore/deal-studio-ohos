/**
 * USB network: a VPN that sends the whole phone's traffic over the USB cable
 * and out through the computer's network.
 *
 * The packets go to 127.0.0.1:USB_NET_PORT, which `./usb-net.sh` on the
 * computer maps (`hdc rport`) to the gnirehtet relay running there; the relay
 * opens the real connections. The copying is native (napi_usbnet.cpp) and
 * reconnects by itself, so the VPN can stay up while the script is restarted
 * or the cable is replugged.
 *
 * Started and stopped from Generate > Advanced (UsbNet.ets). This runs in its
 * own process; it reports through a file the page reads and checks the
 * person's latest wish (usbNetWanted), stopping itself when it is 'off' -- so a
 * stop that arrives before the tun is up, or while the consent dialog is open,
 * still ends with no VPN.
 */

import { VpnExtensionAbility, vpnExtension } from '@kit.NetworkKit'
import { Want } from '@kit.AbilityKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import usbnet from 'libusbnet.so'
import { USB_NET_PORT, usbNetWanted, writeUsbNetStatus, stopUsbNetSelf } from '../vera/UsbNet'

const TAG: string = 'VERA-USBNET'
/** Traffic counters are written at most this often; a change of state is written at once. */
const COUNTER_WRITE_MS: number = 10000

export default class UsbNetAbility extends VpnExtensionAbility {
  private connection: vpnExtension.VpnConnection | null = null
  private timer: number = -1
  private destroyed: boolean = false
  /** Set when a failure has been reported, so onDestroy does not overwrite it with 'off'. */
  private failed: boolean = false
  private lastState: string = ''
  private lastStatus: string = ''
  private lastWriteAt: number = 0

  onCreate(want: Want): void {
    hilog.info(0x0000, TAG, 'onCreate')
    this.open()
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG, 'onDestroy')
    this.destroyed = true
    this.closeVpn()
    if (!this.failed) { writeUsbNetStatus(this.context.filesDir, 'off') }
  }

  private closeVpn(): void {
    if (this.timer >= 0) { clearInterval(this.timer) }
    this.timer = -1
    try { usbnet.usbnetStop() } catch (_e) {}
    let conn = this.connection
    this.connection = null
    if (conn !== null) {
      conn.destroy().catch((e: Error) => { hilog.warn(0x0000, TAG, 'destroy failed: ' + e.message) })
    }
  }

  private stopSelf(): void {
    if (this.destroyed) { return }
    stopUsbNetSelf().catch((e: Error) => { hilog.warn(0x0000, TAG, 'stop self failed: ' + e.message) })
  }

  private async open(): Promise<void> {
    let dir = this.context.filesDir
    if (!usbNetWanted(dir)) {
      this.stopSelf()
      return
    }
    try {
      let conn = vpnExtension.createVpnConnection(this.context)
      this.connection = conn
      let config: vpnExtension.VpnConfig = {
        addresses: [{ address: { address: '10.0.0.2', family: 1 }, prefixLength: 32 }],
        // No routes: netmanager then adds the IPv4 default route through the
        // tun itself. A route with a gateway the /32 address cannot reach is
        // refused, and the VPN comes up with nothing routed into it.
        dnsAddresses: ['8.8.8.8'],
        mtu: 1500,
        isIPv4Accepted: true,
        isIPv6Accepted: false
      }
      let fd = await conn.create(config)
      hilog.info(0x0000, TAG, 'tun fd ' + fd.toString())
      // Destroyed or switched off while create() was pending: nothing may start now.
      if (this.destroyed || !usbNetWanted(dir)) {
        this.closeVpn()
        this.stopSelf()
        return
      }
      usbnet.usbnetStart(fd, USB_NET_PORT)
      this.report()
      this.timer = setInterval(() => { this.tick() }, 1000)
    } catch (e) {
      let msg = (e as Error).message
      hilog.error(0x0000, TAG, 'VPN failed: ' + msg)
      this.failed = true
      writeUsbNetStatus(dir, 'failed: ' + msg)
      this.closeVpn()
      this.stopSelf()
    }
  }

  private tick(): void {
    if (!usbNetWanted(this.context.filesDir)) {
      this.closeVpn()
      this.stopSelf()
      return
    }
    this.report()
  }

  /** Writes the native status when its state changes, and the counters at most every COUNTER_WRITE_MS. */
  private report(): void {
    let status = usbnet.usbnetStatus()
    if (status === this.lastStatus) { return }
    let comma = status.indexOf(',')
    let state = comma >= 0 ? status.substring(0, comma) : status
    let now = Date.now()
    if (state === this.lastState && now - this.lastWriteAt < COUNTER_WRITE_MS) { return }
    writeUsbNetStatus(this.context.filesDir, status)
    this.lastState = state
    this.lastStatus = status
    this.lastWriteAt = now
  }
}
