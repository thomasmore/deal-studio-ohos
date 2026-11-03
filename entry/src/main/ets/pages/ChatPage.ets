import { KeyboardAvoidMode, SymbolGlyphModifier } from '@kit.ArkUI'
import { common } from '@kit.AbilityKit'
import { VeraPreview } from '../components/VeraPreview'
import { loadRawfileText } from '../vera/LlamaEngine'
import { logMark, logStep, initTrace } from '../vera/VeraTiming'
import { settings } from '../vera/SettingsStore'
import { consent } from '../vera/VeraConsentStore'
import { describeCatalogForPrompt } from '../vera/VeraUiCatalog'
import { ensureCapabilities } from '../vera/VeraCapabilities'
import { modelSupportNote } from '../vera/VeraEmbeddings'
import { WidgetBuildContext, WidgetReference, recentWidgetConversation, earlierSearchResults, SearchedTurn } from '../vera/VeraWidgetContext'
import { loadCatalogFile } from '../vera/VeraCatalogFile'
import { ChatTurn, ParsedReply, MiniApp, OperationCancellation, parseReply, chatReply, buildMiniApp, chatAgentRequest, recordChatAgent } from '../vera/VeraChat'
import { AttemptStat, ReplyStats, costOf, formatUsd, formatMs, speedOf } from '../vera/VeraChatStats'
import { chats, StoredChat, StoredMessage } from '../vera/ChatStore'
import { store } from '../vera/ProjectStore'
import { AppRouteParams } from '../vera/AppNavigation'
import { compileVeraSource } from '../vera/VeraCompiler'
import { appAgentHost } from '../vera/agent/AgentAppHost'
import { AgentQuestion, PersonAnswer } from '../vera/agent/AgentQuestions'
import { QuestionCard } from '../components/QuestionCard'
import { buildScreen, RouteRequest, RouteOutcome, OUTCOME_AGENT, OUTCOME_NOT_BUILT } from '../vera/agent/VeraBuildRoute'
import { app, TonalButton } from '../components/AppStyle'
import { ChatStarters, STARTERS_ZH, STARTERS_EN } from '../components/ChatStarters'

const APP_NONE: string = 'none'
const APP_DESCRIBING: string = 'describing'
const APP_BUILDING: string = 'building'
const APP_READY: string = 'ready'
const APP_FAILED: string = 'failed'
const SCROLL_EVERY_MS: number = 150

/**
 * One chat message. Observed, so a reply can grow while it streams and a
 * widget can arrive in it later without the list rebuilding the row: a rebuilt
 * row would throw away the running widget and its state.
 */
@Observed
class ChatMessage {
  id: number = 0
  role: string = 'user'
  /** Text before the widget, or all of it when there is no widget. */
  before: string = ''
  /** Text after the widget. */
  after: string = ''
  appDescription: string = ''
  appState: string = APP_NONE
  vbc2: string = ''
  /** While building: a static picture of the program written so far (VeraWidgetPreview). Never saved. */
  previewVbc2: string = ''
  /** While building: what the builder is doing, shown in the bubble. Never saved. */
  buildStatus: string = ''
  /** While building: a blocking question from the agent (agent/AgentQuestions.ets), its answers and the suggested one. Never saved. */
  question: string = ''
  questionOptions: string[] = []
  questionFallback: number = 0
  /** Answers the open question: an index, the person's own words, or null for its default. Never saved. */
  answerQuestion: ((answer: PersonAnswer) => void) | null = null
  /** Added under the streamed text by this page, so the next streamed piece does not wipe it. */
  beforeNote: string = ''
  source: string = ''
  originalRequest: string = ''
  parentMessageId: number = 0
  cutFrom: number = 0
  update: boolean = false
  /** Latest renderer values are reference data, never a revision's initial state. */
  latestState: string = ''
  /** Fences callbacks from a VeraPreview instance after this page disappears. */
  previewGeneration: number = 0
  error: string = ''
  // What the turn cost, in the same terms the Generate screen uses.
  chatMs: number = 0
  chatTtftMs: number = 0
  chatInput: number = 0
  chatCached: number = 0
  chatOutput: number = 0
  searches: number = 0
  searchMs: number = 0
  /** What web_search returned for this reply (earlierSearchResults). */
  searchResults: string[] = []
  widgetMs: number = 0
  attempts: AttemptStat[] = []
  /** Experiment only (experiment/jev-template-select branch): see noteBlocks. */
  templatePick: string = ''
}

/** Everything a set of messages cost, summed. */
class Tally {
  ms: number = 0
  llmMs: number = 0
  deviceMs: number = 0
  searchMs: number = 0
  searches: number = 0
  input: number = 0
  cached: number = 0
  output: number = 0
  widgets: number = 0
  attempts: number = 0
  cost: number = 0
}

function tallyOf(messages: ChatMessage[]): Tally {
  let t = new Tally()
  for (let m of messages) {
    t.ms = t.ms + m.chatMs + m.searchMs + m.widgetMs
    t.llmMs = t.llmMs + m.chatMs
    t.searchMs = t.searchMs + m.searchMs
    t.searches = t.searches + m.searches
    t.input = t.input + m.chatInput
    t.cached = t.cached + m.chatCached
    t.output = t.output + m.chatOutput
    t.cost = t.cost + costOf(m.chatInput, m.chatCached, m.chatOutput)
    if (m.vbc2.length > 0) { t.widgets++ }
    for (let a of m.attempts) {
      t.llmMs = t.llmMs + a.genMs
      t.deviceMs = t.deviceMs + a.compileMs
      t.input = t.input + a.inputTokens
      t.cached = t.cached + a.cachedTokens
      t.output = t.output + a.outputTokens
      t.attempts++
      t.cost = t.cost + costOf(a.inputTokens, a.cachedTokens, a.outputTokens)
    }
  }
  return t
}

@Component
struct StatCell {
  @Prop label: string = ''
  @Prop value: string = ''
  @Prop note: string = ''

