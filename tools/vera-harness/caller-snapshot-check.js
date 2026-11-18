'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const ts = require(process.env.VERA_TYPESCRIPT_PATH || 'typescript')
const sourceRoot = path.resolve(process.env.VERA_SOURCE_ROOT || path.join(__dirname, '../../entry/src/main/ets'))
const sources = Object.fromEntries(['GeneratePage', 'ChatPage'].map(name =>
  [name, fs.readFileSync(path.join(sourceRoot, 'pages', name + '.ets'), 'utf8')]))
const parsed = []

function method(source, name) {
  const start = source.search(new RegExp('^  (?:private )?(?:async )?' + name + '\\(', 'm'))
  assert(start >= 0, name + ' must exist')
  const scanner = ts.createScanner(ts.ScriptTarget.Latest, true, ts.LanguageVariant.Standard, source.slice(start))
  let depth = 0
  let opened = false
  while (scanner.scan() !== ts.SyntaxKind.EndOfFileToken) {
    if (scanner.getToken() === ts.SyntaxKind.OpenBraceToken) { depth++; opened = true }
    if (scanner.getToken() === ts.SyntaxKind.CloseBraceToken && --depth === 0 && opened) {
      return source.slice(start, start + scanner.getTextPos())
    }
  }
  throw Error('Unterminated method: ' + name)
}

function load(name, names, dependencies, prefix = '') {
  const source = prefix + '\nclass Controller {\n' + names.map(n => method(sources[name], n)).join('\n') + '\n}'
  const tree = ts.createSourceFile(name + '.ts', source, ts.ScriptTarget.Latest, true)
  const compiled = ts.transpileModule(source, {
    fileName: name + '.ts', compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020},
    reportDiagnostics: true
  })
  const errors = [...tree.parseDiagnostics, ...(compiled.diagnostics || [])]
    .filter(d => d.category === ts.DiagnosticCategory.Error)
  assert.equal(errors.length, 0, name + ': ' + errors.map(d => ts.flattenDiagnosticMessageText(d.messageText, '\n')).join('\n'))
  parsed.push({name, tree})
  return new Function(...Object.keys(dependencies), compiled.outputText + '\nreturn Controller;')(...Object.values(dependencies))
}

function deferred() {
  let resolve, reject
  const promise = new Promise((yes, no) => { resolve = yes; reject = no })
  return {promise, resolve, reject}
}

class Data {}
const Generate = load('GeneratePage', ['doRefine', 'refineWithModel', 'setFullscreen', 'openWhole', 'showAgent', 'send',
  'hasResult', 'stopGeneration', 'aboutToDisappear'], {
  WIDGET_ASK: 'Widget: ', MODE_DEEPSEEK: 'cloud', MODE_SERVER: 'server', MAX_RETRIES: 3, TAB_PREVIEW: 'preview',
  templateSelectEnabled: () => false, surfaceRouteEnabled: () => false, drawsSurface: () => false,
  settings: {}, SourceDelta: Data, READY_NOTE_MS: 3000, trace() {}, setTimeout: () => 1, clearTimeout() {}
})

function generate() {
  const gate = deferred(), calls = {capture: 0, compile: 0, model: 0}
  const page = Object.assign(new Generate(), {
    disposed: false, generating: false, snapshotting: false, snapshotRequestId: 0, runId: 0,
    projectId: 'project', baseVersionId: 'v1', compiledSource: 'source', compiledVbc2: 'program',
    previewController: {flushAndSnapshot() { calls.capture++; return gate.promise }},
    baseError: '', refinePrompt: 'change', carriedState: 'old', liveState: 'callback-state',
    compositionJson: '', makeWidget: false, mode: 'cloud', draft: 'change', chipLabel: '', rewriting: false,
    runOnOpen: false, fullscreen: false, readyNote: false, readyNoteTimer: -1, status: 'Ready',
    activeOperation: {cancel() {}, isCancelled: () => false}, keyboardWindow: null,
    prepareRequest() {}, beginOperation() { return this.activeOperation }, resetRunMetrics() {}, startRun() {},
    startAttemptOne() { calls.model++; calls.compile++ }, finishMetrics() {}, settleQuestion() {}, scrollDown() {},
    genStartTime: Date.now(), acceptRequest() {}, closeRun() {}
  })
  return {page, gate, calls}
}

