/**
 * A small, curated set of real adapters for sdk.call's sdk-style targets --
 * the same relationship VeraIntentCatalog has to the raw intent registry.
 * This is deliberately not "the rest of interface_sdk-js": it is the
 * handful of rows someone has actually read the real signature of, written a
 * binding for, and probed on a phone. Everything else sdk.call can address
 * (the full closed set VeraSdkIndex.isValidSdkTarget checks a target
 * against) still compiles -- it answers with the same "not implemented yet"
 * stub it always has, until a row is added here too.
 *
 * Why a curated table rather than generic reflection dispatch: ArkTS gives
 * no safe way to resolve a module and call a named export by a runtime
 * string the way dynamic JavaScript could, and even if it did, that would
 * only solve half the problem. sdk.call's own parameters are plain name/
 * value strings (the language has no other way to write a call argument),
 * while an arbitrary interface_sdk-js function takes enums, numbers,
 * booleans and nested objects -- there is no generic rule for turning
 * ["mode", "0"] into the right typed argument for a function nobody has
 * looked at. Only a person who has read that one function's actual
 * signature can bridge that gap, which is exactly the process
 * docs/intents-design.md section 7 already describes for adding a row to
 * VeraIntentCatalog -- this is the same idea, for the sdk surface.
 *
 * Adding a row: read the real signature in interface_sdk-js, write a
 * function that turns `params` into the right typed call and its answer
 * back into one string, and add it below keyed by the exact
 * "Kit.module.name" target VeraSdkIndex uses. Probe it on a phone before
 * trusting it -- the same rule every other row in this codebase follows.
 */

import {
  storageStatistics,
  fileIo as fs,
  cloudSync,
  cloudSyncManager,
  Environment,
  fileUri,
  hash,
  keyManager,
  securityLabel,
  statfs
} from '@kit.CoreFileKit'
import { AbilityContext } from './VeraPermissions'
import { calendarSdkTargets, runCalendarSdkAdapter } from './VeraCalendarSdk'
import { LIVE_TARGET, liveFetch } from './VeraLive'
import { camera } from '@kit.CameraKit'
import { audio } from '@kit.AudioKit'
import {
  abilityAccessCtrl,
  abilityManager,
  appManager,
  appRecovery,
  application,
  autoStartupManager,
  childProcessManager,
  dataUriUtils,
  hyperSnapManager,
  quickFixManager,
  wantAgent,
  startupManager,
  uriPermissionManager,
  bundleManager,
  defaultAppManager,
  distributedBundleManager,
  freeInstall,
  overlay,
  shortcutManager
} from '@kit.AbilityKit'
import {
  partnerAgent,
  ranging,
  access,
  connection as bluetoothConnection,
  socket,
  nfcController,
  wifiManager
} from '@kit.ConnectivityKit'
import {
  PiPWindow,
  performanceMonitor,
  display,
  promptAction,
  screen,
  window,
  floatView,
  floatingBall
} from '@kit.ArkUI'
import { accessibility } from '@kit.AccessibilityKit'
import {
  osAccount,
  batteryInfo,
  batteryStats,
  brightness,
  serial,
  commonEventManager,
  configPolicy,
  customConfig,
  emitter,
  power,
  cacheDownload,
  screenLock,
  selectionManager,
  settings,
  systemCapability,
  systemDateTime,
  systemParameterEnhance,
  usbManager,
  serialManager,
  wallpaper,
  zlib
} from '@kit.BasicServicesKit'
import { formHost, formProvider } from '@kit.FormKit'
import { buffer, fastbuffer, process, taskpool, util } from '@kit.ArkTS'
import { distributedDataObject, relationalStore, uniformTypeDescriptor } from '@kit.ArkData'
import { mechanicManager } from '@kit.MechanicKit'
import { abilityConnectionManager } from '@kit.DistributedServiceKit'
import { dlpPermission } from '@kit.DataProtectionKit'
import { adminManager, applicationManager, browser } from '@kit.MDMKit'
import { geoLocationManager } from '@kit.LocationKit'
import {
  hiTraceChain,
  hiTraceMeter,
  hichecker,
  hidebug,
  hilog,
  hiAppEvent,
  hiRetrieval,
  jsLeakWatcher
} from '@kit.PerformanceAnalysisKit'
import { i18n } from '@kit.LocalizationKit'
import { identifier } from '@kit.AdsKit'
import { inputMethod } from '@kit.IMEKit'
import { avSession } from '@kit.AVSessionKit'
import { drm } from '@kit.DrmKit'
import { media } from '@kit.MediaKit'
import { videoProcessingEngine } from '@kit.ImageKit'
import { metadataBinding } from '@kit.MultimodalAwarenessKit'
import { inputDevice, pointer, shortKey } from '@kit.InputKit'
import { connection as netConnection, ethernet, networkSecurity, statistics } from '@kit.NetworkKit'
import { notificationManager, notificationSubscribe } from '@kit.NotificationKit'
import {
  reminderAgentManager,
  backgroundProcessManager,
  backgroundTaskManager,
  workScheduler
} from '@kit.BackgroundTasksKit'
import { certificateManagerDialog } from '@kit.DeviceCertificateKit'
import { huksExternalCrypto } from '@kit.UniversalKeystoreKit'
import { sensor, vibrator } from '@kit.SensorServiceKit'
import { call, data, eSIM, radio, sim, sms } from '@kit.TelephonyKit'

/** One row's real implementation: sdk.call's parameters in, its answer string out. */
export type SdkAdapter = (params: Map<string, string>) => Promise<string>

// Not @ohos.multimedia.camera's own module -- CameraManager is a class, not a
// namespace, so its methods need an instance, which is exactly what every
// other row here avoids needing (see the header comment on ADAPTERS below).
// This is the one hand-written exception: setTorchMode is common enough a
// request (it's the vera-skill.txt example, in fact) that it earns the extra
// code a class-based API costs. Not placed in the "generated helpers" block
// below because tools/generate-sdk-backend.py rewrites that block wholesale
// on every run and would delete this along with it.
// An enum value as a program writes it: "ON", "TorchMode.ON", "TORCH_MODE_ON"
// and "ToneType.TONE_TYPE_DIAL_1" all come back from the model, depending on
// the run. Keeps the member name: upper case, nothing before the last dot.
function enumMemberName(raw: string): string {
  let v = raw.trim().toUpperCase()
  let dot = v.lastIndexOf('.')
  return dot >= 0 ? v.substring(dot + 1) : v
}

// camera.TorchMode by number or by the name the SDK documents; -1 for anything
// else. A program writes "ON" as readily as "1", and parseInt("ON") is NaN.
function torchModeFrom(raw: string | undefined): number {
  if (raw === undefined) { return 0 }
  let v = enumMemberName(raw)
  if (v.startsWith('TORCH_MODE_')) { v = v.substring(11) }
  if (v === 'OFF') { return 0 }
  if (v === 'ON') { return 1 }
  if (v === 'AUTO') { return 2 }
  if (v === 'ALWAYS_OPEN') { return 3 }
  let n = Number.parseInt(v, 10)
  return Number.isNaN(n) || n < 0 || n > 3 ? -1 : n
}

let cameraManagerInstance: camera.CameraManager | null = null
function cameraManagerOnce(): camera.CameraManager | null {
  if (cameraManagerInstance !== null) { return cameraManagerInstance }
  let context = AbilityContext.value
  if (context === null) { return null }
  try {
    cameraManagerInstance = camera.getCameraManager(context)
    return cameraManagerInstance
  } catch (e) {
    throw e as Error
  }
}

let audioManagerInstance: audio.AudioManager | null = null
function audioManagerOnce(): audio.AudioManager {
  if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
    if (audioManagerInstance === null) {
      audioManagerInstance = audio.getAudioManager()
    }
    return audioManagerInstance
  }
  throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
}

function audioVolumeManager(): audio.AudioVolumeManager {
  if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
    if (canIUse('SystemCapability.Multimedia.Audio.Volume')) {
      return audioManagerOnce().getVolumeManager()
    }
    throw new Error('SystemCapability.Multimedia.Audio.Volume is not supported')
  }
  throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
}

function audioVolumeGroupManager(): audio.AudioVolumeGroupManager {
  if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
    if (canIUse('SystemCapability.Multimedia.Audio.Volume')) {
      try {
        return audioVolumeManager().getVolumeGroupManagerSync(audio.DEFAULT_VOLUME_GROUP_ID)
      } catch (e) {
        throw e as Error
      }
    }
    throw new Error('SystemCapability.Multimedia.Audio.Volume is not supported')
  }
  throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
}

function streamUsageForVolumeType(volumeType: number): audio.StreamUsage {
  if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
    if (canIUse('SystemCapability.Multimedia.Audio.Volume')) {
      switch (volumeType) {
        case audio.AudioVolumeType.VOICE_CALL: return audio.StreamUsage.STREAM_USAGE_VOICE_COMMUNICATION
        case audio.AudioVolumeType.RINGTONE: return audio.StreamUsage.STREAM_USAGE_RINGTONE
        case audio.AudioVolumeType.MEDIA: return audio.StreamUsage.STREAM_USAGE_MUSIC
        case audio.AudioVolumeType.ALARM: return audio.StreamUsage.STREAM_USAGE_ALARM
        case audio.AudioVolumeType.ACCESSIBILITY: return audio.StreamUsage.STREAM_USAGE_ACCESSIBILITY
        case audio.AudioVolumeType.SYSTEM: return audio.StreamUsage.STREAM_USAGE_SYSTEM
        case audio.AudioVolumeType.VOICE_ASSISTANT: return audio.StreamUsage.STREAM_USAGE_VOICE_ASSISTANT
        case audio.AudioVolumeType.ULTRASONIC: return audio.StreamUsage.STREAM_USAGE_ULTRASONIC
        case audio.AudioVolumeType.NOTIFICATION: return audio.StreamUsage.STREAM_USAGE_NOTIFICATION
        case audio.AudioVolumeType.NAVIGATION: return audio.StreamUsage.STREAM_USAGE_NAVIGATION
        default: throw new Error('volumeType ' + volumeType.toString() + ' has no single StreamUsage')
      }
    }
    throw new Error('SystemCapability.Multimedia.Audio.Volume is not supported')
  }
  throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
}

async function requireAudioPermission(manageConfig: boolean): Promise<void> {
  let context = AbilityContext.value
  if (context === null) { throw new Error('no ability context yet') }
  let permission = manageConfig ? 'ohos.permission.MANAGE_AUDIO_CONFIG' : 'ohos.permission.ACCESS_NOTIFICATION_POLICY'
  try {
    let status = await abilityAccessCtrl.createAtManager().checkAccessToken(context.applicationInfo.accessTokenId,
      manageConfig ? 'ohos.permission.MANAGE_AUDIO_CONFIG' : 'ohos.permission.ACCESS_NOTIFICATION_POLICY')
    if (status !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
      throw new Error('permission not granted: ' + permission)
    }
  } catch (e) {
    throw e as Error
  }
}

let avPlayerInstance: media.AVPlayer | null = null
let avPlayerFile: fs.File | null = null
let avPlayerUrl: string = ''
let avPlayerError: string = ''
let avPlayerBusy: boolean = false
let avPlayerPreparationReject: ((error: Error) => void) | null = null

async function avPlayerOnce(): Promise<media.AVPlayer> {
  if (canIUse('SystemCapability.Multimedia.Media.Core')) {
    if (canIUse('SystemCapability.Multimedia.Media.AVPlayer')) {
      try {
        if (avPlayerInstance !== null) { return avPlayerInstance }
        let player = await media.createAVPlayer()
        try {
          player.on('error', (error: Error): void => {
            avPlayerError = error.message
            let rejectPreparation = avPlayerPreparationReject
            if (rejectPreparation !== null) { rejectPreparation(error) }
          })
        } catch (e) {
          await player.release()
          throw e as Error
        }
        avPlayerInstance = player
        return player
      } catch (e) {
        throw e as Error
      }
    }
    throw new Error('SystemCapability.Multimedia.Media.AVPlayer is not supported')
  }
  throw new Error('SystemCapability.Multimedia.Media.Core is not supported')
}

async function resetAvPlayer(player: media.AVPlayer): Promise<void> {
  if (canIUse('SystemCapability.Multimedia.Media.Core')) {
    if (canIUse('SystemCapability.Multimedia.Media.AVPlayer')) {
      try {
        await player.reset()
      } catch (e) {
        avPlayerInstance = null
        try {
          await player.release()
        } catch (releaseError) {
          hilog.error(0x0000, 'VERA', 'VERA-AUDIO player release failed: ' + (releaseError as Error).message)
        }
      } finally {
        let file = avPlayerFile
        avPlayerFile = null
        avPlayerUrl = ''
        avPlayerError = ''
        try {
          if (file !== null) { fs.closeSync(file) }
        } catch (e) {
          throw e as Error
        }
      }
      return
    }
    throw new Error('SystemCapability.Multimedia.Media.AVPlayer is not supported')
  }
  throw new Error('SystemCapability.Multimedia.Media.Core is not supported')
}

async function prepareAvPlayerSource(player: media.AVPlayer, source: string): Promise<void> {
  if (canIUse('SystemCapability.Multimedia.Media.Core')) {
    if (canIUse('SystemCapability.Multimedia.Media.AVPlayer')) {
      let timer: number = -1
      let stateListener: (state: string, reason: media.StateChangeReason) => void =
        (_state: string, _reason: media.StateChangeReason): void => {}
      try {
        await new Promise<void>((resolve, reject) => {
          let preparing: boolean = false
          stateListener = (state: string, _reason: media.StateChangeReason): void => {
            if (state === 'initialized' && !preparing) {
              preparing = true
              try {
                player.prepare().catch((error: Error): void => { reject(error) })
              } catch (e) {
                reject(e as Error)
              }
            } else if (state === 'prepared') {
              resolve()
            } else if (state === 'error' || state === 'released') {
              reject(new Error('player entered ' + state))
            }
          }
          avPlayerPreparationReject = (error: Error): void => { reject(error) }
          player.on('stateChange', stateListener)
          timer = setTimeout((): void => { reject(new Error('audio preparation timed out')) }, 30000)
          player.url = source
        })
      } catch (e) {
        throw e as Error
      } finally {
        if (timer !== -1) { clearTimeout(timer) }
        try {
          player.off('stateChange', stateListener)
        } catch (e) {
          throw e as Error
        } finally {
          avPlayerPreparationReject = null
        }
      }
      return
    }
    throw new Error('SystemCapability.Multimedia.Media.AVPlayer is not supported')
  }
  throw new Error('SystemCapability.Multimedia.Media.Core is not supported')
}

async function playAudio(params: Map<string, string>): Promise<string> {
  if (avPlayerBusy) { return 'error: player operation in progress' }
  let url = paramString(params, 'url', avPlayerUrl).trim()
  if (url.length === 0) { return 'error: missing url' }
  avPlayerBusy = true
  try {
    if (canIUse('SystemCapability.Multimedia.Media.Core')) {
      if (canIUse('SystemCapability.Multimedia.Media.AVPlayer')) {
        let player = await avPlayerOnce()
        try {
          if (url === avPlayerUrl && avPlayerError.length === 0) {
            if (player.state === 'playing') { return 'ok' }
            if (player.state === 'paused' || player.state === 'prepared' || player.state === 'completed') {
              await player.play()
              return 'ok'
            }
          }
          await resetAvPlayer(player)
          player = await avPlayerOnce()
          let source = url
          if (!url.startsWith('https://') && !url.startsWith('http://')) {
            let context = AbilityContext.value
            if (context === null) { return 'error: no ability context yet' }
            let path = url.startsWith('file://') ? new fileUri.FileUri(url).path : url
            if (!path.startsWith(context.filesDir + '/') || path.split('/').includes('..')) {
              return 'error: local audio must be under app filesDir'
            }
            avPlayerFile = fs.openSync(path, fs.OpenMode.READ_ONLY)
            source = 'fd://' + avPlayerFile.fd.toString()
          }
          await prepareAvPlayerSource(player, source)
          await player.play()
          if (avPlayerError.length > 0) { throw new Error(avPlayerError) }
          avPlayerUrl = url
          return 'ok'
        } catch (e) {
          await resetAvPlayer(player)
          throw e as Error
        }
      }
      throw new Error('SystemCapability.Multimedia.Media.AVPlayer is not supported')
    }
    throw new Error('SystemCapability.Multimedia.Media.Core is not supported')
  } catch (e) {
    throw e as Error
  } finally {
    avPlayerBusy = false
  }
}

async function stopAudio(): Promise<string> {
  if (avPlayerBusy) { return 'error: player operation in progress' }
  let player = avPlayerInstance
  if (player === null || avPlayerUrl.length === 0) { return 'error: nothing playing' }
  avPlayerBusy = true
  try {
    if (canIUse('SystemCapability.Multimedia.Media.Core')) {
      if (canIUse('SystemCapability.Multimedia.Media.AVPlayer')) {
        if (avPlayerError.length > 0) {
          let message = avPlayerError
          await resetAvPlayer(player)
          return 'error: ' + message
        }
        try {
          if (player.state === 'prepared' || player.state === 'playing' ||
              player.state === 'paused' || player.state === 'completed') {
            await player.stop()
          }
        } catch (e) {
          throw e as Error
        } finally {
          await resetAvPlayer(player)
        }
        return 'ok'
      }
      throw new Error('SystemCapability.Multimedia.Media.AVPlayer is not supported')
    }
    throw new Error('SystemCapability.Multimedia.Media.Core is not supported')
  } catch (e) {
    throw e as Error
  } finally {
    avPlayerBusy = false
  }
}

async function pauseAudio(): Promise<string> {
  if (avPlayerBusy) { return 'error: player operation in progress' }
  let player = avPlayerInstance
  if (player === null || avPlayerUrl.length === 0) { return 'error: nothing playing' }
  if (avPlayerError.length > 0) { return 'error: ' + avPlayerError }
  if (canIUse('SystemCapability.Multimedia.Media.Core')) {
    if (canIUse('SystemCapability.Multimedia.Media.AVPlayer')) {
      if (player.state === 'paused') { return 'ok' }
      if (player.state !== 'playing') { return 'error: nothing playing' }
      avPlayerBusy = true
      try {
        await player.pause()
        return 'ok'
      } catch (e) {
        throw e as Error
      } finally {
        avPlayerBusy = false
      }
    }
    throw new Error('SystemCapability.Multimedia.Media.AVPlayer is not supported')
  }
  throw new Error('SystemCapability.Multimedia.Media.Core is not supported')
}

class AudioRecordingProfile implements media.AVRecorderProfile {
  audioBitrate: number = 128000
  audioChannels: number = 1
  audioCodec: media.CodecMimeType
  audioSampleRate: number = 48000
  fileFormat: media.ContainerFormatType

  constructor() {
    if (canIUse('SystemCapability.Multimedia.Media.Core')) {
      this.audioCodec = media.CodecMimeType.AUDIO_AAC
      this.fileFormat = media.ContainerFormatType.CFT_MPEG_4A
      return
    }
    throw new Error('SystemCapability.Multimedia.Media.Core is not supported')
  }
}

class AudioRecordingConfig implements media.AVRecorderConfig {
  audioSourceType: media.AudioSourceType
  profile: media.AVRecorderProfile = new AudioRecordingProfile()
  url: string = ''

  constructor() {
    if (canIUse('SystemCapability.Multimedia.Media.Core')) {
      if (canIUse('SystemCapability.Multimedia.Media.AVRecorder')) {
        this.audioSourceType = media.AudioSourceType.AUDIO_SOURCE_TYPE_MIC
        return
      }
      throw new Error('SystemCapability.Multimedia.Media.AVRecorder is not supported')
    }
    throw new Error('SystemCapability.Multimedia.Media.Core is not supported')
  }
}

let avRecorderInstance: media.AVRecorder | null = null
let avRecorderFile: fs.File | null = null
let avRecorderPath: string = ''
let avRecorderError: string = ''
let avRecorderBusy: boolean = false

async function avRecorderOnce(): Promise<media.AVRecorder> {
  if (canIUse('SystemCapability.Multimedia.Media.Core')) {
    if (canIUse('SystemCapability.Multimedia.Media.AVRecorder')) {
      try {
        if (avRecorderInstance !== null) { return avRecorderInstance }
        let recorder = await media.createAVRecorder()
        try {
          recorder.on('error', (error: Error): void => {
            avRecorderError = error.message
          })
        } catch (e) {
          await recorder.release()
          throw e as Error
        }
        avRecorderInstance = recorder
        return recorder
      } catch (e) {
        throw e as Error
      }
    }
    throw new Error('SystemCapability.Multimedia.Media.AVRecorder is not supported')
  }
  throw new Error('SystemCapability.Multimedia.Media.Core is not supported')
}

async function resetAvRecorder(recorder: media.AVRecorder): Promise<void> {
  if (canIUse('SystemCapability.Multimedia.Media.Core')) {
    if (canIUse('SystemCapability.Multimedia.Media.AVRecorder')) {
      try {
        await recorder.reset()
      } catch (e) {
        avRecorderInstance = null
        try {
          await recorder.release()
        } catch (releaseError) {
          hilog.error(0x0000, 'VERA', 'VERA-AUDIO recorder release failed: ' + (releaseError as Error).message)
        }
      } finally {
        let file = avRecorderFile
        avRecorderFile = null
        avRecorderPath = ''
        avRecorderError = ''
        try {
          if (file !== null) { fs.closeSync(file) }
        } catch (e) {
          throw e as Error
        }
      }
      return
    }
    throw new Error('SystemCapability.Multimedia.Media.AVRecorder is not supported')
  }
  throw new Error('SystemCapability.Multimedia.Media.Core is not supported')
}

