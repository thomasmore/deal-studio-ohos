'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const ts = process.env.VERA_TYPESCRIPT_PATH ? require(process.env.VERA_TYPESCRIPT_PATH) : require('typescript');
const { loadSource, loadVera, sourceRoot } = require('./source-loader');
const navigation = loadVera('AppNavigation');
const file = path.join(sourceRoot, 'entryability/EntryAbility.ets');
const source = fs.readFileSync(file, 'utf8');
const compiled = ts.transpileModule(source, {
  fileName: 'EntryAbility.ts',
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  reportDiagnostics: true
});
assert.deepEqual((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error), [],
  'EntryAbility must transpile without syntax errors');

const project = { id: 'project-1' };
const runnable = { id: 'version-2', vbc2: 'fixture-bytecode' };
const pause = () => new Promise(resolve => setImmediate(resolve));
function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}
function params(values = {}) {
  return { projectId: '', versionId: '', vbc2: '', shortcutMode: '', launchError: '',
    baseVersionId: '', chatId: '', prompt: '', run: '', fromList: '', makeWidget: '', widgetFresh: '', formId: '', ...values };
}
const library = () => ({ name: 'library', param: params() });
const projectPath = (id = project.id) => ({ name: 'project', param: params({ projectId: id }) });
const runnerPath = (id = project.id, version = runnable) => ({ name: 'runner',
  param: params({ projectId: id, versionId: version.id, vbc2: version.vbc2 }) });
const isolatedPath = (values = {}) => ({ name: 'isolatedRunner', param: params({ shortcutMode: 'true', ...values }) });
const snapshot = value => JSON.parse(JSON.stringify(value));

function fixture(options = {}) {
  const errors = [], reads = [], events = [], stages = [];
  const store = {
    init(dir) { reads.push(['init', dir]); },
    getProject(id) { reads.push(['project', id]); return options.missingProject ? null : { ...project, id }; },
    getLatestRunnableVersion(id) { reads.push(['version', id]); return options.noBytecode ? null : runnable; }
  };
  class LocalStorage {
    constructor() { this.values = new Map(); }
    setOrCreate(key, value) { this.values.set(key, value); }
    get(key) { return this.values.get(key); }
  }
  const dependencies = {
    '@kit.AbilityKit': { UIAbility: class {} },
    '@kit.ArkTS': {},
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {}, error(...args) { errors.push(args); } } },
    '../components/LaunchTrust': loadSource(path.join(sourceRoot, 'components/LaunchTrust.ets')),
    '../runtime/trace/StageTrace': loadSource(path.join(sourceRoot, 'runtime/trace/StageTrace.ets')),
    '../vera/AppNavigation': navigation,
    '../vera/ProjectStore': { store },
    '../vera/VeraPermissions': {
      requestCalendarPermissions: async () => {}, requestMicrophonePermission: async () => {}
    }
  };
  const mod = { exports: {} };
  new Function('require', 'module', 'exports', 'LocalStorage', compiled.outputText)(name => {
    if (Object.hasOwn(dependencies, name)) { return dependencies[name]; }
    if (name === '@kit.ArkUI' || name.startsWith('../vera/')) { return {}; }
    throw Error('Unexpected ability dependency: ' + name);
  }, mod, mod.exports, LocalStorage);
  const ability = new mod.exports.default();
  ability.context = { filesDir: '/fixture/files' };

  function createStage(normalFullScreen = false) {
    const calls = [], windowCalls = [], toasts = [], gates = {};
    const stack = {
      paths: [],
      size() { return this.paths.length; },
      getAllPathName() { return this.paths.map(info => info.name); },
      popToIndex(index, animated = true) {
        if (index < 0 || index >= this.paths.length) { return; }
        this.paths.splice(index + 1);
        const call = { paths: snapshot(this.paths), animated };
        calls.push(call);
        events.push(['paths', stages.indexOf(stage), call]);
      },
      popToName(name, animated = true) {
        const index = this.paths.findIndex(info => info.name === name);
        if (index < 0) { return -1; }
        this.popToIndex(index, animated);
        return index;
      },
      setPathStack() {
        assert.fail('Fresh destinations must use pushPath to initialise native indices');
      },
      clear(animated) {
        this.paths = [];
        const call = { paths: [], animated };
        calls.push(call);
        events.push(['paths', stages.indexOf(stage), call]);
      },
      pushPath(info, animated) {
        let call = calls[calls.length - 1];
        assert.equal(animated, false, 'external launches must not animate');
        if (!call) {
          call = { paths: snapshot(this.paths), animated };
          calls.push(call);
          events.push(['paths', stages.indexOf(stage), call]);
        }
        assert.equal(call.animated, false);
        info.index = -1;
        const { index, ...route } = info;
        assert.equal(index, -1);
        this.paths.push(snapshot(route));
        call.paths = snapshot(this.paths);
      }
    };
    async function apply(type, value) {
      windowCalls.push([type, snapshot(value)]);
      events.push([type, stages.indexOf(stage), snapshot(value)]);
      const gate = gates[type];
      delete gates[type];
      if (gate) { await gate.promise; }
      if (type === 'layout') { mainWindow.fullScreen = value; }
      else { mainWindow.bars = value.slice(); }
    }
    const mainWindow = {
      fullScreen: normalFullScreen,
      bars: ['status', 'navigation'],
      getWindowProperties: () => ({ isLayoutFullScreen: mainWindow.fullScreen }),
      getUIContext: () => ({ getPromptAction: () => ({ showToast(value) {
        toasts.push(value);
        events.push(['toast', stages.indexOf(stage), value]);
      } }) }),
      setWindowLayoutFullScreen: value => apply('layout', value),
      setWindowSystemBarEnable: value => apply('bars', value)
    };
    const stage = {
      calls, windowCalls, toasts, stack, mainWindow,
      getMainWindowSync: () => mainWindow,
      loadContent(page, storage, callback) {
        assert.equal(page, 'pages/AppShell');
        this.session = storage.get('navigationSession');
        assert(this.session instanceof navigation.AppNavigationSession);
        this.loaded = callback;
      },
      holdNext(type) { assert.equal(gates[type], undefined); return (gates[type] = deferred()); }
    };
    stages.push(stage);
    ability.onWindowStageCreate(stage);
    return stage;
  }
  async function idle() {
    for (let i = 0; i < 30; i++) {
      await pause();
      assert.deepEqual(errors, [], 'ability must not log errors');
      if (ability.routeDrainGeneration === -1) { return; }
    }
    assert.fail('route drain did not become idle');
  }
  async function launch(want) {
    const previous = ability.lastDestination;
    const queued = [];
    const queueRoute = ability.queueRoute;
    ability.queueRoute = function(...args) {
      queueRoute.apply(this, args);
      queued.push(this.pendingRoute);
    };
    try { ability.onNewWant(want, {}); }
    finally { ability.queueRoute = queueRoute; }
    assert.equal(queued.length, 1, 'launch must queue exactly one route, even if it commits synchronously');
    const request = queued[0];
    assert(request, 'launch must queue a route');
    await idle();
    assert.equal(ability.pendingRoute, null, 'the current route must be cleared');
    if (request.kind !== 'shortcut' && request.kind !== 'home' && options.missingProject) {
      assert.equal(ability.lastDestination, previous, 'a deleted project must not replace the committed route');
    } else {
      assert.equal(ability.lastDestination, request, 'the committed destination must be the current request');
    }
    return request;
  }
  return { ability, createStage, idle, launch, reads, errors, events, stages };
}
async function ready(options = {}) {
  const f = fixture(options);
  f.stage = f.createStage(options.normalFullScreen || false);
  f.stage.loaded({});
  f.stage.session.attach(f.stage.stack);
  await f.idle();
  assert.deepEqual(f.stage.calls, [{ paths: [library()], animated: false }]);
  f.stage.calls.length = 0;
  f.stage.windowCalls.length = 0;
  f.events.length = 0;
  return f;
}
function assertCommit(f, stage, paths, isolated, normalFullScreen = false) {
  assert.deepEqual(stage.calls, [{ paths, animated: false }]);
  assert.deepEqual(stage.stack.paths, paths, 'the complete committed stack must match the launch route');
  assert.deepEqual(stage.windowCalls, [
    ['layout', isolated || normalFullScreen], ['bars', isolated ? [] : ['status', 'navigation']]
  ]);
  assert.equal(stage.mainWindow.fullScreen, isolated || normalFullScreen);
  assert.deepEqual(stage.mainWindow.bars, isolated ? [] : ['status', 'navigation']);
  assert.equal(f.ability.pendingRoute, null);
  assert.deepEqual(f.errors, []);
}
function extractMethods(source, names, state, dependencies = {}) {
  const methods = names.map(name => {
    const match = source.match(new RegExp('^  (?:private )?(?:async )?' + name + '\\([^\\n]*\\)[^{]*\\{[\\s\\S]*?^  \\}', 'm'));
    assert(match, name + ' must exist');
    return match[0];
  });
  const compiled = ts.transpileModule('class ComponentMethods {\n' + methods.join('\n') + '\n}', {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }, reportDiagnostics: true
  });
  assert.deepEqual((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error), []);
  const prototype = new Function(...Object.keys(dependencies), compiled.outputText + '\nreturn ComponentMethods.prototype;')
    (...Object.values(dependencies));
  for (const name of names) { state[name] = prototype[name].bind(state); }
}

