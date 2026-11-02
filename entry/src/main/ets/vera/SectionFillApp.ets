import { BlockCalls } from './SectionFill'
import { deepseek, discoveryToolResult } from './DeepSeekEngine'
import { webSearch } from './VeraWebSearch'
import { OperationCancellation, PredicateCancellation, throwIfCancelled } from './OperationCancellation'

export function appBlockCalls(canSearch: boolean, status: (text: string) => void = (_text: string): void => {},
    cancelled: () => boolean = (): boolean => false, cancellation?: OperationCancellation): BlockCalls {
  let calls = new BlockCalls()
  calls.cancelled = (): boolean => cancelled() || (cancellation !== undefined && cancellation.isCancelled())
  let polling: OperationCancellation = new PredicateCancellation(calls.cancelled, cancellation)
  let operation = cancellation !== undefined ? cancellation : polling
  calls.cancellation = operation
  let check = (): void => { throwIfCancelled(polling) }
  if (canSearch) {
    calls.search = async (query: string, chars: number): Promise<string> => {
      check()
      try {
        return await webSearch(query, chars, operation)
      } finally {
        check()
      }
    }
  }
  calls.content = async (system: string, user: string, budget: number): Promise<string | null> => {
    check()
    try {
      return await deepseek.extractTemplateContent(system, user, budget, 'Text for the blocks', false, operation)
    } finally {
      check()
    }
  }
  calls.hole = async (system: string, user: string): Promise<string | null> => {
    check()
    try {
      return await deepseek.extractTemplateContent(system, user, 500, 'Function bodies for the blocks', false, operation)
    } finally {
      check()
    }
  }
  calls.sdkContext = async (prompt: string): Promise<string> => {
    check()
    try {
      let reply = await discoveryToolResult('find_sdk_function', prompt.substring(0, 300), 0, false, operation)
      return reply.substring(0, 2500)
    } finally {
      check()
    }
  }
  calls.status = (text: string): void => { if (!calls.cancelled()) { status(text) } }
  return calls
}
