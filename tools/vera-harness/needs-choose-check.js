// NeedsChoose.ets: the plan of needs and Jev's choice of a section or a part for each need, through runAgent with a host that
// answers from recorded plans (tools/vera-harness/compose/). The choices Jev gives are put in by hand. No network.
'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const {loadVera} = require('./source-loader')
const {needsOf} = require('./needs-lib')
const {AgentHost, defaultBlockFill} = loadVera('agent/AgentHost')
const {AgentRequest, runAgent} = loadVera('agent/VeraAgent')
const c = loadVera('VeraCompose')
const nc = loadVera('NeedsChoose')
const np = loadVera('NeedsPlan')
const align = loadVera('agent/AgentAlign')
const {OperationController} = loadVera('OperationCancellation')
const route = loadVera('agent/VeraBuildRoute')
const {settings} = loadVera('SettingsStore')
const {serviceNotes} = loadVera('ServiceHealth')
const {toolCalls} = loadVera('ToolLog')
const ts = process.env.VERA_TYPESCRIPT_PATH ? require(process.env.VERA_TYPESCRIPT_PATH) : require('typescript')
const {sourceRoot} = require('./source-loader')

const fixture = (label, file) => fs.readFileSync(path.join(__dirname, 'compose', label, file), 'utf8')
const says = (choice, confidence = 0.9) => ({type: 'choice', choice, confidence})

// Runs the agent on a recorded sketch, written as a needs plan. `edit(sketchJson)` changes the recorded plan first; `choices` is
// what Jev answers to the choice call (null: nothing, twice). Returns what was asked of Jev, in order.
async function run(label, choices, edit = null, request = null) {
  const sketchJson = JSON.parse(fixture(label, 'sketch.json'))
  const rest = JSON.parse(fixture(label, 'jev-answer.json'))
  if (edit) edit(sketchJson, rest.answers)
  for (const key of Object.keys(rest.answers)) if (/^(clock\.part|list\.part|ready\.|whose\.|real_data)/.test(key)) delete rest.answers[key]
  const h = new AgentHost()
  const asked = []
  h.askPlan = async (system, user, onText) => {
    assert.match(system, /JSON plan of what the app needs/)
    const t = JSON.stringify(needsOf(sketchJson)); onText(t); return t
  }
  h.askJev = async body => {
    const q = JSON.parse(body).questions
    const isChoice = Object.keys(q).every(k => /^(clock\.part|list\.part|ready\.|whose\.|real_data)/.test(k))
    asked.push({keys: Object.keys(q), q})
    if (isChoice) return choices === null ? '' : JSON.stringify({answers: choices})
    return JSON.stringify(rest)
  }
  let filled = null
  h.fillBlocks = async request => { filled = request; return defaultBlockFill(request) }
  // The request: every quote the plan makes is in it, unless a test says what the request is.
  const said = needsOf(sketchJson).needs.filter(n => n.from).map(n => n.from).join('. ')
  const r = await runAgent(Object.assign(new AgentRequest(), {prompt: request || said || 'x'}), h)
  return {r, asked, filled}
}
const isChoice = a => a.keys.every(k => /^(clock\.part|list\.part|ready\.|whose\.|real_data)/.test(k))
const settledKeys = a => a.keys.filter(k => /^(clock\.part|list\.part|ready\.|whose\.|real_data)/.test(k))
// A countdown of one fixed time and nothing wired to it: the case the `timer` section may take (merge-check.js's).
const fixedLength = (s, a) => {
  s.constants = [{id: 'brewTime', label: 'Brew time', value: 240, measure: 'seconds'}]
  s.countdown.length = 'brewTime'; s.events = []; s.inputs = []
  if (a) { delete a['effect.notifyDone']; delete a['moment.notifyDone']; a['countdown.length'] = says('brewTime', 1) }
}

