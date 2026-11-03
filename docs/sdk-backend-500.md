# 484 real sdk.call targets

Selected by `tools/select-sdk-backend-candidates.py` from 536 candidates that a generator can safely turn into a real backend call: a namespace-level function (not a class/interface method needing an instance), at most 2 simple-typed parameters, a primitive or void return. Implemented by `tools/generate-sdk-backend.py` into `VeraSdkBackend.ets`.

**484 selected**, across 31 kits.

## TelephonyKit (55)

- `TelephonyKit.call.canSetCallTransferTime(slotId: int): Promise<boolean>` -- Checks whether can set call transfer time.
- `TelephonyKit.call.cancelMuted(): Promise<void>` -- Unmute during a call.
- `TelephonyKit.call.closeUnfinishedUssd(slotId: int): Promise<void>` -- Close unfinished ussd.
- `TelephonyKit.call.combineConference(callId: int): Promise<void>` -- Merge calls, merge two calls into conference calls.
- `TelephonyKit.call.controlCamera(callId: int, cameraId: string): Promise<void>` -- Control camera to open/close/switch camera by cameraId when video call.
- `TelephonyKit.data.disableCellularDataRoaming(slotId: int): Promise<void>` -- Disable cellular data roaming.
- `TelephonyKit.call.disableImsSwitch(slotId: int): Promise<void>` -- Turn off Ims switch.
- `TelephonyKit.data.enableCellularDataRoaming(slotId: int): Promise<void>` -- Enable cellular data roaming.
- `TelephonyKit.radio.factoryReset(slotId: int): Promise<void>` -- Reset all network settings of telephony.
- `TelephonyKit.sms.getDefaultSmsSimId(): Promise<int>` -- Obtains the default SIM ID for sending SMS messages.
- `TelephonyKit.sms.getDefaultSmsSlotId(): Promise<int>` -- Obtains the default SIM card for sending SMS messages.
- `TelephonyKit.radio.getIMEI(slotId: int?): Promise<string>` -- Obtains the IMEI of a specified card slot of the device.
- `TelephonyKit.radio.getIMEISV(slotId: int): string` -- Obtains the software version number of a specified card slot of the device.
- `TelephonyKit.radio.getISOCountryCodeForNetwork(slotId: int): Promise<string>` -- Obtains the ISO-defined country code of the country where the registered network is deployed.
- `TelephonyKit.radio.getISOCountryCodeForNetworkSync(slotId: int): string` -- Obtains the ISO-defined country code of the country where the registered network is deployed.
- `TelephonyKit.sms.getImsShortMessageFormat(): Promise<string>` -- Gets SMS format supported on IMS. SMS over IMS format is either 3GPP or 3GPP2.
- `TelephonyKit.radio.getMEID(slotId: int?): Promise<string>` -- Obtains the MEID of a specified card slot of the device.
- `TelephonyKit.call.getMainCallId(callId: int): Promise<int>` -- Get the main call Id.
- `TelephonyKit.sim.getMaxSimCount(): int` -- Obtains the maximum number of SIM cards that can be used simultaneously on the device,
- `TelephonyKit.sms.getSmscAddr(slotId: int): Promise<string>` -- Obtains the SMSC address based on a specified slot ID.
- `TelephonyKit.radio.getUniqueDeviceId(slotId: int?): Promise<string>` -- Obtains the unique device ID of a specified card slot of the device.
- `TelephonyKit.call.hangUpCall(callId: int?): Promise<void>` -- Hang up the foreground call.
- `TelephonyKit.call.hasCall(): Promise<boolean>` -- Checks whether a call is ongoing.
- `TelephonyKit.call.hasCallSync(): boolean` -- Checks whether a call is ongoing.
- `TelephonyKit.sim.hasOperatorPrivileges(slotId: int): Promise<boolean>` -- Checks whether your application (the caller) has been granted the operator permissions.
- `TelephonyKit.sms.hasSmsCapability(): boolean` -- Returns whether a device is capable of sending and receiving SMS messages.
- `TelephonyKit.call.hasVoiceCapability(): boolean` -- Checks whether a device supports voice calls.
- `TelephonyKit.data.isCellularDataEnabled(): Promise<boolean>` -- Check whether cellular data services are enabled.
- `TelephonyKit.data.isCellularDataEnabledSync(): boolean` -- Check whether cellular data services are enabled.
- `TelephonyKit.data.isCellularDataRoamingEnabled(slotId: int): Promise<boolean>` -- Check whether roaming is enabled for cellular data services.
- `TelephonyKit.data.isCellularDataRoamingEnabledSync(slotId: int): boolean` -- Check whether roaming is enabled for cellular data services.
- `TelephonyKit.sms.isImsSmsSupported(slotId: int): Promise<boolean>` -- SMS over IMS is supported if IMS is registered and SMS is supported on IMS.
- `TelephonyKit.call.isImsSwitchEnabled(slotId: int): Promise<boolean>` -- Judge whether the Ims switch is enabled.
- `TelephonyKit.call.isImsSwitchEnabledSync(slotId: int): boolean` -- Judge whether the Ims switch is enabled.
- `TelephonyKit.call.isInEmergencyCall(): Promise<boolean>` -- Judge whether the emergency call is in progress.
- `TelephonyKit.radio.isManualNetworkScanning(slotId: int): Promise<boolean>` -- Determine whether the current manual network scan is in progress.
- `TelephonyKit.radio.isNRSupported(): boolean` -- Checks whether the device supports 5G New Radio (NR).
- `TelephonyKit.call.isNewCallAllowed(): Promise<boolean>` -- Judge whether to allow another new call.
- `TelephonyKit.radio.isRadioOn(slotId: int?): Promise<boolean>` -- Checks whether the radio service is enabled.
- `TelephonyKit.call.isRinging(): Promise<boolean>` -- Judge whether there is a ringing call.
- `TelephonyKit.eSIM.isSupported(slotId: int): boolean` -- Whether embedded subscriptions are currently supported.
- `TelephonyKit.call.makeCall(phoneNumber: string): Promise<void>` -- Go to the dial screen and the called number is displayed.
- `TelephonyKit.call.preloadCallUI(): Promise<boolean>` -- Preload callUI.
- `TelephonyKit.call.removeMissedIncomingCallNotification(): Promise<void>` -- Remove missed incoming call notification.
- `TelephonyKit.call.sendCallUiEvent(callId: int, eventName: string): Promise<void>` -- Send call ui event.
- `TelephonyKit.call.separateConference(callId: int): Promise<void>` -- Split conference call.
- `TelephonyKit.call.setCallWaiting(slotId: int, activate: boolean): Promise<void>` -- Set call waiting.
- `TelephonyKit.sms.setDefaultSmsSlotId(slotId: int): Promise<void>` -- Sets the default SIM card for sending SMS messages. You can obtain the default SIM card by
- `TelephonyKit.call.setDisplaySurface(callId: int, surfaceId: string): Promise<void>` -- Set display surface when video call.
- `TelephonyKit.call.setMuted(): Promise<void>` -- Set mute during a call.
- `TelephonyKit.call.setPreviewSurface(callId: int, surfaceId: string): Promise<void>` -- Set preview surface when video call.
- `TelephonyKit.sim.setShowName(slotId: int, name: string): Promise<void>` -- Set the SIM card display name of the specified card slot.
- `TelephonyKit.sms.setSmscAddr(slotId: int, smscAddr: string): Promise<void>` -- Sets the address for the Short Message Service Center (SMSC) based on a specified slot ID.
- `TelephonyKit.radio.stopManualNetworkScan(slotId: int): Promise<void>` -- Stop ManualNetworkScan.
- `TelephonyKit.call.unloadCallUI(): Promise<boolean>` -- Unload callUI.

## ConnectivityKit (51)

