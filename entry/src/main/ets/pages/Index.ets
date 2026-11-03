import { KeyboardAvoidMode, window } from '@kit.ArkUI'
import { store } from '../vera/ProjectStore'
import { consent } from '../vera/VeraConsentStore'
import { projectIconResource } from '../vera/ProjectIcons'
import { common } from '@kit.AbilityKit'
import { app } from '../components/AppStyle'
import { HOME_STARTERS, HomeStarter } from '../components/ChatStarters'
import { ProjectRow, confirmDeleteProject, loadProjectRows, tileTint } from '../components/ProjectRows'
import { AppRouteParams } from '../vera/AppNavigation'

/** Width of one label in the Chat / App switch, in vp. */
const MODE_TAB_WIDTH: number = 112

/** Height of the zone above the box, in vp: the ready-made requests. */
const ZONE_HEIGHT: number = 156
/** Narrow enough that a fourth card shows at the edge, so the row reads as one that scrolls. */
const STARTER_CARD_WIDTH: number = 118

/**
 * Height of the apps shelf, in vp: it takes the zone and the box together (the box is
 * about 136 tall with a 24 margin under it), so the greeting stays where it was.
 */
const SHELF_HEIGHT: number = ZONE_HEIGHT + 160

/** Side of an app's icon on the shelf, in vp. */
const SHELF_ICON: number = 120

@Component
export struct Index {
  params: AppRouteParams = new AppRouteParams()
  private backgroundPending: boolean = false

  @Consume('navPathStack') pathStack: NavPathStack

  @State projects: ProjectRow[] = []
  /** What the box at the bottom is for: talking, or making an app. */
  @State makeApp: boolean = true
  @State draft: string = ''
  /**
   * The keyboard is up: the greeting and the zone give up their room to it. Read from the window, not from the box's focus:
   * coming back to the page the box takes the focus again with no keyboard, and the greeting and the requests stayed hidden.
   */
  @State typing: boolean = false
  /** The window the keyboard's height is heard from, and the listener, to stop listening when the page goes. */
  private keyboardWindow: window.Window | null = null
  private keyboardListener: (height: number) => void = (height: number) => {
    let open = height > 0
    if (open !== this.typing) { this.getUIContext().animateTo({ duration: 180 }, () => { this.typing = open }) }
  }
  /** The apps made so far are open on a shelf in place of the requests and the box. */
  @State showApps: boolean = false
  /** The language of the ready-made cards; a card sends its prompt in it. */
  @State starterEnglish: boolean = true

