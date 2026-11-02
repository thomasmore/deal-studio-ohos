/**
 * The agent: the slow path for a request the blocks do not serve. It plans the screen (DeepSeek, no thinking,
 * a JSON plan), has Jev choose how each part of the plan is built, assembles the program and checks it --
 * compiled, then run once with every handler tapped (VeraSmoke.ets) -- before anything is shown.
 *
 * The plan is VeraCompose.ets's sketch; Jev's choices bind each of its parts, and pick a section of the catalogue
 * (VeraTemplates.ets) for each need the plan says one handles whole, whose content and holes the host fills. What
 * neither does is one custom section the model writes (AgentCustom.ets). Callers see only runAgent and AgentResult,
 * so those can change behind it. Never throws.
 */

import { agentCancellation, checkAgent, AgentHost } from './AgentHost'
import { BlockRequest, BlockFill } from '../SectionFill'
import { CustomResult } from './AgentCustom'
import { writeHole } from './AgentHole'
import { AgentQuestion, Asked, PersonAnswer, askBlocking } from './AgentQuestions'
import { Replaced, inputsOnlyForCustom, composePlanEnabled, provisionalProgram, sketchPlan, assembleProgram, screenPlan, partCount, customInputs, partsContract, dropProvided, ComposeResult, Composition, Sketch, SketchInput } from '../VeraCompose'
import { ScreenPlan, PlanSlot, PlanComponent, assemblePlan, FILL_BLOCK, FILL_PART, FILL_REPORTED } from '../ScreenPlan'
import { compileVeraSource } from '../VeraCompiler'
import { Repaired, settleProgram } from './AgentRepair'
import { FragmentSpec } from '../VeraTemplates'
import { buildSlotRequest, readSlotValues, specsOf } from '../VeraSectionCompose'
import { claimsDone, claimsUndone, putBack } from './AgentClaims'
import { composeNeeds } from '../NeedsChoose'
import { AlignResult, alignCandidates, alignIsEnabled, alignLeftovers } from './AgentAlign'
import { Composition as ScreenRecord, compositionFromPlan, rebuilds } from '../VeraComposition'
import { holeBodiesBySlot } from '../VeraHoles'
import { toolCount, toolSpanSince } from '../ToolLog'
import { Stage, addStage, WHO_MODEL, WHO_JEV, WHO_SEARCH, WHO_PHONE, WHO_YOU } from '../RunStages'

export class AgentRequest {
  /** What to build, in the person's words (or the chat's request for them). */
  prompt: string = ''
  /** A widget inside a chat reply rather than a whole screen. */
  widget: boolean = false
  /** What the route was told is drawn on the screen, moving or touched (AgentSurface.ets), for the plan; '' for nothing. */
  scene: string = ''
  /** False when the route asked and was told nothing here is drawn: the plan's scenes are then built as other needs. */
  sceneAllowed: boolean = true
}

export class AgentResult {
  /** The checked program; empty when the agent could not build one. */
  source: string = ''
  vbc2: string = ''
  /** One line for the trace: what was built, or why not. */
  note: string = ''
  /** Why the assembled program was not served: compile or runtime diagnostics, '' when it was or when nothing was assembled. */
  errors: string = ''
  /** The plan and Jev's answers, with their timings. */
  composed: ComposeResult = new ComposeResult()
  /** The plan in words for a generation to keep to, '' when there is none or plans are off. */
  plan: string = ''
  /** The catalogue's sections on the screen, in order; empty when it has none. */
  blocks: string[] = []
  /** What filling them did, when there were any. */
  blockFill: BlockFill | null = null
  /** What was left for the model to write that sections of the catalogue were then found for (AgentAlign.ets); null when not asked. */
  align: AlignResult | null = null
  /** What writing the custom section did, when the composition needed one. */
  custom: CustomResult | null = null
  /** What repairing the assembled program by edits did, when it did not compile or run; null otherwise. */
  repair: Repaired | null = null
  /** What writing the whole screen as one hole did, when nothing narrower served (agent/VeraBuildRoute.ets). */
  whole: CustomResult | null = null
  /** The questions put to the person, with their answers. */
  asked: Asked[] = []
  /** The screen's plan (ScreenPlan.ets) as far as it got: every slot and what fills it; null when Jev chose nothing. */
  screen: ScreenPlan | null = null
  /** The record of the served screen (VeraComposition.ets), for edits that change its structure; null when there is none that rebuilds this very program. */
  record: ScreenRecord | null = null
  firstPreviewMs: number = 0
  previews: number = 0
  checkMs: number = 0
  ms: number = 0
  /** Where the time went, in the order it happened (RunStages.ets); the person's waiting is a stage of its own. */
  stages: Stage[] = []

