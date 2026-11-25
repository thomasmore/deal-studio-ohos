// The platform http module on node's fetch, for a harness that runs the app's own model calls as the phone makes them
// (VeraChat.ets's chat, DeepSeekEngine.ets's generate, VeraAsk.ets, VeraLive.ets): request() and requestInStream() with its
// 'dataReceive' chunks. Every request to /chat/completions is recorded, the body exactly as the app built it and the
// answer as it came back (the stream read into one message), into the log of the async context it runs in.
//
//   const tap = require('./model-tap'); tap.install()          // after host-lookup's install, before the first loadVera
//   await tap.run(log, () => chat.chatReply(...))               // log.asks gets {kind: 'ask', task: log.task, request, reply}
'use strict'
const {AsyncLocalStorage} = require('node:async_hooks')

const store = new AsyncLocalStorage()

/** What a completion answered: a JSON body, or an SSE stream of deltas read into one message. */
function replyOf(text) {
  const out = {content: '', tool_calls: [], finish: '', usage: null, model: ''}
  const trimmed = text.trim()
  if (trimmed.startsWith('{')) {
    try {
      const body = JSON.parse(trimmed)
      const choice = (body.choices || [])[0] || {}
      const message = choice.message || {}
      return Object.assign(out, {content: message.content || '', tool_calls: message.tool_calls || [], finish: choice.finish_reason || '',
        usage: body.usage || null, model: body.model || ''})
    } catch (e) { return out }
  }
  const calls = new Map()
  for (const line of text.split('\n')) {
    const data = line.trim()
    if (!data.startsWith('data:')) continue
    const json = data.slice(5).trim()
    if (!json || json === '[DONE]') continue
    let chunk
    try { chunk = JSON.parse(json) } catch (e) { continue }
    if (chunk.usage) out.usage = chunk.usage
    if (chunk.model) out.model = chunk.model
    const choice = (chunk.choices || [])[0]
    if (!choice) continue
    if (choice.finish_reason) out.finish = choice.finish_reason
    const delta = choice.delta || {}
    if (typeof delta.content === 'string') out.content += delta.content
    for (const c of delta.tool_calls || []) {
      const at = c.index !== undefined ? c.index : calls.size
      const call = calls.get(at) || {id: '', type: 'function', function: {name: '', arguments: ''}}
      if (c.id) call.id = c.id
      if (c.function && c.function.name) call.function.name += c.function.name
      if (c.function && c.function.arguments) call.function.arguments += c.function.arguments
      calls.set(at, call)
    }
  }
  out.tool_calls = [...calls.entries()].sort((a, b) => a[0] - b[0]).map(e => e[1])
  return out
}

function record(url, options, status, text, ms) {
  const log = store.getStore()
  if (!log || !String(url).endsWith('/chat/completions')) return
  let request = null
  try { request = JSON.parse(options.extraData) } catch (e) { request = String(options.extraData || '') }
  log.asks.push({kind: 'ask', task: log.task || 'chat', seq: log.seq++, status, request, reply: replyOf(text), ms})
}

function install() {
  const modules = globalThis.__veraModules = globalThis.__veraModules || {}
  const arkts = modules['@kit.ArkTS'] || {}
  const util = Object.assign({}, arkts.util || {}, {TextDecoder: {create: () => {
    const decoder = new TextDecoder('utf-8')
    return {decodeToString: (bytes, o) => decoder.decode(bytes, {stream: Boolean(o && o.stream)})}
  }}})
  modules['@kit.ArkTS'] = Object.assign({}, arkts, {util})
  globalThis.__veraHttp = () => {
    const handlers = {}
    const send = (url, o) => fetch(url, {method: o.method || 'GET', headers: o.header, body: o.extraData,
      signal: AbortSignal.timeout(Math.max(o.readTimeout || 0, 120000))})
    return {
      on(event, handler) { handlers[event] = handler },
      off(event) { delete handlers[event] },
      destroy() {},
      async request(url, o) {
        const started = Date.now()
        const r = await send(url, o)
        const text = await r.text()
        record(url, o, r.status, text, Date.now() - started)
        return {responseCode: r.status, result: text}
      },
      async requestInStream(url, o) {
        const started = Date.now()
        const r = await send(url, o)
        const decoder = new TextDecoder('utf-8')
        let text = ''
        const reader = r.body.getReader()
        for (;;) {
          const {done, value} = await reader.read()
          if (done) break
          text += decoder.decode(value, {stream: true})
          if (handlers.dataReceive) handlers.dataReceive(value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength))
        }
        if (handlers.dataEnd) handlers.dataEnd()
        record(url, o, r.status, text, Date.now() - started)
        return r.status
      },
    }
  }
}

module.exports = {install, run: (log, fn) => store.run(log, fn), replyOf}