  build() {
    // Two nodes on purpose: the outer one owns the width, the inner one the
    // padding, so a padded node with a layout weight cannot outgrow its parent.
    Column() {
      Column({ space: 2 }) {
        Text(this.label).fontSize(10).fontColor(app.inkMuted).maxLines(1)
        Text(this.value).fontSize(17).fontWeight(FontWeight.Bold).fontColor(app.inkStrong)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.note).fontSize(10).fontColor(app.inkMuted).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .padding(10)
    }
    .layoutWeight(1)
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(app.surface)
    .borderRadius(8)
  }
}

/** The numbers for a set of messages, laid out like the Generate screen's metrics pane. */
@Component
struct StatsPanel {
  @Prop tally: Tally = new Tally()
  @Prop attempts: AttemptStat[] = []
  @Prop heading: string = ''
  /** The <<app: ...>> line this reply handed to the widget builder; empty when it built none. */
  @Prop widgetLine: string = ''
  /** Length of the line before it was cut; 0 when it was not. */
  @Prop widgetCutFrom: number = 0
  @Prop widgetUpdate: boolean = false

  private fresh(): number {
    let f = this.tally.input - this.tally.cached
    return f > 0 ? f : 0
  }

  private cacheNote(): string {
    if (this.tally.cached === 0 || this.tally.input === 0) { return 'nothing reused' }
    return 'reused by ' + settings.providerLabel() + ', ' + Math.round(this.tally.cached * 100 / this.tally.input).toString() + '%'
  }

  build() {
    Column({ space: 8 }) {
      if (this.heading.length > 0) {
        Text(this.heading).fontSize(11).fontColor(app.inkMuted).width('100%')
      }
      if (this.widgetLine.length > 0) {
        Column({ space: 4 }) {
          Text(this.widgetUpdate ? 'Widget request (change to the previous widget)' : 'Widget request')
            .fontSize(10).fontColor(app.inkMuted)
          if (this.widgetCutFrom > 0) {
            Text('Cut to ' + this.widgetLine.length.toString() + ' of ' + this.widgetCutFrom.toString() + ' characters')
              .fontSize(10).fontColor(app.dangerInk)
          }
          Text(this.widgetLine).fontSize(12).fontColor(app.inkStrong).fontFamily('monospace')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(10)
        .backgroundColor(app.surface)
        .borderRadius(8)
      }
      Row({ space: 8 }) {
        StatCell({ label: 'Time', value: formatMs(this.tally.ms),
          note: this.tally.attempts > 0 ? 'reply and widget' : 'reply' }).layoutWeight(1)
        StatCell({ label: 'Cost', value: '~' + formatUsd(this.tally.cost),
          note: 'incl. failed attempts' }).layoutWeight(1)
      }.width('100%')
      Row({ space: 8 }) {
        StatCell({ label: 'LLM wall', value: formatMs(this.tally.llmMs), note: 'all calls' }).layoutWeight(1)
        StatCell({ label: 'On device', value: formatMs(this.tally.deviceMs), note: 'compiler only' }).layoutWeight(1)
      }.width('100%')
      Row({ space: 8 }) {
        StatCell({ label: 'Input', value: this.tally.input.toString() + ' toks',
          note: 'rules, history, request' }).layoutWeight(1)
        StatCell({ label: 'Cached', value: this.tally.cached.toString() + ' toks', note: this.cacheNote() }).layoutWeight(1)
      }.width('100%')
      Row({ space: 8 }) {
        StatCell({ label: 'Fresh', value: this.fresh().toString() + ' toks',
          note: 'input at full price' }).layoutWeight(1)
        StatCell({ label: 'Output', value: this.tally.output.toString() + ' toks',
          note: 'text and programs' }).layoutWeight(1)
      }.width('100%')
      if (this.tally.searches > 0) {
        Row({ space: 8 }) {
          StatCell({ label: 'Web search', value: this.tally.searches.toString() + ' calls',
            note: formatMs(this.tally.searchMs) + ' in all' }).layoutWeight(1)
          StatCell({ label: 'Widgets', value: this.tally.widgets.toString(),
            note: this.tally.attempts.toString() + (this.tally.attempts === 1 ? ' build attempt' : ' build attempts') }).layoutWeight(1)
        }.width('100%')
      } else if (this.tally.attempts > 0) {
        Row({ space: 8 }) {
          StatCell({ label: 'Widgets', value: this.tally.widgets.toString(),
            note: this.tally.attempts.toString() + (this.tally.attempts === 1 ? ' build attempt' : ' build attempts') }).layoutWeight(1)
        }.width('100%')
      }
      ForEach(this.attempts, (a: AttemptStat) => {
        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Text('#' + a.attempt.toString()).fontSize(13).fontWeight(FontWeight.Bold)
            Text(a.success ? '✓' : '✗ ' + a.verdict)
              .fontSize(11)
              .fontColor(a.success ? app.successInk : app.dangerInk)
              .backgroundColor(a.success ? app.successFill : app.dangerFill)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .borderRadius(6)
              .maxLines(2)
          }.width('100%')
          Row({ space: 8 }) {
            StatCell({ label: 'Wait', value: a.ttftMs > 0 ? formatMs(a.ttftMs) : '—',
              note: 'until first token' }).layoutWeight(1)
            if (a.thinkMs > 0) {
              StatCell({ label: 'Think', value: formatMs(a.thinkMs), note: 'reasoning' }).layoutWeight(1)
            }
            StatCell({ label: 'Write', value: formatMs(Math.max(0, a.genMs - a.ttftMs - a.thinkMs)),
              note: 'streaming code' }).layoutWeight(1)
          }.width('100%').alignItems(VerticalAlign.Top)
          Row({ space: 8 }) {
            StatCell({ label: 'Compile', value: a.compileMs > 0 ? formatMs(a.compileMs) : '—',
              note: 'on device' }).layoutWeight(1)
            StatCell({ label: 'Speed', value: speedOf(a), note: 'output after the wait' }).layoutWeight(1)
          }.width('100%').alignItems(VerticalAlign.Top)
          Row({ space: 8 }) {
            StatCell({ label: 'Preview', value: a.previewMs > 0 ? formatMs(a.previewMs) : '—',
              note: 'picture before handlers' }).layoutWeight(1)
            StatCell({ label: 'Lead', value: a.previewMs > 0 ? formatMs(Math.max(0, a.genMs - a.previewMs)) : '—',
              note: 'shown before done' }).layoutWeight(1)
          }.width('100%').alignItems(VerticalAlign.Top)
        }
        .width('100%')
        .padding(10)
        .backgroundColor(app.surface)
        .borderRadius(8)
      })
    }
    .width('100%')
    .padding(10)
    .backgroundColor(app.background)
    .borderRadius(10)
  }
}

