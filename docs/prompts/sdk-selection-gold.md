# SDK selection: gold labels (reduced set)

Each row is one `need` string and the SDK targets that would be a correct
answer to it. Grade **2** = the function a third-party app should call today,
**1** = works but deprecated or a weaker match, **0** = wrong, or unusable by a
normal app. An empty gold means no SDK call is correct for that request.

Checked two ways: the flags in `entry/src/main/resources/rawfile/sdk-index.json`
(`deprecated`, `systemapi`, params, return type), and the official reference in
the OpenHarmony docs checkout (`en/application-dev/reference/`, the page's own
deprecation notice and its advised replacement). `state` is the entry in
`ADAPTERS` (`VeraSdkBackend.ets`) when this was written.

| id | need | target | grade | index flags | docs say | state |
|---|---|---|---|---|---|---|
| battery | read the current battery level | `BasicServicesKit.Battery.getStatus` | 1 | deprecated | `@system.battery`, "no longer maintained since API 6", use `batteryInfo.batterySOC` | stub |
| torch | turn on the phone flashlight torch | `CameraKit.CameraManager.setTorchMode` | 2 | — | `setTorchMode` (11+) | impl |
| torch | turn on the phone flashlight torch | `CameraKit.CameraManager.setTorchModeOnWithLevel` | 0 | systemapi | not for apps | stub |
| bluetooth | turn Bluetooth on | `ConnectivityKit.access.enableBluetooth` | 2 | — | `access.enableBluetooth` (10+) | stub |
| bluetooth | turn Bluetooth on | `ConnectivityKit.access.enableBluetoothAsync` | 2 | — | `enableBluetoothAsync` (20+), reports the user's dialog answer | stub |
| bluetooth | turn Bluetooth off | `ConnectivityKit.access.disableBluetooth` | 2 | — | `access.disableBluetooth` | stub |
| bluetooth | turn Bluetooth on or off | `ConnectivityKit.bluetooth.enableBluetooth` | 1 | deprecated | advised `bluetoothManager.enableBluetooth`, itself deprecated | stub |
| photo | take a photo with the camera | `CameraKit.PhotoOutput.capture` | 2 | — | `capture()` (10+), promise form | stub |
| vibrate | vibrate the phone | `SensorServiceKit.vibrator.startVibration` | 2 | — | `vibrator.startVibration` (9+), needs `ohos.permission.VIBRATE` | stub |
| vibrate | vibrate the phone | `SensorServiceKit.Vibrator.vibrate` | 1 | deprecated | not found in the local reference page (`js-apis-system-vibrate.md` has no deprecation notice); grade rests on the index flag | stub |
| location | read the current location | `LocationKit.geoLocationManager.getCurrentLocation` | 2 | — | `geoLocationManager.getCurrentLocation` (9+) | stub |
| location | read the current location | `LocationKit.geolocation.getCurrentLocation` | 1 | deprecated | `geolocation.*` deprecated since 9 | stub |
| volume | set the media volume | `AudioKit.AudioManager.setVolume` | 1 | deprecated | `AudioManager` deprecated, use `AudioVolumeManager` | impl |
| volume | set the media volume | `AudioKit.AudioVolumeGroupManager.setVolume` | 0 | systemapi | not for apps | stub |
| negative | a counter that adds one each time the button is tapped | (none) | — | — | — | — |
| qr | scan a QR code with the camera | (none in index) | — | — | — | — |

## Corrections from the earlier passes

- `SensorServiceKit.vibrator.on` was listed as a vibrate answer. It subscribes
  to vibrator state changes; it does not vibrate. Removed.
- `setTorchModeOnWithLevel` was graded 1. It is a system API, so an ordinary app
  cannot call it. Now 0.
- Bluetooth: the on-and-off request needs two functions, `enableBluetooth` for
  on and `disableBluetooth` for off. The first pass graded only the enable side.
- Battery: `Battery.getStatus` was graded 2 on the first pass, and the index
  flag alone looked like the only option. The reference says it is no longer
  maintained and points to `batteryInfo.batterySOC`. That is a **constant**, not a
  function, so the index (functions only) cannot contain it. The best reachable
  target here is grade 1, and the row's true answer is outside the index.
- Volume: `AudioManager.setVolume` is deprecated, so grade 1. The
  `AudioVolumeGroupManager` version is a system API (grade 0).

## Reading this

- Of the grade-2 targets that are reachable, only torch is implemented. The
  rest are stubs: photo, vibrate, location, Bluetooth on and off. Retrieval can
  rank them first and the call still answers `error: sdk.call is not
  implemented yet`. `Impl@k` will sit below `Recall@k` on this set; that gap is
  what this measurement is for.
- Battery and volume show a different limit: the best public answer is
  deprecated or outside the index, so no reachable target grades 2. Those rows
  test whether the model is shown the deprecated option at all.
- `negative` checks that the model does not reach for the SDK. `qr` has no
  correct answer, so the right behaviour is to say so.