- `ConnectivityKit.wifiManager.allowAutoConnect(netId: int, isAllowed: boolean): void` -- Set whther to allow automatic connnect by networkId.
- `ConnectivityKit.wifiManager.connectToCandidateConfig(networkId: int): void` -- Connect to a specified candidate hotspot by networkId, only the configuration which is added by ourself
- `ConnectivityKit.wifiManager.connectToCandidateConfigWithUserAction(networkId: int): Promise<void>` -- Connect to a specified candidate hotspot by networkId, and wait for user respond result.
- `ConnectivityKit.access.convertUuid(uuid: string): string` -- Convert 2-byte and 4-byte UUID strings to the 16-byte UUID string standard used in Bluetooth.
- `ConnectivityKit.wifiManager.deletePersistentGroup(netId: int): void` -- Delete the persistent P2P group with the specified network ID.
- `ConnectivityKit.wifiManager.disableNetwork(netId: int): void` -- Disable the specified DeviceConfig by networkId.
- `ConnectivityKit.wifiManager.disableWifi(): void` -- Disable Wi-Fi.
- `ConnectivityKit.wifiManager.disconnect(): void` -- Disconnect connection between sta and Wi-Fi hotspot.
- `ConnectivityKit.wifiManager.enableSemiWifi(): void` -- Enable semi - Wifi.
- `ConnectivityKit.wifiManager.enableWifi(): void` -- Enable Wi-Fi.
- `ConnectivityKit.wifiManager.factoryReset(): void` -- Reset all saved device configure.
- `ConnectivityKit.connection.getCarKeyDfxData(): string` -- Get the dfx data of car key.
- `ConnectivityKit.wifiManager.getCountryCode(): string` -- Obtain the country code of the device.
- `ConnectivityKit.socket.getDeviceId(clientSocket: int): string` -- Obtain the device id in the client socket.
- `ConnectivityKit.socket.getL2capPsm(serverSocket: int): int` -- Get l2cap socket psm.
- `ConnectivityKit.connection.getLastConnectionTime(deviceId: string): Promise<long>` -- Get latest connection time of device.
- `ConnectivityKit.socket.getMaxReceiveDataSize(clientSocket: int): int` -- Obtain the maximum data size that can be received through this socket channel.
- `ConnectivityKit.socket.getMaxTransmitDataSize(clientSocket: int): int` -- Obtain the maximum data size that can be transmitted through this socket channel.
- `ConnectivityKit.wifiManager.getScanAlwaysAllowed(): boolean` -- Get scan always allowed flag.
- `ConnectivityKit.wifiManager.getSignalLevel(rssi: int, band: int): int` -- Calculate the Wi-Fi signal level based on the Wi-Fi RSSI and frequency band.
- `ConnectivityKit.wifiManager.getSupportedFeatures(): long` -- Obtain the features supported by the device.
- `ConnectivityKit.access.isBluetoothSupported(): boolean` -- Check whether Bluetooth is available.
- `ConnectivityKit.wifiManager.isConnected(): boolean` -- Check whether the Wi-Fi connection has been set up.
- `ConnectivityKit.socket.isConnected(clientSocket: int): boolean` -- Check whether the current socket connection has been established.
- `ConnectivityKit.wifiManager.isFeatureSupported(featureId: long): boolean` -- Check whether the device supports a specified feature.
- `ConnectivityKit.wifiManager.isHotspotActive(): boolean` -- Check whether Wi-Fi hotspot is active on a device.
- `ConnectivityKit.wifiManager.isHotspotDualBandSupported(): boolean` -- Check whether a device serving as a Wi-Fi hotspot supports both the 2.4 GHz and 5 GHz Wi-Fi.
- `ConnectivityKit.wifiManager.isMeteredHotspot(): boolean` -- Whether the hotspot is metered hotspot or not.
- `ConnectivityKit.nfcController.isNfcOpen(): boolean` -- Checks whether NFC is enabled.
- `ConnectivityKit.wifiManager.isOpenSoftApAllowed(): boolean` -- Check whether Wi-Fi hotspot is can be operated under some situation. When the airplane mode is turned on
- `ConnectivityKit.partnerAgent.isPartnerAgentSupported(): boolean` -- Checks whether the current device supports the partner agent feature.
- `ConnectivityKit.wifiManager.isRandomMacDisabled(): boolean` -- is random mac disabled
- `ConnectivityKit.ranging.isRangingSupported(): boolean` -- Checks whether the current device supports the ranging feature.
- `ConnectivityKit.wifiManager.isWifiActive(): boolean` -- Query the Wi-Fi status
- `ConnectivityKit.wifiManager.isWlanSupported(): boolean` -- Query whether Wi-Fi is available
- `ConnectivityKit.wifiManager.p2pCancelConnect(): void` -- Stop an ongoing p2p connection that is being established.
- `ConnectivityKit.wifiManager.reassociate(): void` -- Re-associate to current network.
- `ConnectivityKit.wifiManager.reconnect(): void` -- Re-connect to current network.
- `ConnectivityKit.wifiManager.removeAllNetwork(): void` -- Remove all the saved Wi-Fi configurations.
- `ConnectivityKit.wifiManager.removeCandidateConfig(networkId: int): Promise<void>` -- Remove a specified candidate hotspot configuration, only the configuration which is added by ourself is allowed
- `ConnectivityKit.wifiManager.removeDevice(id: int): void` -- Remove a Wi-Fi DeviceConfig with networkId.
- `ConnectivityKit.wifiManager.removeGroup(): void` -- Remove a P2P group.
- `ConnectivityKit.wifiManager.setDeviceName(devName: string): void` -- Set the name of the Wi-Fi P2P device.
- `ConnectivityKit.wifiManager.setScanAlwaysAllowed(isScanAlwaysAllowed: boolean): void` -- User can trigger scan even Wi-Fi is disabled.
- `ConnectivityKit.socket.sppCloseClientSocket(socket: int): void` -- Disables an spp client socket and releases related resources.
- `ConnectivityKit.socket.sppCloseServerSocket(socket: int): void` -- Disables an spp server socket and releases related resources.
- `ConnectivityKit.wifiManager.startDiscoverDevices(): void` -- Start discover Wi-Fi P2P devices.
- `ConnectivityKit.wifiManager.startPortalCertification(): void` -- Start Portal certification.
- `ConnectivityKit.wifiManager.startScan(): void` -- Scan Wi-Fi hotspot.
- `ConnectivityKit.wifiManager.startWifiDetection(): void` -- Start Wi-Fi network detection
- `ConnectivityKit.wifiManager.stopDiscoverDevices(): void` -- Stop discover Wi-Fi P2P devices.

## BasicServicesKit (49)

- `BasicServicesKit.serial.addPortAuthorization(tokenId: string, deviceId: string): Promise<void>` -- Adds the permission for applications to access the serial port.
- `BasicServicesKit.cacheDownload.cancel(url: string): void` -- Cancels an ongoing download task based on the URL. The saved memory cache and file cache are not affected.
- `BasicServicesKit.serialManager.cancelSerialRight(portId: int): void` -- Cancels the permission to access the serial port device when the application is running. This API is used to close
- `BasicServicesKit.cacheDownload.clearFileCache(): void` -- Clears this file cache.
- `BasicServicesKit.cacheDownload.clearMemoryCache(): void` -- Clears this memory cache.
- `BasicServicesKit.serialManager.close(portId: int): void` -- Closes the serial port device.
- `BasicServicesKit.systemTimer.destroyTimer(timer: long): Promise<void>` -- Destroys a timer. This API uses a promise to return the result.
- `BasicServicesKit.emitter.emit(eventId: string): void` -- Emits the specified event.
- `BasicServicesKit.batteryStats.getAppPowerPercent(uid: int): double` -- Obtains the proportion of the power consumption of an application.
- `BasicServicesKit.batteryStats.getAppPowerValue(uid: int): double` -- Obtains the power consumption of an application, in unit of mAh.
- `BasicServicesKit.systemDateTime.getAutoTimeStatus(): boolean` -- Obtains the switch status of the automatic time setting. This API returns the result synchronously.
- `BasicServicesKit.batteryInfo.getBatteryConfig(sceneName: string): string` -- Obtains the battery configuration based on the specified scenario.
- `BasicServicesKit.customConfig.getChannelId(): string` -- Obtains a pre-installed channel ID of this application.
- `BasicServicesKit.wallpaper.getMinHeightSync(): int` -- Obtains the minimum height of the wallpaper. in pixels. returns 0 if no wallpaper has been set.
- `BasicServicesKit.wallpaper.getMinWidthSync(): int` -- Obtains the minimum width of the wallpaper. in pixels. returns 0 if no wallpaper has been set.
- `BasicServicesKit.systemDateTime.getNtpTime(): long` -- Obtains the actual time calculated based on the last updated NTP time. This API returns the result synchronously.
- `BasicServicesKit.configPolicy.getOneCfgFile(relPath: string): Promise<string>` -- Obtains the path of the configuration file with the highest priority. This API uses a promise to return the result.
- `BasicServicesKit.zlib.getOriginalSize(compressedFile: string): Promise<long>` -- Obtains the original size of a compressed file. This API uses a promise to return the result.
- `BasicServicesKit.selectionManager.getSelectionContent(): Promise<string>` -- Obtains this selected text content. This API uses a promise to return the result.
- `BasicServicesKit.systemParameterEnhance.getSync(key: string, def: string?): string` -- Obtains a value of the specified key. This API uses a promise to return the result.
- `BasicServicesKit.systemDateTime.getTime(isNanoseconds: boolean?): long` -- Obtains the time elapsed since the Unix epoch. This API returns the result synchronously.
- `BasicServicesKit.systemDateTime.getTimezone(): Promise<string>` -- Obtains the system time zone. This API uses a promise to return the result.
- `BasicServicesKit.systemDateTime.getTimezoneSync(): string` -- Obtains the system time zone in synchronous mode.
- `BasicServicesKit.usbManager.hasRight(deviceName: string): boolean` -- Checks whether the application has the permission to access the device.
- `BasicServicesKit.serialManager.hasSerialRight(portId: int): boolean` -- Checks whether the application has the permission to access the serial port device. When an application is
- `BasicServicesKit.power.isActive(): boolean` -- Checks whether the current device is active.
- `BasicServicesKit.batteryInfo.isBatteryConfigSupported(sceneName: string): boolean` -- Checks whether the battery configuration is enabled based on the specified scenario.
- `BasicServicesKit.screenLock.isDeviceLocked(userId: int): boolean` -- Check whether the device is currently locked and the screenlock requires an identity to authenticate and unlock.
- `BasicServicesKit.osAccount.isDomainAccountSupported(): Promise<boolean>` -- Checks whether this domain account is supported. This API uses a promise to return the result.
- `BasicServicesKit.settings.isDoubleClickAppForSelf(): Promise<boolean>` -- 1. Checks whether the application started by double-pressing the Down key is the application itself.
- `BasicServicesKit.screenLock.isLocked(): boolean` -- Checks whether the screen is currently locked.
- `BasicServicesKit.power.isStandby(): boolean` -- Checks whether the device is in standby mode.
- `BasicServicesKit.emitter.off(eventId: long): void` -- Unsubscribes from all events with the specified event ID.
- `BasicServicesKit.serialManager.open(portId: int): void` -- Opens a serial port device.
- `BasicServicesKit.systemCapability.querySystemCapabilities(): Promise<string>` -- Get System Capability.
- `BasicServicesKit.usbManager.removeRight(deviceName: string): boolean` -- Removes the device access permission for the application. System applications are granted the device access
- `BasicServicesKit.usbManager.requestRight(deviceName: string): Promise<boolean>` -- Requests the temporary device access permission for the application. This API uses a promise to return the result.
- `BasicServicesKit.serialManager.requestSerialRight(portId: int): Promise<boolean>` -- Requests the permission for the application to access the serial port device. After the application exits, the
- `BasicServicesKit.batteryInfo.setBatteryConfig(sceneName: string, sceneValue: string): number` -- Sets the battery configuration based on the specified scenario.
- `BasicServicesKit.cacheDownload.setDownloadInfoListSize(size: long): void` -- Sets the size of the download information list.
- `BasicServicesKit.cacheDownload.setFileCacheSize(bytes: long): void` -- Sets the upper limit of the file cache size for the **cacheDownload** component.
- `BasicServicesKit.cacheDownload.setMemoryCacheSize(bytes: long): void` -- Sets the upper limit of the memory cache size for the **cacheDownload** component.
- `BasicServicesKit.commonEventManager.setStaticSubscriberState(enable: boolean): Promise<void>` -- Enables or disables static subscription for an app. This API uses a promise to return the result.
- `BasicServicesKit.systemParameterEnhance.setSync(key: string, value: string): void` -- Sets a value for the specified key. This API uses a promise to return the result.
- `BasicServicesKit.brightness.setValue(value: int): void` -- Sets the screen brightness.
- `BasicServicesKit.systemTimer.startTimer(timer: long, triggerTime: long): Promise<void>` -- Starts a timer. This API uses a promise to return the result.
- `BasicServicesKit.systemTimer.stopTimer(timer: long): Promise<void>` -- Stops a timer. This API uses a promise to return the result.
- `BasicServicesKit.screenLock.unlock(): Promise<boolean>` -- Unlock the screen.
- `BasicServicesKit.systemDateTime.updateNtpTime(): Promise<void>` -- Updates the NTP time from the NTP server This API returns the result asynchronously. In this way, the NTP time is

