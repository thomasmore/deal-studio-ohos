import { formBindingData } from '@kit.FormKit'
import { store } from './ProjectStore'
import { formBindings, refreshLedger } from './FormBindings'
import { LiveFrame, WidgetSession, SourceRequest } from './VeraLiveWidget'
import { veraStateStamp } from './VeraStateStamp'
import { sourceFetch } from './VeraSource'

export function liveFrame(projectId: string): LiveFrame {
  let fallback = new LiveFrame()
  fallback.projectId = projectId
  if (projectId.length === 0) { fallback.status = 'Tap to choose an app'; return fallback }
  let project = store.getProject(projectId)
  if (project === null) {
    fallback.title = 'App removed'
    fallback.projectId = ''
    return fallback
  }
  fallback.title = project.name
  fallback.icon = project.icon
  let version = store.getLatestVersion(projectId)
  if (version === null || version.vbc2.length === 0) { fallback.status = 'Open project'; return fallback }
  try {
    let saved = store.loadState(projectId, version.id, veraStateStamp(version.vbc2))
    let session = new WidgetSession(version.vbc2, version.id, saved)
    let frame = session.frame(projectId, project.name, project.icon)
    // A clock-dependent init must not generate a different state/token on the first tap.
    if (frame.live && saved.length === 0) {
      store.saveState(projectId, version.id, veraStateStamp(version.vbc2), session.encodedState())
    }
    return frame
  } catch (e) {
    fallback.status = (e as Error).message
    console.error('VERA-FORM render: ' + fallback.status)
    return fallback
  }
}

/**
 * The program's live source call, if it asked for one, answered -- on the state saved by the time the answer arrives. The fetch
 * takes up to several seconds, and the app may save its state meanwhile (a tap in the app): then the app's state is kept and
 * the answer is handed to it, instead of the card's copy, loaded before the fetch, overwriting it. One call at most: the card's
 * update has about ten seconds, and a single GET (VeraSource.ets) fits in it.
 */
async function answerSource(session: WidgetSession, requests: SourceRequest[], loaded: string, projectId: string,
    versionId: string, vbc2: string, fetchSource: (params: Map<string, string>) => Promise<string>): Promise<WidgetSession> {
  if (requests.length === 0) { return session }
  let text = await fetchSource(requests[0].params)
  let now = store.loadState(projectId, versionId, veraStateStamp(vbc2))
  let target = now === loaded ? session : new WidgetSession(vbc2, versionId, now)
  target.answer(requests[0].handler, text)
  return target
}

export function liveBinding(projectId: string, formId: string = ''): formBindingData.FormBindingData {
  let frame = liveFrame(projectId)
  frame.formId = formId
  return formBindingData.createFormBindingData(frame)
}

/**
 * Render, validate event, dispatch, re-render, THEN commit. Failed/effectful taps never save. The one call a tap may make is the
 * program's live source (Vera.Source.fetch), made here before anything is drawn.
 */
export async function liveFormTap(formId: string, message: string,
    fetchSource: (params: Map<string, string>) => Promise<string> = sourceFetch): Promise<formBindingData.FormBindingData> {
  let start = Date.now()
  let projectId = formBindings.projectFor(formId)
  let project = store.getProject(projectId)
  let version = store.getLatestVersion(projectId)
  if (project === null || version === null || version.vbc2.length === 0) { return liveBinding(projectId) }
  let saved = store.loadState(projectId, version.id, veraStateStamp(version.vbc2))
  try {
    let params = JSON.parse(message) as Record<string, Object>
    if (typeof params['token'] !== 'string' || typeof params['handler'] !== 'string' || typeof params['value'] !== 'number') {
      throw new Error('Invalid widget event')
    }
    console.info('VERA-FORM event action=' + String(params['handler']) + ' value=' + String(params['value']))
    let session = new WidgetSession(version.vbc2, version.id, saved)
    let requests = session.tap(session.frame(projectId, project.name, project.icon), params['token'] as string,
      params['handler'] as string, params['value'] as number)
    // A Refresh button: its live source is fetched and the answer handled before the card is drawn and saved.
    session = await answerSource(session, requests, saved, projectId, version.id, version.vbc2, fetchSource)
    let frame = session.frame(projectId, project.name, project.icon)
    frame.formId = formId
    store.saveState(projectId, version.id, veraStateStamp(version.vbc2), session.encodedState())
    console.info('VERA-FORM tap ms=' + (Date.now() - start).toString() + ' bytes=' + JSON.stringify(frame).length.toString())
    return formBindingData.createFormBindingData(frame)
  } catch (e) {
    let frame = liveFrame(projectId)
    frame.formId = formId
    frame.status = (e as Error).message
    console.warn('VERA-FORM tap rejected: ' + frame.status)
    return formBindingData.createFormBindingData(frame)
  }
}

/**
 * How often a project's widgetRefresh may run: under the live card's update period (form_config.json, updateDuration 1 =
 * 30 minutes), so a period's update is never skipped for arriving a little early, and over a burst of cards updated together.
 */
export const REFRESH_EVERY_MS: number = 20 * 60 * 1000

export class LiveRefresh {
  binding: formBindingData.FormBindingData
  /** widgetRefresh ran and its state was saved: the project's other cards are to be redrawn. */
  ran: boolean = false
  constructor(binding: formBindingData.FormBindingData) { this.binding = binding }
}

/**
 * The card's periodic update. A program with widgetRefresh has it bring the state up to date with the clock, as a tap runs a
 * handler: render the result, THEN commit; an effect or a failure leaves the state as it was. The one call it may make, its
 * live source (Vera.Source.fetch), is made here and its answer handled first, so the card shows the figures fetched now. Once per project per
 * REFRESH_EVERY_MS, however many cards show it. A program without one is redrawn over its saved state.
 */
export async function liveFormRefresh(formId: string, now: number = Date.now(),
    fetchSource: (params: Map<string, string>) => Promise<string> = sourceFetch): Promise<LiveRefresh> {
  let projectId = formBindings.projectFor(formId)
  let project = store.getProject(projectId)
  let version = store.getLatestVersion(projectId)
  if (project === null || version === null || version.vbc2.length === 0 || now - refreshLedger.lastRun(projectId) < REFRESH_EVERY_MS) {
    return new LiveRefresh(liveBinding(projectId, formId))
  }
  let stamp = veraStateStamp(version.vbc2)
  try {
    let loaded = store.loadState(projectId, version.id, stamp)
    let session = new WidgetSession(version.vbc2, version.id, loaded)
    if (!session.refreshes()) { return new LiveRefresh(liveBinding(projectId, formId)) }
    // Marked before the fetch: the other cards of a burst updated together see it and do not fetch too.
    refreshLedger.markRun(projectId, now)
    // A live source widgetRefresh asked for is fetched here, and its answer handled, before anything is drawn or saved.
    session = await answerSource(session, session.refresh(), loaded, projectId, version.id, version.vbc2, fetchSource)
    let frame = session.frame(projectId, project.name, project.icon)
    frame.formId = formId
    store.saveState(projectId, version.id, stamp, session.encodedState())
    console.info('VERA-FORM refresh project=' + projectId)
    let result = new LiveRefresh(formBindingData.createFormBindingData(frame))
    result.ran = true
    return result
  } catch (e) {
    // Not tried again until the next period: a refresh that fails fails the same way every time.
    refreshLedger.markRun(projectId, now)
    console.warn('VERA-FORM refresh rejected: ' + (e as Error).message)
    return new LiveRefresh(liveBinding(projectId, formId))
  }
}
