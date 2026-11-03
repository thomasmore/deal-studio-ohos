// A live source (VeraSource.ets, VeraSourceFind.ets): reading the answer at the paths, the address rules, and the finder with a
// mocked search, model and network -- a candidate that fails is passed over, the model's paths are read on a second fetch.
const assert = require('node:assert/strict')
const fs = require('node:fs'), path = require('node:path')
const {loadVera} = require('./source-loader')
const S = loadVera('VeraSource'), F = loadVera('VeraSourceFind')

const moex = JSON.stringify({marketdata: {columns: ['SECID', 'CURRENTVALUE', 'UPDATETIME'], data: [['IMOEX', 2446.64, '13:51:05']]}})
assert.equal(S.valueText(S.readPath(JSON.parse(moex), 'marketdata.data[0][1]')), '2446.64')
assert.equal(S.valueText(S.readPath(JSON.parse(moex), 'marketdata.data[-1][2]')), '13:51:05')
assert.equal(S.readPath(JSON.parse(moex), 'marketdata.data[3][1]'), undefined)
assert.equal(S.sourceAnswer(moex, 'https://iss.moex.com/x.json', ['marketdata.data[0][1]'], 'marketdata.data[0][2]', '14:00:00'),
  'ok\n2446.64\n\n\nsource\tiss.moex.com\thttps://iss.moex.com/x.json\nasof\t13:51:05')
assert.match(S.sourceAnswer(moex, 'https://a.b/x', ['nothing.here'], '', 'c'), /^error: the source answered without nothing\.here/)
assert.match(S.sourceAnswer('<html>', 'https://a.b/x', ['a'], '', 'c'), /^error: .*JSON/)
for (const bad of ['http://a.com/x', 'https://localhost/x', 'https://192.168.1.2/x', 'https://user:pw@a.com/x', 'https://10.0.0.1/', 'https://a.com/ x'])
  assert.notEqual(S.sourceUrlError(bad), '', bad)
assert.equal(S.sourceUrlError('https://api.open-meteo.com/v1/forecast?latitude=55.75&current=temperature_2m'), '')

// The sample shows a table's column names and a row whole (the live figure is often far along them), but only three rows.
const wide = {marketdata: {columns: Array.from({length: 28}, (_, i) => 'C' + i), data: Array.from({length: 9}, () => Array.from({length: 28}, (_, i) => i))}}
const shown = F.sampleOf(wide)
assert.equal(shown.marketdata.columns.length, 28); assert.equal(shown.marketdata.data.length, 4); assert.equal(shown.marketdata.data[0].length, 28)
assert.match(shown.marketdata.data[3], /9 items/)

