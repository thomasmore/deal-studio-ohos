const assert = require('node:assert/strict')
const fs = require('node:fs'), path = require('node:path')
const {loadVera, sourceRoot} = require('./source-loader')
const {compileVeraSource, widgetRefinementError, spliceWidget, withoutWidget, appUsesWidgetError} = loadVera('VeraCompiler')
const {smokeRun} = loadVera('VeraSmoke')
const {widgetRefinementPrompt, validateWidgetRefinement, widgetRepairNote, checkWidget, CARD_KINDS} = loadVera('VeraWidgetRefine')
const {WidgetSession} = loadVera('VeraLiveWidget')
const source = fs.readFileSync(path.join(__dirname,'examples/widget-counter.vera'),'utf8')
// Standalone fullscreen base, not a view delegating to widget.
const base = source.replace('function widget(', 'function compact(').replace('return widget(state);','return compact(state);')
const addition = '\nfunction widget(state: AppState): ui.View { return compact(state); }'
const candidate = base + addition
const compiled = compileVeraSource(candidate)
assert.equal(widgetRefinementError(base,candidate), '')
assert.equal(widgetRefinementError(base,'// comment\n' + candidate.replace('count: 0','count : 0')), '')
for (const [from,to,name] of [['count: number','count: string','AppState'],['count: 0','count: 10','init'],['state.count + value','state.count - value','change'],['return compact(state);','return ui.Text("body", "changed");','view']]) {
  assert.match(widgetRefinementError(base,candidate.replace(from,to)),new RegExp(name))
}
assert.match(widgetRefinementError(base,base),/add function widget/)
assert.equal(validateWidgetRefinement(base,candidate,compiled.vbc2), '')
assert.equal(smokeRun(compiled),'')

