'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const ts = process.env.VERA_TYPESCRIPT_PATH ? require(process.env.VERA_TYPESCRIPT_PATH) : require('typescript')
const {loadVera, loadSource, sourceRoot} = require('./source-loader')
const S = loadVera('VeraScene')
const T = loadVera('VeraTextures')
const G = loadVera('VeraShapes')
const P = loadVera('VeraSurfaces')
const L = loadVera('VeraLook3D')
const {resolveTheme} = loadVera('VeraTheme')
const theme = resolveTheme('clean', '#2764cc', false)
const controllerFile = path.join(sourceRoot, 'components/VeraWorld3D.ets')
const compiled = ts.transpileModule(fs.readFileSync(controllerFile, 'utf8'), {
  fileName: controllerFile.replace(/\.ets$/, '.ts'),
  compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020,
    experimentalDecorators: true, useDefineForClassFields: false}, reportDiagnostics: true
})
const errors = (compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error)
assert.equal(errors.length, 0, ts.formatDiagnosticsWithColorAndContext(errors, {
  getCurrentDirectory: () => sourceRoot, getCanonicalFileName: f => f, getNewLine: () => '\n'
}))
const checks = []
const filesDir = '/mock-app/files'
const c1 = [0.12, 0.31, 0.72, 1], c2 = [0.91, 0.64, 0.08, 1]
const deferred = () => {
  let resolve
  const promise = new Promise(done => { resolve = done })
  return {promise, resolve}
}

