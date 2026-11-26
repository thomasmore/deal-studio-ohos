/**
 * The host side of ui.Camera: a live CameraKit preview on an XComponent
 * surface, and a shutter that captures one JPEG and answers its file URI.
 *
 * The VM never sees this object. The renderer owns it, starts it when the
 * XComponent's surface exists, stops it when the component leaves the screen,
 * and hands the program only the captured file URI through the handler, the
 * same way every other UI value reaches it.
 *
 * This is deliberately separate from VeraSdkBackend's camera picker adapter:
 * that one is a single sdk.call that opens the system camera (viewfinder,
 * shutter and confirmation in another app); this one keeps the preview inside
 * the generated screen, which is what a scanning or note-photographing screen
 * needs.
 */

import { camera } from '@kit.CameraKit'
import { image } from '@kit.ImageKit'
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { fileIo as fs, fileUri } from '@kit.CoreFileKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { AbilityContext, ensureCameraPermission } from './VeraPermissions'

/** A profile close to 4:3 at about a megapixel: enough to read a page, cheap on the phone. */
function areaDistance(profile: camera.Profile): number {
  // Prefer a 4:3 page-shaped output; a square or ultra-wide profile is still
  // accepted when nothing else is offered, but this phone's capture path
  // behaved badly with a square profile.
  let ratio = profile.size.height === 0 ? 0 : profile.size.width / profile.size.height
  let shape = Math.abs(ratio - 4 / 3) * 1000000
  return Math.abs(profile.size.width * profile.size.height - 1280 * 960) + shape
}

function pickPreviewProfile(capability: camera.CameraOutputCapability): camera.Profile | null {
  let best: camera.Profile | null = null
  let bestDistance = Number.MAX_SAFE_INTEGER
  for (let profile of capability.previewProfiles) {
    let distance = areaDistance(profile)
    if (best === null || distance < bestDistance) {
      best = profile
      bestDistance = distance
    }
  }
  return best
}

function pickPhotoProfile(capability: camera.CameraOutputCapability): camera.Profile | null {
  let best: camera.Profile | null = null
  let bestDistance = Number.MAX_SAFE_INTEGER
  for (let profile of capability.photoProfiles) {
    if (profile.format !== camera.CameraFormat.CAMERA_FORMAT_JPEG) { continue }
    let distance = areaDistance(profile)
    if (best === null || distance < bestDistance) {
      best = profile
      bestDistance = distance
    }
  }
  return best
}

function chooseDevice(cameras: camera.CameraDevice[], facing: string): camera.CameraDevice | null {
  let wantFront = facing.toLowerCase() === 'front'
  let wanted = wantFront ? camera.CameraPosition.CAMERA_POSITION_FRONT : camera.CameraPosition.CAMERA_POSITION_BACK
  for (let candidate of cameras) {
    if (candidate.cameraPosition === wanted) { return candidate }
  }
  return cameras.length > 0 ? cameras[0] : null
}

/**
 * The one capture in flight: the session-level photo handlers resolve or reject
 * it, and a photo that arrives after it has settled (a slow capture that timed
 * out, or the second of the photoAvailable/photoAssetAvailable pair) is released
 * through it so native camera and image buffers are not held by a stray delivery.
 */
class CameraCapturePending {
  settled: boolean = false
  resolve: ((photo: camera.Photo | null) => void) | null = null
  reject: ((error: Error) => void) | null = null
  assetUri: string = ''
  timer: number = -1
}

export class VeraCamera {
  private input: camera.CameraInput | null = null
  private session: camera.PhotoSession | null = null
  private preview: camera.PreviewOutput | null = null
  private output: camera.PhotoOutput | null = null
  private surfaceId: string = ''
  private started: boolean = false
  private capturing: boolean = false
  private generation: number = 0
  private pending: CameraCapturePending | null = null

  /** The surface this camera is showing on, or '' before start. */
  surface(): string { return this.surfaceId }

  /** True once the preview session is running; the shutter stays disabled until then. */
  isStarted(): boolean { return this.started }

