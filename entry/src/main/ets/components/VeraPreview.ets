/**
 * Runs one compiled VERA-L program and renders its UI tree as native ArkUI.
 *
 * Extracted from RunnerPage so the same renderer serves both surfaces: the
 * full-screen run from the project library, and the inline preview on the
 * Generate page that follows a program as it is refined.
 *
 * Feeding it a different vbc2 restarts the program: a fresh VM, fresh init()
 * state, fresh view. That is what makes a refined program replace the previous
 * one in place.
 */

import { VeraUiNode, formatVeraNumber, formatVeraClock, formatVeraDate, unitAfter, keepUnits } from '../vera/VeraUi'
import { veraStateStamp } from '../vera/VeraStateStamp'
import { scheduleCardRefresh } from '../vera/FormUpdater'
import { LengthMetrics, mediaquery, matrix4 } from '@kit.ArkUI'

import { catalogKinds } from '../vera/VeraUiCatalog'
import { iconPath, ICON_STROKE, ICON_VIEWPORT, ICON_ORIGIN } from '../vera/VeraIcons'
import { ResolvedTheme, resolveTheme, containerFill, toneFill, toneEdge, toneInk,
  textSize, textWeight, textInk, buttonFill, buttonInk, pathFill, densityPad,
  densityGap, spacerSize, readableInk } from '../vera/VeraTheme'
import { LiveNode, toLive, cloneLiveTree, reconcile, armReveal, markIconRoom } from './VeraLiveTree'
import { MotionPose, motionPose, motionDuration, pivotPercent, poseMatrix, poseFromArray, multiplyMatrices, perspectiveMatrix,
  columnMajor, poseToPixels, samePose, animatedPose, TRANSFORM_DISTANCE, MOTION_BUDGET_MS } from '../vera/VeraMotion'
import { displaySync } from '@kit.ArkGraphics2D'
import { paintGfx, gfxFit, gfxToSurface, gfxNaturalHeight, GfxOp } from '../vera/GfxPaint'
import { TimerFace, timerFace } from '../widget/CardModel'
import { WorldSpec } from '../vera/VeraScene'
import { worldBackgroundRgba, isDarkRgba } from '../vera/VeraLook3D'
import { WorldBox, WorldPick, WorldGesture, playerOf } from './VeraWorld3D'
import { SimEvent } from '../vera/VeraPhysics'
import { StageTrace } from '../runtime/trace/StageTrace'
import { InProcessHost, HostOperationFailure } from '../runtime/InProcessHost'
import { ProgramRef, AcquireOptions, EffectRequest, ActorHandle, AppSubscriber, FrameEnvelope,
  InputPayload, InputEvent, DrawRequest, TickEvent, SurfaceFrameEvent, AdmissionResult } from '../runtime/shared/Messages'
import { HostEffectsBridge, HostEffectsBinding, EffectResultHost } from '../runtime/HostEffectsBridge'
import { effectConsentTitle, effectConsentValues } from '../runtime/EffectController'

function numberPayload(value: number): InputPayload {
  return { kind: 'NUMBER', num: value, str: '', bool: false, phase: '', id: 0, x: 0, y: 0 }
}

function stringPayload(value: string): InputPayload {
  return { kind: 'STRING', num: 0, str: value, bool: false, phase: '', id: 0, x: 0, y: 0 }
}

function booleanPayload(value: boolean): InputPayload {
  return { kind: 'BOOLEAN', num: 0, str: '', bool: value, phase: '', id: 0, x: 0, y: 0 }
}

function pointerPayload(phase: string, id: number, x: number, y: number): InputPayload {
  return { kind: 'POINTER', num: 0, str: '', bool: false, phase: phase, id: id, x: x, y: y }
}

function scenePayload(kind: string, body: string, other: string, x: number, y: number, z: number,
    speed: number, bodies: string[], values: number[]): InputPayload {
  return { kind: 'SCENE', num: 0, str: '', bool: false, phase: '', id: 0, x: 0, y: 0,
    scene: { kind: kind, body: body, other: other, x: x, y: y, z: z, speed: speed,
      bodies: bodies, values: values } }
}

class PreviewSubscriber implements AppSubscriber {
  private viewFrame: (frame: FrameEnvelope) => void
  private errorHandler: (kind: string, message: string, inputSeq?: number) => void
  private stateSnapshot: (encoded: string) => void
  private stateSaved: (projectId: string) => void
  private effectRequest: (effect: EffectRequest) => void
  private flushInput: (appId: string) => void | Promise<void>
  private mailboxWritable: () => void

  constructor(
    viewFrame: (frame: FrameEnvelope) => void,
    errorHandler: (kind: string, message: string, inputSeq?: number) => void,
    stateSnapshot: (encoded: string) => void,
    stateSaved: (projectId: string) => void,
    effectRequest: (effect: EffectRequest) => void,
    flushInput: (appId: string) => void | Promise<void>,
    mailboxWritable: () => void
  ) {
    this.viewFrame = viewFrame
    this.errorHandler = errorHandler
    this.stateSnapshot = stateSnapshot
    this.stateSaved = stateSaved
    this.effectRequest = effectRequest
    this.flushInput = flushInput
    this.mailboxWritable = mailboxWritable
  }

  onViewFrame(frame: FrameEnvelope): void { this.viewFrame(frame) }
  onError(kind: string, message: string, inputSeq?: number): void {
    this.errorHandler(kind, message, inputSeq)
  }
  onStateSnapshot(encoded: string): void { this.stateSnapshot(encoded) }
  onStateSaved(projectId: string): void { this.stateSaved(projectId) }
  onEffectRequest(effect: EffectRequest): void { this.effectRequest(effect) }
  flushPendingInputFor(appId: string): void | Promise<void> { return this.flushInput(appId) }
  onMailboxWritable(): void { this.mailboxWritable() }
}

class PreviewEffectResultHost implements EffectResultHost {
  private postResult: (
    handle: ActorHandle,
    effectId: number,
    text: string
  ) => AdmissionResult

  constructor(
    postResult: (
      handle: ActorHandle,
      effectId: number,
      text: string
    ) => AdmissionResult
  ) {
    this.postResult = postResult
  }

  postEffectResult(
    handle: ActorHandle,
    effectId: number,
    text: string
  ): AdmissionResult {
    return this.postResult(handle, effectId, text)
  }
}

interface PreviewGfx {
  nodeId: number
  surfaceRevision: number
  ops: GfxOp[]
}

class PreviewPost {
  kind: string
  key: string = ''
  segment: number = 0
  order: number = 0
  action: FieldAction | null = null
  tick: TickEvent | null = null
  surface: SurfaceFrameEvent | null = null
  draws: DrawRequest[] = []
  constructor(kind: string) { this.kind = kind }
}

class PreviewWaiter {
  generation: number
  resolve: () => void
  reject: (error: Error) => void
  constructor(generation: number, resolve: () => void, reject: (error: Error) => void) {
    this.generation = generation; this.resolve = resolve; this.reject = reject
  }
}

/**
 * The rotation of every spinning shape on screen.
 *
 * Observed rather than @State: a nested @Builder is not re-invoked when plain
 * component state changes, but it is re-invoked when a @Trace field it reads is
 * mutated. Advancing this from a timer therefore redraws the shapes without the
 * VM, the program or its state being involved at all.
 */
@ObservedV2
class SpinAngle {
  @Trace angle: number = 0
}

/**
 * The clock of every ui.Motion on screen: the current time, advanced from a timer while any animation is running.
 * Observed for the same reason SpinAngle is: the motion branch of renderNode reads it, so mutating it redraws that branch.
 */
@ObservedV2
class MotionClock {
  @Trace now: number = 0
}

/** The glide of one ui.Transform: from the pose it had when the program changed its numbers to the new ones. */
class PoseAnim {
  from: number[]
  to: number[]
  start: number
  duration: number
  constructor(from: number[], to: number[], start: number, duration: number) {
    this.from = from; this.to = to; this.start = start; this.duration = duration
  }
}

class FieldEdit {
  value: string
  base: string
  action: string
  generation: number
  timer: number = -1
  sequence: number = 0
  composing: boolean = false
  commitRequested: boolean = false
  constructor(node: LiveNode, value: string) {
    this.value = value
    this.base = node.value
    this.action = node.action
    this.generation = node.fieldGeneration
  }
}

class FieldInput {
  generation: number
  controller: TextInputController = new TextInputController()
  constructor(generation: number) {
    this.generation = generation
  }
}

class FieldAction {
  traceKind: string = 'HANDLER'
  inputSeq: number = -1
  order: number = 0
  posting: boolean = false
  tickerId: string = ''
  fieldNode: LiveNode | null = null
  action: string
  payload: InputPayload
  generation: number
  persist: boolean
  node: LiveNode | null
  nodeGeneration: number
  nodeKind: string
  nodeState: string = ''
  dependencies: LiveNode[] = []
  unknownDependencies: boolean = true
  dependencyCancellations: number[] = []
  surfaceInput: SurfaceInput | null = null
  surfaceId: number = -1
  constructor(action: string, payload: InputPayload, generation: number,
    persist: boolean = true, node: LiveNode | null = null) {
    this.action = action
    this.payload = payload
    this.generation = generation
    this.persist = persist
    this.node = node
    this.nodeGeneration = node !== null ? node.fieldGeneration : -1
    this.nodeKind = node !== null ? node.kind : ''
  }
}

class SurfaceInput {
  action: string
  generation: number
  nodeGeneration: number
  ended: boolean = false
  constructor(node: LiveNode, generation: number) {
    this.action = node.value
    this.generation = generation
    this.nodeGeneration = node.fieldGeneration
  }
}

class TimerConfig {
  interval: number
  action: string
  constructor(interval: number, action: string) {
    this.interval = interval
    this.action = action
  }
}

/** Tickers at or above this interval are state/lifecycle events and must observe pending text edits. */
const SLOW_TICK_MS: number = 500
/** The longest a frame says has passed, in ms, so a pause -- the app in the background, a slow frame -- is not a leap. */
const SURFACE_MAX_ELAPSED_MS: number = 100
/**
 * The most world events (hits, settling) that reach the program in one frame: each is a VM call and, when it changes the
 * state, a build and a view refresh. Hits come at most four a second already (HIT_INTERVAL_S).
 */
const WORLD_EVENTS_PER_FRAME: number = 4
/** The stick over a world with a player: its size and its knob's, in vp. */
const STICK_SIZE: number = 128
const STICK_KNOB: number = 56

/** "#rrggbb" as "#aarrggbb" with this alpha (0..255); any other colour as it is. */
function withAlpha(color: string, alpha: number): string {
  if (!/^#[0-9a-fA-F]{6}$/.test(color)) { return color }
  let a = Math.max(0, Math.min(255, Math.round(alpha))).toString(16)
  return '#' + (a.length < 2 ? '0' + a : a) + color.substring(1)
}

/** Whether a moving part's trigger is the one it last had: NaN (a trigger worked out as math.sqrt of a negative number) is the same as NaN, or it would restart every paint. */
function sameTrigger(a: number, b: number): boolean {
  return a === b || (Number.isNaN(a) && Number.isNaN(b))
}

/** One ui.Surface on screen: the canvas it paints into and the box it was given, in vp. */
class SurfaceBox {
  ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true))
  ready: boolean = false
  width: number = 0
  height: number = 0
  // Some of it is on screen. One scrolled away keeps its frame handler running but is neither drawn nor painted.
  visible: boolean = true
  // Its moving parts (gfx.moving), by their order in the drawing: the trigger each was last drawn with and when each began to play (ms;
  // never, for one that has not). A touch on the picture plays them all: touchedAt, and the touch they last began on.
  partTriggers: number[] = []
  partStarts: number[] = []
  touchedAt: number = 0
  touchSeen: number = 0
  // It has a drift (gfx.drift): it moves on and on, so it is painted on every tick while it is on screen.
  drifting: boolean = false
}

/**
 * The look the running program asked for.
 *
 * Observed for the same reason SpinAngle is: the branches of renderNode are
 * built once and retained, so a plain field they read would never redraw them
 * if a program switched preset from its own state.
 *
 * One traced field, holding the whole table, replaced whole. That is the same
 * move reconcile makes on `children`: @Trace notices a field being *written*,
 * so swapping the object in is one notification for the one fact that matters
 * -- the theme changed -- rather than the fifty a traced field per value would
 * need to say it. The two strings beside it are plain: they exist only so an
 * unchanged frame can tell it has nothing to write.
 */
@ObservedV2
class LiveTheme {
  @Trace resolved: ResolvedTheme = resolveTheme('clean', '', false)
  preset: string = 'clean'
  primary: string = ''
  dark: boolean = false
}

/**
 * Whether a call is shown to the person before it runs.
 *
 * Off by request: a program that blinks the torch every two seconds cannot ask
 * about every flash, and a demo that stops on a dialog is not a demo. On, it
 * asks once per program and per call and remembers the answer.
 */
const ASK_BEFORE_CALLS: boolean = false

/**
 * One bar of a ui.Sparkline drawn with bars: true -- its height in vp, the category name under it
 * and its value over it. Built once per frame by VeraPreview.barItems and handed to a ForEach, so
 * the item builder reads nothing but the item's own fields (see the comment at the ForEach for why
 * that matters).
 */
class BarItem {
  height: number = 0
  label: string = ''
  value: string = ''
}

/** The tallest a pane of ui.Tabs grows in a chat reply, in vp; past it the pane scrolls inside the window. */
const EMBEDDED_WINDOW: number = 360

/** The height of the band a lone ui.Path is centred in. */
const PATH_BAND_HEIGHT: number = 240

/** How far into the program, in vp, it still counts as at its top: the host's corner buttons stay shown. */
const READING_TOP: number = 40


/** Nodes a button's form does not reach past (touchFormOf). */
const FORM_BOUNDS: string[] = ['section', 'card', 'sheet', 'dialog']

/**
 * A TileGrid's tiles in rows: a tile of span 2 alone, the others two at a time. What is not a tile (a ui.When that is off draws
 * a spacer) takes no place, so it leaves no hole in a pair.
 */
function tileRows(children: LiveNode[]): LiveNode[][] {
  let rows: LiveNode[][] = []
  let open: LiveNode[] = []
  for (let child of children) {
    if (child.kind !== 'tile') { continue }
    if (child.columns >= 2) {
      if (open.length > 0) { rows.push(open); open = [] }
      rows.push([child])
      continue
    }
    open.push(child)
    if (open.length === 2) { rows.push(open); open = [] }
  }
  if (open.length > 0) { rows.push(open) }
  return rows
}

export class VeraPreviewController {
  private capture: (() => Promise<string>) | null = null

  attach(capture: () => Promise<string>): void {
    this.capture = capture
  }

  detach(capture: () => Promise<string>): void {
    if (this.capture === capture) { this.capture = null }
  }

  flushAndSnapshot(): Promise<string> {
    if (this.capture === null) { return Promise.reject(new Error('Preview is not attached')) }
    return this.capture!()
  }
}

@Component
export struct VeraPreview {
  controller: VeraPreviewController | null = null
  private captureFields: () => Promise<string> = (): Promise<string> => {
    let generation = this.acquireGeneration
    let loadGeneration = this.loadGeneration
    let capture = this.operations.then(async (): Promise<string> => {
      if (this.disposed || generation !== this.acquireGeneration || loadGeneration !== this.loadGeneration || this.previewOnly ||
          this.activeOptions.mode === 'PREVIEW' || this.handle === null) {
        throw new Error('Preview is not active')
      }
      let handle = this.handle!
      await this.flushPendingInputFor(this.frameAppId)
      if (this.handle !== handle || generation !== this.acquireGeneration || loadGeneration !== this.loadGeneration || this.disposed) {
        throw new Error('Preview was released')
      }
      let encoded = await this.runtime.requestSnapshot(handle)
      if (this.handle !== handle || generation !== this.acquireGeneration || loadGeneration !== this.loadGeneration || this.disposed) {
        throw new Error('Preview was released')
      }
      return encoded
    })
    this.operations = capture.then((): void => {}, (_error: Error): void => {})
    return capture
  }

  /**
   * The program is a picture of one still being written (VeraWidgetPreview):
   * its handlers may not exist yet, so nothing dispatches -- no taps, no
   * tickers, no back gesture -- and nothing is saved or reported. Declared
   * before vbc2 so it has its new value by the time a new program loads; the
   * watch covers the other order too.
   */
  @Prop @Watch('onPreviewOnlyChanged') previewOnly: boolean = false
  @Prop @Watch('onProgramChanged') vbc2: string = ''
  /**
   * Where to keep this program's state, as 'projectId/versionId'. Empty means
   * ephemeral: the Generate screen's preview is a scratch pad and must not
   * accumulate a record, while a program opened from the library is the real
   * thing and has to remember.
   */
  @Prop persistKey: string = ''
  /**
   * The state of the program this one replaces, as onStateSnapshot gave it: when no saved state is restored, what it held
   * is carried into the new program's fresh state (carryState), so a refine does not wipe what the person typed.
   */
  @Prop seedState: string = ''
  @StorageProp('veraResume') @Watch('onResume') resumeSignal: number = 0
  @StorageProp('veraForeground') appForeground: boolean = true

  onResume(): void {
    if (this.disposed || this.previewOnly) { return }
    this.queuePost(new PreviewPost('REFRESH'))
  }

  /** Read-only snapshot for a hosting chat. It does not migrate state between programs. */
  onStateSnapshot: (encoded: string) => void = (_encoded: string): void => {}
  /**
   * Told when the program is being read further down (true) or back towards its top (false), for a host that lays buttons
   * over the program's corner: they cover its rows while it scrolls, so the host hides them on the way down.
   */
  onReadingDown: (down: boolean) => void = (_down: boolean): void => {}
  private readingDown: boolean = false
  /**
   * Drawn inside something that scrolls, such as a chat message: the program
   * takes the height it needs and has no scrolling of its own.
   */
  @Prop embedded: boolean = false
  /**
   * Room kept under the program, in vp, so that its last rows can be scrolled clear of something the host lays over its
   * bottom corner (the full-screen button). Not used when embedded.
   */
  @Prop bottomRoom: number = 0
  /**
   * Bumped by the hosting page's onBackPressed() every time the system back
   * gesture should be handed to the program. A counter rather than a boolean:
   * the value itself carries no meaning, only the fact that it changed, so two
   * back-presses in a row -- the normal case -- are both seen.
   */
  @Prop @Watch('onBackPressSignal') backPressSignal: number = 0
  /**
   * Set by the hosting page's NavDestination.onHidden() and cleared its onShown(): while another destination
   * covers this one, the surface frame loop stops instead of drawing underneath it and halving the top screen's
   * frame rate. A plain boolean is enough -- unlike backPressSignal it is a state, not an event.
   */
  @Prop @Watch('onDestinationHidden') destinationHidden: boolean = false
  /**
   * Told whether a ui.BackHandler is currently part of the tree, so the
   * hosting page's onBackPress() can return the right thing synchronously --
   * swallow the gesture and bump backPressSignal, or let the system handle it
   * (pop the page, in RunnerPage's case) -- without waiting on a dispatch.
   * A plain field, not @Prop: a callback's identity never changes, so there is
   * nothing here for ArkUI to watch.
   */
  onBackHandlerChanged: (active: boolean) => void = () => {}
  private backHandlerAction: string = ''
  // The live tree is mutated in place, so it is not @State: its own @Trace
  // fields are what drive the re-render. See VeraLiveTree.
  @State hasRoot: boolean = false
  /** Bumped when a typed number is taken, so its field is drawn again with the value the program holds. */
  @State numberEpoch: number = 0

  private fieldEdits: Map<LiveNode, FieldEdit> = new Map<LiveNode, FieldEdit>()
  private fieldInputs: Map<LiveNode, FieldInput> = new Map<LiveNode, FieldInput>()
  private fieldActions: FieldAction[] = []
  private fieldMenus: Map<LiveNode, FieldAction[]> = new Map<LiveNode, FieldAction[]>()
  private surfaceInputs: Map<LiveNode, Map<number, SurfaceInput>> =
    new Map<LiveNode, Map<number, SurfaceInput>>()
  private resumingFieldActions: boolean = false
  private fieldActionsNeedResume: boolean = false
  private renderingDepth: number = 0
  private liveRoot: LiveNode | null = null
  /** Current membership epoch for nodes reachable from liveRoot. */
  private liveGeneration: number = 0

  /**
   * Which program liveRoot belongs to, bumped by every load(). The drawn tree
   * is keyed by it: load() replaces liveRoot with a new object and flips
   * hasRoot false and back to true within one frame, which ArkUI sees as no
   * change at all, so without the key the old program's tree stayed on screen
   * while every later reconcile updated the new one nobody was drawing. That
   * is what a chat preview handing over to its finished program looked like:
   * taps ran, state changed, the screen did not.
   */
  @State programId: number = 0
  /**
   * A frame counter for the logs, and nothing more -- build() does not read it,
   * so writing it triggers no re-render. It is not @State for that reason: it
   * used to key a ForEach that recreated the whole tree on every action, and
   * leaving it looking like state invited the assumption that the safety net is
   * still there. It is not; correctness now rests entirely on reconcile keeping
   * node identity.
   */
  private revision: number = 0
  @State error: string = ''
  private viewError: string = ''
  private runtime: InProcessHost = InProcessHost.get()
  private handle: ActorHandle | null = null
  private subscriber: AppSubscriber | null = null
  private operations: Promise<void> = Promise.resolve()
  private acquireGeneration: number = 0
  private loadGeneration: number = 0
  private subscriberGeneration: number = 0
  private draining: boolean = false
  private mountRequested: boolean = false
  private transitioning: boolean = false
  private activeProgram: string = ''
  private activeOptions: AcquireOptions = { mode: 'PREVIEW', persistKey: '', seedState: '' }
  private frameAppId: string = ''
  private frameVmGeneration: number = 0
  private lastFrameSeq: number = 0
  private lastAppliedSeq: number = 0
  private observedErrors: Set<number> = new Set<number>()
  private inFlight: FieldAction | null = null
  private deferredFrames: FrameEnvelope[] = []
  private postDrain: boolean = false
  private postEdits: boolean = false
  private postingEffect: boolean = false
  private posts: PreviewPost[] = []
  private postSegment: number = 0
  private nextOrder: number = 0
  private posting: boolean = false
  private admissionBlocked: boolean = false
  private waiters: PreviewWaiter[] = []
  private flushFailure: Error | null = null
  private effectsBinding: HostEffectsBinding | null = null
  private traceOwner: Object = new Object()
  /** The program's own scroll (not in a chat, where the chat scrolls) and where it sits, in vp, for revealIfAsked. */
  private rootScroller: Scroller = new Scroller()
  private rootTop: number = 0
  private rootHeight: number = 0
  /** Where the program's content column sits and how tall it is with its bottom padding, in vp: what a "fill" box leaves under it. */
  private contentTop: number = 0
  private contentHeight: number = 0
  /** Each "fill" surface or world and where it last was ([top, height] in vp), so it is fitted again when what is under it changes. */
  private fillBoxes: Map<LiveNode, number[]> = new Map<LiveNode, number[]>()
  private fillRefit: boolean = false
  /**
   * The world drawn over the whole program, or null: its corner button opened it, or its style "full" did when the
   * program started. Its Header is left out and the program's other things -- the result, the buttons -- float over its
   * bottom; the corner button brings the normal screen back.
   */
  private fullWorld: LiveNode | null = null
  /** Bumped whenever fullWorld changes: a LiveNode (@ObservedV2) cannot be @State, so this redraws the frame instead. */
  @State fullWorldEpoch: number = 0
  /** Whether what is behind the full-screen world is dark: its title and caption are then drawn light. */
  @State fullWorldDark: boolean = false
  /** The program whose "full" world has been opened: closing it is the person's choice, kept until the program changes. */
  private fullOpenedFor: number = -1
  /** How tall the snackbars drawn over the bottom of the window are, in vp: the content ends that far above it (programFrame). */
  @State snackSpace: number = 0
  /**
   * Set when the screen goes away. An intent answers long after the tap, and
   * without this a late answer would re-enter a VM that is no longer there.
   */
  private disposed: boolean = false
  private effectGeneration: number = 0
  // Live tickers, keyed by the program's own id for each: handle, interval and
  // the moment of the last fire, so a handler can be told how long really passed.
  private timers: Map<string, number> = new Map<string, number>()
  private timerConfigs: Map<string, TimerConfig> = new Map<string, TimerConfig>()
  private timerLastFire: Map<string, number> = new Map<string, number>()
  private spin: SpinAngle = new SpinAngle()
  private theme: LiveTheme = new LiveTheme()
  /**
   * Whether the phone is in dark mode.
   *
   * The program is not asked and cannot say. A generated app holding a white
   * screen up at someone whose phone is dark is the app being wrong, and it is
   * not a judgement the program is in a position to make -- view() is a pure
   * function of state and has no way to see the phone. So the renderer follows
   * the system, and the preset supplies the dark palette that keeps the app
   * looking like itself.
   */
  private dark: boolean = false
  private darkListener: mediaquery.MediaQueryListener | null = null
  /**
   * How wide this renderer actually is, in vp.
   *
   * Measured from the box it is drawn in, not from the display. The two are not
   * the same and the difference showed: this component serves both the
   * full-screen run and the Generate page's inline preview, and sizing columns
   * by the display width put three metrics in a preview box wide enough for
   * two, so "1020 kg" wrapped onto a second line.
   *
   * @State because it arrives after the first frame: the first layout uses what
   * the program asked for, the measurement comes back, and the count is
   * corrected.
   */
  @State viewportWidth: number = 0
  /**
   * A ui.Sparkline's own plotting box width, measured directly on its own
   * Shape (see chartWidth's own comment on why not viewportWidth). @State
   * for the same reason viewportWidth is: the first frame draws at a guess,
   * the real area arrives after layout, and the chart redraws at its actual
   * size once it does.
   */
  @State sparklineWidth: number = 0
  /** Width of the y-axis caption column, so the x-axis captions start where the plotting box does. */
  @State sparklineAxisWidth: number = 0
  @State canvasWidth: number = 0
  /**
   * The call waiting for the person to allow it, and the calls queued behind it.
   *
   * A generated program may ask the phone to do things it cannot undo, and
   * neither the program nor the model knows which of them matter -- an intent
   * that changes the volume and one that sends a message look alike from here.
   * So anything that changes something is shown to the person first, and this
   * is the one thing on the screen the program did not draw: it cannot style
   * it, word it, or press its buttons.
   *
   * @State because the dialog is part of the frame; the queue is not, because
   * nothing draws it.
   */
  @State pending: EffectRequest | null = null
  private effectsBridge: HostEffectsBridge | null = null
  private spinTimer: number = -1
  private motionClock: MotionClock = new MotionClock()
  private motionTimer: number = -1
  /** The trigger each Motion had when last seen, by its place in the tree; a change starts its animation. */
  private motionTriggers: Map<string, number> = new Map<string, number>()
  private poseAnims: Map<LiveNode, PoseAnim> = new Map<LiveNode, PoseAnim>()
  private spinPeriod: number = 0
  /**
   * The program's ui.Surfaces: each one's canvas by its node (reconcile keeps a node while it stays a surface),
   * the ones in the frame now, in tree order, and the frame loop that drives the ones with a frame handler.
   */
  private surfaces: Map<LiveNode, SurfaceBox> = new Map<LiveNode, SurfaceBox>()
  /**
   * The program's ui.Worlds: each one's 3D scene by its node. A world's build function runs once per state, in
   * renderView (reconcileWorlds), never per frame; what moves on its own -- orbits and spins -- is moved by the box on the
   * surface frame loop, which runs while any world needs it. Frames and pose-writing ms since the last VERA-WORLD line.
   */
  private worlds: Map<LiveNode, WorldBox> = new Map<LiveNode, WorldBox>()
  private scenes: Map<number, WorldSpec> = new Map<number, WorldSpec>()
  private nodeIds: Map<LiveNode, number> = new Map<LiveNode, number>()
  private pendingWorldStep: boolean = false
  private hadWorlds: boolean = false
  private worldProgram: string = ''
  private pendingWorldProgram: string | null = null
  private worldTransitionError: string = ''
  /** What the worlds told this frame and the node each came from, dispatched once the boxes have all stepped. */
  private worldEvents: SimEvent[] = []
  private worldEventNodes: LiveNode[] = []
  private worldFrames: number = 0
  private worldReportAt: number = 0
  /** Each ui.Timer's controller: the platform's TextTimer ticks by itself once started. */
  private textTimers: Map<LiveNode, TextTimerController> = new Map<LiveNode, TextTimerController>()
  private textTimerOf(node: LiveNode): TextTimerController {
    let known = this.textTimers.get(node)
    if (known !== undefined) { return known }
    let made = new TextTimerController()
    this.textTimers.set(node, made)
    return made
  }
  /** How the timer is set, as of now: counting up from the moment, or (checked) down to it. */
  private textTimerFace(node: LiveNode): TimerFace { return timerFace(node.numberValue, node.checked, Date.now()) }
  private liveSurfaces: LiveNode[] = []
  private surfaceRevision: number = 0
  private surfaceSignature: string = ''
  private surfaceSync: displaySync.DisplaySync | null = null
  private surfaceTimer: number = -1
  // Repaints the surfaces while a moving part plays on one with no frame loop of its own (a picture that only answers a touch).
  private partsTimer: number = -1
  private lastFrameAt: number = 0
  private surfaceLoopStartedAt: number | undefined = undefined
  /** Frames since the last VERA-SURFACE rate line, and the ms they spent in the program and painting, worst included. */
  private frameCount: number = 0
  private frameWork: number = 0
  private frameWorst: number = 0
  // Where the frames' time went since the last report: the frame handlers, draw() and its decoding, the painting,
  // and the view refreshes in between.
  private frameSplit: number[] = [0, 0, 0, 0]
  // The destination this preview is on is covered by another; its frame loop stops until the destination shows again.
  // Driven by the destinationHidden @Prop, set by the hosting page's onHidden()/onShown().
  private pageHidden: boolean = false
  private frameReportAt: number = 0

  // Kinds renderNode has a branch for. Checked against the catalogue on mount so
  // a component that compiles but cannot be drawn is reported here rather than
  // discovered as a blank space in someone's generated app.
  private static RENDERED: string[] = ['column', 'scroll', 'row', 'card', 'text',
    'button', 'cell', 'spacer', 'path', 'image', 'field', 'toggle', 'checkbox',
    'slider', 'select', 'tabs', 'divider', 'progress', 'progressring', 'ticker', 'grid', 'listitem', 'canvas',
    'apptheme', 'hero', 'adaptivecolumns', 'header', 'section', 'sectionheader', 'listgroup', 'banner',
    'emptystate', 'stat', 'metricgroup', 'tilegrid', 'tile',
    'numbertext', 'numberstat', 'numberfield', 'timefield', 'datefield', 'numberlistitem', 'actionbar',
    'kvgroup', 'kvitem', 'icon', 'iconbutton', 'badge', 'clocktext',
    'timeline', 'timelineitem', 'skeleton', 'timer', 'spinner', 'snackbar', 'sparkline', 'backhandler',
    'table', 'tablerow', 'motion', 'layers', 'transform', 'surface', 'world']

  aboutToAppear(): void {
    this.mountRequested = true
    if (this.draining) {
      this.operations.then((): void => {
        if (this.mountRequested && this.disposed) { this.aboutToAppear() }
      })
      return
    }
    this.surfaceSignature = ''
    this.surfaceRevision++
    this.frameAppId = ''
    this.frameVmGeneration = 0
    this.lastFrameSeq = 0
    this.lastAppliedSeq = 0
    this.activeProgram = ''
    this.admissionBlocked = false
    this.flushFailure = null
    this.disposed = false
    this.draining = false
    this.liveRoot = null
    this.hasRoot = false
    this.hadWorlds = false
    this.worldProgram = ''
    this.pendingWorldProgram = null
    this.worldTransitionError = ''
    this.programId++
    this.observedErrors.clear()
    this.acquireGeneration++
    this.subscriber = null
    this.pageHidden = this.destinationHidden
    let missing: string[] = []
    for (let kind of catalogKinds()) {
      if (VeraPreview.RENDERED.indexOf(kind) < 0) { missing.push(kind) }
    }
    if (missing.length > 0) {
      console.error('VERA-RENDER catalogue kinds with no render branch: ' + missing.join(','))
      this.error = 'Renderer is missing: ' + missing.join(', ')
    }
    this.watchDarkMode()
    this.load()
    if (this.controller !== null) { this.controller!.attach(this.captureFields) }
  }

  onProgramChanged(): void {
    // A new program is read from its top, and the host shows its corner again (GeneratePage.showCorner): the next scroll down
    // has to tell it again, which it would not while this still said "down".
    this.readingDown = false
    this.load()
  }

  onPreviewOnlyChanged(): void {
    this.load()
  }

  private actorOptions(): AcquireOptions {
    return {
      mode: this.previewOnly ? 'PREVIEW' : this.persistKey.length > 0 ? 'LIVE_PERSISTENT' : 'LIVE_EPHEMERAL',
      persistKey: !this.previewOnly ? this.persistKey : '',
      seedState: this.previewOnly ? '' : this.seedState
    }
  }

