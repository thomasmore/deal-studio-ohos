import { Instruction, BytecodeFunction, BytecodeModule } from './VeraInterpreter'
import { CATALOG, ComponentSpec, ChildRule, payloadKindFor, childRuleFor, listWords } from './VeraUiCatalog'
import { iconPath, iconNames } from './VeraIcons'
import { isValidSdkTarget } from './VeraSdkIndex'
import { GFX_FUNCTIONS, GFX_POINTER_FIELDS, GFX_ROLES, GFX_BLEND_MODES, DRIFT_DIRECTIONS, DRIFT_SPEEDS, isGfxColor, gfxFunction } from './VeraGfx'
import { MOTION_PRESETS } from './VeraMotion'

// ===== AST Nodes =====

class Position {
  offset: number
  line: number
  column: number
  constructor(offset: number, line: number, column: number) {
    this.offset = offset; this.line = line; this.column = column
  }
}

class Span {
  start: Position
  end: Position
  sourceName: string
  constructor(start: Position, end: Position, sourceName: string) {
    this.start = start; this.end = end; this.sourceName = sourceName
  }
}

abstract class Node {
  span: Span
  constructor(span: Span) { this.span = span }
}

class TypeNode extends Node {
  name: string
  parts: TypeNode[]
  nullable: boolean
  constructor(span: Span, name: string, parts: TypeNode[] = [], nullable: boolean = false) {
    super(span); this.name = name; this.parts = parts; this.nullable = nullable
  }
}

class Parameter extends Node {
  name: string
  type: TypeNode
  constructor(span: Span, name: string, type: TypeNode) {
    super(span); this.name = name; this.type = type
  }
}

abstract class Declaration extends Node {}

class ImportDeclaration extends Node {
  name: string
  specifier: string
  constructor(span: Span, name: string, specifier: string) {
    super(span); this.name = name; this.specifier = specifier
  }
}

class FunctionDeclaration extends Declaration {
  name: string
  parameters: Parameter[]
  returnType: TypeNode
  body: BlockStatement
  isAsync: boolean
  constructor(span: Span, name: string, parameters: Parameter[], returnType: TypeNode, body: BlockStatement, isAsync: boolean) {
    super(span); this.name = name; this.parameters = parameters; this.returnType = returnType; this.body = body; this.isAsync = isAsync
  }
}

class FieldDeclaration extends Node {
  name: string
  type: TypeNode
  constructor(span: Span, name: string, type: TypeNode) {
    super(span); this.name = name; this.type = type
  }
}

class ClassDeclaration extends Declaration {
  name: string
  fields: FieldDeclaration[]
  annotation: string | null
  constructor(span: Span, name: string, fields: FieldDeclaration[], annotation: string | null) {
    super(span); this.name = name; this.fields = fields; this.annotation = annotation
  }
}

class Application extends Node {
  imports: ImportDeclaration[]
  declarations: Declaration[]
  constructor(span: Span, imports: ImportDeclaration[], declarations: Declaration[]) {
    super(span); this.imports = imports; this.declarations = declarations
  }
}

abstract class Statement extends Node {}

class BlockStatement extends Statement {
  statements: Statement[]
  constructor(span: Span, statements: Statement[]) {
    super(span); this.statements = statements
  }
}

class LetStatement extends Statement {
  name: string
  type: TypeNode
  initializer: Expression
  constructor(span: Span, name: string, type: TypeNode, initializer: Expression) {
    super(span); this.name = name; this.type = type; this.initializer = initializer
  }
}

class IfStatement extends Statement {
  condition: Expression
  thenBranch: BlockStatement
  elseBranch: Statement | null
  constructor(span: Span, condition: Expression, thenBranch: BlockStatement, elseBranch: Statement | null) {
    super(span); this.condition = condition; this.thenBranch = thenBranch; this.elseBranch = elseBranch
  }
}

class WhileStatement extends Statement {
  condition: Expression
  body: BlockStatement
  constructor(span: Span, condition: Expression, body: BlockStatement) {
    super(span); this.condition = condition; this.body = body
  }
}

class ForOfStatement extends Statement {
  name: string
  type: TypeNode
  iterable: Expression
  body: BlockStatement
  constructor(span: Span, name: string, type: TypeNode, iterable: Expression, body: BlockStatement) {
    super(span); this.name = name; this.type = type; this.iterable = iterable; this.body = body
  }
}

class BreakStatement extends Statement {}
class ContinueStatement extends Statement {}

class ReturnStatement extends Statement {
  value: Expression | null
  constructor(span: Span, value: Expression | null) {
    super(span); this.value = value
  }
}

class AssignStatement extends Statement {
  target: Expression
  value: Expression
  constructor(span: Span, target: Expression, value: Expression) {
    super(span); this.target = target; this.value = value
  }
}

class ExpressionStatement extends Statement {
  expression: Expression
  constructor(span: Span, expression: Expression) {
    super(span); this.expression = expression
  }
}

class TryStatement extends Statement {
  tryBlock: BlockStatement
  catchName: string
  catchBlock: BlockStatement
  constructor(span: Span, tryBlock: BlockStatement, catchName: string, catchBlock: BlockStatement) {
    super(span); this.tryBlock = tryBlock; this.catchName = catchName; this.catchBlock = catchBlock
  }
}

abstract class Expression extends Node {}

class NameExpression extends Expression {
  name: string
  constructor(span: Span, name: string) { super(span); this.name = name }
}

class IntExpression extends Expression {
  value: number
  constructor(span: Span, value: number) { super(span); this.value = value }
}

class NumberExpression extends Expression {
  value: number
  constructor(span: Span, value: number) { super(span); this.value = value }
}

class StringExpression extends Expression {
  value: string
  constructor(span: Span, value: string) { super(span); this.value = value }
}

class BooleanExpression extends Expression {
  value: boolean
  constructor(span: Span, value: boolean) { super(span); this.value = value }
}

class NullExpression extends Expression {}

class UnaryExpression extends Expression {
  operator: string
  operand: Expression
  constructor(span: Span, operator: string, operand: Expression) {
    super(span); this.operator = operator; this.operand = operand
  }
}

class BinaryExpression extends Expression {
  left: Expression
  operator: string
  right: Expression
  constructor(span: Span, left: Expression, operator: string, right: Expression) {
    super(span); this.left = left; this.operator = operator; this.right = right
  }
}

class CallExpression extends Expression {
  callee: Expression
  argumentsList: Expression[]
  constructor(span: Span, callee: Expression, argumentsList: Expression[]) {
    super(span); this.callee = callee; this.argumentsList = argumentsList
  }
}

class IndexExpression extends Expression {
  target: Expression
  index: Expression
  constructor(span: Span, target: Expression, index: Expression) {
    super(span); this.target = target; this.index = index
  }
}

class SelectExpression extends Expression {
  target: Expression
  field: string
  constructor(span: Span, target: Expression, field: string) {
    super(span); this.target = target; this.field = field
  }
}

class ArrayExpression extends Expression {
  elements: Expression[]
  constructor(span: Span, elements: Expression[]) {
    super(span); this.elements = elements
  }
}

class Property extends Node {
  name: string
  value: Expression
  constructor(span: Span, name: string, value: Expression) {
    super(span); this.name = name; this.value = value
  }
}

class ObjectExpression extends Expression {
  properties: Property[]
  constructor(span: Span, properties: Property[]) {
    super(span); this.properties = properties
  }
}

class LambdaExpression extends Expression {
  parameters: Parameter[]
  returnType: TypeNode
  body: BlockStatement
  constructor(span: Span, parameters: Parameter[], returnType: TypeNode, body: BlockStatement) {
    super(span); this.parameters = parameters; this.returnType = returnType; this.body = body
  }
}

class AwaitExpression extends Expression {
  operand: Expression
  constructor(span: Span, operand: Expression) { super(span); this.operand = operand }
}

class EnsureNotNullExpression extends Expression {
  operand: Expression
  constructor(span: Span, operand: Expression) { super(span); this.operand = operand }
}

// ===== Type System =====

abstract class VeraType {
  abstract display(): string
}

class PrimitiveType extends VeraType {
  name: string
  constructor(name: string) { super(); this.name = name }
  display(): string { return this.name }
}

class VeraClassType extends VeraType {
  identity: string
  name: string
  fields: Map<string, VeraType> = new Map<string, VeraType>()
  constructor(identity: string, name: string) { super(); this.identity = identity; this.name = name }
  display(): string { return this.name }
}

class VeraArrayType extends VeraType {
  element: VeraType
  constructor(element: VeraType) { super(); this.element = element }
  display(): string { return this.element.display() + '[]' }
}

class NullableType extends VeraType {
  base: VeraType
  constructor(base: VeraType) { super(); this.base = base }
  display(): string { return '(' + this.base.display() + ' | null)' }
}

class VeraFunctionType extends VeraType {
  parameters: VeraType[]
  result: VeraType
  isAsync: boolean
  identity: string
  /** See ExternalFunction.required; equal to parameters.length for everything else. */
  required: number
  constructor(parameters: VeraType[], result: VeraType, isAsync: boolean, identity: string,
      required: number = -1) {
    super(); this.parameters = parameters; this.result = result; this.isAsync = isAsync; this.identity = identity
    this.required = required < 0 ? parameters.length : required
  }
  display(): string {
    let parts: string[] = []
    for (let i = 0; i < this.parameters.length; i++) { parts.push(this.parameters[i].display()) }
    return 'function (' + parts.join(', ') + '): ' + this.result.display()
  }
}

class NamespaceType extends VeraType {
  name: string
  members: Map<string, VeraType>
  constructor(name: string, members: Map<string, VeraType>) { super(); this.name = name; this.members = members }
  display(): string { return 'namespace ' + this.name }
}

class VeraNullType extends VeraType {
  display(): string { return 'null' }
}

const NUMBER = new PrimitiveType('number')
const BOOLEAN = new PrimitiveType('boolean')
const STRING = new PrimitiveType('string')
const VOID = new PrimitiveType('void')
const NULL_TYPE = new VeraNullType()

function identical(left: VeraType, right: VeraType): boolean {
  if (left === right) return true
  if (left instanceof VeraArrayType && right instanceof VeraArrayType) return identical(left.element, right.element)
  if (left instanceof NullableType && right instanceof NullableType) return identical(left.base, right.base)
  if (left instanceof VeraFunctionType && right instanceof VeraFunctionType) {
    if (left.isAsync !== right.isAsync) return false
    if (left.parameters.length !== right.parameters.length) return false
    for (let i = 0; i < left.parameters.length; i++) {
      if (!identical(left.parameters[i], right.parameters[i])) return false
    }
    return identical(left.result, right.result)
  }
  return false
}

function subtypeOf(source: VeraType, destination: VeraType): boolean {
  if (identical(source, destination)) return true
  if (destination instanceof NullableType && (subtypeOf(source, destination.base) || source instanceof VeraNullType)) return true
  if (source instanceof VeraFunctionType && destination instanceof VeraFunctionType) {
    if (source.isAsync !== destination.isAsync) return false
    if (source.parameters.length > destination.parameters.length) return false
    for (let i = 0; i < source.parameters.length; i++) {
      if (!subtypeOf(destination.parameters[i], source.parameters[i])) return false
    }
    return subtypeOf(source.result, destination.result)
  }
  return false
}

function assignable(source: VeraType, destination: VeraType): boolean {
  return subtypeOf(source, destination)
}

// ===== Lexer =====

export class Diagnostic {
  code: string
  message: string
  span: Span
  expected: string
  actual: string
  constructor(code: string, message: string, span: Span, expected: string = '', actual: string = '') {
    this.code = code; this.message = message; this.span = span; this.expected = expected; this.actual = actual
  }
}

export class CompileError extends Error {
  diagnostics: Diagnostic[]
  constructor(diagnostics: Diagnostic[]) {
    let msgs: string[] = []
    for (let d of diagnostics) {
      msgs.push(d.span.start.line + ':' + d.span.start.column + ' ' + d.code + ' ' + d.message)
    }
    super(msgs.join('\n'))
    this.diagnostics = diagnostics
  }
}

class Token {
  kind: string
  text: string
  span: Span
  constructor(kind: string, text: string, span: Span) {
    this.kind = kind; this.text = text; this.span = span
  }
}

const KEYWORDS: string[] = [
  'import', 'as', 'from', 'class', 'function', 'async', 'let', 'if', 'else',
  'while', 'for', 'of', 'break', 'continue', 'return', 'true', 'false', 'null',
  'try', 'catch', 'new'
]

function isAlpha(c: string): boolean {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c === '_'
}

function isDigit(c: string): boolean {
  return c >= '0' && c <= '9'
}

function isAlnum(c: string): boolean {
  return isAlpha(c) || isDigit(c)
}

class Lexer {
  private source: string
  private sourceName: string
  private pos: number = 0
  private line: number = 1
  private col: number = 1

  constructor(source: string, sourceName: string) {
    this.source = source; this.sourceName = sourceName
  }

  scan(): Token[] {
    let tokens: Token[] = []
    while (this.pos < this.source.length) {
      this.skipWhitespaceAndComments()
      if (this.pos >= this.source.length) break
      let start = this.makePos()
      let c = this.source[this.pos]
      if (isAlpha(c)) { tokens.push(this.scanIdentifier(start)); continue }
      if (isDigit(c)) { tokens.push(this.scanNumber(start)); continue }
      if (c === '"') { tokens.push(this.scanString(start)); continue }
      if (c === '@') { this.pos++; this.col++; tokens.push(this.scanIdentifier(start)); tokens[tokens.length - 1].kind = 'annotation'; continue }
      tokens.push(this.scanSymbol(start))
    }
    tokens.push(new Token('eof', '', this.makeSpan(this.makePos())))
    return tokens
  }

  private skipWhitespaceAndComments(): void {
    while (this.pos < this.source.length) {
      let c = this.source[this.pos]
      if (c === ' ' || c === '\t' || c === '\r') { this.pos++; this.col++; continue }
      if (c === '\n') { this.pos++; this.line++; this.col = 1; continue }
      if (c === '/' && this.pos + 1 < this.source.length && this.source[this.pos + 1] === '/') {
        while (this.pos < this.source.length && this.source[this.pos] !== '\n') { this.pos++; this.col++ }
        continue
      }
      break
    }
  }

  private scanIdentifier(start: Position): Token {
    let begin = this.pos
    while (this.pos < this.source.length && isAlnum(this.source[this.pos])) { this.pos++; this.col++ }
    let text = this.source.substring(begin, this.pos)
    let kind = 'name'
    if (text === 'true' || text === 'false') kind = 'boolean'
    else if (text === 'null') kind = 'null'
    else {
      for (let kw of KEYWORDS) { if (kw === text) { kind = text; break } }
    }
    return new Token(kind, text, this.makeSpan(start))
  }

  private scanNumber(start: Position): Token {
    let begin = this.pos
    while (this.pos < this.source.length && isDigit(this.source[this.pos])) { this.pos++; this.col++ }
    if (this.pos < this.source.length && this.source[this.pos] === '.' && this.pos + 1 < this.source.length && isDigit(this.source[this.pos + 1])) {
      this.pos++; this.col++
      while (this.pos < this.source.length && isDigit(this.source[this.pos])) { this.pos++; this.col++ }
      return new Token('number', this.source.substring(begin, this.pos), this.makeSpan(start))
    }
    return new Token('integer', this.source.substring(begin, this.pos), this.makeSpan(start))
  }

  private scanString(start: Position): Token {
    this.pos++; this.col++
    let value = ''
    while (this.pos < this.source.length && this.source[this.pos] !== '"') {
      if (this.source[this.pos] === '\\') {
        this.pos++; this.col++
        if (this.pos >= this.source.length) break
        let esc = this.source[this.pos]
        if (esc === 'n') value += '\n'
        else if (esc === 't') value += '\t'
        else if (esc === '\\') value += '\\'
        else if (esc === '"') value += '"'
        else if (esc === 'u' && this.scanUnicodeEscape()) { value += this.escaped; continue }
        else value += esc
        this.pos++; this.col++
      } else {
        if (this.source[this.pos] === '\n') { this.line++; this.col = 0 }
        value += this.source[this.pos]
        this.pos++; this.col++
      }
    }
    if (this.pos < this.source.length) { this.pos++; this.col++ }
    return new Token('string', value, this.makeSpan(start))
  }

  private escaped: string = ''

  /**
   * \uXXXX or \u{X...}, as in TypeScript, with pos on the 'u'. The model writes
   * " · " for a middle dot; without this the backslash was dropped and the
   * screen read "u00b7". On success the character is left in `escaped` and pos
   * is past the escape; a malformed one consumes nothing and stays a plain 'u'.
   */
  private scanUnicodeEscape(): boolean {
    let begin = this.pos + 1
    let digits = ''
    let end = begin
    if (begin < this.source.length && this.source[begin] === '{') {
      let close = this.source.indexOf('}', begin + 1)
      if (close < 0) return false
      digits = this.source.substring(begin + 1, close)
      end = close + 1
      if (digits.length < 1 || digits.length > 6) return false
    } else {
      digits = this.source.substring(begin, begin + 4)
      end = begin + 4
      if (digits.length < 4) return false
    }
    for (let i = 0; i < digits.length; i++) {
      if ('0123456789abcdefABCDEF'.indexOf(digits[i]) < 0) return false
    }
    let code = parseInt(digits, 16)
    if (code > 0x10FFFF) return false
    this.escaped = String.fromCodePoint(code)
    this.col += end - this.pos
    this.pos = end
    return true
  }

