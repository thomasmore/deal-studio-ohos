/**
 * The renderer's own copy of the UI tree, and the reconciler that keeps it in
 * step with what the program produced.
 *
 * Why a second tree exists at all. The VM builds a brand new VeraUiNode tree on
 * every frame, and ArkUI does not re-render a component because an object was
 * *replaced* -- only because one was *mutated*. Three approaches were each built
 * and measured on device before this one, and all three left the screen stale
 * while the VM ran correctly underneath: passing the node to a nested @Builder,
 * keying ForEach on node content, and a recursive @Component taking the node as
 * @Prop. So the renderer keeps a persistent tree of @Trace'd nodes and copies
 * each new frame into it field by field. Mutation propagates; replacement does
 * not.
 *
 * Why not simply mark VeraUiNode itself observable: decodeVeraUi is a measured
 * phase of the benchmark (decodeUs, part of coldTotalUs), and putting
 * observation overhead inside it would move a published number. Decode stays a
 * cheap pure function producing plain data; the cost of observation lands here,
 * in the renderer, where buildUs already accounts for it.
 */

import { VeraUiNode } from '../vera/VeraUi'

@ObservedV2
export class LiveNode {
  // Renderer measurement is live state, never program or saved state.
  @Trace layoutWidth: number = 0
  /** ui.Surface with style fill: how tall it is drawn, from where it starts to the bottom of the window. */
  @Trace layoutHeight: number = 0
  @Trace kind: string = ''
  @Trace style: string = ''
  @Trace text: string = ''
  @Trace source: string = ''
  @Trace alt: string = ''
  @Trace action: string = ''
  @Trace eventValue: number = 0
  @Trace enabled: boolean = true
  @Trace commands: string = ''
  @Trace spinPeriodMs: number = 0
  /** ui.Motion: when its animation began (Date.now()), -1 for none. Renderer state: never in the program, never copied from the node. */
  @Trace motionStart: number = -1
  @Trace label: string = ''
  @Trace tickerId: string = ''
  @Trace columns: number = 1
  @Trace value: string = ''
  @Trace checked: boolean = false
  @Trace minimum: number = 0
  @Trace maximum: number = 100
  @Trace options: string[] = []
  // ui.Sparkline's raw values; see VeraUiNode.
  @Trace series: number[] = []
  @Trace bars: boolean = false
  @Trace series2: number[] = []
  @Trace series2Style: string = ''
  @Trace seriesLabel: string = ''
  @Trace series2Label: string = ''
  @Trace categories: string[] = []
  // The typed numeric layer; see VeraUiNode.
  @Trace numberValue: number = 0
  @Trace prefix: string = ''
  @Trace suffix: string = ''
  @Trace minimumDigits: number = 1
  @Trace decimals: number = -1
  @Trace step: number = 1
  @Trace icon: string = ''
  // ui.TextField validation; see VeraUiNode.
  @Trace keyboardType: string = ''
  @Trace required: boolean = false
  @Trace requiredMessage: string = ''
  @Trace minLength: number = 0
  @Trace minLengthMessage: string = ''
  @Trace maxLength: number = -1
  @Trace maxLengthMessage: string = ''
  @Trace pattern: string = ''
  @Trace patternMessage: string = ''
  @Trace email: boolean = false
  @Trace emailMessage: string = ''
  /**
   * ui.TextField: whether its check may be shown. Not before the person has typed in it or pressed a button: an empty
   * required field on a form just opened is not a mistake. Renderer state, never the program's.
   */
  @Trace touched: boolean = false
  /** What the person last typed in this field, to tell their own clearing from the program's reset of the form. */
  typed: string = ''
  @Trace children: LiveNode[] = []
  @Trace fieldValue: string = ''
  @Trace fieldIssue: string = ''
  @Trace fieldGeneration: number = 0

  fieldCancellation: number = 0

  /** Renderer-only membership stamp; deliberately not @Trace to avoid triggering ArkUI updates. */
  liveGeneration: number = 0

