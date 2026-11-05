/**
 * An assembled program that does not compile or run is repaired by edits, not rebuilt: the model gets the program, the
 * diagnostics with the lines they point at, and answers with SEARCH/REPLACE blocks (VeraRepair.ets, the same form
 * generation repairs with), which are applied and checked again -- at most twice.
 */

import { CodeAsk } from './AgentCustom'
import { OperationCancellation, throwIfCancelled } from '../OperationCancellation'
import { AgentHost, checkAgent, agentCancellation } from './AgentHost'
import { repairPrompt, applyRepair } from '../VeraRepair'
import { compileVeraSource, CompileError } from '../VeraCompiler'
import { smokeRun } from '../VeraSmoke'

const ROUNDS: number = 2
/** Room for the edits: a few blocks of a few lines each. */
const EDIT_TOKENS: number = 2000

export class Repaired {
  /** The program that compiles and runs; '' when none did. */
  source: string = ''
  vbc2: string = ''
  /** Edit rounds asked for. */
  rounds: number = 0
  /** What still fails, '' when the repair worked. */
  failed: string = ''
  ms: number = 0
}

/** The program's diagnostics: '' when it compiles and runs once with every handler tapped. */
export function checkProgram(source: string): string {
  try {
    return smokeRun(compileVeraSource(source))
  } catch (e) {
    return e instanceof CompileError ? (e as CompileError).message : (e as Error).message
  }
}

export class Settled {
  /** The program as assembled, or as repaired when the repair worked. */
  source: string = ''
  /** Its bytecode; '' when it does not pass. */
  vbc2: string = ''
  /** What still fails, '' when the program passes. */
  errors: string = ''
  /** What repairing it did; null when it did not need it or there was no model to ask. */
  repair: Repaired | null = null
  /** Milliseconds the first check took. */
  checkMs: number = 0
  /** For the trace: how a repair went, '' when there was none. */
  note: string = ''
}

/**
 * An assembled program, checked -- compiled, then run once with every handler tapped -- and, if it fails, repaired by
 * edits. Every program the agent or the blocks serve passes through here, whoever assembled it.
 */
export async function settleProgram(source: string, prompt: string, host: AgentHost): Promise<Settled> {
  checkAgent(host)
  let out = new Settled()
  out.source = source
  let checkStart = Date.now()
  out.errors = checkProgram(source)
  out.checkMs = Date.now() - checkStart
  // What the assembly got wrong is repaired by edits to it, not by building it again.
  if (out.errors.length > 0 && host.askCode !== null && host.language.length > 0 && !host.cancelled()) {
    host.status('Repairing the program...')
    checkAgent(host)
    let repaired = await repairProgram(source, out.errors, prompt, host.language, host.askCode!, checkProgram, agentCancellation(host))
    checkAgent(host)
    out.repair = repaired
    if (repaired.source.length > 0) {
      out.source = repaired.source
      out.vbc2 = repaired.vbc2
      out.errors = ''
      out.note = '; repaired by edits in ' + repaired.rounds.toString() + ' round(s)'
    } else {
      out.note = '; repair: ' + repaired.failed
    }
  }
  checkAgent(host)
  if (out.errors.length === 0 && out.vbc2.length === 0) { out.vbc2 = compileVeraSource(out.source).vbc2 }
  return out
}

/** What decides whether a program passes: its diagnostics, '' when it does. */
export type ProgramCheck = (source: string) => string

/** `check` is what the program is held to after each round: by default compiling and running once (checkProgram). */
export async function repairProgram(source: string, errors: string, prompt: string, language: string,
    ask: CodeAsk, check: ProgramCheck = checkProgram, cancellation?: OperationCancellation): Promise<Repaired> {
  throwIfCancelled(cancellation)
  let out = new Repaired()
  let started = Date.now()
  let current = source
  let problem = errors
  for (let round = 0; round < ROUNDS && problem.length > 0; round++) {
    throwIfCancelled(cancellation)
    out.rounds = round + 1
    let reply = await ask(language, 'The program:\n' + current + '\n\n' + repairPrompt('Request: ' + prompt, problem, true, current),
      EDIT_TOKENS, false)
    throwIfCancelled(cancellation)
    if (reply === null) { problem = 'no answer for the repair'; break }
    let applied = applyRepair(current, reply)
    if (applied.source.length === 0) { problem = 'the edits did not apply: ' + applied.error; continue }
    current = applied.source
    problem = check(current)
  }
  throwIfCancelled(cancellation)
  out.ms = Date.now() - started
  if (problem.length > 0) {
    out.failed = problem.split('\n')[0]
    return out
  }
  out.source = current
  out.vbc2 = compileVeraSource(current).vbc2
  return out
}
