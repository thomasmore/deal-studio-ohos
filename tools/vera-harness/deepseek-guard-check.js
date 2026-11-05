'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const ts = process.env.VERA_TYPESCRIPT_PATH ? require(process.env.VERA_TYPESCRIPT_PATH) : require('typescript')
const {loadVera, loadSource, sourceRoot} = require('./source-loader')
const engineFile = path.join(sourceRoot, 'vera/DeepSeekEngine.ets')
const compiled = ts.transpileModule(fs.readFileSync(engineFile, 'utf8'), {
  fileName: 'DeepSeekEngine.ts', reportDiagnostics: true,
  compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020}
})
assert.equal((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0)
const engineModule = {exports: {}}
new Function('require', 'module', 'exports', compiled.outputText)(name => {
  if (name === '@kit.ArkTS') return {util: {TextDecoder: {create(encoding) {
    const decoder = new TextDecoder(encoding)
    return {decodeToString(bytes, options) { return decoder.decode(bytes, options) }}
  }}}}
  if (name === '@kit.NetworkKit') return {http: {
    RequestMethod: {POST: 'POST'},
    createHttp() {
      assert.equal(typeof globalThis.__veraHttp, 'function', 'model transport must be explicitly stubbed')
      return globalThis.__veraHttp()
    }
  }}
  if (name === './VeraSdkIndex') return loadSource(path.join(__dirname, 'src/VeraSdkIndex.ts'))
  assert.ok(name.startsWith('./'), 'unexpected engine dependency: ' + name)
  return loadVera(name.slice(2))
}, engineModule, engineModule.exports)
const {DeepSeekEngine, discoveryToolResult} = engineModule.exports
const {settings} = loadVera('SettingsStore')
const {GenerateRequest} = loadVera('LlamaEngine')
const {SEARCH_TOOL_NAME} = loadVera('VeraWebSearch')
const {OperationController, PredicateCancellation, isCancelled, throwIfCancelled} = loadVera('OperationCancellation')
const sdkIndex = loadSource(path.join(__dirname, 'src/VeraSdkIndex.ts'))
const sdkEmbedding = loadVera('VeraSdkEmbeddingCache')
const intentIndex = loadVera('VeraIntentIndex')
const intentEmbedding = loadVera('VeraIntentEmbeddingCache')
const {resetToolLog, toolCalls} = loadVera('ToolLog')

function deferred() {
  let resolve, reject
  const promise = new Promise((yes, no) => { resolve = yes; reject = no })
  return {promise, resolve, reject}
}

async function promptly(promise, label) {
  let timer
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(Error(label + ' did not settle promptly')), 500)
    })])
  } finally {
    clearTimeout(timer)
  }
}

async function until(predicate, label) {
  const deadline = Date.now() + 500
  while (!predicate()) {
    assert.ok(Date.now() < deadline, label + ' did not start promptly')
    await new Promise(resolve => setImmediate(resolve))
  }
}

function observe(promise) {
  return promise.then(value => ({value}), error => ({error}))
}

async function cancelled(outcome, label) {
  const result = await promptly(outcome, label)
  assert.equal(result.error?.name, 'OperationCancelledError', label)
  assert.equal(result.error.message, 'Operation cancelled', label)
}

async function patched(changes, run) {
  const originals = changes.map(([object, key]) => Object.getOwnPropertyDescriptor(object, key))
  changes.forEach(([object, key, value]) => { object[key] = value })
  try {
    return await run()
  } finally {
    changes.forEach(([object, key], i) => {
      if (originals[i]) Object.defineProperty(object, key, originals[i])
      else delete object[key]
    })
  }
}

function request(prompt) {
  return Object.assign(new GenerateRequest(), {userPrompt: prompt})
}

function turn(content, extra = {}) {
  return {content, reasoning: '', finishReason: 'stop', toolCalls: [], inputTokens: 0, outputTokens: 0, cacheHitTokens: 0, ...extra}
}

