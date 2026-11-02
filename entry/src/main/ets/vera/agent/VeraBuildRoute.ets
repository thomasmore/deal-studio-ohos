/**
 * Which builder makes a new screen, the same for the Generate screen and the chat: the agent (VeraAgent.ets), then the whole
 * screen as one hole. When neither serves, the screen is not built and the outcome says why: the route itself never generates
 * from scratch, and neither does a caller: the Generate screen and the chat both show the reason. The caller turns the outcome into its
 * own state; this file decides nothing about pages.
 *
 * The agent chooses among the composer's parts and the catalogue's sections together (VeraCompose.ets's chooseSections, AgentAlign.ets),
 * so there is no second planner behind it: a separate pick of sections and a layout from the request alone (the blocks pipeline, removed)
 * used to follow the agent and was never the one that served -- none of 121 prompts, none of 22 on the merged choice.
 *
 * When no part of the screen can be built from what is ready, the hole widens to the whole screen: the model writes it
 * as one section against the agent's plan of it, looked up and checked the same way (AgentHole.ets), and Jev reads it
 * against everything the plan says the screen does. Only then does the route return OUTCOME_NOT_BUILT. Never throws.
 */

import { AgentHost, checkAgent, agentCancellation } from './AgentHost'
import { AgentRequest, AgentResult, runAgent } from './VeraAgent'
import { writeHole } from './AgentHole'
import { assemblePlan, ScreenPlan } from '../ScreenPlan'
import { wholeScreenPlan, sketchConstants } from '../VeraCompose'
import { settleProgram } from './AgentRepair'
import { compositionFromPlan, rebuilds } from '../VeraComposition'
import { addStage, WHO_MODEL, WHO_PHONE } from '../RunStages'
import { toolCount, toolSpanSince } from '../ToolLog'
import { briefSurface, writeSurfaceApp, SURFACE_WHOLE, SURFACE_PART, SURFACE_NONE } from './AgentSurface'

/** The agent's program is the result. */
export const OUTCOME_AGENT: string = 'agent'
/**
 * Nothing served: the screen is not built, and `reason` says why. The route does not generate, and nor does the caller: the chat and
 * the Generate screen both show the reason as an error.
 */
export const OUTCOME_NOT_BUILT: string = 'not-built'
export const OUTCOME_CANCELLED: string = 'cancelled'

/** The whole screen as one hole before any generation; `--ps veraWhole 0` turns it off, for comparison. */
let wholeScreen: boolean = true
export function setWholeScreenEnabled(on: boolean): void { wholeScreen = on }
export function wholeScreenEnabled(): boolean { return wholeScreen }

export class RouteRequest {
  /** What the agent builds from; null when the agent is not to be tried. */
  agent: AgentRequest | null = null
  /** The Generate screen's generation mode; the chat is always 'deepseek'. */
  mode: string = 'deepseek'
}

export class RouteOutcome {
  kind: string = OUTCOME_NOT_BUILT
  /** The agent's answer when it ran, served or not. */
  agent: AgentResult | null = null
  /** Why nothing was built, for the person to see: what the agent said; '' when something was. */
  reason: string = ''
}

/**
 * The whole screen as one hole, against the agent's sketch of it (or the request alone when there is none): true when
 * it served, with the agent's result then holding the program.
 */
async function writeWholeScreen(request: RouteRequest, host: AgentHost, outcome: RouteOutcome): Promise<boolean> {
  checkAgent(host)
  let agent = outcome.agent
  if (!wholeScreen || request.agent === null || agent === null || request.mode !== 'deepseek') { return false }
  let prompt = request.agent!.prompt
  let sketch = agent!.composed.parsed
  let plan: ScreenPlan
  if (sketch !== null) {
    plan = wholeScreenPlan(sketch!, request.agent!.widget)
  } else {
    plan = new ScreenPlan()
    plan.widget = request.agent!.widget
    plan.globals.set('__HEADER_STYLE__', 'none')
    plan.addToWrite('screen.0', 'everything the request asks', true)
  }
  plan.prompt = prompt
  host.status('Writing the whole screen...')
  let facts: string[] = sketch !== null ? sketchConstants(sketch!) : []
  if (plan.widget) { facts.push('This is a small widget inside a chat reply: no header of its own, at most two sections, compact') }
  let writeStart = Date.now()
  let writeTools = toolCount()
  let written = await writeHole(plan, prompt, [], host, facts)
  checkAgent(host)
  let wrote = Date.now() - writeStart
  let lookups = Math.min(toolSpanSince(writeTools), wrote)
  addStage(agent!.stages, 'Looking up phone functions', WHO_PHONE, lookups, 'before the model writes')
  addStage(agent!.stages, 'Model writes the whole screen', WHO_MODEL, wrote - lookups,
    written !== null ? written.attempts.toString() + ' attempt(s)' : '')
  agent!.whole = written
  if (written === null || written.section === null) {
    agent!.note += '; whole screen: ' + (written !== null ? written.failed : 'nothing to write')
    return false
  }
  let settleStart = Date.now()
  checkAgent(host)
  let settled = await settleProgram(assemblePlan(plan), prompt, host)
  checkAgent(host)
  addStage(agent!.stages, 'Compile and run once', WHO_PHONE, settled.checkMs)
  addStage(agent!.stages, 'Repair by edits', WHO_MODEL, Date.now() - settleStart - settled.checkMs)
  agent!.checkMs += settled.checkMs
  if (settled.repair !== null) { agent!.repair = settled.repair }
  agent!.note += settled.note
  if (settled.errors.length > 0) {
    agent!.note += '; whole screen: ' + settled.errors
    return false
  }
  agent!.vbc2 = settled.vbc2
  agent!.source = settled.source
  agent!.composed.source = settled.source
  agent!.errors = ''
  agent!.screen = plan
  // The whole screen is one written section: a record of it lets a section be added beside it, or it be taken away.
  let record = compositionFromPlan(plan, prompt, [], [])
  agent!.record = settled.repair === null && rebuilds(record, settled.source) ? record : null
  agent!.note += '; whole screen written in ' + written.attempts.toString() + ' attempt(s)'
  return true
}

