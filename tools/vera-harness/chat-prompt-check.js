// What a chat widget is built from (VeraChat.ets): the marker's plain request, else the description, else the message; a revision is
// no replacement to build.
'use strict'
const assert = require('node:assert/strict')
const {loadVera} = require('./source-loader')
const chat = loadVera('VeraChat')
const {WidgetBuildContext} = loadVera('VeraWidgetContext')
const {settings} = loadVera('SettingsStore')
const compose = loadVera('VeraCompose')

settings.hasSelectorKey = () => true
const context = fields => Object.assign(new WidgetBuildContext(), fields)
const agent = c => chat.chatAgentRequest(c) && chat.chatAgentRequest(c).prompt

// The marker's plain request first, then the description, then the message.
assert.equal(agent(context({request: ' tip calculator ', brief: 'a long description', currentRequest: 'the message'})), 'tip calculator')
assert.equal(agent(context({request: '', brief: 'a long description', currentRequest: 'the message'})), 'a long description')
assert.equal(agent(context({request: '  ', brief: ' ', currentRequest: ' the message '})), 'the message')
// A revision of an existing widget is no replacement to build.
assert.equal(chat.chatAgentRequest(context({request: 'tip calculator', source: 'import ...'})), null)
// A widget built on search results is not the agent's.
assert.equal(chat.chatAgentRequest(context({request: 'weather', verifiedSearchResults: ['x']})), null)
assert.equal(chat.chatAgentRequest(context({request: 'tip calculator'})).widget, true)
// The reply just before the person's message searched: a widget asked for now is built on those results; an older reply's are
// another subject's.
const {earlierSearchResults, SearchedTurn} = loadVera('VeraWidgetContext')
const turn = (role, searchResults = []) => Object.assign(new SearchedTurn(), {role, searchResults})
const weather = 'Web results for "Moscow weather today"...'
assert.deepEqual(earlierSearchResults([turn('user'), turn('assistant', [weather]), turn('user')]), [weather])
assert.deepEqual(earlierSearchResults([turn('user'), turn('assistant', [weather]), turn('user'), turn('assistant'), turn('user')]), [])
assert.deepEqual(earlierSearchResults([turn('user')]), [])
const after = context({request: 'weather card', verifiedSearchResults: earlierSearchResults([turn('assistant', [weather]), turn('user')])})
assert.equal(chat.chatAgentRequest(after), null)
// The chat searches for a current figure rather than refusing it.
assert.match(chat.chatSystemPrompt(true), /search before you answer: do not say you cannot get it/)
assert.doesNotMatch(chat.chatSystemPrompt(false), /web_search/)
// Recognized multi-view failures are terminal in direct Chat builds as well as the route.
{
  const {AgentResult} = loadVera('agent/VeraAgent')
  const failed = new AgentResult(); failed.composed.appPlanFailed = true; failed.errors = 'navigation metadata missing'
  const result = new chat.MiniApp()
  assert.equal(chat.recordChatAgent(failed, context({request:'open a record'}), result), true)
  assert.match(result.error, /navigation metadata missing/); assert.equal(result.vbc2, '')
  const ordinary = new AgentResult()
  assert.equal(chat.recordChatAgent(ordinary, context({request:'calculator'}), new chat.MiniApp()), false)
}
console.log('chat-prompt-check: ok')

// A reply that writes out the record line of an earlier widget (the history shows them as "[widget messageId=3, status=ready: ...]")
// instead of a marker is read as the marker it stands for; half a line is a marker still being written.
{
  const line = '[widget messageId=4, status=ready: A daily medication reminder card. Fields: name ["a", "b"].]'
  let r = chat.parseReply('Here is a daily card.\n\n' + line, true)
  assert.equal(r.error, ''); assert.equal(r.before, 'Here is a daily card.')
  assert.equal(r.appDescription, 'A daily medication reminder card. Fields: name ["a", "b"].')
  r = chat.parseReply('Here is a daily card.\n\n[widget messageId=4, status=ready: A daily medic')
  assert.equal(r.describing, true); assert.equal(r.before, 'Here is a daily card.'); assert.equal(r.appDescription, '')
  r = chat.parseReply('Done. <<app: {"request":"tip","description":"a tip calculator","mode":"create"}>>', true)
  assert.equal(r.appDescription, 'a tip calculator', 'a real marker is as it was')
  assert.equal(r.recordMessageId, 0)
  // The line ends at its own closing bracket: text after it, brackets and all, stays text. Its messageId goes with it.
  r = chat.parseReply('Here.\n\n[widget messageId=3, status=ready: Tip calculator] -- see the [docs](x)', true)
  assert.equal(r.error, ''); assert.equal(r.appDescription, 'Tip calculator')
  assert.equal(r.after, '-- see the [docs](x)'); assert.equal(r.recordMessageId, 3); assert.equal(r.mode, 'create')
}
console.log('chat-prompt-check: record line read as a marker')
