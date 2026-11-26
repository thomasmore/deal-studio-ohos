/**
 * What find_sdk_function says about the targets whose runtime adapter
 * (VeraSdkBackend) takes something other than the native signature in the
 * index -- strings in place of an ArrayBuffer or an enum, extra knobs the
 * native call does not have. The native signature alone sent the model off on
 * a lookup round for TorchMode's values it then guessed, and left it unsure
 * whether the sample rate a prompt asks for can be passed at all.
 *
 * CalendarKit has its own, larger set in VeraCalendarSdk.
 */

import { CalendarSdkContract, calendarSdkContract } from './VeraCalendarSdk'
import { notifySdkContract } from './VeraNotifySdk'

const AUDIO_WRITE_PARAMS: string = 'buffer?: comma-separated 16-bit samples (-32768..32767) as one string, sampleRate?: 8000|16000|44100|48000 (default 48000), frequencyHz?: number, durationMs?: number, volume?: 0-1 (default 0.3)'

export function adapterSdkContract(target: string): CalendarSdkContract | undefined {
  switch (target) {
    case 'CameraKit.PhotoOutput.capture':
      return new CalendarSdkContract('facing?: back|front (default back)', 'string',
        'Opens the system camera for the person to take one photo, then answers the photo as a file URI (file://...) that ui.Image can show. No setup call is needed: call it once per photo, then draw the answer with ui.Image. Cancelling answers an error; show it if you have a slot for one.',
        'sdk.call("CameraKit.PhotoOutput.capture", ["facing", "back"], "onPhoto")')
    case 'CameraKit.CameraManager.setTorchMode':
      return new CalendarSdkContract('mode: OFF|ON|AUTO|ALWAYS_OPEN (0-3 also accepted)', 'string',
        'Turns the flashlight on or off; answers ok, or an error such as "torch not supported on this device".',
        'sdk.call("CameraKit.CameraManager.setTorchMode", ["mode", "ON"], "onTorch")')
    case 'AudioKit.AudioRenderer.write':
      return new CalendarSdkContract(AUDIO_WRITE_PARAMS, 'string',
        'Plays sound: either buffer, samples computed by the program, at sampleRate; or frequencyHz with durationMs, a sine tone the host makes. Starts the renderer itself, so no start call is needed. Writes play one after another. Answers with the number of bytes queued, as soon as they are queued -- not when the sound has finished.',
        'sdk.call("AudioKit.AudioRenderer.write", ["buffer", samples, "sampleRate", "8000"], "onAudio")')
    case 'AudioKit.AudioRenderer.start':
      return new CalendarSdkContract('', 'string',
        'Starts the renderer at 48000 Hz; answers ok. Not needed before write, which starts it at its own sampleRate.',
        'sdk.call("AudioKit.AudioRenderer.start", [], "onAudio")')
    case 'AudioKit.AudioRenderer.stop':
      return new CalendarSdkContract('', 'string', 'Stops playback, dropping what is still queued; answers ok.',
        'sdk.call("AudioKit.AudioRenderer.stop", [], "onAudio")')
    case 'SensorServiceKit.vibrator.vibrate':
      return new CalendarSdkContract('duration: milliseconds, effectId?: preset effect name, count?: number', 'string',
        'Vibrates for duration milliseconds, or plays a preset effect; answers ok.',
        'sdk.call("SensorServiceKit.vibrator.vibrate", ["duration", "800"], "onAnswer")')
    default:
      return undefined
  }
}

/** The contract find_sdk_function shows for a target, if its adapter has one. */
export function sdkContract(target: string): CalendarSdkContract | undefined {
  let calendar = calendarSdkContract(target)
  if (calendar !== undefined) { return calendar }
  let notify = notifySdkContract(target)
  if (notify !== undefined) { return new CalendarSdkContract(notify.params, notify.returns, notify.description, notify.example) }
  return adapterSdkContract(target)
}