;(async () => {
  const calls = new F.SourceCalls(), got = []
  calls.search = async q => { assert.match(q, /free public JSON API/); return 'Web results ... 1. MOEX ISS (https://iss.moex.com/iss/reference/)' }
  calls.askJson = async (system, user) => system === F.SOURCE_FIND_PROMPT
    ? '```json\n{"candidates":[{"url":"https://broken.example.com/q"},{"url":"http://insecure.example.com/q"},{"url":"https://iss.moex.com/x.json"}]}\n```'
    : '{"ok":true,"figures":[{"label":"IMOEX","path":"marketdata.data[0][1]","unit":"points"}],"asof":"marketdata.data[0][2]"}'
  calls.get = async url => { got.push(url); const r = new S.SourceResponse()
    if (url.includes('broken')) r.error = 'HTTP 404'; else r.text = moex; return r }
  const found = await F.findSource('IMOEX index now', calls)
  assert.equal(found.spec.url, 'https://iss.moex.com/x.json')
  assert.deepEqual(found.spec.paths, ['marketdata.data[0][1]']); assert.deepEqual(found.spec.values, ['2446.64'])
  assert.equal(found.spec.asofValue, '13:51:05')
  assert.equal(found.tried.length, 2); assert.match(found.tried[0], /HTTP 404/); assert.match(found.tried[1], /https/)
  assert.deepEqual(got, ['https://broken.example.com/q', 'https://iss.moex.com/x.json', 'https://iss.moex.com/x.json'], 'fetched twice before taken')
  // The call as the program must write it, and the check that it does.
  const call = F.sourceCall(found.spec, 'onSource')
  assert.equal(call, 'sdk.call("Vera.Source.fetch", ["url", "https://iss.moex.com/x.json", "paths", "marketdata.data[0][1]", "asof", "marketdata.data[0][2]"], "onSource");')
  assert.match(F.sourceNote(found.spec), /IMOEX = 2446\.64 \(points\)/)
  assert.equal(F.sourceUseError('x ' + call + ' ui.Ticker("default", "live", 1000, true, "onTick")', found.spec), '')
  assert.match(F.sourceUseError('x ' + call, found.spec), /ui\.Ticker/)
  assert.match(F.sourceUseError('let v: number = 2446.64;', found.spec), /must get its live figures itself/)
  // The program handed an answer of the source's shape must show what it says: a handler reading the time from the wrong line
  // is sent back with the lines and their places. The figures it started with do not count.
  const {compileVeraSource} = loadVera('VeraCompiler')
  const program = fs.readFileSync(path.join(__dirname, 'examples/widget-source.vera'), 'utf8')
  const spec = found.spec
  spec.url = 'https://iss.moex.com/iss/engines/stock/markets/index/securities/IMOEX.json'
  spec.paths = ['marketdata.data[0][1]']; spec.asof = 'marketdata.data[0][3]'
  spec.sample = S.sourceAnswer(moex.replace('"13:51:05"', '"x", "13:51:05"'), spec.url, spec.paths, spec.asof, '12:00:00')
  assert.equal(F.sourceHandlerOf(program), 'onSource')
  const shownProgram = program.replace('ui.Text("caption", state.asOf)', 'ui.Text("caption", state.asOf), ui.Text("caption", "iss.moex.com")')
  assert.equal(F.sourceShownError(shownProgram, compileVeraSource(shownProgram).vbc2, spec), '')
  const misread = shownProgram.replace('strings.split(lines[5]', 'strings.split(lines[4]')
  assert.notEqual(misread, shownProgram)
  assert.match(F.sourceShownError(misread, compileVeraSource(misread).vbc2, spec), /without the time .*03:21[\s\S]*lines\[5\] = "asof/)
  // A path the model named that is not in the answer: the source is not taken.
  calls.askJson = async (system) => system === F.SOURCE_FIND_PROMPT ? '{"candidates":[{"url":"https://iss.moex.com/x.json"}]}'
    : '{"ok":true,"figures":[{"label":"IMOEX","path":"marketdata.data[0][9]","unit":""}],"asof":""}'
  const none = await F.findSource('IMOEX index now', calls)
  assert.equal(none.spec, null); assert.match(none.tried[0], /nothing at marketdata\.data\[0\]\[9\]/)
  console.log('PASS live source: answer read at paths, address rules, finder passes over failures and checks paths on a second fetch, the call and its check')
})().catch(e => { console.error(e); process.exit(1) })

// No API found: the program reads the figure off a search (Vera.Live.fetch) and is held to the same checks, with a made-up answer
// of that shape, so a program that only starts from the search's figures, or reads the lines in the wrong places, is sent back.
{
  const {compileVeraSource} = loadVera('VeraCompiler')
  const spec = F.searchSpec('Apple stock price now')
  assert.match(F.sourceCall(spec, 'onSource'), /^sdk\.call\("Vera\.Live\.fetch", \["query", "Apple stock price now", "labels", /)
  assert.match(F.sourceNote(spec), /No public data source[\s\S]*every five minutes at most/)
  const program = fs.readFileSync(path.join(__dirname, 'examples/widget-source.vera'), 'utf8')
    .split('\n').map(line => line.includes('"Vera.Source.fetch"') ? '  sdk.call("Vera.Live.fetch", ["query", "Apple stock price now", "labels", "Price"], "onSource");' : line).join('\n')
    .replace('ui.Text("caption", state.asOf)', 'ui.Text("caption", state.asOf), ui.Text("caption", state.note), ui.Ticker("default", "live", 1000, true, "refresh")')
  assert.match(program, /Vera\.Live\.fetch/)
  assert.equal(F.sourceHandlerOf(program), 'onSource')
  assert.match(F.sourceUseError(program, spec), /^$/)
  assert.match(F.sourceUseError(program.replace('Apple stock price now', 'apple'), spec), /must get its live figures itself with sdk\.call\("Vera\.Live\.fetch"/)
  // The example shows no source domain: the check says so.
  assert.match(F.sourceShownError(program, compileVeraSource(program).vbc2, spec), /without the source example\.org/)
  const shown = program.replace('ui.Text("caption", state.note)', 'ui.Text("caption", "from example.org")')
  assert.equal(F.sourceShownError(shown, compileVeraSource(shown).vbc2, spec), '')
  const many = shown.replace('"labels", "Price"', '"labels", "Home|Away|Home score|Away score"')
  assert.match(F.sourceUseError(many, spec), /at most 3 figures, but the call asks for 4 labels/)
  const raw = shown.replace('let when: string[] = strings.split(lines[5], "\\t");', 'let when: string[] = [lines[5], lines[5]];')
  assert.notEqual(raw, shown)
  assert.match(F.sourceShownError(raw, compileVeraSource(raw).vbc2, spec), /shows its "source" or "asof" line as it is/)
  console.log('PASS live search fallback: the call, its note and the same checks, three labels at most, no raw lines')
}
