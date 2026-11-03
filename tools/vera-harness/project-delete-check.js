'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const ts = require(process.env.VERA_TYPESCRIPT_PATH || 'typescript')
const sourceRoot = path.resolve(process.env.VERA_SOURCE_ROOT || path.join(__dirname, '../../entry/src/main/ets'))
const compiled = new Map()

function load(name, dependencies, console) {
  if (!compiled.has(name)) {
    const file = path.join(sourceRoot, 'vera', name + '.ets')
    const result = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      fileName: file.replace(/\.ets$/, '.ts'),
      compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020},
      reportDiagnostics: true
    })
    assert.deepEqual((result.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error), [],
      name + ' must transpile without syntax errors')
    compiled.set(name, result.outputText)
  }
  const mod = {exports: {}}
  new Function('require', 'module', 'exports', 'console', compiled.get(name))(dependency => {
    assert.ok(Object.hasOwn(dependencies, dependency), 'Unexpected ' + name + ' dependency: ' + dependency)
    return dependencies[dependency]
  }, mod, mod.exports, console)
  return mod.exports
}

const businessError = (code, message) => Object.assign(new Error(message), {code})
const root = '/fixture/files/vera'
const indexPath = root + '/index.json'
const projectDir = root + '/target'
const checks = []

function memoryFs() {
  const entries = new Map([['/', null]])
  const handles = new Map()
  const calls = [], faults = []
  let nextFd = 1
  const within = (entry, dir) => entry === dir || entry.startsWith(dir + '/')
  function directory(dir) {
    if (entries.has(dir)) {
      assert.equal(entries.get(dir), null, 'Expected a directory: ' + dir)
      return
    }
    directory(path.posix.dirname(dir))
    entries.set(dir, null)
  }
  function file(name, text) {
    directory(path.posix.dirname(name))
    entries.set(name, text)
  }
  function requireEntry(name) {
    if (!entries.has(name)) { throw businessError(13900002, 'No such file or directory: ' + name) }
    return entries.get(name)
  }
  function record(method, name) {
    calls.push({method, path: name})
    const at = faults.findIndex(f => f.method === method && f.path === name)
    if (at < 0) { return }
    const fault = faults.splice(at, 1)[0]
    if (fault.partial) { fault.partial() }
    throw fault.error
  }
  function erase(dir) {
    for (const name of entries.keys()) {
      if (within(name, dir)) { entries.delete(name) }
    }
  }
  const disk = {
    OpenMode: {CREATE: 1, WRITE_ONLY: 2, TRUNC: 4},
    mkdirSync(dir, recursive) {
      record('mkdir', dir)
      assert.equal(recursive, true)
      directory(dir)
    },
    statSync(name) {
      record('stat', name)
      const value = requireEntry(name)
      return {size: value === null ? 0 : Buffer.byteLength(value)}
    },
    readTextSync(name) {
      record('read', name)
      const text = requireEntry(name)
      assert.equal(typeof text, 'string')
      return text
    },
    listFileSync(dir) {
      record('list', dir)
      assert.equal(requireEntry(dir), null)
      return [...entries.keys()].filter(name => name !== dir && path.posix.dirname(name) === dir)
        .map(name => path.posix.basename(name))
    },
    openSync(name, mode) {
      record('open', name)
      assert.equal(mode, disk.OpenMode.CREATE | disk.OpenMode.WRITE_ONLY | disk.OpenMode.TRUNC)
      assert.equal(requireEntry(path.posix.dirname(name)), null)
      entries.set(name, '')
      const fd = nextFd++
      handles.set(fd, name)
      return {fd}
    },
    writeSync(fd, content) {
      assert.ok(handles.has(fd), 'Write needs an open handle')
      const name = handles.get(fd)
      record('write', name)
      entries.set(name, content)
      return Buffer.byteLength(content)
    },
    closeSync(handle) {
      assert.ok(handles.has(handle.fd), 'Close needs an open handle')
      record('close', handles.get(handle.fd))
      handles.delete(handle.fd)
    },
    unlinkSync(name) {
      record('unlink', name)
      assert.equal(typeof requireEntry(name), 'string')
      entries.delete(name)
    },
    rmdirSync(dir) {
      record('rmdir', dir)
      assert.equal(requireEntry(dir), null)
      erase(dir)
    }
  }
  return {disk, entries, calls, faults, handles, file, directory, erase,
    inject(method, name, error, partial) { faults.push({method, path: name, error, partial}) },
    snapshot(dir = '/') {
      return [...entries].filter(([name]) => dir === '/' || within(name, dir))
        .sort(([a], [b]) => a.localeCompare(b))
    }}
}

