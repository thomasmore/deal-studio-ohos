import { copyText } from '../components/Clipboard'
import { Project, Version, VersionMetrics, store } from '../vera/ProjectStore'
import { refreshForms } from '../vera/FormUpdater'
import { projectIconResource } from '../vera/ProjectIcons'
import { IconPicker } from '../components/IconPicker'
import { confirmDeleteProject } from '../components/ProjectRows'
import { requestHeadline, changeNote, versionCountText } from '../vera/ProjectText'
import { projectOperations, ProjectOperationStatus, ProjectShortcutState } from '../vera/ProjectOperations'
import { common } from '@kit.AbilityKit'
import { app, PrimaryButton, TonalButton, QuietButton, DangerButton } from '../components/AppStyle'
import { AppRouteParams, returnToLibrary } from '../vera/AppNavigation'

@CustomDialog
struct ProjectPanelDialog {
  controller?: CustomDialogController

  @Builder
  emptyContent() {}

  @BuilderParam content: () => void = this.emptyContent

  build() {
    Column() {
      this.content()
    }
    .width('100%')
  }
}

@Component
export struct ProjectPage {
  params: AppRouteParams = new AppRouteParams()

  @Consume('navPathStack') pathStack: NavPathStack

  @State project: Project | null = null
  @State versions: Version[] = []
  @State projectId: string = ''
  @State projectOperationPending: boolean = false
  @State shortcutOperation: string = ''
  @State shortcutState: ProjectShortcutState = ProjectShortcutState.Unknown
  private shortcutRefreshGeneration: number = 0
  private pageVisible: boolean = false
  private returningToIndex: boolean = false
  @State viewedSource: string = ''
  @State viewedVersionNumber: number = 0
  @State viewedMetricsVersion: Version | null = null
  @State viewedMetricsNumber: number = 0
  // Shown beside the source: the request a version came from is the thing you
  // actually need when deciding whether to refine it or start again.
  @State viewedPrompt: string = ''
  @State renameText: string = ''
  private activePanel: string = ''

  private sourceController: CustomDialogController = new CustomDialogController({
    builder: ProjectPanelDialog({ content: this.sourceDialog }),
    autoCancel: true,
    isModal: true,
    alignment: DialogAlignment.Center,
    customStyle: true,
    maskColor: '#50000000',
    cancel: () => { this.clearPanels() }
  })

  private metricsController: CustomDialogController = new CustomDialogController({
    builder: ProjectPanelDialog({ content: this.metricsDialog }),
    autoCancel: true,
    isModal: true,
    alignment: DialogAlignment.Center,
    customStyle: true,
    maskColor: '#50000000',
    cancel: () => { this.clearPanels() }
  })

  private renameController: CustomDialogController = new CustomDialogController({
    builder: ProjectPanelDialog({ content: this.renameDialog }),
    autoCancel: true,
    isModal: true,
    alignment: DialogAlignment.Center,
    customStyle: true,
    maskColor: '#50000000',
    cancel: () => { this.clearPanels() }
  })

  private iconController: CustomDialogController = new CustomDialogController({
    builder: ProjectPanelDialog({ content: this.iconDialog }),
    autoCancel: true,
    isModal: true,
    alignment: DialogAlignment.Center,
    customStyle: true,
    maskColor: '#50000000',
    cancel: () => { this.clearPanels() }
  })

  aboutToAppear(): void {
    this.projectId = this.params.projectId
  }

  destinationShown(): void {
    this.pageVisible = true
    this.returningToIndex = false
    this.reload()
  }

  destinationHidden(): void {
    this.pageVisible = false
    this.closePanels()
    this.shortcutRefreshGeneration++
    this.shortcutState = ProjectShortcutState.Unknown
  }

  aboutToDisappear(): void {
    this.destinationHidden()
  }

  private reload(): void {
    if (this.projectId.length === 0) { return }
    this.project = store.getProject(this.projectId)
    this.versions = store.listVersions(this.projectId)
    if (this.project === null) {
      this.shortcutRefreshGeneration++
      this.shortcutState = ProjectShortcutState.Unknown
      this.returnToIndex()
      return
    }
    this.refreshShortcutState()
  }

