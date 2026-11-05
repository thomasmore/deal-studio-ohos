/**
 * The slow fill of a plan (ScreenPlan.ets): the slots nothing ready does, written by the model as one section of the
 * program (AgentCustom.ets's writeSection) against the rest of the plan, checked, and put in the plan as the component
 * that fills them. Whichever way the plan was made -- the agent's sketch or the blocks' layout -- it is filled the same way.
 */

import { AgentHost, HoleRecord, checkAgent, agentCancellation } from './AgentHost'
import { CustomRequest, CustomResult, writeSection } from './AgentCustom'
import { FragmentSpec, StateFieldSpec } from '../VeraTemplates'
import { ScreenPlan, PlanComponent, PlanSlot, assemblePlan, FILL_HOLE, FILL_REPORTED } from '../ScreenPlan'
import { PartsContract } from '../VeraCompose'

const OUTCOME_WRITTEN: string = 'written'
const OUTCOME_PARTIAL: string = 'partial'
const OUTCOME_REPORTED: string = 'reported'
const OUTCOME_KNOWN: string = 'known'

function recordOf(plan: ScreenPlan, prompt: string, slots: PlanSlot[], written: CustomResult, outcome: string): HoleRecord {
  let r = new HoleRecord()
  r.prompt = prompt
  r.origin = plan.origin
  r.needs = slots.map((s: PlanSlot): string => s.need)
  r.phone = slots.map((s: PlanSlot): boolean => s.phone)
  r.outcome = outcome
  r.attempts = written.attempts
  r.thought = written.thought
  r.ms = written.ms
  r.missed = written.missed
  r.why = written.cannot.length > 0 ? written.cannot : written.failed
  let s = written.section
  if (s !== null) {
    r.code = s.supportClass + '\n' + s.stateFields.map((f: StateFieldSpec): string => f.name + ': ' + f.type).join('\n') +
      '\n' + s.functions + '\n' + s.viewBlock
  }
  return r
}

/** How much of each lookup's answer the writer is shown. */
const LOOKUP_CHARS: number = 8000

/** Text as it goes between the quotes of a VERA string literal: no quotes, backslashes or line breaks. */
function literal(text: string): string {
  return text.split('\\').join('/').split('"').join("'").split('\n').join(' ').trim()
}

/** The first sentence of `text`, at most 140 characters. */
function firstSentence(text: string): string {
  let t = text.trim()
  let at = t.search(/[.!?](\s|$)/)
  if (at > 0) { t = t.substring(0, at + 1) }
  return t.length > 140 ? t.substring(0, 137).trim() + '...' : t
}

/**
 * A warning in place of what could not be built. The plan's needs are its own wording, not the person's, so the title is
 * fixed and `why` -- the writer's own sentence for the person when it said it cannot -- carries the rest.
 */
export function noticeBlock(cannot: boolean, why: string): FragmentSpec {
  let unchecked = !cannot && why.startsWith('It may not do')
  let title = cannot ? 'Not available on this phone' : (unchecked ? 'Not checked' : 'Part of this app could not be built')
  // The person sees one short sentence: the plan's needs and the writer's failure are its own wording and stay in the trace.
  let body = cannot ? firstSentence(why) : (unchecked ? 'This part may not work exactly as described.' : 'Try asking for it again, or describe it differently.')
  let view = '{\n  sections.push(ui.Section("supporting", "", "", [ui.InsetBanner("warning", "' + literal(title) + '", "' +
    literal(body) + '", "", "", "warning")]));\n}'
  let spec = new FragmentSpec('notice', '', '', [], '', '', '', view, [], [])
  spec.indexed = false
  return spec
}

/**
 * The screen's subtitle is the plan's own line about what the app does, written before anything was built: when part of the
 * screen is a notice that something could not be done, a subtitle that promises it contradicts the notice, so there is none.
 */
function quietSubtitle(plan: ScreenPlan): void {
  if (plan.components.some((c: PlanComponent): boolean => c.fill === FILL_REPORTED)) { plan.globals.set('__SUPPORTING__', '') }
}