function nativeControl(source, marker, state, scope = {}) {
  const start = source.indexOf(marker);
  assert(start >= 0, marker + ' must exist');
  const parsed = ts.createSourceFile('NativeControl.ts', source.slice(start), ts.ScriptTarget.ES2020, true);
  const statement = parsed.statements[0];
  assert(ts.isExpressionStatement(statement), marker + ' must start a native control chain');
  const control = {};
  let expression = statement.expression;
  while (ts.isCallExpression(expression) && ts.isPropertyAccessExpression(expression.expression)) {
    const name = expression.expression.name.text;
    if (['onChange', 'onEditChange', 'onSubmit', 'onClick', 'enabled'].includes(name)) {
      assert.equal(expression.arguments.length, 1);
      const compiled = ts.transpileModule('function value() { return (' + expression.arguments[0].getText(parsed) + '); }', {
        compilerOptions: { target: ts.ScriptTarget.ES2020 }, reportDiagnostics: true
      });
      assert.deepEqual((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error), []);
      const value = new Function(...Object.keys(scope), compiled.outputText + '\nreturn value;')(...Object.values(scope));
      Object.defineProperty(control, name, { get: () => value.call(state) });
    }
    expression = expression.expression.expression;
  }
  assert(ts.isCallExpression(expression) && ts.isIdentifier(expression.expression), marker + ' must be a native control');
  return control;
}

function projectModalFixture() {
  const source = fs.readFileSync(path.join(sourceRoot, 'pages/ProjectPage.ets'), 'utf8');
  const events = [];
  const nativeInput = { text: '', reads: 0, getText() { this.reads++; return this.text; } };
  const context = { filesDir: '/fixture/files' };
  const state = {
    pageVisible: true, project: { name: 'Original', icon: 'icon' }, projectId: 'project-1', versions: [],
    getUIContext: () => ({ getHostContext: () => context }),
    showProjectMessage(message) { events.push(['message', message]); },
    activePanel: '', renameText: 'Old draft', renameComposing: false, renameInputController: nativeInput,
    viewedSource: '', viewedPrompt: '', viewedVersionNumber: 0,
    viewedMetricsVersion: null, viewedMetricsNumber: 0, shortcutRefreshGeneration: 0,
    widgetVbc2: 'fixture-widget-bytecode', widgetSeed: 'fixture-widget-state',
    reload() { events.push(['reload']); },
    pathStack: { pop() { assert.fail('closing a dialog must not pop the page'); } }
  };
  const store = { updateProject(...args) { events.push(['rename', ...args]); } };
  const refresh = () => events.push(['refresh']);
  const renameGate = deferred();
  let shortcutStatus = 'success';
  const projectOperations = { async renameShortcut(getContext, id) {
    assert.equal(getContext(), context, 'shortcut rename must use the page host context');
    events.push(['shortcut', id]);
    await renameGate.promise;
    return shortcutStatus;
  } };
  extractMethods(source, ['clearPanels', 'closePanels', 'handleBack', 'viewSource', 'viewMetrics',
    'openRename', 'openIconPicker', 'previewWidget', 'setIcon', 'changeRename', 'finishRename', 'submitRename', 'doRename',
    'destinationHidden', 'aboutToDisappear'], state, {
    store, refreshForms: refresh, ProjectShortcutState: { Unknown: 'unknown' }, projectOperations,
    ProjectOperationStatus: { Failed: 'failed' }
  });
  const cancellations = [];
  for (const panel of ['source', 'metrics', 'rename', 'icon', 'widget']) {
    const controller = source.match(new RegExp('private ' + panel + 'Controller:[\\s\\S]*?new CustomDialogController\\(\\{([\\s\\S]*?)^  \\}\\)', 'm'));
    assert(controller, panel + ' controller must exist');
    assert.match(controller[1], new RegExp('builder: ProjectPanelDialog\\(\\{ content: this\\.' + panel + 'Dialog \\}\\)'));
    assert.match(controller[1], /isModal: true/);
    assert.match(controller[1], /autoCancel: true/);
    assert.match(controller[1], /maskColor: '#50000000'/);
    const cancel = controller[1].match(/cancel: \(\) => \{([^}]+)\}/);
    assert(cancel, panel + ' must clear selection on native Back and outside-tap dismissal');
    cancellations.push(new Function(cancel[1]).bind(state));
    state[panel + 'Controller'] = {
      open() { events.push(['open', panel, state.activePanel]); },
      close() { events.push(['close', panel]); }
    };
  }
  return { source, state, events, nativeInput, renameGate, cancellations,
    setShortcutStatus(value) { shortcutStatus = value; },
    input: nativeControl(source, "TextInput({ placeholder: 'Project name'", state),
    save: nativeControl(source, "Button('Save')", state),
    cancel: nativeControl(source, "Button('Cancel')", state) };
}

