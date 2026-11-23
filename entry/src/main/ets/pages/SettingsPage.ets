import { settings, MODE_DEEPSEEK, MODE_SERVER, MODE_LOCAL, SELECTOR_TYPESAFE, SELECTOR_LLM, SELECTOR_LOCAL } from '../vera/SettingsStore'
import { LlamaEngine } from '../vera/LlamaEngine'
import { localJev } from '../vera/LocalJev'
import { resetLogprobsProbe } from '../vera/JevProxy'
import { modelSupportNote } from '../vera/VeraEmbeddings'
import { startUsbNet, stopUsbNet, readUsbNetStatus, usbNetIsOn } from '../vera/UsbNet'
import { AppRouteParams } from '../vera/AppNavigation'
import { app, TonalButton, QuietButton } from '../components/AppStyle'

/**
 * The connection, from any screen's gear (SettingsEntry.ets): how apps are generated, the cloud model, the selector and the
 * USB network. Everything here is kept in SettingsStore or asked of the system, so a screen under it reads it again when it
 * is shown; nothing is handed back.
 */
@Component
export struct SettingsPage {
  params: AppRouteParams = new AppRouteParams()
  @Consume('navPathStack') pathStack: NavPathStack

  @State mode: string = MODE_DEEPSEEK
  @State model: string = ''
  @State selector: string = SELECTOR_TYPESAFE
  @State localSelectorNote: string = ''
  @State usbNetStatus: string = 'off'
  private filesDir: string = ''
  private usbNetTimer: number = -1

  aboutToAppear(): void {
    let context = this.getUIContext().getHostContext()
    if (context === undefined) { throw new Error('Settings host context is unavailable') }
    this.filesDir = context.filesDir
    settings.init(this.filesDir)
    this.reload()
  }

  aboutToDisappear(): void { this.stopPoll() }

  private reload(): void {
    this.mode = settings.getMode()
    this.model = settings.getModel()
    this.selector = settings.getSelectorMode()
    this.localSelectorNote = settings.useLocalSelector() ? 'Local experimental: ' + localJev.statusNote() : ''
    this.usbNetStatus = readUsbNetStatus(this.filesDir)
  }

  /** The VPN's state is read once a second while the page is in view: it changes in another process. */
  private startPoll(): void {
    if (this.usbNetTimer >= 0) { return }
    this.usbNetStatus = readUsbNetStatus(this.filesDir)
    this.usbNetTimer = setInterval(() => {
      this.usbNetStatus = readUsbNetStatus(this.filesDir)
      this.localSelectorNote = settings.useLocalSelector() ? 'Local experimental: ' + localJev.statusNote() : ''
    }, 1000)
  }

  private stopPoll(): void {
    if (this.usbNetTimer < 0) { return }
    clearInterval(this.usbNetTimer)
    this.usbNetTimer = -1
  }

  private pickMode(mode: string): void {
    settings.setMode(mode)
    this.mode = settings.getMode()
  }

  private pickModel(index: number): void {
    settings.applyModelCandidate(index)
    // Whether the proxy can use logprobs is per model, so a switch drops any cached rejection.
    resetLogprobsProbe()
    this.model = settings.getModel()
  }

  private pickSelector(mode: string): void {
    settings.setSelectorMode(mode)
    this.selector = settings.getSelectorMode()
    if (mode === SELECTOR_LOCAL) { localJev.prepare() }
    this.localSelectorNote = settings.useLocalSelector() ? 'Local experimental: ' + localJev.statusNote() : ''
  }

  private selectorTitle(mode: string): string {
    if (mode === SELECTOR_TYPESAFE) { return 'TypeSafe' }
    return mode === SELECTOR_LLM ? 'LLM approximation' : 'Local experimental'
  }

  private selectorDetail(mode: string): string {
    if (mode === SELECTOR_TYPESAFE) {
      return settings.hasSelectorKey() ? 'TypeSafe API · key configured' : 'Missing TypeSafe key (--ps typesafeKey <key>)'
    }
    if (mode === SELECTOR_LLM) {
      return settings.hasApiKey() ? 'Cloud model · ' + this.model : 'Missing cloud key (--ps cloudKey <key>)'
    }
    return 'Embedded model · ' + (this.localSelectorNote.length > 0 ? this.localSelectorNote : localJev.statusNote())
  }

  private async toggleUsbNet(): Promise<void> {
    try {
      if (usbNetIsOn(this.usbNetStatus)) {
        await stopUsbNet(this.filesDir)
      } else {
        await startUsbNet(this.filesDir)
      }
      this.usbNetStatus = readUsbNetStatus(this.filesDir)
    } catch (e) {
      this.usbNetStatus = 'failed: ' + (e as Error).message
    }
  }

  private modeTitle(mode: string): string {
    if (mode === MODE_DEEPSEEK) { return settings.providerLabel() }
    return mode === MODE_SERVER ? 'Server' : 'On the phone'
  }

  private modeDetail(mode: string): string {
    if (mode === MODE_DEEPSEEK) {
      return this.model + (settings.hasApiKey() ? ' · key ' + settings.maskedKey() : ' · no key')
    }
    if (mode === MODE_SERVER) { return settings.hasServerUrl() ? settings.getServerUrl() : 'no address' }
    return 'Qwen3-Coder-3B · ' + (LlamaEngine.modelExists(this.filesDir) ? 'downloaded' : 'not downloaded')
  }

