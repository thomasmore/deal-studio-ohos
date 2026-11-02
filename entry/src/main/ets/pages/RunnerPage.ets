import { VeraPreview } from '../components/VeraPreview'
import { store } from '../vera/ProjectStore'
import { consent } from '../vera/VeraConsentStore'
import { common } from '@kit.AbilityKit'
import { app } from '../components/AppStyle'
import { AppRouteParams } from '../vera/AppNavigation'

@Component
export struct RunnerPage {
  params: AppRouteParams = new AppRouteParams()

  @Consume('navPathStack') pathStack: NavPathStack

  @State vbc2: string = ''
  @State error: string = ''
  // projectId and versionId were already being passed here and ignored; they are
  // what lets a program opened from the library remember its state.
  @State persistKey: string = ''
  // Whether the running program currently has a ui.BackHandler in its tree,
  // and the signal that tells VeraPreview to act on the system back gesture.
  // See VeraPreview's backPressSignal/onBackHandlerChanged for the other half.
  @State hasBackHandler: boolean = false
  @State backPressSignal: number = 0
  @State shortcutMode: boolean = false
  /** The project's name, once known; a program run from nowhere in a project is just "App". */
  @State title: string = 'App'
  private closing: boolean = false

  aboutToAppear(): void {
    let params = this.params
    this.shortcutMode = params.shortcutMode === 'true'
    if (this.shortcutMode && params.launchError) { this.error = params.launchError; return }
    let vbc2 = params.vbc2
    if (vbc2.length === 0) { this.error = 'No VBC2 bytecode'; return }
    this.vbc2 = vbc2
    let projectId = params.projectId
    let versionId = params.versionId
    if (projectId.length > 0 && versionId.length > 0) {
      this.persistKey = projectId + '/' + versionId
      let context = this.getUIContext().getHostContext()
      if (context === undefined) {
        this.error = 'Runner host context is unavailable'
        this.vbc2 = ''
        return
      }
      store.init(context.filesDir)
      consent.init(context.filesDir)
      let project = store.getProject(projectId)
      if (project !== null) { this.title = project!.name }
    }
  }

  private handleBack(): boolean {
    if (this.hasBackHandler) { this.backPressSignal += 1; return true }
    if (this.shortcutMode) { this.closeShortcut(); return true }
    return false
  }

  private async closeShortcut(): Promise<void> {
    if (this.closing) { return }
    this.closing = true
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext
      await context.terminateSelf()
    } catch (e) {
      console.error('Close mini-app failed: ' + (e as Error).message)
    } finally {
      this.closing = false
    }
  }

  build() {
    NavDestination() {
      Column() {
        if (this.error.length > 0) {
          Text(this.error)
            .fontSize(14)
            .fontColor(app.dangerInk)
            .padding(16)
            .width('100%')
            .backgroundColor(app.dangerFill)
        }
        if (this.vbc2.length > 0) {
          VeraPreview({
            vbc2: this.vbc2, persistKey: this.persistKey,
            backPressSignal: this.backPressSignal,
            onBackHandlerChanged: (active: boolean) => { this.hasBackHandler = active },
          })
        }
      }.width('100%').height('100%')
    }
    .title(this.title)
    .hideTitleBar(this.shortcutMode)
    .hideBackButton(this.shortcutMode)
    .onBackPressed((): boolean => this.handleBack())
  }
}