function sse(delta, finishReason = null, usage) {
  return 'data: ' + JSON.stringify({choices: [{delta, finish_reason: finishReason}], ...(usage ? {usage} : {})}) + '\n\n'
}

function transport() {
  const response = deferred()
  let listener
  let queued
  const client = {
    destroyed: 0,
    detached: 0,
    settled: false,
    body: null,
    on(event, callback) {
      assert.equal(event, 'dataReceive')
      listener = callback
      queued = callback
    },
    off(event) {
      assert.equal(event, 'dataReceive')
      client.detached++
      listener = undefined
    },
    destroy() { client.destroyed++ },
    requestInStream(url, options) {
      client.body = JSON.parse(options.extraData)
      return response.promise
    },
    emit(text, late = false) {
      const bytes = typeof text === 'string' ? new TextEncoder().encode(text) : text
      const callback = late ? queued : listener
      assert.equal(typeof callback, 'function', 'transport callback is available')
      callback(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength))
    },
    finish(code = 200) {
      client.settled = true
      response.resolve(code)
    },
    answer(text, inputTokens = 0, outputTokens = 0, cacheHitTokens = 0) {
      client.emit(sse({content: text}, 'stop', {prompt_tokens: inputTokens, completion_tokens: outputTokens, prompt_cache_hit_tokens: cacheHitTokens}))
      client.finish()
    }
  }
  return client
}

async function withTransport(run) {
  const engine = new DeepSeekEngine()
  const clients = []
  await patched([[globalThis, '__veraHttp', () => {
    const client = transport()
    clients.push(client)
    return client
  }]], async () => {
    try {
      await run(engine, clients)
    } finally {
      engine.stop()
      clients.forEach(client => client.finish())
      await new Promise(resolve => setImmediate(resolve))
      assert.equal(engine.isGenerating(), false, 'all operations are released')
      clients.forEach(client => {
        assert.equal(client.destroyed, 1, 'each transport is destroyed exactly once')
        assert.equal(client.detached, 1, 'each transport listener is detached exactly once')
      })
    }
  })
}

function cancellationContract() {
  const controller = new OperationController()
  const calls = []
  assert.equal(isCancelled(), false)
  assert.equal(isCancelled(controller), false)
  throwIfCancelled(controller)
  const unsubscribe = controller.onCancel(() => calls.push('unsubscribed'))
  unsubscribe()
  unsubscribe()
  controller.onCancel(() => { calls.push('first'); controller.cancel(); throw Error('ignored listener failure') })
  controller.onCancel(() => calls.push('second'))
  controller.cancel()
  controller.cancel()
  assert.equal(isCancelled(controller), true)
  assert.deepEqual(calls, ['first', 'second'])
  controller.onCancel(() => calls.push('late'))()
  assert.deepEqual(calls, ['first', 'second', 'late'], 'late subscriptions fire synchronously')
  assert.throws(() => throwIfCancelled(controller), {name: 'OperationCancelledError', message: 'Operation cancelled'})

  let stopped = false
  const owner = new OperationController()
  const polling = new PredicateCancellation(() => stopped, owner)
  assert.equal(polling.isCancelled(), false)
  let notified = 0
  const unregister = polling.onCancel(() => notified++)
  unregister()
  polling.onCancel(() => notified++)
  owner.cancel()
  assert.equal(polling.isCancelled(), true)
  assert.equal(notified, 1)
  polling.onCancel(() => notified++)()
  assert.equal(notified, 2)

  const predicateOnly = new PredicateCancellation(() => stopped)
  assert.equal(predicateOnly.isCancelled(), false)
  predicateOnly.onCancel(() => notified++)()
  stopped = true
  assert.equal(predicateOnly.isCancelled(), true)
  predicateOnly.onCancel(() => notified++)()
  assert.equal(notified, 3)
  assert.throws(() => throwIfCancelled(predicateOnly), {name: 'OperationCancelledError'})
}

