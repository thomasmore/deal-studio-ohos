/**
 * A change to a program that draws on a ui.Surface -- a game written whole, or a screen with a scene among its sections.
 * The general refine has the model write the whole program again from a prompt that knows neither guide, and serves it
 * after one run: "make the paddle wider and every tenth brick drops a power-up" rewrote 470 lines into 571 in 72 s and was
 * never played. Here the model is shown the guide the program was written with (the game guide, or the scene guide),
 * answers with SEARCH/REPLACE edits, and the result is played as a new one is (VeraSurfacePlay.ets: fingers on the surface,
 * and for a scene each button pressed) and repaired by edits against that. A change that cannot be made so leaves the
 * program on the screen as it was. A 3D program (a ui.World) is changed the same way with the world guide, and played on the
 * host's physics (VeraWorldPlay.ets).
 */

import { AgentHost, checkAgent, agentCancellation } from './AgentHost'
import { repairProgram } from './AgentRepair'
import { checkSurfaceProgram, checkWorldProgram, surfaceLanguage, worldLanguage, WORLD_COMPONENTS } from './AgentSurface'
import { SCENE_GUIDE } from './AgentScene'
import { applyRepair } from '../VeraRepair'
import { compileVeraSource, CompileError } from '../VeraCompiler'
import { smokeRun } from '../VeraSmoke'
import { playSurface } from '../VeraSurfacePlay'

/** Room for the edits of a change: more than a repair's, since a change may add a record class and a few functions. */
export const CHANGE_TOKENS: number = 8000

/** A program this path edits: it draws on a ui.Surface, or shows a ui.World. */
export function drawsSurface(source: string): boolean {
  return source.indexOf('ui.Surface(') >= 0 || isWorld(source)
}

/** A 3D program: it shows a ui.World, changed with the world guide and played on the host's physics. */
export function isWorld(source: string): boolean {
  return source.indexOf('ui.World(') >= 0
}

/** A game written whole: its surface fills the screen. Anything else with a surface is a screen with a scene. */
export function isWholeGame(source: string): boolean {
  return source.indexOf('ui.Surface("fill"') >= 0
}

const CHANGE_RULES: string = 'Make the change asked for, and nothing else: keep every other behaviour, the look, and the ' +
  'names and types of the state fields that stay. Answer with edits, not the whole program. Write one block per change:\n' +
  '<<<<<<< SEARCH\n' +
  'lines copied exactly from the program\n' +
  '=======\n' +
  'the lines that replace them\n' +
  '>>>>>>> REPLACE\n' +
  'Each SEARCH part must match exactly one place in the program: copy whole lines, with enough of them to be unique. ' +
  'A new field of AppState is added to the class, to init() and to every object literal that builds an AppState. ' +
  'Write nothing outside the blocks. Only when most of the program has to change, answer with the whole program instead.'

/** For a scene: in a whole program the section's __PASSTHROUGH__ has been written out, so the guide is read with that. */
const SCENE_IN_PROGRAM: string = '\nThe scene below is already part of a whole program: where the guide says to return only ' +
  'the fields a handler changes with __PASSTHROUGH__, this program writes every field out; keep doing that. A setting the ' +
  'change adds that the scene settles from (a new kind of bet, a choice) is copied into the scene\'s own fields when the ' +
  'motion starts, beside the ones already copied there, and settled from that copy: the form may change while it moves.\n'

/** Whether every component the program builds is one of `kinds`. */
function usesOnly(source: string, kinds: string[]): boolean {
  let found = source.match(new RegExp('ui\\.([A-Z][A-Za-z]*)\\(', 'g'))
  if (found === null) { return true }
  for (let call of found) {
    if (kinds.indexOf(call.substring(3, call.length - 1)) < 0) { return false }
  }
  return true
}

/**
 * The language for changing a 3D program: the world route's (its few components and the guide) for one built of them,
 * else the whole catalogue with the guide after it, since a screen of lists with a world among them uses more.
 */