  private returnToIndex(): void {
    if (!this.pageVisible || this.returningToIndex) { return }
    const top = this.pathStack.size() - 1
    if (top < 0 || this.pathStack.getParamByIndex(top) !== this.params) { return }
    try {
      this.returningToIndex = true
      returnToLibrary(this.pathStack)
    } catch (e) {
      this.returningToIndex = false
      console.error('Return to projects failed: ' + (e as Error).message)
    }
  }

  private async refreshShortcutState(): Promise<void> {
    const generation = ++this.shortcutRefreshGeneration
    const projectId = this.projectId
    this.shortcutState = ProjectShortcutState.Unknown
    if (!this.pageVisible || this.projectOperationPending || this.project === null) { return }
    const state = await projectOperations.getShortcutState(projectId)
    if (generation !== this.shortcutRefreshGeneration || projectId !== this.projectId ||
        this.projectOperationPending) { return }
    if (store.getProject(projectId) === null) { this.reload(); return }
    this.shortcutState = state
  }

  private clearPanels(): void {
    this.activePanel = ''
    this.viewedSource = ''
    this.viewedPrompt = ''
    this.viewedVersionNumber = 0
    this.viewedMetricsVersion = null
    this.viewedMetricsNumber = 0
  }

  private closePanels(): void {
    this.sourceController.close()
    this.metricsController.close()
    this.renameController.close()
    this.iconController.close()
    this.clearPanels()
  }

  private handleBack(): boolean {
    if (this.activePanel.length === 0) { return false }
    this.closePanels()
    return true
  }

  private shortcutButtonLabel(): string {
    if (this.shortcutOperation === 'add') { return 'Adding…' }
    if (this.shortcutOperation === 'remove') { return 'Removing…' }
    if (this.shortcutState === ProjectShortcutState.Present) { return 'Remove shortcut' }
    if (this.shortcutState === ProjectShortcutState.Absent) { return 'Add shortcut' }
    return this.shortcutState === ProjectShortcutState.Failed ? 'Check shortcut' : 'Checking shortcut…'
  }

  build() {
    NavDestination() {
      this.pageContent()
    }
    .title(this.project !== null ? this.project!.name : 'Project')
    .backgroundColor(app.background)
    .onBackPressed((): boolean => this.handleBack())
    .onShown(() => { this.destinationShown() })
    .onHidden(() => { this.destinationHidden() })
  }

