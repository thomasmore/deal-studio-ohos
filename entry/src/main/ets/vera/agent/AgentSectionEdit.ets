/**
 * A change to the section the model wrote for a screen (the `custom` block of its composition, VeraComposition.ets):
 * written again by the section writer (AgentCustom.ets's writeSection), shown the section as it is and the change, against
 * the rest of the screen, and checked as any section is -- compiled, run with every handler tapped, read by Jev against the
 * change. The rest of the screen is not touched. Null when the screen has no such section; a change it cannot make leaves
 * the screen as it was, and the refine goes on to edits of the whole program (AgentSurfaceEdit.ets's editProgram).
 */

import { AgentHost, checkAgent, agentCancellation } from './AgentHost'
import { CustomRequest, CustomResult, writeSection } from './AgentCustom'
import { Composition, composeFrom } from '../VeraComposition'
import { FragmentSpec, StateFieldSpec } from '../VeraTemplates'
import { compileVeraSource } from '../VeraCompiler'

/**
 * On by default: a refine the structure does not take is made by changing the written section, else by edits of the whole
 * program (GeneratePage.ets), before the old whole rewrite; `--ps veraRefineEdit 0` goes straight to the whole rewrite.
 */
let refineEdit: boolean = true
export function setRefineEditEnabled(on: boolean): void { refineEdit = on }
export function refineEditEnabled(): boolean { return refineEdit }

/** Where the written section is in the composition, -1 when it has none. */
export function writtenSectionAt(c: Composition): number {
  for (let i = 0; i < c.blocks.length; i++) {
    if (c.blocks[i].kind === 'custom' && c.blocks[i].literal !== null) { return i }
  }
  return -1
}

/** `name: value` of each field from a block's init entries ("a: 1, b: [1, 2]"), split where the next field's name begins. */
function initValues(spec: FragmentSpec): Map<string, string> {
  let out = new Map<string, string>()
  let text = spec.initEntries
  let starts: number[] = []
  for (let f of spec.stateFields) {
    let at = text.indexOf(f.name + ':')
    starts.push(at)
  }
  for (let i = 0; i < spec.stateFields.length; i++) {
    let at = starts[i]
    if (at < 0) { continue }
    let end = text.length
    for (let j = 0; j < starts.length; j++) { if (starts[j] > at && starts[j] < end) { end = starts[j] } }
    let value = text.substring(at + spec.stateFields[i].name.length + 1, end).trim()
    if (value.endsWith(',')) { value = value.substring(0, value.length - 1).trim() }
    out.set(spec.stateFields[i].name, value)
  }
  return out
}

/** A written section in the form the writer answers in (AgentCustom.ets's CONTRACT): the inverse of parseSection. */
export function sectionText(spec: FragmentSpec): string {
  let inits = initValues(spec)
  let fields = spec.stateFields.map((f: StateFieldSpec): string => f.name + ': ' + f.type + ' = ' + (inits.get(f.name) ?? ''))
  let view = spec.viewBlock.trim()
  if (view.startsWith('{') && view.endsWith('}')) { view = view.substring(1, view.length - 1).trim() }
  return '<classes>\n' + spec.supportClass.trim() + '\n</classes>\n<fields>\n' + fields.join('\n') + '\n</fields>\n<functions>\n' +
    spec.functions.trim() + '\n</functions>\n<view>\n' + view + '\n</view>'
}

export class SectionEdit {
  /** The changed program and its composition; '' and null when no change passed. */
  source: string = ''
  vbc2: string = ''
  composition: Composition | null = null
  /** What the writer did: its attempts, its refusal, why it failed. */
  written: CustomResult = new CustomResult()
}

/**
 * The screen of `c` with its written section changed as `change` asks; `prompt` is what the screen was made for (with the
 * refinements so far). Null when the screen has no written section.
 */
export async function editSection(c: Composition, change: string, prompt: string, host: AgentHost): Promise<SectionEdit | null> {
  checkAgent(host)
  let at = writtenSectionAt(c)
  if (at < 0) { return null }
  let out = new SectionEdit()
  if (host.askCode === null || host.language.length === 0) {
    out.written.failed = 'no model to change the section with'
    return out
  }
  let withSection = (section: FragmentSpec | null): Composition => {
    let copy = c.copy()
    if (section === null) { copy.blocks.splice(at, 1) } else { copy.blocks[at].literal = section }
    return copy
  }
  let asked = new CustomRequest()
  asked.needs = [change]
  asked.prompt = prompt
  asked.previous = sectionText(c.blocks[at].literal!)
  asked.whole = c.blocks.length === 1
  asked.compose = (section: FragmentSpec | null): string => composeFrom(withSection(section))
  asked.verify = host.askJev
  // The phone functions the change may need: looked up for the change as for a need.
  checkAgent(host)
  let found = await host.lookup(change)
  checkAgent(host)
  asked.phone = found.length > 0 ? 'For "' + change + '":\n' + found.substring(0, 8000) : ''
  out.written = await writeSection(asked, host.language, host.askCode!, agentCancellation(host), (): string => host.lastCodeFinish)
  checkAgent(host)
  let section = out.written.section
  if (section === null || out.written.missed.length > 0) {
    if (out.written.failed.length === 0) { out.written.failed = 'the section does not make the change' }
    return out
  }
  // The block keeps the kind and place of the one it replaces; what the plan said it was for stays its criteria.
  section.criteria = c.blocks[at].literal!.criteria
  out.composition = withSection(section)
  out.source = composeFrom(out.composition)
  out.vbc2 = compileVeraSource(out.source).vbc2
  return out
}