function networkSource(name, dependencies = {}) {
  const file = path.join(sourceRoot, 'vera', name + '.ets')
  const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    fileName: name + '.ts', reportDiagnostics: true,
    compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020}
  })
  assert.equal((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0)
  const mod = {exports: {}}
  new Function('require', 'module', 'exports', compiled.outputText)(name => {
    if (name === '@kit.NetworkKit') return {http: {
      RequestMethod: {POST: 'POST'}, HttpDataType: {STRING: 'STRING'},
      createHttp() { return globalThis.__veraHttp() }
    }}
    if (Object.hasOwn(dependencies, name)) return dependencies[name]
    assert.ok(name.startsWith('.'), 'unexpected network dependency: ' + name)
    return loadVera(path.relative(path.join(sourceRoot, 'vera'), path.resolve(path.dirname(file), name)))
  }, mod, mod.exports)
  return mod.exports
}

function deferred() {
  let resolve, reject
  const promise = new Promise((yes, no) => { resolve = yes; reject = no })
  return {promise, resolve, reject}
}

const drain = () => new Promise(resolve => setImmediate(resolve))
const observe = promise => promise.then(value => ({value}), error => ({error}))

async function settled(promise) {
  let timer
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(Error('cancelled operation remained pending')), 500)
    })])
  } finally {
    clearTimeout(timer)
  }
}