const runAt = sources.ChatPage.indexOf('class ChatRunContext')
assert(runAt >= 0, 'ChatRunContext must exist')
const runClass = sources.ChatPage.slice(runAt, sources.ChatPage.indexOf('@Component', runAt))
const Chat = load('ChatPage', ['isPageActive', 'isRunActive', 'createRun', 'releaseRunIfIdle', 'cancelActiveRuns',
  'stopChat', 'aboutToDisappear', 'flushReferenceFields', 'referenceSnapshots', 'send'], {
  APP_READY: 'ready', APP_DESCRIBING: 'describing', APP_BUILDING: 'building', APP_FAILED: 'failed', APP_NONE: 'none',
  WidgetReference: Data, ChatMessage: Data, WidgetBuildContext: Data, ReplyStats: Data, SearchedTurn: Data,
  recentWidgetConversation: () => '', earlierSearchResults: () => [],
  ensureCapabilities: async context => { context.calls.capabilities++ }, logStep() {}, logMark() {},
  chatReply: async turns => { turns.calls.model++; return 'reply' },
  parseReply: () => ({error: '', appDescription: 'card'}), console: {info() {}}
}, runClass)

function chat() {
  const gate = deferred(), calls = {capture: 0, compile: 0, model: 0, capabilities: 0}
  const msg = {
    id: 4, role: 'assistant', appState: 'ready', vbc2: 'program', source: 'source', previewGeneration: 1,
    previewController: {flushAndSnapshot() { calls.capture++; return gate.promise }}, latestState: 'old',
    originalRequest: 'original', appDescription: 'brief', before: '', after: '', searchResults: [],
    previewVbc2: '', answerQuestion: null
  }
  const page = Object.assign(new Chat(), {
    disposed: false, lifecycleGeneration: 1, nextRunId: 1, activeRuns: [], chatId: 'chat', messages: [msg],
    busy: false, canStop: false, status: 'Ready', draft: 'change', nextId: 5, title: 'chat', resourcesLoaded: true,
    history: () => Object.assign([], {calls}), hostContext: () => ({calls}), scrollDown() {}, persist() {}, apply() {},
    startWidget(reply, result, references) { calls.compile++; this.captured = references }
  })
  return {page, gate, calls, msg}
}

function noWork(calls) {
  assert.equal(calls.model, 0, 'No model request may start before a valid snapshot')
  assert.equal(calls.compile, 0, 'No compile/build may start before a valid snapshot')
}
function idleChat(page) {
  assert.equal(page.busy, false)
  assert.equal(page.canStop, false)
  assert.equal(page.activeRuns.length, 0)
}

let passed = 0, failed = 0
async function check(name, work) {
  try {
    await work()
    passed++
    console.log('PASS ' + name)
  } catch (error) {
    failed++
    console.error('FAIL ' + name + '\n' + error.stack)
  }
}