  /**
   * Renderer state: this node appeared because of something the person just did (a card opened, a result banner came up),
   * so the renderer brings it into view once it has a size. Never traced: reading it must not redraw anything.
   */
  reveal: boolean = false
  /**
   * A ListItem with no icon of its own in a ListGroup where another row has one: it keeps the icon's room empty, so every row's
   * words start at one edge. Without it a care card's rows started at two (Baby fever: "Keep baby hydrated" at the margin, "Check
   * temperature" beside a clock). Renderer state, set by markIconRoom after each reconcile.
   */
  @Trace iconRoom: boolean = false
}

/** Sets iconRoom on the rows of every ListGroup from here down; see LiveNode.iconRoom. */
export function markIconRoom(node: LiveNode): void {
  if (node.kind === 'listgroup') {
    let any = node.children.some((c: LiveNode): boolean => c.kind === 'listitem' && c.icon.length > 0)
    for (let c of node.children) {
      let room = any && c.kind === 'listitem' && c.icon.length === 0
      if (c.iconRoom !== room) { c.iconRoom = room }
    }
  }
  for (let c of node.children) { markIconRoom(c) }
}

/** The kinds that are brought into view when a tap makes them appear: what opens, not a row added to a list. */
const REVEALED_KINDS: string[] = ['card', 'banner', 'section']

/** Whether the frame being reconciled answers a person's action; only then is what appears brought into view. */
let revealArmed: boolean = false

/** Arm or disarm marking new cards, banners and sections for reveal (VeraPreview.dispatch arms it around one frame). */
export function armReveal(on: boolean): void {
  revealArmed = on
}

/** A fresh live subtree, used for the parts a frame actually adds. */
export function toLive(node: VeraUiNode): LiveNode {
  let live = new LiveNode()
  live.kind = node.kind
  live.style = node.style
  live.text = node.text
  live.source = node.source
  live.alt = node.alt
  live.action = node.action
  live.eventValue = node.eventValue
  live.enabled = node.enabled
  live.commands = node.commands
  live.spinPeriodMs = node.spinPeriodMs
  live.label = node.label
  live.tickerId = node.tickerId
  live.columns = node.columns
  live.value = node.value
  live.fieldValue = node.value
  live.checked = node.checked
  live.minimum = node.minimum
  live.maximum = node.maximum
  live.options = node.options
  live.series = node.series
  live.bars = node.bars
  live.series2 = node.series2
  live.series2Style = node.series2Style
  live.seriesLabel = node.seriesLabel
  live.series2Label = node.series2Label
  live.categories = node.categories
  live.numberValue = node.numberValue
  live.prefix = node.prefix
  live.suffix = node.suffix
  live.minimumDigits = node.minimumDigits
  live.decimals = node.decimals
  live.step = node.step
  live.icon = node.icon
  live.keyboardType = node.keyboardType
  live.required = node.required
  live.requiredMessage = node.requiredMessage
  live.minLength = node.minLength
  live.minLengthMessage = node.minLengthMessage
  live.maxLength = node.maxLength
  live.maxLengthMessage = node.maxLengthMessage
  live.pattern = node.pattern
  live.patternMessage = node.patternMessage
  live.email = node.email
  live.emailMessage = node.emailMessage
  let kids: LiveNode[] = []
  for (let child of node.children) { kids.push(toLive(child)) }
  live.children = kids
  return live
}

/**
 * Copy one frame into the live tree, touching only what differs.
 *
 * Assigning a @Trace field notifies every component that reads it, so the
 * comparisons are not an optimisation -- writing an unchanged value would
 * re-render a node that did not change, which is the very behaviour this
 * replaces.
 *
 * Children are matched by position, and a position that already exists keeps
 * its node. That is not an optimisation either -- it is the invariant the
 * renderer depends on. ForEach there is keyed by position, so ArkUI retains the
 * component it already built for that key and never re-invokes the builder; the
 * component goes on reading the LiveNode it closed over. Hand it a replacement
 * object and that row freezes forever at whatever it showed when it was
 * created, while the new node is rendered by nobody.
 *
 * Rebuilding the whole list whenever the count changed did exactly that, and it
 * is the common case rather than a rare one: any program that appends to a log
 * grows its list every frame. A list drawn newest-first -- the natural way to
 * show a journal -- then disagrees with its own state on every row.
 */
