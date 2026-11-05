/**
 * USB network: what the page and the VPN (UsbNetAbility) share. The page starts
 * and stops the VPN that sends the phone's traffic through the computer and
 * shows what it reports.
 *
 * Two small files in the app's files dir carry the state between the page and
 * the VPN, which runs in its own process:
 *
 *   usbnet-want.txt    'on' / 'off': what the person last asked for. The VPN
 *                      checks it once its tun is up and while it runs, so a
 *                      stop that raced a start (or the consent dialog) still
 *                      ends with the VPN gone.
 *   usbnet-status.txt  '<ms>\n<status>': what the VPN last said, written only
 *                      when it changes. Whether the VPN is really up is asked
 *                      of the system (vpnIsUp), not read from the file's age.
 *
 * On the computer `./usb-net.sh` runs the relay and maps USB_NET_PORT to it.
 */

import { vpnExtension, connection } from '@kit.NetworkKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { Want } from '@kit.AbilityKit'
import { process } from '@kit.ArkTS'
import { readText, writeText } from './SettingsStore'

/**
 * The port on the phone that `hdc rport` maps to the relay. Not gnirehtet's
 * 31416: the phone reserves 31150-31950 and hdc cannot listen there.
 */
export const USB_NET_PORT: number = 28416
const BUNDLE: string = 'com.vera.probe.dyn'
const ABILITY: string = 'UsbNetAbility'
/** How long a start may wait on the person's answer to the VPN dialog. */
const START_GRACE_MS: number = 120000
/** How long a failure stays on screen before the switch just reads 'off'. */
const FAILED_SHOWN_MS: number = 60000

function wantPath(filesDir: string): string { return filesDir + '/usbnet-want.txt' }

function statusPath(filesDir: string): string { return filesDir + '/usbnet-status.txt' }

export function usbNetWanted(filesDir: string): boolean {
  return readText(wantPath(filesDir)).trim() === 'on'
}

function setWanted(filesDir: string, on: boolean): void {
  writeAtomic(wantPath(filesDir), on ? 'on' : 'off')
}

/** Written to a temporary file and renamed, so a reader never sees it half written. */
function writeAtomic(path: string, text: string): void {
  let tmp = path + '.tmp'
  try {
    writeText(tmp, text)
    fs.renameSync(tmp, path)
  } catch (_e) {}
}

export function writeUsbNetStatus(filesDir: string, status: string): void {
  writeAtomic(statusPath(filesDir), Date.now().toString() + '\n' + status)
}

/** Whether the system has a VPN network up (ours is the only one this app starts). */
function vpnIsUp(): boolean {
  try {
    let nets = connection.getAllNetsSync()
    for (let i = 0; i < nets.length; i++) {
      let caps = connection.getNetCapabilitiesSync(nets[i])
      if (caps.bearerTypes.indexOf(connection.NetBearType.BEARER_VPN) >= 0) { return true }
    }
  } catch (_e) {}
  return false
}

/**
 * What the switch shows: 'off', 'starting', 'waiting for the computer ...',
 * 'connected, ...' or 'failed: ...'.
 */
export function readUsbNetStatus(filesDir: string): string {
  let text = readText(statusPath(filesDir))
  let nl = text.indexOf('\n')
  if (nl < 0) { return 'off' }
  let at = Number(text.substring(0, nl))
  let age = isNaN(at) ? Number.MAX_VALUE : Date.now() - at
  let status = text.substring(nl + 1)
  if (status.startsWith('waiting') || status.startsWith('connected')) {
    // A status left behind by a VPN that was killed (an app update does that) is not believed.
    return vpnIsUp() ? status : 'off'
  }
  if (status === 'starting') {
    return vpnIsUp() || age < START_GRACE_MS ? status : 'off'
  }
  if (status.startsWith('failed')) {
    return age < FAILED_SHOWN_MS ? status : 'off'
  }
  return 'off'
}

/** Whether the switch is on: the VPN is starting, waiting for the computer or connected. */
export function usbNetIsOn(status: string): boolean {
  return status === 'starting' || status.startsWith('waiting') || status.startsWith('connected')
}

function want(): Want {
  let w: Want = { bundleName: BUNDLE, abilityName: ABILITY }
  return w
}

/**
 * The first time, the system asks the person to allow the VPN.
 *
 * callingUid/callingPid: this app is system-signed, and netmanager takes a
 * system caller's identity from these two parameters (they are meant for its
 * own consent dialog), so without them every start after the first fails with
 * 2200003 "Failed to get caller uid or pid".
 */
export async function startUsbNet(filesDir: string): Promise<void> {
  setWanted(filesDir, true)
  writeUsbNetStatus(filesDir, 'starting')
  let w = want()
  let params: Record<string, Object> = {}
  params['callingUid'] = process.uid
  params['callingPid'] = process.pid
  w.parameters = params
  try {
    await vpnExtension.startVpnExtensionAbility(w)
  } catch (e) {
    setWanted(filesDir, false)
    writeUsbNetStatus(filesDir, 'failed: ' + (e as Error).message)
    throw e as Error
  }
}

/**
 * Stops the VPN. If it is not running yet (the consent dialog is still open),
 * the stop fails here, and the VPN stops itself once it sees it is not wanted.
 */
export async function stopUsbNet(filesDir: string): Promise<void> {
  setWanted(filesDir, false)
  try {
    await vpnExtension.stopVpnExtensionAbility(want())
  } catch (_e) {}
  writeUsbNetStatus(filesDir, 'off')
}

/** The VPN stopping itself: after a failure, or when it finds it is no longer wanted. */
export function stopUsbNetSelf(): Promise<void> {
  return vpnExtension.stopVpnExtensionAbility(want())
}