async function searchBudget() {
  const rounds = [3, 2]
  let id = 0
  let ran = 0
  const engine = new DeepSeekEngine()
  await patched([
    [DeepSeekEngine.prototype, 'streamOnce', async function () {
      assert.notEqual(this, engine, 'generation uses an operation worker')
      const n = rounds.shift()
      if (n === undefined) return turn('fn view() {}')
      const toolCalls = Array.from({length: n}, () => ({id: 'c' + id++, name: SEARCH_TOOL_NAME, arguments: '{"query":"q"}'}))
      return turn('', {finishReason: 'tool_calls', toolCalls})
    }],
    [DeepSeekEngine.prototype, 'runToolCall', async call => {
      ran++
      return {role: 'tool', tool_call_id: call.id, content: 'found'}
    }]
  ], async () => {
    const result = await engine.generate(request('x'), () => {})
    assert.equal(result.text, 'fn view() {}')
    assert.equal(ran, 2, 'web searches that ran in one generation')
    assert.equal(engine.lastToolRounds(), 2)
    assert.equal(engine.isGenerating(), false)
  })
}

async function overlappingGenerations() {
  await withTransport(async (engine, clients) => {
    const aTokens = [], bTokens = [], aProgress = [], bProgress = []
    const a = observe(engine.generate(request('old'), t => aTokens.push(t), p => aProgress.push({...p})))
    await until(() => clients[0]?.body, 'first generation starts')
    const aBytes = new TextEncoder().encode(sse({content: 'old café'}))
    const split = aBytes.indexOf(0xc3) + 1
    clients[0].emit(aBytes.slice(0, split))
    const b = observe(engine.generate(request('new'), t => bTokens.push(t), p => bProgress.push({...p})))
    await until(() => clients[1]?.body, 'second generation starts')
    const bLine = sse({content: 'new '})
    clients[1].emit(bLine.slice(0, 19))
    clients[0].emit(aBytes.slice(split))
    clients[1].emit(bLine.slice(19))
    clients[1].emit(sse({reasoning_content: 'new reasoning'}))
    clients[0].emit(sse({reasoning_content: 'old reasoning'}))
    clients[1].answer('result', 22, 7, 12)
    assert.equal((await promptly(b, 'new generation')).value.text, 'new result')
    assert.equal(engine.isGenerating(), true, 'old operation is still active')
    assert.equal(engine.lastInputTokens(), 22)
    assert.equal(engine.lastCacheHitTokens(), 12)
    const bSnapshot = [bTokens.slice(), bProgress.slice()]
    clients[1].emit(sse({content: 'queued after success', reasoning_content: 'late'}), true)
    clients[0].answer(' result', 11, 3, 5)
    const old = (await promptly(a, 'old generation')).value
    assert.equal(old.text, 'old café result')
    assert.equal(old.inputTokens, 11)
    assert.equal(old.outputTokens, 3)
    assert.deepEqual(aTokens, ['old café', ' result'])
    assert.deepEqual(bTokens, ['new ', 'result'])
    assert.deepEqual([bTokens, bProgress], bSnapshot, 'queued callbacks after success are ignored')
    assert.deepEqual(aProgress.map(p => p.phase), ['request', 'thinking'])
    assert.deepEqual(bProgress.map(p => p.phase), ['request', 'thinking'])
    assert.equal(engine.lastInputTokens(), 22, 'older completion cannot overwrite newer metrics')
    assert.equal(engine.lastCacheHitTokens(), 12)
    assert.equal(engine.lastFinishReason(), 'stop')
  })
}