function fixture() {
  const calls = [], scenes = [], resources = [], maps = [], packers = [], logs = []
  const files = new Map(), dirs = new Set(), handles = new Map(), faults = new Set(), timers = new Map()
  const boxes = [], loaded = new Set()
  let fd = 0, timerId = 0, gate = null
  function record(op, name, scene) {
    calls.push({op, name, scene})
    if (faults.has(op) || faults.has(op + ':' + name)) throw new Error('injected ' + op + ':' + name)
  }
  async function api(op, name, scene, make) {
    record(op, name, scene)
    const held = gate
    if (held && held.op === op && (held.name === undefined || held.name === name)) {
      held.entered.resolve()
      await held.release.promise
    }
    return make()
  }
  function node(name, scene) {
    const children = []
    const made = {name, scene, parent: null, position: {x: 0, y: 0, z: 0},
      rotation: {x: 0, y: 0, z: 0, w: 1}, scale: {x: 1, y: 1, z: 1}, destroys: 0,
      children: {
        append(child) {
          if (child.parent) child.parent.children.remove(child)
          child.parent = made
          children.push(child)
        },
        remove(child) {
          const at = children.indexOf(child)
          if (at >= 0) { children.splice(at, 1); child.parent = null }
        },
        get: index => children[index] || null,
        count: () => children.length
      },
      destroy() { record('nodeDestroy', name, scene); this.destroys++ }
    }
    resources.push(made)
    return made
  }
  function makeScene() {
    const scene = {id: scenes.length, destroys: 0,
      destroy() { record('destroy', String(this.id), this); this.destroys++ },
      getResourceFactory() { return factory }
    }
    scene.root = node('root', scene)
    function resource(op, params, make) {
      assert.equal(scene.destroys, 0, op + ' cannot start on a destroyed scene')
      return api(op, params.name, scene, () => {
        const made = make()
        resources.push(made)
        return made
      })
    }
    function sceneNode(params) {
      const made = node(params.name, scene)
      scene.root.children.append(made)
      return made
    }
    const factory = {
      createCamera: params => resource('camera', params, () => sceneNode(params)),
      createEnvironment: params => resource('environment', params, () => ({...params, scene})),
      createLight: (params, type) => resource('light', params, () => Object.assign(sceneNode(params), {type})),
      createNode: params => resource('node', params, () => sceneNode(params)),
      createImage: params => resource('image', params, () => {
        assert.ok(params.uri.startsWith('file://'))
        const file = params.uri.slice(7)
        assert.ok(files.get(file)?.length > 0, 'image requires published PNG')
        assert.ok(!file.endsWith('.tmp'), 'image never reads a temporary file')
        return {...params, scene}
      }),
      createSampler: params => resource('sampler', params, () => ({...params, scene})),
      createMaterial: (params, type) => resource('material', params, () => ({...params, scene, type,
        baseColor: {factor: {x: 1, y: 1, z: 1, w: 1}},
        material: {factor: {x: 0.7, y: 0.5, z: 0.5, w: 0.4}},
        specular: {factor: {x: 1, y: 1, z: 1, w: 1}}
      })),
      createMesh: (params, geometry) => resource('mesh', params,
        () => Object.preventExtensions({...params, scene, geometry})),
      createGeometry: (params, mesh) => resource('geometry', params, () => {
        assert.equal(mesh.scene, scene)
        return Object.assign(sceneNode(params), {meshResource: mesh, mesh: {subMeshes: [{material: null}]}})
      })
    }
    scenes.push(scene)
    return scene
  }
  function stat(file) {
    record('stat', file)
    if (!files.has(file) && !dirs.has(file)) throw new Error('ENOENT ' + file)
    return {isFile: () => files.has(file), isDirectory: () => dirs.has(file), size: files.get(file)?.length || 0}
  }
  const fileIo = {
    OpenMode: {CREATE: 1, WRITE_ONLY: 2, TRUNC: 8},
    mkdirSync(dir, recursive) {
      record('mkdir', dir)
      assert.equal(recursive, true)
      if (dirs.has(dir) || files.has(dir)) throw new Error('EEXIST ' + dir)
      dirs.add(dir)
    },
    statSync: stat,
    accessSync(file) { record('access', file); return files.has(file) || dirs.has(file) },
    openSync(file, mode) {
      record('open', file)
      assert.equal(mode, 11)
      const handle = {fd: ++fd, file}
      handles.set(fd, handle)
      files.set(file, Buffer.alloc(0))
      return handle
    },
    closeSync(handle) {
      assert.equal(handles.get(handle.fd), handle, 'file closed exactly once')
      record('close', handle.file)
      handles.delete(handle.fd)
    },
    renameSync(from, to) {
      record('rename', from)
      assert.ok(from.startsWith(to + '.') && from.endsWith('.tmp'))
      assert.ok(files.get(from)?.length > 0, 'only packed files published')
      assert.ok(![...handles.values()].some(h => h.file === from), 'close before rename')
      if (dirs.has(to)) throw new Error('EISDIR ' + to)
      files.set(to, files.get(from))
      files.delete(from)
    },
    unlinkSync(file) { record('unlink', file); assert.ok(files.delete(file)) }
  }
  const image = {
    PixelMapFormat: {RGBA_8888: 'rgba8888'},
    createPixelMap: (buffer, config) => api('pixelMap', String(config.size.width), null, () => {
      assert.equal(config.srcPixelFormat, image.PixelMapFormat.RGBA_8888,
        'createPixelMap must explicitly declare RGBA_8888 source bytes; the platform default is BGRA')
      assert.deepEqual(config, {size: {width: 256, height: 256}, pixelFormat: 'rgba8888',
        srcPixelFormat: 'rgba8888', editable: false})
      assert.equal(buffer.byteLength, 256 * 256 * 4)
      const map = {pixels: Buffer.from(buffer), options: {...config, size: {...config.size}}, releases: 0,
        async release() { this.releases++; record('pixelRelease', String(maps.indexOf(this))) }
      }
      maps.push(map)
      return map
    }),
    createImagePacker() {
      record('packer', String(packers.length))
      const packer = {releases: 0,
        async packToFile(map, number, config) {
          const handle = handles.get(number)
          assert.ok(handle, 'packing requires open fd')
          assert.deepEqual(config, {format: 'image/png', quality: 100})
          await api('pack', handle.file, null, () => { files.set(handle.file, map.pixels) })
        },
        async release() { this.releases++; record('packerRelease', String(packers.indexOf(this))) }
      }
      packers.push(packer)
      return packer
    }
  }
  class CustomGeometry {}
  class CubeGeometry {}
  class SphereGeometry {}
  class CylinderGeometry {}
  class PlaneGeometry {}
  const stubs = {
    '@kit.ArkGraphics3D': {
      Scene: {load: () => api('load', 'empty', null, makeScene)},
      CustomGeometry, CubeGeometry, SphereGeometry, CylinderGeometry, PlaneGeometry,
      PrimitiveTopology: {TRIANGLE_LIST: 'triangles'}, LightType: {DIRECTIONAL: 'directional', SPOT: 'spot'},
      EnvironmentBackgroundType: {BACKGROUND_NONE: 'none'}, MaterialType: {METALLIC_ROUGHNESS: 'pbr', UNLIT: 'unlit'},
      SamplerAddressMode: {REPEAT: 'repeat'}, SamplerFilter: {LINEAR: 'linear'}
    },
    '@kit.ImageKit': {image}, '@kit.CoreFileKit': {fileIo},
    '@kit.BasicServicesKit': {systemDateTime: {}}, '@kit.PerformanceAnalysisKit': {hidebug: {}}, 'libphys.so': {}
  }
  const globals = {
    ObservedV2: value => value, Trace() {}, ModelType: {SURFACE: 'surface'},
    CanvasRenderingContext2D: class {}, RenderingContextSettings: class {},
    console: {info: line => logs.push(line), warn: line => logs.push(line), error: line => logs.push(line)},
    setTimeout(fn, ms) { const id = ++timerId; timers.set(id, {fn, ms}); return id },
    clearTimeout: id => timers.delete(id)
  }
  const mod = {exports: {}}
  const req = id => {
    if (Object.hasOwn(stubs, id)) return stubs[id]
    assert.ok(id.startsWith('.'), 'unexpected dependency ' + id)
    const file = path.resolve(path.dirname(controllerFile), id + '.ets')
    loaded.add(file)
    return loadSource(file)
  }
  new Function('require', 'module', 'exports', ...Object.keys(globals), compiled.outputText)(
    req, mod, mod.exports, ...Object.values(globals))
  async function until(predicate) {
    for (let i = 0; i < 10000; i++) {
      if (predicate()) return
      await Promise.resolve()
      for (const [id, timer] of timers) {
        if (timer.ms === 16) { timers.delete(id); timer.fn() }
      }
    }
    assert.fail('mock async work did not settle')
  }
  async function settle(promise) {
    let done = false, value, error
    Promise.resolve(promise).then(v => { value = v; done = true }, e => { error = e; done = true })
    await until(() => done)
    if (error) throw error
    return value
  }
  function clean() {
    assert.equal(handles.size, 0, 'no open file descriptors')
    assert.ok(maps.every(m => m.releases === 1), 'every PixelMap released once')
    assert.ok(packers.every(p => p.releases === 1), 'every packer released once')
    assert.ok([...files.keys()].every(file => !file.endsWith('.tmp')), 'no temporary files left')
  }
  return {calls, scenes, resources, maps, packers, files, dirs, handles, faults, logs, loaded, settle, clean,
    count: op => calls.filter(c => c.op === op).length,
    hold(op, name) { gate = {op, name, entered: deferred(), release: deferred()}; return gate },
    async create(dir = filesDir) {
      const box = new mod.exports.WorldBox(dir)
      boxes.push(box)
      assert.equal(await settle(box.create()), true)
      return box
    },
    async apply(box, spec, palette = theme) {
      box.apply(spec, palette)
      await until(() => !box.running)
      assert.equal(box.appliedSpec(), spec, box.note || 'spec was not applied')
      assert.equal(box.note, '')
    },
    destroy() { for (const box of boxes) box.destroy() }
  }
}