  private scanSymbol(start: Position): Token {
    let c = this.source[this.pos]
    this.pos++; this.col++
    if (this.pos < this.source.length) {
      let c2 = c + this.source[this.pos]
      if (c2 === '==') {
        this.pos++; this.col++
        if (this.pos < this.source.length && this.source[this.pos] === '=') {
          this.pos++; this.col++
          return new Token('===', '===', this.makeSpan(start))
        }
        return new Token('==', '==', this.makeSpan(start))
      }
      if (c2 === '!=') {
        this.pos++; this.col++
        if (this.pos < this.source.length && this.source[this.pos] === '=') {
          this.pos++; this.col++
          return new Token('!==', '!==', this.makeSpan(start))
        }
        return new Token('!=', '!=', this.makeSpan(start))
      }
      if (c2 === '&&' || c2 === '||' || c2 === '<=' || c2 === '>=') {
        this.pos++; this.col++
        return new Token(c2, c2, this.makeSpan(start))
      }
    }
    return new Token(c, c, this.makeSpan(start))
  }

  private makePos(): Position { return new Position(this.pos, this.line, this.col) }
  private makeSpan(start: Position): Span { return new Span(start, this.makePos(), this.sourceName) }
}

// ===== Parser =====

/** Syntax errors reported from one compile; past this the rest is mostly noise. */
const MAX_SYNTAX_ERRORS: number = 20
const STATEMENT_STARTS: string[] = ['let', 'if', 'while', 'for', 'return', 'try', 'break', 'continue']
const DECLARATION_STARTS: string[] = ['import', 'annotation', 'class', 'function']

/**
 * Parses with recovery: a syntax error is recorded, the parser skips to the
 * next statement or declaration, and goes on, so one compile reports every
 * syntax error rather than the first. With repairs written as edits that
 * matters: egg-2 had two ternaries and needed two repair rounds, because the
 * second was only reported once the first was fixed. Errors that follow from
 * one already recorded are dropped until a statement parses cleanly again.
 */
class Parser {
  private tokens: Token[]
  private pos: number = 0
  private sourceName: string
  private diagnostics: Diagnostic[] = []
  /** An error was recorded and no statement has parsed cleanly since. */
  private recovering: boolean = false

  constructor(source: string, sourceName: string) {
    this.sourceName = sourceName
    this.tokens = new Lexer(source, sourceName).scan()
  }

  parse(): Application {
    let start = this.current().span
    let imports: ImportDeclaration[] = []
    let declarations: Declaration[] = []
    while (!this.atEnd() && this.diagnostics.length < MAX_SYNTAX_ERRORS) {
      let before = this.pos
      try {
        if (this.check('import')) { imports.push(this.parseImport()); continue }
        if (this.check('annotation')) {
          let ann = this.advance()
          declarations.push(this.parseClass(ann.text))
          continue
        }
        if (this.check('class')) { declarations.push(this.parseClass(null)); continue }
        if (this.check('async')) { declarations.push(this.parseFunction()); continue }
        if (this.check('function')) { declarations.push(this.parseFunction()); continue }
        this.error('expected import, class, or function declaration')
      } catch (e) {
        if (!(e instanceof CompileError)) throw e as Error
        this.record(e)
        // Skip to the next declaration, always moving at least one token.
        if (this.pos === before) this.advance()
        while (!this.atEnd() && !this.atDeclarationStart()) this.advance()
      }
    }
    if (this.diagnostics.length > 0) throw new CompileError(this.diagnostics)
    return new Application(this.span(start), imports, declarations)
  }

  private record(e: CompileError): void {
    if (!this.recovering) {
      for (let d of e.diagnostics) {
        // The same token reached again on the way out of a nested recovery.
        let last = this.diagnostics.length > 0 ? this.diagnostics[this.diagnostics.length - 1] : null
        if (last !== null && last.span.start.offset === d.span.start.offset) continue
        this.diagnostics.push(d)
      }
    }
    this.recovering = true
  }

  private atDeclarationStart(): boolean {
    let kind = this.current().kind
    if (DECLARATION_STARTS.indexOf(kind) >= 0) return true
    return kind === 'async' && this.pos + 1 < this.tokens.length && this.tokens[this.pos + 1].kind === 'function'
  }

  /**
   * After an error inside a block: skip to where the next statement can start.
   * That is a ';' or the block's own '}' (at the depth the statement began), a
   * statement keyword at the start of a line, or a top-level declaration.
   * Brackets the error left open are allowed to close on the way.
   */
  private synchronize(): void {
    let depth = 0
    let line = this.current().span.start.line
    while (!this.atEnd()) {
      let t = this.current()
      if (depth <= 0) {
        if (t.kind === ';') { this.advance(); return }
        if (t.kind === '}') return
        if (this.atDeclarationStart()) return
        if (t.span.start.line > line && STATEMENT_STARTS.indexOf(t.kind) >= 0) return
      }
      if (t.kind === '(' || t.kind === '[' || t.kind === '{') depth++
      else if (t.kind === ')' || t.kind === ']' || t.kind === '}') depth--
      this.advance()
    }
  }

  private parseImport(): ImportDeclaration {
    let start = this.current().span
    this.expect('import')
    this.expect('*')
    this.expect('as')
    let name = this.expect('name').text
    this.expect('from')
    let specifier = this.expect('string').text
    return new ImportDeclaration(this.span(start), name, specifier)
  }

  private parseClass(annotation: string | null): ClassDeclaration {
    let start = this.current().span
    this.expect('class')
    let name = this.expect('name').text
    this.expect('{')
    let fields: FieldDeclaration[] = []
    while (!this.check('}') && !this.atEnd()) {
      let fStart = this.current().span
      let fName = this.expect('name').text
      this.expect(':')
      let fType = this.parseType()
      if (this.check(';')) this.advance()
      fields.push(new FieldDeclaration(this.span(fStart), fName, fType))
    }
    this.expect('}')
    return new ClassDeclaration(this.span(start), name, fields, annotation)
  }

  private parseFunction(): FunctionDeclaration {
    let start = this.current().span
    let isAsync = false
    if (this.check('async')) { this.advance(); isAsync = true }
    this.expect('function')
    let name = this.expect('name').text
    this.expect('(')
    let params = this.parseParameters()
    this.expect(')')
    this.expect(':')
    let returnType = this.parseType()
    let body = this.parseBlock()
    return new FunctionDeclaration(this.span(start), name, params, returnType, body, isAsync)
  }

  private parseParameters(): Parameter[] {
    let params: Parameter[] = []
    if (this.check(')')) return params
    while (true) {
      let start = this.current().span
      let name = this.expect('name').text
      this.expect(':')
      let type = this.parseType()
      params.push(new Parameter(this.span(start), name, type))
      if (!this.check(',')) break
      this.advance()
    }
    return params
  }

  private parseType(): TypeNode {
    let start = this.current().span
    let type = this.parseBaseType()
    if (this.check('|')) {
      this.advance()
      this.expect('null')
      type = new TypeNode(this.span(start), type.name, type.parts, true)
    }
    return type
  }

  private parseBaseType(): TypeNode {
    let start = this.current().span
    if (this.check('(')) {
      this.advance()
      let params: TypeNode[] = []
      if (!this.check(')')) {
        while (true) {
          let pStart = this.current().span
          this.expect('name')
          this.expect(':')
          params.push(this.parseType())
          if (!this.check(',')) break
          this.advance()
        }
      }
      this.expect(')')
      this.expect('=')
      this.expect('>')
      let result = this.parseType()
      params.push(result)
      return new TypeNode(this.span(start), 'function', params)
    }
    if (this.check('async')) {
      this.advance()
      this.expect('(')
      let params: TypeNode[] = []
      if (!this.check(')')) {
        while (true) {
          let pStart = this.current().span
          this.expect('name')
          this.expect(':')
          params.push(this.parseType())
          if (!this.check(',')) break
          this.advance()
        }
      }
      this.expect(')')
      this.expect('=')
      this.expect('>')
      let result = this.parseType()
      params.push(result)
      return new TypeNode(this.span(start), 'async-function', params)
    }
    let name = this.expect('name').text
    if (this.check('.')) {
      this.advance()
      let member = this.expect('name').text
      name = name + '.' + member
    }
    if (this.check('[')) {
      this.advance()
      this.expect(']')
      let elementType = new TypeNode(this.span(start), name)
      return new TypeNode(this.span(start), 'array', [elementType])
    }
    return new TypeNode(this.span(start), name)
  }

  private parseBlock(): BlockStatement {
    let start = this.current().span
    this.expect('{')
    let stmts: Statement[] = []
    while (!this.check('}') && !this.atEnd()) {
      if (this.atDeclarationStart()) {
        // A '}' went missing: end the block here and let the declaration parse.
        this.record(new CompileError([new Diagnostic('E1001', 'expected }, found ' + this.current().kind, this.current().span)]))
        return new BlockStatement(this.span(start), stmts)
      }
      if (this.diagnostics.length >= MAX_SYNTAX_ERRORS) break
      let before = this.pos
      try {
        stmts.push(this.parseStatement())
        this.recovering = false
      } catch (e) {
        if (!(e instanceof CompileError)) throw e as Error
        this.record(e)
        this.synchronize()
        if (this.pos === before && !this.check('}')) this.advance()
        // At a statement boundary again: the next error is a new one.
        this.recovering = false
      }
    }
    this.expect('}')
    return new BlockStatement(this.span(start), stmts)
  }

  private parseStatement(): Statement {
    if (this.check('let')) return this.parseLet()
    if (this.check('if')) return this.parseIf()
    if (this.check('while')) return this.parseWhile()
    if (this.check('for')) return this.parseFor()
    if (this.check('break')) { let s = this.current().span; this.advance(); if (this.check(';')) this.advance(); return new BreakStatement(this.span(s)) }
    if (this.check('continue')) { let s = this.current().span; this.advance(); if (this.check(';')) this.advance(); return new ContinueStatement(this.span(s)) }
    if (this.check('return')) return this.parseReturn()
    if (this.check('try')) return this.parseTry()
    if (this.check('{')) return this.parseBlock()
    return this.parseExpressionOrAssign()
  }

  private parseLet(): LetStatement {
    let start = this.current().span
    this.expect('let')
    let name = this.expect('name').text
    this.expect(':')
    let type = this.parseType()
    this.expect('=')
    let init = this.parseExpression()
    if (this.check(';')) this.advance()
    return new LetStatement(this.span(start), name, type, init)
  }

  private parseIf(): IfStatement {
    let start = this.current().span
    this.expect('if')
    this.expect('(')
    let condition = this.parseExpression()
    this.expect(')')
    let thenBranch = this.parseBlock()
    let elseBranch: Statement | null = null
    if (this.check('else')) {
      this.advance()
      if (this.check('if')) elseBranch = this.parseIf()
      else elseBranch = this.parseBlock()
    }
    return new IfStatement(this.span(start), condition, thenBranch, elseBranch)
  }

  private parseWhile(): WhileStatement {
    let start = this.current().span
    this.expect('while')
    this.expect('(')
    let condition = this.parseExpression()
    this.expect(')')
    let body = this.parseBlock()
    return new WhileStatement(this.span(start), condition, body)
  }

  private parseFor(): ForOfStatement {
    let start = this.current().span
    this.expect('for')
    this.expect('(')
    this.expect('let')
    let name = this.expect('name').text
    this.expect(':')
    let type = this.parseType()
    this.expect('of')
    let iterable = this.parseExpression()
    this.expect(')')
    let body = this.parseBlock()
    return new ForOfStatement(this.span(start), name, type, iterable, body)
  }

  private parseReturn(): ReturnStatement {
    let start = this.current().span
    this.expect('return')
    let value: Expression | null = null
    if (!this.check('}') && !this.check(';') && !this.atEnd()) {
      value = this.parseExpression()
    }
    if (this.check(';')) this.advance()
    return new ReturnStatement(this.span(start), value)
  }

  private parseTry(): TryStatement {
    let start = this.current().span
    this.expect('try')
    let tryBlock = this.parseBlock()
    this.expect('catch')
    this.expect('(')
    let catchName = this.expect('name').text
    this.expect(')')
    let catchBlock = this.parseBlock()
    return new TryStatement(this.span(start), tryBlock, catchName, catchBlock)
  }

  private parseExpressionOrAssign(): Statement {
    let start = this.current().span
    let expr = this.parseExpression()
    if (this.check('=')) {
      this.advance()
      let value = this.parseExpression()
      if (this.check(';')) this.advance()
      return new AssignStatement(this.span(start), expr, value)
    }
    if (this.check(';')) this.advance()
    return new ExpressionStatement(this.span(start), expr)
  }

  private parseExpression(): Expression {
    return this.parseBinary(0)
  }

  private parseBinary(minPrec: number): Expression {
    let left = this.parseUnary()
    while (true) {
      let op = this.current().kind
      let prec = this.precedence(op)
      if (prec < 0 || prec < minPrec) break
      let start = left.span
      this.advance()
      let right = this.parseBinary(prec + 1)
      left = new BinaryExpression(this.span(start), left, op, right)
    }
    return left
  }

  private precedence(op: string): number {
    if (op === '||') return 1
    if (op === '&&') return 2
    if (op === '===' || op === '!==') return 3
    if (op === '<' || op === '<=' || op === '>' || op === '>=') return 4
    if (op === '+' || op === '-') return 5
    if (op === '*' || op === '/' || op === '%') return 6
    return -1
  }

  private parseUnary(): Expression {
    let start = this.current().span
    if (this.check('-')) {
      this.advance()
      let operand = this.parseUnary()
      return new UnaryExpression(this.span(start), '-', operand)
    }
    if (this.check('!')) {
      this.advance()
      let operand = this.parseUnary()
      return new UnaryExpression(this.span(start), '!', operand)
    }
    if (this.check('await')) {
      this.advance()
      let operand = this.parseUnary()
      return new AwaitExpression(this.span(start), operand)
    }
    return this.parsePostfix()
  }

  private parsePostfix(): Expression {
    let expr = this.parsePrimary()
    while (true) {
      if (this.check('(')) {
        let start = expr.span
        this.advance()
        let args: Expression[] = []
        if (!this.check(')')) {
          while (true) {
            args.push(this.parseListElement(')'))
            if (!this.check(',')) break
            this.advance()
          }
        }
        this.expect(')')
        expr = new CallExpression(this.span(start), expr, args)
      } else if (this.check('[')) {
        let start = expr.span
        this.advance()
        let index = this.parseExpression()
        this.expect(']')
        expr = new IndexExpression(this.span(start), expr, index)
      } else if (this.check('.')) {
        let start = expr.span
        this.advance()
        let field = this.expect('name').text
        expr = new SelectExpression(this.span(start), expr, field)
      } else if (this.check('!')) {
        let start = expr.span
        this.advance()
        expr = new EnsureNotNullExpression(this.span(start), expr)
      } else {
        break
      }
    }
    return expr
  }

  private parsePrimary(): Expression {
    let start = this.current().span
    if (this.check('name')) {
      let name = this.advance().text
      return new NameExpression(this.span(start), name)
    }
    if (this.check('integer')) {
      let text = this.advance().text
      let value = parseInt(text)
      return new IntExpression(this.span(start), value)
    }
    if (this.check('number')) {
      let text = this.advance().text
      let value = parseFloat(text)
      return new NumberExpression(this.span(start), value)
    }
    if (this.check('string')) {
      let text = this.advance().text
      return new StringExpression(this.span(start), text)
    }
    if (this.check('boolean')) {
      let text = this.advance().text
      return new BooleanExpression(this.span(start), text === 'true')
    }
    if (this.check('null')) {
      this.advance()
      return new NullExpression(this.span(start))
    }
    if (this.check('(')) {
      this.advance()
      if (this.check(')') || this.isLambdaStart()) {
        return this.parseLambda(start)
      }
      let expr = this.parseListElement(')')
      this.expect(')')
      return expr
    }
    if (this.check('[')) {
      this.advance()
      let elements: Expression[] = []
      if (!this.check(']')) {
        while (true) {
          elements.push(this.parseListElement(']'))
          if (!this.check(',')) break
          this.advance()
        }
      }
      this.expect(']')
      return new ArrayExpression(this.span(start), elements)
    }
    if (this.check('{')) {
      this.advance()
      let props: Property[] = []
      if (!this.check('}')) {
        while (true) {
          let pStart = this.current().span
          let pName = this.expect('name').text
          this.expect(':')
          let pValue = this.parseListElement('}')
          props.push(new Property(this.span(pStart), pName, pValue))
          if (!this.check(',')) break
          this.advance()
        }
      }
      this.expect('}')
      return new ObjectExpression(this.span(start), props)
    }
    this.error('expected expression')
    return new NullExpression(this.span(start))
  }

