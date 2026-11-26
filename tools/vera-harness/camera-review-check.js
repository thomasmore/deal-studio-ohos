// Host verification for the two camera-review fixes (commit e8ec495):
//   1. isCameraCaptureNeed: only a capture-only need is filled by the capture fragment;
//      compound needs (QR scan -> decode -> open URL) and camera-only-in-passing needs
//      (a settings checklist, "without taking photos") are left for the writer.
//   2. VeraCamera: a photo arriving after capture settlement (timeout, or the second of the
//      photoAvailable/photoAssetAvailable pair) is released, and capture() registers no
//      per-capture listeners (the handlers are session-level in start()).
// No phone, no kit, no network: the @kit imports are stubbed by source-loader.
'use strict'
const assert = require('node:assert/strict')
const {loadVera} = require('./source-loader')

const np = loadVera('NeedsPlan')
const {VeraCamera} = loadVera('VeraCamera')

// --- 1. isCameraCaptureNeed --------------------------------------------------
// A need the fragment can satisfy on its own: frame a preview, snap a photo, keep it.
const captureOnly = [
  'A live camera view inside the app: the person frames what they want to photograph and taps a shutter; the captured photo is shown and kept.',
  'Photograph the receipt and keep it',
  'A camera preview to capture the page',
  'Let me use the camera to take a picture of the document'
]
for (const words of captureOnly) {
  assert.ok(np.isCameraNeed(words), 'baseline: isCameraNeed still sees a camera need: ' + words.slice(0, 40))
  assert.ok(np.isCameraCaptureNeed(words), 'capture-only: ' + words.slice(0, 40))
}

// Compound needs the fragment cannot satisfy: scan/decode/recognize/open/checklist/without-taking.
const compound = [
  'Build a QR code scanner. Let me point the camera at a QR code, scan it, and open the decoded URL. Show the decoded URL before opening it.',
  'Display a camera settings checklist without taking photos',
  'Scan a barcode and look up the product',
  'Scans receipts and extracts totals',
  'Use the camera to recognize text on the page',
  'Point the camera at a QR code, decode it and open the link',
  'A camera settings checklist for the photographer'
]
for (const words of compound) {
  assert.ok(np.isCameraNeed(words), 'baseline: isCameraNeed still sees a camera need: ' + words.slice(0, 40))
  assert.ok(!np.isCameraCaptureNeed(words), 'should NOT be capture-only (left for the writer): ' + words.slice(0, 40))
}

// ensureCameraNeed still adds a capture-only need when the prompt says camera/photograph/scan.
let plan = np.parseNeedsPlan('{"needs":[{"type":"other","words":"Keep a list of pages"}]}')
np.ensureCameraNeed(plan, 'Take a photograph of each page')
let added = plan.needs.filter(n => np.isCameraCaptureNeed(n.words))
assert.ok(added.length === 1, 'ensureCameraNeed adds a capture-only camera need')

console.log('isCameraCaptureNeed: ' + captureOnly.length + ' capture-only, ' + compound.length + ' compound, ensureCameraNeed intact')

// --- 2. VeraCamera late-photo release and no per-capture listeners ------------
// source-loader stubs @kit.* to {}, and TS `private` is erased at runtime, so the handler
// methods and fields are reachable from plain JS for the cases that do not touch the filesystem.

function makePhoto() {
  let mainCalls = 0, photoCalls = 0
  return {
    main: { release: () => { mainCalls++; return Promise.resolve() } },
    release: () => { photoCalls++; return Promise.resolve() },
    _mainCalls: () => mainCalls, _photoCalls: () => photoCalls
  }
}

// A settled or absent pending capture: a photo arriving now is stray and must be released.
let cam = new VeraCamera()
cam.pending = null
let stray = makePhoto()
cam.onPhotoAvailable(undefined, stray)
assert.equal(stray._mainCalls(), 1, 'stray photo: main.release called')
assert.equal(stray._photoCalls(), 1, 'stray photo: release called')

// A pending capture that already settled (timeout): the late photo is released, resolve NOT called.
let resolved = null
cam.pending = { settled: true, resolve: (p) => { resolved = p }, reject: () => {}, assetUri: '', timer: -1 }
let late = makePhoto()
cam.onPhotoAvailable(undefined, late)
assert.equal(late._mainCalls(), 1, 'late photo after settle: main.release called')
assert.equal(late._photoCalls(), 1, 'late photo after settle: release called')
assert.equal(resolved, null, 'late photo after settle: resolve not called')

// A pending capture that is open: the photo is handed to the caller (resolve), NOT released here.
let handed = null
cam.pending = { settled: false, resolve: (p) => { handed = p }, reject: () => {}, assetUri: '', timer: -1 }
let good = makePhoto()
cam.onPhotoAvailable(undefined, good)
assert.equal(good._mainCalls(), 0, 'success path: the caller releases the photo, not the handler')
assert.equal(good._photoCalls(), 0, 'success path: the caller releases the photo, not the handler')
assert.equal(handed, good, 'success path: resolve called with the photo')

// An error on a pending capture: the photo is released and the capture rejects.
let rejected = null
cam.pending = { settled: false, resolve: () => {}, reject: (e) => { rejected = e }, assetUri: '', timer: -1 }
let errPhoto = makePhoto()
cam.onPhotoAvailable({ code: 1001, message: 'capture failed' }, errPhoto)
assert.equal(errPhoto._mainCalls(), 1, 'error path: main.release called')
assert.equal(errPhoto._photoCalls(), 1, 'error path: release called')
assert.ok(rejected instanceof Error && rejected.message === 'capture failed', 'error path: reject called')

// photoAssetAvailable with no pending capture: no crash, no throw.
cam.pending = null
assert.doesNotThrow(() => cam.onPhotoAssetAvailable(undefined, { uri: 'file://asset' }))

// photoAssetAvailable on an open pending capture: resolves with null and records the asset URI.
let assetResolved = 'unset'
cam.pending = { settled: false, resolve: (p) => { assetResolved = p }, reject: () => {}, assetUri: '', timer: -1 }
cam.onPhotoAssetAvailable(undefined, { uri: 'file://media/123' })
assert.equal(assetResolved, null, 'asset path: resolve called with null')
assert.equal(cam.pending.assetUri, 'file://media/123', 'asset path: asset URI recorded')
cam.pending = null

// capture() registers no per-capture listeners: the handlers live in start(). Drive capture()
// with an output whose capture() rejects fast (so the promise settles without the 15s timer)
// and assert output.on is never called, and pending/capturing are cleared in the finally.
let onCalls = 0
let fakeOutput = {
  on: () => { onCalls++ },
  off: () => {},
  capture: () => Promise.reject(new Error('no hardware on host'))
}
cam.started = true
cam.output = fakeOutput
cam.capturing = false
// AbilityContext.value must be non-null for capture() to proceed past its guard; it is only
// read on the success path, which the fast reject never reaches.
const VeraPermissions = loadVera('VeraPermissions')
VeraPermissions.AbilityContext.value = { filesDir: '/tmp/vera-cam-test' }

cam.capture().then(
  () => { throw new Error('capture should have rejected on host') },
  (e) => {
    assert.equal(e.message, 'no hardware on host', 'capture() surfaces the output.capture rejection')
    assert.equal(onCalls, 0, 'capture() does not register per-capture listeners (session-level in start())')
    assert.equal(cam.capturing, false, 'capture() clears capturing in its finally')
    assert.equal(cam.pending, null, 'capture() clears pending in its finally')
    console.log('VeraCamera: late-photo release on settle/timeout, error-path release, no per-capture listeners')
    console.log('camera-review-check: ok')
  }
)