  aboutToAppear(): void {
    let context = this.getUIContext().getHostContext()
    if (context === undefined) { throw new Error('Project library host context is unavailable') }
    store.init(context.filesDir)
    consent.init(context.filesDir)
    // Shrink the page for the keyboard instead of panning it, so the box and its button stay in view.
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE)
    window.getLastWindow(context).then((win: window.Window) => {
      this.keyboardWindow = win
      win.on('keyboardHeightChange', this.keyboardListener)
    }).catch((e: Error) => { console.warn('VERA keyboard listener unavailable: ' + e.message) })
  }

  aboutToDisappear(): void {
    if (this.keyboardWindow !== null) {
      try { this.keyboardWindow.off('keyboardHeightChange', this.keyboardListener) } catch (_e) { /* the window is already gone */ }
      this.keyboardWindow = null
    }
  }

  destinationShown(): void {
    this.reload()
  }

  private reload(): void {
    this.projects = loadProjectRows()
    if (this.projects.length === 0) { this.showApps = false }
  }

  /** Back closes the shelf before it leaves the app. */
  onBackPress(): boolean {
    if (!this.showApps) { return false }
    this.setShelf(false)
    return true
  }

  private setShelf(open: boolean): void {
    if (this.showApps === open) { return }
    this.getUIContext().animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, () => { this.showApps = open })
  }

  private setMode(makeApp: boolean): void {
    if (this.makeApp === makeApp) { return }
    this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => { this.makeApp = makeApp })
  }

  /** `run` sends what was typed straight away; otherwise it waits in the box of the next page. */
  private openChat(prompt: string, run: boolean): void {
    let nav = new AppRouteParams()
    nav.prompt = prompt
    nav.run = run ? '1' : ''
    this.pathStack.pushPath({ name: 'chat', param: nav })
  }

  private openHistory(): void {
    this.pathStack.pushPath({ name: 'chatList', param: new AppRouteParams() })
  }

  private openApps(): void {
    this.pathStack.pushPath({ name: 'apps', param: new AppRouteParams() })
  }

  /**
   * A new app starts on the Generate screen with no project behind it: nothing is asked for
   * and nothing is made until the first Save, which offers a name taken from the program.
   */
  private openCreate(prompt: string, run: boolean): void {
    let nav = new AppRouteParams()
    nav.prompt = prompt
    nav.run = run ? '1' : ''
    this.pathStack.pushPath({ name: 'generate', param: nav })
  }

  /** What the box and a ready-made request do: go to the page of the current mode with the text, and start it if there is any. */
  private submit(text: string): void {
    let request = text.trim()
    this.draft = ''
    if (this.makeApp) { this.openCreate(request, request.length > 0) } else { this.openChat(request, request.length > 0) }
  }

  private async backgroundAbility(): Promise<void> {
    if (this.backgroundPending) { return }
    this.backgroundPending = true
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext
      if (context === undefined) { return }
      await context.moveAbilityToBackground()
    } catch (e) {
      console.error('Move ability to background failed: ' + (e as Error).message)
    } finally {
      this.backgroundPending = false
    }
  }

  build() {
    NavDestination() {
      Column() {
        this.topBar()
        this.middle()
        if (this.showApps) {
          this.appsShelf()
        } else {
          if (!this.typing) {
            this.zone()
          }
          this.promptBox()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(app.background)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    }
    .hideTitleBar(true)
    .backgroundColor(app.background)
    .onShown(() => { this.destinationShown() })
    .onBackPressed(() => {
      if (this.onBackPress()) { return true }
      this.backgroundAbility()
      return true
    })
  }

  /** The saved chats, at the right. */
  @Builder
  topBar() {
    Row({ space: 8 }) {
      Blank()
      Button({ type: ButtonType.Circle }) {
        // The button follows the mode: chats' history for Chat, the apps made so far for App.
        SymbolGlyph($r(this.makeApp ? 'sys.symbol.square_grid_2x2' : 'sys.symbol.clock')).fontSize(20).fontColor([app.inkStrong])
      }
      .width(44).height(44)
      .backgroundColor(app.secondaryFill)
      .accessibilityText(this.makeApp ? 'My apps' : 'Chat history')
      .onClick(() => { if (this.makeApp) { this.openApps() } else { this.openHistory() } })
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 12 })
  }

  /** The greeting in the middle of the free space, and the switch between the two things to do. */
  @Builder
  middle() {
    Column({ space: 20 }) {
      if (!this.typing) {
        Image($r('app.media.vera_mark')).width(52).height(52).objectFit(ImageFit.Contain)
      }
      Column({ space: 8 }) {
        Text(this.makeApp ? 'What shall we make?' : 'How can I help?')
          .fontSize(30).fontWeight(FontWeight.Medium).fontColor(app.inkStrong).textAlign(TextAlign.Center)
        if (!this.typing) {
          Text(this.makeApp ? 'Describe an idea and VERA builds the screens, logic and data.' :
            'Ask, plan, get a card.')
            .fontSize(15).fontColor(app.inkSoft).textAlign(TextAlign.Center).constraintSize({ maxWidth: 290 })
        }
      }
      // The white pill slides under the label that is on; the state flips inside animateTo so the pill and the ink move together.
      Stack({ alignContent: Alignment.TopStart }) {
        Row()
          .width(MODE_TAB_WIDTH).height(40).borderRadius(20)
          .backgroundColor(app.surface)
          .shadow({ radius: 2, color: '#20000000', offsetY: 1 })
          .translate({ x: this.makeApp ? MODE_TAB_WIDTH + 2 : 0 })
        Row({ space: 2 }) {
          this.modeTab('Chat', 'sys.symbol.ellipsis_message', !this.makeApp, () => { this.setMode(false) })
          this.modeTab('App', 'sys.symbol.plus', this.makeApp, () => { this.setMode(true) })
        }
      }
      .padding(4)
      .borderRadius(24)
      .backgroundColor(app.secondaryFill)
      .margin({ top: 8 })
    }
    .layoutWeight(1)
    .width('100%')
    .padding({ left: 24, right: 24 })
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  modeTab(label: string, symbol: string, on: boolean, go: () => void) {
    Row({ space: 6 }) {
      SymbolGlyph($r(symbol)).fontSize(18).fontColor([on ? app.inkStrong : app.inkSoft])
      Text(label).fontSize(15).fontWeight(FontWeight.Medium).fontColor(on ? app.inkStrong : app.inkSoft)
    }
    .width(MODE_TAB_WIDTH)
    .height(40)
    .justifyContent(FlexAlign.Center)
    .onClick(go)
  }

  /** The ready-made requests, cards in a row that scrolls sideways; "My apps" at the right swaps them and the box for the apps. */
  @Builder
  zone() {
    Column({ space: 10 }) {
      Row() {
        Text(this.starterEnglish ? 'Try one of these' : '试试这些')
          .fontSize(15).fontWeight(FontWeight.Medium).fontColor(app.inkStrong).layoutWeight(1)
        this.langChip('EN', true)
        this.langChip('中文', false)
        if (this.projects.length > 0) {
          Row({ space: 2 }) {
            Text('My apps').fontSize(14).fontWeight(FontWeight.Medium).fontColor(app.primaryInk)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([app.primaryInk])
          }
          .height(44).padding({ left: 12, right: 4 })
          .accessibilityText('My apps')
          .onClick(() => { this.setShelf(true) })
        }
      }
      .width('100%').height(24).padding({ left: 16, right: 12 })
      Scroll() {
        Row({ space: 8 }) {
          ForEach(HOME_STARTERS, (starter: HomeStarter) => {
            this.starterCard(starter)
          }, (starter: HomeStarter) => starter.id)
        }
        .padding({ left: 12, right: 12 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
    }
    .width('100%')
    .height(ZONE_HEIGHT)
    .justifyContent(FlexAlign.Start)
    .transition(TransitionEffect.OPACITY)
  }

  /** One side of the cards' language switch; the picked one is filled. */
  @Builder
  langChip(label: string, english: boolean) {
    Text(label)
      .fontSize(12)
      .fontWeight(this.starterEnglish === english ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.starterEnglish === english ? app.primaryInk : app.inkMuted)
      .backgroundColor(this.starterEnglish === english ? app.primaryFill : Color.Transparent)
      .borderRadius(12)
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      .margin({ left: 4 })
      .accessibilityText(english ? 'English' : 'Chinese')
      .onClick(() => { this.starterEnglish = english })
  }

  /** One request: its symbol on a round tint, a title and a hint; a tap sends it in the current mode. */
  @Builder
  starterCard(starter: HomeStarter) {
    Column({ space: 8 }) {
      Row() {
        SymbolGlyph($r(starter.symbol)).fontSize(18).fontColor([starter.ink])
      }
      .width(34).height(34).borderRadius(17)
      .backgroundColor(starter.tint)
      .justifyContent(FlexAlign.Center)
      Column({ space: 2 }) {
        Text(starter.text(this.starterEnglish).title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(app.inkStrong).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(starter.text(this.starterEnglish).hint).fontSize(12).fontColor(app.inkSoft).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
    }
    .width(STARTER_CARD_WIDTH)
    .height(110)
    .padding(12)
    .alignItems(HorizontalAlign.Start)
    .borderRadius(18)
    .backgroundColor(app.surface)
    .borderWidth(1)
    .borderColor(app.line)
    .accessibilityText(starter.text(this.starterEnglish).title)
    .onClick(() => { this.submit(starter.text(this.starterEnglish).prompt) })
  }

  /** The apps made so far, large, one swipe across; a press opens one, a long press offers to delete it. */
  @Builder
  appsShelf() {
    Column({ space: 20 }) {
      Row() {
        Text('My apps').fontSize(17).fontWeight(FontWeight.Medium).fontColor(app.inkStrong).layoutWeight(1)
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([app.inkStrong])
        }
        .width(36).height(36)
        .backgroundColor(app.secondaryFill)
        .accessibilityText('Close my apps')
        .onClick(() => { this.setShelf(false) })
      }
      .width('100%').padding({ left: 16, right: 12 })
      List({ space: 12 }) {
        ForEach(this.projects, (row: ProjectRow) => {
          ListItem() {
            this.appTile(row)
          }
        }, (row: ProjectRow) => row.project.id + '|' + row.project.name + '|' + row.project.icon)
      }
      .listDirection(Axis.Horizontal)
      .scrollBar(BarState.Off)
      .scrollSnapAlign(ScrollSnapAlign.START)
      .contentStartOffset(16)
      .contentEndOffset(16)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
      .height(SHELF_ICON + 56)
    }
    .width('100%')
    .height(SHELF_HEIGHT)
    .padding({ top: 8 })
    .justifyContent(FlexAlign.Start)
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 40 })))
  }

  @Builder
  appTile(row: ProjectRow) {
    Column({ space: 10 }) {
      Image(projectIconResource(row.project.icon)).objectFit(ImageFit.Contain)
        .width(SHELF_ICON).height(SHELF_ICON).padding(26).borderRadius(34).backgroundColor(tileTint(row.project.id))
      Text(row.project.name).fontSize(14).fontColor(app.inkStrong).maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Center)
        .width('100%').height(40)
    }
    .width(SHELF_ICON + 12)
    .onClick(() => {
      let nav = new AppRouteParams()
      nav.projectId = row.project.id
      this.pathStack.pushPath({ name: 'project', param: nav })
    })
    // The press that asks is its own confirmation: nothing is deleted before the dialog is answered.
    .gesture(LongPressGesture({ repeat: false }).onAction(() => {
      confirmDeleteProject(this.getUIContext(), row.project.id, (deleted: boolean): void => { this.reload() })
    }))
  }

  /** The request: a rounded card that floats above the bottom edge, with the send button at its corner. */
  @Builder
  promptBox() {
    Column({ space: 8 }) {
      TextArea({ placeholder: this.makeApp ? 'Describe the app…' : 'Write a message…', text: this.draft })
        .fontSize(16).fontColor(app.inkStrong).backgroundColor(Color.Transparent)
        .height(64).padding({ left: 6, right: 6 })
        .enterKeyType(EnterKeyType.Send)
        // Coming back to the page, the box takes the focus again; that must not open the keyboard over the apps.
        // A tap on the box still does.
        .enableKeyboardOnFocus(false)
        .onChange((value: string) => { this.draft = value })
        .onSubmit(() => { this.submit(this.draft) })
      Row() {
        Blank()
        // Pale while there is nothing to send, as on the Generate screen; a press then just opens the page.
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.arrow_up')).fontSize(20).fontColor([app.onPrimary])
        }
        .width(44).height(44)
        .backgroundColor(app.primary)
        .opacity(this.draft.trim().length > 0 ? 1 : 0.4)
        .accessibilityText(this.makeApp ? 'Create app' : 'Send')
        .onClick(() => { this.submit(this.draft) })
      }
      .width('100%')
    }
    .margin({ left: 12, right: 12, bottom: 24 })
    .padding({ top: 10, left: 10, right: 10, bottom: 10 })
    .borderRadius(26)
    .backgroundColor(app.surface)
    .borderWidth(1)
    .borderColor(app.line)
    .shadow({ radius: 20, color: '#12000000', offsetY: 4 })
    .transition(TransitionEffect.OPACITY)
  }
}