async function rejectedCancellation(promise) {
  const result = await settled(promise)
  assert.equal(result.error?.name, 'OperationCancelledError')
  assert.equal(result.error.message, 'Operation cancelled')
  return result
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

async function networkCancellationChecks() {
  const search = networkSource('VeraWebSearch')
  const proxy = networkSource('JevProxy', {'./VeraWebSearch': search})
  const compose = networkSource('VeraCompose', {'./VeraWebSearch': search, './JevProxy': proxy})
  const body = count => JSON.stringify({state: 'packing checklist', questions: Object.fromEntries(
    Array.from({length: count}, (_, i) => ['ready.' + i, {type: 'choice', criteria: {checklist: 'packing', note: 'prose'}}]))})
  const exaResponse = {responseCode: 200, result: JSON.stringify({results: [{title: 'Packing', url: 'https://example.test/packing', text: 'Bring water'}]})}
  const jevResponse = {responseCode: 200, result: '{"answers":{"ready.0":{"choice":"checklist","confidence":1}}}'}
  const cloudResponse = {responseCode: 200, result: JSON.stringify({choices: [{message: {content: 'A'}}]})}
  let count = 0
  const test = async (label, run) => {
    try { await run(); count++ } catch (error) { error.message = label + ': ' + error.message; throw error }
  }
  await patched([
    [settings, 'getExaKey', () => 'test-exa-key'],
    [settings, 'getApiKey', () => 'test-cloud-key'],
    [settings, 'getBaseUrl', () => 'https://cloud.example.test/v1'],
    [settings, 'getModel', () => 'test-model'],
    [settings, 'isDeepSeek', () => false]
  ], async () => {
    for (const mode of ['exa', 'http', 'proxy']) {
      const invoke = cancellation => mode === 'exa'
        ? search.webSearch('packing checklist', 400, cancellation)
        : compose.askJev(body(mode === 'proxy' ? 6 : 1), 'test-selector-key', cancellation)
      const response = mode === 'exa' ? exaResponse : mode === 'http' ? jevResponse : cloudResponse
      await patched([[settings, 'useJevProxy', () => mode === 'proxy']], async () => {
        await test(mode + ' successful control', async () => {
          let requests = 0, destroyed = 0
          await patched([[globalThis, '__veraHttp', () => ({
            request() { requests++; return Promise.resolve(response) },
            destroy() { destroyed++ }
          })]], async () => {
            const result = await invoke(new OperationController())
            if (mode === 'exa') assert.match(result, /Bring water/)
            else assert.equal(JSON.parse(result).answers['ready.0'].choice, 'checklist')
          })
          assert.equal(requests, mode === 'proxy' ? 6 : 1)
          assert.equal(destroyed, requests)
        })
        await test(mode + ' pre-cancelled', async () => {
          const cancellation = new OperationController()
          cancellation.cancel()
          await patched([[globalThis, '__veraHttp', () => assert.fail('pre-cancelled request created a transport')]], async () => {
            await rejectedCancellation(observe(invoke(cancellation)))
          })
        })
        for (const late of ['resolve', 'reject']) {
          await test(mode + ' hung transport with late ' + late, async () => {
            const clients = []
            const cancellation = new OperationController()
            const notes = serviceNotes(), tools = toolCalls()
            await patched([[globalThis, '__veraHttp', () => {
              const response = deferred()
              const client = {response, destroyed: 0, url: '', options: null,
                request(url, options) { client.url = url; client.options = options; return response.promise },
                destroy() { client.destroyed++ }
              }
              clients.push(client)
              return client
            }]], async () => {
              const pending = observe(invoke(cancellation))
              await drain()
              assert.equal(clients.length, mode === 'proxy' ? 4 : 1)
              for (const client of clients) {
                assert.equal(client.destroyed, 0)
                assert.equal(client.options.method, 'POST')
                if (mode === 'exa') {
                  assert.equal(client.url, search.EXA_URL)
                  assert.equal(JSON.parse(client.options.extraData).query, 'packing checklist')
                } else if (mode === 'proxy') {
                  assert.equal(client.url, 'https://cloud.example.test/v1/chat/completions')
                  assert.equal(JSON.parse(client.options.extraData).model, 'test-model')
                } else {
                  assert.equal(client.options.extraData, body(1))
                  assert.equal(client.options.header.Authorization, 'Bearer test-selector-key')
                }
              }
              cancellation.cancel()
              const result = await rejectedCancellation(pending)
              assert.ok(clients.every(client => client.destroyed === 1))
              assert.deepEqual(serviceNotes(), notes)
              assert.deepEqual(toolCalls(), tools)
              for (const client of clients) {
                if (late === 'resolve') client.response.resolve(response)
                else client.response.reject(Error('late transport failure'))
              }
              await drain()
              cancellation.cancel()
              assert.strictEqual(await pending, result)
              assert.equal(clients.length, mode === 'proxy' ? 4 : 1, 'no queued questions after cancellation')
              assert.ok(clients.every(client => client.destroyed === 1), 'late callbacks do not repeat cleanup')
              assert.deepEqual(serviceNotes(), notes, 'late callback cannot publish service health')
              assert.deepEqual(toolCalls(), tools, 'late callback cannot publish tool results')
            })
          })
        }
      })
    }
    for (const backoff of [500, 1000, 2000]) {
      await test('proxy cancellation during ' + backoff + 'ms backoff', async () => {
        const cancellation = new OperationController()
        const timers = []
        let requests = 0, destroyed = 0
        const notes = serviceNotes()
        await patched([
          [settings, 'useJevProxy', () => true],
          [globalThis, '__veraHttp', () => ({
            request() { requests++; return Promise.resolve({responseCode: 429, result: 'rate limited'}) },
            destroy() { destroyed++ }
          })],
          [globalThis, 'setTimeout', (callback, ms) => { const timer = {callback, ms, cleared: false}; timers.push(timer); return timer }],
          [globalThis, 'clearTimeout', timer => { timer.cleared = true }]
        ], async () => {
          const pending = observe(compose.askJev(body(1), 'test-selector-key', cancellation))
          for (const ms of [500, 1000, 2000]) {
            await drain()
            const timer = timers[timers.length - 1]
            assert.equal(timer.ms, ms)
            if (ms === backoff) break
            timer.callback()
          }
          const timer = timers[timers.length - 1]
          const before = requests
          assert.equal(before, [500, 1000, 2000].indexOf(backoff) + 1)
          cancellation.cancel()
          await drain()
          const result = await Promise.race([pending, Promise.resolve({error: Error('backoff cancellation remained pending')})])
          assert.equal(result.error?.name, 'OperationCancelledError')
          assert.equal(timer.cleared, true, 'backoff timer is cleared')
          for (const timer of timers) timer.callback()
          await drain()
          assert.equal(requests, before, 'even an already queued timer cannot retry after cancellation')
          assert.equal(destroyed, requests)
          assert.deepEqual(serviceNotes(), notes)
        })
      })
    }
  })
  return count
}

async function agentCancellationChecks() {
  let count = 0
  const sketch = JSON.parse(fixture('sections-beach', 'sketch.json'))
  sketch.questions = [{id: 'q', ask: 'Which beach?', options: ['nearby', 'far away'], default: 0}]
  const plan = JSON.stringify(needsOf(sketch))
  assert.ok(np.parseNeedsPlan(plan))
  assert.ok(np.sketchFrom(np.parseNeedsPlan(plan)).questions.length > 0)
  for (const routed of [false, true]) {
    for (const answer of [plan, null, 'invalid plan', Error('late plan failure')]) {
      const cancellation = new OperationController()
      const reply = deferred()
      const host = new AgentHost()
      const seen = {plans: 0, jev: 0, sections: 0, questions: 0, fallback: 0, lookup: 0, holes: 0, previews: 0, status: []}
      let stream
      host.cancellation = cancellation
      host.askPlan = (system, user, onText) => { seen.plans++; stream = onText; return reply.promise }
      host.askJev = async () => { seen.jev++; return '' }
      host.fillBlocks = async request => { seen.sections++; return defaultBlockFill(request) }
      host.ask = async () => { seen.questions++; return 0 }
      host.askCode = async () => { seen.fallback++; return null }
      host.lookup = async () => { seen.lookup++; return '' }
      host.onHole = () => { seen.holes++ }
      host.preview = () => { seen.previews++ }
      host.status = text => { seen.status.push(text) }
      const request = Object.assign(new AgentRequest(), {prompt: 'beach packing checklist'})
      const pending = observe(routed ? route.buildScreen(Object.assign(new route.RouteRequest(), {agent: request}), host) : runAgent(request, host))
      await drain()
      assert.equal(seen.plans, 1)
      const before = structuredClone(seen)
      cancellation.cancel()
      stream(plan)
      if (answer instanceof Error) reply.reject(answer)
      else reply.resolve(answer)
      if (routed) {
        const result = await settled(pending)
        assert.equal(result.value?.kind, route.OUTCOME_CANCELLED)
        assert.equal(result.value.agent, null)
        assert.equal(result.value.reason, '')
      } else if (answer instanceof Error) {
        assert.strictEqual((await settled(pending)).error, answer)
      } else await rejectedCancellation(pending)
      stream(plan)
      await drain()
      assert.deepEqual(seen, before, 'cancelled plan cannot retry, preview, choose sections, ask questions or enter fallback')
      assert.equal(seen.jev + seen.sections + seen.questions + seen.fallback + seen.lookup + seen.holes + seen.previews, 0)
      count++
    }
  }
  return count
}

async function appHostOwnershipChecks() {
  const {deepseek} = networkSource('DeepSeekEngine', {'@kit.ArkTS': {util: {TextDecoder: {
    create(encoding) {
      const decoder = new TextDecoder(encoding)
      return {decodeToString: (bytes, options) => decoder.decode(bytes, options)}
    }
  }}}})
  const {appBlockCalls} = networkSource('SectionFillApp', {'./DeepSeekEngine': {deepseek}})
  const {appAgentHost} = networkSource('agent/AgentAppHost', {
    '../DeepSeekEngine': {deepseek}, '../SectionFillApp': {appBlockCalls}
  })
  const {BlockRequest} = loadVera('SectionFill')
  let requests = 0, destroyed = 0, beforeReply = () => {}
  await patched([
    [settings, 'hasApiKey', () => true],
    [settings, 'getApiKey', () => 'test-cloud-key'],
    [settings, 'hasExaKey', () => false],
    [settings, 'getBaseUrl', () => 'https://cloud.example.test/v1'],
    [settings, 'getModel', () => 'test-model'],
    [settings, 'isDeepSeek', () => false],
    [globalThis, '__veraHttp', () => {
      let listener
      return {
        on(event, callback) { assert.equal(event, 'dataReceive'); listener = callback },
        off() {},
        destroy() { destroyed++ },
        async requestInStream(url, options) {
          requests++
          assert.equal(url, 'https://cloud.example.test/v1/chat/completions')
          assert.equal(JSON.parse(options.extraData).model, 'test-model')
          beforeReply()
          const bytes = Buffer.from('data: ' + JSON.stringify({
            choices: [{delta: {content: '{"title":"Ownership"}'}, finish_reason: 'stop'}],
            usage: {prompt_tokens: 17, completion_tokens: 3, prompt_cache_hit_tokens: 5}
          }) + '\n\ndata: [DONE]\n\n')
          listener(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength))
          return 200
        }
      }
    }]
  ], async () => {
    const originalController = new OperationController(), otherOwner = new OperationController()
    const host = appAgentHost(() => {}, () => {}, () => false, '', '', originalController)
    const otherHost = appAgentHost(() => {}, () => {}, () => false, '', '', otherOwner)
    const calls = appBlockCalls(false, () => {}, () => false, originalController)
    const streamed = []
    assert.strictEqual(calls.cancellation, originalController)
    deepseek.clearSideCalls()
    assert.equal(await host.askPlan('system', 'plan', text => streamed.push(text), false), '{"title":"Ownership"}')
    assert.deepEqual(streamed, ['{"title":"Ownership"}'])
    assert.equal(await host.askCode('system', 'code', 100, false), '{"title":"Ownership"}')
    const filled = await host.fillBlocks(Object.assign(new BlockRequest(), {kinds: ['checklist'], prompt: 'packing checklist'}))
    assert.equal(filled.globals.get('__TITLE__'), 'Ownership')
    assert.equal(await calls.content('system', 'content', 100), '{"title":"Ownership"}')
    assert.equal(await calls.hole('system', 'hole'), '{"title":"Ownership"}')
    await otherHost.askCode('system', 'independent', 100, false)
    const owned = deepseek.getSideCalls(originalController)
    assert.deepEqual(owned.map(call => call.purpose), [
      'Plan of needs', 'A section of its own', 'Text for the blocks', 'Text for the blocks', 'Function bodies for the blocks'
    ])
    assert.ok(owned.every(call => call.ok))
    assert.deepEqual(owned.reduce((sum, call) => [sum[0] + call.inputTokens, sum[1] + call.cachedTokens,
      sum[2] + call.outputTokens], [0, 0, 0]), [85, 25, 15])
    assert.equal(deepseek.getSideCalls().length, 6)
    const independent = deepseek.getSideCalls(otherOwner)
    assert.equal(independent.length, 1)
    assert.ok(!owned.includes(independent[0]), 'metrics exclude another operation owner')
    assert.deepEqual(deepseek.getSideCalls(new OperationController()), [])

    for (const withController of [false, true]) {
      for (const late of [false, true]) {
        let cancelled = !late
        const seen = []
        const cancellation = withController ? new OperationController() : undefined
        const guardedHost = appAgentHost(text => seen.push(text), text => seen.push(text), () => cancelled, '', '', cancellation)
        const guardedCalls = appBlockCalls(false, text => seen.push(text), () => cancelled, cancellation)
        for (const invoke of [
          () => guardedHost.askPlan('system', 'plan', text => seen.push(text), false),
          () => guardedHost.askCode('system', 'code', 100, false),
          () => guardedCalls.content('system', 'content', 100),
          () => guardedCalls.hole('system', 'hole')
        ]) {
          cancelled = !late
          beforeReply = () => { cancelled = true }
          const before = requests
          await rejectedCancellation(observe(invoke()))
          assert.equal(requests, before + (late ? 1 : 0))
          guardedHost.status('late status')
          guardedHost.preview('late preview')
          guardedCalls.status('late block status')
          assert.deepEqual(seen, [], 'predicate cancellation guards callbacks with or without a controller')
        }
      }
    }
  })
  assert.equal(destroyed, requests)
  return 17
}

