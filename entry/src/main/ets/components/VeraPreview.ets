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

import { VirtualMachine, deserializeVbc2, RuntimeValue, VeraNumberValue, VeraStringValue,
  VeraBooleanValue, encodeRuntimeValue, decodeRuntimeValue } from '../vera/VeraInterpreter'
import { UiHostEnvironment, HostEffect, VeraUiNode, decodeVeraUi, formatVeraNumber, formatVeraClock, formatVeraDate, unitAfter, keepUnits } from '../vera/VeraUi'
import { veraStateStamp } from '../vera/VeraStateStamp'
import { scheduleCardRefresh } from '../vera/FormUpdater'
import { runRawIntent } from '../vera/VeraIntents'
import { runSdkAdapter } from '../vera/VeraSdkBackend'
import { LengthMetrics, mediaquery, matrix4 } from '@kit.ArkUI'

import { catalogKinds } from '../vera/VeraUiCatalog'
import { iconPath, ICON_STROKE, ICON_VIEWPORT, ICON_ORIGIN } from '../vera/VeraIcons'
import { ResolvedTheme, resolveTheme, containerFill, toneFill, toneEdge, toneInk,
  textSize, textWeight, textInk, buttonFill, buttonInk, pathFill, densityPad,
  densityGap, spacerSize, readableInk } from '../vera/VeraTheme'
import { store } from '../vera/ProjectStore'
import { consent } from '../vera/VeraConsentStore'
import { LiveNode, toLive, reconcile, armReveal } from './VeraLiveTree'
import { carryState } from '../vera/VeraStateCarry'
import { MotionPose, motionPose, motionDuration, poseMatrix, poseFromArray, multiplyMatrices, identityMatrix, perspectiveMatrix,
  columnMajor, poseToPixels, facesViewer, samePose, animatedPose, stageDistance, faceShade, depthRanks } from '../vera/VeraMotion'
import { displaySync } from '@kit.ArkGraphics2D'
import { decodeGfx, paintGfx, pointerValue, gfxFit, gfxToSurface, gfxNaturalHeight } from '../vera/VeraGfx'

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

/** One drawn layer of a scene: the node whose children are its content, and what the pose made of it this frame. */
class SceneLayer {
  node: LiveNode
  side: number = 0
  shade: number = 1
  depth: number = 0
  rank: number = 0
  matrix: number[]
  opacity: number
  visible: boolean
  constructor(node: LiveNode, matrix: number[], opacity: number, visible: boolean) {
    this.node = node; this.matrix = matrix; this.opacity = opacity; this.visible = visible
  }
}

class SceneFrame {
  at: number = -1
  layers: SceneLayer[] = []
}

class TimerConfig {
  interval: number
  action: string
  constructor(interval: number, action: string) {
    this.interval = interval
    this.action = action
  }
}

/** How often a running surface re-runs view() for what is drawn around it, in ms: a score in a header, not the scene. */
const SURFACE_VIEW_MS: number = 100
/** How often a running surface's state is saved, in ms. Every frame would write the project sixty times a second. */
const SURFACE_SAVE_MS: number = 5000
/** The longest a frame says has passed, in ms, so a pause -- the app in the background, a slow frame -- is not a leap. */
const SURFACE_MAX_ELAPSED_MS: number = 100

/** One ui.Surface on screen: the canvas it paints into and the box it was given, in vp. */
class SurfaceBox {
  ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true))
  ready: boolean = false
  width: number = 0
  height: number = 0
  // Some of it is on screen. One scrolled away keeps its frame handler running but is neither drawn nor painted.
  visible: boolean = true
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