  /** Time the person spent answering the plan's questions: part of `ms`, and theirs, not the app's. */
  waitedMs(): number {
    let n = 0
    for (let a of this.asked) { n += a.waitedMs }
    return n
  }
}

/**
 * The record of the screen the agent served: its plan's components in order, the catalogue's blocks with the values and hole
 * bodies they were filled with. Null unless it rebuilds exactly the served program, so a screen no edit can be made to
 * through the record is never claimed to have one.
 */
function recordOf(result: AgentResult, comp: Composition, prompt: string): ScreenRecord | null {
  if (result.screen === null) { return null }
  let base: Map<string, string>[] = []
  let holes: Map<string, string>[] = []
  let fill = result.blockFill
  if (fill !== null && comp.blocks.length > 0) {
    let kinds: string[] = []
    let offset = partCount(comp)
    for (let i = 0; i < offset; i++) { kinds.push('none') }
    kinds = kinds.concat(comp.blocks)
    base = fill.baseValues
    holes = holeBodiesBySlot(kinds, fill.holeBodies).slice(offset)
  }
  let record = compositionFromPlan(result.screen!, prompt, base, holes)
  return rebuilds(record, result.source) ? record : null
}

/**
 * The screen again without the inputs only a section nobody could write was to read; the notices stay where the written
 * section's slots were.
 */
function withoutDeadInputs(comp: Composition, values: Map<string, string>[], plan: ScreenPlan): ScreenPlan {
  let dead = inputsOnlyForCustom(comp)
  comp.inputs = comp.inputs.filter((i: SketchInput): boolean => dead.indexOf(i.id) < 0)
  comp.customReads = comp.customReads.filter((id: string): boolean => dead.indexOf(id) < 0)
  let again = screenPlan(comp, values)
  let moved: Map<number, number> = new Map<number, number>()
  for (let i = 0; i < plan.components.length; i++) {
    if (plan.components[i].fill !== FILL_REPORTED) { continue }
    again.components.push(plan.components[i])
    moved.set(i, again.components.length - 1)
  }
  for (let s of again.toWrite()) {
    let was = plan.slots.find((x: PlanSlot): boolean => x.id === s.id)
    let at = was !== undefined && moved.has(was.by) ? moved.get(was.by)! : -1
    if (at < 0) { return plan }
    again.fillWith(s, FILL_REPORTED, at, was!.detail)
  }
  return again
}