function removeFailedRecording(path: string): void {
  if (path.length === 0) { return }
  try {
    fs.unlinkSync(path)
  } catch (e) {
    hilog.error(0x0000, 'VERA', 'VERA-AUDIO failed recording cleanup: ' + (e as Error).message)
  }
}

async function startAudioRecording(): Promise<string> {
  if (avRecorderBusy) { return 'error: recorder operation in progress' }
  let context = AbilityContext.value
  if (context === null) { return 'error: no ability context yet' }
  avRecorderBusy = true
  try {
    if (canIUse('SystemCapability.Multimedia.Media.Core')) {
      if (canIUse('SystemCapability.Multimedia.Media.AVRecorder')) {
        let status = await abilityAccessCtrl.createAtManager().checkAccessToken(
          context.applicationInfo.accessTokenId, 'ohos.permission.MICROPHONE')
        if (status !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          return 'error: microphone permission not granted'
        }
        let recorder = await avRecorderOnce()
        if (recorder.state === 'started' || recorder.state === 'paused') {
          return 'error: already recording'
        }
        try {
          await resetAvRecorder(recorder)
          recorder = await avRecorderOnce()
          let directory = context.filesDir + '/vera'
          if (!fs.accessSync(directory)) { fs.mkdirSync(directory, true) }
          avRecorderPath = directory + '/recording-' + Date.now().toString() + '.m4a'
          avRecorderFile = fs.openSync(avRecorderPath,
            fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC)
          let config = new AudioRecordingConfig()
          config.url = 'fd://' + avRecorderFile.fd.toString()
          await recorder.prepare(config)
          await recorder.start()
          if (avRecorderError.length > 0) { throw new Error(avRecorderError) }
          return 'ok'
        } catch (e) {
          let path = avRecorderPath
          try {
            await resetAvRecorder(recorder)
          } catch (resetError) {
            throw resetError as Error
          } finally {
            removeFailedRecording(path)
          }
          throw e as Error
        }
      }
      throw new Error('SystemCapability.Multimedia.Media.AVRecorder is not supported')
    }
    throw new Error('SystemCapability.Multimedia.Media.Core is not supported')
  } catch (e) {
    throw e as Error
  } finally {
    avRecorderBusy = false
  }
}

async function stopAudioRecording(): Promise<string> {
  if (avRecorderBusy) { return 'error: recorder operation in progress' }
  let recorder = avRecorderInstance
  if (recorder === null || avRecorderPath.length === 0) { return 'error: nothing recording' }
  avRecorderBusy = true
  try {
    if (canIUse('SystemCapability.Multimedia.Media.Core')) {
      if (canIUse('SystemCapability.Multimedia.Media.AVRecorder')) {
        let path = avRecorderPath
        let completed: boolean = false
        try {
          if (avRecorderError.length > 0) { return 'error: ' + avRecorderError }
          if (recorder.state !== 'started' && recorder.state !== 'paused') {
            return 'error: recorder is not recording'
          }
          await recorder.stop()
          if (avRecorderError.length > 0) { return 'error: ' + avRecorderError }
          completed = true
        } catch (e) {
          throw e as Error
        } finally {
          try {
            await resetAvRecorder(recorder)
          } catch (e) {
            throw e as Error
          } finally {
            if (!completed) { removeFailedRecording(path) }
          }
        }
        return path
      }
      throw new Error('SystemCapability.Multimedia.Media.AVRecorder is not supported')
    }
    throw new Error('SystemCapability.Multimedia.Media.Core is not supported')
  } catch (e) {
    throw e as Error
  } finally {
    avRecorderBusy = false
  }
}

// AudioRenderer.write takes a raw ArrayBuffer (interface_sdk-js). The adapter
// accepts it as comma-separated signed 16-bit samples (see parseSamples below),
// since sdk.call only carries strings and the generated program can only build
// integers. Fixed to 48kHz mono 16-bit PCM, matching ToneStreamInfo below.

class ToneStreamInfo implements audio.AudioStreamInfo {
  samplingRate: audio.AudioSamplingRate
  channels: audio.AudioChannel
  sampleFormat: audio.AudioSampleFormat
  encodingType: audio.AudioEncodingType

  constructor() {
    if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
      this.samplingRate = audio.AudioSamplingRate.SAMPLE_RATE_48000
      this.channels = audio.AudioChannel.CHANNEL_1
      this.sampleFormat = audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE
      this.encodingType = audio.AudioEncodingType.ENCODING_TYPE_RAW
      return
    }
    throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
  }
}

class ToneRendererInfo implements audio.AudioRendererInfo {
  usage: audio.StreamUsage
  rendererFlags: number = 0

  constructor() {
    if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
      this.usage = audio.StreamUsage.STREAM_USAGE_MUSIC
      return
    }
    throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
  }
}

class ToneRendererOptions implements audio.AudioRendererOptions {
  streamInfo: audio.AudioStreamInfo = new ToneStreamInfo()
  rendererInfo: audio.AudioRendererInfo = new ToneRendererInfo()
}

class AudioRendererWriter {
  bytes: Uint8Array | null = null
  offset: number = 0
  complete: (() => void) | null = null

  writeData: audio.AudioRendererWriteDataCallback = (data: ArrayBuffer): audio.AudioDataCallbackResult => {
    if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
      let bytes = this.bytes
      if (bytes === null || data.byteLength === 0) { return audio.AudioDataCallbackResult.INVALID }
      let count = Math.min(data.byteLength, bytes.byteLength - this.offset)
      let output = new Uint8Array(data)
      output.fill(0)
      output.set(bytes.subarray(this.offset, this.offset + count))
      this.offset += count
      if (this.offset === bytes.byteLength) {
        let complete = this.complete
        this.bytes = null
        this.complete = null
        if (complete !== null) { complete() }
      }
      return audio.AudioDataCallbackResult.VALID
    }
    throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
  }
}

let audioRendererInstance: audio.AudioRenderer | null = null
let audioRendererWriter: AudioRendererWriter | null = null
let audioRendererRate: number = 0

function samplingRateEnum(rate: number): audio.AudioSamplingRate {
  if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
    if (rate === 8000) { return audio.AudioSamplingRate.SAMPLE_RATE_8000 }
    if (rate === 16000) { return audio.AudioSamplingRate.SAMPLE_RATE_16000 }
    if (rate === 44100) { return audio.AudioSamplingRate.SAMPLE_RATE_44100 }
    return audio.AudioSamplingRate.SAMPLE_RATE_48000
  }
  throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
}

async function disposeAudioRenderer(): Promise<void> {
  let renderer = audioRendererInstance
  let writer = audioRendererWriter
  audioRendererInstance = null
  audioRendererWriter = null
  audioRendererRate = 0
  if (writer !== null) {
    writer.bytes = null
    writer.complete = null
  }
  if (renderer === null) { return }
  if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
    if (canIUse('SystemCapability.Multimedia.Audio.Renderer')) {
      try {
        if (writer !== null) { renderer.off('writeData', writer.writeData) }
      } catch (e) {
        throw e as Error
      } finally {
        try {
          await renderer.release()
        } catch (e) {
          throw e as Error
        }
      }
      return
    }
    throw new Error('SystemCapability.Multimedia.Audio.Renderer is not supported')
  }
  throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
}

async function audioRendererOnce(rate: number): Promise<audio.AudioRenderer> {
  if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
    if (canIUse('SystemCapability.Multimedia.Audio.Renderer')) {
      try {
        if (audioRendererInstance !== null && audioRendererRate === rate) { return audioRendererInstance }
        await disposeAudioRenderer()
        let options = new ToneRendererOptions()
        options.streamInfo.samplingRate = samplingRateEnum(rate)
        let renderer = await audio.createAudioRenderer(options)
        let writer = new AudioRendererWriter()
        try {
          renderer.on('writeData', writer.writeData)
        } catch (e) {
          await renderer.release()
          throw e as Error
        }
        audioRendererInstance = renderer
        audioRendererWriter = writer
        audioRendererRate = rate
        return renderer
      } catch (e) {
        throw e as Error
      }
    }
    throw new Error('SystemCapability.Multimedia.Audio.Renderer is not supported')
  }
  throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
}

// Renderer calls from one program run back to back: a program may fire several
// writes at once, and they must all land, in order, instead of being rejected.
let audioQueue: Promise<string> = Promise.resolve('ok')
function queueAudio(op: () => Promise<string>): Promise<string> {
  let run: Promise<string> = audioQueue.then((): Promise<string> => op())
  audioQueue = run.catch((): string => 'ok')
  return run
}
function startAudioRenderer(): Promise<string> { return queueAudio((): Promise<string> => startAudioRendererNow()) }
function writeAudioRenderer(params: Map<string, string>): Promise<string> {
  return queueAudio((): Promise<string> => writeAudioRendererNow(params))
}
function stopAudioRenderer(): Promise<string> { return queueAudio((): Promise<string> => stopAudioRendererNow()) }
function releaseAudioRenderer(): Promise<string> { return queueAudio((): Promise<string> => releaseAudioRendererNow()) }

async function startAudioRendererNow(): Promise<string> {
  try {
    if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
      if (canIUse('SystemCapability.Multimedia.Audio.Renderer')) {
        let renderer = await audioRendererOnce(48000)
        if (renderer.state !== audio.AudioState.STATE_RUNNING) { await renderer.start() }
        return 'ok'
      }
      throw new Error('SystemCapability.Multimedia.Audio.Renderer is not supported')
    }
    throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
  } catch (e) {
    try {
      await disposeAudioRenderer()
    } catch (releaseError) {
      hilog.error(0x0000, 'VERA', 'VERA-AUDIO renderer release failed: ' + (releaseError as Error).message)
    }
    return 'error: ' + (e as Error).message
  }
}

// The `buffer` parameter arrives as one string of comma-separated signed
// 16-bit samples (-32768..32767, 48kHz mono, ToneStreamInfo above). That is
// the binary form a generated program can actually produce: VERA has int and
// string but no byte type. frequencyHz/durationMs is a fallback that makes a
// sine wave here instead.
const MAX_TONE_DURATION_MS = 10000
function parseSamples(text: string): ArrayBuffer | null {
  let parts = text.split(',')
  let out = new ArrayBuffer(parts.length * 2)
  let view = new Int16Array(out)
  for (let i = 0; i < parts.length; i++) {
    let v = Number.parseInt(parts[i].trim(), 10)
    if (Number.isNaN(v)) { return null }
    view[i] = Math.max(-32768, Math.min(32767, v))
  }
  return out
}

function synthesizeTone(frequencyHz: number, durationMs: number, volume: number): ArrayBuffer {
  let sampleRate = 48000
  let clampedMs = Math.max(0, Math.min(durationMs, MAX_TONE_DURATION_MS))
  let n = Math.floor(sampleRate * clampedMs / 1000)
  let amp = Math.max(0, Math.min(1, volume)) * 32767
  let out = new ArrayBuffer(n * 2)
  let view = new Int16Array(out)
  for (let i = 0; i < n; i++) {
    let t = i / sampleRate
    view[i] = Math.round(amp * Math.sin(2 * Math.PI * frequencyHz * t))
  }
  return out
}

async function writeAudioRendererNow(params: Map<string, string>): Promise<string> {
  let samples = paramString(params, 'buffer', '')
  let sampleRate = paramInt(params, 'sampleRate', 48000)
  let frequencyHz = paramFloat(params, 'frequencyHz', 0)
  let durationMs = paramInt(params, 'durationMs', 0)
  if (samples.length === 0 && (frequencyHz <= 0 || durationMs <= 0)) {
    return 'error: pass buffer (comma-separated 16-bit samples), or frequencyHz and durationMs'
  }
  let bytes: ArrayBuffer | null = samples.length > 0
    ? parseSamples(samples)
    : synthesizeTone(frequencyHz, durationMs, paramFloat(params, 'volume', 0.3))
  if (bytes === null) { return 'error: buffer must be comma-separated integers' }
  let timer: number = -1
  try {
    if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
      if (canIUse('SystemCapability.Multimedia.Audio.Renderer')) {
        let renderer = await audioRendererOnce(sampleRate)
        const writer = audioRendererWriter
        if (writer === null) { throw new Error('audio renderer writer unavailable') }
        let input = new Uint8Array(bytes)
        let length = input.byteLength
        let completion = new Promise<void>((resolve, reject) => {
          writer.bytes = length > 0 ? input : null
          writer.offset = 0
          writer.complete = length > 0 ? resolve : null
          if (length === 0) { resolve(); return }
          timer = setTimeout((): void => {
            writer.bytes = null
            writer.complete = null
            reject(new Error('audio write timed out'))
          }, Math.max(30000, Math.ceil(length * 1000 / (samplingRateEnum(sampleRate) * 2)) + 5000))
        })
        let started = renderer.state !== audio.AudioState.STATE_RUNNING ? renderer.start() : Promise.resolve()
        await Promise.all([started, completion])
        return length.toString()
      }
      throw new Error('SystemCapability.Multimedia.Audio.Renderer is not supported')
    }
    throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
  } catch (e) {
    try {
      await disposeAudioRenderer()
    } catch (releaseError) {
      hilog.error(0x0000, 'VERA', 'VERA-AUDIO renderer release failed: ' + (releaseError as Error).message)
    }
    return 'error: ' + (e as Error).message
  } finally {
    if (timer !== -1) { clearTimeout(timer) }
    let writer = audioRendererWriter
    if (writer !== null) {
      writer.bytes = null
      writer.complete = null
    }
  }
}

async function stopAudioRendererNow(): Promise<string> {
  if (audioRendererInstance === null) { return 'ok' }
  try {
    if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
      if (canIUse('SystemCapability.Multimedia.Audio.Renderer')) {
        await audioRendererInstance.stop()
        return 'ok'
      }
      throw new Error('SystemCapability.Multimedia.Audio.Renderer is not supported')
    }
    throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
  } catch (e) {
    return 'error: ' + (e as Error).message
  }
}

async function releaseAudioRendererNow(): Promise<string> {
  if (audioRendererInstance === null) { return 'ok' }
  try {
    await disposeAudioRenderer()
    return 'ok'
  } catch (e) {
    return 'error: ' + (e as Error).message
  }
}

// -- TonePlayer: the platform's own tone generator (dial tones, beep, ack, ...).
// A class API: nothing works until a TonePlayer exists and a tone is loaded, so
// one instance is created on first use and kept, the way AudioRenderer is.
// Every operation goes through queueAudio, so a program that fires start and
// stop back to back (a blinking pattern) gets them in order.
let tonePlayerInstance: audio.TonePlayer | null = null
let tonePlayerLoaded: number = -1

class ToneEntry {
  name: string = ''
  value: number = 0
  constructor(name: string, value: number) { this.name = name; this.value = value }
}

// audio.ToneType, by the names @ohos.multimedia.audio.d.ts documents.
const TONE_TYPES: ToneEntry[] = [
  new ToneEntry('DIAL_0', 0), new ToneEntry('DIAL_1', 1), new ToneEntry('DIAL_2', 2),
  new ToneEntry('DIAL_3', 3), new ToneEntry('DIAL_4', 4), new ToneEntry('DIAL_5', 5),
  new ToneEntry('DIAL_6', 6), new ToneEntry('DIAL_7', 7), new ToneEntry('DIAL_8', 8),
  new ToneEntry('DIAL_9', 9), new ToneEntry('DIAL_S', 10), new ToneEntry('DIAL_P', 11),
  new ToneEntry('DIAL_A', 12), new ToneEntry('DIAL_B', 13), new ToneEntry('DIAL_C', 14),
  new ToneEntry('DIAL_D', 15),
  new ToneEntry('COMMON_SUPERVISORY_DIAL', 100), new ToneEntry('COMMON_SUPERVISORY_BUSY', 101),
  new ToneEntry('COMMON_SUPERVISORY_CONGESTION', 102), new ToneEntry('COMMON_SUPERVISORY_RADIO_ACK', 103),
  new ToneEntry('COMMON_SUPERVISORY_RADIO_NOT_AVAILABLE', 104),
  new ToneEntry('COMMON_SUPERVISORY_CALL_WAITING', 106), new ToneEntry('COMMON_SUPERVISORY_RINGTONE', 107),
  new ToneEntry('COMMON_SUPERVISORY_CALL_HOLDING', 108),
  new ToneEntry('COMMON_PROPRIETARY_BEEP', 200), new ToneEntry('COMMON_PROPRIETARY_ACK', 201),
  new ToneEntry('COMMON_PROPRIETARY_PROMPT', 203), new ToneEntry('COMMON_PROPRIETARY_DOUBLE_BEEP', 204)
]
const DEFAULT_TONE = 200 // COMMON_PROPRIETARY_BEEP: a plain beep

/** A tone by number, by full name ("TONE_TYPE_DIAL_1", "DIAL_1") or by the short
 * name of a common tone ("BEEP", "DOUBLE_BEEP", "BUSY"); nothing at all means a
 * beep. -1 for anything else. */
function toneTypeFrom(raw: string | undefined): number {
  if (raw === undefined || raw.trim().length === 0) { return DEFAULT_TONE }
  let v = enumMemberName(raw)
  if (v.startsWith('TONE_TYPE_')) { v = v.substring(10) }
  for (let t of TONE_TYPES) {
    let short = t.name.replace('COMMON_PROPRIETARY_', '').replace('COMMON_SUPERVISORY_', '')
    if (v === t.name || v === short) { return t.value }
  }
  let n = Number.parseInt(v, 10)
  if (Number.isNaN(n)) { return -1 }
  for (let t of TONE_TYPES) { if (t.value === n) { return n } }
  return -1
}

async function tonePlayerOnce(): Promise<audio.TonePlayer> {
  if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
    if (canIUse('SystemCapability.Multimedia.Audio.Tone')) {
      try {
        if (tonePlayerInstance !== null) { return tonePlayerInstance }
        let player = await audio.createTonePlayer(new ToneRendererInfo())
        if (player === null) { throw new Error('could not create a tone player') }
        tonePlayerInstance = player
        tonePlayerLoaded = -1
        return player
      } catch (e) {
        throw e as Error
      }
    }
    throw new Error('SystemCapability.Multimedia.Audio.Tone is not supported')
  }
  throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
}

// load() every time, never "already loaded": a tone that has played out or been
// stopped is spent, and start() on it plays nothing (the platform logs
// "CheckToneStopped true ... OnWriteData SequenceGen error"). With a cached
// load only the first beep of a blinking pattern was ever heard.
async function toneLoaded(player: audio.TonePlayer, type: number): Promise<void> {
  if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
    if (canIUse('SystemCapability.Multimedia.Audio.Tone')) {
      try {
        await player.load(type as audio.ToneType)
        tonePlayerLoaded = type
        return
      } catch (e) {
        throw e as Error
      }
    }
    throw new Error('SystemCapability.Multimedia.Audio.Tone is not supported')
  }
  throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
}

function toneFailed(e: Error): string {
  // A failed call leaves the player in an unknown state: start over next time.
  tonePlayerInstance = null
  tonePlayerLoaded = -1
  return 'error: ' + e.message
}

function toneBadType(raw: string | undefined): string {
  return 'error: type must be a tone number or name (DIAL_0..DIAL_D, BEEP, DOUBLE_BEEP, ACK, PROMPT, BUSY, ...), got "' +
    (raw ?? '') + '"'
}

function loadTone(params: Map<string, string>): Promise<string> {
  return queueAudio(async (): Promise<string> => {
    let type = toneTypeFrom(params.get('type'))
    if (type < 0) { return toneBadType(params.get('type')) }
    try {
      await toneLoaded(await tonePlayerOnce(), type)
      return 'ok'
    } catch (e) { return toneFailed(e as Error) }
  })
}

function startTone(params: Map<string, string>): Promise<string> {
  return queueAudio(async (): Promise<string> => {
    let given = params.get('type')
    let type = toneTypeFrom(given)
    if (type < 0) { return toneBadType(given) }
    try {
      let player = await tonePlayerOnce()
      // An explicit type wins; with none, the last one used, else a beep.
      let want = given !== undefined && given.trim().length > 0 ? type
        : (tonePlayerLoaded >= 0 ? tonePlayerLoaded : DEFAULT_TONE)
      if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
        if (canIUse('SystemCapability.Multimedia.Audio.Tone')) {
          await toneLoaded(player, want)
          await player.start()
          return 'ok'
        }
        throw new Error('SystemCapability.Multimedia.Audio.Tone is not supported')
      }
      throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
    } catch (e) { return toneFailed(e as Error) }
  })
}

function stopTone(): Promise<string> {
  return queueAudio(async (): Promise<string> => {
    let player = tonePlayerInstance
    if (player === null) { return 'ok' }
    try {
      if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
        if (canIUse('SystemCapability.Multimedia.Audio.Tone')) {
          await player.stop()
          return 'ok'
        }
        throw new Error('SystemCapability.Multimedia.Audio.Tone is not supported')
      }
      throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
    } catch (e) { return toneFailed(e as Error) }
  })
}

