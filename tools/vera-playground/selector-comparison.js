'use strict'
const {createHash} = require('node:crypto')
const {localFailureMessage, localOperationalReason} = require('./laya-stream')

async function askCloud(body, apiKey, signal) {
  try {
    const timeout = AbortSignal.timeout(30000)
    const reply = await fetch('https://api.typesafe.ai/v1/systemone', {method: 'POST',
      signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
      headers: {'Content-Type': 'application/json', Authorization: 'Bearer ' + apiKey}, body})
    if (!reply.ok) throw Error('Jev HTTP ' + reply.status)
    const text = await reply.text()
    const answers = JSON.parse(text)?.answers
    if (!answers || typeof answers !== 'object' || Array.isArray(answers)) throw Error('Invalid Jev response')
    return text
  } catch (error) {
    throw Error(/^Jev HTTP \d+$/.test(error.message) ? error.message : 'Selector transport or response failure')
  }
}

function validAnswer(question, answer) {
  if (!answer || (Object.hasOwn(answer, 'type') && answer.type !== question.type)) return false
  if (question.type === 'choice') return typeof answer.choice === 'string' && Object.hasOwn(question.criteria || {}, answer.choice)
  return Number.isFinite(answer.noul) && answer.noul >= 0 && answer.noul <= 1
}

async function compareSelectors(traces, stream, apiKey, signal, canReplay) {
  const requests = new Map()
  const kinds = ['cloud', 'local']
  const summary = {requests: 0, paired: 0, replays: {cloud: 0, local: 0}, errors: {cloud: 0, local: 0},
    choice: {eligible: 0, compared: 0, agreed: 0}, noul: {eligible: 0, compared: 0, meanAbsoluteDelta: null}, timing: null}
  for (const kind of kinds) for (const event of traces[kind]) {
    if (typeof event.body !== 'string') continue
    if (!requests.has(event.body)) requests.set(event.body, {body: event.body, sha256: createHash('sha256').update(event.body).digest('hex')})
    const row = requests.get(event.body)
    const {response, ms, timings, requestId} = event
    const error = event.error || localOperationalReason(response)
    if (!row[kind] || (row[kind].error && !error)) {
      row[kind] = {source: 'build', selectorSource: event.source, response, ms, error, timings, requestId}
    }
  }

  const timing = {paired: 0, cloudMs: 0, localMs: 0, localInferenceMs: 0, localWorkerRoundtripMs: 0}
  let deltaSum = 0
  let replayFailure = null
  for (const row of requests.values()) {
    for (const kind of kinds) {
      if (row[kind]) continue
      if (!canReplay || signal.aborted) { row[kind] = {source: 'skipped', error: 'Counterpart replay stopped'}; continue }
      summary.replays[kind]++
      const started = performance.now()
      try {
        const {source: selectorSource, response, timings, requestId} = kind === 'local' ? await stream.query(row.body, signal) : {response: JSON.parse(await askCloud(row.body, apiKey, signal))}
        row[kind] = {source: 'replay', selectorSource, response, timings, requestId, ms: performance.now() - started, error: localOperationalReason(response)}
      } catch (error) {
        row[kind] = {source: 'replay', response: null, ms: performance.now() - started,
          error: kind === 'local' ? localFailureMessage(error) : error.message}
      }
      if (row[kind].error && !signal.aborted) replayFailure ||= {kind, error: row[kind].error}
    }
    for (const kind of kinds) if (row[kind].error) summary.errors[kind]++
    const {cloud, local} = row
    const questions = Object.entries(JSON.parse(row.body).questions || {})
    const paired = Boolean(cloud.response && local.response && !cloud.error && !local.error)
    if (paired) summary.paired++
    let complete = paired && questions.length > 0 && local.response.local?.status !== 'uncertain'
    for (const [key, question] of questions) {
      const type = question.type
      if (type !== 'choice' && type !== 'noul') { complete = false; continue }
      summary[type].eligible++
      const a = cloud.response?.answers?.[key], b = local.response?.answers?.[key]
      if (!paired || !validAnswer(question, a) || !validAnswer(question, b)) { complete = false; continue }
      if (type === 'choice') {
        summary.choice.compared++
        if (a.choice === b.choice) summary.choice.agreed++
      } else {
        summary.noul.compared++
        deltaSum += Math.abs(a.noul - b.noul)
      }
    }
    if (complete && local.timings && !local.timings.cold) {
      timing.paired++
      timing.cloudMs += cloud.ms
      timing.localMs += local.timings.totalMs
      timing.localInferenceMs += local.timings.warmInferenceMs
      timing.localWorkerRoundtripMs += local.timings.roundtripMs
    }
  }
  summary.requests = requests.size
  if (summary.noul.compared) summary.noul.meanAbsoluteDelta = deltaSum / summary.noul.compared
  if (timing.paired) summary.timing = timing
  return {summary, requests: [...requests.values()], replayFailure}
}

module.exports = {askCloud, compareSelectors}
