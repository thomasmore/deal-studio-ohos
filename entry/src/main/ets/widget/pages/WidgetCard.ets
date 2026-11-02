// VERA home-screen card. Tap to run the latest version in the same immersive mode as a desktop shortcut.
// Binding data (injected via LocalStorage): { count, hasProjects, projects: [{id, name, icon}] }
let widgetStorage = new LocalStorage()

@Entry(widgetStorage)
@Component
struct WidgetCard {
  @LocalStorageProp('count') count: number = 0
  @LocalStorageProp('hasProjects') hasProjects: boolean = false
  @LocalStorageProp('projects') projects: Record<string, string>[] = []

  build() {
    Column() {
      Row() {
        Text('VERA').fontSize(13).fontColor('#888888').fontWeight(FontWeight.Medium)
        Blank()
        Text(this.count.toString()).fontSize(11).fontColor('#AAAAAA')
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10 })

      if (this.hasProjects) {
        ForEach(this.projects, (project: Record<string, string>) => {
          Row() {
            Text(project['icon']).fontSize(16).margin({ right: 8 })
            Text(project['name']).fontSize(14).fontColor('#333333')
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text('>').fontSize(13).fontColor('#CCCCCC')
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .onClick(() => {
            // Use the same launch mode as a desktop shortcut. EntryAbility
            // then routes to isolatedRunner and enables immersive full-screen mode.
            postCardAction(this, {
              'action': 'router',
              'abilityName': 'EntryAbility',
              'params': { 'projectId': project['id'], 'launchMode': 'runLatest' }
            })
          })
        // Include the display name and icon in the key: changing project properties must recreate its row.
        }, (project: Record<string, string>) => project['id'] + ':' + project['name'] + ':' + project['icon'])


      } else {
        Column() {
          Text('No projects yet').fontSize(13).fontColor('#AAAAAA')
          Text('Open VERA to create one').fontSize(11).fontColor('#CCCCCC').margin({ top: 2 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }
}