  /**
   * One argument, array element, property value or parenthesised expression. A view is one long expression -- a whole
   * screen of nested calls in a single return -- so recovering only between
   * statements would hide every later error in it. On an error inside the
   * element, or anything but ',' or `close` after it, the error is recorded and
   * the parser skips to the next ',' or to `close` at this depth.
   */
  private parseListElement(close: string): Expression {
    let start = this.current().span
    try {
      let element = this.parseExpression()
      if (!this.check(',') && !this.check(close)) this.error('expected ' + close + ', found ' + this.current().kind)
      this.recovering = false
      return element
    } catch (e) {
      if (!(e instanceof CompileError)) throw e as Error
      this.record(e)
      let depth = 0
      while (!this.atEnd()) {
        let kind = this.current().kind
        if (depth === 0 && (kind === ',' || kind === close)) break
        // A statement or declaration boundary: the list is not coming back.
        if (depth <= 0 && (kind === ';' || this.atDeclarationStart())) break
        if (kind === '(' || kind === '[' || kind === '{') depth++
        else if (kind === ')' || kind === ']' || kind === '}') {
          if (depth === 0) break
          depth--
        }
        this.advance()
      }
      return new NullExpression(this.span(start))
    }
  }

  private isLambdaStart(): boolean {
    let saved = this.pos
    if (this.check('name')) {
      this.advance()
      let result = this.check(':')
      this.pos = saved
      return result
    }
    this.pos = saved
    return false
  }

  private parseLambda(start: Span): LambdaExpression {
    let params: Parameter[] = []
    if (!this.check(')')) {
      while (true) {
        let pStart = this.current().span
        let pName = this.expect('name').text
        this.expect(':')
        let pType = this.parseType()
        params.push(new Parameter(this.span(pStart), pName, pType))
        if (!this.check(',')) break
        this.advance()
      }
    }
    this.expect(')')
    this.expect(':')
    let returnType = this.parseType()
    this.expect('=')
    this.expect('>')
    let body = this.parseBlock()
    return new LambdaExpression(this.span(start), params, returnType, body)
  }

  private current(): Token { return this.tokens[this.pos] }
  private atEnd(): boolean { return this.current().kind === 'eof' }
  private check(kind: string): boolean { return this.current().kind === kind }
  private advance(): Token { let t = this.current(); this.pos++; return t }
  private expect(kind: string): Token {
    if (!this.check(kind)) this.error('expected ' + kind + ', found ' + this.current().kind)
    return this.advance()
  }
  private span(start: Span): Span { return new Span(start.start, this.tokens[this.pos > 0 ? this.pos - 1 : 0].span.end, this.sourceName) }
  private error(message: string): never {
    let span = this.current().span
    throw new CompileError([new Diagnostic('E1001', message, span)])
  }
}

// ===== Semantic Analysis =====

class ExternalFunction {
  name: string
  parameters: VeraType[]
  result: VeraType
  isAsync: boolean
  /** How many of the parameters must actually be passed; the rest are trailing optionals. */
  required: number
  constructor(name: string, parameters: VeraType[], result: VeraType, isAsync: boolean,
      required: number = -1) {
    this.name = name; this.parameters = parameters; this.result = result; this.isAsync = isAsync
    this.required = required < 0 ? parameters.length : required
  }
}

class ExternalClass {
  name: string
  type: VeraClassType
  constructor(name: string, type: VeraClassType) {
    this.name = name; this.type = type
  }
}

class ModuleInterface {
  specifier: string
  functions: ExternalFunction[]
  classes: ExternalClass[]
  constructor(specifier: string, functions: ExternalFunction[], classes: ExternalClass[]) {
    this.specifier = specifier; this.functions = functions; this.classes = classes
  }
}

/**
 * Generated from VeraUiCatalog, so the signatures the compiler accepts cannot
 * drift from what the host decodes, the renderer draws, and the prompt tells
 * the model about.
 */
function buildStdUiModule(): ModuleInterface {
  let viewType = new VeraClassType('std/ui:View', 'View')
  let viewArray = new VeraArrayType(viewType)
  let fns: ExternalFunction[] = []
  for (let spec of CATALOG) {
    let params: VeraType[] = []
    for (let p of spec.props) {
      if (p.kind === 'number') params.push(NUMBER)
      else if (p.kind === 'boolean') params.push(BOOLEAN)
      else if (p.kind === 'view') params.push(viewType)
      else if (p.kind === 'view[]') params.push(viewArray)
      else if (p.kind === 'string[]') params.push(new VeraArrayType(STRING))
      else if (p.kind === 'number[]') params.push(new VeraArrayType(NUMBER))
      else params.push(STRING)
    }
    // Trailing optionals may be left off, so a program written against an
    // older version of the catalogue still compiles.
    let required = params.length
    while (required > 0 && spec.props[required - 1].optional) { required -= 1 }
    fns.push(new ExternalFunction(spec.name, params, viewType, false, required))
  }
  fns.push(new ExternalFunction('When', [BOOLEAN, viewType], viewType, false))
  fns.push(new ExternalFunction('numberToString', [NUMBER], STRING, false))
  fns.push(new ExternalFunction('formatNumber', [NUMBER, NUMBER], STRING, false))
  fns.push(new ExternalFunction('clockToString', [NUMBER], STRING, false))
  fns.push(new ExternalFunction('dateToString', [NUMBER], STRING, false))
  fns.push(new ExternalFunction('durationToString', [NUMBER], STRING, false))
  fns.push(new ExternalFunction('booleanToString', [BOOLEAN], STRING, false))
  return new ModuleInterface('std/ui', fns, [new ExternalClass('View', viewType)])
}

/**
 * The clock, in numbers. nowMillis is Unix milliseconds (~1.8e12), exact in a
 * double; it is what a countdown or a timestamp should be built from.
 *
 * Programs should read the clock in handlers, where the result is stored into
 * state, rather than in view(): view is meant to be a pure function of state,
 * and a clock call there makes the tree differ between two renders of the same
 * state.
 */
/**
 * Arithmetic the language cannot express. There is one numeric type, so each
 * operation has one name; floor, round and ceil are how a program gets a whole
 * number when it needs one.
 */
function buildStdMathModule(): ModuleInterface {
  let fns: ExternalFunction[] = [
    new ExternalFunction('pi', [], NUMBER, false),
    new ExternalFunction('sqrt', [NUMBER], NUMBER, false),
    new ExternalFunction('sin', [NUMBER], NUMBER, false),
    new ExternalFunction('cos', [NUMBER], NUMBER, false),
    new ExternalFunction('atan2', [NUMBER, NUMBER], NUMBER, false),
    new ExternalFunction('pow', [NUMBER, NUMBER], NUMBER, false),
    new ExternalFunction('floor', [NUMBER], NUMBER, false),
    new ExternalFunction('round', [NUMBER], NUMBER, false),
    new ExternalFunction('ceil', [NUMBER], NUMBER, false),
    new ExternalFunction('abs', [NUMBER], NUMBER, false),
    new ExternalFunction('min', [NUMBER, NUMBER], NUMBER, false),
    new ExternalFunction('max', [NUMBER, NUMBER], NUMBER, false),
    // Deterministic and replayable: the seed lives in the program's state, so a
    // saved game restores to the same sequence. A host random() would not.
    new ExternalFunction('randomStep', [NUMBER], NUMBER, false),
    new ExternalFunction('randomBelow', [NUMBER, NUMBER], NUMBER, false),
  ]
  return new ModuleInterface('std/math', fns, [])
}

function buildStdTimeModule(): ModuleInterface {
  let fns: ExternalFunction[] = [
    new ExternalFunction('nowMillis', [], NUMBER, false),
    new ExternalFunction('nowSeconds', [], NUMBER, false),
    new ExternalFunction('millisOfDay', [], NUMBER, false),
    new ExternalFunction('daysSinceEpoch', [], NUMBER, false),
    new ExternalFunction('hourOfDay', [], NUMBER, false),
    new ExternalFunction('minuteOfHour', [], NUMBER, false),
    new ExternalFunction('weekday', [], NUMBER, false),
    // The calendar fields. daysSinceEpoch answers "same day?" but cannot name a
    // day, so anything a person reads back later -- a history row, a report
    // shown to someone else -- had no way to say which date it was about.
    new ExternalFunction('dayOfMonth', [], NUMBER, false),
    new ExternalFunction('monthOfYear', [], NUMBER, false),
    new ExternalFunction('year', [], NUMBER, false),
  ]
  return new ModuleInterface('std/time', fns, [])
}

/**
 * Text, as specified in VERA-L.md's `std/strings` library.
 *
 * The language itself gives a string only `+`, comparison, `.length()` and
 * for-of over its characters, so until now a program could build text but never
 * take it apart. These are the spec's eight functions, with the spec's
 * semantics rather than ArkTS's -- notably positions are Unicode scalar values,
 * not UTF-16 code units.
 *
 * Note the one inconsistency this introduces: the `.length()` intrinsic counts
 * UTF-16 code units (VeraInterpreter's 'length' op), while for-of over a string
 * and `strings.length` here both count scalar values. They agree on every
 * character in the BMP and disagree on an emoji.
 */
function buildStdStringsModule(): ModuleInterface {
  let fns: ExternalFunction[] = [
    new ExternalFunction('length', [STRING], NUMBER, false),
    new ExternalFunction('substring', [STRING, NUMBER, NUMBER], STRING, false),
    new ExternalFunction('contains', [STRING, STRING], BOOLEAN, false),
    new ExternalFunction('startsWith', [STRING, STRING], BOOLEAN, false),
    new ExternalFunction('endsWith', [STRING, STRING], BOOLEAN, false),
    new ExternalFunction('replace', [STRING, STRING, STRING], STRING, false),
    new ExternalFunction('split', [STRING, STRING], new VeraArrayType(STRING), false),
    new ExternalFunction('trim', [STRING], STRING, false),
    new ExternalFunction('toUpperCase', [STRING], STRING, false),
    new ExternalFunction('toLowerCase', [STRING], STRING, false),
    // Text the person typed, read as a number: fallback when it is not one.
    new ExternalFunction('toNumber', [STRING, NUMBER], NUMBER, false),
  ]
  return new ModuleInterface('std/strings', fns, [])
}

/**
 * The one way a program reaches anything outside itself: the OpenHarmony system API surface (found through
 * find_sdk_function, VeraSdkIndex, built offline by tools/build-sdk-index.py
 * from interface_sdk-js) and device intents (found through
 * find_intent_function, VeraIntentIndex) -- both the curated, probed rows
 * and the raw device registry. See docs/selector-design.md.
 *
 *   sdk.call("CameraKit.CameraManager.setTorchMode", ["mode", "0"], "onAnswer")
 *   sdk.call("com.huawei.hmos.meetimeservice/phone_default/IntentUIAbility/SendTextMessage",
 *            [], "onAnswer", "background")
 *   sdk.call("com.huawei.hmos.calendar/phone/MainAbility", [], "onAnswer")
 *
 * One function, two target shapes, told apart by checkSdkArguments on
 * whether the target has slashes (an intent address) or dots (an sdk index
 * entry) -- the same distinction the two tools already encode in what they
 * hand back. An intent-style target is itself two shapes, told apart by
 * whether it has three or four slash-separated parts: three
 * (bundle/module/ability) just launches the target, the way opening the
 * calendar app does; four (...ability/IntentName) goes through
 * insightIntentDriver with a name and parameters. See runRawIntent in
 * VeraIntents.ets. The trailing `mode` is optional and only means anything
 * for the four-part shape. Execution branches the same way
 * (VeraPreview.runEffect): an intent-style target gets real dispatch through
 * runRawIntent, an sdk-style one is real for whatever VeraSdkBackend.ets has
 * a row for and the same honest stub as always otherwise.
 *
 * What used to be std/intent's typed catalogue cannot check any more (the
 * closed set of allowed values for a field, e.g. startNavigate's traffic
 * type) once its rows are reached through this raw call instead: the model
 * is shown every allowed value, translated to the platform's own spelling,
 * in find_intent_function's own answer, but nothing here can catch it writing
 * a value that was not on that list. That is a real, accepted cost of
 * retiring the typed catalogue (see the commit that removed
 * buildStdIntentModule, revert it if this turns out to matter) -- sdk-style
 * targets already carried exactly this risk, and now intent-style ones do
 * too. What this can still check, for an sdk-style target, that a
 * device-only registry entry never could: the index it's checked against is
 * a static artifact, not read from the phone, so a target the model invented
 * instead of asking is a compile error here rather than a silent no-op on
 * the phone.
 */
function buildStdSdkModule(): ModuleInterface {
  let fns: ExternalFunction[] = [
    new ExternalFunction('call',
      [STRING, new VeraArrayType(STRING), STRING, STRING], NUMBER, false, 3)
  ]
  return new ModuleInterface('std/sdk', fns, [])
}

/**
 * What a ui.Surface draws: shapes in the surface's own units, and the pointer its handler is handed. Generated
 * from VeraGfx's table, so the signatures cannot drift from what the host builds and the prompt describes.
 */
function buildStdGfxModule(): ModuleInterface {
  let shapeType = new VeraClassType('std/gfx:Shape', 'Shape')
  let pointerType = new VeraClassType('std/gfx:Pointer', 'Pointer')
  for (let pair of GFX_POINTER_FIELDS) {
    pointerType.fields.set(pair[0], pair[1] === 'number' ? NUMBER : STRING)
  }
  let fns: ExternalFunction[] = []
  for (let f of GFX_FUNCTIONS) {
    let params: VeraType[] = []
    let required = 0
    for (let p of f.params) {
      if (p.kind === 'number') params.push(NUMBER)
      else if (p.kind === 'boolean') params.push(BOOLEAN)
      else if (p.kind === 'number[]') params.push(new VeraArrayType(NUMBER))
      else if (p.kind === 'shapes') params.push(new VeraArrayType(shapeType))
      else if (p.kind === 'colors') params.push(new VeraArrayType(STRING))
      else params.push(STRING)
      if (!p.optional) required = params.length
    }
    let result: VeraType = f.result === 'shape' ? shapeType : f.result === 'number' ? NUMBER
      : f.result === 'boolean' ? BOOLEAN : STRING
    fns.push(new ExternalFunction(f.name, params, result, false, required))
  }
  return new ModuleInterface('std/gfx', fns, [new ExternalClass('Shape', shapeType), new ExternalClass('Pointer', pointerType)])
}

/** String methods a program may call on a string value; each is the std/strings function of that name. */
const STRING_METHODS: string[] = ['toUpperCase', 'toLowerCase']

/** std modules a program may use without importing them, each under its own name. */
const PRELUDE_NAMES: string[] = ['ui', 'math', 'time', 'strings', 'sdk', 'gfx']

class Scope {
  values: Map<string, VeraType> = new Map<string, VeraType>()
  /** Names bound here that the program may read but not assign: parameters and for-of variables. */
  readOnly: Set<string> = new Set<string>()
  parent: Scope | null
  constructor(parent: Scope | null) { this.parent = parent }
  find(name: string): VeraType | null {
    let v = this.values.get(name)
    if (v !== undefined) return v
    if (this.parent !== null) return this.parent.find(name)
    return null
  }
  /** The scope that binds `name`, or null when nothing does. */
  owner(name: string): Scope | null {
    if (this.values.has(name)) return this
    if (this.parent !== null) return this.parent.owner(name)
    return null
  }
  isReadOnly(name: string): boolean {
    let o = this.owner(name)
    return o !== null && o.readOnly.has(name)
  }
}

class SemanticModel {
  expressionTypes: Map<Expression, VeraType> = new Map<Expression, VeraType>()
  declaredTypes: Map<TypeNode, VeraType> = new Map<TypeNode, VeraType>()
  functions: Map<string, VeraFunctionType> = new Map<string, VeraFunctionType>()
  classes: Map<string, VeraClassType> = new Map<string, VeraClassType>()
  imports: Map<string, ModuleInterface> = new Map<string, ModuleInterface>()
  application: Application
  constructor(application: Application) { this.application = application }
}

class Narrowing {
  whenTrue: Scope
  whenFalse: Scope
  constructor(whenTrue: Scope, whenFalse: Scope) { this.whenTrue = whenTrue; this.whenFalse = whenFalse }
}

class Analyzer {
  private diagnostics: Diagnostic[] = []
  private model: SemanticModel
  private globals: Scope = new Scope(null)
  private returnType: VeraType = VOID
  private inAsyncFunction: boolean = false
  private loopDepth: number = 0
  private lambdaCount: number = 0
  private options: CompileOptions

  constructor(application: Application, options: CompileOptions) {
    this.model = new SemanticModel(application)
    this.options = options
  }

