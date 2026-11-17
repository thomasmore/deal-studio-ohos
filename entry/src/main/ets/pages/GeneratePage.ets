import { copyText } from '../components/Clipboard'
import { common } from '@kit.AbilityKit'
import { KeyboardAvoidMode, window } from '@kit.ArkUI'
import { fileIo as fs } from '@kit.CoreFileKit'
import { http } from '@kit.NetworkKit'
import { request } from '@kit.BasicServicesKit'
import { Version, VersionMetrics, store } from '../vera/ProjectStore'
import { AppRouteParams, returnToLibrary } from '../vera/AppNavigation'
import { formBindings } from '../vera/FormBindings'
import { publishLiveWidget, bindLiveForm, WIDGET_ADDED } from '../vera/LiveWidgetPublish'
import { refreshForms } from '../vera/FormUpdater'
import { widgetRefinementPrompt, widgetRepairNote } from '../vera/VeraWidgetRefine'
import { veraStateStamp } from '../vera/VeraStateStamp'
import { WidgetPreview } from '../components/WidgetPreview'
import { hasWidgetFunction } from '../vera/WidgetStatus'
import { engine, LlamaEngine, GenerateRequest, GenerateResult, loadRawfileText } from '../vera/LlamaEngine'
import { compileVeraSource, CompileError, spliceWidget, appUsesWidgetError, carryWidget, withoutWidget, widgetRefinementError } from '../vera/VeraCompiler'
import { applyRepair, repairPrompt } from '../vera/VeraRepair'
import { smokeRun } from '../vera/VeraSmoke'
import { logMark, logStep, initTrace, trace, traceCompile } from '../vera/VeraTiming'
import { deepseek, DEEPSEEK_GENERATION_MAX_TOKENS, SideCall } from '../vera/DeepSeekEngine'
import { OperationController, throwIfCancelled } from '../vera/OperationCancellation'
import { VeraPreview, VeraPreviewController } from '../components/VeraPreview'
import { settings, MODE_DEEPSEEK, MODE_SERVER, MODE_LOCAL } from '../vera/SettingsStore'
import { settingsMenuItem } from '../components/SettingsEntry'
import { withoutWidgetRequests } from '../vera/ProjectText'
import { consent } from '../vera/VeraConsentStore'
import { describeCatalogForPrompt } from '../vera/VeraUiCatalog'
import { ensureUiEmbeddings } from '../vera/VeraUiIndex'
import { ensureCapabilities, prepareCapabilityEmbeddings } from '../vera/VeraCapabilities'
import { loadCatalogFile } from '../vera/VeraCatalogFile'
import { modelSupportNote } from '../vera/VeraEmbeddings'
import { ensureSdkEmbeddings } from '../vera/VeraSdkEmbeddingCache'
import { ensureIntentEmbeddings } from '../vera/VeraIntentEmbeddingCache'
import { benchmarkRequested, runSearchBenchmark } from '../vera/VeraSearchBenchmark'
import { sdkSearchRequested, runSdkSearchProbe } from '../vera/VeraSdkProbe'
import { uiEvalRequested, runUiEval } from '../vera/VeraUiEval'
import { uiAbRequested, runUiAb } from '../vera/VeraUiAb'
import { selectUiForPrompt, UI_SELECT_FULL, UI_SELECT_PROMPT, UI_TOOL_NOTE } from '../vera/VeraUiSelect'
import { sdkEvalRequested, runSdkEval } from '../vera/VeraSdkEval'
import { composeEnabled, ComposeResult } from '../vera/VeraCompose'
import { AgentRequest, AgentResult } from '../vera/agent/VeraAgent'
import { appAgentHost } from '../vera/agent/AgentAppHost'
import { drawsSurface, editSurfaceProgram, SurfaceEdit } from '../vera/agent/AgentSurfaceEdit'
import { writeWidget, WidgetWrite, WIDGET_ASK } from '../vera/agent/AgentWidget'
import { validateWidgetOffMain } from '../vera/agent/WidgetCheckTask'
import { WidgetSuggestion, firstSuggestions, changeSuggestions } from '../vera/agent/WidgetSuggest'
import { sameCard } from '../vera/VeraLiveWidget'
import { surfaceRouteEnabled } from '../vera/agent/AgentSurface'
import { AgentQuestion, PersonAnswer } from '../vera/agent/AgentQuestions'
import { QuestionCard } from '../components/QuestionCard'
import { SymbolGlyphModifier } from '@kit.ArkUI'
import { ChatStarters, APP_STARTERS } from '../components/ChatStarters'
import { IconPicker, APP_ICONS } from '../components/IconPicker'
import { projectIconResource } from '../vera/ProjectIcons'
import { suggestAppName, suggestAppIcon } from '../vera/AppName'
import { app, PrimaryButton, TonalButton, QuietButton } from '../components/AppStyle'
import { MetricCard, MetricTile, MetricChip, MetricLine } from '../components/MetricCard'
import { buildScreen, RouteRequest, RouteOutcome, OUTCOME_AGENT, OUTCOME_CANCELLED } from '../vera/agent/VeraBuildRoute'
import { templateSelectEnabled } from '../vera/VeraTemplateSelectFlag'
import { ToolCall, ToolTotal, toolCalls, resetToolLog, toolTotals, toolMs } from '../vera/ToolLog'
import { ServiceNote, serviceNotes, resetServiceHealth, describeService, silent, serviceTrouble } from '../vera/ServiceHealth'
import { Stage, addStage, appMs, yourMs, byWho, WHO_MODEL, WHO_JEV, WHO_SEARCH, WHO_PHONE, WHO_YOU } from '../vera/RunStages'
import { compositionFromJson, compositionToJson, editComposition, selectEdit, Composition, CompositionEdit, EditResult } from '../vera/VeraComposition'

/** How the system prompt picks the std/ui components it describes: 'full', 'phrases' or 'prompt' (VeraUiSelect.ets). */
const UI_SELECT_MODE: string = UI_SELECT_PROMPT
const MAX_RETRIES: number = 3
/** How long a new app opened full screen keeps the run's line over it. */
const READY_NOTE_MS: number = 4000

// vera-server's address is not written down here. It lives in settings, given
// the same way as the API key -- `--ps veraServer http://host:port` -- because
// one person's machine address has no business in a shared repository.
function serverUrl(): string { return settings.getServerUrl() }

// DeepSeek and Local both run the agent loop on the device and differ only in
// which model writes the code; Server hands the whole job to vera-server.

// The lower half of the screen is one pane at a time: the running program,
// its source, or the numbers behind the run.
/** The picture a new app starts with; the Save window lets it be changed. */
const DEFAULT_APP_ICON: string = APP_ICONS[0]
const TAB_PREVIEW: string = 'preview'
/** The fold button, in full screen: the same size and place folded and unfolded. */
const FOLD_SIZE: number = 44
/** What a program is given under it when the fold button lies over it: the button, its margin and a little more. */
const FOLD_ROOM: number = 76
const TAB_CODE: string = 'code'
const TAB_METRICS: string = 'metrics'
/** The program's home-screen widget, drawn as the card draws it (WidgetPreview). */
const TAB_WIDGET: string = 'widget'

class ServerDecodedResponse {
  source: string = ''
  bytecode: string = ''
}

class RefineRequest {
  prompt: string = ''
  previousSource: string = ''
}

class AttemptMetrics {
  attempt: number = 0
  // Waiting for the first token and streaming the rest have different causes:
  // a long wait is the prompt being read, a slow stream is the model writing.
  ttftMs: number = 0
  genMs: number = 0
  compileMs: number = 0
  inputTokens: number = 0
  outputTokens: number = 0
  cacheHitTokens: number = 0
  thinking: boolean = false
  thinkMs: number = 0
  finishReason: string = ''
  // Which layer rejected the program, taken from the leading digit of the
  // first diagnostic: E1 is the parser, E2 is names and types. Dying in the
  // parser means the model missed the syntax; dying later means it wrote
  // readable VERA-L that means the wrong thing.
  failLayer: string = ''
  failCode: string = ''
  success: boolean = false
}

/** One generation or refinement, kept after the next one starts. */
class RunRecord {
  request: string = ''
  attempts: AttemptMetrics[] = []
  compiled: boolean = false
  delta: SourceDelta = new SourceDelta()
}

/**
 * What the screen held before a request ran: the program and the requests that made it. An edited request is run again on
 * it, in place of the request it replaces (GeneratePage.rewriteRequest).
 */
class RequestBase {
  compiledSource: string = ''
  compiledVbc2: string = ''
  compositionJson: string = ''
  templateKinds: string[] = []
  requestHistory: string = ''
  acceptedRequest: string = ''
  acceptedComposition: string = ''
  acceptedOrigin: string = ''
  acceptedMetrics: VersionMetrics | null = null
  modelWrote: boolean = false
  /** The base of the request that made this program, so that an edit after an edit still has one. */
  before: RequestBase | null = null
}

/** The round button of the request box (GeneratePage.roundButton), passed whole so that its state is followed. */
class RoundButtonSpec {
  symbol: string = ''
  enabled: boolean = true
  tap: () => void = () => {}
}

/** Everything spent since the last fresh generation, refinements included. */
class RunTotals {
  runs: number = 0
  attempts: number = 0
  ms: number = 0
  llmMs: number = 0
  compileMs: number = 0
  inputTokens: number = 0
  cacheHitTokens: number = 0
  outputTokens: number = 0
}

/** How far a refinement moved the program it started from. */
class SourceDelta {
  added: number = 0
  removed: number = 0
  keptPercent: number = 0
  measured: boolean = false
}

/**
 * The compiler groups diagnostics by the layer that raises them, and the
 * leading digit says which: E1 comes from the parser, E2 from names and types.
 * The distinction is the useful one -- a program rejected by the parser missed
 * the syntax, one rejected later reads fine and means the wrong thing.
 */
function codeOf(errors: string): string {
  let m = errors.match(/[ER]\d{4}/)
  return m === null ? '' : m[0]
}

function layerOf(errors: string): string {
  if (errors.indexOf('The program compiled, but') >= 0) { return 'runtime' }
  let code = codeOf(errors)
  if (code.length === 0) { return 'compile' }
  let layer = code.substring(1, 2)
  if (layer === '1') { return 'parser' }
  if (layer === '2') { return 'names & types' }
  return 'layer E' + layer
}

function diffLines(before: string, after: string): SourceDelta {
  let delta = new SourceDelta()
  if (before.length === 0) { return delta }
  let oldLines: string[] = []
  for (let line of before.split('\n')) {
    let t = line.trim()
    if (t.length > 0) { oldLines.push(t) }
  }
  let newLines: string[] = []
  for (let line of after.split('\n')) {
    let t = line.trim()
    if (t.length > 0) { newLines.push(t) }
  }
  // Line multisets rather than a real diff: this answers "how much of the old
  // program survived" without running a diff algorithm on the phone.
  let counts = new Map<string, number>()
  for (let line of oldLines) {
    let n = counts.get(line)
    counts.set(line, (n === undefined ? 0 : n) + 1)
  }
  let kept = 0
  for (let line of newLines) {
    let n = counts.get(line)
    if (n !== undefined && n > 0) {
      kept += 1
      counts.set(line, n - 1)
    } else {
      delta.added += 1
    }
  }
  delta.removed = oldLines.length - kept
  delta.keptPercent = oldLines.length > 0 ? Math.round(kept * 100 / oldLines.length) : 0
  delta.measured = true
  return delta
}

function decodeServerResponse(body: string): ServerDecodedResponse {
  let lines = body.split('\n')
  let sourceLines: string[] = []
  let bytecodeLines: string[] = []
  let inSource = false
  let foundSource = false
  for (let line of lines) {
    if (line === ';vera-source-begin') {
      inSource = true
      foundSource = true
      continue
    }
    if (line === ';vera-source-end' && inSource) {
      inSource = false
      continue
    }
    if (inSource) {
      if (line.startsWith(';|')) {
        sourceLines.push(line.substring(2))
      }
      continue
    }
    bytecodeLines.push(line)
  }
  let result = new ServerDecodedResponse()
  result.source = foundSource ? sourceLines.join('\n') : ''
  result.bytecode = bytecodeLines.join('\n')
  return result
}

class GeneratePageParams extends AppRouteParams {
  prompt: string = ''
  run: string = ''
}

@Component
export struct GeneratePage {
  params: AppRouteParams = new AppRouteParams()
  private disposed: boolean = false

  @Consume('navPathStack') pathStack: NavPathStack

  @State projectId: string = ''
  @State baseVersionId: string = ''
  @State prompt: string = ''
  /** Set by the home screen when it sent the request rather than only filling the box. */
  private runOnOpen: boolean = false
  /** The prompt and the catalogue are read; a request sent before that waits for it (runOnOpen). */
  private resourcesLoaded: boolean = false
  /** What a service that did not answer cost this run (ServiceHealth.ets), shown under the status. */
  @State troubleNote: string = ''
  @State requestHistory: string = ''
  @State baseVersionNumber: number = 0
  @State nextVersionNumber: number = 1
  @State baseError: string = ''
  @State generatedSource: string = ''
  @State status: string = ''
  @State @Watch('threadMoved') generating: boolean = false
  @State modelReady: boolean = false
  @State mode: string = MODE_DEEPSEEK
  // The model the picker last selected. The subtitle and chip highlights read
  // this instead of settings.getModel() directly so that tapping a chip (which
  // changes the stored model at runtime) re-renders them -- settings is not
  // @State, so a method that only reads it does not re-evaluate when the model
  // changes. Kept in sync in aboutToAppear, checkDeepSeek and the chip onClick.
  @State selectedModel: string = ''
  // Whether the composer's selector calls route through the on-device cloud
  // proxy (JevProxy.ets) instead of TypeSafe. Like selectedModel, this mirrors a
  // settings field into @State so the toggle re-renders: settings is not @State,
  // so a method that only reads useJevProxy() does not re-evaluate when it
  // flips. Kept in sync in aboutToAppear, checkDeepSeek and the toggle onClick.
  @State jevProxyOn: boolean = false
  // What the USB-network VPN last reported (UsbNet.ets), read once a second while Advanced is open (syncUsbNetPoll).
  /** The timer that takes the run's line off the full screen (openWhole); -1 when none. */
  private readyNoteTimer: number = -1
  @State attempt: number = 0
  @State compiled: boolean = false
  @State compileErrors: string = ''
  /**
   * Experiment only (experiment/jev-template-select branch): what
   * the last structural edit decided (tryStructuralEdit), regardless of
   * outcome -- mirrors ChatMessage.templatePick (ChatPage.ets), which this
   * page lacked until it became clear hilog's ring buffer and the transient
   * `status` line (overwritten by the next phase) left no way to check
   * after the fact whether Jev was even asked. Cleared at the start of each
   * doGenerate() so a stale answer from a previous attempt is never shown
   * against the current one.
   */
  @State lastTemplatePick: string = ''
  /** The small model calls of this run (text for blocks, function bodies, second opinion, UI choice), for the Metrics tab. */
  @State sideCalls: SideCall[] = []
  /** Where the time of this run went, stage by stage (RunStages.ets): the Metrics tab's first card. */
  @State stages: Stage[] = []
  /** Which of Jev, Exa and DeepSeek answered in this run and which did not: the Metrics tab's last card. */
  @State services: ServiceNote[] = []
  /** What the composer left out of the last screen, and why (ComposeResult.dropped), for the Metrics tab. */
  @State leftOut: string[] = []
  /** The lookups of this run (find_sdk_function, find_intent_function, find_ui_component, web_search), for the Metrics tab. */
  @State tools: ToolCall[] = []
  /** Whether the tool calls card shows every call or only its total: closed until tapped. */
  @State toolsOpen: boolean = false
  /** The Metrics pane's real width, measured: a percentage inside the Scroll resolves against a wider box than the one drawn. */
  @State metricsWidth: number = 0
  @State @Watch('showCorner') compiledVbc2: string = ''
  /** The running preview's state as it last changed; not @State, as writing it must not redraw the page. */
  private liveState: string = ''
  private previewController: VeraPreviewController = new VeraPreviewController()
  /** What the next compiled program starts from (VeraPreview.seedState): the state at the moment a refine was asked for. */
  @State carriedState: string = ''
  /**
   * The widget's bytecode and the saved state its card checks last passed with ('' for none). Save checks the widget again over
   * the state saved by then; when that is the same, the run that plays its taps (seconds for a game) is not made twice.
   */
  private widgetPassed: string = ''
  /** The run's own line ("Ready in 8.3 s") over a new app just opened full screen, for a few seconds. */
  @State readyNote: boolean = false
  /**
   * A picture of the screen drawn from the composer's sketch while the real program is still on its way:
   * it builds up as the sketch streams in, and stays up through a fallback generation. Taps are off;
   * it is never saved, and the finished program replaces it.
   */
  @State previewVbc2: string = ''
  @State previewNote: string = ''
  /** A blocking question from the agent (agent/AgentQuestions.ets), shown above the preview until it is answered. */
  @State questionText: string = ''
  @State questionOptions: string[] = []
  @State questionFallback: number = 0
  /** Answers the open question: an index, the person's own words, or null for its default. */
  private answerQuestion: ((answer: PersonAnswer) => void) | null = null
  @State compiledSource: string = ''
  @State refinePrompt: string = ''
  @State program: RunTotals = new RunTotals()
  @State delta: SourceDelta = new SourceDelta()
  // Every run of this program, oldest first. A refinement used to wipe the
  // numbers of the generation it was refining, which is exactly the comparison
  // worth having.
  @State runs: RunRecord[] = []
  @State composerOpen: boolean = false
  /** The soft keyboard is up (the page shrank): the header gives its room to the preview. See build(). */
  @State keyboardOpen: boolean = false
  /** The request box itself has the focus (as against a field of the program). */
  @State composerFocused: boolean = false
  /** The window the keyboard's height is heard from, and the listener, to stop listening when the page goes. */
  private keyboardWindow: window.Window | null = null
  private keyboardListener: (height: number) => void = (height: number) => {
    if (this.disposed) { return }
    let open = height > 0
    if (open !== this.keyboardOpen) { this.keyboardOpen = open }
  }
  /** The full request history, shown under the one-line request when it is tapped. */
  @State historyOpen: boolean = false
  @State downloading: boolean = false
  /** How to set up what is missing (a key, a server address); shown where the preview would be, not in the status line. */
  @State setupHint: string = ''
  /** The bytecode last saved as a version: Save is off while the program on screen is the one already saved. */
  @State savedVbc2: string = ''
  /** The window that asks for a new app's name, open from the first Save; the name is what it offers or what was typed. */
  @State naming: boolean = false
  @State saveName: string = ''
  @State saveIcon: string = DEFAULT_APP_ICON
  /** The pictures to choose from, shown under the name once the picture is tapped. */
  @State iconsOpen: boolean = false
  /** The window that asks whether to save before leaving with a result that is not saved. */
  @State leaving: boolean = false
  /** Set when Save was chosen in the leaving window: the page closes once the save is done. */
  private leaveAfterSave: boolean = false
  /** Set by Widget on an app that is not saved yet: once it is (a new app is named first), the widget screen opens. */
  private widgetAfterSave: boolean = false
  /** Set just before the page closes itself, so that the back press it causes is not asked about again. */
  private closing: boolean = false
  @State tab: string = TAB_PREVIEW
  /** What the one box holds, the settings and the details are open. */
  @State draft: string = ''
  /** The box holds an edit of the last request: sending it runs it again on what was there before it (rewriteRequest). */
  @State rewriting: boolean = false
  /** The program alone over the whole screen, with the box under it; see fullscreenPane. */
  @State fullscreen: boolean = false
  /** The full-screen corner buttons stepped aside while the program is read further down (VeraPreview onReadingDown). */
  @State cornerHidden: boolean = false
  /** Full screen with the request box folded away; see composer. */
  @State composerHidden: boolean = false
  /** True while another destination covers this page; flows to VeraPreview so its surface frame loop stops underneath. */
  @State destinationHidden: boolean = false
  /** The result card's request line is open to the whole history of requests. */
  @State requestOpen: boolean = false
  private scroller: Scroller = new Scroller()
  @State attempts: AttemptMetrics[] = []
  @State totalMs: number = 0
  private systemPrompt: string = ''
  /** The skill with std/ui spliced in. */
  private promptTemplate: string = ''
  /** The skill before {{UI_CATALOG}} is filled in, so each request can choose what to describe. */
  private skillText: string = ''
  /** How a game is written on a ui.Surface (rawfile vera-surface-skill.txt), for the route; '' when it did not load. */
  private surfaceGuide: string = ''
  /** How a 3D program is written on a ui.World (rawfile vera-world-skill.txt); '' when it did not load (3D is then written flat). */
  private worldGuide: string = ''
  /** Components the current system prompt describes; empty means all of them. */
  private uiSelected: string[] = []
  private grammar: string = ''
  private previousSource: string = ''
  private makeWidget: boolean = false
  private widgetBase: string = ''
  /** The app preview's state when the Widget tab was opened: what the widget preview draws. */
  @State widgetSeed: string = ''
  /** The project's name, for the card's frame (a live card does not show it). */
  private widgetTitle: string = 'App'
  /** Home-screen cards that show this project: the widget screen's button adds one when there are none. */
  @State widgetCards: number = 0
  /** A card placed with no app yet, opened from WidgetBindPage: the widget made here is put on it. */
  private bindFormId: string = ''
  /** Why the last widget was not made, in the model's and the checks' words; '' when it was. */
  @State widgetFailure: string = ''
  @State widgetFailureOpen: boolean = false
  /** The last thing asked of the widget screen, for Try again. */
  private widgetAsk: string = ''
  /** What a tapped suggestion says on its chip, for the version list: its ask is the model's instruction, not the person's words. */
  private chipLabel: string = ''
  private requestLabel: string = ''
  /** Adding the card: the system dialog may take a while, and a second tap must not add two. */
  @State widgetAdding: boolean = false
  /** checkWidgetSave is running the card's checks in a worker: Save waits for them. */
  @State widgetChecking: boolean = false
  /** What to do next when the card could not be added here (a launcher with no add dialog, an error). */
  @State widgetNote: string = ''
  /** Set once the card was put on the home screen from this page: the button then says so. */
  @State widgetPlacedHere: boolean = false
  /** The program before the last widget request: what the new card is compared with. */
  private widgetBeforeVbc2: string = ''
  private widgetBeforeHad: boolean = false
  /**
   * Redo (opened so from the project page): the next widget is written from nothing, on the program without the one
   * it has (withoutWidget), with the first widget's requests. The widget there stays on screen and on the card until a new
   * one is made and kept; after that, requests change the new one.
   */
  @State widgetFresh: boolean = false
  /** widgetChangeNote's answer for widgetChangeFor, which takes a run of the widget to work out. */
  private widgetChangeFor: string = ''
  private widgetChangeText: string = ''
  /** widgetSuggestions' answer for widgetChipsFor, which takes a parse of the program. */
  private widgetChipsFor: string = ''
  private widgetChips: WidgetSuggestion[] = []
  /** A new app was just saved: offer it a home-screen widget, once. */
  @State widgetOffer: boolean = false
  /** The next repair asks for SEARCH/REPLACE edits (VeraRepair); false after edits failed to apply. */
  private repairByEdit: boolean = true
  /** The section kinds of the last composed screen, kept with a saved version as its origin; empty after a scratch run. */
  private templateKinds: string[] = []
  /**
   * The composition record (VeraComposition.ets) of the program on screen while it is a composed screen the
   * model has not rewritten; a refine that only adds, removes, replaces or moves a block rebuilds from it.
   * Empty after a scratch or model-finished program.
   */
  private compositionJson: string = ''
  /** True once a model-written program compiled in this generation; the saved origin then says "+model". */
  private modelWrote: boolean = false
  /** Bumped by every Generate, refine and Stop, so a run that was stopped knows it is stale when a new one resets cancelRequested. */
  private runId: number = 0
  private genStartTime: number = 0
  private cancelRequested: boolean = false
  private activeOperation: OperationController = new OperationController()
  // The server request is the only GeneratePage operation whose transport is
  // owned directly by this page; retain its destroy function so Stop and page
  // disposal can interrupt the in-flight HTTP request, not only ignore its result.
  private activeServerAbort: (() => void) | null = null
  private activeServerAbortRun: number = -1
  private lastRequest: string = ''
  private failedSource: string = ''
  private serverBytecode: string = ''
  private pendingHistory: string = ''
  private pendingRequest: string = ''
  private acceptedRequest: string = ''
  /** What was on the screen when the running request started, and when the accepted one did; null when unknown. */
  private pendingBase: RequestBase | null = null
  private acceptedBase: RequestBase | null = null
  private acceptedComposition: string = ''
  private acceptedOrigin: string = ''
  private acceptedMetrics: VersionMetrics | null = null
  private metricTotals: VersionMetrics = new VersionMetrics()
  private metricRunId: number = -1
  private metricMode: string = ''
  private metricModel: string = ''
  private metricPriced: boolean = false
  private metricRates: number[] = []
  private metricSeenSideCalls: Set<SideCall> = new Set<SideCall>()
  private metricPendingRuns: Set<number> = new Set<number>()
  private metricStaleRuns: Set<number> = new Set<number>()