@Component
export struct VeraPreview {
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
    if (this.previewOnly || this.vm === null) { return }
    // The saved state is taken only when another process -- a home-screen card -- changed it while the app was away. Else
    // the state in memory stays: it may hold what could not be saved, or an answer that arrived around the resume.
    let keys = this.stateKeys()
    if (keys.length > 0 && store.loadState(keys[0], keys[1], this.stamp()) !== this.diskState) {
      let restored = this.restoreState()
      if (restored !== null) { this.currentState = restored }
    }
    this.renderView()
    this.runWidgetRefresh()
  }

  /** The saved state as this app last read or wrote it: a different one on disk was written by someone else. */
  private diskState: string = ''

  /** The program declares widgetRefresh(state): what its card runs on each update, run by the app too. */
  private refreshes: boolean = false

  /**
   * The program's widgetRefresh, when it has one, as the card runs it: the state brought up to date with the clock when
   * the program starts and when the app comes back, so the app opened in the morning shows today's figures whether or not
   * a card has been updated since -- or is on the home screen at all. Run as a handler is, its phone effects (a live
   * source's fetch) afterwards; one that traps leaves the state as it was.
   */
  private runWidgetRefresh(): void {
    if (!this.refreshes || this.disposed || this.previewOnly || this.vm === null || this.currentState === null) { return }
    try {
      if (this.host !== null) { this.host!.effectsAllowed = true }
      this.currentState = this.vm!.execute('widgetRefresh', [this.currentState!])
      if (this.host !== null) { this.host!.effectsAllowed = false }
      this.notifyStateSnapshot()
      this.renderView()
      this.persistState()
      this.drainEffects()
    } catch (e) {
      if (this.host !== null) {
        this.host!.effectsAllowed = false
        this.host!.pendingEffects = []
      }
      console.warn('VERA-REFRESH widgetRefresh failed: ' + (e as Error).message)
    }
  }
  /** Read-only snapshot for a hosting chat. It does not migrate state between programs. */
  onStateSnapshot: (encoded: string) => void = (_encoded: string): void => {}
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
  private liveRoot: LiveNode | null = null
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
  private vm: VirtualMachine | null = null
  private host: UiHostEnvironment | null = null
  /** The program's own scroll (not in a chat, where the chat scrolls) and where it sits, in vp, for revealIfAsked. */
  private rootScroller: Scroller = new Scroller()
  private rootTop: number = 0
  private rootHeight: number = 0
  /** How tall the snackbars drawn over the bottom of the window are, in vp: the content ends that far above it (programFrame). */
  @State snackSpace: number = 0
  private currentState: RuntimeValue | null = null
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
  private ticking: boolean = false
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
  @State pending: HostEffect | null = null
  private heldEffects: HostEffect[] = []
  private spinTimer: number = -1
  private motionClock: MotionClock = new MotionClock()
  private motionTimer: number = -1
  /** The trigger each Motion had when last seen, by its place in the tree; a change starts its animation. */
  private motionTriggers: Map<string, number> = new Map<string, number>()
  private poseAnims: Map<LiveNode, PoseAnim> = new Map<LiveNode, PoseAnim>()
  private sceneFrames: Map<LiveNode, SceneFrame> = new Map<LiveNode, SceneFrame>()
  private spinPeriod: number = 0
  /**
   * The program's ui.Surfaces: each one's canvas by its node (reconcile keeps a node while it stays a surface),
   * the ones in the frame now, in tree order, and the frame loop that drives the ones with a frame handler.
   *
   * A surface does not go through view() and reconcile on every frame. Its frame handler moves the state, its
   * draw function turns the state into shapes, and the shapes go straight to its canvas; the tree around it is
   * brought up to date every SURFACE_VIEW_MS, which is plenty for a score and nothing like sixty times a second.
   */
  private surfaces: Map<LiveNode, SurfaceBox> = new Map<LiveNode, SurfaceBox>()
  private liveSurfaces: LiveNode[] = []
  private surfaceSync: displaySync.DisplaySync | null = null
  private surfaceTimer: number = -1
  private lastFrameAt: number = 0
  private lastViewAt: number = 0
  private lastSurfaceSave: number = 0
  private framing: boolean = false
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
    'timeline', 'timelineitem', 'skeleton', 'spinner', 'snackbar', 'sparkline', 'backhandler',
    'table', 'tablerow', 'motion', 'transform', 'stage', 'surface']

  aboutToAppear(): void {
    this.disposed = false
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
  }

  onProgramChanged(): void {
    this.load()
  }

  /** Start or stop the tickers the current frame asks for, and report the state a preview held back. */
  onPreviewOnlyChanged(): void {
    this.notifyStateSnapshot()
    this.renderView()
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
        this.renderView()
      })
      this.darkListener = listener
    } catch (e) {
      this.dark = false
      console.info('VERA-RENDER dark mode unavailable: ' + (e as Error).message)
    }
  }

  private invalidateEffects(): void {
    this.effectGeneration += 1
    this.heldEffects = []
    this.pending = null
    if (this.host !== null) { this.host!.pendingEffects = [] }
  }

  private load(): void {
    this.invalidateEffects()
    // A preview follows a screen being made: each program it is handed is the same screen a little further on, so its tree
    // is reconciled into the one already drawn. Replacing it rebuilt the whole screen for every piece of the plan, and
    // the screen flickered while it grew.
    let keep = this.previewOnly && this.liveRoot !== null && this.vbc2.length > 0
    this.stopAllTimers()
    this.vm = null
    this.host = null
    this.currentState = null
    if (!keep) {
      this.liveRoot = null
      this.hasRoot = false
      this.programId += 1
    }
    this.error = ''
    if (this.vbc2.length === 0) { return }
    try {
      this.host = new UiHostEnvironment()
      let module = deserializeVbc2(this.vbc2)
      this.vm = new VirtualMachine(module, this.host)
      this.refreshes = module.functions.some((fn): boolean => fn.name === 'widgetRefresh')
      this.currentState = this.restoreState()
      if (this.currentState === null) { this.currentState = this.seeded(this.vm!.execute('init')) }
      this.notifyStateSnapshot()
      this.renderView()
      this.runWidgetRefresh()
    } catch (e) {
      this.error = 'Init error: ' + (e as Error).message
    }
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
    this.sceneFrames.clear()
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
   * Every layer of a scene this frame, flat. A Transform's matrix is composed with its parents' here, in code, and each layer
   * is then drawn as a sibling with its final matrix: ArkUI is asked for one transform per layer and never has to compose
   * nested 3D ones. Cached by clock value, because every attribute of every layer asks for it.
   */
  private sceneFrame(root: LiveNode): SceneFrame {
    let now = this.motionClock.now
    let cached = this.sceneFrames.get(root)
    if (cached !== undefined && cached.at === now) { return cached }
    let frame = new SceneFrame()
    frame.at = now
    let density = this.getUIContext().vp2px(1)
    let distance = stageDistance(root.kind === 'stage' ? root.numberValue : 0) * density
    if (root.kind === 'stage') {
      for (let child of root.children) {
        if (child.kind === 'transform') { this.collectLayers(child, identityMatrix(), 1, distance, density, now, frame) }
      }
    } else {
      this.collectLayers(root, identityMatrix(), 1, distance, density, now, frame)
    }
    let depths: number[] = []
    for (let layer of frame.layers) { depths.push(layer.depth) }
    let ranks = depthRanks(depths)
    for (let i = 0; i < frame.layers.length; i++) { frame.layers[i].rank = ranks[i] }
    this.sceneFrames.set(root, frame)
    return frame
  }

  private collectLayers(node: LiveNode, parent: number[], opacity: number, distance: number, density: number, now: number,
      frame: SceneFrame): void {
    let pose = poseToPixels(this.shownPose(node, now), density)
    let composed = multiplyMatrices(parent, poseMatrix(pose))
    let alpha = opacity * pose[7]
    let hasContent = false
    for (let child of node.children) { if (child.kind !== 'transform') { hasContent = true } }
    if (hasContent) {
      let visible = node.style !== 'solid' || facesViewer(composed, distance)
      let layer = new SceneLayer(node, multiplyMatrices(perspectiveMatrix(distance), composed), alpha, visible)
      layer.side = node.minimum
      layer.depth = composed[11]
      if (node.style === 'solid') { layer.shade = faceShade(composed) }
      frame.layers.push(layer)
    }
    for (let child of node.children) {
      if (child.kind === 'transform') { this.collectLayers(child, composed, alpha, distance, density, now, frame) }
    }
  }

  private layerAt(root: LiveNode, index: number): SceneLayer | null {
    let frame = this.sceneFrame(root)
    return index < frame.layers.length ? frame.layers[index] : null
  }

  private layerOpacity(root: LiveNode, index: number): number {
    let layer = this.layerAt(root, index)
    return layer !== null ? layer!.opacity : 0
  }

  private layerRank(root: LiveNode, index: number): number {
    let layer = this.layerAt(root, index)
    return layer !== null ? layer!.rank : 0
  }

  private layerSide(root: LiveNode, index: number): number {
    let layer = this.layerAt(root, index)
    return layer !== null ? layer!.side : 0
  }

  private layerShade(root: LiveNode, index: number): number {
    let layer = this.layerAt(root, index)
    return layer !== null ? layer!.shade : 1
  }

  private layerVisible(root: LiveNode, index: number): boolean {
    let layer = this.layerAt(root, index)
    return layer !== null && layer!.visible
  }

  private layerTransform(root: LiveNode, index: number): Object {
    let layer = this.layerAt(root, index)
    let m = columnMajor(layer !== null ? layer!.matrix : identityMatrix())
    return matrix4.init([m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12], m[13], m[14], m[15]])
  }

  /** The ids of a scene's layers, in order: when the set of layers changes the drawn layers are rebuilt. */
  private layerKeys(root: LiveNode): string[] {
    let keys: string[] = []
    let frame = this.sceneFrame(root)
    for (let i = 0; i < frame.layers.length; i++) { keys.push(i.toString() + ':' + frame.layers[i].node.children.length.toString()) }
    return keys
  }

  private layerNode(root: LiveNode, index: number): LiveNode {
    let layer = this.layerAt(root, index)
    return layer !== null ? layer!.node : root
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
      this.dispatch(this.backHandlerAction, new VeraNumberValue(0))
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
      if (this.ticking || this.appForeground === false) { return }
      let current = this.timerConfigs.get(id)
      if (current === undefined) { return }
      let last = this.timerLastFire.get(id)
      let now = Date.now()
      let elapsed = last !== undefined ? now - (last as number) : safe
      this.timerLastFire.set(id, now)
      this.ticking = true
      this.dispatch(current.action, new VeraNumberValue(Math.round(elapsed)))
      this.ticking = false
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

  private stopAllTimers(): void {
    this.stopSurfaceLoop()
    for (let id of Array.from(this.timers.keys())) { this.stopTimer(id) }
    if (this.spinTimer >= 0) { clearInterval(this.spinTimer); this.spinTimer = -1 }
    this.spinPeriod = 0
    if (this.motionTimer >= 0) { clearInterval(this.motionTimer); this.motionTimer = -1 }
    this.motionTriggers.clear()
    this.poseAnims.clear()
    this.sceneFrames.clear()
  }

  aboutToDisappear(): void {
    // Without this the tickers -- and the VM they drive -- outlive the screen.
    this.disposed = true
    this.invalidateEffects()
    this.stopAllTimers()
    // A running surface saves every few seconds; the frames since the last save would otherwise be lost.
    if (this.liveSurfaces.length > 0 && !this.previewOnly) { this.persistState() }
    // The same applies to the dark-mode listener: it holds this component, and
    // its callback re-enters the VM.
    if (this.darkListener !== null) {
      try {
        this.darkListener!.off('change')
      } catch (e) {
        console.info('VERA-RENDER dark listener off failed: ' + (e as Error).message)
      }
      this.darkListener = null
    }
  }

  private stateKeys(): string[] {
    let slash = this.persistKey.indexOf('/')
    if (this.persistKey.length === 0 || slash <= 0) { return [] }
    return [this.persistKey.substring(0, slash), this.persistKey.substring(slash + 1)]
  }

  /** The bytecode itself is the stamp: a refined program gets a different one. */
  private stamp(): string {
    return veraStateStamp(this.vbc2)
  }

  /** `fresh` with what seedState held carried into it, or `fresh` itself when there is none or the program cannot draw it. */
  private seeded(fresh: RuntimeValue): RuntimeValue {
    if (this.seedState.length === 0 || this.previewOnly) { return fresh }
    try {
      let carried = carryState(fresh, decodeRuntimeValue(JSON.parse(this.seedState) as Object), this.vm!.classShapes())
      if (this.host !== null) { this.host!.effectsAllowed = false }
      // An entry of an old class may lack a field the new code reads: a view that fails on it means starting clean.
      this.vm!.execute('view', [carried])
      console.info('VERA-STATE carried into the refined program')
      return carried
    } catch (e) {
      console.warn('VERA-STATE could not carry the old state, starting clean: ' + (e as Error).message)
      return fresh
    }
  }

  private restoreState(): RuntimeValue | null {
    let keys = this.stateKeys()
    if (keys.length === 0 || this.previewOnly) { return null }
    let encoded = store.loadState(keys[0], keys[1], this.stamp())
    this.diskState = encoded
    if (encoded.length === 0) { return null }
    try {
      return decodeRuntimeValue(JSON.parse(encoded) as Object)
    } catch (e) {
      console.error('VERA-STATE restore failed, starting clean: ' + (e as Error).message)
      return null
    }
  }

  private notifyStateSnapshot(): void {
    if (this.currentState === null || this.previewOnly) { return }
    try {
      this.onStateSnapshot(JSON.stringify(encodeRuntimeValue(this.currentState!)))
    } catch (e) {
      console.warn('VERA-STATE snapshot unavailable: ' + (e as Error).message)
    }
  }

  private persistState(): void {
    let keys = this.stateKeys()
    if (keys.length === 0 || this.currentState === null) { return }
    try {
      let encoded = JSON.stringify(encodeRuntimeValue(this.currentState!))
      store.saveState(keys[0], keys[1], this.stamp(), encoded)
      this.diskState = encoded
      scheduleCardRefresh(keys[0])
    } catch (e) {
      // A program holding something unsaveable should still run; it just will
      // not remember. Saying so beats a silent half-working save.
      console.error('VERA-STATE save failed: ' + (e as Error).message)
    }
  }

  private renderView(paint: boolean = true): void {
    if (this.vm === null || this.currentState === null) { return }
    this.lastViewAt = Date.now()
    try {
      // view is re-run on every change, so an intent call from there would
      // start navigation on every repaint. The host refuses one while this is
      // false; only dispatch lifts it, and only around the handler itself.
      if (this.host !== null) { this.host!.effectsAllowed = false }
      let viewTree = this.vm!.execute('view', [this.currentState!])
      let nodes = decodeVeraUi(viewTree)
      let root = nodes.length > 0 ? nodes[0] : null
      // Not for the refreshes a running surface makes ten times a second: they would bury every other line.
      if (paint) {
        console.info('VERA-VIEW rev=' + (this.revision + 1).toString() +
          ' root=' + (root !== null ? root!.kind : 'null') +
          ' children=' + (root !== null ? root!.children.length.toString() : '0'))
      }
      this.reconcileTheme(root)
      if (root === null) {
        this.liveRoot = null
        this.hasRoot = false
      } else if (this.liveRoot === null) {
        this.liveRoot = toLive(root!)
        this.hasRoot = true
      } else {
        reconcile(this.liveRoot!, root!)
      }
      this.revision += 1
      this.reconcileTimers(this.previewOnly ? null : root)
      this.reconcileSpin(root)
      this.reconcileMotion()
      this.reconcileBackHandler(root)
      this.reconcileSurfaces(paint)
    } catch (e) {
      this.error = 'View error: ' + (e as Error).message
    }
  }

  /**
   * Bring the surfaces in line with the frame just reconciled: forget the canvases of nodes that are no longer
   * surfaces, run the frame loop exactly while one of them has a frame handler, and paint them all now unless the
   * frame loop is the one asking (it paints straight after).
   */
  private reconcileSurfaces(paint: boolean): void {
    let found: LiveNode[] = []
    if (this.liveRoot !== null) { this.collectSurfaces(this.liveRoot!, found) }
    for (let node of Array.from(this.surfaces.keys())) {
      if (found.indexOf(node) < 0) { this.surfaces.delete(node) }
    }
    this.liveSurfaces = found
    let animated = false
    for (let node of found) { if (node.action.length > 0) { animated = true } }
    if (animated && !this.previewOnly && !this.pageHidden && this.error.length === 0) { this.startSurfaceLoop() } else { this.stopSurfaceLoop() }
    if (paint) { this.paintSurfaces() }
  }

  private collectSurfaces(node: LiveNode, found: LiveNode[]): void {
    if (node.kind === 'surface') { found.push(node) }
    for (let child of node.children) { this.collectSurfaces(child, found) }
  }

  /**
   * Frames at the display's own rate. displaySync is the vsync of this window; an interval is the fallback for a
   * system that refuses one, and is near enough for a game that measures elapsed time rather than counting frames.
   */
  private startSurfaceLoop(): void {
    if (this.surfaceSync !== null || this.surfaceTimer >= 0) { return }
    this.lastFrameAt = 0
    this.lastSurfaceSave = Date.now()
    console.info('VERA-SURFACE loop start')
    this.frameReportAt = 0
    this.frameCount = 0
    this.frameWork = 0
    this.frameWorst = 0
    this.frameSplit = [0, 0, 0, 0]
    try {
      let sync = displaySync.create()
      let range: ExpectedFrameRateRange = { expected: 60, min: 30, max: 120 }
      sync.setExpectedFrameRateRange(range)
      sync.on('frame', (_info: displaySync.IntervalInfo) => { this.surfaceFrame() })
      sync.start()
      this.surfaceSync = sync
    } catch (e) {
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
        console.warn('VERA-SURFACE stopping display sync failed: ' + (e as Error).message)
      }
      this.surfaceSync = null
    }
    if (this.surfaceTimer >= 0) { clearInterval(this.surfaceTimer); this.surfaceTimer = -1 }
  }

  /**
   * One frame: every surface's frame handler is told how long it has been, then every surface is painted. Effects
   * stay off -- a frame is not a person asking for something -- and a trap stops the loop and says so, as a ticker's
   * does, rather than trapping again sixty times a second.
   */
  private surfaceFrame(): void {
    if (this.disposed || this.pageHidden || this.framing || this.vm === null || this.currentState === null) { return }
    let now = Date.now()
    let elapsed = this.lastFrameAt > 0 ? Math.min(SURFACE_MAX_ELAPSED_MS, Math.max(0, now - this.lastFrameAt)) : 16
    this.lastFrameAt = now
    this.framing = true
    try {
      // A frame handler is a handler, as a ticker's is: it may ask the phone for something when its time comes (a
      // vibration on each breath, a sound when the ball lands). Drawing may not.
      if (this.host !== null) { this.host!.effectsAllowed = true }
      for (let node of this.liveSurfaces) {
        if (node.action.length === 0) { continue }
        this.currentState = this.vm!.execute(node.action, [this.currentState!, new VeraNumberValue(elapsed)])
      }
      if (this.host !== null) { this.host!.effectsAllowed = false }
      this.drainEffects()
      this.frameSplit[0] += Date.now() - now
      this.paintSurfaces()
      if (now - this.lastViewAt >= SURFACE_VIEW_MS) {
        let viewAt = Date.now()
        this.renderView(false)
        this.frameSplit[3] += Date.now() - viewAt
      }
      this.countFrame(now, Date.now() - now)
      if (now - this.lastSurfaceSave >= SURFACE_SAVE_MS) {
        this.lastSurfaceSave = now
        this.persistState()
        this.notifyStateSnapshot()
      }
    } catch (e) {
      if (this.host !== null) {
        this.host!.effectsAllowed = false
        // What a frame that trapped half-way asked for is not done, as for a handler that traps.
        this.host!.pendingEffects = []
      }
      console.error('VERA-SURFACE frame TRAP err=' + (e as Error).message)
      this.error = 'Frame error: ' + (e as Error).message
      this.stopAllTimers()
    } finally {
      this.framing = false
    }
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

  private paintSurfaces(): void {
    for (let node of this.liveSurfaces) { this.paintSurface(node) }
  }

  /** Ask the program what this surface shows now and paint it; nothing until its canvas is ready and has a size. */
  private paintSurface(node: LiveNode): void {
    let box = this.surfaces.get(node)
    if (box === undefined || !box.ready || !box.visible || box.width <= 0 || box.height <= 0) { return }
    if (this.vm === null || this.currentState === null || node.label.length === 0) { return }
    try {
      if (this.host !== null) { this.host!.effectsAllowed = false }
      let drawAt = Date.now()
      let ops = decodeGfx(this.vm!.execute(node.label, [this.currentState!]))
      let paintAt = Date.now()
      paintGfx(box.ctx, ops, this.t(), box.width, box.height, node.minimum, node.maximum, this.getUIContext().vp2px(1))
      this.frameSplit[1] += paintAt - drawAt
      this.frameSplit[2] += Date.now() - paintAt
    } catch (e) {
      console.error('VERA-SURFACE draw TRAP err=' + (e as Error).message)
      this.error = 'Draw error: ' + (e as Error).message
      this.stopAllTimers()
    }
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
    if (node.style === 'fill' && !this.embedded && node.layoutHeight > 0) { return node.layoutHeight }
    return natural > 0 ? natural : width
  }

  private surfaceArea(node: LiveNode, now: Area): void {
    let box = this.surfaceBox(node)
    box.width = Number(now.width)
    box.height = Number(now.height)
    if (node.style === 'fill' && !this.embedded && this.rootHeight > 0) {
      let want = Math.max(160, this.rootTop + this.rootHeight - this.snackSpace - Number(now.globalPosition.y))
      // A whole vp, for the same reason viewportWidth is guarded: a re-layout a fraction different would write again.
      if (Math.abs(want - node.layoutHeight) >= 1) { node.layoutHeight = want }
    }
    this.paintSurface(node)
  }

  /**
   * Fingers on a surface, in its own units. Down, up and cancel are taps and go the way every tap goes -- the
   * handler, then the tree, saved, effects run. A move is a stream of them, so it only runs the handler and
   * repaints; the tree catches up on the frame loop's schedule, and the state is saved when the finger lifts.
   */
  private surfaceTouch(node: LiveNode, event: TouchEvent): void {
    if (node.value.length === 0 || this.previewOnly) { return }
    let box = this.surfaces.get(node)
    if (box === undefined || box.width <= 0 || box.height <= 0) { return }
    let fit = gfxFit(box.width, box.height, node.minimum, node.maximum)
    let phase = event.type === TouchType.Down ? 'down' : event.type === TouchType.Move ? 'move'
      : event.type === TouchType.Up ? 'up' : 'cancel'
    for (let touch of event.changedTouches) {
      let at = gfxToSurface(fit, touch.x, touch.y)
      let value = pointerValue(phase, touch.id, at[0], at[1])
      if (phase === 'move') { this.surfaceMove(node.value, value) } else { this.dispatch(node.value, value) }
    }
  }

  private surfaceMove(action: string, value: RuntimeValue): void {
    if (this.vm === null || this.currentState === null) { return }
    try {
      // A finger moving is the person's input, as its down and up are.
      if (this.host !== null) { this.host!.effectsAllowed = true }
      this.currentState = this.vm!.execute(action, [this.currentState!, value])
      if (this.host !== null) { this.host!.effectsAllowed = false }
      this.drainEffects()
      // The frame loop paints and refreshes the tree itself; without one, this move is the frame.
      if (this.surfaceSync === null && this.surfaceTimer < 0) {
        this.paintSurfaces()
        if (Date.now() - this.lastViewAt >= SURFACE_VIEW_MS) { this.renderView(false) }
      }
    } catch (e) {
      if (this.host !== null) {
        this.host!.effectsAllowed = false
        this.host!.pendingEffects = []
      }
      console.error('VERA-SURFACE ' + action + ' TRAP err=' + (e as Error).message)
      this.error = 'Action error: ' + (e as Error).message
      this.stopAllTimers()
    }
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

  private handleAction(action: string, value: number): void {
    this.dispatch(action, new VeraNumberValue(value))
  }

  private handleStringAction(action: string, value: string): void {
    this.dispatch(action, new VeraStringValue(value))
  }

  private handleBoolAction(action: string, value: boolean): void {
    this.dispatch(action, new VeraBooleanValue(value))
  }

  /**
   * The single way a person's input reaches a program: the value is whatever
   * the component produces -- a number, a string or a boolean.
   */
  private dispatch(action: string, payload: RuntimeValue, persist: boolean = true): void {
    if (this.disposed) { return }
    console.info('VERA-CLICK action=' + action + ' rev=' + this.revision.toString())
    if (this.vm === null || this.currentState === null || this.previewOnly) { return }
    let t0 = Date.now()
    try {
      if (this.host !== null) { this.host!.effectsAllowed = true }
      this.currentState = this.vm!.execute(action, [this.currentState!, payload])
      if (this.host !== null) { this.host!.effectsAllowed = false }
      this.notifyStateSnapshot()
      console.info('VERA-ACTION ' + action + ' steps=' + this.vm!.stepsExecuted().toString() +
        ' ms=' + (Date.now() - t0).toString())
      // What this tap makes appear -- a card it opens, a banner with its result -- is brought into view.
      armReveal(true)
      try { this.renderView() } finally { armReveal(false) }
      if (persist) { this.persistState() }
      this.drainEffects()
    } catch (e) {
      if (this.host !== null) {
        this.host!.effectsAllowed = false
        // A handler that trapped half-way may have queued an intent it would
        // never have reached. Asking the platform for it would act on a state
        // the program never committed to.
        this.host!.pendingEffects = []
      }
      console.error('VERA-ACTION ' + action + ' TRAP steps=' + this.vm!.stepsExecuted().toString() +
        ' ms=' + (Date.now() - t0).toString() + ' err=' + (e as Error).message)
      this.error = 'Action error: ' + (e as Error).message
      // A ticker whose handler traps would otherwise trap again every interval.
      this.stopAllTimers()
    }
  }

  /**
   * Runs the intents the handler asked for, and brings each answer back the way
   * every other event arrives -- as a dispatch to a named handler.
   *
   * The queue is taken and cleared first: delivering an answer runs a handler,
   * and that handler may queue intents of its own.
   *
   * A late answer to a screen that has gone is dropped rather than pushed into
   * a VM that is no longer running.
   */
  private drainEffects(): void {
    if (this.disposed || this.host === null) { return }
    let effects: HostEffect[] = this.host!.pendingEffects
    if (effects.length === 0) { return }
    this.host!.pendingEffects = []
    for (let effect of effects) { this.heldEffects.push(effect) }
    this.runQueued()
  }

  /**
   * Works through the queue until it is empty or something needs asking.
   *
   * One dialog at a time, and everything behind it waits: two dialogs at once
   * is a person clicking through whichever is on top, which is the failure this
   * whole mechanism exists to prevent.
   */
  private runQueued(): void {
    if (this.disposed) { return }
    while (this.heldEffects.length > 0) {
      if (this.pending !== null) { return }
      let effect = this.heldEffects.shift() as HostEffect
      console.info('VERA-EFFECT id=' + effect.id.toString() + ' ' + effect.kind + '.' + effect.fn +
        ' -> ' + effect.resultHandler)
      if (this.needsConsent(effect)) {
        console.info('VERA-CONSENT asking for ' + this.consentTitle(effect))
        this.pending = effect
        return
      }
      this.runEffect(effect)
    }
  }

  /**
   * Whether this call is shown to the person before it runs.
   *
   * Reading something, opening a page or launching an app is not worth
   * interrupting for -- the person asked for the app and can see what it did.
   * Anything that changes something is, and an intent the catalogue never
   * described always is: nobody has established what it does, so nobody can say
   * it is safe.
   */
  private needsConsent(effect: HostEffect): boolean {
    // Asking is off. Turn ASK_BEFORE_CALLS back on and every state-changing
    // call is shown to the person again -- the sheet,
    // the queue and the remembered grants are all still here and still work.
    //
    // What is lost while it is off is the only thing standing between a
    // generated program and an intent nobody has checked: the phone accepts
    // Pay and SendTextMessage as readily as OpenFlashlight, and the person
    // sees neither. The log keeps the record -- VERA-INTENT-RAW carries the
    // target and the payload of every call.
    if (!ASK_BEFORE_CALLS) { return false }
    // Nothing about an sdk.call is curated or risk-classified, so "ask every
    // time" is the only posture that makes sense until it is
    // (docs/selector-design.md).
    if (effect.kind !== 'sdk') { return false }
    // Already allowed, for this program and this call. The grant died with the
    // previous version of the program: stamp() is the bytecode.
    if (consent.has(this.stamp(), this.consentKey(effect))) { return false }
    return true
  }

  /** What a grant is about: the target address, as the program wrote it. */
  private consentKey(effect: HostEffect): string {
    return effect.rawTarget
  }

  /** What the dialog says this call is, in the person's words where there are any. */
  private consentTitle(effect: HostEffect): string {
    if (effect.kind === 'sdk') {
      // sdk.call's two target shapes (VeraCompiler.buildStdSdkModule):
      // slash-separated (an intent address) or dot-separated (an sdk entry).
      let sep = effect.rawTarget.indexOf('/') >= 0 ? '/' : '.'
      let parts = effect.rawTarget.split(sep)
      return 'Run ' + parts[parts.length - 1]
    }
    return 'Run ' + effect.rawTarget
  }

  /** The app the call goes to, by bundle name -- the one thing that is never in doubt. */
  private consentTarget(effect: HostEffect): string {
    return effect.rawTarget
  }

  /**
   * Every value that will be sent, after translation, one per line.
   *
   * After translation because that is what the phone will receive: showing the
   * program's own words would be showing something other than what happens.
   */
  private consentValues(effect: HostEffect): string {
    let lines: string[] = []
    effect.values.forEach((value: string, key: string) => { lines.push(key + ': ' + value) })
    return lines.length > 0 ? lines.join('\n') : '(no parameters)'
  }

  /** The person allowed it: run it, then carry on with whatever was behind it. */
  private allowPending(): void {
    if (this.disposed) { return }
    let effect = this.pending
    this.pending = null
    if (effect !== null) {
      console.info('VERA-CONSENT allowed ' + this.consentTarget(effect!))
      // Remembered, so the same program asking the same thing again is not a
      // question the person has to answer twice.
      consent.remember(this.stamp(), this.consentKey(effect!))
      this.runEffect(effect!)
    }
    this.runQueued()
  }

  /**
   * The person refused: the program is told so through its own handler.
   *
   * Told, rather than left waiting -- a program that asked to send something
   * and hears nothing back will show the person a screen that is quietly wrong.
   */
  private refusePending(): void {
    if (this.disposed) { return }
    let effect = this.pending
    this.pending = null
    if (effect !== null) {
      console.info('VERA-CONSENT refused ' + this.consentTarget(effect!))
      this.dispatch(effect!.resultHandler, new VeraStringValue('declined by the person'))
    }
    this.runQueued()
  }

  /** One effect, whichever host it belongs to, answered through its handler. */
  private runEffect(effect: HostEffect): void {
    if (this.disposed) { return }
    let generation = this.effectGeneration
    let answer: Promise<string>
    if (effect.kind === 'sdk' && effect.rawTarget.indexOf('/') >= 0) {
      // An intent-style target: it gets real dispatch through runRawIntent.
      answer = runRawIntent(effect.rawTarget, effect.values, effect.rawMode)
    } else if (effect.kind === 'sdk') {
      // An sdk-style target: a real, curated adapter (VeraSdkBackend.ets) if
      // one has been written for this exact target, the same honest stub as
      // before otherwise. Most of the closed set this compiles against has
      // no adapter yet -- that was never in scope for the selector work --
      // but a target that does have one now really calls interface_sdk-js.
      answer = runSdkAdapter(effect.rawTarget, effect.values)
    } else {
      answer = runSdkAdapter(effect.rawTarget, effect.values)
    }
    answer.then((text: string) => {
      if (this.disposed || generation !== this.effectGeneration) { return }
      this.dispatch(effect.resultHandler, new VeraStringValue(text))
    }).catch((e: Error) => {
      if (this.disposed || generation !== this.effectGeneration) { return }
      this.dispatch(effect.resultHandler, new VeraStringValue('error: ' + e.message))
    })
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
  consentSheet(effect: HostEffect) {
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
            }
            .width('100%')
            .height('100%')
            .onAreaChange((_old: Area, now: Area) => {
              this.rootTop = Number(now.globalPosition.y)
              this.rootHeight = Number(now.height)
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
              if (node.action.length > 0) { this.handleAction(node.action, node.eventValue) }
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
   * end of the row (rowButton), so a stop with a Navigate button is one line, not a line and a bar. A bar of two buttons stays below.
   */
  private rowChildren(node: LiveNode): LiveNode[] {
    let out: LiveNode[] = []
    let i = 0
    while (i < node.children.length) {
      let row = node.children[i]
      out.push(row)
      let next = i + 1 < node.children.length ? node.children[i + 1] : null
      if (row.kind === 'listitem' && next !== null && next.kind === 'actionbar' && next.children.length === 1 &&
          next.children[0].kind === 'button') {
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
      if (value !== node.numberValue) { this.handleAction(node.action, value) }
    }
    this.numberEpoch++
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
  private selectMenuItems(node: LiveNode): MenuElement[] {
    let items: MenuElement[] = []
    for (let i = 0; i < node.options.length; i++) {
      let index = i
      items.push({
        value: node.options[i],
        action: () => {
          if (node.action.length > 0) { this.handleAction(node.action, index) }
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
  private textFieldIssue(node: LiveNode): string {
    let v = node.value
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
    } else if (node.kind === 'stage' || (node.kind === 'transform' && parentKind !== 'stage' && parentKind !== 'transform')) {
      // A scene: every layer is a flat sibling in a centred stack with its own final matrix (see sceneFrame). A Transform
      // outside a Stage is a scene of one layer, with the default viewer distance.
      Stack() {
        ForEach(this.layerKeys(node), (key: string, index: number) => {
          Column() {
            this.renderChildren(this.layerNode(node, index))
          }
          .alignItems(HorizontalAlign.Center)
          .width(this.layerSide(node, index) > 0 ? this.layerSide(node, index) : undefined)
          .height(this.layerSide(node, index) > 0 ? this.layerSide(node, index) : undefined)
          .opacity(this.layerOpacity(node, index))
          .brightness(this.layerShade(node, index))
          .zIndex(this.layerRank(node, index))
          .visibility(this.layerVisible(node, index) ? Visibility.Visible : Visibility.Hidden)
          .transform(this.layerTransform(node, index))
        }, (key: string) => key)
      }
      .width('100%')
      .height(node.kind === 'stage' && node.minimum > 0 ? node.minimum : undefined)
      .clip(node.kind === 'stage' && node.style === 'floor')
      .backgroundColor(node.kind === 'stage' && node.style === 'floor' ? this.t().surface : Color.Transparent)
      .border({ width: node.kind === 'stage' && node.style === 'floor' ? this.t().borderWidth : 0, color: this.t().line })
      .borderRadius(node.kind === 'stage' && node.style === 'floor' ? this.t().radiusCard : 0)
    } else if (node.kind === 'transform') {
      // Inside a Stage or another Transform: drawn by the scene that owns it, not here.
    } else if (node.kind === 'motion') {
      // The children are drawn as they are; only the pose around them moves. Drawn inline, no component of its own.
      Column() {
        this.renderChildren(node)
      }
      .width(parentKind === 'row' ? undefined : '100%')
      .layoutWeight(parentKind === 'row' ? 1 : 0)
      .alignItems(HorizontalAlign.Center)
      .rotate({ x: this.motionPoseOf(node).axisX, y: this.motionPoseOf(node).axisY, z: this.motionPoseOf(node).axisZ,
                angle: this.motionPoseOf(node).angle, centerX: '50%', centerY: '50%', perspective: 2400 })
      .scale({ x: this.motionPoseOf(node).scale, y: this.motionPoseOf(node).scale, centerX: '50%', centerY: '50%' })
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
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (node.value.length > 0) {
          Button(node.value)
            .height(this.t().chipHeight)
            .fontSize(this.t().sizeBody)
            .fontFamily(this.textFamily())
            .type(ButtonType.Capsule)
            .backgroundColor(toneEdge(this.t(), node.style, this.t().primary))
            .fontColor(readableInk(toneEdge(this.t(), node.style, this.t().primary)))
            .onClick(() => {
              if (node.action.length > 0) { this.handleAction(node.action, node.eventValue) }
            })
        }
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
              if (node.action.length > 0) { this.handleAction(node.action, node.eventValue) }
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
      // Two to a row; a tile of span 2 takes the row. Widths are calc() shares of the row less half the gap,
      // so the pair and the wide tile line up at both edges.
      Flex({
        wrap: FlexWrap.Wrap,
        justifyContent: FlexAlign.Start,
        alignItems: ItemAlign.Stretch,
        space: { main: LengthMetrics.vp(this.t().gapLoose), cross: LengthMetrics.vp(this.t().gapLoose) }
      }) {
        ForEach(node.children, (child: LiveNode) => {
          Column() {
            this.renderNode(child, 'tilegrid')
          }
          .width(child.kind === 'tile' && child.columns >= 2 ? '100%' :
            'calc(50% - ' + (this.t().gapLoose / 2).toString() + 'vp)')
          // Same keying as renderChildren; see the note there.
        }, (child: LiveNode, index: number) => index.toString() + ':' + child.kind)
      }
      .width('100%')
      .padding({ left: this.t().padBase, right: this.t().padBase })
      .margin({ top: this.t().gapTight, bottom: this.t().gapTight })
    } else if (node.kind === 'tile') {
      Column({ space: this.t().gapTight }) {
        if (node.icon.length > 0) {
          this.iconChip(node.icon, this.t().controlHeight - 8,
            node.style === 'default' ? this.t().primaryFill : this.t().surface,
            toneInk(this.t(), node.style, this.t().primaryInk))
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
      .width('100%')
      .height('100%')
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
              let next = node.numberValue - 1
              if (next >= node.minimum) { this.handleAction(node.action, next) }
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
              let next = node.numberValue + 1
              if (next <= node.maximum) { this.handleAction(node.action, next) }
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
            this.getUIContext().showTimePickerDialog({
              selected: this.minutesToDate(node.numberValue),
              useMilitaryTime: true,
              onAccept: (result: TimePickerResult) => {
                let h = result.hour !== undefined ? result.hour as number : 0
                let m = result.minute !== undefined ? result.minute as number : 0
                this.handleAction(node.action, h * 60 + m)
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
            this.getUIContext().showDatePickerDialog({
              selected: this.dayToDate(node.numberValue),
              onDateAccept: (value: Date) => {
                this.handleAction(node.action, this.dateToDay(value))
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
          this.handleAction(node.action, node.eventValue)
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
          this.handleAction(node.action, node.eventValue)
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
          this.handleAction(node.action, node.eventValue)
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
            this.handleAction(node.action, node.eventValue)
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
          this.handleAction(node.action, node.eventValue)
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
        TextInput({ placeholder: node.label.length > 0 ? '' : ' ', text: node.value })
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
          .onSubmit((_key: EnterKeyType, _event: SubmitEvent) => {})
          .onChange((v: string) => {
            if (node.action.length > 0) { this.handleStringAction(node.action, v) }
          })
        if (this.textFieldIssue(node).length > 0) {
          Text(this.textFieldIssue(node)).fontSize(this.t().sizeCaption).fontFamily(this.textFamily()).fontColor(this.t().dangerInk)
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
              if (node.action.length > 0) { this.handleBoolAction(node.action, on) }
            })
        } else {
          Checkbox()
            .select(node.checked)
            .enabled(node.enabled)
            .selectedColor(this.t().primary)
            .onChange((on: boolean) => {
              if (node.action.length > 0) { this.handleBoolAction(node.action, on) }
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
            this.dispatch(node.action, new VeraNumberValue(Math.round(v)),
              mode === SliderChangeMode.End)
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
        .bindMenu(this.selectMenuItems(node))
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
                if (node.action.length > 0) { this.handleAction(node.action, index) }
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
          this.iconChip(node.icon, this.t().controlHeight - 4,
            toneFill(this.t(), node.style, this.t().primaryFill),
            toneInk(this.t(), node.style, this.t().primaryInk))
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
          this.handleAction(node.action, node.eventValue)
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
