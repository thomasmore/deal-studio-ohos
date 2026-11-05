import { UIUtils } from '@kit.ArkUI'
import { AppNavigationSession, AppRouteParams } from '../vera/AppNavigation'
import { Index } from './Index'
import { ProjectPage } from './ProjectPage'
import { RunnerPage } from './RunnerPage'
import { GeneratePage } from './GeneratePage'
import { ChatListPage } from './ChatListPage'
import { ChatPage } from './ChatPage'
import { AppsPage } from './AppsPage'
import { WidgetBindPage } from './WidgetBindPage'

@Entry({ useSharedStorage: true })
@Component
struct AppShell {
  @LocalStorageLink('navigationSession') session: AppNavigationSession = new AppNavigationSession()
  @Provide('navPathStack') pathStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    // Attach the session in aboutToAppear, following Huawei's lifecycle guidelines.
    this.session.attach(this.pathStack)
  }

  aboutToDisappear(): void {
    this.session.detach(this.pathStack)
  }

  @Builder
  destination(name: string, params: AppRouteParams) {
    if (name === 'library') {
      Index({ params: params })
    } else if (name === 'project') {
      ProjectPage({ params: params })
    } else if (name === 'runner' || name === 'isolatedRunner') {
      RunnerPage({ params: params })
    } else if (name === 'generate') {
      GeneratePage({ params: params })
    } else if (name === 'chatList') {
      ChatListPage({ params: params })
    } else if (name === 'chat') {
      ChatPage({ params: params })
    } else if (name === 'apps') {
      AppsPage({ params: params })
    } else if (name === 'widgetBind') {
      WidgetBindPage({ params: params })
    }
  }

  build() {
    // Keep the Navigation body empty.
    // The launch route adds the 'library' screen (Index) to the path stack.
    Navigation(UIUtils.getTarget(this.pathStack)) {
      // Leave empty to avoid conflicting root rendering.
    }
    .mode(NavigationMode.Stack)
    .hideNavBar(true)
    .navDestination(this.destination)
  }
}