@Component
struct MessageBubble {
  @ObjectLink msg: ChatMessage
  @Prop showStats: boolean = false
  @Prop chatId: string = ''
  @Prop destinationHidden: boolean = false
  @State showCode: boolean = false

  /** Answers the widget's open question and takes the card away. */
  private settle(given: PersonAnswer): void {
    let answer = this.msg.answerQuestion
    // A null handler means the owning ChatPage has already closed this question.
    if (answer === null) { return }
    this.msg.answerQuestion = null
    this.msg.question = ''
    answer(given)
  }

  private snapshotHandler(generation: number): (encoded: string) => void {
    return (encoded: string): void => {
      if (this.msg.previewGeneration === generation) {
        this.msg.latestState = encoded
      }
    }
  }

  build() {
    Column({ space: 8 }) {
      if (this.msg.before.length > 0) {
        Text(this.msg.before)
          .fontSize(16)
          .fontColor(this.msg.role === 'user' ? app.surface : app.inkStrong)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor(this.msg.role === 'user' ? app.primary : app.surface)
          .borderRadius(14)
          .constraintSize({ maxWidth: '85%' })
          .copyOption(CopyOptions.LocalDevice)
      }
      if (this.msg.appState === APP_DESCRIBING) {
        Text('Planning a widget...')
          .fontSize(13)
          .fontColor(app.inkSoft)
          .padding(12)
          .backgroundColor(app.surface)
          .borderRadius(14)
      }
      if (this.msg.appState === APP_BUILDING && this.msg.question.length > 0) {
        QuestionCard({ question: this.msg.question, options: this.msg.questionOptions, fallback: this.msg.questionFallback,
          onPick: (index: number): void => { this.settle(index) },
          onTyped: (text: string): void => { this.settle(text) } })
          .constraintSize({ maxWidth: '92%' })
      }
      if (this.msg.appState === APP_BUILDING && this.msg.previewVbc2.length === 0) {
        Row({ space: 8 }) {
          LoadingProgress().width(18).height(18)
          Text(this.msg.buildStatus.length > 0 ? this.msg.buildStatus : 'Building a widget...')
            .fontSize(13).fontColor(app.inkSoft).layoutWeight(1)
        }
        .padding(12)
        .backgroundColor(app.surface)
        .borderRadius(14)
      } else if (this.msg.appState === APP_FAILED) {
        Text(this.msg.error === 'Stopped' ? 'Widget stopped' : 'The widget could not be built: ' + this.msg.error.substring(0, 240))
          .fontSize(12)
          .fontColor(app.dangerInk)
          .padding(10)
          .backgroundColor(app.dangerFill)
          .borderRadius(10)
          .copyOption(CopyOptions.LocalDevice)
      }
      // One branch for the preview and the finished widget, so the same
      // renderer is handed the finished program in place instead of a new one
      // appearing where the picture was.
      if (this.msg.appState === APP_READY || (this.msg.appState === APP_BUILDING && this.msg.previewVbc2.length > 0)) {
        VeraPreview({ previewOnly: this.msg.appState !== APP_READY, destinationHidden: this.destinationHidden,
          vbc2: this.msg.appState === APP_READY ? this.msg.vbc2 : this.msg.previewVbc2, embedded: true,
          persistKey: this.chatId.length > 0 ? chats.stateKey(this.chatId, this.msg.id) : '',
          onStateSnapshot: this.snapshotHandler(this.msg.previewGeneration) })
          .width('100%')
          .borderRadius(14)
          .clip(true)
          .backgroundColor(app.surface)
          .opacity(this.msg.appState === APP_READY ? 1 : 0.6)
        if (this.msg.appState === APP_BUILDING) {
          Row({ space: 8 }) {
            LoadingProgress().width(14).height(14)
            Text(this.msg.buildStatus.length > 0 ? this.msg.buildStatus : 'Finishing the widget...')
              .fontSize(12).fontColor(app.inkMuted).layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 4, right: 4 })
        }
      }
      if (this.msg.after.length > 0) {
        Text(this.msg.after)
          .fontSize(16)
          .fontColor(app.inkStrong)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor(app.surface)
          .borderRadius(14)
          .constraintSize({ maxWidth: '85%' })
          .copyOption(CopyOptions.LocalDevice)
      }
      if (this.showStats && this.msg.role === 'assistant' && this.msg.chatInput + this.msg.attempts.length > 0) {
        StatsPanel({ tally: tallyOf([this.msg]), attempts: this.msg.attempts, heading: 'This reply',
          widgetLine: this.msg.appDescription, widgetCutFrom: this.msg.cutFrom, widgetUpdate: this.msg.update })
      }
      // Experiment only (experiment/jev-template-select branch): survives
      // hilog's ring buffer getting overwritten by a busy widget's own
      // logging -- see ChatMessage.templatePick and noteBlocks.
      if (this.showStats && this.msg.templatePick.length > 0) {
        Text('Jev: ' + this.msg.templatePick)
          .fontSize(11)
          .fontColor(app.warningInk)
          .padding({ left: 12, right: 12, top: 2, bottom: 6 })
      }
      // The program behind the widget, next to the numbers about how it was
      // built. Collapsed by default: a whole program would push the next
      // message out of view.
      if (this.showStats && this.msg.role === 'assistant' && this.msg.source.length > 0) {
        Column({ space: 6 }) {
          Row() {
            Text('Widget code').fontSize(13).fontColor(app.inkSoft).layoutWeight(1)
            Text(this.showCode ? 'Hide' : 'Show').fontSize(13).fontColor(app.primary)
          }
          .width('100%')
          .onClick(() => { this.showCode = !this.showCode })
          if (this.showCode) {
            Scroll() {
              Text(this.msg.source)
                .fontSize(11)
                .fontFamily('monospace')
                .fontColor(app.inkStrong)
                .width('100%')
                .copyOption(CopyOptions.LocalDevice)
            }
            .width('100%')
            .constraintSize({ maxHeight: 420 })
            .scrollBar(BarState.Auto)
          }
        }
        .width('100%')
        .padding(10)
        .backgroundColor(app.surface)
        .borderRadius(10)
      }
    }
    .width('100%')
    .alignItems(this.msg.role === 'user' ? HorizontalAlign.End : HorizontalAlign.Start)
  }
}

