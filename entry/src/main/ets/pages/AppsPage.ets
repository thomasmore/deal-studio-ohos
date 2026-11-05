import { store } from '../vera/ProjectStore'
import { versionCountText } from '../vera/ProjectText'
import { SymbolGlyphModifier } from '@kit.ArkUI'
import { projectIconResource } from '../vera/ProjectIcons'
import { app, DangerButton } from '../components/AppStyle'
import { ProjectRow, RowSource, loadProjectRows, confirmDeleteProject, tileTint } from '../components/ProjectRows'
import { AppRouteParams } from '../vera/AppNavigation'

/** Every app made so far, one row each. Swipe or long press to delete. */
@Component
export struct AppsPage {
  params: AppRouteParams = new AppRouteParams()
  @Consume('navPathStack') pathStack: NavPathStack

  @State projects: ProjectRow[] = []
  private source: RowSource = new RowSource()

  aboutToAppear(): void {
    let context = this.getUIContext().getHostContext()
    if (context === undefined) { throw new Error('Project library host context is unavailable') }
    store.init(context.filesDir)
    this.reload()
  }

  destinationShown(): void {
    this.reload()
  }

  private reload(): void {
    this.projects = loadProjectRows()
    this.source.replace(this.projects)
  }

  build() {
    NavDestination() {
      List({ space: 12 }) {
        LazyForEach(this.source, (row: ProjectRow) => {
          ListItem() {
            this.projectRow(row)
          }
          .swipeAction({
            end: {
              builder: () => { this.deleteAction(row.project.id) }
            }
          })
        // Keyed by what a row shows, so a rename, a new picture or a saved version redraws it.
        }, (row: ProjectRow) => row.project.id + '|' + row.project.name + '|' + row.project.icon + '|' +
          row.summary.versions.toString() + '|' + row.summary.updatedAt.toString())
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 16 })
      .scrollBar(BarState.Off)
    }
    .title('My apps (' + this.projects.length.toString() + ')')
    .backgroundColor(app.background)
    .onShown(() => { this.destinationShown() })
  }

  /** One project: its icon, what it is (the request it began as), how much work is in it, and when it was last worked on. */
  @Builder
  projectRow(row: ProjectRow) {
    Column() {
      Row() {
        Image(projectIconResource(row.project.icon)).objectFit(ImageFit.Contain)
          .width(48).height(48).padding(10).borderRadius(14).backgroundColor(tileTint(row.project.id))
          .margin({ right: 14 })
        Column({ space: 2 }) {
          Text(row.project.name).fontSize(17).fontWeight(FontWeight.Medium).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (row.summary.request.length > 0) {
            Text(row.summary.request).fontSize(13).fontColor(app.inkSoft).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          Text(versionCountText(row.summary.versions) + ' · ' + new Date(row.summary.updatedAt).toLocaleDateString())
            .fontSize(12).fontColor(app.inkMuted)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(18).fontColor([app.inkDisabled])
      }
      .width('100%')
      .padding(14)
    }
    .width('100%')
    .backgroundColor(app.surface)
    .borderRadius(12)
    .clip(true)
    .shadow({ radius: 2, color: '#10000000', offsetY: 1 })
    .onClick(() => {
      let nav = new AppRouteParams()
      nav.projectId = row.project.id
      this.pathStack.pushPath({ name: 'project', param: nav })
    })
    .bindContextMenu(() => { this.rowMenu(row.project.id) }, ResponseType.LongPress)
  }

  @Builder
  rowMenu(id: string) {
    Menu() {
      MenuItem({ content: 'Delete project', symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.trash')) })
        .onClick(() => { confirmDeleteProject(this.getUIContext(), id, (deleted: boolean): void => { this.reload() }) })
    }
  }

  @Builder
  deleteAction(id: string) {
    Row() {
      Button('Delete')
        .attributeModifier(new DangerButton())
        .height('100%')
        .onClick(() => { confirmDeleteProject(this.getUIContext(), id, (deleted: boolean): void => { this.reload() }) })
    }.height('100%').padding({ left: 8 })
  }
}