export async function runAgent(request: AgentRequest, host: AgentHost): Promise<AgentResult> {
  checkAgent(host)
  let cancellation = agentCancellation(host)
  let result = new AgentResult()
  let started = Date.now()
  // The picture of the screen while it is being made: the plan as it streams, then the parts and sections Jev chose, then
  // those sections with their content. Each is a whole program; one that does not compile is skipped and the next replaces it.
  let preview = (source: string): void => {
    if (cancellation.isCancelled() || source.length === 0) { return }
    try {
      host.preview(compileVeraSource(source).vbc2)
      checkAgent(host)
      result.previews++
      if (result.firstPreviewMs === 0) { result.firstPreviewMs = Date.now() - started }
    } catch (_e) {
      checkAgent(host)
      if ((_e as Error).name === 'OperationCancelledError') { throw (_e as Error) }
    }
  }
  host.status(request.widget ? 'Sketching the widget...' : 'Composing...')
  let composed = await composeNeeds(request.prompt, host.askPlan, host.askJev, (partial: Sketch): void => {
    preview(provisionalProgram(partial, request.widget))
  }, request.widget, async (sketch: Sketch): Promise<string> => {
    checkAgent(host)
    let settled = await askBlocking(request.prompt, sketch.questions, host.askJev, (q: AgentQuestion): Promise<PersonAnswer> => {
      host.status('Waiting for your answer...')
      checkAgent(host)
      return host.ask(q)
    }, result.asked, cancellation)
    checkAgent(host)
    if (settled.length > 0) { host.status('Planning again with your answer...') }
    return settled
  }, request.scene, request.sceneAllowed, cancellation)
  checkAgent(host)
  result.composed = composed
  result.note = composed.note
  let planning = Date.now() - started
  let waitedOnYou = result.waitedMs()
  addStage(result.stages, 'Plan of needs', WHO_MODEL, composed.sketchMs, 'the request as a list of needs')
  addStage(result.stages, 'Choosing parts and sections', WHO_JEV, composed.jevMs)
  addStage(result.stages, 'Your answers', WHO_YOU, waitedOnYou, result.asked.length.toString() + ' question(s)')
  addStage(result.stages, 'Planning, the rest', WHO_PHONE, planning - composed.sketchMs - composed.jevMs - waitedOnYou, 'building the sketch, checks')
  result.plan = composed.parsed !== null && composePlanEnabled() ? sketchPlan(composed.parsed!) : ''
  // What the composition leaves to be written is first offered to the catalogue: a section may do exactly that.
  if (composed.composition !== null && alignIsEnabled() && !host.cancelled() && alignCandidates(composed.composition!).length > 0) {
    host.status('Looking for ready-made parts...')
    let alignStart = Date.now()
    let aligned = await alignLeftovers(composed.composition!, request.prompt, host.askJev, cancellation)
    checkAgent(host)
    addStage(result.stages, 'Looking for ready-made parts', WHO_JEV, Date.now() - alignStart)
    if (aligned.asked.length > 0 || aligned.note.length > 0) {
      result.align = aligned
      result.note += aligned.note
    }
  }
  // Sections of the catalogue: their content written for the request (from a search when it needs real data), and
  // their holes, before the program is assembled.
  if (composed.composition !== null && !host.cancelled()) {
    let comp: Composition = composed.composition!
    // What Jev chose, drawn before anything is written for it: the sections show their placeholder content.
    preview(assembleProgram(comp))
    let values: Map<string, string>[] = []
    let ready = true
    if (comp.blocks.length > 0) {
      host.status(comp.realData ? 'Looking up real data...' : 'Filling in the sections...')
      let blocks = new BlockRequest()
      blocks.kinds = comp.blocks
      // What the plan fixed for a section that took a part's place (a countdown's length) is told to the section's writer.
      let fixed: string[] = comp.replaced.filter((r: Replaced): boolean => r.detail.length > 0).map((r: Replaced): string => r.need + ': ' + r.detail)
      // The plan's own words for what each section is to hold: the section is written from them, not from the request alone, so
      // that it does not add what the plan did not (a timer's length, another list's worth of items).
      let said: string = comp.sketch.ready.length > 0 ? '\n\nThe plan says the sections are for: ' + comp.sketch.ready.join(' | ') : ''
      blocks.prompt = (fixed.length > 0 ? request.prompt + '\n\nThe plan fixes: ' + fixed.join('; ') : request.prompt) + said
      blocks.realData = comp.realData
      blocks.offset = partCount(comp)
      blocks.compose = (filled: Map<string, string>[], _globals: Map<string, string>): string => assembleProgram(comp, filled)
      // What each section is to offer (a button for each item, a calendar) is read from the request, as the blocks' own route
      // does: the composer counts on the section for what it left out of the plan, and the defaults leave it off.
      if (specsOf(comp.blocks).some((sp: FragmentSpec | null): boolean => sp !== null && sp.slots.length > 0)) {
        let slotStart = Date.now()
        checkAgent(host)
        let slotReply = await host.askJev(buildSlotRequest(request.prompt, comp.blocks))
        checkAgent(host)
        blocks.slotValues = readSlotValues(slotReply, comp.blocks)
        addStage(result.stages, 'What each section offers', WHO_JEV, Date.now() - slotStart)
        let specs = specsOf(comp.blocks)
        let provided: string[] = []
        for (let i = 0; i < specs.length; i++) {
          let spec = specs[i]
          if (spec === null) { continue }
          for (let slot of spec.slots) {
            if (blocks.slotValues[i].get(slot.token) === slot.values[1]) { provided = provided.concat(slot.provides) }
          }
        }
        let gone = dropProvided(comp, provided)
        if (gone.length > 0) { result.note += '; done by the sections: ' + gone.join('; ') }
      }
      let fillStart = Date.now()
      let fillTools = toolCount()
      checkAgent(host)
      let fill = await host.fillBlocks(blocks)
      checkAgent(host)
      let fillMs = Date.now() - fillStart
      let named = Math.max(0, fill.searchMs) + fill.contentMs + fill.holesMs
      // The phone-function lookups a hole makes before the model writes it are the phone's wait, not the model's.
      let holeLookups = Math.min(toolSpanSince(fillTools), fill.holesMs)
      addStage(result.stages, 'Looking up real data', WHO_SEARCH, fill.searchMs)
      addStage(result.stages, 'Text of the sections', WHO_MODEL, fill.contentMs)
      addStage(result.stages, 'Looking up phone functions for the sections', WHO_PHONE, holeLookups)
      addStage(result.stages, 'Functions of the sections', WHO_MODEL, fill.holesMs - holeLookups)
      addStage(result.stages, 'Filling the sections, the rest', WHO_PHONE, fillMs - named, 'checks of what was found')
      result.blocks = comp.blocks
      result.blockFill = fill
      result.note += '; ' + (fill.failed.length > 0 ? fill.failed : fill.note)
      ready = fill.failed.length === 0
      values = fill.values
    }
    // The plan, and what nothing ready does in it: one section the model writes into the program the rest makes.
    let plan = screenPlan(comp, values)
    result.screen = plan
    if (ready && comp.blocks.length > 0) { preview(assemblePlan(plan, true)) }
    // What was left out because a section is said to do it is checked against the screen the sections make.
    let claimStart = Date.now()
    if (ready && comp.claimed.length > 0 && !host.cancelled()) {
      let missing = await claimsUndone(comp.claimed, request.prompt, assemblePlan(plan, true), host.askJev, cancellation)
      checkAgent(host)
      if (missing.length > 0) {
        putBack(plan, missing)
        result.note += '; not done by the sections said to do it: ' + missing.join('; ')
      }
    }
    // What is left to write, read against the screen the sections make: a detail of how a section works or looks (how entries are
    // labelled, what a chart is drawn from) is the section's own, and is not written again.
    if (ready && plan.toWrite().length > 0 && !host.cancelled()) {
      // The screen's own parts count as much as the catalogue's sections: a lap list or a clock they draw is not written again.
      let own = plan.components.findIndex((c: PlanComponent): boolean => c.fill === FILL_BLOCK)
      let byPart = own < 0
      if (byPart) { own = plan.components.findIndex((c: PlanComponent): boolean => c.fill === FILL_PART) }
      let open = plan.toWrite().filter((s: PlanSlot): boolean => !s.phone && s.id.startsWith('custom.') && !s.need.startsWith('the figure "'))
      let done = own < 0 || open.length === 0 ? [] : await claimsDone(open.map((s: PlanSlot): string => s.need), request.prompt, assemblePlan(plan, true), host.askJev, cancellation)
      checkAgent(host)
      if (done.length > 0) {
        for (let slot of open) { if (done.indexOf(slot.need) >= 0) { plan.fillWith(slot, byPart ? FILL_PART : FILL_BLOCK, own, 'already on the screen') } }
        result.note += '; already on the screen: ' + done.join('; ')
      }
    }
    addStage(result.stages, 'Does a section do it already?', WHO_JEV, Date.now() - claimStart)
    if (ready && plan.toWrite().length > 0 && !host.cancelled()) {
      host.status('Writing the rest...')
      let writeStart = Date.now()
      let writeTools = toolCount()
      checkAgent(host)
      let written = await writeHole(plan, request.prompt, customInputs(comp), host, [], partsContract(comp))
      checkAgent(host)
      result.custom = written
      let wrote = Date.now() - writeStart
      let lookups = Math.min(toolSpanSince(writeTools), wrote)
      addStage(result.stages, 'Looking up phone functions', WHO_PHONE, lookups, 'before the model writes')
      addStage(result.stages, 'Model writes the rest', WHO_MODEL, wrote - lookups,
        written !== null ? written.attempts.toString() + ' attempt(s)' : '')
      ready = plan.toWrite().length === 0
      // Nothing written, only a notice: the inputs kept for what was to be written have nothing to do and are left off.
      if (ready && written !== null && written.section === null && inputsOnlyForCustom(comp).length > 0) {
        plan = withoutDeadInputs(comp, values, plan)
        result.screen = plan
      }
      if (written !== null) {
        result.note += '; ' + (written.section !== null ? 'custom section in ' + written.attempts.toString() + ' attempt(s)' :
          'reported on the screen (' + written.failed + ')')
      }
    }
    if (ready) { composed.source = assemblePlan(plan) }
  }
  if (composed.source.length > 0) {
    let settleStart = Date.now()
    checkAgent(host)
    let settled = await settleProgram(composed.source, request.prompt, host)
    checkAgent(host)
    addStage(result.stages, 'Compile and run once', WHO_PHONE, settled.checkMs)
    addStage(result.stages, 'Repair by edits', WHO_MODEL, Date.now() - settleStart - settled.checkMs)
    result.checkMs = settled.checkMs
    result.repair = settled.repair
    result.errors = settled.errors
    result.note += settled.note
    composed.source = settled.source
    if (settled.errors.length === 0) {
      result.source = settled.source
      result.vbc2 = settled.vbc2
      // A program the repair edited is no longer the plan's: there is no record of it.
      if (settled.repair === null && composed.composition !== null) { result.record = recordOf(result, composed.composition!, request.prompt) }
    } else {
      result.note += '; ' + settled.errors
    }
  }
  checkAgent(host)
  result.ms = Date.now() - started
  return result
}