  /** What is missing for the chosen mode, with the command that supplies it; '' when nothing is. */
  private missing(): string {
    if (this.mode === MODE_DEEPSEEK && !settings.hasApiKey()) {
      return 'No ' + settings.providerLabel() + ' key. It is given when the app is started, and kept after that:\n' +
        'hdc shell aa start -a EntryAbility -b com.vera.probe.dyn --ps deepseekKey <key>\n' +
        '(or --ps cloudKey <key> --ps apiBase <url> --ps apiModel <model> for another provider)'
    }
    if (this.mode === MODE_SERVER && !settings.hasServerUrl()) {
      return 'No server address. It is given when the app is started, and kept after that:\n' +
        'hdc shell aa start -a EntryAbility -b com.vera.probe.dyn --ps veraServer http://host:port'
    }
    if (this.mode === MODE_LOCAL && !LlamaEngine.modelExists(this.filesDir) && !settings.hasServerUrl()) {
      return 'The model (about 1.9 GB) is downloaded from vera-server, and no server address is set.'
    }
    return ''
  }

  private modelLabels(): string[] {
    let labels: string[] = []
    for (let i = 0; i < settings.modelCandidateCount(); i++) { labels.push(settings.modelCandidateLabel(i)) }
    return labels
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 16 }) {
          this.section('Generate apps with')
          Column() {
            ForEach([MODE_DEEPSEEK, MODE_SERVER, MODE_LOCAL], (mode: string, index: number) => {
              if (index > 0) { Divider().color(app.secondaryFill).margin({ left: 44 }) }
              this.modeRow(mode)
            }, (mode: string) => mode)
          }
          .width('100%')
          .backgroundColor(app.surface)
          .borderRadius(14)

          if (this.missing().length > 0) {
            Text(this.missing()).fontSize(12).fontColor(app.warningInk).width('100%')
              .padding(12).backgroundColor(app.warningFill).borderRadius(12).copyOption(CopyOptions.LocalDevice)
          }

          // The dashscope models share one key and base URL, so the choice is the model name alone.
          if (this.mode === MODE_DEEPSEEK && settings.isDashscopeProvider() && settings.hasApiKey()) {
            this.section('Model')
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.modelLabels(), (label: string, index: number) => {
                Button(label)
                  .attributeModifier(settings.modelCandidateModel(index) === this.model ? new TonalButton() : new QuietButton())
                  .fontSize(13).height(32).margin({ right: 8, bottom: 8 })
                  .onClick(() => { this.pickModel(index) })
              }, (label: string, index: number) => label + index.toString())
            }
            .width('100%')
          }

          this.section('Jev selector')
          Column() {
            ForEach([SELECTOR_TYPESAFE, SELECTOR_LLM, SELECTOR_LOCAL], (mode: string, index: number) => {
              if (index > 0) { Divider().color(app.secondaryFill).margin({ left: 44 }) }
              this.selectorRow(mode)
            }, (mode: string) => mode)
          }
          .width('100%').backgroundColor(app.surface).borderRadius(14)
          Text('Used for generation and structural edits. Saved across restarts. No automatic selector fallback.')
            .fontSize(12).fontColor(app.inkMuted).width('100%')
          if (this.selector === SELECTOR_LOCAL) {
            Text('Experimental and uncalibrated. Planning and code generation still use the cloud.')
              .fontSize(12).fontColor(app.warningInk).width('100%')
          }
          this.section('Connection')
          Column({ space: 14 }) {
            this.usbSwitchRow()
          }
          .width('100%')
          .padding(14)
          .backgroundColor(app.surface)
          .borderRadius(14)

          if (this.mode === MODE_DEEPSEEK && settings.hasApiKey() && modelSupportNote().length > 0) {
            Text(modelSupportNote()).fontSize(12).fontColor(app.inkMuted).width('100%')
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 24 })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .title('Settings')
    .backgroundColor(app.background)
    .onShown(() => { this.reload(); this.startPoll() })
    .onHidden(() => { this.stopPoll() })
  }

  private usbNetLine(): string {
    if (this.usbNetStatus === 'off') { return 'The whole phone through the computer; run ./usb-net.sh there' }
    if (this.usbNetStatus === 'starting') { return 'Starting; allow the VPN if the phone asks' }
    return this.usbNetStatus
  }

  @Builder
  section(text: string) {
    Text(text).fontSize(13).fontWeight(FontWeight.Medium).fontColor(app.inkMuted).width('100%').padding({ left: 4 })
  }

  @Builder
  modeRow(mode: string) {
    Row({ space: 12 }) {
      Radio({ value: mode, group: 'generation-mode' })
        .checked(this.mode === mode)
        .width(20).height(20)
        .hitTestBehavior(HitTestMode.None)
      Column({ space: 2 }) {
        Text(this.modeTitle(mode)).fontSize(16).fontColor(app.inkStrong)
        Text(this.modeDetail(mode)).fontSize(12).fontColor(app.inkMuted).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .onClick(() => { this.pickMode(mode) })
  }

  @Builder
  selectorRow(mode: string) {
    Row({ space: 12 }) {
      Radio({ value: mode, group: 'jev-selector' })
        .checked(this.selector === mode)
        .width(20).height(20).hitTestBehavior(HitTestMode.None)
      Column({ space: 2 }) {
        Text(this.selectorTitle(mode)).fontSize(16).fontColor(app.inkStrong)
        Text(this.selectorDetail(mode)).fontSize(12).fontColor(app.inkMuted)
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)
    }
    .width('100%').padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .onClick(() => { this.pickSelector(mode) })
  }

  /**
   * One switch. It is named, not given its state: a builder's arguments are copied when it is built, so a state passed in
   * would leave the switch where it was drawn first; read here, it follows the state.
   */
  @Builder
  usbSwitchRow() {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text('USB network').fontSize(16).fontColor(app.inkStrong)
        Text(this.usbNetLine()).fontSize(12).fontColor(app.inkMuted)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: usbNetIsOn(this.usbNetStatus) })
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .onClick(() => { this.toggleUsbNet() })
  }
}