async function sideCallsOverlap() {
  await withTransport(async (engine, clients) => {
    engine.setThinking(true)
    const tokens = [], progress = [], sketchText = []
    const generation = observe(engine.generate(request('program'), t => tokens.push(t), p => progress.push({...p})))
    await until(() => clients[0]?.body, 'generation starts')
    const line = sse({content: 'program '})
    clients[0].emit(line.slice(0, 17))
    const sketch = observe(engine.extractSketch('system', 'sketch', text => sketchText.push(text)))
    const template = observe(engine.extractTemplateContent('system', 'template', 100))
    await until(() => clients.length === 3 && clients.every(c => c.body), 'side calls overlap generation')
    assert.equal(await engine.extractUiNeeds('busy'), null, 'UI-needs retains its idle-only gate')
    assert.equal(clients.length, 3)
    assert.equal(clients[0].body.thinking.type, 'enabled')
    assert.equal(clients[1].body.thinking.type, 'disabled')
    assert.equal(clients[2].body.thinking.type, 'disabled')
    clients[1].emit(sse({content: '{"needs":'}))
    clients[0].emit(line.slice(17))
    clients[2].answer('{"title":"Template"}', 2, 3)
    assert.equal((await promptly(template, 'template')).value, '{"title":"Template"}')
    assert.equal(engine.isGenerating(), true, 'template completion leaves generation active')
    clients[0].answer('source', 17, 4, 8)
    assert.equal((await promptly(generation, 'generation')).value.text, 'program source')
    assert.equal(engine.isGenerating(), true, 'sketch still owns its operation')
    clients[1].answer('[]}', 3, 2)
    assert.equal((await promptly(sketch, 'sketch')).value, '{"needs":[]}')
    assert.deepEqual(sketchText, ['{"needs":', '{"needs":[]}'])
    assert.deepEqual(tokens, ['program ', 'source'])
    assert.deepEqual(progress.map(p => p.phase), ['request'])
    assert.equal(engine.lastInputTokens(), 17, 'side calls do not publish generation metrics')
    assert.deepEqual(engine.getSideCalls().map(c => [c.purpose, c.inputTokens, c.ok]), [
      ['Text for the blocks', 2, true], ['Plan of needs', 3, true]
    ])
    const uiNeeds = observe(engine.extractUiNeeds('idle'))
    await until(() => clients[3]?.body, 'idle UI-needs starts')
    clients[3].answer('["numeric value display"]')
    assert.deepEqual((await promptly(uiNeeds, 'UI-needs')).value, ['numeric value display'])
  })
}

const operations = [
  ['generate', (engine, owner, tokens, progress) => engine.generate(request('generate'), t => tokens.push(t), p => progress.push({...p}), owner)],
  ['sketch', (engine, owner, tokens) => engine.extractSketch('system', 'sketch', t => tokens.push(t), false, owner)],
  ['template', (engine, owner) => engine.extractTemplateContent('system', 'template', 100, 'Text', false, owner)]
]

async function cancellationDestroysTransport() {
  for (const [name, start] of operations) {
    await withTransport(async (engine, clients) => {
      const owner = new OperationController()
      const tokens = [], progress = []
      const result = observe(start(engine, owner, tokens, progress))
      await until(() => clients[0]?.body, name + ' starts')
      clients[0].emit(sse({content: 'before'}))
      const snapshot = [tokens.slice(), progress.slice()]
      owner.cancel()
      assert.equal(clients[0].destroyed, 1, name + ' destroys its transport synchronously')
      assert.equal(clients[0].detached, 1)
      assert.equal(clients[0].settled, false, 'destroy does not settle the underlying request')
      clients[0].emit(sse({content: 'queued', reasoning_content: 'queued'}), true)
      await cancelled(result, name + ' cancellation with a pending transport')
      assert.deepEqual([tokens, progress], snapshot, name + ' ignores queued callbacks')
      assert.equal(engine.isGenerating(), false)
      assert.deepEqual(engine.getSideCalls(), [], 'cancelled work is not recorded as a fallback')
      assert.equal(owner.callbacks.length, 0, 'owner listener is released')
      clients[0].finish()
      await new Promise(resolve => setImmediate(resolve))
      assert.equal(engine.lastInputTokens(), 0, 'late transport completion publishes no metrics')
    })
  }
}

