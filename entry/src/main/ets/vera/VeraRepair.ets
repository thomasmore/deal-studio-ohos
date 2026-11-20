/**
 * Compile repair by edit. A repair used to be a complete rewrite: shanghai-2 in
 * the benchmark spent 7.7k output tokens and 25 s to add the "()" of one
 * .length. The model now answers a repair with SEARCH/REPLACE blocks against
 * the failed source, which are applied here and compiled. When an edit does
 * not apply, the next attempt falls back to a complete rewrite.
 *
 * Shared by the Generate screen and the chat widget builder.
 */

import { extractVeraSource } from './DeepSeekEngine'

export const SEARCH_MARK: string = '<<<<<<< SEARCH'
export const SPLIT_MARK: string = '======='
export const REPLACE_MARK: string = '>>>>>>> REPLACE'

const EDIT_RULES: string =
  'Answer with edits only, not the whole program. Write one block per change:\n' +
  SEARCH_MARK + '\n' +
  'lines copied exactly from the failed program\n' +
  SPLIT_MARK + '\n' +
  'the lines that replace them\n' +
  REPLACE_MARK + '\n' +
  'Each SEARCH part must match exactly one place in the failed program: copy whole lines, with enough of them to be unique. ' +
  'Fix every diagnostic, and anything else that would fail the same way. Write nothing outside the blocks.'

const QUOTED_DIAGNOSTICS: number = 12

function isDigits(text: string): boolean {
  if (text.length === 0) { return false }
  for (let i = 0; i < text.length; i++) {
    if ('0123456789'.indexOf(text[i]) < 0) { return false }
  }
  return true
}

/**
 * Each "line:col CODE message" diagnostic followed by the source line it points
 * at, with the line before it, and a caret under the column. Line numbers alone
 * sent the model counting: shanghai-3 spent 66 s and 15k reasoning tokens
 * finding lines 475-507 of an 800-line program before writing four small edits.
 */
export function quoteDiagnostics(source: string, diagnostics: string): string {
  if (source.length === 0) { return diagnostics }
  let lines = source.split('\n')
  let out: string[] = []
  let quoted = 0
  for (let d of diagnostics.split('\n')) {
    out.push(d)
    let colon = d.indexOf(':')
    let space = d.indexOf(' ')
    if (quoted >= QUOTED_DIAGNOSTICS || colon < 0 || space < colon) { continue }
    let lineText = d.substring(0, colon)
    let colText = d.substring(colon + 1, space)
    if (!isDigits(lineText) || !isDigits(colText)) { continue }
    let line = parseInt(lineText, 10)
    let col = parseInt(colText, 10)
    if (line < 1 || line > lines.length) { continue }
    if (line > 1) { out.push('    ' + (line - 1).toString() + ' | ' + lines[line - 2]) }
    let gutter = '    ' + line.toString() + ' | '
    out.push(gutter + lines[line - 1])
    let pad = ''
    for (let i = 1; i < gutter.length + Math.max(col, 1); i++) { pad += ' ' }
    out.push(pad + '^')
    quoted++
  }
  return out.join('\n')
}

/**
 * The user prompt for a repair attempt: the request, the diagnostics with the
 * lines they point at in `failedSource`, and how to answer.
 */
export function repairPrompt(userPrompt: string, diagnostics: string, byEdit: boolean, failedSource: string = ''): string {
  let head = userPrompt + '\n\nThe program above is your previous attempt and it failed validation:\n' +
    quoteDiagnostics(failedSource, diagnostics) + '\n\n'
  if (byEdit) {
    return head + 'Repair the failed source against these diagnostics. Preserve requested behavior and compatible state field names and types. ' + EDIT_RULES
  }
  return head + 'Repair the failed source against these diagnostics. Preserve requested behavior and compatible state field names and types. ' +
    'Return the complete replacement program as source only, not a patch or continuation. ' +
    'If output was truncated, shorten optional content while preserving required behavior.'
}

