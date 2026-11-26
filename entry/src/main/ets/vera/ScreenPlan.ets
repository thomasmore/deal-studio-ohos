/**
 * The plan of a screen: the one format both ways of planning give, and the one the program is assembled from.
 *
 * Planning is fast when Jev picks a layout of the catalogue (VeraLayouts.ets, the blocks) and slow when the model
 * sketches the screen (VeraCompose.ets's sketch). Either way the result is a ScreenPlan:
 *
 *   state       the named values the screen keeps: what the person sets, what is worked out, the clock, the list
 *   slots       what the screen does, each in words, with the state it reads and writes and, for something the
 *               phone does, the moment it happens at
 *   components  what fills the slots, in screen order: a part the composer makes from the state, a section of the
 *               catalogue, or a section the model writes for the request (a hole)
 *
 * Each slot names the component that fills it; one component may fill several (the composer's inputs part fills
 * every input slot). A slot nothing fills yet is open, and a plan with an open slot is not served. Implementation
 * is filling every slot: picked by Jev when something ready fits, written by the model when nothing does.
 */

import { FragmentSpec } from './VeraTemplates'
import { NeedsPlan } from './NeedsPlan'
import { composeFragments } from './VeraSectionCompose'
import { findLayout } from './VeraLayouts'

/** Nothing fills the slot yet; `detail` says why. */
export const FILL_OPEN: string = 'open'
/** The `detail` of an open slot a section the model writes is to fill; any other open slot refuses the screen. */
export const TO_WRITE: string = 'to be written'
/** A part the composer makes from the plan's state (VeraCompose.ets). */
export const FILL_PART: string = 'part'
/** A section of the catalogue (VeraTemplates.ets's fragments). */
export const FILL_BLOCK: string = 'block'
/** One of the composer's phone actions, carried out by its effects part; `detail` is the effect's id. */
export const FILL_EFFECT: string = 'effect'
/** A section the model wrote for this request. */
export const FILL_HOLE: string = 'hole'
/**
 * Not done, and the screen says so: a notice in its place says what this phone or app cannot do and why. The rest of
 * the screen is served with it, rather than nothing.
 */
export const FILL_REPORTED: string = 'reported'

export const PLAN_FROM_SKETCH: string = 'sketch'
export const PLAN_FROM_LAYOUT: string = 'layout'

/** A named value the screen keeps. */
export class StateItem {
  name: string = ''
  /** input, constant, value, clock or list. */
  role: string = ''
  /** The VERA type of the value. */
  type: string = 'number'
  label: string = ''
  constructor(name: string, role: string, type: string, label: string) {
    this.name = name
    this.role = role
    this.type = type
    this.label = label
  }
}

/** Something the screen does. */
export class PlanSlot {
  id: string = ''
  /** What it does for the person, in words. */
  need: string = ''
  /** Names in the plan's state (or a component's ports) it reads and writes. */
  reads: string[] = []
  writes: string[] = []
  /** For something the phone does: the moment it happens at; '' otherwise. */
  when: string = ''
  /** Something the phone or another app does: whoever writes it is shown the phone's functions found for it. */
  phone: boolean = false
  /** The kinds of component that may fill it ([] for any); a layout's slot names them. */
  accepts: string[] = []
  /** The request asked for it; a slot the plan added on its own can be left out rather than refuse the screen. */
  asked: boolean = true
  fill: string = FILL_OPEN
  /** The component that fills it, as its index in the plan's components; -1 while open. */
  by: number = -1
  /** The effect's id for an effect, why for an open slot, '' otherwise. */
  detail: string = ''
  constructor(id: string, need: string) {
    this.id = id
    this.need = need
  }
}

/** A block of the program: its text and the values its tokens take. */
export class PlanComponent {
  fill: string
  /** null for a place in the screen nothing is in. */
  spec: FragmentSpec | null
  values: Map<string, string>
  constructor(fill: string, spec: FragmentSpec | null, values: Map<string, string>) {
    this.fill = fill
    this.spec = spec
    this.values = values
  }
}