function worldEditLanguage(source: string, host: AgentHost): string {
  return usesOnly(source, WORLD_COMPONENTS) ? worldLanguage(host.language, host.worldGuide) : host.language + '\n\n' + host.worldGuide
}

/** '' when a screen with a scene compiles, runs once, and plays with its buttons pressed; else what is wrong. */
export function checkSceneProgram(source: string): string {
  try {
    let compiled = compileVeraSource(source)
    let smoke = smokeRun(compiled)
    if (smoke.length > 0) { return smoke }
    return playSurface(compiled, true, true)
  } catch (e) {
    return e instanceof CompileError ? (e as CompileError).message : (e as Error).message
  }
}

export class SurfaceEdit {
  /** The changed program, played; '' when none passed. */
  source: string = ''
  vbc2: string = ''
  /** True for a game written whole, false for a screen with a scene. */
  game: boolean = false
  /** True for a 3D program (a ui.World). */
  world: boolean = false
  /** Changes asked for: a second is asked with thinking on when the first could not be repaired. */
  attempts: number = 0
  /** Repair rounds, over all attempts. */
  rounds: number = 0
  /** The edit blocks the change that served was made of; 0 when the model answered with the whole program. */
  edits: number = 0
  /** What still failed, '' when served. */
  failed: string = ''
  ms: number = 0
}

/**
 * The program changed as `change` asks: `source` is the program on the screen, `prompt` what it was made for. Played
 * before it is returned; `failed` says why when no change passed.
 */
export async function editSurfaceProgram(source: string, change: string, prompt: string, host: AgentHost): Promise<SurfaceEdit> {
  checkAgent(host)
  let out = new SurfaceEdit()
  let started = Date.now()
  out.world = isWorld(source)
  out.game = out.world || isWholeGame(source)
  if (host.askCode === null || host.language.length === 0 || (out.world && host.worldGuide.length === 0) ||
      (out.game && !out.world && host.surfaceGuide.length === 0)) {
    out.failed = 'no model or guide to make the change with'
    return out
  }
  let system = out.world ? worldEditLanguage(source, host) :
    (out.game ? surfaceLanguage(host.language, host.surfaceGuide) : host.language + SCENE_GUIDE + SCENE_IN_PROGRAM)
  let check: (source: string) => string = out.world ? checkWorldProgram : (out.game ? checkSurfaceProgram : checkSceneProgram)
  let asked = 'The program:\n' + source + '\n\nIt was made for: ' + prompt + '\n\nThe change asked for now: ' + change +
    '\n\n' + CHANGE_RULES
  for (let attempt = 0; attempt < 2 && out.source.length === 0; attempt++) {
    checkAgent(host)
    let think = attempt > 0
    out.attempts = attempt + 1
    host.status(think ? 'Making the change again, thinking it through...' : 'Making the change...')
    checkAgent(host)
    let reply = await host.askCode!(system, asked, CHANGE_TOKENS, think)
    checkAgent(host)
    if (reply === null || reply.trim().length === 0) { out.failed = 'no answer for the change'; continue }
    let applied = applyRepair(source, reply)
    if (applied.source.length === 0) { out.failed = 'the edits did not apply: ' + applied.error; continue }
    let current = applied.source
    let problem = check(current)
    if (problem.length > 0 && !host.cancelled()) {
      host.status('Playing it and fixing what broke...')
      checkAgent(host)
      let repaired = await repairProgram(current, problem, prompt + '\n\nThe change: ' + change, system, host.askCode!, check, agentCancellation(host))
      checkAgent(host)
      out.rounds += repaired.rounds
      if (repaired.source.length > 0) {
        current = repaired.source
        problem = ''
      } else {
        problem = repaired.failed
      }
    }
    checkAgent(host)
    if (problem.length > 0) { out.failed = problem.split('\n')[0]; continue }
    out.source = current
    out.vbc2 = compileVeraSource(current).vbc2
    out.edits = applied.edits
    out.failed = ''
  }
  out.ms = Date.now() - started
  return out
}