export function reconcile(live: LiveNode, next: VeraUiNode,
    fieldValue?: (node: LiveNode, next: VeraUiNode) => string | undefined): void {
  let generation = live.fieldGeneration
  let draft = live.kind === 'field'
    ? fieldValue !== undefined ? fieldValue(live, next)
      : live.fieldValue !== live.value && next.value === live.value ? live.fieldValue : undefined
    : undefined
  if (live.kind !== next.kind || live.action !== next.action || live.enabled !== next.enabled ||
      ((live.kind === 'field' || live.kind === 'surface') &&
        live.value !== next.value && live.fieldValue !== next.value && draft === undefined) ||
      (live.kind === 'field' && (live.keyboardType !== next.keyboardType || live.required !== next.required ||
        live.minLength !== next.minLength || live.maxLength !== next.maxLength ||
        live.pattern !== next.pattern || live.email !== next.email))) {
    live.fieldGeneration++
  }
  let value = generation === live.fieldGeneration && draft !== undefined ? draft : next.value
  if (live.fieldValue !== value) { live.fieldValue = value }
  if (live.kind !== next.kind) {
    live.kind = next.kind
    live.layoutWidth = 0
    // A ui.When that turned true: the spacer that held its place is now the card.
    if (revealArmed && REVEALED_KINDS.indexOf(next.kind) >= 0) { live.reveal = true }
  }
  if (live.style !== next.style) { live.style = next.style }
  if (live.text !== next.text) { live.text = next.text }
  if (live.source !== next.source) { live.source = next.source }
  if (live.alt !== next.alt) { live.alt = next.alt }
  if (live.action !== next.action) { live.action = next.action }
  if (live.eventValue !== next.eventValue) { live.eventValue = next.eventValue }
  if (live.enabled !== next.enabled) { live.enabled = next.enabled }
  if (live.commands !== next.commands) { live.commands = next.commands }
  if (live.spinPeriodMs !== next.spinPeriodMs) { live.spinPeriodMs = next.spinPeriodMs }
  if (live.label !== next.label) { live.label = next.label; live.touched = false; live.typed = '' }
  if (live.tickerId !== next.tickerId) { live.tickerId = next.tickerId }
  if (live.columns !== next.columns) { live.columns = next.columns }
  if (live.value !== next.value) {
    // The program emptied the field (a form reset after a successful add): untouched again, so nothing is flagged.
    if (next.value.length === 0 && live.typed !== next.value) { live.touched = false }
    live.value = next.value
  }
  if (live.checked !== next.checked) { live.checked = next.checked }
  if (live.minimum !== next.minimum) { live.minimum = next.minimum }
  if (live.maximum !== next.maximum) { live.maximum = next.maximum }
  if (live.options.join('\u0000') !== next.options.join('\u0000')) { live.options = next.options }
  if (live.series.join(',') !== next.series.join(',')) { live.series = next.series }
  if (live.bars !== next.bars) { live.bars = next.bars }
  if (live.series2.join(',') !== next.series2.join(',')) { live.series2 = next.series2 }
  if (live.series2Style !== next.series2Style) { live.series2Style = next.series2Style }
  if (live.seriesLabel !== next.seriesLabel) { live.seriesLabel = next.seriesLabel }
  if (live.series2Label !== next.series2Label) { live.series2Label = next.series2Label }
  if (live.categories.join('\u0000') !== next.categories.join('\u0000')) { live.categories = next.categories }
  if (live.numberValue !== next.numberValue) { live.numberValue = next.numberValue }
  if (live.prefix !== next.prefix) { live.prefix = next.prefix }
  if (live.suffix !== next.suffix) { live.suffix = next.suffix }
  if (live.minimumDigits !== next.minimumDigits) { live.minimumDigits = next.minimumDigits }
  if (live.decimals !== next.decimals) { live.decimals = next.decimals }
  if (live.step !== next.step) { live.step = next.step }
  if (live.icon !== next.icon) { live.icon = next.icon }
  if (live.keyboardType !== next.keyboardType) { live.keyboardType = next.keyboardType }
  if (live.required !== next.required) { live.required = next.required }
  if (live.requiredMessage !== next.requiredMessage) { live.requiredMessage = next.requiredMessage }
  if (live.minLength !== next.minLength) { live.minLength = next.minLength }
  if (live.minLengthMessage !== next.minLengthMessage) { live.minLengthMessage = next.minLengthMessage }
  if (live.maxLength !== next.maxLength) { live.maxLength = next.maxLength }
  if (live.maxLengthMessage !== next.maxLengthMessage) { live.maxLengthMessage = next.maxLengthMessage }
  if (live.pattern !== next.pattern) { live.pattern = next.pattern }
  if (live.patternMessage !== next.patternMessage) { live.patternMessage = next.patternMessage }
  if (live.email !== next.email) { live.email = next.email }
  if (live.emailMessage !== next.emailMessage) { live.emailMessage = next.emailMessage }

  // Reconcile the positions that already exist, in place, so the components
  // rendering them keep pointing at a node that is still being updated.
  let shared = live.children.length < next.children.length
    ? live.children.length : next.children.length
  for (let i = 0; i < shared; i++) {
    reconcile(live.children[i], next.children[i], fieldValue)
  }
  if (live.children.length === next.children.length) { return }

  // The length did change, so the array has to be reassigned -- @Trace sees a
  // field being written, not an array being mutated, and without the write
  // ForEach never learns the list grew. The surviving nodes are carried over
  // by reference; only the tail is new.
  let kids: LiveNode[] = []
  for (let i = 0; i < shared; i++) { kids.push(live.children[i]) }
  for (let i = shared; i < next.children.length; i++) {
    let added = toLive(next.children[i])
    if (revealArmed && REVEALED_KINDS.indexOf(added.kind) >= 0) { added.reveal = true }
    kids.push(added)
  }
  live.children = kids
}

