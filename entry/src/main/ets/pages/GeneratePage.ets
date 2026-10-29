import { copyText } from '../components/Clipboard'
import { common } from '@kit.AbilityKit'
import { KeyboardAvoidMode, window } from '@kit.ArkUI'
import { fileIo as fs } from '@kit.CoreFileKit'
import { http } from '@kit.NetworkKit'
import { request } from '@kit.BasicServicesKit'
import { Version, VersionMetrics, store } from '../vera/ProjectStore'
import { refreshForms } from '../vera/FormUpdater'
import { engine, LlamaEngine, GenerateRequest, GenerateResult, loadRawfileText } from '../vera/LlamaEngine'
import { compileVeraSource, CompileError } from '../vera/VeraCompiler'
import { applyRepair, repairPrompt } from '../vera/VeraRepair'
import { smokeRun } from '../vera/VeraSmoke'
import { logMark, logStep, initTrace, trace, traceCompile } from '../vera/VeraTiming'
import { deepseek, DEEPSEEK_GENERATION_MAX_TOKENS, SideCall } from '../vera/DeepSeekEngine'
import { VeraPreview } from '../components/VeraPreview'
import { settings } from '../vera/SettingsStore'
import { resetLogprobsProbe } from '../vera/JevProxy'
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
import { webSearch } from '../vera/VeraWebSearch'
import { foundResults, liveFiguresNote } from '../vera/LiveFigures'
import { templateSelectEnabled } from '../vera/VeraTemplateSelectFlag'
import { ToolCall, ToolTotal, toolCalls, resetToolLog, toolTotals, toolMs } from '../vera/ToolLog'
import { ServiceNote, serviceNotes, resetServiceHealth, describeService, silent, serviceTrouble } from '../vera/ServiceHealth'
import { Stage, addStage, appMs, yourMs, byWho, WHO_MODEL, WHO_JEV, WHO_SEARCH, WHO_PHONE, WHO_YOU } from '../vera/RunStages'
import { compositionFromJson, compositionToJson, editComposition, selectEdit, Composition, CompositionEdit, EditResult } from '../vera/VeraComposition'

/** How the system prompt picks the std/ui components it describes: 'full', 'phrases' or 'prompt' (VeraUiSelect.ets). */
const UI_SELECT_MODE: string = UI_SELECT_PROMPT
const MAX_RETRIES: number = 3

// vera-server's address is not written down here. It lives in settings, given
// the same way as the API key -- `--ps veraServer http://host:port` -- because
// one person's machine address has no business in a shared repository.
function serverUrl(): string { return settings.getServerUrl() }

// DeepSeek and Local both run the agent loop on the device and differ only in
// which model writes the code; Server hands the whole job to vera-server.
const MODE_DEEPSEEK: string = 'deepseek'
const MODE_SERVER: string = 'server'
const MODE_LOCAL: string = 'local'

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

@Entry
@Component
struct GeneratePage {
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
  /** The lookups of this run (find_sdk_function, find_intent_function, find_ui_component, web_search), for the Metrics tab. */
  @State tools: ToolCall[] = []
  /** Whether the tool calls card shows every call or only its total: closed until tapped. */
  @State toolsOpen: boolean = false
  /** The Metrics pane's real width, measured: a percentage inside the Scroll resolves against a wider box than the one drawn. */
  @State metricsWidth: number = 0
  @State compiledVbc2: string = ''
  /** The running preview's state as it last changed; not @State, as writing it must not redraw the page. */
  private liveState: string = ''
  /** What the next compiled program starts from (VeraPreview.seedState): the state at the moment a refine was asked for. */
  @State carriedState: string = ''
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
  /** Set just before the page closes itself, so that the back press it causes is not asked about again. */
  private closing: boolean = false
  @State tab: string = TAB_PREVIEW
  /** What the one box holds, the settings and the details are open. */
  @State draft: string = ''
  /** The box holds an edit of the last request: sending it runs it again on what was there before it (rewriteRequest). */
  @State rewriting: boolean = false
  @State settingsOpen: boolean = false
  /** The selector route switch is for working on the app, not for making one: folded away until asked for. */
  @State advancedOpen: boolean = false
  /** The program alone over the whole screen, with the box under it; see fullscreenPane. */
  @State fullscreen: boolean = false
  /** Full screen with the request box folded away; see composer. */
  @State composerHidden: boolean = false
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
  /** Components the current system prompt describes; empty means all of them. */
  private uiSelected: string[] = []
  private grammar: string = ''
  private previousSource: string = ''
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