// What a tap starts the card finishes (it runs the app's frames after a tap): a wheel's Spin passes. One that takes longer than the card
// runs them leaves its button off for good, and the reason asks for a handler that finishes at once. A picture that does nothing on the
// card although the app's does is a dead toy: the reason names the app's handler.
{
  const wheel = fs.readFileSync(path.join(__dirname, 'examples/widget-wheel.vera'), 'utf8')
  const wheelBase = withoutWidget(wheel)
  assert.equal(validateWidgetRefinement(wheelBase, wheel, compileVeraSource(wheel).vbc2), '', 'a wheel that lands within the card\'s frames passes')
  const slow = wheel.replace('let speed: number = state.speed - 900 * ms / 1000;', 'let speed: number = state.speed - 30 * ms / 1000;')
  assert.match(validateWidgetRefinement(withoutWidget(slow), slow, compileVeraSource(slow).vbc2), /"Spin" that button stays off on the card for good[\s\S]*finishes at once/)
  const once = wheel.replace('ui.Button("primary", "Spin", "spin", 0, state.speed === 0)', 'ui.Button("primary", "Spin", "spin", 0, state.spins === 0)')
  assert.notEqual(once, wheel)
  assert.equal(validateWidgetRefinement(withoutWidget(once), once, compileVeraSource(once).vbc2), '',
    'a button the app turns off once what it started is over (one spin only) is the app\'s rule, not something left unfinished')
  const dead = wheel.replace('ui.Surface("default", 100, 100, "wheelCard", "", "onTouch"),\n      ui.Text("caption", result(state)),\n      ui.Button("primary", "Spin", "spin", 0, state.speed === 0)',
    'ui.Surface("default", 100, 100, "wheelCard", "", ""),\n      ui.Text("caption", result(state))')
  assert.notEqual(dead, wheel)
  assert.match(validateWidgetRefinement(withoutWidget(dead), dead, compileVeraSource(dead).vbc2), /In the app a touch on the picture does something \(its handler "onTouch"\)/)
  assert.match(widgetRefinementPrompt(false), /After a tap the card runs the app's own frame handlers for up to 20 s/)
  assert.match(widgetRefinementPrompt(false), /for size 3, draws its picture wide/)
  assert.match(widgetRefinementPrompt(false), /ALWAYS MOVING[\s\S]*gfx\.drift\(direction, speed/)
}

// The prompt's worked example of moving parts (a clock whose pendulum swings, a wheel of gfx.sector slices that spins under a pointer that
// stays) is real code: in a draw function it compiles, and a widget of it passes Make widget's checks.
{
  const text = widgetRefinementPrompt(false)
  const at = text.indexOf('The pattern, in a clock and in a wheel:\n')
  assert.ok(at > 0, 'the prompt has the worked example')
  const lines = []
  for (const line of text.slice(at).split('\n').slice(1)) { if (!line.startsWith('  ')) break; lines.push(line) }
  assert.ok(lines.length >= 6 && lines.length <= 9, 'six to nine lines: ' + lines.length)
  assert.ok(lines.some(l => l.includes('gfx.moving("swing"')) && lines.some(l => l.includes('gfx.sector(')) && lines.some(l => l.includes('gfx.moving("spin"')))
  const app = `@jsonable class AppState { n: number; }
function init(): AppState { return {n: 0}; }
function draw(state: AppState): gfx.Shape[] {
  let shapes: gfx.Shape[] = [];
${lines.join('\n')}
  return shapes;
}
function onTouch(state: AppState, p: gfx.Pointer): AppState { if (p.phase !== "down") { return state; } return {n: state.n + 1}; }
function view(state: AppState): ui.View { return ui.AppTheme("soft", "", [ui.Surface("default", 100, 100, "draw", "", "onTouch")]); }
`
  const withWidget = app + 'function widget(state: AppState): ui.View { return ui.AppTheme("soft", "", [ui.Column("center", [ui.Surface("default", 100, 100, "draw", "", "onTouch"), ui.Text("caption", ui.numberToString(state.n))])]); }\n'
  const built = compileVeraSource(withWidget)
  assert.equal(validateWidgetRefinement(app, withWidget, built.vbc2), '', 'a widget of the example passes')
}

// The moving part, learnt from the app's own animation: the frames are run, the draw function looked at, and the shapes that turn and the point
// they turn about found (VeraMovingPart). A widget that swings the whole clock in a ui.Motion, or moves nothing, is refused with the shapes
// and the pivot; the widget that moves only the rod and the bob passes.
{
  const {appMovingPart, partFromLooks} = loadVera('VeraMovingPart')
  const clock = fs.readFileSync(path.join(__dirname, 'examples/widget-pendulum-frames.vera'), 'utf8')
  const code = compileVeraSource(clock).vbc2
  const started = Date.now()
  const part = appMovingPart(code, '')
  const took = Date.now() - started
  assert.ok(part !== null, 'the pendulum is found')
  assert.deepEqual([part.draw, part.style, part.pivotX, part.pivotY, part.moving, part.still], ['clock', 'swing', 50, 18, [3, 4], [0, 1, 2]],
    'the rod and the bob swing about the top of the rod; the case, its back and the pin stay')
  assert.ok(part.turn >= 40 && part.turn <= 60, 'it swings about 57 degrees: ' + part.turn)
  assert.ok(took < 2000, 'found in ' + took + ' ms')
  assert.equal(part.movingText, 'the gfx.line in #d4a64a and the gfx.circle in #fff3c4')
  assert.equal(part.stillText, '2 gfx.roundRect (#7c4a2d, #2a1a12) and the gfx.circle in #d4a64a')
  assert.equal(validateWidgetRefinement(withoutWidget(clock), clock, code), '', 'the widget with the rod and bob as a gfx.moving part passes')
  const whole = clock.replace('ui.Surface("default", 100, 100, "clockCard", "", ""),\n      ui.Text', 'ui.Motion("swing", 0, [ui.Surface("default", 100, 100, "clock", "", "")]),\n      ui.Text')
  assert.notEqual(whole, clock)
  const wholeWhy = validateWidgetRefinement(withoutWidget(whole), whole, compileVeraSource(whole).vbc2)
  assert.match(wholeWhy, /^In the app's picture these shapes swing about the point 50, 18 of the widget's picture: the gfx\.line in #d4a64a and the gfx\.circle in #fff3c4; and these stay where they are: 2 gfx\.roundRect/)
  assert.match(wholeWhy, /the ui\.Motion\("swing"\) moves the whole picture[\s\S]*The app's draw function "clock" cannot be changed from here: give the widget's picture a draw function of its own[\s\S]*gfx\.moving\("swing", 0, 50, 18, \[those shapes\]\)/)
  const breathing = whole.replace('ui.Motion("swing", 0, [ui.Surface("default", 100, 100, "clock"', 'ui.Motion("breathe", 0, [ui.Surface("default", 100, 100, "clock"')
  assert.notEqual(breathing, whole)
  assert.equal(validateWidgetRefinement(withoutWidget(breathing), breathing, compileVeraSource(breathing).vbc2), '', 'a movement that does not turn is the model\'s choice')
  const still = clock.replace('"clockCard", "", ""', '"clock", "", ""')
  assert.match(validateWidgetRefinement(withoutWidget(still), still, compileVeraSource(still).vbc2), /On the card nothing in the picture moves\./)
  // The widget's own drawing at another size: the pivot is the same point of the same shape there (the top of its rod), not a proportion.
  const own = clock.replace('function widget(', `function smallClock(state: AppState): gfx.Shape[] {
  return [gfx.roundRect(10, 2, 40, 56, 6, "#7c4a2d"), gfx.line(30, 8, 30, 40, 1, "#d4a64a"), gfx.circle(30, 44, 5, "#fff3c4")];
}

function widget(`).replace('ui.Surface("default", 100, 100, "clockCard", "", ""),\n      ui.Text', 'ui.Motion("swing", 0, [ui.Surface("default", 60, 60, "smallClock", "", "")]),\n      ui.Text')
  const ownWhy = validateWidgetRefinement(withoutWidget(own), own, compileVeraSource(own).vbc2)
  assert.match(ownWhy, /swing about the point 30, 8 of the widget's picture/)
  assert.match(ownWhy, /Take the ui\.Motion away\. In the draw function wrap only the shapes that turn in gfx\.moving\("swing", 0, 30, 8, /)
  // A ui.Motion around only the part, in a ui.Layers over the case, is right.
  const layered = clock.replace('function widget(', `function caseOnly(state: AppState): gfx.Shape[] { return caseShapes(); }
function bobOnly(state: AppState): gfx.Shape[] { return bob(state); }

function widget(`).replace('ui.Surface("default", 100, 100, "clockCard", "", ""),\n      ui.Text', 'ui.Layers("default", 100, 100, [ui.Surface("default", 100, 100, "caseOnly", "", ""), ui.Motion("swing", 0, [ui.Surface("clear", 100, 100, "bobOnly", "", "")])]),\n      ui.Text')
  assert.equal(validateWidgetRefinement(withoutWidget(layered), layered, compileVeraSource(layered).vbc2), '', 'a Motion around only the bob passes')

  // Two things turning about different points (a dial's hand and the pendulum): the part is the one most of the moving points turn with, and
  // the hand is in neither list.
  const handed = clock.replace('  let shapes: gfx.Shape[] = caseShapes();\n  for (let s: gfx.Shape of bob(state)) { shapes.push(s); }',
    '  let shapes: gfx.Shape[] = caseShapes();\n  shapes.push(gfx.line(50, 40, 50 + 10 * math.sin(state.t * 0.3), 40 - 10 * math.cos(state.t * 0.3), 1, "#ffffff"));\n' +
    '  for (let s: gfx.Shape of bob(state)) { shapes.push(s); }')
  assert.notEqual(handed, clock)
  const both = appMovingPart(compileVeraSource(handed).vbc2, '')
  assert.deepEqual([both.pivotX, both.pivotY, both.moving, both.still], [50, 18, [4, 5], [0, 1, 2]], 'the pendulum, not the hand')

  // The wheel sits still until it is spun: the touch on its picture sets it going, and its slices, a group, turn round its centre.
  const wheel = fs.readFileSync(path.join(__dirname, 'examples/widget-wheel.vera'), 'utf8')
  const spun = appMovingPart(compileVeraSource(wheel).vbc2, '')
  assert.deepEqual([spun.draw, spun.style, spun.pivotX, spun.pivotY, spun.anchorKind, spun.anchorPoint], ['wheel', 'spin', 50, 52, 'group', 0],
    'the wheel turns round the origin of its group')
  const naive = wheel.replace('"wheelCard", "", "onTouch"', '"wheel", "", "onTouch"')
  assert.match(validateWidgetRefinement(withoutWidget(naive), naive, compileVeraSource(naive).vbc2),
    /these shapes turn round about the point 50, 52 of the widget's picture: the gfx\.group in #f87171, #fbbf24, #34d399; and these stay where they are: the gfx\.circle in white and the gfx\.polygon in #1f2937\. On the card nothing in the picture moves\.[\s\S]*gfx\.moving\("spin", 0, 50, 52,/)
  // A rocket that rises is not a turn: nothing is asked of its widget.
  const rocket = fs.readFileSync(path.join(__dirname, 'examples/widget-countdown-rocket.vera'), 'utf8')
  assert.equal(appMovingPart(compileVeraSource(rocket).vbc2, ''), null, 'a rise is not a turn')
  // A part is not guessed from too little: one look, or nothing that stays.
  assert.equal(partFromLooks([[]], 100, 100), null)
}

// Many of the same is one gfx.repeat: the prompt says so beside the card's shape limit, and the bubble wrap example's widget passes.
{
  assert.match(widgetRefinementPrompt(false), /At most 60 shapes and 5 pictures \(ui\.Surface or ui\.Sparkline\) in all; many of the same \(bubbles, bricks, stars in a grid\) is one gfx\.repeat\(columns, rows, dx, dy/)
  const bubbles = fs.readFileSync(path.join(__dirname, 'examples/widget-bubbles.vera'), 'utf8')
  assert.equal(validateWidgetRefinement(withoutWidget(bubbles), bubbles, compileVeraSource(bubbles).vbc2), '', 'the bubble wrap widget passes')
  // A touch in the middle of the sheet falls between four bubbles and pops none; one a little off it pops one, so the touch shows.
  const exact = bubbles.replace('let at: number = row * 12 + column;',
    'if (gfx.distance(p.x, p.y, column * 10 + 5, row * 10 + 5) > 4.2) { return state; }\n  let at: number = row * 12 + column;')
  assert.notEqual(exact, bubbles)
  assert.equal(validateWidgetRefinement(withoutWidget(exact), exact, compileVeraSource(exact).vbc2), '', 'a touch between bubbles is not the only one tried')
}

// A picture that takes a touch and shows nothing for it -- no movement, the same card after the tap -- is refused.
{
  const rocket = fs.readFileSync(path.join(__dirname, 'examples/widget-countdown-rocket.vera'), 'utf8')
  assert.equal(validateWidgetRefinement(withoutWidget(rocket), rocket, compileVeraSource(rocket).vbc2), '', 'a tap that launches the rocket on the card passes')
  const inert = rocket.replace('if (p.phase !== "up" || state.launching) { return state; }', 'return state;')
  assert.notEqual(inert, rocket)
  assert.match(validateWidgetRefinement(withoutWidget(inert), inert, compileVeraSource(inert).vbc2), /A touch on the picture changes nothing you can see/)
  // A rocket that flies up and lands back on its pad in the app's frames is drawn on its pad again; a launch count beside it that rose is not
  // the picture answering. Wrapped in gfx.moving("launch") it moves on the card.
  const back = fs.readFileSync(path.join(__dirname, 'examples/widget-return-rocket.vera'), 'utf8')
  assert.match(validateWidgetRefinement(withoutWidget(back), back, compileVeraSource(back).vbc2), /A touch on the picture changes nothing you can see[\s\S]*comes back is drawn where it started/)
  const rocketShapes = 'shapes.push(gfx.polygon([rx - 6, ry + 7, rx - 11, ry + 14, rx - 6, ry + 12], "#e0453f"));'
  const moving = back.replace(rocketShapes, 'let body: gfx.Shape[] = [];\n  ' + rocketShapes.replace('shapes.push', 'body.push'))
    .replace('shapes.push(gfx.polygon([rx + 6, ry + 7', 'body.push(gfx.polygon([rx + 6, ry + 7')
    .replace('shapes.push(gfx.roundRect(rx - 6, ry - 7', 'body.push(gfx.roundRect(rx - 6, ry - 7')
    .replace('shapes.push(gfx.polygon([rx - 6, ry - 6', 'body.push(gfx.polygon([rx - 6, ry - 6')
    .replace('shapes.push(gfx.circle(rx, ry - 1, 3,', 'body.push(gfx.circle(rx, ry - 1, 3,')
    .replace('shapes.push(gfx.circle(rx, ry - 1, 1.5, "#bfe6ff"));\n  return shapes;',
      'body.push(gfx.circle(rx, ry - 1, 1.5, "#bfe6ff"));\n  shapes.push(gfx.moving("launch", state.c_launches, 50, 80, body));\n  return shapes;')
  assert.notEqual(moving, back)
  assert.equal(validateWidgetRefinement(withoutWidget(moving), moving, compileVeraSource(moving).vbc2), '', 'the rocket as a gfx.moving part passes')
}

// A text drawn in a cover picture where a wide card cuts it off (a frog's score at the bottom of its pond, gone on 2x4) is sent back
// with the part that is seen; the same text in the middle band passes.
{
  const pond = (y) => 'import * as ui from "std/ui"\nimport * as gfx from "std/gfx"\n@jsonable class AppState { n: number; }\n' +
    'function init(): AppState { return {n: 3}; }\n' +
    'function pond(state: AppState): gfx.Shape[] { return [gfx.rect(0, 0, 100, 100, "#2a9d8f"), gfx.circle(50, 50, 20, "#8ee06a"), ' +
    'gfx.text(8, ' + y + ', 10, "left", "#0d3b32", "Pads " + ui.numberToString(state.n), true)]; }\n' +
    'function view(state: AppState): ui.View { return ui.Surface("cover", 100, 100, "pond", "", ""); }\n' +
    'function widget(state: AppState): ui.View { return ui.AppTheme("playful", "", [ui.Surface("cover", 100, 100, "pond", "", "")]); }\n'
  const low = pond(92)
  assert.match(validateWidgetRefinement(withoutWidget(low), low, compileVeraSource(low).vbc2),
    /The text "Pads 3" drawn in the cover picture is cut off on a 2x4 card[\s\S]*y 27\.2 to 72\.8[\s\S]*ui\.Text/)
  const middle = pond(60)
  assert.equal(validateWidgetRefinement(withoutWidget(middle), middle, compileVeraSource(middle).vbc2), '', 'a text in the middle band is seen on every card')
}

// A picture that paints its own background is a scene: Make widget asks for it as a cover picture, so it is not a square in the middle of the card.
{
  const rich = fs.readFileSync(path.join(__dirname, 'examples/widget-rich.vera'), 'utf8')
  const richBase = withoutWidget(rich)
  assert.notEqual(richBase, rich)
  assert.match(validateWidgetRefinement(richBase, rich, compileVeraSource(rich).vbc2), /paints its own background[\s\S]*ui\.Surface\("cover", 100, 100/)
  const widgetPicture = 'ui.Surface("default", 100, 100, "scene", "", "onTouch"),\n      ui.Text'
  const covered = rich.replace(widgetPicture, 'ui.Surface("cover", 100, 100, "scene", "", "onTouch"),\n      ui.Text')
  assert.notEqual(covered, rich)
  assert.equal(validateWidgetRefinement(richBase, covered, compileVeraSource(covered).vbc2), '', 'as a cover picture it passes')
  // A ui.Motion around a scene moves its background too: the reason asks for the thing to move as a gfx.moving part instead.
  const sky = '@jsonable class AppState { n: number; }\nfunction init(): AppState { return {n: 0}; }\n' +
    'function sky(state: AppState): gfx.Shape[] { return [gfx.rect(0, 0, 100, 100, "#123456"), gfx.circle(50, 50, 10, "accent")]; }\n' +
    'function view(state: AppState): ui.View { return ui.Text("body", "x"); }\n'
  const skyWidget = style => sky + 'function widget(state: AppState): ui.View { return ui.Column("center", [ui.Motion("launch", 0, [ui.Surface("' + style + '", 100, 100, "sky", "", "")]), ui.Text("caption", "hi")]); }\n'
  assert.match(validateWidgetRefinement(sky, skyWidget('cover'), compileVeraSource(skyWidget('cover')).vbc2),
    /ui\.Motion\("launch"\) moves the whole scene[\s\S]*gfx\.moving\("launch", 0, pivotX, pivotY/)
  const both = validateWidgetRefinement(sky, skyWidget('default'), compileVeraSource(skyWidget('default')).vbc2)
  assert.match(both, /moves the whole scene[\s\S]*Make the picture ui\.Surface\("cover", 100, 100/, 'one reason for both, so one retry fixes both: ' + both)
  const object = rich.replace('shapes.push(gfx.rect(0, 0, 100, 100, gfx.linear(0, 0, 0, 100, ["#1e1b4b", "#7c3aed", "#f472b6"])));', '')
  assert.equal(validateWidgetRefinement(withoutWidget(object), object, compileVeraSource(object).vbc2), '', 'a single object with no background rect passes')
  assert.match(widgetRefinementPrompt(false), /MAKE IT LOOK GOOD[\s\S]*gfx\.radial[\s\S]*ui\.Surface\("cover"/)
}
for (const altered of [candidate.replace('function widget(state: AppState)', 'async function widget(state: AppState)'),candidate.replace('function widget(state: AppState)', 'function widget(state: number)'),candidate.replace('function widget(state: AppState): ui.View', 'function widget(state: AppState): AppState')]) {
  assert.throws(()=>compileVeraSource(altered),/E2115/)
}
// The signature error is at the widget's own line, not the whole program's.
{
  const altered = candidate.replace('function widget(state: AppState)', 'async function widget(state: AppState)')
  let diagnostics = []
  try { compileVeraSource(altered) } catch (e) { diagnostics = e.diagnostics }
  const d = diagnostics.find(x => x.code === 'E2115')
  assert(d, 'E2115'); assert.equal(d.span.start.line, altered.split('\n').findIndex(l => l.includes('async function widget')) + 1)
}
const unsafe = candidate.replace('return compact(state); }\nfunction widget','return compact(state); }\nfunction widget')
  .replace('function widget(state: AppState): ui.View { return compact(state); }','function widget(state: AppState): ui.View { return ui.Image("default", "url", "alt"); }')
assert.match(smokeRun(compileVeraSource(unsafe)),/home-screen widget [\s\S]*Not card-safe/)
const saved = new WidgetSession(compiled.vbc2,'v','')
let frame = saved.frame('p','App','')
saved.tap(frame,frame.token,'change',1)
assert.equal(validateWidgetRefinement(base,candidate,compiled.vbc2,saved.encodedState()),'')
const prompt = widgetRefinementPrompt(), {CATALOG} = loadVera('VeraUiCatalog')
for (const component of CATALOG) {
  assert.equal(prompt.includes('  ui.' + component.name + '('),component.card,component.name)
}
assert.match(prompt,/100000 VM steps/)
assert.match(prompt,/8000 UTF-16/)
// What a widget is: the same state, what the person asked for, only the few things that matter.
assert.match(prompt,/draws the very state view\(state\) draws/)
assert.match(prompt,/request says what it should show/)
assert.match(prompt,/one to three figures/)
assert.match(prompt,/at most two buttons/)
// The reply's rewrite of an existing declaration is not taken; its widget, new helpers and new imports are.
const rewritten = 'import * as math from "std/math"\n' + base.replace('state.count + value', 'state.count + value * 2') +
  '\nfunction twice(n: number): number { return n * 2; }' + addition
const spliced = spliceWidget(base, rewritten)
assert.equal(widgetRefinementError(base, spliced), '')
assert.match(spliced, /state\.count \+ value \}/)
assert.doesNotMatch(spliced, /value \* 2/)
assert.match(spliced, /function twice/)
assert.match(spliced, /^import \* as math from "std\/math"/)
assert.equal(validateWidgetRefinement(base, spliced, compileVeraSource(spliced).vbc2), '')
// A widget already there is replaced; a reply that does not parse is left for the compiler.
assert.equal((spliceWidget(candidate, base + '\nfunction widget(state: AppState): ui.View { return ui.Text("body", "new"); }').match(/function widget/g) || []).length, 1)
assert.equal(spliceWidget(base, 'not a program {'), 'not a program {')
// A missing field is explained: the app's state is kept as it is.
assert.match(widgetRepairNote('3:5 E2031 class AppState has no field doneToday'), /cannot add fields to the state/)
assert.equal(widgetRepairNote('3:5 E2036 expected 5 arguments, found 4'), '3:5 E2036 expected 5 arguments, found 4')
// widgetRefresh: its own signature (E2113); one that keeps changing the state is refused; it belongs to the widget.
const daily = fs.readFileSync(path.join(__dirname,'examples/widget-daily.vera'),'utf8')
const dailyBase = daily.replace(/function widget\(state[\s\S]*$/, '')
assert.equal(validateWidgetRefinement(dailyBase, daily, compileVeraSource(daily).vbc2), '')
assert.throws(() => compileVeraSource(daily.replace('function widgetRefresh(state: AppState): AppState', 'function widgetRefresh(state: AppState, v: number): AppState')), /E2113/)
const adds = daily.replace('return state; }', 'return {count: state.count + 1, day: state.day}; }')
assert.match(validateWidgetRefinement(dailyBase, adds, compileVeraSource(adds).vbc2), /changed the state again/)
assert.doesNotMatch(spliceWidget(daily, dailyBase + 'function widget(state: AppState): ui.View { return ui.Text("body", "x"); }'), /widgetRefresh/)
assert.match(prompt, /widgetRefresh/)
// A widget is a glance: a button per item is refused with the reason, for the next attempt.
const crowded = base + '\nfunction widget(state: AppState): ui.View { return ui.Column("default", [ui.Button("default", "+1", "change", 1, true), ' +
  'ui.Button("default", "+2", "change", 2, true), ui.Button("default", "+3", "change", 3, true)]); }'
assert.match(validateWidgetRefinement(base, crowded, compileVeraSource(crowded).vbc2), /3 buttons; a 2x2 widget has at most 2/)
// An app whose own screen is drawn by widget(state) would change with a new widget: Make widget is refused for it, before and
// after the model answers.
{
  const {appUsesWidgetError} = loadVera('VeraCompiler')
  assert.match(appUsesWidgetError(source), /own view calls widget\(\)/)
  assert.equal(appUsesWidgetError(base), '')
  assert.equal(appUsesWidgetError(candidate), '', 'the widget calling its own helpers is the widget\'s business')
  const viaRefresh = base + '\nfunction widgetRefresh(state: AppState): AppState { return state; }\nfunction reset(state: AppState, v: number): AppState { return widgetRefresh(state); }'
  assert.match(appUsesWidgetError(viaRefresh), /own reset calls widgetRefresh\(\)/)
  assert.match(widgetRefinementError(source, source.replace('ui.Text("caption", "COUNTER"),', '')), /own view calls widget/)
}
console.log('PASS widget refinement: additive preservation, signature, catalogue prompt, smoke/repair diagnostics, saved-state validation, glance limits, splice, widgetRefresh')

// Make widget writes only the widget (agent/AgentWidget.ets): the program is shown, never written again; a failing answer goes
// back with its reason and the next one is taken.
;(async () => {
  const {AgentHost} = loadVera('agent/AgentHost')
  const W = loadVera('agent/AgentWidget')
  const only = widgetRefinementPrompt(false)
  assert.match(only, /Answer with only what the widget adds/)
  assert.doesNotMatch(only, /Return the complete program/)
  const asked = []
  const replies = [
    'function widget(state: AppState): ui.View { return ui.Column("default", [ui.Text("body", "Count"), ui.Button("default", "+", "change", 1, true), ' +
      'ui.Button("default", "+2", "change", 2, true), ui.Button("default", "+3", "change", 3, true)]); }',
    '```vera\nfunction widget(state: AppState): ui.View { return compact(state); }\n```'
  ]
  const host = new AgentHost()
  host.language = 'Language.\n{{UI_CATALOG}}\nVISUAL COMPOSITION\nfull screens\nClock -- time. rest'
  host.askCode = async (system, user, budget, think) => { asked.push({system, user, budget, think}); return replies.shift() }
  const made = await W.writeWidget(base, 'the count and a plus button', 'a counter', '', host)
  assert.equal(made.failed, ''); assert.equal(made.attempts, 2)
  assert.equal(made.source, spliceWidget(base, 'function widget(state: AppState): ui.View { return compact(state); }'))
  assert.equal(validateWidgetRefinement(base, made.source, made.vbc2), '')
  assert(asked[0].system.includes('ui.NumberText(') && !asked[0].system.includes('ui.Image('), 'only the card kinds are shown')
  assert(!asked[0].system.includes('full screens'), 'the advice on full screens is left out')
  assert(asked[0].budget <= W.WIDGET_TOKENS && !asked[0].think)
  assert.match(asked[0].user, /The home-screen widget should show: the count and a plus button/)
  assert.match(asked[1].user, /3 buttons; a 2x2 widget has at most 2/)
  const none = new AgentHost(); none.language = host.language
  none.askCode = async () => 'function helper(): number { return 1; }'
  const refused = await W.writeWidget(base, 'x', 'a counter', '', none)
  assert.equal(refused.source, ''); assert.equal(refused.attempts, 3); assert.match(refused.failed, /no function widget/)
  // The last answer thinks, and its reasoning counts in the same limit: it gets a larger one. An answer the limit cut off is said to be one.
  assert(asked.length === 2 && !asked[1].think)
  const thinking = new AgentHost(); thinking.language = host.language
  const budgets = []
  thinking.askCode = async (system, user, budget, think) => {
    budgets.push([budget, think]); thinking.lastCodeFinish = 'length'
    return 'function widget(state: AppState): ui.View { return ui.Column("default", [ui.Text("body", "x")'
  }
  const cutOff = await W.writeWidget(base, 'x', 'a counter', '', thinking)
  assert.deepEqual(budgets, [[W.WIDGET_TOKENS, false], [W.WIDGET_TOKENS, false], [W.WIDGET_THINKING_TOKENS, true]])
  assert(W.WIDGET_THINKING_TOKENS >= 4 * W.WIDGET_TOKENS)
  assert.match(cutOff.failed, /cut off at the length limit/)
  // The host's checker is used when it has one (the app's runs off the UI thread).
  const checked = new AgentHost(); checked.language = host.language
  checked.askCode = async () => 'function widget(state: AppState): ui.View { return compact(state); }'
  const seen = []
  checked.checkWidget = async (b, program, saved) => { seen.push(saved); return '' }
  const viaHost = await W.writeWidget(base, 'x', 'a counter', 'SAVED', checked)
  assert.equal(viaHost.failed, ''); assert.deepEqual(seen, ['SAVED'])
  console.log('PASS widget written alone: card kinds only, spliced into the program, failure fed back, three answers at most')
})().catch(e => { console.error(e); process.exit(1) })

// A program with a live source: widgetRefresh may ask for Vera.Source.fetch (and only that), its handler takes a failure and
// still draws; the address cannot be built from the state (E2114).
{
  const live = fs.readFileSync(path.join(__dirname, 'examples/widget-source.vera'), 'utf8')
  const c = compileVeraSource(live)
  assert.equal(smokeRun(c), '')
  assert.equal(checkWidget(c.vbc2), '')
  const other = live.replace('function widgetRefresh(state: AppState): AppState { return fetchNow(state, time.nowSeconds()); }',
    'function widgetRefresh(state: AppState): AppState { sdk.call("ohos.vibrator.startVibration", ["duration", "100"], "onSource"); return state; }')
  assert.notEqual(other, live)
  assert.match(checkWidget(compileVeraSource(other).vbc2), /phone action/)
  const built = live.replace('["url", "https://iss.moex.com', '["url", state.note + "https://iss.moex.com')
  assert.throws(() => compileVeraSource(built), /E2114/)
  assert.match(widgetRefinementPrompt(false), /Vera\.Source\.fetch/)
  console.log('PASS live source on a widget: widgetRefresh may fetch the source only, its address is literal')
}

// An import closed with a semicolon, as TypeScript writes one, is taken; any other answer that does not parse is sent back with
// the parser's own message, not a guess.
;(async () => {
  const {AgentHost} = loadVera('agent/AgentHost')
  const W = loadVera('agent/AgentWidget')
  const host = new AgentHost(), asked = []
  host.language = 'Language.\n{{UI_CATALOG}}\nVISUAL COMPOSITION\nClock -- time. rest'
  const replies = ['function widget(state: AppState): ui.View { return compact(state) }}',
    'import * as time from "std/time";\nfunction widget(state: AppState): ui.View { return compact(state); }']
  host.askCode = async (system, user) => { asked.push(user); return replies.shift() }
  const made = await W.writeWidget(base, 'the count', 'a counter', '', host)
  assert.equal(made.failed, ''); assert.equal(made.attempts, 2)
  assert.match(asked[1], /The answer does not parse: /)
  assert.doesNotMatch(asked[1], /has no function widget/)
  assert.match(made.source, /^import \* as time from "std\/time"$/m)
  console.log('PASS widget answers: an import with a semicolon is taken, a parse error is passed on as it is')
})().catch(e => { console.error(e); process.exit(1) })

  // A drum on the card whose handler vibrates: the tap would be refused on the card, so Make widget sends it back (found on a phone).
{
  const drum = fs.readFileSync(path.join(__dirname, 'examples/widget-drum.vera'), 'utf8')
  assert.equal(checkWidget(compileVeraSource(drum).vbc2), '')
  const buzzing = 'import * as sdk from "std/sdk"\n' + drum.replace('return { hits: state.hits + value };',
    'sdk.call("SensorServiceKit.vibrator.vibrate", ["duration", "60"], "buzzed"); return { hits: state.hits + 1 };') +
    '\nfunction buzzed(state: AppState, value: string): AppState { return state; }'
  const message = checkWidget(compileVeraSource(buzzing).vbc2)
  assert.match(message, /makes a phone call/)
  assert.match(message, /NEW handler/)
  assert.match(widgetRefinementPrompt(), /must not make phone calls/)
}
// A drum that jumps when it is hit: ui.Motion is a card kind with the presets a card can play, and the prompt says so.
{
  const motion = fs.readFileSync(path.join(__dirname, 'examples/widget-drum-motion.vera'), 'utf8')
  assert.equal(checkWidget(compileVeraSource(motion).vbc2), '')
  assert.match(widgetRefinementPrompt(), /ui\.Motion\(style, 0, \[the picture\]\)/)
  assert.match(widgetRefinementPrompt(), /NEVER a ui\.Path/, 'a drawing of several colours is a Surface, not a Path')
  assert.match(widgetRefinementPrompt(), /should DO what that thing does/)
  assert.match(widgetRefinementPrompt(), /Every touch on the picture plays the movement by itself/)
  assert.match(widgetRefinementPrompt(), /MOVING PARTS[\s\S]*gfx\.moving\(style, 0, pivotX, pivotY/)
  assert.match(widgetRefinementPrompt(), /Do NOT add a counter to the state/)
  for (const preset of require('./source-loader').loadVera('VeraMotion').MOTION_PRESETS) assert.ok(widgetRefinementPrompt().includes(preset), 'the prompt names ' + preset)
  assert.match(widgetRefinementPrompt(), /cannot loop/)
  assert.equal(checkWidget(compileVeraSource(motion.replace('"pop"', '"spin"')).vbc2), '', 'a turning preset plays on a card')
}
// A picture on the card (ui.Surface): described to the model, its tap held to the same rules as a button's.
{
  const panda = fs.readFileSync(path.join(__dirname, 'examples/widget-panda.vera'), 'utf8')
  assert.equal(checkWidget(compileVeraSource(panda).vbc2), '')
  assert.match(widgetRefinementPrompt(), /ui\.Surface\(style, width, height, "draw", "", "touch"\)/)
  assert.match(widgetRefinementPrompt(), /gfx\.Shape\[\]/)
  assert.match(widgetRefinementPrompt(), /a card has no frames/)
  assert(CARD_KINDS.includes('Surface'), 'Surface is a card kind')
  assert.match(widgetRefinementPrompt(), /std\/gfx \(always available as gfx/, 'the gfx functions come with it')
  const buzzing = panda.replace('if (p.phase === "down") { return { hops: state.hops + 1 }; }',
    'sdk.call("SensorServiceKit.vibrator.vibrate", ["duration", "60"], "buzzed"); if (p.phase === "down") { return { hops: state.hops + 1 }; }')
    .replace('import * as gfx from "std/gfx"', 'import * as gfx from "std/gfx"\nimport * as sdk from "std/sdk"') +
    '\nfunction buzzed(state: AppState, value: string): AppState { return state; }'
  const message = checkWidget(compileVeraSource(buzzing).vbc2)
  assert.match(message, /makes a phone call/)
  // Too much around the picture: no room for it on the card.
  const cut = panda.indexOf('function widget(')
  const tall = panda.substring(0, cut) + panda.substring(cut).replace('ui.NumberText("metric", state.hops, "", " hops", 1)',
    'ui.NumberText("metric", state.hops, "", " hops", 1), ui.Text("caption", "a"), ui.Text("caption", "b"), ui.Text("caption", "c")')
  assert.match(validateWidgetRefinement(panda, tall, compileVeraSource(tall).vbc2), /too much around its picture/)
  // The picture's tap is one of the two buttons.
  const at = panda.indexOf('function widget(')
  const three = panda.substring(0, at) + 'function pandaCount(state: AppState, value: number): AppState { return { hops: state.hops + value }; }\n' +
    panda.substring(at).replace('ui.NumberText("metric", state.hops, "", " hops", 1)',
      'ui.Button("primary", "A", "pandaCount", 1, true), ui.Button("primary", "B", "pandaCount", 2, true)')
  assert.match(validateWidgetRefinement(panda, three, compileVeraSource(three).vbc2), /3 buttons/)
}
// Styles reach the model, and a widget clearly taller than the card is refused with the reason.
{
  assert.match(widgetRefinementPrompt(), /STYLES\. A text style is drawn as the app draws it/)
  assert.match(widgetRefinementPrompt(), /eyebrow \(a small spaced label/)
  const styles = fs.readFileSync(path.join(__dirname, 'examples/widget-styles.vera'), 'utf8').replace(/\r\n/g, '\n')
  const at = styles.indexOf('function widget(')
  const lines = n => Array.from({length: n}, (_, i) => 'ui.Text("display", "big ' + i + '")').join(', ')
  const tall = styles.substring(0, at) + styles.substring(at).replace('ui.Column("accent", [\n        ui.Text("caption", "3 of 5 done")\n      ])', lines(3))
  assert.match(validateWidgetRefinement(styles, tall, compileVeraSource(tall).vbc2), /vp tall and the 2x2 card is 126/)
}
// An icon button is one of the two buttons; the new kinds are on the card list and in the prompt.
{
  const water = fs.readFileSync(path.join(__dirname, 'examples/widget-water.vera'), 'utf8')
  assert.equal(checkWidget(compileVeraSource(water).vbc2), '')
  for (const kind of ['Icon', 'IconButton', 'Badge', 'Progress', 'ProgressRing', 'Stat', 'NumberStat', 'MetricGroup', 'Sparkline']) assert(CARD_KINDS.includes(kind), kind + ' is a card kind')
  const at = water.indexOf('function widget(')
  const three = water.substring(0, at) + water.substring(at).replace('ui.IconButton("primary", "plus", "More", "add", 1, true)',
    'ui.IconButton("primary", "plus", "More", "add", 1, true), ui.IconButton("danger", "trash", "Clear", "remove", 1, true)')
  assert.match(validateWidgetRefinement(water, three, compileVeraSource(three).vbc2), /3 buttons/)
  assert.match(widgetRefinementPrompt(), /ICONS AND DATA/)
}
// A timer is a card kind and the prompt says when to use it.
{
  assert(CARD_KINDS.includes('Timer'), 'Timer is a card kind')
  assert.match(widgetRefinementPrompt(), /TIME THAT MOVES\. ui\.Timer\(style, millis, down\) runs by itself/)
  assert.equal(checkWidget(compileVeraSource(fs.readFileSync(path.join(__dirname, 'examples/widget-timer.vera'), 'utf8')).vbc2), '')
}
// A widget that takes the card's size is held to the limits of every size; the prompt says how to ask for it.
{
  const sized = fs.readFileSync(path.join(__dirname, 'examples/widget-sizes.vera'), 'utf8')
  assert.equal(checkWidget(compileVeraSource(sized).vbc2), '')
  assert.match(widgetRefinementPrompt(), /CARD SIZES\. The card is 2x2 by default/)
  assert.match(widgetRefinementPrompt(), /function widget\(state, size: number\): ui\.View/)
  const at = sized.indexOf('function widget(')
  const crowded = sized.substring(0, at) + sized.substring(at).replace('rows.push(ui.Row("split", [ui.Text("muted", "left"), ui.Text("danger", "late")]));',
    'rows.push(ui.Column("default", [' + Array.from({length: 13}, (_, i) => 'ui.Text("caption", "c' + i + '")').join(', ') + ']));')
  assert.match(validateWidgetRefinement(sized, crowded, compileVeraSource(crowded).vbc2), /a 2x4 widget shows at most 12/)
  // A button only the 4x4 card shows is pressed there too: one that makes a phone call is sent back.
  const buzzing = 'import * as sdk from "std/sdk"\n' + sized.replace('return { done: state.done + value };',
    'sdk.call("SensorServiceKit.vibrator.vibrate", ["duration", "60"], "buzzed"); return { done: state.done + value };') +
    '\nfunction buzzed(state: AppState, value: string): AppState { return state; }'
  assert.match(checkWidget(compileVeraSource(buzzing).vbc2), /"more" makes a phone call/)
  // What the prompt says a card holds is what the card holds.
  const prompt = widgetRefinementPrompt()
  assert.doesNotMatch(prompt, /three pictures|no overlap/)
  assert.match(prompt, /a 2x4 has room for up to 4 buttons and 12 texts, a 4x4 has room for up to 6 buttons and 24 texts/)
  assert.match(prompt, /5 pictures \(ui\.Surface or ui\.Sparkline\) in all/)
  assert.match(prompt, /one of the two buttons/)
  const surface = require('./source-loader').loadVera('VeraUiCatalog').CATALOG.find(c => c.name === 'Surface').guidance
  assert.doesNotMatch(surface, /One Surface at most/); assert.match(surface, /Up to 5 pictures on a card/)
  const badParam = sized.replace('function widget(state: AppState, size: number)', 'function widget(state: AppState, size: string)')
  assert.throws(() => compileVeraSource(badParam), /E2115/)
}
// ui.Layers: in the prompt, and a widget that uses it passes the glance checks.
{
  assert.match(widgetRefinementPrompt(), /LAYERS\. A subject made of parts that move differently/)
  assert.equal(checkWidget(compileVeraSource(fs.readFileSync(path.join(__dirname, 'examples/widget-layers.vera'), 'utf8')).vbc2), '')
}
// A control the first tap takes away is not tapped a second time: a box shown only while the task is open is a valid widget.
{
  const once = fs.readFileSync(path.join(__dirname, 'examples/widget-switch.vera'), 'utf8').replace(/function widget\(state: AppState\): ui\.View \{[\s\S]*$/, 'function widget(state: AppState): ui.View {\n' +
    '  if (state.done) { return ui.AppTheme("soft", "", [ui.Column("default", [ui.Text("eyebrow", "DONE")])]); }\n' +
    '  return ui.AppTheme("soft", "", [ui.Column("default", [ui.Checkbox("default", "Done", state.done, "setDone")])]);\n}\n')
  assert.equal(checkWidget(compileVeraSource(once).vbc2), '')
}

;(async () => {
  const ts = require(process.env.VERA_TYPESCRIPT_PATH || 'typescript')
  const {hasWidgetFunction} = loadVera('WidgetStatus')
  const {veraStateStamp} = loadVera('VeraStateStamp')
  const {withoutWidgetRequests} = loadVera('ProjectText')
  const {WIDGET_ASK} = loadVera('agent/AgentWidget')
  const pageSource = fs.readFileSync(path.join(sourceRoot, 'pages/GeneratePage.ets'), 'utf8')
  const {OperationController, throwIfCancelled} = loadVera('OperationCancellation')
  const {GenerateRequest, GenerateResult} = loadVera('LlamaEngine')
  const names = ['aboutToAppear', 'makeWidgetAlone', 'doServerGenerate', 'commitSave', 'widgetSaveState', 'checkWidgetSave', 'hasResult', 'versionCount',
    'modelRequestHistory', 'prepareRequest', 'acceptRequest', 'doRefine', 'refineWithModel', 'startAttemptOne', 'runAttempt', 'callModel']
  const methods = names.map(name => {
    const match = pageSource.match(new RegExp('^  (?:private )?(?:async )?' + name + '\\([^\\{]*\\{[\\s\\S]*?^  \\}', 'm'))
    assert(match, 'GeneratePage.' + name + ' must exist')
    return match[0]
  })
  const declarations = ['class ServerDecodedResponse', 'class RefineRequest', 'class AttemptMetrics', 'class RunTotals',
    'class SourceDelta', 'function diffLines', 'function decodeServerResponse'].map(name => {
    const match = pageSource.match(new RegExp('^' + name + '\\b[\\s\\S]*?^\\}', 'm'))
    assert(match, name + ' must exist')
    return match[0]
  })
  const transpiled = ts.transpileModule(declarations.join('\n') + '\nclass GeneratePage {\n' + methods.join('\n') + '\n}', {
    compilerOptions: {target: ts.ScriptTarget.ES2020}, reportDiagnostics: true
  })
  assert.deepEqual((transpiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error), [])
  function fixture(original, fresh = true) {
    const initial = {id: 'v1', source: original, vbc2: compileVeraSource(original).vbc2,
      prompt: 'A counter\n\nRefinement:\n' + WIDGET_ASK + 'Old widget', composition: '', origin: '', lastPrompt: '', note: ''}
    const versions = [initial], writes = [], saves = [], stateReads = [], serverRequests = [], localRequests = []
    let latest = initial, failSave = false, failWrite = false, savedState = '', serverResponse, localResponse = ''
    const store = {
      init() {}, listVersions: () => versions, getVersion: (project, id) => versions.find(v => v.id === id) || null,
      getLatestVersion: () => latest, getProject: () => ({name: 'Counter'}),
      loadState(project, id, stamp) { stateReads.push({id, stamp}); return savedState },
      createVersion(...args) {
        if (failSave) { throw Error('disk full') }
        saves.push(args)
        latest = {id: 'v' + (versions.length + 1), source: args[1], vbc2: args[2]}
        versions.unshift(latest)
        return latest
      }
    }
    const dependencies = {
      store, appUsesWidgetError, withoutWidget, hasWidgetFunction, veraStateStamp, validateWidgetRefinement,
      widgetRefinementError: loadVera('VeraCompiler').widgetRefinementError,
      validateWidgetOffMain: async (...args) => validateWidgetRefinement(...args),
      compileVeraSource, spliceWidget, smokeRun, widgetRefinementPrompt, Curve: {EaseInOut: 'ease-in-out'},
      serverUrl: () => 'http://fixture.invalid', http: {RequestMethod: {POST: 'POST'}, createHttp: () => ({
        async request(url, options) { serverRequests.push({url, ...options}); assert(serverResponse); return serverResponse },
        destroy() {}
      })},
      withoutWidgetRequests, WIDGET_ASK, TAB_WIDGET: 'widget', TAB_PREVIEW: 'preview', KeyboardAvoidMode: {RESIZE: 'resize'},
      settings: {init() {}, getMode: () => 'DeepSeek', getModel: () => 'test', useJevProxy: () => false,
        hasServerUrl: () => true, getBaseUrl: () => 'https://fixture.invalid'},
      MODE_DEEPSEEK: 'DeepSeek', MODE_LOCAL: 'Local', MODE_SERVER: 'Server', UI_SELECT_MODE: 'full', UI_SELECT_FULL: 'full',
      MAX_RETRIES: 3, GenerateRequest, GenerateResult, throwIfCancelled,
      CompileError: loadVera('VeraCompiler').CompileError, widgetRepairNote,
      logStep() {}, logMark() {}, traceCompile() {},
      engine: {stop() {}, async generate(request) {
        localRequests.push(request)
        return Object.assign(new GenerateResult(), {text: localResponse})
      }},
      initTrace() {}, trace() {}, refreshForms() {}, appAgentHost: () => ({}),
      window: {getLastWindow: async () => ({on() {}})},
      async writeWidget(program, ask, history, state) {
        writes.push({program, ask, history, state})
        if (failWrite) { return {source: '', failed: 'try again', attempts: 3, ms: 0, written: ''} }
        const written = 'import * as math from "std/math"\n' +
          'function newFigure(state: AppState): number { return state.count + 1; }\n' +
          'function widget(state: AppState): ui.View { return ui.NumberText("metric", newFigure(state), "", "", 1); }'
        const source = spliceWidget(program, written), vbc2 = compileVeraSource(source).vbc2
        assert.equal(validateWidgetRefinement(program, source, vbc2, state), '')
        return {source, vbc2, failed: '', attempts: 1, ms: 0, written}
      }
    }
    const prototype = new Function(...Object.keys(dependencies), transpiled.outputText + '\nreturn GeneratePage.prototype;')
      (...Object.values(dependencies))
    const page = Object.assign(Object.create(prototype), {
      params: {projectId: 'project', baseVersionId: 'v1', makeWidget: '1', widgetFresh: fresh ? '1' : ''},
      widgetBase: '', widgetFresh: false, disposed: false, generating: false, runId: 0, baseError: '',
      requestLabel: '', liveState: '', metricTotals: {}, promptTemplate: '',
      hostContext: () => ({filesDir: '/fixture/files'}), readWidgetCards: () => 0,
      getUIContext: () => ({setKeyboardAvoidMode() {}, animateTo(options, work) { work() },
        getPromptAction: () => ({showToast() {}})}),
      loadResources: async () => {}, currentBase: () => ({}), ratePerMillion: () => 0,
      modeLabel: () => 'fixture', originLabel: () => '', copyMetrics: metrics => metrics,
      beginOperation: () => new OperationController(), resetRunMetrics() { this.attempt = 1; this.attempts = [] },
      beginMetricAttempt() {}, recordMetricResult() {}, addToProgram() {}, traceEnd() {}, currentRun: () => null,
      closeRun() {}, grammar: '', skillText: '',
      metricWork: (run, work) => work(), finishMetrics() {}, startRun() {}
    })
    page.aboutToAppear()
    return {page, initial, writes, saves, stateReads, serverRequests, localRequests,
      setServerResponse(value) { serverResponse = value }, setLocalResponse(value) { localResponse = value },
      failSave(value) { failSave = value }, failWrite(value) { failWrite = value },
      setLatest(value) { latest = value }, setState(value) { savedState = value }}
  }
  // Save as the page makes it for a widget: the card's checks (in a worker, when what Generate found no longer holds), then the commit.
  const saveWidget = async page => (await page.checkWidgetSave()) && page.commitSave()
  const oldPrograms = [
    base + '\nfunction oldFigure(state: AppState): number { return state.count; }\n' +
      'function widget(state: AppState): ui.View { return ui.NumberText("metric", oldFigure(state), "", "", 1); }',
    'import * as time from "std/time"\n' + base +
      '\nfunction widget(state: AppState): ui.View { return ui.NumberText("metric", time.nowSeconds(), "", "", 1); }'
  ]
  for (const [index, original] of oldPrograms.entries()) {
    const f = fixture(original), p = f.page, baseline = withoutWidget(original)
    assert.equal(p.widgetFresh, true)
    assert.equal(p.widgetBase, baseline, 'Redo initialization must strip widget-only declarations and imports')
    assert.doesNotMatch(baseline, index === 0 ? /oldFigure/ : /std\/time/)
    assert.equal(fixture(original, false).page.widgetBase, original, 'ordinary refinement keeps its saved baseline')
    f.failWrite(true)
    await p.makeWidgetAlone(WIDGET_ASK + 'New widget')
    assert.equal(p.widgetBase, baseline)
    assert.equal(p.compiledSource, original)
    assert.equal(p.widgetFresh, true, 'failed Redo must still retry without the old widget')
    f.failWrite(false)
    await p.makeWidgetAlone(WIDGET_ASK + 'New widget')
    assert.equal(f.writes[1].program, baseline)
    assert.doesNotMatch(f.writes[1].history, /Old widget/)
    assert.equal(p.widgetFresh, false)
    const first = p.compiledSource
    assert.doesNotMatch(first, index === 0 ? /oldFigure/ : /std\/time/)
    assert.equal(p.widgetBase, baseline, 'a successful unsaved Redo must not replace the preservation baseline')
    await p.makeWidgetAlone(WIDGET_ASK + 'Another refinement')
    assert.equal(f.writes[2].program, first)
    assert.equal(p.widgetBase, baseline, 'multiple unsaved refinements retain the original stripped baseline')
    const good = p.compiledSource
    const goodVbc2 = p.compiledVbc2
    p.compiledSource = good.replace('count: 0', 'count: 10')
    p.compiledVbc2 = compileVeraSource(p.compiledSource).vbc2
    assert.equal((await saveWidget(p)), false)
    assert.match(p.compileErrors, /preserve existing declaration init/)
    assert.equal(f.saves.length, 0)
    assert.equal(p.widgetBase, baseline, 'rejected app tampering must not advance the baseline')
    p.compiledSource = good
    p.compiledVbc2 = goodVbc2
    f.setLatest({id: 'other'})
    assert.equal((await saveWidget(p)), false, 'a concurrent app change still rejects Save')
    assert.equal(p.widgetBase, baseline)
    f.setLatest(f.initial)
    f.failSave(true)
    assert.equal((await saveWidget(p)), false)
    assert.match(p.status, /Save failed: disk full/)
    assert.equal(p.baseVersionId, f.initial.id)
    assert.equal(p.widgetBase, baseline, 'a failed persistence attempt must be retryable against the same baseline')
    f.failSave(false)
    const state = new WidgetSession(p.compiledVbc2, 'saved', '').encodedState()
    f.setState(state)
    // The state changed since the checks ran: commitSave alone refuses rather than run them on the UI thread.
    assert.equal(p.commitSave(), false, 'commitSave never runs the card checks itself')
    assert.match(p.status, /Save again/)
    assert.equal(f.saves.length, 0)
    assert.equal((await saveWidget(p)), true, 'Redo must save after intentional widget helper/import removal')
    assert.equal(f.saves.length, 1)
    assert.equal(f.saves[0][10], state, 'Save reads and preserves the latest stored app state')
    assert.equal(f.stateReads.at(-1).id, f.initial.id)
    assert.equal(p.widgetBase, good, 'only a successful save advances the preservation baseline')
    assert.equal(p.baseVersionId, 'v2')
    await p.makeWidgetAlone(WIDGET_ASK + 'Refine saved widget')
    assert.equal(f.writes.at(-1).program, good)
    assert.equal(p.widgetBase, good)
    const next = p.compiledSource, nextVbc2 = p.compiledVbc2
    p.compiledSource = spliceWidget(baseline, 'function widget(state: AppState): ui.View { return compact(state); }')
    p.compiledVbc2 = compileVeraSource(p.compiledSource).vbc2
    assert.equal((await saveWidget(p)), false, 'the next refinement must preserve helpers from the newly saved version')
    assert.match(p.compileErrors, /preserve existing declaration newFigure/)
    p.compiledSource = next.replace('import * as math from "std/math"', '')
    p.compiledVbc2 = compileVeraSource(p.compiledSource).vbc2
    assert.equal((await saveWidget(p)), false, 'the next refinement must preserve imports from the newly saved version')
    assert.match(p.compileErrors, /preserve existing imports/)
    assert.equal(p.widgetBase, good)
    p.compiledSource = next
    p.compiledVbc2 = nextVbc2
    assert.equal((await saveWidget(p)), true)
    assert.equal(f.saves.length, 2)
    assert.equal(f.saves[1][8], 'v2')
    assert.equal(f.stateReads.at(-1).id, 'v2')
    assert.equal(p.widgetBase, next)
  }
  async function submit(page, ask, mode) {
    page.mode = mode
    page.refinePrompt = ask
    page.doRefine()
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(page.generating, false, 'the fixture request must finish')
  }
  function assertFreshRequest(program, history, baseline, ask) {
    assert.equal(program, baseline, 'the model must receive the app without the old widget, helpers and imports')
    assert.match(history, /A counter/)
    assert.doesNotMatch(history, /Old widget/)
    assert(history.includes(ask), 'the current widget request must reach the model')
  }
  const serverBody = (program, bytecode = 'server bytecode') => ';vera-source-begin\n' +
    program.split('\n').map(line => ';|' + line).join('\n') + '\n;vera-source-end\n' + bytecode
  for (const original of oldPrograms) {
    const f = fixture(original), p = f.page, baseline = withoutWidget(original)
    const ask = WIDGET_ASK + 'New server widget'
    assert.equal(p.widgetFresh, true)
    for (const response of [
      {responseCode: 500, result: JSON.stringify({diagnostics: [{message: 'generation failed'}]})},
      {responseCode: 200, result: serverBody('', '')},
      {responseCode: 200, result: serverBody('function widget(state: AppState): ui.View { return missing(); }')}
    ]) {
      f.setServerResponse(response)
      await submit(p, 'New server widget', 'Server')
      const outbound = JSON.parse(f.serverRequests.at(-1).extraData)
      assertFreshRequest(outbound.previousSource, outbound.prompt, baseline, ask)
      assert.equal(p.requestHistory, f.initial.prompt, 'failure must not discard the saved request history')
      assert.equal(p.widgetFresh, true, 'a failed server Redo must keep the New widget state')
      assert.equal(p.widgetBase, baseline, 'a failed server Redo must keep the stripped preservation baseline')
      assert.equal(p.compiledSource, original)
      assert.equal(p.compiledVbc2, f.initial.vbc2)
      assert.equal(p.generating, false)
      assert.equal(f.saves.length, 0)
    }
    const reply = 'function widget(state: AppState): ui.View { return compact(state); }'
    f.setServerResponse({responseCode: 200, result: serverBody(reply)})
    await submit(p, 'New server widget', 'Server')
    const outbound = JSON.parse(f.serverRequests.at(-1).extraData)
    assertFreshRequest(outbound.previousSource, outbound.prompt, baseline, ask)
    assert.doesNotMatch(p.requestHistory, /Old widget/, 'successful Redo must replace old widget history')
    const good = spliceWidget(baseline, reply)
    assert.equal(p.status, 'Server compiled successfully')
    assert.equal(p.widgetFresh, false, 'a successful server Redo must reveal the widget and save/action controls')
    assert.equal(p.widgetBase, baseline, 'server completion must not advance the unsaved preservation baseline')
    assert.equal(p.compiledSource, good)
    assert.equal(p.compiledVbc2, compileVeraSource(good).vbc2, 'server widgets use locally validated bytecode')
    assert.equal(p.compiled, true)
    assert.equal(p.generating, false)
    assert.equal(p.tab, 'widget')
    assert.equal(p.attempts[0].success, true)
    assert.equal(p.acceptedRequest, ask)
    assert.equal(f.serverRequests.length, 4)
    assert.equal(f.saves.length, 0, 'server completion must not save implicitly')
    assert.equal((await saveWidget(p)), true, 'a completed server Redo must be saveable against its stripped baseline')
    assert.equal(f.saves.length, 1)
    assert.equal(f.saves[0][1], good)
    assert.equal(f.saves[0][2], p.compiledVbc2)
    assert.equal(f.saves[0][8], f.initial.id)
    assert.equal(p.widgetBase, good, 'only Save advances the server Redo baseline')
    assert.equal(p.baseVersionId, 'v2')
  }
  for (const original of oldPrograms) {
    const f = fixture(original), p = f.page, baseline = withoutWidget(original)
    const ask = WIDGET_ASK + 'New local widget'
    await submit(p, 'New local widget', 'Local')
    assertFreshRequest(f.localRequests[0].previousSource, f.localRequests[0].userPrompt, baseline, ask)
    assert.equal(p.widgetFresh, true, 'empty local output must keep Redo fresh')
    assert.equal(p.compiledSource, original)
    assert.equal(p.requestHistory, f.initial.prompt)
    const reply = 'function widget(state: AppState): ui.View { return compact(state); }'
    f.setLocalResponse(reply)
    await submit(p, 'New local widget', 'Local')
    assertFreshRequest(f.localRequests[1].previousSource, f.localRequests[1].userPrompt, baseline, ask)
    const good = spliceWidget(baseline, reply).trim()
    assert.equal(p.compiledSource, good)
    assert.equal(p.widgetFresh, false)
    assert.doesNotMatch(p.requestHistory, /Old widget/)
    assert.equal(p.widgetBase, baseline)
    assert.equal((await saveWidget(p)), true)
    assert.equal(p.widgetBase, good)
    await submit(p, 'Refine local widget', 'Local')
    assert.equal(f.localRequests[2].previousSource, good, 'later refinements must see the replacement widget')
    assert(f.localRequests[2].userPrompt.includes(ask), 'later refinements keep the replacement widget history')
    const refine = fixture(original, false)
    await submit(refine.page, 'Change old widget', 'Local')
    assert.equal(refine.localRequests[0].previousSource, original, 'ordinary refinement keeps its widget')
    assert.match(refine.localRequests[0].userPrompt, /Old widget/)
  }
  console.log('PASS GeneratePage Redo dispatch: Server/local outbound source/history stripped, failures retry fresh, ordinary refinements retain context')
  console.log('PASS GeneratePage server Redo: failures retain fresh state, success reveals widget/actions, baseline preserved until Save')
  console.log('PASS GeneratePage Redo: helper/import removal, failures and retries, unsaved refinements, app preservation, saved baseline advancement')
})().catch(e => { console.error(e); process.exit(1) })