const body = (id = 'sample', shape = 'box', extra = {}) => Object.assign(new S.BodySpec(), {
  id, shape, dims: shape === 'sphere' ? [1.4, 1.4, 1.4] : shape === 'cylinder' ? [1.4, 2.3, 1.4] : [2, 3, 4],
  color: 'accent', color2: 'ink', pattern: 'wood', position: [1, 2, 3], rotation: [10, 20, 30],
  points: shape === 'shape' ? [0, 0, 2, 0, 2, 1, 1, 1, 1, 2, 0, 2] :
    shape === 'hull' ? [-1, 0, -1, 1, 0, -1, 1, 0, 1, -1, 0, 1, 0, 2, 0] : []
}, extra)
const world = bodies => Object.assign(new S.WorldSpec(), {bodies})
const materialOf = node => node.mesh.subMeshes[0].material
const expectedMesh = b => b.shape === 'shape' ? G.prismMesh(b.points, b.dims[1]) :
  b.shape === 'hull' ? G.hullMesh(b.points) : b.shape === 'sphere' ? G.texturedSphereMesh(b.dims[0] / 2, 48, 24) :
    b.shape === 'cylinder' ? G.texturedCylinderMesh(b.dims[0] / 2, b.dims[1], 32) : G.texturedBoxMesh(...b.dims)
