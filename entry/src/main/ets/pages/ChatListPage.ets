import { chats, ChatSummary } from '../vera/ChatStore'
import { app, DangerButton, TonalButton } from '../components/AppStyle'
import { SymbolGlyphModifier } from '@kit.ArkUI'
import { AppRouteParams } from '../vera/AppNavigation'

/** The chats that fall in one period: today, yesterday, the week, the month, or an older month. */
class ChatGroup {
  key: string = ''
  label: string = ''
  /** Within today and yesterday a row says only the time; further back it says the date. */
  timeOnly: boolean = false
  chats: ChatSummary[] = []
}

const DAY_MS: number = 24 * 60 * 60 * 1000

function startOfDay(t: number): number {
  let d = new Date(t)
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
}

/** Calendar days between two midnights; rounded, so a daylight-saving hour does not shift it. */
function daysBetween(later: number, earlier: number): number {
  return Math.round((later - earlier) / DAY_MS)
}

/**
 * Splits a newest-first list the way chat apps do: the pinned chats first, then Today,
 * Yesterday, Previous 7 days, Previous 30 days, then one group per month, the year
 * shown only for earlier years. A pinned chat is only in Pinned.
 */
function groupChats(list: ChatSummary[], now: number): ChatGroup[] {
  let today = startOfDay(now)
  let thisYear = new Date(now).getFullYear()
  let groups: ChatGroup[] = []
  let pinned = list.filter((c: ChatSummary): boolean => c.pinned)
  if (pinned.length > 0) {
    let g = new ChatGroup()
    g.key = 'pinned'
    g.label = 'Pinned'
    g.chats = pinned
    groups.push(g)
  }
  for (let c of list) {
    if (c.pinned) { continue }
    let age = daysBetween(today, startOfDay(c.updatedAt))
    let key = ''
    let label = ''
    if (age <= 0) {
      key = 'today'
      label = 'Today'
    } else if (age === 1) {
      key = 'yesterday'
      label = 'Yesterday'
    } else if (age <= 7) {
      key = 'week'
      label = 'Previous 7 days'
    } else if (age <= 30) {
      key = 'month'
      label = 'Previous 30 days'
    } else {
      let d = new Date(c.updatedAt)
      key = 'm-' + d.getFullYear().toString() + '-' + d.getMonth().toString()
      label = d.getFullYear() === thisYear
        ? d.toLocaleDateString('en-US', { month: 'long' })
        : d.toLocaleDateString('en-US', { month: 'long', year: 'numeric' })
    }
    if (groups.length === 0 || groups[groups.length - 1].key !== key) {
      let g = new ChatGroup()
      g.key = key
      g.label = label
      g.timeOnly = key === 'today' || key === 'yesterday'
      groups.push(g)
    }
    groups[groups.length - 1].chats.push(c)
  }
  return groups
}

/** The groups folded away, kept while the app runs so coming back to the list keeps them. */
let foldedGroups: string[] = []

/** The saved chats, newest first, in foldable periods, with a way to start another. */
@Component
export struct ChatListPage {
  params: AppRouteParams = new AppRouteParams()

  @Consume('navPathStack') pathStack: NavPathStack

  @State list: ChatSummary[] = []
  @State groups: ChatGroup[] = []
  @State folded: string[] = foldedGroups

  aboutToAppear(): void {
    let context = this.getUIContext().getHostContext()
    if (context === undefined) { throw new Error('Chat list host context is unavailable') }
    chats.init(context.filesDir)
  }

  // A chat is saved while it is open, so coming back from one shows its new title and count.
  destinationShown(): void {
    this.reload()
  }

  private reload(): void {
    this.list = chats.list()
    this.groups = groupChats(this.list, Date.now())
  }

  private open(id: string): void {
    let nav = new AppRouteParams()
    nav.chatId = id
    nav.fromList = '1'
    this.pathStack.pushPath({ name: 'chat', param: nav })
  }

  private isFolded(key: string): boolean {
    return this.folded.indexOf(key) >= 0
  }