/** The plan with `section` after everything else, assembled; null assembles what is filled, the program so far. */
function withSection(plan: ScreenPlan, section: FragmentSpec | null): string {
  if (section === null) { return assemblePlan(plan, true) }
  plan.components.push(new PlanComponent(FILL_HOLE, section, new Map<string, string>()))
  let source = assemblePlan(plan, true)
  plan.components.pop()
  return source
}

/**
 * Writes the section for the plan's slots to be written, and fills them with it. Null when there are none; otherwise
 * what writing did, with `failed` saying why the slots are still open. `hints` are lines the writer is told about the
 * screen (inputs nothing else reads, and where they are in the state).
 */
export async function writeHole(plan: ScreenPlan, prompt: string, hints: string[], host: AgentHost,
    facts: string[] = [], contract: PartsContract | null = null): Promise<CustomResult | null> {
  checkAgent(host)
  let cancellation = agentCancellation(host)
  let slots: PlanSlot[] = plan.toWrite()
  if (slots.length === 0) { return null }
  // Phone needs an earlier hole of this request already found nothing can do are reported as it said, not asked again.
  let known = slots.filter((s: PlanSlot): boolean => s.phone && host.cannot.has(s.need))
  if (known.length > 0 && plan.components.length === 0 && known.length === slots.length) {
    // The whole screen is nothing but those: there is nothing to write, and no rest to serve.
    let nothing = new CustomResult()
    nothing.cannot = host.cannot.get(known[0].need)!
    nothing.failed = 'custom section cannot: ' + nothing.cannot + ' (known from an earlier hole)'
    return nothing
  }
  if (known.length > 0) {
    let why = host.cannot.get(known[0].need)!
    plan.components.push(new PlanComponent(FILL_REPORTED, noticeBlock(true, why), new Map<string, string>()))
    for (let s of known) { plan.fillWith(s, FILL_REPORTED, plan.components.length - 1, why) }
    slots = plan.toWrite()
    if (slots.length === 0) {
      let reported = new CustomResult()
      reported.cannot = why
      reported.failed = 'custom section cannot: ' + why + ' (known from an earlier hole)'
      host.onHole(recordOf(plan, prompt, known, reported, OUTCOME_KNOWN))
      checkAgent(host)
      quietSubtitle(plan)
      return reported
    }
  }
  if (host.askCode === null || host.language.length === 0) {
    let none = new CustomResult()
    none.failed = 'no model to write a custom section'
    return none
  }
  let asked = new CustomRequest()
  asked.needs = slots.map((s: PlanSlot): string => s.need)
  asked.prompt = prompt
  asked.inputs = hints
  asked.facts = facts
  if (contract !== null) { asked.parts = contract.lines; asked.ownsClock = contract.clock; asked.ownsList = contract.list }
  // A plan with nothing in it yet is the whole screen as one hole.
  asked.whole = plan.components.length === 0
  asked.compose = (section: FragmentSpec | null): string => withSection(plan, section)
  asked.verify = host.askJev
  // What the phone could do for each need: its functions found for every need, not only those the plan marked as the phone's.
  // Whether "show it on a map" or "turn the torch on" is the phone's job is not for a keyword or the plan to decide; the lookup
  // answers nothing for a need that is not, and the writer may call only what was found.
  checkAgent(host)
  let texts = await Promise.all(slots.map(async (s: PlanSlot): Promise<string> => {
    checkAgent(host)
    let text = host.looked.get(s.need) ?? await host.lookup(s.need)
    checkAgent(host)
    host.looked.set(s.need, text)
    return text
  }))
  checkAgent(host)
  let found: string[] = []
  for (let i = 0; i < slots.length; i++) {
    if (texts[i].length > 0) { found.push('For "' + slots[i].need + '":\n' + texts[i].substring(0, LOOKUP_CHARS)) }
  }
  asked.phone = found.join('\n\n')
  checkAgent(host)
  let written = await writeSection(asked, host.language, host.askCode!, cancellation)
  checkAgent(host)
  // A refusal of several needs at once says nothing of each: a need the phone can do is not lost with one it cannot. Each is
  // then written on its own, with only the functions found for it.
  if (written.cannot.length > 0 && slots.length > 1 && !asked.whole) {
    host.onHole(recordOf(plan, prompt, slots, written, OUTCOME_REPORTED))
    for (let i = 0; i < slots.length; i++) {
      checkAgent(host)
      let one = new CustomRequest()
      one.needs = [slots[i].need]
      one.prompt = prompt
      one.inputs = hints
      one.facts = facts
      if (contract !== null) { one.parts = contract.lines; one.ownsClock = contract.clock; one.ownsList = contract.list }
      one.compose = asked.compose
      one.verify = host.askJev
      one.phone = texts[i].length > 0 ? 'For "' + slots[i].need + '":\n' + texts[i].substring(0, LOOKUP_CHARS) : ''
      let single = await writeSection(one, host.language, host.askCode!, cancellation)
      checkAgent(host)
      settle(plan, prompt, [slots[i]], one, single, host)
    }
    checkAgent(host)
    quietSubtitle(plan)
    return written
  }
  settle(plan, prompt, slots, asked, written, host)
  quietSubtitle(plan)
  return written
}