function assertGeometry(node, mesh) {
  const g = node.meshResource.geometry
  assert.equal(g.constructor.name, 'CustomGeometry')
  assert.equal(g.topology, 'triangles')
  assert.deepEqual(g.vertices, Array.from({length: mesh.positions.length / 3}, (_, i) => ({
    x: mesh.positions[i * 3], y: mesh.positions[i * 3 + 1], z: mesh.positions[i * 3 + 2]
  })))
  assert.deepEqual(g.normals, Array.from({length: mesh.normals.length / 3}, (_, i) => ({
    x: mesh.normals[i * 3], y: mesh.normals[i * 3 + 1], z: mesh.normals[i * 3 + 2]
  })))
  assert.deepEqual(g.colors, Array.from({length: mesh.colors.length / 3}, (_, i) => ({
    r: L.srgbToLinear(mesh.colors[i * 3]), g: L.srgbToLinear(mesh.colors[i * 3 + 1]),
    b: L.srgbToLinear(mesh.colors[i * 3 + 2]), a: 1
  })))
  assert.deepEqual(g.indices, mesh.indices)
  if (mesh.uvs.length === 0) assert.equal(g.uvs, undefined)
  else {
    assert.deepEqual(g.uvs, Array.from({length: mesh.uvs.length / 2}, (_, i) => ({x: mesh.uvs[i * 2], y: mesh.uvs[i * 2 + 1]})))
    assert.equal(g.uvs.length, g.vertices.length)
    assert.ok(g.uvs.every(uv => Number.isFinite(uv.x) && Number.isFinite(uv.y)))
  }
}
function assertTexture(f, node, pattern, first, second, seed, options = {}) {
  const m = materialOf(node), key = T.textureKey(pattern, first, second, seed)
  const file = filesDir + '/vera/tex/' + key + '.png'
  assert.equal(m.scene, node.scene)
  assert.equal(m.type, options.glow ? 'unlit' : 'pbr')
  assert.equal(m.baseColor.image.scene, node.scene, 'images belong to the consuming scene')
  assert.equal(m.baseColor.image.name, key)
  assert.equal(m.baseColor.image.uri, 'file://' + file)
  assert.deepEqual(f.files.get(file), Buffer.from(T.texturePixels(pattern, first, second, seed, 256)))
  assert.equal(m.baseColor.sampler.scene, node.scene)
  assert.equal(m.baseColor.sampler.addressModeU, 'repeat')
  assert.equal(m.baseColor.sampler.addressModeV, 'repeat')
  assert.equal(m.baseColor.sampler.minFilter, 'linear')
  assert.equal(m.baseColor.sampler.magFilter, 'linear')
  const factor = options.glow ? 1 : 1 / (options.gain || 1)
  assert.deepEqual(m.baseColor.factor, {x: factor, y: factor, z: factor, w: 1})
  assert.equal(m.shadowReceiver === true, options.receiver === true)
  if (!options.glow) {
    assert.equal(m.material.factor.y, options.floor ? L.FLOOR_ROUGHNESS : T.textureRoughness(pattern))
    assert.equal(m.material.factor.z, L.FLOOR_METALLIC)
    assert.equal(m.material.factor.x, 0.7)
    assert.equal(m.material.factor.w, 0.4)
    if (options.floor) assert.equal(m.specular.factor.w, L.FLOOR_SPECULAR)
  }
  return m
}
const assertBodyTexture = (f, node, b, palette = theme, glow = b.glow) => assertTexture(f, node, b.pattern,
  L.lookRgba(palette, b.color, 'ink'), L.lookRgba(palette, b.color2 || b.color, 'ink'), P.surfaceSeed(b.id), {glow})
async function check(name, run) {
  const f = fixture()
  try {
    await run(f)
    f.clean()
    checks.push({name, status: 'PASS'})
    console.log('PASS ' + name)
  } catch (error) {
    checks.push({name, status: 'FAIL', error: error.message})
    console.error('FAIL ' + name + '\n  ' + error.message)
  } finally { f.destroy() }
}