  analyze(): SemanticModel {
    this.collectImports()
    for (let decl of this.model.application.declarations) {
      if (!(decl instanceof ClassDeclaration) && !(decl instanceof FunctionDeclaration)) continue
      if (this.globals.find(decl.name) !== null) { this.addError('E2001', 'duplicate global ' + decl.name, decl.span); continue }
      if (decl instanceof ClassDeclaration) {
        let type = new VeraClassType('local:' + decl.name, decl.name)
        this.model.classes.set(decl.name, type)
        this.globals.values.set(decl.name, type)
      } else {
        this.globals.values.set(decl.name, new VeraFunctionType([], VOID, (decl as FunctionDeclaration).isAsync, 'pending:' + decl.name))
      }
    }
    for (let decl of this.model.application.declarations) {
      if (!(decl instanceof FunctionDeclaration)) continue
      let params: VeraType[] = []
      for (let p of decl.parameters) params.push(this.resolveType(p.type))
      let result = this.resolveType(decl.returnType)
      let type = new VeraFunctionType(params, result, decl.isAsync, 'function:' + decl.name)
      this.model.functions.set(decl.name, type)
      this.globals.values.set(decl.name, type)
    }
    for (let decl of this.model.application.declarations) {
      if (decl instanceof ClassDeclaration) this.checkClass(decl)
    }
    this.checkJsonableCycles()
    // A declaration's own place, for an error about its signature: the whole program when it cannot be found.
    let placeOf = (name: string): Span => {
      let found = this.model.application.declarations.find((d: Declaration): boolean =>
        d instanceof FunctionDeclaration && (d as FunctionDeclaration).name === name)
      return found !== undefined ? found.span : this.model.application.span
    }
    let widget = this.model.functions.get('widget')
    if (widget !== undefined) {
      let init = this.model.functions.get('init')
      let view = this.model.functions.get('view')
      let uiView = this.stdModules.get('std/ui')!.classes.find((c: ExternalClass): boolean => c.name === 'View')
      let sizeOk = widget.parameters.length === 1 || (widget.parameters.length === 2 && identical(widget.parameters[1], NUMBER))
      if (init === undefined || view === undefined || uiView === undefined || widget.isAsync || !sizeOk ||
          !identical(widget.parameters[0], init.result) || !identical(widget.result, uiView.type)) {
        this.addError('E2115', 'widget must be synchronous: function widget(state: init return type[, size: number]): ui.View', placeOf('widget'))
      }
    }
    // The card's periodic update (LiveFormService.liveFormRefresh): the state brought up to date with the clock.
    let refresh = this.model.functions.get('widgetRefresh')
    if (refresh !== undefined) {
      let init = this.model.functions.get('init')
      if (init === undefined || refresh.isAsync || refresh.parameters.length !== 1 ||
          !identical(refresh.parameters[0], init.result) || !identical(refresh.result, init.result)) {
        this.addError('E2113', 'widgetRefresh must be synchronous: function widgetRefresh(state: init return type): init return type',
          placeOf('widgetRefresh'))
      }
    }
    for (let decl of this.model.application.declarations) {
      if (decl instanceof FunctionDeclaration) this.checkFunction(decl)
    }
    if (this.diagnostics.length > 0) throw new CompileError(this.diagnostics)
    return this.model
  }

  private stdModules: Map<string, ModuleInterface> = new Map<string, ModuleInterface>()

  private collectImports(): void {
    // A table rather than a chain of string compares, so a new std module is
    // one entry here plus a host implementation -- nothing in the checker, the
    // code generator, the bytecode format or the VM has to know about it.
    let registry = this.stdModules
    registry.set('std/ui', buildStdUiModule())
    registry.set('std/time', buildStdTimeModule())
    registry.set('std/math', buildStdMathModule())
    registry.set('std/strings', buildStdStringsModule())
    registry.set('std/sdk', buildStdSdkModule())
    registry.set('std/gfx', buildStdGfxModule())
    for (let decl of this.model.application.imports) {
      if (this.globals.find(decl.name) !== null) { this.addError('E2001', 'duplicate global ' + decl.name, decl.span); continue }
      let found = registry.get(decl.specifier)
      let resolved: ModuleInterface | null = found !== undefined ? found : null
      if (resolved === null) { this.addError('E2002', 'module not found: ' + decl.specifier, decl.span); continue }
      this.bindNamespace(decl.name, resolved)
    }
  }

  private bindNamespace(name: string, resolved: ModuleInterface): void {
    let members = new Map<string, VeraType>()
    for (let fn of resolved.functions) members.set(fn.name, new VeraFunctionType(fn.parameters, fn.result, fn.isAsync, 'external:' + resolved.specifier + ':' + fn.name, fn.required))
    for (let cls of resolved.classes) members.set(cls.name, cls.type)
    this.model.imports.set(name, resolved)
    this.globals.values.set(name, new NamespaceType(name, members))
  }

  /**
   * The prelude: ui, math, time, strings and sdk need no import. A program
   * that writes math.floor without `import * as math from "std/math"` gets
   * std/math, the way TypeScript's Math needs no import -- leaving the line
   * out was the commonest first-attempt compile error. Bound only when the
   * name is otherwise unknown, so a program's own `time` local still works,
   * and an explicit import under that name still wins.
   */
  private preludeNamespace(name: string): VeraType | null {
    if (PRELUDE_NAMES.indexOf(name) < 0) return null
    let resolved = this.stdModules.get('std/' + name)
    if (resolved === undefined) return null
    this.bindNamespace(name, resolved)
    return this.globals.find(name)
  }

  private checkClass(decl: ClassDeclaration): void {
    let type = this.model.classes.get(decl.name)
    if (type === undefined) return
    if (decl.annotation !== null && decl.annotation !== 'jsonable') this.addError('E2039', 'unknown annotation ' + decl.annotation, decl.span)
    for (let field of decl.fields) {
      if (type.fields.has(field.name)) this.addError('E2003', 'duplicate field ' + field.name, field.span)
      else type.fields.set(field.name, this.resolveType(field.type))
    }
  }

  private checkJsonableCycles(): void {
    let jsonables: ClassDeclaration[] = []
    for (let d of this.model.application.declarations) {
      if (d instanceof ClassDeclaration && d.annotation === 'jsonable') jsonables.push(d)
    }
    let visiting = new Set<string>()
    let visited = new Set<string>()
    let jsonableNames = new Set<string>()
    for (let d of jsonables) jsonableNames.add(d.name)
    for (let d of jsonables) {
      if (this.visitJsonable(d.name, jsonableNames, visiting, visited)) {
        this.addError('E2040', 'circular jsonable dependency involving ' + d.name, d.span)
        break
      }
    }
  }

  private visitJsonable(name: string, jsonable: Set<string>, visiting: Set<string>, visited: Set<string>): boolean {
    if (visiting.has(name)) return true
    if (visited.has(name)) return false
    visiting.add(name)
    let type = this.model.classes.get(name)
    if (type !== undefined) {
      let fieldValues = Array.from(type.fields.values())
      for (let ft of fieldValues) {
        let dep = this.localClass(ft)
        if (dep !== null && jsonable.has(dep.name) && this.visitJsonable(dep.name, jsonable, visiting, visited)) return true
      }
    }
    visiting.delete(name)
    visited.add(name)
    return false
  }

  private localClass(type: VeraType): VeraClassType | null {
    if (type instanceof NullableType) return this.localClass(type.base)
    if (type instanceof VeraArrayType) return this.localClass(type.element)
    if (type instanceof VeraClassType && type.identity.startsWith('local:')) return type
    return null
  }

  private checkFunction(decl: FunctionDeclaration): void {
    let ft = this.model.functions.get(decl.name)
    if (ft === undefined) return
    let prevRet = this.returnType
    let prevAsync = this.inAsyncFunction
    this.returnType = ft.result
    this.inAsyncFunction = decl.isAsync
    let scope = new Scope(this.globals)
    for (let i = 0; i < decl.parameters.length; i++) {
      let p = decl.parameters[i]
      if (scope.find(p.name) !== null) this.addError('E2004', 'declaration ' + p.name + ' shadows a visible entity', p.span)
      else { scope.values.set(p.name, ft.parameters[i]); scope.readOnly.add(p.name) }
    }
    let returns = this.checkBlock(decl.body, scope)
    if (!identical(this.returnType, VOID) && !returns) this.addError('E2018', 'function ' + decl.name + ' must return a value', decl.body.span)
    this.returnType = prevRet
    this.inAsyncFunction = prevAsync
  }

  private checkBlock(block: BlockStatement, parent: Scope): boolean {
    let scope = new Scope(parent)
    let returns = false
    for (let s of block.statements) {
      if (this.checkStatement(s, scope)) returns = true
    }
    return returns
  }

  private checkStatement(stmt: Statement, scope: Scope): boolean {
    if (stmt instanceof BlockStatement) return this.checkBlock(stmt, scope)
    if (stmt instanceof LetStatement) {
      let type = this.resolveType(stmt.type)
      this.checkExpression(stmt.initializer, scope, type)
      if (scope.find(stmt.name) !== null) this.addError('E2004', 'declaration ' + stmt.name + ' shadows a visible entity', stmt.span)
      else scope.values.set(stmt.name, type)
      return false
    }
    if (stmt instanceof AssignStatement) {
      let target = this.checkAssignable(stmt.target, scope)
      this.checkExpression(stmt.value, scope, target)
      return false
    }
    if (stmt instanceof ExpressionStatement) {
      this.checkExpression(stmt.expression, scope, null)
      if (!(stmt.expression instanceof CallExpression) && !(stmt.expression instanceof AwaitExpression)) {
        this.addError('E2005', 'expression statement must be a function call', stmt.span)
      }
      return false
    }
    if (stmt instanceof IfStatement) {
      this.requireType(this.checkExpression(stmt.condition, scope, BOOLEAN), BOOLEAN, stmt.condition)
      let narrowing = this.narrow(stmt.condition, scope)
      let thenRet = this.checkBlock(stmt.thenBranch, narrowing.whenTrue)
      let elseRet = stmt.elseBranch === null ? false : this.checkStatement(stmt.elseBranch, narrowing.whenFalse)
      return thenRet && elseRet
    }
    if (stmt instanceof WhileStatement) {
      this.requireType(this.checkExpression(stmt.condition, scope, BOOLEAN), BOOLEAN, stmt.condition)
      this.loopDepth += 1
      this.checkBlock(stmt.body, scope)
      this.loopDepth -= 1
      return false
    }
    if (stmt instanceof ForOfStatement) {
      let iter = this.checkExpression(stmt.iterable, scope, null)
      let declared = this.resolveType(stmt.type)
      let element: VeraType | null = null
      if (iter instanceof VeraArrayType) element = iter.element
      else if (identical(iter, STRING)) element = STRING
      else this.addError('E2006', 'for-of requires an array or string', stmt.iterable.span)
      if (element !== null && !identical(element, declared)) this.typeError(stmt.iterable, declared, element)
      let child = new Scope(scope)
      if (child.find(stmt.name) !== null) this.addError('E2004', 'declaration ' + stmt.name + ' shadows a visible entity', stmt.span)
      else { child.values.set(stmt.name, declared); child.readOnly.add(stmt.name) }
      this.loopDepth += 1
      this.checkBlock(stmt.body, child)
      this.loopDepth -= 1
      return false
    }
    if (stmt instanceof BreakStatement || stmt instanceof ContinueStatement) {
      if (this.loopDepth === 0) this.addError('E2007', 'loop control used outside a loop', stmt.span)
      return false
    }
    if (stmt instanceof TryStatement) {
      let tryRet = this.checkBlock(stmt.tryBlock, scope)
      let catchScope = new Scope(scope)
      catchScope.values.set(stmt.catchName, STRING)
      let catchRet = this.checkBlock(stmt.catchBlock, catchScope)
      return tryRet && catchRet
    }
    if (stmt instanceof ReturnStatement) {
      if (stmt.value === null) {
        if (!identical(this.returnType, VOID)) this.addError('E2008', 'return value required', stmt.span)
      } else {
        if (identical(this.returnType, VOID)) this.addError('E2009', 'void function cannot return a value', stmt.span)
        else this.checkExpression(stmt.value, scope, this.returnType)
      }
      return true
    }
    return false
  }

  /**
   * What the language allows a bare name to be assigned: a let local, of any
   * type. A parameter or for-of variable is read-only ("return a new value
   * instead"), and a global -- a class, function or imported namespace -- is
   * not a variable at all.
   *
   * This used to decide by the name's type, refusing anything whose type was a
   * class. That was meant for `AppState = ...`, but a variable of class type has
   * the same type as the class, so `let badge: ui.View = ...; badge = ...` was
   * refused too, while an int or string parameter could be reassigned freely.
   */
  private checkAssignable(expr: Expression, scope: Scope): VeraType {
    if (expr instanceof NameExpression) {
      let type = scope.find(expr.name)
      let owner = scope.owner(expr.name)
      if (type === null || owner === null || owner === this.globals) {
        this.addError('E2010', 'invalid assignment target', expr.span)
        return VOID
      }
      if (owner.readOnly.has(expr.name)) {
        this.addError('E2010', 'cannot assign to ' + expr.name + ': parameters and for-of variables are read-only; ' +
          'declare a let local or return a new value instead', expr.span)
        return type
      }
      return type
    }
    if (expr instanceof IndexExpression || expr instanceof SelectExpression) return this.checkExpression(expr, scope, null)
    this.addError('E2010', 'invalid assignment target', expr.span)
    return VOID
  }

  private checkExpression(expr: Expression, scope: Scope, expected: VeraType | null): VeraType {
    let result: VeraType = VOID
    if (expr instanceof IntExpression) {
      // A literal without a '.' is still a number: there is no other numeric type.
      if (expr.value > 9007199254740991) this.addError('E2011', 'number literal is larger than a number holds exactly', expr.span)
      result = NUMBER
    }
    else if (expr instanceof NumberExpression) result = NUMBER
    else if (expr instanceof StringExpression) result = STRING
    else if (expr instanceof BooleanExpression) result = BOOLEAN
    else if (expr instanceof NullExpression) result = NULL_TYPE
    else if (expr instanceof NameExpression) {
      let found = scope.find(expr.name)
      if (found === null) found = this.preludeNamespace(expr.name)
      if (found !== null) result = found
      else { result = VOID; this.addError('E2012', 'unknown name ' + expr.name, expr.span) }
    }
    else if (expr instanceof ArrayExpression) result = this.checkArray(expr, scope, expected)
    else if (expr instanceof ObjectExpression) result = this.checkObject(expr, scope, expected)
    else if (expr instanceof UnaryExpression) result = this.checkUnary(expr, scope)
    else if (expr instanceof BinaryExpression) result = this.checkBinary(expr, scope)
    else if (expr instanceof IndexExpression) {
      let target = this.checkExpression(expr.target, scope, null)
      this.requireType(this.checkExpression(expr.index, scope, NUMBER), NUMBER, expr.index)
      if (target instanceof VeraArrayType) result = target.element
      else this.addError('E2013', 'index target must be an array', expr.target.span)
    }
    else if (expr instanceof SelectExpression) result = this.checkSelect(expr, scope)
    else if (expr instanceof EnsureNotNullExpression) {
      let op = this.checkExpression(expr.operand, scope, null)
      if (op instanceof NullableType) result = op.base
      else { this.addError('E2041', 'ensure-not-null requires a nullable value', expr.span); result = op }
    }
    else if (expr instanceof CallExpression) result = this.checkCall(expr, scope, false)
    else if (expr instanceof AwaitExpression) {
      if (!this.inAsyncFunction) this.addError('E2014', 'await is valid only in an async function', expr.span)
      if (!(expr.operand instanceof CallExpression)) { this.addError('E2015', 'await requires an async function call', expr.span); result = VOID }
      else result = this.checkCall(expr.operand, scope, true)
    }
    else if (expr instanceof LambdaExpression) result = this.checkLambda(expr, scope)
    this.model.expressionTypes.set(expr, result)
    if (expected !== null && !assignable(result, expected)) this.typeError(expr, expected, result)
    return result
  }

  private checkArray(expr: ArrayExpression, scope: Scope, expected: VeraType | null): VeraType {
    let candidate = expected instanceof NullableType ? expected.base : expected
    if (!(candidate instanceof VeraArrayType)) {
      this.addError('E2020', 'array literal requires array context', expr.span)
      return new VeraArrayType(VOID)
    }
    for (let el of expr.elements) this.checkExpression(el, scope, candidate.element)
    return candidate
  }

  private checkObject(expr: ObjectExpression, scope: Scope, expected: VeraType | null): VeraType {
    let candidate = expected instanceof NullableType ? expected.base : expected
    if (!(candidate instanceof VeraClassType)) {
      this.addError('E2021', 'object literal requires class context', expr.span)
      return VOID
    }
    let seen = new Set<string>()
    for (let prop of expr.properties) {
      let field = candidate.fields.get(prop.name)
      if (field === undefined) this.addError('E2022', 'unknown field ' + prop.name, prop.span)
      else this.checkExpression(prop.value, scope, field)
      if (seen.has(prop.name)) this.addError('E2023', 'duplicate property ' + prop.name, prop.span)
      seen.add(prop.name)
    }
    let fieldKeys = Array.from(candidate.fields.keys())
    for (let name of fieldKeys) {
      if (!seen.has(name)) this.addError('E2024', 'missing field ' + name, expr.span)
    }
    return candidate
  }

  private checkUnary(expr: UnaryExpression, scope: Scope): VeraType {
    let op = this.checkExpression(expr.operand, scope, null)
    if (expr.operator === '!') { this.requireType(op, BOOLEAN, expr.operand); return BOOLEAN }
    if (!identical(op, NUMBER)) this.addError('E2025', 'unary minus requires a number', expr.span)
    return op
  }

