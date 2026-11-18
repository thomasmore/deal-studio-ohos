/**
 * What the agent needs from whoever runs it: the two model calls, and where its progress goes. The Generate
 * screen and the chat each make one (appAgentHost in AgentAppHost.ets); the host harness makes its own with
 * fetch, so the agent itself imports no UI and no network client and runs under node unchanged.
 */

import { OperationCancellation, PredicateCancellation, throwIfCancelled, cancellationError } from '../OperationCancellation'
import { SketchAsk, JevAsk } from '../VeraCompose'
import { blockDefaults } from '../VeraTemplateContent'
import { BlockRequest, BlockFill } from '../SectionFill'
import { CodeAsk } from './AgentCustom'
import { AgentQuestion, PersonAnswer } from './AgentQuestions'

/** The catalogue's defaults for every section: what a host with no model to ask gives. */
export async function defaultBlockFill(request: BlockRequest): Promise<BlockFill> {
  let fill = new BlockFill()
  for (let kind of request.kinds) { fill.values.push(blockDefaults(kind)) }
  fill.note = 'content=default'
  return fill
}

/**
 * What one hole was and how it ended, for the record (AgentHost.onHole): holes that recur across requests are what the
 * catalogue should grow -- a need written over and over is a block waiting to be made.
 */
export class HoleRecord {
  prompt: string = ''
  /** 'sketch' or 'layout': the plan the hole was in. */
  origin: string = ''
  /** The whole screen as the hole. */
  whole: boolean = false
  needs: string[] = []
  /** For each need: something the phone or another app does. */
  phone: boolean[] = []
  /** written: did every need; partial: served, missing some; reported: a notice in its place; known: refused by an earlier hole. */
  outcome: string = ''
  attempts: number = 0
  thought: boolean = false
  ms: number = 0
  missed: string[] = []
  /** The writer's sentence when it said it cannot, or why it failed. */
  why: string = ''
  /** The section as written: fields, functions and view. */
  code: string = ''
  /** The phone functions the writer was shown for the phone needs (the lookups' answers), '' for none. */
  lookup: string = ''
}

export class AgentHost {
  /** The plan: DeepSeek with no thinking, one JSON object. */
  askPlan: SketchAsk = async (_system: string, _user: string, _onText: (soFar: string) => void, _think: boolean): Promise<string | null> => null
  /** Jev's choices for a plan. */
  askJev: JevAsk = async (_body: string): Promise<string> => ''
  /** One line for the person: what the agent is doing now. */
  status: (text: string) => void = (_text: string): void => {}
  /** A compiled picture of the screen while it is being made. */
  preview: (vbc2: string) => void = (_vbc2: string): void => {}
  /** The content, real data and holes of the sections the plan asked for. */
  fillBlocks: (request: BlockRequest) => Promise<BlockFill> = defaultBlockFill
  /** The model that writes a custom section, null when there is none to ask: then a need nothing does refuses the screen. */
  askCode: CodeAsk | null = null
  /** Why the model stopped its last askCode reply: "length" at the token limit, "stop" when it ended it; "" when not known. */
  lastCodeFinish: string = ''
  /**
   * Make widget's checks of a program with its widget (AgentWidget.checkWidgetProgram): '' when it passes, else why not. Null runs
   * them where they are called; the app runs them off the UI thread (WidgetCheckTask), since they play the app's clock.
   */
  checkWidget: ((base: string, source: string, saved: string) => Promise<string>) | null = null
  /**
   * The phone's functions for something the phone or another app is to do: what find_intent_function and find_sdk_function
   * answer for the need, as text with each result's call; '' when nothing can be looked up (then nothing is called).
   */
  lookup: (need: string) => Promise<string> = async (_need: string): Promise<string> => ''
  /** The language as generation is shown it (the skill prompt with the UI catalogue), for the custom section. */
  language: string = ''
  /** How a full-canvas program is written (rawfile vera-surface-skill.txt), for a game; '' sends every request to the agent. */
  surfaceGuide: string = ''
  /** How a 3D program is written on a ui.World (rawfile vera-world-skill.txt); '' writes every game flat, on a surface. */
  worldGuide: string = ''
  /** Asks the person a blocking question: an answer's index, their own words, or null for the default (the default host never asks). */
  ask: (question: AgentQuestion) => Promise<PersonAnswer> = async (_question: AgentQuestion): Promise<PersonAnswer> => null
  /**
   * What this request's holes already learned, so a later, wider hole does not repeat it: each phone need a writer said
   * it cannot do, with its sentence for the person, and each lookup made.
   */
  cannot: Map<string, string> = new Map<string, string>()
  looked: Map<string, string> = new Map<string, string>()
  /** Every written hole and how it ended, for the record (the app's trace, the host runner's log). */
  onHole: (record: HoleRecord) => void = (_record: HoleRecord): void => {}
  /** True once the person has asked to stop. */
  cancelled: () => boolean = (): boolean => false
  cancellation?: OperationCancellation
}

export function agentCancellation(host: AgentHost): OperationCancellation {
  return new PredicateCancellation((): boolean => host.cancelled(), host.cancellation)
}

export function checkAgent(host: AgentHost): void {
  throwIfCancelled(host.cancellation)
  if (host.cancelled()) { throw cancellationError() }
}
