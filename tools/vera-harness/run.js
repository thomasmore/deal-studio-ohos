#!/usr/bin/env node
/**
 * Host-side proof for std/ui, without a device or a build.
 *
 * Compiles a VERA-L source file, runs its init()/view() (or any other named
 * entry point) through the real VM, decodes the resulting ui.View tree with
 * the real decoder, and prints it as JSON.
 *
 * source-loader.js transpiles the current ETS sources for this process.
 * The SDK stub supports host checks without native platform dependencies.
 * proof-sheet.js draws an approximate SVG from the decoded tree.
 *
 * Usage:
 *   node run.js <path-to.vera> [entryFunction=view] [stateJson]
 *
 * If stateJson is omitted and entryFunction is 'view', init() is run first
 * and its result is used as the state argument.
 */
'use strict'

const fs = require('fs')
const path = require('path')

const { loadVera } = require('./source-loader')
const { compileVeraSource, CompileError } = loadVera('VeraCompiler')
const { VirtualMachine, deserializeVbc2, decodeRuntimeValue } = loadVera('VeraInterpreter')
const { UiHostEnvironment, decodeVeraUi } = loadVera('VeraUi')

function main() {
  const [sourcePath, entryArg, stateArg] = process.argv.slice(2)
  if (!sourcePath) {
    console.error('usage: node run.js <path-to.vera> [entryFunction=view] [stateJson]')
    process.exit(2)
  }
  const entry = entryArg || 'view'
  const source = fs.readFileSync(path.resolve(sourcePath), 'utf8')

  let vbc2
  try {
    const result = compileVeraSource(source)
    vbc2 = result.vbc2 !== undefined ? result.vbc2 : result
  } catch (e) {
    if (e instanceof CompileError || (e && e.diagnostics)) {
      console.error('COMPILE ERROR:')
      for (const d of e.diagnostics) {
        const line = d.span && d.span.start ? d.span.start.line : '?'
        const col = d.span && d.span.start ? d.span.start.column : '?'
        console.error(`  ${d.code || '?'} ${line}:${col} ${d.message || d}`)
      }
      process.exit(1)
    }
    throw e
  }

  const host = new UiHostEnvironment()
  const module_ = deserializeVbc2(vbc2)
  const vm = new VirtualMachine(module_, host)

  let stateValue
  if (stateArg) {
    stateValue = decodeRuntimeValue(JSON.parse(stateArg))
  } else if (entry === 'view' || entry === 'widget') {
    stateValue = vm.execute('init')
  }

  const viewTree = stateValue !== undefined ? vm.execute(entry, [stateValue]) : vm.execute(entry)
  const nodes = decodeVeraUi(viewTree)
  const root = nodes.length > 0 ? nodes[0] : null

  console.log(JSON.stringify(root, null, 2))
}

main()