export class RepairOutcome {
  /** The program to compile; empty when the edits could not be applied. */
  source: string = ''
  /** How many SEARCH/REPLACE blocks were applied; 0 for a reply that was a whole program. */
  edits: number = 0
  /** Why the edits could not be applied, for the next attempt and the trace. */
  error: string = ''
}

class EditBlock {
  search: string = ''
  replace: string = ''
}

function parseBlocks(reply: string): EditBlock[] | null {
  let lines = reply.split('\n')
  let blocks: EditBlock[] = []
  let i = 0
  while (i < lines.length) {
    if (lines[i].trim() !== SEARCH_MARK) { i++; continue }
    let search: string[] = []
    let replace: string[] = []
    i++
    while (i < lines.length && lines[i].trim() !== SPLIT_MARK) { search.push(lines[i]); i++ }
    if (i >= lines.length) { return null }
    i++
    while (i < lines.length && lines[i].trim() !== REPLACE_MARK) { replace.push(lines[i]); i++ }
    if (i >= lines.length) { return null }
    i++
    let block = new EditBlock()
    block.search = search.join('\n')
    block.replace = replace.join('\n')
    blocks.push(block)
  }
  return blocks
}

/**
 * Where `search` sits in `source`, comparing line by line with surrounding
 * whitespace ignored: the model often re-indents what it copies. -1 when it is
 * nowhere, -2 when it is in more than one place.
 */
function findLines(sourceLines: string[], searchLines: string[]): number {
  let found = -1
  for (let start = 0; start + searchLines.length <= sourceLines.length; start++) {
    let same = true
    for (let k = 0; k < searchLines.length; k++) {
      if (sourceLines[start + k].trim() !== searchLines[k].trim()) { same = false; break }
    }
    if (same) {
      if (found >= 0) { return -2 }
      found = start
    }
  }
  return found
}

function applyBlock(source: string, block: EditBlock): string | null {
  let at = source.indexOf(block.search)
  if (at >= 0 && source.indexOf(block.search, at + 1) < 0) {
    return source.substring(0, at) + block.replace + source.substring(at + block.search.length)
  }
  let sourceLines = source.split('\n')
  let searchLines = block.search.split('\n')
  while (searchLines.length > 0 && searchLines[searchLines.length - 1].trim().length === 0) { searchLines.pop() }
  while (searchLines.length > 0 && searchLines[0].trim().length === 0) { searchLines.shift() }
  if (searchLines.length === 0) { return null }
  let start = findLines(sourceLines, searchLines)
  if (start < 0) { return null }
  let out: string[] = sourceLines.slice(0, start)
  for (let line of block.replace.split('\n')) { out.push(line) }
  for (let line of sourceLines.slice(start + searchLines.length)) { out.push(line) }
  return out.join('\n')
}

/**
 * Applies a repair reply to the source it was written against. A reply with no
 * blocks is taken as a complete program: the model may still rewrite, and that
 * is no worse than before.
 */
export function applyRepair(failedSource: string, reply: string): RepairOutcome {
  let outcome = new RepairOutcome()
  let blocks = parseBlocks(reply)
  if (blocks === null) {
    outcome.error = 'An edit block was not closed (each needs ' + SPLIT_MARK + ' and ' + REPLACE_MARK + ').'
    return outcome
  }
  if (blocks.length === 0) {
    outcome.source = extractVeraSource(reply)
    return outcome
  }
  let source = failedSource
  for (let n = 0; n < blocks.length; n++) {
    let next = applyBlock(source, blocks[n])
    if (next === null) {
      let first = blocks[n].search.trim().split('\n')[0]
      outcome.error = 'Edit ' + (n + 1).toString() + ' of ' + blocks.length.toString() +
        ' could not be applied: its SEARCH text is not in the program exactly once (it starts "' + first + '").'
      return outcome
    }
    source = next
  }
  outcome.source = source.trim()
  outcome.edits = blocks.length
  return outcome
}
