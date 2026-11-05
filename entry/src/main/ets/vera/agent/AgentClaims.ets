/**
 * What the composer leaves out of the plan because "a section of the catalogue does it" is a claim, and the section's own
 * options decide whether it does: a button for each item, a calendar, a style. The finished screen is read against each
 * claim, as a written section is read against its needs (AgentCustom.ets), and what it does not do is put back in the plan
 * to be written, or reported on the screen, rather than lost without a word.
 */

import { OperationCancellation, throwIfCancelled } from '../OperationCancellation'
import { CustomRequest, DOES_ABOVE, undone, verifyRequest } from './AgentCustom'
import { ScreenPlan } from '../ScreenPlan'

/** The claimed needs the program, as assembled, is not read as doing; [] when it does all, or Jev did not answer. */
export async function claimsUndone(claimed: string[], prompt: string, source: string,
    askJev: (body: string) => Promise<string>, cancellation?: OperationCancellation): Promise<string[]> {
  throwIfCancelled(cancellation)
  if (claimed.length === 0) { return [] }
  let request = new CustomRequest()
  request.needs = claimed
  request.prompt = prompt
  let reply = await askJev(verifyRequest(request, source))
  throwIfCancelled(cancellation)
  return undone(request, reply)
}

/** Puts the needs back in the plan as slots to write; the section hole that follows writes them, or reports them. */
export function putBack(plan: ScreenPlan, needs: string[]): void {
  for (let i = 0; i < needs.length; i++) { plan.addToWrite('claimed.' + i.toString(), needs[i]) }
}

/**
 * Of the needs, those the program, as assembled, is read as doing; [] when Jev did not answer or did not answer for a need, so
 * nothing is taken for done that was not said to be. A need the sections chosen for the screen already do in their own way (how
 * entries are labelled, what a chart is drawn from) is then not written again.
 */
export async function claimsDone(needs: string[], prompt: string, source: string,
    askJev: (body: string) => Promise<string>, cancellation?: OperationCancellation): Promise<string[]> {
  throwIfCancelled(cancellation)
  if (needs.length === 0) { return [] }
  let request = new CustomRequest()
  request.needs = needs
  request.prompt = prompt
  let answers: Record<string, Object> = {}
  try {
    let reply = await askJev(verifyRequest(request, source))
    throwIfCancelled(cancellation)
    if (reply.length === 0) { return [] }
    answers = (JSON.parse(reply) as Record<string, Object>)['answers'] as Record<string, Object>
  } catch (_e) {
    throwIfCancelled(cancellation)
    if ((_e as Error).name === 'OperationCancelledError') { throw (_e as Error) }
    return []
  }
  let out: string[] = []
  for (let i = 0; i < needs.length; i++) {
    let a = answers['does.' + i.toString()] as Record<string, Object>
    let p = a !== undefined && a !== null ? (a['probabilities'] as Record<string, Object>) : null
    if (p !== null && p !== undefined && typeof p['yes'] === 'number' && (p['yes'] as number) >= DOES_ABOVE) { out.push(needs[i]) }
  }
  return out
}
