/**
 * The route for a game, a toy, a simulation or a drawing: a request that is something moving on its own or touched
 * anywhere, which the agent's plan of needs (figures, lists, countdowns, phone actions) has no word for. Such a request is
 * written whole by the model on one ui.Surface, from a short design the plan model writes first, and served only after it
 * compiles, runs once (VeraSmoke.ets) and plays (VeraSurfacePlay.ets): a tap, a few seconds of frames, fingers dragging.
 *
 * Asked only when the request's words could mean such an app (looksLikeSurface), so a to-do list never pays for the
 * question; the plan model then decides, and a "no" goes on to the agent as before.
 */

import { AgentHost, checkAgent, agentCancellation } from './AgentHost'
import { repairProgram } from './AgentRepair'
import { compileVeraSource, CompileError } from '../VeraCompiler'
import { smokeRun } from '../VeraSmoke'
import { playSurface } from '../VeraSurfacePlay'
import { describeCatalogForPrompt } from '../VeraUiCatalog'

/** Room for a whole game: its records, its frame, its fingers and its drawing. */
export const SURFACE_TOKENS: number = 14000

/**
 * Words that may mean a game, a toy, a simulation or a drawing. Only a gate for asking: the plan model decides, and a word
 * here that means something else ("a drawing of my week") costs one short question.
 */
const SURFACE_WORDS: RegExp = new RegExp('\\b(game|games|play|playable|arcade|shoot\\w*|shooter|tank|tanks|snake|pong|brick\\w*|' +
  'breakout|arkanoid|asteroid\\w*|invader\\w*|flappy|racing|racer|race|platformer|jump\\w*|maze|pinball|bounc\\w*|ball|balls|' +
  'physics|particle\\w*|simulat\\w*|draw|drawing|paint\\w*|sketch\\w*|doodle|canvas|animat\\w*|aquarium|fireworks?|orbit\\w*|' +
  'planet\\w*|galaxy|starfield|joystick|dodge|catch|falling|neon|spaceship|ship|missile\\w*|zombie\\w*|enemy|enemies|' +
  'level|levels|score|arena|battle|fight\\w*|racket|paddle|tetris|puzzle|screensaver|kaleidoscope|spirograph|pendulum|' +
  'gravity|swarm|boids|life|roulette|casino|wheel|spin\\w*|dice|die|coin|lottery|slots?|plinko|marbles?|pendulum|' +
  'signature|sign)\\b', 'i')

/**
 * The same, for requests written in Chinese, which people type although the Generate screen asks for English: the
 * project list on the phone this was built on has 坦克大战 among its games. Characters, not words, so no boundaries.
 */
const SURFACE_WORDS_ZH: RegExp = new RegExp('游戏|小游戏|坦克|打砖块|弹球|贪吃蛇|射击|飞机大战|赛车|跑酷|俄罗斯方块|消除|闯关|关卡|' +
  '画板|画画|涂鸦|绘画|动画|模拟|物理|粒子|烟花|弹跳|重力|躲避|接住|掉落|霓虹|红白机|街机|太空|外星|僵尸|敌人|对战|大战|球|' +
  '轮盘|转盘|骰子|抽奖|赌场|老虎机|签名|单摆')

export function looksLikeSurface(prompt: string): boolean {
  return SURFACE_WORDS.test(prompt) || SURFACE_WORDS_ZH.test(prompt)
}

/** On by default; `--ps veraSurface 0` sends every request to the agent, for comparison. */
let surfaceRoute: boolean = true
export function setSurfaceRouteEnabled(on: boolean): void { surfaceRoute = on }
export function surfaceRouteEnabled(): boolean { return surfaceRoute }