function fixture(versionCount = 2) {
  const memory = memoryFs(), errors = [], warnings = [], platformCalls = []
  const logger = {error: (...args) => errors.push(args.join(' ')),
    warn: (...args) => warnings.push(args.join(' ')), info() {}}
  const textModule = load('ProjectText', {}, logger)
  const storeModule = load('ProjectStore', {
    '@kit.CoreFileKit': {fileIo: memory.disk},
    '@kit.BasicServicesKit': {},
    './ProjectText': textModule
  }, logger)
  const store = new storeModule.ProjectStore()
  store.init('/fixture/files')
  const project = Object.assign(new storeModule.Project(), {id: 'target', name: 'Target', icon: 'code', createdAt: 100})
  const other = Object.assign(new storeModule.Project(), {id: 'target-copy', name: 'Keep', icon: 'code', createdAt: 101})
  memory.file(indexPath, JSON.stringify([project, other]))
  const versions = []
  for (const p of [project, other]) {
    memory.directory(root + '/' + p.id)
    for (let i = 0; i < (p === project ? versionCount : 1); i++) {
      const version = Object.assign(new storeModule.Version(), {id: 'v' + i, projectId: p.id,
        source: 'source ' + i, vbc2: 'bytecode ' + i, note: 'Version ' + i,
        prompt: 'Request ' + i, createdAt: 200 + i})
      memory.file(root + '/' + p.id + '/' + version.id + '.json', JSON.stringify(version))
      memory.file(root + '/' + p.id + '/' + version.id + '.state.json', JSON.stringify({stamp: 'stamp', value: {count: i}}))
      if (p === project) { versions.push(version) }
    }
    memory.file(root + '/' + p.id + '/assets/nested/data.bin', 'nested saved data')
  }
  const operationsModule = load('ProjectOperations', {
    './ProjectStore': storeModule,
    './ProjectIcons': {projectShortcutIconResource() { assert.fail('Deletion must not load shortcut icons') }},
    '@kit.AbilityKit': {
      bundleManager: {BundleFlag: {GET_BUNDLE_INFO_DEFAULT: 0}, getBundleInfoForSelfSync() {
        platformCalls.push('bundle')
        return {name: 'fixture.vera'}
      }},
      shortcutManager: {async getAllDesktopShortcutInfo(userId) {
        assert.equal(userId, 42)
        platformCalls.push('shortcuts')
        return []
      }}
    },
    '@kit.BasicServicesKit': {osAccount: {getAccountManager: () => ({getOsAccountLocalIdForUidSync(uid) {
      assert.equal(uid, 1000)
      platformCalls.push('account')
      return 42
    }})}},
    '@kit.IPCKit': {rpc: {RemoteObject: class {}}},
    '@kit.ArkTS': {process: {uid: 1000}, util: {}}
  }, logger)
  const operations = new operationsModule.ProjectOperations(store)
  const context = () => { assert.fail('An absent shortcut needs no launcher context') }
  memory.calls.length = 0
  return {...memory, store, project, other, versions, operations, context,
    status: operationsModule.ProjectOperationStatus, errors, warnings, platformCalls}
}

const mutations = f => f.calls.filter(c => ['mkdir', 'open', 'write', 'unlink', 'rmdir'].includes(c.method))
const indexCalls = f => f.calls.filter(c => c.path === indexPath && ['open', 'write'].includes(c.method))
const deletionCalls = f => mutations(f).filter(c => c.method === 'rmdir' || c.path === indexPath)
const expectedDeletion = [
  {method: 'rmdir', path: projectDir},
  {method: 'open', path: indexPath},
  {method: 'write', path: indexPath}
]
function throwsIdentity(action, error) {
  assert.throws(action, caught => {
    assert.strictEqual(caught, error, 'The original thrown value must propagate unchanged')
    return true
  })
}
function preserved(f, index, other) {
  assert.equal(f.entries.get(indexPath), index, 'The project index must be unchanged')
  assert.deepEqual(f.snapshot(root + '/' + f.other.id), other, 'The other project must be unchanged')
  assert.deepEqual(f.faults, [], 'The injected fault must have been reached')
  assert.equal(f.handles.size, 0, 'No file handles may leak')
}
function deleted(f, other) {
  assert.deepEqual(f.snapshot(projectDir), [], 'All project files and nested directories must be deleted')
  assert.deepEqual(f.store.listProjects().map(p => p.id), [f.other.id])
  assert.deepEqual(f.snapshot(root + '/' + f.other.id), other, 'The other project must be unchanged')
  assert.equal(f.handles.size, 0, 'No file handles may leak')
}
function check(name, run) { checks.push({name, run}) }