## AbilityKit (49)

- `AbilityKit.dataUriUtils.attachId(uri: string, id: double): string` -- Attaches an ID to the end of a given URI.
- `AbilityKit.bundleManager.canOpenLink(link: string): boolean` -- Checks whether the target application can be accessed based on the provided link. The scheme specified in the link
- `AbilityKit.bundleManager.cleanBundleCacheFilesForSelf(): Promise<void>` -- Clears the application cache. This API uses a promise to return the result.
- `AbilityKit.dataUriUtils.deleteId(uri: string): string` -- Deletes the ID from the end of a given URI.
- `AbilityKit.application.demoteCurrentFromCandidateMasterProcess(): Promise<void>` -- Removes the current process from the candidate master process list. This API uses a promise to return the result.
- `AbilityKit.application.exitMasterProcessRole(): Promise<void>` -- Relinquishes the [master-process](docroot://application-models/ability-terminology.md#master-process) role from the
- `AbilityKit.bundleManager.getAdditionalInfo(bundleName: string): string` -- Obtains additional information about a bundle in synchronous mode. The return value is the **additionalInfo** field
- `AbilityKit.bundleManager.getAllBundleCacheSize(): Promise<long>` -- Obtains the global cache size. This API uses a promise to return the result.
- `AbilityKit.appManager.getAppMemorySize(): Promise<int>` -- Obtains the maximum memory (RAM allocation) available to the current application. This API uses a promise to return
- `AbilityKit.bundleManager.getApplicationLabel(bundleName: string, appIndex: int): Promise<string>` -- Obtains the name of an application with the specified package name and clone index.
- `AbilityKit.autoStartupManager.getAutoStartupStatusForSelf(): Promise<boolean>` -- Checks whether the current application is enabled for automatic startup at boot time. This API uses a promise to
- `AbilityKit.bundleManager.getBundleNameByUid(uid: int): Promise<string>` -- Obtains the bundle name based on the given UID. This API uses a promise to return the result.
- `AbilityKit.bundleManager.getBundleNameByUidSync(uid: int): string` -- Obtains the bundle name based on the given UID. This API returns the result synchronously.
- `AbilityKit.bundleManager.getDynamicIcon(bundleName: string): Promise<string>` -- Obtains the module name corresponding to the dynamic icon based on the specified bundle name. This API uses a
- `AbilityKit.dataUriUtils.getId(uri: string): double` -- Obtains the ID attached to the end of a given URI.
- `AbilityKit.bundleManager.getPluginBundlePathForSelf(pluginBundleName: string): string` -- Obtains the installation path of a specified plugin in the current
- `AbilityKit.appManager.getProcessMemoryByPid(pid: int): Promise<int>` -- Obtains the memory size of a process. This API uses a promise to return the result.
- `AbilityKit.distributedBundleManager.getRemoteBundleVersionCode(deviceId: string, bundleName: string): Promise<long>` -- Obtains the version information of an app with a specified bundle name on a specified remote device.
- `AbilityKit.bundleManager.getSandboxDataDir(bundleName: string, appIndex: int): string` -- Obtains the sandbox directory of an application based on the given bundle name and clone index.
- `AbilityKit.bundleManager.getSpecifiedDistributionType(bundleName: string): string` -- Obtains the [distribution type](docroot://security/app-provision-structure.md) of a bundle in synchronous mode. The
- `AbilityKit.bundleManager.isApplicationEnabled(bundleName: string): Promise<boolean>` -- Checks whether an application is enabled. This API uses a promise to return the result.
- `AbilityKit.bundleManager.isApplicationEnabledSync(bundleName: string): boolean` -- Checks whether an application is enabled. This API returns the result synchronously.
- `AbilityKit.childProcessManager.isArkChildProcessSupported(): boolean` -- Checks whether the caller is allowed to create ark child processes on this device.
- `AbilityKit.autoStartupManager.isAutoStartupSupported(): boolean` -- Check whether the current device supports auto startup on this device.
- `AbilityKit.defaultAppManager.isDefaultApplication(type: string): Promise<boolean>` -- Checks whether this application is the default application of a system-defined application type or a
- `AbilityKit.defaultAppManager.isDefaultApplicationSync(type: string): boolean` -- Checks whether this application is the default application of a system-defined application type or a
- `AbilityKit.abilityManager.isEmbeddedUIExtensionSupported(): boolean` -- Indicates whether the current device supports EmbeddedUIExtensionAbility.
- `AbilityKit.freeInstall.isHapModuleRemovable(bundleName: string, moduleName: string): Promise<boolean>` -- Checks whether a module can be removed. This API uses a promise to return the result.
- `AbilityKit.childProcessManager.isNativeChildProcessSupported(): boolean` -- Checks whether the caller is allowed to create native child processes on this device.
- `AbilityKit.appManager.isRamConstrainedDevice(): Promise<boolean>` -- Checks whether the current device is a RAM-constrained device (a device with severely limited memory resources).
- `AbilityKit.appManager.isRunningInStabilityTest(): Promise<boolean>` -- Checks whether the system is undergoing a stability test. This API uses a promise to return the result.
- `AbilityKit.shortcutManager.isShortcutSupported(): boolean` -- Checks whether the current device supports shortcuts.
- `AbilityKit.startupManager.isStartupTaskInitialized(startupTask: string): boolean` -- Checks whether a startup task or .so file preloading task is initialized.
- `AbilityKit.application.promoteCurrentToCandidateMasterProcess(insertToHead: boolean): Promise<void>` -- Adds the current process into the
- `AbilityKit.startupManager.removeAllStartupTaskResults(): void` -- Removes all startup task results.
- `AbilityKit.startupManager.removeStartupTaskResult(startupTask: string): void` -- Removes the initialization result of a startup task or .so file preloading task.
- `AbilityKit.hyperSnapManager.requestRebuildHyperSnap(): void` -- Requests the recreation of the Hyper Snap process snapshot for the application.
- `AbilityKit.appRecovery.restartApp(): void` -- Restarts the current process and starts the first ability that is displayed when the application is started. If the
- `AbilityKit.quickFixManager.revokeQuickFix(bundleName: string): Promise<void>` -- Revokes quick fix. This API uses a promise to return the result.
- `AbilityKit.uriPermissionManager.revokeUriPermission(uri: string, targetBundleName: string): Promise<void>` -- Revokes the URI permission from an application. This API uses a promise to return the result.
- `AbilityKit.appRecovery.saveAppState(): boolean` -- Saves the application state. This API can be used together with the APIs of
- `AbilityKit.bundleManager.setAdditionalInfo(bundleName: string, additionalInfo: string): void` -- Sets additional information for an application. This API can be called only by AppGallery.
- `AbilityKit.bundleManager.setAlternateIcon(alternateIconName: string): Promise<void>` -- Sets the alternate icon of the caller based on the given alternate icon name.
- `AbilityKit.hyperSnapManager.setHyperSnapEnabled(enableFlag: boolean): void` -- Enables or disables the Hyper Snap performance optimization for the application.
- `AbilityKit.overlay.setOverlayEnabled(moduleName: string, isEnabled: boolean): Promise<void>` -- Enables or disables a module with the overlay feature in the current application. This API uses a promise to return
- `AbilityKit.abilityManager.setResidentProcessEnabled(bundleName: string, enable: boolean): Promise<void>` -- Enables or disables the resident process of an application.
- `AbilityKit.shortcutManager.setShortcutVisibleForSelf(id: string, visible: boolean): Promise<void>` -- Sets whether to display the specified shortcut for the current application. This API uses a promise to return the
- `AbilityKit.wantAgent.setWantAgentMultithreading(isMultithreadingSupported: boolean): void` -- Enables or disables the WantAgent multithreading feature.
- `AbilityKit.dataUriUtils.updateId(uri: string, id: double): string` -- Updates the ID in a given URI.

## PerformanceAnalysisKit (48)

- `PerformanceAnalysisKit.hichecker.addCheckRule(rule: bigint): void` -- Adds one or more check rules. HiChecker detects unexpected operations or gives feedback based on the added rules.
- `PerformanceAnalysisKit.hiAppEvent.addProcessorFromConfig(processorName: string, configName: string?): Promise<long>` -- Adds the configuration information of the data processor. The configuration file contains information such as the
- `PerformanceAnalysisKit.jsLeakWatcher.check(): string` -- Obtains the list of objects that are leaked and registered using **jsLeakWatcher.watch()**. Objects that are not
- `PerformanceAnalysisKit.hilog.clean(): void` -- Delete all hilog logs in the sandbox.
- `PerformanceAnalysisKit.hiAppEvent.clearData(): void` -- Clears local logging data of the application.
- `PerformanceAnalysisKit.hiTraceChain.clearId(): void` -- Clears the trace ID. This API returns the result synchronously.
- `PerformanceAnalysisKit.hichecker.containsCheckRule(rule: bigint): boolean` -- Checks whether the specified rule exists in the collection of added rules. If the rule is of the thread level, this
- `PerformanceAnalysisKit.hidebug.disableGwpAsanGrayscale(): void` -- Disables GWP-ASan. This API is used to cancel the custom configuration and restore the default parameter
- `PerformanceAnalysisKit.hidebug.dumpJsRawHeapData(needGC: boolean?): Promise<string>` -- Dumps the original heap snapshot of the VM for the current thread and generates a .rawheap file. This API uses a
- `PerformanceAnalysisKit.jsLeakWatcher.enable(isEnable: boolean): void` -- Enables the detection for JS object leaks. This function is disabled by default.
- `PerformanceAnalysisKit.hiTraceMeter.finishTrace(name: string, taskId: int): void` -- Stops an asynchronous trace.
- `PerformanceAnalysisKit.hilog.flush(): void` -- Flush hilog logs in the sandbox.
- `PerformanceAnalysisKit.hidebug.getAppVMObjectUsedSize(): bigint` -- Obtains the VM memory size occupied by ArkTS objects.
- `PerformanceAnalysisKit.hidebug.getCpuUsage(): double` -- Obtains the CPU usage of a process.
- `PerformanceAnalysisKit.hidebug.getGraphicsMemory(): Promise<int>` -- Obtains the total GPU memory size (**gl** + **graph**) of the application. This API uses a promise to return the
- `PerformanceAnalysisKit.hidebug.getGraphicsMemorySync(): int` -- Obtains the total GPU memory size (GL + graph) of an application in synchronous mode.
- `PerformanceAnalysisKit.hidebug.getGwpAsanGrayscaleState(): int` -- Obtain the remaining days of GWP-ASan grayscale for your application.
- `PerformanceAnalysisKit.hiRetrieval.getLastParticipationTimestamp(): long` -- Query the UNIX timestamp of the last participating time.
- `PerformanceAnalysisKit.hidebug.getNativeHeapAllocatedSize(): bigint` -- Obtains the total number of bytes occupied by the total allocated space (**uordblks**, which is obtained from
- `PerformanceAnalysisKit.hidebug.getNativeHeapFreeSize(): bigint` -- Obtains the total number of bytes occupied by the total free space (**fordblks**, which is obtained from
- `PerformanceAnalysisKit.hidebug.getNativeHeapSize(): bigint` -- Obtains the total number of bytes occupied by the total space (**uordblks** + **fordblks**, which are obtained from
- `PerformanceAnalysisKit.hilog.getOutputDir(): string` -- Returns the directory path of hilog logs in the sandbox.
- `PerformanceAnalysisKit.hidebug.getPrivateDirty(): bigint` -- Obtains the size of the private dirty memory of a process. This API is implemented by reading the value of
- `PerformanceAnalysisKit.hidebug.getPss(): bigint` -- Obtains the size of the physical memory actually used by the application process. This API is implemented by
- `PerformanceAnalysisKit.hichecker.getRule(): bigint` -- Obtains a collection of thread, process, and alarm rules that have been added.
- `PerformanceAnalysisKit.hidebug.getSharedDirty(): bigint` -- Obtains the size of the shared dirty memory of a process. This API is implemented by reading the value of
- `PerformanceAnalysisKit.hidebug.getSystemCpuUsage(): double` -- Obtains the CPU usage of the system.
- `PerformanceAnalysisKit.hiAppEvent.getUserId(name: string): string` -- Obtains the value set through **setUserId**.
- `PerformanceAnalysisKit.hiAppEvent.getUserProperty(name: string): string` -- Obtains the value set through **setUserProperty**.
- `PerformanceAnalysisKit.hidebug.getVMRuntimeStat(item: string): long` -- Obtains the specified system GC statistics based on parameters.
- `PerformanceAnalysisKit.hidebug.getVss(): bigint` -- Obtains the virtual set size used by the application process. This API is implemented by multiplying the value of
- `PerformanceAnalysisKit.hiRetrieval.init(): void` -- Init the HiRetrieval functionality.
- `PerformanceAnalysisKit.hidebug.isDebugState(): boolean` -- Obtains the debugging state of an application process.
- `PerformanceAnalysisKit.hiRetrieval.isParticipant(): boolean` -- Query if the app is participating the HiRetrieval project.
- `PerformanceAnalysisKit.hiTraceMeter.isTraceEnabled(): boolean` -- Checks whether application trace capture is enabled.
- `PerformanceAnalysisKit.hiRetrieval.quit(): void` -- Quit the HiRetrieval project. This operation clears the current HiRetrieval config.
- `PerformanceAnalysisKit.hichecker.removeCheckRule(rule: bigint): void` -- Removes one or more rules. The removed rules will become ineffective.
- `PerformanceAnalysisKit.hiAppEvent.removeProcessor(id: long): void` -- Removes the data processor of a reported event.
- `PerformanceAnalysisKit.hiRetrieval.run(): void` -- Trigger the HiRetrieval functionality, make it start working.
- `PerformanceAnalysisKit.hidebug.setProcDumpInSharedOOM(enable: boolean): void` -- Changes the dump heap snapshot from the thread-level to the process-level.
- `PerformanceAnalysisKit.hiAppEvent.setUserId(name: string, value: string): void` -- Sets a user ID, which is used for association when a [Processor]{@link hiAppEvent.Processor} is configured.
- `PerformanceAnalysisKit.hiAppEvent.setUserProperty(name: string, value: string): void` -- Sets a user property, which is used for association when a [Processor]{@link hiAppEvent.Processor} is configured.
- `PerformanceAnalysisKit.hidebug.startJsCpuProfiling(filename: string): void` -- Starts the VM profiling method. **startJsCpuProfiling(filename: string)** and **stopJsCpuProfiling()** are called
- `PerformanceAnalysisKit.hiTraceMeter.startTrace(name: string, taskId: int): void` -- Starts an asynchronous trace.
- `PerformanceAnalysisKit.hidebug.stopAppTraceCapture(): void` -- Stops application trace collection. Use [startAppTraceCapture()]{@link hidebug.startAppTraceCapture} to start
- `PerformanceAnalysisKit.hidebug.stopJsCpuProfiling(): void` -- Stops the VM profiling method. **stopJsCpuProfiling()** and **startJsCpuProfiling(filename: string)** are called in
- `PerformanceAnalysisKit.hiTraceMeter.traceByValue(name: string, count: long): void` -- Traces the value changes of an integer variable.
- `PerformanceAnalysisKit.hiTraceMeter.unregisterTraceListener(index: int): int` -- Unregisters the callback function used to notify whether the trace capture is enabled, which is registered using

## InputKit (40)

- `InputKit.pointer.getHoverScrollState(): Promise<boolean>` -- Obtains the status of the mouse hover scroll switch. This API uses a promise to return the result.
- `InputKit.inputDevice.getIntervalSinceLastInput(): Promise<long>` -- Obtains the interval (including the device sleep time) elapsed since the last system input event. This API uses a
- `InputKit.inputDevice.getKeyboardRepeatDelay(): Promise<int>` -- Obtains the keyboard repeat delay. This API uses a promise to return the result.
- `InputKit.inputDevice.getKeyboardRepeatRate(): Promise<int>` -- Obtains the keyboard repeat rate. This API uses a promise to return the result.
- `InputKit.pointer.getMouseScrollRows(): Promise<int>` -- Obtains the number of mouse scroll lines. This API uses a promise to return the result.
- `InputKit.pointer.getPointerColor(): Promise<int>` -- Obtains the current mouse pointer color. This API uses a promise to return the result.
- `InputKit.pointer.getPointerColorSync(): int` -- Obtains the pointer color. This API returns the result synchronously.
- `InputKit.pointer.getPointerSize(): Promise<int>` -- Obtains the current mouse pointer size. This API uses a promise to return the result.
- `InputKit.pointer.getPointerSizeSync(): int` -- Obtains the pointer size. This API returns the result synchronously.
- `InputKit.pointer.getPointerSpeed(): Promise<int>` -- Obtains the mouse pointer speed. This API uses a promise to return the result.
- `InputKit.pointer.getPointerSpeedSync(): int` -- Obtains the mouse pointer speed. This API returns the result synchronously.
- `InputKit.pointer.getTouchpadDoubleTapAndDragState(): Promise<boolean>` -- Obtains the touchpad double-tap and drag switch state. This API uses a promise to return the result.
- `InputKit.pointer.getTouchpadPinchSwitch(): Promise<boolean>` -- Obtains the touchpad pinch switch state. This API uses a promise to return the result.
- `InputKit.pointer.getTouchpadPointerSpeed(): Promise<int>` -- Obtains the touchpad pointer speed. This API uses a promise to return the result.
- `InputKit.pointer.getTouchpadScrollDirection(): Promise<boolean>` -- Obtains the scroll direction of the touchpad. This API uses a promise to return the result.
- `InputKit.pointer.getTouchpadScrollSwitch(): Promise<boolean>` -- Obtains the touchpad scroll switch state. This API uses a promise to return the result.
- `InputKit.pointer.getTouchpadSwipeSwitch(): Promise<boolean>` -- Obtains the touchpad multi-finger swipe switch state. This API uses a promise to return the result.
- `InputKit.pointer.getTouchpadTapSwitch(): Promise<boolean>` -- Obtains the touchpad tap switch state. This API uses a promise to return the result.
- `InputKit.pointer.isPointerVisible(): Promise<boolean>` -- Obtains the visible status of the mouse pointer. This API uses a promise to return the result.
- `InputKit.pointer.isPointerVisibleSync(): boolean` -- Checks whether the mouse pointer is visible in the current window. This API returns the result synchronously.
- `InputKit.pointer.setHoverScrollState(state: boolean): Promise<void>` -- Sets the status of the mouse hover scroll switch. This API uses a promise to return the result.
- `InputKit.shortKey.setKeyDownDuration(businessKey: string, delay: int): Promise<void>` -- Sets the delay for starting an ability using shortcut keys. This API uses a promise to return the result.
- `InputKit.inputDevice.setKeyboardRepeatDelay(delay: int): Promise<void>` -- Sets the keyboard repeat delay. This API uses a promise to return the result.
- `InputKit.inputDevice.setKeyboardRepeatRate(rate: int): Promise<void>` -- Sets the keyboard repeat rate. This API uses a promise to return the result.
- `InputKit.pointer.setMouseScrollRows(rows: int): Promise<void>` -- Sets the number of mouse scroll lines. This API uses a promise to return the result.
- `InputKit.pointer.setPointerColor(color: int): Promise<void>` -- Sets the mouse pointer color. This API uses a promise to return the result.
- `InputKit.pointer.setPointerColorSync(color: int): void` -- Sets the pointer color. This API returns the result synchronously.
- `InputKit.pointer.setPointerSize(size: int): Promise<void>` -- Sets the mouse pointer size. This API uses a promise to return the result.
- `InputKit.pointer.setPointerSizeSync(size: int): void` -- Sets the pointer size. This API returns the result synchronously.
- `InputKit.pointer.setPointerSpeed(speed: int): Promise<void>` -- Sets the mouse pointer speed. This API uses a promise to return the result.
- `InputKit.pointer.setPointerSpeedSync(speed: int): void` -- Sets the mouse pointer speed. This API returns the result synchronously.
- `InputKit.pointer.setPointerVisible(visible: boolean): Promise<void>` -- Sets whether the mouse pointer is visible in the current window. This API uses a promise to return the result.
- `InputKit.pointer.setPointerVisibleSync(visible: boolean): void` -- Sets whether the mouse pointer is visible in the current window. This API returns the result synchronously.
- `InputKit.pointer.setTouchpadDoubleTapAndDragState(isOpen: boolean): Promise<void>` -- Sets the touchpad double-tap and drag switch state. This API uses a promise to return the result.
- `InputKit.pointer.setTouchpadPinchSwitch(state: boolean): Promise<void>` -- Sets the touchpad pinch switch. This API uses a promise to return the result.
- `InputKit.pointer.setTouchpadPointerSpeed(speed: int): Promise<void>` -- Sets the touchpad pointer speed. This API uses a promise to return the result.
- `InputKit.pointer.setTouchpadScrollDirection(state: boolean): Promise<void>` -- Sets the touchpad scroll direction. This API uses a promise to return the result.
- `InputKit.pointer.setTouchpadScrollSwitch(state: boolean): Promise<void>` -- Sets the touchpad scroll switch. This API uses a promise to return the result.
- `InputKit.pointer.setTouchpadSwipeSwitch(state: boolean): Promise<void>` -- Sets the touchpad multi-finger swipe switch. This API uses a promise to return the result.
- `InputKit.pointer.setTouchpadTapSwitch(state: boolean): Promise<void>` -- Sets the touchpad tap switch. This API uses a promise to return the result.

## NotificationKit (25)

- `NotificationKit.notificationManager.cancel(id: int, label: string?): Promise<void>` -- Cancels a published notification based on the notification ID and label. This API uses a promise to
- `NotificationKit.notificationManager.cancelAll(): Promise<void>` -- Cancels all notifications of this application. This API uses a promise to return the result.
- `NotificationKit.notificationManager.cancelGroup(groupName: string): Promise<void>` -- Cancels notifications under a notification group of this application. This API uses a promise to return the result.
- `NotificationKit.notificationManager.getActiveNotificationCount(): Promise<long>` -- Obtains the number of active notifications of this application. This API uses a promise to return the result.
- `NotificationKit.notificationManager.getBadgeNumber(): Promise<long>` -- Obtains the badge number of this application. This API uses a promise to return the result.
- `NotificationKit.notificationManager.isDistributedEnabled(deviceType: string): Promise<boolean>` -- Checks whether a device enables cross-device notification. This API uses a promise to return the result.
- `NotificationKit.notificationManager.isGeofenceEnabled(): Promise<boolean>` -- Checks whether geofencing is enabled. This API uses a promise to return the result.
- `NotificationKit.notificationManager.isNotificationEnabled(): Promise<boolean>` -- Queries the notification authorization status of the current application. This API uses a promise to
- `NotificationKit.notificationManager.isNotificationEnabledSync(): boolean` -- Synchronously queries the notification authorization status of the current application.
- `NotificationKit.notificationManager.isPriorityEnabled(): Promise<boolean>` -- Checks whether the priority notification is enabled.
- `NotificationKit.notificationManager.isPriorityIntelligentEnabled(): Promise<boolean>` -- Obtains whether the intelligent priority notification service is enabled. This API uses a promise to return the
- `NotificationKit.notificationManager.isSmartReminderEnabled(deviceType: string): Promise<boolean>` -- Obtains a smart reminder for cross-device collaboration. This API uses a promise to return the result.
- `NotificationKit.notificationManager.isSupportDoNotDisturbMode(): Promise<boolean>` -- Checks whether DND mode is supported. This API uses a promise to return the result.
- `NotificationKit.notificationManager.isSupportTemplate(templateName: string): Promise<boolean>` -- Checks whether a specified template is supported before using
- `NotificationKit.notificationManager.offBadgeNumberQuery(): void` -- Unregisters the callback for querying the number of application badges.
- `NotificationKit.notificationSubscribe.removeAll(userId: int): Promise<void>` -- Removes all notifications for a specified user. This API uses a promise to return the result.
- `NotificationKit.notificationManager.removeAllSlots(): Promise<void>` -- Removes all notification slots for this application. This API uses a promise to return the result.
- `NotificationKit.notificationManager.setBadgeNumber(badgeNumber: int): Promise<void>` -- Sets the notification badge number. This API uses a promise to return the result.
- `NotificationKit.notificationManager.setDistributedEnabled(enable: boolean, deviceType: string): Promise<void>` -- Sets whether the device of a specified type enables cross-device notification. This API uses a promise to return
- `NotificationKit.notificationManager.setGeofenceEnabled(enabled: boolean): Promise<void>` -- Sets the enabling state of geofencing. This API uses a promise to return the result.
- `NotificationKit.notificationManager.setPriorityEnabled(enable: boolean): Promise<void>` -- Sets the enabling status of the priority notification.
- `NotificationKit.notificationManager.setPriorityIntelligentEnabled(enable: boolean): Promise<void>` -- Sets the enabling status of the intelligent priority notification service. This API uses a promise to return the
- `NotificationKit.notificationManager.setSmartReminderEnabled(deviceType: string, enable: boolean): Promise<void>` -- Sets a smart reminder for cross-device collaboration. This API uses a promise to return the result.
- `NotificationKit.notificationManager.setTargetDeviceStatus(deviceType: string, status: long): Promise<void>` -- Sets the status of a device after it is successfully connected. Device status determines the notification mode of
- `NotificationKit.notificationManager.snoozeNotification(hashCode: string, delayTime: long): Promise<void>` -- Snoozes a notification. The notification will be reminded again after the specified time. Each

## CoreFileKit (24)

- `CoreFileKit.keyManager.deactivateUserKey(userId: long): void` -- When the screen is locked, the specified user key is uninstalled synchronously.
- `CoreFileKit.storageStatistics.getCurrentBundleInodes(): Promise<long>` -- Get the current bundle inodes.
- `CoreFileKit.storageStatistics.getFreeInodes(): Promise<long>` -- Get the free inodes.
- `CoreFileKit.statfs.getFreeSize(path: string): Promise<long>` -- Obtains the free size of the specified file system, in bytes. This API uses a promise to return the result.
- `CoreFileKit.storageStatistics.getFreeSize(): Promise<long>` -- Get the free size.
- `CoreFileKit.storageStatistics.getFreeSizeOfVolume(volumeUuid: string): Promise<long>` -- Get the free size of volume.
- `CoreFileKit.storageStatistics.getFreeSizeSync(): long` -- Obtains the available space of the built-in storage, in bytes. This API returns the result synchronously.
- `CoreFileKit.statfs.getFreeSizeSync(path: string): long` -- Obtains the free size of the specified file system, in bytes. This API returns the result synchronously.
- `CoreFileKit.securityLabel.getSecurityLabel(path: string): Promise<string>` -- Obtains the data security level of a file or directory. If no data security level has been set, **s3** is returned
- `CoreFileKit.securityLabel.getSecurityLabelSync(path: string): string` -- Obtains the data security level of a file or directory in synchronous mode. If no data security level has been set,
- `CoreFileKit.Environment.getStorageDataDir(): Promise<string>` -- Obtains the root directory of the memory. This API uses a promise to return the result.
- `CoreFileKit.storageStatistics.getSystemDataSize(): Promise<long>` -- Get the system data size.
- `CoreFileKit.storageStatistics.getSystemSize(): Promise<long>` -- Get the system size.
- `CoreFileKit.storageStatistics.getTotalInodes(): Promise<long>` -- Get the total inodes.
- `CoreFileKit.statfs.getTotalSize(path: string): Promise<long>` -- Obtains the total size of the specified file system, in bytes. This API uses a promise to return the result.
- `CoreFileKit.storageStatistics.getTotalSize(): Promise<long>` -- Get the total size.
- `CoreFileKit.storageStatistics.getTotalSizeOfVolume(volumeUuid: string): Promise<long>` -- Get the total size of volume.
- `CoreFileKit.storageStatistics.getTotalSizeSync(): long` -- Obtains the total space of the built-in storage, in bytes. This API returns the result synchronously.
- `CoreFileKit.statfs.getTotalSizeSync(path: string): long` -- Obtains the total size of the specified file system, in bytes. This API returns the result synchronously.
- `CoreFileKit.fileUri.getUriFromPath(path: string): string` -- Get the uri from the path of file in app sandbox
- `CoreFileKit.Environment.getUserDataDir(): Promise<string>` -- Obtains the root directory of user files. This API uses a promise to return the result.
- `CoreFileKit.hash.hash(path: string, algorithm: string): Promise<string>` -- Calculates a hash value for a file. This API uses a promise to return the result.
- `CoreFileKit.cloudSyncManager.notifyDataChange(accountId: string, bundleName: string): Promise<void>` -- Notifies the device-cloud service that the cloud data of a specific application under a specified account has been
- `CoreFileKit.cloudSync.unregisterChange(uri: string): void` -- Unsubscribes from the change of a file.

## ArkUI (21)

- `ArkUI.promptAction.closeToast(toastId: number): void` -- Closes the specified toast.
- `ArkUI.screen.destroyVirtualScreen(screenId: long): Promise<void>` -- Destroys a virtual screen. This API uses a promise to return the result.
- `ArkUI.performanceMonitor.end(scene: string): void` -- Marks the end of a user scene. Call this API when the scene ends.
- `ArkUI.window.getGlobalWindowMode(displayId: long?): Promise<int>` -- Obtains the window mode of the window that is in the foreground lifecycle on the specified screen. This API uses a
- `ArkUI.window.getTopNavDestinationName(windowId: int): Promise<string>` -- Obtains the name of [NavDestination]{@link NavDestination} in the current top-level
- `ArkUI.display.hasPrivateWindow(displayId: long): boolean` -- Checks whether there is a visible privacy window on a display. The privacy window can be set by calling
- `ArkUI.display.isCaptured(): boolean` -- Checks whether the device's screen content is being captured.
- `ArkUI.floatView.isFloatViewEnabled(): boolean` -- Checks whether the device supports the float view.
- `ArkUI.floatingBall.isFloatingBallEnabled(): boolean` -- Checks whether the device supports floating balls.
- `ArkUI.display.isFoldable(): boolean` -- Checks whether this device is foldable.
- `ArkUI.PiPWindow.isPiPEnabled(): boolean` -- Checks whether the current device supports the PiP feature.
- `ArkUI.screen.isScreenRotationLocked(): Promise<boolean>` -- Checks whether auto rotate is locked. This API uses a promise to return the result.
- `ArkUI.window.minimizeAll(id: long): Promise<void>` -- Minimizes all main windows on a display. This API uses a promise to return the result.
- `ArkUI.window.minimizeAllWithExclusion(displayId: long, excludeWindowId: int): Promise<void>` -- Minimizes all main windows on a display while keeping one window open. This API uses a promise to return the
- `ArkUI.display.removeVirtualScreenSurface(screenId: long, surfaceId: string): Promise<void>` -- Remove surface for the virtual screen.
- `ArkUI.display.setFoldStatusLocked(locked: boolean): void` -- Sets whether to lock the current fold status of the foldable device.
- `ArkUI.window.setGestureNavigationEnabled(enable: boolean): Promise<void>` -- Enables or disables gesture navigation. This API uses a promise to return the result. For security purposes, the
- `ArkUI.screen.setScreenRotationLocked(isLocked: boolean): Promise<void>` -- Sets whether to lock auto rotate. This API uses a promise to return the result.
- `ArkUI.window.shiftAppWindowFocus(sourceWindowId: int, targetWindowId: int): Promise<void>` -- Shifts the window focus from the source window to the target window in the same application. The window focus can
- `ArkUI.window.shiftAppWindowPointerEvent(sourceWindowId: int, targetWindowId: int): Promise<void>` -- Transfers a mouse input event from one window to another within the same application. This API takes effect only
- `ArkUI.window.toggleShownStateForAllAppWindows(): Promise<void>` -- Hides or restores the application's windows during quick multi-window switching. This API uses a promise to return

## NetworkKit (20)

- `NetworkKit.connection.clearCustomDnsRules(): Promise<void>` -- Clear all custom DNS rules for current application.
- `NetworkKit.connection.findProxyForUrl(url: string): string` -- Find pac proxy info for the url.
- `NetworkKit.statistics.getAllRxBytes(): Promise<long>` -- Queries the data traffic (including all TCP and UDP data packets) received through all NICs.
- `NetworkKit.statistics.getAllTxBytes(): Promise<long>` -- Queries the data traffic (including all TCP and UDP data packets) sent through all NICs.
- `NetworkKit.statistics.getCellularRxBytes(): Promise<long>` -- Queries the data traffic (including all TCP and UDP data packets) received through the cellular network.
- `NetworkKit.statistics.getCellularTxBytes(): Promise<long>` -- Queries the data traffic (including all TCP and UDP data packets) sent through the cellular network.
- `NetworkKit.statistics.getIfaceRxBytes(nic: string): Promise<long>` -- Queries the data traffic (including all TCP and UDP data packets) received through a specified NIC.
- `NetworkKit.statistics.getIfaceTxBytes(nic: string): Promise<long>` -- Queries the data traffic (including all TCP and UDP data packets) sent through a specified NIC.
- `NetworkKit.connection.getPacFileUrl(): string` -- Obtain the URL {@link pacFileUrl} of the current PAC script.
- `NetworkKit.connection.getPacUrl(): string` -- Obtain the URL {@link pacUrl} of the current PAC script.
- `NetworkKit.statistics.getSockfdRxBytes(sockfd: int): Promise<long>` -- Queries the data traffic (including all TCP and UDP data packets) received through a specified sockfd.
- `NetworkKit.statistics.getSockfdTxBytes(sockfd: int): Promise<long>` -- Queries the data traffic (including all TCP and UDP data packets) sent through a specified sockfd.
- `NetworkKit.connection.hasDefaultNet(): Promise<boolean>` -- Checks whether the default data network is activated.
- `NetworkKit.connection.hasDefaultNetSync(): boolean` -- Checks whether the default data network is activated.
- `NetworkKit.networkSecurity.isCleartextPermitted(): boolean` -- Checks whether the Cleartext traffic is permitted.
- `NetworkKit.networkSecurity.isCleartextPermittedByHostName(hostName: string): boolean` -- Checks whether the Cleartext traffic for a specified hostname is permitted.
- `NetworkKit.connection.isDefaultNetMetered(): Promise<boolean>` -- Checks whether data traffic usage on the current network is metered.
- `NetworkKit.connection.isDefaultNetMeteredSync(): boolean` -- Checks whether data traffic usage on the current network is metered.
- `NetworkKit.ethernet.isIfaceActive(iface: string): Promise<number>` -- Check whether the specified network is active.
- `NetworkKit.connection.removeCustomDnsRule(host: string): Promise<void>` -- Remove the custom DNS rule of the {@link host} for current application.

## ArkTS (15)

- `ArkTS.process.abort(): void` -- Aborts a process and generates a core file. This method will cause a process to exit immediately. Exercise
- `ArkTS.taskpool.cancel(taskId: number): void` -- Cancels a task in the task pool by task ID. If the task is in the internal queue of the task pool, the task will
- `ArkTS.process.chdir(dir: string): void` -- Change current directory
- `ArkTS.process.cwd(): string` -- Return the current work directory;
- `ArkTS.util.errnoToString(errno: number): string` -- Obtains detailed information about a system error code.
- `ArkTS.util.generateRandomUUID(entropyCache: boolean?): string` -- Uses a secure random number generator to generate a random universally unique identifier (UUID) of the string type
- `ArkTS.util.getMainThreadStackTrace(): string` -- Obtains the stack trace information of the main thread. A maximum of 64 call frames can be returned.
- `ArkTS.process.getPastCpuTime(): number` -- Obtains the CPU time (in milliseconds) from the time the process starts to the current time.
- `ArkTS.process.getStartRealtime(): number` -- Obtains the duration (excluding the system sleep time), in milliseconds, from the time the system starts to the
- `ArkTS.process.is64Bit(): boolean` -- Checks whether this process is running in a 64-bit environment.
- `ArkTS.buffer.isEncoding(encoding: string): boolean` -- Checks whether the encoding format is supported.
- `ArkTS.fastbuffer.isEncoding(encoding: string): boolean` -- Returns true if encoding is the name of a supported character encoding, or false otherwise.
- `ArkTS.process.isIsolatedProcess(): boolean` -- Checks whether this process is isolated.
- `ArkTS.process.off(type: string): boolean` -- Remove registered event
- `ArkTS.process.uptime(): number` -- Obtains the running time of the current system, in seconds.

## AccessibilityKit (13)

- `AccessibilityKit.accessibility.getSeniorModeStateForSelf(): Promise<boolean>` -- Check if this application's senior mode is enabled.
- `AccessibilityKit.accessibility.getTouchModeSync(): string` -- Queries single- or double-touch mode.
- `AccessibilityKit.accessibility.isAnimationReduceEnabled(): Promise<boolean>` -- Checks whether animation reduction mode is enabled. This API uses a promise to return the result.
- `AccessibilityKit.accessibility.isAnimationReduceEnabledSync(): boolean` -- Checks whether animation reduction mode is enabled with a synchronous method.
- `AccessibilityKit.accessibility.isAudioMonoEnabled(): Promise<boolean>` -- Checks whether mono audio mode is enabled. This API uses a promise to return the result.
- `AccessibilityKit.accessibility.isAudioMonoEnabledSync(): boolean` -- Checks whether mono audio mode is enabled with a synchronous mode.
- `AccessibilityKit.accessibility.isFlashReminderEnabled(): Promise<boolean>` -- Checks whether flash alerts mode is enabled. This API uses a promise to return the result.
- `AccessibilityKit.accessibility.isFlashReminderEnabledSync(): boolean` -- Checks whether flash alerts mode is enabled with a synchronous method.
- `AccessibilityKit.accessibility.isOpenAccessibilitySync(): boolean` -- Checks whether any accessibility application has been enabled in the system. To obtain information about
- `AccessibilityKit.accessibility.isOpenTouchGuideSync(): boolean` -- Checks whether touch guide mode is enabled.
- `AccessibilityKit.accessibility.isScreenReaderOpenSync(): boolean` -- Checks whether screen reader mode is enabled.
- `AccessibilityKit.accessibility.isSeniorModeEnabled(): Promise<boolean>` -- Checks whether the senior mode is enabled. This API uses a promise to return the result.
- `AccessibilityKit.accessibility.setSeniorModeStateForSelf(state: boolean): Promise<void>` -- Set this application's senior mode.

## BackgroundTasksKit (10)

- `BackgroundTasksKit.reminderAgentManager.cancelAllReminders(): Promise<void>` -- Cancels all reminders set by the current application. This API uses a promise to return the result.
- `BackgroundTasksKit.reminderAgentManager.cancelReminder(reminderId: int): Promise<void>` -- Cancels a reminder published. This API uses a promise to return the result.
- `BackgroundTasksKit.reminderAgentManager.cancelReminderOnDisplay(reminderId: int): Promise<void>` -- Cancels the notification card displayed in the notification center with the agent reminder data retained. For
- `BackgroundTasksKit.backgroundTaskManager.cancelSuspendDelay(requestId: int): void` -- Cancels a transient task.
- `BackgroundTasksKit.reminderAgentManager.deleteExcludeDates(reminderId: int): Promise<void>` -- Deletes all non-reminder dates for a recurring calendar reminder with a specific ID. This API uses a promise to
- `BackgroundTasksKit.backgroundTaskManager.getRemainingDelayTime(requestId: int): Promise<int>` -- Obtains the remaining time of a transient task. This API uses a promise to return the result.
- `BackgroundTasksKit.workScheduler.isLastWorkTimeOut(workId: int): Promise<boolean>` -- Checks whether the last execution of a task timed out. This API uses a promise to return the result.
- `BackgroundTasksKit.backgroundTaskManager.resetAllEfficiencyResources(): void` -- Releases all efficiency resources.
- `BackgroundTasksKit.backgroundProcessManager.resetProcessPriority(pid: int): Promise<void>` -- Unsuppresses the child process. In this case, the child process follows the scheduling policy of the main
- `BackgroundTasksKit.workScheduler.stopAndClearWorks(): void` -- Stops and clears all the deferred tasks.

## LocationKit (8)

- `LocationKit.geoLocationManager.isBeaconFenceSupported(): boolean` -- Check whether the BeaconFence service is supported.
- `LocationKit.geoLocationManager.isCachedGnssServiceSupported(): boolean` -- Check whether the cached GNSS service is supported.
- `LocationKit.geoLocationManager.isGeocoderAvailable(): boolean` -- Obtain geocoding service status.
- `LocationKit.geoLocationManager.isGnssFenceServiceSupported(): boolean` -- Check whether the GNSS fence service is supported.
- `LocationKit.geoLocationManager.isGnssServiceSupported(): boolean` -- Check whether the GNSS service is supported.
- `LocationKit.geoLocationManager.isLocationEnabled(): boolean` -- Obtain current location switch status.
- `LocationKit.geoLocationManager.isLocationEnabledByUserId(userId: int): boolean` -- Obtaining the location switch status of a specified user.
- `LocationKit.geoLocationManager.isPoiServiceSupported(): boolean` -- Check whether the POI service is supported.

## DataProtectionKit (8)

- `DataProtectionKit.dlpPermission.cleanSandboxAppConfig(): Promise<void>` -- Clears the sandbox application configuration. After the API is successfully called, the sandbox application
- `DataProtectionKit.dlpPermission.getDLPSuffix(): string` -- Obtains the DLP file name extension. After the API is called successfully, the DLP file name extension (for
- `DataProtectionKit.dlpPermission.getOriginalFileName(fileName: string): string` -- Obtains the original name of a DLP file. This API returns the result synchronously.
- `DataProtectionKit.dlpPermission.getSandboxAppConfig(): Promise<string>` -- Obtains sandbox application configuration. This API uses a promise to return the result.
- `DataProtectionKit.dlpPermission.isDLPFeatureProvided(): Promise<boolean>` -- Checks whether the current system provides the encryption protection feature. This API is available only for
- `DataProtectionKit.dlpPermission.isDLPFile(fd: number): Promise<boolean>` -- Checks whether a file is a DLP file based on the FD. This API uses a promise to return the result.
- `DataProtectionKit.dlpPermission.isInSandbox(): Promise<boolean>` -- Checks whether this application is running in a DLP sandbox environment. This API uses a promise to return the
- `DataProtectionKit.dlpPermission.setSandboxAppConfig(configInfo: string): Promise<void>` -- Sets the configuration information of the sandbox application. The configuration information is in JSON string

## DistributedServiceKit (8)

- `DistributedServiceKit.abilityConnectionManager.acceptConnect(sessionId: int, token: string): Promise<void>` -- Accepts the UIAbility connection after a collaboration session is set up and the session ID is obtained.
- `DistributedServiceKit.abilityConnectionManager.destroyAbilityConnectionSession(sessionId: int): void` -- Destroys a collaboration session between applications.
- `DistributedServiceKit.abilityConnectionManager.destroyStream(streamId: int): void` -- Destroy the Stream.
- `DistributedServiceKit.abilityConnectionManager.disconnect(sessionId: int): void` -- Disconnects the UIAbility connection to end the collaboration session.
- `DistributedServiceKit.abilityConnectionManager.reject(token: string, reason: string): void` -- Rejects a connection request in a cross-device collaboration session. After a connection request sent from the peer
- `DistributedServiceKit.abilityConnectionManager.sendMessage(sessionId: int, msg: string): Promise<void>` -- Sends text messages after a collaboration session is set up.
- `DistributedServiceKit.abilityConnectionManager.startStream(streamId: int): void` -- Start Streaming
- `DistributedServiceKit.abilityConnectionManager.stopStream(streamId: int): void` -- Stop Streaming

## FormKit (7)

- `FormKit.formProvider.activateSceneAnimation(formId: string): Promise<void>` -- Requests to activate a widget. This API takes effect only for
- `FormKit.formProvider.cancelOverflow(formId: string): Promise<void>` -- Cancels an animation. This API takes effect only for
- `FormKit.formProvider.closeFormEditAbility(isMainPage: boolean?): void` -- Closes the widget editing page.
- `FormKit.formProvider.deactivateSceneAnimation(formId: string): Promise<void>` -- Requests to deactivate a widget. This API takes effect only for
- `FormKit.formProvider.isRequestPublishFormSupported(): Promise<boolean>` -- Checks whether a widget can be added to the widget host. This API uses a promise to return the result.
- `FormKit.formHost.isSystemReady(): Promise<void>` -- Checks whether the system is ready. This API uses a promise to return the result.
- `FormKit.formProvider.setFormNextRefreshTime(formId: string, minute: int): Promise<void>` -- Sets the next refresh time for a widget. This API uses a promise to return the result.

## AVSessionKit (5)

- `AVSessionKit.avSession.isDesktopLyricSupported(): Promise<boolean>` -- Whether desktop lyric feature is supported.
- `AVSessionKit.avSession.setDiscoverable(enable: boolean): Promise<void>` -- Enable or disable device to be discoverable, used at sink side.
- `AVSessionKit.avSession.startDeviceLogging(url: string, maxSize: int?): Promise<void>` -- Begin to write device logs into a file descriptor for the purpose of problem locating.
- `AVSessionKit.avSession.stopCastDeviceDiscovery(): Promise<void>` -- Stop device discovery.
- `AVSessionKit.avSession.stopDeviceLogging(): Promise<void>` -- Stop the current device written even the discovery is ongoing.

## MechanicKit (4)

- `MechanicKit.mechanicManager.getCameraTrackingEnabled(): boolean` -- Checks whether camera tracking is enabled for this mechanical device.
- `MechanicKit.mechanicManager.getMaxRotationTime(mechId: int): int` -- Obtains the maximum continuous rotation duration of a mechanical device.
- `MechanicKit.mechanicManager.setCameraTrackingEnabled(isEnabled: boolean): void` -- Enables or disables camera tracking.
- `MechanicKit.mechanicManager.stopMoving(mechId: int): Promise<void>` -- Stops a mechanical device from moving.

## SensorServiceKit (4)

- `SensorServiceKit.sensor.getDeviceAltitude(seaPressure: double, currentPressure: double): Promise<double>` -- Obtains the altitude based on the atmospheric pressure. This API uses a promise to return the result.
- `SensorServiceKit.vibrator.isHdHapticSupported(): boolean` -- Checks whether HD vibration is supported.
- `SensorServiceKit.vibrator.isSupportEffect(effectId: string): Promise<boolean>` -- Checks whether an effect ID is supported. This API uses a promise to return the result.
- `SensorServiceKit.vibrator.isSupportEffectSync(effectId: string): boolean` -- Checks whether the preset vibration effect is supported.

## ArkData (4)

- `ArkData.distributedDataObject.genSessionId(): string` -- Creates a random session ID.
- `ArkData.uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(filenameExtension: string, belongsTo: string?): string` -- Obtains the uniform data type ID based on the given file name extension and data type. If there are multiple
- `ArkData.uniformTypeDescriptor.getUniformDataTypeByMIMEType(mimeType: string, belongsTo: string?): string` -- Obtains the uniform data type ID based on the given MIME type and data type. If there are multiple uniform data
- `ArkData.relationalStore.isVectorSupported(): boolean` -- Checks whether the system supports vector stores.

## MDMKit (3)

- `MDMKit.adminManager.getEnterpriseManagedTips(): Promise<string>` -- Gets enterprise message tips.
- `MDMKit.browser.getSelfManagedBrowserPolicyVersion(): string` -- Obtains the browser policy version of the current device.
- `MDMKit.applicationManager.isAppKioskAllowed(appIdentifier: string): boolean` -- Checks whether an application is allowed to run in kiosk mode.

## MultimodalAwarenessKit (2)

- `MultimodalAwarenessKit.metadataBinding.notifyMetadataBindingEvent(bundleName: string): Promise<string>` -- Transfers metadata to the application or service that calls the encoding API. This API uses a promise to return the
- `MultimodalAwarenessKit.metadataBinding.submitMetadata(metadata: string): void` -- Transfers the metadata to be encoded to the MSDP. The MSDP determines whether to transfer the metadata to the

## DrmKit (2)

- `DrmKit.drm.getMediaKeySystemUuid(name: string): string` -- Get a MediaKeySystem's UUID.
- `DrmKit.drm.isMediaKeySystemSupported(name: string): boolean` -- Judge whether a system that specifies name is supported.

## MediaKit (2)

- `MediaKit.media.getAVScreenCaptureConfigurableParameters(sessionId: int): Promise<string>` -- get Configurations which user can changes from AVScreenCapture server
- `MediaKit.media.reportAVScreenCaptureUserChoice(sessionId: int, choice: string): Promise<void>` -- Reports the user selection result in the screen capture privacy dialog box to the AVScreenCapture server to

## ImageKit (2)

- `ImageKit.videoProcessingEngine.deinitializeEnvironment(): Promise<void>` -- Deinitialize global environment for image processing.
- `ImageKit.videoProcessingEngine.initializeEnvironment(): Promise<void>` -- Initialize global environment for image processing.

## DeviceCertificateKit (1)

- `DeviceCertificateKit.certificateManagerDialog.supportsCACertDialog(): boolean` -- Check whether the device supports the [openCertificateDetailDialog]{@link

## IMEKit (1)

- `IMEKit.inputMethod.setSimpleKeyboardEnabled(enable: boolean): void` -- Set simple keyboard mode.

## UniversalKeystoreKit (1)

- `UniversalKeystoreKit.huksExternalCrypto.clearUkeyPinAuthState(resourceId: string): Promise<void>` -- Clear the PIN auth state of the specified resource ID.

## AdsKit (1)

- `AdsKit.identifier.resetOAID(): void` -- Resets the OAID.

## LocalizationKit (1)

- `LocalizationKit.i18n.isRTL(locale: string): boolean` -- Checks whether a language is an RTL language. For an RTL language,