class ChatPageParams extends AppRouteParams {
  prompt: string = ''
  run: string = ''
}

/**
 * Lifetime of one user turn. A turn owns its reply and any widget build
 * started from that reply. It remains valid after chatReply completes while
 * its queued widget build is still running.
 */
class ChatRunContext implements OperationCancellation {
  id: number = 0
  pageGeneration: number = 0
  cancelled: boolean = false
  replyFinished: boolean = false
  pendingBuilds: number = 0
  private cancelCallbacks: (() => void)[] = []

  constructor(id: number, pageGeneration: number) {
    this.id = id
    this.pageGeneration = pageGeneration
  }

  isCancelled(): boolean {
    return this.cancelled
  }

  onCancel(callback: () => void): () => void {
    if (this.cancelled) {
      callback()
      return (): void => {}
    }
    this.cancelCallbacks.push(callback)
    return (): void => {
      this.cancelCallbacks = this.cancelCallbacks.filter((item: () => void): boolean => item !== callback)
    }
  }

  cancel(): void {
    if (this.cancelled) { return }
    this.cancelled = true
    let callbacks = this.cancelCallbacks
    this.cancelCallbacks = []
    for (let callback of callbacks) {
      try { callback() } catch (_e) {}
    }
  }
}

@Component
export struct ChatPage {
  params: AppRouteParams = new AppRouteParams()
  private disposed: boolean = false
  /** Monotonically changes on each appearance/disappearance of this page. */
  private lifecycleGeneration: number = 0
  private nextRunId: number = 1
  private activeRuns: ChatRunContext[] = []

  @Consume('navPathStack') pathStack: NavPathStack

  @State messages: ChatMessage[] = []
  @State draft: string = ''
  @State busy: boolean = false
  @State canStop: boolean = false
  @State status: string = ''
  // The active model, mirrored from settings so the idle status line can show it
  // and re-render when it changes (e.g. the model was picked on the Generate page
  // while Chat was in the background). settings is not @State, so reading it
  // directly would not refresh; synced in aboutToAppear and NavDestination.onShow.
  @State selectedModel: string = ''
  @State showStats: boolean = false
  @State destinationHidden: boolean = false
  @State chatId: string = ''
  @State title: string = ''
  private createdAt: number = 0
  private scroller: Scroller = new Scroller()
  private skillPrompt: string = ''
  private resourcesReady: Promise<void> | null = null
  private resourcesLoaded: boolean = false
  private nextId: number = 1
  private lastScrollAt: number = 0
  /** Widget builds run one at a time: the DeepSeek engine has a single generation in flight. */
  private buildQueue: Promise<void> = Promise.resolve()
  /** The composed template a completion started from, kept for when the model cannot finish it. */

  private isPageActive(generation: number): boolean {
    return !this.disposed && generation === this.lifecycleGeneration
  }

  private isRunActive(run: ChatRunContext): boolean {
    return !run.cancelled && this.isPageActive(run.pageGeneration)
  }

  private createRun(): ChatRunContext {
    let run = new ChatRunContext(this.nextRunId++, this.lifecycleGeneration)
    this.activeRuns.push(run)
    this.canStop = true
    return run
  }

  private releaseRunIfIdle(run: ChatRunContext): void {
    if (run.cancelled || (run.replyFinished && run.pendingBuilds === 0)) {
      this.activeRuns = this.activeRuns.filter((item: ChatRunContext): boolean => item.id !== run.id)
    }
    if (!this.disposed) { this.canStop = this.activeRuns.length > 0 }
  }

  private cancelActiveRuns(): void {
    for (let run of this.activeRuns) {
      run.cancel()
    }
    this.activeRuns = []
    if (!this.disposed) { this.canStop = false }
  }

  private stopChat(): void {
    if (this.disposed || !this.canStop) { return }
    this.cancelActiveRuns()
    for (let msg of this.messages) {
      let answer = msg.answerQuestion
      msg.answerQuestion = null
      msg.question = ''
      msg.questionOptions = []
      msg.questionFallback = 0
      if (msg.appState === APP_DESCRIBING || msg.appState === APP_BUILDING) {
        msg.previewGeneration++
        msg.appState = APP_FAILED
        msg.error = 'Stopped'
      }
      msg.previewVbc2 = ''
      msg.buildStatus = ''
      if (answer !== null) { answer(null) }
    }
    this.busy = false
    this.status = 'Stopped'
    this.scrollDown(true)
    this.persist()
  }

  private hostContext(): common.Context {
    let context = this.getUIContext().getHostContext()
    if (context === undefined) {
      this.status = 'Chat host context is unavailable'
      throw new Error(this.status)
    }
    return context
  }

  /** The chat as last written (or as opened), to tell whether leaving has anything to save. */
  private lastSavedJson: string = ''