  private checkBinary(expr: BinaryExpression, scope: Scope): VeraType {
    let left = this.checkExpression(expr.left, scope, null)
    let right = this.checkExpression(expr.right, scope, null)
    let op = expr.operator
    if (op === '===' || op === '!==') {
      let nullPair = this.isNullableNullPair(left, right) || this.isNullableNullPair(right, left)
      let prim = left instanceof PrimitiveType && identical(left, right) && !identical(left, VOID)
      let fns = left instanceof VeraFunctionType && right instanceof VeraFunctionType && (subtypeOf(left, right) || subtypeOf(right, left))
      if (!nullPair && !prim && !fns) this.addError('E2026', 'unsupported equality operands', expr.span)
      return BOOLEAN
    }
    if (op === '&&' || op === '||') {
      this.requireType(left, BOOLEAN, expr.left)
      this.requireType(right, BOOLEAN, expr.right)
      return BOOLEAN
    }
    if (op === '<' || op === '<=' || op === '>' || op === '>=') {
      if ((!identical(left, NUMBER) && !identical(left, STRING)) || !identical(left, right)) {
        this.addError('E2027', 'relational operands must both be numbers or both be strings', expr.span)
      }
      return BOOLEAN
    }
    if (!identical(left, right)) this.addError('E2028', 'arithmetic operands must have identical types', expr.span)
    let valid = identical(left, NUMBER) || (op === '+' && identical(left, STRING))
    if (!valid) this.addError('E2029', 'operator ' + op + ' is invalid for ' + left.display(), expr.span)
    return left
  }

  private checkSelect(expr: SelectExpression, scope: Scope): VeraType {
    let target = this.checkExpression(expr.target, scope, null)
    if (target instanceof NamespaceType) {
      let m = target.members.get(expr.field)
      if (m === undefined) this.addError('E2030', 'namespace has no member ' + expr.field, expr.span)
      return m !== undefined ? m : VOID
    }
    if ((target instanceof VeraArrayType || identical(target, STRING)) && expr.field === 'length') {
      return new VeraFunctionType([], NUMBER, false, 'intrinsic:length')
    }
    // s.toUpperCase() and s.toLowerCase(), the way TypeScript writes them: the
    // model reaches for the method, and "field selection requires class" sent
    // a whole repair round after it. Compiled as the std/strings calls.
    if (identical(target, STRING) && STRING_METHODS.indexOf(expr.field) >= 0) {
      return new VeraFunctionType([], STRING, false, 'intrinsic:' + expr.field)
    }
    // Array growth as intrinsics rather than a std module: the element type
    // comes from the receiver, so these are polymorphic for free, whereas an
    // ExternalFunction carries concrete types and would need one entry per
    // element type -- unbounded, since element types include user classes.
    if (target instanceof VeraArrayType) {
      let element = (target as VeraArrayType).element
      if (expr.field === 'push') {
        // Returns the new length, as in JavaScript. It also has to leave one
        // value behind: every expression statement emits a pop after it.
        return new VeraFunctionType([element], NUMBER, false, 'intrinsic:push')
      }
      if (expr.field === 'pop') {
        return new VeraFunctionType([], element, false, 'intrinsic:pop')
      }
    }
    if (target instanceof VeraClassType) {
      let f = target.fields.get(expr.field)
      if (f === undefined) this.addError('E2031', 'class ' + target.name + ' has no field ' + expr.field, expr.span)
      return f !== undefined ? f : VOID
    }
    if (target instanceof NullableType) this.addError('E2032', 'nullable value must be narrowed before field access', expr.span)
    else this.addError('E2033', 'field selection requires class, array, string, or namespace', expr.span)
    return VOID
  }

  private checkCall(expr: CallExpression, scope: Scope, awaited: boolean): VeraType {
    let callee = this.checkExpression(expr.callee, scope, null)
    if (!(callee instanceof VeraFunctionType)) { this.addError('E2034', 'callee is not a function', expr.callee.span); return VOID }
    if (callee.isAsync !== awaited) this.addError('E2035', callee.isAsync ? 'async call must be awaited' : 'synchronous call cannot be awaited', expr.span)
    if (expr.argumentsList.length < callee.required ||
        expr.argumentsList.length > callee.parameters.length) {
      let want = callee.required === callee.parameters.length
        ? callee.parameters.length.toString()
        : callee.required.toString() + ' to ' + callee.parameters.length.toString()
      this.addError('E2036', 'expected ' + want + ' arguments, found ' +
        expr.argumentsList.length, expr.span)
    }
    for (let i = 0; i < expr.argumentsList.length; i++) {
      let param = i < callee.parameters.length ? callee.parameters[i] : null
      this.checkExpression(expr.argumentsList[i], scope, param)
    }
    this.checkStyleArguments(expr, callee)
    this.checkComposition(expr, callee)
    this.checkSdkArguments(expr, callee)
    this.checkGfxArguments(expr, callee)
    return callee.result
  }

  /**
   * The composition rules in VeraUiCatalog's CHILD_RULES, where the source
   * shows enough to check them.
   *
   * These are design rules rather than type rules -- a ListGroup full of Cards
   * type-checks perfectly and draws precisely the thing ListGroup was added to
   * replace. They are caught here and not in the renderer because a compile
   * error is handed back to the model and fixed on the next attempt, while
   * anything the renderer notices is seen only by whoever is watching.
   *
   * Literal children only. A list built by a loop -- which is how every real
   * list is built -- cannot be read here and passes, the same limitation
   * checkStyleArguments has. That is the prompt's half of the job.
   */
  private checkComposition(expr: CallExpression, callee: VeraFunctionType): void {
    const prefix = 'external:std/ui:'
    if (!callee.identity.startsWith(prefix)) return
    let name = callee.identity.substring(prefix.length)
    let rule: ChildRule | null = childRuleFor(name)
    if (rule === null) return

    if (rule!.allowed.length > 0) {
      for (let spec of CATALOG) {
        if (spec.name !== name) continue
        for (let i = 0; i < spec.props.length && i < expr.argumentsList.length; i++) {
          if (spec.props[i].kind !== 'view[]') continue
          let arg = expr.argumentsList[i]
          if (!(arg instanceof ArrayExpression)) break
          for (let element of (arg as ArrayExpression).elements) {
            // Only a child we can positively name is judged. Anything else --
            // a variable, a call that returns a View -- is unknowable here and
            // is left alone rather than guessed at.
            let childName = this.uiComponentName(element)
            if (childName.length === 0) continue
            if (rule!.allowed.indexOf(childName) < 0) {
              this.addError('E2107', name + ' takes only ' + listWords(rule!.allowed) +
                ' children, not ' + childName, element.span)
            }
          }
          break
        }
        break
      }
    }

    for (let bad of rule!.refusedInside) {
      for (let arg of expr.argumentsList) {
        let found = this.findUiDescendant(arg, bad)
        if (found !== null) {
          this.addError('E2107', name + ' may not contain another ' + bad, found!.span)
          break
        }
      }
    }
  }

  /**
   * The std/ui component a literal `ui.Name(...)` names, or '' when the call is
   * not one.
   *
   * Read off the syntax rather than the types, because the arguments have
   * already been checked by the time this runs and checking them again would
   * report every mistake in them twice. The field name alone is enough: a
   * program cannot declare a namespace of its own, and no member of std/time,
   * std/math, std/strings or std/sdk shares a name with a
   * component.
   */
  private uiComponentName(expr: Expression): string {
    if (!(expr instanceof CallExpression)) return ''
    let callee = (expr as CallExpression).callee
    if (!(callee instanceof SelectExpression)) return ''
    let field = (callee as SelectExpression).field
    if (field === 'When') return 'When'
    for (let spec of CATALOG) { if (spec.name === field) return field }
    return ''
  }

  /** The first `ui.<name>` call anywhere below this expression, or null. */
  private findUiDescendant(expr: Expression, name: string): Expression | null {
    if (expr instanceof ArrayExpression) {
      for (let element of (expr as ArrayExpression).elements) {
        let found = this.findUiDescendant(element, name)
        if (found !== null) return found
      }
      return null
    }
    if (expr instanceof CallExpression) {
      if (this.uiComponentName(expr) === name) return expr
      for (let arg of (expr as CallExpression).argumentsList) {
        let found = this.findUiDescendant(arg, name)
        if (found !== null) return found
      }
    }
    return null
  }

  /**
   * Icons and handler signatures for a std/ui call. Style names are not
   * checked here: one outside its set is drawn in the set's default style
   * (resolveStyle, applied when the tree is decoded), because refusing it cost
   * a whole generation attempt over something cosmetic.
   */
  private checkStyleArguments(expr: CallExpression, callee: VeraFunctionType): void {
    const prefix = 'external:std/ui:'
    if (!callee.identity.startsWith(prefix)) return
    let name = callee.identity.substring(prefix.length)
    for (let spec of CATALOG) {
      if (spec.name !== name) continue
      this.checkIconArguments(expr, spec)
      this.checkHandlerSignature(expr, spec)
      if (spec.nodeKind === 'surface') this.checkSurfaceFunctions(expr, spec)
      return
    }
  }

  /**
   * An icon name outside the set draws nothing, which on screen is
   * indistinguishable from the renderer having failed. Same closed-set
   * treatment as a style, and the same limit: only a literal is checked.
   */
  private checkIconArguments(expr: CallExpression, spec: ComponentSpec): void {
    for (let i = 0; i < spec.props.length && i < expr.argumentsList.length; i++) {
      if (spec.props[i].kind !== 'icon') continue
      let arg = expr.argumentsList[i]
      if (!(arg instanceof StringExpression)) continue
      let value = (arg as StringExpression).value
      // '' is how a component that takes an icon is told not to draw one.
      if (value.length === 0) continue
      if (iconPath(value).length === 0) {
        this.addError('E2108', 'unknown icon "' + value + '"; the icons are: ' +
          iconNames().join(' '), arg.span)
      }
    }
  }

  /**
   * A colour std/gfx does not know is drawn in ink, which on a dark scene is a shape that vanished, and an align
   * outside the three is drawn left. Only a literal is checked, as with icons.
   */
  private checkGfxArguments(expr: CallExpression, callee: VeraFunctionType): void {
    const prefix = 'external:std/gfx:'
    if (!callee.identity.startsWith(prefix)) return
    let f = gfxFunction(callee.identity.substring(prefix.length))
    if (f === null) return
    for (let i = 0; i < f.params.length && i < expr.argumentsList.length; i++) {
      let arg = expr.argumentsList[i]
      if (f.params[i].kind === 'colors' && arg instanceof ArrayExpression) {
        let elements = (arg as ArrayExpression).elements
        if (elements.length < 2) {
          this.addError('E2112', 'a gradient needs at least two colours, from the first to the last', arg.span)
        }
        for (let element of elements) {
          if (element instanceof StringExpression && !isGfxColor((element as StringExpression).value)) {
            this.addError('E2112', 'unknown colour "' + (element as StringExpression).value + '" in a gradient; a colour is one of ' +
              GFX_ROLES.join(' ') + ', or "#rrggbb" / "#rrggbbaa"', element.span)
          }
        }
        continue
      }
      if (!(arg instanceof StringExpression)) continue
      let value = (arg as StringExpression).value
      if (f.params[i].kind === 'color' && !isGfxColor(value)) {
        this.addError('E2112', 'unknown colour "' + value + '"; a colour is one of ' + GFX_ROLES.join(' ') +
          ', or "#rrggbb" / "#rrggbbaa", or gfx.rgb(red, green, blue), gfx.linear(...), gfx.radial(...)', arg.span)
      } else if (f.name === 'drift' && f.params[i].name === 'direction' && DRIFT_DIRECTIONS.indexOf(value) < 0) {
        this.addError('E2112', 'gfx.drift direction is ' + DRIFT_DIRECTIONS.map((d: string): string => '"' + d + '"').join(', ') + '; got "' + value + '"', arg.span)
      } else if (f.name === 'drift' && f.params[i].name === 'speed' && DRIFT_SPEEDS.indexOf(value) < 0) {
        this.addError('E2112', 'gfx.drift speed is ' + DRIFT_SPEEDS.map((d: string): string => '"' + d + '"').join(', ') + '; got "' + value + '"', arg.span)
      } else if (f.params[i].name === 'motion' && MOTION_PRESETS.indexOf(value) < 0) {
        this.addError('E2112', 'gfx.moving takes a ui.Motion style: ' + MOTION_PRESETS.join(', ') + '; got "' + value + '"', arg.span)
      } else if (f.name === 'blend' && f.params[i].name === 'mode' && GFX_BLEND_MODES.indexOf(value) < 0) {
        this.addError('E2112', 'gfx.blend mode is ' + GFX_BLEND_MODES.map((m: string): string => '"' + m + '"').join(', ') + '; got "' + value + '"', arg.span)
      } else if (f.params[i].name === 'align' && ['left', 'center', 'right'].indexOf(value) < 0) {
        this.addError('E2112', 'align is "left", "center" or "right"; got "' + value + '"', arg.span)
      }
    }
  }

  /**
   * A ui.Surface names three functions: what it draws, what happens each frame, and what a finger does. Each is
   * only a string in the tree until the renderer calls it sixty times a second, so a wrong signature is caught
   * here rather than as a trap on the first frame. "" means none, except for draw: a surface draws something.
   */
  private checkSurfaceFunctions(expr: CallExpression, spec: ComponentSpec): void {
    for (let i = 0; i < spec.props.length && i < expr.argumentsList.length; i++) {
      let role = spec.props[i].name
      if (role !== 'draw' && role !== 'frame' && role !== 'pointer') continue
      let arg = expr.argumentsList[i]
      if (!(arg instanceof StringExpression)) continue
      let name = (arg as StringExpression).value
      if (name.length === 0) {
        if (role === 'draw') this.addError('E2106', 'a ui.Surface needs a draw function: function draw(state: AppState): gfx.Shape[]', arg.span)
        continue
      }
      let fn = this.model.functions.get(name)
      if (fn === undefined) {
        if (!this.options.allowMissingHandlers) { this.addError('E2106', 'no function named "' + name + '"', arg.span) }
        continue
      }
      if (role === 'draw') {
        let result = fn.result
        let ok = fn.parameters.length === 1 && result instanceof VeraArrayType &&
          (result as VeraArrayType).element instanceof VeraClassType &&
          ((result as VeraArrayType).element as VeraClassType).identity === 'std/gfx:Shape'
        if (!ok) {
          this.addError('E2106', 'ui.Surface draws what "' + name + '" returns, so it must be function ' + name +
            '(state: AppState): gfx.Shape[]', arg.span)
        }
      } else if (role === 'frame') {
        if (fn.parameters.length !== 2 || !identical(fn.parameters[1], NUMBER)) {
          this.addError('E2106', 'ui.Surface hands "' + name + '" the milliseconds since the last frame, so it must take (state, elapsedMs: number)', arg.span)
        }
      } else {
        let p = fn.parameters.length === 2 ? fn.parameters[1] : null
        let ok = p !== null && p instanceof VeraClassType && (p as VeraClassType).identity === 'std/gfx:Pointer'
        if (!ok) {
          this.addError('E2106', 'ui.Surface hands "' + name + '" a finger, so it must take (state, p: gfx.Pointer)', arg.span)
        }
      }
    }
  }