/** Puts what writing the section did in the plan: the section for the slots it does, a notice for the rest. */
function settle(plan: ScreenPlan, prompt: string, slots: PlanSlot[], asked: CustomRequest, written: CustomResult, host: AgentHost): void {
  checkAgent(host)
  // Remembered for the rest of the request only when this was the need alone: a refusal of several says nothing of each.
  if (written.cannot.length > 0 && slots.length === 1 && slots[0].phone) { host.cannot.set(slots[0].need, written.cannot) }
  let record = recordOf(plan, prompt, slots, written, written.section === null ? OUTCOME_REPORTED :
    (written.missed.length > 0 ? OUTCOME_PARTIAL : OUTCOME_WRITTEN))
  record.whole = asked.whole
  record.lookup = asked.phone
  checkAgent(host)
  host.onHole(record)
  checkAgent(host)
  if (written.section !== null) {
    plan.components.push(new PlanComponent(FILL_HOLE, written.section, new Map<string, string>()))
    let at = plan.components.length - 1
    let missed = slots.filter((s: PlanSlot): boolean => written.missed.indexOf(s.need) >= 0)
    // What the writer declined it says in its own words; what Jev does not read the section as doing is only "not checked".
    let said = missed.filter((s: PlanSlot): boolean => written.declined.has(s.need))
    let unread = missed.filter((s: PlanSlot): boolean => !written.declined.has(s.need))
    let noticeAt = new Map<string, number>()
    for (let s of said) {
      let why = written.declined.get(s.need)!
      if (!noticeAt.has(why)) {
        plan.components.push(new PlanComponent(FILL_REPORTED, noticeBlock(true, why), new Map<string, string>()))
        noticeAt.set(why, plan.components.length - 1)
      }
    }
    if (unread.length > 0) {
      // Served, with a notice for the part of it Jev does not read it as doing.
      let why = 'It may not do: ' + unread.map((s: PlanSlot): string => s.need).join('; ') + '.'
      plan.components.push(new PlanComponent(FILL_REPORTED, noticeBlock(false, why), new Map<string, string>()))
    }
    for (let s of slots) {
      if (written.declined.has(s.need) && missed.indexOf(s) >= 0) {
        plan.fillWith(s, FILL_REPORTED, noticeAt.get(written.declined.get(s.need)!)!, written.declined.get(s.need)!)
      } else if (missed.indexOf(s) >= 0) { plan.fillWith(s, FILL_REPORTED, plan.components.length - 1, written.failed) }
      else { plan.fillWith(s, FILL_HOLE, at) }
    }
  } else if (!asked.whole) {
    // Reported, not dropped: the rest of the screen is served with a notice in place of what could not be built. The
    // whole screen as a hole has no rest to serve.
    let cannot = written.cannot.length > 0
    let why = cannot ? written.cannot : 'Not built: ' + asked.needs.join('; ') + '. ' + written.failed
    plan.components.push(new PlanComponent(FILL_REPORTED, noticeBlock(cannot, why), new Map<string, string>()))
    for (let s of slots) { plan.fillWith(s, FILL_REPORTED, plan.components.length - 1, why) }
  }
}