  @LocalBuilder
  pageContent() {
      Column() {
        if (this.project !== null) {
          Row() {
            // The picture and the name are the controls for changing them: a pencil says so.
            Stack({ alignContent: Alignment.BottomEnd }) {
              Image(projectIconResource(this.project!.icon))
                .width(56).height(56).objectFit(ImageFit.Contain)
              this.pencilBadge()
            }
            .margin({ right: 16 })
            .onClick(() => { this.openIconPicker() })
            Column() {
              Row({ space: 6 }) {
                Text(this.project!.name).fontSize(22).fontWeight(FontWeight.Bold)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
                SymbolGlyph($r('sys.symbol.pencil_tip')).fontSize(16).fontColor([app.inkMuted])
              }
              .onClick(() => { this.openRename() })
              Text(versionCountText(this.versions.length))
                .fontSize(14).fontColor(app.inkMuted).margin({ top: 4 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }
          .width('100%')
          .padding(16)

          // One thing to do first (Generate), the one next to it (Run), and the rest in a menu.
          Row({ space: 10 }) {
            Button('New version')
              .attributeModifier(new PrimaryButton())
              .layoutWeight(1)
              .onClick(() => { this.openGenerate('') })
            Button('Run')
              .attributeModifier(new TonalButton())
              .layoutWeight(1)
              .enabled(this.latestRunnableIndex() >= 0)
              .onClick(() => { this.runLatest() })
            Button('\u22EF')
              .attributeModifier(new TonalButton())
              .width(52)
              .fontSize(22)
              .enabled(!this.projectOperationPending)
              .bindMenu([
                { value: this.shortcutButtonLabel(), action: () => { this.onShortcutMenu() },
                  enabled: this.shortcutMenuEnabled() },
                { value: 'Rename', action: () => { this.openRename() } },
                { value: 'Delete project', action: () => { this.askDeleteProject() } }
              ])
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 12 })

          if (this.versions.length > 0 && this.latestRunnableIndex() !== 0) {
            Text(this.runSelectionNote())
              .fontSize(12)
              .fontColor(app.warningInk)
              .width('100%')
              .padding({ left: 16, right: 16, bottom: 12 })
          }

          List({ space: 12 }) {
            ForEach(this.versions, (v: Version, index: number) => {
              ListItem() {
                Column() {
                  Column() {
                    Row() {
                      Text('v' + (this.versions.length - index).toString())
                        .fontSize(15).fontWeight(FontWeight.Medium)
                      if (v.vbc2.length === 0) {
                        Text('needs compile')
                          .fontSize(11)
                          .fontColor(app.warningInk)
                          .backgroundColor(app.warningFill)
                          .borderRadius(4)
                          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                          .margin({ left: 8 })
                      }
                    }
                    // What the app is (the request it began as); and, for a refinement, what this version changed.
                    if (requestHeadline(v.prompt, v.note).length > 0) {
                      Text(requestHeadline(v.prompt, v.note)).fontSize(13).fontColor(app.inkStrong).margin({ top: 2 })
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    if (changeNote(v.prompt, v.note).length > 0) {
                      Text('Changed: ' + changeNote(v.prompt, v.note)).fontSize(12).fontColor(app.inkSoft).margin({ top: 2 })
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    Text(new Date(v.createdAt).toLocaleString())
                      .fontSize(12).fontColor(app.inkMuted).margin({ top: 2 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .width('100%')

                  Row({ space: 6 }) {
                    Button('Run')
                      .attributeModifier(new TonalButton())
                      .height(32)
                      .fontSize(12)
                      .padding({ left: 4, right: 4 })
                      .layoutWeight(1)
                      .enabled(v.vbc2.length > 0)
                      .onClick(() => { this.runVersion(v) })
                    Button('Refine')
                      .attributeModifier(new QuietButton())
                      .height(32)
                      .fontSize(12)
                      .padding({ left: 4, right: 4 })
                      .layoutWeight(1)
                      .onClick(() => { this.openGenerate(v.id) })
                    Button('Code')
                      .attributeModifier(new QuietButton())
                      .height(32)
                      .fontSize(12)
                      .padding({ left: 4, right: 4 })
                      .layoutWeight(1)
                      .onClick(() => { this.viewSource(v, this.versions.length - index) })
                    Button('Metrics')
                      .attributeModifier(new QuietButton())
                      .height(32)
                      .fontSize(12)
                      .padding({ left: 4, right: 4 })
                      .layoutWeight(1)
                      .onClick(() => { this.viewMetrics(v, this.versions.length - index) })
                  }
                  .width('100%')
                  .margin({ top: 8 })
                }
                .width('100%')
                .padding(14)
                .backgroundColor(app.surface)
                .borderRadius(12)
                .shadow({ radius: 2, color: '#10000000', offsetY: 1 })
              }
              .swipeAction({
                end: {
                  builder: () => { this.deleteVersionAction(v) }
                }
              })
            }, (v: Version) => v.id)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12 })
          .layoutWeight(1)
        }

      }.width('100%').height('100%')
  }

  @LocalBuilder
  deleteVersionAction(v: Version) {
    Row() {
      Button('Delete')
        .attributeModifier(new DangerButton())
        .height('100%')
        .enabled(!this.projectOperationPending)
        .onClick(() => { this.confirmDeleteVersion(v) })
    }.height('100%').padding({ left: 8 })
  }

  private confirmDeleteVersion(v: Version): void {
    let versions = store.listVersions(v.projectId)
    let index = -1
    for (let i = 0; i < versions.length; i++) {
      if (versions[i].id === v.id) { index = i; break }
    }
    if (index < 0) { this.reload(); return }
    let lastVersion = versions.length === 1
    let shortcutWarning = this.shortcutState === ProjectShortcutState.Present ?
      ' Its desktop shortcut will also be removed.' : ' Any desktop shortcut will also be removed.'
    let message = lastVersion ?
      'This is the only remaining version. Deleting it will also delete the mini-app and all its saved program data.' +
        shortcutWarning + ' This cannot be undone.' :
      'Delete v' + (versions.length - index).toString() + ' and its saved program data? This cannot be undone.'
    this.getUIContext().showAlertDialog({
      title: lastVersion ? 'Delete mini-app?' : 'Delete version?',
      message: message,
      primaryButton: {
        value: 'Cancel',
        action: () => {}
      },
      secondaryButton: {
        value: 'Delete',
        fontColor: app.danger,
        action: () => { this.doDeleteVersion(v) }
      }
    })
  }

  private async doDeleteVersion(v: Version): Promise<void> {
    if (this.projectOperationPending) {
      return;
    }
    this.projectOperationPending = true
    let context = (): common.UIAbilityContext => this.getUIContext().getHostContext() as common.UIAbilityContext
    const status = await projectOperations.deleteVersion(context, v.projectId, v.id)
    this.projectOperationPending = false
    if (status === ProjectOperationStatus.ProjectDeletedShortcutRemovalFailed) {
      this.showProjectMessage('Mini-application was deleted, but its shortcut cannot be removed.')
    }
    this.reload()
    refreshForms();
    if (status === ProjectOperationStatus.ProjectDeleted || status === ProjectOperationStatus.NotFound ||
        status === ProjectOperationStatus.ProjectDeletedShortcutRemovalFailed) {
      this.returnToIndex()
    } else if (status !== ProjectOperationStatus.Success) {
      this.showProjectMessage('Cannot delete version.')
    }
  }

  private latestRunnableIndex(): number {
    for (let i = 0; i < this.versions.length; i++) {
      if (this.versions[i].vbc2.length > 0) { return i }
    }
    return -1
  }

  private runSelectionNote(): string {
    let index = this.latestRunnableIndex()
    if (index < 0) { return 'Run is unavailable: no version has compiled code.' }
    return 'Run will launch v' + (this.versions.length - index).toString() +
      ', the latest compiled version. Newer versions need compilation.'
  }

  private runLatest(): void {
    let index = this.latestRunnableIndex()
    if (index < 0) { return }
    this.runVersion(this.versions[index])
  }

  private runVersion(v: Version): void {
    if (v.vbc2.length === 0) { return }
    let p = new AppRouteParams()
    p.projectId = v.projectId
    p.versionId = v.id
    p.vbc2 = v.vbc2
    this.pathStack.pushPath({ name: 'runner', param: p })
  }

  private openGenerate(baseVersionId: string): void {
    let p = new AppRouteParams()
    p.projectId = this.projectId
    p.baseVersionId = baseVersionId
    this.pathStack.pushPath({ name: 'generate', param: p })
  }

  private viewSource(v: Version, versionNumber: number): void {
    if (!this.pageVisible || this.activePanel.length > 0) { return }
    this.viewedVersionNumber = versionNumber
    this.viewedSource = v.source
    this.viewedPrompt = v.prompt
    this.activePanel = 'source'
    this.sourceController.open()
  }

  private viewMetrics(v: Version, versionNumber: number): void {
    if (!this.pageVisible || this.activePanel.length > 0) { return }
    this.viewedMetricsNumber = versionNumber
    this.viewedMetricsVersion = v
    this.activePanel = 'metrics'
    this.metricsController.open()
  }

  private openRename(): void {
    if (!this.pageVisible || this.project === null || this.activePanel.length > 0) { return }
    this.renameText = this.project!.name
    this.activePanel = 'rename'
    this.renameController.open()
  }

  private openIconPicker(): void {
    if (!this.pageVisible || this.project === null || this.activePanel.length > 0) { return }
    this.activePanel = 'icon'
    this.iconController.open()
  }

  private metricCount(value: number): string {
    return value >= 0 ? value.toLocaleString() : 'No data'
  }

  private metricTime(value: number): string {
    if (value < 0) { return 'No data' }
    return value < 1000 ? value.toString() + ' ms' : (value / 1000).toFixed(1) + ' s'
  }

  @LocalBuilder
  metricCell(label: string, value: string, note: string) {
    Column() {
      Column({ space: 2 }) {
        Text(label).fontSize(10).fontColor(app.inkMuted).maxLines(1)
        Text(value).fontSize(17).fontWeight(FontWeight.Bold).fontColor(app.inkStrong)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(note).fontSize(10).fontColor(app.inkMuted).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .padding(10)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(app.surface)
    .borderRadius(8)
  }

  @LocalBuilder
  metricSection(title: string, badge: string, color: string) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(title).fontSize(13).fontWeight(FontWeight.Bold).fontColor(color).layoutWeight(1)
        Text(badge)
          .fontSize(10)
          .fontColor(color)
          .border({ width: 1, color: color, radius: 6 })
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      }
      .width('100%')
      Divider().strokeWidth(2).color(color)
    }
    .width('100%')
    .padding({ top: 6 })
  }

  @LocalBuilder
  metricsDashboard(metrics: VersionMetrics) {
    Column({ space: 10 }) {
      Column({ space: 4 }) {
        Text(metrics.provider.length > 0 ? metrics.provider : 'Provider: No data')
          .fontSize(14).fontWeight(FontWeight.Bold).fontColor(app.inkStrong)
        Text(metrics.model.length > 0 ? metrics.model : 'Model: No data')
          .fontSize(12).fontColor(app.inkSoft).wordBreak(WordBreak.BREAK_ALL)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      this.metricSection('Accepted result', 'Saved snapshot', app.primary)
      Row({ space: 8 }) {
        this.metricCell('Total time', this.metricTime(metrics.elapsedMs), 'generation and refinements')
        this.metricCell('Estimated cost', metrics.estimatedUsd >= 0 ? '~$' + metrics.estimatedUsd.toFixed(6) : 'No data',
          metrics.partial ? 'measured portion only' : 'all measured model calls')
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      Row({ space: 8 }) {
        this.metricCell('Runs', this.metricCount(metrics.runs), 'generation and refinements')
        this.metricCell('Model attempts', this.metricCount(metrics.attempts),
          metrics.attempts === 0 ? 'none: built from ready-made parts' : 'including failed retries')
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      this.metricSection('Token usage', metrics.partial ? 'Partial' : 'Measured', app.successInk)
      Row({ space: 8 }) {
        this.metricCell('Input', this.metricCount(metrics.inputTokens), 'rules, request, old code')
        this.metricCell('Cached', this.metricCount(metrics.cacheHitTokens), 'included in input')
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      Row({ space: 8 }) {
        this.metricCell('Output', this.metricCount(metrics.outputTokens), 'program and reasoning')
      }
      .width('100%')

      Column({ space: 6 }) {
        Text(metrics.partial ? 'Partial metrics' : 'About these metrics')
          .fontSize(12).fontWeight(FontWeight.Medium).fontColor(metrics.partial ? app.warningInk : app.inkSoft)
        Text('Work toward the accepted result in this session, including retries. ' +
          'Excludes the base version and later unsuccessful changes.')
          .fontSize(11).fontColor(app.inkSoft)
        Text('Measured usage only, not complete billing. Stage timings and individual attempts were not saved.')
          .fontSize(11).fontColor(app.inkMuted)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @LocalBuilder
  metricsDialog() {
    if (this.viewedMetricsVersion !== null) {
      Column() {
        Row() {
          Text('Version ' + this.viewedMetricsNumber.toString() + ' · Metrics')
            .fontSize(18).fontWeight(FontWeight.Bold)
          Blank()
          Button('Close')
            .attributeModifier(new QuietButton())
            .height(36)
            .fontSize(13)
            .onClick(() => { this.closePanels() })
        }
        .width('100%')
        .margin({ bottom: 10 })

        Scroll() {
          Column() {
            Column() {
              if (this.viewedMetricsVersion!.metrics !== null) {
                this.metricsDashboard(this.viewedMetricsVersion!.metrics!)
              } else {
                Column({ space: 6 }) {
                  Text('No saved metrics')
                    .fontSize(17).fontWeight(FontWeight.Bold).fontColor(app.inkStrong)
                  Text('Metrics were not saved for this version')
                    .fontSize(13).fontColor(app.inkMuted)
                }
                .alignItems(HorizontalAlign.Start)
                .padding(12)
              }
            }
            .padding(12)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .backgroundColor(app.background)
        .borderRadius(10)
      }
      .width('90%')
      .height('80%')
      .padding(18)
      .backgroundColor(app.surface)
      .borderRadius(14)
      .shadow({ radius: 10, color: '#40000000' })
    }
  }

  private pinToHome(): void {
    this.setPinnedState(true)
  }

  private unpinFromHome(): void {
    this.setPinnedState(false)
  }

  private async setPinnedState(pin: boolean): Promise<void> {
    if (this.projectOperationPending) { return }
    this.projectOperationPending = true
    this.shortcutOperation = pin ? 'add' : 'remove'
    let context = (): common.UIAbilityContext => this.getUIContext().getHostContext() as common.UIAbilityContext

    const status = pin ? await projectOperations.pinProject(context, this.projectId) :
      await projectOperations.unpinProject(context, this.projectId)
    this.shortcutOperation = ''
    this.projectOperationPending = false
    this.reload()
    if (status === ProjectOperationStatus.NotFound) {
      this.returnToIndex()
    } else if (status !== ProjectOperationStatus.Success) {
      this.showProjectMessage(pin ? 'Cannot add shortcut.' : 'Cannot delete shortcut.')
    }
  }

  private showProjectMessage(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message })
    } catch (e) {
      console.error('Show project message failed: ' + (e as Error).message)
    }
  }

  @LocalBuilder
  sourceDialog() {
      Column() {
        Row() {
          Text('Version ' + this.viewedVersionNumber.toString() + ' \u00B7 Code').fontSize(18).fontWeight(FontWeight.Bold)
          Blank()
          Button('Copy')
            .attributeModifier(new QuietButton())
            .height(36)
            .fontSize(13)
            .margin({ right: 8 })
            .onClick(() => { copyText(this.getUIContext(), this.viewedSource) })
          Button('Close')
            .attributeModifier(new QuietButton())
            .height(36)
            .fontSize(13)
            .onClick(() => { this.closePanels() })
        }
        .width('100%')
        .margin({ bottom: 10 })

        Scroll() {
          Column() {
            if (this.viewedPrompt.length > 0) {
              Text('Version request')
                .fontSize(12).fontColor(app.inkMuted).width('100%').margin({ bottom: 4 })
              Text(this.viewedPrompt)
                .fontSize(14)
                .fontColor(app.inkStrong)
                .width('100%')
                .padding(10)
                .backgroundColor(app.background)
                .borderRadius(8)
                .margin({ bottom: 12 })
                .copyOption(CopyOptions.LocalDevice)
            }
            Text('Source')
              .fontSize(12).fontColor(app.inkMuted).width('100%').margin({ bottom: 4 })
            // Lines are not wrapped: an indent is what shows the nesting.
            Scroll() {
              Text(this.viewedSource)
                .fontSize(12)
                .fontFamily('monospace')
                .fontColor(app.inkStrong)
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .align(Alignment.TopStart)
            .width('100%')
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
      }
      .width('90%')
      .height('80%')
      .padding(18)
      .backgroundColor(app.surface)
      .borderRadius(14)
      .shadow({ radius: 10, color: '#40000000' })
  }

  @LocalBuilder
  renameDialog() {
      Column() {
        Text('Rename').fontSize(20).fontWeight(FontWeight.Bold).margin({ bottom: 16 }).width('100%')
        TextInput({ placeholder: 'Project name', text: this.renameText })
          .onChange((value: string) => { this.renameText = value })
          .defaultFocus(true)
          .onSubmit(() => { this.doRename() })
          .width('100%')
          .height(44)
        Row({ space: 12 }) {
          Button('Cancel')
            .attributeModifier(new QuietButton())
            .layoutWeight(1)
            .onClick(() => { this.closePanels() })
          Button('Save')
            .attributeModifier(new PrimaryButton())
            .layoutWeight(1)
            .enabled(this.renameText.trim().length > 0)
            .onClick(() => { this.doRename() })
        }
        .width('100%')
        .margin({ top: 20 })
      }
      .width('90%')
      .padding(24)
      .backgroundColor(app.surface)
      .borderRadius(16)
      .shadow({ radius: 8, color: '#30000000' })
  }

  /** A picture was chosen: it applies at once and the window closes. */
  private async setIcon(icon: string): Promise<void> {
    if (this.project === null) { return }
    this.closePanels()
    if (icon === this.project!.icon) { return }
    store.updateProject(this.projectId, this.project!.name, icon)
    this.reload()
    refreshForms()


    if (this.project !== null && this.versions.length >= 0) {
      let context = (): common.UIAbilityContext => this.getUIContext().getHostContext() as common.UIAbilityContext
      const status = await projectOperations.renameShortcut(context, this.projectId)
      if (status === ProjectOperationStatus.Failed) {
        this.showProjectMessage('Renamed, but the shortcut on the home screen may still show the old icon. Remove and re-add it to update.')
      }
    }
  }

  /** A small pencil on a corner of the picture. */
  @LocalBuilder
  pencilBadge() {
    Column() {
      SymbolGlyph($r('sys.symbol.pencil_tip')).fontSize(12).fontColor([app.primaryInk])
    }
    .width(22).height(22)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(app.surface)
    .borderRadius(11)
    .shadow({ radius: 2, color: '#30000000', offsetY: 1 })
  }

  @LocalBuilder
  iconDialog() {
    Column() {
      Text('Picture').fontSize(20).fontWeight(FontWeight.Bold).margin({ bottom: 12 }).width('100%')
      IconPicker({ selected: this.project !== null ? this.project!.icon : '', onPick: (icon: string): void => { this.setIcon(icon) } })
    }
    .width('90%')
    .padding(24)
    .backgroundColor(app.surface)
    .borderRadius(16)
    .shadow({ radius: 8, color: '#30000000' })
  }

  private async doRename(): Promise<void> {
    let name = this.renameText.trim()
    if (name.length === 0 || this.project === null) { return }
    store.updateProject(this.projectId, name, this.project!.icon)
    this.closePanels()
    this.reload()
    refreshForms()

    if (this.project !== null && this.versions.length >= 0) {
      let context = (): common.UIAbilityContext => this.getUIContext().getHostContext() as common.UIAbilityContext
      const status = await projectOperations.renameShortcut(context, this.projectId)
      if (status === ProjectOperationStatus.Failed) {
        this.showProjectMessage('Renamed, but the shortcut on the home screen may still show the old name. Remove and re-add it to update.')
      }
    }
  }

  /** A shortcut can be added only to something that runs; one that exists can always be removed. */
  private shortcutMenuEnabled(): boolean {
    if (this.projectOperationPending || this.shortcutState === ProjectShortcutState.Unknown) { return false }
    return this.shortcutState === ProjectShortcutState.Present || this.latestRunnableIndex() >= 0
  }

  private onShortcutMenu(): void {
    if (this.shortcutState === ProjectShortcutState.Present) { this.unpinFromHome() }
    else if (this.shortcutState === ProjectShortcutState.Absent) { this.pinToHome() }
    else { this.refreshShortcutState() }
  }

  private askDeleteProject(): void {
    if (this.project === null) { return }
    confirmDeleteProject(this.getUIContext(), this.projectId, (deleted: boolean): void => {
      if (deleted) { this.returnToIndex() }
    })
  }
}
