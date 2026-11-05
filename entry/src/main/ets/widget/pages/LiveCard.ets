// The launcher only consumes binding DTOs. No VM, filesystem, or app imports here.
let liveStorage = new LocalStorage()

class CardNode {
  key: string = ''
  kind: string = ''
  text: string = ''
  action: string = ''
  value: number = 0
  enabled: boolean = true
  color: string = '#172033'
  fill: string = '#FFFFFF'
  size: number = 14
  children: CardNode[] = []
}

@Entry(liveStorage)
@Component
struct LiveCard {
  @LocalStorageProp('formId') formId: string = ''
  @LocalStorageProp('projectId') projectId: string = ''
  @LocalStorageProp('title') title: string = 'VERA app'
  @LocalStorageProp('icon') icon: string = '📱'
  @LocalStorageProp('token') token: string = ''
  @LocalStorageProp('status') status: string = ''
  @LocalStorageProp('live') live: boolean = false
  @LocalStorageProp('background') cardBackground: string = '#F8FAFC'
  @LocalStorageProp('nodes') nodes: CardNode[] = []

  build() {
    // A live widget has the whole card: no title strip with the app's name. A tap anywhere but on a button opens the app
    // (an unbound card: the page that binds it); a button's own tap is the button's.
    Column({ space: 6 }) {
      if (this.live) {
        ForEach(this.nodes, (node: CardNode) => { this.level1(node, false) }, (node: CardNode) => node.key + this.token)
      } else {
        Text(this.title).fontSize(13).fontWeight(FontWeight.Medium).fontColor('#475569')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.icon).fontSize(32)
      }
      if (this.status.length > 0) {
        Text(this.status).fontSize(11).fontColor('#64748B').maxLines(2)
      }
    }
    .width('100%').height('100%').padding(12).backgroundColor(this.cardBackground)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      postCardAction(this, { action: 'router', abilityName: 'EntryAbility', params: { projectId: this.projectId, veraRun: '1', veraFormId: this.projectId.length === 0 ? this.formId : '' } })
    })
  }

  @Builder
  leaf(node: CardNode) {
    if (node.kind === 'button') {
      Button(node.text).type(ButtonType.Normal).borderRadius(10).height(40)
        .backgroundColor(node.fill).fontColor(node.color).fontSize(14)
        .enabled(node.enabled).onClick(() => {
          postCardAction(this, { action: 'message', params: { token: this.token, handler: node.action, value: node.value } })
        })
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

  // This layout (leaf and the level builders) is a copy of components/WidgetPreview.ets's, kept in step by hand: a card cannot import the
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
        ForEach(node.children, (child: CardNode) => { this.level4(child, true) }, (child: CardNode) => child.key)
      }.width('100%').layoutWeight(inRow ? 1 : 0).justifyContent(FlexAlign.SpaceEvenly)
    } else if (node.kind === 'column') {
      Column({ space: 6 }) {
        ForEach(node.children, (child: CardNode) => { this.level4(child, false) }, (child: CardNode) => child.key)
      }.width('100%').layoutWeight(inRow ? 1 : 0)
    } else {
      this.leaf(node)
    }
  }

  @Builder
  level4(node: CardNode, inRow: boolean) {
    this.leaf(node)
  }
}
