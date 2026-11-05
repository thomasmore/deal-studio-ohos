import { WidgetSession, LiveFrame, CardNode } from '../vera/VeraLiveWidget'
import { app } from './AppStyle'
import { sourceFetch } from '../vera/VeraSource'

/** A 2x2 home-screen card on this phone, in vp: the size the widget is written for. */
const CARD_SIDE: number = 172

/**
 * The program's widget(state) as the home-screen card will draw it: the same session (VeraLiveWidget) and the same
 * layout as LiveCard, over the state the app preview holds. Taps run the handlers here only; nothing is saved.
 */
@Component
export struct WidgetPreview {
  @Prop @Watch('restart') vbc2: string = ''
  @Prop @Watch('restart') seedState: string = ''
  /** Passed to the session, as the card's frame carries it; a live card does not show it. */
  @Prop title: string = 'App'
  @State frame: LiveFrame = new LiveFrame()
  @State error: string = ''
  private session: WidgetSession | null = null

  aboutToAppear(): void {
    this.restart()
  }

  /** A new program or a new state: draw it from the start. A state the program cannot draw falls back to init. */
  restart(): void {
    this.error = ''
    this.session = null
    this.frame = new LiveFrame()
    if (this.vbc2.length === 0) { return }
    let seeds = this.seedState.length > 0 ? [this.seedState, ''] : ['']
    for (let seed of seeds) {
      try {
        let session = new WidgetSession(this.vbc2, 'preview', seed)
        this.frame = session.frame('', this.title, '')
        this.session = session
        return
      } catch (e) {
        this.error = (e as Error).message
      }
    }
  }

  /** A tap is being handled (a Refresh's fetch may take seconds): another tap meanwhile is ignored, not handled twice. */
  private busy: boolean = false

  private async tap(node: CardNode): Promise<void> {
    if (this.session === null || this.busy) { return }
    let session = this.session!
    // What the session held before the tap: put back if the tap or its answer fails, so it matches the frame on show.
    let before = session.encodedState()
    this.busy = true
    try {
      // A Refresh button fetches its live source here too, as the card does: one call, as on the card.
      let requests = session.tap(this.frame, this.frame.token, node.action, node.value)
      if (requests.length > 0) { session.answer(requests[0].handler, await sourceFetch(requests[0].params)) }
      if (session !== this.session) { return }
      this.frame = session.frame('', this.title, '')
      this.error = ''
    } catch (e) {
      if (session === this.session) { this.session = new WidgetSession(this.vbc2, 'preview', before) }
      this.error = (e as Error).message
    } finally {
      this.busy = false
    }
  }

  build() {
    Column({ space: 12 }) {
      // As LiveCard: the widget has the whole card, with no title strip.
      Column({ space: 6 }) {
        if (this.frame.live) {
          ForEach(this.frame.nodes, (node: CardNode) => { this.level1(node, false) }, (node: CardNode) => node.key + this.frame.token)
        }
      }
      .width(CARD_SIDE)
      .height(CARD_SIDE)
      .padding(12)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.frame.background)
      .borderRadius(20)
      .clip(true)
      .shadow({ radius: 8, color: '#26000000', offsetY: 2 })

      Text(this.note())
        .fontSize(12).fontColor(this.error.length > 0 ? app.warningInk : app.inkMuted)
        .textAlign(TextAlign.Center).constraintSize({ maxWidth: 300 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(app.background)
  }

  private note(): string {
    if (this.error.length > 0) { return this.error }
    if (!this.frame.live) { return 'No widget yet. Say below what it should show.' }
    return 'The home-screen card, over the data in the preview. Taps here are not saved.'
  }

  @Builder
  leaf(node: CardNode) {
    if (node.kind === 'button') {
      Button(node.text).type(ButtonType.Normal).borderRadius(10).height(40)
        .backgroundColor(node.fill).fontColor(node.color).fontSize(14)
        .enabled(node.enabled).onClick(() => { this.tap(node) })
    } else if (node.kind === 'divider') {
      Divider().color('#CBD5E1')
    } else if (node.kind === 'spacer') {
      Blank().height(4)
    } else if (node.kind === 'numbertext') {
      // A figure is never broken over two lines: beside another, it shrinks to fit its half of the card.
      Text(node.text).maxFontSize(node.size).minFontSize(Math.min(node.size, 12)).fontColor(node.color).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    } else {
      Text(node.text).fontSize(node.size).fontColor(node.color).maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
  }

  // This layout (leaf and the level builders) is a copy of widget/pages/LiveCard.ets's, kept in step by hand: a card cannot import the
  // app's code. A change to how a node is drawn goes into both, or the preview stops showing what the card shows.
  @Builder
  level1(node: CardNode, inRow: boolean) {
    if (node.kind === 'row') {
      Row({ space: 8 }) {
        ForEach(node.children, (child: CardNode) => { this.level2(child, true) }, (child: CardNode) => child.key)
      }.width('100%').layoutWeight(inRow ? 1 : 0).justifyContent(FlexAlign.SpaceEvenly)
    } else if (node.kind === 'column') {
      Column({ space: 6 }) {
        ForEach(node.children, (child: CardNode) => { this.level2(child, false) }, (child: CardNode) => child.key)
      }.width('100%').layoutWeight(inRow ? 1 : 0)
    } else {
      this.leaf(node)
    }
  }

  @Builder
  level2(node: CardNode, inRow: boolean) {
    if (node.kind === 'row') {
      Row({ space: 8 }) {
        ForEach(node.children, (child: CardNode) => { this.level3(child, true) }, (child: CardNode) => child.key)
      }.width('100%').layoutWeight(inRow ? 1 : 0).justifyContent(FlexAlign.SpaceEvenly)
    } else if (node.kind === 'column') {
      Column({ space: 6 }) {
        ForEach(node.children, (child: CardNode) => { this.level3(child, false) }, (child: CardNode) => child.key)
      }.width('100%').layoutWeight(inRow ? 1 : 0)
    } else {
      this.leaf(node)
    }
  }

  @Builder
  level3(node: CardNode, inRow: boolean) {
    if (node.kind === 'row') {
      Row({ space: 8 }) {
        ForEach(node.children, (child: CardNode) => { this.leaf(child) }, (child: CardNode) => child.key)
      }.width('100%').layoutWeight(inRow ? 1 : 0).justifyContent(FlexAlign.SpaceEvenly)
    } else if (node.kind === 'column') {
      Column({ space: 6 }) {
        ForEach(node.children, (child: CardNode) => { this.leaf(child) }, (child: CardNode) => child.key)
      }.width('100%').layoutWeight(inRow ? 1 : 0)
    } else {
      this.leaf(node)
    }
  }
}
