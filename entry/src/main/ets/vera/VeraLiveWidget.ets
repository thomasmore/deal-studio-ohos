import { VirtualMachine, deserializeVbc2, encodeRuntimeValue, decodeRuntimeValue, RuntimeValue,
  VeraNumberValue } from './VeraInterpreter'
import { UiHostEnvironment, VeraUiNode, decodeVeraUi, formatVeraNumber } from './VeraUi'
import { CATALOG } from './VeraUiCatalog'
import { resolveTheme } from './VeraTheme'
import { veraStateStamp, stateDigest } from './VeraStateStamp'

export const LIVE_MAX_DEPTH: number = 4
export const LIVE_MAX_NODES: number = 40
export const LIVE_MAX_TEXT: number = 256
export const LIVE_MAX_STEPS: number = 100000
// UTF-16 length capped conservatively: even non-ASCII JSON remains small on the wire.
export const LIVE_MAX_JSON: number = 8000

/** A plain binding DTO. All appearance is resolved outside the launcher. */
export class CardNode {
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

export class LiveFrame {
  formId: string = ''
  projectId: string = ''
  title: string = 'Choose app'
  icon: string = '📱'
  versionId: string = ''
  token: string = ''
  status: string = ''
  live: boolean = false
  background: string = '#F8FAFC'
  nodes: CardNode[] = []
}

export class WidgetSession {
  private host: UiHostEnvironment = new UiHostEnvironment()
  private vm: VirtualMachine
  private state: RuntimeValue
  private bytecode: string
  private versionId: string
  private hasWidget: boolean = false
  private hasRefresh: boolean = false

  constructor(vbc2: string, versionId: string, saved: string) {
    this.bytecode = vbc2
    this.versionId = versionId
    let module = deserializeVbc2(vbc2)
    this.hasWidget = module.functions.some((fn): boolean => fn.name === 'widget')
    this.hasRefresh = module.functions.some((fn): boolean => fn.name === 'widgetRefresh')
    this.vm = new VirtualMachine(module, this.host, LIVE_MAX_STEPS)
    this.state = saved.length > 0 ? decodeRuntimeValue(JSON.parse(saved) as Object) : this.vm.execute('init')
  }

  encodedState(): string { return JSON.stringify(encodeRuntimeValue(this.state)) }

  frame(projectId: string, title: string, icon: string): LiveFrame {
    let frame = new LiveFrame()
    frame.projectId = projectId
    frame.title = title
    frame.icon = icon
    frame.versionId = this.versionId
    if (!this.hasWidget) { frame.status = 'Open app'; return frame }
    this.host.effectsAllowed = false
    let roots = decodeVeraUi(this.vm.execute('widget', [this.state]))
    if (roots.length !== 1) { throw new Error('widget must return one root') }
    let root = roots[0]
    let theme = resolveTheme(root.kind === 'apptheme' ? root.style : 'clean',
      root.kind === 'apptheme' ? root.value : '', false)
    frame.background = theme.background
    let count = 0
    let project = (node: VeraUiNode, depth: number, key: string): CardNode => {
      count += 1
      if (count > LIVE_MAX_NODES) { throw new Error('widget exceeds 40 nodes') }
      if (depth > LIVE_MAX_DEPTH) { throw new Error('widget exceeds depth 4') }
      let spec = CATALOG.find((entry): boolean => entry.nodeKind === node.kind)
      if (spec === undefined || !spec.card) { throw new Error('Not card-safe: ' + node.kind) }
      if (node.kind === 'apptheme' && key !== '0') { throw new Error('AppTheme must be the widget root') }
      let item = new CardNode()
      item.key = key
      item.kind = node.kind
      item.text = node.kind === 'numbertext' ? node.prefix + formatVeraNumber(node.numberValue, node.decimals, node.minimumDigits) + node.suffix : node.text
      if (item.text.length > LIVE_MAX_TEXT) { throw new Error('widget text exceeds 256 characters') }
      item.action = node.action
      item.value = node.eventValue
      item.enabled = node.enabled
      item.color = theme.inkStrong
      item.fill = theme.surface
      item.size = node.style === 'metric' ? 30 : node.style === 'heading' ? 18 : 14
      if (node.kind === 'button') {
        item.fill = node.style === 'primary' ? theme.primary : theme.secondaryFill
        item.color = node.style === 'primary' ? theme.onPrimary : theme.secondaryInk
      }
      item.children = node.children.map((child: VeraUiNode, index: number): CardNode => project(child, depth + 1, key + '.' + index.toString()))
      return item
    }
    // The theme wrapper consumes no layout level but is still validated and counted.
    let tree = project(root, root.kind === 'apptheme' ? 0 : 1, '0')
    frame.nodes = root.kind === 'apptheme' ? tree.children : [tree]
    // Rejects taps from an older frame or state. A digest, not the state itself: the token is in the card's data, which has
    // a size budget, and in every key of its layout, so it must not grow with the app's data.
    frame.token = this.versionId + ':' + veraStateStamp(this.bytecode) + ':' + stateDigest(this.encodedState())
    frame.live = true
    if (JSON.stringify(frame).length > LIVE_MAX_JSON) { throw new Error('widget binding exceeds size budget') }
    return frame
  }

  /** The program has widgetRefresh: the card's periodic update brings its state up to date with the clock. */
  refreshes(): boolean { return this.hasRefresh }

  /** widgetRefresh, as a tap runs a handler: phone effects are refused and the state is kept only when it returns. */
  refresh(): void {
    if (!this.hasRefresh) { return }
    this.host.effectsAllowed = true
    this.host.pendingEffects = []
    try {
      let next = this.vm.execute('widgetRefresh', [this.state])
      if (this.host.pendingEffects.length > 0) { throw new Error('widgetRefresh asked for a phone action') }
      this.state = next
    } finally {
      this.host.effectsAllowed = false
      this.host.pendingEffects = []
    }
  }

  tap(frame: LiveFrame, token: string, action: string, value: number): void {
    if (!frame.live || token !== frame.token) { throw new Error('Widget changed; tap again') }
    let allowed = (nodes: CardNode[]): boolean => nodes.some((node: CardNode): boolean =>
      (node.kind === 'button' && node.enabled && node.action.length > 0 && node.action === action && node.value === value) || allowed(node.children))
    if (!Number.isFinite(value) || !allowed(frame.nodes)) { throw new Error('Action is not available on this widget') }
    this.host.effectsAllowed = true
    this.host.pendingEffects = []
    try {
      let next = this.vm.execute(action, [this.state, new VeraNumberValue(value)])
      if (this.host.pendingEffects.length > 0) { throw new Error('Open app to continue: phone action required') }
      this.state = next
    } finally {
      this.host.effectsAllowed = false
      this.host.pendingEffects = []
    }
  }
}
