'use strict'
// Metadata for run-all.js. Checks are discovered from disk; this file only records
// what cannot be inferred: extra arguments, required environment, platform skips,
// and which family a check belongs to (matched by name prefix, first rule wins).

const os = require('node:os')
const path = require('node:path')

const root = path.resolve(__dirname, '../..')

const families = [
  ['in-process-host-', 'runtime'],
  ['preview-host-', 'runtime'],
  ['caller-snapshot-', 'runtime'],
  ['host-effects-', 'runtime'],
  ['app-actor-', 'runtime'],
  ['runtime-', 'runtime'],
  ['stage-trace-', 'runtime'],
  ['offline-baseline-', 'runtime'],
  ['state-carry-', 'runtime'],
  ['visual-', 'visual'],
  ['gfx-', 'visual'],
  ['proof-', 'visual'],
  ['surface-', 'visual'],
  ['scene-', 'visual'],
  ['motion-', 'visual'],
  ['world-', 'visual'],
  ['locomotion-', 'visual'],
  ['shapes-', 'visual'],
  ['interaction-', 'visual'],
  ['models-', 'visual'],
  ['particles-', 'visual'],
  ['texture-', 'visual'],
  ['live-widget-', 'widget'],
  ['live-form-', 'widget'],
  ['widget-', 'widget'],
  ['prompt-', 'prompt'],
  ['chat-', 'prompt'],
  ['deepseek-guard-', 'prompt'],
  ['agent-', 'agent'],
  ['align-', 'agent'],
  ['needs-', 'agent'],
  ['plan-', 'agent'],
  ['dead-', 'agent'],
  ['deadline-', 'agent'],
  ['length-feeders-', 'agent'],
  ['request-seed-', 'agent'],
  ['screen-order-', 'agent'],
  ['merge-', 'agent'],
  ['compose-', 'composition'],
  ['composition-', 'composition'],
  ['template-', 'composition'],
  ['parts-', 'composition'],
  ['section-', 'composition'],
  ['hole-', 'composition'],
  ['port-bind-', 'composition'],
  ['verify-', 'composition'],
  ['intent-', 'composition'],
  ['idea-deck-', 'composition'],
  ['record-', 'composition'],
  ['coverage-eval-', 'composition'],
  ['live-', 'live'],
  ['source-', 'live'],
  ['date-field-', 'ui'],
  ['decimals-', 'ui'],
  ['project-text-', 'ui'],
  ['ask-notify-', 'ui'],
  ['metrics-', 'ui'],
  ['calendar-sdk-', 'ui'],
  ['handler-signature-', 'compiler'],
  ['validation-', 'compiler'],
  ['smoke-', 'compiler'],
  ['stage-legacy-', 'compiler'],
]

const overrides = {
  'prompt-check.js': {
    args: [root, path.join(os.tmpdir(), 'vera-prompt-verification.json')],
    family: 'prompt',
    timeout: 600000,
  },
  'chat-handoff-check.js': {
    args: [root, path.join(os.tmpdir(), 'vera-chat-handoff-verification.json')],
    family: 'prompt',
    timeout: 600000,
  },
  'capability-check.js': {
    args: [path.join(os.tmpdir(), 'vera-capability-verification.json')],
    family: 'runtime',
  },
  'visual-check.js': {
    args: [path.join(os.tmpdir(), 'vera-visual-verification.json')],
    family: 'visual',
  },
  'calendar-sdk-check.js': {
    env: ['VERA_CALENDAR_SDK_PATH'],
    family: 'ui',
  },
  'coverage-eval-check.js': {
    skipOn: ['win32'],
    family: 'composition',
    reason: 'needs symlink support (EPERM on Windows)',
  },
}

module.exports = {families, overrides}