  /**
   * Opens the chosen camera and starts a preview on `surfaceId`. Safe to call
   * twice for the same surface (a re-render can re-fire XComponent.onLoad); a
   * different surface replaces the old session.
   */
  async start(surfaceId: string, facing: string): Promise<void> {
    console.info('VERA-CAMERA start surface=' + surfaceId + ' facing=' + facing)
    if (this.started && this.surfaceId === surfaceId) { return }
    if (this.started) { await this.stop() }
    let generation = ++this.generation
    let context = AbilityContext.value
    if (context === null) { throw new Error('camera: no ability context') }
    if (!await ensureCameraPermission(context)) { throw new Error('camera permission not granted') }
    if (generation !== this.generation) { return }
    let manager = camera.getCameraManager(context)
    let cameras: camera.CameraDevice[] = []
    for (let attempt = 0; attempt < 10 && cameras.length === 0; attempt++) {
      try {
        cameras = manager.getSupportedCameras()
      } catch (_e) {
        cameras = []
      }
      if (cameras.length === 0) {
        await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 300) })
      }
    }
    console.info('VERA-CAMERA cameras=' + cameras.length.toString())
    for (let c of cameras) {
      console.info('VERA-CAMERA camera ' + c.cameraId + ' position=' + c.cameraPosition.toString())
    }
    let device = chooseDevice(cameras, facing)
    if (device === null) { throw new Error('camera: no camera on this device') }
    let capability: camera.CameraOutputCapability
    try {
      capability = manager.getSupportedOutputCapability(device, camera.SceneMode.NORMAL_PHOTO)
    } catch (_e) {
      capability = manager.getSupportedOutputCapability(device)
    }
    let previewProfile = pickPreviewProfile(capability)
    let photoProfile = pickPhotoProfile(capability)
    if (previewProfile === null) { throw new Error('camera: no preview output') }
    if (photoProfile === null) { throw new Error('camera: no JPEG photo output') }

    let input: camera.CameraInput | null = null
    let session: camera.PhotoSession | null = null
    let preview: camera.PreviewOutput | null = null
    let output: camera.PhotoOutput | null = null
    try {
      input = await manager.createCameraInput(device)
      await input.open()
      if (generation !== this.generation) { throw new Error('camera: stopped while opening') }
      session = manager.createSession<camera.PhotoSession>(camera.SceneMode.NORMAL_PHOTO)
      preview = manager.createPreviewOutput(previewProfile, surfaceId)
      output = manager.createPhotoOutput(photoProfile)
      session.beginConfig()
      session.addInput(input)
      session.addOutput(preview)
      session.addOutput(output)
      await session.commitConfig()
      await session.start()
      if (generation !== this.generation) { throw new Error('camera: stopped while starting') }
      this.input = input
      this.session = session
      this.preview = preview
      this.output = output
      this.surfaceId = surfaceId
      this.started = true
      // One pair of handlers for the whole session: a capture points `this.pending`
      // at itself, the handler resolves or rejects it, and any photo that arrives
      // with no pending capture (or after one has settled) is released here so it
      // does not leak native buffers. Registered once per output, not per capture,
      // so the per-capture closures do not stack across a long-lived preview.
      output.on('photoAvailable', (err: BusinessError, captured: camera.Photo): void => {
        this.onPhotoAvailable(err, captured)
      })
      output.on('photoAssetAvailable', (err: BusinessError, asset: photoAccessHelper.PhotoAsset): void => {
        this.onPhotoAssetAvailable(err, asset)
      })
      console.info('VERA-CAMERA started ' + previewProfile.size.width.toString() + 'x' + previewProfile.size.height.toString() + ' photo=' + photoProfile.size.width.toString() + 'x' + photoProfile.size.height.toString())
    } catch (e) {
      if (output !== null) { try { await output.release() } catch (_e) {} }
      if (preview !== null) { try { await preview.release() } catch (_e) {} }
      if (session !== null) {
        try { await session.stop() } catch (_e) {}
        try { await session.release() } catch (_e) {}
      }
      if (input !== null) { try { await input.close() } catch (_e) {} }
      throw e as Error
    }
  }

  /**
   * Captures one JPEG from the running session and answers its app-sandbox
   * file URI. The preview stays live, so the next tap can capture again.
   */
  async capture(): Promise<string> {
    if (!this.started || this.output === null) { throw new Error('camera is not running') }
    if (this.capturing) { throw new Error('camera is already taking a photo') }
    let context = AbilityContext.value
    if (context === null) { throw new Error('camera: no ability context') }
    let output = this.output
    console.info('VERA-CAMERA capture begin')
    this.capturing = true
    let pending = new CameraCapturePending()
    this.pending = pending
    try {
      let photo = await new Promise<camera.Photo | null>((resolve: (photo: camera.Photo | null) => void,
          reject: (error: Error) => void): void => {
        pending.resolve = resolve
        pending.reject = reject
        pending.timer = setTimeout((): void => {
          if (pending.settled) { return }
          pending.settled = true
          console.error('VERA-CAMERA capture timed out')
          reject(new Error('camera capture timed out'))
        }, 15000)
        output.capture().then((): void => { console.info('VERA-CAMERA capture accepted') }).catch((e: Error): void => {
          if (pending.settled) { return }
          pending.settled = true
          clearTimeout(pending.timer)
          reject(e)
        })
      })
      if (photo === null) {
        let dir = context.filesDir + '/vera/photos'
        try { fs.mkdirSync(dir, true) } catch (_e) {}
        let path = dir + '/camera-' + Date.now().toString() + '.jpg'
        let source: fs.File | null = null
        try {
          source = fs.openSync(pending.assetUri, fs.OpenMode.READ_ONLY)
          fs.copyFileSync(source.fd, path)
        } finally {
          if (source !== null) { fs.closeSync(source) }
        }
        console.info('VERA-CAMERA saved asset ' + path)
        return fileUri.getUriFromPath(path)
      }
      try {
        let component = await photo.main.getComponent(image.ComponentType.JPEG)
        let dir = context.filesDir + '/vera/photos'
        try { fs.mkdirSync(dir, true) } catch (_e) {}
        let path = dir + '/camera-' + Date.now().toString() + '.jpg'
        let file: fs.File | null = null
        try {
          file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
          fs.writeSync(file.fd, component.byteBuffer)
        } finally {
          if (file !== null) { fs.closeSync(file) }
        }
        console.info('VERA-CAMERA saved ' + path)
        return fileUri.getUriFromPath(path)
      } finally {
        await photo.main.release()
        await photo.release()
      }
    } finally {
      this.capturing = false
      this.pending = null
    }
  }

  /** Resolves the pending capture with a photo, or releases a photo that arrived late. */
  private onPhotoAvailable(err: BusinessError, captured: camera.Photo): void {
    let p = this.pending
    if (p === null || p.settled) {
      // No capture waiting, or it already settled (a slow capture that timed out, or
      // the asset path already won): release this photo so native capture/image buffers
      // are not held by a delivery nobody consumed.
      this.releasePhoto(captured)
      return
    }
    p.settled = true
    clearTimeout(p.timer)
    if (err) {
      console.error('VERA-CAMERA photo error ' + err.code.toString() + ' ' + err.message)
      this.releasePhoto(captured)
      p.reject!(new Error(err.message))
      return
    }
    console.info('VERA-CAMERA photo available')
    p.resolve!(captured)
  }

  /** Resolves the pending capture with a photo-asset URI, or drops a late asset. */
  private onPhotoAssetAvailable(err: BusinessError, asset: photoAccessHelper.PhotoAsset): void {
    let p = this.pending
    if (p === null || p.settled) { return }
    p.settled = true
    clearTimeout(p.timer)
    if (err) {
      console.error('VERA-CAMERA asset error ' + err.code.toString() + ' ' + err.message)
      p.reject!(new Error(err.message))
      return
    }
    p.assetUri = asset.uri
    console.info('VERA-CAMERA photo asset ' + p.assetUri)
    p.resolve!(null)
  }

  private releasePhoto(captured: camera.Photo): void {
    // Fire-and-forget: this runs in the synchronous event handler, so the async
    // releases cannot be awaited here. .catch swallows rejections so a release
    // failure on a stray photo does not become an unhandled rejection.
    captured.main.release().catch((): void => {})
    captured.release().catch((): void => {})
  }

  /** Stops the preview and releases every camera object; safe to call more than once. */
  async stop(): Promise<void> {
    if (this.started) { console.info('VERA-CAMERA stop') }
    this.generation++
    this.started = false
    this.capturing = false
    this.surfaceId = ''
    this.pending = null
    let input = this.input
    let session = this.session
    let preview = this.preview
    let output = this.output
    this.input = null
    this.session = null
    this.preview = null
    this.output = null
    if (output !== null) {
      try { output.off('photoAvailable') } catch (_e) {}
      try { output.off('photoAssetAvailable') } catch (_e) {}
      try { await output.release() } catch (_e) {}
    }
    if (preview !== null) {
      try { await preview.release() } catch (_e) {}
    }
    if (session !== null) {
      try { await session.stop() } catch (_e) {}
      try { await session.release() } catch (_e) {}
    }
    if (input !== null) {
      try { await input.close() } catch (_e) {}
    }
  }
}