  /**
   * sdk.call covers two target shapes (VeraCompiler.buildStdSdkModule): an
   * intent address (bundle/module/ability/IntentName or, to just launch the
   * target, bundle/module/ability -- slash-separated and device-only, so only
   * the shape can be checked) or an sdk index entry (kit.module.name,
   * dot-separated, a static artifact built offline from interface_sdk-js, so
   * checked against a real closed set built by tools/build-sdk-index.py).
   * Told apart by whether the literal target has a slash in it -- the same
   * test a person would use reading it.
   *
   * An sdk-style target the model invented instead of calling
   * find_sdk_function is a compile error here (E2110) -- the existing retry
   * loop (GeneratePage.runAttempt) gives it a chance to call the tool
   * instead. An intent-style target has no such closed set to check against
   * (the registry is read from the device, not a static artifact), so an
   * invented one only fails silently on the phone.
   */
  private checkSdkArguments(expr: CallExpression, callee: VeraFunctionType): void {
    if (callee.identity !== 'external:std/sdk:call') return
    if (expr.argumentsList.length > 0 && expr.argumentsList[0] instanceof StringExpression) {
      let arg = expr.argumentsList[0]
      let target = (arg as StringExpression).value
      if (target.indexOf('/') >= 0) {
        let parts = target.split('/')
        let empty = false
        for (let part of parts) { if (part.trim().length === 0) { empty = true } }
        if ((parts.length !== 4 && parts.length !== 3) || empty) {
          this.addError('E2109', 'an intent-style sdk.call target must be ' +
            '"bundle/module/ability/IntentName", or "bundle/module/ability" to just launch it; got "' +
            target + '"', arg.span)
        }
      } else if (target !== 'Vera.Live.fetch' && target !== 'Vera.Source.fetch' && target !== 'Vera.Ask.text' && !isValidSdkTarget(target)) {
        // The host functions that are not SDK entries (VeraLive.ets, VeraSource.ets, VeraAsk.ets); any other made-up "Vera." address is still refused.
        this.addError('E2110', 'sdk.call target "' + target + '" is not one find_sdk_function ' +
          'returned; call it first and use a target exactly as it came back', arg.span)
      }
    }
    // A live source's address and paths (VeraSource.ets), and a live search's query (VeraLive.ets), are the ones given at
    // generation: written out, never built from the state, so nothing the program keeps can go out in an address or a query.
    let liveTarget = expr.argumentsList.length > 0 && expr.argumentsList[0] instanceof StringExpression ?
      (expr.argumentsList[0] as StringExpression).value : ''
    if (liveTarget === 'Vera.Source.fetch' || liveTarget === 'Vera.Live.fetch') {
      let params = expr.argumentsList.length > 1 ? expr.argumentsList[1] : null
      let literal = params instanceof ArrayExpression &&
        (params as ArrayExpression).elements.every((item: Expression): boolean => item instanceof StringExpression)
      if (!literal) {
        this.addError('E2114', liveTarget + ' takes its parameters as written-out strings only: copy them exactly as given, ' +
          'never build them from variables or the state', (params ?? expr).span)
      }
    }
    if (expr.argumentsList.length > 1 && expr.argumentsList[1] instanceof ArrayExpression) {
      let arg = expr.argumentsList[1]
      let items = (arg as ArrayExpression).elements
      if (items.length % 2 !== 0) {
        this.addError('E2111', 'sdk.call parameters are name and value in pairs, so the ' +
          'array must have an even number of items; got ' + items.length.toString(), arg.span)
      }
      for (let i = 0; i + 1 < items.length; i = i + 2) {
        if (!(items[i] instanceof StringExpression)) { continue }
        if ((items[i] as StringExpression).value.trim().length === 0) {
          this.addError('E2111', 'sdk.call parameter names cannot be empty', items[i].span)
        }
      }
    }
    // Trailing and optional: only meaningful for an intent-style target, but
    // checked whenever it's written, since a stray "forground" typo is worth
    // catching even if the target turns out to be an sdk one.
    if (expr.argumentsList.length > 3 && expr.argumentsList[3] instanceof StringExpression) {
      let arg = expr.argumentsList[3]
      let mode = (arg as StringExpression).value
      if (mode !== 'foreground' && mode !== 'background') {
        this.addError('E2109', 'sdk.call mode must be "foreground" or "background"; got "' +
          mode + '"', arg.span)
      }
    }
    if (expr.argumentsList.length < 3 || !(expr.argumentsList[2] instanceof StringExpression)) return
    let arg = expr.argumentsList[2]
    let handlerName = (arg as StringExpression).value
    let fn = this.model.functions.get(handlerName)
    if (fn === undefined) {
      if (!this.options.allowMissingHandlers) { this.addError('E2106', 'no handler named "' + handlerName + '"', arg.span) }
      return
    }
    if (fn.parameters.length < 2 || !identical(fn.parameters[1], STRING)) {
      this.addError('E2106', 'sdk.call answers with a string, so "' + handlerName +
        '" must take (state, value: string)', arg.span)
    }
  }

  /**
   * A component that produces a value hands its handler that value, so the
   * handler's second parameter has to match. Without this the mismatch surfaces
   * as a runtime trap on the first keystroke, long after the program looked
   * finished -- and the retry loop never sees it, because compilation passed.
   *
   * Only a literal handler name is checked; a computed one cannot be resolved
   * here and is left alone.
   */
  private checkHandlerSignature(expr: CallExpression, spec: ComponentSpec): void {
    let payload = payloadKindFor(spec.nodeKind)
    if (payload.length === 0) return
    for (let i = 0; i < spec.props.length && i < expr.argumentsList.length; i++) {
      if (spec.props[i].name !== 'action') continue
      let arg = expr.argumentsList[i]
      if (!(arg instanceof StringExpression)) return
      let handlerName = (arg as StringExpression).value
      // No action: a banner or an empty state with nothing to tap passes "".
      if (handlerName.length === 0) return
      let fn = this.model.functions.get(handlerName)
      if (fn === undefined) {
        if (!this.options.allowMissingHandlers) { this.addError('E2106', 'no handler named "' + handlerName + '"', arg.span) }
        return
      }
      let want: VeraType = payload === 'string' ? STRING : payload === 'boolean' ? BOOLEAN : NUMBER
      if (fn.parameters.length < 2 || !identical(fn.parameters[1], want)) {
        this.addError('E2106', spec.name + ' hands its handler a ' + payload + ', so "' +
          handlerName + '" must take (state, value: ' + payload + ')', arg.span)
      }
      return
    }
  }

  private checkLambda(expr: LambdaExpression, parent: Scope): VeraType {
    let params: VeraType[] = []
    for (let p of expr.parameters) params.push(this.resolveType(p.type))
    let result = this.resolveType(expr.returnType)
    let type = new VeraFunctionType(params, result, false, 'lambda:' + this.lambdaCount++)
    let scope = new Scope(parent)
    for (let i = 0; i < expr.parameters.length; i++) {
      let p = expr.parameters[i]
      if (scope.find(p.name) !== null) this.addError('E2004', 'declaration ' + p.name + ' shadows a visible entity', p.span)
      else { scope.values.set(p.name, params[i]); scope.readOnly.add(p.name) }
    }
    let oldRet = this.returnType
    let oldAsync = this.inAsyncFunction
    this.returnType = result
    this.inAsyncFunction = false
    let returns = this.checkBlock(expr.body, scope)
    this.returnType = oldRet
    this.inAsyncFunction = oldAsync
    if (!identical(result, VOID) && !returns) this.addError('E2018', 'lambda must return a value', expr.body.span)
    return type
  }

  private narrow(expr: Expression, scope: Scope): Narrowing {
    let yes = new Scope(scope)
    let no = new Scope(scope)
    if (expr instanceof BinaryExpression) {
      let op = expr.operator
      if (op !== '===' && op !== '!==') return new Narrowing(yes, no)
      let nameExpr: NameExpression | null = null
      if (expr.left instanceof NameExpression && expr.right instanceof NullExpression) nameExpr = expr.left
      else if (expr.right instanceof NameExpression && expr.left instanceof NullExpression) nameExpr = expr.right
      if (nameExpr !== null) {
        let type = scope.find(nameExpr.name)
        if (type !== null && type instanceof NullableType) {
          let narrowedScope = op === '!==' ? yes : no
          narrowedScope.values.set(nameExpr.name, type.base)
          if (scope.isReadOnly(nameExpr.name)) narrowedScope.readOnly.add(nameExpr.name)
        }
      }
    }
    return new Narrowing(yes, no)
  }

  resolveType(node: TypeNode): VeraType {
    let existing = this.model.declaredTypes.get(node)
    if (existing !== undefined) return existing
    let type: VeraType
    if (node.name === 'int') {
      // Habit from other languages; said plainly so the repair is one word.
      this.addError('E2042', 'there is no int type; use number', node.span)
      type = NUMBER
    }
    else if (node.name === 'number') type = NUMBER
    else if (node.name === 'boolean') type = BOOLEAN
    else if (node.name === 'string') type = STRING
    else if (node.name === 'void') type = VOID
    else if (node.name === 'array') type = new VeraArrayType(this.resolveType(node.parts[0]))
    else if (node.name === 'function' || node.name === 'async-function') {
      let pieces: VeraType[] = []
      for (let p of node.parts) pieces.push(this.resolveType(p))
      type = new VeraFunctionType(pieces.slice(0, -1), pieces[pieces.length - 1], node.name === 'async-function', 'function-type')
    } else type = this.resolveNamedType(node.name, node)
    if (node.nullable) {
      if (identical(type, VOID)) this.addError('E2037', 'void cannot be nullable', node.span)
      type = new NullableType(type)
    }
    this.model.declaredTypes.set(node, type)
    return type
  }

  private resolveNamedType(name: string, node: TypeNode): VeraType {
    let pieces = name.split('.')
    let value: VeraType | null = this.globals.find(pieces[0])
    if (value === null && pieces.length > 1) value = this.preludeNamespace(pieces[0])
    for (let i = 1; i < pieces.length; i++) {
      if (value instanceof NamespaceType) {
        let m = value.members.get(pieces[i])
        value = m !== undefined ? m : null
      } else {
        value = null
      }
    }
    if (!(value instanceof VeraClassType)) { this.addError('E2038', 'unknown class type ' + name, node.span); return VOID }
    return value
  }

  private isNullableNullPair(a: VeraType, b: VeraType): boolean {
    return a instanceof NullableType && b instanceof VeraNullType
  }

  private requireType(actual: VeraType, expected: VeraType, expr: Expression): void {
    if (!identical(actual, expected)) this.typeError(expr, expected, actual)
  }

  private typeError(expr: Expression, expected: VeraType, actual: VeraType): void {
    this.diagnostics.push(new Diagnostic('E2019', 'expected ' + expected.display() + ', found ' + actual.display(), expr.span, expected.display(), actual.display()))
  }

  private addError(code: string, message: string, span: Span): void {
    this.diagnostics.push(new Diagnostic(code, message, span))
  }
}

// ===== Bytecode Compilation =====

class Binding {
  location: string
  slot: number
  constructor(location: string, slot: number) { this.location = location; this.slot = slot }
}

class LoopLabels {
  breaks: number[]
  continues: number[]
  continueTarget: number
  constructor(breaks: number[], continues: number[], continueTarget: number) {
    this.breaks = breaks; this.continues = continues; this.continueTarget = continueTarget
  }
}

class FunctionBuilder {
  instructions: Instruction[] = []
  /** The source line each instruction came from, for a runtime error to name. */
  lines: number[] = []
  line: number = 0
  bindings: Map<string, Binding> = new Map<string, Binding>()
  capturedBindings: Map<string, number> = new Map<string, number>()
  loops: LoopLabels[] = []
  localCount: number = 0
  name: string
  parent: FunctionBuilder | null

  constructor(name: string, parent: FunctionBuilder | null) {
    this.name = name; this.parent = parent
  }

  emit(inst: Instruction): number {
    this.instructions.push(inst)
    this.lines.push(this.line)
    return this.instructions.length - 1
  }

  local(name: string): number {
    let slot = this.localCount++
    this.bindings.set(name, new Binding('local', slot))
    return slot
  }
}

function mkInst(op: string): Instruction { return new Instruction(op) }

function mkPushNumber(v: number): Instruction { let i = mkInst('push-number'); i.numValue = v; return i }
function mkPushString(v: string): Instruction { let i = mkInst('push-string'); i.value = v; return i }
function mkPushBoolean(v: boolean): Instruction { let i = mkInst('push-boolean'); i.boolValue = v; return i }
function mkLoadLocal(slot: number): Instruction { let i = mkInst('load-local'); i.slot = slot; return i }
function mkStoreLocal(slot: number): Instruction { let i = mkInst('store-local'); i.slot = slot; return i }
function mkLoadCapture(slot: number): Instruction { let i = mkInst('load-capture'); i.slot = slot; return i }
function mkStoreCapture(slot: number): Instruction { let i = mkInst('store-capture'); i.slot = slot; return i }
function mkLoadFunction(name: string): Instruction { let i = mkInst('load-function'); i.name = name; return i }
function mkLoadExternal(mod: string, name: string): Instruction { let i = mkInst('load-external'); i.module = mod; i.name = name; return i }
function mkUnary(op: string): Instruction { let i = mkInst('unary'); i.operator = op; return i }
function mkBinary(op: string): Instruction { let i = mkInst('binary'); i.operator = op; return i }
function mkJump(target: number): Instruction { let i = mkInst('jump'); i.target = target; return i }
function mkJumpIfFalse(target: number): Instruction { let i = mkInst('jump-if-false'); i.target = target; return i }
function mkCall(count: number, awaited: boolean): Instruction { let i = mkInst('call'); i.count = count; i.awaited = awaited; return i }
function mkMakeArray(count: number): Instruction { let i = mkInst('make-array'); i.count = count; return i }
function mkMakeObject(classIdentity: string, fields: string[]): Instruction {
  let i = mkInst('make-object'); i.classIdentity = classIdentity; i.fields = fields; return i
}
function mkLoadField(name: string): Instruction { let i = mkInst('load-field'); i.name = name; return i }
function mkStoreField(name: string): Instruction { let i = mkInst('store-field'); i.name = name; return i }
function mkMakeClosure(functionName: string, captures: number[]): Instruction {
  let i = mkInst('make-closure'); i.functionName = functionName; i.captures = captures; return i
}

class BytecodeCompiler {
  private functions: BytecodeFunction[] = []
  private lambdaCount: number = 0
  private model: SemanticModel

  constructor(model: SemanticModel) { this.model = model }

  compile(): BytecodeModule {
    for (let decl of this.model.application.declarations) {
      if (decl instanceof FunctionDeclaration) this.compileFunction(decl)
    }
    let entries: string[] = []
    let fnKeys = Array.from(this.model.functions.keys())
    for (let name of fnKeys) entries.push(name)
    return new BytecodeModule(this.functions, entries)
  }

  private compileFunction(decl: FunctionDeclaration): void {
    let b = new FunctionBuilder(decl.name, null)
    for (let p of decl.parameters) b.local(p.name)
    this.block(decl.body, b)
    b.emit(mkInst('push-null'))
    b.emit(mkInst('return'))
    this.functions.push(new BytecodeFunction(decl.name, decl.parameters.length, b.localCount, decl.isAsync, b.instructions, b.lines))
  }

  private block(block: BlockStatement, b: FunctionBuilder): void {
    for (let s of block.statements) this.statement(s, b)
  }

  private statement(stmt: Statement, b: FunctionBuilder): void {
    let outer = b.line
    b.line = stmt.span.start.line
    this.statementAt(stmt, b)
    b.line = outer
  }

  private statementAt(stmt: Statement, b: FunctionBuilder): void {
    if (stmt instanceof BlockStatement) this.block(stmt, b)
    else if (stmt instanceof LetStatement) {
      this.expression(stmt.initializer, b)
      b.emit(mkStoreLocal(b.local(stmt.name)))
    }
    else if (stmt instanceof ExpressionStatement) {
      this.expression(stmt.expression, b)
      b.emit(mkInst('pop'))
    }
    else if (stmt instanceof AssignStatement) this.assignment(stmt, b)
    else if (stmt instanceof ReturnStatement) {
      if (stmt.value === null) b.emit(mkInst('push-null'))
      else this.expression(stmt.value, b)
      b.emit(mkInst('return'))
    }
    else if (stmt instanceof IfStatement) {
      this.expression(stmt.condition, b)
      let falseJump = b.emit(mkJumpIfFalse(-1))
      this.block(stmt.thenBranch, b)
      if (stmt.elseBranch !== null) {
        let endJump = b.emit(mkJump(-1))
        this.patch(b, falseJump, b.instructions.length)
        this.statement(stmt.elseBranch, b)
        this.patch(b, endJump, b.instructions.length)
      } else {
        this.patch(b, falseJump, b.instructions.length)
      }
    }
    else if (stmt instanceof WhileStatement) {
      let start = b.instructions.length
      this.expression(stmt.condition, b)
      let exit = b.emit(mkJumpIfFalse(-1))
      let loop = new LoopLabels([], [], start)
      b.loops.push(loop)
      this.block(stmt.body, b)
      b.line = stmt.span.start.line
      b.emit(mkJump(start))
      let end = b.instructions.length
      this.patch(b, exit, end)
      this.finishLoop(b, loop, end, true)
    }
    else if (stmt instanceof ForOfStatement) this.forOf(stmt, b)
    else if (stmt instanceof TryStatement) {
      this.block(stmt.tryBlock, b)
    }
    else if (stmt instanceof BreakStatement) {
      let loop = b.loops[b.loops.length - 1]
      loop.breaks.push(b.emit(mkJump(-1)))
    }
    else if (stmt instanceof ContinueStatement) {
      let loop = b.loops[b.loops.length - 1]
      loop.continues.push(b.emit(mkJump(-1)))
    }
  }

  private forOf(stmt: ForOfStatement, b: FunctionBuilder): void {
    let arraySlot = b.local('$array' + b.localCount)
    let indexSlot = b.local('$index' + b.localCount)
    let varSlot = b.local(stmt.name)
    this.expression(stmt.iterable, b)
    if (this.model.expressionTypes.get(stmt.iterable) === STRING) b.emit(mkInst('string-symbols'))
    b.emit(mkStoreLocal(arraySlot))
    b.emit(mkPushNumber(0))
    b.emit(mkStoreLocal(indexSlot))
    let start = b.instructions.length
    b.emit(mkLoadLocal(indexSlot))
    b.emit(mkLoadLocal(arraySlot))
    b.emit(mkInst('length'))
    b.emit(mkBinary('<'))
    let exit = b.emit(mkJumpIfFalse(-1))
    b.emit(mkLoadLocal(arraySlot))
    b.emit(mkLoadLocal(indexSlot))
    b.emit(mkInst('load-index'))
    b.emit(mkStoreLocal(varSlot))
    let loop = new LoopLabels([], [], -1)
    b.loops.push(loop)
    this.block(stmt.body, b)
    b.line = stmt.span.start.line
    let advance = b.instructions.length
    b.emit(mkLoadLocal(indexSlot))
    b.emit(mkPushNumber(1))
    b.emit(mkBinary('+'))
    b.emit(mkStoreLocal(indexSlot))
    b.emit(mkJump(start))
    let end = b.instructions.length
    this.patch(b, exit, end)
    let fixed = new LoopLabels(loop.breaks, loop.continues, advance)
    b.loops.pop()
    this.finishLoop(b, fixed, end, false)
  }