async function oldCancellationCannotStopNew() {
  await withTransport(async (engine, clients) => {
    const oldOwner = new OperationController(), newOwner = new OperationController()
    const oldText = [], newText = [], newProgress = []
    const old = observe(engine.extractSketch('system', 'chat plan', t => oldText.push(t), false, oldOwner))
    await until(() => clients[0]?.body, 'old chat-side operation starts')
    clients[0].emit(sse({content: 'old'}))
    const next = observe(engine.generate(request('Generate handoff'), t => newText.push(t), p => newProgress.push({...p}), newOwner))
    await until(() => clients[1]?.body, 'new Generate operation starts')
    oldOwner.cancel()
    await cancelled(old, 'old chat-side operation')
    engine.stop(oldOwner)
    assert.equal(clients[1].destroyed, 0, 'old owner cannot destroy the new transport')
    assert.equal(engine.isGenerating(), true)
    clients[0].emit(sse({content: 'late old', reasoning_content: 'late'}), true)
    clients[0].finish()
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(clients[1].destroyed, 0, 'old finally cannot clean up the new transport')
    clients[1].answer('new source', 31, 9, 4)
    assert.equal((await promptly(next, 'Generate handoff')).value.text, 'new source')
    assert.deepEqual(oldText, ['old'])
    assert.deepEqual(newText, ['new source'])
    assert.deepEqual(newProgress.map(p => p.phase), ['request'])
    assert.equal(engine.lastInputTokens(), 31)
    assert.deepEqual(engine.getSideCalls(), [])
    assert.equal(newOwner.isCancelled(), false, 'completion does not cancel the caller')
    assert.equal(newOwner.callbacks.length, 0, 'successful owner listener is released')
  })
}

async function scopedStop() {
  await withTransport(async (engine, clients) => {
    const owner = new OperationController(), other = new OperationController()
    const first = observe(engine.extractSketch('system', 'first', () => {}, false, owner))
    const second = observe(engine.extractTemplateContent('system', 'second', 100, 'Text', false, owner))
    const third = observe(engine.generate(request('other'), () => {}, () => {}, other))
    const unowned = observe(engine.extractTemplateContent('system', 'unowned', 100))
    await until(() => clients.length === 4 && clients.every(c => c.body), 'scoped operations start')
    engine.stop(new OperationController())
    assert.deepEqual(clients.map(c => c.destroyed), [0, 0, 0, 0], 'unknown scope is a no-op')
    engine.stop(owner)
    assert.deepEqual(clients.map(c => c.destroyed), [1, 1, 0, 0], 'stop targets every worker owned by the exact scope')
    await cancelled(first, 'first scoped operation')
    await cancelled(second, 'second scoped operation')
    assert.equal(owner.isCancelled(), false, 'engine stop does not cancel the caller controller')
    assert.equal(engine.isGenerating(), true)
    engine.stop(owner)
    engine.stop()
    await cancelled(third, 'unscoped stop owned operation')
    await cancelled(unowned, 'unscoped stop unowned operation')
    assert.deepEqual(clients.map(c => c.destroyed), [1, 1, 1, 1])
    engine.stop()
    const fresh = observe(engine.generate(request('fresh'), () => {}, () => {}, owner))
    await until(() => clients[4]?.body, 'stopped owner can start a fresh worker')
    clients[4].answer('fresh')
    assert.equal((await promptly(fresh, 'fresh worker')).value.text, 'fresh')
  })
}