  private beginOperation(): OperationController {
    this.activeOperation.cancel()
    this.settleQuestion(null)
    this.activeOperation = new OperationController()
    return this.activeOperation
  }

  private modelRequestHistory(): string {
    return this.makeWidget && this.widgetFresh ? withoutWidgetRequests(this.requestHistory) : this.requestHistory
  }

  private prepareRequest(ask: string): void {
    this.finishMetrics(this.runId)
    this.pendingBase = this.currentBase()
    if (this.makeWidget && this.widgetFresh) { this.previousSource = withoutWidget(this.compiledSource) }
    this.pendingRequest = ask
    let history = this.modelRequestHistory()
    this.pendingHistory = history.length > 0 ? history + '\n\nRefinement:\n' + ask : ask
    this.metricRunId = this.runId + 1
    this.metricMode = this.mode
    this.metricModel = this.mode === MODE_DEEPSEEK ? settings.getModel() :
      (this.mode === MODE_LOCAL ? 'qwen2.5-coder-3b-instruct-q4_k_m' : '')
    this.metricPriced = this.mode === MODE_DEEPSEEK && this.metricModel === 'deepseek-flash' &&
      settings.getBaseUrl().replace(/\/+$/, '') === 'https://api.deepseek.com'
    this.metricRates = [this.ratePerMillion('cache'), this.ratePerMillion('fresh'), this.ratePerMillion('output')]
    this.metricSeenSideCalls = new Set<SideCall>()
    let totals = this.metricTotals
    if (totals.runs === 0) {
      totals.provider = this.modeLabel()
      totals.model = this.metricModel
    } else {
      if (totals.provider !== this.modeLabel()) { totals.provider = 'Mixed' }
      if (totals.model !== this.metricModel) { totals.model = 'Mixed' }
    }
    totals.runs++
    if (!this.metricPriced) { totals.partial = true }
  }

  private measuredTotal(total: number, value: number): number {
    return value < 0 ? total : Math.max(0, total) + value
  }

  private addMetricUsage(input: number, cached: number, output: number, priced: boolean): void {
    let totals = this.metricTotals
    totals.inputTokens = this.measuredTotal(totals.inputTokens, input)
    totals.cacheHitTokens = this.measuredTotal(totals.cacheHitTokens, cached)
    totals.outputTokens = this.measuredTotal(totals.outputTokens, output)
    if (priced && input >= 0 && cached >= 0 && output >= 0) {
      let usd = (cached * this.metricRates[0] + Math.max(0, input - cached) * this.metricRates[1] +
        output * this.metricRates[2]) / 1000000
      totals.estimatedUsd = this.measuredTotal(totals.estimatedUsd, usd)
    } else {
      totals.partial = true
    }
    if (input < 0 || cached < 0 || output < 0) { totals.partial = true }
  }

  private async metricWork<T>(run: number, work: () => Promise<T>): Promise<T> {
    let totals = this.metricTotals
    this.metricPendingRuns.add(run)
    try {
      return await work()
    } finally {
      this.metricPendingRuns.delete(run)
      if (this.metricStaleRuns.delete(run)) { totals.partial = true }
    }
  }

  private collectMetricSideCalls(run: number): void {
    if (this.metricRunId !== run || this.metricMode === MODE_SERVER) { return }
    for (let call of deepseek.getSideCalls(this.activeOperation)) {
      if (this.metricSeenSideCalls.has(call)) { continue }
      this.metricSeenSideCalls.add(call)
      if (!call.ok || (call.inputTokens === 0 && call.outputTokens === 0)) {
        this.metricTotals.partial = true
        continue
      }
      this.addMetricUsage(call.inputTokens, call.cachedTokens, call.outputTokens, this.metricPriced)
    }
  }

  private beginMetricAttempt(run: number): void {
    if (this.metricRunId === run) { this.metricTotals.attempts++ }
  }

  private recordMetricResult(run: number, result: GenerateResult): void {
    if (this.metricRunId !== run) { return }
    let known = result.inputTokens > 0 || result.outputTokens > 0
    let completeCache = this.metricMode === MODE_DEEPSEEK
    let cached = completeCache && known ? result.cacheHitTokens : -1
    this.addMetricUsage(known ? result.inputTokens : -1, cached,
      known ? result.outputTokens : -1, this.metricPriced && completeCache)
    this.collectMetricSideCalls(run)
  }

  private finishMetrics(run: number): void {
    if (this.metricRunId !== run) { return }
    this.collectMetricSideCalls(run)
    this.metricTotals.elapsedMs += Math.max(0, Date.now() - this.genStartTime)
    this.metricRunId = -1
  }

  private copyMetrics(metrics: VersionMetrics): VersionMetrics {
    let copy = new VersionMetrics()
    copy.provider = metrics.provider
    copy.model = metrics.model
    copy.elapsedMs = metrics.elapsedMs
    copy.runs = metrics.runs
    copy.attempts = metrics.attempts
    copy.inputTokens = metrics.inputTokens
    copy.cacheHitTokens = metrics.cacheHitTokens
    copy.outputTokens = metrics.outputTokens
    copy.estimatedUsd = metrics.estimatedUsd
    copy.partial = metrics.partial
    return copy
  }

  private acceptRequest(): void {
    this.requestHistory = this.pendingHistory
    this.acceptedRequest = this.pendingRequest
    this.acceptedBase = this.pendingBase
    this.acceptedComposition = this.compositionJson
    this.acceptedOrigin = this.originLabel()
    this.totalMs = Math.max(0, Date.now() - this.genStartTime)
    this.finishMetrics(this.runId)
    this.acceptedMetrics = this.copyMetrics(this.metricTotals)
  }

  /** A new app has no project yet, so it has no versions; the id is empty until the first Save. */
  private versionCount(): number {
    return this.projectId.length === 0 ? 0 : store.listVersions(this.projectId).length
  }

  /** A run began or ended: the end of the thread is where the new card is. */
  private threadMoved(): void {
    this.scrollDown()
  }

  private previewSnapshot(controller: VeraPreviewController): (encoded: string) => void {
    return (encoded: string): void => {
      if (!this.disposed && this.previewController === controller) { this.liveState = encoded }
    }
  }

  private startNew(): void {
    this.previewController = new VeraPreviewController()
    this.savedVbc2 = ''
    this.historyOpen = false
    this.liveState = ''
    this.carriedState = ''
    this.baseVersionId = ''
    this.baseVersionNumber = 0
    this.baseError = ''
    this.previousSource = ''
    this.requestHistory = ''
    this.pendingHistory = ''
    this.pendingRequest = ''
    this.acceptedRequest = ''
    this.pendingBase = null
    this.acceptedBase = null
    this.rewriting = false
    this.acceptedComposition = ''
    this.acceptedOrigin = ''
    this.acceptedMetrics = null
    this.metricTotals = new VersionMetrics()
    this.metricRunId = -1
    this.metricSeenSideCalls = new Set<SideCall>()
    this.compiledSource = ''
    this.compiledVbc2 = ''
    this.generatedSource = ''
    this.compositionJson = ''
    this.templateKinds = []
    this.modelWrote = false
    this.previewVbc2 = ''
    this.previewNote = ''
    this.compiled = false
    this.compileErrors = ''
    this.prompt = ''
    this.refinePrompt = ''
    this.lastRequest = ''
    this.composerOpen = true
    this.nextVersionNumber = this.versionCount() + 1
  }

  private hostContext(): common.Context {
    let context = this.getUIContext().getHostContext()
    if (context === undefined) {
      this.status = 'Generate host context is unavailable'
      throw new Error(this.status)
    }
    return context
  }