;(async () => {
  await check('All three snapshot calls are awaited in extracted current-source methods', async () => {
    let total = 0
    for (const {name, tree} of parsed) {
      let count = 0
      function visit(node) {
        if (ts.isCallExpression(node) && ts.isPropertyAccessExpression(node.expression) &&
            node.expression.name.text === 'flushAndSnapshot') {
          assert(ts.isAwaitExpression(node.parent), name + ' snapshot call must be awaited')
          count++
        }
        ts.forEachChild(node, visit)
      }
      visit(tree)
      assert.equal(count, name === 'GeneratePage' ? 2 : 1)
      assert.equal((sources[name].match(/\.flushAndSnapshot\s*\(/g) || []).length, count)
      total += count
    }
    assert.equal(total, 3)
  })
  await check('Generate defers refine/model/compile, blocks duplicate send, and consumes barrier state', async () => {
    const {page, gate, calls} = generate(), pending = page.send()
    assert(page.snapshotting); assert.equal(page.draft, 'change'); noWork(calls)
    await page.send(); assert.equal(calls.capture, 1); noWork(calls)
    gate.resolve('barrier-state'); await pending
    assert.equal(page.carriedState, 'barrier-state'); assert.equal(page.previousSource, 'source')
    assert.equal(calls.model, 1); assert.equal(calls.compile, 1)
    assert.equal(page.draft, ''); assert.equal(page.snapshotting, false); assert(page.generating)
  })
  await check('Generate rejection resets capture busy state and retains draft without model/compile', async () => {
    const {page, gate, calls} = generate(), pending = page.send()
    gate.reject(Error('capture failed')); await pending
    noWork(calls); assert.equal(page.draft, 'change'); assert.equal(page.carriedState, 'old')
    assert.match(page.status, /capture failed/); assert.equal(page.snapshotting, false); assert.equal(page.generating, false)
  })
  const generateChanges = [
    ['disappear', p => p.aboutToDisappear()], ['project', p => { p.projectId = 'new' }],
    ['version', p => { p.baseVersionId = 'new' }], ['controller', p => { p.previewController = {} }],
    ['program', p => { p.compiledVbc2 = 'new' }], ['source', p => { p.compiledSource = 'new' }],
    ['run', p => { p.runId++ }], ['stop', p => p.stopGeneration()]
  ]
  for (const [name, mutate] of generateChanges) {
    for (const ending of ['resolve', 'reject']) {
      await check('Generate fences late snapshot ' + ending + ' after ' + name, async () => {
        const {page, gate, calls} = generate(), pending = page.send()
        mutate(page); const status = page.status
        gate[ending](ending === 'resolve' ? 'stale' : Error('stale failure')); await pending
        noWork(calls); assert.equal(page.carriedState, 'old'); assert.equal(page.draft, 'change')
        assert.equal(page.status, status); assert.equal(page.snapshotting, false)
      })
    }
  }
  await check('First result opens directly; fullscreen transfers wait for the barrier and block duplicates', async () => {
    const result = {source: 'built-source', vbc2: 'built-program', record: null,
      composed: {dropped: []}, waitedMs: () => 0}
    const first = generate()
    first.page.compiledVbc2 = ''; first.page.compiledSource = ''
    first.page.cornerHidden = true; first.page.composerHidden = true
    first.page.previewController.flushAndSnapshot = () => {
      first.calls.capture++
      return Promise.reject(Error('Preview is not attached'))
    }
    first.page.showAgent(result)
    assert.equal(first.calls.capture, 0); assert.equal(first.page.fullscreen, true)
    assert.equal(first.page.readyNote, true); assert.equal(first.page.readyNoteTimer, 1)
    assert.equal(first.page.cornerHidden, false); assert.equal(first.page.composerHidden, false)
    assert.equal(first.page.tab, 'preview'); assert.match(first.page.status, /^Ready in /)
    assert.equal(first.page.compiledVbc2, result.vbc2); assert.equal(first.page.compiledSource, result.source)
    assert.equal(first.page.carriedState, 'old'); assert.equal(first.page.liveState, 'callback-state')
    assert.equal(first.page.snapshotting, false)
    first.page.fullscreen = false
    first.page.showAgent(result)
    assert.equal(first.page.fullscreen, false); assert.equal(first.calls.capture, 0)
    for (const blocked of ['disposed', 'snapshotting']) {
      const fresh = generate()
      fresh.page[blocked] = true
      await fresh.page.openWhole(true)
      assert.equal(fresh.page.fullscreen, false); assert.equal(fresh.page.readyNote, false)
      assert.equal(fresh.calls.capture, 0)
    }
    const {page, gate, calls} = generate(), pending = page.openWhole()
    assert.equal(page.fullscreen, false); assert.equal(await page.setFullscreen(false), false)
    assert.equal(calls.capture, 1); noWork(calls)
    gate.resolve('fullscreen-state'); await pending
    assert.equal(page.fullscreen, true); assert.equal(page.carriedState, 'fullscreen-state'); assert.equal(page.snapshotting, false)
    assert.equal(page.readyNote, true); assert.equal(page.readyNoteTimer, 1)
  })
  await check('Fullscreen rejection preserves view and state, resets busy, and reports error', async () => {
    const {page, gate, calls} = generate(), pending = page.openWhole()
    gate.reject(Error('no snapshot')); await pending
    noWork(calls); assert.equal(page.readyNote, false); assert.equal(page.fullscreen, false)
    assert.equal(page.carriedState, 'old'); assert.equal(page.snapshotting, false); assert.match(page.status, /no snapshot/)
  })
  for (const [name, mutate] of generateChanges) {
    for (const ending of ['resolve', 'reject']) {
      await check('Fullscreen fences late snapshot ' + ending + ' after ' + name, async () => {
        const {page, gate, calls} = generate(), pending = page.openWhole()
        mutate(page); const status = page.status
        gate[ending](ending === 'resolve' ? 'stale' : Error('stale failure')); await pending
        noWork(calls); assert.equal(page.fullscreen, false); assert.equal(page.readyNote, false)
        assert.equal(page.carriedState, 'old'); assert.equal(page.status, status); assert.equal(page.snapshotting, false)
      })
    }
  }
  await check('Chat defers model/build, locks busy, blocks duplicate send, and consumes barrier state', async () => {
    const {page, gate, calls, msg} = chat(), pending = page.send()
    assert(page.busy); assert(page.canStop); assert.equal(page.messages.length, 1); noWork(calls)
    assert.equal(calls.capabilities, 0); await page.send(); assert.equal(calls.capture, 1)
    gate.resolve('barrier-state'); await pending
    assert.equal(calls.model, 1); assert.equal(calls.compile, 1)
    assert.equal(page.captured[0].latestState, 'barrier-state'); assert.equal(msg.latestState, 'old')
    assert.equal(page.draft, ''); idleChat(page)
  })
  await check('Chat rejection resets busy/run ownership and retains draft without model/build', async () => {
    const {page, gate, calls} = chat(), pending = page.send()
    gate.reject(Error('capture failed')); await pending
    noWork(calls); assert.equal(calls.capabilities, 0); assert.equal(page.draft, 'change')
    assert.equal(page.messages.length, 1); idleChat(page); assert.match(page.status, /capture failed/)
  })
  const chatChanges = [
    ['preview generation', (p, m) => { m.previewGeneration++ }],
    ['controller', (p, m) => { m.previewController = {} }], ['program', (p, m) => { m.vbc2 = 'new' }],
    ['source', (p, m) => { m.source = 'new' }], ['readiness', (p, m) => { m.appState = 'failed' }],
    ['chat/project', p => { p.chatId = 'new' }], ['messages', p => { p.messages = [] }],
    ['stop', p => p.stopChat()], ['disappear', p => p.aboutToDisappear()]
  ]
  for (const [name, mutate] of chatChanges) {
    await check('Chat fences late snapshot resolution after ' + name, async () => {
      const {page, gate, calls, msg} = chat(), pending = page.send()
      mutate(page, msg); gate.resolve('stale'); await pending
      noWork(calls); assert.equal(page.draft, 'change'); assert.equal(msg.latestState, 'old')
      assert.equal(page.activeRuns.length, 0)
      if (!page.disposed) { idleChat(page) }
    })
  }
  for (const [name, mutate] of chatChanges.filter(([name]) => name === 'stop' || name === 'disappear')) {
    await check('Chat catches stale rejection after ' + name + ' without publishing an error', async () => {
      const {page, gate, calls, msg} = chat(), pending = page.send()
      mutate(page, msg); const status = page.status
      gate.reject(Error('stale failure')); await pending
      noWork(calls); assert.equal(page.status, status); assert.equal(page.draft, 'change'); assert.equal(page.activeRuns.length, 0)
    })
  }
  for (const ending of ['resolve', 'reject']) {
    await check('Generate stop/retry keeps new capture busy after old ' + ending, async () => {
      const {page, gate, calls} = generate(), pending = page.send()
      page.stopGeneration(); const next = deferred()
      page.previewController = {flushAndSnapshot: () => next.promise}
      const fresh = page.send(); gate[ending](ending === 'resolve' ? 'stale' : Error('stale failure')); await pending
      assert(page.snapshotting); assert.equal(page.status, 'Stopped'); noWork(calls)
      next.resolve('fresh'); await fresh; assert.equal(page.carriedState, 'fresh'); assert.equal(calls.model, 1)
    })
    await check('Chat stop/retry keeps new run busy after old ' + ending, async () => {
      const {page, gate, calls} = chat(), pending = page.send()
      page.stopChat(); const next = deferred()
      page.messages[0].previewController = {flushAndSnapshot: () => next.promise}
      const fresh = page.send(); gate[ending](ending === 'resolve' ? 'stale' : Error('stale failure')); await pending
      assert(page.busy); assert(page.canStop); assert.equal(page.activeRuns.length, 1); noWork(calls)
      next.resolve('fresh'); await fresh; assert.equal(page.captured[0].latestState, 'fresh'); idleChat(page)
    })
  }
  await check('Empty Generate snapshot retains last known state', async () => {
    const {page, gate} = generate(), pending = page.send()
    gate.resolve(''); await pending; assert.equal(page.carriedState, 'callback-state')
  })
  await check('Empty Chat snapshot retains send-start state', async () => {
    const {page, gate} = chat(), pending = page.send()
    gate.resolve(''); await pending; assert.equal(page.captured[0].latestState, 'old')
  })
  await check('Multiple previews revalidate earlier program generations before any model/build', async () => {
    const {page, gate, calls, msg} = chat(), second = deferred()
    page.messages.push({...msg, id: 6, previewController: {flushAndSnapshot: () => second.promise}})
    const pending = page.send(); gate.resolve('first'); await Promise.resolve()
    msg.previewGeneration++; second.resolve('second'); await pending
    noWork(calls); idleChat(page); assert.equal(page.draft, 'change')
  })
  await check('Multiple previews preserve barrier snapshots rather than later callback side effects', async () => {
    const {page, gate, msg} = chat(), second = deferred()
    page.messages.push({...msg, id: 6, previewController: {flushAndSnapshot: () => second.promise}})
    const pending = page.send(); gate.resolve('first'); await Promise.resolve()
    msg.latestState = 'later callback'; second.resolve('second'); await pending
    assert.deepEqual(page.captured.map(ref => ref.latestState), ['first', 'second'])
  })
  console.log('caller-snapshot-check: ' + passed + ' passed, ' + failed + ' failed (stubbed APIs/model/build; not ArkTS typechecking)')
  process.exitCode = failed ? 1 : 0
})().catch(error => { console.error(error); process.exitCode = 1 })