  private activationCurrent(generation: number): boolean {
    return generation === this.acquireGeneration && (!this.disposed || this.draining)
  }

  private createSubscriber(generation: number): AppSubscriber {
    let subscriberGeneration = ++this.subscriberGeneration
    let current = (): boolean =>
      this.activationCurrent(generation) &&
      subscriberGeneration === this.subscriberGeneration

    return new PreviewSubscriber(
      (frame: FrameEnvelope): void => {
        if (current()) { this.acceptFrame(frame) }
      },

      (kind: string, message: string, inputSeq?: number): void => {
        if (!current()) { return }
        if (inputSeq !== undefined) { this.observedErrors.add(inputSeq) }
        let viewFailure = kind.toUpperCase() === 'VIEW'
        this.worldTransitionError = ''
        this.viewError = viewFailure ? message : ''
        if (!this.disposed) {
          this.error = message
          if (kind.toUpperCase() !== 'INIT' && !viewFailure) { this.stopAllTimers('TRAP') }
        }
        if (!viewFailure) { this.flushFailure = new Error(message) }
        this.completeInput()
        this.syncEditGate()
        this.scheduleFieldActions()
      },

      (encoded: string): void => {
        if (current() && !this.disposed) { this.onStateSnapshot(encoded) }
      },

      (projectId: string): void => {
        if (current()) { scheduleCardRefresh(projectId) }
      },

      (effect: EffectRequest): void => {
        if (!current() || this.disposed || this.effectsBinding === null) { return }
        this.effectsBinding!.onEffectRequest(effect)
      },

      (appId: string): void | Promise<void> => current()
        ? this.flushPendingInputFor(appId)
        : Promise.reject(new Error('Preview activation changed')),

      (): void => {
        if (!current()) { return }
        this.admissionBlocked = false
        this.resumeFieldActions()
        this.resumePosts()
        if (this.effectsBridge !== null) { this.effectsBridge!.onMailboxWritable() }
        this.syncEditGate()
      }
    )
  }

  private async configure(generation: number, loadGeneration: number): Promise<void> {
    if (!this.activationCurrent(generation) || this.disposed || loadGeneration !== this.loadGeneration) { return }
    let program: ProgramRef = { vbc2: this.vbc2, stamp: this.stamp() }
    let options = this.actorOptions()
    if (this.handle !== null && this.activeProgram === program.vbc2 &&
        this.activeOptions.mode === options.mode && this.activeOptions.persistKey === options.persistKey) {
      this.flushFailure = null
      this.admissionBlocked = false
      this.transitioning = false
      let binding = this.bridge().beginBinding(program.stamp)
      this.effectsBinding = binding
      binding.bind(this.handle!)
      this.queuePost(new PreviewPost('VIEW'))
      this.syncEditGate()
      return
    }
    let originalHadWorlds = this.hadWorlds || this.worlds.size > 0
    let originalWorldsRunnable = !this.worldErrorBlocks()
    let original = this.handle
    let originalProgram = this.activeProgram
    let originalOptions = this.activeOptions
    let originalAppId = this.frameAppId
    let originalGeneration = this.frameVmGeneration
    let originalFrameSeq = this.lastFrameSeq
    let originalAppliedSeq = this.lastAppliedSeq
    let originalReleased = false
    let originalInvalid = false
    this.transitioning = true
    this.stopAllTimers('REPLACE')
    this.posts = []
    this.admissionBlocked = false
    this.flushFailure = null
    this.lastAppliedSeq = 0
    this.lastFrameSeq = 0
    this.observedErrors.clear()
    this.activeProgram = program.vbc2
    this.activeOptions = options
    this.pendingWorldProgram = this.worldProgram !== program.vbc2 ? program.vbc2 : null
    this.worldTransitionError = ''
    this.error = ''
    this.viewError = ''
    let binding = this.bridge().beginBinding(program.stamp)
    this.effectsBinding = binding
    this.syncEditGate()
    try {
      let next: ActorHandle
      if (original === null) {
        if (this.subscriber === null) { this.subscriber = this.createSubscriber(generation) }
        next = await this.runtime.acquire(options.mode === 'LIVE_PERSISTENT' ? options.persistKey : '',
          program, options, this.subscriber!)
      } else {
        try {
          try {
            next = await this.changeRuntime(original, program, options, originalProgram, originalOptions)
          } catch (e) {
            if ((e as HostOperationFailure).code !== 'INVALID_HANDLE') { throw e as Error }
            originalInvalid = true
            if (this.handle === null || this.handle === original) { throw e as Error }
            original = this.handle!
            originalInvalid = false
            try {
              next = await this.changeRuntime(original, program, options, originalProgram, originalOptions)
            } catch (retryError) {
              originalInvalid = (retryError as HostOperationFailure).code === 'INVALID_HANDLE'
              throw retryError as Error
            }
          }
        } catch (e) {
          if ((e as HostOperationFailure).code === 'APP_ID_CONFLICT') {
            originalReleased = true
            this.handle = null
            try {
              await this.runtime.release(original, {
                saveState: originalOptions.mode !== 'PREVIEW' && (originalHadWorlds || this.liveSurfaces.length > 0)
              })
            } catch (releaseError) {
              console.error('VERA-RENDER conflict release failed: ' + (releaseError as Error).message)
            }
            if (!this.activationCurrent(generation) || this.disposed) { throw new Error('Preview was released') }
            this.subscriber = this.createSubscriber(generation)
            this.frameAppId = ''
            this.frameVmGeneration = 0
            this.lastFrameSeq = 0
            this.lastAppliedSeq = 0
            this.observedErrors.clear()
            next = await this.runtime.acquire(options.mode === 'LIVE_PERSISTENT' ? options.persistKey : '',
              program, options, this.subscriber!)
          } else { throw e as Error }
        }
      }
      if (!this.activationCurrent(generation) || this.disposed) {
        binding.failBinding()
        if (generation === this.acquireGeneration) { this.handle = null }
        try {
          await this.runtime.release(next, {
            saveState: generation === this.acquireGeneration &&
              (this.hadWorlds || this.worlds.size > 0 || this.liveSurfaces.length > 0) && options.mode !== 'PREVIEW'
          })
        } catch (e) {
          console.error('VERA-RENDER late release failed: ' + (e as Error).message)
        }
        return
      }
      if (this.pendingWorldProgram !== null) { this.commitWorldProgram(this.pendingWorldProgram!) }
      this.handle = next
      binding.bind(next)
    } catch (e) {
      binding.failBinding()
      if (this.activationCurrent(generation)) {
        this.handle = originalReleased || originalInvalid ? null : original
        this.activeProgram = originalProgram
        this.activeOptions = originalOptions
        this.pendingWorldProgram = null
        this.hadWorlds = originalHadWorlds
        this.frameAppId = originalReleased || originalInvalid ? '' : originalAppId
        this.frameVmGeneration = originalReleased || originalInvalid ? 0 : originalGeneration
        this.lastFrameSeq = originalReleased || originalInvalid ? 0 : originalFrameSeq
        this.lastAppliedSeq = originalReleased || originalInvalid ? 0 : originalAppliedSeq
        if (originalInvalid) {
          this.subscriber = null
          this.subscriberGeneration++
          this.observedErrors.clear()
        }
        if (original !== null && !originalInvalid && (!originalReleased || !this.disposed)) {
          let restoredBinding = this.bridge().beginBinding(veraStateStamp(originalProgram))
          this.effectsBinding = restoredBinding
          try {
            if (originalReleased) {
              this.subscriber = this.createSubscriber(generation)
              let restored = await this.runtime.acquire(originalAppId,
                { vbc2: originalProgram, stamp: veraStateStamp(originalProgram) }, originalOptions, this.subscriber!)
              if (!this.activationCurrent(generation) || this.disposed) {
                restoredBinding.failBinding()
                await this.runtime.release(restored, { saveState: false })
              } else { this.handle = restored; restoredBinding.bind(restored) }
            } else { restoredBinding.bind(original) }
          } catch (restoreError) {
            restoredBinding.failBinding()
            this.handle = null
            console.error('VERA-RENDER conflict recovery failed: ' + (restoreError as Error).message)
          }
        }
        this.flushFailure = e as Error
        this.syncEditGate()
        if (this.handle !== null) {
          this.flushFailure = null
          if (!this.disposed) { this.queuePost(new PreviewPost('VIEW')) }
        }
        if (!this.disposed) {
          this.error = (e as Error).message
          this.worldTransitionError = this.handle !== null && originalWorldsRunnable ? this.error : ''
        }
      }
    } finally {
      if (generation === this.acquireGeneration && loadGeneration === this.loadGeneration) {
        this.transitioning = false
        this.syncEditGate()
        this.resumeFieldActions()
        this.resumePosts()
      }
    }
  }

  private changeRuntime(handle: ActorHandle, program: ProgramRef, options: AcquireOptions,
      previousProgram: string, previousOptions: AcquireOptions): Promise<ActorHandle> {
    if (previousProgram !== program.vbc2 || (options.mode === 'PREVIEW' && previousOptions.mode !== 'PREVIEW')) {
      return this.runtime.replaceProgram(handle, program, options)
    }
    return this.runtime.promote(handle, options.mode, options.persistKey)
  }

  /**
   * Follow the system's light/dark setting, and keep following it.
   *
   * A listener rather than a one-off read, so the app turns over while it is on
   * screen instead of only at launch. Wrapped because a media query is not
   * worth failing to draw over: if it is unavailable the app stays light, which
   * is what it has always been.
   */
  private watchDarkMode(): void {
    try {
      let listener = this.getUIContext().getMediaQuery().matchMediaSync('(dark-mode: true)')
      this.dark = listener.matches
      listener.on('change', (result: mediaquery.MediaQueryResult) => {
        if (this.disposed || result.matches === this.dark) { return }
        this.dark = result.matches
        // The palette is chosen in reconcileTheme, off the frame, so the way to
        // repaint is to ask for a frame.
        this.queuePost(new PreviewPost('VIEW'))
      })
      this.darkListener = listener
    } catch (e) {
      StageTrace.emit(this.traceOwner, 'ERROR', { kind: 'DARK_MODE' })
      this.dark = false
      console.info('VERA-RENDER dark mode unavailable: ' + (e as Error).message)
    }
  }

  private invalidateEffects(): void {
    this.cancelFields()
    this.effectGeneration += 1
    this.inFlight = null
    this.deferredFrames = []
    this.postDrain = false
    this.postEdits = false
    if (this.effectsBridge !== null) { this.effectsBridge!.invalidate() }
    this.effectsBinding = null
    if (!this.disposed) { this.pending = null }
    this.syncEditGate()
  }

  private load(): void {
    if (this.disposed || this.draining) { return }
    let generation = this.acquireGeneration
    let loadGeneration = ++this.loadGeneration
    this.transitioning = true
    this.flushFailure = new Error('Preview activation changed')
    this.posts = []
    this.invalidateEffects()
    this.stopAllTimers('REPLACE')
    this.syncEditGate()
    this.operations = this.operations.then(() => this.configure(generation, loadGeneration)).catch((error: Error): void => {
      if (this.activationCurrent(generation) && loadGeneration === this.loadGeneration && !this.disposed) {
        this.transitioning = false
        this.flushFailure = error
        this.error = error.message
        this.syncEditGate()
      }
    })
  }

  /**
   * Start, stop and re-time the program's tickers to match the frame just
   * produced.
   *
   * Identity comes from the id the program chose, not from a node position: a
   * conditional subtree shifts every later node, and a ticker that changed
   * identity every frame would be cancelled and restarted forever.
   *
   * A running ticker is left strictly alone unless its interval changed --
   * restarting it on each state change would reset its phase, so a one-second
   * ticker under a stream of taps would never reach a full second.
   */
  private reconcileTimers(root: VeraUiNode | null): void {
    let wanted = new Map<string, TimerConfig>()
    if (root !== null) { this.collectTickers(root!, wanted) }

    let live = Array.from(this.timers.keys())
    for (let id of live) {
      let want = wanted.get(id)
      let current = this.timerConfigs.get(id)
      if (want === undefined || current === undefined || want.interval !== current.interval) {
        this.stopTimer(id)
      }
    }
    let ids = Array.from(wanted.keys())
    for (let id of ids) {
      let config = wanted.get(id) as TimerConfig
      if (this.timers.has(id)) {
        this.timerConfigs.set(id, config)
        continue
      }
      this.startTimer(id, config)
    }
  }

  /**
   * Keep the shared rotation running for as long as any shape asks to spin.
   *
   * The angle is advanced here rather than by the program: rotation is
   * decoration, and routing it through the VM would make every frame a state
   * transition and a saved snapshot.
   */
  private reconcileSpin(root: VeraUiNode | null): void {
    let period = root !== null ? this.findSpinPeriod(root!) : 0
    if (period === this.spinPeriod) { return }
    this.spinPeriod = period
    if (this.spinTimer >= 0) { clearInterval(this.spinTimer); this.spinTimer = -1 }
    if (period <= 0) { this.spin.angle = 0; return }
    let step = 360 * 50 / period
    this.spinTimer = setInterval(() => {
      this.spin.angle = (this.spin.angle + step) % 360
    }, 50)
  }

  /**
   * Start the arrival animation of every Motion whose trigger changed and the glide of every Transform whose pose changed, and
   * keep the clock running until the last one ends.
   *
   * The first time either is seen it only records itself, so a screen never animates on opening. A Motion's identity is its
   * place in the tree; a Transform's is its node (reconcile keeps a node across frames), and a glide that is retargeted
   * mid-flight continues from the pose being shown, so nothing jumps.
   */
  private reconcileMotion(): void {
    let root = this.liveRoot
    if (root === null) { return }
    let now = Date.now()
    let next: Map<LiveNode, PoseAnim> = new Map<LiveNode, PoseAnim>()
    let started = this.visitMotion(root!, '', now, next)
    this.poseAnims = next
    if (started) { this.motionClock.now = now }
    if (this.motionTimer < 0 && this.motionRunning(root!, now)) {
      this.motionTimer = setInterval(() => {
        let at = Date.now()
        this.motionClock.now = at
        let top = this.liveRoot
        if (top === null || !this.motionRunning(top!, at)) {
          clearInterval(this.motionTimer)
          this.motionTimer = -1
        }
      }, 33)
    }
  }

  private visitMotion(node: LiveNode, path: string, now: number, next: Map<LiveNode, PoseAnim>): boolean {
    let started = false
    if (node.kind === 'motion') {
      let seen = this.motionTriggers.get(path)
      if (seen !== undefined && seen !== node.numberValue && motionDuration(node.style) > 0) {
        node.motionStart = now
        started = true
      }
      this.motionTriggers.set(path, node.numberValue)
    } else if (node.kind === 'transform') {
      let target = poseFromArray(node.series)
      let before = this.poseAnims.get(node)
      if (before === undefined) {
        next.set(node, new PoseAnim(target, target, -1, 0))
      } else if (samePose(before.to, target)) {
        next.set(node, before)
      } else {
        let shown = animatedPose(before.from, before.to, before.start, before.duration, now)
        next.set(node, new PoseAnim(shown, target, now, node.numberValue))
        started = true
      }
    }
    for (let i = 0; i < node.children.length; i++) {
      if (this.visitMotion(node.children[i], path + '/' + i.toString(), now, next)) { started = true }
    }
    return started
  }

  private motionRunning(node: LiveNode, now: number): boolean {
    if (node.kind === 'motion' && node.motionStart >= 0 && now - node.motionStart < motionDuration(node.style)) { return true }
    if (node.kind === 'transform') {
      let anim = this.poseAnims.get(node)
      if (anim !== undefined && anim.start >= 0 && now - anim.start < anim.duration) { return true }
    }
    for (let child of node.children) {
      if (this.motionRunning(child, now)) { return true }
    }
    return false
  }

  /** The pose of a Motion now; the identity pose when it is not playing. Reads the clock, so the branch redraws with it. */
  private motionPoseOf(node: LiveNode): MotionPose {
    let now = this.motionClock.now
    if (node.motionStart < 0) { return new MotionPose() }
    let duration = motionDuration(node.style)
    if (duration <= 0) { return new MotionPose() }
    return motionPose(node.style, (now - node.motionStart) / duration)
  }

  /** The pose a Transform shows at `now`. */
  private shownPose(node: LiveNode, now: number): number[] {
    let anim = this.poseAnims.get(node)
    if (anim === undefined) { return poseFromArray(node.series) }
    return animatedPose(anim.from, anim.to, anim.start, anim.duration, now)
  }

