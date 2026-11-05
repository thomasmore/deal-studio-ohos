/**
 * Make widget: the widget written on its own. The general refine had the model write the whole program again to add one
 * function, and spliceWidget then threw everything but the widget away -- the reply was the program's length, most of the
 * wait. Here the model is shown the program, the request and the card's few components, and writes only what the widget
 * adds; the splice puts it into the program as it is. What does not pass (compile, one run with every handler tapped, the
 * card's checks and the glance limits) goes back with the reason, at most twice, the last time with thinking on.
 */

import { AgentHost } from './AgentHost'
import { languageWith, sourceIn } from './AgentSurface'
import { compileVeraSource, CompileError, spliceWidget, parseErrorOf } from '../VeraCompiler'
import { smokeRun } from '../VeraSmoke'
import { CARD_KINDS, widgetRefinementPrompt, validateWidgetRefinement, widgetRepairNote } from '../VeraWidgetRefine'

/** Room for a widget, its refresh and a helper or two: a fraction of a whole program's. */
export const WIDGET_TOKENS: number = 3000

/** How Make widget puts what the person typed: the widget should show what follows. */
export const WIDGET_ASK: string = 'The home-screen widget should show: '

/** Answers asked for: the first, then each failure's reason back, the last with thinking on. */
const WIDGET_ATTEMPTS: number = 3

export class WidgetWrite {
  /** The program with the widget, checked; '' when none passed. */
  source: string = ''
  vbc2: string = ''
  /** The last answer as written: only the widget's declarations. */
  written: string = ''
  attempts: number = 0
  /** What still failed, '' when served. */
  failed: string = ''
  ms: number = 0
}

/** '' when the program with the widget compiles, runs, and its widget draws within a glance over `saved`; else why not. */
export function checkWidgetProgram(base: string, source: string, saved: string): string {
  try {
    let compiled = compileVeraSource(source)
    let smoke = smokeRun(compiled)
    if (smoke.length > 0) { return smoke }
    return validateWidgetRefinement(base, source, compiled.vbc2, saved)
  } catch (e) {
    return e instanceof CompileError ? (e as CompileError).message : (e as Error).message
  }
}

/**
 * `source` with the widget `ask` describes: `prompt` is what the program was made for, `saved` its saved state (the widget
 * is checked against it). `failed` says why when no answer passed.
 */
export async function writeWidget(source: string, ask: string, prompt: string, saved: string, host: AgentHost): Promise<WidgetWrite> {
  let out = new WidgetWrite()
  let started = Date.now()
  if (host.askCode === null || host.language.length === 0) {
    out.failed = 'no model to write the widget with'
    return out
  }
  let system = languageWith(host.language, CARD_KINDS, widgetRefinementPrompt(false))
  let asked = 'The program:\n' + source + '\n\nIt was made for: ' + prompt + '\n\n' + WIDGET_ASK + ask
  let feedback = ''
  for (let attempt = 0; attempt < WIDGET_ATTEMPTS && out.source.length === 0; attempt++) {
    if (host.cancelled()) { out.failed = 'cancelled'; break }
    let think = attempt === WIDGET_ATTEMPTS - 1
    out.attempts = attempt + 1
    host.status(attempt === 0 ? 'Writing the widget...' : 'Fixing the widget...')
    let reply = await host.askCode!(system, asked + feedback, WIDGET_TOKENS, think)
    if (reply === null || reply.trim().length === 0) { out.failed = 'no answer for the widget'; continue }
    // An import line closed with a semicolon, as in TypeScript, is the one slip that stops a widget's answer from parsing.
    out.written = sourceIn(reply).replace(/^(\s*import\s[^\n;]*);[ \t]*$/gm, '$1')
    let program = spliceWidget(source, out.written)
    let unparsed = program === out.written ? parseErrorOf(out.written) : ''
    let problem = program !== out.written ? checkWidgetProgram(source, program, saved) :
      (unparsed.length > 0 ? 'The answer does not parse: ' + unparsed : 'The answer has no function widget.')
    if (problem.length > 0) {
      out.failed = problem.split('\n')[0]
      feedback = '\n\nYour previous answer:\n' + out.written + '\n\nIt does not work: ' + widgetRepairNote(problem) +
        '\nWrite the widget again.'
      continue
    }
    out.source = program
    out.vbc2 = compileVeraSource(program).vbc2
    out.failed = ''
  }
  out.ms = Date.now() - started
  return out
}