  private toggle(key: string): void {
    let next = this.isFolded(key)
      ? this.folded.filter((k: string): boolean => k !== key)
      : [...this.folded, key]
    foldedGroups = next
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.folded = next })
  }

  private setPinned(c: ChatSummary, pinned: boolean): void {
    chats.setPinned(c.id, pinned)
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.reload() })
  }

  private remove(id: string): void {
    chats.remove(id)
    this.reload()
  }

  private describe(c: ChatSummary, timeOnly: boolean): string {
    let d = new Date(c.updatedAt)
    // Pinned chats span every period, so one from today says its time too.
    let when = timeOnly || startOfDay(c.updatedAt) === startOfDay(Date.now())
      ? d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' })
      : d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' })
    let parts: string[] = [when, c.messages.toString() + (c.messages === 1 ? ' message' : ' messages')]
    if (c.widgets > 0) { parts.push(c.widgets.toString() + (c.widgets === 1 ? ' widget' : ' widgets')) }
    return parts.join(' · ')
  }

  build() {
    NavDestination() {
      Column() {
        if (this.list.length === 0) {
          Column() {
            Text('No chats yet').fontSize(18).fontColor(app.inkMuted).margin({ top: 120 })
            Text('Tap New chat to start one').fontSize(14).fontColor(app.inkDisabled).margin({ top: 8 })
          }.width('100%').alignItems(HorizontalAlign.Center)
        } else {
          List({ space: 12 }) {
            // Keyed by its chats and whether it is folded, so either change rebuilds the group.
            ForEach(this.groups, (g: ChatGroup) => {
              ListItemGroup({ header: this.groupHeader(g, this.isFolded(g.key)) }) {
                if (!this.isFolded(g.key)) {
                  ForEach(g.chats, (c: ChatSummary, i: number) => {
                    ListItem() {
                      this.chatRow(c, g.timeOnly, i === 0, i === g.chats.length - 1)
                    }
                    .swipeAction({
                      end: {
                        builder: () => { this.rowActions(c) }
                      }
                    })
                  }, (c: ChatSummary) => c.id)
                }
              }
              .divider({ strokeWidth: 0.5, color: app.lineSoft, startMargin: 14, endMargin: 14 })
            }, (g: ChatGroup) => g.key + (this.isFolded(g.key) ? '|folded|' : '|open|') +
              g.chats.map((c: ChatSummary): string => c.id + '@' + c.updatedAt.toString()).join(','))
          }
          .sticky(StickyStyle.Header)
          .width('100%')
          .height('100%')
          .padding({ left: 16, right: 16 })
          .scrollBar(BarState.Off)
        }
      }
      .width('100%')
      .height('100%')
    }
    .title('Chats')
    .backgroundColor(app.background)
    .onShown(() => { this.destinationShown() })
    .toolbarConfiguration([{
      value: 'New chat',
      symbolIcon: new SymbolGlyphModifier($r('sys.symbol.plus')),
      status: ToolbarItemStatus.NORMAL,
      action: () => { this.open('') }
    }])
  }

  /** A period's name, how many chats it has, and a chevron; a tap folds or unfolds it. */
  @Builder
  groupHeader(g: ChatGroup, folded: boolean) {
    Row({ space: 6 }) {
      Text(g.label).fontSize(13).fontWeight(FontWeight.Medium).fontColor(app.inkSoft)
      Text(g.chats.length.toString()).fontSize(12).fontColor(app.inkDisabled)
      Blank()
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([app.inkMuted])
        .rotate({ angle: folded ? 0 : 90 })
    }
    .width('100%')
    .height(40)
    .padding({ left: 4, right: 6 })
    .backgroundColor(app.background)
    .onClick(() => { this.toggle(g.key) })
  }

  /** One chat in its period's block: the rows share a surface, rounded at its two ends. */
  @Builder
  chatRow(c: ChatSummary, timeOnly: boolean, first: boolean, last: boolean) {
    Column({ space: 3 }) {
      Text(c.title.length > 0 ? c.title : '(untitled)')
        .fontSize(15).fontColor(app.inkStrong)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.describe(c, timeOnly)).fontSize(12).fontColor(app.inkMuted).maxLines(1)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .backgroundColor(app.surface)
    .borderRadius({
      topLeft: first ? 12 : 0, topRight: first ? 12 : 0,
      bottomLeft: last ? 12 : 0, bottomRight: last ? 12 : 0
    })
    .onClick(() => { this.open(c.id) })
    .bindContextMenu(this.rowMenu(c), ResponseType.LongPress)
  }

  /** Long press: the same actions the swipe gives. */
  @Builder
  rowMenu(c: ChatSummary) {
    Menu() {
      MenuItem({ content: c.pinned ? 'Unpin' : 'Pin' })
        .onClick(() => { this.setPinned(c, !c.pinned) })
      MenuItem({ content: 'Delete' })
        .onClick(() => { this.remove(c.id) })
    }
  }

  @Builder
  rowActions(c: ChatSummary) {
    Row({ space: 8 }) {
      Button(c.pinned ? 'Unpin' : 'Pin')
        .attributeModifier(new TonalButton())
        .height('100%')
        .onClick(() => { this.setPinned(c, !c.pinned) })
      Button('Delete')
        .attributeModifier(new DangerButton())
        .height('100%')
        .onClick(() => { this.remove(c.id) })
    }.height('100%').padding({ left: 8 })
  }
}