function questionFixture() {
  const source = fs.readFileSync(path.join(sourceRoot, 'components/QuestionCard.ets'), 'utf8');
  const events = [];
  const nativeInput = { text: '', reads: 0, getText() { this.reads++; return this.text; } };
  const state = {
    typed: '', composing: false, disposed: false, inputController: nativeInput,
    options: ['One', 'Two'], fallback: 1,
    onPick(index) { events.push(['pick', index]); },
    onTyped(text) { events.push(['answer', text]); }
  };
  extractMethods(source, ['aboutToAppear', 'aboutToDisappear', 'changeAnswer', 'finishAnswer', 'submitAnswer', 'answer'], state);
  return { source, state, events, nativeInput,
    input: nativeControl(source, "TextInput({ placeholder: 'Or type your own answer'", state),
    answer: nativeControl(source, "Button('Answer')", state),
    option: index => nativeControl(source, 'Button(index === this.fallback', state, { index }) };
}

let passed = 0;
async function test(name, run) {
  if (process.env.VERA_CHECK_FILTER && !new RegExp(process.env.VERA_CHECK_FILTER).test(name)) { return; }
  await run();
  passed++;
  console.log('PASS ' + name);
}

(async () => {
  await test('Widget card runs its project in immersive shortcut mode', async () => {
    const widget = fs.readFileSync(path.join(sourceRoot, 'widget/pages/WidgetCard.ets'), 'utf8');
    assert.match(widget, /'action': 'router'/);
    assert.match(widget, /'abilityName': 'EntryAbility'/);
    assert.match(widget, /'params':\s*\{\s*'projectId': project\['id'\],\s*'launchMode': 'runLatest'\s*\}/);
    const f = await ready();
    const request = await f.launch({ parameters: { projectId: project.id, launchMode: 'runLatest' } });
    assert.equal(request.kind, 'shortcut');
    assertCommit(f, f.stage,
      [isolatedPath({ projectId: project.id, versionId: runnable.id, vbc2: runnable.vbc2 })], true);
  });
  await test('Live card opens its project in immersive shortcut mode', async () => {
    const source = fs.readFileSync(path.join(sourceRoot, 'widget/pages/LiveCard.ets'), 'utf8');
    const actions = [];
    const state = { projectId: project.id, formId: 'form-7' };
    extractMethods(source, ['openApp'], state, {
      postCardAction(owner, action) { assert.equal(owner, state); actions.push(action); }
    });
    state.openApp();
    assert.deepEqual(actions, [{ action: 'router', abilityName: 'EntryAbility',
      params: { projectId: project.id, launchMode: 'runLatest', veraFormId: '' } }]);
    const f = await ready();
    f.stage.stack.paths.push(projectPath(), runnerPath());
    const request = await f.launch({ parameters: actions[0].params });
    assert.equal(request.kind, 'shortcut');
    assertCommit(f, f.stage,
      [isolatedPath({ projectId: project.id, versionId: runnable.id, vbc2: runnable.vbc2 })], true);
  });
  await test('Live card without a project preserves widget binding instead of immersive launch', async () => {
    const source = fs.readFileSync(path.join(sourceRoot, 'widget/pages/LiveCard.ets'), 'utf8');
    const actions = [];
    const state = { projectId: '', formId: 'form-7' };
    extractMethods(source, ['openApp'], state, {
      postCardAction(owner, action) { assert.equal(owner, state); actions.push(action); }
    });
    state.openApp();
    assert.deepEqual(actions, [{ action: 'router', abilityName: 'EntryAbility',
      params: { projectId: '', launchMode: 'runLatest', veraFormId: 'form-7' } }]);
    const f = await ready();
    const request = await f.launch({ parameters: actions[0].params });
    assert.equal(request.kind, 'form');
    assertCommit(f, f.stage, [library(), { name: 'widgetBind', param: params({ formId: 'form-7' }) }], false);
  });
  await test('Navigation receives the raw stack without notifying observed state during render', async () => {
    const shell = fs.readFileSync(path.join(sourceRoot, 'pages/AppShell.ets'), 'utf8');
    assert.match(shell, /import\s*\{[^}]*\bUIUtils\b[^}]*\}\s*from\s*'@kit\.ArkUI'/);
    const boundary = shell.match(/^\s*Navigation\((.+)\)\s*\{/m);
    assert(boundary, 'AppShell must construct Navigation with its stack');
    let rendering = true;
    let notifications = 0;
    const raw = { setNativeStack(value) { this.nativeStack = value; } };
    const observed = new Proxy(raw, { set(target, key, value) {
      notifications++;
      assert.equal(rendering, false, 'observed stack must not change during Navigation creation');
      return Reflect.set(target, key, value);
    } });
    const UIUtils = { getTarget(value) { return value === observed ? raw : value; } };
    const argument = new Function('UIUtils', 'return (' + boundary[1] + ');')
      .call({ pathStack: observed }, UIUtils);
    assert.equal(argument, raw, 'the native boundary must not receive the observed proxy');
    const nativeStack = {};
    argument.setNativeStack(nativeStack);
    rendering = false;
    assert.equal(raw.nativeStack, nativeStack);
    assert.equal(notifications, 0);
  });
  await test('Project Rename, Code, Metrics, Picture and Widget Preview use modal dialogs without popping the page', async () => {
    const { source, state, events, renameGate, cancellations, setShortcutStatus } = projectModalFixture();
    assert.match(source, /NavDestination\(\)\s*\{\s*this\.pageContent\(\)/);
    assert.match(source, /@CustomDialog\s+struct ProjectPanelDialog/);
    assert.match(source, /@BuilderParam content: \(\) => void = this\.emptyContent/);
    assert.match(source, /\.onBackPressed\(\(\): boolean => this\.handleBack\(\)\)/);
    assert.doesNotMatch(source, /\.overlay\(|\bpageOverlays\b|\brenaming\b/);
    assert.match(source, /value: 'Rename', action: \(\) => \{ this\.openRename\(\) \}/);
    assert.match(source, /\.onClick\(\(\) => \{ this\.openIconPicker\(\) \}\)/);
    assert.match(source, /onPick: \(icon: string\): void => \{ this\.setIcon\(icon\) \}/);
    assert.match(source, /\.onClick\(\(\) => \{ this\.viewSource\(v, this\.versions\.length - index\) \}\)/);
    assert.match(source, /\.onClick\(\(\) => \{ this\.viewMetrics\(v, this\.versions\.length - index\) \}\)/);
    assert.match(source, /@State renameComposing: boolean = false/);
    assert.match(source, /private renameInputController: TextInputController = new TextInputController\(\)/);
    assert.match(source, /controller: this\.renameInputController/);
    assert.match(source, /\.enabled\(!this\.renameComposing && this\.renameText\.trim\(\)\.length > 0\)/);
    assert.match(source, /\.onClick\(\(\) => \{ this\.doRename\(\) \}\)/);
    assert.equal((source.match(/\.onClick\(\(\) => \{ this\.closePanels\(\) \}\)/g) || []).length, 4);
    const version = { source: 'app source', prompt: 'version request', metrics: null };
    const assertCleared = () => {
      assert.equal(state.activePanel, '');
      assert.equal(state.renameComposing, false);
      assert.equal(state.viewedSource, '');
      assert.equal(state.viewedPrompt, '');
      assert.equal(state.viewedVersionNumber, 0);
      assert.equal(state.viewedMetricsVersion, null);
      assert.equal(state.viewedMetricsNumber, 0);
    };
    for (const [panel, open] of [
      ['source', () => state.viewSource(version, 3)],
      ['metrics', () => state.viewMetrics(version, 3)],
      ['rename', () => state.openRename()],
      ['icon', () => state.openIconPicker()],
      ['widget', () => state.previewWidget()]
    ]) {
      for (const dismiss of [() => assert.equal(state.handleBack(), true),
        () => state.closePanels(), ...cancellations, () => state.destinationHidden(),
        () => state.aboutToDisappear()]) {
        state.pageVisible = true;
        events.length = 0;
        open();
        assert.deepEqual(events, [['open', panel, panel]], 'populate selection before opening');
        if (panel === 'source') {
          assert.equal(state.viewedSource, version.source);
          assert.equal(state.viewedPrompt, version.prompt);
          assert.equal(state.viewedVersionNumber, 3);
        } else if (panel === 'metrics') {
          assert.equal(state.viewedMetricsVersion, version, 'metrics without saved data must still open');
          assert.equal(state.viewedMetricsNumber, 3);
        } else if (panel === 'rename') {
          assert.equal(state.renameText, 'Original', 'reopening must discard a cancelled draft');
          state.renameText = 'Unsaved';
        }
        open();
        assert.equal(events.length, 1, 'do not stack duplicate dialogs');
        dismiss();
        assertCleared();
        assert.equal(state.handleBack(), false, 'Back without a dialog must allow normal navigation');
        assert(!events.some(event => event[0] === 'rename'), 'dismissal must not save a rename');
      }
    }
    events.length = 0;
    state.pageVisible = false;
    state.viewSource(version, 3);
    state.viewMetrics(version, 3);
    state.openRename();
    state.openIconPicker();
    state.previewWidget();
    assert.deepEqual(events, [], 'hidden destinations must not open dialogs');
    state.pageVisible = true;
    state.viewSource({ source: '', prompt: '', metrics: null }, 1);
    assert.equal(state.activePanel, 'source', 'Code must open even for empty source');
    state.closePanels();
    state.openRename();
    events.length = 0;
    state.renameText = '   ';
    await state.doRename();
    assert.deepEqual(events, [], 'blank names must not save or dismiss');
    assert.equal(state.activePanel, 'rename');
    state.renameText = '  New name  ';
    let renamed = false;
    const pendingRename = state.doRename().then(() => { renamed = true; });
    assert.deepEqual(events, [['rename', 'project-1', 'New name', 'icon'],
      ['close', 'source'], ['close', 'metrics'], ['close', 'rename'], ['close', 'icon'], ['close', 'widget'],
      ['reload'], ['refresh'], ['shortcut', 'project-1']]);
    assertCleared();
    await pause();
    assert.equal(renamed, false, 'rename must await shortcut refresh after saving and closing the dialog');
    renameGate.resolve();
    await pendingRename;
    assert.equal(renamed, true);
    assert(!events.some(event => event[0] === 'message'), 'successful shortcut rename must not show a warning');
    setShortcutStatus('failed');
    events.length = 0;
    state.openRename();
    await state.doRename();
    assert.deepEqual(events.at(-1), ['message',
      'Renamed, but the shortcut on the home screen may still show the old name. Remove and re-add it to update.']);
    assertCleared();
    setShortcutStatus('success');
    events.length = 0;
    state.openIconPicker();
    await state.setIcon('new-icon');
    assert.deepEqual(events, [['open', 'icon', 'icon'], ['close', 'source'], ['close', 'metrics'],
      ['close', 'rename'], ['close', 'icon'], ['close', 'widget'], ['rename', 'project-1', 'Original', 'new-icon'],
      ['reload'], ['refresh'], ['shortcut', 'project-1']]);
    assertCleared();
    events.length = 0;
    state.openIconPicker();
    state.setIcon('icon');
    assert.deepEqual(events, [['open', 'icon', 'icon'], ['close', 'source'], ['close', 'metrics'],
      ['close', 'rename'], ['close', 'icon'], ['close', 'widget']], 'choosing the current icon must close without saving');
    assertCleared();
    state.project = null;
    events.length = 0;
    state.openRename();
    state.openIconPicker();
    state.setIcon('new-icon');
    await state.doRename();
    assert.deepEqual(events, [], 'a missing project must not open or save Rename or Picture');
  });
  await test('Rename native submit saves finalized event text over stale state during composition', async () => {
    for (const composing of [false, true]) {
      const f = projectModalFixture();
      f.renameGate.resolve();
      f.state.openRename();
      f.input.onChange('stale state', composing ? { offset: 0, value: 'provisional' } : undefined);
      assert.equal(f.state.renameComposing, composing);
      f.events.length = 0;
      f.input.onSubmit(0, { text: '  Final name  ' });
      await pause();
      assert.equal(f.state.renameText, '  Final name  ');
      assert.equal(f.state.renameComposing, false);
      assert.equal(f.state.activePanel, '');
      assert.deepEqual(f.events.filter(event => event[0] === 'rename'), [['rename', 'project-1', 'Final name', 'icon']]);
    }
  });
  await test('Rename Save and method guard reject provisional text until ordinary change commits it', async () => {
    for (const preview of [undefined, { offset: 0, value: '' }]) {
      const f = projectModalFixture();
      f.renameGate.resolve();
      f.state.openRename();
      f.input.onChange('draft', { offset: 0, value: 'provisional' });
      f.events.length = 0;
      assert.equal(f.save.enabled, false);
      await f.save.onClick();
      await f.state.doRename();
      assert.deepEqual(f.events, []);
      assert.equal(f.state.activePanel, 'rename');
      f.input.onChange('  Committed name  ', preview);
      assert.equal(f.state.renameComposing, false);
      assert.equal(f.save.enabled, true);
      await f.save.onClick();
      assert.deepEqual(f.events.filter(event => event[0] === 'rename'), [['rename', 'project-1', 'Committed name', 'icon']]);
    }
  });
  await test('Rename blur synchronizes native text without submitting or reading on focus', async () => {
    const f = projectModalFixture();
    f.state.openRename();
    f.input.onChange('stale', { offset: 0, value: 'provisional' });
    f.nativeInput.text = '  Native name  ';
    f.events.length = 0;
    f.input.onEditChange(true);
    assert.equal(f.nativeInput.reads, 0);
    assert.equal(f.state.renameComposing, true);
    f.input.onEditChange(false);
    assert.equal(f.nativeInput.reads, 1);
    assert.equal(f.state.renameText, f.nativeInput.text);
    assert.equal(f.state.renameComposing, false);
    assert.equal(f.save.enabled, true);
    assert.equal(f.state.activePanel, 'rename');
    assert.deepEqual(f.events, []);
  });
  await test('Rename ignores whitespace from change, blur and authoritative submit', async () => {
    for (const text of ['', ' \t\n ']) {
      const f = projectModalFixture();
      f.state.openRename();
      f.events.length = 0;
      f.input.onChange(text);
      assert.equal(f.save.enabled, false);
      await f.save.onClick();
      f.input.onChange('stale', { offset: 0, value: 'provisional' });
      f.input.onSubmit(0, { text });
      f.nativeInput.text = text;
      f.input.onEditChange(false);
      await f.state.doRename();
      assert.equal(f.state.renameText, text);
      assert.equal(f.state.renameComposing, false);
      assert.equal(f.save.enabled, false);
      assert.equal(f.state.activePanel, 'rename');
      assert.deepEqual(f.events, []);
    }
  });
  await test('Rename cancellation and dismissal reject late native callbacks and direct saves', async () => {
    for (const dismiss of [f => f.cancel.onClick(), f => f.state.handleBack(),
      ...[0, 1, 2, 3, 4].map(index => f => f.cancellations[index]()),
      f => f.state.destinationHidden(), f => f.state.aboutToDisappear()]) {
      const f = projectModalFixture();
      f.state.openRename();
      f.input.onChange('cancelled draft', { offset: 0, value: 'provisional' });
      dismiss(f);
      assert.equal(f.state.activePanel, '');
      assert.equal(f.state.renameComposing, false);
      f.events.length = 0;
      f.nativeInput.text = 'late native text';
      f.input.onEditChange(false);
      f.input.onChange('late change', { offset: 0, value: 'late preview' });
      f.state.finishRename('late finish');
      f.input.onSubmit(0, { text: 'late submit' });
      f.state.submitRename('late direct submit');
      await f.save.onClick();
      await f.state.doRename();
      assert.equal(f.nativeInput.reads, 0);
      assert.equal(f.state.renameText, 'cancelled draft');
      assert.equal(f.state.renameComposing, false);
      assert.deepEqual(f.events, []);
    }
  });
  await test('Rename guards hidden pages and other panels and resets composition on reopen', async () => {
    const f = projectModalFixture();
    f.state.openRename();
    f.input.onChange('draft', { offset: 0, value: 'provisional' });
    f.state.pageVisible = false;
    f.events.length = 0;
    f.input.onSubmit(0, { text: 'hidden submit' });
    f.state.submitRename('hidden direct submit');
    assert.equal(f.state.renameText, 'draft');
    assert.equal(f.state.renameComposing, true);
    f.state.renameComposing = false;
    await f.state.doRename();
    assert.deepEqual(f.events, []);
    f.state.pageVisible = true;
    f.state.closePanels();
    f.state.renameComposing = true;
    f.state.openRename();
    assert.equal(f.state.renameText, 'Original');
    assert.equal(f.state.renameComposing, false);
    assert.equal(f.save.enabled, true);
    f.state.closePanels();
    f.state.openIconPicker();
    f.events.length = 0;
    f.input.onChange('wrong panel', { offset: 0, value: 'preview' });
    f.state.finishRename('wrong panel finish');
    f.input.onEditChange(false);
    f.input.onSubmit(0, { text: 'wrong panel submit' });
    await f.state.doRename();
    assert.equal(f.state.renameText, 'Original');
    assert.equal(f.state.renameComposing, false);
    assert.equal(f.nativeInput.reads, 0);
    assert.deepEqual(f.events, []);
  });
  await test('Question native submit answers finalized event text over stale state during composition', async () => {
    for (const composing of [false, true]) {
      const f = questionFixture();
      assert.match(f.source, /@State composing: boolean = false/);
      assert.match(f.source, /private inputController: TextInputController = new TextInputController\(\)/);
      assert.match(f.source, /controller: this\.inputController/);
      assert.match(f.source, /if \(this\.typed\.trim\(\)\.length > 0\)\s*\{\s*Button\('Answer'\)/);
      f.input.onChange('stale answer', composing ? { offset: 0, value: 'provisional' } : undefined);
      assert.equal(f.state.composing, composing);
      f.input.onSubmit(0, { text: '  Final answer  ' });
      assert.equal(f.state.typed, '  Final answer  ');
      assert.equal(f.state.composing, false);
      assert.deepEqual(f.events, [['answer', 'Final answer']]);
    }
  });
  await test('Question Answer and method guard reject provisional text until ordinary change commits it', async () => {
    for (const preview of [undefined, { offset: 0, value: '' }]) {
      const f = questionFixture();
      f.input.onChange('draft', { offset: 0, value: 'provisional' });
      assert.equal(f.answer.enabled, false);
      f.answer.onClick();
      f.state.answer();
      assert.deepEqual(f.events, []);
      f.input.onChange('  Committed answer  ', preview);
      assert.equal(f.state.composing, false);
      assert.equal(f.answer.enabled, true);
      f.answer.onClick();
      assert.deepEqual(f.events, [['answer', 'Committed answer']]);
    }
  });
  await test('Question blur synchronizes native text without answering or reading on focus', async () => {
    const f = questionFixture();
    f.input.onChange('stale', { offset: 0, value: 'provisional' });
    f.nativeInput.text = '  Native answer  ';
    f.input.onEditChange(true);
    assert.equal(f.nativeInput.reads, 0);
    assert.equal(f.state.composing, true);
    f.input.onEditChange(false);
    assert.equal(f.nativeInput.reads, 1);
    assert.equal(f.state.typed, f.nativeInput.text);
    assert.equal(f.state.composing, false);
    assert.equal(f.answer.enabled, true);
    assert.deepEqual(f.events, []);
  });
  await test('Question ignores whitespace from change, blur and authoritative submit', async () => {
    for (const text of ['', ' \t\n ']) {
      const f = questionFixture();
      f.input.onChange(text);
      f.answer.onClick();
      f.state.answer();
      f.input.onChange('stale', { offset: 0, value: 'provisional' });
      f.input.onSubmit(0, { text });
      f.nativeInput.text = text;
      f.input.onEditChange(false);
      f.state.answer();
      assert.equal(f.state.typed, text);
      assert.equal(f.state.composing, false);
      assert.deepEqual(f.events, []);
    }
  });
  await test('Question dismissal rejects late native callbacks and answers until it appears again', async () => {
    const f = questionFixture();
    f.input.onChange('cancelled draft', { offset: 0, value: 'provisional' });
    f.state.aboutToDisappear();
    assert.equal(f.state.disposed, true);
    assert.equal(f.state.composing, false);
    f.nativeInput.text = 'late native text';
    f.input.onEditChange(false);
    f.input.onChange('late change', { offset: 0, value: 'preview' });
    f.state.finishAnswer('late finish');
    f.input.onSubmit(0, { text: 'late submit' });
    f.state.submitAnswer('late direct submit');
    f.answer.onClick();
    f.state.answer();
    assert.equal(f.nativeInput.reads, 0);
    assert.equal(f.state.typed, 'cancelled draft');
    assert.equal(f.state.composing, false);
    assert.deepEqual(f.events, []);
    f.state.aboutToAppear();
    assert.equal(f.state.disposed, false);
    f.input.onSubmit(0, { text: '  New answer  ' });
    assert.deepEqual(f.events, [['answer', 'New answer']]);
  });
  await test('Question option picks retain their indices even while typed input is composing', async () => {
    const f = questionFixture();
    for (const preview of [undefined, { offset: 0, value: 'provisional' }]) {
      f.input.onChange('draft', preview);
      f.option(0).onClick();
      f.option(1).onClick();
    }
    assert.deepEqual(f.events, [['pick', 0], ['pick', 1], ['pick', 0], ['pick', 1]]);
  });
  await test('Home composer opens Generate or Chat with prompt and run params without creating a project', async () => {
    const source = fs.readFileSync(path.join(sourceRoot, 'pages/Index.ets'), 'utf8');
    assert.match(source, /NavDestination\(\)/);
    assert.doesNotMatch(source, /@CustomDialog|CustomDialogController|\.overlay\(|\bshowCreate\b|\bdoCreate\b|store\.createProject/);
    assert.match(source, /\.onSubmit\(\(\) => \{ this\.submit\(this\.draft\) \}\)/);
    assert.match(source, /\.onClick\(\(\) => \{ this\.submit\(this\.draft\) \}\)/);
    assert.match(source, /\.onClick\(\(\) => \{ this\.submit\(starter\.text\(this\.starterEnglish\)\.prompt\) \}\)/);
    assert.match(source, /if \(this\.makeApp\) \{ this\.openApps\(\) \} else \{ this\.openHistory\(\) \}/);
    const events = [];
    const state = {
      makeApp: true, draft: 'Previous draft',
      pathStack: { pushPath(route) { events.push(['push', snapshot(route)]); } }
    };
    const method = (text, name) => {
      const match = text.match(new RegExp('^  (?:private )?' + name + '\\([^\\n]*\\)[^{]*\\{[\\s\\S]*?^  \\}', 'm'));
      assert(match, name + ' must exist');
      const compiled = ts.transpileModule('class PageMethods {\n' + match[0] + '\n}', {
        compilerOptions: { target: ts.ScriptTarget.ES2020 }, reportDiagnostics: true
      });
      assert.deepEqual((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error), []);
      return new Function('AppRouteParams', compiled.outputText + '\nreturn PageMethods.prototype.' + name + ';')
        (navigation.AppRouteParams).bind(state);
    };
    for (const name of ['openCreate', 'openChat', 'submit', 'openApps', 'openHistory']) {
      state[name] = method(source, name);
    }
    assert.deepEqual(snapshot(new navigation.AppRouteParams()), params(), 'route fixtures must include every production default');
    for (const [makeApp, name] of [[true, 'generate'], [false, 'chat']]) {
      state.makeApp = makeApp;
      for (const text of ['  Build a timer  ', '   ', '']) {
        events.length = 0;
        state.draft = text;
        state.submit(text);
        assert.equal(state.draft, '', 'submitting must clear the composer draft');
        assert.deepEqual(events, [['push', { name,
          param: params({ prompt: text.trim(), run: text.trim() ? '1' : '' }) }]],
        'empty submissions open an idle page; requests start immediately in the selected mode');
      }
      for (const run of [false, true]) {
        events.length = 0;
        state[makeApp ? 'openCreate' : 'openChat']('Prepared request', run);
        assert.deepEqual(events, [['push', { name, param: params({ prompt: 'Prepared request', run: run ? '1' : '' }) }]]);
      }
    }
    events.length = 0;
    state.openApps();
    state.openHistory();
    assert.deepEqual(events, [['push', { name: 'apps', param: params() }], ['push', { name: 'chatList', param: params() }]]);
    events.length = 0;
    const list = fs.readFileSync(path.join(sourceRoot, 'pages/ChatListPage.ets'), 'utf8');
    method(list, 'open')('saved-chat');
    assert.deepEqual(events, [['push', { name: 'chat', param: params({ chatId: 'saved-chat', fromList: '1' }) }]]);
    const keyboardWindow = { off(event, listener) { events.push(['off', event, listener]); } };
    state.keyboardWindow = keyboardWindow;
    state.keyboardListener = () => {};
    const disappear = method(source, 'aboutToDisappear');
    events.length = 0;
    disappear();
    disappear();
    assert.deepEqual(events, [['off', 'keyboardHeightChange', state.keyboardListener]], 'composer teardown must remove its listener only once');
    assert.equal(state.keyboardWindow, null);
  });
  await test('AppsPage owns its NavDestination and AppShell routes to it with params', async () => {
    const source = fs.readFileSync(path.join(sourceRoot, 'pages/AppsPage.ets'), 'utf8');
    const shell = fs.readFileSync(path.join(sourceRoot, 'pages/AppShell.ets'), 'utf8');
    assert.match(source, /export struct AppsPage\s*\{/);
    assert.match(source, /params: AppRouteParams = new AppRouteParams\(\)/);
    assert.match(source, /@Consume\('navPathStack'\) pathStack: NavPathStack/);
    assert.match(source, /NavDestination\(\)\s*\{\s*List\(/);
    assert.match(source, /\.onShown\(\(\) => \{ this\.destinationShown\(\) \}\)/);
    assert.doesNotMatch(source, /@Entry|Navigation\(|\.overlay\(/);
    assert.match(shell, /import\s*\{ AppsPage \}\s*from '\.\/AppsPage'/);
    assert.match(shell, /else if \(name === 'apps'\)\s*\{\s*AppsPage\(\{ params: params \}\)/);
    const click = source.match(/\.onClick\(\(\) => \{([\s\S]*?)^    \}\)/m);
    assert(click, 'an app row must navigate to its project');
    const compiled = ts.transpileModule('function open(row: any) {\n' + click[1] + '\n}', {
      compilerOptions: { target: ts.ScriptTarget.ES2020 }, reportDiagnostics: true
    });
    assert.deepEqual((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error), []);
    const routes = [];
    new Function('AppRouteParams', compiled.outputText + '\nreturn open;')(navigation.AppRouteParams)
      .call({ pathStack: { pushPath(route) { routes.push(snapshot(route)); } } }, { project });
    assert.deepEqual(routes, [projectPath()]);
  });
  await test('Library context menus receive deferred builders', async () => {
    const bindings = [
      ['AppsPage', 'bindContextMenu', 'rowMenu']
    ];
    for (const [page, attribute, builder] of bindings) {
      const source = fs.readFileSync(path.join(sourceRoot, 'pages/' + page + '.ets'), 'utf8');
      const line = source.split('\n').find(line => line.trim().startsWith('.' + attribute + '('));
      assert(line, page + ' must retain ' + attribute);
      const calls = [];
      const component = { [builder](...args) { calls.push(args); } };
      let callback;
      const receiver = { [attribute](value) { callback = value; } };
      new Function('receiver', 'row', 'ResponseType', 'receiver' + line.trim() + ';')
        .call(component, receiver, { project: { id: 'project-1' } }, { LongPress: 1 });
      assert.deepEqual(calls, [], page + ' must not build overlay or menu children on the destination stack');
      assert.equal(typeof callback, 'function', page + ' must pass a builder callback');
      callback();
      assert.deepEqual(calls, [builder === 'rowMenu' ? ['project-1'] : []]);
    }
  });
  await test('Returning to a missing library uses pushPath for the fresh root', async () => {
    const operations = [];
    const stack = {
      getAllPathName: () => ['project'],
      size: () => 1,
      setPathStack() { assert.fail('Fresh library must not use setPathStack'); },
      clear(animated) { operations.push(['clear', animated]); },
      pushPath(info, animated) { operations.push(['push', snapshot(info), animated]); }
    };
    navigation.returnToLibrary(stack);
    assert.deepEqual(operations, [['clear', false], ['push', library(), false]]);
  });
  await test('Returning to an existing library pops to its first entry without replacing params', async () => {
    const f = await ready();
    const root = f.stage.stack.paths[0];
    f.stage.stack.paths.push(projectPath(), library(), runnerPath());
    const names = f.stage.stack.getAllPathName();
    names.length = 0;
    assert.equal(f.stage.stack.size(), 4, 'path names must be a snapshot, not the stack storage');
    assert.equal(f.stage.stack.popToName('absent'), -1);
    assert.equal(f.stage.stack.size(), 4, 'an unknown name must leave the stack intact');
    navigation.returnToLibrary(f.stage.stack);
    assert.deepEqual(f.stage.stack.paths, [library()]);
    assert.equal(f.stage.stack.paths[0], root, 'popping must preserve the native root entry and its params');
    assert.deepEqual(f.stage.calls, [{ paths: [library()], animated: true }]);
    f.stage.stack.paths = [];
    f.stage.calls.length = 0;
    navigation.returnToLibrary(f.stage.stack);
    assert.deepEqual(f.stage.calls, [], 'returning on an empty stack must not create a destination');
    assert.equal(f.stage.stack.size(), 0);
  });
  await test('Home clears a stale stack before pushing a fresh library root', async () => {
    const f = fixture();
    const stage = f.createStage();
    stage.stack.paths.push({ name: 'previous', param: { stale: true } });
    stage.loaded({});
    stage.session.attach(stage.stack);
    await f.idle();
    assertCommit(f, stage, [library()], false);
    assert.equal(f.ability.lastDestination.kind, 'home');
  });
  await test('A widget launch appends to the existing navigation stack without replacing its root', async () => {
    const f = await ready();
    const root = f.stage.stack.paths[0];
    const existing = { name: 'apps', param: params({ prompt: 'Kept draft' }) };
    f.stage.stack.paths.push(existing);
    await f.launch({ parameters: { projectId: project.id, veraRun: '1' } });
    assertCommit(f, f.stage, [library(), existing, projectPath(), runnerPath()], false);
    assert.equal(f.stage.stack.paths[0], root);
    assert.equal(f.stage.stack.paths[1], existing, 'existing destinations and their params must survive');
  });
  await test('An unbound live card opens the page that binds it, over the library', async () => {
    const f = await ready();
    const request = await f.launch({ parameters: { veraFormId: 'form-7' } });
    assert.equal(request.kind, 'form');
    assertCommit(f, f.stage, [library(), { name: 'widgetBind', param: params({ formId: 'form-7' }) }], false);
  });
  const cases = [
    ['A widget row with a runnable version opens the runner over its project', {},
      { projectId: ' project-1 ', veraRun: '1' }, 'run', [library(), projectPath(), runnerPath()], false],
    ['A widget row with no runnable version opens the project', { noBytecode: true },
      { projectId: project.id, veraRun: '1' }, 'run', [library(), projectPath()], false],
    ['A widget row for a deleted project preserves home and says so', { missingProject: true },
      { projectId: project.id, veraRun: '1' }, 'run', [library()], false],
    ['An ordinary project launch does not run', {},
      { projectId: project.id }, 'project', [library(), projectPath()], false],
    ['A home-screen shortcut runs on its own', {},
      { projectId: project.id, launchMode: 'runLatest', veraRun: '1' }, 'shortcut',
      [isolatedPath({ projectId: project.id, versionId: runnable.id, vbc2: runnable.vbc2 })], true],
    ['An isolated shortcut for a deleted project shows its launch error without a toast', { missingProject: true },
      { projectId: project.id, launchMode: 'runLatest' }, 'shortcut',
      [isolatedPath({ launchError: 'Mini-app no longer exists.' })], true],
    ['An isolated shortcut without bytecode shows its launch error without a toast', { noBytecode: true },
      { projectId: project.id, launchMode: 'runLatest' }, 'shortcut',
      [isolatedPath({ projectId: project.id, launchError: 'Run is unavailable: no version has compiled code.' })], true]
  ];
  for (const [name, options, parameters, kind, paths, isolated] of cases) {
    await test(name, async () => {
      const f = await ready(options);
      const request = await f.launch({ parameters });
      assert.equal(request.kind, kind);
      assert.equal(request.projectId, project.id);
      assert.equal(request.revision, f.ability.launchRevision);
      if (options.missingProject && !isolated) {
        assert.deepEqual(f.stage.calls, [], 'a missing project must not change the existing stack');
        assert.deepEqual(f.stage.stack.paths, paths);
        assert.deepEqual(f.stage.windowCalls, [], 'a missing project must not change the window mode');
        assert.equal(f.stage.mainWindow.fullScreen, false);
        assert.deepEqual(f.stage.mainWindow.bars, ['status', 'navigation']);
      } else {
        assertCommit(f, f.stage, paths, isolated);
      }
      assert.deepEqual(f.reads, [
        ['init', '/fixture/files'], ['project', project.id],
        ...(!options.missingProject && kind !== 'project' ? [['version', project.id]] : [])
      ]);
      assert.deepEqual(f.stage.toasts, options.missingProject && !isolated ? [{ message: 'Mini-app no longer exists.' }] : []);
      assert.deepEqual(f.events.map(event => event[0]), options.missingProject && !isolated ?
        ['toast'] : ['layout', 'bars', 'paths']);
    });
  }

  for (const normalFullScreen of [false, true]) {
    await test('Home replaces the isolated stack and restores normal fullscreen=' + normalFullScreen + ' and bars', async () => {
      const f = await ready({ normalFullScreen });
      await f.launch({ parameters: { projectId: project.id, launchMode: 'runLatest' } });
      assert.equal(f.stage.mainWindow.fullScreen, true);
      assert.deepEqual(f.stage.mainWindow.bars, []);
      const wants = [{ action: 'action.system.home' }, { entities: ['entity.system.home'] }, {}];
      for (const want of wants) {
        f.stage.calls.length = 0;
        f.stage.windowCalls.length = 0;
        f.reads.length = 0;
        const request = await f.launch(want);
        assert.equal(request.kind, 'home');
        assert.equal(request.projectId, '');
        assertCommit(f, f.stage, [library()], false, normalFullScreen);
        assert.deepEqual(f.stage.toasts, []);
        assert.deepEqual(f.reads, []);
      }
    });
  }

  for (const phase of ['layout', 'bars']) {
    await test('Latest launch wins while async window ' + phase + ' is pending', async () => {
      const f = await ready();
      const gate = f.stage.holdNext(phase);
      f.ability.onNewWant({ parameters: { projectId: project.id, launchMode: 'runLatest' } }, {});
      const stale = f.ability.pendingRoute;
      await pause();
      assert.deepEqual(f.stage.windowCalls, [['layout', true], ...(phase === 'bars' ? [['bars', []]] : [])]);
      assert.equal(f.ability.routeDrainGeneration, f.ability.windowStageGeneration);
      assert.deepEqual(f.stage.calls, []);
      f.ability.onNewWant({ parameters: { projectId: 'project-2', veraRun: '1' } }, {});
      const latest = f.ability.pendingRoute;
      assert(latest.revision > stale.revision);
      assert.equal(f.ability.routeIsCurrent(f.ability.windowStageGeneration, stale.revision), false);
      assert.equal(f.ability.lastDestination.kind, 'home');
      assert.deepEqual(f.stage.calls, []);
      gate.resolve();
      await f.idle();
      const paths = [library(), projectPath('project-2'), runnerPath('project-2')];
      assert.deepEqual(f.stage.calls, [{ paths, animated: false }]);
      assert.deepEqual(f.stage.stack.paths, paths);
      assert.deepEqual(f.stage.windowCalls, [
        ['layout', true], ...(phase === 'bars' ? [['bars', []]] : []),
        ['layout', false], ['bars', ['status', 'navigation']]
      ]);
      assert.equal(f.stage.mainWindow.fullScreen, false);
      assert.deepEqual(f.stage.mainWindow.bars, ['status', 'navigation']);
      assert.equal(f.ability.pendingRoute, null);
      assert.equal(f.ability.lastDestination, latest);
      assert.deepEqual(f.stage.toasts, []);
    });
  }

  for (const first of ['content', 'stack']) {
    await test('Launch waits for both content and NavPathStack readiness (' + first + ' first)', async () => {
      const f = fixture();
      f.ability.onNewWant({ parameters: { projectId: project.id, veraRun: '1' } }, {});
      const request = f.ability.pendingRoute;
      assert.equal(f.ability.routeDrainGeneration, -1);
      const stage = f.createStage();
      const generation = f.ability.windowStageGeneration;
      assert.equal(f.ability.routeIsCurrent(generation, request.revision), false);
      if (first === 'content') { stage.loaded({}); }
      else { stage.session.attach(stage.stack); }
      await f.idle();
      assert.deepEqual(stage.calls, []);
      assert.deepEqual(stage.windowCalls, []);
      assert.equal(f.ability.pendingRoute, request);
      if (first === 'content') { stage.session.attach(stage.stack); }
      else { stage.loaded({}); }
      await f.idle();
      assertCommit(f, stage, [library(), projectPath(), runnerPath()], false);
      assert.equal(f.ability.lastDestination, request);
      assert.equal(f.ability.routeIsCurrent(generation, request.revision), true);
      stage.session.detach(stage.stack);
      assert.equal(f.ability.routeIsCurrent(generation, request.revision), false);
    });
  }

  await test('Stage invalidation rejects stale readiness and an old async drain cannot clear the replacement drain', async () => {
    const f = await ready();
    const old = f.stage;
    const oldGeneration = f.ability.windowStageGeneration;
    const oldReady = old.session.onReady;
    const oldGate = old.holdNext('layout');
    f.ability.onNewWant({ parameters: { projectId: project.id, launchMode: 'runLatest' } }, {});
    const request = f.ability.pendingRoute;
    f.ability.onWindowStageDestroy();
    assert.equal(f.ability.windowStageGeneration, oldGeneration + 1);
    assert.equal(f.ability.contentReady, false);
    assert.equal(f.ability.activeWindowStage, null);
    assert.equal(f.ability.navigationSession, null);
    assert.equal(old.session.pathStack, null);
    assert.equal(f.ability.routeDrainGeneration, -1);
    assert.equal(f.ability.pendingRoute, request);
    assert.equal(f.ability.routeIsCurrent(oldGeneration, request.revision), false);
    old.loaded({});
    oldReady();
    old.session.attach(old.stack);
    assert.equal(old.session.pathStack, null);
    assert.equal(f.ability.contentReady, false);
    const replacement = f.createStage();
    const newGate = replacement.holdNext('layout');
    old.loaded({});
    oldReady();
    assert.equal(f.ability.contentReady, false);
    replacement.loaded({});
    replacement.session.attach(replacement.stack);
    await Promise.resolve();
    const generation = f.ability.windowStageGeneration;
    assert.equal(f.ability.routeDrainGeneration, generation);
    oldGate.resolve();
    await pause();
    assert.equal(f.ability.routeDrainGeneration, generation);
    assert.equal(f.ability.pendingRoute, request);
    assert.deepEqual(old.calls, []);
    assert.deepEqual(old.windowCalls, [['layout', true]]);
    assert.deepEqual(replacement.calls, []);
    newGate.resolve();
    await f.idle();
    assertCommit(f, replacement,
      [isolatedPath({ projectId: project.id, versionId: runnable.id, vbc2: runnable.vbc2 })], true);
    assert.equal(f.ability.lastDestination, request);
    assert.deepEqual(old.calls, []);
  });

  await test('A recreated stage requeues the last committed destination with a fresh revision', async () => {
    const f = await ready();
    const committed = await f.launch({ parameters: { projectId: project.id, veraRun: '1' } });
    const old = f.stage;
    f.ability.onWindowStageDestroy();
    const replay = f.ability.pendingRoute;
    assert.notEqual(replay, committed);
    assert.equal(replay.kind, committed.kind);
    assert.equal(replay.projectId, committed.projectId);
    assert.equal(replay.revision, committed.revision + 1);
    const replacement = f.createStage(true);
    replacement.session.attach(replacement.stack);
    assert.deepEqual(replacement.calls, []);
    replacement.loaded({});
    await f.idle();
    assertCommit(f, replacement, [library(), projectPath(), runnerPath()], false, true);
    assert.equal(f.ability.lastDestination, replay);
    assert.equal(old.calls.length, 1);
    assert.equal(old.session.pathStack, null);
  });

  await test('Unrelated Wants preserve both a pending launch and the committed route', async () => {
    const f = await ready();
    const gate = f.stage.holdNext('layout');
    f.ability.onNewWant({ parameters: { projectId: project.id, veraRun: '1' } }, {});
    const request = f.ability.pendingRoute;
    const revision = f.ability.launchRevision;
    f.ability.onNewWant({ parameters: { unrelated: 'value' } }, {});
    assert.equal(f.ability.pendingRoute, request);
    assert.equal(f.ability.launchRevision, revision);
    gate.resolve();
    await f.idle();
    assertCommit(f, f.stage, [library(), projectPath(), runnerPath()], false);
    const paths = f.stage.stack.paths;
    for (const want of [{ action: 'custom.action' }, { entities: ['custom.entity'] }, { parameters: { unrelated: 'value' } }]) {
      f.ability.onNewWant(want, {});
      await f.idle();
      assert.equal(f.ability.pendingRoute, null);
      assert.equal(f.ability.launchRevision, revision);
      assert.equal(f.ability.lastDestination, request);
      assert.equal(f.stage.stack.paths, paths);
      assert.equal(f.stage.calls.length, 1);
      assert.equal(f.stage.windowCalls.length, 2);
    }
  });

  await test('Ability destruction clears pending and committed routes and invalidates its session', async () => {
    const f = await ready();
    const gate = f.stage.holdNext('layout');
    f.ability.onNewWant({ parameters: { projectId: project.id, launchMode: 'runLatest' } }, {});
    const revision = f.ability.launchRevision;
    f.ability.onDestroy();
    assert.equal(f.ability.pendingRoute, null);
    assert.equal(f.ability.lastDestination, null);
    assert.equal(f.ability.launchRevision, revision + 1);
    assert.equal(f.ability.contentReady, false);
    assert.equal(f.ability.activeWindowStage, null);
    assert.equal(f.ability.navigationSession, null);
    f.stage.loaded({});
    f.stage.session.attach(f.stage.stack);
    gate.resolve();
    await f.idle();
    assert.equal(f.stage.session.pathStack, null);
    assert.deepEqual(f.stage.calls, []);
    assert.deepEqual(f.stage.windowCalls, [['layout', true]]);
    assert.equal(f.ability.pendingRoute, null);
    assert.equal(f.ability.lastDestination, null);
  });
  console.log('PASS ' + passed + ' widget launch checks');
})().catch(error => { console.error(error); process.exitCode = 1; });