  private prepareRequest(ask: string): void {
    this.finishMetrics(this.runId)
    this.pendingBase = this.currentBase()
    this.pendingRequest = ask
    this.pendingHistory = this.requestHistory.length > 0 ?
      this.requestHistory + '\n\nRefinement:\n' + ask : ask
    this.metricRunId = this.runId + 1
    this.metricMode = this.mode
    this.metricModel = this.mode === MODE_DEEPSEEK ? settings.getModel() :
      (this.mode === MODE_LOCAL ? 'qwen2.5-coder-3b-instruct-q4_k_m' : '')
    this.metricPriced = this.mode === MODE_DEEPSEEK && this.metricModel === 'deepseek-flash' &&
      settings.getBaseUrl().replace(/\/+$/, '') === 'https://api.deepseek.com'
    this.metricRates = [this.ratePerMillion('cache'), this.ratePerMillion('fresh'), this.ratePerMillion('output')]
    this.metricSeenSideCalls = new Set<SideCall>(deepseek.getSideCalls())
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
    this.metricPendingRuns.add(run)
    try {
      return await work()
    } finally {
      this.metricPendingRuns.delete(run)
      if (this.metricStaleRuns.delete(run) && this.metricRunId >= 0) {
        this.metricSeenSideCalls = new Set<SideCall>(deepseek.getSideCalls())
        this.metricTotals.partial = true
      }
    }
  }

