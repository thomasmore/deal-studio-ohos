'use strict'
const $ = id => document.getElementById(id)
let state, selected = '', lastRender = '', posting = false, followLatest = true, clientError = '', historySignature = ''
let draft = null, lastGeneratedId = '', draftStatusActive = false
const streamedLabels = {'mmbert-shared-state-q8-experimental': 'mmBERT shared-state Q8', 'mmbert-q4': 'mmBERT-small Q4'}
const historicalLabels = {e5: 'E5 · safe / uncalibrated', 'laya-safe': 'Laya · safe / uncertain', 'laya-diagnostic': 'Laya · diagnostic / uncalibrated'}
const duration = ms => Number.isFinite(ms) ? ms < 1000 ? `${ms.toFixed(0)} ms` : `${(ms / 1000).toFixed(2)} s` : '—'
function sizePrompt() { $('prompt').style.height = 'auto'; $('prompt').style.height = Math.min(180, $('prompt').scrollHeight) + 'px' }
function text(tag, value, className) { const node = document.createElement(tag); node.textContent = value; if (className) node.className = className; return node }
function emptyScreen(container, heading, description, running = false) {
  const box = text('div', '', 'empty-screen' + (running ? ' running' : ''))
  box.append(text('span', '◇', 'empty-mark'), text('h3', heading), text('p', description))
  container.replaceChildren(box)
}
function renderMatched(row, errors) {
  const match = row.selectorComparison
  $('matched').hidden = !match
  if (!match) return
  const results = $('matched-results')
  if (!match.requests) {
    results.replaceChildren(text('p', match.error || (match.status === 'running' ? 'Comparing both selectors on identical requests…' : 'No matched request data.')))
    return
  }
  const {choice, noul, timing} = match
  const metrics = document.createElement('dl')
  for (const [label, value] of [
    ['Paired replies', `${match.paired} of ${match.requests} requests`],
    ['Choice agreement', choice.compared ? `${choice.agreed} of ${choice.compared} agree · ${choice.compared} of ${choice.eligible} covered` : `0 of ${choice.eligible} covered`],
    ['Mean absolute noul difference', noul.compared ? `${noul.meanAbsoluteDelta.toFixed(3)} · ${noul.compared} of ${noul.eligible} covered` : `0 of ${noul.eligible} covered`],
    ['Matched warm round trips', timing ? `Cloud ${duration(timing.cloudMs)} · Local ${duration(timing.localMs)}` : 'No timed pairs']
  ]) {
    const metric = document.createElement('div')
    metric.append(text('dt', label), text('dd', value))
    metrics.append(metric)
  }
  const link = text('a', 'Matched requests, replies, and replay log ↗')
  link.href = `/artifacts/${row.id}/shared/selector-comparison.json`
  link.target = '_blank'
  link.rel = 'noopener'
  results.replaceChildren(metrics, text('p', `Replays outside build totals · Cloud ${match.replays.cloud} · Local ${match.replays.local}.`))
  if (timing) results.append(text('p', `${timing.paired} timed pairs · Rust inference ${duration(timing.localInferenceMs)} · Rust process round trips ${duration(timing.localWorkerRoundtripMs)}.`))
  results.append(text('p', 'Timing uses warm requests with complete, valid answers from both selectors.'))
  if (match.error) errors.push(text('p', match.error))
  if (match.errors.cloud || match.errors.local) errors.push(text('p', `Matched request errors · Cloud ${match.errors.cloud} · Local ${match.errors.local}. See the replay log.`))
  results.append(link)
}
function render() {
  const generation=state.promptGeneration
  if(generation?.mode==='manual'&&generation.status==='complete'&&!generation.usedBy&&generation.id!==lastGeneratedId) {
    lastGeneratedId=generation.id;draft={id:generation.id,prompt:generation.prompt};draftStatusActive=true;$('prompt').value=generation.prompt;sizePrompt()
  }
  const manualGeneration=generation?.mode==='manual'&&(['generating','verifying','retrying'].includes(generation.status)||(generation.status==='complete'&&!generation.usedBy))?generation:null
  const readyDraft=manualGeneration?.status==='complete'&&draft?.id===manualGeneration.id&&draft.prompt===$('prompt').value
  const notice = clientError || (draftStatusActive&&!state.busy&&manualGeneration?.status==='complete'&&!readyDraft?'An unused generated request is saved. Run comparison uses the current editor text.':state.notice)
  if ($('status').textContent !== notice) $('status').textContent = notice
  $('auto-status').textContent = state.auto ? 'Auto mode on' : 'Auto mode off'
  for (const id of ['run', 'auto', 'random', 'prompt']) $(id).disabled = posting || state.busy || state.auto
  $('stop').disabled = posting || !state.canStop
  const options = state.history.map(row => ({id: row.id, label: `${new Date(row.startedAt).toLocaleTimeString()} · ${(row.prompt||row.promptGeneration?.prompt||('Request '+(row.promptGeneration?.status||'pending'))).slice(0, 65)}`}))
  const optionSignature = options.map(option => option.id).join(',')
  if (optionSignature !== historySignature) {
    $('history').replaceChildren(...(options.length ? options.map(option => { const node = text('option', option.label); node.value = option.id; return node }) : [text('option', 'No saved runs')]))
    historySignature = optionSignature
  } else options.forEach((option,index)=>{if($('history').options[index]?.textContent!==option.label)$('history').options[index].textContent=option.label})
  const row = (followLatest ? state.history[0] : state.history.find(row => row.id === selected)) || state.history[0]
  if (!row) {
    $('local-title').textContent = state.localSelector?.label || 'mmBERT shared-state Q8'
    $('local-subtitle').textContent = state.localSelector?.available === false ? 'Local model unavailable' : 'Local Rust · uncalibrated'
    if(generation) {
      $('notes').replaceChildren(text('p',`Request generation: ${generation.status} · ${generation.attemptCount} attempt(s). ${generation.nextRetryAt?'Next retry: '+new Date(generation.nextRetryAt).toLocaleTimeString()+'. ':''}Requests and semantic checks are saved. Novelty is heuristic.`))
      $('errors').replaceChildren(text('p',generation.error||'No prompt-provider errors reported.'))
    }
    return
  }
  selected = row.id
  $('history').value = selected
  const signature = JSON.stringify({row,manualGeneration,draftId:draft?.id||null})
  if (signature === lastRender) return
  lastRender = signature
  if (!$('prompt').matches(':focus')&&!draft&&row.prompt) { $('prompt').value = row.prompt; sizePrompt() }
  const decisions = [], errors = []
  const streamed = Object.hasOwn(streamedLabels, row.localModel)
  for (const kind of ['cloud', 'local']) {
    const value = row.paths[kind], name = kind === 'cloud' ? 'Cloud Jev' : value.selectorSource?.label || row.localLabel || streamedLabels[row.localModel] || historicalLabels[row.localModel] || 'Local E5'
    if (kind === 'local') {
      $('local-title').textContent = name
      $('local-subtitle').textContent = streamed ? 'Local Rust · uncalibrated' : 'Generated with local Rust model'
    }
    const base = `/artifacts/${row.id}/${kind}/`
    $(kind + '-selector').textContent = duration(value.selectorMs)
    $(kind + '-total').textContent = duration(value.totalMs)
    $(kind + '-status').textContent = (({diagnostic:'Diagnostic · uncalibrated logits',complete: value.preview ? 'Generated · approximate host preview' : 'Generated · preview unavailable', uncertain: 'Uncertain · ' + (value.uncertainty || []).join(', '), running: 'Generation in progress', pending: 'Waiting for this path', failed: 'Path failed', 'not-built': 'No screen built', interrupted: 'Interrupted'})[value.status] || value.status) + (value.selectorCalls === 0 ? ' · No selector call' : '')
    const source = $(kind + '-source')
    source.hidden = !value.served
    source.href = base + 'program.vera'
    const screen = $(kind + '-screen')
    if (value.preview) {
      const img = document.createElement('img'); img.src = base + 'preview.svg'; img.alt = `${name} approximate host preview from the generated program`
      img.addEventListener('error', () => emptyScreen(screen, 'Preview unavailable', 'The saved host preview could not load.'))
      screen.replaceChildren(img)
    } else if (value.status === 'running' || value.status === 'pending') emptyScreen(screen, value.status === 'running' ? 'Generating the screen' : 'Waiting for this path', 'The real app pipeline runs on the host. Results appear after this path completes.', true)
    else emptyScreen(screen, value.status === 'uncertain' ? 'The selector is uncertain' : 'No generated screen', value.error || value.note || 'This path did not produce a usable host preview.')
    const group = text('div', '')
    group.append(text('strong', name), text('p', value.note || (value.status === 'pending' || value.status === 'running' ? 'Decisions are pending.' : 'No decision note returned.')))
    if (value.uncertainty?.length) group.append(text('p', 'Local status: ' + value.uncertainty.join(', ') + '. Empty answers are not decisions.'))
    if (value.decisions?.length) {
      const details = document.createElement('details'); details.append(text('summary', `${value.selectorCalls} selector call(s) · actual replies`), text('pre', JSON.stringify(value.decisions, null, 2)))
      group.append(details)
    }
    if (value.selectorCalls) { const link = text('a', 'Selector request and reply log ↗'); link.href = base + 'selector-events.jsonl'; link.target = '_blank'; link.rel = 'noopener'; group.append(link) }
    decisions.push(group)
    if (value.error) errors.push(text('p', `${name}: ${value.error}`))
  }
  $('decisions').classList.remove('muted'); $('decisions').replaceChildren(...decisions)
  renderMatched(row, errors)
  const planNote = row.plan?.sha256 ? `Shared DeepSeek plan · ${duration(row.plan.ms)} · ${row.plan.planningCalls} planning call. SHA-256: ${row.plan.sha256}.` : row.plan ? (row.plan.error || 'DeepSeek creates one shared plan before both paths.') : 'Legacy comparison: independent plans. This run predates the shared-plan contract.'
  const notes = [text('p', planNote)]
  if(row.promptGeneration) {
    const generated=row.promptGeneration
    notes.unshift(text('p',generated.status==='complete'?`Request generated by DeepSeek · ${duration(generated.ms)} · ${generated.attemptCount} attempt(s). Semantic novelty compared ${generated.novelty?.comparedRequests??0} prior requests. This is a heuristic, not a guarantee.`:`Request generation: ${generated.status} · ${generated.attemptCount} attempt(s). ${generated.nextRetryAt?'Next retry: '+new Date(generated.nextRetryAt).toLocaleTimeString()+'. ':''}Novelty checks are heuristic. No shared planning call starts until a fresh request is accepted.`))
    const link=text('a','Generated request and novelty provenance ↗');link.href=generated.status==='complete'?`/artifacts/${row.id}/shared/prompt-generation.json`:`/prompts/${generated.id}.json`;link.target='_blank';link.rel='noopener';notes.splice(1,0,link)
    if(generated.error)errors.push(text('p','Prompt generation: '+generated.error))
  }
  if (row.plan?.sha256) {
    const link = text('a', 'Shared plan and provenance ↗'); link.href = `/artifacts/${row.id}/shared/shared-plan.json`; link.target = '_blank'; link.rel = 'noopener'; notes.push(link)
    if (row.paths.cloud.planSha256 && row.paths.local.planSha256) notes.push(text('p', row.paths.cloud.planSha256 === row.paths.local.planSha256 ? 'Both paths consumed the same plan hash.' : 'Plan hash mismatch. Do not interpret this comparison.'))
  }
  if (streamed) {
    const workers = new Map((row.paths.local.decisions || []).filter(event => event.timings).map(event => [event.timings.pid, event.timings]))
    for (const worker of workers.values()) notes.push(text('p', `Rust process ${worker.pid} · model startup ${duration(worker.modelStartupMs)} · host startup ${duration(worker.coldStartMs)}.`))
    const inputNote = row.localModel === 'mmbert-shared-state-q8-experimental' ? ' The Q8 tokenizer keeps up to the first 48 tokens of each text.' : ''
    notes.unshift(text('p', 'The selector uses temperature 1 to convert logits to probabilities. The probabilities have no human calibration.' + inputNote))
  } else if (row.localModel === 'laya-diagnostic') notes.unshift(text('p','Laya diagnostic mode uses real raw logits at temperature 1. These probabilities are uncalibrated. Official Laya token caps apply and every truncation appears in the selector log. This mode is playground-only and cannot enable app production answers.'))
  if(row.paths.local.selectorSource)notes.push(text('pre',JSON.stringify(row.paths.local.selectorSource,null,2)))
  if(row.paths.cloud.selectorSource)notes.push(text('p','Cloud selector source: '+JSON.stringify(row.paths.cloud.selectorSource)))
  if (row.plan?.error) errors.push(text('p', 'Shared plan: ' + row.plan.error))
  if(manualGeneration) {
    notes.unshift(text('p',`Request generation: ${manualGeneration.status} · ${manualGeneration.attemptCount} attempt(s). ${manualGeneration.nextRetryAt?'Next retry: '+new Date(manualGeneration.nextRetryAt).toLocaleTimeString()+'. ':''}Novelty checks are heuristic. ${manualGeneration.status==='complete'?(readyDraft?'The draft is ready. Select Run comparison to generate its previews.':'An unused generated request is saved. Its provenance is available below.'):'Select Stop to cancel.'}`))
    const link=text('a','Draft request and novelty provenance ↗');link.href=`/prompts/${manualGeneration.id}.json`;link.target='_blank';link.rel='noopener';notes.splice(1,0,link)
    if(manualGeneration.error)errors.unshift(text('p','Prompt generation: '+manualGeneration.error))
  }
  $('errors').classList.toggle('muted', !errors.length); $('errors').replaceChildren(...(errors.length ? errors : [text('p', row.finishedAt ? 'No errors reported for this comparison.' : 'Results are pending.')]))
  notes.push(text('p', 'Host previews use the real compiler and VM with approximate SVG layout. They do not measure phone rendering or speed.'),
    text('p', streamed ? 'Build selector time includes all calls from that build. The server starts Rust separately and reuses it across runs.' : 'Build selector time sums the selector calls. This comparison uses an earlier local runtime.'),
    text('p', `Saved comparison: ${row.id}. Both paths consume one shared plan. DeepSeek content and code generation can still vary. A request for replanning stops that path explicitly.`))
  $('notes').replaceChildren(...notes)
}
async function refresh() {
  try { const res = await fetch('/api/state' + (!followLatest && selected ? '?selected=' + encodeURIComponent(selected) : '')); if (!res.ok) throw Error(); state = await res.json(); render() }
  catch (_) { $('status').textContent = 'The local host is unavailable. Auto mode stops before another pair after the browser lease expires.'; for (const id of ['run', 'auto', 'random', 'stop']) $(id).disabled = true }
}
async function post(endpoint, body) {
  if (!state || posting) return
  clientError = ''
  posting = true; render()
  try {
    const res = await fetch(endpoint, {method: 'POST', headers: {'Content-Type': 'application/json', 'X-Playground-Token': state.token}, body: JSON.stringify(body)})
    const result = await res.json()
    if (!res.ok) throw Error(result.error || 'The request failed.')
    if (endpoint === '/api/run') { selected = ''; lastRender = ''; followLatest = true;draft=null;draftStatusActive=false }
  } catch (error) { clientError = error.message }
  finally { posting = false; await refresh() }
}
$('request-form').addEventListener('submit', event => { event.preventDefault(); post('/api/run', {prompt: $('prompt').value,...(draft&&draft.prompt===$('prompt').value?{promptGenerationId:draft.id}:{})}) })
$('auto').addEventListener('click', () => post('/api/run', {auto: true}))
$('stop').addEventListener('click', () => post('/api/stop', {}))
$('random').addEventListener('click', () => post('/api/random', {}))
$('prompt').addEventListener('input', () => {if(draft&&draft.prompt!==$('prompt').value)draft=null;sizePrompt();if(state)render()})
$('history').addEventListener('change', () => { selected = $('history').value; followLatest = selected === state.history[0]?.id; lastRender = ''; clientError = '';draft=null; refresh() })
refresh()
setInterval(refresh, 1000)