export const SURFACE_CLASSIFY_PROMPT: string = [
  'You decide how an app request on a phone is built, and if it is a game or something like one, you design it.',
  'Answer with one JSON object: {"surface": "whole" | "part" | "none", "title": "...", "design": "...", "scene": "..."}.',
  '',
  'surface is "whole" when the heart of the request is something that moves continuously or is touched anywhere on a',
  'drawing, and the whole screen is that: a real-time game (arcade, action, shooter, racing, a ball and a paddle, falling',
  'things, a tank battle, a snake), a physics or particle toy, a simulation, an animated scene, a drawing or painting pad.',
  'surface is "part" when the request is a screen of ordinary controls -- forms, choices, amounts, lists, results -- with',
  'one drawn picture among them that moves or is touched: a roulette or prize wheel that spins beside the bets and the',
  'bank, dice that tumble above a score sheet, a signature area on a delivery form, a pendulum whose length a slider sets.',
  'surface is "none" for everything built from controls and text alone: trackers, lists, timers, calculators, forms,',
  'quizzes, flashcards, charts of figures, and turn-based games played by tapping buttons or cells (tic-tac-toe, hangman,',
  'memory), and dice, coins or cards that only show a result.',
  '"part" needs the request itself to ask for the picture: an animation, a wheel or ball that moves, something drawn or',
  'signed with a finger. A request that only names a thing that could be animated (a coin flip, a dice roll, a timer) is',
  '"none", however well an animation would suit it.',
  '',
  'When surface is "whole", title is a short name of your own for the app, and design is a short original game design in',
  'plain sentences, at most 12 lines: the goal; what the player controls and exactly how on a touch screen (drag, tap,',
  'a stick on the left half and fire on the right half); the objects and how each moves and behaves; collisions and what',
  'they do; score, lives, levels and how the game gets harder; how a round starts and ends; the look, with 4 to 6 hex',
  'colours; portrait (360 by 640) unless landscape clearly suits it better. A named game means its genre and mechanics:',
  'describe your own take, never its levels, characters, names or artwork.',
  'When surface is "part", scene is one or two plain sentences: what the picture shows, what moves or is touched, what',
  'sets it moving, and what it decides or changes on the screen. title and design are "".',
  'When surface is "none", title, design and scene are "".',
].join('\n')

/** The three answers: the whole screen is drawn, one part of it is, or none of it. */
export const SURFACE_WHOLE: string = 'whole'
export const SURFACE_PART: string = 'part'
export const SURFACE_NONE: string = 'none'

export class SurfaceBrief {
  /** SURFACE_WHOLE, SURFACE_PART or SURFACE_NONE. */
  kind: string = SURFACE_NONE
  title: string = ''
  design: string = ''
  /** For SURFACE_PART: the scene, in words, for the agent's plan. */
  scene: string = ''
}

/** The plan model's answer, or null when it is not one. A bare true or false is read as whole or none. */
export function parseSurfaceBrief(text: string): SurfaceBrief | null {
  let start = text.indexOf('{')
  let end = text.lastIndexOf('}')
  if (start < 0 || end <= start) { return null }
  try {
    let raw = JSON.parse(text.substring(start, end + 1)) as Record<string, Object>
    let brief = new SurfaceBrief()
    let said = raw['surface']
    brief.kind = said === true || said === SURFACE_WHOLE ? SURFACE_WHOLE : (said === SURFACE_PART ? SURFACE_PART : SURFACE_NONE)
    brief.title = typeof raw['title'] === 'string' ? (raw['title'] as string).trim() : ''
    brief.design = typeof raw['design'] === 'string' ? (raw['design'] as string).trim() : ''
    brief.scene = typeof raw['scene'] === 'string' ? (raw['scene'] as string).trim() : ''
    if (brief.kind === SURFACE_WHOLE && brief.design.length === 0) { return null }
    if (brief.kind === SURFACE_PART && brief.scene.length === 0) { return null }
    return brief
  } catch (e) {
    return null
  }
}

/** The components a full-canvas program is shown: the surface, the frame around it, and a few controls for outside it. */
const SURFACE_COMPONENTS: string[] = ['AppTheme', 'Surface', 'Column', 'Row', 'Text', 'Header', 'Button', 'ActionBar']

/**
 * The language for writing a full-canvas program: the generation prompt with its catalogue replaced by the surface's
 * components and std/gfx, and its advice on composing screens of sections replaced by the surface guide and example.
 * `language` is the generation prompt as a host holds it, with the catalogue spliced in or not.
 */
export function surfaceLanguage(language: string, guide: string): string {
  let catalogue = describeCatalogForPrompt(new Set<string>(SURFACE_COMPONENTS))
  let start = language.indexOf('{{UI_CATALOG}}')
  if (start < 0) { start = language.indexOf('UI constructors (all return ui.View):') }
  let end = language.indexOf('Clock -- time.')
  if (start < 0 || end <= start) { return language + '\n\n' + catalogue + '\n\n' + guide }
  return language.substring(0, start) + catalogue + '\n\n' + guide + '\n\n' + language.substring(end)
}