  aboutToAppear(): void {
    this.disposed = false
    this.lifecycleGeneration++
    this.busy = false
    this.canStop = false
    let generation = this.lifecycleGeneration
    let dir = this.hostContext().filesDir
    settings.init(dir)
    this.selectedModel = settings.getModel()
    consent.init(dir)
    // The store VeraPreview saves a widget's state in, and the chats themselves.
    store.init(dir)
    chats.init(dir)
    initTrace(dir)
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE)
    let params = this.params as ChatPageParams
    let runOnOpen = false
    if (params.chatId.length > 0) {
      this.openChat(params.chatId)
    } else {
      this.draft = params.prompt || ''
      runOnOpen = (params.run || '').length > 0 && this.draft.trim().length > 0
    }
    this.loadResources(generation).then((): void => {
      if (this.isPageActive(generation) && runOnOpen) { this.send().catch((_e: Error): void => {}) }
    }).catch((_e: Error): void => {})
  }

  aboutToDisappear(): void {
    // Fence first: any continuation/callback arriving below this point is stale.
    this.disposed = true
    this.lifecycleGeneration++
    this.cancelActiveRuns()
    for (let msg of this.messages) {
      // Invalidate callbacks held by VeraPreview instances from this page lifetime.
      msg.previewGeneration++
      let answer = msg.answerQuestion
      msg.answerQuestion = null
      msg.question = ''
      if (answer !== null) { answer(null) }
    }
    // A not-yet-completed resource load belonged to the old page generation.
    // Let its underlying reads finish, but allow a new appearance to retry.
    if (!this.resourcesLoaded) { this.resourcesReady = null }
    this.persist()
  }

  private destinationShown(): void {
    if (this.disposed) { return }
    this.destinationHidden = false
    // The model may have been changed on the Generate page while this page was in
    // the background; re-read it so the idle status line shows what a reply will use.
    this.selectedModel = settings.getModel()
    if (!settings.hasApiKey()) {
      this.status = 'No cloud API key yet (see CLAUDE.md)'
    } else if (this.status.startsWith('No cloud API key') || this.status.startsWith('No DeepSeek')) {
      this.status = ''
    }
  }

  /** What the idle status line shows: the provider, the active model a reply will use, and the masked key. */
  private readyLine(): string {
    let model = this.selectedModel.length > 0 ? this.selectedModel : settings.getModel()
    return settings.providerLabel() + ' · ' + model + ' · key ' + settings.maskedKey()
  }

  /**
   * The idle status line: the ready line plus the model-support note (stub-build
   * warning) when there is one, so the note no longer hides the provider/model.
   * With no key, just the note (if any). Shown only when status is empty -- i.e.
   * not Thinking, not an error, not the no-key prompt.
   */
  private idleLine(): string {
    let note = modelSupportNote()
    // Provider, model and key are for working on the app: the line speaks only when something needs saying.
    return note
  }

  /** Brings a saved chat back. A widget that was still building when it was closed cannot be resumed. */
  private openChat(id: string): void {
    let saved = chats.load(id)
    if (saved === null) { return }
    this.chatId = saved!.id
    this.title = saved!.title
    this.createdAt = saved!.createdAt
    this.nextId = saved!.nextId
    let restored: ChatMessage[] = []
    for (let m of saved!.messages) {
      let msg = new ChatMessage()
      msg.id = m.id
      msg.role = m.role
      msg.before = m.before
      msg.after = m.after
      msg.appDescription = m.appDescription
      msg.appState = m.appState
      msg.vbc2 = m.vbc2
      msg.source = m.source
      msg.originalRequest = m.originalRequest
      msg.parentMessageId = m.parentMessageId
      msg.cutFrom = m.cutFrom
      msg.update = m.update
      msg.error = m.error
      msg.chatMs = m.chatMs
      msg.chatTtftMs = m.chatTtftMs
      msg.chatInput = m.chatInput
      msg.chatCached = m.chatCached
      msg.chatOutput = m.chatOutput
      msg.searches = m.searches
      msg.searchMs = m.searchMs
      msg.searchResults = m.searchResults
      msg.widgetMs = m.widgetMs
      msg.attempts = m.attempts
      msg.templatePick = m.templatePick
      if (msg.appState === APP_DESCRIBING || msg.appState === APP_BUILDING) {
        msg.appState = APP_FAILED
        msg.error = 'The chat was closed while this widget was still being built.'
      }
      restored.push(msg)
    }
    this.messages = restored
    // What opening it would write back: if nothing changes, leaving writes nothing.
    this.lastSavedJson = JSON.stringify(this.storedChat())
  }

  /** Writes the chat down. Called whenever something finishes, and on leaving. */
  private persist(): void {
    if (this.messages.length === 0) { return }
    if (this.chatId.length === 0) {
      this.chatId = chats.newId()
      this.createdAt = Date.now()
    }
    let chat = this.storedChat()
    // Looking at a chat is not changing it: only a changed chat is written, which moves it up the list.
    let json = JSON.stringify(chat)
    if (json === this.lastSavedJson) { return }
    chats.save(chat)
    this.lastSavedJson = json
  }

  private storedChat(): StoredChat {
    let chat = new StoredChat()
    chat.id = this.chatId
    chat.title = this.title
    chat.createdAt = this.createdAt
    chat.nextId = this.nextId
    for (let m of this.messages) {
      let sm = new StoredMessage()
      sm.id = m.id
      sm.role = m.role
      sm.before = m.before
      sm.after = m.after
      sm.appDescription = m.appDescription
      sm.appState = m.appState
      sm.vbc2 = m.vbc2
      sm.source = m.source
      sm.originalRequest = m.originalRequest
      sm.parentMessageId = m.parentMessageId
      sm.cutFrom = m.cutFrom
      sm.update = m.update
      sm.error = m.error
      sm.chatMs = m.chatMs
      sm.chatTtftMs = m.chatTtftMs
      sm.chatInput = m.chatInput
      sm.chatCached = m.chatCached
      sm.chatOutput = m.chatOutput
      sm.searches = m.searches
      sm.searchMs = m.searchMs
      sm.searchResults = m.searchResults
      sm.widgetMs = m.widgetMs
      sm.attempts = m.attempts
      sm.templatePick = m.templatePick
      chat.messages.push(sm)
    }
    return chat
  }

  private async loadResources(pageGeneration: number): Promise<void> {
    if (this.resourcesLoaded) { return }
    if (this.resourcesReady === null) {
      this.resourcesReady = (async (): Promise<void> => {
        try {
          let context = this.hostContext()
          let capabilities = ensureCapabilities(context)
          loadCatalogFile(context.filesDir)
          let skill = await loadRawfileText(context.resourceManager, 'vera-skill.txt')
          if (!this.isPageActive(pageGeneration)) { return }
          let widget = await loadRawfileText(context.resourceManager, 'vera-widget.txt')
          if (!this.isPageActive(pageGeneration)) { return }
          if (skill.trim().length === 0 || widget.trim().length === 0) {
            throw new Error('Widget prompt resources are empty.')
          }
          let prompt = skill
            .replace('{{UI_CATALOG}}', describeCatalogForPrompt())
            .replace('{{UI_TOOL_NOTE}}\n', '') + widget
          await capabilities
          if (!this.isPageActive(pageGeneration)) { return }
          this.skillPrompt = prompt
          this.resourcesLoaded = true
          // The model-support note (stub-build warning) is shown by idleLine()
          // alongside the provider/model, not parked in status where it would
          // hide the ready line on a stub build.
        } catch (e) {
          if (this.isPageActive(pageGeneration)) {
            this.status = 'Failed to load resources: ' + (e as Error).message
          }
          throw e as Error
        }
      })()
    }
    await this.resourcesReady!
  }

  private scrollDown(force: boolean = false): void {
    let generation = this.lifecycleGeneration
    if (!this.isPageActive(generation)) { return }
    let now = Date.now()
    if (!force && now - this.lastScrollAt < SCROLL_EVERY_MS) { return }
    this.lastScrollAt = now
    setTimeout((): void => {
      if (this.isPageActive(generation)) {
        this.scroller.scrollEdge(Edge.Bottom)
      }
    }, 60)
  }

  private history(): ChatTurn[] {
    let turns: ChatTurn[] = []
    for (let m of this.messages) {
      let text = m.before
      if (m.appDescription.length > 0 && m.role === 'assistant') {
        text = text + '\n[widget messageId=' + m.id.toString() + ', status=' + m.appState + ': ' + m.appDescription + ']'
      }
      if (m.after.length > 0) { text = text + '\n' + m.after }
      if (text.trim().length === 0) { continue }
      let t = new ChatTurn()
      t.messageId = m.id
      t.role = m.role
      t.text = text.trim()
      turns.push(t)
    }
    return turns
  }

  /** Capture scalar values before the reply or a queued build can change them. */
  private referenceSnapshots(): WidgetReference[] {
    let references: WidgetReference[] = []
    for (let msg of this.messages) {
      if (msg.role !== 'assistant' || msg.appState !== APP_READY) { continue }
      let ref = new WidgetReference()
      ref.messageId = msg.id
      ref.source = msg.source
      ref.originalRequest = msg.originalRequest
      ref.brief = msg.appDescription
      ref.latestState = msg.latestState
      references.push(ref)
    }
    return references
  }

  /** Stream visible text. A widget already handed to the builder keeps its state. */
  private apply(msg: ChatMessage, parsed: ParsedReply, run: ChatRunContext): void {
    if (!this.isRunActive(run)) { return }
    if (this.disposed) { return }
    msg.before = parsed.before + msg.beforeNote
    msg.after = parsed.after
    // A failure the builder already reported (startWidget, run while the reply
    // was still streaming, found no such widget) stands: the description in a
    // later chunk must not turn it back into "describing".
    let builderFailed = msg.appState === APP_FAILED && parsed.error.length === 0
    if (msg.appState === APP_BUILDING || msg.appState === APP_READY || builderFailed) {
      this.scrollDown()
      return
    }
    if (parsed.error.length > 0) {
      msg.appState = APP_FAILED
      msg.error = parsed.error
      msg.appDescription = ''
    } else if (parsed.describing || parsed.appDescription.length > 0) {
      msg.appState = APP_DESCRIBING
    }
    this.scrollDown()
  }

  /**
   * The saved chats. This page is replaced by the list rather than covered by
   * it, so Back from a chat opened there returns to the list, and from the
   * list to the projects. The chat is saved on the way out, as on Back.
   */
  private openHistory(): void {
    if (this.disposed) { return }
    if (this.pathStack.getAllPathName().indexOf('chatList') >= 0) {
      this.pathStack.popToName('chatList')
      return
    }
    this.pathStack.replacePath({ name: 'chatList', param: new AppRouteParams() })
  }

  /** Asks the last message again: it is taken back out of the thread and sent as if just typed. */
  private retryLast(): void {
    if (this.busy || this.messages.length === 0) { return }
    let last = this.messages[this.messages.length - 1]
    if (last.role !== 'user') { return }
    this.messages = this.messages.slice(0, this.messages.length - 1)
    this.draft = last.before
    this.send().catch((_e: Error): void => {})
  }

  private async send(): Promise<void> {
    let text = this.draft.trim()
    if (this.disposed || text.length === 0 || this.busy) { return }
    let run = this.createRun()
    let references = this.referenceSnapshots()
    this.draft = ''
    this.busy = true
    let mine = new ChatMessage()
    mine.id = this.nextId++
    mine.role = 'user'
    mine.before = text
    if (this.title.length === 0) {
      this.title = text.length > 48 ? text.substring(0, 48) + '...' : text
    }
    this.messages = [...this.messages, mine]
    let turns = this.history()
    let context = new WidgetBuildContext()
    context.currentRequest = text
    context.originalRequest = text
    context.recentConversation = recentWidgetConversation(turns)
    // Taken before this turn's reply is added: the reply that answered the person last.
    context.verifiedSearchResults = earlierSearchResults(this.messages.map((m: ChatMessage): SearchedTurn => {
      let t = new SearchedTurn()
      t.role = m.role
      t.searchResults = m.searchResults
      return t
    }))
    let reply = new ChatMessage()
    reply.id = this.nextId++
    reply.role = 'assistant'
    this.messages = [...this.messages, reply]
    this.scrollDown(true)
    this.status = 'Thinking...'
    let stats = new ReplyStats()
    let started = false
    let sawText = false
    logMark('chat-send', 'chars=' + text.length.toString())
    try {
      let capsStartedAt = Date.now()
      await ensureCapabilities(this.hostContext())
      if (!this.isRunActive(run)) { return }
      logStep('ensure-capabilities', capsStartedAt)
      let raw = await chatReply(turns, (soFar: string): void => {
        if (!this.isRunActive(run)) { return }
        if (!sawText) { sawText = true; logMark('chat-first-text') }
        if (this.status === 'Thinking...') { this.status = '' }
        let parsed = parseReply(soFar)
        this.apply(reply, parsed, run)
        // A JSON marker is complete and final the moment its >> arrives -- a
        // second one would be an error either way -- so the build starts
        // while the rest of the reply is still being written.
        if (!started && parsed.structured && parsed.error.length === 0 && parsed.appDescription.length > 0) {
          started = true
          console.info('VERA-CHAT widget started before the reply ended, at ' + soFar.length.toString() + ' chars')
          this.startWidget(reply, parsed, references, context, run)
        }
      }, (status: string): void => {
        if (!this.isRunActive(run)) { return }
        this.status = status.length > 0 ? status : 'Thinking...'
      }, stats, (verified: string): void => {
        if (!this.isRunActive(run)) { return }
        context.verifiedSearchResults.push(verified)
        reply.searchResults.push(verified)
      }, run)
      if (!this.isRunActive(run)) { return }
      logMark('chat-reply-done')
      console.info('VERA-CHAT reply: ' + raw)
      let parsed = parseReply(raw, true)
      this.apply(reply, parsed, run)
      if (started && parsed.error.length > 0) {
        // The rest of the reply broke the marker (a second one, say). The
        // build already under way is dropped when it finishes.
        reply.appState = APP_FAILED
        reply.error = parsed.error
      } else if (!started && parsed.error.length === 0 && parsed.appDescription.length > 0) {
        this.startWidget(reply, parsed, references, context, run)
      }
    } catch (e) {
      if (this.isRunActive(run)) {
        this.status = (e as Error).message
        if (reply.appState === APP_DESCRIBING) {
          reply.appState = APP_FAILED
          reply.error = 'The reply ended before the widget request was complete.'
        }
        // A reply that never started is not worth an empty row.
        if (reply.before.length === 0 && reply.appState === APP_NONE) {
          this.messages = this.messages.filter((m: ChatMessage): boolean => m.id !== reply.id)
        }
      }
    } finally {
      // chatReply may complete after the page has disappeared. Never publish
      // its result, stats, status or busy flag into a newer page generation.
      try {
        if (this.isRunActive(run)) {
          reply.chatMs = stats.ms
          reply.chatTtftMs = stats.ttftMs
          reply.chatInput = stats.inputTokens
          reply.chatCached = stats.cachedTokens
          reply.chatOutput = stats.outputTokens
          reply.searches = stats.searches
          reply.searchMs = stats.searchMs
          this.busy = false
          this.scrollDown(true)
          this.persist()
        }
      } finally {
        run.replyFinished = true
        this.releaseRunIfIdle(run)
      }
    }
  }

  /** Resolve the widget a marker asks for and hand it to the builder. */
  private startWidget(reply: ChatMessage, parsed: ParsedReply, references: WidgetReference[],
      context: WidgetBuildContext, run: ChatRunContext): void {
    if (!this.isRunActive(run)) { return }
    context.brief = parsed.appDescription
    context.request = parsed.appRequest
    // A record line written out for a widget the chat already has is about that widget: it is refined, not built again.
    if (parsed.mode === 'create' && parsed.recordMessageId > 0 &&
        references.some((ref: WidgetReference): boolean => ref.messageId === parsed.recordMessageId)) {
      parsed.mode = 'refine'
      parsed.targetMessageId = parsed.recordMessageId
    }
    if (parsed.mode === 'refine' || parsed.update) {
      let target: WidgetReference | undefined = parsed.update ? references[references.length - 1] :
        references.find((ref: WidgetReference): boolean => ref.messageId === parsed.targetMessageId)
      if (target === undefined) {
        reply.appState = APP_FAILED
        reply.error = 'The selected widget is unavailable. Specify an existing widget.'
        return
      }
      context.parentMessageId = target.messageId
      context.source = target.source
      context.originalRequest = target.originalRequest.length > 0 ? target.originalRequest : target.brief
      context.latestState = target.latestState
      if (target.source.length === 0) {
        reply.beforeNote = '\nThis older widget has no saved source. I will recreate it from its description.'
        reply.before = parsed.before + reply.beforeNote
      }
    }
    reply.appDescription = parsed.appDescription
    reply.cutFrom = 0
    reply.update = parsed.update || parsed.mode === 'refine'
    reply.appState = APP_BUILDING
    logMark('widget-queued')
    this.queueBuild(reply, context, run)
  }

  private queueBuild(msg: ChatMessage, context: WidgetBuildContext, run: ChatRunContext): void {
    run.pendingBuilds++
    this.buildQueue = this.buildQueue.catch((_e: Error): void => {}).then(async (): Promise<void> => {
      let startedAt = 0
      let sawPreview = false
      try {
        // A run can be cancelled while it waits behind another widget build.
        if (!this.isRunActive(run) || msg.appState === APP_FAILED) { return }
        startedAt = Date.now()
        logMark('widget-build-start')
        await this.loadResources(run.pageGeneration)
        if (!this.isRunActive(run)) { return }
        logStep('load-resources', startedAt)
        // The route (agent/VeraBuildRoute.ets): the agent, from the marker's request.
        let route = new RouteRequest()
        route.agent = chatAgentRequest(context)
        context.composeTried = true
        let host = appAgentHost((s: string): void => {
          if (this.isRunActive(run) && msg.buildStatus !== s) { msg.buildStatus = s }
        }, (vbc2: string): void => {
          if (!this.isRunActive(run) || msg.appState !== APP_BUILDING) { return }
          if (!sawPreview) { sawPreview = true; logMark('widget-preview') }
          msg.previewVbc2 = vbc2
          this.scrollDown(true)
        }, (): boolean => !this.isRunActive(run), this.skillPrompt, '', run)
        // A blocking question goes in the bubble of the widget it is for.
        host.ask = (question: AgentQuestion): Promise<PersonAnswer> => new Promise<PersonAnswer>((resolve: (answer: PersonAnswer) => void) => {
          if (!this.isRunActive(run) || msg.appState !== APP_BUILDING) { resolve(null); return }
          msg.questionOptions = question.options
          msg.questionFallback = question.fallback
          msg.answerQuestion = resolve
          msg.question = question.text
          this.scrollDown(true)
        })
        let outcome: RouteOutcome = await buildScreen(route, host)
        if (!this.isRunActive(run)) { return }
        msg.question = ''
        msg.answerQuestion = null
        let composed = new MiniApp()
        if (outcome.agent !== null) { recordChatAgent(outcome.agent!, context, composed) }
        if (outcome.kind === OUTCOME_AGENT && msg.appState !== APP_FAILED) {
          msg.attempts = composed.stats
          msg.vbc2 = composed.vbc2
          msg.source = composed.source
          msg.originalRequest = context.originalRequest
          msg.parentMessageId = context.parentMessageId
          msg.appState = APP_READY
          logMark('widget-ready')
          return
        }
        if (outcome.kind === OUTCOME_NOT_BUILT && context.source.length === 0 && route.agent !== null) {
          msg.error = 'Not built: ' + outcome.reason
          msg.appState = APP_FAILED
          return
        }
        let app: MiniApp = await buildMiniApp(this.skillPrompt, context, (s: string): void => {
          if (this.isRunActive(run) && msg.buildStatus !== s) { msg.buildStatus = s }
        }, '', (_s: string): void => {}, (vbc2: string): void => {
          if (!this.isRunActive(run) || msg.appState !== APP_BUILDING) { return }
          if (!sawPreview) { sawPreview = true; logMark('widget-preview') }
          msg.previewVbc2 = vbc2
          this.scrollDown(true)
        }, run)
        if (!this.isRunActive(run)) { return }
        msg.attempts = app.stats
        if (msg.appState === APP_FAILED) {
          // The streamed reply invalidated the marker while the build was running.
        } else if (app.error.length === 0 && app.vbc2.length > 0) {
          msg.vbc2 = app.vbc2
          msg.source = app.source
          msg.originalRequest = context.originalRequest
          msg.parentMessageId = context.parentMessageId
          msg.appState = APP_READY
          logMark('widget-ready')
        } else {
          msg.error = app.error
          msg.appState = APP_FAILED
        }
      } catch (e) {
        if (this.isRunActive(run)) {
          msg.error = (e as Error).message
          msg.appState = APP_FAILED
        }
      } finally {
        try {
          if (startedAt > 0 && this.isRunActive(run)) {
            msg.widgetMs = Date.now() - startedAt
            // After appState: the renderer has already been handed the finished program.
            msg.previewVbc2 = ''
            msg.buildStatus = ''
            msg.question = ''
            msg.answerQuestion = null
            this.scrollDown(true)
            this.persist()
          }
        } finally {
          run.pendingBuilds--
          this.releaseRunIfIdle(run)
        }
      }
    })
  }

  build() {
    NavDestination() {
      Column() {
        // The same numbers the Generate screen shows for a program, for the
        // whole chat; each reply carries its own underneath when this is on.
        Row() {
          Text(this.title.length > 0 ? this.title : 'New chat')
            .fontSize(13).fontColor(app.inkSoft).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          Text('Stats').fontSize(13).fontColor(app.inkSoft).margin({ right: 8 })
          Toggle({ type: ToggleType.Switch, isOn: this.showStats })
            .onChange((on: boolean) => { this.showStats = on })
        }
        .width('100%')
        .padding({ left: 16, right: 12, top: 4, bottom: 4 })

        List({ space: 10, scroller: this.scroller }) {
          if (this.showStats && this.messages.length > 0) {
            ListItem() {
              StatsPanel({ tally: tallyOf(this.messages), attempts: [], heading: 'Whole chat' })
            }
          }
          // An empty chat offers ready-made first messages; a tap sends one, as if typed.
          if (this.messages.length === 0) {
            ListItem() {
              ChatStarters({ zh: STARTERS_ZH, en: STARTERS_EN, onPick: (prompt: string): void => {
                if (this.busy) { return }
                this.draft = prompt
                this.send()
              } })
            }
          }
          ForEach(this.messages, (m: ChatMessage) => {
            ListItem() {
              MessageBubble({ msg: m, showStats: this.showStats, chatId: this.chatId,
                destinationHidden: this.destinationHidden })
            }
          }, (m: ChatMessage) => m.id.toString())
          // A question with nothing under it (the chat was closed before the answer came): say so, and offer to ask again.
          if (!this.busy && this.messages.length > 0 && this.messages[this.messages.length - 1].role === 'user') {
            ListItem() {
              Row({ space: 12 }) {
                Text('No answer was saved for this message.').fontSize(14).fontColor(app.inkSoft).layoutWeight(1)
                Button('Retry')
                  .attributeModifier(new TonalButton())
                  .onClick(() => { this.retryLast() })
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 10, bottom: 10 })
              .borderRadius(12)
              .backgroundColor(app.surface)
            }
          }
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .scrollBar(BarState.Off)

        if (this.status.length > 0) {
          Text(this.status).fontSize(12).fontColor(app.inkMuted).width('100%').padding({ left: 16, right: 16, bottom: 4 })
        } else if (this.idleLine().length > 0) {
          // Idle: show which provider/model a reply will use (plus the stub-build
          // note when there is one), since the chat request reads settings.getModel()
          // and the model is picked on the Generate page.
          Text(this.idleLine()).fontSize(12).fontColor(app.inkMuted).width('100%').padding({ left: 16, right: 16, bottom: 4 })
        }

        Row({ space: 8 }) {
          TextInput({ placeholder: 'Message', text: this.draft })
            .onChange((value: string) => {
              this.draft = value
              // The key can arrive while this page is open, and NavDestination.onShow does not fire for that.
              if (this.status.startsWith('No cloud API key') && settings.hasApiKey()) { this.status = '' }
            })
            .onSubmit(() => { this.send() })
            .layoutWeight(1)
            .height(44)
          if (this.canStop) {
            Button({ type: ButtonType.Circle }) {
              SymbolGlyph($r('sys.symbol.square_fill')).fontSize(20).fontColor([app.onPrimary])
            }
            .width(44).height(44)
            .backgroundColor(app.primary)
            .accessibilityText('Stop')
            .onClick(() => { this.stopChat() })
          }
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.arrow_up')).fontSize(20).fontColor([app.onPrimary])
          }
          .width(44).height(44)
          .backgroundColor(app.primary)
          .opacity(!this.busy && this.draft.trim().length > 0 ? 1 : 0.4)
          .enabled(!this.busy && this.draft.trim().length > 0)
          .accessibilityText('Send')
          .onClick(() => { this.send() })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 6, bottom: 10 })
        .backgroundColor(app.surface)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(app.background)
    }
    .title('Chat')
    .menus([{
      value: 'History',
      symbolIcon: new SymbolGlyphModifier($r('sys.symbol.clock')),
      action: () => { this.openHistory() }
    }])
    .onShown(() => { this.destinationShown() })
    .onHidden(() => { this.destinationHidden = true })
  }
}