function releaseTone(): Promise<string> {
  return queueAudio(async (): Promise<string> => {
    let player = tonePlayerInstance
    tonePlayerInstance = null
    tonePlayerLoaded = -1
    if (player === null) { return 'ok' }
    try {
      if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
        if (canIUse('SystemCapability.Multimedia.Audio.Tone')) {
          await player.release()
          return 'ok'
        }
        throw new Error('SystemCapability.Multimedia.Audio.Tone is not supported')
      }
      throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
    } catch (e) { return 'error: ' + (e as Error).message }
  })
}

// -- Vibration: vibrator.startVibration / stopVibration, and the older
// vibrator.vibrate a generated program reaches for just as often. The effect and
// the attribute are objects, which sdk.call cannot carry, so they are built here
// from flat parameters: `duration` (ms) for a timed buzz, or `effectId` (a preset
// such as "haptic.clock.timer") with an optional `count`; `usage` is optional and
// defaults to "alarm", which is not muted by the ringer setting.
const VIBRATE_USAGES: string[] = ['unknown', 'alarm', 'ring', 'notification', 'communication', 'touch',
  'media', 'physicalFeedback', 'simulateReality']

function vibrateUsageFrom(raw: string | undefined): string {
  if (raw === undefined || raw.trim().length === 0) { return 'alarm' }
  let v = enumMemberName(raw)
  for (let u of VIBRATE_USAGES) { if (u.toUpperCase() === v) { return u } }
  return ''
}

async function vibrateNow(params: Map<string, string>): Promise<string> {
  let usage = vibrateUsageFrom(params.get('usage'))
  if (usage.length === 0) {
    return 'error: usage must be one of ' + VIBRATE_USAGES.join(', ') + ', got "' + (params.get('usage') ?? '') + '"'
  }
  let effectJson = ''
  let preset = params.get('effectId')
  if (preset !== undefined && preset.trim().length > 0) {
    effectJson = '{"type":"preset","effectId":' + JSON.stringify(preset.trim()) + ',"count":' +
      Math.max(1, paramInt(params, 'count', 1)).toString() + '}'
  } else {
    let duration = paramInt(params, 'duration', 0)
    if (duration <= 0) { return 'error: pass duration (milliseconds, more than 0) or effectId' }
    effectJson = '{"type":"time","duration":' + duration.toString() + '}'
  }
  try {
    // JSON.parse, not an object literal: the effect and the attribute are
    // interfaces with literal-typed members, which ArkTS will not build inline.
    let effect = JSON.parse(effectJson) as vibrator.VibrateEffect
    let attribute = JSON.parse('{"id":0,"usage":"' + usage + '"}') as vibrator.VibrateAttribute
    await vibrator.startVibration(effect, attribute)
    return 'ok'
  } catch (e) {
    return 'error: ' + (e as Error).message
  }
}

// -- generated helpers below (tools/generate-sdk-backend.py) --

function paramString(params: Map<string, string>, name: string, fallback: string): string {
  let v = params.get(name)
  return v !== undefined ? v : fallback
}

// A value that is not a number is an error the program can see, not a NaN that
// the platform quietly reads as 0: a generated program passed ["mode", "OFF"]
// to setTorchMode, got "ok", and the flashlight never lit. runSdkAdapter turns
// the throw into "error: ..." as the answer.
function paramInt(params: Map<string, string>, name: string, fallback: number): number {
  let v = params.get(name)
  if (v === undefined) { return fallback }
  let n = Number.parseInt(v, 10)
  if (Number.isNaN(n)) { throw new Error('parameter ' + name + ' must be an integer, got "' + v + '"') }
  return n
}

function paramFloat(params: Map<string, string>, name: string, fallback: number): number {
  let v = params.get(name)
  if (v === undefined) { return fallback }
  let n = Number.parseFloat(v)
  if (Number.isNaN(n)) { throw new Error('parameter ' + name + ' must be a number, got "' + v + '"') }
  return n
}

function paramBoolean(params: Map<string, string>, name: string, fallback: boolean): boolean {
  let v = params.get(name)
  return v !== undefined ? v === 'true' : fallback
}

function paramBigInt(params: Map<string, string>, name: string, fallback: bigint): bigint {
  let v = params.get(name)
  return v !== undefined ? BigInt(v) : fallback
}

class SdkLocaleInfo {
  locale: string
  baseName: string
  language: string
  script: string | undefined
  region: string | undefined

  constructor(value: Intl.Locale) {
    this.locale = value.toString()
    this.baseName = value.baseName
    this.language = value.language
    this.script = value.script
    this.region = value.region
  }
}

class SdkDisplayInfo {
  id: number
  name: string
  width: number
  height: number
  rotation: number
  orientation: number
  state: number
  refreshRate: number
  densityDPI: number
  densityPixels: number
  scaledDensity: number
  xDPI: number
  yDPI: number

  constructor(value: display.Display) {
    this.id = value.id
    this.name = value.name
    this.width = value.width
    this.height = value.height
    this.rotation = value.rotation
    this.orientation = value.orientation
    this.state = value.state
    this.refreshRate = value.refreshRate
    this.densityDPI = value.densityDPI
    this.densityPixels = value.densityPixels
    this.scaledDensity = value.scaledDensity
    this.xDPI = value.xDPI
    this.yDPI = value.yDPI
  }
}

class SdkDisplayPhysicalResolutionInfo {
  foldDisplayMode: number
  physicalWidth: number
  physicalHeight: number

  constructor(value: display.DisplayPhysicalResolution) {
    this.foldDisplayMode = value.foldDisplayMode
    this.physicalWidth = value.physicalWidth
    this.physicalHeight = value.physicalHeight
  }
}

class SdkDisplayRectInfo {
  left: number
  top: number
  width: number
  height: number

  constructor(value: display.Rect) {
    this.left = value.left
    this.top = value.top
    this.width = value.width
    this.height = value.height
  }
}

class SdkFoldCreaseRegionInfo {
  displayId: number
  creaseRects: Array<SdkDisplayRectInfo>

  constructor(value: display.FoldCreaseRegion) {
    if (canIUse('SystemCapability.Window.SessionManager')) {
      this.displayId = value.displayId
      this.creaseRects = value.creaseRects.map((rect: display.Rect): SdkDisplayRectInfo => {
        return new SdkDisplayRectInfo(rect)
      })
      return
    }
    throw new Error('SystemCapability.Window.SessionManager is not supported')
  }
}