export class ScreenPlan {
  /** Shared-module app context for a single whole-app contribution; absent on the old screen path. */
  appPlan: NeedsPlan | null = null
  /** Which way the plan was made: PLAN_FROM_SKETCH or PLAN_FROM_LAYOUT. */
  origin: string = PLAN_FROM_SKETCH
  prompt: string = ''
  /** A widget inside a chat reply rather than a whole screen. */
  widget: boolean = false
  /** The catalogue's layout the slots are arranged in; 'stack' for one under another. */
  layout: string = 'stack'
  /** __THEME__, __HEADER_STYLE__, __TITLE__ and the rest of the header (VeraSectionCompose.ets's composeFragments). */
  globals: Map<string, string> = new Map<string, string>()
  state: StateItem[] = []
  slots: PlanSlot[] = []
  components: PlanComponent[] = []

  open(): PlanSlot[] {
    return this.slots.filter((s: PlanSlot): boolean => s.fill === FILL_OPEN)
  }

  /** The open slots a section the model writes is to fill. */
  toWrite(): PlanSlot[] {
    return this.slots.filter((s: PlanSlot): boolean => s.fill === FILL_OPEN && s.detail === TO_WRITE)
  }

  /** A need nothing in the plan does yet, as a slot for a written section to fill. */
  addToWrite(id: string, need: string, phone: boolean = false): PlanSlot {
    let slot = new PlanSlot(id, need)
    slot.detail = TO_WRITE
    slot.phone = phone
    this.slots.push(slot)
    return slot
  }

  /** The slot to fill with the component at `index`, which must already be in the plan. */
  fillWith(slot: PlanSlot, fill: string, index: number, detail: string = ''): void {
    slot.fill = fill
    slot.by = index
    slot.detail = detail
  }
}

/**
 * The program for the plan, '' when a slot is open. `partial` assembles what is filled and leaves the open slots out:
 * the program so far, for a hole to be written against.
 */
export function assemblePlan(plan: ScreenPlan, partial: boolean = false): string {
  if (!partial && plan.open().length > 0) { return '' }
  let specs: (FragmentSpec | null)[] = []
  let values: Map<string, string>[] = []
  // A notice that part of the screen is missing shows first, under the title: at the bottom of a long screen the person never
  // reaches it and takes what is there for everything asked (measured: Exam prep, a form and a list above it). It is drawn first
  // (FragmentSpec.viewFirst) but placed last: put first, it took block 1 and renumbered every block after it, so a section written
  // against the program before the notice existed read another block's names (review of #46).
  // Several are one banner, each its own line: three stacked banners took half the screen above anything that works (Timetable).
  // A notice that only says what the screen does instead (NOTICE_INSTEAD) is not a warning: it goes last, after what it explains.
  let notices: FragmentSpec[] = []
  let insteads: FragmentSpec[] = []
  for (let c of plan.components) {
    if (c.fill === FILL_REPORTED && c.spec !== null && c.spec!.kind === 'notice') {
      if (c.spec!.criteria.startsWith(NOTICE_INSTEAD_TITLE + NOTICE_SPLIT)) { insteads.push(c.spec!) } else { notices.push(c.spec!) }
    }
  }
  // The folded settings (VeraCompose.ets's settingsPart) go under every section: what the screen is for comes first.
  let settings: PlanComponent[] = []
  for (let c of plan.components) {
    if (c.fill === FILL_REPORTED && c.spec !== null && c.spec!.kind === 'notice') { continue }
    if (c.spec !== null && c.spec!.kind === SETTINGS_PART) { settings.push(c); continue }
    specs.push(c.spec)
    values.push(c.values)
  }
  for (let c of settings) { specs.push(c.spec); values.push(c.values) }
  if (notices.length > 0) {
    specs.push(notices.length > 1 ? oneNotice(notices) : notices[0])
    values.push(new Map<string, string>())
  }
  if (insteads.length > 0) {
    specs.push(insteads.length > 1 ? oneNotice(insteads, 'info') : insteads[0])
    values.push(new Map<string, string>())
  }
  return composeFragments(specs, plan.globals, values)
}

/** Between a notice's title and its words in FragmentSpec.criteria (agent/AgentHole.ets's noticeBlock). */
export const NOTICE_SPLIT: string = '\u0001'

/** The title of a notice that says what the screen does instead (agent/AgentHole.ets's NOTICE_INSTEAD; kept here to avoid a cycle). */
export const NOTICE_INSTEAD_TITLE: string = 'Done differently'

/** The kind of the composer's folded settings part (VeraCompose.ets's SETTINGS_KIND; kept here to avoid a cycle). */
export const SETTINGS_PART: string = 'settings'