async function cancellationBeforeStart() {
  await withTransport(async (engine, clients) => {
    const owner = new OperationController()
    owner.cancel()
    for (const [name, start] of operations) {
      await cancelled(observe(start(engine, owner, [], [])), name + ' pre-cancelled owner')
    }
    const immediateOwner = new OperationController()
    const immediate = observe(engine.generate(request('not started'), () => assert.fail('cancelled token'), () => assert.fail('cancelled progress'), immediateOwner))
    immediateOwner.cancel()
    await cancelled(immediate, 'cancelled before operation microtask')
    assert.equal(clients.length, 0, 'cancelled operations never create a transport')
  })
}

async function cancellationInsideCallbacks() {
  for (const phase of ['token', 'thinking']) {
    await withTransport(async (engine, clients) => {
      const owner = new OperationController()
      const tokens = [], progress = []
      const result = observe(engine.generate(request(phase), token => {
        tokens.push(token)
        if (phase === 'token') owner.cancel()
      }, p => {
        progress.push(p.phase)
        if (phase === 'thinking' && p.phase === 'thinking') owner.cancel()
      }, owner))
      await until(() => clients[0]?.body, phase + ' callback request starts')
      clients[0].emit(sse(phase === 'token' ? {content: 'first'} : {reasoning_content: 'reason', content: 'must not arrive'}) + sse({content: 'second'}))
      await cancelled(result, phase + ' callback cancellation')
      assert.deepEqual(tokens, phase === 'token' ? ['first'] : [], 'rest of the same chunk is ignored')
      assert.deepEqual(progress, phase === 'thinking' ? ['request', 'thinking'] : ['request'])
    })
  }
}

async function staleSideCalls() {
  await withTransport(async (engine, clients) => {
    const old = observe(engine.extractTemplateContent('system', 'old metrics', 100))
    await until(() => clients[0]?.body, 'old side call starts')
    engine.clearSideCalls()
    const next = observe(engine.extractTemplateContent('system', 'new metrics', 100, 'New run'))
    await until(() => clients[1]?.body, 'new side call starts')
    clients[1].answer('new', 9, 2)
    assert.equal((await promptly(next, 'new side call')).value, 'new')
    clients[0].answer('old', 99, 20)
    assert.equal((await promptly(old, 'old side call')).value, 'old')
    assert.deepEqual(engine.getSideCalls().map(c => [c.purpose, c.inputTokens]), [['New run', 9]], 'old completion cannot repopulate a new run ledger')
  })
}

async function discoveryBoundaries() {
  const calls = []
  let sdkAnswer = () => Promise.resolve([])
  let intentAnswer = () => Promise.resolve([])
  await patched([
    [sdkIndex, 'findSdkFunctionFromCache', () => { calls.push('sdk keywords'); return [] }],
    [intentIndex, 'findIntentFunction', () => { calls.push('intent keywords'); return [] }],
    [sdkEmbedding, 'findSdkFunctionByEmbedding', (...args) => { calls.push('sdk embedding'); return sdkAnswer(...args) }],
    [intentEmbedding, 'findIntentFunctionByEmbedding', (...args) => { calls.push('intent embedding'); return intentAnswer(...args) }]
  ], async () => {
    for (const name of ['find_sdk_function', 'find_intent_function', 'unknown']) {
      calls.length = 0
      resetToolLog()
      const owner = new OperationController()
      owner.cancel()
      await cancelled(observe(discoveryToolResult(name, 'need', 1, false, owner)), name + ' entry boundary')
      assert.deepEqual(calls, [])
      assert.deepEqual(toolCalls(), [])
    }
    for (const [name, boundary, rejects] of [
      ['find_sdk_function', 'embedding', false],
      ['find_intent_function', 'embedding', false],
      ['find_intent_function', 'curated SDK', false],
      ['find_intent_function', 'curated SDK', true]
    ]) {
      calls.length = 0
      resetToolLog()
      const pending = deferred(), entered = deferred(), owner = new OperationController()
      sdkAnswer = () => { entered.resolve(); return pending.promise }
      intentAnswer = () => {
        if (boundary === 'curated SDK') return Promise.resolve([])
        entered.resolve()
        return pending.promise
      }
      const result = observe(discoveryToolResult(name, 'need', 1, false, owner))
      await promptly(entered.promise, name + ' reaches ' + boundary)
      owner.cancel()
      const before = toolCalls()
      if (rejects) pending.reject(Error('late embedding failure'))
      else pending.resolve(null)
      await cancelled(result, name + ' after ' + boundary)
      assert.deepEqual(toolCalls(), before, 'cancelled discovery emits no late tool log')
      assert.deepEqual(calls, boundary === 'curated SDK' ? ['intent keywords', 'intent embedding', 'sdk embedding'] :
        name === 'find_sdk_function' ? ['sdk keywords', 'sdk embedding'] : ['intent keywords', 'intent embedding'], 'no fallback or downstream lookup after cancellation')
    }
    sdkAnswer = () => Promise.resolve([])
    intentAnswer = () => Promise.resolve([])
    for (const name of ['find_sdk_function', 'find_intent_function']) {
      assert.deepEqual(JSON.parse(await discoveryToolResult(name, 'need')).results, [], 'uncancelled discovery still returns results')
    }
  })
}