async function main() {
  console.log('Current WorldBox and real pure modules; mocked scene kits, PNG encoder, filesystem and timers.')
  await check('RGBA source format is explicit and red/blue checker bytes reach packing without swizzling', async f => {
    const box = await f.create()
    const first = [1, 0.2, 0, 1], second = [0, 0.4, 1, 1], seed = 321
    const material = await f.settle(box.texturedMaterial('checker', first, second, seed, false, false))
    assert.equal(f.maps.length, 1)
    const map = f.maps[0]
    assert.equal(map.options.srcPixelFormat, 'rgba8888')
    assert.equal(map.options.pixelFormat, 'rgba8888')
    const pixel = (x, y) => Array.from(map.pixels.subarray((y * 256 + x) * 4, (y * 256 + x) * 4 + 4))
    assert.deepEqual(pixel(0, 0), [255, 51, 0, 255], 'red stays in R, not B')
    assert.deepEqual(pixel(32, 0), [0, 102, 255, 255], 'blue stays in B, not R')
    assert.deepEqual(map.pixels, Buffer.from(T.texturePixels('checker', first, second, seed, 256)),
      'renderer passes RGBA bytes unchanged, without a compensating channel swap')
    assert.deepEqual(f.files.get(material.baseColor.image.uri.slice(7)), map.pixels)
    assert.equal(f.count('pack'), 1)
  })
  for (const shape of ['box', 'sphere', 'cylinder', 'shape', 'hull']) {
    await check('all 11 patterns: ' + shape + ' geometry, UVs, RGBA, image and material', async f => {
      const box = await f.create()
      for (const [pattern] of T.TEXTURE_PATTERNS) {
        const b = body(pattern, shape, {pattern})
        await f.apply(box, world([b]))
        const entry = box.bodies.get(b.id)
        assertGeometry(entry.node, expectedMesh(b))
        assertBodyTexture(f, entry.node, b)
        assert.deepEqual(entry.node.position, {x: 1, y: 2, z: 3})
      }
      for (const name of ['VeraLook3D', 'VeraShapes', 'VeraTextures', 'VeraScene', 'VeraSurfaces']) {
        assert.ok(f.loaded.has(path.join(sourceRoot, 'vera', name + '.ets')))
      }
    })
  }
  await check('eight legacy sphere patterns retain vertex colours, no UVs and no texture I/O', async f => {
    const box = await f.create()
    for (const pattern of ['patches', 'bands', 'oval', 'craters', 'mottled', 'polar', 'swirls', 'stripes']) {
      const b = body(pattern, 'sphere', {pattern, glow: pattern === 'bands'})
      await f.apply(box, world([b]))
      const node = box.bodies.get(b.id).node
      assertGeometry(node, P.paintedSphere(b.dims[0] / 2, pattern,
        L.lookRgba(theme, b.color), L.lookRgba(theme, b.color2), P.surfaceSeed(b.id)))
      assert.equal(materialOf(node).type, b.glow ? 'unlit' : 'pbr')
      assert.equal(materialOf(node).baseColor.image, undefined)
    }
    for (const op of ['pixelMap', 'pack', 'image', 'sampler', 'open']) assert.equal(f.count(op), 0)
  })
  await check('plain primitives keep native geometry and do not allocate images', async f => {
    const box = await f.create()
    for (const shape of ['box', 'sphere', 'cylinder']) {
      const b = body(shape, shape, {pattern: ''})
      await f.apply(box, world([b]))
      const node = box.bodies.get(b.id).node
      assert.equal(node.meshResource.geometry.constructor.name, {box: 'CubeGeometry', sphere: 'SphereGeometry', cylinder: 'CylinderGeometry'}[shape])
      assert.equal(materialOf(node).baseColor.image, undefined)
    }
    assert.equal(f.count('pixelMap'), 0)
  })
  await check('group parts use individual geometry, colours and inherited or local glow', async f => {
    const box = await f.create()
    const parts = ['box', 'sphere', 'cylinder', 'shape', 'hull'].map((shape, i) => body('part-' + shape, shape,
      {pattern: T.TEXTURE_PATTERNS[i][0], glow: i === 1, position: [i, 1, -i]}))
    for (const glow of [false, true, false]) {
      const group = body('group', 'group', {parts, glow})
      await f.apply(box, world([group]))
      const entry = box.bodies.get(group.id)
      assert.equal(entry.parts.length, parts.length)
      for (let i = 0; i < parts.length; i++) {
        assert.equal(entry.parts[i].parent, entry.node)
        assertGeometry(entry.parts[i], expectedMesh(parts[i]))
        assertBodyTexture(f, entry.parts[i], parts[i], theme, glow || parts[i].glow)
        assert.equal(box.partByName.get(entry.parts[i].name), parts[i].id)
      }
    }
  })
  await check('changing only a patterned part glow updates its material in place', async f => {
    const box = await f.create(), part = body('part')
    const group = body('group', 'group', {parts: [part]})
    await f.apply(box, world([group]))
    const node = box.bodies.get(group.id).parts[0]
    const nextPart = body('part', 'box', {glow: true})
    await f.apply(box, world([body('group', 'group', {parts: [nextPart]})]))
    assert.equal(box.bodies.get(group.id).parts[0], node)
    assertBodyTexture(f, node, nextPart)
  })
  await check('floor and all table pieces: UVs, shadow receivers, matte floor and glow gain changes', async f => {
    const box = await f.create()
    const spec = world([])
    spec.table = Object.assign(new S.TableSpec(), {width: 4, depth: 3, pattern: 'planks', color: 'accent', color2: 'ink'})
    spec.floor = Object.assign(new S.FloorSpec(), {pattern: 'tiles', color: 'surface', color2: 'accent'})
    let tableNodes, floorImage
    for (const glow of [false, true, false]) {
      const next = Object.assign(new S.WorldSpec(), spec, {bodies: glow ? [body('lamp', 'sphere', {glow: true})] : []})
      await f.apply(box, next)
      const parts = L.tableParts(next.table)
      assert.equal(box.tableNodes.length, parts.length)
      for (let i = 0; i < parts.length; i++) {
        const node = box.tableNodes[i], p = parts[i]
        assertGeometry(node, G.texturedBoxMesh(p[3], p[4], p[5]))
        assert.deepEqual(node.position, {x: p[0], y: p[1], z: p[2]})
        assertTexture(f, node, 'planks', L.lookRgba(theme, 'accent'), L.lookRgba(theme, 'ink'), P.surfaceSeed('table'), {receiver: true})
      }
      if (tableNodes) assert.deepEqual(box.tableNodes, tableNodes, 'glow does not rebuild the table')
      tableNodes = box.tableNodes.slice()
      assert.equal(box.floorNodes.length, 1)
      const node = box.floorNodes[0], size = L.floorSize(next)
      assertGeometry(node, G.texturedPlaneMesh(size, size))
      assert.equal(node.position.y, -L.TABLE_TOP_THICKNESS)
      const m = assertTexture(f, node, 'tiles', L.lookRgba(theme, L.floorColor(theme, 'surface')),
        L.lookRgba(theme, 'accent'), P.surfaceSeed('floor'), {receiver: true, floor: true, gain: L.floorGain(glow)})
      if (floorImage) assert.equal(m.baseColor.image, floorImage, 'gain changes reuse the image')
      floorImage = m.baseColor.image
    }
  })
  for (const kind of ['theme', 'first colour', 'second colour']) {
    await check(kind + ' change recolours bodies, parts, floor and table', async f => {
      const box = await f.create()
      const b = body('main'), part = body('part', 'cylinder')
      const make = (first, second) => {
        const spec = world([Object.assign(new S.BodySpec(), b, {color: first, color2: second}),
          body('group', 'group', {parts: [Object.assign(new S.BodySpec(), part, {color: first, color2: second})]})])
        spec.floor = Object.assign(new S.FloorSpec(), {pattern: 'stone', color: first, color2: second})
        spec.table = Object.assign(new S.TableSpec(), {width: 3, depth: 2, pattern: 'wood', color: first, color2: second})
        return spec
      }
      const before = make('accent', 'ink')
      await f.apply(box, before)
      const old = [box.bodies.get('main').node, box.bodies.get('group').parts[0], box.floorNodes[0], box.tableNodes[0]]
      const oldImages = old.map(n => materialOf(n).baseColor.image)
      const palette = kind === 'theme' ? resolveTheme('clean', '#c1482b', true) : theme
      const after = kind === 'theme' ? before : make(kind === 'first colour' ? '#168745' : 'accent', kind === 'second colour' ? '#d3a212' : 'ink')
      await f.apply(box, after, palette)
      const nodes = [box.bodies.get('main').node, box.bodies.get('group').parts[0], box.floorNodes[0], box.tableNodes[0]]
      assertBodyTexture(f, nodes[0], after.bodies[0], palette)
      assertBodyTexture(f, nodes[1], after.bodies[1].parts[0], palette)
      for (const [i, ground, role, seed] of [[2, after.floor, L.LOOK_FLOOR_ROLE, 'floor'], [3, after.table, L.LOOK_TABLE_ROLE, 'table']]) {
        assertTexture(f, nodes[i], ground.pattern, L.lookRgba(palette, ground.color, role), L.lookRgba(palette, ground.color2, role),
          P.surfaceSeed(seed), {receiver: true, floor: i === 2, gain: i === 2 ? L.floorGain(false) : 1})
      }
      nodes.forEach((n, i) => assert.notEqual(materialOf(n).baseColor.image, oldImages[i]))
      if (kind === 'theme') {
        assert.equal(nodes[0], old[0], 'theme changes keep textured geometry')
        assert.equal(nodes[1], old[1])
      }
    })
  }
  await check('concurrent same key shares disk work across boxes, but images and materials stay scene-local', async f => {
    const a = await f.create(), b = await f.create(), held = f.hold('pack')
    const first = a.texturedMaterial('wood', c1, c2, 123, false, false)
    const same = a.texturedMaterial('wood', c1, c2, 123, false, false)
    const unlit = a.texturedMaterial('wood', c1, c2, 123, true, false)
    const other = b.texturedMaterial('wood', c1, c2, 123, false, false)
    assert.equal(first, same, 'same material promise')
    await f.settle(held.entered.promise)
    assert.equal(f.count('pixelMap'), 1)
    assert.equal(f.count('pack'), 1)
    assert.equal(f.count('image'), 0)
    held.release.resolve()
    const [m1, m2, m3] = await f.settle(Promise.all([first, unlit, other]))
    assert.equal(m1.baseColor.image, m2.baseColor.image)
    assert.notEqual(m1.baseColor.image, m3.baseColor.image)
    assert.equal(m1.baseColor.image.uri, m3.baseColor.image.uri)
    assert.equal(m1.scene, a.options.scene)
    assert.equal(m3.scene, b.options.scene)
    assert.equal(f.count('image'), 2)
    assert.equal(f.count('rename'), 1)
    const third = await f.create()
    await f.settle(third.texturedMaterial('wood', c1, c2, 123, false, false))
    assert.equal(f.count('pack'), 1, 'later scene reuses disk PNG')
    assert.equal(f.count('image'), 3, 'later scene owns a fresh image')
  })
  await check('disk key includes storage directory; empty filesDir rejects without writing', async f => {
    const a = await f.create(), b = await f.create('/other/files'), empty = await f.create('')
    const args = ['checker', c1, c2, 42, false, false]
    const [m1, m2] = await f.settle(Promise.all([a.texturedMaterial(...args), b.texturedMaterial(...args)]))
    assert.notEqual(m1.baseColor.image.uri, m2.baseColor.image.uri)
    assert.equal(f.count('pack'), 2)
    await assert.rejects(f.settle(empty.texturedMaterial(...args)), /filesDir is empty/)
    assert.equal(empty.images.size, 0)
    assert.equal(empty.materials.size, 0)
    assert.equal(f.count('pack'), 2)
  })
  for (const existing of ['valid', 'empty', 'directory']) {
    await check('disk cache handles ' + existing + ' destination', async f => {
      const box = await f.create(), key = T.textureKey('wood', c1, c2, 7)
      const file = filesDir + '/vera/tex/' + key + '.png'
      if (existing === 'directory') f.dirs.add(file)
      else f.files.set(file, existing === 'valid' ? Buffer.from('existing PNG') : Buffer.alloc(0))
      if (existing === 'directory') {
        await assert.rejects(f.settle(box.texturedMaterial('wood', c1, c2, 7, false, false)), /EISDIR/)
        assert.equal(box.images.size + box.materials.size, 0)
        assert.equal(f.count('image'), 0)
        f.dirs.delete(file)
        await f.settle(box.texturedMaterial('wood', c1, c2, 7, false, false))
        assert.equal(f.count('pack'), 2)
      } else {
        await f.settle(box.texturedMaterial('wood', c1, c2, 7, false, false))
        assert.equal(f.count('pack'), existing === 'valid' ? 0 : 1)
      }
    })
  }
  for (const fault of ['mkdir', 'pixelMap', 'packer', 'open', 'pack', 'rename', 'image', 'sampler', 'material']) {
    await check('failed ' + fault + ' evicts rejected work, cleans up and permits retry', async f => {
      const box = await f.create(), args = ['marble', c1, c2, 54, false, false]
      f.faults.add(fault)
      await assert.rejects(f.settle(box.texturedMaterial(...args)), /injected|ENOENT/)
      assert.equal(box.materials.size, 0)
      assert.equal(box.images.size, ['sampler', 'material'].includes(fault) ? 1 : 0)
      f.clean()
      f.faults.clear()
      const material = await f.settle(box.texturedMaterial(...args))
      assert.ok(material.baseColor.image)
      assert.equal(box.images.size, 1)
      assert.equal(box.materials.size, 1)
      if (['image', 'sampler', 'material'].includes(fault)) assert.equal(f.count('pack'), 1, 'successful disk work survives scene-resource failure')
    })
  }
  for (const fault of ['pixelRelease', 'packerRelease', 'unlink']) {
    await check('cleanup failure at ' + fault + ' still closes files and attempts both releases', async f => {
      const box = await f.create()
      f.faults.add(fault)
      if (fault === 'unlink') f.faults.add('pack')
      await assert.rejects(f.settle(box.texturedMaterial('wood', c1, c2, 55, false, false)), /injected/)
      assert.equal(f.handles.size, 0)
      assert.ok(f.maps.every(m => m.releases === 1))
      assert.ok(f.packers.every(p => p.releases === 1))
      assert.equal(box.materials.size, 0)
      assert.equal(box.images.size, 0)
      if (fault === 'unlink') {
        const temporary = [...f.files.keys()].filter(file => file.endsWith('.tmp'))
        assert.equal(temporary.length, 1, 'injected unlink rejection leaves its file untouched')
        assert.equal(f.count('unlink'), 1)
        f.files.delete(temporary[0])
      }
      f.faults.clear()
      await f.settle(box.texturedMaterial('wood', c1, c2, 55, false, false))
    })
  }
  await check('shared failed disk promise rejects both scenes and concurrent retry writes one PNG', async f => {
    const a = await f.create(), b = await f.create(), args = ['fabric', c1, c2, 99, false, false]
    f.faults.add('pack')
    const results = await f.settle(Promise.allSettled([a.texturedMaterial(...args), b.texturedMaterial(...args)]))
    assert.ok(results.every(r => r.status === 'rejected'))
    assert.equal(f.count('pixelMap'), 1)
    assert.equal(a.images.size + b.images.size + a.materials.size + b.materials.size, 0)
    f.clean()
    f.faults.clear()
    await f.settle(Promise.all([a.texturedMaterial(...args), b.texturedMaterial(...args)]))
    assert.equal(f.count('pixelMap'), 2)
    assert.equal(f.count('rename'), 1)
    assert.equal(f.count('image'), 2)
  })
  for (const mode of ['retire visible', 'retire unmounted', 'destroy']) {
    for (const boundary of ['pack', 'image', 'sampler', 'material']) {
      await check(mode + ' while ' + boundary + ' awaits prevents late publication', async f => {
        const box = await f.create(), held = f.hold(boundary)
        const pending = box.texturedMaterial('wood', c1, c2, 77, false, false)
        const rejected = assert.rejects(f.settle(pending), /retired/)
        await f.settle(held.entered.promise)
        const readyImages = box.images.size > 0 && ['sampler', 'material'].includes(boundary) ? 1 : 0
        if (mode === 'retire visible') box.appeared()
        if (mode === 'destroy') box.destroy()
        else box.retire()
        const before = f.calls.length
        held.release.resolve()
        await rejected
        assert.equal(f.calls.slice(before).filter(c => ['image', 'sampler', 'material', 'mesh', 'geometry'].includes(c.op)).length, 0)
        assert.equal(box.images.size, mode === 'retire visible' ? readyImages : 0, 'no late cached image; already loaded images live until scene destruction')
        assert.equal(box.materials.size, 0, 'no late cached material')
        assert.equal(box.bodyCount(), 0)
        box.disappeared()
        box.destroy()
        assert.equal(f.scenes[0].destroys, 1)
      })
    }
  }
  await check('failed public apply can be retried without poisoned caches or duplicate bodies', async f => {
    const box = await f.create(), spec = world([body()])
    f.faults.add('image')
    box.apply(spec, theme)
    await f.settle((async () => { while (box.running) await Promise.resolve() })())
    assert.match(box.note, /failed/)
    assert.equal(box.appliedSpec(), null)
    assert.equal(box.images.size + box.materials.size, 0)
    f.faults.clear()
    await f.apply(box, spec)
    assert.equal(box.bodyCount(), 1)
    assert.equal(f.count('pack'), 1)
    assertBodyTexture(f, box.bodies.get('sample').node, spec.bodies[0])
  })
  for (const earlier of [0, 20]) {
    await check('failed creation reconciles superseded siblings from ' + (earlier ? 'earlier and current batches' : 'the current batch'), async f => {
      const box = await f.create(), stable = body('stable')
      await f.apply(box, world([stable]))
      const kept = box.bodies.get(stable.id), keptMaterial = materialOf(kept.node)
      const additions = Array.from({length: earlier + 2}, (_, i) => body('addition-' + i))
      const failedName = 'b' + (box.serial + earlier + 1), delayedName = 'b' + (box.serial + earlier + 2)
      const gate = f.hold('geometry', delayedName)
      f.faults.add('mesh:' + failedName + 'm')
      box.apply(world([stable, ...additions]), theme)
      await f.settle(gate.entered.promise)
      for (let i = 0; i < 40; i++) await Promise.resolve()
      assert.equal(box.running, true)
      const retry = world([stable])
      box.apply(retry, theme)
      assert.equal(box.bodies.get(stable.id), kept)
      gate.release.resolve()
      await f.settle((async () => { while (box.running) await Promise.resolve() })())
      assert.match(box.note, /World rendering failed:/)
      assert.equal(box.bodyCount(), earlier + 2)
      const partial = [...box.bodies.values()].filter(entry => entry !== kept).map(entry => entry.node)
      f.faults.clear()
      await f.apply(box, retry)
      assert.equal(box.bodyCount(), 1, 'superseded successful creations must leave the scene')
      assert.equal(box.bodies.get(stable.id), kept)
      assert.equal(materialOf(kept.node), keptMaterial)
      assert.ok(partial.every(node => node.parent === null && node.destroys === 1))
      assert.deepEqual([...box.materialBindings.keys()], [kept.node.name])
      assert.deepEqual([...box.byName.keys()], [kept.node.name])
      await f.apply(box, world([]))
      assert.equal(box.materialBindings.size, 0)
    })
  }
  await check('failed pip creation drains delayed siblings then removes every successful unattached pip before retry', async f => {
    const box = await f.create(), spec = world([body('die', 'box', {isDie: true, pattern: ''})])
    const gate = f.hold('geometry', 'p3')
    f.faults.add('mesh:p2m')
    box.apply(spec, theme)
    await f.settle(gate.entered.promise)
    for (let i = 0; i < 40; i++) await Promise.resolve()
    assert.equal(box.running, true)
    assert.equal(f.calls.filter(c => c.op === 'nodeDestroy').length, 0, 'no cleanup before the last pip settles')
    assert.equal(box.materialBindings.size, 20)
    gate.release.resolve()
    await f.settle((async () => { while (box.running) await Promise.resolve() })())
    assert.match(box.note, /mesh:p2m/)
    const pips = [...new Set(f.resources.filter(r => /^p\d+$/.test(r.name) && r.children))]
    assert.equal(pips.length, 20)
    assert.ok(pips.every(pip => pip.parent === null && pip.destroys === 1), 'all successful pip nodes are removed once')
    assert.deepEqual([...box.materialBindings.keys()], [box.bodies.get('die').node.name])
    f.faults.clear()
    await f.apply(box, spec)
    assert.equal(box.bodies.get('die').pips.length, 21)
    assert.equal(box.materialBindings.size, 22)
    await f.apply(box, world([]))
    assert.equal(box.materialBindings.size, 0)
  })
  const passed = checks.filter(c => c.status === 'PASS').length
  console.log(JSON.stringify({passed, failed: checks.length - passed, typescript: ts.version,
    scope: 'Host product renderer API/control-flow only; PNG bytes are captured RGBA, not encoded PNG. No GPU, visual, ArkTS typecheck or device validation.',
    failures: checks.filter(c => c.status === 'FAIL')}))
  if (passed !== checks.length) process.exitCode = 1
}

main().catch(error => { console.error(error.stack || error); process.exitCode = 1 })