;(async () => {
  const cancellationChecks = await networkCancellationChecks() + await agentCancellationChecks() + await appHostOwnershipChecks()
  console.log('needs-choose-check cancellation: ' + cancellationChecks + ' passed')
  // A request that names one length starts the input that holds a length on it.
  {
    const mk = (kind, measure, extra) => c.parseSketch(JSON.stringify({title: 'T', inputs: [Object.assign({id: 'len', label: 'Length', kind, measure}, extra)]}))
    assert.deepEqual(nc.requestedSeconds('10 minute meditation timer, 2 hours later, 10 min'), [600, 7200])
    assert.deepEqual(nc.requestedSeconds('a 90-second plank'), [90])
    const choice = mk('choice', 'seconds', {options: [{label: '5 minutes', value: 300}, {label: '10 minutes', value: 600}, {label: '15 minutes', value: 900}], value: 2})
    assert.equal(nc.startOnRequested(choice, '10 minute meditation timer'), 'Length starts on 10 minutes')
    assert.equal(choice.inputs[0].value, 1)
    assert.equal(nc.startOnRequested(choice, '10 minute meditation timer'), '', 'already there: nothing to say')
    assert.equal(nc.startOnRequested(choice, 'a 7 minute timer'), '', 'not among the options: left as the plan has it')
    assert.equal(nc.startOnRequested(choice, '5 minutes then 10 minutes'), '', 'two lengths: no way to tell')
    const amount = mk('amount', 'minutes', {min: 1, max: 60, value: 20})
    assert.equal(nc.startOnRequested(amount, 'pomodoro timer 25 minutes'), 'Length starts at 25')
    assert.equal(amount.inputs[0].value, 25)
    assert.equal(nc.startOnRequested(mk('amount', 'minutes', {min: 1, max: 20, value: 5}), '25 minutes'), '', 'out of range')
    assert.equal(nc.startOnRequested(mk('amount', 'money', {value: 5}), '25 minutes'), '', 'not a length')
  }
  align.setAlignEnabled(false)

  // The plan's facts decide what is offered, before anyone is asked.
  {
    const plan = n => np.parseNeedsPlan(JSON.stringify(needsOf(n)))
    const egg = JSON.parse(fixture('soft-egg', 'sketch.json'))
    assert.equal(nc.timerMayTakeCountdown(plan(egg)), false, 'a length the person sets keeps the part')
    fixedLength(egg)
    assert.equal(nc.timerMayTakeCountdown(plan(egg)), true)
    egg.events = [{id: 'done', when: 'the countdown reaches zero', what: 'beep', asked: true}]
    assert.equal(nc.timerMayTakeCountdown(plan(egg)), false, 'something at the end keeps the part')
    const pill = JSON.parse(fixture('pill', 'sketch.json'))
    assert.deepEqual(nc.listSectionsFor(plan({...pill, events: [{id: 'a', when: 'when an entry is added', what: 'x', asked: true}]})), [])
    const log = JSON.parse(fixture('expenses', 'sketch.json'))
    log.values = [{id: 'sum', label: 'Sum', means: 'sum', format: 'plain', formula: 'entryTotal', example: {given: {entryTotal: 1}, result: 1}}]
    assert.deepEqual(nc.listSectionsFor(plan(log)), ['record_log'], 'a figure over the entries is only for the log to publish')
  }

  // A countdown of one fixed time: Jev is asked once, with the part and the section; the second call does not ask it again.
  {
    const {r, asked, filled} = await run('soft-egg', {'clock.part': says('timer')}, fixedLength)
    assert.ok(isChoice(asked[0]) && !isChoice(asked[1]), 'the choice, then the rest')
    // The plan fixed the length (240 s): the section's writer is told, and the finished screen is read against it.
    assert.match(filled.prompt, /The plan fixes: .*counts down 4 minutes/)
    assert.ok(JSON.stringify(asked.map(a => a.q)).includes('counting down 4 minutes'), 'the claim carries the length')
    assert.deepEqual(asked[0].keys, ['clock.part'])
    assert.deepEqual(Object.keys(asked[0].q['clock.part'].criteria).sort(), ['part', 'timer'])
    assert.ok(!asked[1].keys.includes('clock.part'))
    assert.deepEqual(r.blocks, ['timer'], r.note)
    assert.equal(r.errors, '', r.note)
  }
  // The same, when Jev prefers the part: the part stays and nothing else changes.
  {
    const {r, asked} = await run('soft-egg', {'clock.part': says('part')}, fixedLength)
    assert.deepEqual(r.blocks || [], [], r.note)
    assert.ok(r.vbc2.length > 0, r.note)
    assert.ok(isChoice(asked[0]) && !isChoice(asked[1]))
  }
  // A length the person sets: the section is not offered, so nobody is asked, and the second call does not ask it either.
  {
    const {r, asked} = await run('soft-egg', {})
    assert.ok(!isChoice(asked[0]) && !asked[0].keys.includes('clock.part'), 'no choice call')
    assert.deepEqual(r.blocks || [], [])
    assert.ok(r.vbc2.length > 0, r.note)
  }
  // A list the person fills in: the part, the log and the reminders side by side; the log takes it.
  {
    const {r, asked} = await run('expenses', {'list.part': says('record_log')})
    assert.deepEqual(Object.keys(asked[0].q['list.part'].criteria).sort(), ['part', 'record_log', 'reminders'])
    assert.ok(!asked[1].keys.includes('list.part'))
    assert.deepEqual(r.blocks, ['record_log'], r.note)
  }
  // Something happens as an entry is added: only the part can do it, so the question is not asked.
  {
    const {asked} = await run('pill', {}, s => { s.events = [{id: 'a', when: 'when an entry is added', what: 'beep', asked: true}] })
    assert.ok(asked.every(a => !a.keys.includes('list.part')))
  }
  // Content written for the request: which section, whose data it is and whether it needs a search are asked once, first.
  {
    const {r, asked} = await run('sections-beach', {'ready.0': says('checklist'), 'whose.0': says('written'), real_data: says('false')})
    assert.ok(isChoice(asked[0]))
    assert.ok(asked[0].keys.includes('ready.0') && asked[0].keys.includes('whose.0') && asked[0].keys.includes('real_data'))
    assert.deepEqual(settledKeys(asked[1]), [], 'the second call asks none of them')
    assert.deepEqual(r.blocks, ['checklist'], r.note)
  }
  // Jev gives no choice: the composer asks them itself in the second call, as before the plan of needs.
  {
    const {asked} = await run('sections-beach', null)
    assert.ok(asked.length >= 3 && isChoice(asked[0]) && isChoice(asked[1]))
    assert.ok(settledKeys(asked.find(a => !isChoice(a))).includes('ready.0'), 'the second call asks them')
  }
  // A need the request does not ask for is not built: the quote it makes is not the request's.
  {
    const {r} = await run('sections-beach', {'ready.0': says('checklist'), 'whose.0': says('written'), real_data: says('false')}, (s) => {
      s.ready = ['beach packing checklist', 'a short note about the weather on the beach']
    }, 'beach packing checklist')
    // The checklist's own quote is its words, and the request is "beach packing checklist": it stays; the weather note does not.
    assert.deepEqual(r.blocks, ['checklist'], r.note)
    assert.match(r.note, /not in the request, so not built: a short note about the weather/)
    assert.ok(r.composed.dropped.some(d => /^not in the request: a short note about the weather/.test(d)))
  }
  // A section that does an effect does it for an event the effect could not be given its details for as well: no second button.
  {
    const sketch = c.parseSketch(JSON.stringify({title: 'T', ready: ['an hour by hour list of stops'],
      events: [{id: 'nav', when: 'the person taps a stop\'s navigate button', what: 'opens maps with directions to that stop', asked: true},
               {id: 'cal', when: 'the person taps a stop\'s calendar button', what: 'adds that stop to the calendar', asked: true},
               {id: 'wipe', when: 'the person taps the wipe button', what: 'removes every calendar event this app added', asked: true}]}))
    const a = (choice, confidence = 0.95) => ({type: 'choice', choice, confidence})
    const answers = {'ready.0': a('itinerary'), 'whose.0': a('written'), real_data: a('false'),
      'effect.nav': a('navigate'), 'moment.nav': a('button'), 'arg.nav.navigate.place': a('unavailable'),
      'effect.cal': a('calendar_add'), 'moment.cal': a('button'), 'arg.cal.calendar_add.title': a('unavailable'),
      'effect.wipe': a('calendar_clear'), 'moment.wipe': a('button')}
    const comp = c.readComposition(JSON.stringify({answers}), sketch, false)
    assert.equal(comp.custom.length, 2, 'two events could not be given their details: ' + comp.custom.join(' / '))
    assert.deepEqual([...comp.customEffects.values()].sort(), ['calendar_add', 'navigate'])
    // The itinerary's stop buttons: its navigate and calendar slots provide these effects.
    const itinerary = loadVera('VeraTemplates').fragments().find(f => f.kind === 'itinerary')
    const provided = itinerary.slots.flatMap(sl => sl.provides)
    assert.ok(provided.includes('navigate') && provided.includes('calendar_add') && provided.includes('calendar_clear'))
    const gone = c.dropProvided(comp, provided)
    assert.equal(gone.length, 3, gone.join(' / '))
    assert.deepEqual(comp.custom, [])
    assert.deepEqual(comp.phoneNeeds, [])
    assert.deepEqual(comp.unboundNeeds, [])
    assert.equal(comp.events.length, 0)
  }
  align.setAlignEnabled(true)
  console.log('needs-choose-check ok')
})().catch(e => { console.error(e); process.exit(1) })