  /**
   * The matrix of a Transform this frame: the pose being shown (distances in px, as ArkUI's matrices want) turned about the
   * node's centre, behind the viewer distance TRANSFORM_DISTANCE. Reads the motion clock, so the node redraws with the glide.
   */
  private transformMatrix(node: LiveNode): Object {
    let now = this.motionClock.now
    let density = this.getUIContext().vp2px(1)
    let pose = poseToPixels(this.shownPose(node, now), density)
    let m = columnMajor(multiplyMatrices(perspectiveMatrix(TRANSFORM_DISTANCE * density), poseMatrix(pose)))
    return matrix4.init([m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12], m[13], m[14], m[15]])
  }

  /** The opacity entry of the pose a Transform shows now. */
  private transformOpacity(node: LiveNode): number {
    return this.shownPose(node, this.motionClock.now)[7]
  }

  /** First spinning shape wins; one shared angle is enough. */
  private findSpinPeriod(node: VeraUiNode): number {
    if (node.kind === 'path' && node.spinPeriodMs > 0) { return node.spinPeriodMs }
    for (let child of node.children) {
      let found = this.findSpinPeriod(child)
      if (found > 0) { return found }
    }
    return 0
  }

  /**
   * Keep backHandlerAction in step with the frame just produced, and tell the
   * hosting page when a handler starts or stops being there -- not on every
   * frame, only on that transition, since that is the only thing the page
   * needs to decide what its own onBackPress() should do next time.
   */
  private reconcileBackHandler(root: VeraUiNode | null): void {
    let action = root !== null ? this.findBackHandlerAction(root!) : ''
    let had = this.backHandlerAction.length > 0
    this.backHandlerAction = action
    let has = action.length > 0
    if (has !== had) { this.onBackHandlerChanged(has) }
  }

  /** Last one in the tree wins, matching the catalogue's own stated rule. */
  private findBackHandlerAction(node: VeraUiNode): string {
    let found = node.kind === 'backhandler' ? node.action : ''
    for (let child of node.children) {
      let childFound = this.findBackHandlerAction(child)
      if (childFound.length > 0) { found = childFound }
    }
    return found
  }

  /** The system back gesture, relayed by the hosting page via backPressSignal. */
  onBackPressSignal(): void {
    if (this.backHandlerAction.length > 0) {
      this.dispatchFieldAction(this.backHandlerAction, numberPayload(0), true, null, 'BACK')
    }
  }

  /**
   * The hosting page's NavDestination.onHidden()/onShown() set destinationHidden; the surface frame loop follows it.
   * This replaces the old routerPageUpdate observer, which only fired when the whole app went away: every screen now
   * lives inside one router page, so a proof opened over this one never stopped the loop underneath.
   */
  private onDestinationHidden(): void {
    if (this.disposed) { return }
    if (this.destinationHidden) {
      if (!this.pageHidden) {
        this.pageHidden = true
        this.stopSurfaceLoop()
        // The parts' repaint stops too; showing the page again repaints, which starts it again if anything still plays.
        this.stopPartsTimer()
      }
    } else {
      if (this.pageHidden) {
        this.pageHidden = false
        this.reconcileSurfaces(true)
      }
    }
  }

  private collectTickers(node: VeraUiNode, wanted: Map<string, TimerConfig>): void {
    if (node.kind === 'ticker' && node.checked && node.minimum > 0 &&
        node.tickerId.length > 0 && node.action.length > 0) {
      wanted.set(node.tickerId, new TimerConfig(node.minimum, node.action))
    }
    for (let child of node.children) { this.collectTickers(child, wanted) }
  }

  private startTimer(id: string, config: TimerConfig): void {
    let safe = config.interval < 16 ? 16 : config.interval
    this.timerConfigs.set(id, config)
    this.timerLastFire.set(id, Date.now())
    let handle = setInterval(() => {
      // A tick that arrives while the previous one is still running would
      // re-enter the VM with a half-applied state.
      // In the background the tick is skipped, not stopped: the time it last fired is kept, so the first tick after
      // resume carries the whole gap, and the app does not write state while a card may be changing it.
      if (this.disposed || this.transitioning || this.appForeground === false) {
        if (this.appForeground === false) { StageTrace.emit(this.traceOwner, 'TICK_SKIPPED', { tickerId: id, reason: 'BACKGROUND' }) }
        return
      }
      let current = this.timerConfigs.get(id)
      if (current === undefined) { return }
      // Do not queue a tick while an IME composition is active: keep its elapsed time for the next deliverable tick.
      for (let edit of this.fieldEdits.values()) {
        if (edit.composing) {
          StageTrace.emit(this.traceOwner, 'TICK_SKIPPED', { tickerId: id, reason: 'COMPOSING' })
          return
        }
      }
      // Fast tickers are frame-like. Let the 400-ms field debounce finish rather than committing on every tick;
      // timerLastFire stays unchanged, so the next delivered tick carries the elapsed time accumulated while typing.
      if (current.interval < SLOW_TICK_MS && this.fieldEdits.size > 0) {
        StageTrace.emit(this.traceOwner, 'TICK_SKIPPED', { tickerId: id, reason: 'PENDING_EDIT' })
        return
      }
      let last = this.timerLastFire.get(id)
      let now = Date.now()
      let elapsed = last !== undefined ? now - (last as number) : safe
      this.timerLastFire.set(id, now)
      StageTrace.emit(this.traceOwner, 'TICK_DELIVERED', { tickerId: id, action: current.action,
        class: current.interval >= SLOW_TICK_MS ? 'slow' : 'fast' })
      if (current.interval >= SLOW_TICK_MS) {
        let next = this.captureFieldAction(current.action, numberPayload(Math.round(elapsed)))
        next.traceKind = 'TICK'
        next.tickerId = id
        this.enqueueFieldAction(next)
      } else {
        let post = new PreviewPost('TICK')
        post.key = id
        post.tick = { tickerId: id, action: current.action, elapsed: Math.round(elapsed) }
        this.queuePost(post)
      }
    }, safe)
    this.timers.set(id, handle)
  }

  private stopTimer(id: string): void {
    let handle = this.timers.get(id)
    if (handle !== undefined) { clearInterval(handle as number) }
    this.timers.delete(id)
    this.timerConfigs.delete(id)
    this.timerLastFire.delete(id)
  }

  private stopAllTimers(reason: string = 'RELEASE'): void {
    StageTrace.emit(this.traceOwner, 'TIMERS_STOPPED', { reason: reason })
    this.stopSurfaceLoop()
    for (let id of Array.from(this.timers.keys())) { this.stopTimer(id) }
    if (this.spinTimer >= 0) { clearInterval(this.spinTimer); this.spinTimer = -1 }
    this.spinPeriod = 0
    if (this.motionTimer >= 0) { clearInterval(this.motionTimer); this.motionTimer = -1 }
    this.stopPartsTimer()
    this.motionTriggers.clear()
    this.poseAnims.clear()
  }

  private detachDrainTree(): void {
    if (this.liveRoot === null) { return }
    let root = cloneLiveTree(this.liveRoot!)
    let copies: Map<LiveNode, LiveNode> = new Map<LiveNode, LiveNode>()
    let originals: LiveNode[] = [this.liveRoot!]
    let detached: LiveNode[] = [root]
    while (originals.length > 0) {
      let node = originals.pop()!
      let copy = detached.pop()!
      copies.set(node, copy)
      copy.fieldGeneration = node.fieldGeneration
      copy.fieldCancellation = node.fieldCancellation
      copy.liveGeneration = node.liveGeneration
      copy.fieldValue = node.fieldValue
      copy.typed = node.typed
      copy.touched = node.touched
      copy.layoutWidth = node.layoutWidth
      copy.layoutHeight = node.layoutHeight
      for (let i = 0; i < node.children.length; i++) {
        originals.push(node.children[i])
        detached.push(copy.children[i])
      }
    }
    let edits: Map<LiveNode, FieldEdit> = new Map<LiveNode, FieldEdit>()
    this.fieldEdits.forEach((edit: FieldEdit, node: LiveNode): void => {
      let copy = copies.get(node)
      if (copy !== undefined) { edits.set(copy, edit) }
      else if (edit.timer >= 0) { clearTimeout(edit.timer) }
    })
    this.fieldEdits = edits
    let actions = this.fieldActions.slice()
    if (this.inFlight !== null) { actions.push(this.inFlight!) }
    for (let post of this.posts) { if (post.action !== null) { actions.push(post.action!) } }
    for (let action of actions) {
      if (action.node !== null) { action.node = copies.get(action.node!) || action.node }
      if (action.fieldNode !== null) { action.fieldNode = copies.get(action.fieldNode!) || null }
      action.dependencies = action.dependencies.map((node: LiveNode): LiveNode => copies.get(node) || node)
    }
    let surfaces: Map<LiveNode, SurfaceBox> = new Map<LiveNode, SurfaceBox>()
    this.surfaces.forEach((box: SurfaceBox, node: LiveNode): void => {
      let copy = copies.get(node)
      if (copy !== undefined) { surfaces.set(copy, box) }
    })
    this.surfaces = surfaces
    let inputs: Map<LiveNode, Map<number, SurfaceInput>> = new Map<LiveNode, Map<number, SurfaceInput>>()
    this.surfaceInputs.forEach((contacts: Map<number, SurfaceInput>, node: LiveNode): void => {
      let copy = copies.get(node)
      if (copy !== undefined) { inputs.set(copy, contacts) }
    })
    this.surfaceInputs = inputs
    this.liveSurfaces = this.liveSurfaces.map((node: LiveNode): LiveNode => copies.get(node) || node)
    this.fieldInputs.clear()
    this.fieldMenus.clear()
    this.liveRoot = root
    this.liveGeneration++
    this.markLiveNodeGeneration(root)
  }

  aboutToDisappear(): void {
    this.mountRequested = false
    if (this.disposed) { return }
    if (this.controller !== null) { this.controller!.detach(this.captureFields) }
    let generation = this.acquireGeneration
    let saveState = (this.hadWorlds || this.worlds.size > 0 || this.liveSurfaces.length > 0) &&
      this.activeOptions.mode !== 'PREVIEW'
    this.draining = true
    this.disposed = true
    this.fieldActions = []
    this.posts = []
    this.surfaceInputs.clear()
    this.stopAllTimers('DISAPPEAR')
    this.retireWorlds()
    for (let node of Array.from(this.fieldEdits.keys())) {
      let edit = this.fieldEdits.get(node)!
      let input = this.fieldInputs.get(node)
      if (edit.composing) {
        if (input !== undefined) {
          try { edit.value = input.controller.getText() } catch (_) {}
        }
        edit.composing = false
      }
      if (edit.timer >= 0) { clearTimeout(edit.timer); edit.timer = -1 }
      edit.commitRequested = true
    }
    this.detachDrainTree()
    this.resumeFieldActions()
    this.syncEditGate()
    this.operations = this.operations.then(async (): Promise<void> => {
      try {
        this.transitioning = false
        if (this.activationCurrent(generation) && this.handle !== null && this.activeOptions.mode !== 'PREVIEW') {
          await this.flushPendingInputFor(this.frameAppId)
        }
      } catch (e) {
        console.error('VERA-RENDER final input flush failed: ' + (e as Error).message)
      } finally {
        if (generation === this.acquireGeneration) {
          this.invalidateEffects()
          let handle = this.handle
          this.handle = null
          try {
            if (handle !== null) { await this.runtime.release(handle, { saveState: saveState }) }
          } catch (e) {
            console.error('VERA-RENDER release failed: ' + (e as Error).message)
          } finally {
            this.draining = false
            this.subscriber = null
            this.subscriberGeneration++
            this.surfaces.clear()
            this.liveSurfaces = []
            this.textTimers.clear()
            this.posts = []
            this.liveRoot = null
            this.observedErrors.clear()
            this.numberDraft.clear()
            this.syncEditGate()
          }
        }
      }
    })
    // The same applies to the dark-mode listener: it holds this component, and
    // its callback re-enters the VM.
    if (this.darkListener !== null) {
      try {
        this.darkListener!.off('change')
      } catch (e) {
        StageTrace.emit(this.traceOwner, 'ERROR', { kind: 'DARK_LISTENER' })
        console.info('VERA-RENDER dark listener off failed: ' + (e as Error).message)
      }
      this.darkListener = null
    }
  }

  private retireWorlds(): void {
    for (let box of this.worlds.values()) { box.retire() }
    this.worlds.clear()
    this.scenes.clear()
    this.nodeIds.clear()
    this.pendingWorldStep = false
    this.worldEvents = []
    this.worldEventNodes = []
    this.fullOpenedFor = -1
    if (!this.disposed) { this.setFullWorld(null) }
    else { this.fullWorld = null }
  }

  private commitWorldProgram(program: string): void {
    if (this.worldProgram !== program) {
      this.retireWorlds()
      this.hadWorlds = false
      this.worldProgram = program
    }
    this.pendingWorldProgram = null
  }

  private worldErrorBlocks(): boolean {
    return this.error.length > 0 && this.error !== this.viewError && this.error !== this.worldTransitionError
  }

  /** The bytecode itself is the stamp: a refined program gets a different one. */
  private stamp(): string {
    return veraStateStamp(this.vbc2)
  }

  private drainFrames(): void {
    let frames = this.deferredFrames
    this.deferredFrames = []
    for (let frame of frames) { this.acceptFrame(frame) }
  }

  private acceptFrame(frame: FrameEnvelope): void {
    if (this.inFlight !== null && this.inFlight!.posting) {
      this.deferredFrames.push(frame)
      return
    }
    if (frame.vmGeneration < this.frameVmGeneration ||
        (frame.vmGeneration === this.frameVmGeneration && frame.appId === this.frameAppId &&
          frame.frameSeq <= this.lastFrameSeq)) { return }
    if (this.pendingWorldProgram !== null && frame.view !== null &&
        (frame.appId !== this.frameAppId || frame.vmGeneration !== this.frameVmGeneration)) {
      this.commitWorldProgram(this.pendingWorldProgram!)
    }
    this.frameAppId = frame.appId
    this.frameVmGeneration = frame.vmGeneration
    this.lastFrameSeq = frame.frameSeq
    this.lastAppliedSeq = Math.max(this.lastAppliedSeq, frame.appliedSeq)
    if (frame.scenes !== undefined) {
      this.scenes.clear()
      if (frame.scenes.length > 0) { this.hadWorlds = true }
      for (let scene of frame.scenes) { this.scenes.set(scene.nodeId, scene.spec) }
    }
    let started = Date.now()
    if (frame.view !== null) {
      if (this.viewError.length > 0 && this.error === this.viewError) { this.error = '' }
      this.viewError = ''
      armReveal(frame.reveal && !this.disposed)
      try { this.renderView(frame.view as VeraUiNode, frame.gfx.length === 0, frame.reveal) }
      finally { armReveal(false) }
    }
    if (!this.disposed) {
      for (let value of frame.gfx) {
        let gfx = value as PreviewGfx
        if (gfx.surfaceRevision !== this.surfaceRevision) { continue }
        let node = this.liveSurfaces[gfx.nodeId]
        if (node !== undefined && this.isLiveNode(node)) { this.paintSurfaceFrame(node, gfx.ops) }
      }
      this.frameSplit[0] += frame.timing[0] || 0
      this.frameSplit[1] += frame.timing[1] || 0
      this.frameSplit[3] += frame.timing[2] || 0
      if (frame.gfx.length > 0) {
        this.countFrame(Date.now(), Date.now() - started + (frame.timing[0] || 0) +
          (frame.timing[1] || 0) + (frame.timing[2] || 0))
      }
    }
    this.completeInput()
    this.syncEditGate()
    this.scheduleFieldActions()
  }

  private renderView(root: VeraUiNode, paint: boolean = true, reveal: boolean = false): void {
    this.renderingDepth++
    let rendered = false
    try {
      // Not for the refreshes a running surface makes ten times a second: they would bury every other line.
      if (paint) {
        console.info('VERA-VIEW rev=' + (this.revision + 1).toString() +
          ' root=' + (root !== null ? root!.kind : 'null') +
          ' children=' + (root !== null ? root!.children.length.toString() : '0'))
      }
      if (!this.disposed) { this.reconcileTheme(root) }
      // Invalidate all prior membership stamps before mutating the live tree.
      // If reconciliation fails partway through, stale node references fail closed.
      this.liveGeneration++
      let applied = this.inFlight
      let fieldApplied = applied !== null && applied.fieldNode !== null &&
        (applied.posting || (applied.inputSeq >= 0 && this.lastAppliedSeq >= applied.inputSeq))
      if (root === null) {
        this.liveRoot = null
        if (!this.disposed) { this.hasRoot = false }
      } else if (this.liveRoot === null) {
        this.liveRoot = toLive(root!)
        if (!this.disposed) { this.hasRoot = true }
      } else {
        reconcile(this.liveRoot!, root!, (node: LiveNode, next: VeraUiNode): string | undefined => {
          let edit = this.fieldEdits.get(node)
          let acknowledged = fieldApplied && applied !== null && applied.fieldNode === node && next.value === applied.payload.str
          if (edit !== undefined && node.fieldGeneration === edit.generation && node.action === edit.action &&
              (next.value === edit.base || acknowledged)) { return node.fieldValue }
          return acknowledged ? next.value : undefined
        })
      }
      if (this.liveRoot !== null) {
        this.markLiveNodeGeneration(this.liveRoot!)
        markIconRoom(this.liveRoot!)
      }
      if (applied !== null && applied.fieldNode !== null) {
        let node = applied.fieldNode!
        let edit = this.fieldEdits.get(node)
        if (edit !== undefined && node.action === edit.action && node.fieldGeneration === edit.generation &&
            node.value === applied.payload.str &&
            (applied.posting || (applied.inputSeq >= 0 && this.lastAppliedSeq >= applied.inputSeq))) {
          edit.base = node.value
          edit.generation = node.fieldGeneration
        }
      }
      this.reconcileFields()
      if (this.disposed) { rendered = true; return }
      this.revision += 1
      this.reconcileTimers(this.previewOnly ? null : root)
      this.reconcileSpin(root)
      this.reconcileMotion()
      this.reconcileBackHandler(root)
      this.reconcileSurfaces(paint)
      StageTrace.frame(this.traceOwner, root, reveal)
      rendered = true
    } catch (e) {
      StageTrace.emit(this.traceOwner, 'ERROR', { kind: 'VIEW' })
      this.flushFailure = e as Error
      if (!this.disposed) { this.error = 'View error: ' + (e as Error).message }
    } finally {
      this.renderingDepth--
    }
    if (rendered) { this.scheduleFieldActions() }
  }

  /**
   * Bring the surfaces in line with the frame just reconciled: forget the canvases of nodes that are no longer
   * surfaces (and the controllers of timers that are gone), run the frame loop exactly while one of them has a frame handler, and paint them all now unless the
   * frame loop is the one asking (it paints straight after).
   */
  private reconcileSurfaces(paint: boolean): void {
    this.reconcileWorlds()
    let found: LiveNode[] = []
    let timers: LiveNode[] = []
    if (this.liveRoot !== null) {
      this.collectKind(this.liveRoot!, 'surface', found)
      this.collectKind(this.liveRoot!, 'timer', timers)
    }
    for (let node of Array.from(this.surfaces.keys())) {
      if (found.indexOf(node) < 0) { this.surfaces.delete(node) }
    }
    // A timer's controller lives as long as its node is in the tree.
    for (let node of Array.from(this.textTimers.keys())) {
      if (timers.indexOf(node) < 0) { this.textTimers.delete(node) }
    }
    let descriptors: string[] = found.map((node: LiveNode): string => JSON.stringify([
      this.nodeIds.get(node), node.label, node.action, node.value, node.style, node.minimum, node.maximum
    ]))
    let signature = JSON.stringify([this.frameAppId, this.frameVmGeneration, descriptors])
    let changed = signature !== this.surfaceSignature || found.length !== this.liveSurfaces.length ||
      found.some((node: LiveNode, index: number): boolean => node !== this.liveSurfaces[index])
    if (changed) {
      this.surfaceSignature = signature
      this.surfaceRevision++
      for (let post of this.posts) {
        if (post.kind === 'DRAW') {
          post.draws = post.draws.filter((draw: DrawRequest): boolean => draw.surfaceRevision === this.surfaceRevision)
        }
      }
      this.posts = this.posts.filter((post: PreviewPost): boolean => post.kind !== 'DRAW' || post.draws.length > 0)
    }
    this.liveSurfaces = found
    let animated = false
    for (let node of found) { if (node.action.length > 0) { animated = true } }
    if (this.pendingWorldStep || this.worldsNeedFrames()) { animated = true }
    if (animated && !this.previewOnly && !this.pageHidden &&
        (this.error.length === 0 || this.error === this.viewError ||
          (this.worlds.size > 0 && this.error === this.worldTransitionError))) { this.startSurfaceLoop() } else { this.stopSurfaceLoop() }
    if (paint || changed) { this.paintSurfaces() }
  }

  /**
   * Bring the worlds in line with the frame just reconciled. Each world's build function runs on the current state and
   * its scene is given the result when that differs from what it was last given (or the theme changed); a world whose
   * node left the tree is retired, and its scene destroyed once its Component3D has gone. A build that traps, or returns
   * a world that breaks the contract (two bodies with one id, too many bodies), stops the program as a draw error does.
   */
  private ensureNodeIds(): void {
    this.nodeIds.clear()
    if (this.liveRoot === null) { return }
    let nodes: LiveNode[] = [this.liveRoot!]
    let nextId = 1
    while (nodes.length > 0) {
      let node = nodes.pop()!
      this.nodeIds.set(node, nextId++)
      for (let index = node.children.length - 1; index >= 0; index--) { nodes.push(node.children[index]) }
    }
  }

  private reconcileWorlds(): void {
    this.ensureNodeIds()
    let found: LiveNode[] = []
    if (this.liveRoot !== null) { this.collectKind(this.liveRoot!, 'world', found) }
    let wanted: Set<number> = new Set<number>()
    for (let node of found) { wanted.add(this.nodeIds.get(node)!) }
    for (let nodeId of Array.from(this.scenes.keys())) {
      if (!wanted.has(nodeId)) { this.scenes.delete(nodeId) }
    }
    for (let node of Array.from(this.worlds.keys())) {
      if (found.indexOf(node) < 0) {
        (this.worlds.get(node) as WorldBox).retire()
        this.worlds.delete(node)
      }
    }
    if (this.fullWorld !== null && (found.indexOf(this.fullWorld!) < 0 ||
        !this.scenes.has(this.nodeIds.get(this.fullWorld!)!))) { this.setFullWorld(null) }
    if (this.fullOpenedFor !== this.programId && !this.embedded && !this.previewOnly) {
      let full = found.find((node: LiveNode): boolean => node.style === 'full' && this.scenes.has(this.nodeIds.get(node)!))
      if (full !== undefined) {
        this.fullOpenedFor = this.programId
        this.setFullWorld(full)
      }
    }
    if (found.length === 0 || this.disposed) { return }
    let theme = this.t()
    for (let node of found) {
      let spec = this.scenes.get(this.nodeIds.get(node)!)
      let box = this.worlds.get(node)
      if (spec === undefined) {
        if (box !== undefined) { box.retire(); this.worlds.delete(node) }
        continue
      }
      if (box === undefined) {
        let context = this.getUIContext().getHostContext()
        box = new WorldBox(context !== undefined ? context.filesDir : '')
        this.worlds.set(node, box)
      }
      if (node.label.length === 0 || this.worldErrorBlocks()) { continue }
      try {
        let dark = isDarkRgba(worldBackgroundRgba(spec, theme))
        if (node === this.fullWorld && dark !== this.fullWorldDark) { this.fullWorldDark = dark }
        let key = JSON.stringify(spec)
        if (key !== box.key || theme !== box.theme) {
          box.key = key
          box.theme = theme
          box.apply(spec, theme)
        }
      } catch (e) {
        console.error('VERA-WORLD build TRAP fn=' + node.label + ' err=' + (e as Error).message)
        this.error = 'World error in ' + node.label + ': ' + (e as Error).message
        this.stopAllTimers()
        return
      }
    }
  }

  private worldsNeedFrames(): boolean {
    for (let box of this.worlds.values()) { if (box.needsFrames()) { return true } }
    return false
  }

  /**
   * One frame for every world, then what they told the program -- hits, settling -- at most WORLD_EVENTS_PER_FRAME of it
   * (the rest waits in each box for the next frame), each through the field-action queue as a tap's is, and only then
   * the next physics step of each. Every two seconds
   * a VERA-WORLD line: frames, bodies, loose bodies awake, the ms spent writing poses and stepping the physics.
   */
  private finishWorldStep(): void {
    if (!this.pendingWorldStep || this.disposed || this.transitioning || this.flushFailure !== null ||
        this.fieldActions.length > 0 || this.inFlight !== null || this.fieldEdits.size > 0 ||
        this.posts.length > 0 || this.posting || this.postDrain || this.postingEffect || this.admissionBlocked ||
        this.resumingFieldActions || this.renderingDepth > 0) { return }
    this.pendingWorldStep = false
    for (let box of Array.from(this.worlds.values())) { box.advance() }
  }

  private tickWorlds(now: number, elapsed: number): void {
    if (this.pendingWorldStep) {
      this.finishWorldStep()
      return
    }
    if (this.worlds.size === 0) { return }
    let bodies = 0
    let awake = 0
    this.worldEvents = []
    this.worldEventNodes = []
    for (let entry of Array.from(this.worlds.entries())) {
      let node = entry[0]
      let box = entry[1]
      box.frame(elapsed)
      bodies += box.bodyCount()
      awake += box.awake
      let room = WORLD_EVENTS_PER_FRAME - this.worldEvents.length
      if (node.action.length === 0 || this.previewOnly) {
        // No handler: nobody to tell.
        box.takeEvents(1000)
      } else if (room > 0) {
        for (let e of box.takeEvents(room)) {
          this.worldEvents.push(e)
          this.worldEventNodes.push(node)
        }
      }
    }
    // Told between the end of each world's last step and the start of its next, so a handler that changes a world has
    // it applied with no step running: the UI thread does not wait on the step thread for it.
    this.pendingWorldStep = true
    this.dispatchWorldEvents()
    this.finishWorldStep()
    if (this.worldReportAt === 0) { this.worldReportAt = now }
    this.worldFrames += 1
    if (now - this.worldReportAt < 2000) { return }
    let writeMs = 0
    let stepMs = 0
    let contacts = 0
    let particles = 0
    let emitted = 0
    let particleMs = 0
    for (let box of this.worlds.values()) {
      writeMs += box.writeMs
      stepMs += box.stepMs
      contacts = Math.max(contacts, box.mostContacts)
      particles += box.particleCount()
      emitted += box.particlesEmitted
      particleMs += box.particleMs
      box.particlesEmitted = 0
      box.particleMs = 0
      box.writeMs = 0
      box.stepMs = 0
      box.mostContacts = 0
      box.frames = 0
    }
    console.info('VERA-WORLD fps=' + (this.worldFrames * 1000 / (now - this.worldReportAt)).toFixed(1) +
      ' bodies=' + bodies.toString() + ' awake=' + awake.toString() + ' writeMs=' + (writeMs / this.worldFrames).toFixed(2) +
      ' stepMs=' + (stepMs / this.worldFrames).toFixed(2) + ' contacts=' + contacts.toString() +
      ' particles=' + particles.toString() + ' emitted=' + emitted.toString() + ' particleMs=' + (particleMs / this.worldFrames).toFixed(2))
    this.worldReportAt = now
    this.worldFrames = 0
  }

  /** The events tickWorlds collected, each to its world's handler, unless that world has gone or the program stopped. */
  private dispatchWorldEvents(): void {
    let events = this.worldEvents
    let nodes = this.worldEventNodes
    this.worldEvents = []
    this.worldEventNodes = []
    for (let i = 0; i < events.length; i++) {
      let node = nodes[i]
      let e = events[i]
      if (this.disposed || this.previewOnly ||
          this.worldErrorBlocks() || this.liveRoot === null) {
        for (let k = i; k < events.length; k++) {
          if (events[k].kind !== 'hit') {
            console.info('VERA-WORLD event dropped kind=' + events[k].kind + ' reason=' + (this.error.length > 0 ? 'program-error' : 'program-stopped'))
          }
        }
        return
      }
      if (!this.worlds.has(node) || !this.isLiveNode(node) || node.kind !== 'world' || node.action.length === 0) {
        console.info('VERA-WORLD event dropped kind=' + e.kind + ' reason=world-gone')
        continue
      }
      console.info('VERA-WORLD event ' + e.kind + ' body=' + e.body + ' other=' + e.other + ' speed=' + e.speed.toFixed(2) +
        ' values=' + e.values.join(',') + (e.kind === 'settled' ? ' kick=' + e.kick.toString() : ''))
      // A knock (hit, struck) is frequent and changes little: it is saved with the next settle, tap or save, not on its own.
      this.dispatchFieldAction(node.action, scenePayload(e.kind, e.body, e.other, e.x, e.y, e.z, e.speed, e.bodies, e.values,
        [e.dx, e.dy, e.dz]), e.kind !== 'hit' && e.kind !== 'struck', node)
    }
  }

  /** Every text field from here down may show its check now; see LiveNode.touched. */
  private touchFields(node: LiveNode): void {
    if (node.kind === 'field') {
      node.touched = true
      this.refreshFieldIssue(node)
    }
    for (let child of node.children) { this.touchFields(child) }
  }

  /**
   * The fields a button submits: those under its nearest enclosing node that has a field, its form; none for a button with no
   * field around it. Touching every field on the screen, Start on a stopwatch flagged "Enter a task name" on an Add form beside
   * it, which is what touched was for (review of #46).
   */
  private touchFormOf(button: LiveNode): void {
    let form = this.fieldFormOf(button)
    if (form !== null) { this.touchFields(form!) }
  }

  private fieldFormOf(node: LiveNode): LiveNode | null {
    if (this.liveRoot === null) { return null }
    let path: LiveNode[] = []
    if (!this.pathTo(this.liveRoot!, node, path)) { return null }
    for (let i = path.length - 2; i >= 0; i--) {
      if (this.hasField(path[i])) { return path[i] }
      if (FORM_BOUNDS.indexOf(path[i].kind) >= 0) { return path[i] }
    }
    return null
  }

  private collectFieldDependencies(node: LiveNode, fields: LiveNode[]): void {
    if (node.kind === 'field') { fields.push(node) }
    for (let child of node.children) { this.collectFieldDependencies(child, fields) }
  }

  /** The nodes from `node` down to `target`, both included, into `path`; false when `target` is not under `node`. */
  private pathTo(node: LiveNode, target: LiveNode, path: LiveNode[]): boolean {
    path.push(node)
    if (node === target) { return true }
    for (let child of node.children) { if (this.pathTo(child, target, path)) { return true } }
    path.pop()
    return false
  }

  private hasField(node: LiveNode): boolean {
    if (node.kind === 'field') { return true }
    for (let child of node.children) { if (this.hasField(child)) { return true } }
    return false
  }

  private collectKind(node: LiveNode, kind: string, found: LiveNode[]): void {
    if (node.kind === kind) { found.push(node) }
    for (let child of node.children) { this.collectKind(child, kind, found) }
  }

  /**
   * Frames at the display's own rate. displaySync is the vsync of this window; an interval is the fallback for a
   * system that refuses one, and is near enough for a game that measures elapsed time rather than counting frames.
   */
  private startSurfaceLoop(): void {
    if (this.surfaceSync !== null || this.surfaceTimer >= 0) { return }
    // The frame loop paints every surface each frame: the parts' own repaint would paint them a second time.
    this.stopPartsTimer()
    this.lastFrameAt = 0
    this.surfaceLoopStartedAt = Date.now()
    console.info('VERA-SURFACE loop start')
    this.frameReportAt = 0
    this.frameCount = 0
    this.frameWork = 0
    this.frameWorst = 0
    this.frameSplit = [0, 0, 0, 0]
    this.worldReportAt = 0
    this.worldFrames = 0
    try {
      let sync = displaySync.create()
      let range: ExpectedFrameRateRange = { expected: 60, min: 30, max: 120 }
      sync.setExpectedFrameRateRange(range)
      sync.on('frame', (_info: displaySync.IntervalInfo) => { this.surfaceFrame() })
      sync.start()
      this.surfaceSync = sync
    } catch (e) {
      StageTrace.emit(this.traceOwner, 'ERROR', { kind: 'SURFACE_LOOP' })
      console.warn('VERA-SURFACE no display sync, using an interval: ' + (e as Error).message)
      this.surfaceTimer = setInterval(() => { this.surfaceFrame() }, 16)
    }
  }

  private stopSurfaceLoop(): void {
    if (this.surfaceSync !== null || this.surfaceTimer >= 0) { console.info('VERA-SURFACE loop stop') }
    if (this.surfaceSync !== null) {
      try {
        this.surfaceSync!.stop()
        this.surfaceSync!.off('frame')
      } catch (e) {
        StageTrace.emit(this.traceOwner, 'ERROR', { kind: 'SURFACE_LOOP_STOP' })
        console.warn('VERA-SURFACE stopping display sync failed: ' + (e as Error).message)
      }
      this.surfaceSync = null
    }
    if (this.surfaceTimer >= 0) { clearInterval(this.surfaceTimer); this.surfaceTimer = -1 }
    this.surfaceLoopStartedAt = undefined
  }

  private surfaceFrame(): void {
    if (this.disposed || this.transitioning || this.pageHidden || this.handle === null) {
      if (!this.disposed && this.pageHidden) { StageTrace.emit(this.traceOwner, 'SURFACE_SKIPPED', { reason: 'PAGE_HIDDEN' }) }
      return
    }
    // Do not advance the VM while an IME composition is in progress; resume with a bounded elapsed value afterward.
    for (let edit of this.fieldEdits.values()) {
      if (edit.composing) {
        StageTrace.emit(this.traceOwner, 'SURFACE_SKIPPED', { reason: 'COMPOSING' })
        return
      }
    }
    let now = Date.now()
    let elapsed = this.lastFrameAt > 0 ? Math.min(SURFACE_MAX_ELAPSED_MS, Math.max(0, now - this.lastFrameAt)) : 16
    this.lastFrameAt = now
    this.tickWorlds(now, elapsed)
    let actions: string[] = []
    for (let node of this.liveSurfaces) {
      if (node.action.length > 0) { actions.push(node.action) }
    }
    let worldOnly = actions.length === 0
    let stopping = worldOnly && !this.pendingWorldStep && !this.worldsNeedFrames()
    let post = new PreviewPost('SURFACE_FRAME')
    post.key = worldOnly ? 'world' : 'surface'
    post.surface = { elapsed: elapsed, actions: actions, draws: worldOnly ? [] : this.surfaceDraws(),
      loopStartedAt: this.surfaceLoopStartedAt, worldOnly: worldOnly, worldStopping: stopping }
    this.surfaceLoopStartedAt = undefined
    this.queuePost(post)
    if (stopping) { this.stopSurfaceLoop() }
  }

  /**
   * Every two seconds, how many frames ran and how long the program and the painting took in them: the one number
   * that says whether a surface keeps up with the display, on the phone, without a profiler.
   */
  private countFrame(now: number, work: number): void {
    if (this.frameReportAt === 0) { this.frameReportAt = now }
    this.frameCount += 1
    this.frameWork += work
    if (work > this.frameWorst) { this.frameWorst = work }
    if (now - this.frameReportAt < 2000) { return }
    let seconds = (now - this.frameReportAt) / 1000
    let per = (i: number): string => (this.frameSplit[i] / this.frameCount).toFixed(1)
    console.info('VERA-SURFACE fps=' + (this.frameCount / seconds).toFixed(1) +
      ' workMs avg=' + (this.frameWork / this.frameCount).toFixed(1) + ' max=' + this.frameWorst.toString() +
      ' frame=' + per(0) + ' draw=' + per(1) + ' paint=' + per(2) + ' view=' + per(3))
    this.frameSplit = [0, 0, 0, 0]
    this.frameReportAt = now
    this.frameCount = 0
    this.frameWork = 0
    this.frameWorst = 0
  }

  private surfaceDraws(only: LiveNode | null = null): DrawRequest[] {
    let draws: DrawRequest[] = []
    for (let i = 0; i < this.liveSurfaces.length; i++) {
      let node = this.liveSurfaces[i]
      let box = this.surfaces.get(node)
      if ((only === null || node === only) && box !== undefined && box.ready && box.visible &&
          box.width > 0 && box.height > 0 && node.label.length > 0) {
        draws.push({ nodeId: i, entry: node.label, surfaceRevision: this.surfaceRevision })
      }
    }
    return draws
  }

  private paintSurfaces(): void {
    let post = new PreviewPost('DRAW')
    post.draws = this.surfaceDraws()
    if (post.draws.length > 0) { this.queuePost(post) }
  }

  private paintSurface(node: LiveNode): void {
    let post = new PreviewPost('DRAW')
    post.draws = this.surfaceDraws(node)
    if (post.draws.length > 0) { this.queuePost(post) }
  }

  private paintSurfaceFrame(node: LiveNode, ops: GfxOp[]): void {
    let box = this.surfaces.get(node)
    if (box === undefined || !box.ready || !box.visible || box.width <= 0 || box.height <= 0) { return }
    try {
      let paintAt = Date.now()
      paintGfx(box.ctx, ops, this.t(), box.width, box.height, node.minimum, node.maximum, this.getUIContext().vp2px(1), node.style === 'clear',
        false, this.partPoses(box, ops, paintAt), paintAt)
      this.frameSplit[2] += Date.now() - paintAt
      StageTrace.emit(this.traceOwner, 'DRAW', { nodeId: this.liveSurfaces.indexOf(node), result: 'OK' })
    } catch (e) {
      StageTrace.emit(this.traceOwner, 'ERROR', { kind: 'DRAW' })
      StageTrace.emit(this.traceOwner, 'DRAW', { nodeId: this.liveSurfaces.indexOf(node), result: 'ERROR' })
      console.error('VERA-SURFACE draw TRAP err=' + (e as Error).message)
      this.error = 'Draw error: ' + (e as Error).message
      this.stopAllTimers('TRAP')
    }
  }

  /**
   * Where each moving part of a drawing is now (gfx.moving): a part plays its preset from when its trigger changed or the picture was last
   * touched, as on a card. While any plays on a surface that has no frame loop, a short timer repaints until it is over.
   */
  private partPoses(box: SurfaceBox, ops: GfxOp[], now: number): MotionPose[] {
    let poses: MotionPose[] = []
    box.drifting = ops.some((o: GfxOp): boolean => o.kind === 'drift')
    let playing = box.drifting
    let touched = box.touchedAt > box.touchSeen
    box.touchSeen = box.touchedAt
    let i = 0
    for (let o of ops) {
      if (o.kind !== 'moving') { continue }
      if (box.partStarts.length <= i) { box.partStarts.push(-1e15); box.partTriggers.push(o.sweep) }
      if (!sameTrigger(box.partTriggers[i], o.sweep) || touched) { box.partStarts[i] = touched ? box.touchedAt : now }
      box.partTriggers[i] = o.sweep
      let length = motionDuration(o.fx)
      let progress = length > 0 ? (now - box.partStarts[i]) / length : 1
      if (progress < 1) { playing = true }
      poses.push(motionPose(o.fx, progress))
      i++
    }
    if (playing && this.partsTimer < 0 && this.surfaceSync === null && this.surfaceTimer < 0 && !this.pageHidden && !this.disposed) {
      this.partsTimer = setInterval(() => {
        if (this.pageHidden || this.disposed) { this.stopPartsTimer(); return }
        // Only the pictures that move are drawn again: each repaint runs the program's draw function, and a page of still pictures
        // with one drift ran every one of them 60 times a second. A part is painted a little past its budget, so it lands at rest.
        let at = Date.now()
        let moving = false
        for (let node of this.liveSurfaces) {
          let b = this.surfaces.get(node)
          if (b === undefined) { continue }
          if ((b.drifting && b.visible) || b.partStarts.some((start: number): boolean => at - start < MOTION_BUDGET_MS + 100)) {
            moving = true
            this.paintSurface(node)
          }
        }
        if (!moving) { this.stopPartsTimer() }
      }, 16)
    }
    return poses
  }

  private stopPartsTimer(): void {
    if (this.partsTimer >= 0) { clearInterval(this.partsTimer); this.partsTimer = -1 }
  }

  /** The canvas of a surface node, made the first time the node is drawn. */
  private surfaceBox(node: LiveNode): SurfaceBox {
    let box = this.surfaces.get(node)
    if (box === undefined) {
      box = new SurfaceBox()
      this.surfaces.set(node, box)
    }
    return box
  }

  /**
   * How tall a surface is drawn, in vp. As wide as its column and as tall as its proportions make that; style fill
   * instead runs to the bottom of the program's window from wherever the surface starts (measured into
   * layoutHeight), except in a chat, where there is no window of its own to fill.
   */
  private surfaceHeight(node: LiveNode): number {
    let width = this.viewportWidth > 0 ? this.viewportWidth : 360
    let natural = gfxNaturalHeight(width, node.minimum, node.maximum)
    if ((node.style === 'fill' || node.style === 'cover') && !this.embedded && node.layoutHeight > 0) { return node.layoutHeight }
    return natural > 0 ? natural : width
  }

  private surfaceArea(node: LiveNode, now: Area): void {
    let box = this.surfaceBox(node)
    box.width = Number(now.width)
    box.height = Number(now.height)
    if (node.style === 'fill' || node.style === 'cover') { this.fitFill(node, Number(now.globalPosition.y), Number(now.height)) }
    this.paintSurface(node)
  }

  /**
   * Fingers on a surface, in its own units. Down, up and cancel are taps and go the way every tap goes -- the
   * handler, then the tree, saved, effects run. A move is a stream of them, so it only runs the handler and
   * repaints; the tree catches up on the frame loop's schedule, and the state is saved when the finger lifts.
   */
  private surfaceTouch(node: LiveNode, event: TouchEvent): void {
    // A finger down plays the picture's moving parts, whether or not it has a handler (as on a card); the next paint starts them.
    if (event.type === TouchType.Down && !this.disposed) {
      let touchedBox = this.surfaces.get(node)
      if (touchedBox !== undefined) {
        touchedBox.touchedAt = Date.now()
        if (node.value.length === 0 || this.previewOnly) { this.paintSurface(node) }
      }
    }
    if (this.disposed || this.previewOnly || node.value.length === 0) { return }
    let down = new SurfaceInput(node, this.effectGeneration)
    let phase = event.type === TouchType.Down ? 'down' : event.type === TouchType.Move ? 'move'
      : event.type === TouchType.Up ? 'up' : 'cancel'
    if (phase === 'down') {
      let previous = this.surfaceInputs.get(node)
      if (previous !== undefined) {
        for (let touch of event.changedTouches) {
          let input = previous.get(touch.id)
          if (input !== undefined && !input.ended) { previous.delete(touch.id) }
        }
        if (previous.size === 0) { this.surfaceInputs.delete(node) }
      }
      if (!this.flushUserFields()) { return }
    }
    if (this.liveRoot === null || !this.isLiveNode(node) ||
        node.kind !== 'surface' || node.value.length === 0) {
      this.surfaceInputs.delete(node)
      return
    }
    let box = this.surfaces.get(node)
    if (box === undefined || box.width <= 0 || box.height <= 0) {
      this.surfaceInputs.delete(node)
      return
    }
    let inputs = this.surfaceInputs.get(node)
    if (inputs === undefined) {
      if (phase !== 'down') { return }
      inputs = new Map<number, SurfaceInput>()
      this.surfaceInputs.set(node, inputs)
    }
    for (let touch of event.changedTouches) {
      if (this.surfaceInputs.get(node) !== inputs) { break }
      if (phase === 'down') {
        let previous = inputs.get(touch.id)
        if (previous !== undefined && previous.ended) { continue }
        let accepted = new SurfaceInput(node, down.generation)
        accepted.action = down.action
        accepted.nodeGeneration = down.nodeGeneration
        inputs.set(touch.id, accepted)
      }
      let input = inputs.get(touch.id)
      if (input === undefined || input.ended) { continue }
      if (phase === 'move' && !this.flushUserFields()) { continue }
      if (this.surfaceInputs.get(node) !== inputs || inputs.get(touch.id) !== input) { continue }
      if (input.generation !== this.effectGeneration || this.disposed || this.previewOnly ||
          this.liveRoot === null || !this.isLiveNode(node) || node.kind !== 'surface' ||
          node.value !== input.action || node.fieldGeneration !== input.nodeGeneration) {
        inputs.delete(touch.id)
        continue
      }
      let currentBox = this.surfaces.get(node)
      if (currentBox === undefined || currentBox.width <= 0 || currentBox.height <= 0) {
        inputs.delete(touch.id)
        continue
      }
      let fit = gfxFit(currentBox.width, currentBox.height, node.minimum, node.maximum)
      let at = gfxToSurface(fit, touch.x, touch.y)
      let value = pointerPayload(phase, touch.id, at[0], at[1])
      if (phase === 'up' || phase === 'cancel') {
        input.ended = true
        let next = this.captureFieldAction(input.action, value, true, node)
        next.surfaceInput = input
        next.surfaceId = touch.id
        this.enqueueFieldAction(next)
      } else if (phase === 'move') {
        this.surfaceMove(input.action, value, node, input)
      } else {
        let next = this.captureFieldAction(input.action, value, true, node)
        next.surfaceInput = input
        next.surfaceId = touch.id
        this.enqueueFieldAction(next)
      }
    }
    if (inputs.size === 0 && this.surfaceInputs.get(node) === inputs) { this.surfaceInputs.delete(node) }
  }

  /**
   * The scene of a world node, as reconcileWorlds made it before the tree was drawn. Only reconcileWorlds makes or
   * retires one: a draw of a node it has already retired finds none here, and must not put a new box in the map that no
   * reconcile would ever retire.
   */
  private worldOptions(node: LiveNode): SceneOptions | null {
    let box = this.worlds.get(node)
    return box !== undefined ? box.options : null
  }

  /** The box of a node drawn with worldOptions non-null, in the same draw. */
  private drawnWorld(node: LiveNode): WorldBox {
    return this.worlds.get(node) as WorldBox
  }

  private worldBackdropReady(box: WorldBox): () => void {
    return () => { box.backdropShown() }
  }

  private worldShown(box: WorldBox, shown: boolean): () => void {
    return () => { if (shown) { box.appeared() } else { box.disappeared() } }
  }

  /** How tall a world is drawn, in vp: its height, or as tall as it is wide for 0; fill runs to the bottom of the window as a surface's does. */
  private worldHeight(node: LiveNode): number {
    let width = this.viewportWidth > 0 ? this.viewportWidth : 360
    if (node === this.fullWorld && this.rootHeight > 0) { return this.rootHeight }
    if ((node.style === 'fill' || node.style === 'full') && !this.embedded && node.layoutHeight > 0) { return node.layoutHeight }
    return node.minimum > 0 ? node.minimum : width
  }

  private worldArea(node: LiveNode, now: Area): void {
    let box = this.worlds.get(node)
    if (box !== undefined) { box.setSize(Number(now.width), Number(now.height), this.getUIContext().vp2px(1)) }
    if ((node.style === 'fill' || node.style === 'full') && node !== this.fullWorld) {
      this.fitFill(node, Number(now.globalPosition.y), Number(now.height))
    }
  }

  private setFullWorld(node: LiveNode | null): void {
    if (node === this.fullWorld) { return }
    this.fullWorld = node
    // Opened from its corner button, with no state change to describe its scene again: whether it is dark comes from the
    // box showing it, or its caption is drawn in the theme's ink on black.
    let box = node !== null ? this.worlds.get(node) : undefined
    this.fullWorldDark = box !== undefined && box.dark
    this.fullWorldEpoch++
  }

  /** The title of the Header beside a full-screen world, which full screen leaves out: '' when there is none. */
  private fullWorldTitle(world: LiveNode): string {
    let header = this.fullWorldHeader(world)
    return header !== null ? header.text : ''
  }

  /** The Header's supporting line (how to use the world: drag to turn, tap a planet), which full screen would lose. */
  private fullWorldHint(world: LiveNode): string {
    let header = this.fullWorldHeader(world)
    return header !== null ? header.value.trim() : ''
  }

  private fullWorldHeader(world: LiveNode): LiveNode | null {
    let parent = this.liveRoot !== null ? this.parentOf(this.liveRoot!, world) : null
    if (parent === null) { return null }
    let header = parent.children.find((child: LiveNode): boolean => child.kind === 'header')
    return header !== undefined ? header : null
  }

  /** The caption over a full-screen world: the text of the plain Texts beside it in its column, the result line(s). */
  private fullWorldCaption(world: LiveNode): string[] {
    let parent = this.liveRoot !== null ? this.parentOf(this.liveRoot!, world) : null
    if (parent === null) { return [] }
    return parent.children.filter((child: LiveNode): boolean => child.kind === 'text' && child.text.trim().length > 0)
      .map((child: LiveNode): string => child.text.trim())
  }

  private parentOf(at: LiveNode, child: LiveNode): LiveNode | null {
    for (let c of at.children) {
      if (c === child) { return at }
      let found = this.parentOf(c, child)
      if (found !== null) { return found }
    }
    return null
  }

  /**
   * The stick over a world with a player (scene.player), bottom left, and its buttons bottom right, one over the other,
   * when the player has them (action, then fire): the host's, drawn the same in every program. The stick is its own touch target, so a thumb on it steers
   * while another finger turns the camera; the knob follows the thumb, and lifting lets go.
   */
  @LocalBuilder
  worldStick(node: LiveNode) {
    Column() {
      Row() {
        Stack() {
          Circle()
            .width(STICK_SIZE)
            .height(STICK_SIZE)
            .fill(this.t().surface)
            .fillOpacity(0.45)
            .stroke(this.t().ink)
            .strokeOpacity(0.25)
            .strokeWidth(1.5)
          Circle()
            .width(STICK_KNOB)
            .height(STICK_KNOB)
            .fill(this.t().surface)
            .fillOpacity(0.92)
            .stroke(this.t().ink)
            .strokeOpacity(0.35)
            .strokeWidth(1.5)
            .translate({ x: this.drawnWorld(node).knobX * (STICK_SIZE - STICK_KNOB) / 2,
              y: this.drawnWorld(node).knobY * (STICK_SIZE - STICK_KNOB) / 2 })
        }
        .width(STICK_SIZE)
        .height(STICK_SIZE)
        .accessibilityText('Steer')
        .hitTestBehavior(HitTestMode.Block)
        .onTouch((event: TouchEvent) => { this.stickTouch(node, event) })
        // The thumb's drag is the stick's: the page must not scroll under it, nor the world take it for a camera turn.
        .gesture(PanGesture({ distance: 1 }))
        .onGestureJudgeBegin((_info: GestureInfo, _event: BaseGestureEvent) => GestureJudgeResult.CONTINUE)
        if (this.drawnWorld(node).action.length > 0 || this.drawnWorld(node).fire.length > 0) {
          // The player's buttons, one over the other: the action's, then the second (fire) under it, nearer the thumb.
          Column({ space: 12 }) {
            if (this.drawnWorld(node).action.length > 0) {
              this.worldButton(node, false)
            }
            if (this.drawnWorld(node).fire.length > 0) {
              this.worldButton(node, true)
            }
          }
          .alignItems(HorizontalAlign.End)
          // As the row round it: the gap between the buttons passes a finger through to the world.
          .hitTestBehavior(HitTestMode.None)
        }
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(VerticalAlign.Bottom)
      .padding({ left: 20, right: 20, bottom: 20 + (this.fullWorldEpoch >= 0 && node === this.fullWorld ?
        this.snackbarRoom() + this.bottomRoom : 0) })
      // None, not Transparent: a finger on the stick or the button is theirs alone (Transparent would hand it to the
      // world under them as well, a tap or a camera turn), and one anywhere else passes through to the world.
      .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .hitTestBehavior(HitTestMode.None)
  }

  /**
   * One of the player's buttons over a world, the action's or (second) the fire one; pressed, it sends "action" with its
   * label. The label is read here, not passed in, so a new one is drawn.
   */
  @Builder
  worldButton(node: LiveNode, second: boolean) {
    Button(second ? this.drawnWorld(node).fire : this.drawnWorld(node).action)
      .fontSize(16)
      .fontWeight(600)
      .fontColor(this.t().ink)
      .backgroundColor(this.t().surface)
      .opacity(0.92)
      .height(56)
      .padding({ left: 22, right: 22 })
      .onClick(() => { this.worldAction(node, second ? this.drawnWorld(node).fire : this.drawnWorld(node).action) })
      .hitTestBehavior(HitTestMode.Block)
  }

  /** A thumb on the stick: where it is from the stick's centre, as a share of how far the knob can go, steers the player. */
  private stickTouch(node: LiveNode, event: TouchEvent): void {
    let box = this.worlds.get(node)
    if (box === undefined || this.disposed || event.changedTouches.length === 0) { return }
    let touch = event.changedTouches[0]
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      box.setStick(0, 0)
      return
    }
    let reach = (STICK_SIZE - STICK_KNOB) / 2
    box.setStick((touch.x - STICK_SIZE / 2) / reach, (touch.y - STICK_SIZE / 2) / reach)
    if (event.type === TouchType.Down && !this.previewOnly && !this.pageHidden &&
        (this.error.length === 0 || this.error === this.worldTransitionError)) {
      this.startSurfaceLoop()
    }
  }

  /**
   * A player's button: the event "action" to the world's handler, with where the player is, the way it faces (dx, dy,
   * dz) and the button's label in other.
   */
  private worldAction(node: LiveNode, label: string): void {
    let box = this.worlds.get(node)
    if (box === undefined || this.previewOnly || node.action.length === 0) { return }
    let player = playerOf(box.appliedSpec())
    if (player === null) { return }
    let at = box.playerAt()
    let p = at !== null ? at : player.position
    console.info('VERA-WORLD event action body=' + player.id + ' button=' + label)
    box.noteInput('action')
    this.dispatchFieldAction(node.action, scenePayload('action', player.id, label, p[0], p[1], p[2], 0, [], [],
      box.playerFacing()), true, node)
  }

  /** The corner button of a world: full screen, or back to the normal screen from it. */
  @LocalBuilder
  worldFullButton(node: LiveNode) {
    Row() {
      Button({ type: ButtonType.Circle }) {
        // Out of full screen is back to the app's buttons under the world: a chevron up, so it is not mistaken for the
        // Generate page's own collapse button beside it, which leaves the program's full screen.
        SymbolGlyph($r(this.fullWorldEpoch >= 0 && node === this.fullWorld ? 'sys.symbol.chevron_up' :
          'sys.symbol.arrow_up_left_and_arrow_down_right'))
          .fontSize(16)
          .fontColor([this.t().ink])
      }
      .width(36)
      .height(36)
      .backgroundColor(this.t().surface)
      .opacity(0.9)
      .accessibilityText(this.fullWorldEpoch >= 0 && node === this.fullWorld ? 'Show the controls' : 'Full screen')
      .onClick(() => { this.setFullWorld(node === this.fullWorld ? null : node) })
    }
    .width('100%')
    // The left corner: on the Generate screen the page's own buttons sit over the right one.
    .justifyContent(FlexAlign.Start)
    .padding(8)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /**
   * A "fill" surface or world takes the window from its top down, less what the program puts under it -- a result line,
   * a row of buttons -- so that stays on screen instead of being pushed below it. What is under it is the content
   * column's bottom less the box's: growing the box moves both, so it settles in one pass. With something under it the
   * box also leaves the room the host keeps over the bottom (bottomRoom), as the content does; a box that is last on the
   * screen runs under that, as it always has.
   */
  private fitFill(node: LiveNode, top: number, height: number): void {
    if (this.embedded || this.rootHeight <= 0) { return }
    this.fillBoxes.set(node, [top, height])
    let under = 0
    if (this.contentHeight > 0) {
      let padding = this.snackbarRoom() + this.bottomRoom
      under = Math.max(0, this.contentTop + this.contentHeight - padding - (top + height))
      if (under >= 1) { under += this.bottomRoom }
    }
    let want = Math.max(160, this.rootTop + this.rootHeight - this.snackSpace - top - under)
    // A whole vp, for the same reason viewportWidth is guarded: a re-layout a fraction different would write again.
    if (Math.abs(want - node.layoutHeight) >= 1) { node.layoutHeight = want }
  }

  /**
   * The content column moved or changed height: what sits under each "fill" box may have, so fit them again -- after
   * the layout pass's other callbacks, so each box's place is from the same pass as the column's and a box that grew
   * is not counted twice (once in the column, once as stale room under itself).
   */
  private contentArea(now: Area): void {
    this.contentTop = Number(now.globalPosition.y)
    this.contentHeight = Number(now.height)
    if (this.fillBoxes.size === 0 || this.fillRefit) { return }
    this.fillRefit = true
    setTimeout(() => {
      this.fillRefit = false
      if (this.disposed) { return }
      for (let entry of Array.from(this.fillBoxes.entries())) {
        if (!this.isLiveNode(entry[0])) { this.fillBoxes.delete(entry[0]); continue }
        this.fitFill(entry[0], entry[1][0], entry[1][1])
      }
    }, 0)
  }

  /**
   * Fingers on a world. A drag on empty space turns the camera and two fingers pinch it nearer or further when the
   * program's camera orbits (the box does both itself, nothing reaches the program); a drag that started on a body is a "swipe" when it lifts; a tap is a raycast,
   * and what it hit goes to the event handler as a "tap". Both go the way every tap goes, through the field-action queue
   * -- the tap unless the world, its handler or the program changed while the ray was cast.
   */
  private worldTouch(node: LiveNode, event: TouchEvent): void {
    if (this.disposed || event.changedTouches.length === 0) { return }
    let box = this.worlds.get(node)
    if (box === undefined) { return }
    let touch = event.changedTouches[0]
    if (event.type === TouchType.Down) {
      box.touchDown(touch.id, touch.x, touch.y, this.getUIContext().vp2px(1))
      return
    }
    if (event.type === TouchType.Move) {
      // Every finger down, not only the first changed one: a pinch needs where both are.
      let fingers = event.touches.length > 0 ? event.touches : event.changedTouches
      for (let f of fingers) { box.touchMove(f.id, f.x, f.y) }
      return
    }
    if (event.type !== TouchType.Up) {
      box.touchCancel()
      return
    }
    let gesture: WorldGesture | null = box.touchUp(touch.id, touch.x, touch.y)
    if (gesture === null || this.previewOnly || node.action.length === 0) { return }
    let action = node.action
    if (gesture.kind === 'swipe') {
      console.info('VERA-WORLD event swipe body=' + gesture.body + ' speed=' + gesture.speed.toFixed(2))
      this.dispatchFieldAction(action, scenePayload('swipe', gesture.body, '', gesture.x, 0, gesture.z, gesture.speed, [], []),
        true, node)
      return
    }
    let generation = this.effectGeneration
    let nodeGeneration = node.fieldGeneration
    let tapped = box
    tapped.pick(touch.x, touch.y).then((pick: WorldPick | null) => {
      if (pick === null || this.disposed || this.previewOnly || generation !== this.effectGeneration ||
          this.liveRoot === null || !this.isLiveNode(node) || node.kind !== 'world' || node.action !== action ||
          node.fieldGeneration !== nodeGeneration || this.worlds.get(node) !== tapped) {
        console.info('VERA-WORLD event dropped kind=tap reason=changed-during-pick')
        return
      }
      // Logged once the ray is cast: before it, the body is not known yet.
      console.info('VERA-WORLD event tap body=' + pick.body + (pick.part.length > 0 ? ' part=' + pick.part : ''))
      // A group's tap tells the part in other; dx, dy, dz are the ray through the finger.
      tapped.noteInput('tap')
      this.dispatchFieldAction(action, scenePayload('tap', pick.body, pick.part, pick.x, pick.y, pick.z, 0, [], [],
        [pick.dx, pick.dy, pick.dz]), true, node)
    }).catch((e: Error) => {
      console.warn('VERA-WORLD pick failed: ' + e.message)
    })
  }

  private surfaceMove(action: string, value: InputPayload, node: LiveNode, input: SurfaceInput): void {
    let next = this.captureFieldAction(action, value, false, node)
    next.traceKind = 'SURFACE_MOVE'
    next.surfaceInput = input
    next.surfaceId = value.id
    let post = new PreviewPost('MOVE')
    post.key = action + ':' + value.id.toString()
    post.action = next
    this.queuePost(post)
  }

  /**
   * Take the look from the root of the frame, if the program named one.
   *
   * A program that does not use ui.AppTheme -- which is every program written
   * before it existed, and both benchmark artifacts -- resolves to 'clean',
   * so existing projects receive the refreshed typography and palette too.
   * Their source, bytecode, handlers and saved state keep the same contracts.
   */
  private reconcileTheme(root: VeraUiNode | null): void {
    let preset = 'clean'
    let primary = ''
    if (root !== null && root!.kind === 'apptheme') {
      preset = root!.style
      primary = root!.value
    }
    if (this.theme.preset === preset && this.theme.primary === primary &&
        this.theme.dark === this.dark) { return }
    this.theme.preset = preset
    this.theme.primary = primary
    this.theme.dark = this.dark
    // Written last, because writing it is what triggers the redraw.
    this.theme.resolved = resolveTheme(preset, primary, this.dark)
  }

  /**
   * The theme, for a render branch.
   *
   * Every branch reaches the table through here, so every branch reads the
   * traced field and is therefore rebuilt when the table is replaced. A branch
   * that cached it instead would stay at the look it was first built with.
   */
  private t(): ResolvedTheme {
    return this.theme.resolved
  }

  private handleAction(action: string, value: number, node: LiveNode | null = null): void {
    this.dispatchFieldAction(action, numberPayload(value), true, node)
  }

  /**
   * A field commit dispatches directly, not through the deferred-action queue: it must precede any
   * control action already queued (a pending text commit comes first), and it deliberately does not
   * flush sibling fields, whose debounce deadlines are independent. A handler that reads another field
   * sees its last committed value; control actions, surface gestures and slow tickers flush all ready
   * edits before they dispatch.
   */
  private handleStringAction(action: string, value: string): void {
    this.dispatch(action, stringPayload(value), true, 'FIELD')
  }

  private handleBoolAction(action: string, value: boolean, node: LiveNode | null = null): void {
    this.dispatchFieldAction(action, booleanPayload(value), true, node)
  }

  private fieldActionState(node: LiveNode): string {
    if (node.kind === 'slider') { return JSON.stringify([node.minimum, node.maximum]) }
    if (node.kind === 'toggle' || node.kind === 'checkbox') { return '' }
    if (node.kind === 'numberfield' || node.kind === 'timefield' || node.kind === 'datefield') {
      return JSON.stringify([node.label, node.numberValue, node.minimum, node.maximum, node.step])
    }
    if (node.kind === 'select' || node.kind === 'tabs') { return JSON.stringify([node.label, node.options]) }
    return JSON.stringify([node.eventValue, node.text, node.label])
  }

  /** A world's event (a settle, a hit, a tap) that fieldActionCurrent refused never reaches its handler: say why. */
  private logWorldDrop(next: FieldAction): void {
    if (next.nodeKind !== 'world') { return }
    console.info('VERA-WORLD event dropped kind=' + (next.payload.scene?.kind || '?') + ' reason=' + this.fieldActionStaleReason(next))
  }

  /** Why fieldActionCurrent refuses an action, for the log: the first guard it fails. */
  private fieldActionStaleReason(next: FieldAction): string {
    if (next.generation !== this.effectGeneration) { return 'program-generation' }
    if (this.disposed) { return 'disposed' }
    if (this.previewOnly) { return 'preview' }
    for (let i = 0; i < next.dependencies.length; i++) {
      if (next.dependencies[i].fieldCancellation !== next.dependencyCancellations[i]) { return 'field-edited' }
    }
    if (next.node === null) { return 'none' }
    let node = next.node!
    if (this.liveRoot === null || !this.isLiveNode(node)) { return 'node-gone' }
    if (node.kind !== next.nodeKind) { return 'node-kind' }
    if (!node.enabled) { return 'node-disabled' }
    if (node.action !== next.action) { return 'handler-changed' }
    if (node.fieldGeneration !== next.nodeGeneration) { return 'node-generation' }
    if (this.fieldActionState(node) !== next.nodeState) { return 'node-state' }
    return 'none'
  }

  private fieldActionCurrent(next: FieldAction): boolean {
    if (next.generation !== this.effectGeneration || this.transitioning || this.disposed || this.previewOnly) {
      StageTrace.emit(this.traceOwner, 'FIELD_ACTION_DROP', { action: next.action, reason: 'effectGeneration' })
      return false
    }
    for (let i = 0; i < next.dependencies.length; i++) {
      if (next.dependencies[i].fieldCancellation !== next.dependencyCancellations[i]) {
        StageTrace.emit(this.traceOwner, 'FIELD_ACTION_DROP', { action: next.action, reason: 'fieldCancellation' })
        return false
      }
    }
    if (next.node === null) { return true }
    let node = next.node!
    if (next.surfaceInput !== null) {
      let input = next.surfaceInput!
      let inputs = this.surfaceInputs.get(node)
      let box = this.surfaces.get(node)
      let current = this.liveRoot !== null && this.isLiveNode(node) && node.kind === 'surface' &&
        node.value === next.action && node.fieldGeneration === input.nodeGeneration &&
        input.generation === this.effectGeneration && inputs !== undefined &&
        inputs.get(next.surfaceId) === input &&
        box !== undefined && box.width > 0 && box.height > 0
      if (!current) { StageTrace.emit(this.traceOwner, 'FIELD_ACTION_DROP', { action: next.action, reason: 'nodeState' }) }
      return current
    }
    let current = this.liveRoot !== null && this.isLiveNode(node) &&
      node.kind === next.nodeKind && node.enabled && node.action === next.action &&
      node.fieldGeneration === next.nodeGeneration && this.fieldActionState(node) === next.nodeState
    if (!current) { StageTrace.emit(this.traceOwner, 'FIELD_ACTION_DROP', { action: next.action, reason: 'nodeState' }) }
    return current
  }

  private releaseSurfaceAction(next: FieldAction): void {
    if (next.surfaceInput === null || next.node === null ||
        (next.payload.phase !== 'up' && next.payload.phase !== 'cancel')) { return }
    let inputs = this.surfaceInputs.get(next.node!)
    if (inputs === undefined || inputs.get(next.surfaceId) !== next.surfaceInput) { return }
    inputs.delete(next.surfaceId)
    if (inputs.size === 0) { this.surfaceInputs.delete(next.node!) }
  }

  private scheduleFieldActions(): void {
    if (this.renderingDepth > 0 || this.fieldActionsNeedResume) { return }
    this.fieldActionsNeedResume = true
    let generation = this.effectGeneration
    Promise.resolve().then(() => {
      this.fieldActionsNeedResume = false
      if (generation !== this.effectGeneration || (this.disposed && !this.draining)) { return }
      this.resumeFieldActions()
      this.resumePosts()
      if (this.effectsBridge !== null) { this.effectsBridge!.onMailboxWritable() }
    })
  }

  private captureFieldAction(action: string, payload: InputPayload,
    persist: boolean = true, node: LiveNode | null = null): FieldAction {
    let next = new FieldAction(action, payload, this.effectGeneration, persist, node)
    if (node !== null) {
      next.nodeState = this.fieldActionState(node!)
      let form = this.fieldFormOf(node!)
      if (form !== null) {
        let fields: LiveNode[] = []
        this.collectFieldDependencies(form!, fields)
        next.dependencies = fields
        next.unknownDependencies = false
      }
    }
    if (next.unknownDependencies && this.liveRoot !== null) {
      this.collectFieldDependencies(this.liveRoot!, next.dependencies)
    }
    next.dependencyCancellations = next.dependencies.map((field: LiveNode): number => field.fieldCancellation)
    return next
  }

  private dispatchFieldAction(action: string, payload: InputPayload,
    persist: boolean = true, node: LiveNode | null = null, traceKind: string = 'HANDLER'): void {
    if (this.disposed || this.previewOnly) { return }
    let next = this.captureFieldAction(action, payload, persist, node)
    next.traceKind = traceKind
    this.enqueueFieldAction(next)
  }

  private enqueueFieldAction(next: FieldAction): void {
    if (!this.fieldActionCurrent(next)) {
      this.logWorldDrop(next)
      this.releaseSurfaceAction(next)
      return
    }
    next.order = ++this.nextOrder
    this.postSegment++
    let node = next.node
    let action = next.action
    let last = this.fieldActions.length > 0
      ? this.fieldActions[this.fieldActions.length - 1] : undefined
    if (node !== null && node!.kind === 'slider' && last !== undefined && last.node === node &&
        last.action === action && last.generation === next.generation &&
        last.nodeGeneration === next.nodeGeneration && last.nodeState === next.nodeState && !last.persist &&
        (this.posts.length === 0 || this.posts[this.posts.length - 1].order < last.order)) {
      StageTrace.emit(this.traceOwner, 'FIELD_ACTION_DROP', { action: last.action, reason: 'nodeState' })
      this.fieldActions[this.fieldActions.length - 1] = next
    } else {
      this.fieldActions.push(next)
    }
    StageTrace.emit(this.traceOwner, 'FIELD_ACTION_ENQUEUE', { action: next.action })
    this.syncEditGate()
    this.resumeFieldActions()
  }

  private resumeFieldActions(): void {
    if (this.renderingDepth > 0 || this.resumingFieldActions || this.transitioning || this.handle === null ||
        this.inFlight !== null || this.postingEffect || this.posting || this.postDrain || this.admissionBlocked) { return }
    this.resumingFieldActions = true
    try {
      while (this.inFlight === null && !this.admissionBlocked && !this.transitioning && (!this.disposed || this.draining)) {
        for (let node of Array.from(this.fieldEdits.keys())) {
          let edit = this.fieldEdits.get(node)
          if (edit !== undefined && edit.commitRequested) { this.commitField(node, edit.generation) }
          if (this.inFlight !== null || this.admissionBlocked || this.transitioning) { break }
        }
        if (this.inFlight !== null || this.admissionBlocked || this.transitioning) { break }
        let next = this.fieldActions[0]
        if (this.posts.length > 0 && (next === undefined || this.posts[0].order < next.order)) { break }
        if (next === undefined) { break }
        this.flushFields()
        if (this.inFlight !== null || this.admissionBlocked || this.fieldEdits.size > 0) { break }
        if (this.fieldActions[0] !== next) { continue }
        if (!this.fieldActionCurrent(next)) {
          this.fieldActions.shift()
          this.logWorldDrop(next)
          this.releaseSurfaceAction(next)
          continue
        }
        this.fieldActions.shift()
        StageTrace.emit(this.traceOwner, 'FIELD_ACTION_APPLY', { action: next.action })
        let result = this.postAction(next)
        if (result.status === 'BACKPRESSURE') {
          if (!this.disposed && !this.transitioning && next.generation === this.effectGeneration) { this.fieldActions.unshift(next) }
          if (this.inFlight === next) { this.inFlight = null }
          break
        }
      }
    } finally {
      this.resumingFieldActions = false
      this.syncEditGate()
      this.resumePosts()
    }
  }

  private inputEvent(next: FieldAction): InputEvent {
    let kind = next.traceKind
    if (next.payload.kind === 'POINTER') { kind = 'SURFACE_' + next.payload.phase.toUpperCase() }
    if (next.payload.kind === 'SCENE') { kind = 'SCENE' }
    return { appId: this.frameAppId, vmGeneration: this.frameVmGeneration, kind: kind,
      action: next.action, payload: next.payload, persist: next.persist, skipIfSame: next.nodeKind === 'world',
      draws: kind === 'SURFACE_MOVE' && this.surfaceSync === null && this.surfaceTimer < 0 ? this.surfaceDraws() : [] }
  }

  private postAction(next: FieldAction): AdmissionResult {
    if (this.handle === null) { return { status: 'REJECTED', reason: 'INVALID_HANDLE' } }
    next.posting = true
    this.inFlight = next
    this.syncEditGate()
    let result: AdmissionResult
    try {
      result = next.traceKind === 'TICK'
        ? this.runtime.postTick(this.handle!, { tickerId: next.tickerId, action: next.action, elapsed: next.payload.num }, true)
        : this.runtime.postInput(this.handle!, this.inputEvent(next))
    } catch (e) {
      result = { status: 'REJECTED', reason: (e as Error).message }
    }
    next.posting = false
    if (result.status === 'ACCEPTED' && result.inputSeq !== undefined) {
      next.inputSeq = result.inputSeq
      this.drainFrames()
      if (next.nodeKind === 'world') { this.completeWorldInput(next) }
      else { this.completeInput() }
    } else if (result.status === 'BACKPRESSURE') {
      this.admissionBlocked = true
    } else {
      if (this.inFlight === next) { this.inFlight = null }
      this.flushFailure = new Error(result.status === 'REJECTED' ? result.reason : 'Missing input sequence')
      this.releaseSurfaceAction(next)
    }
    if (result.status !== 'ACCEPTED') { this.drainFrames() }
    this.syncEditGate()
    return result
  }

  private completeWorldInput(next: FieldAction): void {
    let handle = this.handle!
    let generation = this.effectGeneration
    let barrier: Promise<string>
    try { barrier = this.runtime.requestSnapshot(handle) }
    catch (e) { barrier = Promise.reject(e as Error) }
    barrier.then((): void => {
      if (generation !== this.effectGeneration || this.handle !== handle || this.inFlight !== next) { return }
      this.inFlight = null
      this.observedErrors.delete(next.inputSeq)
      this.releaseSurfaceAction(next)
      this.syncEditGate()
      this.scheduleFieldActions()
    }, (error: Error): void => {
      if (generation !== this.effectGeneration || this.handle !== handle || this.inFlight !== next) { return }
      this.inFlight = null
      this.flushFailure = error
      this.syncEditGate()
      this.scheduleFieldActions()
    })
  }

  private completeInput(): void {
    let next = this.inFlight
    if (next === null || next.nodeKind === 'world' || next.posting || next.inputSeq < 0 ||
        (this.lastAppliedSeq < next.inputSeq && !this.observedErrors.has(next.inputSeq))) { return }
    this.observedErrors.delete(next.inputSeq)
    this.inFlight = null
    this.releaseSurfaceAction(next)
    this.syncEditGate()
    this.scheduleFieldActions()
  }

  private syncEditGate(): void {
    let pending = this.fieldEdits.size > 0 || this.fieldActions.length > 0 || this.inFlight !== null ||
      this.postingEffect || this.postEdits || this.posts.some((post: PreviewPost): boolean => post.kind === 'MOVE')
    if (this.handle !== null) { this.runtime.notifyEdits(this.handle!, pending) }
    if (this.flushFailure === null && (pending || this.posts.length > 0 || this.posting || this.postDrain || this.transitioning)) { return }
    let waiters = this.waiters
    this.waiters = []
    for (let waiter of waiters) {
      if (waiter.generation !== this.acquireGeneration) { waiter.reject(new Error('Preview activation changed')) }
      else if (this.flushFailure !== null) { waiter.reject(this.flushFailure!) }
      else { waiter.resolve() }
    }
  }

  private flushPendingInputFor(appId: string): Promise<void> {
    if (appId !== this.frameAppId || this.handle === null || (!this.draining && this.disposed)) {
      return Promise.reject(new Error('Preview is not active'))
    }
    if (this.flushFailure !== null) { return Promise.reject(this.flushFailure!) }
    let promise = new Promise<void>((resolve, reject) => {
      this.waiters.push(new PreviewWaiter(this.acquireGeneration, resolve, reject))
    })
    for (let edit of this.fieldEdits.values()) { edit.commitRequested = true }
    this.flushFields()
    this.resumeFieldActions()
    this.resumePosts()
    this.syncEditGate()
    return promise
  }

  private queuePost(post: PreviewPost): void {
    if (this.disposed || (this.transitioning && post.kind !== 'VIEW' && post.kind !== 'DRAW') ||
        (this.previewOnly && post.kind !== 'VIEW' && post.kind !== 'DRAW')) { return }
    post.order = ++this.nextOrder
    let stopping = post.surface !== null && post.surface!.worldStopping === true
    if (stopping) { this.postSegment++ }
    post.segment = this.postSegment
    if (stopping) { this.postSegment++ }
    let last = this.posts[this.posts.length - 1]
    if (last !== undefined && last.segment === post.segment && last.kind === post.kind && last.key === post.key) {
      if (post.kind === 'TICK' && last.tick !== null && post.tick !== null) { post.tick!.elapsed += last.tick!.elapsed }
      if (post.kind === 'SURFACE_FRAME' && last.surface !== null && post.surface !== null) {
        post.surface!.elapsed = Math.min(SURFACE_MAX_ELAPSED_MS, post.surface!.elapsed + last.surface!.elapsed)
        if (post.surface!.loopStartedAt === undefined) { post.surface!.loopStartedAt = last.surface!.loopStartedAt }
      }
      if (post.kind === 'DRAW') {
        for (let draw of last.draws) {
          if (!post.draws.some((next: DrawRequest): boolean =>
            next.nodeId === draw.nodeId && next.surfaceRevision === draw.surfaceRevision)) { post.draws.push(draw) }
        }
      }
      if (post.kind !== 'REFRESH') { post.order = last.order; this.posts.pop() }
    }
    this.posts.push(post)
    this.syncEditGate()
    this.resumePosts()
  }

  private resumePosts(): void {
    if (this.disposed || this.posting || this.postDrain || this.resumingFieldActions || this.transitioning || this.handle === null ||
        this.inFlight !== null || this.postingEffect || this.renderingDepth > 0 || this.admissionBlocked) { return }
    this.posting = true
    let progressed = false
    try {
      while (this.posts.length > 0 && this.inFlight === null && !this.admissionBlocked && !this.transitioning && !this.disposed) {
        let post = this.posts[0]
        if (this.fieldActions.length > 0 && this.fieldActions[0].order < post.order) { break }
        if (post.kind === 'MOVE') {
          if (progressed) { break }
          this.flushFields()
          if (this.inFlight !== null || this.fieldEdits.size > 0 || this.admissionBlocked || this.transitioning || this.disposed) { break }
          if (this.posts[0] !== post) { continue }
          if (post.action === null || !this.fieldActionCurrent(post.action!)) {
            this.posts.shift()
            progressed = true
            continue
          }
        }
        if (post.kind === 'MOVE') { this.postEdits = true; this.syncEditGate() }
        let result: AdmissionResult
        try {
          if (post.kind === 'VIEW') { result = this.runtime.requestView(this.handle!) }
          else if (post.kind === 'DRAW') { result = this.runtime.requestDraw(this.handle!, post.draws) }
          else if (post.kind === 'TICK') { result = this.runtime.postTick(this.handle!, post.tick!, false) }
          else if (post.kind === 'SURFACE_FRAME') { result = this.runtime.postSurfaceFrame(this.handle!, post.surface!) }
          else if (post.kind === 'MOVE') { result = this.runtime.postInput(this.handle!, this.inputEvent(post.action!)) }
          else { result = this.runtime.postRefresh(this.handle!, 'APP') }
        } catch (e) {
          result = { status: 'REJECTED', reason: (e as Error).message }
        }
        if (result.status === 'BACKPRESSURE') { this.admissionBlocked = true; break }
        if (this.posts[0] === post) { this.posts.shift() }
        progressed = true
        if (result.status === 'REJECTED') { this.flushFailure = new Error(result.reason) }
      }
    } finally {
      this.posting = false
      if (progressed && this.handle !== null && this.activeOptions.mode !== 'PREVIEW') { this.postDrain = true }
      this.syncEditGate()
    }
    if (progressed && this.handle !== null && this.activeOptions.mode !== 'PREVIEW') {
      let handle = this.handle!
      let generation = this.effectGeneration
      this.postDrain = true
      this.syncEditGate()
      let barrier: Promise<string>
      try { barrier = this.runtime.requestSnapshot(handle) }
      catch (e) { barrier = Promise.reject(e as Error) }
      barrier.then((): void => {
        if (generation !== this.effectGeneration || this.handle !== handle) { return }
        this.postDrain = false
        this.postEdits = false
        this.syncEditGate()
        this.scheduleFieldActions()
      }, (error: Error): void => {
        if (generation !== this.effectGeneration || this.handle !== handle) { return }
        this.postDrain = false
        this.postEdits = false
        this.flushFailure = error
        this.syncEditGate()
        this.scheduleFieldActions()
      })
    } else if (progressed && this.fieldActions.length > 0 && this.inFlight === null && !this.admissionBlocked) {
      this.scheduleFieldActions()
    }
  }

  /**
   * The single way a person's input reaches a program: the value is whatever
   * the component produces -- a number, a string or a boolean.
   */
  private dispatch(action: string, payload: InputPayload, persist: boolean = true, kind: string = 'HANDLER'): void {
    this.dispatchFieldAction(action, payload, persist, null, kind)
  }

  /**
   * Runs the intents the handler asked for, and brings each answer back the way
   * every other event arrives -- as a dispatch to a named handler.
   *
   * A late answer to a screen that has gone is dropped rather than pushed into
   * a VM that is no longer running.
   */
  private bridge(): HostEffectsBridge {
    if (this.effectsBridge === null) {
    let host: EffectResultHost = new PreviewEffectResultHost(
      (handle: ActorHandle, effectId: number, text: string): AdmissionResult => {
        if (this.admissionBlocked || this.transitioning || this.posting || this.postDrain || this.inFlight !== null ||
            this.fieldActions.length > 0 || this.fieldEdits.size > 0 || this.posts.length > 0) {
          return { status: 'BACKPRESSURE' }
        }
        let next = this.captureFieldAction('', stringPayload(text))
        next.traceKind = 'EFFECT_RESULT'
        next.posting = true
        this.inFlight = next
        this.postingEffect = true
        this.syncEditGate()
        try {
          let admission = this.runtime.postEffectResult(handle, effectId, text)
          next.posting = false
          if (admission.status === 'ACCEPTED' && admission.inputSeq !== undefined) {
            next.inputSeq = admission.inputSeq
            this.drainFrames()
            this.completeInput()
          } else {
            this.inFlight = null
            if (admission.status === 'BACKPRESSURE') { this.admissionBlocked = true }
            else { this.flushFailure = new Error(admission.status === 'REJECTED' ? admission.reason : 'Missing input sequence') }
          }
          return admission
        } catch (e) {
          if (this.inFlight === next) { this.inFlight = null }
          throw e as Error
        } finally {
          next.posting = false
          this.postingEffect = false
          this.drainFrames()
          this.syncEditGate()
          this.scheduleFieldActions()
        }
      })
      this.effectsBridge = new HostEffectsBridge(host, {
        askBeforeCalls: ASK_BEFORE_CALLS,
        traceOwner: this.traceOwner,
        onPending: (effect: EffectRequest | null): void => { if (!this.disposed) { this.pending = effect } },
        flushPendingInputFor: (appId: string): Promise<void> => this.flushPendingInputFor(appId),
        captureValidity: (effect: EffectRequest): (() => boolean) => {
          let next = this.captureFieldAction(effect.resultHandler, stringPayload(''))
          return (): boolean => !this.disposed && this.fieldActionCurrent(next)
        },
        readyToPost: (_effect: EffectRequest): boolean => !this.disposed && !this.transitioning &&
          !this.admissionBlocked && !this.posting && !this.postDrain && !this.postingEffect && this.inFlight === null && this.fieldEdits.size === 0 && this.fieldActions.length === 0 && this.posts.length === 0,
        onFailure: (_effect: EffectRequest | null, error: Error): void => {
          this.flushFailure = error
          console.error('VERA-EFFECT callback failed: ' + error.message)
          this.syncEditGate()
        }
      })
    }
    return this.effectsBridge!
  }

  private consentTitle(effect: EffectRequest): string {
    return effectConsentTitle(effect)
  }

  private consentTarget(effect: EffectRequest): string {
    return effect.rawTarget
  }

  private consentValues(effect: EffectRequest): string {
    return effectConsentValues(effect)
  }

  private allowPending(): void {
    if (this.disposed || this.effectsBridge === null) { return }
    this.effectsBridge!.allowPending()
  }

  private refusePending(): void {
    if (this.disposed || this.effectsBridge === null) { return }
    this.effectsBridge!.refusePending()
  }

  build() {
    Stack() {
      this.programFrame()
      // Drawn over the program, by the renderer, from the call the host is about
      // to send. The program supplies no text here and cannot dismiss it.
      if (this.pending !== null) {
        this.consentSheet(this.pending!)
      }
    }
    .width('100%')
    // Embedded, the box is as tall as the program. At 100% inside a list row it
    // takes the height of the whole list and the program sinks to its bottom.
    .height(this.embedded ? undefined : '100%')
    .alignContent(Alignment.Bottom)
  }

  @LocalBuilder
  consentSheet(effect: EffectRequest) {
    Column() {
      Column() {
        Text(this.consentTitle(effect))
          .fontSize(19).fontWeight(FontWeight.Bold)
          .fontColor(this.t().ink)
          .width('100%')
        Text(this.consentTarget(effect))
          .fontSize(12).fontFamily('monospace')
          .fontColor(this.t().inkMuted)
          .width('100%')
          .margin({ top: 4 })
        Text(this.consentValues(effect))
          .fontSize(13).fontFamily('monospace')
          .fontColor(this.t().inkStrong)
          .width('100%')
          .padding(10)
          .margin({ top: 12 })
          .backgroundColor(this.t().surface)
          .borderRadius(8)
        // Said plainly, because it is the part a person cannot check for
        // themselves: this call was written by a program, not by them.
        Text('This app wrote this call itself. Nothing has checked what it does.' +
          ' Allow it and this app stops asking for this one.')
          .fontSize(12)
          .fontColor(this.t().inkSoft)
          .width('100%')
          .margin({ top: 10 })
        Row() {
          Button('Not now')
            .fontSize(15)
            .layoutWeight(1)
            .backgroundColor(this.t().surface)
            .fontColor(this.t().ink)
            .onClick(() => { this.refusePending() })
          Button('Allow')
            .fontSize(15)
            .layoutWeight(1)
            .margin({ left: 10 })
            .backgroundColor(this.t().primary)
            .fontColor(this.t().onPrimary)
            .onClick(() => { this.allowPending() })
        }
        .width('100%')
        .margin({ top: 16 })
      }
      .width('100%')
      .padding(18)
      .backgroundColor(this.t().background)
      .borderRadius({ topLeft: 16, topRight: 16 })
    }
    .width('100%')
  }

  @LocalBuilder
  programFrame() {
    Column() {
      if (this.error.length > 0) {
        Text(this.error)
          .fontSize(14)
          .fontColor('#CC0000')
          .padding(16)
          .width('100%')
          .backgroundColor('#FFECEC')
      }
      if (this.hasRoot && this.liveRoot !== null) {
        // A snackbar is told to the person now, wherever they have scrolled to: it is drawn over the program, at the bottom of its
        // window, not at the end of the content where it was written (the end of a long screen is out of sight).
        Stack({ alignContent: Alignment.Bottom }) {
          if (this.embedded) {
            // No Scroll of its own and no fixed height: the card is as tall as
            // the program, and whatever it sits in does the scrolling. A Scroll
            // here would take a drag that began on the program and leave the
            // page behind it unmoved.
            Column() {
              ForEach([this.programId], (_id: number) => {
                this.renderNode(this.liveRoot!, 'root')
              }, (id: number) => id.toString())
            }
            .width('100%')
            .padding({ bottom: this.snackbarRoom() })
          } else if (this.fullWorldEpoch >= 0 && this.fullWorld !== null && this.isLiveNode(this.fullWorld!)) {
            // One world over the whole program, nothing to press but the world itself: the program's lines of text (what
            // was tapped, the result) are a caption over its bottom, and its buttons wait on the normal screen.
            Stack({ alignContent: Alignment.Bottom }) {
              this.renderNode(this.fullWorld!, 'root')
              Column({ space: 2 }) {
                ForEach(this.fullWorldCaption(this.fullWorld!), (line: string) => {
                  Text(line)
                    .fontSize(15)
                    .fontFamily(this.textFamily())
                    .fontColor(this.fullWorldDark ? '#E8ECF8' : this.t().ink)
                    .textAlign(TextAlign.Center)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .textShadow({ radius: 6, color: this.fullWorldDark ? '#C0000000' : '#00000000', offsetX: 0, offsetY: 1 })
                }, (line: string, index: number) => index.toString() + ':' + line)
              }
              .width('100%')
              // Over a world with a player the caption sits above the stick, not under the thumb.
              .padding({ left: 24, right: 24, bottom: 16 + this.snackbarRoom() + this.bottomRoom +
                (this.drawnWorld(this.fullWorld!).hasPlayer ? STICK_SIZE + 16 : 0) })
              .hitTestBehavior(HitTestMode.Transparent)
              // The app's name, which the Header gave and full screen leaves out, beside the corner button.
              // Under it, the Header's supporting line: what to do with the world, which nothing else on this screen says.
              if (this.fullWorldTitle(this.fullWorld!).length > 0) {
                Column({ space: 2 }) {
                  Text(this.fullWorldTitle(this.fullWorld!))
                    .fontSize(15)
                    .fontWeight(600)
                    .fontFamily(this.textFamily())
                    .fontColor(this.fullWorldDark ? '#E8ECF8' : this.t().ink)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (this.fullWorldHint(this.fullWorld!).length > 0) {
                    Text(this.fullWorldHint(this.fullWorld!))
                      .fontSize(12)
                      .fontFamily(this.textFamily())
                      .fontColor(this.fullWorldDark ? '#A8B0C8' : this.t().inkSoft)
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .position({ x: 56, y: 14 })
                .width('45%')
                .hitTestBehavior(HitTestMode.Transparent)
              }
            }
            .width('100%')
            .height('100%')
            .onAreaChange((_old: Area, now: Area) => {
              this.rootTop = Number(now.globalPosition.y)
              this.rootHeight = Number(now.height)
            })
          } else {
            Scroll(this.rootScroller) {
              Column() {
                ForEach([this.programId], (_id: number) => {
                  this.renderNode(this.liveRoot!, 'root')
                }, (id: number) => id.toString())
              }
              .width('100%')
              // Room under the content for the snackbars, so the last rows can be scrolled out from under them, and for
              // what the host lays over the corner.
              .padding({ bottom: this.snackbarRoom() + this.bottomRoom })
              .onAreaChange((_old: Area, now: Area) => { this.contentArea(now) })
            }
            .width('100%')
            .height('100%')
            .onAreaChange((_old: Area, now: Area) => {
              this.rootTop = Number(now.globalPosition.y)
              this.rootHeight = Number(now.height)
            })
            .onDidScroll((_x: number, dy: number) => {
              let top = this.rootScroller.currentOffset().yOffset <= READING_TOP
              let down = !top && (dy > 2 ? true : (dy < -2 ? false : this.readingDown))
              if (down !== this.readingDown) {
                this.readingDown = down
                this.onReadingDown(down)
              }
            })
            // Scroll centres its content by default, which leaves a generated
            // program floating in the middle of the box instead of starting where
            // a real app would.
            .align(Alignment.Top)
          }
          Column() {
            ForEach(this.snackbarsOf(this.liveRoot!), (bar: LiveNode) => {
              this.snackbarBar(bar)
            }, (bar: LiveNode, index: number) => index.toString() + ':' + bar.text)
          }
          .width('100%')
          .onAreaChange((_old: Area, now: Area) => {
            let h = Number(now.height)
            if (Math.abs(h - this.snackSpace) >= 1) { this.snackSpace = h }
          })
        }
        .width('100%')
        .layoutWeight(this.embedded ? 0 : 1)
      }
    }
    .width('100%')
    .height(this.embedded ? undefined : '100%')
    // Writing this back is what makes the column counts adapt. Guarded by a
    // whole vp: the write triggers a re-layout, and a re-layout that reports a
    // width a fraction different would write again, and so on.
    .onAreaChange((_old: Area, now: Area) => {
      let w = now.width as number
      if (Math.abs(w - this.viewportWidth) >= 1) { this.viewportWidth = w }
    })
    // The page behind the program, so a theme whose background is not white
    // reaches past the tree to the edges of the screen. Reading the theme here
    // also subscribes build() itself, so a program that changes its own preset
    // repaints the page and not only its contents.
    .backgroundColor(this.t().background)
  }

  /**
   * Whether this row shares its width by weight instead of wrapping. Cells and
   * cards are laid out proportionally -- a tic-tac-toe row, a pair of stat
   * cards -- and wrapping would collapse them.
   */
  private rowDistributes(node: LiveNode): boolean {
    for (let child of node.children) {
      if (child.kind === 'cell' || child.kind === 'card') { return true }
    }
    return false
  }

  @LocalBuilder
  renderChildren(node: LiveNode) {
    // Keyed by position and kind. Position, because reconcile keeps a node's
    // identity across frames, so a retained component is still reading a node
    // that is being updated and only the changed fields re-render.
    //
    // Kind as well, because renderNode picks its branch with an if/else chain
    // when the component is built, and a retained component cannot switch
    // branches later. A position that turns from a text into a listitem -- an
    // empty-state line replaced by the first real row -- would otherwise stay a
    // text forever. Including the kind makes ArkUI rebuild exactly then, and
    // never merely because some text changed.
    ForEach(node.children, (child: LiveNode) => {
      this.renderNode(child, node.kind)
    }, (child: LiveNode, index: number) => index.toString() + ':' + child.kind)
  }

  /**
   * Values the theme does not own.
   *
   * The line is: anything that makes one preset look like a different app --
   * colour, type size, radius, padding -- comes from VeraTheme. Structural
   * dimensions that are about fitting on a phone rather than about character --
   * how tall a canvas band is, how far a scroll may grow, how big an image box
   * is -- stay here as literals, because varying them per preset would change
   * what fits on the screen rather than how it looks.
   */
  private gridPad(style: string): number {
    let t = this.t()
    if (style === 'compact') { return t.padGrid - 2 }
    if (style === 'spacious') { return t.padGrid + 2 }
    return t.padGrid
  }

  /** What a Section's role fills its box with; transparent for plain content. */
  private sectionFill(style: string): string {
    let t = this.t()
    if (style === 'hero') { return t.primaryFill }
    if (style === 'summary' || style === 'content') { return t.surface }
    if (style === 'warning') { return t.warningFill }
    return '#00000000'
  }

  /**
   * The role a section is drawn as. A summary or content section whose drawn children are all frames of their own
   * (list groups, cards, tables, timelines, tile grids, banners) is drawn plain: filling it too would put a card inside a card,
   * two edges and two shadows around one thing.
   */
  private sectionLook(node: LiveNode): string {
    if (node.style !== 'summary' && node.style !== 'content') { return node.style }
    // A When that is false decodes to an empty spacer; it neither draws nor counts.
    let framed = 0
    for (let child of node.children) {
      if (child.kind === 'spacer') { continue }
      if (['listgroup', 'card', 'table', 'timeline', 'tilegrid', 'banner'].indexOf(child.kind) < 0) { return node.style }
      framed++
    }
    // Two framed children are each their own card: filling the section around them drew a card around both, which is
    // what happened when a detail card opened under a list.
    return framed >= 1 ? 'plain' : node.style
  }

  private sectionFills(style: string): boolean {
    return style === 'hero' || style === 'summary' || style === 'content' || style === 'warning'
  }

  /**
   * A role that fills its box insets its content from the fill. One that does
   * not still holds its content off the edge of the screen -- which it did not
   * at first: a plain section ran its heading and its controls flush into the
   * left margin while the Header above sat properly indented, and a
   * SectionHeader's count ran off the right edge and was cut in half.
   */
  private sectionPadX(style: string): number {
    return this.sectionFills(style) ? this.t().padCard : this.t().padBase
  }

  /** Vertical padding belongs to the fill, so an unfilled section has none. */

  /** A ui.Snackbar, drawn over the program at the bottom of its window (see programFrame). */
  @LocalBuilder
  snackbarBar(node: LiveNode) {
      Row({ space: this.t().gapBase }) {
        Text(node.text)
          .fontSize(this.t().sizeBody)
          .fontFamily(this.textFamily())
          .fontColor(readableInk(toneEdge(this.t(), node.style, this.t().inkStrong)))
          .layoutWeight(1)
        if (node.value.length > 0) {
          Button(node.value)
            .height(this.t().chipHeight)
            .fontSize(this.t().sizeBody)
            .fontFamily(this.textFamily())
            .type(ButtonType.Capsule)
            .backgroundColor('#00000000')
            .fontColor(readableInk(toneEdge(this.t(), node.style, this.t().inkStrong)))
            .onClick(() => {
              if (node.action.length > 0) { this.handleAction(node.action, node.eventValue, node) }
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding(this.t().padBase)
      .backgroundColor(toneEdge(this.t(), node.style, this.t().inkStrong))
      .borderRadius(this.t().radiusControl)
      .margin({ left: this.t().padBase, right: this.t().padBase, bottom: this.t().padBase })
  }

  /** The space kept free under the program for its snackbars: none when there are none up. */
  private snackbarRoom(): number {
    return this.liveRoot !== null && this.snackbarsOf(this.liveRoot).length > 0 ? this.snackSpace : 0
  }

  /** Every ui.Snackbar in the program's tree, for the window to draw. */
  private snackbarsOf(node: LiveNode): LiveNode[] {
    let found: LiveNode[] = []
    if (node.kind === 'snackbar') { found.push(node) }
    for (let child of node.children) { found = found.concat(this.snackbarsOf(child)) }
    return found
  }

  /**
   * A row is drawn dimmed only when it is a control that is switched off. A row with no action is information, not a control that is
   * not available: it is read, so it is drawn as full-strength as any other text.
   */
  private rowOpacity(node: LiveNode): number {
    return node.enabled || node.action.length === 0 ? 1 : 0.5
  }

  /** The one-button action bars that follow a list row, each with the row it belongs to (see rowChildren). */
  private rowBar: Map<LiveNode, LiveNode> = new Map<LiveNode, LiveNode>()

  /**
   * A list group's children without the action bars that hold one button for the row above them: that button is drawn at the
   * end of the row (rowButton), so a stop with a Navigate button is one line, not a line and a bar, and a row's tone (a stop
   * reached) covers the whole of it. A bar of two buttons stays below.
   */
  private rowChildren(node: LiveNode): LiveNode[] {
    let out: LiveNode[] = []
    let i = 0
    while (i < node.children.length) {
      let row = node.children[i]
      out.push(row)
      let next = i + 1 < node.children.length ? node.children[i + 1] : null
      if (row.kind === 'listitem' && next !== null && next.kind === 'actionbar' && next.children.length === 1 &&
          (next.children[0].kind === 'button' || next.children[0].kind === 'iconbutton')) {
        this.rowBar.set(row, next.children[0])
        i += 2
      } else {
        this.rowBar.delete(row)
        i++
      }
    }
    return out
  }

  private rowButton(row: LiveNode): LiveNode[] {
    let button = this.rowBar.get(row)
    return button !== undefined ? [button] : []
  }

  /** What the person typed into a ui.NumberField, until they are done: node by node. */
  private numberDraft: Map<LiveNode, string> = new Map<LiveNode, string>()

  /** Takes a typed number: whole, within the field's limits; the field is drawn again either way, so it shows the value the program holds. */
  private commitNumber(node: LiveNode): void {
    let typed = this.numberDraft.get(node)
    if (typed === undefined) { return }
    this.numberDraft.delete(node)
    let value = Math.round(parseFloat(typed))
    if (!isNaN(value) && node.action.length > 0) {
      value = Math.max(node.minimum, Math.min(node.maximum, value))
      if (value !== node.numberValue) { this.handleAction(node.action, value, node) }
    }
    this.numberEpoch++
  }

  /** A ui.NumberField's step as a whole number of at least 1, whatever the program passed (0, -5 and 2.5 included). */
  private numberStep(node: LiveNode): number {
    let step = Math.round(node.step)
    return isNaN(step) || step < 1 ? 1 : step
  }

  private fieldCurrent(node: LiveNode, generation: number): boolean {
    return (!this.disposed || this.draining) && !this.previewOnly && node.kind === 'field' && node.enabled &&
      node.fieldGeneration === generation && this.liveRoot !== null && this.isLiveNode(node)
  }

  /** Stamp every node reachable from the current root with this render's membership epoch. */
  private markLiveNodeGeneration(root: LiveNode): void {
    let pending: LiveNode[] = [root]
    while (pending.length > 0) {
      let node = pending.pop()!
      node.liveGeneration = this.liveGeneration
      for (let child of node.children) { pending.push(child) }
    }
  }

  /** O(1) membership check; removed nodes retain an older epoch and need no explicit cleanup. */
  private isLiveNode(node: LiveNode): boolean {
    return node.liveGeneration === this.liveGeneration
   }

  private recordFieldInput(node: LiveNode, value: string): void {
    if (value !== node.value) {
      node.typed = value
      if (!node.touched) { node.touched = true }
    }
  }

  private refreshFieldIssue(node: LiveNode): void {
    let edit = this.fieldEdits.get(node)
    let issue = node.touched && (edit === undefined || !edit.composing)
      ? this.textFieldIssue(node, edit !== undefined ? edit.value : node.value) : ''
    if (node.fieldIssue !== issue) { node.fieldIssue = issue }
  }

  private refreshFieldIssues(node: LiveNode): void {
    if (node.kind === 'field') { this.refreshFieldIssue(node) }
    for (let child of node.children) { this.refreshFieldIssues(child) }
  }

  private cancelField(node: LiveNode): void {
    let edit = this.fieldEdits.get(node)
    if (edit !== undefined && edit.timer >= 0) { clearTimeout(edit.timer) }
    if (edit !== undefined && edit.composing) {
      node.fieldCancellation++
      this.fieldActions = this.fieldActions.filter((next: FieldAction): boolean => {
        let keep = !next.unknownDependencies && next.dependencies.indexOf(node) < 0
        if (!keep) {
          StageTrace.emit(this.traceOwner, 'FIELD_ACTION_DROP', { action: next.action, reason: 'fieldCancellation' })
          this.releaseSurfaceAction(next)
        }
        return keep
      })
    }
    this.fieldEdits.delete(node)
    this.syncEditGate()
    if (!this.disposed && node.kind === 'field') { this.refreshFieldIssue(node) }
  }

  private cancelFields(): void {
    this.fieldInputs.clear()
    this.fieldMenus.clear()
    this.surfaceInputs.clear()
    for (let next of this.fieldActions) {
      StageTrace.emit(this.traceOwner, 'FIELD_ACTION_DROP', { action: next.action, reason: 'effectGeneration' })
    }
    this.fieldActions = []
    this.fieldActionsNeedResume = false
    for (let node of Array.from(this.fieldEdits.keys())) { this.cancelField(node) }
    let nodes: LiveNode[] = this.liveRoot !== null ? [this.liveRoot!] : []
    while (nodes.length > 0) {
      let node = nodes.pop()!
      if (node.kind === 'field') { node.fieldGeneration++ }
      nodes = nodes.concat(node.children)
    }
  }

  private fieldController(node: LiveNode, generation: number): TextInputController {
    let input = this.fieldInputs.get(node)
    if (input === undefined || input.generation !== generation) {
      input = new FieldInput(generation)
      this.fieldInputs.set(node, input)
    }
    return input.controller
  }

  private endFieldEditing(node: LiveNode, generation: number): void {
    if (!this.fieldCurrent(node, generation)) { return }
    let input = this.fieldInputs.get(node)
    if (input === undefined || input.generation !== generation) { return }
    this.finishField(node, generation, input.controller.getText())
  }

  private reconcileFields(): void {
    for (let node of Array.from(this.fieldInputs.keys())) {
      let input = this.fieldInputs.get(node)!
      if (!this.fieldCurrent(node, input.generation)) { this.fieldInputs.delete(node) }
    }
    for (let node of Array.from(this.fieldEdits.keys())) {
      let edit = this.fieldEdits.get(node)!
      if (!this.fieldCurrent(node, edit.generation) || node.action !== edit.action || node.value !== edit.base) {
        this.cancelField(node)
      }
    }
    if (!this.disposed && this.liveRoot !== null) { this.refreshFieldIssues(this.liveRoot!) }
    this.syncEditGate()
  }

  private changeField(node: LiveNode, generation: number, value: string, composing: boolean): void {
    if (!this.fieldCurrent(node, generation)) { return }
    let edit = this.fieldEdits.get(node)
    if (edit === undefined) {
      edit = new FieldEdit(node, value)
      this.fieldEdits.set(node, edit)
    }
    if (edit.timer >= 0) { clearTimeout(edit.timer); edit.timer = -1 }
    edit.value = value
    edit.composing = composing
    this.recordFieldInput(node, value)
    this.refreshFieldIssue(node)
    edit.sequence++
    this.syncEditGate()
    let sequence = edit.sequence
    if (composing) { return }
    if (edit.commitRequested) {
      this.commitField(node, generation)
      this.resumeFieldActions()
      return
    }
    if (this.fieldActions.length > 0) {
      this.resumeFieldActions()
      return
    }
    edit.timer = setTimeout(() => {
      let current = this.fieldEdits.get(node)
      if (current === undefined || current !== edit || current.sequence !== sequence) { return }
      current.timer = -1
      this.commitField(node, generation)
    }, 400)
  }

  private commitField(node: LiveNode, generation: number): void {
    let edit = this.fieldEdits.get(node)
    if (edit === undefined || edit.composing || edit.generation !== generation) { return }
    edit.commitRequested = true
    if (this.inFlight !== null || this.postingEffect || this.postDrain || this.admissionBlocked || this.transitioning || this.handle === null) {
      this.syncEditGate()
      return
    }
    if (!this.fieldCurrent(node, generation) || node.value !== edit.base) {
      this.cancelField(node)
      return
    }
    if (edit.value === node.value || edit.action.length === 0) { this.cancelField(node); return }
    let next = this.captureFieldAction(edit.action, stringPayload(edit.value))
    next.traceKind = 'FIELD'
    next.fieldNode = node
    if (edit.timer >= 0) { clearTimeout(edit.timer); edit.timer = -1 }
    this.inFlight = next
    this.fieldEdits.delete(node)
    this.syncEditGate()
    let result = this.postAction(next)
    if (result.status === 'BACKPRESSURE') {
      if (next.generation === this.effectGeneration && !this.transitioning && !this.fieldEdits.has(node)) {
        this.fieldEdits.set(node, edit)
      }
      if (this.inFlight === next) { this.inFlight = null }
    }
    this.syncEditGate()
  }

  private flushFields(): void {
    this.reconcileFields()
    for (let node of Array.from(this.fieldEdits.keys())) { this.commitField(node, node.fieldGeneration) }
  }

  private flushUserFields(): boolean {
    if (this.disposed || this.previewOnly) { return false }
    let generation = this.effectGeneration
    this.flushFields()
    if (generation !== this.effectGeneration || this.disposed || this.previewOnly) { return false }
    for (let edit of Array.from(this.fieldEdits.values())) {
      if (edit.composing) { return false }
    }
    return true
  }

  private finishField(node: LiveNode, generation: number, value?: string): void {
    let edit = this.fieldEdits.get(node)
    if (edit === undefined || edit.generation !== generation) { return }
    if (!this.fieldCurrent(node, generation) || node.value !== edit.base) {
      this.cancelField(node)
      return
    }
    if (value !== undefined) {
      edit.value = value
      edit.composing = false
      this.recordFieldInput(node, value)
      this.refreshFieldIssue(node)
    }
    if (edit.composing) {
      edit.commitRequested = true
      return
    }
    this.commitField(node, generation)
    this.resumeFieldActions()
  }

  /** The pane ui.Tabs shows: its selected child, kept inside the children there are. */
  private tabSelected(node: LiveNode): number {
    return Math.max(0, Math.min(Math.floor(node.eventValue), node.children.length - 1))
  }

  private tabPane(node: LiveNode): LiveNode[] {
    return node.children.length > 0 ? [node.children[this.tabSelected(node)]] : []
  }

  private sectionPadY(style: string): number {
    return this.sectionFills(style) ? this.t().padCard : 0
  }

  /**
   * Bring `node` into view when a tap has just made it appear (LiveNode.reveal) and it ends below the program's window:
   * a detail card opened under a list was drawn off screen, and the tap looked like it did nothing. Scrolls no further
   * than puts its top at the top, so a card taller than the window shows its beginning. Once per appearance.
   */
  private revealIfAsked(node: LiveNode, area: Area): void {
    if (!node.reveal || this.embedded || this.rootHeight <= 0) { return }
    let height = Number(area.height)
    if (height <= 0) { return }
    node.reveal = false
    let gap = this.t().padBase
    let top = Number(area.globalPosition.y)
    let below = top + height - (this.rootTop + this.rootHeight) + gap
    let room = top - this.rootTop - gap
    let by = Math.min(below, room)
    if (by > 0) { this.rootScroller.scrollBy(0, by) }
  }

  /**
   * The icon a banner shows. A warning or a danger always shows the warning sign, whatever the program named: the icon
   * says what kind of message it is, and a clock on "enter the number first" said nothing of the kind.
   */
  private bannerIcon(node: LiveNode): string {
    if (node.style === 'warning' || node.style === 'danger') { return 'warning' }
    return node.icon
  }

  /** A number, as the program asked for it to be shown: see formatVeraNumber. */
  private formatNumber(node: LiveNode): string {
    return node.prefix + formatVeraNumber(node.numberValue, node.decimals, node.minimumDigits) + unitAfter(node.numberValue, node.suffix)
  }

  /**
   * The same minutes as a Date, because the picker wants one.
   *
   * The day part is never read back -- only hour and minute return through
   * onAccept -- so today's date is as good as any.
   */
  private minutesToDate(total: number): Date {
    let m = total < 0 ? 0 : total % 1440
    let d = new Date()
    d.setHours(Math.floor(m / 60), m % 60, 0, 0)
    return d
  }

  /**
   * A local day number, as time.daysSinceEpoch() counts it, as that day's local
   * midnight; dateToDay is the way back. The day number is the local date read
   * as if it were UTC, so the UTC fields of day * 86400000 are that date.
   */
  private dayToDate(day: number): Date {
    let utc = new Date(Math.floor(day) * 86400000)
    return new Date(utc.getUTCFullYear(), utc.getUTCMonth(), utc.getUTCDate())
  }

  private dateToDay(date: Date): number {
    return Math.floor(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()) / 86400000)
  }

  /** Semantic roles use system fonts unless the theme names a generic family. */
  private textFamily(style: string = 'body'): string | undefined {
    let t = this.t()
    let f = style === 'metric' ? t.metricFontFamily :
      (style === 'display' || style === 'title' || style === 'heading') ? t.headingFontFamily : t.fontFamily
    return f.length > 0 ? f : undefined
  }

  private renderTextSize(style: string): number {
    let size = textSize(this.t(), style)
    return this.embedded && (style === 'display' || style === 'metric') ? Math.min(32, size) : size
  }

  /**
   * The wash behind a title block: the accent's container fading into the page, so the top of the
   * screen carries the colour without a frame. Flat presets (no shadow) and an already-filled
   * accent block get none -- a gradient needs two distinct stops, so this gives the same colour twice.
   */
  private titleTint(filled: boolean): string {
    return this.t().shadowRadius > 0 && !filled ? this.t().primaryFill : this.t().background
  }

  /** The disc a timeline entry's icon sits on; the rail runs through its centre. */
  private timelineMarker(): number {
    return Math.round(this.t().sizeBody * 1.9)
  }

  /**
   * How a title block or a section comes onto the screen: it fades in while rising a little.
   * Short and with no overshoot, so a screen that fills in as it is generated settles rather than bounces.
   */
  private arrival(): TransitionEffect {
    return TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 14 }))
      .animation({ duration: 280, curve: Curve.EaseOut })
  }

  /** The ring is a square sized to the control rhythm, never wider than a third of a phone. */
  private ringSize(): number {
    return this.t().controlHeight * 3
  }

  /** A stat's figure sits a step under the display size, so the title leads and the numbers follow it. */
  private statFigureSize(): number {
    return Math.round(this.renderTextSize('metric') * 0.85)
  }

  /** The figure size each stat of a group is drawn at (metricChildren); one for the whole row. */
  private groupFigure: Map<LiveNode, number> = new Map<LiveNode, number>()

  private figureSizeOf(node: LiveNode): number {
    return this.groupFigure.get(node) ?? this.statFigureSize()
  }

  /**
   * A group's stats, each given the one figure size the row is drawn at: the largest at which every figure fits its column.
   * Shrinking each figure on its own to fit made "250 ml" larger than "7 glasses" beside it. Widths are measured with the
   * figure's own font, against the row's measured width (layoutWidth, from onAreaChange); until the row has been laid out
   * once, the figures keep the full size.
   */
  private metricChildren(group: LiveNode): LiveNode[] {
    let base = this.statFigureSize()
    let size = base
    if (group.layoutWidth > 0 && group.children.length > 0) {
      let columns = Math.min(this.fittingColumns(this.metricColumns(group), 104), group.children.length)
      let ui = this.getUIContext()
      let cell = ui.vp2px(group.layoutWidth / columns - this.t().padTight * 2)
      let scale = 1
      for (let child of group.children) {
        let text = child.kind === 'numberstat' ? this.formatNumber(child) : child.text
        if (text.length === 0) { continue }
        let width = ui.getMeasureUtils().measureText({ textContent: text, fontSize: base,
          fontWeight: this.t().weightMetric, fontFamily: this.textFamily('metric') })
        if (width > cell) { scale = Math.min(scale, cell / width) }
      }
      size = Math.max(14, Math.floor(base * scale))
    }
    for (let child of group.children) { this.groupFigure.set(child, size) }
    return group.children
  }

  /** Each group measures its own available width, including inside another group. */
  private adaptiveColumnsCount(node: LiveNode): number {
    let minimum = node.minimum <= 0 ? 240 : Math.max(160, node.minimum)
    let gap = densityGap(this.t(), node.style)
    return node.layoutWidth > 0 && node.layoutWidth - gap >= minimum * 2 ? 2 : 1
  }

  private adaptiveChildWidth(node: LiveNode): number | string {
    if (this.adaptiveColumnsCount(node) === 1) { return '100%' }
    return (node.layoutWidth - densityGap(this.t(), node.style)) / 2
  }

  /** An enclosing composition already supplies its horizontal inset. */
  private compositionOwnsInset(parentKind: string): boolean {
    return parentKind === 'hero' || parentKind === 'adaptivecolumns' || parentKind === 'section' ||
      parentKind === 'card' || parentKind === 'column' || parentKind === 'scroll'
  }

  /** Minutes since midnight as HH:MM, which is what TimeField holds. */
  private formatMinutes(total: number): string {
    return formatVeraClock(total)
  }

  /**
   * ui.Sparkline's own plotting box height, in vp. Width is not a constant --
   * see chartWidth's own comment -- so every sparkline-drawing method below
   * takes it as a parameter instead of assuming a fixed square, the way
   * SPARKLINE_HEIGHT alone would.
   */
  private static readonly SPARKLINE_HEIGHT: number = 260
  /** Room a line chart keeps above its top and below its bottom gridline, so the stroke and the dots are not clipped. */
  private static readonly SPARKLINE_INSET: number = 16
  private static readonly SPARKLINE_DOT: number = 5
  /** The most x-axis captions a line chart prints; past that, every other one (or third...) is left out. */
  private static readonly SPARKLINE_LABELS: number = 6
  /** Width a caption may use, wider than its slot: it is centred on its point and may reach over the empty slots beside it. */
  private static readonly SPARKLINE_LABEL_BOX: number = 64
  /** Room a bars: true chart keeps above and below the tallest bar for its value and its name. */
  private static readonly BAR_LABEL_ROOM: number = 48

  /**
   * A ui.Sparkline's series as an SVG path, directly in vp -- x across
   * 0..width, y across 0..SPARKLINE_HEIGHT. This used to be a fixed 0..100
   * box mapped onto the real one with Shape.viewPort, the same device every
   * icon's single, genuinely-square path uses -- measured wrong on device for
   * a wide, short chart: viewPort scales uniformly to fit a 100x100 square
   * inside a ~300x200 box, so the content came out squeezed into a sliver at
   * the left rather than stretched to fill it. Writing real vp coordinates
   * and dropping viewPort avoids the scaling step (and its aspect-ratio
   * assumption) entirely, the same way sparklineBarRects now draws one Path
   * per bar instead of trusting a multi-subpath Path's own measurement.
   * maximum bounds the vertical scale; a value past it is clamped rather than
   * drawn off the top, since the program named maximum itself and a point
   * above it is the program's own figure being wrong, not a reason to redraw
   * everything else smaller. floor is node.minimum -- the bottom of the same
   * scale, 0 unless the program set it, for a series whose whole range sits
   * far from zero (a height in cm, a temperature) and would otherwise draw as
   * a sliver pinned to the top of the box with the rest of it empty.
   *
   * width and SPARKLINE_HEIGHT arrive in vp, but a Path's own command numbers
   * are not: unlike .height()/.width(), which ArkUI reads as vp, Path paints
   * its M/L coordinates in real device px (the same split drawIcon's own
   * comment describes for the icon box, '100px'/'8px' against a vp-sized
   * viewPort). Skipping the conversion here drew a chart that was only
   * 1/density of the box it sat in -- correct in proportion, pinned to the
   * top-left corner of a box several times its own size, which is what reads
   * as "a tiny line and a lot of empty space" on any screen whose density
   * isn't 1. this.getUIContext().vp2px(1) is that density, so multiplying both axes by it before
   * building the path is what makes the drawing fill the box it is declared
   * to fill.
   */
  private sparklineCommands(series: number[], maximum: number, floor: number, width: number): string {
    if (series.length === 0) { return '' }
    let cmds: string[] = []
    for (let i = 0; i < series.length; i++) {
      cmds.push((i === 0 ? 'M ' : 'L ') + this.sparklinePoint(series, i, maximum, floor, width))
    }
    return cmds.join(' ')
  }

  /**
   * Point i of a line-mode ui.Sparkline as "x y" in px. Each point sits in the middle of its own equal
   * slot (the x-axis captions are laid out in the same slots, so a caption is always under its point),
   * and the line is kept SPARKLINE_INSET inside the box above and below so the stroke and the dots are
   * not cut off at the top and bottom gridlines.
   */
  private sparklinePoint(series: number[], i: number, maximum: number, floor: number, width: number): string {
    let max = maximum > floor ? maximum : floor + 1
    let scale = this.getUIContext().vp2px(1)
    let inset = VeraPreview.SPARKLINE_INSET * scale
    let h = VeraPreview.SPARKLINE_HEIGHT * scale
    let x = (i + 0.5) / series.length * width * scale
    let v = series[i] < floor ? floor : (series[i] > max ? max : series[i])
    let y = inset + (1 - (v - floor) / (max - floor)) * (h - 2 * inset)
    return x.toFixed(2) + ' ' + y.toFixed(2)
  }

  /**
   * sparklineCommands's own points, closed down to the floor gridline and back to the start -- the area
   * a chart's fill reads against, computed from the line itself rather than left to an implicit close.
   */
  private sparklineAreaCommands(series: number[], maximum: number, floor: number, width: number): string {
    if (series.length === 0) { return '' }
    let scale = this.getUIContext().vp2px(1)
    let bottom = (VeraPreview.SPARKLINE_HEIGHT - VeraPreview.SPARKLINE_INSET) * scale
    let cmds: string[] = []
    for (let i = 0; i < series.length; i++) {
      cmds.push((i === 0 ? 'M ' : 'L ') + this.sparklinePoint(series, i, maximum, floor, width))
    }
    let first = this.sparklinePoint(series, 0, maximum, floor, width).split(' ')[0]
    let last = this.sparklinePoint(series, series.length - 1, maximum, floor, width).split(' ')[0]
    cmds.push('L ' + last + ' ' + bottom.toFixed(2))
    cmds.push('L ' + first + ' ' + bottom.toFixed(2))
    cmds.push('Z')
    return cmds.join(' ')
  }

  /** One filled circle per point, so a chart of two or three values still reads as points, not as a bare slope. */
  private sparklineDotCommands(series: number[], maximum: number, floor: number, width: number): string {
    let r = VeraPreview.SPARKLINE_DOT * this.getUIContext().vp2px(1)
    let cmds: string[] = []
    for (let i = 0; i < series.length; i++) {
      let xy = this.sparklinePoint(series, i, maximum, floor, width).split(' ')
      let x = parseFloat(xy[0])
      cmds.push('M ' + (x - r).toFixed(2) + ' ' + xy[1] + ' a ' + r.toFixed(2) + ' ' + r.toFixed(2) + ' 0 1 0 ' +
        (2 * r).toFixed(2) + ' 0 a ' + r.toFixed(2) + ' ' + r.toFixed(2) + ' 0 1 0 ' + (-2 * r).toFixed(2) + ' 0')
    }
    return cmds.join(' ')
  }

  /**
   * The x-axis captions, one per point (cut or padded to the series), each laid out in its point's slot. With
   * more than SPARKLINE_LABELS points only every step-th caption is kept (the rest are empty, their slots stay),
   * so the ones that remain have room to be read in full.
   */
  private sparklineLabels(node: LiveNode): string[] {
    let n = node.series.length
    let step = n > VeraPreview.SPARKLINE_LABELS ? Math.ceil((n - 1) / (VeraPreview.SPARKLINE_LABELS - 1)) : 1
    let labels: string[] = []
    for (let i = 0; i < n; i++) {
      let text = i < node.categories.length ? node.categories[i] : ''
      labels.push(i % step === 0 ? text : '')
    }
    return labels
  }

  /**
   * The real width to draw a ui.Sparkline's path commands in, in vp.
   *
   * This used to reuse viewportWidth -- the whole program's own outer content
   * box, measured once near the root (onAreaChange several screens up from
   * here) -- on the reasoning that a chart a little too wide would read
   * better than one squeezed into a sliver. Measured on device: wrong in the
   * other direction and worse than that reasoning expected. A chart nested
   * inside a ui.Section sits well inside viewportWidth -- the section's own
   * padding, plus this preview's own page padding counted on top of it a
   * second time -- so the bars drew at a small fraction of the real box and
   * sat flush left in it rather than centred, nowhere near "a little wide".
   * sparklineWidth is measured on the chart's own Shape instead (see its
   * own onAreaChange in the 'sparkline' branch), so it needs no guess about
   * how many padded containers sit between this chart and the page edge.
   * 300 is a plain guess for the first frame, before any area has been
   * measured.
   */
  private chartWidth(): number {
    return this.sparklineWidth > 0 ? this.sparklineWidth : 300
  }

  private canvasSide(style: string): number {
    let inset = 2 * (this.t().padBase + this.t().padCard)
    let fallback = this.viewportWidth > inset ? this.viewportWidth - inset : 300
    let width = this.canvasWidth > 0 ? this.canvasWidth : fallback
    let ratio = style === 'large' ? 1.0 : style === 'small' ? 0.55 : 0.8
    return width * ratio
  }

  /**
   * ui.Sparkline with bars: true -- every value's bar height, in vp, clamped
   * to maximum the same way sparklineCommands clamps a line's points. Called
   * once as the 'sparkline' branch's ForEach data source, not from inside
   * its item builder -- see that branch's own comment for why that distinction
   * is exactly what makes every bar draw, not only the tallest.
   */
  private barHeights(node: LiveNode): number[] {
    let max = node.maximum > 0 ? node.maximum : 1
    let heights: number[] = []
    for (let v of node.series) {
      let clamped = v < 0 ? 0 : (v > max ? max : v)
      heights.push((clamped / max) * VeraPreview.SPARKLINE_HEIGHT)
    }
    return heights
  }

  /**
   * The bars of a bars: true ui.Sparkline with the name under each and its value over it. Like
   * barHeights this is called once, as the ForEach's data source, never from inside an item builder.
   */
  private barItems(node: LiveNode): BarItem[] {
    let heights = this.barHeights(node)
    let items: BarItem[] = []
    for (let i = 0; i < heights.length; i++) {
      let item = new BarItem()
      item.height = heights[i]
      item.label = i < node.categories.length ? node.categories[i] : ''
      item.value = node.series[i].toString()
      items.push(item)
    }
    return items
  }

  /**
   * Four evenly spaced y-axis values for a line-mode ui.Sparkline, maximum
   * first -- the order the label column draws top to bottom, over the same
   * range sparklineGridCommands draws its lines across.
   */
  private sparklineTicks(maximum: number, floor: number): string[] {
    let max = maximum > floor ? maximum : floor + 1
    let step = (max - floor) / 3
    let ticks: string[] = []
    for (let i = 3; i >= 0; i--) {
      let v = floor + step * i
      // A narrow range needs a decimal or the four labels repeat (172, 172, 173, 173).
      ticks.push(max - floor >= 6 ? Math.round(v).toString() : (Math.round(v * 10) / 10).toString())
    }
    return ticks
  }

  /** One horizontal line per sparklineTicks value, in the same px-corrected space sparklineCommands draws in. */
  private sparklineGridCommands(maximum: number, floor: number, width: number): string {
    let scale = this.getUIContext().vp2px(1)
    let inset = VeraPreview.SPARKLINE_INSET * scale
    let h = VeraPreview.SPARKLINE_HEIGHT * scale
    let w = width * scale
    let cmds: string[] = []
    for (let i = 0; i <= 3; i++) {
      let y = inset + (i / 3) * (h - 2 * inset)
      cmds.push('M 0 ' + y.toFixed(2) + ' L ' + w.toFixed(2) + ' ' + y.toFixed(2))
    }
    return cmds.join(' ')
  }

  /** ui.Select's current choice, for the trigger row -- '' if it has no options at all. */
  private selectDisplayText(node: LiveNode): string {
    let i = node.eventValue
    if (i >= 0 && i < node.options.length) { return node.options[i] }
    return node.options.length > 0 ? node.options[0] : ''
  }

  /** ui.Select's options as the overlay bindMenu opens, one MenuElement each. */
  private openFieldMenu(node: LiveNode): void {
    let actions: FieldAction[] = []
    for (let i = 0; i < node.options.length; i++) {
      actions.push(this.captureFieldAction(node.action, numberPayload(i), true, node))
    }
    this.fieldMenus.set(node, actions)
  }

  private selectMenuItems(node: LiveNode): MenuElement[] {
    let items: MenuElement[] = []
    let state = this.fieldActionState(node)
    for (let i = 0; i < node.options.length; i++) {
      let index = i
      items.push({
        value: node.options[i],
        action: () => {
          let actions = this.fieldMenus.get(node)
          if (actions === undefined || index >= actions.length) { return }
          let next = actions[index]
          if (next.action.length > 0 && next.nodeState === state) { this.enqueueFieldAction(next) }
        }
      })
    }
    return items
  }

  /**
   * ui.TextField's checks, in a fixed order, as the one message to show under
   * the field or '' if it currently has none. VERA has no way to refuse a
   * value once typed, so this never stops anything reaching the handler --
   * it only tells the person what is wrong, the same thing a host test runs
   * against the same inputs to confirm before this ever touches ArkUI.
   */
  private textFieldIssue(node: LiveNode, v: string = node.value): string {
    if (node.required && v.length === 0) {
      return node.requiredMessage.length > 0 ? node.requiredMessage : 'Required'
    }
    if (v.length === 0) { return '' }
    if (node.minLength > 0 && v.length < node.minLength) {
      return node.minLengthMessage.length > 0 ? node.minLengthMessage
        : 'Enter at least ' + node.minLength.toString() + ' characters'
    }
    if (node.maxLength >= 0 && v.length > node.maxLength) {
      return node.maxLengthMessage.length > 0 ? node.maxLengthMessage
        : 'Enter at most ' + node.maxLength.toString() + ' characters'
    }
    if (node.email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v)) {
      return node.emailMessage.length > 0 ? node.emailMessage : 'Enter a valid email address'
    }
    if (node.pattern.length > 0 && !new RegExp(node.pattern).test(v)) {
      return node.patternMessage.length > 0 ? node.patternMessage : 'Invalid format'
    }
    return ''
  }

  private textFieldKeyboard(node: LiveNode): InputType {
    // Digits and a decimal point: InputType.Number is digits only, and the catalogue sends money, weights and distances here.
    if (node.keyboardType === 'number') { return InputType.NUMBER_DECIMAL }
    if (node.keyboardType === 'phone') { return InputType.PhoneNumber }
    if (node.keyboardType === 'email') { return InputType.Email }
    return InputType.Normal
  }

  /**
   * How many columns actually fit, rather than how many were asked for.
   *
   * The requested count is a maximum. Four metrics side by side is a fine
   * layout on a tablet and four unreadable slivers on this phone, and the
   * program cannot know which it is running on -- it is a pure function of
   * state and has no way to ask. So the renderer decides, from the width it can
   * see and the narrowest a cell may usefully be.
   */
  private fittingColumns(requested: number, minimumCellWidth: number): number {
    let want = requested < 1 ? 1 : requested
    if (this.viewportWidth <= 0) { return want }
    let fits = Math.floor(this.viewportWidth / minimumCellWidth)
    if (fits < 1) { fits = 1 }
    return fits < want ? fits : want
  }

  /** Two to four; anything else is a number the model should not have picked. */
  private metricColumns(node: LiveNode): number {
    if (node.columns < 2) { return 2 }
    if (node.columns > 4) { return 4 }
    return node.columns
  }

  private sectionRadius(style: string): number {
    return this.sectionFills(style) ? this.t().radiusCard : 0
  }

  /** An icon on a tinted disc: the anchor that lets the eye find a row or an empty screen. */
  @LocalBuilder
  iconChip(name: string, box: number, fill: string, colour: string) {
    Column() {
      this.drawIcon(name, Math.round(box * 0.5), colour)
    }
    .width(box)
    .height(box)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(fill)
    .borderRadius(box / 2)
  }

  /**
   * One icon, at a size, in a colour.
   *
   * The paths are written in the same 0..100 box as ui.Path, so drawing one at
   * sixteen points is a scale of 0.16 about the centre of a box that size. They
   * are stroked rather than filled -- see VeraIcons for why -- with round caps,
   * which is what keeps a two-segment tick from ending in two blunt chisels.
   */
  @LocalBuilder
  drawIcon(name: string, size: number, colour: string) {
    // The viewport is the whole trick, and its unit is half the trick.
    //
    // ArkUI's Path has no viewBox of its own: its commands are drawn in a fixed
    // unit and its width/height only set the box they are clipped to, so
    // .scale() on the Path fights the layout rather than sizing the drawing.
    // Three rounds of that put a speck in the corner of every button.
    // Shape.viewPort is the mechanism that does exist -- it maps the 0..100 box
    // the icons are drawn in onto whatever size this component is given, and it
    // carries the stroke along with the geometry, so the weight stays even from
    // twelve points to thirty-eight.
    //
    // The unit of that box is the pixel. Stated as bare numbers the viewPort
    // and the stroke are read as vp while the commands are read as px, the
    // three disagree by the display density, and the glyph lands at a quarter
    // of its box -- measured at 0.25 where 0.78 was wanted. Hence '100px' and
    // '8px'. This was settled by drawing the candidates on the phone and
    // measuring them, after three rounds of reasoning about it got it wrong.
    //
    // Every icon is normalised to span 78 of those 100 units, so a glyph drawn
    // at `size` reads at about the cap height of text at the same size. That
    // normalisation lives in the path data, done once; nothing is scaled here.
    Shape() {
      Path({ commands: iconPath(name) })
        .fill(Color.Transparent)
        .stroke(colour)
        .strokeWidth(ICON_STROKE)
        .strokeLineCap(LineCapStyle.Round)
        .strokeLineJoin(LineJoinStyle.Round)
    }
    .viewPort({ x: ICON_ORIGIN, y: ICON_ORIGIN, width: ICON_VIEWPORT, height: ICON_VIEWPORT })
    .width(size)
    .height(size)
  }

  /** One legend entry for a two-series ui.Sparkline: a tone-coloured dot and its name. */
  @LocalBuilder
  sparklineLegendEntry(text: string, colour: string) {
    Row({ space: this.t().gapTight }) {
      Column().width(8).height(8).borderRadius(4).backgroundColor(colour)
      Text(text).fontSize(this.t().sizeCaption).fontFamily(this.textFamily()).fontColor(this.t().inkSoft)
    }
  }

  @LocalBuilder
  renderNode(node: LiveNode, parentKind: string) {
    if (node.kind === 'apptheme') {
      // The look itself is picked up in reconcileTheme, off the root of the
      // frame. All this branch does is paint the page and get out of the way.
      Column() {
        this.renderChildren(node)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(this.t().background)
    } else if (node.kind === 'scroll') {
      // Rendered as a plain Column until now, so a program asking for a
      // scrolling region got one that could not scroll and simply grew.
      Scroll() {
        Column() {
          this.renderChildren(node)
        }
        .width('100%')
        .alignItems(node.style === 'center' ? HorizontalAlign.Center :
          node.style === 'end' ? HorizontalAlign.End : HorizontalAlign.Start)
        .padding(densityPad(this.t(), node.style))
      }
      .width('100%')
      .constraintSize({ maxHeight: 420 })
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
      .backgroundColor(containerFill(this.t(), node.style))
    } else if (node.kind === 'column') {
      Column() {
        this.renderChildren(node)
      }
      .width('100%')
      .alignItems(node.style === 'center' ? HorizontalAlign.Center :
        node.style === 'end' ? HorizontalAlign.End : HorizontalAlign.Start)
      .padding(densityPad(this.t(), node.style))
      .backgroundColor(containerFill(this.t(), node.style))
    } else if (node.kind === 'row' && this.rowDistributes(node)) {
      // A row of cells or cards is a grid row: the children share the width by
      // weight, and a wrapping Flex does not distribute weight, which collapses
      // a board to nothing.
      Row({ space: densityGap(this.t(), node.style) }) {
        this.renderChildren(node)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .justifyContent(node.style === 'split' ? FlexAlign.SpaceBetween :
        node.style === 'center' ? FlexAlign.Center :
          node.style === 'end' ? FlexAlign.End : FlexAlign.Start)
      .padding(this.t().padRow)
      .backgroundColor(containerFill(this.t(), node.style))
    } else if (node.kind === 'row') {
      // Everything else wraps rather than pushing children past the right edge,
      // where they cannot be tapped. Half the probes lost a control that way --
      // a "Mark taken" button, the true/false of a switch, a preset that read
      // "Call mo".
      Flex({
        wrap: FlexWrap.Wrap,
        justifyContent: node.style === 'split' ? FlexAlign.SpaceBetween :
          node.style === 'center' ? FlexAlign.Center :
            node.style === 'end' ? FlexAlign.End : FlexAlign.Start,
        alignItems: ItemAlign.Center,
        space: { main: LengthMetrics.vp(densityGap(this.t(), node.style)),
                 cross: LengthMetrics.vp(this.t().padRow) }
      }) {
        this.renderChildren(node)
      }
      .width('100%')
      .padding(node.style === 'joined' ? 0 : this.t().padRow)
      .backgroundColor(containerFill(this.t(), node.style))
    } else if (node.kind === 'card') {
      Column() {
        this.renderChildren(node)
      }
      .width(parentKind === 'row' ? undefined : '100%')
      .layoutWeight(parentKind === 'row' ? 1 : 0)
      .alignItems(HorizontalAlign.Start)
      .padding(this.t().padCard)
      .backgroundColor(toneFill(this.t(), node.style, this.t().surface))
      .border({ width: this.t().borderWidth, color: this.t().lineSoft })
      .borderRadius(this.t().radiusCard)
      .shadow({ radius: this.t().shadowRadius, color: this.t().shadowColor, offsetY: this.t().shadowOffsetY })
      .onAreaChange((_old: Area, now: Area) => { this.revealIfAsked(node, now) })
    } else if (node.kind === 'transform') {
      // One node turned, moved, scaled and faded by the pose being shown (see transformMatrix); its children are plain content.
      Stack() {
        Column() {
          this.renderChildren(node)
        }
        .alignItems(HorizontalAlign.Center)
        .width(node.minimum > 0 ? node.minimum : undefined)
        .height(node.minimum > 0 ? node.minimum : undefined)
        .opacity(this.transformOpacity(node))
        .transform(this.transformMatrix(node))
      }
      .width('100%')
    } else if (node.kind === 'layers') {
      // One over another, each in the middle; the box is the size the program gave.
      Stack({ alignContent: Alignment.Center }) {
        this.renderChildren(node)
      }
      .width(node.minimum > 0 ? node.minimum : undefined)
      .height(node.maximum > 0 ? node.maximum : undefined)
    } else if (node.kind === 'motion') {
      // The children are drawn as they are; only the pose around them moves. Drawn inline, no component of its own.
      Column() {
        this.renderChildren(node)
      }
      .width(parentKind === 'row' ? undefined : '100%')
      .layoutWeight(parentKind === 'row' ? 1 : 0)
      .alignItems(HorizontalAlign.Center)
      .rotate({ x: this.motionPoseOf(node).axisX, y: this.motionPoseOf(node).axisY, z: this.motionPoseOf(node).axisZ,
                angle: this.motionPoseOf(node).angle, centerX: '50%', centerY: pivotPercent(this.motionPoseOf(node).pivotY), perspective: 2400 })
      .scale({ x: this.motionPoseOf(node).scale * this.motionPoseOf(node).scaleX, y: this.motionPoseOf(node).scale * this.motionPoseOf(node).scaleY, centerX: '50%', centerY: '50%' })
      .translate({ x: this.motionPoseOf(node).dx, y: this.motionPoseOf(node).dy })
      .opacity(this.motionPoseOf(node).opacity)
    } else if (node.kind === 'text') {
      Text(keepUnits(node.text))
        .fontSize(this.renderTextSize(node.style))
        .fontFamily(this.textFamily(node.style))
        .fontWeight(textWeight(this.t(), node.style))
        .fontColor(textInk(this.t(), node.style))
        .letterSpacing(node.style === 'eyebrow' ? this.t().eyebrowSpacing : 0)
        // In a row the text takes only what it needs and shrinks rather than
        // shoving its siblings out of the window; the row wraps if it must.
        // Making it greedy instead (an earlier attempt) merely moved the problem
        // to rows that also hold a weighted card.
        .width(parentKind === 'row' ? undefined : '100%')
        .constraintSize({ maxWidth: '100%' })
        .flexShrink(1)
        .padding({ top: 2, bottom: 2 })
    } else if (node.kind === 'hero') {
      Column({ space: this.t().gapBase }) {
        if (node.label.length > 0) {
          Text(node.label)
            .fontSize(this.t().sizeCaption)
            .fontFamily(this.textFamily())
            .fontWeight(Math.max(this.t().weightHeading, 600))
            .fontColor(this.t().primaryInk)
            .letterSpacing(this.t().eyebrowSpacing)
            .width('100%')
        }
        if (node.text.length > 0) {
          Text(node.text)
            .fontSize(this.renderTextSize('display'))
            .fontFamily(this.textFamily('display'))
            .fontWeight(this.t().weightDisplay)
            .fontColor(this.t().ink)
            .width('100%')
        }
        if (node.value.length > 0) {
          Text(node.value)
            .fontSize(this.t().sizeBody)
            .fontFamily(this.textFamily())
            .fontColor(this.t().inkSoft)
            .width('100%')
        }
        this.renderChildren(node)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({
        left: node.style === 'accent' ? this.t().padCard :
          this.compositionOwnsInset(parentKind) ? 0 : this.t().padBase,
        right: node.style === 'accent' ? this.t().padCard :
          this.compositionOwnsInset(parentKind) ? 0 : this.t().padBase,
        top: node.style === 'accent' ? this.t().padCard : this.t().padLoose,
        bottom: node.style === 'accent' ? this.t().padCard : 0
      })
      .backgroundColor(node.style === 'accent' ? this.t().primaryFill : '#00000000')
      .linearGradient({ angle: 180, colors: [[this.titleTint(node.style === 'accent'), 0.0], [this.t().background, 1.0]] })
      .borderRadius(node.style === 'accent' ? this.t().radiusCard : 0)
      .margin({ bottom: this.t().gapSection })
    } else if (node.kind === 'adaptivecolumns') {
      Column() {
        Flex({
          wrap: FlexWrap.Wrap,
          justifyContent: FlexAlign.Start,
          alignItems: ItemAlign.Start,
          space: { main: LengthMetrics.vp(densityGap(this.t(), node.style)),
                   cross: LengthMetrics.vp(densityGap(this.t(), node.style)) }
        }) {
          ForEach(node.children, (child: LiveNode) => {
            Column() {
              this.renderNode(child, 'adaptivecolumns')
            }
            .width(this.adaptiveChildWidth(node))
            .alignItems(HorizontalAlign.Start)
          }, (child: LiveNode, index: number) => index.toString() + ':' + child.kind)
        }
        .width('100%')
        .onAreaChange((_old: Area, now: Area) => {
          let width = now.width as number
          if (width >= 0 && Math.abs(width - node.layoutWidth) >= 1) { node.layoutWidth = width }
        })
      }
      .width('100%')
      .padding({
        left: this.compositionOwnsInset(parentKind) ? 0 : this.t().padBase,
        right: this.compositionOwnsInset(parentKind) ? 0 : this.t().padBase
      })
    } else if (node.kind === 'header') {
      // The app's own title block. A generated program used to open with a bare
      // ui.Text and nothing to distinguish it from the first line of content.
      Column({ space: this.t().gapBase }) {
        if (node.label.length > 0) {
          Text(node.label)
            .fontSize(this.t().sizeEyebrow)
            .fontFamily(this.textFamily())
            .fontWeight(Math.max(this.t().weightHeading, 600))
            .fontColor(this.t().primaryInk)
            .letterSpacing(this.t().eyebrowSpacing)
            .width('100%')
            .textAlign(node.style === 'center' ? TextAlign.Center : TextAlign.Start)
        }
        Row({ space: this.t().gapBase }) {
          if (node.icon.length > 0) {
            Column() {
              this.drawIcon(node.icon, this.t().sizeTitle - 4, this.t().primaryInk)
            }
            .width(this.t().sizeTitle + 16)
            .height(this.t().sizeTitle + 16)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor(this.t().primaryFill)
            .borderRadius(this.t().radiusControl)
          }
          Text(node.text)
            .fontSize(this.renderTextSize('display'))
            .fontFamily(this.textFamily('display'))
            .fontWeight(this.t().weightDisplay)
            .fontColor(this.t().ink)
            .layoutWeight(1)
            .textAlign(node.style === 'center' ? TextAlign.Center : TextAlign.Start)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        if (node.value.length > 0) {
          Text(node.value)
            .fontSize(this.t().sizeBody)
            .fontFamily(this.textFamily())
            .fontColor(this.t().inkSoft)
            .width('100%')
            .textAlign(node.style === 'center' ? TextAlign.Center : TextAlign.Start)
        }
      }
      .width('100%')
      .alignItems(node.style === 'center' ? HorizontalAlign.Center : HorizontalAlign.Start)
      .padding({ left: this.t().padBase, right: this.t().padBase,
                 top: this.t().padLoose, bottom: this.t().padBase })
      .linearGradient({ angle: 180, colors: [[this.titleTint(false), 0.0], [this.t().background, 1.0]] })
      .transition(this.arrival())
    } else if (node.kind === 'section') {
      Column({ space: this.t().gapTight }) {
        if (node.text.length > 0) {
          Text(node.text)
            .fontSize(this.renderTextSize('heading'))
            .fontFamily(this.textFamily('heading'))
            .fontWeight(Math.max(this.t().weightHeading, 600))
            .fontColor(node.style === 'warning' ? this.t().warningInk :
              node.style === 'supporting' ? this.t().inkSoft : this.t().ink)
            .width('100%')
        }
        if (node.label.length > 0) {
          Text(node.label)
            .fontSize(this.t().sizeCaption)
            .fontFamily(this.textFamily())
            .fontColor(this.t().inkMuted)
            .width('100%')
        }
        this.renderChildren(node)
      }
      // Margins add to a 100% width, so a section that stands in from the edges takes them off it.
      .width(this.sectionFills(this.sectionLook(node)) ? 'calc(100% - ' + (this.t().padBase * 2).toString() + 'vp)' : '100%')
      .alignItems(HorizontalAlign.Start)
      .padding({
        left: !this.sectionFills(this.sectionLook(node)) && this.compositionOwnsInset(parentKind) ? 0 : this.sectionPadX(this.sectionLook(node)),
        right: !this.sectionFills(this.sectionLook(node)) && this.compositionOwnsInset(parentKind) ? 0 : this.sectionPadX(this.sectionLook(node)),
        top: this.sectionPadY(this.sectionLook(node)), bottom: this.sectionPadY(this.sectionLook(node))
      })
      .backgroundColor(this.sectionFill(this.sectionLook(node)))
      .borderRadius(this.sectionRadius(this.sectionLook(node)))
      // Only a section that fills has a box to lift. For the others a shadow of radius 0 is not "none":
      // it is a hard copy of the box offset downward, which showed as a line under every plain section.
      .shadow({
        radius: this.sectionFills(this.sectionLook(node)) ? this.t().shadowRadius : 0,
        color: this.sectionFills(this.sectionLook(node)) ? this.t().shadowColor : '#00000000',
        offsetY: this.sectionFills(this.sectionLook(node)) ? this.t().shadowOffsetY : 0 })
      // The gap between one section and the next comes from the theme, so a
      // program does not have to punctuate itself with ui.Spacer.
      // A section that fills stands in from the screen's edges: run flush to them, its shadow
      // shows only as a hard line along the bottom and its corners are cut off.
      .margin({
        left: this.sectionFills(this.sectionLook(node)) ? this.t().padBase : 0,
        right: this.sectionFills(this.sectionLook(node)) ? this.t().padBase : 0,
        top: this.t().gapTight, bottom: this.t().gapSection })
      .transition(this.arrival())
      .onAreaChange((_old: Area, now: Area) => { this.revealIfAsked(node, now) })
    } else if (node.kind === 'sectionheader') {
      Column({ space: 2 }) {
        Row() {
          Text(node.text)
            .fontSize(this.renderTextSize('heading'))
            .fontFamily(this.textFamily('heading'))
            .fontWeight(this.t().weightHeading)
            .fontColor(node.style === 'accent' ? this.t().primaryInk :
              node.style === 'muted' ? this.t().inkMuted : this.t().ink)
            .layoutWeight(1)
          if (node.value.length > 0) {
            Text(node.value)
              .fontSize(this.t().sizeCaption)
              .fontFamily(this.textFamily())
              .fontColor(this.t().inkMuted)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        if (node.label.length > 0) {
          Text(node.label)
            .fontSize(this.t().sizeCaption)
            .fontFamily(this.textFamily())
            .fontColor(this.t().inkMuted)
            .width('100%')
        }
      }
      .width('100%')
      // Indents itself only when nothing else is doing it: inside a Section the
      // section already owns the margin, and doing it twice reads as a stray
      // indent rather than as alignment.
      .padding({
        left: parentKind === 'section' ? 0 : this.t().padBase,
        right: parentKind === 'section' ? 0 : this.t().padBase,
        top: this.t().gapBase, bottom: this.t().gapTight
      })
    } else if (node.kind === 'listgroup') {
      // One frame around the whole collection, with the separators drawn here.
      // Before this, a list was a Card per row: every row had its own border,
      // its own radius and its own margin, and a list of eight read as eight
      // unrelated things.
      Column() {
        if (node.text.length > 0) {
          Text(node.text)
            .fontSize(this.t().sizeCaption)
            .fontFamily(this.textFamily())
            .fontWeight(this.t().weightHeading)
            .fontColor(this.t().inkMuted)
            .width('100%')
            .padding({ left: this.t().padListX, right: this.t().padListX,
                       top: this.t().gapBase, bottom: this.t().gapTight })
        }
        ForEach(this.rowChildren(node), (child: LiveNode, index: number) => {
          // A hairline between rows, never above the first. Drawn by the group
          // rather than by the row so a row does not have to know whether it is
          // last.
          // Rules go between rows. A program that puts something else in a
          // group -- an ActionBar for the row above it, most often -- was
          // getting a rule drawn across it, which read as a broken list.
          if (index > 0 && (child.kind === 'listitem' || child.kind === 'numberlistitem')) {
            Divider()
              .strokeWidth(this.t().borderWidth)
              .color(this.t().lineSoft)
              .margin({ left: this.t().padListX, right: this.t().padListX })
          }
          this.renderNode(child, 'listgroup')
          // Same keying as renderChildren; see the note there.
        }, (child: LiveNode, index: number) => index.toString() + ':' + child.kind)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(this.t().surfaceRaised)
      .border({ width: this.t().borderWidth, color: this.t().lineSoft })
      .borderRadius(this.t().radiusCard)
      .shadow({ radius: this.t().shadowRadius, color: this.t().shadowColor, offsetY: this.t().shadowOffsetY })
      .clip(true)
      .margin({ top: this.t().gapTight, bottom: this.t().gapTight })
    } else if (node.kind === 'banner') {
      Row({ space: this.t().gapBase }) {
        // A rail in the tone, so the banner reads as a status at a glance rather than as one more tinted box. Drawn as
        // its own rounded bar: a left border on a rounded box followed the corners and showed as a bracket.
        Column()
          .width(4)
          .alignSelf(ItemAlign.Stretch)
          .borderRadius(2)
          .backgroundColor(toneEdge(this.t(), node.style, this.t().primary))
        if (this.bannerIcon(node).length > 0) {
          this.iconChip(this.bannerIcon(node), this.t().controlHeight - 8, this.t().surface,
            toneEdge(this.t(), node.style, this.t().primaryInk))
        }
        Column({ space: 2 }) {
          if (node.text.length > 0) {
            Text(node.text)
              .fontSize(this.t().sizeBody)
              .fontFamily(this.textFamily())
              .fontWeight(this.t().weightHeading)
              .fontColor(toneInk(this.t(), node.style, this.t().ink))
              .width('100%')
          }
          if (node.label.length > 0) {
            Text(node.label)
              .fontSize(this.t().sizeCaption)
              .fontFamily(this.textFamily())
              .fontColor(this.t().inkStrong)
              .width('100%')
          }
          // Under the words, not beside them: beside, a button like "Open camera" took half the row and the message
          // wrapped two words to a line (Exam prep).
          if (node.value.length > 0) {
            Button(node.value)
              .height(this.t().chipHeight)
              .fontSize(this.t().sizeBody)
              .fontFamily(this.textFamily())
              .type(ButtonType.Capsule)
              .backgroundColor(toneEdge(this.t(), node.style, this.t().primary))
              .fontColor(readableInk(toneEdge(this.t(), node.style, this.t().primary)))
              .margin({ top: this.t().gapTight })
              .onClick(() => {
                if (node.action.length > 0) { this.handleAction(node.action, node.eventValue, node) }
              })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding(this.t().padBase)
      .backgroundColor(toneFill(this.t(), node.style, this.t().surface))
      .borderRadius(this.t().radiusControl)
      .margin({ top: this.t().gapTight, bottom: this.t().gapTight,
                left: this.compositionOwnsInset(parentKind) ? 0 : this.t().padBase,
                right: this.compositionOwnsInset(parentKind) ? 0 : this.t().padBase })
      .onAreaChange((_old: Area, now: Area) => { this.revealIfAsked(node, now) })
    } else if (node.kind === 'emptystate') {
      // State starts empty, so for most programs this is the first thing anyone
      // sees. It used to be a blank column.
      Column({ space: this.t().gapBase }) {
        // A widget in a chat reply has no room for the picture: the words say it.
        if (node.icon.length > 0 && !this.embedded) {
          this.iconChip(node.icon, this.t().controlHeight + 24,
            this.t().primaryFill, this.t().primaryInk)
        }
        Text(node.text)
          .fontSize(this.renderTextSize('heading'))
          .fontFamily(this.textFamily('heading'))
          .fontWeight(this.t().weightHeading)
          .fontColor(node.style === 'muted' ? this.t().inkMuted : this.t().ink)
          .textAlign(TextAlign.Center)
          .width('100%')
        if (node.label.length > 0) {
          Text(node.label)
            .fontSize(this.t().sizeBody)
            .fontFamily(this.textFamily())
            .fontColor(this.t().inkMuted)
            .textAlign(TextAlign.Center)
            .width('100%')
        }
        if (node.value.length > 0) {
          Button(node.value)
            .height(this.t().controlHeight)
            .fontSize(this.t().sizeBody)
            .fontFamily(this.textFamily())
            .type(ButtonType.Capsule)
            .backgroundColor(this.t().primary)
            .fontColor(this.t().onPrimary)
            .onClick(() => {
              if (node.action.length > 0) { this.handleAction(node.action, node.eventValue, node) }
            })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .justifyContent(FlexAlign.Center)
      .padding(this.embedded ? this.t().padBase : this.t().padLoose)
    } else if (node.kind === 'stat') {
      // Carries no surface of its own: it is meant to sit inside a MetricGroup,
      // which owns the one surface the group shares.
      Column({ space: 2 }) {
        Row({ space: this.t().gapTight }) {
          if (node.icon.length > 0) {
            this.drawIcon(node.icon, this.t().sizeCaption,
              toneInk(this.t(), node.style, this.t().inkMuted))
          }
          if (node.label.length > 0) {
            Text(node.label)
              .fontSize(this.t().sizeCaption)
              .fontFamily(this.textFamily())
              .fontColor(this.t().inkMuted)
              .layoutWeight(1)
              // Two lines of fixed size and a fixed box, so every figure in a row sits on one baseline
              // and neighbouring labels are the same size; a longer label is cut, not shrunk.
              .maxLines(2)
              .height(Math.round(this.t().sizeCaption * 2.6))
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        Text(node.text)
          .fontSize(this.figureSizeOf(node))
          // One line, at the size its group shares (metricChildren), shrunk further only if the estimate was short.
          .maxLines(1)
          .minFontSize(14)
          .maxFontSize(this.figureSizeOf(node))
          .fontFamily(this.textFamily('metric'))
          .fontWeight(this.t().weightMetric)
          .fontColor(toneInk(this.t(), node.style, this.t().ink))
          .width('100%')
        if (node.value.length > 0) {
          Text(node.value)
            .fontSize(this.t().sizeCaption)
            .fontFamily(this.textFamily())
            .fontColor(this.t().inkSoft)
            .width('100%')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(this.t().padTight)
    } else if (node.kind === 'metricgroup') {
      // Equal columns over one shared surface, built the same way ui.Grid is
      // and for the same reason -- see the note in the grid branch.
      Flex({
        wrap: FlexWrap.Wrap,
        justifyContent: FlexAlign.Start,
        alignItems: ItemAlign.Start
      }) {
        ForEach(this.metricChildren(node), (child: LiveNode) => {
          Column() {
            this.renderNode(child, 'metricgroup')
          }
          .width(Math.floor(100 / this.fittingColumns(this.metricColumns(node), 104)).toString() + '%')
          // Same keying as renderChildren (see the note there), plus the shared figure size: the size lives in a plain map,
          // so a cell is rebuilt to pick up a new one only because its key changed.
        }, (child: LiveNode, index: number) => index.toString() + ':' + child.kind + ':' + this.figureSizeOf(child).toString())
      }
      .width('100%')
      .padding(densityPad(this.t(), node.style) - this.t().padTight)
      .margin({ top: this.t().gapTight, bottom: this.t().gapTight })
      // The row's width inside its padding, for metricChildren to fit the figures to.
      .onAreaChange((_old: Area, now: Area) => {
        let width = Number(now.width) - (densityPad(this.t(), node.style) - this.t().padTight) * 2
        if (width > 0 && Math.abs(width - node.layoutWidth) >= 1) { node.layoutWidth = width }
      })
    } else if (node.kind === 'tilegrid') {
      // Two to a row; a tile of span 2 takes the row. Each row is a Flex of its own that stretches its tiles to the taller one, so
      // a pair is one height whatever each holds (an icon, a second line). Not one wrapping Flex: in a scroll it had no height to
      // stretch to, and each tile took the whole screen (live_figure, 2026-11-06).
      Column({ space: this.t().gapLoose }) {
        ForEach(tileRows(node.children), (row: LiveNode[]) => {
          Flex({
            justifyContent: FlexAlign.Start,
            alignItems: ItemAlign.Stretch,
            space: { main: LengthMetrics.vp(this.t().gapLoose) }
          }) {
            ForEach(row, (child: LiveNode) => {
              this.renderNode(child, 'tilegrid')
            }, (child: LiveNode, index: number) => index.toString() + ':' + child.kind)
          }
          .width('100%')
          // Same keying as renderChildren; see the note there.
        }, (row: LiveNode[], index: number) => index.toString() + ':' + row.length.toString())
      }
      .width('100%')
      .padding({ left: this.t().padBase, right: this.t().padBase })
      .margin({ top: this.t().gapTight, bottom: this.t().gapTight })
    } else if (node.kind === 'tile') {
      Column({ space: this.t().gapTight }) {
        if (node.icon.length > 0) {
          // Keyed for the reason given at the list row's chip.
          ForEach([node.icon + '|' + node.style], (_key: string) => {
            this.iconChip(node.icon, this.t().controlHeight - 8,
              node.style === 'default' ? this.t().primaryFill : this.t().surface,
              toneInk(this.t(), node.style, this.t().primaryInk))
          }, (key: string) => key)
        }
        if (node.label.length > 0) {
          Text(node.label).fontSize(this.t().sizeCaption).fontFamily(this.textFamily())
            .fontWeight(Math.max(this.t().weightHeading, 500)).fontColor(this.t().inkSoft)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
        Text(node.text).fontSize(this.statFigureSize()).fontFamily(this.textFamily('metric'))
          .fontWeight(this.t().weightMetric).fontColor(toneInk(this.t(), node.style, this.t().ink))
          .maxLines(1).minFontSize(14).maxFontSize(this.statFigureSize()).width('100%')
        if (node.value.length > 0) {
          Text(node.value).fontSize(this.t().sizeCaption).fontFamily(this.textFamily())
            .fontColor(this.t().inkSoft).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
      }
      // The tile is its row's flex item (see the grid above): its width is its share of the row, less half the gap, so the pair and
      // the wide tile line up at both edges; its height is the row's, stretched to the taller of the pair.
      .width(node.columns >= 2 ? '100%' : 'calc(50% - ' + (this.t().gapLoose / 2).toString() + 'vp)')
      .alignItems(HorizontalAlign.Start)
      .padding(this.t().padCard)
      .backgroundColor(toneFill(this.t(), node.style, this.t().surface))
      .border({ width: this.t().borderWidth, color: this.t().lineSoft })
      .borderRadius(this.t().radiusCard)
      .shadow({ radius: this.t().shadowRadius, color: this.t().shadowColor, offsetY: this.t().shadowOffsetY })
    } else if (node.kind === 'numbertext') {
      // ui.Text's twin for a number the program holds as a number.
      Text(this.formatNumber(node))
        .fontSize(this.renderTextSize(node.style))
        .fontFamily(this.textFamily(node.style))
        .fontWeight(textWeight(this.t(), node.style))
        .fontColor(textInk(this.t(), node.style))
        .width(parentKind === 'row' ? undefined : '100%')
        .constraintSize({ maxWidth: '100%' })
        .flexShrink(1)
        .padding({ top: 2, bottom: 2 })
    } else if (node.kind === 'clocktext') {
      Text(node.prefix + this.formatMinutes(node.numberValue) + unitAfter(node.numberValue, node.suffix))
        .fontSize(this.renderTextSize(node.style))
        .fontFamily(this.textFamily(node.style))
        .fontWeight(textWeight(this.t(), node.style))
        .fontColor(textInk(this.t(), node.style))
        .width(parentKind === 'row' ? undefined : '100%')
        .constraintSize({ maxWidth: '100%' })
        .flexShrink(1)
        .padding({ top: 2, bottom: 2 })
    } else if (node.kind === 'numberstat') {
      Column({ space: 2 }) {
        Row({ space: this.t().gapTight }) {
          if (node.icon.length > 0) {
            this.drawIcon(node.icon, this.t().sizeCaption,
              toneInk(this.t(), node.style, this.t().inkMuted))
          }
          if (node.label.length > 0) {
            Text(node.label)
              .fontSize(this.t().sizeCaption)
              .fontFamily(this.textFamily())
              .fontColor(this.t().inkMuted)
              .layoutWeight(1)
              // Two lines of fixed size and a fixed box, so every figure in a row sits on one baseline
              // and neighbouring labels are the same size; a longer label is cut, not shrunk.
              .maxLines(2)
              // Words are not torn apart in a narrow column ("Compoundin|g factor"): a long one is cut with an ellipsis.
              .wordBreak(WordBreak.NORMAL)
              .height(Math.round(this.t().sizeCaption * 2.6))
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        Text(this.formatNumber(node))
          .fontSize(this.figureSizeOf(node))
          // One line, shrunk to fit its column: "$120.50" in half a screen wrapped its last digit onto a second line.
          .maxLines(1)
          .minFontSize(14)
          .maxFontSize(this.figureSizeOf(node))
          .fontFamily(this.textFamily('metric'))
          .fontWeight(this.t().weightMetric)
          .fontColor(toneInk(this.t(), node.style, this.t().ink))
          .width('100%')
        if (node.value.length > 0) {
          Text(node.value)
            .fontSize(this.t().sizeCaption)
            .fontFamily(this.textFamily())
            .fontColor(this.t().inkSoft)
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(this.t().padTight)
    } else if (node.kind === 'numberfield') {
      // A stepper for a small count; a typed amount goes through ui.TextField
      // and strings.toNumber instead.
      Column({ space: this.t().gapTight }) {
        if (node.label.length > 0) {
          Text(node.label).fontSize(this.t().sizeCaption).fontFamily(this.textFamily())
            .fontWeight(Math.max(this.t().weightHeading, 500)).fontColor(this.t().inkStrong).width('100%')
        }
        Row({ space: this.t().gapBase }) {
          // − and + are one pair: the same size and the same tonal look, so neither reads as the more important one.
          Button('\u2212')
            .fontSize(this.t().sizeBody)
            .fontFamily(this.textFamily())
            .width(this.t().controlHeight - 8)
            .height(this.t().controlHeight - 8)
            .type(ButtonType.Circle)
            .enabled(node.enabled && node.numberValue > node.minimum)
            .backgroundColor(this.t().primaryFill)
            .fontColor(this.t().primary)
            .onClick(() => {
              if (node.action.length === 0) { return }
              // A step that does not fit stops at the limit: 3 with a step of 5 and a minimum of 0 goes to 0.
              let next = Math.max(node.minimum, node.numberValue - this.numberStep(node))
              if (next < node.numberValue) { this.handleAction(node.action, next, node) }
            })
          // The value is typed as well as stepped: tap it and write 60, rather than tapping + sixty times. It is taken when the
          // person is done editing and kept inside the field's own limits.
          ForEach([this.numberEpoch], (_epoch: number) => {
            TextInput({ text: this.formatNumber(node) })
              .type(InputType.Number)
              .fontSize(this.renderTextSize('heading'))
              .fontFamily(this.textFamily('metric'))
              .fontWeight(this.t().weightHeading)
              .fontColor(this.t().ink)
              .textAlign(TextAlign.Center)
              .backgroundColor(Color.Transparent)
              .borderRadius(0)
              .padding(0)
              .layoutWeight(1)
              .height(this.t().controlHeight - 8)
              .enabled(node.enabled)
              .onChange((typed: string) => { this.numberDraft.set(node, typed) })
              .onSubmit(() => { this.commitNumber(node) })
              .onEditChange((editing: boolean) => { if (!editing) { this.commitNumber(node) } })
          }, (epoch: number) => epoch.toString())
          Button('+')
            .fontSize(this.t().sizeBody)
            .fontFamily(this.textFamily())
            .width(this.t().controlHeight - 8)
            .height(this.t().controlHeight - 8)
            .type(ButtonType.Circle)
            .enabled(node.enabled && node.numberValue < node.maximum)
            .backgroundColor(this.t().primaryFill)
            .fontColor(this.t().primary)
            .onClick(() => {
              if (node.action.length === 0) { return }
              let next = Math.min(node.maximum, node.numberValue + this.numberStep(node))
              if (next > node.numberValue) { this.handleAction(node.action, next, node) }
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        // One pill holding both buttons and the value, rather than a circle at each edge of the screen.
        .height(this.t().controlHeight)
        .padding({ left: 4, right: 4 })
        .backgroundColor(this.t().fieldFill)
        .border({ width: this.t().borderWidth, color: this.t().fieldLine })
        .borderRadius(this.t().controlHeight / 2)
      }
      .width('100%')
      .padding({ top: this.t().gapTight, bottom: this.t().gapTight })
    } else if (node.kind === 'timefield') {
      Row({ space: this.t().gapBase }) {
        Text(node.label).fontSize(this.t().sizeBody).fontFamily(this.textFamily()).layoutWeight(1)
            .fontColor(this.t().ink)
        Button(this.formatMinutes(node.numberValue))
          .height(this.t().chipHeight)
          .fontSize(this.t().sizeBody)
          .fontFamily(this.textFamily())
          .type(ButtonType.Capsule)
          .enabled(node.enabled)
          .backgroundColor(this.t().secondaryFill)
          .fontColor(this.t().secondaryInk)
          .onClick(() => {
            if (node.action.length === 0) { return }
            // The phone's own picker, so the value is always a real time and
            // the program never has to validate one.
            let next = this.captureFieldAction(node.action, numberPayload(0), true, node)
            this.getUIContext().showTimePickerDialog({
              selected: this.minutesToDate(node.numberValue),
              useMilitaryTime: true,
              onAccept: (result: TimePickerResult) => {
                let h = result.hour !== undefined ? result.hour as number : 0
                let m = result.minute !== undefined ? result.minute as number : 0
                next.payload = numberPayload(h * 60 + m)
                this.enqueueFieldAction(next)
              }
            })
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: this.t().padRow, bottom: this.t().padRow })
    } else if (node.kind === 'datefield') {
      Row({ space: this.t().gapBase }) {
        Text(node.label).fontSize(this.t().sizeBody).fontFamily(this.textFamily()).layoutWeight(1)
            .fontColor(this.t().ink)
        Button(formatVeraDate(node.numberValue))
          .height(this.t().chipHeight)
          .fontSize(this.t().sizeBody)
          .fontFamily(this.textFamily())
          .type(ButtonType.Capsule)
          .enabled(node.enabled)
          .backgroundColor(this.t().secondaryFill)
          .fontColor(this.t().secondaryInk)
          .onClick(() => {
            if (node.action.length === 0) { return }
            // The phone's own calendar, as TimeField uses its clock dialog.
            let next = this.captureFieldAction(node.action, numberPayload(0), true, node)
            this.getUIContext().showDatePickerDialog({
              selected: this.dayToDate(node.numberValue),
              onDateAccept: (value: Date) => {
                next.payload = numberPayload(this.dateToDay(value))
                this.enqueueFieldAction(next)
              }
            })
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: this.t().padRow, bottom: this.t().padRow })
    } else if (node.kind === 'numberlistitem') {
      Row({ space: this.t().gapBase + 2 }) {
        if (node.icon.length > 0) {
          this.drawIcon(node.icon, this.t().sizeHeading,
            toneInk(this.t(), node.style, this.t().inkSoft))
        }
        Column({ space: 2 }) {
          Text(node.text).fontSize(this.t().sizeBody + 1).fontFamily(this.textFamily()).width('100%')
            .fontColor(this.t().ink)
          if (node.label.length > 0) {
            Text(node.label).fontSize(this.t().sizeCaption).fontFamily(this.textFamily()).fontColor(this.t().inkMuted).width('100%')
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text(this.formatNumber(node))
          .fontSize(this.t().sizeBody)
          .fontFamily(this.textFamily())
          .fontWeight(this.t().weightHeading)
          .fontColor(toneInk(this.t(), node.style, this.t().inkStrong))
      }
      .width('100%')
      .padding({ left: this.t().padListX, right: this.t().padListX,
                 top: this.t().padListY, bottom: this.t().padListY })
      // Identical framing rules to ui.ListItem, so the two mix inside one
      // ListGroup without the rows disagreeing about whether they have borders.
      .backgroundColor(toneFill(this.t(), node.style,
        parentKind === 'listgroup' ? '#00000000' : this.t().surfaceRaised))
      .border({
        width: parentKind === 'listgroup' ? 0 : this.t().borderWidth,
        color: this.t().lineSoft
      })
      .borderRadius(parentKind === 'listgroup' ? 0 : this.t().radiusControl)
      .margin({
        top: parentKind === 'listgroup' ? 0 : this.t().gapTight - 1,
        bottom: parentKind === 'listgroup' ? 0 : this.t().gapTight - 1
      })
      .opacity(this.rowOpacity(node))
      .onClick(() => {
        if (node.action.length > 0 && node.enabled) {
          this.handleAction(node.action, node.eventValue, node)
        }
      })
    } else if (node.kind === 'actionbar' && parentKind === 'listgroup') {
      // Inside a group the bar belongs to the row above it, so it is inset to
      // the row's own margin and packs to one end instead of spreading across
      // the full width, where two buttons end up in opposite corners.
      Flex({
        wrap: FlexWrap.Wrap,
        justifyContent: FlexAlign.End,
        alignItems: ItemAlign.Center,
        space: { main: LengthMetrics.vp(this.t().gapBase),
                 cross: LengthMetrics.vp(this.t().gapTight) }
      }) {
        this.renderChildren(node)
      }
      .width('100%')
      .padding({ left: this.t().padListX, right: this.t().padListX,
                 top: 0, bottom: this.t().gapBase })
    } else if (node.kind === 'actionbar') {
      // Wraps rather than overflowing, for the reason the plain row branch
      // gives: a control past the right edge cannot be tapped.
      Flex({
        wrap: FlexWrap.Wrap,
        justifyContent: node.style === 'end' ? FlexAlign.End :
          node.style === 'center' ? FlexAlign.Center :
            node.style === 'spread' ? FlexAlign.SpaceBetween : FlexAlign.Start,
        alignItems: ItemAlign.Center,
        space: { main: LengthMetrics.vp(this.t().gapBase),
                 cross: LengthMetrics.vp(this.t().gapTight) }
      }) {
        this.renderChildren(node)
      }
      .width('100%')
      .padding({ top: this.t().gapBase, bottom: this.t().gapBase })
    } else if (node.kind === 'timeline') {
      // The rail belongs to the timeline, not to the entry.
      //
      // An entry cannot draw the line below itself, because it does not know
      // whether it is the last one, and a rail that runs on past the final
      // marker reads as an unfinished list. The parent knows, so the parent
      // draws both the marker and the line, and the entry draws only its words.
      Column() {
        if (node.text.length > 0) {
          Text(node.text)
            .fontSize(this.t().sizeCaption)
            .fontFamily(this.textFamily())
            .fontWeight(this.t().weightHeading)
            .fontColor(this.t().inkMuted)
            .width('100%')
            .padding({ bottom: this.t().gapTight })
        }
        ForEach(node.children, (child: LiveNode, index: number) => {
          // The rail is the entry's own left border.
          //
          // It has to be exactly as tall as the entry beside it, and every way
          // of asking for that height directly fails: height('100%') inside a
          // Scroll resolves against an unbounded height and stretches the first
          // entry down the whole screen, in a Row and in a Stack alike -- both
          // were tried and both did it. A border needs no height at all. It is
          // drawn down the side of the content whatever the content turns out
          // to be, which is the thing that was wanted, and the last entry
          // simply has none so the rail stops where the events do.
          //
          // The marker then sits over the line on a disc of the background
          // colour, which is what breaks the rail at each node.
          Stack({ alignContent: Alignment.TopStart }) {
            Column() {
              this.renderNode(child, 'timeline')
            }
            .width('100%')
            .padding({ left: this.timelineMarker() / 2 + this.t().gapBase })
            .border({
              // The last entry keeps the rail's width but not its colour, so its words line up with the rest.
              width: { left: this.t().borderWidth * 2 },
              color: { left: index < node.children.length - 1 ? this.t().lineStrong : '#00000000' }
            })

            // A marker means "a moment happened here", so only an entry gets
            // one. The other things a timeline may hold -- the ActionBar that
            // belongs to the entry above it -- sit against the rail without
            // interrupting it, which is what they are: part of that moment, not
            // another one.
            Column() {
              if (child.kind === 'timelineitem' && child.icon.length > 0) {
                this.drawIcon(child.icon, this.t().sizeBody - 2,
                  toneEdge(this.t(), child.style, this.t().primaryInk))
              } else if (child.kind === 'timelineitem') {
                Column()
                  .width(this.t().gapBase)
                  .height(this.t().gapBase)
                  .borderRadius(this.t().gapBase / 2)
                  .backgroundColor(toneEdge(this.t(), child.style, this.t().primaryInk))
              }
            }
            .width(child.kind === 'timelineitem' ? this.timelineMarker() : 0)
            .height(child.kind === 'timelineitem' ? this.timelineMarker() : 0)
            .borderRadius(this.timelineMarker() / 2)
            .backgroundColor(child.kind === 'timelineitem'
              ? toneFill(this.t(), child.style, this.t().primaryFill) : '#00000000')
            .alignItems(HorizontalAlign.Center)
            .justifyContent(FlexAlign.Center)
            .offset({ x: -(this.timelineMarker() / 2) })
            // Same keying as renderChildren; see the note there.
          }
          .width('100%')
        }, (child: LiveNode, index: number) => index.toString() + ':' + child.kind)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({
        left: densityPad(this.t(), node.style) + this.timelineMarker() / 2,
        right: densityPad(this.t(), node.style),
        top: densityPad(this.t(), node.style),
        bottom: densityPad(this.t(), node.style)
      })
      .margin({ top: this.t().gapTight, bottom: this.t().gapSection })
    } else if (node.kind === 'timelineitem') {
      // Only the words: the marker and the rail beside it are the timeline's.
      Column({ space: 2 }) {
        Row({ space: this.t().gapBase }) {
          Text(node.text)
            .fontSize(this.t().sizeBody + 1)
            .fontFamily(this.textFamily())
            .fontWeight(this.t().weightHeading)
            .fontColor(toneInk(this.t(), node.style, this.t().ink))
            .layoutWeight(1)
          if (node.value.length > 0) {
            Text(node.value)
              .fontSize(this.t().sizeBody)
              .fontFamily(this.textFamily())
              .fontColor(this.t().inkSoft)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        if (node.label.length > 0) {
          Text(node.label)
            .fontSize(this.t().sizeCaption)
            .fontFamily(this.textFamily())
            .fontColor(this.t().inkSoft)
            .width('100%')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ top: Math.round((this.timelineMarker() - this.t().sizeBody * 1.3) / 2),
                 bottom: node.style === 'compact' ? this.t().gapBase : this.t().gapLoose })
      .opacity(this.rowOpacity(node))
      .onClick(() => {
        if (node.action.length > 0 && node.enabled) {
          this.handleAction(node.action, node.eventValue, node)
        }
      })
    } else if (node.kind === 'kvgroup') {
      Flex({
        wrap: FlexWrap.Wrap,
        justifyContent: FlexAlign.Start,
        alignItems: ItemAlign.Start
      }) {
        ForEach(node.children, (child: LiveNode) => {
          Column() {
            this.renderNode(child, 'kvgroup')
          }
          // A fact needs more room than a figure, so it asks for a wider cell.
          .width(Math.floor(100 / this.fittingColumns(
            node.columns > 0 ? node.columns : 2, 160)).toString() + '%')
          // Same keying as renderChildren; see the note there.
        }, (child: LiveNode, index: number) => index.toString() + ':' + child.kind)
      }
      .width('100%')
      .padding(densityPad(this.t(), node.style) - this.t().padTight)
      .margin({ top: this.t().gapTight, bottom: this.t().gapTight })
    } else if (node.kind === 'kvitem') {
      Column({ space: 2 }) {
        Text(node.label)
          .fontSize(this.t().sizeCaption)
          .fontFamily(this.textFamily())
          .fontColor(this.t().inkMuted)
          .width('100%')
        Text(node.text)
          .fontSize(this.t().sizeBody)
          .fontFamily(this.textFamily())
          .fontWeight(this.t().weightHeading)
          .fontColor(toneInk(this.t(), node.style, this.t().ink))
          .width('100%')
        if (node.value.length > 0) {
          Text(node.value)
            .fontSize(this.t().sizeCaption)
            .fontFamily(this.textFamily())
            .fontColor(this.t().inkSoft)
            .width('100%')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(this.t().padBase)
    } else if (node.kind === 'table') {
      // Same one-frame-around-the-collection shape as 'listgroup': the table
      // owns the border, the radius and the rule between rows, so a row
      // (below) draws nothing of its own.
      Column() {
        if (node.options.length > 0) {
          Row() {
            ForEach(node.options, (h: string, index: number) => {
              Text(h)
                .fontSize(this.t().sizeCaption)
                .fontFamily(this.textFamily())
                .fontWeight(this.t().weightHeading)
                .fontColor(this.t().inkMuted)
                .layoutWeight(1)
            }, (h: string, index: number) => index.toString() + ':' + h)
          }
          .width('100%')
          .padding({ left: this.t().padListX, right: this.t().padListX,
                     top: this.t().gapBase, bottom: this.t().gapTight })
        }
        ForEach(node.children, (child: LiveNode, index: number) => {
          if (index > 0 && child.kind === 'tablerow') {
            Divider().strokeWidth(this.t().borderWidth).color(this.t().lineSoft)
              .margin({ left: this.t().padListX, right: this.t().padListX })
          }
          this.renderNode(child, 'table')
        }, (child: LiveNode, index: number) => index.toString() + ':' + child.kind)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(this.t().surfaceRaised)
      .border({ width: this.t().borderWidth, color: this.t().lineSoft })
      .borderRadius(this.t().radiusCard)
      .shadow({ radius: this.t().shadowRadius, color: this.t().shadowColor, offsetY: this.t().shadowOffsetY })
    } else if (node.kind === 'tablerow') {
      // Each row's own cells (node.options) say how many columns it draws --
      // not the table's columns prop, which exists for the model to keep
      // every row and the header the same length, not for the renderer to
      // enforce at runtime.
      Row() {
        ForEach(node.options, (cell: string, index: number) => {
          Text(cell)
            .fontSize(this.t().sizeBody)
            .fontFamily(this.textFamily())
            .fontColor(this.t().ink)
            .layoutWeight(1)
        }, (cell: string, index: number) => index.toString() + ':' + cell)
      }
      .width('100%')
      .padding({ left: this.t().padListX, right: this.t().padListX,
                 top: this.t().padListY, bottom: this.t().padListY })
      .backgroundColor(toneFill(this.t(), node.style, '#00000000'))
    } else if (node.kind === 'icon') {
      this.drawIcon(node.icon, this.t().sizeHeading,
        toneInk(this.t(), node.style, this.t().inkStrong))
    } else if (node.kind === 'iconbutton') {
      // Sized to the same 44 as a text button, so a row of mixed actions lines
      // up and the tap target stays a tap target.
      Column() {
        this.drawIcon(node.icon, this.t().sizeHeading,
          node.style === 'quiet' || node.style === 'secondary'
            ? this.t().secondaryInk : this.t().onPrimary)
      }
      .width(this.t().controlHeight)
      .height(this.t().controlHeight)
      .alignItems(HorizontalAlign.Center)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(node.style === 'quiet' ? '#00000000'
        : node.style === 'secondary' ? this.t().secondaryFill
          : buttonFill(this.t(), node.style))
      .borderRadius(this.t().controlHeight / 2)
      .opacity(node.enabled ? 1 : 0.4)
      .accessibilityText(node.label)
      .onClick(() => {
        if (node.action.length > 0 && node.enabled) {
          this.handleAction(node.action, node.eventValue, node)
        }
      })
    } else if (node.kind === 'badge') {
      Row({ space: this.t().gapTight }) {
        if (node.icon.length > 0) {
          this.drawIcon(node.icon, this.t().sizeCaption,
            toneInk(this.t(), node.style, this.t().inkSoft))
        }
        Text(node.text)
          .fontSize(this.t().sizeCaption)
          .fontFamily(this.textFamily())
          .fontWeight(this.t().weightHeading)
          .fontColor(toneInk(this.t(), node.style, this.t().inkSoft))
      }
      .padding({ left: this.t().gapBase, right: this.t().gapBase,
                 top: this.t().gapTight - 1, bottom: this.t().gapTight - 1 })
      .backgroundColor(toneFill(this.t(), node.style, this.t().surface))
      .borderRadius(this.t().radiusSmall)
    } else if (node.kind === 'timer') {
      TextTimer({ isCountDown: this.textTimerFace(node).countDown, count: this.textTimerFace(node).count,
                  startTime: this.textTimerFace(node).startTime, controller: this.textTimerOf(node) })
        .format(this.textTimerFace(node).format)
        .fontSize(textSize(this.t(), node.style))
        .fontWeight(textWeight(this.t(), node.style))
        .fontColor(textInk(this.t(), node.style))
        .onAppear(() => { this.textTimerOf(node).start() })
    } else if (node.kind === 'skeleton') {
      // width/height/rounded ride minimum/maximum/checked -- the same field
      // reuse Ticker already does for intervalMs/running, so decode needed
      // no new case.
      Column()
        .width(node.minimum > 0 ? node.minimum : 120)
        .height(node.maximum > 0 ? node.maximum : 16)
        .backgroundColor(this.t().surfaceDisabled)
        .borderRadius(node.checked ? (node.maximum > 0 ? node.maximum : 16) / 2 : this.t().radiusSmall)
    } else if (node.kind === 'spinner') {
      // ArkUI's own LoadingProgress animates on its own -- no extra timer or
      // @Trace angle needed, unlike ui.Path's hand-rolled spin.
      Row({ space: this.t().gapTight }) {
        LoadingProgress()
          .width(this.t().sizeHeading)
          .height(this.t().sizeHeading)
          .color(toneInk(this.t(), node.style, this.t().primary))
        if (node.label.length > 0) {
          Text(node.label).fontSize(this.t().sizeCaption).fontFamily(this.textFamily()).fontColor(this.t().inkSoft)
        }
      }
      .alignItems(VerticalAlign.Center)
    } else if (node.kind === 'snackbar') {
      // Not in the content: programFrame draws it over the window.
      Blank().height(0).width(0)
    } else if (node.kind === 'button') {
      Button(node.text.length === 0 ? ' ' : node.text)
        .height(parentKind === 'rowbar' ? this.t().controlHeight - 12 : this.t().controlHeight)
        .fontSize(parentKind === 'rowbar' ? this.t().sizeCaption : this.t().sizeBody)
        .fontFamily(this.textFamily())
        .enabled(node.enabled)
        // Every button is a capsule: a square secondary next to a round primary read as two different kinds of control.
        .type(ButtonType.Capsule)
        .backgroundColor(buttonFill(this.t(), node.style))
        .fontColor(buttonInk(this.t(), node.style))
        .onClick(() => {
          if (node.action.length > 0 && node.enabled) {
            // A button press is the attempt after which an empty required field of its own form is worth pointing out.
            this.touchFormOf(node)
            this.handleAction(node.action, node.eventValue, node)
          }
        })
    } else if (node.kind === 'cell') {
      Column() {
        // Two steps below the title size: a board glyph, not a heading.
        Text(node.text).fontSize(this.t().sizeTitle - 2).fontFamily(this.textFamily()).fontWeight(FontWeight.Bold)
          .fontColor(node.enabled ? this.t().inkStrong : this.t().inkDisabled)
      }
      .layoutWeight(parentKind === 'grid' ? 0 : 1)
      .width(parentKind === 'grid' ? '100%' : undefined)
      // A board cell should be square. Outside a row a cell is a list item and
      // keeps a comfortable fixed height instead.
      .aspectRatio(parentKind === 'row' || parentKind === 'grid' ? 1 : 0)
      .height(parentKind === 'row' || parentKind === 'grid' ? undefined : 68)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(node.enabled ? this.t().surfaceRaised : this.t().surfaceDisabled)
      .border({
        width: node.style === 'accent' ? this.t().borderWidth * 2 : this.t().borderWidth,
        color: toneEdge(this.t(), node.style, this.t().lineStrong)
      })
      .borderRadius(this.t().radiusControl)
      .onClick(() => {
        if (node.action.length > 0 && node.enabled) {
          this.handleAction(node.action, node.eventValue, node)
        }
      })
    } else if (node.kind === 'spacer') {
      if (node.style !== 'none') {
        Blank()
          .height(parentKind === 'row' ? 0 : spacerSize(this.t(), node.style))
          .width(parentKind === 'row' ? spacerSize(this.t(), node.style) : 0)
      }
    } else if (node.kind === 'field') {
      Column({ space: this.t().gapTight }) {
        if (node.label.length > 0) {
          Text(node.label).fontSize(this.t().sizeCaption).fontFamily(this.textFamily())
            .fontWeight(Math.max(this.t().weightHeading, 500)).fontColor(this.t().inkStrong).width('100%')
        }
        // Commits on submit rather than on every keystroke. The tree no longer
        // rebuilds under the caret, but echoing each character back through the
        // VM and into .text() still fights whoever is typing.
        // The label is already drawn above the box, so it is not repeated inside it as a placeholder.
        ForEach([node.fieldGeneration], (generation: number) => {
          TextInput({ placeholder: node.label.length > 0 ? '' : ' ', text: node.fieldValue,
            controller: this.fieldController(node, generation) })
            .fontSize(this.t().sizeBody)
            .fontFamily(this.textFamily())
            .fontColor(this.t().ink)
            .placeholderColor(this.t().inkMuted)
            .caretColor(this.t().primary)
            .backgroundColor(this.t().fieldFill)
            .border({ width: this.t().borderWidth, color: this.t().fieldLine })
            .borderRadius(this.t().radiusControl)
            .height(node.style === 'multiline' ? this.t().controlHeight * 2 : this.t().controlHeight)
            .width('100%')
            .enabled(node.enabled)
            .type(this.textFieldKeyboard(node))
            .onChange((v: string, previewText?: PreviewText) => {
              this.changeField(node, generation, v, previewText !== undefined && previewText.value.length > 0)
            })
            .onSubmit((_key: EnterKeyType, event: SubmitEvent) => { this.finishField(node, generation, event.text) })
            .onEditChange((editing: boolean) => { if (!editing) { this.endFieldEditing(node, generation) } })
        }, (generation: number) => generation.toString())
        if (node.fieldIssue.length > 0) {
          Text(node.fieldIssue).fontSize(this.t().sizeCaption).fontFamily(this.textFamily()).fontColor(this.t().dangerInk)
            .width('100%')
        }
      }
      .width('100%')
      .padding({ top: this.t().gapTight, bottom: this.t().gapTight })
    } else if (node.kind === 'toggle' || node.kind === 'checkbox') {
      Row({ space: this.t().gapBase + 2 }) {
        Text(node.label).fontSize(this.t().sizeBody).fontFamily(this.textFamily()).layoutWeight(1)
            .fontColor(this.t().ink)
        if (node.kind === 'toggle') {
          Toggle({ type: ToggleType.Switch, isOn: node.checked })
            .enabled(node.enabled)
            .selectedColor(this.t().primary)
            .onChange((on: boolean) => {
              if (node.action.length > 0) { this.handleBoolAction(node.action, on, node) }
            })
        } else {
          Checkbox()
            .select(node.checked)
            .enabled(node.enabled)
            .selectedColor(this.t().primary)
            .onChange((on: boolean) => {
              if (node.action.length > 0) { this.handleBoolAction(node.action, on, node) }
            })
        }
      }
      .width('100%')
      .padding({ top: this.t().padRow, bottom: this.t().padRow })
    } else if (node.kind === 'slider') {
      Column({ space: 2 }) {
        Row() {
          Text(node.label).fontSize(this.t().sizeCaption).fontFamily(this.textFamily())
            .fontWeight(Math.max(this.t().weightHeading, 500)).fontColor(this.t().inkStrong).layoutWeight(1)
          Text(node.eventValue.toString()).fontSize(this.t().sizeCaption).fontFamily(this.textFamily('metric'))
            .fontWeight(Math.max(this.t().weightHeading, 500)).fontColor(this.t().primaryInk)
        }.width('100%')
        Slider({
          value: node.eventValue,
          min: node.minimum,
          max: node.maximum,
          step: 1,
          style: SliderStyle.OutSet
        })
          .width('100%')
          .enabled(node.enabled)
          .selectedColor(toneEdge(this.t(), node.style, this.t().primary))
          .onChange((v: number, mode: SliderChangeMode) => {
            // Every position reaches the program, so the thing being controlled
            // follows the thumb instead of jumping when the finger lifts -- a
            // slider that only answers on release reads as broken. Only the end
            // of the drag is written to disk, so a drag is one save, not fifty.
            if (node.action.length === 0) { return }
            this.dispatchFieldAction(node.action, numberPayload(Math.round(v)),
              mode === SliderChangeMode.End, node)
          })
      }
      .width('100%')
      .padding({ top: this.t().gapTight, bottom: this.t().gapTight })
    } else if (node.kind === 'select') {
      Column({ space: this.t().gapTight }) {
        if (node.label.length > 0) {
          Text(node.label).fontSize(this.t().sizeCaption).fontFamily(this.textFamily())
            .fontWeight(Math.max(this.t().weightHeading, 500)).fontColor(this.t().inkStrong).width('100%')
        }
        // A single trigger showing the current choice, with the rest of the
        // options in a system overlay menu rather than always on screen. The
        // chip row this replaced drew every option whether or not it was the
        // one picked, which is what ran a five-plus-option Select off the
        // right edge before Flex-wrap fixed the overflow -- this removes the
        // row entirely rather than giving it more room to wrap into.
        Row({ space: this.t().gapTight }) {
          Text(this.selectDisplayText(node))
            .fontSize(this.t().sizeBody)
            .fontColor(node.enabled ? this.t().ink : this.t().inkMuted)
            .fontFamily(this.textFamily())
            .layoutWeight(1)
          Row() { this.drawIcon('chevron-right', this.t().sizeCaption, this.t().inkSoft) }
            .rotate({ angle: 90 })
        }
        .width('100%')
        .height(this.t().controlHeight)
        .padding({ left: this.t().padBase, right: this.t().padBase })
        .borderRadius(this.t().radiusControl)
        .backgroundColor(this.t().fieldFill)
        .border({ width: this.t().borderWidth, color: this.t().fieldLine })
        .opacity(node.enabled ? 1 : 0.5)
        .enabled(node.enabled)
        .bindMenu(this.selectMenuItems(node), {
          aboutToAppear: () => { this.openFieldMenu(node) },
          onDisappear: () => { this.fieldMenus.delete(node) }
        })
      }
      .width('100%')
      .padding({ top: this.t().gapTight, bottom: this.t().gapTight })
    } else if (node.kind === 'tabs') {
      // One window: a row of tab names, and the selected pane under it. In a chat reply the pane is as tall as it needs, up to a
      // limit, and scrolls inside the window past it, so the window does not grow with what a pane holds.
      Column({ space: this.t().gapTight }) {
        Row({ space: this.t().gapTight }) {
          ForEach(node.options, (label: string, index: number) => {
            Text(label)
              .fontSize(this.t().sizeBody)
              .fontFamily(this.textFamily())
              .fontWeight(this.t().weightHeading)
              .fontColor(index === this.tabSelected(node) ? this.t().onPrimary : this.t().ink)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .height(this.t().controlHeight)
              .borderRadius(this.t().radiusControl)
              .backgroundColor(index === this.tabSelected(node) ? this.t().primary : this.t().fieldFill)
              .onClick(() => {
                if (node.action.length > 0) { this.handleAction(node.action, index, node) }
              })
          }, (label: string, index: number) => index.toString() + ':' + label)
        }
        .width('100%')
        // One Scroll per pane, keyed by the selected tab: a pane opens at its top, not at the offset the last one
        // was left at. At either end the pane's scroll passes on to what holds it, so a chat keeps scrolling past it.
        ForEach(this.tabPane(node), (pane: LiveNode) => {
          Scroll() {
            Column() {
              this.renderNode(pane, 'tabs')
            }
            .width('100%')
          }
          .width('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.None)
          .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
          .constraintSize({ maxHeight: this.embedded ? EMBEDDED_WINDOW : 100000 })
        }, (pane: LiveNode) => this.tabSelected(node).toString())
      }
      .width('100%')
      .padding({ top: this.t().gapTight, bottom: this.t().gapTight })
    } else if (node.kind === 'grid') {
      // Equal columns built from a wrapping Flex rather than ArkUI's Grid: Grid
      // wants an explicit height, while a generated tree grows to whatever the
      // program produced. Each child is boxed at its share of the width, so the
      // cells stay square and wrap onto new rows by themselves.
      Flex({
        wrap: FlexWrap.Wrap,
        justifyContent: FlexAlign.Start,
        alignItems: ItemAlign.Start
      }) {
        ForEach(node.children, (child: LiveNode) => {
          Column() {
            this.renderNode(child, 'grid')
          }
          .width(Math.floor(100 / (node.columns > 0 ? node.columns : 1)).toString() + '%')
          .padding(this.gridPad(node.style))
          // Same keying as renderChildren; see the note there.
        }, (child: LiveNode, index: number) => index.toString() + ':' + child.kind)
      }
      .width('100%')
      .padding(this.t().padGrid)
    } else if (node.kind === 'listitem') {
      Row({ space: this.t().gapBase + 2 }) {
        if (node.icon.length > 0) {
          // Keyed on the icon and the tone: iconChip takes its arguments by value and is not drawn again when they change, so a
          // stop ticked as reached kept its pin on a neutral disc while the row around it turned green.
          ForEach([node.icon + '|' + node.style], (_key: string) => {
            this.iconChip(node.icon, this.t().controlHeight - 4,
              toneFill(this.t(), node.style, this.t().primaryFill),
              toneInk(this.t(), node.style, this.t().primaryInk))
          }, (key: string) => key)
        } else if (node.iconRoom) {
          // Not a Blank: in a Row that grows to take the free width.
          Column().width(this.t().controlHeight - 4).height(this.t().controlHeight - 4)
        }
        Column({ space: 2 }) {
          Text(node.text).fontSize(this.t().sizeBody + 1).fontFamily(this.textFamily()).width('100%')
            .fontColor(this.t().ink)
          if (node.label.length > 0) {
            Text(node.label).fontSize(this.t().sizeCaption).fontFamily(this.textFamily()).fontColor(this.t().inkMuted).width('100%')
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (node.value.length > 0) {
          Text(node.value).fontSize(this.t().sizeBody - 1).fontFamily(this.textFamily()).fontColor(this.t().inkSoft)
        }
        // The row's one action sits at its end, not on a line of its own under it.
        ForEach(this.rowButton(node), (button: LiveNode) => {
          this.renderNode(button, 'rowbar')
        }, (button: LiveNode, index: number) => index.toString())
      }
      .width('100%')
      .padding({ left: this.t().padListX, right: this.t().padListX,
                 top: this.t().padListY, bottom: this.t().padListY })
      // Inside a ListGroup the row owns no frame of its own: the group draws
      // one border, one radius and the separators, which is the whole reason
      // ListGroup exists. On its own the row is still a standalone card.
      .backgroundColor(toneFill(this.t(), node.style,
        parentKind === 'listgroup' ? '#00000000' : this.t().surfaceRaised))
      .border({
        width: parentKind === 'listgroup' ? 0 : this.t().borderWidth,
        color: this.t().lineSoft
      })
      .borderRadius(parentKind === 'listgroup' ? 0 : this.t().radiusControl)
      .margin({
        top: parentKind === 'listgroup' ? 0 : this.t().gapTight - 1,
        bottom: parentKind === 'listgroup' ? 0 : this.t().gapTight - 1
      })
      .opacity(this.rowOpacity(node))
      .onClick(() => {
        if (node.action.length > 0 && node.enabled) {
          this.handleAction(node.action, node.eventValue, node)
        }
      })
    } else if (node.kind === 'ticker') {
      // Draws nothing: it exists so the host will call the program on a timer.
      Blank().height(0).width(0)
    } else if (node.kind === 'backhandler') {
      // Draws nothing: see reconcileBackHandler, which is what actually acts on it.
      Blank().height(0).width(0)
    } else if (node.kind === 'divider') {
      Divider().strokeWidth(this.t().borderWidth).color(this.t().line)
        .margin({ top: this.t().padRow, bottom: this.t().padRow })
    } else if (node.kind === 'progress') {
      Column({ space: 6 }) {
        // The label on the left and how far along on the right, so the bar needs no second line to be read.
        Row() {
          Text(node.label).fontSize(this.t().sizeCaption).fontFamily(this.textFamily())
            .fontWeight(Math.max(this.t().weightHeading, 500)).fontColor(this.t().inkStrong).layoutWeight(1)
          Text(Math.round(100 * node.eventValue / (node.maximum > 0 ? node.maximum : 100)).toString() + '%')
            .fontSize(this.t().sizeCaption).fontFamily(this.textFamily('metric'))
            .fontWeight(Math.max(this.t().weightHeading, 500)).fontColor(this.t().primaryInk)
        }
        .width('100%')
        Progress({
          value: node.eventValue,
          total: node.maximum > 0 ? node.maximum : 100,
          type: ProgressType.Linear
        })
          .width('100%')
          .style({ strokeWidth: 10, strokeRadius: 5 })
          .color(toneEdge(this.t(), node.style, this.t().primary))
          .backgroundColor(this.t().lineSoft)
      }
      .width('100%')
      .padding({ top: this.t().gapTight, bottom: this.t().gapTight })
    } else if (node.kind === 'progressring') {
      Column({ space: this.t().gapTight }) {
        Stack({ alignContent: Alignment.Center }) {
          Progress({
            value: node.eventValue,
            total: node.maximum > 0 ? node.maximum : 100,
            type: ProgressType.Ring
          })
            .width(this.ringSize())
            .height(this.ringSize())
            .style({ strokeWidth: 12 })
            .color(toneEdge(this.t(), node.style, this.t().primary))
            .backgroundColor(this.t().lineSoft)
          Text(node.text.length > 0 ? node.text :
            Math.round(100 * node.eventValue / (node.maximum > 0 ? node.maximum : 100)).toString() + '%')
            .fontSize(this.renderTextSize('heading'))
            .fontFamily(this.textFamily('metric'))
            .fontWeight(this.t().weightMetric)
            .fontColor(toneInk(this.t(), node.style, this.t().ink))
            .maxLines(1)
            .textAlign(TextAlign.Center)
            .width(this.ringSize() - 36)
        }
        if (node.label.length > 0) {
          Text(node.label).fontSize(this.t().sizeCaption).fontFamily(this.textFamily())
            .fontWeight(Math.max(this.t().weightHeading, 500)).fontColor(this.t().inkStrong)
            .textAlign(TextAlign.Center).width('100%')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ top: this.t().gapBase, bottom: this.t().gapBase })
    } else if (node.kind === 'sparkline') {
      // The path commands are written directly in this box's own real vp
      // (chartWidth's own comment has the full story on why, and on the
      // viewPort-based approach this replaced). The renderer does the
      // normalising -- the program hands raw values and a scale, not a
      // pre-computed string, which is the point of series travelling as
      // number[] rather than as text.
      Column({ space: 4 }) {
        if (node.label.length > 0) {
          Text(node.label).fontSize(this.t().sizeBody).fontFamily(this.textFamily())
            .fontColor(this.t().inkSoft).width('100%')
        }
        if (node.bars) {
          // Plain flex layout instead of Shape/Path -- one column per value,
          // each ui.ListItem/Table cell's own .layoutWeight(1) trick stretches
          // it to its even share of the row, no path coordinates and no
          // measured width needed at all. See chartWidth's own comment for
          // why that measurement is what made the line branch below unsafe
          // to trust for this: bars do not have to share that risk when
          // ArkUI's own flex layout already divides the width correctly.
          Row({ space: 6 }) {
            // barHeights is called once here, to build the array this
            // ForEach iterates -- not from inside its item builder. That
            // distinction is the whole fix: renderNode is @LocalBuilder, and
            // five shapes of this ForEach's item builder reading node.max-
            // imum itself -- a let before the loop, a @Component method
            // call, a bare function call, and two hand-written inline
            // expressions, all reading node.maximum alongside the item's
            // own v -- each compiled clean but left every bar but the
            // tallest missing from the render tree on device (confirmed
            // with uitest dumpLayout each time). Only node.series' own
            // values, read straight by the ForEach above with nothing
            // else touched per item, ever drew right. barHeights reads
            // node.maximum exactly once, outside any item builder, and
            // hands ForEach the one thing already proven safe inside one:
            // each item's own plain closure variable.
            ForEach(this.barItems(node), (item: BarItem, index: number) => {
              // One column per bar: its value over it, the bar, its name under it. The value and the
              // name come from the item, never from node, for the reason above.
              Column({ space: 4 }) {
                Text(item.value).fontSize(this.t().sizeCaption).fontFamily(this.textFamily())
                  .fontColor(this.t().ink).maxLines(1)
                Column()
                  .width('100%')
                  .height(item.height)
                  .borderRadius(2)
                  .backgroundColor(toneEdge(this.t(), node.style, this.t().primary))
                if (item.label.length > 0) {
                  Text(item.label).fontSize(this.t().sizeCaption).fontFamily(this.textFamily())
                    .fontColor(this.t().inkSoft).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .textAlign(TextAlign.Center).width('100%')
                }
              }
              .layoutWeight(1)
              .height(VeraPreview.SPARKLINE_HEIGHT + VeraPreview.BAR_LABEL_ROOM)
              .justifyContent(FlexAlign.End)
            // The key carries everything the column shows: with the index alone a bar that was drawn
            // at 0 (its friend had paid nothing yet) kept that height when the series changed, because
            // ForEach does not rebuild an item whose key is unchanged. Seen with the shared-costs
            // prompt: Anna paid first, Ben second, and only Anna's bar ever showed.
            }, (item: BarItem, index: number) => index.toString() + ':' + item.height.toFixed(1) + ':' + item.value + ':' + item.label)
          }
          .width('100%')
          .height(VeraPreview.SPARKLINE_HEIGHT + VeraPreview.BAR_LABEL_ROOM)
          .alignItems(VerticalAlign.Bottom)
        } else {
          Row({ space: this.t().gapTight }) {
            // The four y-axis labels, top (maximum) to bottom (floor) --
            // sparklineTicks and sparklineGridCommands divide the same range
            // into the same four levels, so a label and its gridline always
            // land at the same height without either one measuring the other.
            Column() {
              ForEach(this.sparklineTicks(node.maximum, node.minimum), (v: string, _index: number) => {
                Text(v).fontSize(this.t().sizeCaption).fontFamily(this.textFamily())
                  .fontColor(this.t().inkMuted)
              }, (v: string, index: number) => index.toString() + v)
            }
            .height(VeraPreview.SPARKLINE_HEIGHT)
            // The gridlines sit SPARKLINE_INSET inside the box; a caption is about 16vp tall, so half of it is
            // taken off that to put each caption's middle on its gridline.
            .padding({ top: VeraPreview.SPARKLINE_INSET - 8, bottom: VeraPreview.SPARKLINE_INSET - 8 })
            .justifyContent(FlexAlign.SpaceBetween)
            .alignItems(HorizontalAlign.End)
            .onAreaChange((_old: Area, now: Area) => {
              let w = now.width as number
              if (Math.abs(w - this.sparklineAxisWidth) >= 1) { this.sparklineAxisWidth = w }
            })

            Shape() {
              Path({ commands: this.sparklineGridCommands(node.maximum, node.minimum, this.chartWidth()) })
                .fill(Color.Transparent)
                .stroke(this.t().line)
                .strokeWidth('1px')
              // A second series present turns this into a comparison chart: both
              // lines are plain strokes with no area fill, since two overlapping
              // fills read as a muddy blob rather than two readable lines. The
              // single-series area fill below is unchanged, so an existing
              // one-line chart still reads as a filled trend, not a bare line.
              if (node.series2.length > 0) {
                Path({ commands: this.sparklineCommands(node.series, node.maximum, node.minimum, this.chartWidth()) })
                  .fill(Color.Transparent)
                  .stroke(toneEdge(this.t(), node.style, this.t().primary))
                  .strokeWidth('3px')
                  .strokeLineCap(LineCapStyle.Round)
                  .strokeLineJoin(LineJoinStyle.Round)
                Path({ commands: this.sparklineCommands(node.series2, node.maximum, node.minimum, this.chartWidth()) })
                  .fill(Color.Transparent)
                  .stroke(toneEdge(this.t(), node.series2Style, this.t().primary))
                  .strokeWidth('3px')
                  .strokeLineCap(LineCapStyle.Round)
                  .strokeLineJoin(LineJoinStyle.Round)
                Path({ commands: this.sparklineDotCommands(node.series, node.maximum, node.minimum, this.chartWidth()) })
                  .fill(toneEdge(this.t(), node.style, this.t().primary))
                  .stroke(Color.Transparent)
                Path({ commands: this.sparklineDotCommands(node.series2, node.maximum, node.minimum, this.chartWidth()) })
                  .fill(toneEdge(this.t(), node.series2Style, this.t().primary))
                  .stroke(Color.Transparent)
              } else {
                // The same line, closed down to the bottom edge and filled with
                // the tone's soft background -- this is why it reads as a chart
                // rather than a bare line, and unlike the plain 'path' branch
                // above, the fill traces exactly the points this shape itself
                // drew, not an open shape closed by accident.
                Path({ commands: this.sparklineAreaCommands(node.series, node.maximum, node.minimum, this.chartWidth()) })
                  .fill(toneFill(this.t(), node.style, this.t().primaryFill))
                  .fillOpacity(0.4)
                  .stroke(Color.Transparent)
                Path({ commands: this.sparklineCommands(node.series, node.maximum, node.minimum, this.chartWidth()) })
                  .fill(Color.Transparent)
                  .stroke(toneEdge(this.t(), node.style, this.t().primary))
                  .strokeWidth('3px')
                  .strokeLineCap(LineCapStyle.Round)
                  .strokeLineJoin(LineJoinStyle.Round)
                Path({ commands: this.sparklineDotCommands(node.series, node.maximum, node.minimum, this.chartWidth()) })
                  .fill(toneEdge(this.t(), node.style, this.t().primary))
                  .stroke(Color.Transparent)
              }
            }
            .layoutWeight(1)
            .height(VeraPreview.SPARKLINE_HEIGHT)
            // Measures this chart's own box, the way the whole page measures
            // its own for viewportWidth two screens up -- see chartWidth's own
            // comment on why this chart cannot just reuse that one.
            .onAreaChange((_old: Area, now: Area) => {
              let w = now.width as number
              if (Math.abs(w - this.sparklineWidth) >= 1) { this.sparklineWidth = w }
            })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }
        if (node.series2.length > 0 && (node.seriesLabel.length > 0 || node.series2Label.length > 0)) {
          Row({ space: this.t().gapBase }) {
            if (node.seriesLabel.length > 0) {
              this.sparklineLegendEntry(node.seriesLabel, toneEdge(this.t(), node.style, this.t().primary))
            }
            if (node.series2Label.length > 0) {
              this.sparklineLegendEntry(node.series2Label, toneEdge(this.t(), node.series2Style, this.t().primary))
            }
          }
          .width('100%')
        }
        if (node.categories.length > 0 && !node.bars) {
          // One caption per point, each in the same equal slot its point is drawn in, so it stands under it.
          Row() {
            ForEach(this.sparklineLabels(node), (label: string, _index: number) => {
              Column() {
                Text(label).fontSize(this.t().sizeCaption).fontFamily(this.textFamily())
                  .fontColor(this.t().inkSoft).maxLines(1).textAlign(TextAlign.Center)
                  .width(VeraPreview.SPARKLINE_LABEL_BOX)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Center)
            }, (label: string, index: number) => index.toString() + ':' + label)
          }
          .width('100%')
          .padding({ left: this.sparklineAxisWidth + this.t().gapTight })
        }
      }
      .width('100%')
      .padding({ top: this.t().gapTight, bottom: this.t().gapTight })
    } else if (node.kind === 'surface') {
      // The program paints this itself, frame by frame (paintSurface); the tree only gives it a box.
      Canvas(this.surfaceBox(node).ctx)
        .width('100%')
        .height(this.surfaceHeight(node))
        .onReady(() => {
          this.surfaceBox(node).ready = true
          this.paintSurface(node)
        })
        .onAreaChange((_old: Area, now: Area) => { this.surfaceArea(node, now) })
        .onVisibleAreaChange([0.0, 0.01], (visible: boolean, ratio: number) => {
          let box = this.surfaceBox(node)
          box.visible = visible && ratio > 0
          if (box.visible) { this.paintSurface(node) }
        })
        .onTouch((event: TouchEvent) => { this.surfaceTouch(node, event) })
        // A drag on a surface that takes fingers is the program's, not the page's: without a pan gesture of its
        // own the screen around it scrolls under the finger. One that takes none lets the page scroll through it.
        .gesture(PanGesture({ distance: 1 }))
        .onGestureJudgeBegin((_info: GestureInfo, _event: BaseGestureEvent) => {
          return node.value.length > 0 ? GestureJudgeResult.CONTINUE : GestureJudgeResult.REJECT
        })
    } else if (node.kind === 'world') {
      // The program describes this world (reconcileWorlds) and its box moves it; the tree only gives it a place.
      if (this.worldOptions(node) !== null) {
        Stack({ alignContent: Alignment.TopStart }) {
          // What is behind the world, under the scene: the sky, its stars, the trails and the halos of glowing bodies
          // (WorldBox.paintBackdrop), which the scene, see-through then, lets through round its bodies. Empty otherwise.
          Canvas(this.drawnWorld(node).backdrop)
            .width('100%')
            .height('100%')
            .hitTestBehavior(HitTestMode.Transparent)
            .onReady(this.worldBackdropReady(this.drawnWorld(node)))
          Component3D(this.worldOptions(node) as SceneOptions)
            .width('100%')
            .height('100%')
            // The box drawn, not the node's box when the callback runs: a retired box has left the map by then.
            .onAppear(this.worldShown(this.drawnWorld(node), true))
            .onDisAppear(this.worldShown(this.drawnWorld(node), false))
            .onAreaChange((_old: Area, now: Area) => { this.worldArea(node, now) })
            .onTouch((event: TouchEvent) => { this.worldTouch(node, event) })
            // A drag that turns the camera, or flicks a body, is the world's, not the page's; otherwise the page scrolls through it.
            .gesture(PanGesture({ distance: 1 }))
            .onGestureJudgeBegin((_info: GestureInfo, _event: BaseGestureEvent) => {
              let box = this.worlds.get(node)
              return box !== undefined && (box.orbits() || (node.action.length > 0 && box.holdsDrag()))
                ? GestureJudgeResult.CONTINUE : GestureJudgeResult.REJECT
            })
          if (this.drawnWorld(node).note.length > 0) {
            // Not an error: the world is shown, it just does not move (a build without physics).
            Text(this.drawnWorld(node).note)
              .fontSize(12)
              .fontColor(this.t().inkSoft)
              .padding(8)
              .hitTestBehavior(HitTestMode.Transparent)
          }
          if (!this.embedded && !this.previewOnly) {
            this.worldFullButton(node)
          }
          if (!this.previewOnly && this.drawnWorld(node).hasPlayer) {
            this.worldStick(node)
          }
        }
        .width('100%')
        .height(this.worldHeight(node))
      } else {
        Column()
          .width('100%')
          .height(this.worldHeight(node))
          .backgroundColor(this.t().background)
          .onAreaChange((_old: Area, now: Area) => { this.worldArea(node, now) })
      }
    } else if (node.kind === 'canvas') {
      Column() {
        Row()
          .width('100%')
          .height(0)
          .onAreaChange((_old: Area, now: Area) => {
            let w = now.width as number
            if (Math.abs(w - this.canvasWidth) >= 1) { this.canvasWidth = w }
          })
        Stack({ alignContent: Alignment.TopStart }) {
          this.renderChildren(node)
        }
        .scale({ x: this.getUIContext().vp2px(this.canvasSide(node.style)) / 100, y: this.getUIContext().vp2px(this.canvasSide(node.style)) / 100,
                 centerX: 0, centerY: 0 })
      }
      .width('100%')
      .height(this.canvasSide(node.style))
      .alignItems(HorizontalAlign.Start)
    } else if (node.kind === 'path' && parentKind === 'canvas') {
      // Bare: no wrapper, no centring, no scale of its own. Those are right for
      // a lone shape and fatal for a composition -- centring throws away the
      // position the shape was given, and a per-shape scale throws away its size
      // relative to its neighbours.
      Path({ commands: node.commands })
        .fill(pathFill(this.t(), node.style))
        .rotate({ angle: node.spinPeriodMs > 0 ? this.spin.angle : 0 })
    } else if (node.kind === 'path') {
      Column() {
        // Drawn inline rather than through a child component. Passing a @Trace
        // field of the live tree into a custom component's constructor makes
        // that component silently fail to construct -- measured on device: the
        // same component built from constants renders, built from node fields it
        // never appears. That is the V1/V2 boundary, and the way past it is not
        // to cross it.
        //
        // No width or height on the Path: given a size it draws its commands at
        // their own units from the top-left of a larger box, and .rotate() then
        // swings the shape around a point outside itself, so it orbits instead
        // of spinning.
        Path({ commands: node.commands })
          .fill(pathFill(this.t(), node.style))
          .rotate({ angle: node.spinPeriodMs > 0 ? this.spin.angle : 0 })
          .scale({ x: this.getUIContext().vp2px(PATH_BAND_HEIGHT) / 100, y: this.getUIContext().vp2px(PATH_BAND_HEIGHT) / 100 })
      }
      .width('100%')
      .height(PATH_BAND_HEIGHT)
      .alignItems(HorizontalAlign.Center)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        // A shape given an action is tappable like a button (the home-screen widget's drum).
        if (node.action.length > 0 && node.enabled) { this.handleAction(node.action, node.eventValue) }
      })
    } else if (node.kind === 'image') {
      // std/ui has declared Image since the first version, but there was no
      // branch here, so every generated program that used one painted nothing
      // and still reported success.
      if (node.source.length > 0) {
        Image(node.source)
          .width('100%')
          .height(180)
          .objectFit(ImageFit.Contain)
          .borderRadius(this.t().radiusControl)
          .accessibilityText(node.alt)
      } else {
        Text(node.alt.length > 0 ? node.alt : 'image')
          .fontSize(this.t().sizeCaption + 1)
          .fontFamily(this.textFamily())
          .fontColor(this.t().inkMuted)
          .width('100%')
          .height(180)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.t().surface)
          .borderRadius(this.t().radiusControl)
      }
    } else {
      // A kind the decoder produced but no branch above renders. Saying so is
      // worth more than a blank: a silent gap looks like a model failure.
      Text('unrendered component: ' + node.kind)
        .fontSize(this.t().sizeCaption)
        .fontFamily(this.textFamily())
        .fontColor(this.t().dangerInk)
        .width('100%')
        .padding(this.t().gapBase)
        .backgroundColor(this.t().dangerFill)
        .borderRadius(this.t().radiusSmall)
    }
  }
}