const ADAPTERS: Map<string, SdkAdapter> = new Map<string, SdkAdapter>([
  // Both zero-argument and synchronous in the real API -- about as simple as
  // this surface gets, which is why they're first. Needs
  // ohos.permission.STORAGE_MANAGER (module.json5), system_basic APL
  // (signing/UnsgnedReleasedProfileTemplate.json) -- both already true of
  // this app.
  // CameraManager is a class (VeraSdkIndex scopeKind: interface), not a
  // namespace -- the one shape excluded from tools/select-sdk-backend-
  // candidates.py wholesale, because most classes need an instance built in
  // a way no script can read off the declaration. This one is the exception:
  // camera.getCameraManager(context) is itself a plain namespace function
  // that only needs the ability context every handler already has, cached
  // once above (cameraManagerOnce). mode arrives as sdk.call's usual string
  // ("0"/"1"/"2"), which happens to already be TorchMode's own numeric
  // encoding (OFF/ON/AUTO), so parsing it as int and casting is exact rather
  // than a guess.
  ['CameraKit.CameraManager.setTorchMode', async (params: Map<string, string>): Promise<string> => {
    let manager = cameraManagerOnce()
    if (manager === null) { return 'error: no ability context yet' }
    if (!manager.isTorchSupported()) { return 'error: torch not supported on this device' }
    let mode = torchModeFrom(params.get('mode'))
    if (mode < 0) {
      return 'error: mode must be 0 (OFF), 1 (ON), 2 (AUTO) or 3 (ALWAYS_OPEN), got "' + (params.get('mode') ?? '') + '"'
    }
    manager.setTorchMode(mode as camera.TorchMode)
    return 'ok'
  }],
  ['AudioKit.AudioManager.setVolume', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
      if (canIUse('SystemCapability.Multimedia.Audio.Volume')) {
        let volumeType = paramInt(params, 'volumeType', audio.AudioVolumeType.MEDIA)
        let volume = paramInt(params, 'volume', 0)
        await requireAudioPermission(false)
        await audioVolumeGroupManager().setVolume(volumeType as audio.AudioVolumeType, volume)
        return 'ok'
      }
      throw new Error('SystemCapability.Multimedia.Audio.Volume is not supported')
    }
    throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
  }],
  ['AudioKit.AudioManager.getVolume', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
      if (canIUse('SystemCapability.Multimedia.Audio.Volume')) {
        let volumeType = paramInt(params, 'volumeType', audio.AudioVolumeType.MEDIA)
        let result = audioVolumeManager().getVolumeByStream(streamUsageForVolumeType(volumeType))
        return result.toString()
      }
      throw new Error('SystemCapability.Multimedia.Audio.Volume is not supported')
    }
    throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
  }],
  ['AudioKit.AudioManager.getMaxVolume', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
      if (canIUse('SystemCapability.Multimedia.Audio.Volume')) {
        let volumeType = paramInt(params, 'volumeType', audio.AudioVolumeType.MEDIA)
        let result = audioVolumeManager().getMaxVolumeByStream(streamUsageForVolumeType(volumeType))
        return result.toString()
      }
      throw new Error('SystemCapability.Multimedia.Audio.Volume is not supported')
    }
    throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
  }],
  ['AudioKit.AudioManager.getMinVolume', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
      if (canIUse('SystemCapability.Multimedia.Audio.Volume')) {
        let volumeType = paramInt(params, 'volumeType', audio.AudioVolumeType.MEDIA)
        let result = audioVolumeManager().getMinVolumeByStream(streamUsageForVolumeType(volumeType))
        return result.toString()
      }
      throw new Error('SystemCapability.Multimedia.Audio.Volume is not supported')
    }
    throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
  }],
  ['AudioKit.AudioManager.mute', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
      if (canIUse('SystemCapability.Multimedia.Audio.Volume')) {
        let volumeType = paramInt(params, 'volumeType', audio.AudioVolumeType.MEDIA)
        let mute = paramBoolean(params, 'mute', false)
        await requireAudioPermission(false)
        await audioVolumeGroupManager().mute(volumeType as audio.AudioVolumeType, mute)
        return 'ok'
      }
      throw new Error('SystemCapability.Multimedia.Audio.Volume is not supported')
    }
    throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
  }],
  ['AudioKit.AudioManager.isMute', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
      if (canIUse('SystemCapability.Multimedia.Audio.Volume')) {
        let volumeType = paramInt(params, 'volumeType', audio.AudioVolumeType.MEDIA)
        let result = audioVolumeManager().isSystemMutedForStream(streamUsageForVolumeType(volumeType))
        return result.toString()
      }
      throw new Error('SystemCapability.Multimedia.Audio.Volume is not supported')
    }
    throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
  }],
  ['AudioKit.AudioManager.setMicrophoneMute', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
      if (canIUse('SystemCapability.Multimedia.Audio.Volume')) {
        let mute = paramBoolean(params, 'mute', false)
        await requireAudioPermission(true)
        await audioVolumeGroupManager().setMicMute(mute)
        return 'ok'
      }
      throw new Error('SystemCapability.Multimedia.Audio.Volume is not supported')
    }
    throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
  }],
  ['AudioKit.AudioManager.isMicrophoneMute', async (_params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
      if (canIUse('SystemCapability.Multimedia.Audio.Volume')) {
        let result = await audioVolumeGroupManager().isMicrophoneMute()
        return result.toString()
      }
      throw new Error('SystemCapability.Multimedia.Audio.Volume is not supported')
    }
    throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
  }],
  ['AudioKit.AudioManager.setRingerMode', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
      if (canIUse('SystemCapability.Multimedia.Audio.Volume')) {
        let mode = paramInt(params, 'mode', audio.AudioRingMode.RINGER_MODE_NORMAL)
        await requireAudioPermission(false)
        await audioVolumeGroupManager().setRingerMode(mode as audio.AudioRingMode)
        return 'ok'
      }
      throw new Error('SystemCapability.Multimedia.Audio.Volume is not supported')
    }
    throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
  }],
  ['AudioKit.AudioManager.getRingerMode', async (_params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Multimedia.Audio.Core')) {
      if (canIUse('SystemCapability.Multimedia.Audio.Volume')) {
        let result = await audioVolumeGroupManager().getRingerMode()
        return result.toString()
      }
      throw new Error('SystemCapability.Multimedia.Audio.Volume is not supported')
    }
    throw new Error('SystemCapability.Multimedia.Audio.Core is not supported')
  }],
  ['MediaKit.AVPlayer.play', async (params: Map<string, string>): Promise<string> => {
    return await playAudio(params)
  }],
  ['MediaKit.AVPlayer.stop', async (_params: Map<string, string>): Promise<string> => {
    return await stopAudio()
  }],
  ['MediaKit.AVPlayer.pause', async (_params: Map<string, string>): Promise<string> => {
    return await pauseAudio()
  }],
  ['MediaKit.AVRecorder.start', async (_params: Map<string, string>): Promise<string> => {
    return await startAudioRecording()
  }],
  ['MediaKit.AVRecorder.stop', async (_params: Map<string, string>): Promise<string> => {
    return await stopAudioRecording()
  }],
  // Sound generation, not file playback: `buffer` is comma-separated 16-bit
  // samples (48kHz, mono -- ToneStreamInfo above) that the generated program
  // computed itself, or frequencyHz/durationMs for a built-in sine wave.
  // start()/write() both lazily create the renderer and start it if it
  // isn't already running, so a program can just call write() directly in
  // the common case; start/stop/release are still exposed separately for a
  // program that wants to hold the stream open across several writes rather
  // than pay renderer startup latency each time.
  // Vibration. startVibration and the deprecated vibrate share one implementation:
  // `duration` in milliseconds (or `effectId` for a preset), optional `usage`.
  ['SensorServiceKit.vibrator.startVibration', async (params: Map<string, string>): Promise<string> => {
    return await vibrateNow(params)
  }],
  ['SensorServiceKit.vibrator.vibrate', async (params: Map<string, string>): Promise<string> => {
    return await vibrateNow(params)
  }],
  ['SensorServiceKit.vibrator.stopVibration', async (_params: Map<string, string>): Promise<string> => {
    try {
      await vibrator.stopVibration()
      return 'ok'
    } catch (e) { return 'error: ' + (e as Error).message }
  }],
  // The platform's tone generator. createTonePlayer takes an AudioRendererInfo,
  // which a program cannot build, so it is created with the same media-usage info
  // the AudioRenderer adapter uses; load takes `type` (a number or a ToneType
  // name), and start with no `type` plays whatever is loaded, a beep if nothing is.
  ['AudioKit.audio.createTonePlayer', async (_params: Map<string, string>): Promise<string> => {
    return await queueAudio(async (): Promise<string> => {
      try { await tonePlayerOnce(); return 'ok' } catch (e) { return toneFailed(e as Error) }
    })
  }],
  ['AudioKit.TonePlayer.load', async (params: Map<string, string>): Promise<string> => {
    return await loadTone(params)
  }],
  ['AudioKit.TonePlayer.start', async (params: Map<string, string>): Promise<string> => {
    return await startTone(params)
  }],
  ['AudioKit.TonePlayer.stop', async (_params: Map<string, string>): Promise<string> => {
    return await stopTone()
  }],
  ['AudioKit.TonePlayer.release', async (_params: Map<string, string>): Promise<string> => {
    return await releaseTone()
  }],
  ['AudioKit.AudioRenderer.start', async (_params: Map<string, string>): Promise<string> => {
    return await startAudioRenderer()
  }],
  ['AudioKit.AudioRenderer.write', async (params: Map<string, string>): Promise<string> => {
    return await writeAudioRenderer(params)
  }],
  ['AudioKit.AudioRenderer.stop', async (_params: Map<string, string>): Promise<string> => {
    return await stopAudioRenderer()
  }],
  ['AudioKit.AudioRenderer.release', async (_params: Map<string, string>): Promise<string> => {
    return await releaseAudioRenderer()
  }],
  ['CoreFileKit.storageStatistics.getFreeSizeSync', async (_params: Map<string, string>): Promise<string> => {
    return storageStatistics.getFreeSizeSync().toString()
  }],
  ['CoreFileKit.storageStatistics.getTotalSizeSync', async (_params: Map<string, string>): Promise<string> => {
    return storageStatistics.getTotalSizeSync().toString()
  }],
  ['LocalizationKit.System.getSystemLanguages', async (_params: Map<string, string>): Promise<string> => {
    return JSON.stringify(i18n.System.getSystemLanguages())
  }],
  ['LocalizationKit.System.getSystemLanguage', async (_params: Map<string, string>): Promise<string> => {
    return i18n.System.getSystemLanguage()
  }],
  ['LocalizationKit.System.getSystemRegion', async (_params: Map<string, string>): Promise<string> => {
    return i18n.System.getSystemRegion()
  }],
  ['LocalizationKit.System.getSystemLocaleInstance', async (_params: Map<string, string>): Promise<string> => {
    return JSON.stringify(new SdkLocaleInfo(i18n.System.getSystemLocaleInstance()))
  }],
  ['LocalizationKit.System.is24HourClock', async (_params: Map<string, string>): Promise<string> => {
    return i18n.System.is24HourClock().toString()
  }],
  ['LocalizationKit.System.getPreferredLanguageList', async (_params: Map<string, string>): Promise<string> => {
    return JSON.stringify(i18n.System.getPreferredLanguageList())
  }],
  ['LocalizationKit.System.getFirstPreferredLanguage', async (_params: Map<string, string>): Promise<string> => {
    return i18n.System.getFirstPreferredLanguage()
  }],
  ['LocalizationKit.System.getAppPreferredLanguage', async (_params: Map<string, string>): Promise<string> => {
    return i18n.System.getAppPreferredLanguage()
  }],
  ['LocalizationKit.System.getUsingLocalDigit', async (_params: Map<string, string>): Promise<string> => {
    return i18n.System.getUsingLocalDigit().toString()
  }],
  ['LocalizationKit.System.getTemperatureType', async (_params: Map<string, string>): Promise<string> => {
    return i18n.System.getTemperatureType().toString()
  }],
  ['LocalizationKit.System.getFirstDayOfWeek', async (_params: Map<string, string>): Promise<string> => {
    return i18n.System.getFirstDayOfWeek().toString()
  }],
  ['ArkUI.display.getDefaultDisplaySync', async (_params: Map<string, string>): Promise<string> => {
    return JSON.stringify(new SdkDisplayInfo(display.getDefaultDisplaySync()))
  }],
  ['ArkUI.display.getPrimaryDisplaySync', async (_params: Map<string, string>): Promise<string> => {
    return JSON.stringify(new SdkDisplayInfo(display.getPrimaryDisplaySync()))
  }],
  ['ArkUI.display.getAllDisplays', async (_params: Map<string, string>): Promise<string> => {
    let result = await display.getAllDisplays()
    return JSON.stringify(result.map((value: display.Display): SdkDisplayInfo => {
      return new SdkDisplayInfo(value)
    }))
  }],
  ['ArkUI.display.getAllDisplayPhysicalResolution', async (_params: Map<string, string>): Promise<string> => {
    let result = await display.getAllDisplayPhysicalResolution()
    return JSON.stringify(result.map((value: display.DisplayPhysicalResolution): SdkDisplayPhysicalResolutionInfo => {
      return new SdkDisplayPhysicalResolutionInfo(value)
    }))
  }],
  ['ArkUI.display.getFoldStatus', async (_params: Map<string, string>): Promise<string> => {
    return display.getFoldStatus().toString()
  }],
  ['ArkUI.display.getFoldDisplayMode', async (_params: Map<string, string>): Promise<string> => {
    return display.getFoldDisplayMode().toString()
  }],
  ['ArkUI.display.getCurrentFoldCreaseRegion', async (_params: Map<string, string>): Promise<string> => {
    return JSON.stringify(new SdkFoldCreaseRegionInfo(display.getCurrentFoldCreaseRegion()))
  }],
  // generated by tools/generate-sdk-backend.py -- do not hand-edit below this line
  ['AVSessionKit.avSession.isDesktopLyricSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Multimedia.AVSession.Core')) {
      let result = await avSession.isDesktopLyricSupported()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Multimedia.AVSession.Core')
  }],
  ['AVSessionKit.avSession.setDiscoverable', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Multimedia.AVSession.Core')) {
      if (canIUse('SystemCapability.Multimedia.AVSession.AVCast')) {
        let enable = paramBoolean(params, 'enable', false)
        await avSession.setDiscoverable(enable)
        return 'ok'
      }
      throw new Error('unsupported capability: SystemCapability.Multimedia.AVSession.AVCast')
    }
    throw new Error('unsupported capability: SystemCapability.Multimedia.AVSession.Core')
  }],
  ['AVSessionKit.avSession.startDeviceLogging', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Multimedia.AVSession.Core')) {
      if (canIUse('SystemCapability.Multimedia.AVSession.AVCast')) {
        let url = paramString(params, 'url', '')
        let maxSize = paramInt(params, 'maxSize', 0)
        await avSession.startDeviceLogging(url, maxSize)
        return 'ok'
      }
      throw new Error('unsupported capability: SystemCapability.Multimedia.AVSession.AVCast')
    }
    throw new Error('unsupported capability: SystemCapability.Multimedia.AVSession.Core')
  }],
  ['AVSessionKit.avSession.stopCastDeviceDiscovery', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Multimedia.AVSession.Core')) {
      if (canIUse('SystemCapability.Multimedia.AVSession.AVCast')) {
        await avSession.stopCastDeviceDiscovery()
        return 'ok'
      }
      throw new Error('unsupported capability: SystemCapability.Multimedia.AVSession.AVCast')
    }
    throw new Error('unsupported capability: SystemCapability.Multimedia.AVSession.Core')
  }],
  ['AVSessionKit.avSession.stopDeviceLogging', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Multimedia.AVSession.Core')) {
      if (canIUse('SystemCapability.Multimedia.AVSession.AVCast')) {
        await avSession.stopDeviceLogging()
        return 'ok'
      }
      throw new Error('unsupported capability: SystemCapability.Multimedia.AVSession.AVCast')
    }
    throw new Error('unsupported capability: SystemCapability.Multimedia.AVSession.Core')
  }],
  ['AbilityKit.abilityManager.isEmbeddedUIExtensionSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AbilityRuntime.Core')) {
      let result = abilityManager.isEmbeddedUIExtensionSupported()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AbilityRuntime.Core')
  }],
  ['AbilityKit.abilityManager.setResidentProcessEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AbilityRuntime.Core')) {
      let bundleName = paramString(params, 'bundleName', '')
      let enable = paramBoolean(params, 'enable', false)
      await abilityManager.setResidentProcessEnabled(bundleName, enable)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AbilityRuntime.Core')
  }],
  ['AbilityKit.appManager.getAppMemorySize', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AbilityRuntime.Core')) {
      let result = await appManager.getAppMemorySize()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AbilityRuntime.Core')
  }],
  ['AbilityKit.appManager.getProcessMemoryByPid', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AbilityRuntime.Core')) {
      let pid = paramInt(params, 'pid', 0)
      let result = await appManager.getProcessMemoryByPid(pid)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AbilityRuntime.Core')
  }],
  ['AbilityKit.appManager.isRamConstrainedDevice', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AbilityRuntime.Core')) {
      let result = await appManager.isRamConstrainedDevice()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AbilityRuntime.Core')
  }],
  ['AbilityKit.appManager.isRunningInStabilityTest', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AbilityRuntime.Core')) {
      let result = await appManager.isRunningInStabilityTest()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AbilityRuntime.Core')
  }],
  ['AbilityKit.appRecovery.restartApp', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AbilityRuntime.Core')) {
      appRecovery.restartApp()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AbilityRuntime.Core')
  }],
  ['AbilityKit.appRecovery.saveAppState', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AbilityRuntime.Core')) {
      let result = appRecovery.saveAppState()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AbilityRuntime.Core')
  }],
  ['AbilityKit.application.demoteCurrentFromCandidateMasterProcess', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AbilityRuntime.Core')) {
      await application.demoteCurrentFromCandidateMasterProcess()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AbilityRuntime.Core')
  }],
  ['AbilityKit.application.exitMasterProcessRole', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AbilityRuntime.Core')) {
      await application.exitMasterProcessRole()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AbilityRuntime.Core')
  }],
  ['AbilityKit.application.promoteCurrentToCandidateMasterProcess', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AbilityRuntime.Core')) {
      let insertToHead = paramBoolean(params, 'insertToHead', false)
      await application.promoteCurrentToCandidateMasterProcess(insertToHead)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AbilityRuntime.Core')
  }],
  ['AbilityKit.autoStartupManager.getAutoStartupStatusForSelf', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AbilityRuntime.Core')) {
      let result = await autoStartupManager.getAutoStartupStatusForSelf()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AbilityRuntime.Core')
  }],
  ['AbilityKit.autoStartupManager.isAutoStartupSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AbilityRuntime.Core')) {
      let result = autoStartupManager.isAutoStartupSupported()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AbilityRuntime.Core')
  }],
  ['AbilityKit.bundleManager.canOpenLink', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BundleManager.BundleFramework.Core')) {
      let link = paramString(params, 'link', '')
      let result = bundleManager.canOpenLink(link)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BundleManager.BundleFramework.Core')
  }],
  ['AbilityKit.bundleManager.cleanBundleCacheFilesForSelf', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BundleManager.BundleFramework.Core')) {
      await bundleManager.cleanBundleCacheFilesForSelf()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.BundleManager.BundleFramework.Core')
  }],
  ['AbilityKit.bundleManager.getAdditionalInfo', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BundleManager.BundleFramework.Core')) {
      let bundleName = paramString(params, 'bundleName', '')
      let result = bundleManager.getAdditionalInfo(bundleName)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BundleManager.BundleFramework.Core')
  }],
  ['AbilityKit.bundleManager.getAllBundleCacheSize', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BundleManager.BundleFramework.Core')) {
      let result = await bundleManager.getAllBundleCacheSize()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BundleManager.BundleFramework.Core')
  }],
  ['AbilityKit.bundleManager.getApplicationLabel', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BundleManager.BundleFramework.Core')) {
      if (canIUse('SystemCapability.BundleManager.BundleFramework.Resource')) {
        let bundleName = paramString(params, 'bundleName', '')
        let appIndex = paramInt(params, 'appIndex', 0)
        let result = await bundleManager.getApplicationLabel(bundleName, appIndex)
        return result.toString()
      }
      throw new Error('unsupported capability: SystemCapability.BundleManager.BundleFramework.Resource')
    }
    throw new Error('unsupported capability: SystemCapability.BundleManager.BundleFramework.Core')
  }],
  ['AbilityKit.bundleManager.getBundleNameByUid', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BundleManager.BundleFramework.Core')) {
      let uid = paramInt(params, 'uid', 0)
      let result = await bundleManager.getBundleNameByUid(uid)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BundleManager.BundleFramework.Core')
  }],
  ['AbilityKit.bundleManager.getBundleNameByUidSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BundleManager.BundleFramework.Core')) {
      let uid = paramInt(params, 'uid', 0)
      let result = bundleManager.getBundleNameByUidSync(uid)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BundleManager.BundleFramework.Core')
  }],
  ['AbilityKit.bundleManager.getDynamicIcon', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BundleManager.BundleFramework.Core')) {
      let bundleName = paramString(params, 'bundleName', '')
      let result = await bundleManager.getDynamicIcon(bundleName)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BundleManager.BundleFramework.Core')
  }],
  ['AbilityKit.bundleManager.getPluginBundlePathForSelf', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BundleManager.BundleFramework.Core')) {
      let pluginBundleName = paramString(params, 'pluginBundleName', '')
      let result = bundleManager.getPluginBundlePathForSelf(pluginBundleName)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BundleManager.BundleFramework.Core')
  }],
  ['AbilityKit.bundleManager.getSandboxDataDir', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BundleManager.BundleFramework.Core')) {
      let bundleName = paramString(params, 'bundleName', '')
      let appIndex = paramInt(params, 'appIndex', 0)
      let result = bundleManager.getSandboxDataDir(bundleName, appIndex)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BundleManager.BundleFramework.Core')
  }],
  ['AbilityKit.bundleManager.getSpecifiedDistributionType', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BundleManager.BundleFramework.Core')) {
      let bundleName = paramString(params, 'bundleName', '')
      let result = bundleManager.getSpecifiedDistributionType(bundleName)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BundleManager.BundleFramework.Core')
  }],
  ['AbilityKit.bundleManager.isApplicationEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BundleManager.BundleFramework.Core')) {
      let bundleName = paramString(params, 'bundleName', '')
      let result = await bundleManager.isApplicationEnabled(bundleName)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BundleManager.BundleFramework.Core')
  }],
  ['AbilityKit.bundleManager.isApplicationEnabledSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BundleManager.BundleFramework.Core')) {
      let bundleName = paramString(params, 'bundleName', '')
      let result = bundleManager.isApplicationEnabledSync(bundleName)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BundleManager.BundleFramework.Core')
  }],
  ['AbilityKit.bundleManager.setAdditionalInfo', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BundleManager.BundleFramework.Core')) {
      let bundleName = paramString(params, 'bundleName', '')
      let additionalInfo = paramString(params, 'additionalInfo', '')
      bundleManager.setAdditionalInfo(bundleName, additionalInfo)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.BundleManager.BundleFramework.Core')
  }],
  ['AbilityKit.bundleManager.setAlternateIcon', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BundleManager.BundleFramework.Core')) {
      let alternateIconName = paramString(params, 'alternateIconName', '')
      await bundleManager.setAlternateIcon(alternateIconName)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.BundleManager.BundleFramework.Core')
  }],
  ['AbilityKit.childProcessManager.isArkChildProcessSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AbilityRuntime.Core')) {
      let result = childProcessManager.isArkChildProcessSupported()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AbilityRuntime.Core')
  }],
  ['AbilityKit.childProcessManager.isNativeChildProcessSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AbilityRuntime.Core')) {
      let result = childProcessManager.isNativeChildProcessSupported()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AbilityRuntime.Core')
  }],
  ['AbilityKit.dataUriUtils.attachId', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AbilityRuntime.Core')) {
      let uri = paramString(params, 'uri', '')
      let id = paramFloat(params, 'id', 0)
      let result = dataUriUtils.attachId(uri, id)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AbilityRuntime.Core')
  }],
  ['AbilityKit.dataUriUtils.deleteId', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AbilityRuntime.Core')) {
      let uri = paramString(params, 'uri', '')
      let result = dataUriUtils.deleteId(uri)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AbilityRuntime.Core')
  }],
  ['AbilityKit.dataUriUtils.getId', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AbilityRuntime.Core')) {
      let uri = paramString(params, 'uri', '')
      let result = dataUriUtils.getId(uri)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AbilityRuntime.Core')
  }],
  ['AbilityKit.dataUriUtils.updateId', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AbilityRuntime.Core')) {
      let uri = paramString(params, 'uri', '')
      let id = paramFloat(params, 'id', 0)
      let result = dataUriUtils.updateId(uri, id)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AbilityRuntime.Core')
  }],
  ['AbilityKit.defaultAppManager.isDefaultApplication', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BundleManager.BundleFramework.DefaultApp')) {
      let type = paramString(params, 'type', '')
      let result = await defaultAppManager.isDefaultApplication(type)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BundleManager.BundleFramework.DefaultApp')
  }],
  ['AbilityKit.defaultAppManager.isDefaultApplicationSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BundleManager.BundleFramework.DefaultApp')) {
      let type = paramString(params, 'type', '')
      let result = defaultAppManager.isDefaultApplicationSync(type)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BundleManager.BundleFramework.DefaultApp')
  }],
  ['AbilityKit.distributedBundleManager.getRemoteBundleVersionCode', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BundleManager.DistributedBundleFramework')) {
      let deviceId = paramString(params, 'deviceId', '')
      let bundleName = paramString(params, 'bundleName', '')
      let result = await distributedBundleManager.getRemoteBundleVersionCode(deviceId, bundleName)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BundleManager.DistributedBundleFramework')
  }],
  ['AbilityKit.freeInstall.isHapModuleRemovable', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BundleManager.BundleFramework.FreeInstall')) {
      let bundleName = paramString(params, 'bundleName', '')
      let moduleName = paramString(params, 'moduleName', '')
      let result = await freeInstall.isHapModuleRemovable(bundleName, moduleName)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BundleManager.BundleFramework.FreeInstall')
  }],
  ['AbilityKit.hyperSnapManager.requestRebuildHyperSnap', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AbilityRuntime.Core')) {
      hyperSnapManager.requestRebuildHyperSnap()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AbilityRuntime.Core')
  }],
  ['AbilityKit.hyperSnapManager.setHyperSnapEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AbilityRuntime.Core')) {
      let enableFlag = paramBoolean(params, 'enableFlag', false)
      hyperSnapManager.setHyperSnapEnabled(enableFlag)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AbilityRuntime.Core')
  }],
  ['AbilityKit.overlay.setOverlayEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BundleManager.BundleFramework.Overlay')) {
      let moduleName = paramString(params, 'moduleName', '')
      let isEnabled = paramBoolean(params, 'isEnabled', false)
      await overlay.setOverlayEnabled(moduleName, isEnabled)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.BundleManager.BundleFramework.Overlay')
  }],
  ['AbilityKit.quickFixManager.revokeQuickFix', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AbilityRuntime.QuickFix')) {
      let bundleName = paramString(params, 'bundleName', '')
      await quickFixManager.revokeQuickFix(bundleName)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AbilityRuntime.QuickFix')
  }],
  ['AbilityKit.shortcutManager.isShortcutSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BundleManager.BundleFramework.Launcher')) {
      let result = shortcutManager.isShortcutSupported()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BundleManager.BundleFramework.Launcher')
  }],
  ['AbilityKit.shortcutManager.setShortcutVisibleForSelf', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BundleManager.BundleFramework.Launcher')) {
      let id = paramString(params, 'id', '')
      let visible = paramBoolean(params, 'visible', false)
      await shortcutManager.setShortcutVisibleForSelf(id, visible)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.BundleManager.BundleFramework.Launcher')
  }],
  ['AbilityKit.startupManager.isStartupTaskInitialized', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AppStartup')) {
      let startupTask = paramString(params, 'startupTask', '')
      let result = startupManager.isStartupTaskInitialized(startupTask)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AppStartup')
  }],
  ['AbilityKit.startupManager.removeAllStartupTaskResults', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AppStartup')) {
      startupManager.removeAllStartupTaskResults()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AppStartup')
  }],
  ['AbilityKit.startupManager.removeStartupTaskResult', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AppStartup')) {
      let startupTask = paramString(params, 'startupTask', '')
      startupManager.removeStartupTaskResult(startupTask)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AppStartup')
  }],
  ['AbilityKit.uriPermissionManager.revokeUriPermission', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AbilityRuntime.Core')) {
      let uri = paramString(params, 'uri', '')
      let targetBundleName = paramString(params, 'targetBundleName', '')
      await uriPermissionManager.revokeUriPermission(uri, targetBundleName)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AbilityRuntime.Core')
  }],
  ['AbilityKit.wantAgent.setWantAgentMultithreading', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.AbilityRuntime.Core')) {
      let isMultithreadingSupported = paramBoolean(params, 'isMultithreadingSupported', false)
      wantAgent.setWantAgentMultithreading(isMultithreadingSupported)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Ability.AbilityRuntime.Core')
  }],
  ['AccessibilityKit.accessibility.getSeniorModeStateForSelf', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BarrierFree.Accessibility.Core')) {
      let result = await accessibility.getSeniorModeStateForSelf()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BarrierFree.Accessibility.Core')
  }],
  ['AccessibilityKit.accessibility.getTouchModeSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BarrierFree.Accessibility.Core')) {
      let result = accessibility.getTouchModeSync()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BarrierFree.Accessibility.Core')
  }],
  ['AccessibilityKit.accessibility.isAnimationReduceEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BarrierFree.Accessibility.Core')) {
      let result = await accessibility.isAnimationReduceEnabled()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BarrierFree.Accessibility.Core')
  }],
  ['AccessibilityKit.accessibility.isAnimationReduceEnabledSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BarrierFree.Accessibility.Core')) {
      let result = accessibility.isAnimationReduceEnabledSync()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BarrierFree.Accessibility.Core')
  }],
  ['AccessibilityKit.accessibility.isAudioMonoEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BarrierFree.Accessibility.Core')) {
      let result = await accessibility.isAudioMonoEnabled()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BarrierFree.Accessibility.Core')
  }],
  ['AccessibilityKit.accessibility.isAudioMonoEnabledSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BarrierFree.Accessibility.Core')) {
      let result = accessibility.isAudioMonoEnabledSync()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BarrierFree.Accessibility.Core')
  }],
  ['AccessibilityKit.accessibility.isFlashReminderEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BarrierFree.Accessibility.Core')) {
      let result = await accessibility.isFlashReminderEnabled()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BarrierFree.Accessibility.Core')
  }],
  ['AccessibilityKit.accessibility.isFlashReminderEnabledSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BarrierFree.Accessibility.Core')) {
      let result = accessibility.isFlashReminderEnabledSync()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BarrierFree.Accessibility.Core')
  }],
  ['AccessibilityKit.accessibility.isOpenAccessibilitySync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BarrierFree.Accessibility.Core')) {
      let result = accessibility.isOpenAccessibilitySync()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BarrierFree.Accessibility.Core')
  }],
  ['AccessibilityKit.accessibility.isOpenTouchGuideSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BarrierFree.Accessibility.Core')) {
      if (canIUse('SystemCapability.BarrierFree.Accessibility.Vision')) {
        let result = accessibility.isOpenTouchGuideSync()
        return result.toString()
      }
      throw new Error('unsupported capability: SystemCapability.BarrierFree.Accessibility.Vision')
    }
    throw new Error('unsupported capability: SystemCapability.BarrierFree.Accessibility.Core')
  }],
  ['AccessibilityKit.accessibility.isScreenReaderOpenSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BarrierFree.Accessibility.Core')) {
      if (canIUse('SystemCapability.BarrierFree.Accessibility.Vision')) {
        let result = accessibility.isScreenReaderOpenSync()
        return result.toString()
      }
      throw new Error('unsupported capability: SystemCapability.BarrierFree.Accessibility.Vision')
    }
    throw new Error('unsupported capability: SystemCapability.BarrierFree.Accessibility.Core')
  }],
  ['AccessibilityKit.accessibility.isSeniorModeEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BarrierFree.Accessibility.Core')) {
      let result = await accessibility.isSeniorModeEnabled()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BarrierFree.Accessibility.Core')
  }],
  ['AccessibilityKit.accessibility.setSeniorModeStateForSelf', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BarrierFree.Accessibility.Core')) {
      let state = paramBoolean(params, 'state', false)
      await accessibility.setSeniorModeStateForSelf(state)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.BarrierFree.Accessibility.Core')
  }],
  ['AdsKit.identifier.resetOAID', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Advertising.OAID')) {
      identifier.resetOAID()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Advertising.OAID')
  }],
  ['ArkData.distributedDataObject.genSessionId', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.DistributedDataManager.DataObject.DistributedObject')) {
      let result = distributedDataObject.genSessionId()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.DistributedDataManager.DataObject.DistributedObject')
  }],
  ['ArkData.relationalStore.isVectorSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.DistributedDataManager.RelationalStore.Core')) {
      let result = relationalStore.isVectorSupported()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.DistributedDataManager.RelationalStore.Core')
  }],
  ['ArkData.uniformTypeDescriptor.getUniformDataTypeByFilenameExtension', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.DistributedDataManager.UDMF.Core')) {
      let filenameExtension = paramString(params, 'filenameExtension', '')
      let belongsTo = paramString(params, 'belongsTo', '')
      let result = uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(filenameExtension, belongsTo)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.DistributedDataManager.UDMF.Core')
  }],
  ['ArkData.uniformTypeDescriptor.getUniformDataTypeByMIMEType', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.DistributedDataManager.UDMF.Core')) {
      let mimeType = paramString(params, 'mimeType', '')
      let belongsTo = paramString(params, 'belongsTo', '')
      let result = uniformTypeDescriptor.getUniformDataTypeByMIMEType(mimeType, belongsTo)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.DistributedDataManager.UDMF.Core')
  }],
  ['ArkTS.buffer.isEncoding', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Utils.Lang')) {
      let encoding = paramString(params, 'encoding', '')
      let result = buffer.isEncoding(encoding)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Utils.Lang')
  }],
  ['ArkTS.fastbuffer.isEncoding', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Utils.Lang')) {
      let encoding = paramString(params, 'encoding', '')
      let result = fastbuffer.isEncoding(encoding)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Utils.Lang')
  }],
  ['ArkTS.process.abort', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Utils.Lang')) {
      process.abort()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Utils.Lang')
  }],
  ['ArkTS.process.chdir', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Utils.Lang')) {
      let dir = paramString(params, 'dir', '')
      process.chdir(dir)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Utils.Lang')
  }],
  ['ArkTS.process.cwd', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Utils.Lang')) {
      let result = process.cwd()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Utils.Lang')
  }],
  ['ArkTS.process.getPastCpuTime', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Utils.Lang')) {
      let result = process.getPastCpuTime()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Utils.Lang')
  }],
  ['ArkTS.process.getStartRealtime', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Utils.Lang')) {
      let result = process.getStartRealtime()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Utils.Lang')
  }],
  ['ArkTS.process.is64Bit', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Utils.Lang')) {
      let result = process.is64Bit()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Utils.Lang')
  }],
  ['ArkTS.process.isIsolatedProcess', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Utils.Lang')) {
      let result = process.isIsolatedProcess()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Utils.Lang')
  }],
  ['ArkTS.process.off', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Utils.Lang')) {
      let type = paramString(params, 'type', '')
      let result = process.off(type)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Utils.Lang')
  }],
  ['ArkTS.process.uptime', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Utils.Lang')) {
      let result = process.uptime()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Utils.Lang')
  }],
  ['ArkTS.taskpool.cancel', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Utils.Lang')) {
      let taskId = paramFloat(params, 'taskId', 0)
      taskpool.cancel(taskId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Utils.Lang')
  }],
  ['ArkTS.util.errnoToString', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Utils.Lang')) {
      let errno = paramFloat(params, 'errno', 0)
      let result = util.errnoToString(errno)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Utils.Lang')
  }],
  ['ArkTS.util.generateRandomUUID', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Utils.Lang')) {
      let entropyCache = paramBoolean(params, 'entropyCache', false)
      let result = util.generateRandomUUID(entropyCache)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Utils.Lang')
  }],
  ['ArkTS.util.getMainThreadStackTrace', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Utils.Lang')) {
      let result = util.getMainThreadStackTrace()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Utils.Lang')
  }],
  ['ArkUI.PiPWindow.isPiPEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Window.SessionManager')) {
      let result = PiPWindow.isPiPEnabled()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Window.SessionManager')
  }],
  ['ArkUI.display.hasPrivateWindow', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.WindowManager.WindowManager.Core')) {
      let displayId = paramInt(params, 'displayId', 0)
      let result = display.hasPrivateWindow(displayId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.WindowManager.WindowManager.Core')
  }],
  ['ArkUI.display.isCaptured', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.WindowManager.WindowManager.Core')) {
      if (canIUse('SystemCapability.Window.SessionManager')) {
        let result = display.isCaptured()
        return result.toString()
      }
      throw new Error('unsupported capability: SystemCapability.Window.SessionManager')
    }
    throw new Error('unsupported capability: SystemCapability.WindowManager.WindowManager.Core')
  }],
  ['ArkUI.display.isFoldable', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.WindowManager.WindowManager.Core')) {
      if (canIUse('SystemCapability.Window.SessionManager')) {
        let result = display.isFoldable()
        return result.toString()
      }
      throw new Error('unsupported capability: SystemCapability.Window.SessionManager')
    }
    throw new Error('unsupported capability: SystemCapability.WindowManager.WindowManager.Core')
  }],
  ['ArkUI.display.removeVirtualScreenSurface', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.WindowManager.WindowManager.Core')) {
      if (canIUse('SystemCapability.Window.SessionManager')) {
        let screenId = paramInt(params, 'screenId', 0)
        let surfaceId = paramString(params, 'surfaceId', '')
        await display.removeVirtualScreenSurface(screenId, surfaceId)
        return 'ok'
      }
      throw new Error('unsupported capability: SystemCapability.Window.SessionManager')
    }
    throw new Error('unsupported capability: SystemCapability.WindowManager.WindowManager.Core')
  }],
  ['ArkUI.display.setFoldStatusLocked', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.WindowManager.WindowManager.Core')) {
      if (canIUse('SystemCapability.Window.SessionManager')) {
        let locked = paramBoolean(params, 'locked', false)
        display.setFoldStatusLocked(locked)
        return 'ok'
      }
      throw new Error('unsupported capability: SystemCapability.Window.SessionManager')
    }
    throw new Error('unsupported capability: SystemCapability.WindowManager.WindowManager.Core')
  }],
  ['ArkUI.floatView.isFloatViewEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Window.SessionManager')) {
      let result = floatView.isFloatViewEnabled()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Window.SessionManager')
  }],
  ['ArkUI.floatingBall.isFloatingBallEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Window.SessionManager')) {
      let result = floatingBall.isFloatingBallEnabled()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Window.SessionManager')
  }],
  ['ArkUI.performanceMonitor.end', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.ArkUI.ArkUI.Full')) {
      let scene = paramString(params, 'scene', '')
      performanceMonitor.end(scene)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.ArkUI.ArkUI.Full')
  }],
  ['ArkUI.promptAction.closeToast', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.ArkUI.ArkUI.Full')) {
      let toastId = paramFloat(params, 'toastId', 0)
      promptAction.closeToast(toastId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.ArkUI.ArkUI.Full')
  }],
  ['ArkUI.screen.destroyVirtualScreen', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.WindowManager.WindowManager.Core')) {
      let screenId = paramInt(params, 'screenId', 0)
      await screen.destroyVirtualScreen(screenId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.WindowManager.WindowManager.Core')
  }],
  ['ArkUI.screen.isScreenRotationLocked', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.WindowManager.WindowManager.Core')) {
      let result = await screen.isScreenRotationLocked()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.WindowManager.WindowManager.Core')
  }],
  ['ArkUI.screen.setScreenRotationLocked', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.WindowManager.WindowManager.Core')) {
      let isLocked = paramBoolean(params, 'isLocked', false)
      await screen.setScreenRotationLocked(isLocked)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.WindowManager.WindowManager.Core')
  }],
  ['ArkUI.window.getGlobalWindowMode', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.WindowManager.WindowManager.Core')) {
      if (canIUse('SystemCapability.Window.SessionManager')) {
        let displayId = paramInt(params, 'displayId', 0)
        let result = await window.getGlobalWindowMode(displayId)
        return result.toString()
      }
      throw new Error('unsupported capability: SystemCapability.Window.SessionManager')
    }
    throw new Error('unsupported capability: SystemCapability.WindowManager.WindowManager.Core')
  }],
  ['ArkUI.window.getTopNavDestinationName', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.WindowManager.WindowManager.Core')) {
      if (canIUse('SystemCapability.Window.SessionManager')) {
        let windowId = paramInt(params, 'windowId', 0)
        let result = await window.getTopNavDestinationName(windowId)
        return result.toString()
      }
      throw new Error('unsupported capability: SystemCapability.Window.SessionManager')
    }
    throw new Error('unsupported capability: SystemCapability.WindowManager.WindowManager.Core')
  }],
  ['ArkUI.window.minimizeAll', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.WindowManager.WindowManager.Core')) {
      let id = paramInt(params, 'id', 0)
      await window.minimizeAll(id)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.WindowManager.WindowManager.Core')
  }],
  ['ArkUI.window.minimizeAllWithExclusion', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.WindowManager.WindowManager.Core')) {
      let displayId = paramInt(params, 'displayId', 0)
      let excludeWindowId = paramInt(params, 'excludeWindowId', 0)
      await window.minimizeAllWithExclusion(displayId, excludeWindowId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.WindowManager.WindowManager.Core')
  }],
  ['ArkUI.window.setGestureNavigationEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.WindowManager.WindowManager.Core')) {
      let enable = paramBoolean(params, 'enable', false)
      await window.setGestureNavigationEnabled(enable)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.WindowManager.WindowManager.Core')
  }],
  ['ArkUI.window.shiftAppWindowFocus', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.WindowManager.WindowManager.Core')) {
      if (canIUse('SystemCapability.Window.SessionManager')) {
        let sourceWindowId = paramInt(params, 'sourceWindowId', 0)
        let targetWindowId = paramInt(params, 'targetWindowId', 0)
        await window.shiftAppWindowFocus(sourceWindowId, targetWindowId)
        return 'ok'
      }
      throw new Error('unsupported capability: SystemCapability.Window.SessionManager')
    }
    throw new Error('unsupported capability: SystemCapability.WindowManager.WindowManager.Core')
  }],
  ['ArkUI.window.shiftAppWindowPointerEvent', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.WindowManager.WindowManager.Core')) {
      if (canIUse('SystemCapability.Window.SessionManager')) {
        let sourceWindowId = paramInt(params, 'sourceWindowId', 0)
        let targetWindowId = paramInt(params, 'targetWindowId', 0)
        await window.shiftAppWindowPointerEvent(sourceWindowId, targetWindowId)
        return 'ok'
      }
      throw new Error('unsupported capability: SystemCapability.Window.SessionManager')
    }
    throw new Error('unsupported capability: SystemCapability.WindowManager.WindowManager.Core')
  }],
  ['ArkUI.window.toggleShownStateForAllAppWindows', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.WindowManager.WindowManager.Core')) {
      await window.toggleShownStateForAllAppWindows()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.WindowManager.WindowManager.Core')
  }],
  ['BackgroundTasksKit.backgroundProcessManager.resetProcessPriority', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Resourceschedule.BackgroundProcessManager')) {
      let pid = paramInt(params, 'pid', 0)
      await backgroundProcessManager.resetProcessPriority(pid)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Resourceschedule.BackgroundProcessManager')
  }],
  ['BackgroundTasksKit.backgroundTaskManager.cancelSuspendDelay', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')) {
      if (canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.TransientTask')) {
        let requestId = paramInt(params, 'requestId', 0)
        backgroundTaskManager.cancelSuspendDelay(requestId)
        return 'ok'
      }
      throw new Error('unsupported capability: SystemCapability.ResourceSchedule.BackgroundTaskManager.TransientTask')
    }
    throw new Error('unsupported capability: SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')
  }],
  ['BackgroundTasksKit.backgroundTaskManager.getRemainingDelayTime', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')) {
      if (canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.TransientTask')) {
        let requestId = paramInt(params, 'requestId', 0)
        let result = await backgroundTaskManager.getRemainingDelayTime(requestId)
        return result.toString()
      }
      throw new Error('unsupported capability: SystemCapability.ResourceSchedule.BackgroundTaskManager.TransientTask')
    }
    throw new Error('unsupported capability: SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')
  }],
  ['BackgroundTasksKit.backgroundTaskManager.resetAllEfficiencyResources', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')) {
      if (canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.EfficiencyResourcesApply')) {
        backgroundTaskManager.resetAllEfficiencyResources()
        return 'ok'
      }
      throw new Error('unsupported capability: SystemCapability.ResourceSchedule.BackgroundTaskManager.EfficiencyResourcesApply')
    }
    throw new Error('unsupported capability: SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')
  }],
  ['BackgroundTasksKit.reminderAgentManager.cancelAllReminders', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.ReminderAgent')) {
      await reminderAgentManager.cancelAllReminders()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Notification.ReminderAgent')
  }],
  ['BackgroundTasksKit.reminderAgentManager.cancelReminder', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.ReminderAgent')) {
      let reminderId = paramInt(params, 'reminderId', 0)
      await reminderAgentManager.cancelReminder(reminderId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Notification.ReminderAgent')
  }],
  ['BackgroundTasksKit.reminderAgentManager.cancelReminderOnDisplay', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.ReminderAgent')) {
      let reminderId = paramInt(params, 'reminderId', 0)
      await reminderAgentManager.cancelReminderOnDisplay(reminderId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Notification.ReminderAgent')
  }],
  ['BackgroundTasksKit.reminderAgentManager.deleteExcludeDates', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.ReminderAgent')) {
      let reminderId = paramInt(params, 'reminderId', 0)
      await reminderAgentManager.deleteExcludeDates(reminderId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Notification.ReminderAgent')
  }],
  ['BackgroundTasksKit.workScheduler.isLastWorkTimeOut', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.ResourceSchedule.WorkScheduler')) {
      let workId = paramInt(params, 'workId', 0)
      let result = await workScheduler.isLastWorkTimeOut(workId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.ResourceSchedule.WorkScheduler')
  }],
  ['BackgroundTasksKit.workScheduler.stopAndClearWorks', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.ResourceSchedule.WorkScheduler')) {
      workScheduler.stopAndClearWorks()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.ResourceSchedule.WorkScheduler')
  }],
  ['BasicServicesKit.batteryInfo.getBatteryConfig', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.PowerManager.BatteryManager.Core')) {
      let sceneName = paramString(params, 'sceneName', '')
      let result = batteryInfo.getBatteryConfig(sceneName)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.PowerManager.BatteryManager.Core')
  }],
  ['BasicServicesKit.batteryInfo.isBatteryConfigSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.PowerManager.BatteryManager.Core')) {
      let sceneName = paramString(params, 'sceneName', '')
      let result = batteryInfo.isBatteryConfigSupported(sceneName)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.PowerManager.BatteryManager.Core')
  }],
  ['BasicServicesKit.batteryInfo.setBatteryConfig', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.PowerManager.BatteryManager.Core')) {
      let sceneName = paramString(params, 'sceneName', '')
      let sceneValue = paramString(params, 'sceneValue', '')
      let result = batteryInfo.setBatteryConfig(sceneName, sceneValue)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.PowerManager.BatteryManager.Core')
  }],
  ['BasicServicesKit.batteryStats.getAppPowerPercent', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.PowerManager.BatteryStatistics')) {
      let uid = paramInt(params, 'uid', 0)
      let result = batteryStats.getAppPowerPercent(uid)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.PowerManager.BatteryStatistics')
  }],
  ['BasicServicesKit.batteryStats.getAppPowerValue', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.PowerManager.BatteryStatistics')) {
      let uid = paramInt(params, 'uid', 0)
      let result = batteryStats.getAppPowerValue(uid)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.PowerManager.BatteryStatistics')
  }],
  ['BasicServicesKit.brightness.setValue', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.PowerManager.DisplayPowerManager')) {
      let value = paramInt(params, 'value', 0)
      brightness.setValue(value)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.PowerManager.DisplayPowerManager')
  }],
  ['BasicServicesKit.cacheDownload.cancel', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Request.FileTransferAgent')) {
      let url = paramString(params, 'url', '')
      cacheDownload.cancel(url)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Request.FileTransferAgent')
  }],
  ['BasicServicesKit.cacheDownload.clearFileCache', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Request.FileTransferAgent')) {
      cacheDownload.clearFileCache()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Request.FileTransferAgent')
  }],
  ['BasicServicesKit.cacheDownload.clearMemoryCache', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Request.FileTransferAgent')) {
      cacheDownload.clearMemoryCache()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Request.FileTransferAgent')
  }],
  ['BasicServicesKit.cacheDownload.setDownloadInfoListSize', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Request.FileTransferAgent')) {
      let size = paramInt(params, 'size', 0)
      cacheDownload.setDownloadInfoListSize(size)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Request.FileTransferAgent')
  }],
  ['BasicServicesKit.cacheDownload.setFileCacheSize', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Request.FileTransferAgent')) {
      let bytes = paramInt(params, 'bytes', 0)
      cacheDownload.setFileCacheSize(bytes)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Request.FileTransferAgent')
  }],
  ['BasicServicesKit.cacheDownload.setMemoryCacheSize', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Request.FileTransferAgent')) {
      let bytes = paramInt(params, 'bytes', 0)
      cacheDownload.setMemoryCacheSize(bytes)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Request.FileTransferAgent')
  }],
  ['BasicServicesKit.commonEventManager.setStaticSubscriberState', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.CommonEvent')) {
      let enable = paramBoolean(params, 'enable', false)
      await commonEventManager.setStaticSubscriberState(enable)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Notification.CommonEvent')
  }],
  ['BasicServicesKit.configPolicy.getOneCfgFile', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Customization.ConfigPolicy')) {
      let relPath = paramString(params, 'relPath', '')
      let result = await configPolicy.getOneCfgFile(relPath)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Customization.ConfigPolicy')
  }],
  ['BasicServicesKit.customConfig.getChannelId', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Customization.CustomConfig')) {
      let result = customConfig.getChannelId()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Customization.CustomConfig')
  }],
  ['BasicServicesKit.emitter.emit', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Emitter')) {
      let eventId = paramString(params, 'eventId', '')
      emitter.emit(eventId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Emitter')
  }],
  ['BasicServicesKit.emitter.off', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Emitter')) {
      let eventId = paramInt(params, 'eventId', 0)
      emitter.off(eventId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Emitter')
  }],
  ['BasicServicesKit.osAccount.isDomainAccountSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Account.OsAccount')) {
      let result = await osAccount.isDomainAccountSupported()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Account.OsAccount')
  }],
  ['BasicServicesKit.power.isActive', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.PowerManager.PowerManager.Core')) {
      let result = power.isActive()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.PowerManager.PowerManager.Core')
  }],
  ['BasicServicesKit.power.isStandby', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.PowerManager.PowerManager.Core')) {
      let result = power.isStandby()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.PowerManager.PowerManager.Core')
  }],
  ['BasicServicesKit.screenLock.isDeviceLocked', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MiscServices.ScreenLock')) {
      let userId = paramInt(params, 'userId', 0)
      let result = screenLock.isDeviceLocked(userId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MiscServices.ScreenLock')
  }],
  ['BasicServicesKit.screenLock.isLocked', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MiscServices.ScreenLock')) {
      let result = screenLock.isLocked()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MiscServices.ScreenLock')
  }],
  ['BasicServicesKit.screenLock.unlock', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MiscServices.ScreenLock')) {
      let result = await screenLock.unlock()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MiscServices.ScreenLock')
  }],
  ['BasicServicesKit.selectionManager.getSelectionContent', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.SelectionInput.Selection')) {
      let result = await selectionManager.getSelectionContent()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.SelectionInput.Selection')
  }],
  ['BasicServicesKit.serial.addPortAuthorization', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BusManager.Serial')) {
      let tokenId = paramString(params, 'tokenId', '')
      let deviceId = paramString(params, 'deviceId', '')
      await serial.addPortAuthorization(tokenId, deviceId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.BusManager.Serial')
  }],
  ['BasicServicesKit.serialManager.cancelSerialRight', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.USB.USBManager.Serial')) {
      let portId = paramInt(params, 'portId', 0)
      serialManager.cancelSerialRight(portId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.USB.USBManager.Serial')
  }],
  ['BasicServicesKit.serialManager.close', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.USB.USBManager.Serial')) {
      let portId = paramInt(params, 'portId', 0)
      serialManager.close(portId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.USB.USBManager.Serial')
  }],
  ['BasicServicesKit.serialManager.hasSerialRight', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.USB.USBManager.Serial')) {
      let portId = paramInt(params, 'portId', 0)
      let result = serialManager.hasSerialRight(portId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.USB.USBManager.Serial')
  }],
  ['BasicServicesKit.serialManager.open', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.USB.USBManager.Serial')) {
      let portId = paramInt(params, 'portId', 0)
      serialManager.open(portId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.USB.USBManager.Serial')
  }],
  ['BasicServicesKit.serialManager.requestSerialRight', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.USB.USBManager.Serial')) {
      let portId = paramInt(params, 'portId', 0)
      let result = await serialManager.requestSerialRight(portId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.USB.USBManager.Serial')
  }],
  ['BasicServicesKit.settings.isDoubleClickAppForSelf', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Applications.Settings.Core')) {
      let result = await settings.isDoubleClickAppForSelf()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Applications.Settings.Core')
  }],
  ['BasicServicesKit.systemCapability.querySystemCapabilities', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Developtools.Syscap')) {
      let result = await systemCapability.querySystemCapabilities()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Developtools.Syscap')
  }],
  ['BasicServicesKit.systemDateTime.getAutoTimeStatus', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MiscServices.Time')) {
      let result = systemDateTime.getAutoTimeStatus()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MiscServices.Time')
  }],
  ['BasicServicesKit.systemDateTime.getNtpTime', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MiscServices.Time')) {
      let result = systemDateTime.getNtpTime()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MiscServices.Time')
  }],
  ['BasicServicesKit.systemDateTime.getTime', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MiscServices.Time')) {
      let isNanoseconds = paramBoolean(params, 'isNanoseconds', false)
      let result = systemDateTime.getTime(isNanoseconds)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MiscServices.Time')
  }],
  ['BasicServicesKit.systemDateTime.getTimezone', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MiscServices.Time')) {
      let result = await systemDateTime.getTimezone()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MiscServices.Time')
  }],
  ['BasicServicesKit.systemDateTime.getTimezoneSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MiscServices.Time')) {
      let result = systemDateTime.getTimezoneSync()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MiscServices.Time')
  }],
  ['BasicServicesKit.systemDateTime.updateNtpTime', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MiscServices.Time')) {
      await systemDateTime.updateNtpTime()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.MiscServices.Time')
  }],
  ['BasicServicesKit.systemParameterEnhance.getSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Startup.SystemInfo')) {
      let key = paramString(params, 'key', '')
      let def = paramString(params, 'def', '')
      let result = systemParameterEnhance.getSync(key, def)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Startup.SystemInfo')
  }],
  ['BasicServicesKit.systemParameterEnhance.setSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Startup.SystemInfo')) {
      let key = paramString(params, 'key', '')
      let value = paramString(params, 'value', '')
      systemParameterEnhance.setSync(key, value)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Startup.SystemInfo')
  }],
  // No systemTimer rows: startTimer, stopTimer and destroyTimer take a timer id that only createTimer hands
  // out, together with what to do when it fires -- a callback no program can pass, so createTimer has no row
  // either. With rows, find_sdk_function offered them for "egg timer" and a widget started timer "1", which
  // does nothing. A timer belongs in the program (ui.Ticker).
  ['BasicServicesKit.usbManager.hasRight', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.USB.USBManager')) {
      let deviceName = paramString(params, 'deviceName', '')
      let result = usbManager.hasRight(deviceName)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.USB.USBManager')
  }],
  ['BasicServicesKit.usbManager.removeRight', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.USB.USBManager')) {
      let deviceName = paramString(params, 'deviceName', '')
      let result = usbManager.removeRight(deviceName)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.USB.USBManager')
  }],
  ['BasicServicesKit.usbManager.requestRight', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.USB.USBManager')) {
      let deviceName = paramString(params, 'deviceName', '')
      let result = await usbManager.requestRight(deviceName)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.USB.USBManager')
  }],
  ['BasicServicesKit.wallpaper.getMinHeightSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MiscServices.Wallpaper')) {
      let result = wallpaper.getMinHeightSync()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MiscServices.Wallpaper')
  }],
  ['BasicServicesKit.wallpaper.getMinWidthSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MiscServices.Wallpaper')) {
      let result = wallpaper.getMinWidthSync()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MiscServices.Wallpaper')
  }],
  ['BasicServicesKit.zlib.getOriginalSize', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.BundleManager.Zlib')) {
      let compressedFile = paramString(params, 'compressedFile', '')
      let result = await zlib.getOriginalSize(compressedFile)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.BundleManager.Zlib')
  }],
  ['ConnectivityKit.access.convertUuid', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.Bluetooth.Core')) {
      let uuid = paramString(params, 'uuid', '')
      let result = access.convertUuid(uuid)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.Bluetooth.Core')
  }],
  ['ConnectivityKit.access.isBluetoothSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.Bluetooth.Core')) {
      let result = access.isBluetoothSupported()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.Bluetooth.Core')
  }],
  ['ConnectivityKit.connection.getCarKeyDfxData', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.Bluetooth.Core')) {
      let result = bluetoothConnection.getCarKeyDfxData()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.Bluetooth.Core')
  }],
  ['ConnectivityKit.connection.getLastConnectionTime', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.Bluetooth.Core')) {
      let deviceId = paramString(params, 'deviceId', '')
      let result = await bluetoothConnection.getLastConnectionTime(deviceId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.Bluetooth.Core')
  }],
  ['ConnectivityKit.nfcController.isNfcOpen', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.NFC.Core')) {
      let result = nfcController.isNfcOpen()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.NFC.Core')
  }],
  ['ConnectivityKit.partnerAgent.isPartnerAgentSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.FusionConnectivity.Core')) {
      let result = partnerAgent.isPartnerAgentSupported()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.FusionConnectivity.Core')
  }],
  ['ConnectivityKit.ranging.isRangingSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.FusionConnectivity.Core')) {
      let result = ranging.isRangingSupported()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.FusionConnectivity.Core')
  }],
  ['ConnectivityKit.socket.getDeviceId', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.Bluetooth.Core')) {
      let clientSocket = paramInt(params, 'clientSocket', 0)
      let result: string = socket.getDeviceId(clientSocket)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.Bluetooth.Core')
  }],
  ['ConnectivityKit.socket.getL2capPsm', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.Bluetooth.Core')) {
      let serverSocket = paramInt(params, 'serverSocket', 0)
      let result: number = socket.getL2capPsm(serverSocket)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.Bluetooth.Core')
  }],
  ['ConnectivityKit.socket.getMaxReceiveDataSize', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.Bluetooth.Core')) {
      let clientSocket = paramInt(params, 'clientSocket', 0)
      let result: number = socket.getMaxReceiveDataSize(clientSocket)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.Bluetooth.Core')
  }],
  ['ConnectivityKit.socket.getMaxTransmitDataSize', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.Bluetooth.Core')) {
      let clientSocket = paramInt(params, 'clientSocket', 0)
      let result: number = socket.getMaxTransmitDataSize(clientSocket)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.Bluetooth.Core')
  }],
  ['ConnectivityKit.socket.isConnected', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.Bluetooth.Core')) {
      let clientSocket = paramInt(params, 'clientSocket', 0)
      let result: boolean = socket.isConnected(clientSocket)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.Bluetooth.Core')
  }],
  ['ConnectivityKit.socket.sppCloseClientSocket', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.Bluetooth.Core')) {
      let socket_ = paramInt(params, 'socket', 0)
      socket.sppCloseClientSocket(socket_)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Communication.Bluetooth.Core')
  }],
  ['ConnectivityKit.socket.sppCloseServerSocket', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.Bluetooth.Core')) {
      let socket_ = paramInt(params, 'socket', 0)
      socket.sppCloseServerSocket(socket_)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Communication.Bluetooth.Core')
  }],
  ['ConnectivityKit.wifiManager.allowAutoConnect', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      let netId = paramInt(params, 'netId', 0)
      let isAllowed = paramBoolean(params, 'isAllowed', false)
      wifiManager.allowAutoConnect(netId, isAllowed)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.connectToCandidateConfig', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      let networkId = paramInt(params, 'networkId', 0)
      wifiManager.connectToCandidateConfig(networkId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.connectToCandidateConfigWithUserAction', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      let networkId = paramInt(params, 'networkId', 0)
      await wifiManager.connectToCandidateConfigWithUserAction(networkId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.deletePersistentGroup', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      if (canIUse('SystemCapability.Communication.WiFi.P2P')) {
        let netId = paramInt(params, 'netId', 0)
        wifiManager.deletePersistentGroup(netId)
        return 'ok'
      }
      throw new Error('unsupported capability: SystemCapability.Communication.WiFi.P2P')
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.disableNetwork', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      let netId = paramInt(params, 'netId', 0)
      wifiManager.disableNetwork(netId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.disableWifi', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      wifiManager.disableWifi()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.disconnect', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      wifiManager.disconnect()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.enableSemiWifi', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      wifiManager.enableSemiWifi()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.enableWifi', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      wifiManager.enableWifi()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.factoryReset', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      wifiManager.factoryReset()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.getCountryCode', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      if (canIUse('SystemCapability.Communication.WiFi.Core')) {
        let result = wifiManager.getCountryCode()
        return result.toString()
      }
      throw new Error('unsupported capability: SystemCapability.Communication.WiFi.Core')
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.getScanAlwaysAllowed', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      let result = wifiManager.getScanAlwaysAllowed()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.getSignalLevel', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      let rssi = paramInt(params, 'rssi', 0)
      let band = paramInt(params, 'band', 0)
      let result = wifiManager.getSignalLevel(rssi, band)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.getSupportedFeatures', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      if (canIUse('SystemCapability.Communication.WiFi.Core')) {
        let result = wifiManager.getSupportedFeatures()
        return result.toString()
      }
      throw new Error('unsupported capability: SystemCapability.Communication.WiFi.Core')
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.isConnected', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      let result = wifiManager.isConnected()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.isFeatureSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      if (canIUse('SystemCapability.Communication.WiFi.Core')) {
        let featureId = paramInt(params, 'featureId', 0)
        let result = wifiManager.isFeatureSupported(featureId)
        return result.toString()
      }
      throw new Error('unsupported capability: SystemCapability.Communication.WiFi.Core')
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.isHotspotActive', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      if (canIUse('SystemCapability.Communication.WiFi.AP.Core')) {
        let result = wifiManager.isHotspotActive()
        return result.toString()
      }
      throw new Error('unsupported capability: SystemCapability.Communication.WiFi.AP.Core')
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.isHotspotDualBandSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      if (canIUse('SystemCapability.Communication.WiFi.AP.Core')) {
        let result = wifiManager.isHotspotDualBandSupported()
        return result.toString()
      }
      throw new Error('unsupported capability: SystemCapability.Communication.WiFi.AP.Core')
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.isMeteredHotspot', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      let result = wifiManager.isMeteredHotspot()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.isOpenSoftApAllowed', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      if (canIUse('SystemCapability.Communication.WiFi.AP.Core')) {
        let result = wifiManager.isOpenSoftApAllowed()
        return result.toString()
      }
      throw new Error('unsupported capability: SystemCapability.Communication.WiFi.AP.Core')
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.isRandomMacDisabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      let result = wifiManager.isRandomMacDisabled()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.isWifiActive', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      let result = wifiManager.isWifiActive()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.isWlanSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      if (canIUse('SystemCapability.Communication.WiFi.Core')) {
        let result = wifiManager.isWlanSupported()
        return result.toString()
      }
      throw new Error('unsupported capability: SystemCapability.Communication.WiFi.Core')
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.p2pCancelConnect', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      if (canIUse('SystemCapability.Communication.WiFi.P2P')) {
        wifiManager.p2pCancelConnect()
        return 'ok'
      }
      throw new Error('unsupported capability: SystemCapability.Communication.WiFi.P2P')
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.reassociate', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      wifiManager.reassociate()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.reconnect', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      wifiManager.reconnect()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.removeAllNetwork', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      wifiManager.removeAllNetwork()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.removeCandidateConfig', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      let networkId = paramInt(params, 'networkId', 0)
      await wifiManager.removeCandidateConfig(networkId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.removeDevice', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      let id = paramInt(params, 'id', 0)
      wifiManager.removeDevice(id)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.removeGroup', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      if (canIUse('SystemCapability.Communication.WiFi.P2P')) {
        wifiManager.removeGroup()
        return 'ok'
      }
      throw new Error('unsupported capability: SystemCapability.Communication.WiFi.P2P')
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.setDeviceName', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      if (canIUse('SystemCapability.Communication.WiFi.P2P')) {
        let devName = paramString(params, 'devName', '')
        wifiManager.setDeviceName(devName)
        return 'ok'
      }
      throw new Error('unsupported capability: SystemCapability.Communication.WiFi.P2P')
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.setScanAlwaysAllowed', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      let isScanAlwaysAllowed = paramBoolean(params, 'isScanAlwaysAllowed', false)
      wifiManager.setScanAlwaysAllowed(isScanAlwaysAllowed)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.startDiscoverDevices', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      if (canIUse('SystemCapability.Communication.WiFi.P2P')) {
        wifiManager.startDiscoverDevices()
        return 'ok'
      }
      throw new Error('unsupported capability: SystemCapability.Communication.WiFi.P2P')
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.startPortalCertification', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      wifiManager.startPortalCertification()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.startScan', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      wifiManager.startScan()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.startWifiDetection', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      wifiManager.startWifiDetection()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['ConnectivityKit.wifiManager.stopDiscoverDevices', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.WiFi.STA')) {
      if (canIUse('SystemCapability.Communication.WiFi.P2P')) {
        wifiManager.stopDiscoverDevices()
        return 'ok'
      }
      throw new Error('unsupported capability: SystemCapability.Communication.WiFi.P2P')
    }
    throw new Error('unsupported capability: SystemCapability.Communication.WiFi.STA')
  }],
  ['CoreFileKit.Environment.getStorageDataDir', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.FileManagement.File.Environment')) {
      let result = await Environment.getStorageDataDir()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.FileManagement.File.Environment')
  }],
  ['CoreFileKit.Environment.getUserDataDir', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.FileManagement.File.Environment')) {
      let result = await Environment.getUserDataDir()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.FileManagement.File.Environment')
  }],
  ['CoreFileKit.cloudSync.unregisterChange', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.FileManagement.DistributedFileService.CloudSync.Core')) {
      let uri = paramString(params, 'uri', '')
      cloudSync.unregisterChange(uri)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.FileManagement.DistributedFileService.CloudSync.Core')
  }],
  ['CoreFileKit.cloudSyncManager.notifyDataChange', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.FileManagement.DistributedFileService.CloudSyncManager')) {
      let accountId = paramString(params, 'accountId', '')
      let bundleName = paramString(params, 'bundleName', '')
      await cloudSyncManager.notifyDataChange(accountId, bundleName)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.FileManagement.DistributedFileService.CloudSyncManager')
  }],
  ['CoreFileKit.fileUri.getUriFromPath', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.FileManagement.AppFileService')) {
      let path = paramString(params, 'path', '')
      let result = fileUri.getUriFromPath(path)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.FileManagement.AppFileService')
  }],
  ['CoreFileKit.hash.hash', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.FileManagement.File.FileIO')) {
      let path = paramString(params, 'path', '')
      let algorithm = paramString(params, 'algorithm', '')
      let result = await hash.hash(path, algorithm)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.FileManagement.File.FileIO')
  }],
  ['CoreFileKit.keyManager.deactivateUserKey', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.FileManagement.StorageService.Encryption')) {
      let userId = paramInt(params, 'userId', 0)
      keyManager.deactivateUserKey(userId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.FileManagement.StorageService.Encryption')
  }],
  ['CoreFileKit.securityLabel.getSecurityLabel', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.FileManagement.File.FileIO')) {
      let path = paramString(params, 'path', '')
      let result = await securityLabel.getSecurityLabel(path)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.FileManagement.File.FileIO')
  }],
  ['CoreFileKit.securityLabel.getSecurityLabelSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.FileManagement.File.FileIO')) {
      let path = paramString(params, 'path', '')
      let result = securityLabel.getSecurityLabelSync(path)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.FileManagement.File.FileIO')
  }],
  ['CoreFileKit.statfs.getFreeSize', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.FileManagement.File.FileIO')) {
      let path = paramString(params, 'path', '')
      let result = await statfs.getFreeSize(path)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.FileManagement.File.FileIO')
  }],
  ['CoreFileKit.statfs.getFreeSizeSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.FileManagement.File.FileIO')) {
      let path = paramString(params, 'path', '')
      let result = statfs.getFreeSizeSync(path)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.FileManagement.File.FileIO')
  }],
  ['CoreFileKit.statfs.getTotalSize', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.FileManagement.File.FileIO')) {
      let path = paramString(params, 'path', '')
      let result = await statfs.getTotalSize(path)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.FileManagement.File.FileIO')
  }],
  ['CoreFileKit.statfs.getTotalSizeSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.FileManagement.File.FileIO')) {
      let path = paramString(params, 'path', '')
      let result = statfs.getTotalSizeSync(path)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.FileManagement.File.FileIO')
  }],
  ['CoreFileKit.storageStatistics.getCurrentBundleInodes', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.FileManagement.StorageService.SpatialStatistics')) {
      let result = await storageStatistics.getCurrentBundleInodes()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.FileManagement.StorageService.SpatialStatistics')
  }],
  ['CoreFileKit.storageStatistics.getFreeInodes', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.FileManagement.StorageService.SpatialStatistics')) {
      let result = await storageStatistics.getFreeInodes()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.FileManagement.StorageService.SpatialStatistics')
  }],
  ['CoreFileKit.storageStatistics.getFreeSize', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.FileManagement.StorageService.SpatialStatistics')) {
      let result = await storageStatistics.getFreeSize()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.FileManagement.StorageService.SpatialStatistics')
  }],
  ['CoreFileKit.storageStatistics.getFreeSizeOfVolume', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.FileManagement.StorageService.SpatialStatistics')) {
      let volumeUuid = paramString(params, 'volumeUuid', '')
      let result = await storageStatistics.getFreeSizeOfVolume(volumeUuid)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.FileManagement.StorageService.SpatialStatistics')
  }],
  ['CoreFileKit.storageStatistics.getFreeSizeSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.FileManagement.StorageService.SpatialStatistics')) {
      let result = storageStatistics.getFreeSizeSync()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.FileManagement.StorageService.SpatialStatistics')
  }],
  ['CoreFileKit.storageStatistics.getSystemDataSize', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.FileManagement.StorageService.SpatialStatistics')) {
      let result = await storageStatistics.getSystemDataSize()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.FileManagement.StorageService.SpatialStatistics')
  }],
  ['CoreFileKit.storageStatistics.getSystemSize', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.FileManagement.StorageService.SpatialStatistics')) {
      let result = await storageStatistics.getSystemSize()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.FileManagement.StorageService.SpatialStatistics')
  }],
  ['CoreFileKit.storageStatistics.getTotalInodes', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.FileManagement.StorageService.SpatialStatistics')) {
      let result = await storageStatistics.getTotalInodes()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.FileManagement.StorageService.SpatialStatistics')
  }],
  ['CoreFileKit.storageStatistics.getTotalSize', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.FileManagement.StorageService.SpatialStatistics')) {
      let result = await storageStatistics.getTotalSize()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.FileManagement.StorageService.SpatialStatistics')
  }],
  ['CoreFileKit.storageStatistics.getTotalSizeOfVolume', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.FileManagement.StorageService.SpatialStatistics')) {
      let volumeUuid = paramString(params, 'volumeUuid', '')
      let result = await storageStatistics.getTotalSizeOfVolume(volumeUuid)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.FileManagement.StorageService.SpatialStatistics')
  }],
  ['CoreFileKit.storageStatistics.getTotalSizeSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.FileManagement.StorageService.SpatialStatistics')) {
      let result = storageStatistics.getTotalSizeSync()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.FileManagement.StorageService.SpatialStatistics')
  }],
  ['DataProtectionKit.dlpPermission.cleanSandboxAppConfig', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Security.DataLossPrevention')) {
      await dlpPermission.cleanSandboxAppConfig()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Security.DataLossPrevention')
  }],
  ['DataProtectionKit.dlpPermission.getDLPSuffix', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Security.DataLossPrevention')) {
      let result = dlpPermission.getDLPSuffix()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Security.DataLossPrevention')
  }],
  ['DataProtectionKit.dlpPermission.getOriginalFileName', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Security.DataLossPrevention')) {
      let fileName = paramString(params, 'fileName', '')
      let result = dlpPermission.getOriginalFileName(fileName)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Security.DataLossPrevention')
  }],
  ['DataProtectionKit.dlpPermission.getSandboxAppConfig', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Security.DataLossPrevention')) {
      let result = await dlpPermission.getSandboxAppConfig()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Security.DataLossPrevention')
  }],
  ['DataProtectionKit.dlpPermission.isDLPFeatureProvided', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Security.DataLossPrevention')) {
      let result = await dlpPermission.isDLPFeatureProvided()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Security.DataLossPrevention')
  }],
  ['DataProtectionKit.dlpPermission.isDLPFile', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Security.DataLossPrevention')) {
      let fd = paramFloat(params, 'fd', 0)
      let result = await dlpPermission.isDLPFile(fd)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Security.DataLossPrevention')
  }],
  ['DataProtectionKit.dlpPermission.isInSandbox', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Security.DataLossPrevention')) {
      let result = await dlpPermission.isInSandbox()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Security.DataLossPrevention')
  }],
  ['DataProtectionKit.dlpPermission.setSandboxAppConfig', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Security.DataLossPrevention')) {
      let configInfo = paramString(params, 'configInfo', '')
      await dlpPermission.setSandboxAppConfig(configInfo)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Security.DataLossPrevention')
  }],
  ['DeviceCertificateKit.certificateManagerDialog.supportsCACertDialog', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Security.CertificateManagerDialog')) {
      let result = certificateManagerDialog.supportsCACertDialog()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Security.CertificateManagerDialog')
  }],
  ['DistributedServiceKit.abilityConnectionManager.acceptConnect', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.DistributedSched.AppCollaboration')) {
      let sessionId = paramInt(params, 'sessionId', 0)
      let token = paramString(params, 'token', '')
      await abilityConnectionManager.acceptConnect(sessionId, token)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.DistributedSched.AppCollaboration')
  }],
  ['DistributedServiceKit.abilityConnectionManager.destroyAbilityConnectionSession', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.DistributedSched.AppCollaboration')) {
      let sessionId = paramInt(params, 'sessionId', 0)
      abilityConnectionManager.destroyAbilityConnectionSession(sessionId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.DistributedSched.AppCollaboration')
  }],
  ['DistributedServiceKit.abilityConnectionManager.destroyStream', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.DistributedSched.AppCollaboration')) {
      let streamId = paramInt(params, 'streamId', 0)
      abilityConnectionManager.destroyStream(streamId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.DistributedSched.AppCollaboration')
  }],
  ['DistributedServiceKit.abilityConnectionManager.disconnect', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.DistributedSched.AppCollaboration')) {
      let sessionId = paramInt(params, 'sessionId', 0)
      abilityConnectionManager.disconnect(sessionId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.DistributedSched.AppCollaboration')
  }],
  ['DistributedServiceKit.abilityConnectionManager.reject', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.DistributedSched.AppCollaboration')) {
      let token = paramString(params, 'token', '')
      let reason = paramString(params, 'reason', '')
      abilityConnectionManager.reject(token, reason)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.DistributedSched.AppCollaboration')
  }],
  ['DistributedServiceKit.abilityConnectionManager.sendMessage', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.DistributedSched.AppCollaboration')) {
      let sessionId = paramInt(params, 'sessionId', 0)
      let msg = paramString(params, 'msg', '')
      await abilityConnectionManager.sendMessage(sessionId, msg)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.DistributedSched.AppCollaboration')
  }],
  ['DistributedServiceKit.abilityConnectionManager.startStream', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.DistributedSched.AppCollaboration')) {
      let streamId = paramInt(params, 'streamId', 0)
      abilityConnectionManager.startStream(streamId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.DistributedSched.AppCollaboration')
  }],
  ['DistributedServiceKit.abilityConnectionManager.stopStream', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.DistributedSched.AppCollaboration')) {
      let streamId = paramInt(params, 'streamId', 0)
      abilityConnectionManager.stopStream(streamId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.DistributedSched.AppCollaboration')
  }],
  ['DrmKit.drm.getMediaKeySystemUuid', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Multimedia.Drm.Core')) {
      let name = paramString(params, 'name', '')
      let result = drm.getMediaKeySystemUuid(name)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Multimedia.Drm.Core')
  }],
  ['DrmKit.drm.isMediaKeySystemSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Multimedia.Drm.Core')) {
      let name = paramString(params, 'name', '')
      let result = drm.isMediaKeySystemSupported(name)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Multimedia.Drm.Core')
  }],
  ['FormKit.formHost.isSystemReady', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.Form')) {
      await formHost.isSystemReady()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Ability.Form')
  }],
  ['FormKit.formProvider.activateSceneAnimation', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.Form')) {
      let formId = paramString(params, 'formId', '')
      await formProvider.activateSceneAnimation(formId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Ability.Form')
  }],
  ['FormKit.formProvider.cancelOverflow', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.Form')) {
      let formId = paramString(params, 'formId', '')
      await formProvider.cancelOverflow(formId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Ability.Form')
  }],
  ['FormKit.formProvider.closeFormEditAbility', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.Form')) {
      let isMainPage = paramBoolean(params, 'isMainPage', false)
      formProvider.closeFormEditAbility(isMainPage)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Ability.Form')
  }],
  ['FormKit.formProvider.deactivateSceneAnimation', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.Form')) {
      let formId = paramString(params, 'formId', '')
      await formProvider.deactivateSceneAnimation(formId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Ability.Form')
  }],
  ['FormKit.formProvider.isRequestPublishFormSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.Form')) {
      let result = await formProvider.isRequestPublishFormSupported()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Ability.Form')
  }],
  ['FormKit.formProvider.setFormNextRefreshTime', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Ability.Form')) {
      let formId = paramString(params, 'formId', '')
      let minute = paramInt(params, 'minute', 0)
      await formProvider.setFormNextRefreshTime(formId, minute)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Ability.Form')
  }],
  ['IMEKit.inputMethod.setSimpleKeyboardEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MiscServices.InputMethodFramework')) {
      let enable = paramBoolean(params, 'enable', false)
      inputMethod.setSimpleKeyboardEnabled(enable)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.MiscServices.InputMethodFramework')
  }],
  ['ImageKit.videoProcessingEngine.deinitializeEnvironment', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Multimedia.VideoProcessingEngine')) {
      await videoProcessingEngine.deinitializeEnvironment()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Multimedia.VideoProcessingEngine')
  }],
  ['ImageKit.videoProcessingEngine.initializeEnvironment', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Multimedia.VideoProcessingEngine')) {
      await videoProcessingEngine.initializeEnvironment()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Multimedia.VideoProcessingEngine')
  }],
  ['InputKit.inputDevice.getIntervalSinceLastInput', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.InputDevice')) {
      let result = await inputDevice.getIntervalSinceLastInput()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.InputDevice')
  }],
  ['InputKit.inputDevice.getKeyboardRepeatDelay', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.InputDevice')) {
      let result = await inputDevice.getKeyboardRepeatDelay()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.InputDevice')
  }],
  ['InputKit.inputDevice.getKeyboardRepeatRate', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.InputDevice')) {
      let result = await inputDevice.getKeyboardRepeatRate()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.InputDevice')
  }],
  ['InputKit.inputDevice.setKeyboardRepeatDelay', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.InputDevice')) {
      let delay = paramInt(params, 'delay', 0)
      await inputDevice.setKeyboardRepeatDelay(delay)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.InputDevice')
  }],
  ['InputKit.inputDevice.setKeyboardRepeatRate', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.InputDevice')) {
      let rate = paramInt(params, 'rate', 0)
      await inputDevice.setKeyboardRepeatRate(rate)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.InputDevice')
  }],
  ['InputKit.pointer.getHoverScrollState', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let result = await pointer.getHoverScrollState()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.getMouseScrollRows', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let result = await pointer.getMouseScrollRows()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.getPointerColor', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let result = await pointer.getPointerColor()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.getPointerColorSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let result = pointer.getPointerColorSync()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.getPointerSize', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let result = await pointer.getPointerSize()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.getPointerSizeSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let result = pointer.getPointerSizeSync()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.getPointerSpeed', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let result = await pointer.getPointerSpeed()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.getPointerSpeedSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let result = pointer.getPointerSpeedSync()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.getTouchpadDoubleTapAndDragState', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let result = await pointer.getTouchpadDoubleTapAndDragState()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.getTouchpadPinchSwitch', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let result = await pointer.getTouchpadPinchSwitch()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.getTouchpadPointerSpeed', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let result = await pointer.getTouchpadPointerSpeed()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.getTouchpadScrollDirection', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let result = await pointer.getTouchpadScrollDirection()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.getTouchpadScrollSwitch', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let result = await pointer.getTouchpadScrollSwitch()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.getTouchpadSwipeSwitch', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let result = await pointer.getTouchpadSwipeSwitch()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.getTouchpadTapSwitch', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let result = await pointer.getTouchpadTapSwitch()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.isPointerVisible', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let result = await pointer.isPointerVisible()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.isPointerVisibleSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let result = pointer.isPointerVisibleSync()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.setHoverScrollState', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let state = paramBoolean(params, 'state', false)
      await pointer.setHoverScrollState(state)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.setMouseScrollRows', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let rows = paramInt(params, 'rows', 0)
      await pointer.setMouseScrollRows(rows)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.setPointerColor', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let color = paramInt(params, 'color', 0)
      await pointer.setPointerColor(color)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.setPointerColorSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let color = paramInt(params, 'color', 0)
      pointer.setPointerColorSync(color)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.setPointerSize', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let size = paramInt(params, 'size', 0)
      await pointer.setPointerSize(size)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.setPointerSizeSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let size = paramInt(params, 'size', 0)
      pointer.setPointerSizeSync(size)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.setPointerSpeed', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let speed = paramInt(params, 'speed', 0)
      await pointer.setPointerSpeed(speed)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.setPointerSpeedSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let speed = paramInt(params, 'speed', 0)
      pointer.setPointerSpeedSync(speed)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.setPointerVisible', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let visible = paramBoolean(params, 'visible', false)
      await pointer.setPointerVisible(visible)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.setPointerVisibleSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let visible = paramBoolean(params, 'visible', false)
      pointer.setPointerVisibleSync(visible)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.setTouchpadDoubleTapAndDragState', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let isOpen = paramBoolean(params, 'isOpen', false)
      await pointer.setTouchpadDoubleTapAndDragState(isOpen)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.setTouchpadPinchSwitch', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let state = paramBoolean(params, 'state', false)
      await pointer.setTouchpadPinchSwitch(state)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.setTouchpadPointerSpeed', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let speed = paramInt(params, 'speed', 0)
      await pointer.setTouchpadPointerSpeed(speed)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.setTouchpadScrollDirection', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let state = paramBoolean(params, 'state', false)
      await pointer.setTouchpadScrollDirection(state)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.setTouchpadScrollSwitch', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let state = paramBoolean(params, 'state', false)
      await pointer.setTouchpadScrollSwitch(state)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.setTouchpadSwipeSwitch', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let state = paramBoolean(params, 'state', false)
      await pointer.setTouchpadSwipeSwitch(state)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.pointer.setTouchpadTapSwitch', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.Pointer')) {
      let state = paramBoolean(params, 'state', false)
      await pointer.setTouchpadTapSwitch(state)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.Pointer')
  }],
  ['InputKit.shortKey.setKeyDownDuration', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalInput.Input.ShortKey')) {
      let businessKey = paramString(params, 'businessKey', '')
      let delay = paramInt(params, 'delay', 0)
      await shortKey.setKeyDownDuration(businessKey, delay)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalInput.Input.ShortKey')
  }],
  ['LocalizationKit.i18n.isRTL', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Global.I18n')) {
      let locale = paramString(params, 'locale', '')
      let result = i18n.isRTL(locale)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Global.I18n')
  }],
  ['LocationKit.geoLocationManager.isBeaconFenceSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Location.Location.Core')) {
      if (canIUse('SystemCapability.Location.Location.Geofence')) {
        let result = geoLocationManager.isBeaconFenceSupported()
        return result.toString()
      }
      throw new Error('unsupported capability: SystemCapability.Location.Location.Geofence')
    }
    throw new Error('unsupported capability: SystemCapability.Location.Location.Core')
  }],
  ['LocationKit.geoLocationManager.isCachedGnssServiceSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Location.Location.Core')) {
      let result = geoLocationManager.isCachedGnssServiceSupported()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Location.Location.Core')
  }],
  ['LocationKit.geoLocationManager.isGeocoderAvailable', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Location.Location.Core')) {
      if (canIUse('SystemCapability.Location.Location.Geocoder')) {
        let result = geoLocationManager.isGeocoderAvailable()
        return result.toString()
      }
      throw new Error('unsupported capability: SystemCapability.Location.Location.Geocoder')
    }
    throw new Error('unsupported capability: SystemCapability.Location.Location.Core')
  }],
  ['LocationKit.geoLocationManager.isGnssFenceServiceSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Location.Location.Core')) {
      let result = geoLocationManager.isGnssFenceServiceSupported()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Location.Location.Core')
  }],
  ['LocationKit.geoLocationManager.isGnssServiceSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Location.Location.Core')) {
      let result = geoLocationManager.isGnssServiceSupported()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Location.Location.Core')
  }],
  ['LocationKit.geoLocationManager.isLocationEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Location.Location.Core')) {
      let result = geoLocationManager.isLocationEnabled()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Location.Location.Core')
  }],
  ['LocationKit.geoLocationManager.isLocationEnabledByUserId', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Location.Location.Core')) {
      let userId = paramInt(params, 'userId', 0)
      let result = geoLocationManager.isLocationEnabledByUserId(userId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Location.Location.Core')
  }],
  ['LocationKit.geoLocationManager.isPoiServiceSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Location.Location.Core')) {
      let result = geoLocationManager.isPoiServiceSupported()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Location.Location.Core')
  }],
  ['MDMKit.adminManager.getEnterpriseManagedTips', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Customization.EnterpriseDeviceManager')) {
      let result = await adminManager.getEnterpriseManagedTips()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Customization.EnterpriseDeviceManager')
  }],
  ['MDMKit.applicationManager.isAppKioskAllowed', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Customization.EnterpriseDeviceManager')) {
      let appIdentifier = paramString(params, 'appIdentifier', '')
      let result = applicationManager.isAppKioskAllowed(appIdentifier)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Customization.EnterpriseDeviceManager')
  }],
  ['MDMKit.browser.getSelfManagedBrowserPolicyVersion', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Customization.EnterpriseDeviceManager')) {
      let result = browser.getSelfManagedBrowserPolicyVersion()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Customization.EnterpriseDeviceManager')
  }],
  ['MechanicKit.mechanicManager.getCameraTrackingEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Mechanic.Core')) {
      let result = mechanicManager.getCameraTrackingEnabled()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Mechanic.Core')
  }],
  ['MechanicKit.mechanicManager.getMaxRotationTime', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Mechanic.Core')) {
      let mechId = paramInt(params, 'mechId', 0)
      let result = mechanicManager.getMaxRotationTime(mechId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Mechanic.Core')
  }],
  ['MechanicKit.mechanicManager.setCameraTrackingEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Mechanic.Core')) {
      let isEnabled = paramBoolean(params, 'isEnabled', false)
      mechanicManager.setCameraTrackingEnabled(isEnabled)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Mechanic.Core')
  }],
  ['MechanicKit.mechanicManager.stopMoving', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Mechanic.Core')) {
      let mechId = paramInt(params, 'mechId', 0)
      await mechanicManager.stopMoving(mechId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Mechanic.Core')
  }],
  ['MediaKit.media.getAVScreenCaptureConfigurableParameters', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Multimedia.Media.Core')) {
      if (canIUse('SystemCapability.Multimedia.Media.AVScreenCapture')) {
        let sessionId = paramInt(params, 'sessionId', 0)
        let result = await media.getAVScreenCaptureConfigurableParameters(sessionId)
        return result.toString()
      }
      throw new Error('unsupported capability: SystemCapability.Multimedia.Media.AVScreenCapture')
    }
    throw new Error('unsupported capability: SystemCapability.Multimedia.Media.Core')
  }],
  ['MediaKit.media.reportAVScreenCaptureUserChoice', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Multimedia.Media.Core')) {
      if (canIUse('SystemCapability.Multimedia.Media.AVScreenCapture')) {
        let sessionId = paramInt(params, 'sessionId', 0)
        let choice = paramString(params, 'choice', '')
        await media.reportAVScreenCaptureUserChoice(sessionId, choice)
        return 'ok'
      }
      throw new Error('unsupported capability: SystemCapability.Multimedia.Media.AVScreenCapture')
    }
    throw new Error('unsupported capability: SystemCapability.Multimedia.Media.Core')
  }],
  ['MultimodalAwarenessKit.metadataBinding.notifyMetadataBindingEvent', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalAwareness.MetadataBinding')) {
      let bundleName = paramString(params, 'bundleName', '')
      let result = await metadataBinding.notifyMetadataBindingEvent(bundleName)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalAwareness.MetadataBinding')
  }],
  ['MultimodalAwarenessKit.metadataBinding.submitMetadata', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.MultimodalAwareness.MetadataBinding')) {
      let metadata = paramString(params, 'metadata', '')
      metadataBinding.submitMetadata(metadata)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.MultimodalAwareness.MetadataBinding')
  }],
  ['NetworkKit.connection.clearCustomDnsRules', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.NetManager.Core')) {
      await netConnection.clearCustomDnsRules()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Communication.NetManager.Core')
  }],
  ['NetworkKit.connection.findProxyForUrl', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.NetManager.Core')) {
      let url = paramString(params, 'url', '')
      let result = netConnection.findProxyForUrl(url)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.NetManager.Core')
  }],
  ['NetworkKit.connection.getPacFileUrl', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.NetManager.Core')) {
      let result = netConnection.getPacFileUrl()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.NetManager.Core')
  }],
  ['NetworkKit.connection.getPacUrl', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.NetManager.Core')) {
      let result = netConnection.getPacUrl()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.NetManager.Core')
  }],
  ['NetworkKit.connection.hasDefaultNet', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.NetManager.Core')) {
      let result = await netConnection.hasDefaultNet()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.NetManager.Core')
  }],
  ['NetworkKit.connection.hasDefaultNetSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.NetManager.Core')) {
      let result = netConnection.hasDefaultNetSync()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.NetManager.Core')
  }],
  ['NetworkKit.connection.isDefaultNetMetered', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.NetManager.Core')) {
      let result = await netConnection.isDefaultNetMetered()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.NetManager.Core')
  }],
  ['NetworkKit.connection.isDefaultNetMeteredSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.NetManager.Core')) {
      let result = netConnection.isDefaultNetMeteredSync()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.NetManager.Core')
  }],
  ['NetworkKit.connection.removeCustomDnsRule', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.NetManager.Core')) {
      let host = paramString(params, 'host', '')
      await netConnection.removeCustomDnsRule(host)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Communication.NetManager.Core')
  }],
  ['NetworkKit.ethernet.isIfaceActive', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.NetManager.Ethernet')) {
      let iface = paramString(params, 'iface', '')
      let result = await ethernet.isIfaceActive(iface)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.NetManager.Ethernet')
  }],
  ['NetworkKit.networkSecurity.isCleartextPermitted', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.NetStack')) {
      let result = networkSecurity.isCleartextPermitted()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.NetStack')
  }],
  ['NetworkKit.networkSecurity.isCleartextPermittedByHostName', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.NetStack')) {
      let hostName = paramString(params, 'hostName', '')
      let result = networkSecurity.isCleartextPermittedByHostName(hostName)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.NetStack')
  }],
  ['NetworkKit.statistics.getAllRxBytes', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.NetManager.Core')) {
      let result = await statistics.getAllRxBytes()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.NetManager.Core')
  }],
  ['NetworkKit.statistics.getAllTxBytes', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.NetManager.Core')) {
      let result = await statistics.getAllTxBytes()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.NetManager.Core')
  }],
  ['NetworkKit.statistics.getCellularRxBytes', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.NetManager.Core')) {
      let result = await statistics.getCellularRxBytes()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.NetManager.Core')
  }],
  ['NetworkKit.statistics.getCellularTxBytes', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.NetManager.Core')) {
      let result = await statistics.getCellularTxBytes()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.NetManager.Core')
  }],
  ['NetworkKit.statistics.getIfaceRxBytes', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.NetManager.Core')) {
      let nic = paramString(params, 'nic', '')
      let result = await statistics.getIfaceRxBytes(nic)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.NetManager.Core')
  }],
  ['NetworkKit.statistics.getIfaceTxBytes', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.NetManager.Core')) {
      let nic = paramString(params, 'nic', '')
      let result = await statistics.getIfaceTxBytes(nic)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.NetManager.Core')
  }],
  ['NetworkKit.statistics.getSockfdRxBytes', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.NetManager.Core')) {
      let sockfd = paramInt(params, 'sockfd', 0)
      let result = await statistics.getSockfdRxBytes(sockfd)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.NetManager.Core')
  }],
  ['NetworkKit.statistics.getSockfdTxBytes', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Communication.NetManager.Core')) {
      let sockfd = paramInt(params, 'sockfd', 0)
      let result = await statistics.getSockfdTxBytes(sockfd)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Communication.NetManager.Core')
  }],
  ['NotificationKit.notificationManager.cancel', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      let id = paramInt(params, 'id', 0)
      let label = paramString(params, 'label', '')
      await notificationManager.cancel(id, label)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['NotificationKit.notificationManager.cancelAll', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      await notificationManager.cancelAll()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['NotificationKit.notificationManager.cancelGroup', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      let groupName = paramString(params, 'groupName', '')
      await notificationManager.cancelGroup(groupName)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['NotificationKit.notificationManager.getActiveNotificationCount', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      let result = await notificationManager.getActiveNotificationCount()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['NotificationKit.notificationManager.getBadgeNumber', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      let result = await notificationManager.getBadgeNumber()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['NotificationKit.notificationManager.isDistributedEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      let deviceType = paramString(params, 'deviceType', '')
      let result = await notificationManager.isDistributedEnabled(deviceType)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['NotificationKit.notificationManager.isGeofenceEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      let result = await notificationManager.isGeofenceEnabled()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['NotificationKit.notificationManager.isNotificationEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      let result = await notificationManager.isNotificationEnabled()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['NotificationKit.notificationManager.isNotificationEnabledSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      let result = notificationManager.isNotificationEnabledSync()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['NotificationKit.notificationManager.isPriorityEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      let result = await notificationManager.isPriorityEnabled()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['NotificationKit.notificationManager.isPriorityIntelligentEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      let result = await notificationManager.isPriorityIntelligentEnabled()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['NotificationKit.notificationManager.isSmartReminderEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      let deviceType = paramString(params, 'deviceType', '')
      let result = await notificationManager.isSmartReminderEnabled(deviceType)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['NotificationKit.notificationManager.isSupportDoNotDisturbMode', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      let result = await notificationManager.isSupportDoNotDisturbMode()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['NotificationKit.notificationManager.isSupportTemplate', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      let templateName = paramString(params, 'templateName', '')
      let result = await notificationManager.isSupportTemplate(templateName)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['NotificationKit.notificationManager.offBadgeNumberQuery', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      notificationManager.offBadgeNumberQuery()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['NotificationKit.notificationManager.removeAllSlots', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      await notificationManager.removeAllSlots()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['NotificationKit.notificationManager.setBadgeNumber', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      let badgeNumber = paramInt(params, 'badgeNumber', 0)
      await notificationManager.setBadgeNumber(badgeNumber)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['NotificationKit.notificationManager.setDistributedEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      let enable = paramBoolean(params, 'enable', false)
      let deviceType = paramString(params, 'deviceType', '')
      await notificationManager.setDistributedEnabled(enable, deviceType)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['NotificationKit.notificationManager.setGeofenceEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      let enabled = paramBoolean(params, 'enabled', false)
      await notificationManager.setGeofenceEnabled(enabled)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['NotificationKit.notificationManager.setPriorityEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      let enable = paramBoolean(params, 'enable', false)
      await notificationManager.setPriorityEnabled(enable)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['NotificationKit.notificationManager.setPriorityIntelligentEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      let enable = paramBoolean(params, 'enable', false)
      await notificationManager.setPriorityIntelligentEnabled(enable)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['NotificationKit.notificationManager.setSmartReminderEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      let deviceType = paramString(params, 'deviceType', '')
      let enable = paramBoolean(params, 'enable', false)
      await notificationManager.setSmartReminderEnabled(deviceType, enable)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['NotificationKit.notificationManager.setTargetDeviceStatus', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      let deviceType = paramString(params, 'deviceType', '')
      let status = paramInt(params, 'status', 0)
      await notificationManager.setTargetDeviceStatus(deviceType, status)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['NotificationKit.notificationManager.snoozeNotification', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      let hashCode = paramString(params, 'hashCode', '')
      let delayTime = paramInt(params, 'delayTime', 0)
      await notificationManager.snoozeNotification(hashCode, delayTime)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['NotificationKit.notificationSubscribe.removeAll', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Notification.Notification')) {
      let userId = paramInt(params, 'userId', 0)
      await notificationSubscribe.removeAll(userId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Notification.Notification')
  }],
  ['PerformanceAnalysisKit.hiAppEvent.addProcessorFromConfig', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiAppEvent')) {
      let processorName = paramString(params, 'processorName', '')
      let configName = paramString(params, 'configName', '')
      let result = await hiAppEvent.addProcessorFromConfig(processorName, configName)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiAppEvent')
  }],
  ['PerformanceAnalysisKit.hiAppEvent.clearData', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiAppEvent')) {
      hiAppEvent.clearData()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiAppEvent')
  }],
  ['PerformanceAnalysisKit.hiAppEvent.getUserId', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiAppEvent')) {
      let name = paramString(params, 'name', '')
      let result = hiAppEvent.getUserId(name)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiAppEvent')
  }],
  ['PerformanceAnalysisKit.hiAppEvent.getUserProperty', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiAppEvent')) {
      let name = paramString(params, 'name', '')
      let result = hiAppEvent.getUserProperty(name)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiAppEvent')
  }],
  ['PerformanceAnalysisKit.hiAppEvent.removeProcessor', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiAppEvent')) {
      let id = paramInt(params, 'id', 0)
      hiAppEvent.removeProcessor(id)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiAppEvent')
  }],
  ['PerformanceAnalysisKit.hiAppEvent.setUserId', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiAppEvent')) {
      let name = paramString(params, 'name', '')
      let value = paramString(params, 'value', '')
      hiAppEvent.setUserId(name, value)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiAppEvent')
  }],
  ['PerformanceAnalysisKit.hiAppEvent.setUserProperty', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiAppEvent')) {
      let name = paramString(params, 'name', '')
      let value = paramString(params, 'value', '')
      hiAppEvent.setUserProperty(name, value)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiAppEvent')
  }],
  ['PerformanceAnalysisKit.hiRetrieval.getLastParticipationTimestamp', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiRetrieval')) {
      let result = hiRetrieval.getLastParticipationTimestamp()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiRetrieval')
  }],
  ['PerformanceAnalysisKit.hiRetrieval.init', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiRetrieval')) {
      hiRetrieval.init()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiRetrieval')
  }],
  ['PerformanceAnalysisKit.hiRetrieval.isParticipant', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiRetrieval')) {
      let result = hiRetrieval.isParticipant()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiRetrieval')
  }],
  ['PerformanceAnalysisKit.hiRetrieval.quit', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiRetrieval')) {
      hiRetrieval.quit()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiRetrieval')
  }],
  ['PerformanceAnalysisKit.hiRetrieval.run', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiRetrieval')) {
      hiRetrieval.run()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiRetrieval')
  }],
  ['PerformanceAnalysisKit.hiTraceChain.clearId', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiTrace')) {
      hiTraceChain.clearId()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiTrace')
  }],
  ['PerformanceAnalysisKit.hiTraceMeter.finishTrace', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiTrace')) {
      let name = paramString(params, 'name', '')
      let taskId = paramInt(params, 'taskId', 0)
      hiTraceMeter.finishTrace(name, taskId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiTrace')
  }],
  ['PerformanceAnalysisKit.hiTraceMeter.isTraceEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiTrace')) {
      let result = hiTraceMeter.isTraceEnabled()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiTrace')
  }],
  ['PerformanceAnalysisKit.hiTraceMeter.startTrace', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiTrace')) {
      let name = paramString(params, 'name', '')
      let taskId = paramInt(params, 'taskId', 0)
      hiTraceMeter.startTrace(name, taskId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiTrace')
  }],
  ['PerformanceAnalysisKit.hiTraceMeter.traceByValue', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiTrace')) {
      let name = paramString(params, 'name', '')
      let count = paramInt(params, 'count', 0)
      hiTraceMeter.traceByValue(name, count)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiTrace')
  }],
  ['PerformanceAnalysisKit.hiTraceMeter.unregisterTraceListener', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiTrace')) {
      let index = paramInt(params, 'index', 0)
      let result = hiTraceMeter.unregisterTraceListener(index)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiTrace')
  }],
  ['PerformanceAnalysisKit.hichecker.addCheckRule', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiChecker')) {
      let rule = paramBigInt(params, 'rule', BigInt(0))
      hichecker.addCheckRule(rule)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiChecker')
  }],
  ['PerformanceAnalysisKit.hichecker.containsCheckRule', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiChecker')) {
      let rule = paramBigInt(params, 'rule', BigInt(0))
      let result = hichecker.containsCheckRule(rule)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiChecker')
  }],
  ['PerformanceAnalysisKit.hichecker.getRule', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiChecker')) {
      let result = hichecker.getRule()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiChecker')
  }],
  ['PerformanceAnalysisKit.hichecker.removeCheckRule', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiChecker')) {
      let rule = paramBigInt(params, 'rule', BigInt(0))
      hichecker.removeCheckRule(rule)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiChecker')
  }],
  ['PerformanceAnalysisKit.hidebug.disableGwpAsanGrayscale', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiProfiler.HiDebug')) {
      hidebug.disableGwpAsanGrayscale()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiProfiler.HiDebug')
  }],
  ['PerformanceAnalysisKit.hidebug.dumpJsRawHeapData', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiProfiler.HiDebug')) {
      let needGC = paramBoolean(params, 'needGC', false)
      let result = await hidebug.dumpJsRawHeapData(needGC)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiProfiler.HiDebug')
  }],
  ['PerformanceAnalysisKit.hidebug.getAppVMObjectUsedSize', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiProfiler.HiDebug')) {
      let result = hidebug.getAppVMObjectUsedSize()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiProfiler.HiDebug')
  }],
  ['PerformanceAnalysisKit.hidebug.getCpuUsage', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiProfiler.HiDebug')) {
      let result = hidebug.getCpuUsage()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiProfiler.HiDebug')
  }],
  ['PerformanceAnalysisKit.hidebug.getGraphicsMemory', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiProfiler.HiDebug')) {
      let result = await hidebug.getGraphicsMemory()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiProfiler.HiDebug')
  }],
  ['PerformanceAnalysisKit.hidebug.getGraphicsMemorySync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiProfiler.HiDebug')) {
      let result = hidebug.getGraphicsMemorySync()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiProfiler.HiDebug')
  }],
  ['PerformanceAnalysisKit.hidebug.getGwpAsanGrayscaleState', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiProfiler.HiDebug')) {
      let result = hidebug.getGwpAsanGrayscaleState()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiProfiler.HiDebug')
  }],
  ['PerformanceAnalysisKit.hidebug.getNativeHeapAllocatedSize', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiProfiler.HiDebug')) {
      let result = hidebug.getNativeHeapAllocatedSize()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiProfiler.HiDebug')
  }],
  ['PerformanceAnalysisKit.hidebug.getNativeHeapFreeSize', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiProfiler.HiDebug')) {
      let result = hidebug.getNativeHeapFreeSize()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiProfiler.HiDebug')
  }],
  ['PerformanceAnalysisKit.hidebug.getNativeHeapSize', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiProfiler.HiDebug')) {
      let result = hidebug.getNativeHeapSize()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiProfiler.HiDebug')
  }],
  ['PerformanceAnalysisKit.hidebug.getPrivateDirty', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiProfiler.HiDebug')) {
      let result = hidebug.getPrivateDirty()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiProfiler.HiDebug')
  }],
  ['PerformanceAnalysisKit.hidebug.getPss', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiProfiler.HiDebug')) {
      let result = hidebug.getPss()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiProfiler.HiDebug')
  }],
  ['PerformanceAnalysisKit.hidebug.getSharedDirty', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiProfiler.HiDebug')) {
      let result = hidebug.getSharedDirty()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiProfiler.HiDebug')
  }],
  ['PerformanceAnalysisKit.hidebug.getSystemCpuUsage', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiProfiler.HiDebug')) {
      let result = hidebug.getSystemCpuUsage()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiProfiler.HiDebug')
  }],
  ['PerformanceAnalysisKit.hidebug.getVMRuntimeStat', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiProfiler.HiDebug')) {
      let item = paramString(params, 'item', '')
      let result = hidebug.getVMRuntimeStat(item)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiProfiler.HiDebug')
  }],
  ['PerformanceAnalysisKit.hidebug.getVss', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiProfiler.HiDebug')) {
      let result = hidebug.getVss()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiProfiler.HiDebug')
  }],
  ['PerformanceAnalysisKit.hidebug.isDebugState', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiProfiler.HiDebug')) {
      let result = hidebug.isDebugState()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiProfiler.HiDebug')
  }],
  ['PerformanceAnalysisKit.hidebug.setProcDumpInSharedOOM', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiProfiler.HiDebug')) {
      let enable = paramBoolean(params, 'enable', false)
      hidebug.setProcDumpInSharedOOM(enable)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiProfiler.HiDebug')
  }],
  ['PerformanceAnalysisKit.hidebug.startJsCpuProfiling', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiProfiler.HiDebug')) {
      let filename = paramString(params, 'filename', '')
      hidebug.startJsCpuProfiling(filename)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiProfiler.HiDebug')
  }],
  ['PerformanceAnalysisKit.hidebug.stopAppTraceCapture', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiProfiler.HiDebug')) {
      hidebug.stopAppTraceCapture()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiProfiler.HiDebug')
  }],
  ['PerformanceAnalysisKit.hidebug.stopJsCpuProfiling', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiProfiler.HiDebug')) {
      hidebug.stopJsCpuProfiling()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiProfiler.HiDebug')
  }],
  ['PerformanceAnalysisKit.hilog.clean', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiLog')) {
      hilog.clean()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiLog')
  }],
  ['PerformanceAnalysisKit.hilog.flush', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiLog')) {
      hilog.flush()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiLog')
  }],
  ['PerformanceAnalysisKit.hilog.getOutputDir', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiLog')) {
      let result = hilog.getOutputDir()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiLog')
  }],
  ['PerformanceAnalysisKit.jsLeakWatcher.check', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiChecker')) {
      let result = jsLeakWatcher.check()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiChecker')
  }],
  ['PerformanceAnalysisKit.jsLeakWatcher.enable', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.HiviewDFX.HiChecker')) {
      let isEnable = paramBoolean(params, 'isEnable', false)
      jsLeakWatcher.enable(isEnable)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.HiviewDFX.HiChecker')
  }],
  ['SensorServiceKit.sensor.getDeviceAltitude', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Sensors.Sensor')) {
      let seaPressure = paramFloat(params, 'seaPressure', 0)
      let currentPressure = paramFloat(params, 'currentPressure', 0)
      let result = await sensor.getDeviceAltitude(seaPressure, currentPressure)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Sensors.Sensor')
  }],
  ['SensorServiceKit.vibrator.isHdHapticSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Sensors.MiscDevice')) {
      let result = vibrator.isHdHapticSupported()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Sensors.MiscDevice')
  }],
  ['SensorServiceKit.vibrator.isSupportEffect', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Sensors.MiscDevice')) {
      let effectId = paramString(params, 'effectId', '')
      let result = await vibrator.isSupportEffect(effectId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Sensors.MiscDevice')
  }],
  ['SensorServiceKit.vibrator.isSupportEffectSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Sensors.MiscDevice')) {
      let effectId = paramString(params, 'effectId', '')
      let result = vibrator.isSupportEffectSync(effectId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Sensors.MiscDevice')
  }],
  ['TelephonyKit.call.canSetCallTransferTime', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      let slotId = paramInt(params, 'slotId', 0)
      let result = await call.canSetCallTransferTime(slotId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.cancelMuted', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      await call.cancelMuted()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.closeUnfinishedUssd', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      let slotId = paramInt(params, 'slotId', 0)
      await call.closeUnfinishedUssd(slotId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.combineConference', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      let callId = paramInt(params, 'callId', 0)
      await call.combineConference(callId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.controlCamera', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      let callId = paramInt(params, 'callId', 0)
      let cameraId = paramString(params, 'cameraId', '')
      await call.controlCamera(callId, cameraId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.disableImsSwitch', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      let slotId = paramInt(params, 'slotId', 0)
      await call.disableImsSwitch(slotId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.getMainCallId', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      let callId = paramInt(params, 'callId', 0)
      let result = await call.getMainCallId(callId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.hangUpCall', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      let callId = paramInt(params, 'callId', 0)
      await call.hangUpCall(callId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.hasCall', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      let result = await call.hasCall()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.hasCallSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      let result = call.hasCallSync()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.hasVoiceCapability', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      let result = call.hasVoiceCapability()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.isImsSwitchEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      let slotId = paramInt(params, 'slotId', 0)
      let result = await call.isImsSwitchEnabled(slotId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.isImsSwitchEnabledSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      let slotId = paramInt(params, 'slotId', 0)
      let result = call.isImsSwitchEnabledSync(slotId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.isInEmergencyCall', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      let result = await call.isInEmergencyCall()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.isNewCallAllowed', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      let result = await call.isNewCallAllowed()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.isRinging', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      let result = await call.isRinging()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.makeCall', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      if (canIUse('SystemCapability.Applications.Contacts')) {
        let phoneNumber = paramString(params, 'phoneNumber', '')
        await call.makeCall(phoneNumber)
        return 'ok'
      }
      throw new Error('unsupported capability: SystemCapability.Applications.Contacts')
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.preloadCallUI', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      let result = await call.preloadCallUI()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.removeMissedIncomingCallNotification', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      await call.removeMissedIncomingCallNotification()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.sendCallUiEvent', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      let callId = paramInt(params, 'callId', 0)
      let eventName = paramString(params, 'eventName', '')
      await call.sendCallUiEvent(callId, eventName)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.separateConference', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      let callId = paramInt(params, 'callId', 0)
      await call.separateConference(callId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.setCallWaiting', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      let slotId = paramInt(params, 'slotId', 0)
      let activate = paramBoolean(params, 'activate', false)
      await call.setCallWaiting(slotId, activate)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.setDisplaySurface', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      let callId = paramInt(params, 'callId', 0)
      let surfaceId = paramString(params, 'surfaceId', '')
      await call.setDisplaySurface(callId, surfaceId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.setMuted', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      await call.setMuted()
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.setPreviewSurface', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      let callId = paramInt(params, 'callId', 0)
      let surfaceId = paramString(params, 'surfaceId', '')
      await call.setPreviewSurface(callId, surfaceId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.call.unloadCallUI', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CallManager')) {
      let result = await call.unloadCallUI()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CallManager')
  }],
  ['TelephonyKit.data.disableCellularDataRoaming', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CellularData')) {
      let slotId = paramInt(params, 'slotId', 0)
      await data.disableCellularDataRoaming(slotId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CellularData')
  }],
  ['TelephonyKit.data.enableCellularDataRoaming', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CellularData')) {
      let slotId = paramInt(params, 'slotId', 0)
      await data.enableCellularDataRoaming(slotId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CellularData')
  }],
  ['TelephonyKit.data.isCellularDataEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CellularData')) {
      let result = await data.isCellularDataEnabled()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CellularData')
  }],
  ['TelephonyKit.data.isCellularDataEnabledSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CellularData')) {
      let result = data.isCellularDataEnabledSync()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CellularData')
  }],
  ['TelephonyKit.data.isCellularDataRoamingEnabled', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CellularData')) {
      let slotId = paramInt(params, 'slotId', 0)
      let result = await data.isCellularDataRoamingEnabled(slotId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CellularData')
  }],
  ['TelephonyKit.data.isCellularDataRoamingEnabledSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CellularData')) {
      let slotId = paramInt(params, 'slotId', 0)
      let result = data.isCellularDataRoamingEnabledSync(slotId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CellularData')
  }],
  ['TelephonyKit.eSIM.isSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CoreService.Esim')) {
      let slotId = paramInt(params, 'slotId', 0)
      let result = eSIM.isSupported(slotId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CoreService.Esim')
  }],
  ['TelephonyKit.radio.factoryReset', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CoreService')) {
      let slotId = paramInt(params, 'slotId', 0)
      await radio.factoryReset(slotId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CoreService')
  }],
  ['TelephonyKit.radio.getIMEI', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CoreService')) {
      let slotId = paramInt(params, 'slotId', 0)
      let result = await radio.getIMEI(slotId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CoreService')
  }],
  ['TelephonyKit.radio.getIMEISV', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CoreService')) {
      let slotId = paramInt(params, 'slotId', 0)
      let result = radio.getIMEISV(slotId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CoreService')
  }],
  ['TelephonyKit.radio.getISOCountryCodeForNetwork', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CoreService')) {
      let slotId = paramInt(params, 'slotId', 0)
      let result = await radio.getISOCountryCodeForNetwork(slotId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CoreService')
  }],
  ['TelephonyKit.radio.getISOCountryCodeForNetworkSync', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CoreService')) {
      let slotId = paramInt(params, 'slotId', 0)
      let result = radio.getISOCountryCodeForNetworkSync(slotId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CoreService')
  }],
  ['TelephonyKit.radio.getMEID', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CoreService')) {
      let slotId = paramInt(params, 'slotId', 0)
      let result = await radio.getMEID(slotId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CoreService')
  }],
  ['TelephonyKit.radio.getUniqueDeviceId', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CoreService')) {
      let slotId = paramInt(params, 'slotId', 0)
      let result = await radio.getUniqueDeviceId(slotId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CoreService')
  }],
  ['TelephonyKit.radio.isManualNetworkScanning', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CoreService')) {
      let slotId = paramInt(params, 'slotId', 0)
      let result = await radio.isManualNetworkScanning(slotId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CoreService')
  }],
  ['TelephonyKit.radio.isNRSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CoreService')) {
      let result = radio.isNRSupported()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CoreService')
  }],
  ['TelephonyKit.radio.isRadioOn', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CoreService')) {
      let slotId = paramInt(params, 'slotId', 0)
      let result = await radio.isRadioOn(slotId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CoreService')
  }],
  ['TelephonyKit.radio.stopManualNetworkScan', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CoreService')) {
      let slotId = paramInt(params, 'slotId', 0)
      await radio.stopManualNetworkScan(slotId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CoreService')
  }],
  ['TelephonyKit.sim.getMaxSimCount', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CoreService')) {
      let result = sim.getMaxSimCount()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CoreService')
  }],
  ['TelephonyKit.sim.hasOperatorPrivileges', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CoreService')) {
      let slotId = paramInt(params, 'slotId', 0)
      let result = await sim.hasOperatorPrivileges(slotId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CoreService')
  }],
  ['TelephonyKit.sim.setShowName', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.CoreService')) {
      let slotId = paramInt(params, 'slotId', 0)
      let name = paramString(params, 'name', '')
      await sim.setShowName(slotId, name)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.CoreService')
  }],
  ['TelephonyKit.sms.getDefaultSmsSimId', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.SmsMms')) {
      let result = await sms.getDefaultSmsSimId()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.SmsMms')
  }],
  ['TelephonyKit.sms.getDefaultSmsSlotId', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.SmsMms')) {
      let result = await sms.getDefaultSmsSlotId()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.SmsMms')
  }],
  ['TelephonyKit.sms.getImsShortMessageFormat', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.SmsMms')) {
      let result = await sms.getImsShortMessageFormat()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.SmsMms')
  }],
  ['TelephonyKit.sms.getSmscAddr', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.SmsMms')) {
      let slotId = paramInt(params, 'slotId', 0)
      let result = await sms.getSmscAddr(slotId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.SmsMms')
  }],
  ['TelephonyKit.sms.hasSmsCapability', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.SmsMms')) {
      let result = sms.hasSmsCapability()
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.SmsMms')
  }],
  ['TelephonyKit.sms.isImsSmsSupported', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.SmsMms')) {
      let slotId = paramInt(params, 'slotId', 0)
      let result = await sms.isImsSmsSupported(slotId)
      return result.toString()
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.SmsMms')
  }],
  ['TelephonyKit.sms.setDefaultSmsSlotId', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.SmsMms')) {
      let slotId = paramInt(params, 'slotId', 0)
      await sms.setDefaultSmsSlotId(slotId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.SmsMms')
  }],
  ['TelephonyKit.sms.setSmscAddr', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Telephony.SmsMms')) {
      let slotId = paramInt(params, 'slotId', 0)
      let smscAddr = paramString(params, 'smscAddr', '')
      await sms.setSmscAddr(slotId, smscAddr)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Telephony.SmsMms')
  }],
  ['UniversalKeystoreKit.huksExternalCrypto.clearUkeyPinAuthState', async (params: Map<string, string>): Promise<string> => {
    if (canIUse('SystemCapability.Security.Huks.CryptoExtension')) {
      let resourceId = paramString(params, 'resourceId', '')
      await huksExternalCrypto.clearUkeyPinAuthState(resourceId)
      return 'ok'
    }
    throw new Error('unsupported capability: SystemCapability.Security.Huks.CryptoExtension')
  }],
])

