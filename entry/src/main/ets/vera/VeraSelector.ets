// Shared transport boundary for generation and structural edits.
import { http } from '@kit.NetworkKit'
import { OperationCancellation, throwIfCancelled } from './OperationCancellation'
import { requestWithCancellation } from './VeraWebSearch'
import { noteService, httpFailure } from './ServiceHealth'
import { settings } from './SettingsStore'
import { askJevViaCloud } from './JevProxy'
import { localJev } from './LocalJev'
import { trace } from './VeraTiming'
import { SelectorCall, beginSelectorCall, finishSelectorCall, selectorUsage, selectorLabel } from './SelectorMetrics'

const JEV_ENDPOINT: string = 'https://api.typesafe.ai/v1/systemone'

export async function askSelector(body: string, apiKey: string, cancellation?: OperationCancellation): Promise<string> {
  throwIfCancelled(cancellation)
  let backend = settings.useLocalSelector() ? 'local-experimental' : (settings.useJevProxy() ? 'llm' : 'typesafe')
  let call = beginSelectorCall(backend, backend === 'llm' ? settings.getModel() :
    (backend === 'typesafe' ? 'jev-latest' : localJev.identity()), body, cancellation)
  let started = Date.now()
  try {
    let reply = await sendSelector(body, apiKey, call, cancellation)
    throwIfCancelled(cancellation)
    finishSelectorCall(call, reply)
    return reply
  } catch (e) {
    call.cancelled = cancellation !== undefined && cancellation.isCancelled()
    if (call.requests > 0) { call.partial = true }
    call.error = call.cancelled ? 'cancelled' : (e as Error).message
    throw (e as Error)
  } finally {
    call.ms = Math.max(0, Date.now() - started)
    call.finished = true
    if (!call.cancelled) { noteService(selectorLabel(backend), call.ok, call.error) }
  }
}

async function sendSelector(body: string, apiKey: string, call: SelectorCall,
    cancellation?: OperationCancellation): Promise<string> {
  if (call.backend === 'local-experimental') {
    let started = Date.now()
    let reply = await localJev.ask(body, cancellation)
    throwIfCancelled(cancellation)
    let fields: Record<string, Object> = {}
    fields['backend'] = 'local-experimental'
    fields['body'] = body
    fields['response'] = reply
    fields['source'] = localJev.identity()
    fields['ms'] = Date.now() - started
    trace('selector', fields)
    return reply
  }
  if (call.backend === 'llm') { return askJevViaCloud(body, cancellation, call) }
  if (apiKey.length === 0) { return '' }
  try {
    let headers: Record<string, string> = {}
    headers['Content-Type'] = 'application/json'
    headers['Authorization'] = 'Bearer ' + apiKey
    call.requests++
    let response = await requestWithCancellation(JEV_ENDPOINT, {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: body,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 5000,
      readTimeout: 15000
    }, cancellation)
    selectorUsage(call, String(response.result), response.responseCode as number)
    throwIfCancelled(cancellation)
    if ((response.responseCode as number) !== 200) {
      console.warn('VERA-JEV http ' + (response.responseCode as number).toString() + ' bytes=' + body.length.toString() + ' ' +
        String(response.result).substring(0, 300))
      call.error = httpFailure(response.responseCode as number, String(response.result))
      return ''
    }
    return response.result as string
  } catch (e) {
    throwIfCancelled(cancellation)
    if ((e as Error).name === 'OperationCancelledError') { throw (e as Error) }
    console.warn('VERA-JEV failed bytes=' + body.length.toString() + ': ' + (e as Error).message)
    call.error = (e as Error).message
    call.partial = true
    return ''
  }
}