check('recursive deletion precedes index write and preserves the other project and its summary', () => {
  const f = fixture(), other = f.snapshot(root + '/' + f.other.id)
  f.store.summaryOf(f.project)
  const otherSummary = f.store.summaryOf(f.other)
  f.store.deleteProject(f.project.id)
  assert.deepEqual(deletionCalls(f), expectedDeletion)
  assert.deepEqual(f.calls.filter(c => c.method === 'unlink'), [])
  deleted(f, other)
  assert.strictEqual(f.store.summaryOf(f.other), otherSummary)
  assert.equal(f.store.summaryOf(f.project).versions, 0)
})

check('missing directory code 13900002 still cleans up the index', () => {
  const f = fixture(), other = f.snapshot(root + '/' + f.other.id)
  const cached = f.store.summaryOf(f.project)
  f.erase(projectDir)
  f.store.deleteProject(f.project.id)
  assert.deepEqual(deletionCalls(f), expectedDeletion)
  deleted(f, other)
  const summary = f.store.summaryOf(f.project)
  assert.notStrictEqual(summary, cached)
  assert.equal(summary.versions, 0)
})

const failures = [
  ['permission', () => businessError(13900012, 'Permission denied')],
  ['busy', () => businessError(13900014, 'Device or resource busy')],
  ['unexpected business error', () => businessError(13900005, 'Unexpected I/O error')],
  ['ordinary Error', () => new Error('Unexpected failure')],
  ['non-Error object', () => ({message: 'Unexpected object', detail: 7})],
  ['string missing-directory code', () => ({code: '13900002', message: 'Not the numeric missing-directory code'})],
  ['primitive', () => 'unexpected thrown string'],
  ['null', () => null],
  ['undefined', () => undefined]
]
for (const [name, makeError] of failures) {
  check(name + ' propagates unchanged, preserves the index without writes, and permits retry', () => {
    const f = fixture(), error = makeError(), before = f.snapshot()
    const index = f.entries.get(indexPath), other = f.snapshot(root + '/' + f.other.id)
    f.inject('rmdir', projectDir, error)
    throwsIdentity(() => f.store.deleteProject(f.project.id), error)
    assert.deepEqual(indexCalls(f), [], 'A failed rmdir must not even open the index for writing')
    assert.deepEqual(mutations(f), [{method: 'rmdir', path: projectDir}])
    assert.deepEqual(f.snapshot(), before)
    preserved(f, index, other)
    f.calls.length = 0
    f.store.deleteProject(f.project.id)
    assert.deepEqual(deletionCalls(f), expectedDeletion)
    deleted(f, other)
  })
}

check('unknown project leaves even an orphan directory untouched', () => {
  const f = fixture()
  f.file(root + '/unknown/nested/keep.json', '{"keep":true}')
  const before = f.snapshot()
  f.store.deleteProject('unknown')
  assert.deepEqual(mutations(f), [])
  assert.deepEqual(f.snapshot(), before)
})

check('index open failure follows rmdir, invalidates summary, and retry removes the residual index entry', () => {
  const f = fixture(), error = businessError(13900012, 'Cannot open index')
  const index = f.entries.get(indexPath), other = f.snapshot(root + '/' + f.other.id)
  const cached = f.store.summaryOf(f.project)
  assert.equal(cached.versions, 2)
  f.inject('open', indexPath, error)
  throwsIdentity(() => f.store.deleteProject(f.project.id), error)
  assert.deepEqual(deletionCalls(f), expectedDeletion.slice(0, 2))
  assert.deepEqual(f.snapshot(projectDir), [])
  preserved(f, index, other)
  assert.ok(f.store.getProject(f.project.id), 'Failed index open must retain the index entry')
  const summary = f.store.summaryOf(f.project)
  assert.notStrictEqual(summary, cached)
  assert.equal(summary.versions, 0)
  assert.equal(summary.request, '')
  assert.equal(summary.updatedAt, f.project.createdAt)
  f.calls.length = 0
  f.store.deleteProject(f.project.id)
  assert.deepEqual(deletionCalls(f), expectedDeletion)
  deleted(f, other)
})