/**
 * Runs the real adapter for `target`, or answers with the same stub text
 * sdk.call has always used if this target doesn't have one yet -- callers
 * don't need to check first, and a target with no adapter is never the
 * reason a call hangs.
 */
export async function runSdkAdapter(target: string, params: Map<string, string>): Promise<string> {
  // The live-data block's own function (VeraLive.ets): not an SDK function, so not in ADAPTERS or the index.
  if (target === LIVE_TARGET) { return await liveFetch(params) }
  if (calendarSdkTargets.indexOf(target) >= 0) {
    return await runCalendarSdkAdapter(target, params)
  }
  let adapter = ADAPTERS.get(target)
  if (adapter === undefined) {
    return 'error: sdk.call is not implemented yet'
  }
  try {
    return await adapter(params)
  } catch (e) {
    return 'error: ' + (e as Error).message
  }
}

/**
 * Whether `target` has a real adapter: a row in ADAPTERS or one of the CalendarKit
 * targets VeraCalendarSdk handles. find_sdk_function, as the model
 * reaches it (DeepSeekEngine), returns only such targets: a program that picks a
 * stub compiles and runs and then answers "sdk.call is not implemented yet" on
 * every tap -- a Morse widget did exactly that while setTorchMode sat first in
 * its results. The ranking itself does not use it, and the eval, probe and
 * benchmark search the whole index and mark each result :impl/:stub with it, so
 * recall is still measured against everything the SDK has.
 */
export function isSdkTargetImplemented(target: string): boolean {
  return calendarSdkTargets.indexOf(target) >= 0 || ADAPTERS.has(target) || target === LIVE_TARGET
}