  private collectMetricSideCalls(run: number): void {
    if (this.metricRunId !== run || this.metricMode === MODE_SERVER) { return }
    if (this.metricStaleRuns.size > 0) {
      this.metricTotals.partial = true
      return
    }
    for (let call of deepseek.getSideCalls()) {
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
    let completeCache = this.metricMode === MODE_DEEPSEEK && deepseek.lastToolRounds() === 0 &&
      this.metricStaleRuns.size === 0
    let cached = completeCache && known ? deepseek.lastCacheHitTokens() : -1
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

  private startNew(): void {
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
    let params = this.getUIContext().getRouter().getParams() as Record<string, string>
    if (params !== null && params !== undefined) {
      this.projectId = params['projectId'] || ''
      this.baseVersionId = params['baseVersionId'] || ''
      // A request typed on the home screen waits in the box for the person to send it.
      this.prompt = params['prompt'] || ''
      this.runOnOpen = (params['run'] || '').length > 0 && this.prompt.trim().length > 0
    }
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
      } else {
        this.baseError = 'The selected version is unavailable or has no source. Return to the version list.'
      }
    }
    settings.init(context.filesDir)
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
      this.keyboardWindow = win
      win.on('keyboardHeightChange', this.keyboardListener)
    }).catch((e: Error) => { console.warn('VERA keyboard listener unavailable: ' + e.message) })
    this.loadResources().then((): void => {
      // The request came with "send it": it goes now that the prompt and the catalogue are loaded.
      if (this.runOnOpen) { this.runOnOpen = false; this.doGenerate() }
    }).catch((_e: Error): void => {})
  }

  aboutToDisappear(): void {
    if (this.keyboardWindow !== null) {
      try { this.keyboardWindow.off('keyboardHeightChange', this.keyboardListener) } catch (_e) { /* the window is already gone */ }
      this.keyboardWindow = null
    }
  }

  // The key can arrive from a launch parameter while this page sits in the
  // foreground, so re-read it whenever the page comes back into view.
  onPageShow(): void {
    if (this.mode === MODE_DEEPSEEK && !this.generating) {
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
      // The UI catalogue is the same for every request, so it is spliced in
      // once. The intent catalogue is not spliced at
      // all any more: find_intent_function (DeepSeekEngine.ets,
      // VeraIntentIndex.ets) looks it up, along with the raw device
      // registry, when the model decides it needs one.
      this.skillText = skill
      try {
        this.surfaceGuide = await loadRawfileText(mgr, 'vera-surface-skill.txt')
      } catch (e) {
        console.warn('VERA-SURFACE no guide, games go to the agent: ' + (e as Error).message)
      }
      this.promptTemplate = skill
        .replace('{{UI_CATALOG}}', describeCatalogForPrompt())
        .replace('{{UI_TOOL_NOTE}}\n', '')
      // Chat and Generate share index readiness and background embedding work.
      ensureCapabilities(context)
      this.ensureEmbeddingsReady()
      this.systemPrompt = this.promptTemplate
      this.grammar = await loadRawfileText(mgr, 'vera.gbnf')
      this.status = 'Resources loaded'
    } catch (e) {
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
      if (resp.responseCode === 200) {
        let body = resp.result as string
        let health = JSON.parse(body) as Record<string, Object>
        this.status = 'Server ready (' + (health['model'] as string) + ')'
      } else {
        this.status = 'Server error: HTTP ' + resp.responseCode
      }
    } catch (e) {
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
            if (total > 0) {
              this.status = 'Downloading model ' + Math.floor(received * 100 / total).toString() + '%'
            }
          })
          await new Promise<void>((resolve, reject) => {
            task.on('complete', (): void => { resolve() })
            task.on('fail', (err: number): void => { reject(new Error('download failed, code ' + err.toString())) })
          })
          this.status = 'Model downloaded'
          return
        }
        throw new Error('SystemCapability.MiscServices.Download is not supported')
      }
      throw new Error('SystemCapability.Request.FileTransferAgent is not supported')
    } catch (e) {
      this.status = 'Model download failed: ' + (e as Error).message
    } finally {
      this.downloading = false
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

  private doGenerate(): void {
    if (this.prompt.trim().length === 0 || this.baseError.length > 0 || this.generating) { return }
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
    this.generating = true
    this.generatedSource = ''
    this.compiled = false
    this.compileErrors = ''
    this.attempt = 1
    this.attempts = []
    this.totalMs = 0
    this.sideCalls = []
    this.stages = []
    this.services = []
    resetServiceHealth()
    this.troubleNote = ''
    this.tools = []
    resetToolLog()
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
    deepseek.clearSideCalls()
    this.sideCalls = []
    this.stages = []
    this.services = []
    resetServiceHealth()
    this.troubleNote = ''
    this.tools = []
    resetToolLog()
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
    if (route.agent !== null) {
      this.tryLiveFigures(this.prompt.trim(), route)
      return
    }
    this.startAttemptOne(this.prompt.trim())
  }

  /**
   * A new screen that shows a current figure (the weather, a rate, a price) is written by the model on a search made now
   * (LiveFigures.ets), not built by the agent; everything else, and a search that found nothing, goes to the route.
   */
  private async tryLiveFigures(userPrompt: string, route: RouteRequest): Promise<void> {
    let run = this.runId
    if (settings.hasExaKey()) {
      this.status = 'Checking whether it needs current figures...'
      let checkStart = Date.now()
      let query = await this.metricWork(run, (): Promise<string> => deepseek.extractLiveQuery(userPrompt))
      addStage(this.stages, 'Does it need current figures', WHO_MODEL, Date.now() - checkStart)
      if (run !== this.runId || this.cancelRequested) { return }
      if (query.length > 0) {
        this.status = 'Looking up current figures...'
        let searchStart = Date.now()
        let results = await this.metricWork(run, (): Promise<string> => webSearch(query))
        addStage(this.stages, 'Looking up current figures', WHO_SEARCH, Date.now() - searchStart, query)
        if (run !== this.runId || this.cancelRequested) { return }
        let fields: Record<string, Object> = {}
        fields['query'] = query
        fields['found'] = foundResults(results)
        trace('live-figures', fields)
        if (foundResults(results)) {
          this.startAttemptOne(userPrompt, 'Generating', liveFiguresNote(results))
          return
        }
      }
    }
    this.tryRoute(userPrompt, route)
  }

  private async tryRoute(userPrompt: string, route: RouteRequest): Promise<void> {
    let run = this.runId
    this.metricTotals.partial = true
    let host = appAgentHost((s: string): void => { if (run === this.runId) { this.status = s } }, (vbc2: string): void => {
      if (run !== this.runId || this.cancelRequested) { return }
      this.previewVbc2 = vbc2
      this.previewNote = 'Sketching the screen...'
    }, (): boolean => run !== this.runId || this.cancelRequested, this.promptTemplate, this.surfaceGuide)
    host.ask = (question: AgentQuestion): Promise<PersonAnswer> => this.askPerson(question)
    let outcome: RouteOutcome = await this.metricWork(run, (): Promise<RouteOutcome> => buildScreen(route, host))
    if (run !== this.runId) { return }
    if (outcome.kind === OUTCOME_CANCELLED) {
      this.metricTotals.partial = true
      this.finishMetrics(run)
      return
    }
    if (outcome.agent !== null) {
      this.traceAgent(outcome.agent!)
      // After the stages of the check for current figures (tryLiveFigures), if it ran.
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
      (composed.dropped.length > 0 ? '. Left out: ' + composed.dropped.join('; ') : '')
    let endFields: Record<string, Object> = {}
    endFields['ok'] = true
    endFields['attempt'] = 0
    endFields['totalMs'] = this.totalMs
    endFields['waitedMs'] = waited
    endFields['via'] = 'compose'
    trace('gen-end', endFields)
    this.closeRun(true, 0)
  }

  /**
   * Chooses which std/ui components the system prompt describes for this
   * request, then makes the first attempt. Only DeepSeek mode selects; every
   * other mode, and any failure on the way (no extraction, embeddings not
   * ready), describes the whole catalogue. The choice is made once and kept for
   * the retries, which only rewrite the user prompt.
   */
  private async startAttemptOne(userPrompt: string, label: string = 'Generating', plan: string = ''): Promise<void> {
    let run = this.runId
    this.systemPrompt = this.promptTemplate
    this.uiSelected = []
    if (UI_SELECT_MODE !== UI_SELECT_FULL && this.mode === MODE_DEEPSEEK && this.skillText.length > 0) {
      this.status = 'Choosing UI components...'
      let selectStartedAt = Date.now()
      let selected = await this.metricWork(run,
        (): Promise<Set<string> | null> => selectUiForPrompt(UI_SELECT_MODE, userPrompt, this.previousSource))
      logStep('ui-select', selectStartedAt, 'mode=' + UI_SELECT_MODE)
      if (run !== this.runId || this.cancelRequested) { return }
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
    let contextPrompt = this.requestHistory.length > 0 ?
      'Version request history:\n' + this.requestHistory + '\n\nCurrent change request:\n' + userPrompt : userPrompt
    this.runAttempt(plan.length > 0 ? contextPrompt + '\n\n' + plan : contextPrompt, '')
  }

  private async doServerGenerate(ask: string = ''): Promise<void> {
    let submitted = ask.length > 0 ? ask : this.prompt.trim()
    this.prepareRequest(submitted)
    this.cancelRequested = false
    let run = ++this.runId
    this.generating = true
    this.generatedSource = ''
    this.compiled = false
    this.compileErrors = ''
    this.attempts = []
    this.totalMs = 0
    this.sideCalls = []
    this.stages = []
    this.services = []
    resetServiceHealth()
    this.troubleNote = ''
    this.tools = []
    resetToolLog()
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
    try {
      let genStart = Date.now()
      // Refinement: send the base version's source so the server can edit it
      // instead of regenerating from scratch.
      let requestBody: string = this.pendingHistory
      let contentType: string = 'text/plain; charset=utf-8'
      if (this.previousSource.length > 0) {
        let refine = new RefineRequest()
        refine.prompt = this.pendingHistory
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
        this.serverBytecode = decoded.bytecode
        this.compiledVbc2 = decoded.bytecode
        this.compiledSource = decoded.source
        this.compositionJson = ''
        this.modelWrote = true
        this.acceptRequest()
        this.getUIContext().animateTo({ duration: 250, curve: Curve.EaseInOut }, () => { this.composerOpen = false })
        this.tab = TAB_PREVIEW
        this.compiled = true
        this.compileErrors = ''
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
      client.destroy()
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
  private async callModel(request: GenerateRequest, onToken: (token: string) => void, run: number): Promise<GenerateResult> {
    if (this.mode === MODE_DEEPSEEK) {
      // Initial generation, refinement, and retries share reasoning and output settings.
      await ensureCapabilities(this.hostContext())
      if (run !== this.runId || this.cancelRequested) { return new GenerateResult() }
      deepseek.setThinking(true)
      request.maxTokens = DEEPSEEK_GENERATION_MAX_TOKENS
      return deepseek.generate(request, onToken)
    }
    return Promise.resolve(engine.generate(request, onToken))
  }

  private async runAttempt(userPrompt: string, errorFeedback: string): Promise<void> {
    let run = this.runId
    this.generatedSource = ''
    let metrics = new AttemptMetrics()
    metrics.attempt = this.attempt

    let request = new GenerateRequest()
    request.systemPrompt = this.systemPrompt
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
        if (run !== this.runId || this.cancelRequested) { return }
        if (firstTokenAt === 0) { firstTokenAt = Date.now() }
        this.generatedSource += token
      }, run))
      if (run !== this.runId) { return }
      this.recordMetricResult(run, genResult)
      if (genResult.text.length > 0) {
        this.generatedSource = genResult.text
      }
    } catch (e) {
      if (run !== this.runId) { return }
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
      metrics.cacheHitTokens = deepseek.lastCacheHitTokens()
      metrics.finishReason = deepseek.lastFinishReason()
      metrics.thinking = true
      // Prefill from the engine rather than the token callback: the callback
      // only fires on visible content, so with reasoning on it would report
      // the thinking time as waiting.
      let prefill = deepseek.lastPrefillMs()
      if (prefill > 0) { metrics.ttftMs = prefill }
      metrics.thinkMs = deepseek.lastThinkMs()
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
          await this.runAttempt(userPrompt, errorFeedback)
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
      logStep('smoke', smokeStart, 'src=generate attempt=' + this.attempt.toString() + ' ok=' + (errors.length === 0).toString())
      vbc2 = errors.length === 0 ? result.vbc2 : ''
    } catch (e) {
      if (e instanceof CompileError) {
        errors = e.message
      } else {
        errors = (e as Error).message
      }
    }
    metrics.compileMs = Date.now() - compileStart
    logStep('compile', compileStart, 'src=generate attempt=' + this.attempt.toString() + ' ok=' + (errors.length === 0).toString())
    traceCompile('generate', this.attempt, this.generatedSource.trim(), errors)

    // A program cut off at the token ceiling fails to parse somewhere near its
    // end. Saying so is worth more to the next attempt than the parse error,
    // which describes the cut rather than the mistake.
    if (errors.length > 0 && this.mode === MODE_DEEPSEEK && deepseek.lastFinishReason() === 'length') {
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
      this.modelWrote = true
      this.compositionJson = ''
      this.acceptRequest()
      this.status = 'Compiled successfully on attempt ' + this.attempt
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
      this.repairByEdit = !(this.mode === MODE_DEEPSEEK && deepseek.lastFinishReason() === 'length')
      this.attempt++
      this.status = (metrics.failLayer === 'runtime' ? 'Stopped on its first run' : 'Compile failed') +
        ', retrying (attempt ' + this.attempt + '/' + MAX_RETRIES + ')...'
      await this.runAttempt(userPrompt, errors)
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
    this.sideCalls = deepseek.getSideCalls()
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
    this.sideCalls = deepseek.getSideCalls()
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
    if (ask.length === 0 || this.compiledSource.length === 0 || this.generating || this.baseError.length > 0) { return }
    // What the person typed into the preview is kept through the refine.
    this.carriedState = this.liveState
    // A change that only adds, removes, replaces or moves a block of a composed screen is made on its
    // record, with no model rewrite; anything else, and any step that does not hold, refines as before.
    if (this.compositionJson.length > 0 && this.mode === MODE_DEEPSEEK && templateSelectEnabled() && settings.hasSelector()) {
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
    this.generating = true
    this.cancelRequested = false
    let run = ++this.runId
    this.genStartTime = Date.now()
    this.metricTotals.partial = true
    this.status = 'Checking whether this changes the structure...'
    let result: EditResult = await this.metricWork(run, (): Promise<EditResult> => editComposition(ask, record!, this.mode,
      (request: string, c: Composition): Promise<CompositionEdit> => selectEdit(request, c, settings.getSelectorKey())))
    // Stop bumps runId too, and has already said Stopped.
    if (run !== this.runId) { return }
    this.lastTemplatePick = result.note
    if (!result.applied || result.composition === null) {
      this.refineWithModel(ask, true)
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

  private refineWithModel(ask: string, continuing: boolean = false): void {
    // Refine from the last program that compiled, not from generatedSource --
    // a failed attempt leaves its broken text in there.
    this.previousSource = this.compiledSource
    // A game or a scene is changed by edits, with its guide, and played before it is served (AgentSurfaceEdit.ets).
    if (this.mode === MODE_DEEPSEEK && surfaceRouteEnabled() && drawsSurface(this.compiledSource)) {
      this.editSurface(ask, continuing)
      return
    }
    if (this.mode === MODE_SERVER) {
      if (!settings.hasServerUrl()) { this.checkServer(); return }
      this.doServerGenerate(ask)
      return
    }
    if (!continuing) { this.prepareRequest(ask) }
    this.generating = true
    this.compiled = false
    this.compileErrors = ''
    this.attempt = 1
    this.attempts = []
    this.totalMs = 0
    this.sideCalls = []
    this.stages = []
    this.services = []
    resetServiceHealth()
    this.troubleNote = ''
    this.tools = []
    resetToolLog()
    this.serverBytecode = ''
    this.cancelRequested = false
    if (!continuing) { this.runId++ }
    this.failedSource = ''
    this.delta = new SourceDelta()
    this.startRun(ask)
    if (!continuing) { this.genStartTime = Date.now() }
    this.lastRequest = ask
    this.status = 'Refining (attempt 1/' + MAX_RETRIES + ')...'
    this.startAttemptOne(ask, 'Refining')
  }

  /**
   * A change to a program that draws on a ui.Surface: edits made with the guide it was written with, played before they
   * are served. One that does not pass leaves the program on the screen as it was, saying why.
   */
  private async editSurface(ask: string, continuing: boolean): Promise<void> {
    if (!continuing) { this.prepareRequest(ask) }
    this.generating = true
    this.cancelRequested = false
    let run = continuing ? this.runId : ++this.runId
    if (!continuing) { this.genStartTime = Date.now() }
    this.metricTotals.partial = true
    let host = appAgentHost((text: string): void => { if (run === this.runId) { this.status = text } },
      (_vbc2: string): void => {}, (): boolean => run !== this.runId || this.cancelRequested, this.promptTemplate, this.surfaceGuide)
    let base = this.compiledSource
    let made: SurfaceEdit = await this.metricWork(run,
      (): Promise<SurfaceEdit> => editSurfaceProgram(base, ask, this.requestHistory, host))
    if (run !== this.runId) { return }
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

  /** The open question goes with its default: stopping or starting again must not leave the agent waiting. */
  private settleQuestion(given: PersonAnswer): void {
    let answer = this.answerQuestion
    this.answerQuestion = null
    this.questionText = ''
    this.questionOptions = []
    if (answer !== null) { answer(given) }
  }

  /** Puts the agent's question on the screen; the promise settles with the person's tap. */
  private askPerson(question: AgentQuestion): Promise<PersonAnswer> {
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
    if (this.mode === MODE_LOCAL) { engine.stop() }
    if (this.mode === MODE_DEEPSEEK) { deepseek.stop() }
    this.generating = false
    this.totalMs = Date.now() - this.genStartTime
    this.status = 'Stopped'
  }

  /** Save: a new app is named first, an app that already exists takes the result as its next version. */
  private doSave(): void {
    if (this.generating || this.compiledSource.length === 0 || !this.hasResult()) { return }
    if (this.projectId.length === 0) {
      this.saveName = suggestAppName(this.compiledSource, this.acceptedRequest)
      let icon = suggestAppIcon(this.saveName, this.acceptedRequest)
      this.saveIcon = icon.length > 0 && APP_ICONS.indexOf(icon) >= 0 ? icon : DEFAULT_APP_ICON
      this.iconsOpen = false
      this.naming = true
      return
    }
    this.commitSave()
    this.afterSave()
  }

  /** The name was confirmed: the project is made now, with the default picture, and the result is its first version. */
  private confirmName(): void {
    let name = this.saveName.trim()
    if (name.length === 0) { return }
    let project = store.createProject(name, this.saveIcon)
    this.projectId = project.id
    this.naming = false
    this.commitSave()
    this.afterSave()
  }

  private cancelName(): void {
    this.naming = false
    this.leaveAfterSave = false
  }

  private afterSave(): void {
    if (this.leaveAfterSave) {
      this.leaveAfterSave = false
      this.close()
    }
  }

  private close(): void {
    this.closing = true
    this.getUIContext().getRouter().back()
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
  onBackPress(): boolean | void {
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

  private commitSave(): void {
    let note = this.acceptedRequest
    if (note.length > 100) { note = note.substring(0, 100) + '...' }
    let saved = store.createVersion(this.projectId, this.compiledSource, this.compiledVbc2, note,
      this.requestHistory, this.acceptedOrigin, this.acceptedComposition, this.acceptedRequest, this.baseVersionId,
      this.acceptedMetrics)
    // Stay here: the next change is a refinement of what was just saved, and the next Save its own version.
    this.baseVersionId = saved.id
    this.baseVersionNumber = this.nextVersionNumber
    this.nextVersionNumber = this.versionCount() + 1
    this.savedVbc2 = this.compiledVbc2
    this.status = 'Saved as version ' + this.baseVersionNumber.toString()
    refreshForms()
    try {
      this.getUIContext().getPromptAction().showToast({ message: 'Saved as version ' + this.baseVersionNumber.toString() })
    } catch (e) {
      console.error('Show save toast failed: ' + (e as Error).message)
    }
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

  /** Labels for the dashscope model picker, in candidate order. */
  private modelPickerLabels(): string[] {
    let labels: string[] = []
    for (let i = 0; i < settings.modelCandidateCount(); i++) {
      labels.push(settings.modelCandidateLabel(i))
    }
    return labels
  }

  /** Index of the selected model among the candidates, or -1 if it is not one. */
  private selectedModelIndex(): number {
    let m = this.selectedModel.length > 0 ? this.selectedModel : settings.getModel()
    for (let i = 0; i < settings.modelCandidateCount(); i++) {
      if (settings.modelCandidateModel(i) === m) { return i }
    }
    return -1
  }

  /** The selected model is tinted, the others quiet. */
  private modelPickerLook(index: number): AttributeModifier<ButtonAttribute> {
    return this.selectedModelIndex() === index ? new TonalButton() : new QuietButton()
  }

  /**
   * The Jev proxy toggle, like the model picker above it. On routes the
   * composer's selector calls (askJev/selectEdit) through the configured cloud
   * model on-device (JevProxy.ets); off sends them to api.typesafe.ai as before,
   * which needs a separate selector key or the agent route is gated off. The
   * proxy uses the cloud key (getApiKey), not the selector key, so it is offered
   * whenever there is a cloud key -- independent of whether the provider is
   * dashscope (the model picker only shows for dashscope).
   */
  private jevProxyLabel(): string {
    return this.jevProxyOn ? 'Jev proxy: on' : 'Jev proxy: off'
  }

  private jevProxyLook(): AttributeModifier<ButtonAttribute> {
    return this.jevProxyOn ? new TonalButton() : new QuietButton()
  }

  private toggleJevProxy(): void {
    if (this.jevProxyOn) {
      settings.setJevProxy('')
      this.jevProxyOn = false
    } else {
      settings.setJevProxy('1')
      this.jevProxyOn = true
    }
    // Rebuild the status line so the selector note reflects the new state.
    this.checkDeepSeek()
  }

  /** One line of the mode menu: a mark on the one in use, the name, and what it runs on. */
  private modeMenuLabel(mode: string): string {
    let name = mode === MODE_DEEPSEEK ? settings.providerLabel() + ' \u00B7 ' +
      (this.selectedModel.length > 0 ? this.selectedModel : settings.getModel()) :
      (mode === MODE_SERVER ? 'Server' + (settings.hasServerUrl() ? ' \u00B7 ' + serverUrl() : ' \u00B7 no address') :
        'Local \u00B7 Qwen3-Coder-3B')
    return (this.mode === mode ? '\u2713  ' : '     ') + name
  }

  private pickMode(mode: string): void {
    if (this.generating || mode === this.mode) { return }
    this.mode = mode
    this.checkProvider()
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
  @Builder
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
  @Builder
  editCheckPanel() {
    MetricCard({ title: 'Structure edit check', value: '' }) {
      Text(this.lastTemplatePick).fontSize(11).fontColor(app.warningInk).width('100%')
    }
  }

  @Builder
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
  @Builder
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
  @Builder
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
  @Builder
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

  /**
   * The program the model wrote itself (a run the agent did not serve, or a refine): how long it took, what the compiler cost,
   * each attempt, and the runs before it.
   */
  @Builder
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
        Text(this.hasUnsavedResult() ? 'Save this app?' : 'Leave without generating?')
          .fontSize(20).fontWeight(FontWeight.Bold).margin({ bottom: 6 }).width('100%')
        Text(this.hasUnsavedResult() ?
          (this.projectId.length === 0 ? 'It is not saved yet. Leaving now discards it.' :
            'This version is not saved yet. Leaving now discards it.') :
          (this.generating ? 'A program is still being built. Leaving now stops it.' :
            'What you typed has not been used yet. Leaving now discards it.'))
          .fontSize(13).fontColor(app.inkMuted).margin({ bottom: 20 }).width('100%')
        if (this.hasUnsavedResult()) {
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
      TextInput({ placeholder: this.hasResult() || this.baseVersionId.length > 0 ? 'What to change?' : 'Describe the app you want...',
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
    if (this.hasResult() && !this.generating) {
      items.push({
        value: 'Full screen',
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.arrow_up_left_and_arrow_down_right')),
        action: () => { this.setFullscreen(true) }
      })
    }
    items.push({
      value: 'Settings',
      symbolIcon: new SymbolGlyphModifier($r('sys.symbol.gearshape')),
      action: () => { this.settingsOpen = !this.settingsOpen }
    })
    items.push({
      value: 'New',
      symbolIcon: new SymbolGlyphModifier($r('sys.symbol.plus')),
      action: () => { this.confirmNew() }
    })
    return items
  }

  /** What was typed into the program goes with it to the other view, which draws a program of its own. */
  private setFullscreen(on: boolean): void {
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
        VeraPreview({ vbc2: this.compiledVbc2, seedState: this.carriedState, bottomRoom: this.composerHidden ? FOLD_ROOM : 0,
          onStateSnapshot: (encoded: string): void => { this.liveState = encoded } })
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
        if (this.generating || !this.compiled) {
          Row({ space: 8 }) {
            if (this.generating) { LoadingProgress().width(16).height(16) }
            Text(this.status.length > 0 ? this.status : 'Working...')
              .fontSize(12).fontColor(this.generating ? app.inkSoft : app.warningInk).maxLines(3)
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
          Text(this.requestOpen && this.requestHistory.length > 0 ? this.requestHistory : this.acceptedRequest)
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
      }
      .width('100%')

      Stack() {
        // Kept built under the other tabs, hidden, so what was typed into the running program is still there on return.
        VeraPreview({ vbc2: this.compiledVbc2, seedState: this.carriedState,
          onStateSnapshot: (encoded: string): void => { this.liveState = encoded } })
          .width('100%')
          .height('100%')
          .visibility(this.tab === TAB_PREVIEW ? Visibility.Visible : Visibility.Hidden)
        if (this.tab !== TAB_PREVIEW) {
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
      .onClick(() => { this.tab = name })
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

  /** The engine's settings, out of the way until the title bar's gear is tapped: provider, model, selector. */
  @Builder
  settingsPanel() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Button(this.modeLabel() + ' ▾')
          .attributeModifier(new QuietButton())
          .fontSize(12)
          .height(30)
          .enabled(!this.generating)
          .bindMenu([
            { value: this.modeMenuLabel(MODE_DEEPSEEK), action: () => { this.pickMode(MODE_DEEPSEEK) } },
            { value: this.modeMenuLabel(MODE_SERVER), action: () => { this.pickMode(MODE_SERVER) } },
            { value: this.modeMenuLabel(MODE_LOCAL), action: () => { this.pickMode(MODE_LOCAL) } }
          ])
        Text(this.status)
          .fontSize(12)
          .fontColor(this.compiled ? app.successInk : app.inkMuted)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')

      // The three dashscope models (glm-5.2 and the two deepseek-v4 ones) share one key and base URL, so the choice is
      // the model name alone -- which also flips isDeepSeek() and so the request shape. Shown only when the configured
      // endpoint is dashscope; tapping applies and persists.
      if (this.mode === MODE_DEEPSEEK && settings.isDashscopeProvider() && settings.hasApiKey()) {
        Row({ space: 6 }) {
          ForEach(this.modelPickerLabels(), (label: string, index: number) => {
            Button(label)
              .attributeModifier(this.modelPickerLook(index))
              .fontSize(11)
              .height(26)
              .enabled(!this.generating)
              .onClick(() => {
                settings.applyModelCandidate(index)
                // Whether the proxy can use logprobs is per model, so a switch drops any cached rejection.
                resetLogprobsProbe()
                this.selectedModel = settings.getModel()
                this.checkDeepSeek()
              })
          }, (label: string, index: number) => label + index.toString())
        }
        .width('100%')
      }

      // Toggle for the on-device Jev proxy (see jevProxyLabel). Offered for any cloud provider with a key.
      if (this.mode === MODE_DEEPSEEK && settings.hasApiKey()) {
        Text(this.advancedOpen ? 'Advanced \u25B4' : 'Advanced \u25BE').fontSize(12).fontColor(app.inkMuted)
          .padding({ top: 4, bottom: 4 })
          .onClick(() => { this.advancedOpen = !this.advancedOpen })
      }
      if (this.advancedOpen && this.mode === MODE_DEEPSEEK && settings.hasApiKey()) {
        Row({ space: 8 }) {
          Button(this.jevProxyLabel())
            .attributeModifier(this.jevProxyLook())
            .fontSize(11)
            .height(26)
            .enabled(!this.generating)
            .onClick(() => { this.toggleJevProxy() })
          Text(this.jevProxyOn ? 'selector via cloud model' :
            (settings.hasSelectorKey() ? 'selector via TypeSafe' : 'no selector — agent route off'))
            .fontSize(11).fontColor(app.inkMuted).layoutWeight(1)
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(app.surface)
    .borderRadius(14)
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

  private send(): void {
    let text = this.draft.trim()
    if (text.length === 0 || this.generating) { return }
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

  /** The request line has more to show when there is a history of requests or the text does not fit on one line. */
  private requestExpands(): boolean {
    return (this.requestHistory.length > 0 && this.requestHistory !== this.acceptedRequest) || this.acceptedRequest.length > 34
  }

  /** What the card says under its title: the run's own last words, or the version when nothing has run yet. */
  private resultNote(): string {
    return this.runs.length > 0 ? this.status : (this.baseVersionNumber > 0 ? 'Version ' + this.baseVersionNumber.toString() : '')
  }

  private scrollDown(): void {
    setTimeout(() => { this.scroller.scrollEdge(Edge.Bottom) }, 80)
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
    this.startNew()
    this.runs = []
    this.program = new RunTotals()
    this.attempts = []
    this.stages = []
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
    // The windows are siblings of the page, not children of its content: their dimming then covers the title bar too.
    Stack() {
    Navigation() {
      Column() {
        if (this.baseError.length > 0 && !this.fullscreen) {
          Text(this.baseError).fontSize(13).fontColor(app.dangerInk).width('100%').padding({ left: 16, right: 16, top: 8 })
        }
        if (this.settingsOpen && !this.fullscreen) {
          Column() { this.settingsPanel() }
            .width('100%')
            .padding({ left: 12, right: 12, top: 8 })
        }
        // A program that runs takes the whole space between the bar and the box, as the whole of the screen it is; before
        // and while it is built, and when it was not, the page is a thread of cards.
        if (this.fullscreen && this.hasResult()) {
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
        if (!(this.fullscreen && this.composerHidden && this.hasResult()) &&
          !(this.keyboardOpen && !this.composerFocused && this.hasResult())) {
          this.composer()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(app.background)
    }
    .title(this.baseVersionId.length > 0 ? 'Refine · Version ' + this.baseVersionNumber.toString() :
      (this.projectId.length === 0 ? 'New app' : 'New version'))
    .titleMode(NavigationTitleMode.Mini)
    .hideTitleBar(this.fullscreen && this.hasResult())
    .backgroundColor(app.background)
    .menus(this.barMenus())

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
}