async function cancelledDiscoveryCannotResumeGeneration() {
  for (const name of ['find_sdk_function', 'find_intent_function']) {
    const pending = deferred(), entered = deferred()
    await patched([
      [sdkIndex, 'findSdkFunctionFromCache', () => []],
      [intentIndex, 'findIntentFunction', () => []],
      [sdkEmbedding, 'findSdkFunctionByEmbedding', () => { entered.resolve(); return pending.promise }],
      [intentEmbedding, 'findIntentFunctionByEmbedding', () => { entered.resolve(); return pending.promise }]
    ], async () => {
      await withTransport(async (engine, clients) => {
        const owner = new OperationController(), progress = [], tokens = []
        const result = observe(engine.generate(request('discover'), t => tokens.push(t), p => progress.push({...p}), owner))
        await until(() => clients[0]?.body, 'discovery generation starts')
        clients[0].emit(sse({tool_calls: [{index: 0, id: 'lookup', function: {name, arguments: '{"need":"need"}'}}]}, 'tool_calls'))
        clients[0].finish()
        await promptly(entered.promise, name + ' discovery starts')
        owner.cancel()
        await cancelled(result, name + ' generation interrupted during discovery')
        assert.equal(engine.isGenerating(), false)
        const snapshot = progress.slice()
        resetToolLog()
        pending.resolve(null)
        await new Promise(resolve => setImmediate(resolve))
        assert.equal(clients.length, 1, 'late discovery cannot send another model round')
        assert.deepEqual(progress, snapshot, 'late discovery cannot publish progress')
        assert.deepEqual(tokens, [])
        assert.deepEqual(toolCalls(), [])
        assert.equal(engine.lastToolRounds(), 0, 'cancelled generation cannot publish metrics')
      })
    })
  }
}

;(async () => {
  const tests = [cancellationContract, searchBudget, overlappingGenerations, sideCallsOverlap,
    cancellationDestroysTransport, oldCancellationCannotStopNew, scopedStop, cancellationBeforeStart,
    cancellationInsideCallbacks, staleSideCalls, discoveryBoundaries, cancelledDiscoveryCannotResumeGeneration]
  let failures = 0
  await patched([[settings, 'getApiKey', () => 'sk-test'], [settings, 'hasApiKey', () => true], [settings, 'hasExaKey', () => true]], async () => {
    for (const test of tests) {
      try {
        await test()
        console.log('deepseek-guard-check: ' + test.name + ' ok')
      } catch (error) {
        failures++
        console.error('deepseek-guard-check: ' + test.name + ' FAIL', error)
      }
    }
  })
  assert.equal(failures, 0, 'request ownership regression failures')
  console.log('deepseek-guard-check: ok (' + tests.length + ' checks)')
})().catch(e => { console.error(e); process.exitCode = 1 })
