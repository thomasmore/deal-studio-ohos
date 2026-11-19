'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const ts = process.env.VERA_TYPESCRIPT_PATH ? require(process.env.VERA_TYPESCRIPT_PATH) : require('typescript')
const {loadVera, loadSource, sourceRoot} = require('./source-loader')
const S = loadVera('VeraScene')
const P = loadVera('VeraParticles')
const Physics = loadVera('VeraPhysics')
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
const deferred = () => {
  let resolve
  const promise = new Promise(done => { resolve = done })
  return {promise, resolve}
}
const {particleGlb, output: particleFile} = require('../particle-glb')
const particleBytes = fs.readFileSync(particleFile)
const particleDoc = JSON.parse(particleBytes.subarray(20, 20 + particleBytes.readUInt32LE(12)).toString())
const isParticle = name => /^particle\d+(?:m|:.*)?$/.test(name)

function fixture() {
  const calls = [], writes = [], scenes = [], resources = [], boxes = [], logs = [], loaded = new Set()
  const timers = new Map(), gates = [], faults = new Set()
  const activity = {pending: 0, peak: 0}
  const engine = new Physics.FakePhys()
  let timerId = 0, clock = 10000, contacts = []
  engine.drainContacts = out => {
    assert.ok(contacts.length <= out.length)
    out.set(contacts)
    const n = contacts.length / Physics.CONTACT_RECORD
    contacts = []
    return n
  }
  function record(op, name, scene) {
    const call = {op, name, scene}
    calls.push(call)
    return call
  }
  function tracked(object, property, value, scene) {
    Object.defineProperty(object, property, {enumerable: true,
      get: () => value,
      set(next) {
        assert.equal(scene.destroys, 0, 'no write to a destroyed scene: ' + object.name + '.' + property)
        writes.push({object, property, value: next})
        value = next
      }
    })
  }
  function resource(name, scene, extra = {}) {
    const made = {name, scene, destroys: 0, ...extra,
      destroy() {
        assert.equal(scene.destroys, 0, 'no resource destruction after scene destruction')
        assert.equal(this.destroys++, 0, 'resource destroyed once: ' + name)
        record('resourceDestroy', name, scene)
      }
    }
    resources.push(made)
    return made
  }
  function node(name, scene) {
    const made = resource(name, scene, {parent: null, childrenList: []})
    tracked(made, 'position', {x: 0, y: 0, z: 0}, scene)
    tracked(made, 'rotation', {x: 0, y: 0, z: 0, w: 1}, scene)
    tracked(made, 'scale', {x: 1, y: 1, z: 1}, scene)
    tracked(made, 'visible', true, scene)
    made.children = {
      append(child) {
        assert.equal(scene.destroys, 0)
        assert.equal(child.scene, scene)
        if (child.parent) child.parent.children.remove(child)
        child.parent = made
        made.childrenList.push(child)
        record('append', child.name, scene)
      },
      get: index => made.childrenList[index] || null,
      count: () => made.childrenList.length,
      remove(child) {
        assert.equal(scene.destroys, 0)
        const at = made.childrenList.indexOf(child)
        assert.ok(at >= 0, 'only attached children removed')
        made.childrenList.splice(at, 1)
        child.parent = null
        record('remove', child.name, scene)
      }
    }
    made.nodeType = 'node'
    made.getNodeByPath = path => {
      const parts = path.split('/').filter(Boolean)
      let current = made
      for (const part of parts) current = current && current.childrenList.find(c => c.name === part)
      return current || null
    }
    return made
  }
  async function api(op, name, scene, make) {
    if (scene) assert.equal(scene.destroys, 0, 'no factory call after scene destruction')
    record(op, name, scene)
    const particle = isParticle(name) && op === 'node'
    if (particle) { activity.pending++; activity.peak = Math.max(activity.peak, activity.pending) }
    try {
      if (faults.has(op + ':' + name)) throw new Error('injected ' + op + ':' + name)
      const gate = gates.find(g => !g.used && g.op === op && g.match(name))
      if (gate) {
        gate.used = true
        gate.entered.resolve()
        await gate.release.promise
      }
      return make()
    } finally { if (particle) activity.pending-- }
  }
  function importedParticleMaterial(name, scene, original) {
    const made = resource(name, scene, {materialType: original.materialType,
      shadowCaster: original.shadowCaster, blend: {...original.blend}, baseColor: {name: name + '.baseColor'}})
    tracked(made.baseColor, 'factor', {...original.baseColor.factor}, scene)
    return made
  }
  function makeScene(sourceName = '') {
    const scene = {id: scenes.length, sourceName, destroys: 0, imports: [],
      destroy() { assert.equal(this.destroys++, 0, 'scene destroyed once'); record('sceneDestroy', String(this.id), this) },
      getResourceFactory: () => factory,
      importScene(name, source, parent) {
        assert.equal(this.destroys, 0)
        assert.equal(source.destroys, 0)
        record('importScene', name, this)
        const root = node(name, this)
        parent.children.append(root)
        this.imports.push({root, source, parent})
        if (faults.has('importScene:' + name)) throw new Error('injected importScene:' + name)
        if (source.sourceName === 'vera-particle.glb') {
          assert.equal(parent.visible, false, 'parent hides the import before it exists')
          assert.deepEqual(parent.scale, zero)
          if (faults.has('empty:' + name)) return null
          if (faults.has('missing:' + name)) return root
          const cube = node(faults.has('renamedParticleHierarchy') ? name + ':nativeMesh' : 'particleCube', this)
          cube.nodeType = 'geometry'
          if (faults.has('renamedParticleHierarchy')) {
            const wrapper = node(name + ':nativeWrapper', this)
            root.children.append(wrapper)
            wrapper.children.append(cube)
            root.getNodeByPath = () => null
          } else root.children.append(cube)
          const original = source.particleMaterial
          const material = importedParticleMaterial(name + ':material', this, original)
          const mesh = resource(name + ':mesh', this, {subMeshes: [{material}]})
          cube.mesh = mesh
          Object.defineProperty(mesh.subMeshes[0], 'material', {get: () => material,
            set() { assert.fail('imported particle material must not be replaced') }})
          this.imports.at(-1).leaf = cube
          this.imports.at(-1).copies = [material, mesh, cube, root]
          return root
        }
        let leaf = root
        for (let i = 0; i < 12; i++) {
          const child = node('asset-child-' + i, this)
          leaf.children.append(child)
          leaf = child
        }
        leaf.mesh = {subMeshes: [{material: Object.freeze({asset: source.sourceName})}]}
        this.imports[this.imports.length - 1].leaf = leaf
        return root
      }
    }
    scene.root = node('root', scene)
    if (sourceName === 'vera-particle.glb') {
      if (!faults.has('emptySource')) scene.root.children.append(node('particleCube', scene))
      const m = particleDoc.materials[0], c = m.pbrMetallicRoughness.baseColorFactor
      scene.particleMaterial = importedParticleMaterial('sourceParticleMaterial', scene, {
        materialType: Object.hasOwn(m.extensions, 'KHR_materials_unlit') ? 'unlit' : 'pbr',
        shadowCaster: m.alphaMode !== 'BLEND', blend: {enabled: m.alphaMode === 'BLEND'},
        baseColor: {factor: {x: c[0], y: c[1], z: c[2], w: c[3]}}
      })
    }
    function sceneNode(params) {
      const made = node(params.name, scene)
      if (!scene.destroys) scene.root.children.append(made)
      return made
    }
    const factory = {
      createCamera: params => api('camera', params.name, scene, () => sceneNode(params)),
      createEnvironment: params => api('environment', params.name, scene, () => resource(params.name, scene)),
      createLight: (params, type) => api('light', params.name, scene, () => Object.assign(sceneNode(params), {type})),
      createNode: params => api('node', params.name, scene, () => {
        const made = sceneNode(params)
        if (isParticle(params.name)) {
          const destroy = made.destroy.bind(made)
          made.destroy = () => {
            for (const imported of scene.imports.filter(i => i.parent === made)) {
              for (const copy of imported.copies || [imported.root]) copy.destroy()
            }
            destroy()
          }
        }
        return made
      }),
      createMaterial: (params, type) => api('material', params.name, scene, () => {
        const made = resource(params.name, scene, {type,
          baseColor: {name: params.name + '.baseColor'},
          material: {factor: {x: 0.7, y: 0.5, z: 0.5, w: 0.4}},
          specular: {factor: {x: 1, y: 1, z: 1, w: 0.4}}
        })
        tracked(made.baseColor, 'factor', {x: 1, y: 1, z: 1, w: 1}, scene)
        return made
      }),
      createMesh: (params, geometry) => api('mesh', params.name, scene,
        () => resource(params.name, scene, {geometry, subMeshes: [{material: null}]})),
      createGeometry: (params, mesh) => api('geometry', params.name, scene, () => {
        assert.equal(mesh.scene, scene)
        return Object.assign(sceneNode(params), {meshResource: mesh, mesh})
      })
    }
    scenes.push(scene)
    return scene
  }
  class CustomGeometry {}
  class CubeGeometry {}
  class SphereGeometry {}
  class CylinderGeometry {}
  class PlaneGeometry {}
  const native = {}
  for (const name of ['init', 'reset', 'setGravity', 'setBound', 'addBox', 'addSphere', 'addCylinder', 'addParts',
    'remove', 'setPose', 'setMaterial', 'setVelocity', 'sleep', 'moveKinematic', 'drive', 'step', 'stepBegin',
    'stepEnd', 'readAwake', 'readPose', 'readVelocity', 'drainContacts', 'awakeDynamic', 'watch', 'explode']) {
    native['phys' + name[0].toUpperCase() + name.slice(1)] = (...args) => {
      record('phys:' + name, '')
      return engine[name](...args)
    }
  }
  const stubs = {
    '@kit.ArkGraphics3D': {
      Scene: {load: raw => api('load', raw ? raw.path : 'empty', null, () => makeScene(raw ? raw.path : ''))},
      CustomGeometry, CubeGeometry, SphereGeometry, CylinderGeometry, PlaneGeometry,
      NodeType: {GEOMETRY: 'geometry'}, PrimitiveTopology: {TRIANGLE_LIST: 'triangles'}, LightType: {DIRECTIONAL: 'directional', SPOT: 'spot'},
      EnvironmentBackgroundType: {BACKGROUND_NONE: 'none'}, MaterialType: {METALLIC_ROUGHNESS: 'pbr', UNLIT: 'unlit'}
    },
    '@kit.ImageKit': {}, '@kit.CoreFileKit': {}, '@kit.BasicServicesKit': {},
    '@kit.PerformanceAnalysisKit': {}, 'libphys.so': native
  }
  const globals = {
    ObservedV2: value => value, Trace() {}, ModelType: {SURFACE: 'surface'}, $rawfile: path => ({path}),
    CanvasRenderingContext2D: class {}, RenderingContextSettings: class {},
    Date: class extends Date { static now() { return clock++ } },
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
  async function until(predicate, runFrames = true) {
    for (let i = 0; i < 20000; i++) {
      if (predicate()) return
      await Promise.resolve()
      if (runFrames) {
        for (const [id, timer] of [...timers]) {
          if (timer.ms === 16) { timers.delete(id); timer.fn() }
        }
      }
    }
    assert.fail('mock async work did not settle')
  }
  async function settle(promise, runFrames = true) {
    let done = false, value, error
    Promise.resolve(promise).then(v => { value = v; done = true }, e => { error = e; done = true })
    await until(() => done, runFrames)
    if (error) throw error
    return value
  }
  function newBox() {
    const box = new mod.exports.WorldBox('/mock-app/files')
    boxes.push(box)
    return box
  }
  return {calls, writes, scenes, resources, engine, timers, faults, loaded, logs, activity, until, settle, newBox,
    count: (op, particlesOnly = false) => calls.filter(c => c.op === op && (!particlesOnly || isParticle(c.name))).length,
    jump: ms => { clock += ms },
    contact(records) { contacts = records.flat() },
    hold(op, match = isParticle) {
      const gate = {op, match, used: false, entered: deferred(), release: deferred()}
      gates.push(gate)
      return gate
    },
    async create() {
      const box = newBox()
      assert.equal(await settle(box.create()), true)
      return box
    },
    async apply(box, spec, palette = theme) {
      box.apply(spec, palette)
      await until(() => !box.running)
      assert.equal(box.appliedSpec(), spec, box.note)
      assert.equal(box.note, '')
    },
    async ready(box) {
      await until(() => box.particlePreparing === null)
      assert.equal(box.note, '')
      assert.equal(box.particleReady, true)
    },
    fire(ms) {
      const matching = [...timers].filter(([, timer]) => timer.ms === ms)
      assert.ok(matching.length > 0, 'expected timer ' + ms)
      for (const [id, timer] of matching) { timers.delete(id); timer.fn() }
    },
    async clean() {
      for (const box of boxes) box.destroy()
      for (const gate of gates) gate.release.resolve()
      await until(() => boxes.every(b => !b.running && b.particlePreparing === null))
      assert.equal(timers.size, 0, 'no leaked mock timers')
      assert.ok(scenes.every(s => s.destroys === 1), 'each scene destroyed once')
    }
  }
}

const burst = (trigger = 1, extra = {}) => Object.assign(new S.BurstSpec(), {
  id: 'effect', trigger, x: 2, y: 3, z: -4, kind: 'sparks', color: 'accent'
}, extra)
const blast = (trigger = 1) => Object.assign(new S.BlastSpec(), {
  id: 'blast', trigger, x: 1, y: 2, z: 3, radius: 5, strength: 4
})
const body = (id = 'body', extra = {}) => Object.assign(new S.BodySpec(), {
  id, shape: 'box', dims: [1, 1, 1], color: 'ink', position: [0, 0.5, 0]
}, extra)
const world = (bursts = [], bodies = [], extra = {}) => Object.assign(new S.WorldSpec(), {bursts, bodies}, extra)
const vector = values => ({x: values[0], y: values[1], z: values[2]})
const particleGeometry = node => node.childrenList[0].childrenList[0]
const materialOf = node => (isParticle(node.name) ? particleGeometry(node) : node).mesh.subMeshes[0].material
const zero = {x: 0, y: 0, z: 0}
const particleSnapshot = f => f.writes.filter(w => isParticle(w.object.name.replace(/\.baseColor$/, ''))).length
function assertPoses(box, expected, palette = theme) {
  assert.equal(box.particleCount(), expected.length)
  assert.equal(box.particleVisible, expected.length)
  expected.forEach((pose, i) => {
    const node = box.particleNodes[i], factor = materialOf(node).baseColor.factor
    const color = L.lookLinear(palette, pose.color, 'accent')
    assert.deepEqual(node.position, vector(pose.position))
    const alpha = color[3] * pose.alpha
    const size = box.backdropOn ? pose.sizeM * Math.cbrt(Math.max(0, Math.min(1, alpha))) : pose.sizeM
    assert.deepEqual(node.scale, {x: size, y: size, z: size})
    assert.deepEqual(factor, {x: color[0], y: color[1], z: color[2], w: box.backdropOn ? (alpha > 0 ? 1 : 0) : alpha})
    assert.equal(node.visible, alpha > 0)
  })
  assert.ok(box.particleNodes.slice(expected.length).every(n => n.visible === false && n.scale.x === 0 && n.scale.y === 0 && n.scale.z === 0))
}
function expectedParticles(spec, prev = null) {
  return S.burstsForDiff(S.diffWorld(prev, spec)).flatMap(r => P.burstParticles(r.kind, r.seed, r.origin, r.color))
}
async function expire(f, box) {
  for (let i = 0; i < 40 && box.needsFrames(); i++) {
    box.frame(100)
    box.takeEvents(1000)
  }
  assert.equal(box.particleCount(), 0)
  assert.equal(box.needsFrames(), false, 'expired static world stops requesting frames')
}
async function check(name, run) {
  const f = fixture()
  let error
  try { await run(f) } catch (caught) { error = caught }
  try { await f.clean() } catch (caught) { error = error || caught }
  checks.push({name, status: error ? 'FAIL' : 'PASS', ...(error ? {error: error.stack || error.message} : {})})
  if (error) console.error('FAIL ' + name + '\n' + (error.stack || error.message))
  else console.log('PASS ' + name)
}

async function main() {
  console.log('Current WorldBox with real particle, scene and physics modules; mocked scene resources, native boundary, clock and timers.')
  await check('owned deterministic GLB is a centered single cube with imported BLEND/unlit no-shadow configuration', async f => {
    assert.deepEqual(particleBytes, particleGlb())
    assert.equal(particleBytes.readUInt32LE(0), 0x46546c67)
    assert.equal(particleBytes.readUInt32LE(4), 2)
    assert.equal(particleBytes.readUInt32LE(8), particleBytes.length)
    assert.equal(particleBytes.readUInt32LE(16), 0x4e4f534a)
    const binOffset = 20 + particleBytes.readUInt32LE(12)
    assert.equal(particleBytes.readUInt32LE(binOffset + 4), 0x004e4942)
    const binary = particleBytes.subarray(binOffset + 8)
    assert.equal(binary.length, particleBytes.readUInt32LE(binOffset))
    assert.deepEqual(particleDoc.scenes, [{nodes: [0]}])
    assert.deepEqual(particleDoc.nodes, [{name: 'particleCube', mesh: 0}])
    assert.equal(particleDoc.meshes.length, 1)
    assert.equal(particleDoc.meshes[0].primitives.length, 1)
    assert.equal(particleDoc.materials.length, 1)
    const material = particleDoc.materials[0]
    assert.equal(material.alphaMode, 'BLEND')
    assert.deepEqual(material.extensions, {KHR_materials_unlit: {}})
    assert.deepEqual(material.pbrMetallicRoughness.baseColorFactor, [1, 1, 1, 0])
    assert.deepEqual(particleDoc.extensionsRequired, ['KHR_materials_unlit'])
    assert.deepEqual(particleDoc.buffers, [{byteLength: binary.length}])
    for (const key of ['images', 'textures', 'cameras', 'animations', 'skins']) assert.equal(particleDoc[key], undefined)
    const read = index => {
      const a = particleDoc.accessors[index], view = particleDoc.bufferViews[a.bufferView]
      const size = a.type === 'VEC3' ? 3 : 1, width = a.componentType === 5126 ? 4 : 2
      assert.equal(view.byteOffset % 4, 0)
      assert.ok(view.byteOffset + view.byteLength <= binary.length)
      return Array.from({length: a.count}, (_, i) => Array.from({length: size}, (_, j) =>
        binary[a.componentType === 5126 ? 'readFloatLE' : 'readUInt16LE'](view.byteOffset + (i * size + j) * width)))
    }
    const positions = read(0), normals = read(1), indices = read(2).flat()
    assert.equal(indices.length, 36)
    for (let axis = 0; axis < 3; axis++) {
      assert.equal(Math.min(...positions.map(p => p[axis])), -.5)
      assert.equal(Math.max(...positions.map(p => p[axis])), .5)
    }
    for (let i = 0; i < indices.length; i += 3) {
      const [a, b, c] = indices.slice(i, i + 3).map(j => positions[j])
      const u = b.map((v, k) => v - a[k]), v = c.map((x, k) => x - a[k])
      const cross = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]]
      assert.ok(cross.reduce((sum, x, k) => sum + x * normals[indices[i]][k], 0) > 0)
    }
    const source = fs.readFileSync(controllerFile, 'utf8')
    assert.match(source, /Scene\.load\(\$rawfile\('vera-particle\.glb'\)\)/)
    assert.ok(!loadVera('VeraModels').MODEL_CATALOG.some(m => m.file.includes('vera-particle')))
  })
  await check('particle import finds its unique geometry through renamed native wrappers without path lookup', async f => {
    f.faults.add('renamedParticleHierarchy')
    const box = await f.create()
    await f.apply(box, world([burst(0)])); await f.ready(box)
    assert.equal(box.particleNodes.length, 256)
    assert.equal(box.particleMaterials.length, 256)
    assert.equal(box.note, '')
    const root = f.scenes.find(s => s.sourceName === '').imports[0].root
    assert.equal(root.getNodeByPath('particleCube'), null)
    assert.equal(box.particleGeometry(root).nodeType, 'geometry')
    const extra = node => { node.nodeType = 'geometry'; return node }
    const duplicate = {nodeType: 'node', children: {count: () => 2, get: i => extra({children: {count: () => 0}})}}
    assert.throws(() => box.particleGeometry(duplicate), /Multiple particle geometries/)
  })
  await check('particle source loads once per world and every import copies its material without cross-slot writes', async f => {
    const a = await f.create(), b = await f.create()
    await f.apply(a, world([burst(0)])); await f.ready(a)
    await f.apply(b, world([burst(0)])); await f.ready(b)
    const sources = f.scenes.filter(s => s.sourceName === 'vera-particle.glb')
    assert.equal(sources.length, 2)
    const copies = [...a.particleMaterials, ...b.particleMaterials]
    assert.equal(new Set(copies).size, 512)
    assert.ok(copies.every(m => !sources.some(s => s.particleMaterial === m)))
    a.particleMaterials[0].baseColor.factor = {x: .2, y: .3, z: .4, w: .5}
    assert.ok(copies.slice(1).every(m => m.baseColor.factor.w === 0))
    assert.ok(sources.every(s => s.particleMaterial.baseColor.factor.w === 0))
    const imports = f.count('importScene', true), loads = f.count('load')
    await f.apply(a, world([burst(1)])); a.frame(0)
    await expire(f, a)
    await f.apply(a, world([burst(2)])); a.frame(0)
    assert.equal(f.count('importScene', true), imports)
    assert.equal(f.count('load'), loads)
    a.destroy()
    assert.equal(sources[0].destroys, 1)
    assert.equal(sources[1].destroys, 0)
    const order = f.calls.filter(c => c.op === 'sceneDestroy').map(c => c.scene)
    assert.ok(order.indexOf(f.scenes[0]) < order.indexOf(sources[0]))
    assert.equal(b.particleNodes.length, 256)
  })
  await check('rejected particle source load is shared, evicted, idle after failure and retryable from an empty pool', async f => {
    const box = await f.create()
    f.faults.add('load:vera-particle.glb')
    await f.apply(box, world([burst()]))
    await f.until(() => box.particlePreparing === null)
    assert.match(box.note, /Particle rendering failed:/)
    assert.equal(box.particleNodes.length, 0)
    assert.equal(box.particleSource, null)
    assert.equal(box.needsFrames(), false)
    assert.equal(f.calls.filter(c => c.op === 'load' && c.name === 'vera-particle.glb').length, 1)
    f.faults.clear()
    await f.apply(box, world([burst(2)])); await f.ready(box)
    assert.equal(f.calls.filter(c => c.op === 'load' && c.name === 'vera-particle.glb').length, 2)
    assert.equal(box.particleNodes.length, 256)
  })
  await check('empty loaded particle source is disposed and evicted before retry', async f => {
    const box = await f.create()
    f.faults.add('emptySource')
    await f.apply(box, world([burst()]))
    await f.until(() => box.particlePreparing === null)
    assert.match(box.note, /Empty particle source/)
    assert.equal(box.particleSource, null)
    assert.equal(box.particleNodes.length, 0)
    assert.equal(f.scenes.find(s => s.sourceName === 'vera-particle.glb').destroys, 1)
    f.faults.clear()
    await f.apply(box, world([burst(2)])); await f.ready(box)
    assert.equal(f.scenes.filter(s => s.sourceName === 'vera-particle.glb').length, 2)
  })
  for (const mode of ['retire visible', 'retire unmounted', 'destroy']) {
    await check(mode + ' during particle source load disposes the late source once without importing', async f => {
      const box = await f.create(), held = f.hold('load', n => n === 'vera-particle.glb')
      await f.apply(box, world([burst()]))
      await f.settle(held.entered.promise)
      if (mode === 'retire visible') box.appeared()
      if (mode === 'destroy') box.destroy()
      else box.retire()
      held.release.resolve()
      await f.until(() => box.particlePreparing === null)
      const source = f.scenes.find(s => s.sourceName === 'vera-particle.glb')
      assert.equal(source.destroys, 1)
      assert.equal(box.particleSourceScene, null)
      assert.equal(box.particleSource, null)
      assert.equal(f.count('importScene', true), 0)
      assert.equal(f.count('node', true), 0)
      assert.equal(box.particleNodes.length, 0)
      box.disappeared(); box.destroy()
    })
  }
  await check('particle descendants never enter body picking or alter camera framing or body counts', async f => {
    const box = await f.create(), solid = body()
    await f.apply(box, world([], [solid]))
    const pose = box.pose, entry = box.bodies.get(solid.id)
    await f.apply(box, world([burst(0)], [solid])); await f.ready(box)
    assert.equal(box.pose, pose)
    assert.equal(box.bodyCount(), 1)
    assert.equal(box.byName.size, 1)
    assert.equal(box.bodies.get(solid.id), entry)
    const cube = particleGeometry(box.particleNodes[0])
    assert.ok(isParticle(cube.name))
    assert.equal(box.bodyOf(cube), '')
    box.width = 300; box.height = 200
    box.cam.raycast = async () => [{node: cube, hitPosition: {x: 0, y: 0, z: 0}},
      {node: entry.node, hitPosition: {x: 1, y: 2, z: 3}}]
    assert.equal((await f.settle(box.raycast(0, 0))).body, solid.id)
  })
  await check('lazy allocation and public metrics stay idle for empty and static scenes', async f => {
    const box = await f.create()
    for (const spec of [world(), world([], [body()])]) {
      await f.apply(box, spec)
      assert.equal(box.needsFrames(), false)
      for (let i = 0; i < 4; i++) { box.frame(100); box.advance() }
      assert.equal(box.particleCount(), 0)
      assert.equal(box.particlesEmitted, 0)
      assert.equal(box.particleMs, 0)
      assert.equal(box.particleNodes.length, 0)
    }
    for (const op of ['material', 'mesh', 'geometry']) assert.equal(f.count(op, true), 0)
    assert.equal(f.count('phys:init'), 0, 'static scenes never initialize native physics')
    for (const name of ['VeraScene', 'VeraParticles', 'VeraPhysics']) {
      assert.ok(f.loaded.has(path.join(sourceRoot, 'vera', name + '.ets')))
    }
  })
  for (const feature of ['dormant burst', 'dormant blast', 'target', 'shot']) {
    await check(feature + ': targeted prewarm waits for the scene, requests temporary frames and emits nothing', async f => {
      const box = f.newBox(), load = f.hold('load', () => true), held = f.hold('node')
      const spec = feature === 'dormant burst' ? world([burst(0)]) : feature === 'dormant blast' ?
        world([], [], {blasts: [blast(0)]}) : feature === 'target' ? world([], [body('target', {target: true})]) :
          world([], [body('shot', {motion: 'loose', mass: 1, shot: Object.assign(new S.SceneShot(), {speed: 0})})],
            {floor: Object.assign(new S.FloorSpec(), {color: 'surface'})})
      box.apply(spec, theme)
      assert.equal(box.needsFrames(), true)
      await f.settle(load.entered.promise)
      assert.equal(f.count('material', true), 0, 'no prewarm resources before scene creation')
      assert.equal(box.particlePending.length, 0)
      load.release.resolve()
      await f.settle(held.entered.promise)
      await f.until(() => !box.running)
      assert.ok(box.options.scene)
      assert.equal(box.needsFrames(), true)
      for (let i = 0; i < 10; i++) box.frame(100)
      assert.equal(box.particlesEmitted, 0)
      assert.equal(box.particleMs, 0)
      held.release.resolve()
      await f.ready(box)
      assert.equal(box.needsFrames(), false, 'ready dormant pool never requests frames, including a resting zero-speed shot')
      const writes = particleSnapshot(f), resources = f.resources.length
      for (let i = 0; i < 10; i++) { box.frame(100); assert.equal(box.needsFrames(), false) }
      assert.equal(box.particleCount(), 0)
      assert.equal(box.particlesEmitted, 0)
      assert.equal(box.particleMs, 0)
      assert.equal(particleSnapshot(f), writes)
      assert.equal(f.resources.length, resources)
      assert.equal(f.count('node', true), 256)
      assert.equal(f.count('importScene', true), 256)
      for (const op of ['material', 'mesh', 'geometry']) assert.equal(f.count(op, true), 0)
      assert.ok(box.particleNodes.every(n => n.visible === false && n.scale.x === 0 && materialOf(n).baseColor.factor.w === 0))
    })
  }
  for (const boundary of ['scene load', 'static apply']) {
    await check('coalesced accepted edges preserve payloads during ' + boundary + ' without commit replay', async f => {
      const box = boundary === 'scene load' ? f.newBox() : await f.create()
      const held = boundary === 'scene load' ? f.hold('load', () => true) : f.hold('geometry', name => !isParticle(name))
      const prepare = f.hold('node')
      const bodies = boundary === 'static apply' ? [body()] : []
      const initial = world([burst(0)], bodies, {blasts: [blast(0)]})
      box.apply(initial, theme)
      await f.settle(held.entered.promise)
      const one = world([burst(1, {kind: 'smoke', color: '#ee220080', x: 1, y: 2, z: 3})], bodies,
        {blasts: [Object.assign(blast(1), {x: -1, y: -2, z: -3})]})
      const same = world([burst(1, {kind: 'dust', color: '#0088ff00', x: 90, y: 80, z: 70})], bodies,
        {blasts: [Object.assign(blast(1), {x: 99})]})
      const two = world([burst(2, {kind: 'confetti', color: '#22cc55', x: 4, y: 5, z: 6})], bodies,
        {blasts: [Object.assign(blast(2), {x: -4, y: -5, z: -6})]})
      const back = world([burst(0, {kind: 'sparks', color: '#cc22aa', x: 7, y: 8, z: 9})], bodies,
        {blasts: [Object.assign(blast(0), {x: -7, y: -8, z: -9})]})
      const accepted = [initial, one, same, two, back, world([], bodies)]
      for (const spec of accepted.slice(1)) box.apply(spec, theme)
      const expected = accepted.slice(1).flatMap((spec, i) => S.burstsForDiff(S.diffWorld(accepted[i], spec)))
      assert.equal(expected.length, 9)
      assert.deepEqual(box.particlePending, expected, 'every accepted trigger edge owns its original origin, kind, colour and seed')
      assert.deepEqual(box.particlePending.filter(r => r.kind !== 'debris' && r.color !== '#7f8895').map(r => [r.kind, r.origin, r.color]),
        [['smoke', [1, 2, 3], '#ee220080'], ['confetti', [4, 5, 6], '#22cc55'], ['sparks', [7, 8, 9], '#cc22aa']])
      assert.equal(box.particlesEmitted, 0)
      assert.equal(box.needsFrames(), true)
      held.release.resolve()
      await f.settle(prepare.entered.promise)
      await f.until(() => !box.running)
      assert.equal(box.appliedSpec(), accepted[accepted.length - 1])
      assert.deepEqual(box.particlePending, expected, 'coalesced final commit neither loses nor re-emits accepted edges')
      prepare.release.resolve()
      await f.ready(box)
      box.frame(1000)
      const particles = expected.flatMap(r => P.burstParticles(r.kind, r.seed, r.origin, r.color))
      assert.equal(particles.length, 212)
      assertPoses(box, particles.map(p => P.particlePose(p, 0)))
      assert.equal(box.particlesEmitted, 9)
      box.apply(accepted[accepted.length - 1], theme)
      await f.until(() => !box.running)
      box.frame(0)
      assert.equal(box.particlesEmitted, 9)
      await expire(f, box)
    })
  }
  await check('accepted edges are bounded to the newest 16 even before the scene exists', async f => {
    const box = f.newBox(), held = f.hold('load', () => true)
    const accepted = Array.from({length: 40}, (_, i) => world([burst(i + 1, {kind: 'confetti', x: i})]))
    for (const spec of accepted) {
      box.apply(spec, theme)
      assert.ok(box.particlePending.length <= 16)
    }
    await f.settle(held.entered.promise)
    assert.equal(box.particlePending.length, 16)
    assert.deepEqual(box.particlePending.map(r => r.origin[0]), Array.from({length: 16}, (_, i) => 24 + i))
    for (const op of ['material', 'mesh', 'geometry']) assert.equal(f.count(op, true), 0)
    assert.equal(box.particlesEmitted, 0)
    held.release.resolve()
    await f.until(() => !box.running)
    await f.ready(box)
    box.frame(1000)
    assert.equal(box.appliedSpec(), accepted[39])
    assert.equal(box.particlesEmitted, 16)
    assert.equal(box.particleCount(), 256)
    assert.deepEqual(box.particleNodes.map(n => n.position.x), Array.from({length: 256}, (_, i) => 32 + Math.floor(i / 32)))
    await expire(f, box)
  })
  for (const staticBody of [false, true]) {
    await check((staticBody ? 'static body' : 'no body') + ': burst wakes before scene load and throughout preparation', async f => {
      const box = f.newBox(), load = f.hold('load', () => true), prepare = f.hold('node')
      const spec = world([burst()], staticBody ? [body()] : [])
      box.apply(spec, theme)
      assert.equal(box.needsFrames(), true, 'public apply wakes the display loop immediately')
      await f.settle(load.entered.promise)
      box.frame(100)
      assert.equal(box.particlesEmitted, 0)
      load.release.resolve()
      await f.settle(prepare.entered.promise)
      await f.until(() => !box.running)
      assert.equal(box.appliedSpec(), spec)
      assert.equal(box.needsFrames(), true)
      assert.equal(box.particleCount(), 0)
      for (let i = 0; i < 50; i++) box.frame(1000)
      f.jump(60000)
      assert.equal(box.particlesEmitted, 0)
      prepare.release.resolve()
      await f.ready(box)
      box.frame(10000)
      assertPoses(box, expectedParticles(spec).map(p => P.particlePose(p, 0)))
      assert.equal(box.particlesEmitted, 1, 'counter counts admitted bursts, not individual particles')
      assert.ok(box.particleMs > 0, 'injected clock measures particle work without host timing flakiness')
      assert.ok(box.writeMs >= box.particleMs)
      assert.equal(f.count('phys:init'), 0)
      await expire(f, box)
    })
  }
  for (const [kind] of P.PARTICLE_KINDS) {
    await check(kind + ': initial zero is dormant, unchanged trigger is silent, changed zero emits once', async f => {
      const box = await f.create()
      const initial = world([burst(0, {kind})])
      const held = f.hold('node')
      await f.apply(box, initial)
      await f.settle(held.entered.promise)
      assert.equal(box.needsFrames(), true, 'zero trigger prewarms resources without emitting')
      assert.equal(box.particleCount(), 0)
      assert.equal(box.particlesEmitted, 0)
      held.release.resolve()
      await f.ready(box)
      assert.equal(box.needsFrames(), false)
      const first = world([burst(7, {kind})])
      await f.apply(box, first)
      await f.ready(box)
      box.frame(100)
      assertPoses(box, expectedParticles(first, initial).map(p => P.particlePose(p, 0)))
      assert.equal(box.particlesEmitted, 1)
      await expire(f, box)
      const unchanged = world([burst(7, {kind: kind === 'smoke' ? 'dust' : 'smoke', x: 9, y: -2, color: '#127fca'})])
      await f.apply(box, unchanged)
      box.frame(100)
      assert.equal(box.needsFrames(), false)
      assert.equal(box.particlesEmitted, 1)
      const changedZero = world([burst(0, {kind, x: -3, color: '#d85825'})])
      await f.apply(box, changedZero)
      assert.equal(box.needsFrames(), true)
      box.frame(100)
      assertPoses(box, expectedParticles(changedZero, unchanged).map(p => P.particlePose(p, 0)))
      assert.equal(box.particlesEmitted, 2)
      await f.apply(box, world([burst(0, {kind})]))
      box.frame(0)
      assert.equal(box.particlesEmitted, 2)
      await expire(f, box)
    })
  }
  await check('in-flight static apply keeps its burst wake when the latest wanted trigger is zero', async f => {
    const box = await f.create(), held = f.hold('geometry', name => !isParticle(name))
    const first = world([burst(1)], [body()]), latest = world([burst(0)], [body()])
    box.apply(first, theme)
    await f.settle(held.entered.promise)
    box.apply(latest, theme)
    assert.equal(box.needsFrames(), true, 'in-progress effect survives replacement of the pending wake flag')
    held.release.resolve()
    await f.until(() => !box.running)
    await f.ready(box)
    assert.equal(box.appliedSpec(), latest)
    box.frame(16)
    assert.equal(box.particlesEmitted, 2)
    assert.equal(box.particleCount(), 48)
    assert.equal(box.bodyCount(), 1)
  })
  await check('256 independent alpha-enabled unlit materials, meshes and hidden nodes are reused per frame', async f => {
    const box = await f.create(), spec = world([burst(1, {kind: 'smoke', color: '#3685ca'})])
    await f.apply(box, spec)
    await f.ready(box)
    assert.equal(P.MAX_PARTICLES, 256)
    assert.equal(f.count('node', true), 256)
    assert.equal(f.count('importScene', true), 256)
    for (const op of ['material', 'mesh', 'geometry']) assert.equal(f.count(op, true), 0)
    assert.equal(new Set(box.particleNodes).size, 256)
    assert.equal(new Set(box.particleNodes.map(n => particleGeometry(n).mesh)).size, 256)
    assert.equal(new Set(box.particleMaterials).size, 256)
    assert.equal(box.materials.size, 0, 'particles do not use shared body-material cache')
    for (const [i, node] of box.particleNodes.entries()) {
      const material = box.particleMaterials[i]
      assert.equal(materialOf(node), material)
      assert.equal(node.parent, f.scenes[0].root)
      assert.equal(particleGeometry(node).nodeType, 'geometry')
      assert.equal(material.materialType, 'unlit')
      assert.equal(material.shadowCaster, false)
      assert.deepEqual(material.blend, {enabled: true})
      assert.equal(material.baseColor.factor.w, 0)
      assert.deepEqual(node.scale, zero)
    }
    const made = f.resources.length, specs = expectedParticles(spec)
    box.frame(16)
    assertPoses(box, specs.map(p => P.particlePose(p, 0)))
    const firstAlpha = materialOf(box.particleNodes[0]).baseColor.factor.w
    box.frame(100)
    assertPoses(box, specs.map(p => P.particlePose(p, 0.1)))
    assert.ok(materialOf(box.particleNodes[0]).baseColor.factor.w < firstAlpha)
    assert.notEqual(materialOf(box.particleNodes[0]).baseColor.factor.w, materialOf(box.particleNodes[1]).baseColor.factor.w)
    const before = box.particleMs
    await expire(f, box)
    assert.ok(box.particleMs > before)
    const next = world([burst(2, {kind: 'confetti'})])
    await f.apply(box, next)
    box.frame(0)
    assert.equal(box.particlesEmitted, 2)
    assert.equal(f.resources.length, made, 'no frame or subsequent burst creates scene resources')
    assert.equal(f.count('node', true), 256)
    assert.equal(f.count('importScene', true), 256)
    for (const op of ['material', 'mesh', 'geometry']) assert.equal(f.count(op, true), 0)
  })
  for (const [kind] of P.PARTICLE_KINDS) {
    await check(kind + ': transparent and half-alpha colours multiply lifetime fade without changing RGB or lifetime', async f => {
      const box = await f.create()
      const spec = world([burst(1, {id: 'clear', kind, color: '#3685ca00'}),
        burst(1, {id: 'half', kind, color: '#3685ca80'}), burst(1, {id: 'opaque', kind, color: '#3685ca'})])
      await f.apply(box, spec)
      await f.ready(box)
      const particles = expectedParticles(spec), count = P.burstParticles(kind, 0, [0, 0, 0], 'accent').length
      assert.equal(L.lookLinear(theme, '#3685ca00')[3], 0)
      const half = L.lookLinear(theme, '#3685ca80')[3]
      assert.ok(Math.abs(half - 0.5) < 0.01)
      box.frame(16)
      assertPoses(box, particles.map(p => P.particlePose(p, 0)))
      const factors = box.particleMaterials.slice(0, particles.length).map(m => m.baseColor.factor)
      assert.equal(factors[0].w, 0)
      assert.equal(factors[count].w, half * particles[count].alpha)
      assert.equal(factors[count * 2].w, particles[count * 2].alpha)
      for (const factor of factors) assert.deepEqual([factor.x, factor.y, factor.z], [factors[0].x, factors[0].y, factors[0].z])
      box.frame(100)
      assertPoses(box, particles.map(p => P.particlePose(p, 0.1)))
      assert.ok(box.particleMaterials.slice(0, count).every(m => m.baseColor.factor.w === 0))
      assert.ok(box.particleMaterials[count].baseColor.factor.w > 0 && box.particleMaterials[count].baseColor.factor.w < factors[count].w)
      assert.equal(box.particlesEmitted, 3)
      await expire(f, box)
    })
  }
  for (const backdrop of [false, true]) {
    await check((backdrop ? 'Canvas spatial fade' : 'native alpha') + ': zero, full, partial and bounded particle sizes keep RGB', async f => {
      const box = await f.create()
      await f.apply(box, world([burst()], [], backdrop ? {sky: new S.SkySpec()} : {}))
      await f.ready(box)
      box.frame(0)
      const alphas = [0, 1, .125, .5, 2, -1]
      const poses = alphas.map((alpha, i) => ({position: [i, 2, 3], sizeM: 2, alpha, color: '#3685ca'}))
      box.particlePool.poses = () => poses
      box.frame(0)
      const expectedSizes = backdrop ? [0, 2, 1, 2 * Math.cbrt(.5), 2, 0] : alphas.map(() => 2)
      const rgb = L.lookLinear(theme, '#3685ca').slice(0, 3)
      for (let i = 0; i < poses.length; i++) {
        assert.deepEqual(box.particleNodes[i].scale, {x: expectedSizes[i], y: expectedSizes[i], z: expectedSizes[i]})
        const factor = box.particleMaterials[i].baseColor.factor
        assert.deepEqual([factor.x, factor.y, factor.z], rgb)
        assert.equal(factor.w, backdrop ? (alphas[i] > 0 ? 1 : 0) : alphas[i])
        assert.equal(box.particleNodes[i].visible, alphas[i] > 0)
      }
    })
  }
  for (const [kind] of P.PARTICLE_KINDS) {
    await check(kind + ': Canvas fallback shrinks all fades and source alpha, hides zero, and expires without allocations', async f => {
      const box = await f.create(), sky = Object.assign(new S.SkySpec(), {color: '#234567', stars: 12})
      const spec = world([burst(1, {id: 'clear', kind, color: '#3685ca00'}),
        burst(1, {id: 'low', kind, color: '#3685ca20'}), burst(1, {id: 'opaque', kind, color: '#3685ca'})], [], {sky})
      await f.apply(box, spec); await f.ready(box)
      assert.equal(box.backdropOn, true)
      const nodes = box.particleNodes.slice(), materials = box.particleMaterials.slice(), resources = f.resources.length
      box.frame(0)
      assertPoses(box, box.particlePool.poses())
      const count = P.burstParticles(kind, 0, [0, 0, 0], 'accent').length
      assert.ok(nodes.slice(0, count).every(n => !n.visible && n.scale.x === 0))
      const poses = box.particlePool.poses(), low = L.lookLinear(theme, '#3685ca20')[3] * poses[count].alpha
      assert.equal(nodes[count].scale.x, poses[count].sizeM * Math.cbrt(low))
      assert.equal(materials[count].baseColor.factor.w, 1)
      box.frame(100)
      assertPoses(box, box.particlePool.poses())
      assert.ok(materials.every(m => m.baseColor.factor.w === 0 || m.baseColor.factor.w === 1))
      assert.ok(materials.every(m => m.shadowCaster === false && m.blend.enabled))
      await expire(f, box)
      assert.ok(nodes.every(n => !n.visible && n.scale.x === 0))
      const writes = particleSnapshot(f)
      box.frame(100)
      assert.equal(particleSnapshot(f), writes)
      assert.equal(f.resources.length, resources)
      assert.deepEqual(box.particleMaterials, materials)
    })
  }
  for (const decoration of ['explicit sky', 'stars', 'trail', 'halo']) {
    await check(decoration + ': live particles switch native to Canvas and back on the next frame with independent materials', async f => {
      const box = await f.create()
      const bursts = [burst(1, {id: 'half', color: '#3685ca80', kind: 'smoke'}),
        burst(1, {id: 'clear', color: '#cc552200', kind: 'dust'})]
      const native = world(bursts)
      const decorated = decoration === 'trail' ? world(bursts, [body('trail', {trail: true})]) :
        decoration === 'halo' ? world(bursts, [body('sun', {glow: true})]) :
          world(bursts, [], {sky: Object.assign(new S.SkySpec(), {color: '#234567', stars: decoration === 'stars' ? 12 : 0})})
      await f.apply(box, native); await f.ready(box)
      box.frame(0); box.frame(100)
      assert.equal(box.backdropOn, false)
      const poses = box.particlePool.poses(), materials = box.particleMaterials.slice(), nodes = box.particleNodes.slice()
      const alpha = L.lookLinear(theme, poses[0].color)[3] * poses[0].alpha
      assert.ok(alpha > 0 && alpha < 1)
      assert.equal(materials[0].baseColor.factor.w, alpha)
      await f.apply(box, decorated)
      assert.equal(box.backdropOn, true)
      const start = f.writes.length
      box.frame(0)
      assertPoses(box, poses)
      const writes = f.writes.slice(start)
      assert.ok(writes.filter(w => w.property === 'factor').every(w => w.value.w === 0 || w.value.w === 1))
      for (let i = 0; i < poses.length; i++) {
        const own = writes.filter(w => w.object === nodes[i] || w.object === materials[i].baseColor)
        assert.equal(own[0].property, 'visible')
        assert.equal(own[0].value, false)
        const show = own.findIndex(w => w.property === 'visible' && w.value === true)
        if (show >= 0) {
          assert.equal(own[show - 1].property, 'factor')
          assert.equal(own[show - 1].value.w, 1)
        }
      }
      await f.apply(box, native)
      assert.equal(box.backdropOn, false)
      box.frame(0)
      assertPoses(box, poses)
      assert.equal(materials[0].baseColor.factor.w, alpha)
      assert.equal(nodes[0].scale.x, poses[0].sizeM)
      assert.equal(new Set(materials).size, 256)
      assert.deepEqual(box.particleMaterials, materials)
      assert.deepEqual(box.particleNodes, nodes)
      assert.ok(materials.every(m => !m.shadowCaster))
      await expire(f, box)
    })
  }
  await check('pending queue drops oldest beyond 16 and the dense pool retains only the newest 256 particles', async f => {
    const box = await f.create(), held = f.hold('node')
    let last
    for (let i = 0; i < 40; i++) {
      last = world([burst(i + 1, {kind: 'confetti', x: i})])
      await f.apply(box, last)
      assert.ok(box.particlePending.length <= P.MAX_BURSTS)
      assert.equal(box.particleQueuedAt.length, box.particlePending.length)
      box.frame(100)
    }
    assert.equal(P.MAX_BURSTS, 16)
    assert.deepEqual(box.particlePending.map(r => r.origin[0]), Array.from({length: 16}, (_, i) => i + 24))
    assert.equal(box.particleCount(), 0)
    assert.equal(box.particlesEmitted, 0)
    held.release.resolve()
    await f.ready(box)
    box.frame(1000)
    assert.equal(box.particlesEmitted, 16)
    assert.equal(box.particlePending.length, 0)
    assert.equal(box.particleCount(), 256)
    assert.deepEqual(box.particleNodes.map(n => n.position.x), Array.from({length: 256}, (_, i) => 32 + Math.floor(i / 32)))
    assert.ok(box.particleNodes.every(n => n.position.y === 3 && n.position.z === -4))
    const count = box.particlesEmitted
    for (let i = 0; i < 10; i++) {
      await f.apply(box, world([burst(50 + i, {kind: 'confetti', x: 100 + i})]))
      box.frame(0)
      assert.equal(box.particleCount(), 256)
      assert.ok(box.particlePool.burstCount() <= 16)
      assertPoses(box, box.particlePool.poses())
    }
    assert.equal(box.particlesEmitted, count + 10)
    assert.ok(box.particleNodes.every(n => n.position.x >= 102), 'whole oldest bursts evicted, not partial bursts')
  })
  await check('lifetime expiry hides each live slot once and idle frames do no particle loops or writes', async f => {
    const box = await f.create()
    await f.apply(box, world([burst(1, {kind: 'sparks'})]))
    await f.ready(box)
    box.frame(16)
    const nodes = box.particleNodes.slice(0, box.particleCount())
    const start = f.writes.length
    await expire(f, box)
    for (const node of nodes) {
      assert.equal(f.writes.slice(start).filter(w => w.object === node && w.property === 'scale' && w.value.x === 0).length, 1)
      assert.equal(f.writes.slice(start).filter(w => w.object === node && w.property === 'visible' && w.value === false).length, 1)
    }
    const counts = {advance: 0, poses: 0}
    for (const method of Object.keys(counts)) {
      const original = box.particlePool[method].bind(box.particlePool)
      box.particlePool[method] = (...args) => { counts[method]++; return original(...args) }
    }
    const writes = particleSnapshot(f), ms = box.particleMs, emitted = box.particlesEmitted, resources = f.resources.length
    for (let i = 0; i < 100; i++) { box.frame(100); box.advance(); assert.equal(box.needsFrames(), false) }
    assert.deepEqual(counts, {advance: 0, poses: 0})
    assert.equal(particleSnapshot(f), writes)
    assert.equal(box.particleMs, ms)
    assert.equal(box.particlesEmitted, emitted)
    assert.equal(f.resources.length, resources)
  })
  for (const ground of ['none', 'floor', 'table', 'both']) {
    await check('particle floor is ' + (ground === 'none' ? 'null without ground' : 'zero with ' + ground), async f => {
      const box = await f.create(), extra = {}
      if (ground === 'floor' || ground === 'both') extra.floor = Object.assign(new S.FloorSpec(), {color: 'surface'})
      if (ground === 'table' || ground === 'both') extra.table = Object.assign(new S.TableSpec(), {width: 4, depth: 3, color: 'surface'})
      const spec = world([burst(1, {kind: 'debris', y: -10})], [], extra)
      await f.apply(box, spec)
      await f.ready(box)
      const particles = expectedParticles(spec), floor = ground === 'none' ? null : 0
      box.frame(16)
      assertPoses(box, particles.map(p => P.particlePose(p, 0, floor)))
      box.frame(100)
      assertPoses(box, particles.map(p => P.particlePose(p, 0.1, floor)))
      if (floor === null) assert.ok(box.particleNodes.slice(0, 28).every(n => n.position.y < -9))
      else assert.ok(box.particleNodes.slice(0, 28).every(n => n.position.y === n.scale.y / 2))
    })
  }
  await check('blast debris and smoke emit once per diff, not on native physics acquisition or reacquisition', async f => {
    const box = await f.create(), first = world([], [], {blasts: [blast()]})
    await f.apply(box, first)
    await f.ready(box)
    box.frame(16)
    assert.equal(box.particlesEmitted, 2)
    assertPoses(box, expectedParticles(first).map(p => P.particlePose(p, 0)))
    const loose = body('loose', {motion: 'loose', mass: 1, position: [0, 3, 0]})
    const acquired = world([], [loose], {blasts: [blast()]})
    const beforeAcquisition = f.count('phys:explode')
    await f.apply(box, acquired)
    assert.equal(f.count('phys:explode'), beforeAcquisition, 'physics acquisition does not replay an unchanged blast impulse')
    assert.ok(box.sim instanceof Physics.WorldSim)
    assert.equal(f.count('phys:init'), 1)
    box.frame(0)
    assert.equal(box.particlesEmitted, 2)
    box.releasePhysics()
    const reacquired = world([], [loose], {blasts: [blast()]})
    const beforeReacquisition = f.count('phys:explode')
    await f.apply(box, reacquired)
    assert.equal(f.count('phys:explode'), beforeReacquisition, 'physics reacquisition does not replay an unchanged blast impulse')
    assert.ok(box.sim instanceof Physics.WorldSim)
    box.frame(0)
    assert.equal(box.particlesEmitted, 2, 'full physics rebuild must not replay visual blasts')
    const changed = world([], [loose], {blasts: [blast(0)]})
    await f.apply(box, changed)
    assert.equal(f.count('phys:explode'), beforeReacquisition + 1, 'changed zero blast applies exactly one native impulse')
    box.frame(0)
    assert.equal(box.particlesEmitted, 4, 'changed zero blast emits debris plus smoke once')
    box.frame(0)
    assert.equal(box.particlesEmitted, 4)
    await f.apply(box, world([], [loose], {blasts: [blast(0)]}))
    assert.equal(f.count('phys:explode'), beforeReacquisition + 1, 'unchanged zero does not replay a native impulse')
    box.releasePhysics()
    await f.apply(box, world([], [loose], {blasts: [blast(3)]}))
    assert.equal(f.count('phys:explode'), beforeReacquisition + 2, 'changed trigger on reacquisition is not suppressed')
    box.frame(0)
    assert.equal(box.particlesEmitted, 6)
  })
  for (const kind of ['sparks', 'dust']) {
    await check('real sim ' + kind + ' are drained before events and survive a handler removing their source', async f => {
      const box = await f.create()
      const target = body('target', {target: true, position: [5, 2, 0]})
      const moving = body('moving', {motion: 'loose', mass: 1, position: [-5, 2, 0],
        shot: kind === 'sparks' ? Object.assign(new S.SceneShot(), {speed: 2}) : null})
      await f.apply(box, world([], [target, moving]))
      const sim = box.sim, held = f.hold('node'), order = []
      for (const method of ['collect', 'takeBursts', 'takeEvents']) {
        const original = sim[method].bind(sim)
        sim[method] = (...args) => { order.push(method); return original(...args) }
      }
      const queue = box.queue.bind(box)
      box.queue = event => {
        order.push('queue:' + event.kind)
        assert.equal(sim.pendingBursts.length, 0)
        assert.equal(box.particlePending.length, 1)
        queue(event)
      }
      f.contact([[sim.index.get('target'), sim.index.get('moving'), 5, 1.25, 2.5, -0.75]])
      box.frame(20)
      box.advance()
      assert.equal(box.particlesEmitted, 0)
      box.frame(20)
      assert.deepEqual(order.slice(-5), ['collect', 'takeBursts', 'takeEvents', 'queue:struck', 'queue:hit'])
      assert.equal(box.particlePending[0].kind, kind)
      const request = box.particlePending[0]
      const events = box.takeEvents(100)
      assert.ok(events.some(e => e.kind === 'struck'))
      order.push('dispatch')
      assert.ok(order.lastIndexOf('takeBursts') < order.indexOf('dispatch'))
      await f.apply(box, world())
      assert.equal(box.bodyCount(), 0)
      held.release.resolve()
      await f.ready(box)
      box.frame(1000)
      assert.equal(box.particlesEmitted, 1)
      assertPoses(box, P.burstParticles(kind, request.seed, request.origin, request.color).map(p => P.particlePose(p, 0)))
      assert.deepEqual(sim.takeBursts(), [])
    })
  }
  await check('real sim contact queue and renderer pending queue both cap at the newest 16 effects', async f => {
    const box = await f.create()
    const targets = Array.from({length: 40}, (_, i) => body('target-' + i, {target: true, position: [i * 2, 2, 0]}))
    const moving = body('moving', {motion: 'loose', mass: 1, position: [-10, 2, 0]})
    await f.apply(box, world([], [...targets, moving]))
    const sim = box.sim, held = f.hold('node')
    f.contact(targets.map((b, i) => [sim.index.get(b.id), sim.index.get('moving'), 5, i, 2, 0]))
    box.frame(20)
    box.advance()
    box.frame(20)
    assert.equal(box.particlePending.length, 16)
    assert.deepEqual(box.particlePending.map(r => r.origin[0]), Array.from({length: 16}, (_, i) => i + 24))
    assert.ok(box.particlePending.every(r => r.kind === 'dust'))
    assert.deepEqual(sim.takeBursts(), [])
    held.release.resolve()
    await f.ready(box)
    box.frame(0)
    assert.equal(box.particlesEmitted, 16)
    assert.equal(box.particleCount(), 11 * 22)
    assert.equal(box.particleNodes[0].position.x, 29)
    assert.equal(box.particleNodes[241].position.x, 39)
  })
  await check('static grouped parts retain their nodes and poses while particles animate and expire', async f => {
    const box = await f.create()
    const parts = [body('left', {position: [-1, 0, 0]}), body('right', {shape: 'sphere', position: [1, 0, 0], color: 'accent'})]
    const group = body('group', {shape: 'group', parts, position: [3, 2, 1], rotation: [0, 30, 0]})
    await f.apply(box, world([], [group]))
    const entry = box.bodies.get('group'), nodes = [entry.node, ...entry.parts]
    assert.equal(entry.parts.length, 2)
    const poses = nodes.map(n => ({position: {...n.position}, rotation: {...n.rotation}, scale: {...n.scale}}))
    const start = f.writes.length
    await f.apply(box, world([burst()], [group]))
    await f.ready(box)
    box.frame(16)
    await expire(f, box)
    assert.equal(box.bodies.get('group'), entry)
    nodes.forEach((n, i) => {
      assert.deepEqual({position: n.position, rotation: n.rotation, scale: n.scale}, poses[i])
      assert.equal(f.writes.slice(start).filter(w => w.object === n).length, 0, 'static part has no per-frame pose writes')
    })
    assert.equal(box.bodyCount(), 1)
    assert.equal(f.count('phys:init'), 0)
  })
  for (const boundary of ['node', 'batch']) {
    for (const mode of ['retire visible', 'retire unmounted', 'destroy']) {
      await check(mode + ' during particle ' + boundary + ' defers cleanup safely without late publication', async f => {
        const box = await f.create()
        const held = boundary === 'batch' ? null : f.hold(boundary)
        box.apply(world([burst()]), theme)
        if (held) await f.settle(held.entered.promise, false)
        else await f.until(() => box.particleNodes.length === 16 && [...f.timers.values()].some(t => t.ms === 16), false)
        await f.until(() => !box.running, false)
        const nodes = box.particleNodes.length, materials = box.particleMaterials.length
        const published = new Set([...box.particleNodes, ...f.scenes[0].imports.flatMap(i => i.copies || [])])
        if (mode === 'retire visible') box.appeared()
        if (mode === 'destroy') box.destroy()
        else box.retire()
        assert.equal(box.needsFrames(), false)
        assert.equal(box.particleCount(), 0)
        assert.equal(box.particlePending.length, 0)
        assert.equal(f.scenes[0].destroys, mode === 'retire visible' ? 0 : 1)
        const before = f.calls.length, beforeWrites = f.writes.length
        if (held) held.release.resolve()
        else f.fire(16)
        await f.until(() => box.particlePreparing === null)
        assert.equal(box.particleReady, false)
        assert.equal(box.particleNodes.length, mode === 'retire visible' ? nodes : 0)
        assert.equal(box.particleMaterials.length, mode === 'retire visible' ? materials : 0)
        assert.equal(box.particlesEmitted, 0)
        assert.equal(box.note, '')
        assert.equal(f.calls.slice(before).filter(c => ['material', 'mesh', 'geometry'].includes(c.op)).length, 0)
        assert.equal(f.writes.length, beforeWrites, 'no delayed resource receives particle state')
        if (mode === 'retire visible') {
          const late = f.resources.filter(r => isParticle(r.name) && !published.has(r))
          assert.ok(boundary === 'batch' ? late.length === 0 : late.length > 0)
          assert.ok(late.every(r => r.destroys === 1), 'every unpublished material, mesh and geometry is released exactly once')
          assert.ok(f.scenes[0].root.childrenList.every(n => !isParticle(n.name) || box.particleNodes.includes(n)))
          box.disappeared()
        }
        box.destroy()
        assert.equal(f.scenes[0].destroys, 1)
      })
    }
  }
  await check('retiring visible live particles hides once and destroys only on the retirement deadline', async f => {
    const box = await f.create()
    await f.apply(box, world([burst()]))
    await f.ready(box)
    box.frame(16)
    const visible = box.particleNodes.slice(0, box.particleCount())
    box.appeared()
    const before = f.writes.length
    box.retire()
    box.retire()
    assert.equal(box.needsFrames(), false)
    assert.equal(box.particleCount(), 0)
    assert.equal(f.scenes[0].destroys, 0)
    visible.forEach(n => { assert.deepEqual(n.scale, zero); assert.equal(n.visible, false) })
    assert.equal(f.writes.slice(before).length, visible.length * 2)
    box.frame(1000)
    assert.equal(f.writes.slice(before).length, visible.length * 2)
    assert.equal([...f.timers.values()].filter(t => t.ms === 1000).length, 1)
    f.fire(1000)
    assert.equal(f.scenes[0].destroys, 1)
    assert.equal(box.particleNodes.length + box.particleMaterials.length + box.particleColors.size, 0)
    box.disappeared()
    box.destroy()
  })
  for (const boundary of ['node', 'importScene', 'empty', 'missing']) {
    await check('failed particle ' + boundary + ' preparation preserves completed slots and retries on a later burst', async f => {
      const box = await f.create()
      const name = 'particle17' + (boundary === 'node' ? '' : ':asset')
      f.faults.add(boundary + ':' + name)
      await f.apply(box, world([burst()]))
      await f.until(() => box.particlePreparing === null)
      assert.match(box.note, /Particle rendering failed:/)
      assert.equal(box.particleNodes.length, 23)
      assert.equal(box.particleMaterials.length, 23)
      assert.equal(box.particlePending.length, 0)
      assert.equal(box.particleCount(), 0)
      assert.equal(box.particleReady, false)
      assert.equal(box.needsFrames(), false, 'failed preparation does not spin a retry loop')
      assert.equal(box.particlesEmitted, 0)
      const partial = box.particleNodes.slice()
      const orphans = f.resources.filter(r => r.name === 'particle17' || r.name.startsWith('particle17:'))
      assert.ok(orphans.every(r => r.destroys === 1), 'failed slot releases its material and mesh')
      f.faults.clear()
      const retry = world([burst(2, {kind: 'dust'})])
      await f.apply(box, retry)
      await f.ready(box)
      assert.deepEqual(box.particleNodes.slice(0, partial.length), partial)
      assert.equal(box.particleNodes.length, 256)
      assert.equal(new Set(box.particleNodes.map(n => particleGeometry(n).mesh)).size, 256)
      assert.equal(f.calls.filter(c => c.op === 'load' && c.name === 'vera-particle.glb').length, 1)
      box.frame(16)
      assert.equal(box.particlesEmitted, 1, 'failed request is discarded, not replayed with the retry')
      assertPoses(box, expectedParticles(retry).map(p => P.particlePose(p, 0)))
      await expire(f, box)
    })
  }
  for (const kind of ['smoke', 'dust']) {
    await check(kind + ': zero-alpha slots become visible on reuse and invisible again on expiration', async f => {
      const box = await f.create()
      await f.apply(box, world([burst(1, {kind, color: '#3685ca00'})]))
      await f.ready(box)
      assert.ok(box.particleNodes.every(n => n.visible === false))
      box.frame(0)
      const slots = box.particleNodes.slice(0, box.particleCount())
      assert.ok(slots.every(n => n.visible === false && materialOf(n).baseColor.factor.w === 0))
      await expire(f, box)
      await f.apply(box, world([burst(2, {kind, color: '#3685ca80'})]))
      box.frame(0)
      assert.ok(slots.every(n => n.visible === true && materialOf(n).baseColor.factor.w > 0))
      await expire(f, box)
      assert.ok(box.particleNodes.every(n => n.visible === false))
      await f.apply(box, world([burst(3, {kind, color: '#3685ca00'})]))
      box.frame(0)
      assert.ok(slots.every(n => n.visible === false))
      assert.equal(f.count('importScene', true), 256)
    })
  }
  await check('preparation runs at most eight slots in parallel, yields at sixteen, and reports full elapsed queue wait', async f => {
    const box = await f.create()
    const gates = Array.from({length: 8}, () => f.hold('node'))
    await f.apply(box, world([burst(1)]))
    await f.settle(Promise.all(gates.map(g => g.entered.promise)), false)
    assert.equal(f.activity.pending, 8)
    assert.equal(f.activity.peak, 8)
    assert.equal(f.count('node', true), 8)
    assert.equal(box.particleReady, false)
    assert.equal(box.particlesEmitted, 0)
    f.jump(5000)
    gates.forEach(g => g.release.resolve())
    await f.until(() => box.particleNodes.length === 16 && [...f.timers.values()].some(t => t.ms === 16), false)
    assert.equal(f.count('node', true), 16)
    assert.equal(box.particleReady, false)
    assert.ok(box.particleNodes.every(n => n.visible === false))
    f.jump(2000)
    await f.ready(box)
    assert.equal(f.activity.pending, 0)
    assert.equal(f.activity.peak, 8)
    const prep = f.logs.filter(l => l.startsWith('VERA-WORLD-PARTICLES prep '))
    assert.equal(prep.length, 1)
    assert.match(prep[0], /status=ready initial=0 added=256 count=256 totalMs=\d+$/)
    assert.ok(Number(prep[0].match(/totalMs=(\d+)/)[1]) >= 7000)
    f.jump(3000)
    box.frame(0)
    const emit = f.logs.filter(l => l.startsWith('VERA-WORLD-PARTICLES emit '))
    assert.equal(emit.length, 1)
    assert.match(emit[0], /requests=1 oldestQueuedMs=\d+$/)
    assert.ok(Number(emit[0].match(/oldestQueuedMs=(\d+)/)[1]) >= 10000)
    assertPoses(box, box.particlePool.poses())
  })
  for (const boundary of ['node', 'importScene', 'empty', 'missing']) {
    await check('failed parallel ' + boundary + ' drains all held siblings before retrying the missing slot', async f => {
      const box = await f.create()
      f.faults.add(boundary + ':particle1' + (boundary === 'node' ? '' : ':asset'))
      const gates = Array.from({length: 7}, (_, i) => f.hold('node', name => name === 'particle' + (i + 2)))
      await f.apply(box, world([burst()]))
      await f.settle(Promise.all(gates.map(g => g.entered.promise)), false)
      for (let i = 0; i < 40; i++) await Promise.resolve()
      assert.notEqual(box.particlePreparing, null)
      assert.equal(box.note, '')
      gates.slice(0, 6).forEach(g => g.release.resolve())
      await f.until(() => box.particleNodes.length === 6, false)
      assert.notEqual(box.particlePreparing, null)
      assert.equal(f.count('node', true), 8, 'no next batch while a sibling remains pending')
      assert.equal(f.logs.filter(l => l.startsWith('VERA-WORLD-PARTICLES prep ')).length, 0)
      gates[6].release.resolve()
      await f.until(() => box.particlePreparing === null)
      assert.match(box.note, /Particle rendering failed:/)
      assert.equal(box.particleNodes.length, 7)
      assert.equal(f.activity.pending, 0)
      assert.equal(box.particleReady, false)
      assert.ok(box.particleNodes.every(n => n.visible === false))
      assert.match(f.logs.find(l => l.startsWith('VERA-WORLD-PARTICLES prep ')), /status=failed initial=0 added=7 count=7/)
      const partial = box.particleNodes.slice()
      f.faults.clear()
      await f.apply(box, world([burst(2)]))
      await f.ready(box)
      assert.deepEqual(box.particleNodes.slice(0, 7), partial)
      assert.equal(box.particleNodes.length, 256)
      assert.equal(new Set(box.particleNodes.map(n => particleGeometry(n).mesh)).size, 256)
      assert.equal(new Set(box.particleMaterials).size, 256)
      assert.match(f.logs.filter(l => l.startsWith('VERA-WORLD-PARTICLES prep '))[1], /status=ready initial=7 added=249 count=256/)
      assert.ok(f.activity.peak <= 8)
    })
  }
  for (const mode of ['retire visible', 'retire unmounted', 'destroy']) {
    await check(mode + ': parallel preparation remains pending until every in-flight slot drains', async f => {
      const box = await f.create(), gates = Array.from({length: 8}, () => f.hold('node'))
      await f.apply(box, world([burst()]))
      await f.settle(Promise.all(gates.map(g => g.entered.promise)), false)
      assert.equal(f.activity.pending, 8)
      if (mode === 'retire visible') box.appeared()
      if (mode === 'destroy') box.destroy()
      else box.retire()
      gates.slice(0, 7).forEach(g => g.release.resolve())
      for (let i = 0; i < 80; i++) await Promise.resolve()
      assert.notEqual(box.particlePreparing, null)
      assert.equal(f.activity.pending, 1)
      assert.equal(box.particleNodes.length, 0)
      const writes = f.writes.length
      gates[7].release.resolve()
      await f.until(() => box.particlePreparing === null)
      assert.equal(f.activity.pending, 0)
      assert.equal(f.writes.length, writes)
      assert.equal(box.particleReady, false)
      assert.equal(box.particleNodes.length, 0)
      assert.equal(f.count('node', true), 8)
      assert.match(f.logs.find(l => l.startsWith('VERA-WORLD-PARTICLES prep ')), /status=retired initial=0 added=0 count=0/)
      if (mode === 'retire visible') {
        assert.ok(f.resources.filter(r => isParticle(r.name)).every(r => r.destroys === 1))
        box.disappeared()
      }
    })
  }
  const passed = checks.filter(c => c.status === 'PASS').length
  console.log(JSON.stringify({passed, failed: checks.length - passed, typescript: ts.version,
    scope: 'Host renderer control flow and resource API only; no GPU blending, visuals, ArkTS typecheck, build or device validation.',
    failures: checks.filter(c => c.status === 'FAIL')}))
  if (passed !== checks.length) process.exitCode = 1
}

main().catch(error => { console.error(error.stack || error); process.exitCode = 1 })
