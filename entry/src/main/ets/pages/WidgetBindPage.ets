import { formProvider } from '@kit.FormKit'
import { store, Project } from '../vera/ProjectStore'
import { formBindings } from '../vera/FormBindings'
import { refreshForms } from '../vera/FormUpdater'
import { projectIconResource } from '../vera/ProjectIcons'
import { app } from '../components/AppStyle'
import { tileTint } from '../components/ProjectRows'
import { AppRouteParams, returnToLibrary } from '../vera/AppNavigation'

/** A program a live card can show: its latest version that runs declares widget(state). */
function hasWidget(project: Project): boolean {
  let version = store.getLatestRunnableVersion(project.id)
  return version !== null && /\bfunction\s+widget\s*\(/.test(version.source)
}

/** A live card with no app yet, opened by tapping it: the apps that have a widget, one tap to bind one. */
@Component
export struct WidgetBindPage {
  params: AppRouteParams = new AppRouteParams()
  @Consume('navPathStack') pathStack: NavPathStack

  @State projects: Project[] = []
  @State error: string = ''

  aboutToAppear(): void {
    let context = this.getUIContext().getHostContext()
    if (context === undefined) { throw new Error('Widget binding host context is unavailable') }
    store.init(context.filesDir)
    formBindings.init(context.filesDir)
    this.projects = store.listProjects().filter(hasWidget)
  }

  private async bind(project: Project): Promise<void> {
    try {
      // Do not accept arbitrary form IDs supplied as launch parameters.
      let info = await formProvider.getPublishedRunningFormInfoById(this.params.formId)
      if (info.formName !== 'live' || info.bundleName !== 'com.vera.probe.dyn') { throw new Error('Not a VERA live widget') }
      formBindings.bind(this.params.formId, project.id)
      await refreshForms()
      // Opened from the card, possibly as the only page: the library is what is left under it.
      returnToLibrary(this.pathStack)
    } catch (e) { this.error = (e as Error).message }
  }

  build() {
    NavDestination() {
      Column({ space: 12 }) {
        Text(this.projects.length > 0 ? 'Choose the app for this home-screen widget.' :
          'No app has a widget yet. Open an app, then ⋯ › Make widget.')
          .fontSize(15).fontColor(app.inkMuted).width('100%')
        if (this.error.length > 0) { Text(this.error).fontSize(14).fontColor(app.warningInk).width('100%') }
        List({ space: 10 }) {
          ForEach(this.projects, (project: Project) => {
            ListItem() {
              Row({ space: 14 }) {
                Image(projectIconResource(project.icon)).objectFit(ImageFit.Contain)
                  .width(40).height(40).padding(8).borderRadius(12).backgroundColor(tileTint(project.id))
                Text(project.name).fontSize(17).fontWeight(FontWeight.Medium).fontColor(app.inkStrong)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
              }
              .width('100%').padding(12).backgroundColor(app.surface).borderRadius(12)
              .onClick(() => { this.bind(project) })
            }
          }, (project: Project) => project.id)
        }.width('100%').layoutWeight(1)
      }
      .width('100%').height('100%').padding(16)
    }
    .title('Choose widget app')
    .backgroundColor(app.background)
  }
}