  aboutToAppear(): void {
    let params = this.params as GeneratePageParams
    this.projectId = params.projectId
    this.baseVersionId = params.baseVersionId
    this.prompt = params.prompt || ''
    this.draft = this.prompt
    this.runOnOpen = (params.run || '').length > 0 && this.prompt.trim().length > 0
    this.makeWidget = params.makeWidget === '1'
    let context = this.hostContext()
    store.init(context.filesDir)
    let versions = this.projectId.length > 0 ? store.listVersions(this.projectId) : []
    this.nextVersionNumber = versions.length + 1
    if (this.baseVersionId.length > 0) {
      let v = store.getVersion(this.projectId, this.baseVersionId)
      let index = versions.findIndex((version: Version): boolean => version.id === this.baseVersionId)
      if (v !== null && v.source.length > 0 && index >= 0) {
        this.baseVersionNumber = versions.length - index
        this.previousSource = v.source
        this.requestHistory = v.prompt
        this.compositionJson = v.composition
        this.templateKinds = v.origin.replace('+model', '').split(',').filter((kind: string): boolean => kind.length > 0)
        this.modelWrote = v.origin.endsWith('+model')
        // The saved program stands in the thread as the result to change, already saved.
        if (v.vbc2.length > 0) {
          this.compiledSource = v.source
          this.generatedSource = v.source
          this.compiledVbc2 = v.vbc2
          this.savedVbc2 = v.vbc2
          this.compiled = true
          this.acceptedRequest = v.lastPrompt.length > 0 ? v.lastPrompt : v.note
          this.acceptedComposition = v.composition
          this.acceptedOrigin = v.origin
          this.status = 'Version ' + this.baseVersionNumber.toString()
        }
        if (this.makeWidget) {
          // An app that draws its own screen with widget(state) would change with a new widget: refused before any is made.
          let usesWidget = appUsesWidgetError(v.source)
          if (usesWidget.length > 0) { this.baseError = usesWidget }
          // The person says what the widget shows; the app and the widget start from the data the app has saved.
          let project = store.getProject(this.projectId)
          if (project !== null) { this.widgetTitle = project.name }
          this.carriedState = store.loadState(this.projectId, v.id, veraStateStamp(v.vbc2))
          this.widgetSeed = this.carriedState
          this.tab = TAB_WIDGET
          // Redo, from the project page: the widget there is not shown to the model (withoutWidget).
          this.widgetFresh = params.widgetFresh === '1' && hasWidgetFunction(v.source)
          this.widgetBase = this.widgetFresh ? withoutWidget(v.source) : v.source
          this.bindFormId = params.formId || ''
          this.widgetCards = this.readWidgetCards()
        }
      } else {
        this.baseError = 'The selected version is unavailable or has no source. Return to the version list.'
      }
    }
    settings.init(context.filesDir)
    this.mode = settings.getMode()
    this.selectedModel = settings.getModel()
    this.jevProxyOn = settings.useJevProxy()
    initTrace(context.filesDir)
    // Shrink the page for the keyboard instead of panning it: panning slides
    // the preview up under the title bar, and with the refine field pinned at
    // the bottom the page has to give up height, not move.
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE)
    // Whether the keyboard is up is the window's to say. Reading it from the page's height took any lasting drop -- a turn
    // to landscape, a fold, split screen -- for an open keyboard, for good.
    window.getLastWindow(context).then((win: window.Window) => {
      if (this.disposed) { return }
      this.keyboardWindow = win
      win.on('keyboardHeightChange', this.keyboardListener)
    }).catch((e: Error) => { console.warn('VERA keyboard listener unavailable: ' + e.message) })
    this.loadResources().then((): void => {
      // The request came with "send it": it goes now that the prompt and the catalogue are loaded.
      if (!this.disposed && this.runOnOpen) {
        this.runOnOpen = false
        this.doGenerate()
        if (this.generating) { this.draft = '' }
      }
    }).catch((_e: Error): void => {})
  }

  aboutToDisappear(): void {
    this.disposed = true
    if (this.readyNoteTimer >= 0) {
      clearTimeout(this.readyNoteTimer)
      this.readyNoteTimer = -1
    }
    if (this.generating) {
      this.stopGeneration()
    } else {
      this.finishMetrics(this.runId)
      this.cancelRequested = true
      this.runId++
      this.settleQuestion(null)
      this.activeOperation.cancel()
    }
    if (this.keyboardWindow !== null) {
      try { this.keyboardWindow.off('keyboardHeightChange', this.keyboardListener) } catch (_e) { /* the window is already gone */ }
      this.keyboardWindow = null
    }
  }

  // The key can arrive from a launch parameter while this page sits in the
  // foreground, so re-read it whenever the page comes back into view.
  private destinationShown(): void {
    if (this.disposed) { return }
    this.destinationHidden = false
    if (this.makeWidget) { this.widgetCards = this.readWidgetCards() }
    if (this.generating) { return }
    // The mode, the model and the selector are chosen on the Settings page, which may have been open over this one.
    let mode = settings.getMode()
    if (mode !== this.mode) {
      this.mode = mode
      this.checkProvider()
    } else if (this.mode === MODE_DEEPSEEK) {
      this.checkDeepSeek()
    }
  }

  private async loadResources(): Promise<void> {
    try {
      let context = this.hostContext()
      let mgr = context.resourceManager
      // Both catalogues are generated rather than written out in the rawfile,
      // so the prompt cannot describe a component the compiler rejects or the
      // renderer cannot draw, nor an intent the compiler will not accept and
      // the host will not send.
      // Loaded here as well as in EntryAbility: this page can be reached in a
      // process that started somewhere else, and a prompt built without the
      // file would offer fewer intents than the device actually has.
      consent.init(context.filesDir)
      let extra = loadCatalogFile(context.filesDir)
      if (extra.problems.length > 0) {
        console.warn('VERA-CATALOG rejected ' + extra.rejected.toString() + ' rows: ' +
          extra.problems.join('; '))
      }
      let skill = await loadRawfileText(mgr, 'vera-skill.txt')
      if (this.disposed) { return }
      // The UI catalogue is the same for every request, so it is spliced in
      // once. The intent catalogue is not spliced at
      // all any more: find_intent_function (DeepSeekEngine.ets,
      // VeraIntentIndex.ets) looks it up, along with the raw device
      // registry, when the model decides it needs one.
      this.skillText = skill
      try {
        let surfaceGuide = await loadRawfileText(mgr, 'vera-surface-skill.txt')
        if (this.disposed) { return }
        this.surfaceGuide = surfaceGuide
      } catch (e) {
        console.warn('VERA-SURFACE no guide, games go to the agent: ' + (e as Error).message)
      }
      try {
        let worldGuide = await loadRawfileText(mgr, 'vera-world-skill.txt')
        if (this.disposed) { return }
        this.worldGuide = worldGuide
      } catch (e) {
        console.warn('VERA-SURFACE no world guide, 3D is written flat: ' + (e as Error).message)
      }
      if (this.disposed) { return }
      this.promptTemplate = skill
        .replace('{{UI_CATALOG}}', describeCatalogForPrompt())
        .replace('{{UI_TOOL_NOTE}}\n', '')
      // Chat and Generate share index readiness and background embedding work.
      ensureCapabilities(context)
      this.ensureEmbeddingsReady()
      this.systemPrompt = this.promptTemplate
      let grammar = await loadRawfileText(mgr, 'vera.gbnf')
      if (this.disposed) { return }
      this.grammar = grammar
      this.status = 'Resources loaded'
    } catch (e) {
      if (this.disposed) { return }
      this.status = 'Failed to load resources: ' + (e as Error).message
    }
    this.resourcesLoaded = true
    this.checkProvider()
  }

  private checkProvider(): void {
    if (this.mode === MODE_DEEPSEEK) {
      this.checkDeepSeek()
    } else if (this.mode === MODE_SERVER) {
      this.checkServer()
    } else {
      this.checkModel()
    }
  }

  private checkDeepSeek(): void {
    this.selectedModel = settings.getModel()
    this.jevProxyOn = settings.useJevProxy()
    if (settings.hasApiKey()) {
      // A stub build cannot load the embedding model, so discovery falls back to
      // keywords; that belongs next to the provider line, which is what stays up.
      let note = modelSupportNote()
      let line = 'Ready \u00B7 key ' + settings.maskedKey()
      // joinSentence keeps the punctuation single whether or not the note is
      // present: modelSupportNote ends with '.', the selector note does not.
      line = this.joinSentence(line, note)
      line = this.joinSentence(line, this.selectorNote())
      this.status = line
      this.setupHint = ''
    } else {
      this.status = 'No ' + settings.providerLabel() + ' key set'
      this.setupHint = 'The key is given when the app is started, and kept after that:\n' +
        'hdc shell aa start -a EntryAbility -b com.vera.probe.dyn --ps deepseekKey <key>\n' +
        '(or --ps cloudKey <key> --ps apiBase <url> --ps apiModel <model> for another provider)'
    }
  }

  /**
   * A short suffix for the DeepSeek status line saying which selector answers
   * the composer's choice/noul questions: the on-device cloud proxy (JevProxy),
   * the real TypeSafe key, or none -- which is why the agent route and the
   * structural-edit path are gated off (hasSelector). Reads the @State copy so
   * it re-renders when the proxy toggle flips.
   */
  private selectorNote(): string {
    if (this.jevProxyOn) { return 'Selector: cloud proxy' }
    if (settings.hasSelectorKey()) { return 'Selector: TypeSafe' }
    return 'No selector (agent route off)'
  }

  /**
   * Join `more` onto `base` as a new sentence with exactly one separator: a
   * space when base already ends a sentence (. ! ?), else ". ". The provider
   * note and modelSupportNote end with a period and the selector note does not,
   * so a plain ". " join would double it; this keeps the line readable either
   * way.
   */
  private joinSentence(base: string, more: string): string {
    if (base.length === 0 || more.length === 0) { return base + more }
    let last = base.charAt(base.length - 1)
    if (last === '.' || last === '!' || last === '?') { return base + ' ' + more }
    return base + '. ' + more
  }

  private async checkServer(): Promise<void> {
    if (!settings.hasServerUrl()) {
      // Said in full, because the address is not written down anywhere in the
      // app and the person has no other way to learn what is missing.
      this.status = 'No server address set'
      this.setupHint = 'The address is given when the app is started, and kept after that:\n' +
        'hdc shell aa start -a EntryAbility -b com.vera.probe.dyn --ps veraServer http://host:port'
      return
    }
    this.setupHint = ''
    this.status = 'Checking server...'
    let client = http.createHttp()
    try {
      let resp = await client.request(serverUrl() + '/health', {
        method: http.RequestMethod.GET,
        connectTimeout: 5000,
        readTimeout: 5000
      })
      if (this.disposed) { return }
      if (resp.responseCode === 200) {
        let body = resp.result as string
        let health = JSON.parse(body) as Record<string, Object>
        this.status = 'Server ready (' + (health['model'] as string) + ')'
      } else {
        this.status = 'Server error: HTTP ' + resp.responseCode
      }
    } catch (e) {
      if (this.disposed) { return }
      this.status = 'Server unreachable: ' + (e as Error).message
    } finally {
      client.destroy()
    }
  }

  private async checkModel(): Promise<void> {
    let filesDir = this.hostContext().filesDir
    let modelPath = LlamaEngine.defaultModelPath(filesDir)
    this.setupHint = ''
    if (!LlamaEngine.modelExists(filesDir) && !settings.hasServerUrl()) {
      // The model is fetched from vera-server, so with no address there is nothing to fetch it from.
      this.modelReady = false
      this.status = 'Model not downloaded'
      return
    }
    if (!LlamaEngine.modelExists(filesDir)) {
      // hdc file send is blocked on release-provisioned installs, so the
      // model is fetched from the vera-server /models endpoint instead.
      await this.downloadModel(modelPath)
    }
    if (this.disposed) { return }
    this.modelReady = LlamaEngine.modelExists(filesDir)
    if (!this.modelReady) {
      this.status = 'Model not found'
      return
    }
    this.status = 'Model ready'
    if (!engine.isReady()) {
      this.status = 'Loading model...'
      let ok = engine.init({
        modelPath: modelPath,
        nCtx: 4096,
        nThreads: 4,
        nGpuLayers: 0
      })
      this.status = ok ? 'Model loaded' : 'Model load failed'
      this.modelReady = ok
    }
  }

  private async downloadModel(modelPath: string): Promise<void> {
    let context = this.hostContext()
    let filesDir = context.filesDir
    try {
      fs.mkdirSync(filesDir + '/models', true)
    } catch (_e) {}
    this.status = 'Downloading model (one-time, ~1.9GB)...'
    this.downloading = true
    try {
      if (canIUse('SystemCapability.Request.FileTransferAgent')) {
        if (canIUse('SystemCapability.MiscServices.Download')) {
          let task = await request.downloadFile(context, {
            url: serverUrl() + '/models/qwen2.5-coder-3b-instruct-q4_k_m.gguf',
            filePath: modelPath
          })
          task.on('progress', (received: number, total: number): void => {
            if (!this.disposed && total > 0) {
              this.status = 'Downloading model ' + Math.floor(received * 100 / total).toString() + '%'
            }
          })
          await new Promise<void>((resolve, reject) => {
            task.on('complete', (): void => { resolve() })
            task.on('fail', (err: number): void => { reject(new Error('download failed, code ' + err.toString())) })
          })
          if (this.disposed) { return }
          this.status = 'Model downloaded'
          return
        }
        throw new Error('SystemCapability.MiscServices.Download is not supported')
      }
      throw new Error('SystemCapability.Request.FileTransferAgent is not supported')
    } catch (e) {
      if (this.disposed) { return }
      this.status = 'Model download failed: ' + (e as Error).message
    } finally {
      if (!this.disposed) { this.downloading = false }
    }
  }

  /** Preserve UI preparation and evaluation hooks after shared capability preparation. */
  private async ensureEmbeddingsReady(): Promise<void> {
    let context = this.hostContext()
    let filesDir = context.filesDir
    await prepareCapabilityEmbeddings(context)
    let sdkPromise = ensureSdkEmbeddings(filesDir, context.resourceManager)
    let intentPromise = ensureIntentEmbeddings(filesDir, context.resourceManager)
    let uiPromise = ensureUiEmbeddings(filesDir)
    if (benchmarkRequested()) {
      await sdkPromise
      await intentPromise
      await runSearchBenchmark()
    }
    let search = sdkSearchRequested()
    if (search !== null) {
      await sdkPromise
      await runSdkSearchProbe(search)
    }
    if (uiEvalRequested()) {
      await uiPromise
      await runUiEval(context.resourceManager)
    }
    if (uiAbRequested()) {
      await uiPromise
      await runUiAb(context.resourceManager)
    }
    if (sdkEvalRequested()) {
      await sdkPromise
      await runSdkEval(context.resourceManager)
    }
  }

  private resetRunMetrics(): void {
    this.attempt = 1
    this.attempts = []
    this.totalMs = 0
    this.sideCalls = []
    this.stages = []
    this.services = []
    this.leftOut = []
    resetServiceHealth()
    this.troubleNote = ''
    this.tools = []
    resetToolLog()
  }

  private doGenerate(): void {
    if (this.disposed || this.prompt.trim().length === 0 || this.baseError.length > 0 || this.generating) { return }
    // Sent before the prompt and the catalogue were read: it goes when they are (aboutToAppear).
    if (!this.resourcesLoaded) { this.runOnOpen = true; return }
    if (this.compiledSource.length > 0) { this.previousSource = this.compiledSource }
    if (this.mode === MODE_SERVER) {
      if (!settings.hasServerUrl()) { this.checkServer(); return }
      this.doServerGenerate()
      return
    }
    if (this.mode === MODE_DEEPSEEK && !settings.hasApiKey()) {
      this.checkDeepSeek()
      return
    }
    if (this.mode === MODE_LOCAL && !this.modelReady) { return }
    this.prepareRequest(this.prompt.trim())
    let operation = this.beginOperation()
    this.generating = true
    this.generatedSource = ''
    this.compiled = false
    this.compileErrors = ''
    this.resetRunMetrics()
    this.serverBytecode = ''
    this.previewVbc2 = ''
    this.previewNote = ''
    this.settleQuestion(null)
    this.cancelRequested = false
    this.failedSource = ''
    this.lastTemplatePick = ''
    if (this.previousSource.length === 0) {
      this.modelWrote = false
      this.templateKinds = []
      this.compositionJson = ''
    }
    this.runId++
    this.program = new RunTotals()
    this.delta = new SourceDelta()
    this.runs = []
    this.startRun(this.prompt.trim())
    this.genStartTime = Date.now()
    logMark('gen-start', 'chars=' + this.prompt.trim().length.toString())
    let startFields: Record<string, Object> = {}
    startFields['prompt'] = this.prompt.trim()
    startFields['refining'] = this.previousSource.length > 0
    startFields['effort'] = settings.getReasoningEffort()
    trace('gen-start', startFields)
    this.lastRequest = this.prompt.trim()
    // No pre-generation intent selection step any more: find_intent_function
    // and find_sdk_function (DeepSeekEngine.ets) are looked up by the model
    // itself, mid-generation, the first time either is worth calling.
    // JevSelector.ets is unchanged and still callable; nothing here calls it.
    this.status = 'Generating (attempt 1/' + MAX_RETRIES + ')...'
    // A new screen goes through the route (agent/VeraBuildRoute.ets): the agent, then the whole screen as one hole; what
    // neither builds comes back as not built, and the model then writes the whole program.
    // Not on top of a saved program: with previousSource set this is a change to it (the model edits it).
    let route = new RouteRequest()
    route.mode = this.mode
    if (this.previousSource.length === 0 && settings.hasSelector()) {
      if (this.mode === MODE_DEEPSEEK && composeEnabled()) {
        route.agent = new AgentRequest()
        route.agent.prompt = this.prompt.trim()
      }
    }
    // A screen that shows a figure of the real world as it is now is built like any other: the plan names it a live figure and
    // the live_figure section fetches it (LiveBlock.ets).
    if (route.agent !== null) {
      this.tryRoute(this.prompt.trim(), route, operation)
      return
    }
    this.startAttemptOne(this.prompt.trim(), operation)
  }

  private async tryRoute(userPrompt: string, route: RouteRequest, operation: OperationController): Promise<void> {
    if (this.disposed || operation.isCancelled()) { return }
    let run = this.runId
    this.metricTotals.partial = true
    let host = appAgentHost((s: string): void => { if (run === this.runId) { this.status = s } }, (vbc2: string): void => {
      if (run !== this.runId || this.cancelRequested) { return }
      this.previewVbc2 = vbc2
      this.previewNote = 'Sketching the screen...'
    }, (): boolean => run !== this.runId || this.cancelRequested, this.promptTemplate, this.surfaceGuide, operation)
    host.worldGuide = this.worldGuide
    host.ask = (question: AgentQuestion): Promise<PersonAnswer> => this.askPerson(question, run, operation)
    let outcome: RouteOutcome
    try {
      outcome = await this.metricWork(run, (): Promise<RouteOutcome> => buildScreen(route, host))
    } catch (e) {
      if (run !== this.runId || operation.isCancelled()) { return }
      throw (e as Error)
    }
    if (run !== this.runId || operation.isCancelled()) { return }
    if (outcome.kind === OUTCOME_CANCELLED) {
      this.metricTotals.partial = true
      this.finishMetrics(run)
      return
    }
    if (outcome.agent !== null) {
      this.traceAgent(outcome.agent!)
      this.stages = this.stages.concat(outcome.agent!.stages)
    }
    if (outcome.kind === OUTCOME_AGENT) {
      this.showAgent(outcome.agent!)
      return
    }
    // Nothing built it: no generation from scratch, the reason is shown, to be seen and fixed.
    this.totalMs = Date.now() - this.genStartTime
    this.generating = false
    this.status = 'Not built (' + (this.totalMs / 1000).toFixed(1) + ' s): ' + outcome.reason
    if (this.previewVbc2.length > 0) { this.previewNote = 'Preview from the sketch only — the app was not built' }
    this.traceEnd('not built: ' + outcome.reason)
    this.finishMetrics(run)
  }

  private traceAgent(result: AgentResult): void {
    let composed: ComposeResult = result.composed
    if (composed.source.length > 0) { traceCompile('compose', 0, composed.source, result.errors) }
    let fields: Record<string, Object> = {}
    fields['served'] = result.vbc2.length > 0
    fields['note'] = result.note
    fields['sketchMs'] = composed.sketchMs
    fields['firstPreviewMs'] = result.firstPreviewMs
    fields['previews'] = result.previews
    fields['jevMs'] = composed.jevMs
    fields['ms'] = result.ms
    fields['sketch'] = composed.sketch
    fields['answers'] = composed.answers
    fields['source'] = composed.source
    trace('compose', fields)
    console.info('VERA-COMPOSE ' + (result.vbc2.length > 0 ? 'served' : 'fell through') + ' ' + result.note)
  }

  private showAgent(result: AgentResult): void {
    let hadProgram = this.compiledVbc2.length > 0
    let composed: ComposeResult = result.composed
    this.generatedSource = result.source
    this.compiledSource = result.source
    this.compiledVbc2 = result.vbc2
    this.acceptRequest()
    // The record of the screen, when it rebuilds exactly this program: a request to add, remove or move a section is then
    // answered without the model (tryStructuralEdit); with none, such a request is refined by the model as before.
    this.compositionJson = result.record !== null ? compositionToJson(result.record!) : ''
    if (result.record !== null) { this.templateKinds = result.record!.kinds() }
    this.compiled = true
    this.compileErrors = ''
    this.composerOpen = false
    this.tab = TAB_PREVIEW
    this.generating = false
    this.totalMs = Date.now() - this.genStartTime
    // The time the person took to answer a question of the plan is theirs: said apart, not counted as the app's.
    let waited = result.waitedMs()
    // Where the time went (the plan, the choosing, the sketch) is on the Metrics tab, not in this line.
    this.status = 'Ready in ' + ((this.totalMs - waited) / 1000).toFixed(1) + ' s' +
      (waited > 0 ? ' (and ' + (waited / 1000).toFixed(1) + ' s waiting for your answer)' : '') +
      (composed.dropped.length > 0 ? ' · ' + composed.dropped.length.toString() + (composed.dropped.length === 1 ? ' part' : ' parts') +
        ' not included (Metrics)' : '')
    // Which, and why, on the Metrics tab: the line has room for the count only, and only the count left a person missing a figure
    // with no way to see which (review of #46).
    this.leftOut = composed.dropped.slice()
    let endFields: Record<string, Object> = {}
    endFields['ok'] = true
    endFields['attempt'] = 0
    endFields['totalMs'] = this.totalMs
    endFields['waitedMs'] = waited
    endFields['via'] = 'compose'
    endFields['dropped'] = composed.dropped.join('; ')
    trace('gen-end', endFields)
    this.closeRun(true, 0)
    if (!hadProgram) { this.openWhole() }
  }

  /**
   * Chooses which std/ui components the system prompt describes for this
   * request, then makes the first attempt. Only DeepSeek mode selects; every
   * other mode, and any failure on the way (no extraction, embeddings not
   * ready), describes the whole catalogue. The choice is made once and kept for
   * the retries, which only rewrite the user prompt.
   */
  private async startAttemptOne(userPrompt: string, operation: OperationController,
      label: string = 'Generating', plan: string = ''): Promise<void> {
    if (this.disposed || operation.isCancelled()) { return }
    let run = this.runId
    this.systemPrompt = this.promptTemplate
    this.uiSelected = []
    if (UI_SELECT_MODE !== UI_SELECT_FULL && this.mode === MODE_DEEPSEEK && this.skillText.length > 0) {
      this.status = 'Choosing UI components...'
      let selectStartedAt = Date.now()
      let selected = await this.metricWork(run,
        (): Promise<Set<string> | null> => selectUiForPrompt(UI_SELECT_MODE, userPrompt, this.previousSource))
      logStep('ui-select', selectStartedAt, 'mode=' + UI_SELECT_MODE)
      if (run !== this.runId || this.cancelRequested || operation.isCancelled()) { return }
      if (selected === null) {
        console.info('VERA-UI-SELECT fallback to the whole catalogue')
      } else {
        let names: string[] = []
        selected.forEach((n: string) => { names.push(n) })
        this.uiSelected = names
        this.systemPrompt = this.skillText
          .replace('{{UI_CATALOG}}', describeCatalogForPrompt(selected))
          .replace('{{UI_TOOL_NOTE}}\n', UI_TOOL_NOTE)
        let uiFields: Record<string, Object> = {}
        uiFields['mode'] = UI_SELECT_MODE
        uiFields['described'] = names
        uiFields['promptChars'] = this.systemPrompt.length
        uiFields['fullChars'] = this.promptTemplate.length
        trace('ui-select', uiFields)
        console.info('VERA-UI-SELECT mode=' + UI_SELECT_MODE + ' described=' + names.length.toString() +
          ' promptChars=' + this.systemPrompt.length.toString() + ' fullChars=' + this.promptTemplate.length.toString())
      }
    }
    this.status = label + ' (attempt 1/' + MAX_RETRIES + ')...'
    let history = this.modelRequestHistory()
    let contextPrompt = history.length > 0 ?
      'Version request history:\n' + history + '\n\nCurrent change request:\n' + userPrompt : userPrompt
    this.runAttempt(plan.length > 0 ? contextPrompt + '\n\n' + plan : contextPrompt, '', operation)
  }

  private async doServerGenerate(ask: string = ''): Promise<void> {
    let submitted = ask.length > 0 ? ask : this.prompt.trim()
    this.prepareRequest(submitted)
    let operation = this.beginOperation()
    this.cancelRequested = false
    let run = ++this.runId
    this.generating = true
    this.generatedSource = ''
    this.compiled = false
    this.compileErrors = ''
    this.resetRunMetrics()
    this.serverBytecode = ''
    this.program = new RunTotals()
    this.delta = new SourceDelta()
    this.runs = []
    this.startRun(submitted)
    this.genStartTime = Date.now()
    this.lastRequest = submitted
    this.status = this.previousSource.length > 0 ? 'Server refining...' : 'Server generating...'

    let metrics = new AttemptMetrics()
    metrics.attempt = 1
    this.beginMetricAttempt(run)
    let client = http.createHttp()
    let clientDestroyed = false
    let destroyClient = (): void => {
      if (clientDestroyed) { return }
      clientDestroyed = true
      client.destroy()
    }
    this.activeServerAbortRun = run
    this.activeServerAbort = destroyClient
    let unsubscribe = operation.onCancel(destroyClient)
    try {
      let genStart = Date.now()
      // Refinement: send the base version's source so the server can edit it
      // instead of regenerating from scratch.
      let requested = this.pendingHistory + (this.makeWidget ? '\n\n' + widgetRefinementPrompt() : '')
      let requestBody: string = requested
      let contentType: string = 'text/plain; charset=utf-8'
      if (this.previousSource.length > 0) {
        let refine = new RefineRequest()
        refine.prompt = requested
        refine.previousSource = this.previousSource
        requestBody = JSON.stringify(refine)
        contentType = 'application/json'
      }
      let resp = await client.request(serverUrl() + '/compile', {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': contentType },
        extraData: requestBody,
        connectTimeout: 10000,
        readTimeout: 180000
      })
      if (run !== this.runId || this.cancelRequested) { return }
      metrics.genMs = Date.now() - genStart

      if (resp.responseCode === 200) {
        let body = resp.result as string
        let decoded = decodeServerResponse(body)
        if (decoded.source.trim().length === 0 || decoded.bytecode.trim().length === 0) {
          this.status = 'Server result has no source/bytecode pair; the previous successful result is unchanged'
          this.generating = false
          this.totalMs = Date.now() - this.genStartTime
          return
        }
        this.generatedSource = decoded.source
        if (this.makeWidget) {
          // A widget is spliced into the saved program here, so the server's bytecode is not the program's: it is compiled
          // and held to the widget's checks on the phone. Any other server result is taken as the server built it.
          decoded.source = spliceWidget(this.widgetBase, decoded.source)
          this.generatedSource = decoded.source
          let local = compileVeraSource(decoded.source)
          let validation = smokeRun(local)
          if (validation.length === 0) { validation = await validateWidgetOffMain(this.widgetBase, decoded.source, local.vbc2) }
          if (validation.length > 0) { throw new Error(validation) }
          decoded.bytecode = local.vbc2
        }
        this.serverBytecode = decoded.bytecode
        this.compiledVbc2 = decoded.bytecode
        this.compiledSource = decoded.source
        this.compositionJson = ''
        this.modelWrote = true
        this.acceptRequest()
        this.getUIContext().animateTo({ duration: 250, curve: Curve.EaseInOut }, () => { this.composerOpen = false })
        this.tab = this.makeWidget ? TAB_WIDGET : TAB_PREVIEW
        this.compiled = true
        this.compileErrors = ''
        if (this.makeWidget) { this.widgetFresh = false }
        metrics.success = true
        this.status = 'Server compiled successfully'
      } else {
        let body = resp.result as string
        try {
          let errObj = JSON.parse(body) as Record<string, Object>
          let diags = errObj['diagnostics'] as Object[]
          if (diags !== null && diags !== undefined && diags.length > 0) {
            let firstDiag = diags[0] as Record<string, Object>
            let msg = (firstDiag['message'] as string) || ''
            let generatedSrc = (firstDiag['generatedSource'] as string) || ''
            if (generatedSrc.length > 0) {
              this.generatedSource = generatedSrc
            }
            this.compileErrors = msg
          } else {
            this.compileErrors = 'Server error: HTTP ' + resp.responseCode
          }
        } catch (_e) {
          this.compileErrors = 'Server error: HTTP ' + resp.responseCode + ' — ' + body.substring(0, 200)
        }
        this.status = 'Server generation failed'
      }
    } catch (e) {
      if (run !== this.runId || this.cancelRequested) { return }
      this.compileErrors = 'Request failed: ' + (e as Error).message
      this.status = 'Server unreachable'
    } finally {
      // Do not clear a newer request's abort hook if Stop was followed quickly
      // by another generation before this request's promise settled.
      if (this.activeServerAbortRun === run) {
        this.activeServerAbort = null
        this.activeServerAbortRun = -1
      }
      unsubscribe()
      destroyClient()
      if (run === this.runId) { this.finishMetrics(run) }
    }

    this.attempts = [metrics]
    this.totalMs = Date.now() - this.genStartTime
    this.generating = false
  }

  /**
   * The one place that knows which model is behind the loop. Everything after
   * it -- compile, collect diagnostics, retry -- is identical for both.
   */
  private async callModel(request: GenerateRequest, onToken: (token: string) => void, run: number,
      operation: OperationController): Promise<GenerateResult> {
    throwIfCancelled(operation)
    if (this.mode === MODE_DEEPSEEK) {
      // Initial generation, refinement, and retries share reasoning and output settings.
      await ensureCapabilities(this.hostContext())
      if (run !== this.runId || this.cancelRequested || operation.isCancelled()) { return new GenerateResult() }
      deepseek.setThinking(true)
      request.maxTokens = DEEPSEEK_GENERATION_MAX_TOKENS
      return deepseek.generate(request, onToken, undefined, operation)
    }
    let unsubscribe = operation.onCancel((): void => { engine.stop() })
    try {
      return engine.generate(request, onToken)
    } finally {
      unsubscribe()
    }
  }

  private async runAttempt(userPrompt: string, errorFeedback: string, operation: OperationController): Promise<void> {
    if (operation.isCancelled()) { return }
    let run = this.runId
    this.generatedSource = ''
    let metrics = new AttemptMetrics()
    metrics.attempt = this.attempt

    let request = new GenerateRequest()
    request.systemPrompt = this.systemPrompt + (this.makeWidget ? '\n\n' + widgetRefinementPrompt() : '')
    request.uiSelected = this.uiSelected
    request.uiTool = this.uiSelected.length > 0
    request.grammar = this.grammar
    request.maxTokens = 2048
    request.temperature = 0.2

    if (errorFeedback.length === 0) { this.repairByEdit = true }
    // Only DeepSeek is asked for edits; the local model rewrites as before.
    let editing = errorFeedback.length > 0 && this.repairByEdit && this.mode === MODE_DEEPSEEK
    if (errorFeedback.length > 0) {
      // Hand back the program that failed, not the last one that worked: the
      // diagnostics carry line and column numbers, and they only mean
      // something against the text they were produced from. Sending the last
      // good program instead made every retry a blind rewrite -- which is how
      // three attempts in a row used to trip over the same operator.
      request.previousSource = this.failedSource
      request.repairByEdit = editing
      request.userPrompt = repairPrompt(userPrompt, errorFeedback, editing, this.failedSource)
    } else if (this.previousSource.length > 0) {
      request.previousSource = this.previousSource
      request.userPrompt = userPrompt
    } else {
      request.userPrompt = userPrompt
    }

    let genStart = Date.now()
    let firstTokenAt = 0
    let genResult: GenerateResult
    this.beginMetricAttempt(run)
    try {
      genResult = await this.metricWork(run, (): Promise<GenerateResult> => this.callModel(request, (token: string) => {
        if (run !== this.runId || this.cancelRequested || operation.isCancelled()) { return }
        if (firstTokenAt === 0) { firstTokenAt = Date.now() }
        this.generatedSource += token
      }, run, operation))
      if (run !== this.runId || operation.isCancelled()) { return }
      this.recordMetricResult(run, genResult)
      if (genResult.text.length > 0) {
        this.generatedSource = genResult.text
      }
    } catch (e) {
      if (run !== this.runId || operation.isCancelled()) { return }
      this.metricTotals.partial = true
      metrics.genMs = Date.now() - genStart
      metrics.failLayer = 'request'
      this.attempts = [...this.attempts, metrics]
      this.totalMs = Date.now() - this.genStartTime
      this.addToProgram(metrics)
      this.traceEnd('request: ' + (e as Error).message)
      this.status = 'Generation failed: ' + (e as Error).message
      this.generating = false
      this.finishMetrics(run)
      return
    }
    metrics.genMs = Date.now() - genStart
    metrics.ttftMs = firstTokenAt > 0 ? firstTokenAt - genStart : 0
    if (this.cancelRequested) {
      this.attempts = [...this.attempts, metrics]
      this.totalMs = Date.now() - this.genStartTime
      this.status = 'Stopped'
      this.generating = false
      this.metricTotals.partial = true
      this.finishMetrics(run)
      return
    }
    metrics.inputTokens = genResult.inputTokens
    metrics.outputTokens = genResult.outputTokens
    if (this.mode === MODE_DEEPSEEK) {
      metrics.cacheHitTokens = genResult.cacheHitTokens
      metrics.finishReason = genResult.finishReason
      metrics.thinking = true
      // Prefill from the engine rather than the token callback: the callback
      // only fires on visible content, so with reasoning on it would report
      // the thinking time as waiting.
      let prefill = genResult.prefillMs
      if (prefill > 0) { metrics.ttftMs = prefill }
      metrics.thinkMs = genResult.thinkMs
    }

    if (editing && this.generatedSource.trim().length > 0) {
      let repair = applyRepair(this.failedSource, this.generatedSource)
      if (repair.source.length === 0) {
        // The edits did not fit the failed source: the next attempt rewrites it
        // in full, against the same diagnostics and the same failed text.
        traceCompile('generate', this.attempt, this.generatedSource, 'edit not applied: ' + repair.error)
        metrics.failLayer = 'edit'
        this.attempts = [...this.attempts, metrics]
        this.addToProgram(metrics)
        if (this.attempt < MAX_RETRIES) {
          this.repairByEdit = false
          this.attempt++
          this.status = 'Edit did not apply, rewriting (attempt ' + this.attempt + '/' + MAX_RETRIES + ')...'
          await this.runAttempt(userPrompt, errorFeedback, operation)
        } else {
          this.totalMs = Date.now() - this.genStartTime
          this.traceEnd('compile')
          this.status = 'Compilation failed after ' + MAX_RETRIES + ' attempts'
          this.generating = false
          this.finishMetrics(run)
        }
        return
      }
      this.generatedSource = repair.source
    }

    if (this.generatedSource.trim().length === 0) {
      metrics.failLayer = 'empty'
      this.traceEnd('empty')
      this.status = 'Generation produced empty output'
      this.generating = false
      this.attempts = [...this.attempts, metrics]
      this.totalMs = Date.now() - this.genStartTime
      this.addToProgram(metrics)
      this.finishMetrics(run)
      return
    }

    // A widget is added to the saved program as it is: only the widget and what it adds are taken from the reply.
    if (this.makeWidget) { this.generatedSource = spliceWidget(this.widgetBase, this.generatedSource) }

    this.status = 'Compiling (attempt ' + this.attempt + '/' + MAX_RETRIES + ')...'
    let vbc2 = ''
    let errors = ''
    let compileStart = Date.now()
    try {
      let result = compileVeraSource(this.generatedSource.trim())
      // Run once before serving: a program that compiles can still stop at its first tap, and that is
      // repaired here like a compile error rather than found on the screen.
      let smokeStart = Date.now()
      errors = smokeRun(result)
      if (errors.length === 0 && this.makeWidget) {
        errors = await validateWidgetOffMain(this.widgetBase, this.generatedSource.trim(), result.vbc2)
      }
      logStep('smoke', smokeStart, 'src=generate attempt=' + this.attempt.toString() + ' ok=' + (errors.length === 0).toString())
      vbc2 = errors.length === 0 ? result.vbc2 : ''
    } catch (e) {
      if (e instanceof CompileError) {
        errors = e.message
      } else {
        errors = (e as Error).message
      }
    }
    if (errors.length > 0 && this.makeWidget) { errors = widgetRepairNote(errors) }
    metrics.compileMs = Date.now() - compileStart
    logStep('compile', compileStart, 'src=generate attempt=' + this.attempt.toString() + ' ok=' + (errors.length === 0).toString())
    traceCompile('generate', this.attempt, this.generatedSource.trim(), errors)

    // A program cut off at the token ceiling fails to parse somewhere near its
    // end. Saying so is worth more to the next attempt than the parse error,
    // which describes the cut rather than the mistake.
    if (errors.length > 0 && this.mode === MODE_DEEPSEEK && genResult.finishReason === 'length') {
      errors = 'The previous attempt was cut off at the output token limit before the program ended, so it did not parse. Write a shorter program.\n' + errors
    }

    if (errors.length === 0 && vbc2.length > 0) {
      let hadProgram = this.compiledVbc2.length > 0
      metrics.success = true
      this.attempts = [...this.attempts, metrics]
      this.addToProgram(metrics)
      this.totalMs = Date.now() - this.genStartTime
      // Source and bytecode are kept as a pair: the next failed attempt
      // overwrites generatedSource, and Save must not pair that broken text
      // with the bytecode of the program still on screen.
      this.delta = diffLines(this.previousSource, this.generatedSource.trim())
      let current = this.currentRun()
      if (current !== null) { current!.delta = this.delta }
      this.compiledVbc2 = vbc2
      this.compiledSource = this.generatedSource.trim()
      this.refinePrompt = ''
      this.getUIContext().animateTo({ duration: 250, curve: Curve.EaseInOut }, () => { this.composerOpen = false })
      // Only when the program first appears: yanking the pane away from
      // someone reading the source or the numbers is worse than leaving it.
      if (!hadProgram) { this.tab = TAB_PREVIEW }
      this.compiled = true
      this.compileErrors = ''
      if (this.makeWidget) { this.widgetFresh = false }
      this.modelWrote = true
      this.compositionJson = ''
      this.acceptRequest()
      this.status = 'Compiled successfully on attempt ' + this.attempt
      if (!hadProgram) { this.openWhole() }
      logMark('gen-compiled', 'attempt=' + this.attempt.toString())
      let endFields: Record<string, Object> = {}
      endFields['ok'] = true
      endFields['attempt'] = this.attempt
      endFields['totalMs'] = this.totalMs
      trace('gen-end', endFields)
      this.closeRun(false, this.attempt)
      this.generating = false
      return
    }

    metrics.failLayer = layerOf(errors)
    metrics.failCode = codeOf(errors)
    this.attempts = [...this.attempts, metrics]
    this.addToProgram(metrics)
    this.compileErrors = errors
    if (this.attempt < MAX_RETRIES) {
      // runAttempt clears generatedSource on entry, so the broken text has to
      // be kept now if the next attempt is to see it.
      this.failedSource = this.generatedSource.trim()
      // A program cut off at the limit has no end to edit; anything else is
      // repaired by edits.
      this.repairByEdit = !(this.mode === MODE_DEEPSEEK && genResult.finishReason === 'length')
      this.attempt++
      this.status = (metrics.failLayer === 'runtime' ? 'Stopped on its first run' : 'Compile failed') +
        ', retrying (attempt ' + this.attempt + '/' + MAX_RETRIES + ')...'
      await this.runAttempt(userPrompt, errors, operation)
    } else {
      this.totalMs = Date.now() - this.genStartTime
      this.generating = false
      this.traceEnd('compile')
      this.status = (metrics.failLayer === 'runtime' ? 'Still stopping on its first run' : 'Compilation failed') +
        ' after ' + MAX_RETRIES + ' attempts'
      this.finishMetrics(run)
    }
  }

  /** The trace's closing event for a generation that ended without a program. */
  private traceEnd(failure: string): void {
    let fields: Record<string, Object> = {}
    fields['ok'] = false
    fields['attempt'] = this.attempt
    fields['failure'] = failure
    trace('gen-end', fields)
    this.closeRun(false, this.attempt)
  }

  /**
   * Closes the run's figures for the Metrics tab: the model calls, the lookups and the services as they stand, and the time that
   * no stage accounts for -- the page's own work when the agent built the screen, the model's own writing when it wrote the program.
   */
  private closeRun(byAgent: boolean, attempts: number): void {
    let ms = this.totalMs > 0 ? this.totalMs : Date.now() - this.genStartTime
    this.sideCalls = deepseek.getSideCalls(this.activeOperation)
    let rest = ms - appMs(this.stages) - yourMs(this.stages)
    let stages = this.stages.slice()
    if (byAgent) {
      addStage(stages, 'Showing the screen', WHO_PHONE, rest)
    } else {
      addStage(stages, 'Model writes the program', WHO_MODEL, rest, attempts.toString() + ' attempt(s)')
    }
    this.stages = stages
    this.services = serviceNotes()
    this.troubleNote = serviceTrouble()
    this.tools = toolCalls()
  }

  private addToProgram(metrics: AttemptMetrics): void {
    this.sideCalls = deepseek.getSideCalls(this.activeOperation)
    let record = this.currentRun()
    if (record !== null) {
      record!.attempts = [...record!.attempts, metrics]
      record!.compiled = metrics.success
      this.runs = [...this.runs]
    }
    let totals = new RunTotals()
    totals.runs = this.program.runs
    totals.attempts = this.program.attempts + 1
    totals.ms = this.program.ms + metrics.genMs + metrics.compileMs
    totals.llmMs = this.program.llmMs + metrics.genMs
    totals.compileMs = this.program.compileMs + metrics.compileMs
    totals.inputTokens = this.program.inputTokens + metrics.inputTokens
    totals.cacheHitTokens = this.program.cacheHitTokens + metrics.cacheHitTokens
    totals.outputTokens = this.program.outputTokens + metrics.outputTokens
    this.program = totals
  }

  private startRun(request: string): void {
    let record = new RunRecord()
    record.request = request
    this.runs = [...this.runs, record]
    this.startRunTotals()
  }

  private currentRun(): RunRecord | null {
    return this.runs.length > 0 ? this.runs[this.runs.length - 1] : null
  }

  private startRunTotals(): void {
    let totals = new RunTotals()
    totals.runs = this.program.runs + 1
    totals.attempts = this.program.attempts
    totals.ms = this.program.ms
    totals.llmMs = this.program.llmMs
    totals.compileMs = this.program.compileMs
    totals.inputTokens = this.program.inputTokens
    totals.cacheHitTokens = this.program.cacheHitTokens
    totals.outputTokens = this.program.outputTokens
    this.program = totals
  }

  /**
   * DeepSeek's published rates for deepseek-flash, per million tokens. Peak is
   * 01:00-04:00 and 06:00-10:00 UTC on weekdays and costs twice as much. The
   * price list lives on their side, so every figure here is an estimate.
   */
  private ratePerMillion(kind: string): number {
    let now = new Date()
    let day = now.getUTCDay()
    let hour = now.getUTCHours()
    let peak = day >= 1 && day <= 5 && ((hour >= 1 && hour < 4) || (hour >= 6 && hour < 10))
    if (kind === 'cache') { return peak ? 0.006 : 0.003 }
    if (kind === 'fresh') { return peak ? 0.30 : 0.15 }
    return peak ? 1.20 : 0.60
  }

  private costOf(input: number, cached: number, output: number): number {
    let fresh = input - cached
    if (fresh < 0) { fresh = 0 }
    return (cached * this.ratePerMillion('cache') +
      fresh * this.ratePerMillion('fresh') +
      output * this.ratePerMillion('output')) / 1000000
  }

  private runCost(): number {
    return this.costOf(this.totalInputTokens(), this.totalCacheHitTokens(), this.totalOutputTokens())
  }

  private formatUsd(value: number): string {
    if (value <= 0) { return '$0' }
    if (value < 0.0001) { return '$' + value.toFixed(5) }
    if (value < 0.01) { return '$' + value.toFixed(4) }
    return '$' + value.toFixed(3)
  }

  /**
   * Output tokens over everything after the prompt was read. Reasoning tokens
   * are billed as output and take real time, so dividing by the visible
   * stream alone would report rates the model never reached.
   */
  private formatRate(metrics: AttemptMetrics): string {
    let workMs = metrics.genMs - metrics.ttftMs
    if (workMs <= 0 || metrics.outputTokens === 0) { return '' }
    return ' (' + Math.round(metrics.outputTokens * 1000 / workMs) + ' tok/s)'
  }

  private attemptVerdict(a: AttemptMetrics): string {
    if (a.success) { return a.thinking ? '✓ think' : '✓' }
    if (a.failLayer === 'request') { return '✗ request failed' }
    if (a.failLayer === 'empty') { return '✗ empty answer' }
    let verdict = '✗ ' + a.failLayer
    if (a.failCode.length > 0) { verdict += ' ' + a.failCode }
    if (a.finishReason === 'length') { verdict += ' · cut off at the token limit' }
    return verdict
  }

  private cacheLabel(): string {
    let cached = this.totalCacheHitTokens()
    if (cached === 0) { return '' }
    let percent = Math.round(cached * 100 / this.totalInputTokens())
    return ' (cached ' + cached + ' · ' + percent + '%)'
  }

  // Money only where it is actually spent and known: llama runs on the phone,
  // and what the server pays for a generation is not ours to guess.
  private programCostLabel(): string {
    if (this.mode !== MODE_DEEPSEEK) { return '' }
    return ' · ~' + this.formatUsd(
      this.costOf(this.program.inputTokens, this.program.cacheHitTokens, this.program.outputTokens))
  }

  private runVerdict(): string {
    if (this.generating) { return 'running attempt ' + this.attempt }
    if (this.compiled) { return 'compiled on attempt ' + this.attempt }
    return 'failed after ' + this.attempts.length + ' attempts'
  }

  private rateNote(a: AttemptMetrics): string {
    let workMs = a.genMs - a.ttftMs
    if (workMs <= 0 || a.outputTokens === 0) { return 'model time' }
    return Math.round(a.outputTokens * 1000 / workMs) + ' tok/s'
  }

  /** Everything except the run on screen, newest first. */
  private pastRuns(): RunRecord[] {
    let past: RunRecord[] = []
    for (let i = this.runs.length - 2; i >= 0; i--) { past.push(this.runs[i]) }
    return past
  }

  private indexOfRun(record: RunRecord): number {
    for (let i = 0; i < this.runs.length; i++) {
      if (this.runs[i] === record) { return i }
    }
    return 0
  }

  private runMs(record: RunRecord): number {
    let ms = 0
    for (let a of record.attempts) { ms += a.genMs + a.compileMs }
    return ms
  }

  private pastRunSummary(record: RunRecord): string {
    let summary = record.attempts.length + (record.attempts.length === 1 ? ' attempt · ' : ' attempts · ')
    summary += this.formatMs(this.runMs(record))
    if (this.mode === MODE_DEEPSEEK) {
      let input = 0
      let cached = 0
      let output = 0
      for (let a of record.attempts) {
        input += a.inputTokens
        cached += a.cacheHitTokens
        output += a.outputTokens
      }
      summary += ' · ~' + this.formatUsd(this.costOf(input, cached, output))
    }
    if (record.delta.measured) {
      summary += ' · +' + record.delta.added + ' −' + record.delta.removed + ' lines'
    }
    return summary
  }

  private programSpentLabel(): string {
    if (this.mode !== MODE_DEEPSEEK) { return this.formatMs(this.program.ms) }
    return '~' + this.formatUsd(
      this.costOf(this.program.inputTokens, this.program.cacheHitTokens, this.program.outputTokens))
  }

  private runHeadline(): string {
    let head = this.compiled
      ? 'compiled on attempt ' + this.attempt
      : (this.generating ? 'running' : 'failed after ' + this.attempts.length + ' attempts')
    head += ' · ' + this.formatMs(this.totalMs)
    if (this.mode === MODE_DEEPSEEK) { head += ' · ~' + this.formatUsd(this.runCost()) }
    return head
  }

  /** Wall time inside the model across this run, retries included. */
  private runLlmMs(): number {
    let ms = 0
    for (let a of this.attempts) { ms += a.genMs }
    return ms
  }

  private runCompileMs(): number {
    let ms = 0
    for (let a of this.attempts) { ms += a.compileMs }
    return ms
  }

  private writeMs(a: AttemptMetrics): number {
    let ms = a.genMs - a.ttftMs - a.thinkMs
    return ms > 0 ? ms : 0
  }

  /**
   * Over everything after the prompt was read. Reasoning tokens are billed as
   * output and take real time, so dividing by the writing phase alone would
   * report a speed the model never reached.
   */
  private speedLabel(a: AttemptMetrics): string {
    let workMs = a.genMs - a.ttftMs
    if (workMs <= 0 || a.outputTokens === 0) { return '—' }
    return Math.round(a.outputTokens * 1000 / workMs) + ' tok/s'
  }

  private attemptTiming(a: AttemptMetrics): string {
    let parts = a.ttftMs > 0 ? 'wait ' + this.formatMs(a.ttftMs) + ' · ' : ''
    if (a.thinkMs > 0) { parts += 'think ' + this.formatMs(a.thinkMs) + ' · ' }
    parts += 'gen ' + this.formatMs(a.genMs) + this.formatRate(a)
    if (a.compileMs > 0) { parts += ' · compile ' + this.formatMs(a.compileMs) }
    if (a.inputTokens > 0 || a.outputTokens > 0) {
      parts += ' · ' + a.inputTokens + '→' + a.outputTokens
    }
    return parts
  }

  private hasResult(): boolean {
    return this.compiledVbc2.length > 0 && this.compiledSource.length > 0
  }

  /**
   * Sends the change request together with the program currently on screen.
   * The existing refine path does the rest: previousSource goes over as the
   * assistant's own last turn, so the model edits that program instead of
   * writing a new one, and a failed attempt still gets the three compiler
   * retries.
   */
  private doRefine(): void {
    let ask = this.refinePrompt.trim()
    if (this.disposed || ask.length === 0 || this.compiledSource.length === 0 || this.generating || this.baseError.length > 0) { return }
    // What the person typed is what the widget shows; the instructions for a widget are the system prompt's (widgetRefinementPrompt).
    if (this.makeWidget) { ask = WIDGET_ASK + ask }
    // What the person typed into the preview is kept through the refine. The widget screen draws no app preview: what it
    // carries is the saved data it was opened with.
    if (!this.makeWidget) {
      if (!this.previewController.flushAndSnapshot()) { return }
      this.carriedState = this.liveState
    }
    // A change that only adds, removes, replaces or moves a block of a composed screen is made on its
    // record, with no model rewrite; anything else, and any step that does not hold, refines as before.
    // Make widget is not a structural edit: only the model, told what a widget may add, writes it.
    if (!this.makeWidget && this.compositionJson.length > 0 && this.mode === MODE_DEEPSEEK && templateSelectEnabled() &&
        settings.hasSelector()) {
      this.tryStructuralEdit(ask)
      return
    }
    this.refineWithModel(ask)
  }

  private async tryStructuralEdit(ask: string): Promise<void> {
    let record: Composition | null = compositionFromJson(this.compositionJson)
    if (record === null) {
      this.compositionJson = ''
      this.refineWithModel(ask)
      return
    }
    this.prepareRequest(ask)
    let operation = this.beginOperation()
    this.generating = true
    this.cancelRequested = false
    let run = ++this.runId
    this.genStartTime = Date.now()
    this.metricTotals.partial = true
    this.status = 'Checking whether this changes the structure...'
    let result: EditResult
    try {
      result = await this.metricWork(run, (): Promise<EditResult> => editComposition(ask, record!, this.mode,
        async (request: string, c: Composition): Promise<CompositionEdit> => {
          throwIfCancelled(operation)
          let edit = await selectEdit(request, c, settings.getSelectorKey(), operation)
          throwIfCancelled(operation)
          return edit
        }, operation))
    } catch (e) {
      if (run !== this.runId || operation.isCancelled()) { return }
      this.status = 'Could not change the structure: ' + (e as Error).message
      this.generating = false
      return
    }
    // Stop bumps runId too, and has already said Stopped.
    if (run !== this.runId || operation.isCancelled()) { return }
    this.lastTemplatePick = result.note
    if (!result.applied || result.composition === null) {
      this.refineWithModel(ask, operation)
      return
    }
    this.startRun(ask)
    this.lastRequest = ask
    this.previousSource = this.compiledSource
    this.generatedSource = result.source
    this.compiledSource = result.source
    this.compiledVbc2 = result.vbc2
    this.compositionJson = compositionToJson(result.composition!)
    this.templateKinds = result.composition!.kinds()
    this.acceptRequest()
    this.compiled = true
    this.compileErrors = ''
    this.generating = false
    this.refinePrompt = ''
    this.totalMs = Date.now() - this.genStartTime
    this.status = 'Changed the structure: ' + result.note
  }

  private refineWithModel(ask: string, continuingOperation?: OperationController): void {
    let continuing = continuingOperation !== undefined
    if (continuingOperation !== undefined && continuingOperation.isCancelled()) { return }
    // Refine from the last program that compiled, not from generatedSource --
    // a failed attempt leaves its broken text in there.
    this.previousSource = this.compiledSource
    // A game or a scene is changed by edits, with its guide, and played before it is served (AgentSurfaceEdit.ets).
    if (!this.makeWidget && this.mode === MODE_DEEPSEEK && surfaceRouteEnabled() && drawsSurface(this.compiledSource)) {
      this.editSurface(ask, continuingOperation)
      return
    }
    // A widget is written on its own and spliced into the program, which is not written again (AgentWidget.ets).
    if (this.makeWidget && this.mode === MODE_DEEPSEEK) {
      this.makeWidgetAlone(ask)
      return
    }
    if (this.mode === MODE_SERVER) {
      if (!settings.hasServerUrl()) { this.checkServer(); return }
      this.doServerGenerate(ask)
      return
    }
    if (!continuing) { this.prepareRequest(ask) }
    let operation = continuingOperation !== undefined ? continuingOperation : this.beginOperation()
    this.generating = true
    this.compiled = false
    this.compileErrors = ''
    this.resetRunMetrics()
    this.serverBytecode = ''
    this.cancelRequested = false
    if (!continuing) { this.runId++ }
    this.failedSource = ''
    this.delta = new SourceDelta()
    this.startRun(ask)
    if (!continuing) { this.genStartTime = Date.now() }
    this.lastRequest = ask
    this.status = 'Refining (attempt 1/' + MAX_RETRIES + ')...'
    this.startAttemptOne(ask, operation, 'Refining')
  }

  /**
   * A change to a program that draws on a ui.Surface: edits made with the guide it was written with, played before they
   * are served. One that does not pass leaves the program on the screen as it was, saying why.
   */
  private async editSurface(ask: string, continuingOperation?: OperationController): Promise<void> {
    let continuing = continuingOperation !== undefined
    if (continuingOperation !== undefined && continuingOperation.isCancelled()) { return }
    if (!continuing) { this.prepareRequest(ask) }
    let operation = continuingOperation !== undefined ? continuingOperation : this.beginOperation()
    this.generating = true
    this.cancelRequested = false
    let run = continuing ? this.runId : ++this.runId
    if (!continuing) { this.genStartTime = Date.now() }
    this.metricTotals.partial = true
    let host = appAgentHost((text: string): void => { if (run === this.runId) { this.status = text } },
      (_vbc2: string): void => {}, (): boolean => run !== this.runId || this.cancelRequested,
      this.promptTemplate, this.surfaceGuide, operation)
    host.worldGuide = this.worldGuide
    let base = this.compiledSource
    let made: SurfaceEdit
    try {
      made = await this.metricWork(run,
        (): Promise<SurfaceEdit> => editSurfaceProgram(base, ask, this.requestHistory, host))
    } catch (e) {
      if (run !== this.runId || operation.isCancelled()) { return }
      throw (e as Error)
    }
    if (run !== this.runId || operation.isCancelled()) { return }
    let fields: Record<string, Object> = {}
    fields['change'] = ask
    fields['game'] = made.game
    fields['attempts'] = made.attempts
    fields['rounds'] = made.rounds
    fields['edits'] = made.edits
    fields['ms'] = made.ms
    fields['failed'] = made.failed
    fields['lines'] = base.split('\n').length
    fields['source'] = made.source
    trace('surface-edit', fields)
    this.generating = false
    this.totalMs = Date.now() - this.genStartTime
    if (made.source.length === 0) {
      this.metricTotals.partial = true
      this.finishMetrics(run)
      this.status = 'Could not make this change, the app is as it was: ' + made.failed
      return
    }
    this.startRun(ask)
    this.lastRequest = ask
    this.previousSource = base
    this.generatedSource = made.source
    this.compiledSource = made.source
    this.compiledVbc2 = made.vbc2
    // The program is no longer what the record rebuilds.
    this.compositionJson = ''
    this.modelWrote = true
    this.acceptRequest()
    this.compiled = true
    this.compileErrors = ''
    this.refinePrompt = ''
    this.status = 'Changed in ' + (this.totalMs / 1000).toFixed(1) + ' s' +
      (made.edits > 0 ? ' by ' + made.edits.toString() + ' edit(s)' : ', written again') +
      (made.rounds > 0 ? ', ' + made.rounds.toString() + ' repair round(s)' : '') + ', played before serving'
  }

  /**
   * Make widget: only the widget is written, and spliced into the program on the screen, which stays as it is. One that
   * does not pass leaves the program as it was, saying why.
   */
  private async makeWidgetAlone(ask: string): Promise<void> {
    this.prepareRequest(ask)
    this.generating = true
    this.cancelRequested = false
    let run = ++this.runId
    this.genStartTime = Date.now()
    this.metricTotals.partial = true
    let host = appAgentHost((text: string): void => { if (run === this.runId) { this.status = text } },
      (_vbc2: string): void => {}, (): boolean => run !== this.runId || this.cancelRequested, this.promptTemplate)
    // Redo: neither the old widget nor what it was asked to show goes to the model, or it makes the same one again.
    let base = this.widgetFresh ? withoutWidget(this.compiledSource) : this.compiledSource
    let madeFor = this.modelRequestHistory()
    console.info('VERA-WIDGET ' + (this.widgetFresh ? 'redo' : 'refine') + ' base widget=' + hasWidgetFunction(base).toString() +
      ' history widget asks=' + (madeFor.split(WIDGET_ASK).length - 1).toString())
    let shows = ask.startsWith(WIDGET_ASK) ? ask.substring(WIDGET_ASK.length) : ask
    let made: WidgetWrite = await this.metricWork(run,
      (): Promise<WidgetWrite> => writeWidget(base, shows, madeFor, this.carriedState, host))
    if (run !== this.runId) { return }
    let fields: Record<string, Object> = {}
    fields['shows'] = shows
    fields['attempts'] = made.attempts
    fields['ms'] = made.ms
    fields['failed'] = made.failed
    fields['written'] = made.written
    trace('widget-write', fields)
    this.generating = false
    this.totalMs = Date.now() - this.genStartTime
    if (made.source.length === 0) {
      this.metricTotals.partial = true
      this.finishMetrics(run)
      this.status = 'Could not make this widget, the app is as it was'
      this.widgetFailure = made.failed.length > 0 ? made.failed : 'No answer passed the checks.'
      return
    }
    this.startRun(ask)
    this.lastRequest = ask
    this.previousSource = base
    this.generatedSource = made.source
    this.compiledSource = made.source
    this.compiledVbc2 = made.vbc2
    this.widgetPassed = made.vbc2 + '\u0000' + this.carriedState
    this.compositionJson = ''
    this.modelWrote = true
    this.acceptRequest()
    this.compiled = true
    this.compileErrors = ''
    this.refinePrompt = ''
    this.widgetSeed = this.liveState.length > 0 ? this.liveState : this.carriedState
    this.widgetFresh = false
    this.tab = TAB_WIDGET
    this.status = 'Widget written in ' + (this.totalMs / 1000).toFixed(1) + ' s' +
      (made.attempts > 1 ? ', on answer ' + made.attempts.toString() : '')
  }

  /** The open question goes with its default: stopping or starting again must not leave the agent waiting. */
  private settleQuestion(given: PersonAnswer): void {
    let answer = this.answerQuestion
    this.answerQuestion = null
    this.questionText = ''
    this.questionOptions = []
    if (answer !== null) { answer(given) }
  }

  /** Puts the agent's question on the screen; the promise settles with the person's tap. */
  private askPerson(question: AgentQuestion, run: number, operation: OperationController): Promise<PersonAnswer> {
    if (this.disposed || this.cancelRequested || run !== this.runId || operation.isCancelled()) {
      return Promise.resolve(null)
    }
    this.settleQuestion(null)
    return new Promise<PersonAnswer>((resolve: (answer: PersonAnswer) => void) => {
      this.questionText = question.text
      this.questionOptions = question.options
      this.questionFallback = question.fallback
      this.answerQuestion = resolve
    })
  }

  private stopGeneration(): void {
    if (!this.generating) { return }
    this.metricTotals.partial = true
    this.finishMetrics(this.runId)
    if (this.metricPendingRuns.has(this.runId)) { this.metricStaleRuns.add(this.runId) }
    this.settleQuestion(null)
    this.cancelRequested = true
    this.runId++
    // Abort the server transport as well as fencing its eventual result. The
    // request's finally block owns the matching cleanup and is idempotent.
    let abortServer = this.activeServerAbort
    this.activeServerAbort = null
    this.activeServerAbortRun = -1
    if (abortServer !== null) {
      try { abortServer() } catch (e) {
        console.warn('VERA server request abort failed: ' + (e as Error).message)
      }
    }
    this.activeOperation.cancel()
    this.generating = false
    this.totalMs = Date.now() - this.genStartTime
    this.status = 'Stopped'
  }

  /** Save: a new app is named first, an app that already exists takes the result as its next version. */
  private doSave(): void {
    if (this.disposed || this.generating || this.compiledSource.length === 0 || !this.hasResult()) { return }
    if (this.projectId.length === 0) {
      this.saveName = suggestAppName(this.compiledSource, this.acceptedRequest)
      let icon = suggestAppIcon(this.saveName, this.acceptedRequest)
      this.saveIcon = icon.length > 0 && APP_ICONS.indexOf(icon) >= 0 ? icon : DEFAULT_APP_ICON
      this.iconsOpen = false
      this.naming = true
      return
    }
    if (this.makeWidget) {
      if (!this.widgetChecking) { void this.saveWidget() }
      return
    }
    if (this.commitSave()) { this.afterSave() } else { this.leaveAfterSave = false; this.widgetAfterSave = false }
  }

  /** Save for a widget: its checks first, off the UI thread when what they found at Generate no longer holds (checkWidgetSave). */
  private async saveWidget(): Promise<void> {
    if (await this.checkWidgetSave() && this.commitSave()) { this.afterSave() } else { this.leaveAfterSave = false; this.widgetAfterSave = false }
  }

  /**
   * The state a widget is saved with: the base version's saved state, read at Save, not at Generate, so widget/app taps during
   * generation are not lost. null when the app changed under the widget (status says so).
   */
  private widgetSaveState(): string | null {
    let base = store.getVersion(this.projectId, this.baseVersionId)
    let latest = store.getLatestVersion(this.projectId)
    if (base === null || latest === null || latest.id !== base.id || this.compiledVbc2.length === 0) {
      this.status = 'The app changed while this widget was being made. Make the widget again.'
      return null
    }
    return store.loadState(this.projectId, base.id, veraStateStamp(base.vbc2))
  }

  /**
   * Before a widget is saved: the card's checks for the state it is saved with, in a TaskPool worker (WidgetCheckTask) when the
   * ones made at Generate were for another state -- a tap on the app or the card meanwhile. They play every tap to rest, which
   * for a game that never rests froze the UI thread. What passes is remembered (widgetPassed), so commitSave finds it.
   */
  private async checkWidgetSave(): Promise<boolean> {
    if (!this.makeWidget) { return true }
    if (this.widgetChecking || this.disposed || this.generating || this.compiledSource.length === 0 || !this.hasResult()) { return false }
    let preserved = this.widgetSaveState()
    if (preserved === null) { return false }
    let key = this.compiledVbc2 + '\u0000' + preserved
    if (this.widgetPassed === key || widgetRefinementError(this.widgetBase, this.compiledSource).length > 0) { return true }
    this.widgetChecking = true
    this.status = 'Checking the widget...'
    try {
      let validation = await validateWidgetOffMain(this.widgetBase, this.compiledSource, this.compiledVbc2, preserved)
      if (this.disposed) { return false }
      if (validation.length > 0) { this.compileErrors = validation; this.status = 'Widget not saved'; return false }
      this.widgetPassed = key
      return true
    } finally {
      this.widgetChecking = false
    }
  }

  /**
   * Widget, from the app on screen: the app is kept first (a new one is named, a changed one becomes its next version),
   * since the card on the home screen draws a saved version; then the widget screen opens on it. One tap, with the name
   * asked for if it has none, where Save and then Make widget were two.
   */
  private startWidget(): void {
    if (this.disposed || this.generating || !this.hasResult() || this.makeWidget) { return }
    let refused = appUsesWidgetError(this.compiledSource)
    if (refused.length > 0) {
      try { this.getUIContext().getPromptAction().showToast({ message: 'A widget cannot be added to this app.' }) } catch (e) {
        console.error('Show widget toast failed: ' + (e as Error).message)
      }
      return
    }
    this.widgetOffer = false
    if (this.projectId.length > 0 && this.isSaved()) { this.openWidgetFromOffer(); return }
    this.widgetAfterSave = true
    this.doSave()
  }

  /** The name was confirmed: the project is made now, with the default picture, and the result is its first version. */
  private confirmName(): void {
    if (this.disposed || !this.naming || this.generating || !this.hasResult()) { return }
    let name = this.saveName.trim()
    if (name.length === 0) { return }
    let project = store.createProject(name, this.saveIcon)
    this.projectId = project.id
    this.naming = false
    if (this.commitSave()) {
      // A new app, just saved: the moment to say it can live on the home screen too.
      this.widgetOffer = !this.leaveAfterSave && !this.widgetAfterSave && !hasWidgetFunction(this.compiledSource) &&
        appUsesWidgetError(this.compiledSource).length === 0
      this.afterSave()
    } else { this.leaveAfterSave = false; this.widgetAfterSave = false }
  }

  private cancelName(): void {
    this.naming = false
    this.leaveAfterSave = false
    this.widgetAfterSave = false
  }

  private afterSave(): void {
    if (this.widgetAfterSave) {
      this.widgetAfterSave = false
      this.openWidgetFromOffer()
      return
    }
    if (this.leaveAfterSave) {
      this.leaveAfterSave = false
      this.close()
    }
  }

  private close(): void {
    if (this.disposed || this.closing) { return }
    this.closing = true
    this.pathStack.pop()
  }

  /** A result that no version holds yet: the one thing Save can keep. */
  private hasUnsavedResult(): boolean {
    return this.hasResult() && !this.isSaved()
  }

  /**
   * Whether leaving would throw something away: an unsaved result, a request typed into either box, or
   * a generation still running. A request typed is work done, even if nothing was generated from it.
   */
  private hasUnsavedWork(): boolean {
    return this.hasUnsavedResult() || this.draft.trim().length > 0 || this.generating
  }

  /**
   * Back with work that was never saved asks first, instead of dropping it. A screen with nothing on it,
   * or with everything saved, goes straight back.
   */
  private handleBack(): boolean {
    if (this.closing) { return false }
    // The naming window is on top: Back closes it and keeps the result, instead of leaving the page with it.
    if (this.naming) { this.cancelName(); return true }
    if (this.leaving) { this.leaving = false; return true }
    // Through the same way out as the button, so what was typed into the program goes with it.
    if (this.fullscreen) { this.setFullscreen(false); return true }
    if (this.hasUnsavedWork()) {
      this.leaving = true
      return true
    }
    return false
  }

  private leaveSave(): void {
    this.leaving = false
    if (this.generating) { this.stopGeneration() }
    this.leaveAfterSave = true
    this.doSave()
  }

  /** Whether the result was saved: a widget that does not keep the app as it was is refused. */
  private commitSave(): boolean {
    if (this.disposed || this.generating || this.compiledSource.length === 0 || !this.hasResult()) { return false }
    let note = this.makeWidget && this.requestLabel.length > 0 ? WIDGET_ASK + this.requestLabel : this.acceptedRequest
    if (note.length > 100) { note = note.substring(0, 100) + '...' }
    let preserved = ''
    if (this.makeWidget) {
      let state = this.widgetSaveState()
      if (state === null) { return false }
      preserved = state
      // The card's checks ran for this bytecode and this state (checkWidgetSave, or at Generate): only that the app around the
      // widget was kept is checked again (cheap). They are never run here: on the UI thread they froze the app.
      let preservation = widgetRefinementError(this.widgetBase, this.compiledSource)
      if (preservation.length > 0) { this.compileErrors = preservation; this.status = 'Widget not saved'; return false }
      if (this.widgetPassed !== this.compiledVbc2 + '\u0000' + preserved) {
        this.status = 'The app changed while the widget was checked. Save again.'
        return false
      }
    }
    let widgetLost = !this.makeWidget && this.keepWidget()
    let saved: Version
    try {
      saved = store.createVersion(this.projectId, this.compiledSource, this.compiledVbc2, note,
        this.requestHistory, this.acceptedOrigin, this.acceptedComposition, this.acceptedRequest, this.baseVersionId,
        this.acceptedMetrics, preserved, veraStateStamp(this.compiledVbc2))
    } catch (e) { this.status = 'Save failed: ' + (e as Error).message; return false }
    // Stay here: the next change is a refinement of what was just saved, and the next Save its own version.
    this.baseVersionId = saved.id
    if (this.makeWidget) { this.widgetBase = this.compiledSource }
    this.baseVersionNumber = this.nextVersionNumber
    this.nextVersionNumber = this.versionCount() + 1
    this.savedVbc2 = this.compiledVbc2
    this.status = 'Saved as version ' + this.baseVersionNumber.toString() +
      (widgetLost ? '. It has no widget: your home-screen card shows "Open app"' : '')
    refreshForms()
    try {
      this.getUIContext().getPromptAction().showToast({ message: this.status })
    } catch (e) {
      console.error('Show save toast failed: ' + (e as Error).message)
    }
    return true
  }

  /**
   * A change written without the widget the base had, while a card shows it: the base's widget is put back (carryWidget),
   * if the program still compiles and runs with it. Whether the widget is lost all the same.
   */
  private keepWidget(): boolean {
    let base = this.baseVersionId.length > 0 ? store.getVersion(this.projectId, this.baseVersionId) : null
    if (base === null || !hasWidgetFunction(base.source) || hasWidgetFunction(this.compiledSource)) { return false }
    if (this.readWidgetCards() === 0) { return false }
    let next = carryWidget(this.compiledSource, base.source)
    try {
      let compiled = compileVeraSource(next)
      if (smokeRun(compiled).length === 0) {
        this.compiledSource = next
        this.generatedSource = next
        this.compiledVbc2 = compiled.vbc2
        return false
      }
    } catch (e) {
      console.warn('Carry widget failed: ' + (e as Error).message)
    }
    return true
  }

  private isSaved(): boolean {
    return this.hasResult() && this.compiledVbc2 === this.savedVbc2
  }

  /** The saved version's origin: the kinds of the composed screen it began as, "+model" when the model finished or rewrote it. */
  private originLabel(): string {
    let kinds = this.templateKinds.filter((k: string): boolean => k !== 'none')
    if (kinds.length === 0) { return '' }
    let label = kinds.join(',')
    if (this.modelWrote) { label = label + '+model' }
    return label
  }

  private formatMs(ms: number): string {
    if (ms < 1000) return ms + 'ms'
    let secs = (ms / 1000).toFixed(1)
    return secs + 's'
  }

  private modeLabel(): string {
    if (this.mode === MODE_DEEPSEEK) { return settings.providerLabel() }
    if (this.mode === MODE_SERVER) { return 'Server' }
    return 'Local'
  }

  /** The open tab is the tinted one; the others are the page's own colour, so the row reads as one control. */
  private tabTint(name: string): string {
    return this.tab === name ? app.primaryFill : app.secondaryFill
  }

  private tabInk(name: string): string {
    return this.tab === name ? app.primaryInk : app.inkSoft
  }

  private canGenerate(): boolean {
    if (this.baseError.length > 0) { return false }
    if (this.mode === MODE_SERVER) { return settings.hasServerUrl() }
    if (this.mode === MODE_DEEPSEEK) { return settings.hasApiKey() }
    return this.modelReady
  }

  private totalCacheHitTokens(): number {
    let total = 0
    for (let a of this.attempts) total += a.cacheHitTokens
    return total
  }

  private totalInputTokens(): number {
    let total = 0
    for (let a of this.attempts) total += a.inputTokens
    return total
  }

  /** Every model call of the run: the program's own attempts and the small calls (plan, text, functions, sections). */
  private allInputTokens(): number { return this.totalInputTokens() + this.sideInput(this.sideCalls) }
  private allCachedTokens(): number { return this.totalCacheHitTokens() + this.sideCached(this.sideCalls) }
  private allOutputTokens(): number { return this.totalOutputTokens() + this.sideOutput(this.sideCalls) }
  private allFreshTokens(): number { return Math.max(0, this.allInputTokens() - this.allCachedTokens()) }
  private allModelMs(): number { return this.runLlmMs() + this.sideMs(this.sideCalls) }
  private allCost(): number { return this.costOf(this.allInputTokens(), this.allCachedTokens(), this.allOutputTokens()) }

  /** Output tokens per second over every model call, the wait for the first token included: what the person lived through. */
  private allSpeed(): string {
    let ms = this.allModelMs()
    return ms > 0 && this.allOutputTokens() > 0 ? Math.round(this.allOutputTokens() * 1000 / ms) + ' tok/s' : '\u2014'
  }

  private allCachePercentNote(): string {
    if (this.allCachedTokens() === 0 || this.allInputTokens() === 0) { return 'nothing reused' }
    return 'reused by DeepSeek, ' + Math.round(this.allCachedTokens() * 100 / this.allInputTokens()) + '%'
  }

  private totalOutputTokens(): number {
    let total = 0
    for (let a of this.attempts) total += a.outputTokens
    return total
  }

  private sideInput(calls: SideCall[]): number { let n = 0; for (let c of calls) { n += c.inputTokens } return n }
  private sideCached(calls: SideCall[]): number { let n = 0; for (let c of calls) { n += c.cachedTokens } return n }
  private sideOutput(calls: SideCall[]): number { let n = 0; for (let c of calls) { n += c.outputTokens } return n }
  private sideMs(calls: SideCall[]): number { let n = 0; for (let c of calls) { n += c.ms } return n }
  private sideCost(calls: SideCall[]): number { return this.costOf(this.sideInput(calls), this.sideCached(calls), this.sideOutput(calls)) }

  /** The colour of whoever did the work in a stage: the model that writes, Jev, the web search, the phone, the person. */
  whoTone(who: string): string {
    if (who === WHO_MODEL) { return app.warningInk }
    if (who === WHO_JEV) { return app.primary }
    if (who === WHO_SEARCH) { return '#7B3FE4' }
    if (who === WHO_PHONE) { return app.successInk }
    return app.inkMuted
  }

  /** One model call without its time (that is on the line's right): what it read, wrote, how fast, what it cost. */
  private callDetail(call: SideCall): string {
    if (!call.ok) { return 'failed' }
    return call.inputTokens + ' in' + (call.cachedTokens > 0 ? ' (' + call.cachedTokens + ' cached)' : '') + ' \u00B7 ' +
      call.outputTokens + ' out' + (call.ms > 0 && call.outputTokens > 0 ? ' (' + Math.round(call.outputTokens * 1000 / call.ms) + ' tok/s)' : '') +
      ' \u00B7 ~' + this.formatUsd(this.costOf(call.inputTokens, call.cachedTokens, call.outputTokens))
  }

  /** The head figure of the services card, and its colour: whether anyone in this run did not answer. */
  private servicesSummary(): string {
    let down = 0
    let some = 0
    for (let n of this.services) {
      if (silent(n)) { down++ } else if (n.failed > 0) { some++ }
    }
    if (down > 0) { return down + ' not answering' }
    if (some > 0) { return some + ' with failures' }
    return 'all answered'
  }

  private servicesTone(): string {
    let some = false
    for (let n of this.services) {
      if (silent(n)) { return app.dangerInk }
      if (n.failed > 0) { some = true }
    }
    return some ? app.warningInk : app.successInk
  }

  /**
   * Where the time of the run went: the app's total, how it divides between the model, Jev, the search and the phone, and then
   * every stage in the order it happened, each with its share drawn as a bar. The person's own waiting is listed, never counted.
   */
  @LocalBuilder
  stagesPanel() {
    MetricCard({ title: 'Where the time went', value: this.formatMs(appMs(this.stages)) }) {
      if (yourMs(this.stages) > 0) {
        Text('and ' + this.formatMs(yourMs(this.stages)) + ' waiting for your answers, not counted')
          .fontSize(11).fontColor(app.inkMuted).width('100%')
      }
      // Who spent it: one chip each, in the order they first appear in the run.
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(byWho(this.stages), (w: Stage) => {
          MetricChip({ text: w.who + ' ' + this.formatMs(w.ms), color: this.whoTone(w.who) })
        }, (w: Stage) => w.who)
      }
      .width('100%')
      ForEach(this.stages, (st: Stage, index: number) => {
        this.stageRow(st, appMs(this.stages))
      }, (st: Stage, index: number) => index.toString() + st.name)
    }
  }

  /** What the check of whether a refine changes the structure decided, kept after the status line moves on. */
  @LocalBuilder
  editCheckPanel() {
    MetricCard({ title: 'Structure edit check', value: '' }) {
      Text(this.lastTemplatePick).fontSize(11).fontColor(app.warningInk).width('100%')
    }
  }

  @LocalBuilder
  stageRow(st: Stage, total: number) {
    Column({ space: 3 }) {
      Row({ space: 6 }) {
        Text(st.name).fontSize(12).fontColor(app.inkStrong).layoutWeight(1).maxLines(2)
        Text(st.who).fontSize(10).fontColor(this.whoTone(st.who))
        Text(this.formatMs(st.ms)).fontSize(12).fontWeight(FontWeight.Medium).fontColor(app.inkStrong)
      }
      .width('100%')
      Stack({ alignContent: Alignment.Start }) {
        Row().width('100%').height(4).backgroundColor(app.lineSoft).borderRadius(2)
        Row()
          .width(st.who === WHO_YOU || total <= 0 ? '0%' : Math.max(1, Math.min(100, Math.round(st.ms * 100 / total))).toString() + '%')
          .height(4)
          .backgroundColor(this.whoTone(st.who))
          .borderRadius(2)
      }
      .width('100%')
      Text((st.who === WHO_YOU ? 'not counted' : (total > 0 ? Math.round(st.ms * 100 / total).toString() + '% of the run' : '')) +
        (st.note.length > 0 ? ' \u00B7 ' + st.note : ''))
        .fontSize(10).fontColor(app.inkMuted).width('100%').maxLines(2)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * What the model calls of the run read and wrote: tokens in, reused from the cache, paid for in full, and out; the speed and
   * the cost over all of them; then each call on a line of its own. The program's own attempts and the small calls (the plan,
   * the sections' text and functions, a section the model writes) count together.
   */
  @LocalBuilder
  tokensPanel() {
    MetricCard({ title: 'Model calls', value: this.mode === MODE_DEEPSEEK ? '~' + this.formatUsd(this.allCost()) : '' }) {
      Row({ space: 8 }) {
        MetricTile({ label: 'Input', value: this.allInputTokens() + ' tokens', note: 'rules, request, old code' }).layoutWeight(1)
        MetricTile({ label: 'Cached', value: this.allCachedTokens() + ' tokens', note: this.allCachePercentNote() }).layoutWeight(1)
      }
      .width('100%')
      Row({ space: 8 }) {
        MetricTile({ label: 'Fresh', value: this.allFreshTokens() + ' tokens', note: 'input at full price' }).layoutWeight(1)
        MetricTile({ label: 'Output', value: this.allOutputTokens() + ' tokens', note: 'text, code and reasoning' }).layoutWeight(1)
      }
      .width('100%')
      Row({ space: 8 }) {
        MetricTile({ label: 'Speed', value: this.allSpeed(), note: 'output over the time of all calls' }).layoutWeight(1)
        MetricTile({ label: 'Calls', value: (this.sideCalls.length + this.attempts.length).toString(), note: 'plan, text, functions, program' }).layoutWeight(1)
      }
      .width('100%')
      ForEach(this.sideCalls, (call: SideCall, index: number) => {
        MetricLine({ title: call.purpose, right: this.formatMs(call.ms), detail: this.callDetail(call), bad: !call.ok })
      }, (call: SideCall, index: number) => index.toString() + call.purpose)
    }
  }

  /**
   * The lookups of the run: how many and how long they took on the head line; a tap opens each with what it asked for and what
   * came back. A run that made none says so, so an empty card is a fact and not a card that failed to load.
   */
  @LocalBuilder
  toolsPanel() {
    MetricCard({
      title: 'Tool calls',
      value: this.tools.length === 0 ? 'none' : this.tools.length + ' \u00B7 ' + this.formatMs(toolMs(this.tools)),
      chevron: this.tools.length === 0 ? '' : (this.toolsOpen ? '\u25B2' : '\u25BC'),
      onHead: (): void => {
        if (this.tools.length > 0) { this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseInOut }, () => { this.toolsOpen = !this.toolsOpen }) }
      }
    }) {
      if (this.tools.length === 0) {
        Text('No lookups in this run: nothing asked for a phone function, an intent, a component or a search.')
          .fontSize(11).fontColor(app.inkMuted).width('100%')
      } else if (this.toolsOpen) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(toolTotals(this.tools), (t: ToolTotal) => {
            MetricChip({ text: t.tool + ' \u00D7' + t.count + ' \u00B7 ' + this.formatMs(t.ms) + (t.failed > 0 ? ' \u00B7 ' + t.failed + ' failed' : ''),
              color: t.failed > 0 ? app.dangerInk : app.inkSoft })
          }, (t: ToolTotal) => t.tool)
        }
        .width('100%')
        ForEach(this.tools, (c: ToolCall, index: number) => {
          MetricLine({ title: c.tool, right: this.formatMs(c.ms), ask: c.query.length > 0 ? '"' + c.query + '"' : '',
            detail: (c.ok ? '' : 'FAILED: ') + c.note, bad: !c.ok })
        }, (c: ToolCall, index: number) => index.toString() + c.tool)
      }
    }
  }

  /**
   * Who answered: one line per service the run called (Jev, Exa, DeepSeek), red when it answered nothing, amber when some calls
   * failed. What a slow or fallen-back run owes to a service that was not there reads here, with what it said.
   */
  @LocalBuilder
  servicesPanel() {
    MetricCard({ title: 'Services', value: this.servicesSummary(), valueColor: this.servicesTone() }) {
      ForEach(this.services, (n: ServiceNote) => {
        Row({ space: 8 }) {
          Text(silent(n) ? '\u2716' : (n.failed > 0 ? '!' : '\u2714'))
            .fontSize(12)
            .fontColor(silent(n) ? app.dangerInk : (n.failed > 0 ? app.warningInk : app.successInk))
          Text(describeService(n))
            .fontSize(12)
            .fontColor(silent(n) ? app.dangerInk : (n.failed > 0 ? app.warningInk : app.inkStrong))
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (n: ServiceNote) => n.service)
    }
  }

  /** What the screen does not include of the plan, one line each with why: "Day length": the itinerary's own times. */
  @LocalBuilder
  leftOutPanel() {
    MetricCard({ title: 'Not included', value: this.leftOut.length.toString() }) {
      ForEach(this.leftOut, (line: string) => {
        Text(leftOutLine(line))
          .fontSize(12)
          .fontColor(app.inkStrong)
          .width('100%')
      }, (line: string, index: number) => index.toString() + line)
    }
  }

  /**
   * The program the model wrote itself (a run the agent did not serve, or a refine): how long it took, what the compiler cost,
   * each attempt, and the runs before it.
   */
  @LocalBuilder
  attemptsPanel() {
    MetricCard({ title: 'Model writes the program', value: this.formatMs(this.runLlmMs()) }) {
      Row({ space: 8 }) {
        MetricTile({ label: 'Writing', value: this.formatMs(this.runLlmMs()), note: this.runVerdict() }).layoutWeight(1)
        MetricTile({ label: 'On device', value: this.formatMs(this.runCompileMs()), note: 'compiler only' }).layoutWeight(1)
      }
      .width('100%')
      if (this.mode === MODE_DEEPSEEK) {
        Row({ space: 8 }) {
          MetricTile({ label: 'Cost', value: '~' + this.formatUsd(this.runCost()), note: 'incl. failed attempts' }).layoutWeight(1)
          MetricTile({ label: 'Attempts', value: this.attempts.length.toString(), note: 'of ' + MAX_RETRIES }).layoutWeight(1)
        }
        .width('100%')
      }
      if (this.delta.measured) {
        Row({ space: 8 }) {
          MetricTile({ label: 'Changed', value: '+' + this.delta.added + ' \u2212' + this.delta.removed + ' lines', note: 'against the previous version' }).layoutWeight(1)
          MetricTile({ label: 'Kept', value: this.delta.keptPercent + '%', note: 'of the previous lines' }).layoutWeight(1)
        }
        .width('100%')
      }
      ForEach(this.attempts, (a: AttemptMetrics) => {
        MetricLine({ title: '#' + a.attempt + ' attempt', right: this.formatMs(a.genMs), detail: this.attemptVerdict(a), bad: !a.success })
        // Three disjoint phases of one model call, then the compiler: they add up to the time of the attempt.
        Row({ space: 8 }) {
          MetricTile({ label: 'Wait', value: a.ttftMs > 0 ? this.formatMs(a.ttftMs) : '\u2014', note: 'until first token' }).layoutWeight(1)
          if (a.thinkMs > 0) {
            MetricTile({ label: 'Think', value: this.formatMs(a.thinkMs), note: 'reasoning' }).layoutWeight(1)
          }
          MetricTile({ label: 'Write', value: this.formatMs(this.writeMs(a)), note: 'streaming code' }).layoutWeight(1)
        }
        .width('100%')
        Row({ space: 8 }) {
          MetricTile({ label: 'Compile', value: a.compileMs > 0 ? this.formatMs(a.compileMs) : '\u2014', note: 'on device' }).layoutWeight(1)
          MetricTile({ label: 'Speed', value: this.speedLabel(a), note: 'output after the wait' }).layoutWeight(1)
        }
        .width('100%')
      })
      if (this.program.runs > 1) {
        Row({ space: 8 }) {
          MetricTile({ label: 'Runs', value: this.program.runs + '', note: 'generation and refines' }).layoutWeight(1)
          MetricTile({ label: 'Spent', value: this.programSpentLabel(), note: this.program.attempts + ' model calls in all' }).layoutWeight(1)
        }
        .width('100%')
        Row({ space: 8 }) {
          MetricTile({ label: 'LLM wall', value: this.formatMs(this.program.llmMs), note: 'whole program' }).layoutWeight(1)
          MetricTile({ label: 'On device', value: this.formatMs(this.program.compileMs), note: 'whole program' }).layoutWeight(1)
        }
        .width('100%')
        Text('Earlier runs').fontSize(11).fontColor(app.inkMuted).width('100%')
        ForEach(this.pastRuns(), (record: RunRecord) => {
          MetricLine({ title: '#' + (this.indexOfRun(record) + 1) + (this.indexOfRun(record) === 0 ? ' generated' : ' refined'),
            right: record.compiled ? '\u2714' : '\u2716', ask: record.request.length > 0 ? record.request : '(no request)',
            detail: this.pastRunSummary(record), bad: !record.compiled })
        })
      }
    }
  }

  /** The first Save of a new app: its name, offered from the program and open to change. */
  @Builder
  nameOverlay() {
    Column() {
      Column() {
        Text('Save app').fontSize(20).fontWeight(FontWeight.Bold).margin({ bottom: 6 }).width('100%')
        Text('Tap the picture to change it. Name and picture can be changed later too.')
          .fontSize(13).fontColor(app.inkMuted).margin({ bottom: 16 }).width('100%')
        // The picture and the name side by side, as they will sit in the list.
        Row({ space: 12 }) {
          Stack({ alignContent: Alignment.BottomEnd }) {
            Image(projectIconResource(this.saveIcon)).width(48).height(48).objectFit(ImageFit.Contain)
            Column() {
              SymbolGlyph($r('sys.symbol.pencil_tip')).fontSize(11).fontColor([app.primaryInk])
            }
            .width(20).height(20)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(app.surface)
            .borderRadius(10)
            .shadow({ radius: 2, color: '#30000000', offsetY: 1 })
          }
          .onClick(() => { this.iconsOpen = !this.iconsOpen })
          TextInput({ placeholder: 'App name', text: this.saveName })
            .onChange((value: string) => { this.saveName = value })
            .onSubmit(() => { this.confirmName() })
            .defaultFocus(true)
            .selectAll(true)
            .layoutWeight(1)
            .height(44)
        }
        .width('100%')
        if (this.iconsOpen) {
          Column() {
            IconPicker({ selected: this.saveIcon, onPick: (icon: string): void => { this.saveIcon = icon; this.iconsOpen = false } })
          }
          .width('100%')
          .margin({ top: 12 })
        }
        Row({ space: 12 }) {
          Button('Cancel')
            .attributeModifier(new QuietButton())
            .layoutWeight(1)
            .onClick(() => { this.cancelName() })
          Button('Save')
            .attributeModifier(new PrimaryButton())
            .layoutWeight(1)
            .enabled(this.saveName.trim().length > 0)
            .onClick(() => { this.confirmName() })
        }
        .width('100%')
        .margin({ top: 20 })
      }
      .width('90%')
      .padding(24)
      .backgroundColor(app.surface)
      .borderRadius(16)
      .shadow({ radius: 8, color: '#30000000' })
      // A tap inside the card is the card's, not a tap on the dimming behind it.
      .onClick(() => {})
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#50000000')
    .onClick(() => { this.cancelName() })
  }

  /** Back with a result that is not saved: save it, drop it, or stay. */
  @Builder
  leaveOverlay() {
    Column() {
      Column() {
        // With a result there is something to save; with only a request typed, or a run under way, there is not.
        Text(this.hasUnsavedResult() ? (this.makeWidget ? (this.widgetCards > 0 && this.bindFormId.length === 0 ? 'Update the widget on your home screen?' :
          'Add this widget to your home screen?') : 'Save this app?') :
          'Leave without generating?')
          .fontSize(20).fontWeight(FontWeight.Bold).margin({ bottom: 6 }).width('100%')
        Text(this.hasUnsavedResult() ?
          (this.projectId.length === 0 || this.makeWidget ? 'It is not saved yet. Leaving now discards it.' :
            'This version is not saved yet. Leaving now discards it.') :
          (this.generating ? 'A program is still being built. Leaving now stops it.' :
            'What you typed has not been used yet. Leaving now discards it.'))
          .fontSize(13).fontColor(app.inkMuted).margin({ bottom: 20 }).width('100%')
        if (this.hasUnsavedResult() && this.makeWidget) {
          // Save and put it on the home screen; leaves once the card is there.
          Button(this.widgetActionLabel())
            .attributeModifier(new PrimaryButton())
            .width('100%')
            .onClick(() => { this.leaving = false; this.addToHomeScreen(true) })
          if (this.widgetCards === 0 && this.bindFormId.length === 0) {
            Button('Save only')
              .attributeModifier(new QuietButton())
              .width('100%')
              .margin({ top: 12 })
              .onClick(() => { this.leaveSave() })
          }
        } else if (this.hasUnsavedResult()) {
          Button('Save')
            .attributeModifier(new PrimaryButton())
            .width('100%')
            .onClick(() => { this.leaveSave() })
        }
        Row({ space: 12 }) {
          Button('Discard')
            .attributeModifier(new QuietButton())
            .layoutWeight(1)
            .onClick(() => { this.leaving = false; if (this.generating) { this.stopGeneration() } this.close() })
          Button('Keep editing')
            .attributeModifier(new QuietButton())
            .layoutWeight(1)
            .onClick(() => { this.leaving = false })
        }
        .width('100%')
        .margin({ top: this.hasUnsavedResult() ? 12 : 0 })
      }
      .width('90%')
      .padding(24)
      .backgroundColor(app.surface)
      .borderRadius(16)
      .shadow({ radius: 8, color: '#30000000' })
      .onClick(() => {})
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#50000000')
    .onClick(() => { this.leaving = false })
  }

  /** While a run is going: what it is doing now, the agent's question if it asks one, and the sketch of the screen. */
  @Builder
  buildCard() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        LoadingProgress().width(18).height(18)
        Text(this.status.length > 0 ? this.status : 'Building...')
          .fontSize(13).fontColor(app.inkSoft).layoutWeight(1).maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      if (this.pendingRequest.length > 0) {
        Text(this.pendingRequest).fontSize(13).fontColor(app.inkMuted).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }
      if (this.questionText.length > 0) {
        QuestionCard({ question: this.questionText, options: this.questionOptions, fallback: this.questionFallback,
          onPick: (index: number): void => { this.settleQuestion(index) },
          onTyped: (text: string): void => { this.settleQuestion(text) } })
      }
      if (this.previewVbc2.length > 0) {
        Text(this.previewNote).fontSize(12).fontColor(app.warningInk).width('100%')
        // As tall as the screen it shows, as in Chat: the list scrolls it, and the parts Jev chose are not cut off below a fixed box.
        VeraPreview({ previewOnly: true, vbc2: this.previewVbc2, embedded: true })
          .width('100%')
          .borderRadius(12)
          .clip(true)
          .opacity(0.6)
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(app.surface)
    .borderRadius(14)
  }

  /** The compiler's words, what a service that did not answer cost, and what is missing to set up; nothing when there is none. */
  @Builder
  failureDetails() {
    if (this.compileErrors.length > 0) {
      Scroll() {
        Text(this.compileErrors).fontSize(11).fontFamily('monospace').fontColor(app.danger).width('100%').padding(8)
      }
      .width('100%')
      .constraintSize({ maxHeight: 140 })
      .backgroundColor(app.dangerFill)
      .borderRadius(8)
    }
    if (this.troubleNote.length > 0) {
      Text(this.troubleNote).fontSize(12).fontColor(app.warningInk).width('100%')
    }
    if (this.setupHint.length > 0) {
      Text(this.setupHint).fontSize(11).fontColor(app.inkMuted).width('100%').copyOption(CopyOptions.LocalDevice)
    }
  }

  /** A run that gave no program: why, the compiler's words, and what a service that did not answer cost. */
  @Builder
  failedCard() {
    Column({ space: 8 }) {
      Text(this.status.length > 0 ? this.status : 'Nothing was built')
        .fontSize(13).fontColor(app.warningInk).width('100%').copyOption(CopyOptions.LocalDevice)
      if (this.pendingRequest.length > 0) {
        Row({ space: 4 }) {
          Text(this.pendingRequest).fontSize(13).fontColor(app.inkSoft).maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          this.requestAction('sys.symbol.square_on_square_fill', true, () => { copyText(this.getUIContext(), this.pendingRequest) })
          this.requestAction('sys.symbol.square_and_pencil', true, () => { this.editFailedRequest() })
        }
        .width('100%')
      }
      this.failureDetails()
      if (this.previewVbc2.length > 0 && !this.hasResult()) {
        Text(this.previewNote).fontSize(12).fontColor(app.warningInk).width('100%')
        VeraPreview({ previewOnly: true, vbc2: this.previewVbc2, embedded: true })
          .width('100%').borderRadius(12).clip(true).opacity(0.6)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor(app.surface)
    .borderRadius(14)
  }

  /**
   * The one box: the first message asks for an app, the ones after it ask for a change to it. It floats over the page as a
   * rounded card with a shadow and a margin on every side, so that it reads as something laid over the program and not as
   * its bottom edge. One round button on its right does whatever is next: send, or stop while a run is going. In full
   * screen a button at its left folds the box away, and the button that brings it back is that same button, in the same
   * place.
   */
  @Builder
  composer() {
    Column({ space: 4 }) {
    if (this.rewriting) {
      Row({ space: 4 }) {
        Text('Editing the request: sending builds it again in its place')
          .fontSize(12).fontColor(app.inkMuted).layoutWeight(1).maxLines(2)
          .padding({ left: 10 })
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(16).fontColor([app.inkMuted])
        }
        .width(28)
        .height(28)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.rewriting = false
          this.draft = ''
        })
      }
      .width('100%')
    }
    Row({ space: 8 }) {
      if (this.fullscreen && this.hasResult()) {
        this.foldButton(true)
      }
      TextInput({ placeholder: this.makeWidget ? (hasWidgetFunction(this.compiledSource) ?
        (this.widgetFresh ? 'What should the new widget show?' : 'Change something...') : 'What should it show?') :
        (this.hasResult() || this.baseVersionId.length > 0 ? 'What to change?' : 'Describe the app you want...'),
        text: this.draft })
        .onChange((value: string) => { this.draft = value })
        .onSubmit(() => { this.send() })
        // The box is enabled again when a run ends and takes the focus back; that must not open the keyboard over the
        // result. A tap on the box still does.
        .enableKeyboardOnFocus(false)
        .onFocus(() => { this.composerFocused = true })
        .onBlur(() => { this.composerFocused = false })
        .layoutWeight(1)
        .height(44)
        .fontSize(16)
        .backgroundColor(Color.Transparent)
        .enabled(!this.generating && this.baseError.length === 0)
      this.actionButton()
    }
    .width('100%')
    }
    .width('calc(100% - 24vp)')
    .margin({ left: 12, right: 12, top: 8, bottom: 10 })
    .padding(6)
    .backgroundColor(app.surface)
    .borderRadius(30)
    .border({ width: 1, color: app.line })
    .shadow({ radius: 16, color: '#33000000', offsetY: -2 })
  }

  /** A small round button beside a request: copy it, or edit it. */
  @Builder
  requestAction(symbol: string, enabled: boolean, tap: () => void) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph($r(symbol)).fontSize(18).fontColor([app.inkSoft])
    }
    .width(36)
    .height(36)
    .backgroundColor(app.background)
    .opacity(enabled ? 1 : 0.4)
    .enabled(enabled)
    .onClick(tap)
  }

  /** The round button on the right of the box; see composer. */
  @Builder
  actionButton() {
    if (this.generating) {
      this.roundButton({ symbol: 'sys.symbol.square_fill', enabled: true, tap: () => { this.stopGeneration() } })
    } else {
      this.roundButton({ symbol: 'sys.symbol.arrow_up', enabled: this.draft.trim().length > 0 && this.canGenerate(),
        tap: () => { this.send() } })
    }
  }

  /**
   * One object literal, not separate arguments: a @Builder's arguments passed by value are read once, and the send button
   * then stayed as dim and as disabled as it was over the empty box whatever was typed into it.
   */
  @Builder
  roundButton(spec: RoundButtonSpec) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph($r(spec.symbol)).fontSize(22).fontColor([app.onPrimary])
    }
    .width(44)
    .height(44)
    .backgroundColor(app.primary)
    .opacity(spec.enabled ? 1 : 0.4)
    .enabled(spec.enabled)
    .onClick(spec.tap)
  }

  /**
   * Folds the box away in full screen, and brings it back: one button with the arrow turned over. Both places are the same
   * point of the screen, so a second tap undoes the first without the hand moving.
   */
  @Builder
  foldButton(fold: boolean) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph($r(fold ? 'sys.symbol.chevron_down' : 'sys.symbol.chevron_up')).fontSize(18).fontColor([app.secondaryInk])
    }
    .width(FOLD_SIZE)
    .height(FOLD_SIZE)
    .backgroundColor(app.secondaryFill)
    // Over the program it needs a shadow to be seen; in the box it sits on the box.
    .shadow(fold ? { radius: 0 } : { radius: 8, color: '#40000000', offsetY: 2 })
    .onClick(() => { this.composerHidden = fold })
  }

  /** The title bar's buttons: the program full screen once there is one, the settings, a new app. */
  private barMenus(): NavigationMenuItem[] {
    let items: NavigationMenuItem[] = []
    // The widget screen has one thing to do besides the connection: New belongs to making an app.
    if (this.makeWidget) { return [settingsMenuItem(this.pathStack)] }
    if (this.hasResult() && !this.generating && !this.makeWidget) {
      items.push({
        value: 'Full screen',
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.arrow_up_left_and_arrow_down_right')),
        action: () => { this.setFullscreen(true) }
      })
    }
    items.push(settingsMenuItem(this.pathStack))
    items.push({
      value: 'New',
      symbolIcon: new SymbolGlyphModifier($r('sys.symbol.plus')),
      action: () => { this.confirmNew() }
    })
    return items
  }

  /**
   * A new app opens over the whole screen: in the pane under the request it had a third of the height and was read through
   * a slot (the Try one of these demos). Only a new one: a change keeps whichever view the person was in. The run's line stays
   * over it for a few seconds; the collapse button and Back return to the pane, where the line, Code and Metrics are.
   */
  private openWhole(): void {
    if (this.fullscreen) { return }
    this.setFullscreen(true)
    this.readyNote = true
    // The line of an earlier run goes with its own timer, not this run's line with it.
    if (this.readyNoteTimer >= 0) { clearTimeout(this.readyNoteTimer) }
    this.readyNoteTimer = setTimeout(() => { this.readyNoteTimer = -1; this.readyNote = false }, READY_NOTE_MS)
  }

  /** A new program starts at its top: the corner buttons show again (a short one may never scroll to bring them back). */
  showCorner(): void { this.cornerHidden = false }

  /** What was typed into the program goes with it to the other view, which draws a program of its own. */
  private setFullscreen(on: boolean): void {
    this.cornerHidden = false
    if (!this.previewController.flushAndSnapshot()) { return }
    this.carriedState = this.liveState
    this.tab = TAB_PREVIEW
    this.composerHidden = false
    this.fullscreen = on
  }

  /**
   * Full screen: nothing but the program, and the box under it for the next request. While a change is being made the
   * program stays as it was, with what the run is doing in a small label over it, and the agent's question under it.
   */
  @Builder
  fullscreenPane() {
    Column() {
      Stack({ alignContent: Alignment.TopEnd }) {
        // With the box folded, the round button lies over the bottom corner: the program gets room to scroll clear of it.
        VeraPreview({ controller: this.previewController,
          vbc2: this.compiledVbc2, seedState: this.carriedState, destinationHidden: this.destinationHidden,
          bottomRoom: this.composerHidden ? FOLD_ROOM : 0,
          onStateSnapshot: this.previewSnapshot(this.previewController),
          // The two round buttons lie over the program's corner: on the way down they would cover its rows (a stop's
          // Navigate button, measured on Istanbul layover), so they step aside and come back on the way up.
          onReadingDown: (down: boolean): void => { animateTo({ duration: 180 }, () => { this.cornerHidden = down }) } })
          .width('100%')
          .height('100%')
        Row({ space: 8 }) {
          // Save without leaving full screen: a name is asked for the first time, as ever; greyed out once it is saved.
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.save'))
              .fontSize(18).fontColor([this.isSaved() ? app.inkDisabled : app.primaryInk])
          }
          .width(36)
          .height(36)
          .backgroundColor(app.surface)
          .shadow({ radius: 4, color: '#26000000', offsetY: 1 })
          .enabled(!this.generating && !this.isSaved())
          .opacity(this.generating ? 0.5 : 1)
          .onClick(() => { this.doSave() })
          // Keeps the app, then the widget screen: the card on the home screen is made from a saved version.
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.square_grid_2x2')).fontSize(18).fontColor([app.primaryInk])
          }
          .width(36)
          .height(36)
          .backgroundColor(app.surface)
          .shadow({ radius: 4, color: '#26000000', offsetY: 1 })
          .enabled(!this.generating)
          .opacity(this.generating ? 0.5 : 1)
          .accessibilityText('Make a widget')
          .onClick(() => { this.startWidget() })
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.arrow_down_right_and_arrow_up_left')).fontSize(18).fontColor([app.secondaryInk])
          }
          .width(36)
          .height(36)
          .backgroundColor(app.surface)
          .shadow({ radius: 4, color: '#26000000', offsetY: 1 })
          .onClick(() => { this.setFullscreen(false) })
        }
        .margin({ top: 8, right: 8 })
        .opacity(this.cornerHidden ? 0 : 1)
        .translate({ y: this.cornerHidden ? -56 : 0 })
        .hitTestBehavior(this.cornerHidden ? HitTestMode.None : HitTestMode.Default)
        if (this.generating || !this.compiled || this.readyNote) {
          Row({ space: 8 }) {
            if (this.generating) { LoadingProgress().width(16).height(16) }
            Text(this.status.length > 0 ? this.status : 'Working...')
              .fontSize(12).fontColor(this.generating ? app.inkSoft : (this.compiled ? app.successInk : app.warningInk)).maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor(app.surface)
          .borderRadius(12)
          .shadow({ radius: 4, color: '#26000000', offsetY: 1 })
          // Left of the collapse button, not over it.
          .constraintSize({ maxWidth: '75%' })
          .margin({ top: 12, right: 100 })
        }
        if (this.composerHidden) {
          // Where the fold button was in the box: margin 12 and the box's border and padding in, margin 10 and the same up.
          Column() { this.foldButton(false) }
            .position({ left: 19, bottom: 17 })
        }
      }
      .width('100%')
      .layoutWeight(1)
      .clip(true)
      if (this.questionText.length > 0) {
        QuestionCard({ question: this.questionText, options: this.questionOptions, fallback: this.questionFallback,
          onPick: (index: number): void => { this.settleQuestion(index) },
          onTyped: (text: string): void => { this.settleQuestion(text) } })
          .margin({ left: 12, right: 12, top: 8 })
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  /**
   * Make widget: the card as the home screen will draw it, ready-made requests under it, and the one thing to do next --
   * put it on the home screen. The code is on the project page, under the version it is saved as.
   */
  @Builder
  widgetPane() {
    Column({ space: 10 }) {
      Stack() {
        // Redo shows the empty card: the old widget is what is being replaced, not the start of the new one.
        if (hasWidgetFunction(this.compiledSource) && !this.widgetFresh) {
          WidgetPreview({ vbc2: this.compiledVbc2, seedState: this.widgetSeed, title: this.widgetTitle })
            .width('100%')
            .height('100%')
            .opacity(this.generating ? 0.5 : 1)
        } else {
          Column({ space: 10 }) {
            if (this.generating) {
              LoadingProgress().width(28).height(28)
            }
            Text(this.generating ? 'Making the widget...' :
              (this.widgetFresh ? 'Your new widget appears here' : 'Your widget appears here'))
              .fontSize(13).fontColor(app.inkMuted).textAlign(TextAlign.Center)
          }
          .width(172)
          .height(172)
          .justifyContent(FlexAlign.Center)
          .borderRadius(20)
          .border({ width: 1.5, color: app.lineStrong, style: BorderStyle.Dashed })
        }
      }
      .width('100%')
      .layoutWeight(1)

      if (this.generating) {
        Row({ space: 8 }) {
          LoadingProgress().width(16).height(16)
          Text(this.status.length > 0 ? this.status : 'Making the widget...')
            .fontSize(13).fontColor(app.inkSoft).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      } else if (this.widgetFailed()) {
        this.widgetFailureCard()
      } else if (this.widgetChangeNote().length > 0) {
        Text(this.widgetChangeNote() === 'same' ? 'Looks the same as before. Try saying what to change.' :
          (this.widgetChangeNote() === 'made' ? '\u2713 Widget made' : '\u2713 Updated'))
          .fontSize(13)
          .fontColor(this.widgetChangeNote() === 'same' ? app.warningInk : app.successInk)
          .padding({ left: 12, right: 12, top: 4, bottom: 4 })
          .borderRadius(12)
          .backgroundColor(this.widgetChangeNote() === 'same' ? app.warningFill : app.successFill)
      }

      if (!this.generating) {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
          ForEach(this.widgetSuggestions(), (suggestion: WidgetSuggestion) => {
            Button(suggestion.label)
              .attributeModifier(new QuietButton())
              .height(32).fontSize(13)
              .margin(4)
              .enabled(this.canGenerate() && this.baseError.length === 0)
              .onClick(() => { this.sendWidget(suggestion.ask, suggestion.label) })
          }, (suggestion: WidgetSuggestion) => suggestion.label)
        }
        .width('100%')
      }

      this.widgetAction()
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
  }

  /** After a new app's first save: one tap to its widget, one to say no. */
  @Builder
  widgetOfferCard() {
    Column() {
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.square_grid_2x2')).fontSize(22).fontColor([app.primaryInk])
        Column({ space: 2 }) {
          Text('Put it on your home screen?').fontSize(14).fontWeight(FontWeight.Medium).fontColor(app.inkStrong)
          Text('A small card with what matters most.').fontSize(12).fontColor(app.inkMuted)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Button('Make widget')
          .attributeModifier(new TonalButton())
          .height(32).fontSize(13)
          .onClick(() => { this.openWidgetFromOffer() })
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(14).fontColor([app.inkMuted])
        }
        .width(28)
        .height(28)
        .backgroundColor(Color.Transparent)
        .onClick(() => { this.widgetOffer = false })
      }
      .width('100%')
      .padding(12)
      .backgroundColor(app.surface)
      .borderRadius(12)
      .shadow({ radius: 4, color: '#1A000000', offsetY: 1 })
    }
    .width('100%')
    .padding({ left: 12, right: 12, bottom: 4 })
  }

  /** Done: the project's page, where the widget now reads "On home screen" -- not the screen the app was made on. */
  private finishWidget(): void {
    let names = this.pathStack.getAllPathName()
    if (names.length >= 2 && names[names.length - 2] === 'project') { this.close(); return }
    if (this.disposed || this.closing || this.projectId.length === 0) { this.close(); return }
    let p = new AppRouteParams()
    p.projectId = this.projectId
    this.closing = true
    this.pathStack.replacePath({ name: 'project', param: p })
  }

  /** The widget screen, in place of this one: the app is saved, and Back from the widget goes where Back from here did. */
  private openWidgetFromOffer(): void {
    if (this.generating || this.projectId.length === 0 || !this.isSaved()) { return }
    this.widgetOffer = false
    let p = new AppRouteParams()
    p.projectId = this.projectId
    p.baseVersionId = this.baseVersionId
    p.makeWidget = '1'
    this.closing = true
    this.pathStack.replacePath({ name: 'generate', param: p })
  }

  /** Why the widget was not made, in plain words first; the checks' own words a tap away. */
  @Builder
  widgetFailureCard() {
    Column({ space: 6 }) {
      Text('Couldn\'t make that one. Try simpler wording or pick a suggestion.')
        .fontSize(13).fontColor(app.warningInk).width('100%')
      Row({ space: 16 }) {
        Text(this.widgetFailureOpen ? 'Hide details' : 'Details \u203A')
          .fontSize(12).fontColor(app.inkMuted)
          .onClick(() => { this.widgetFailureOpen = !this.widgetFailureOpen })
        if (this.widgetAsk.length > 0) {
          Text('Try again').fontSize(12).fontColor(app.primaryInk)
            .onClick(() => { this.sendWidget(this.widgetAsk, this.requestLabel) })
        }
      }
      .width('100%')
      if (this.widgetFailureOpen) {
        Text(this.widgetFailureText()).fontSize(11).fontColor(app.inkSoft).fontFamily('monospace')
          .maxLines(12).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          .copyOption(CopyOptions.LocalDevice)
      }
    }
    .width('100%')
    .padding(10)
    .backgroundColor(app.warningFill)
    .borderRadius(10)
  }

  /** The widget screen's one button: put the card on the home screen, or say it is there. */
  @Builder
  widgetAction() {
    if (hasWidgetFunction(this.compiledSource) && !this.generating && !this.widgetFresh) {
      Column({ space: 8 }) {
        if (this.isSaved() && this.bindFormId.length === 0 && (this.widgetCards > 0 || this.widgetPlacedHere)) {
          Button('\u2713 On home screen')
            .attributeModifier(new TonalButton())
            .width('100%')
            .enabled(false)
          Text('Done').fontSize(14).fontColor(app.primaryInk).onClick(() => { this.finishWidget() })
        } else {
          Button(this.widgetChecking ? 'Checking...' : this.widgetAdding ? 'Adding...' : this.widgetActionLabel())
            .attributeModifier(new PrimaryButton())
            .width('100%')
            .enabled(!this.widgetAdding && !this.widgetChecking)
            .onClick(() => { this.addToHomeScreen(false) })
          if (!this.isSaved() && this.widgetCards === 0 && this.bindFormId.length === 0) {
            Text('Save without adding').fontSize(13).fontColor(app.inkMuted).onClick(() => { this.doSave() })
          }
        }
        if (this.widgetNote.length > 0) {
          Text(this.widgetNote).fontSize(13).fontColor(app.inkSoft).textAlign(TextAlign.Center).width('100%')
        }
      }
      .width('100%')
    }
  }

  /** The program that runs, over the whole space: its status and Save on top, then Preview, Code or Metrics. */
  @Builder
  resultPane() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          // One line of status: the button beside it already says whether this is saved.
          Text(this.resultNote().length > 0 ? this.resultNote() : (this.isSaved() ? 'Saved' : 'Ready'))
            .fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor(this.compiled ? app.successInk : app.inkStrong).maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Button('Widget')
          .attributeModifier(new TonalButton())
          .fontSize(13)
          .height(34)
          .enabled(!this.generating)
          .onClick(() => { this.startWidget() })
        Button(this.isSaved() ? 'Saved' : 'Save')
          .attributeModifier(new PrimaryButton())
          .fontSize(13)
          .height(34)
          .enabled(!this.generating && !this.isSaved())
          .onClick(() => { this.doSave() })
      }
      .width('100%')

      // What was asked, in one line; tapped, every request that led here.
      if (this.acceptedRequest.length > 0) {
        Row({ space: 4 }) {
          Text(this.shownRequest(this.requestOpen && this.requestHistory.length > 0 ? this.requestHistory : this.acceptedRequest))
            .fontSize(13)
            .fontColor(app.inkSoft)
            .maxLines(this.requestOpen ? 12 : 1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            // Selecting text takes the tap, so only the open history can be copied; closed, the tap opens it.
            .copyOption(this.requestOpen ? CopyOptions.LocalDevice : CopyOptions.None)
          if (this.requestExpands()) {
            SymbolGlyph($r(this.requestOpen ? 'sys.symbol.chevron_up' : 'sys.symbol.chevron_down')).fontSize(20).fontColor([app.inkMuted])
          }
          this.requestAction('sys.symbol.square_on_square_fill', true, () => { copyText(this.getUIContext(), this.acceptedRequest) })
          if (this.acceptedBase !== null) {
            this.requestAction('sys.symbol.square_and_pencil', !this.generating, () => { this.editRequest() })
          }
        }
        .width('100%')
        .constraintSize({ minHeight: 40 })
        .alignItems(this.requestOpen ? VerticalAlign.Top : VerticalAlign.Center)
        .onClick(() => { if (this.requestExpands()) { this.requestOpen = !this.requestOpen } })
      }

      if (this.generatedSource.trim() !== this.compiledSource.trim()) {
        Text('The last attempt was not applied. Save keeps the previous successful code and version request.')
          .fontSize(12).fontColor(app.warningInk).width('100%')
        // And why: the program that stays is the old one, and its errors are the only place to read them.
        this.failureDetails()
      }

      Row({ space: 6 }) {
        this.tabButton('Preview', TAB_PREVIEW)
        this.tabButton('Code', TAB_CODE)
        this.tabButton('Metrics', TAB_METRICS)
        if (this.showsWidgetTab()) {
          this.tabButton('Widget', TAB_WIDGET)
        }
      }
      .width('100%')

      Stack() {
        // Kept built under the other tabs, hidden, so what was typed into the running program is still there on return.
        VeraPreview({ controller: this.previewController,
          vbc2: this.compiledVbc2, seedState: this.carriedState, destinationHidden: this.destinationHidden,
          onStateSnapshot: this.previewSnapshot(this.previewController) })
          .width('100%')
          .height('100%')
          .visibility(this.tab === TAB_PREVIEW ? Visibility.Visible : Visibility.Hidden)
        if (this.tab === TAB_WIDGET) {
          WidgetPreview({ vbc2: this.compiledVbc2, seedState: this.widgetSeed, title: this.widgetTitle })
            .width('100%')
            .height('100%')
        } else if (this.tab !== TAB_PREVIEW) {
          Scroll() {
            this.detailsPanel()
          }
          .width('100%')
          .height('100%')
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .padding({ top: 8, bottom: 8, left: 4, right: 4 })
        }
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor(app.surface)
      .borderRadius(12)
      .clip(true)
      .border({ width: 1, color: app.line })
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
  }

  /** One of the card's tabs. */
  @Builder
  tabButton(label: string, name: string) {
    Button(label)
      .type(ButtonType.Capsule).fontSize(12).height(30).layoutWeight(1)
      .fontWeight(this.tab === name ? FontWeight.Medium : FontWeight.Normal)
      .backgroundColor(this.tabTint(name)).fontColor(this.tabInk(name))
      .onClick(() => {
        // The widget is drawn over what the app preview holds now.
        if (name === TAB_WIDGET) { this.widgetSeed = this.liveState.length > 0 ? this.liveState : this.carriedState }
        this.tab = name
      })
  }

  /** Make widget, or a program that already has one. */
  private showsWidgetTab(): boolean {
    return this.makeWidget || hasWidgetFunction(this.compiledSource)
  }

  /** The source or the figures of the run, under the tab that was chosen. */
  @Builder
  detailsPanel() {
    Column({ space: 8 }) {
      if (this.tab === TAB_METRICS) {
        Column({ space: 10 }) {
          if (this.stages.length > 0) { this.stagesPanel() }
          if (this.lastTemplatePick.length > 0) { this.editCheckPanel() }
          if (this.attempts.length > 0) { this.attemptsPanel() }
          if (this.mode !== MODE_SERVER && (this.sideCalls.length > 0 || this.attempts.length > 0)) { this.tokensPanel() }
          if (this.stages.length > 0 || this.attempts.length > 0 || this.tools.length > 0) { this.toolsPanel() }
          if (this.services.length > 0) { this.servicesPanel() }
          if (this.leftOut.length > 0) { this.leftOutPanel() }
          if (this.attempts.length === 0 && this.stages.length === 0) {
            Text('No run yet').fontSize(13).fontColor(app.inkDisabled).width('100%').textAlign(TextAlign.Center).padding({ top: 12 })
          }
        }
        // The measured width, so that the cards (92% of it) are centred in the pane drawn and not in the wider box a percentage
        // resolves against; before the first measure the percentage stands in.
        .width(this.metricsWidth > 0 ? this.metricsWidth : '100%')
        .alignItems(HorizontalAlign.Center)
        .onAreaChange((_old: Area, area: Area): void => {
          let w = Number(area.width)
          if (w > 0 && Math.abs(w - this.metricsWidth) > 0.5) { this.metricsWidth = w }
        })
      } else {
        // Lines are not wrapped: a wrapped line of code reads as two, and an indent is what shows its nesting.
        Button('Copy code')
          .attributeModifier(new QuietButton())
          .height(32).fontSize(12)
          .margin({ left: 10, top: 6, bottom: 4 })
          .alignSelf(ItemAlign.Start)
          .onClick(() => { copyText(this.getUIContext(), this.compiledSource) })
        Scroll() {
          Text(this.compiledSource)
            .fontSize(12).fontFamily('monospace').fontColor(app.inkStrong).padding(10)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart)
        .width('100%')
        .backgroundColor(app.background)
        .borderRadius(10)
      }
    }
    .width('100%')
  }

  @Builder
  modelCard() {
    // The model (~1.9 GB) is fetched from vera-server, so what is missing is either the address or the download.
    Column({ space: 8 }) {
      Text('Model not downloaded').fontSize(14).fontWeight(FontWeight.Medium)
      Text(settings.hasServerUrl() ?
        'One-time download of about 1.9 GB from the server, best over WiFi.' :
        'It is downloaded from vera-server, and no server address is set. Choose Server in the settings to see how to set one.')
        .fontSize(12).fontColor(app.inkSoft)
      if (settings.hasServerUrl()) {
        Button('Download')
          .attributeModifier(new PrimaryButton())
          .fontSize(12)
          .height(32)
          .onClick(() => { this.checkModel() })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(16)
    .backgroundColor(app.warningFill)
    .borderRadius(14)
  }

  /** Sends what was typed: a request for an app while there is none, a change to it once there is. */
  private currentBase(): RequestBase {
    let base = new RequestBase()
    base.compiledSource = this.compiledSource
    base.compiledVbc2 = this.compiledVbc2
    base.compositionJson = this.compositionJson
    base.templateKinds = this.templateKinds.slice()
    base.requestHistory = this.requestHistory
    base.acceptedRequest = this.acceptedRequest
    base.acceptedComposition = this.acceptedComposition
    base.acceptedOrigin = this.acceptedOrigin
    base.acceptedMetrics = this.acceptedMetrics
    base.modelWrote = this.modelWrote
    base.before = this.acceptedBase
    return base
  }

  /**
   * Puts back what was on the screen before the last accepted request, so that the edit of it sent now runs in its place: a
   * change on the version before it, or a new app when it was the first request.
   */
  private restoreBase(base: RequestBase): void {
    if (base.compiledSource.length === 0) { this.previewController = new VeraPreviewController() }
    this.compiledSource = base.compiledSource
    this.compiledVbc2 = base.compiledVbc2
    this.generatedSource = base.compiledSource
    this.compositionJson = base.compositionJson
    this.templateKinds = base.templateKinds.slice()
    this.requestHistory = base.requestHistory
    this.acceptedRequest = base.acceptedRequest
    this.acceptedComposition = base.acceptedComposition
    this.acceptedOrigin = base.acceptedOrigin
    this.acceptedMetrics = base.acceptedMetrics
    this.metricTotals = base.acceptedMetrics !== null ? this.copyMetrics(base.acceptedMetrics) : new VersionMetrics()
    this.modelWrote = base.modelWrote
    this.acceptedBase = base.before
    this.requestOpen = false
    if (base.compiledSource.length === 0) {
      // A new app: nothing to change and nothing typed into it to carry over.
      this.previousSource = ''
      this.carriedState = ''
      this.liveState = ''
    }
  }

  /** The last request, into the box to be edited and sent again in its place. */
  private editRequest(): void {
    if (this.generating || this.acceptedBase === null) { return }
    this.draft = this.acceptedRequest
    this.rewriting = true
    this.fullscreen = false
  }

  /** A request that built nothing, into the box: sending it is a new try on the screen as it is. */
  private editFailedRequest(): void {
    if (this.generating) { return }
    this.draft = this.pendingRequest
    this.rewriting = false
  }

  /** Cards on the home screen that show this project. */
  private readWidgetCards(): number {
    try { return formBindings.formsFor(this.projectId).length } catch (e) {
      console.error('Read widget bindings failed: ' + (e as Error).message)
      return 0
    }
  }

  /**
   * The launcher's widget list adds the card in the form's own process (formBindings.takeOffer): watched for a minute, so
   * the button says it is there once it is.
   */
  private watchForCard(): void {
    let tries = 0
    let tick = (): void => {
      if (this.disposed) { return }
      this.widgetCards = this.readWidgetCards()
      if (this.widgetCards > 0) { this.widgetPlacedHere = true; this.widgetNote = ''; return }
      tries++
      if (tries < 60) { setTimeout(tick, 1000) }
    }
    setTimeout(tick, 1000)
  }

  /** The first widget is asked for in one tap; one that is there, changed in one. */
  private widgetSuggestions(): WidgetSuggestion[] {
    let key = (this.widgetFresh ? 'fresh:' : 'change:') + this.compiledSource
    if (this.widgetChipsFor !== key) {
      this.widgetChipsFor = key
      this.widgetChips = hasWidgetFunction(this.compiledSource) && !this.widgetFresh ? changeSuggestions(this.compiledSource) :
        firstSuggestions(withoutWidget(this.compiledSource))
    }
    return this.widgetChips
  }

  /**
   * What the last request did to the card: made it, changed it, or left it looking as it was -- the last one says so,
   * since a request the card cannot show otherwise reads as nothing having happened.
   */
  private widgetChangeNote(): string {
    if (this.widgetBeforeVbc2.length === 0 || this.compiledVbc2 === this.widgetBeforeVbc2 ||
      !hasWidgetFunction(this.compiledSource)) { return '' }
    if (this.widgetChangeFor !== this.compiledVbc2) {
      this.widgetChangeFor = this.compiledVbc2
      this.widgetChangeText = !this.widgetBeforeHad ? 'made' :
        (sameCard(this.widgetBeforeVbc2, this.compiledVbc2, this.widgetSeed) ? 'same' : 'updated')
    }
    return this.widgetChangeText
  }

  /** A suggestion or Try again: sent as if typed into the box. */
  private sendWidget(ask: string, label: string = ''): void {
    if (this.generating) { return }
    this.chipLabel = label
    this.draft = ask
    this.send()
  }

  /** The last request built nothing: the model's checks said no, or the reply did not compile. */
  private widgetFailed(): boolean {
    if (this.widgetFailure.length > 0) { return true }
    return this.runs.length > 0 && (!this.compiled || this.generatedSource.trim() !== this.compiledSource.trim())
  }

  private widgetFailureText(): string {
    if (this.widgetFailure.length > 0) { return this.widgetFailure }
    return this.compileErrors.length > 0 ? this.compileErrors : this.status
  }

  private widgetActionLabel(): string {
    if (this.bindFormId.length > 0) { return 'Show on this card' }
    if (this.widgetCards > 0) { return 'Update widget' }
    return 'Add to home screen'
  }

  /**
   * Save the widget, and put it on the home screen: on the card it was opened for, or a new one when there are none.
   * Cards already there draw the saved version on their own (commitSave refreshes them).
   */
  private async addToHomeScreen(leave: boolean): Promise<void> {
    if (this.disposed || this.generating || this.widgetAdding || this.widgetChecking) { return }
    if (!this.isSaved() && !(await this.checkWidgetSave() && this.commitSave())) { return }
    this.widgetAdding = true
    this.widgetNote = ''
    let placed = false
    try {
      if (this.bindFormId.length > 0) {
        await bindLiveForm(this.bindFormId, this.projectId)
        this.bindFormId = ''
        this.widgetAdding = false
        returnToLibrary(this.pathStack)
        return
      }
      if (this.readWidgetCards() === 0) {
        let message = await publishLiveWidget(this.projectId)
        placed = message === WIDGET_ADDED
        if (!placed) { this.widgetNote = message; this.watchForCard() }
      } else {
        placed = true
      }
    } catch (e) {
      this.widgetNote = 'Could not add the widget: ' + (e as Error).message
    } finally {
      this.widgetAdding = false
    }
    if (this.disposed) { return }
    this.widgetCards = this.readWidgetCards()
    this.widgetPlacedHere = this.widgetPlacedHere || placed
    if (leave && placed) { this.close() }
  }

  private send(): void {
    let text = this.draft.trim()
    if (this.disposed || text.length === 0 || this.generating) { return }
    this.widgetOffer = false
    this.requestLabel = this.chipLabel
    this.chipLabel = ''
    if (this.makeWidget) {
      this.widgetAsk = text
      this.widgetBeforeVbc2 = this.compiledVbc2
      this.widgetBeforeHad = hasWidgetFunction(this.compiledSource) && !this.widgetFresh
      this.widgetFailure = ''
      this.widgetFailureOpen = false
      this.widgetNote = ''
    }
    if (this.rewriting) {
      this.rewriting = false
      if (this.acceptedBase !== null) { this.restoreBase(this.acceptedBase!) }
    }
    if (this.hasResult()) {
      this.refinePrompt = text
      this.doRefine()
    } else {
      this.prompt = text
      this.doGenerate()
    }
    // Emptied only once the request has gone: with no key, no model or no server it did not, and the words stay to be sent
    // when that is put right.
    if (this.generating || this.runOnOpen) { this.draft = '' }
    this.scrollDown()
  }

  /** A request as the person reads it: Make widget's wording for the model ("The home-screen widget should show: ") is "Widget: ". */
  private shownRequest(text: string): string {
    return text.split(WIDGET_ASK).join('Widget: ')
  }

  /** The request line has more to show when there is a history of requests or the text does not fit on one line. */
  private requestExpands(): boolean {
    return (this.requestHistory.length > 0 && this.requestHistory !== this.acceptedRequest) || this.acceptedRequest.length > 34
  }

  /** What the card says under its title: the run's own last words, or the version when nothing has run yet. */
  private resultNote(): string {
    return this.runs.length > 0 ? this.status : (this.baseVersionNumber > 0 ? 'Version ' + this.baseVersionNumber.toString() : '')
  }

  private scrollDown(): void {
    setTimeout(() => { if (!this.disposed) { this.scroller.scrollEdge(Edge.Bottom) } }, 80)
  }

  /** New starts the thread over; with a result that was never saved it asks first. */
  private confirmNew(): void {
    if (this.generating) { return }
    if (!this.hasUnsavedResult()) {
      this.startFresh()
      return
    }
    this.getUIContext().showAlertDialog({
      title: 'Start a new app?',
      message: 'The app on screen is not saved and will be lost.',
      primaryButton: { value: 'Cancel', action: () => {} },
      secondaryButton: { value: 'Start new', fontColor: app.danger, action: () => { this.startFresh() } }
    })
  }

  private startFresh(): void {
    // "New" means a new app: it is no longer a version of the project this page was opened from.
    this.projectId = ''
    // Nor a widget for it.
    this.makeWidget = false
    this.widgetBase = ''
    this.startNew()
    this.runs = []
    this.program = new RunTotals()
    this.resetRunMetrics()
    this.status = ''
    this.draft = ''
    this.tab = TAB_PREVIEW
    this.fullscreen = false
    this.requestOpen = false
    this.composerOpen = false
    this.scroller.scrollEdge(Edge.Top)
  }

  /** The thread is a list of turns: the person's requests, and under the last one what is being built or was built. */
  build() {
    NavDestination() {
      Stack() {
        Column() {
          if (this.baseError.length > 0 && !this.fullscreen) {
            Text(this.baseError).fontSize(13).fontColor(app.dangerInk).width('100%').padding({ left: 16, right: 16, top: 8 })
          }
          // A program that runs takes the whole space between the bar and the box, as the whole of the screen it is; before
          // and while it is built, and when it was not, the page is a thread of cards.
          if (this.makeWidget && this.baseError.length === 0 && this.hasResult()) {
            this.widgetPane()
          } else if (this.fullscreen && this.hasResult()) {
            this.fullscreenPane()
          } else if (!this.generating && this.hasResult()) {
            this.resultPane()
          } else {
            List({ space: 10, scroller: this.scroller }) {
              // Nothing asked for yet: ready-made requests to start from, as an empty chat has. A tap sends one.
              if (this.runs.length === 0 && !this.generating && this.baseVersionId.length === 0 && !this.hasResult()) {
                ListItem() {
                  ChatStarters({ en: APP_STARTERS, flat: true, onPick: (prompt: string): void => {
                    if (this.generating) { return }
                    this.prompt = prompt
                    this.doGenerate()
                  } })
                }
                if (this.setupHint.length > 0) {
                  ListItem() {
                    Text(this.setupHint).fontSize(12).fontColor(app.inkMuted).padding({ left: 4, right: 4 })
                      .copyOption(CopyOptions.LocalDevice)
                  }
                }
              }
              if (this.generating) {
                ListItem() { this.buildCard() }
              } else if (this.runs.length > 0 && !this.compiled) {
                ListItem() { this.failedCard() }
              }
              if (this.mode === MODE_LOCAL && !this.modelReady && !this.generating && !this.downloading) {
                ListItem() { this.modelCard() }
              }
            }
            .layoutWeight(1)
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .scrollBar(BarState.Off)
          }

          // Full screen can fold the box away, leaving the program the whole screen; a round button brings it back.
          // While a field of the program has the keyboard, the box would only take room from the program.
          if (this.widgetOffer && !this.generating && !this.makeWidget) {
            this.widgetOfferCard()
          }
          if (!(this.fullscreen && this.composerHidden && this.hasResult()) &&
            !(this.keyboardOpen && !this.composerFocused && this.hasResult())) {
            this.composer()
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor(app.background)
        if (this.naming) {
          this.nameOverlay()
        }
        if (this.leaving) {
          this.leaveOverlay()
        }
      }
      .width('100%')
      .height('100%')
    }
    .title(this.makeWidget ? (this.widgetFresh ? 'New widget \u00B7 ' : 'Widget \u00B7 ') + this.widgetTitle : this.baseVersionId.length > 0 ? 'Refine · Version ' + this.baseVersionNumber.toString() :
      (this.projectId.length === 0 ? 'New app' : 'New version'))
    .hideTitleBar((this.fullscreen && this.hasResult()) || this.naming || this.leaving)
    .backgroundColor(app.background)
    .menus(this.barMenus())
    .onBackPressed((): boolean => this.handleBack())
    .onShown(() => { this.destinationShown() })
    .onHidden(() => { this.destinationHidden = true })
  }
}

/** One of the composer's left-out notes as a person reads it: 'value "Pace": ...' is '"Pace": ...'. */
function leftOutLine(line: string): string {
  return line.replace(/^(value|input|field|figure) (?=")/, '')
}
