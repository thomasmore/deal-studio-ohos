import { deepseek } from './DeepSeekEngine'
import { webSearch, SEARCH_CHARS } from './VeraWebSearch'
import { httpGetText, SourceResponse } from './VeraSource'
import { SourceCalls } from './VeraSourceFind'
import { OperationCancellation } from './OperationCancellation'

/** The finder's calls on the phone: the search, DeepSeek with thinking off, and the GET the program will make. */
export function appSourceCalls(cancellation?: OperationCancellation): SourceCalls {
  let calls = new SourceCalls()
  calls.search = (query: string): Promise<string> => webSearch(query, SEARCH_CHARS, cancellation)
  calls.askJson = (system: string, user: string): Promise<string | null> => deepseek.extractSourceJson(system, user, cancellation)
  calls.get = (url: string): Promise<SourceResponse> => httpGetText(url)
  return calls
}