  private finishLoop(b: FunctionBuilder, loop: LoopLabels, end: number, pop: boolean): void {
    if (pop) b.loops.pop()
    for (let idx of loop.breaks) this.patch(b, idx, end)
    for (let idx of loop.continues) this.patch(b, idx, loop.continueTarget)
  }

  private assignment(stmt: AssignStatement, b: FunctionBuilder): void {
    let target = stmt.target
    if (target instanceof NameExpression) {
      this.expression(stmt.value, b)
      this.storeName(target.name, b)
    } else if (target instanceof IndexExpression) {
      this.expression(target.target, b)
      this.expression(target.index, b)
      this.expression(stmt.value, b)
      b.emit(mkInst('store-index'))
    } else if (target instanceof SelectExpression) {
      this.expression(target.target, b)
      this.expression(stmt.value, b)
      b.emit(mkStoreField(target.field))
    }
  }

  private expression(expr: Expression, b: FunctionBuilder): void {
    let outer = b.line
    b.line = expr.span.start.line
    this.expressionAt(expr, b)
    b.line = outer
  }

  private expressionAt(expr: Expression, b: FunctionBuilder): void {
    if (expr instanceof IntExpression) b.emit(mkPushNumber(expr.value))
    else if (expr instanceof NumberExpression) b.emit(mkPushNumber(expr.value))
    else if (expr instanceof StringExpression) b.emit(mkPushString(expr.value))
    else if (expr instanceof BooleanExpression) b.emit(mkPushBoolean(expr.value))
    else if (expr instanceof NullExpression) b.emit(mkInst('push-null'))
    else if (expr instanceof NameExpression) this.loadName(expr.name, b)
    else if (expr instanceof UnaryExpression) {
      this.expression(expr.operand, b)
      b.emit(mkUnary(expr.operator))
    }
    else if (expr instanceof BinaryExpression) this.binary(expr, b)
    else if (expr instanceof CallExpression) {
      if (expr.callee instanceof SelectExpression && expr.callee.field === 'push' && expr.argumentsList.length === 1 &&
        this.model.expressionTypes.get(expr.callee.target) instanceof VeraArrayType) {
        this.expression(expr.callee.target, b)
        this.expression(expr.argumentsList[0], b)
        b.emit(mkInst('array-push'))
      }
      else if (expr.callee instanceof SelectExpression && expr.callee.field === 'pop' && expr.argumentsList.length === 0 &&
        this.model.expressionTypes.get(expr.callee.target) instanceof VeraArrayType) {
        this.expression(expr.callee.target, b)
        b.emit(mkInst('array-pop'))
      }
      else if (expr.callee instanceof SelectExpression && expr.callee.field === 'length' && expr.argumentsList.length === 0) {
        this.expression(expr.callee.target, b)
        b.emit(mkInst('length'))
      }
      else if (expr.callee instanceof SelectExpression && STRING_METHODS.indexOf(expr.callee.field) >= 0 &&
        expr.argumentsList.length === 0 && this.model.expressionTypes.get(expr.callee.target) === STRING) {
        b.emit(mkLoadExternal('std/strings', expr.callee.field))
        this.expression(expr.callee.target, b)
        b.emit(mkCall(1, false))
      } else {
        this.call(expr, b, false)
      }
    }
    else if (expr instanceof AwaitExpression) {
      if (expr.operand instanceof CallExpression) this.call(expr.operand, b, true)
    }
    else if (expr instanceof ArrayExpression) {
      for (let el of expr.elements) this.expression(el, b)
      b.emit(mkMakeArray(expr.elements.length))
    }
    else if (expr instanceof ObjectExpression) {
      for (let prop of expr.properties) this.expression(prop.value, b)
      let type = this.model.expressionTypes.get(expr)
      let identity = type instanceof VeraClassType ? type.identity : 'invalid'
      let fields: string[] = []
      for (let p of expr.properties) fields.push(p.name)
      b.emit(mkMakeObject(identity, fields))
    }
    else if (expr instanceof IndexExpression) {
      this.expression(expr.target, b)
      this.expression(expr.index, b)
      b.emit(mkInst('load-index'))
    }
    else if (expr instanceof EnsureNotNullExpression) {
      this.expression(expr.operand, b)
      b.emit(mkInst('ensure-not-null'))
    }
    else if (expr instanceof SelectExpression) {
      if (expr.target instanceof NameExpression) {
        let imported = this.model.imports.get(expr.target.name)
        if (imported !== undefined && this.findBinding(expr.target.name, b) === null) {
          b.emit(mkLoadExternal(imported.specifier, expr.field))
          return
        }
      }
      this.expression(expr.target, b)
      b.emit(mkLoadField(expr.field))
    }
    else if (expr instanceof LambdaExpression) this.lambda(expr, b)
  }

  private binary(expr: BinaryExpression, b: FunctionBuilder): void {
    if (expr.operator === '&&') {
      this.expression(expr.left, b)
      let skip = b.emit(mkJumpIfFalse(-1))
      this.expression(expr.right, b)
      let end = b.emit(mkJump(-1))
      this.patch(b, skip, b.instructions.length)
      b.emit(mkPushBoolean(false))
      this.patch(b, end, b.instructions.length)
      return
    }
    if (expr.operator === '||') {
      this.expression(expr.left, b)
      b.emit(mkUnary('!'))
      let skip = b.emit(mkJumpIfFalse(-1))
      this.expression(expr.right, b)
      let end = b.emit(mkJump(-1))
      this.patch(b, skip, b.instructions.length)
      b.emit(mkPushBoolean(true))
      this.patch(b, end, b.instructions.length)
      return
    }
    this.expression(expr.left, b)
    this.expression(expr.right, b)
    b.emit(mkBinary(expr.operator))
  }

  private call(expr: CallExpression, b: FunctionBuilder, awaited: boolean): void {
    this.expression(expr.callee, b)
    for (let arg of expr.argumentsList) this.expression(arg, b)
    b.emit(mkCall(expr.argumentsList.length, awaited))
  }

  private lambda(expr: LambdaExpression, parent: FunctionBuilder): void {
    let name = '$lambda' + this.lambdaCount++
    let child = new FunctionBuilder(name, parent)
    for (let p of expr.parameters) child.local(p.name)
    this.block(expr.body, child)
    child.emit(mkInst('push-null'))
    child.emit(mkInst('return'))
    let captures: number[] = []
    let captureValues = Array.from(child.capturedBindings.values())
    for (let v of captureValues) captures.push(v)
    this.functions.push(new BytecodeFunction(name, expr.parameters.length, child.localCount, false, child.instructions, child.lines))
    parent.emit(mkMakeClosure(name, captures))
  }

  private loadName(name: string, b: FunctionBuilder): void {
    let binding = b.bindings.get(name)
    if (binding !== undefined) {
      if (binding.location === 'local') b.emit(mkLoadLocal(binding.slot))
      else b.emit(mkLoadCapture(binding.slot))
      return
    }
    if (this.model.functions.has(name)) { b.emit(mkLoadFunction(name)); return }
    let pieces = name.split('.')
    if (pieces.length >= 2) {
      let imported = this.model.imports.get(pieces[0])
      if (imported !== undefined) {
        b.emit(mkLoadExternal(imported.specifier, pieces[1]))
        return
      }
    }
    let parent = b.parent
    if (parent !== null) {
      // The variable lives in an enclosing function. Capture it here, and thread
      // the capture through every level between b and the owner: the owner is the
      // builder walking up whose bindings already name it. A deep capture
      // encoded straight from the owner's slot would be read from this frame's
      // local/captures at make-closure time, so each level in between has to
      // carry the variable itself for th depth-1 encoding to compose.
      let chain: FunctionBuilder[] = []
      let cur: FunctionBuilder | null = parent
      while (cur !== null && !cur.bindings.has(name)) {
        chain.push(cur)
        cur = cur.parent
      }
      if (cur !== null) {
        let ownerBinding = cur.bindings.get(name)
        if (ownerBinding !== undefined) {
          let captureIdx = ownerBinding.location === 'local' ? ownerBinding.slot : -ownerBinding.slot - 1
          for (let i = chain.length -1; i >= 0; --i) {
            let level = chain[i]
            let levelSlot = level.capturedBindings.size
            level.capturedBindings.set(name, captureIdx)
            level.bindings.set(name, new Binding('capture', levelSlot))
            captureIdx = -levelSlot - 1

          }
          let slot = b.capturedBindings.size
          b.capturedBindings.set(name, captureIdx)
          b.bindings.set(name, new Binding('capture', slot))
          b.emit(mkLoadCapture(slot))
          return
        }
      }
    }
    b.emit(mkLoadFunction(name))
  }

  private storeName(name: string, b: FunctionBuilder): void {
    let binding = b.bindings.get(name)
    if (binding === undefined) throw new Error('compiler invariant')
    if (binding.location === 'local') b.emit(mkStoreLocal(binding.slot))
    else b.emit(mkStoreCapture(binding.slot))
  }

  private findBinding(name: string, b: FunctionBuilder): Binding | null {
    let found = b.bindings.get(name)
    if (found !== undefined) return found
    if (b.parent !== null) return this.findBinding(name, b.parent)
    return null
  }

  private patch(b: FunctionBuilder, index: number, target: number): void {
    let inst = b.instructions[index]
    if (inst.op === 'jump-if-false') {
      let newInst = mkJumpIfFalse(target)
      b.instructions[index] = newInst
    } else {
      let newInst = mkJump(target)
      b.instructions[index] = newInst
    }
  }
}

// ===== VBC2 Serialization =====

function encodeInstruction(inst: Instruction): Object[] {
  let op = inst.op
  switch (op) {
    case 'push-number': return [op, inst.numValue]
    case 'push-string': return [op, inst.value]
    case 'push-boolean': return [op, inst.boolValue]
    case 'push-null': return [op]
    case 'load-local': return [op, inst.slot]
    case 'store-local': return [op, inst.slot]
    case 'load-capture': return [op, inst.slot]
    case 'store-capture': return [op, inst.slot]
    case 'load-function': return [op, inst.name]
    case 'load-external': return [op, inst.module, inst.name]
    case 'pop': return [op]
    case 'duplicate': return [op]
    case 'unary': return [op, inst.operator]
    case 'binary': return [op, inst.operator]
    case 'jump': return [op, inst.target]
    case 'jump-if-false': return [op, inst.target]
    case 'call': return [op, inst.count, inst.awaited]
    case 'return': return [op]
    case 'make-array': return [op, inst.count]
    case 'array-push': return [op]
    case 'array-pop': return [op]
    case 'length': return [op]
    case 'string-symbols': return [op]
    case 'ensure-not-null': return [op]
    case 'load-index': return [op]
    case 'store-index': return [op]
    case 'make-object': return [op, inst.classIdentity, inst.fields]
    case 'load-field': return [op, inst.name]
    case 'store-field': return [op, inst.name]
    case 'make-closure': return [op, inst.functionName, inst.captures]
    default: return [op]
  }
}

function serializeVbc2(module: BytecodeModule): string {
  let functions: Object[] = []
  for (let fn of module.functions) {
    let instrs: Object[] = []
    for (let inst of fn.instructions) instrs.push(encodeInstruction(inst))
    functions.push([fn.name, fn.parameterCount, fn.localCount, fn.isAsync, instrs, fn.lines])
  }
  return JSON.stringify(['VBC2', module.entryCandidates, functions])
}

// ===== Fields nothing reads =====

/**
 * The fields of the app's state (the class init() returns) that no code reads. A handler hands the state on field by field
 * ({a: state.a, b: value}); that is not a read. A read is any other use of `.field`: in view(), in a formula, a condition, a call.
 * A field only a setter writes is an input the person can fill in that changes nothing.
 */
function unreadStateFields(app: Application): string[] {
  let stateName = ''
  for (let d of app.declarations) {
    if (d instanceof FunctionDeclaration && (d as FunctionDeclaration).name === 'init') { stateName = (d as FunctionDeclaration).returnType.name }
  }
  let fields: string[] = []
  for (let d of app.declarations) {
    if (d instanceof ClassDeclaration && (d as ClassDeclaration).name === stateName) {
      for (let f of (d as ClassDeclaration).fields) { fields.push(f.name) }
    }
  }
  let read = new Set<string>()
  let walkExpr = (e: Expression): void => {}
  let walkStmt = (st: Statement): void => {}
  walkExpr = (e: Expression): void => {
    if (e instanceof SelectExpression) {
      let sel = e as SelectExpression
      read.add(sel.field)
      walkExpr(sel.target)
    } else if (e instanceof UnaryExpression) { walkExpr((e as UnaryExpression).operand) }
    else if (e instanceof BinaryExpression) { walkExpr((e as BinaryExpression).left); walkExpr((e as BinaryExpression).right) }
    else if (e instanceof CallExpression) {
      walkExpr((e as CallExpression).callee)
      for (let a of (e as CallExpression).argumentsList) { walkExpr(a) }
    } else if (e instanceof IndexExpression) { walkExpr((e as IndexExpression).target); walkExpr((e as IndexExpression).index) }
    else if (e instanceof ArrayExpression) { for (let x of (e as ArrayExpression).elements) { walkExpr(x) } }
    else if (e instanceof ObjectExpression) {
      // {a: state.a} in a new state is the field handed on under its own name, not read. Only in a new state: an entry built
      // from a draft field of the same name ({title: state.title, done: false}) reads it. A new state names every field of
      // the state class and nothing else.
      let props = (e as ObjectExpression).properties
      let isState = props.length === fields.length && props.every((p: Property): boolean => fields.indexOf(p.name) >= 0)
      for (let prop of props) {
        let v = prop.value
        if (isState && v instanceof SelectExpression && (v as SelectExpression).field === prop.name) { walkExpr((v as SelectExpression).target) }
        else { walkExpr(v) }
      }
    } else if (e instanceof LambdaExpression) { walkStmt((e as LambdaExpression).body) }
    else if (e instanceof AwaitExpression) { walkExpr((e as AwaitExpression).operand) }
    else if (e instanceof EnsureNotNullExpression) { walkExpr((e as EnsureNotNullExpression).operand) }
  }
  walkStmt = (st: Statement): void => {
    if (st instanceof BlockStatement) { for (let x of (st as BlockStatement).statements) { walkStmt(x) } }
    else if (st instanceof LetStatement) { walkExpr((st as LetStatement).initializer) }
    else if (st instanceof IfStatement) {
      walkExpr((st as IfStatement).condition)
      walkStmt((st as IfStatement).thenBranch)
      let other = (st as IfStatement).elseBranch
      if (other !== null) { walkStmt(other) }
    } else if (st instanceof WhileStatement) { walkExpr((st as WhileStatement).condition); walkStmt((st as WhileStatement).body) }
    else if (st instanceof ForOfStatement) { walkExpr((st as ForOfStatement).iterable); walkStmt((st as ForOfStatement).body) }
    else if (st instanceof ReturnStatement) {
      let v = (st as ReturnStatement).value
      if (v !== null) { walkExpr(v) }
    } else if (st instanceof AssignStatement) { walkExpr((st as AssignStatement).target); walkExpr((st as AssignStatement).value) }
    else if (st instanceof ExpressionStatement) { walkExpr((st as ExpressionStatement).expression) }
    else if (st instanceof TryStatement) { walkStmt((st as TryStatement).tryBlock); walkStmt((st as TryStatement).catchBlock) }
  }
  for (let d of app.declarations) {
    if (d instanceof FunctionDeclaration) { walkStmt((d as FunctionDeclaration).body) }
  }
  return fields.filter((f: string): boolean => !read.has(f))
}

// ===== Public API =====

export class CompileResult {
  vbc2: string
  /**
   * Every handler a tap, a ticker or an answer can reach -- (state, value) to state -- with the kind of value
   * it takes: number, string or boolean, or pointer for a ui.Surface's finger handler. For running a new program once before it is served.
   */
  handlers: Map<string, string> = new Map<string, string>()
  /** Fields of the app's state that no code reads (unreadStateFields): a setter writes them, nothing shows or uses what it wrote. */
  unreadFields: string[] = []
  constructor(vbc2: string) { this.vbc2 = vbc2 }
}

function handlersOf(model: SemanticModel): Map<string, string> {
  let handlers: Map<string, string> = new Map<string, string>()
  let init = model.functions.get('init')
  if (init === undefined) { return handlers }
  let state = init.result
  model.functions.forEach((fn: VeraFunctionType, name: string) => {
    if (fn.isAsync || fn.parameters.length !== 2 || !identical(fn.parameters[0], state) || !identical(fn.result, state)) { return }
    let value = fn.parameters[1]
    if (value === NUMBER || value === STRING || value === BOOLEAN) { handlers.set(name, (value as PrimitiveType).name) }
    else if (value instanceof VeraClassType && (value as VeraClassType).identity === 'std/gfx:Pointer') { handlers.set(name, 'pointer') }
  })
  return handlers
}

/** The declarations Make widget writes and may replace: the widget and the card's periodic update. */
const WIDGET_OWNED: string[] = ['widget', 'widgetRefresh']