export function cloneLiveTree(node: LiveNode): LiveNode {
  let copy = new LiveNode()

  copy.layoutWidth = node.layoutWidth
  copy.layoutHeight = node.layoutHeight
  copy.kind = node.kind
  copy.style = node.style
  copy.text = node.text
  copy.source = node.source
  copy.alt = node.alt
  copy.action = node.action
  copy.eventValue = node.eventValue
  copy.enabled = node.enabled
  copy.commands = node.commands
  copy.spinPeriodMs = node.spinPeriodMs
  copy.motionStart = node.motionStart
  copy.label = node.label
  copy.tickerId = node.tickerId
  copy.columns = node.columns
  copy.value = node.value
  copy.checked = node.checked
  copy.minimum = node.minimum
  copy.maximum = node.maximum
  copy.options = node.options.slice()
  copy.series = node.series.slice()
  copy.bars = node.bars
  copy.series2 = node.series2.slice()
  copy.series2Style = node.series2Style
  copy.seriesLabel = node.seriesLabel
  copy.series2Label = node.series2Label
  copy.categories = node.categories.slice()
  copy.numberValue = node.numberValue
  copy.prefix = node.prefix
  copy.suffix = node.suffix
  copy.minimumDigits = node.minimumDigits
  copy.decimals = node.decimals
  copy.step = node.step
  copy.icon = node.icon
  copy.keyboardType = node.keyboardType
  copy.required = node.required
  copy.requiredMessage = node.requiredMessage
  copy.minLength = node.minLength
  copy.minLengthMessage = node.minLengthMessage
  copy.maxLength = node.maxLength
  copy.maxLengthMessage = node.maxLengthMessage
  copy.pattern = node.pattern
  copy.patternMessage = node.patternMessage
  copy.email = node.email
  copy.emailMessage = node.emailMessage
  copy.touched = node.touched
  copy.typed = node.typed
  copy.fieldValue = node.fieldValue
  copy.fieldIssue = node.fieldIssue
  copy.fieldGeneration = node.fieldGeneration
  copy.fieldCancellation = node.fieldCancellation
  copy.liveGeneration = node.liveGeneration
  copy.reveal = node.reveal
  copy.iconRoom = node.iconRoom

  let children: LiveNode[] = []
  for (let child of node.children) {
    children.push(cloneLiveTree(child))
  }
  copy.children = children

  return copy
}