/** The notices of a screen as one banner: their common title, or a general one, and each one's words on a line of its own. */
function oneNotice(notices: FragmentSpec[], icon: string = 'warning'): FragmentSpec {
  let style = icon === 'warning' ? 'warning' : 'default'
  let titles: string[] = []
  let lines: string[] = []
  for (let n of notices) {
    let at = n.criteria.indexOf(NOTICE_SPLIT)
    if (at < 0) { continue }
    let title = n.criteria.substring(0, at)
    let body = n.criteria.substring(at + NOTICE_SPLIT.length)
    if (titles.indexOf(title) < 0) { titles.push(title) }
    if (lines.indexOf(body) < 0) { lines.push(body) }
  }
  let title = titles.length === 1 ? titles[0] : 'Some parts are limited'
  let view = '{\n  sections.push(ui.Section("supporting", "", "", [ui.InsetBanner("' + style + '", "' + title + '", "' +
    lines.map((l: string): string => '- ' + l).join('\\n') + '", "", "", "' + icon + '")]));\n}'
  let spec = new FragmentSpec('notice', '', '', [], '', '', '', view, [], [])
  spec.indexed = false
  // A banner of what is done differently goes where a single one does (noticeBlock): last, not above every section.
  spec.viewFirst = icon !== 'info'
  return spec
}

/** One line per slot, for the trace and the host checks: "id fill(detail) by=N: need". */
export function describePlan(plan: ScreenPlan): string {
  let lines: string[] = []
  for (let s of plan.slots) {
    let kind = s.by >= 0 && s.by < plan.components.length && plan.components[s.by].spec !== null ?
      plan.components[s.by].spec!.kind : ''
    lines.push(s.id + ' ' + s.fill + (s.detail.length > 0 ? '(' + s.detail + ')' : '') + (kind.length > 0 ? ' by ' + kind : '') +
      (s.reads.length > 0 ? ' reads ' + s.reads.join(',') : '') + (s.writes.length > 0 ? ' writes ' + s.writes.join(',') : '') +
      (s.when.length > 0 ? ' when ' + s.when : '') + (s.phone ? ' (phone)' : '') + ': ' + s.need)
  }
  return lines.join('\n')
}

/** The names a block's ports publish (writes) or ask for (reads). */
export function portNames(spec: FragmentSpec, dir: string): string[] {
  let out: string[] = []
  for (let p of spec.ports) { if (p.dir === dir && out.indexOf(p.name) < 0) { out.push(p.name) } }
  return out
}

/** The kinds the layout's slot that takes `kind` accepts: the slot naming it, else its slot for any kind; [] when none. */
function acceptsOf(layout: string, kind: string): string[] {
  let spec = findLayout(layout)
  if (spec === null) { return [] }
  for (let slot of spec.slots) { if (slot.accepts.indexOf(kind) >= 0) { return slot.accepts } }
  for (let slot of spec.slots) { if (slot.accepts.indexOf('*') >= 0) { return slot.accepts } }
  return []
}

/**
 * The plan of the blocks' pick: Jev's layout, one slot per section it chose, each filled by that section. `specs[i]`
 * is null for an empty place, which takes no slot. The blocks' shared state is their ports.
 */
export function planFromBlocks(prompt: string, layout: string, specs: (FragmentSpec | null)[], globals: Map<string, string>,
    values: Map<string, string>[]): ScreenPlan {
  let plan = new ScreenPlan()
  plan.origin = PLAN_FROM_LAYOUT
  plan.prompt = prompt
  plan.layout = layout
  globals.forEach((v: string, k: string) => { plan.globals.set(k, v) })
  for (let i = 0; i < specs.length; i++) {
    let spec = specs[i]
    plan.components.push(new PlanComponent(spec === null ? FILL_OPEN : FILL_BLOCK, spec,
      i < values.length ? values[i] : new Map<string, string>()))
    if (spec === null) { continue }
    let slot = new PlanSlot(spec.kind + '.' + (i + 1).toString(), spec.criteria)
    slot.reads = portNames(spec, 'reads')
    slot.writes = portNames(spec, 'writes')
    slot.accepts = acceptsOf(layout, spec.kind)
    plan.fillWith(slot, FILL_BLOCK, i)
    plan.slots.push(slot)
    for (let port of spec.ports) {
      if (port.dir === 'writes' && !plan.state.some((s: StateItem): boolean => s.name === port.name)) {
        plan.state.push(new StateItem(port.name, 'port', port.type, port.name))
      }
    }
  }
  return plan
}