check('partial rmdir failure invalidates summary before deletion while preserving the index for retry', () => {
  const f = fixture(), error = businessError(13900014, 'Partial recursive removal')
  const index = f.entries.get(indexPath), other = f.snapshot(root + '/' + f.other.id)
  const cached = f.store.summaryOf(f.project)
  assert.equal(cached.request, 'Request 1')
  f.inject('rmdir', projectDir, error, () => {
    f.entries.delete(projectDir + '/v1.json')
    f.entries.delete(projectDir + '/v1.state.json')
  })
  throwsIdentity(() => f.store.deleteProject(f.project.id), error)
  assert.deepEqual(indexCalls(f), [])
  preserved(f, index, other)
  const summary = f.store.summaryOf(f.project)
  assert.notStrictEqual(summary, cached)
  assert.equal(summary.versions, 1)
  assert.equal(summary.request, 'Request 0')
  assert.equal(summary.updatedAt, 200)
  f.store.deleteProject(f.project.id)
  deleted(f, other)
})

check('last-version deletion propagates rmdir failure and retry deletes the project, version, and state', () => {
  const f = fixture(1), error = businessError(13900012, 'Last version removal denied')
  const before = f.snapshot(), index = f.entries.get(indexPath), other = f.snapshot(root + '/' + f.other.id)
  f.inject('rmdir', projectDir, error)
  throwsIdentity(() => f.store.deleteVersion(f.project.id, f.versions[0].id), error)
  assert.deepEqual(indexCalls(f), [])
  assert.deepEqual(f.snapshot(), before)
  preserved(f, index, other)
  f.calls.length = 0
  assert.equal(f.store.deleteVersion(f.project.id, f.versions[0].id), true)
  assert.deepEqual(deletionCalls(f), expectedDeletion)
  deleted(f, other)
})

for (const method of ['deleteProject', 'deleteVersion']) {
  for (const [name, makeError] of failures.slice(0, 4)) {
    check('ProjectOperations.' + method + ' returns Failed and logs ' + name + ', then releases its lock for retry', async () => {
      const f = fixture(1), error = makeError(), before = f.snapshot()
      const index = f.entries.get(indexPath), other = f.snapshot(root + '/' + f.other.id)
      const operation = method === 'deleteProject' ? 'Delete project' : 'Delete Version ' + f.versions[0].id
      const invoke = () => f.operations[method](f.context, f.project.id, f.versions[0].id)
      f.inject('rmdir', projectDir, error)
      const pending = invoke()
      assert.equal(await invoke(), f.status.Busy, 'The real operation must hold its lock while awaiting platform calls')
      assert.equal(await pending, f.status.Failed)
      assert.deepEqual(f.errors, [operation + ' failed for project "target": error code = ' +
        (error.code === undefined ? 'unknown' : error.code) + ', message = "' + error.message + '"'])
      assert.equal(f.warnings.length, 1)
      assert.match(f.warnings[0], /is busy$/)
      assert.deepEqual(indexCalls(f), [])
      assert.deepEqual(f.snapshot(), before)
      preserved(f, index, other)
      f.calls.length = 0
      assert.equal(await invoke(), method === 'deleteProject' ? f.status.Success : f.status.ProjectDeleted,
        'Retry must not return Busy after the failed operation')
      assert.deepEqual(deletionCalls(f), expectedDeletion)
      assert.equal(f.errors.length, 1, 'Successful retry must not log a failure')
      assert.equal(f.platformCalls.filter(c => c === 'shortcuts').length, 2)
      deleted(f, other)
    })
  }
  check('ProjectOperations.' + method + ' succeeds through real store and platform lookup', async () => {
    const f = fixture(1), other = f.snapshot(root + '/' + f.other.id)
    const invoke = () => f.operations[method](f.context, f.project.id, f.versions[0].id)
    assert.equal(await invoke(), method === 'deleteProject' ? f.status.Success : f.status.ProjectDeleted)
    assert.deepEqual(deletionCalls(f), expectedDeletion)
    assert.deepEqual(f.platformCalls, ['bundle', 'account', 'shortcuts'])
    assert.deepEqual(f.errors, [])
    assert.deepEqual(f.warnings, [])
    deleted(f, other)
    f.calls.length = 0
    assert.equal(await invoke(), f.status.NotFound)
    assert.deepEqual(mutations(f), [])
  })
}

;(async () => {
  let failed = 0
  for (const {name, run} of checks) {
    try {
      await run()
      console.log('PASS ' + name)
    } catch (error) {
      failed++
      console.error('FAIL ' + name + '\n' + (error && error.stack || String(error)))
    }
  }
  console.log('project-delete-check: ' + (checks.length - failed) + '/' + checks.length + ' passed')
  if (failed) { process.exitCode = 1 }
})().catch(error => { console.error(error); process.exitCode = 1 })