/**
 * A game, a toy, a simulation or a drawing (AgentSurface.ets): written whole on a ui.Surface, from a design the plan model
 * writes. Null when the request is not one, so the agent builds it; an outcome when it is, served or not -- a game the
 * agent's parts would build is a screen of buttons pretending to be one, so a game that could not be written is not built.
 * A screen of which only a part is drawn (a roulette wheel beside the bets) is the agent's too, told of its scene: the plan
 * makes it a need of its own, and the section hole writes it on a surface beside the rest.
 */
async function buildSurface(request: RouteRequest, host: AgentHost): Promise<RouteOutcome | null> {
  checkAgent(host)
  if (request.agent === null || request.agent!.widget || request.mode !== 'deepseek') { return null }
  let prompt = request.agent!.prompt
  let started = Date.now()
  let brief = await briefSurface(prompt, host)
  checkAgent(host)
  let briefMs = Date.now() - started
  if (brief === null || brief.kind !== SURFACE_WHOLE) {
    // The question was asked and answered no, part or not at all: its time is the agent's first stage.
    if (brief !== null && brief.kind === SURFACE_PART) { request.agent!.scene = brief.scene }
    if (brief !== null && brief.kind === SURFACE_NONE) { request.agent!.sceneAllowed = false }
    return null
  }
  let outcome = new RouteOutcome()
  let result = new AgentResult()
  outcome.agent = result
  addStage(result.stages, 'Model designs the game', WHO_MODEL, briefMs, brief.title)
  checkAgent(host)
  let written = await writeSurfaceApp(prompt, brief, host)
  checkAgent(host)
  addStage(result.stages, 'Model writes the game', WHO_MODEL, written.writeMs, written.attempts.toString() + ' attempt(s)')
  addStage(result.stages, 'Compile and play it', WHO_PHONE, written.checkMs)
  result.note = written.note
  result.ms = Date.now() - started
  if (host.cancelled()) { outcome.kind = OUTCOME_CANCELLED; return outcome }
  if (written.source.length === 0) {
    outcome.kind = OUTCOME_NOT_BUILT
    outcome.reason = written.note
    return outcome
  }
  result.source = written.source
  result.vbc2 = written.vbc2
  result.composed.source = written.source
  result.composed.sketch = JSON.stringify(brief)
  outcome.kind = OUTCOME_AGENT
  return outcome
}

export async function buildScreen(request: RouteRequest, host: AgentHost): Promise<RouteOutcome> {
  let outcome = new RouteOutcome()
  try {
    checkAgent(host)
    let surface = await buildSurface(request, host)
    checkAgent(host)
    if (surface !== null) { return surface }
    if (request.agent !== null) {
      let result = await runAgent(request.agent!, host)
      checkAgent(host)
      outcome.agent = result
      if (result.vbc2.length > 0) { outcome.kind = OUTCOME_AGENT; return outcome }
    }
    checkAgent(host)
    let whole = await writeWholeScreen(request, host, outcome)
    checkAgent(host)
    if (whole) { outcome.kind = OUTCOME_AGENT; return outcome }
    outcome.kind = OUTCOME_NOT_BUILT
    outcome.reason = notBuiltReason(outcome)
    return outcome
  } catch (e) {
    if (agentCancellation(host).isCancelled() || (e as Error).name === 'OperationCancelledError') {
      let cancelled = new RouteOutcome()
      cancelled.kind = OUTCOME_CANCELLED
      return cancelled
    }
    throw (e as Error)
  }
}

/** What the agent said, for a screen it did not build. */
function notBuiltReason(outcome: RouteOutcome): string {
  if (outcome.agent === null) { return 'nothing was tried' }
  return 'agent: ' + (outcome.agent!.note.length > 0 ? outcome.agent!.note : 'no answer')
}