/** The source in a reply: inside the first fenced block when there is one, else the reply itself. */
export function sourceIn(reply: string): string {
  let fence = reply.indexOf('```')
  if (fence < 0) { return reply.trim() }
  let open = reply.indexOf('\n', fence)
  let close = reply.indexOf('```', open + 1)
  if (open < 0) { return reply.trim() }
  return (close < 0 ? reply.substring(open + 1) : reply.substring(open + 1, close)).trim()
}

/** '' when the program compiles, runs once with every handler tapped, and plays; else what is wrong. */
export function checkSurfaceProgram(source: string): string {
  try {
    let compiled = compileVeraSource(source)
    let smoke = smokeRun(compiled)
    if (smoke.length > 0) { return smoke }
    return playSurface(compiled)
  } catch (e) {
    return e instanceof CompileError ? (e as CompileError).message : (e as Error).message
  }
}

export class SurfaceResult {
  /** The program served; '' when none passed. */
  source: string = ''
  vbc2: string = ''
  brief: SurfaceBrief | null = null
  /** Programs written (a second is written with thinking on when the first could not be repaired). */
  attempts: number = 0
  /** Repair rounds, over all attempts. */
  rounds: number = 0
  /** What still failed, '' when served. */
  failed: string = ''
  briefMs: number = 0
  writeMs: number = 0
  checkMs: number = 0
  /** For the trace. */
  note: string = ''
}

/**
 * Whether the request is drawn, wholly or in part, and its design or its scene when it is: null when the route does not
 * apply (switched off, no guide on this host, no word for it in the request, or the plan model did not answer), and a
 * brief of kind SURFACE_NONE when it said no.
 */
export async function briefSurface(prompt: string, host: AgentHost): Promise<SurfaceBrief | null> {
  checkAgent(host)
  if (!surfaceRoute || host.surfaceGuide.length === 0 || host.askCode === null || !looksLikeSurface(prompt)) { return null }
  host.status('Is this a game?')
  checkAgent(host)
  let reply = await host.askPlan(SURFACE_CLASSIFY_PROMPT, 'Request: ' + prompt, (_soFar: string): void => {}, false)
  checkAgent(host)
  if (reply === null) { return null }
  return parseSurfaceBrief(reply)
}

/**
 * The program for a request the brief says is a full-canvas app: written, checked, repaired by edits at most twice, and
 * written once more with thinking on when that did not hold.
 */
export async function writeSurfaceApp(prompt: string, brief: SurfaceBrief, host: AgentHost): Promise<SurfaceResult> {
  checkAgent(host)
  let out = new SurfaceResult()
  out.brief = brief
  let system = surfaceLanguage(host.language, host.surfaceGuide)
  let user = 'Request: ' + prompt + '\n\nDesign (' + brief.title + '):\n' + brief.design +
    '\n\nWrite the complete program for it on one ui.Surface. Output the source only.'
  for (let attempt = 0; attempt < 2 && out.source.length === 0; attempt++) {
    checkAgent(host)
    let think = attempt > 0
    host.status(think ? 'Writing the game again, thinking it through...' : 'Writing ' + (brief.title.length > 0 ? brief.title : 'the game') + '...')
    out.attempts = attempt + 1
    let writeStart = Date.now()
    checkAgent(host)
    let reply = await host.askCode!(system, user, SURFACE_TOKENS, think)
    checkAgent(host)
    out.writeMs += Date.now() - writeStart
    if (reply === null || reply.trim().length === 0) { out.failed = 'no program came back'; continue }
    let source = sourceIn(reply)
    let checkStart = Date.now()
    let problem = checkSurfaceProgram(source)
    out.checkMs += Date.now() - checkStart
    if (problem.length > 0 && !host.cancelled()) {
      host.status('Playing it and fixing what broke...')
      checkAgent(host)
      let repaired = await repairProgram(source, problem, prompt, system, host.askCode!, checkSurfaceProgram, agentCancellation(host))
      checkAgent(host)
      out.rounds += repaired.rounds
      if (repaired.source.length > 0) {
        source = repaired.source
        problem = ''
      } else {
        problem = repaired.failed
      }
    }
    checkAgent(host)
    if (problem.length > 0) { out.failed = problem.split('\n')[0]; continue }
    out.source = source
    out.vbc2 = compileVeraSource(source).vbc2
    out.failed = ''
  }
  out.note = 'surface "' + brief.title + '": ' + (out.source.length > 0 ? 'written' : 'not built (' + out.failed + ')') +
    ' in ' + out.attempts.toString() + ' attempt(s), ' + out.rounds.toString() + ' repair round(s)'
  return out
}