/** Additive widget refinement: token comparison ignores formatting/comments, not program semantics. */
export function widgetRefinementError(base: string, candidate: string): string {
  let before = new Parser(base, '<base>').parse()
  let after = new Parser(candidate, '<widget>').parse()
  let fingerprint = (source: string, node: Node): string => JSON.stringify(
    new Lexer(source.substring(node.span.start.offset, node.span.end.offset), '<declaration>').scan()
      .map((token: Token): string => token.kind + ':' + token.text))
  for (let declaration of before.declarations) {
    if (!(declaration instanceof FunctionDeclaration) && !(declaration instanceof ClassDeclaration)) { continue }
    if (declaration instanceof FunctionDeclaration && WIDGET_OWNED.indexOf(declaration.name) >= 0) { continue }
    let name = declaration.name
    let found = after.declarations.find((entry: Declaration): boolean =>
      ((entry instanceof FunctionDeclaration && declaration instanceof FunctionDeclaration) ||
       (entry instanceof ClassDeclaration && declaration instanceof ClassDeclaration)) &&
      (entry as FunctionDeclaration).name === name)
    if (found === undefined || fingerprint(base, declaration) !== fingerprint(candidate, found)) {
      return 'Make widget must preserve existing declaration ' + name + ' unchanged; add widget and new helpers only.'
    }
  }
  for (let entry of before.imports) {
    if (!after.imports.some((other: ImportDeclaration): boolean => entry.name === other.name && entry.specifier === other.specifier)) {
      return 'Make widget must preserve existing imports.'
    }
  }
  if (!after.declarations.some((entry: Declaration): boolean => entry instanceof FunctionDeclaration && entry.name === 'widget')) {
    return 'Make widget must add function widget(state): ui.View.'
  }
  return appUsesWidgetError(base)
}

/**
 * '' when none of the app's own declarations calls widget or widgetRefresh; else why Make widget cannot be used on it. A screen
 * that draws itself with widget(state) -- view returning widget(state) -- would change with every new widget, and the model
 * cannot change the app's code to stop that. A source that does not parse is left to the checks that say so.
 */
export function appUsesWidgetError(source: string): string {
  let app: Application
  try { app = new Parser(source, '<app>').parse() } catch (_e) { return '' }
  for (let declaration of app.declarations) {
    if (declaration instanceof FunctionDeclaration && WIDGET_OWNED.indexOf(declaration.name) >= 0) { continue }
    let tokens = new Lexer(source.substring(declaration.span.start.offset, declaration.span.end.offset), '<declaration>').scan()
    for (let i = 0; i + 1 < tokens.length; i++) {
      if (WIDGET_OWNED.indexOf(tokens[i].text) >= 0 && tokens[i + 1].text === '(') {
        let name = declaration instanceof FunctionDeclaration ? (declaration as FunctionDeclaration).name :
          (declaration instanceof ClassDeclaration ? (declaration as ClassDeclaration).name : 'a declaration')
        return 'This app\'s own ' + name + ' calls ' + tokens[i].text + '(), so a new widget would change the app too. ' +
          'Make widget keeps the app as it is, so it cannot make a widget for this app.'
      }
    }
  }
  return ''
}

/** '' when `source` parses (types are not checked); else the parser's message, with its place. */
export function parseErrorOf(source: string): string {
  try {
    new Parser(source, '<answer>').parse()
    return ''
  } catch (e) {
    return (e as Error).message
  }
}

/**
 * Make widget: the base program exactly as it is, with the candidate's widget and the functions, classes and imports the
 * candidate adds. A declaration the base already has is the base's: the model's rewrite of it, asked for or not, is not
 * taken, so a widget cannot change the app (widgetRefinementError holds by construction). The base's own widget and
 * widgetRefresh, if any, are replaced by the reply's: a new widget without a widgetRefresh has none. A candidate that does not parse or has no widget is returned as it is, for the compiler and the checks to say why.
 */
export function spliceWidget(base: string, candidate: string): string {
  let before: Application
  let after: Application
  try {
    before = new Parser(base, '<base>').parse()
    after = new Parser(candidate, '<widget>').parse()
  } catch (_e) {
    return candidate
  }
  // Functions and classes are the only declarations a program has (imports are apart, below): nothing else can be dropped.
  let named = (entry: Declaration): string => entry instanceof FunctionDeclaration ? 'function ' + entry.name :
    (entry instanceof ClassDeclaration ? 'class ' + entry.name : '')
  let isWidget = (entry: Declaration): boolean => entry instanceof FunctionDeclaration && entry.name === 'widget'
  let owned = (entry: Declaration): boolean => entry instanceof FunctionDeclaration && WIDGET_OWNED.indexOf(entry.name) >= 0
  if (!after.declarations.some(isWidget)) { return candidate }
  let text = (source: string, node: Node): string => source.substring(node.span.start.offset, node.span.end.offset)
  // The base without its widget-owned declarations, cut from the end so the earlier offsets still hold.
  let kept = base
  let old = before.declarations.filter(owned).sort((a: Declaration, b: Declaration): number => b.span.start.offset - a.span.start.offset)
  for (let entry of old) { kept = kept.substring(0, entry.span.start.offset) + kept.substring(entry.span.end.offset) }
  let known = before.declarations.filter((entry: Declaration): boolean => !owned(entry)).map(named)
  let added: string[] = []
  for (let entry of after.declarations) {
    let name = named(entry)
    if (name.length > 0 && known.indexOf(name) < 0) { added.push(text(candidate, entry)) }
  }
  let imports: string[] = []
  for (let entry of after.imports) {
    if (!before.imports.some((other: ImportDeclaration): boolean => entry.name === other.name && entry.specifier === other.specifier)) {
      imports.push(text(candidate, entry))
    }
  }
  return (imports.length > 0 ? imports.join('\n') + '\n' : '') + kept.trimEnd() + '\n\n' + added.join('\n\n') + '\n'
}

/**
 * A new version of a program that had a home-screen widget, written without it: the earlier version's widget, its refresh
 * and what they use that the new version does not have (helpers, classes, imports), put back at the end. A new version
 * with a widget of its own, or an earlier one without, is returned as it is. Whether the result compiles and the card
 * still draws is the caller's to check: the widget may read a field the new version took away.
 */
export function carryWidget(next: string, previous: string): string {
  let now: Application
  let before: Application
  try {
    now = new Parser(next, '<next>').parse()
    before = new Parser(previous, '<previous>').parse()
  } catch (_e) {
    return next
  }
  let nameOf = (entry: Declaration): string => entry instanceof FunctionDeclaration ? entry.name :
    (entry instanceof ClassDeclaration ? entry.name : '')
  let isWidget = (entry: Declaration): boolean => entry instanceof FunctionDeclaration && entry.name === 'widget'
  if (now.declarations.some(isWidget) || !before.declarations.some(isWidget)) { return next }
  let present = now.declarations.map(nameOf)
  let text = (node: Node): string => previous.substring(node.span.start.offset, node.span.end.offset)
  let words = (node: Node): string[] => new Lexer(text(node), '<declaration>').scan().map((token: Token): string => token.text)
  // The widget's own, then whatever they name that the new version lacks, until nothing new is named.
  let carried: Declaration[] = before.declarations.filter((entry: Declaration): boolean =>
    entry instanceof FunctionDeclaration && WIDGET_OWNED.indexOf(entry.name) >= 0)
  let used: string[] = []
  for (let i = 0; i < carried.length; i++) {
    for (let word of words(carried[i])) {
      if (used.indexOf(word) < 0) { used.push(word) }
      let wanted = before.declarations.find((entry: Declaration): boolean => nameOf(entry) === word)
      if (wanted !== undefined && present.indexOf(word) < 0 && carried.indexOf(wanted) < 0) { carried.push(wanted) }
    }
  }
  carried.sort((a: Declaration, b: Declaration): number => a.span.start.offset - b.span.start.offset)
  let imports: string[] = []
  for (let entry of before.imports) {
    if (used.indexOf(entry.name) >= 0 &&
      !now.imports.some((other: ImportDeclaration): boolean => other.name === entry.name && other.specifier === entry.specifier)) {
      imports.push(text(entry))
    }
  }
  return (imports.length > 0 ? imports.join('\n') + '\n' : '') + next.trimEnd() + '\n\n' +
    carried.map(text).join('\n\n') + '\n'
}

/**
 * The program without its home-screen widget, for a widget made again from nothing: widget, widgetRefresh, and what only
 * they use (a helper, a class, an import the app itself never names). What the app uses as well stays. Left in, the old
 * widget is what the model edits, and a helper of the old one would win over the new one's of the same name (spliceWidget
 * keeps the base's). A program without a widget, or one that does not parse, is returned as it is.
 */
export function withoutWidget(source: string): string {
  let app: Application
  try {
    app = new Parser(source, '<program>').parse()
  } catch (_e) {
    return source
  }
  let nameOf = (entry: Declaration): string => entry instanceof FunctionDeclaration ? entry.name :
    (entry instanceof ClassDeclaration ? entry.name : '')
  let owned = (entry: Declaration): boolean => entry instanceof FunctionDeclaration && WIDGET_OWNED.indexOf(entry.name) >= 0
  if (!app.declarations.some(owned)) { return source }
  let text = (node: Node): string => source.substring(node.span.start.offset, node.span.end.offset)
  let words = (node: Node): string[] => new Lexer(text(node), '<declaration>').scan().map((token: Token): string => token.text)
  // What the widget's declarations name, and what those name in turn.
  let gone: Declaration[] = app.declarations.filter(owned)
  for (let i = 0; i < gone.length; i++) {
    for (let word of words(gone[i])) {
      let named = app.declarations.find((entry: Declaration): boolean => nameOf(entry) === word)
      if (named !== undefined && word !== 'init' && word !== 'view' && gone.indexOf(named) < 0) { gone.push(named) }
    }
  }
  // Back in: whatever a declaration that stays names, until nothing more comes back.
  let changed = true
  while (changed) {
    changed = false
    let staying = app.declarations.filter((entry: Declaration): boolean => gone.indexOf(entry) < 0)
    let used: string[] = []
    for (let entry of staying) { used = used.concat(words(entry)) }
    let back = gone.filter((entry: Declaration): boolean => !owned(entry) && used.indexOf(nameOf(entry)) >= 0)
    if (back.length > 0) {
      gone = gone.filter((entry: Declaration): boolean => back.indexOf(entry) < 0)
      changed = true
    }
  }
  let staying = app.declarations.filter((entry: Declaration): boolean => gone.indexOf(entry) < 0)
  let used: string[] = []
  for (let entry of staying) { used = used.concat(words(entry)) }
  let cut: Node[] = (gone as Node[]).concat(app.imports.filter((entry: ImportDeclaration): boolean => used.indexOf(entry.name) < 0))
  cut.sort((a: Node, b: Node): number => b.span.start.offset - a.span.start.offset)
  let kept = source
  for (let node of cut) { kept = kept.substring(0, node.span.start.offset) + kept.substring(node.span.end.offset) }
  return kept.replace(/\n{3,}/g, '\n\n').trimEnd() + '\n'
}

/** A field or handler the app shows, under the words the app itself gives it ("Score", "Start"); '' when it gives none. */
export class WidgetFact {
  name: string
  label: string

  constructor(name: string, label: string) {
    this.name = name
    this.label = label
  }
}

/**
 * What a program shows that a widget could: the state's numbers it puts on screen as figures, the lists it lays out as
 * rows, and the actions its buttons take -- in the order the app shows them, primary buttons first. A number only drawn
 * (a paddle's x) or a list only painted (a game's bricks) is not one: it means nothing on a card.
 */
export class WidgetFacts {
  numbers: WidgetFact[] = []
  lists: WidgetFact[] = []
  handlers: WidgetFact[] = []
  /** Names the widget and widgetRefresh mention: a field or handler in here is on the card already. */
  used: string[] = []
  /** The widget's and widgetRefresh's own text: a figure the app words as a label is on the card when the label is here. */
  widgetText: string = ''
}

export function widgetFacts(source: string): WidgetFacts {
  let facts = new WidgetFacts()
  let app: Application
  try { app = new Parser(source, '<facts>').parse() } catch (_e) { return facts }
  let init = app.declarations.find((entry: Declaration): boolean =>
    entry instanceof FunctionDeclaration && entry.name === 'init') as FunctionDeclaration | undefined
  if (init === undefined) { return facts }
  let stateName = init.returnType.name
  let state = app.declarations.find((entry: Declaration): boolean =>
    entry instanceof ClassDeclaration && entry.name === stateName) as ClassDeclaration | undefined
  if (state === undefined) { return facts }
  let numberFields = state.fields.filter((field: FieldDeclaration): boolean => field.type.name === 'number' && !field.type.nullable)
    .map((field: FieldDeclaration): string => field.name)
  let listFields = state.fields.filter((field: FieldDeclaration): boolean => field.type.name === 'array')
    .map((field: FieldDeclaration): string => field.name)
  let widgetText = ''
  let appText = ''
  let handlerNames: string[] = []
  for (let entry of app.declarations) {
    if (!(entry instanceof FunctionDeclaration)) { continue }
    let fn = entry as FunctionDeclaration
    let text = source.substring(fn.span.start.offset, fn.span.end.offset)
    if (WIDGET_OWNED.indexOf(fn.name) >= 0) { widgetText = widgetText + '\n' + text; continue }
    appText = appText + '\n' + text
    if (!fn.isAsync && fn.parameters.length === 2 && fn.parameters[0].type.name === stateName &&
      fn.returnType.name === stateName && fn.parameters[1].type.name === 'number') { handlerNames.push(fn.name) }
    // A list laid out as rows is one a function walks while it makes ListItems or TimelineItems.
    if (/\b(ListItem|TimelineItem)\(/.test(text)) {
      for (let field of listFields) {
        if (new RegExp('state\\.' + field + '\\b').test(text) && !facts.lists.some((f: WidgetFact): boolean => f.name === field)) {
          facts.lists.push(new WidgetFact(field, ''))
        }
      }
    }
  }
  facts.widgetText = widgetText
  for (let token of new Lexer(widgetText, '<widget>').scan()) {
    if (facts.used.indexOf(token.text) < 0) { facts.used.push(token.text) }
  }
  // Figures, in the order the app shows them: a labelled stat (its value may be worked out, not a field), then a number
  // written straight from the state.
  let addFigure = (field: string, label: string): void => {
    let known = facts.numbers.find((f: WidgetFact): boolean =>
      (field.length > 0 && f.name === field) || (label.length > 0 && f.label === label))
    if (known === undefined) { facts.numbers.push(new WidgetFact(field, label)) }
    else if (known.label.length === 0) { known.label = label }
  }
  let stat = /(?:NumberStat|\bStat|Hero)\(\s*"[^"]*"\s*,\s*"([^"]*)"\s*,\s*([^,]+),/g
  let match = stat.exec(appText)
  while (match !== null) {
    let direct = /^state\.(\w+)$/.exec(match[2].trim())
    let field = direct !== null && numberFields.indexOf(direct[1]) >= 0 ? direct[1] : ''
    if (match[1].trim().length > 0) { addFigure(field, match[1].trim()) }
    match = stat.exec(appText)
  }
  let plain = /NumberText\(\s*"[^"]*"\s*,\s*state\.(\w+)|numberToString\(\s*state\.(\w+)/g
  match = plain.exec(appText)
  while (match !== null) {
    let field = match[1] !== undefined ? match[1] : match[2]
    if (numberFields.indexOf(field) >= 0) { addFigure(field, '') }
    match = plain.exec(appText)
  }
  // Buttons, with the words on them; the primary ones first, as the app's main actions.
  // Only a button that gives its handler a fixed value: a Remove that passes the row's index means nothing on a card.
  let button = /Button\(\s*"(\w+)"\s*,\s*"([^"]*)"\s*,\s*"(\w+)"\s*,\s*-?\d+(?:\.\d+)?\s*,/g
  let primary: WidgetFact[] = []
  let rest: WidgetFact[] = []
  match = button.exec(appText)
  while (match !== null) {
    let name = match[3]
    if (handlerNames.indexOf(name) >= 0 && !primary.concat(rest).some((f: WidgetFact): boolean => f.name === name)) {
      if (match[1] === 'primary') { primary.push(new WidgetFact(name, match[2])) } else { rest.push(new WidgetFact(name, match[2])) }
    }
    match = button.exec(appText)
  }
  facts.handlers = primary.concat(rest)
  return facts
}

export class CompileOptions {
  /**
   * Accept an action that names a handler not declared anywhere. Only for a
   * preview of a program still being written: the chat compiles the source
   * that has streamed in so far once view() is complete, before the handlers
   * after it have arrived, and draws it with taps switched off. A handler is
   * only a string in the UI tree until something dispatches to it, so nothing
   * else needs it to exist.
   */
  allowMissingHandlers: boolean = false
}

export function compileVeraSource(source: string, sourceName: string = '<source>',
    options: CompileOptions = new CompileOptions()): CompileResult {
  let app = new Parser(source, sourceName).parse()
  let model = new Analyzer(app, options).analyze()
  let module = new BytecodeCompiler(model).compile()
  let result = new CompileResult(serializeVbc2(module))
  result.handlers = handlersOf(model)
  result.unreadFields = unreadStateFields(app)
  return result
}
