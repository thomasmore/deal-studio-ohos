'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const Module = require('node:module')
const {loadVera} = require('./source-loader')
const M = loadVera('VeraModels')
const file = path.join(__dirname, 'particles-renderer-check.js')
const mod = new Module(file, module)
mod.filename = file
mod.paths = Module._nodeModulePaths(__dirname)
mod._compile(fs.readFileSync(file, 'utf8').replace(
  '$rawfile: path => ({path})',
  '$rawfile: path => ({id: 0, type: 30000, path, params: [path]})').replace(
  "Scene: {load: raw => api('load', raw ? raw.path : 'empty', null, () => makeScene(raw ? raw.path : ''))}",
  "Scene: {load: raw => { if (raw) { assert.equal(raw.id, 0); assert.equal(raw.type, 30000) } const name = raw ? raw.params[0] : ''; return api('load', name || 'empty', null, () => { const source = makeScene(name); source.root.children.count = () => raw && !faults.has('emptyModel:' + name) ? 1 : 0; return source }) }}").replace(
  'main().catch(error => { console.error(error.stack || error); process.exitCode = 1 })',
  'module.exports = {fixture, body, world, theme, L, resolveTheme}'), file)
const {fixture, body, world, theme, L, resolveTheme} = mod.exports
const model = (id = 'car', name = 'raceCarRed', extra = {}) => {
  const shape = M.modelShape(name, 3)
  return body(id, {model: name, shape: 'hull', dims: shape.dims, points: shape.points,
    position: [2, 4 + shape.dims[1] / 2, -3], rotation: [10, 25, 5], ...extra})
}
const vector = a => ({x: a[0], y: a[1], z: a[2]})
const rotation = a => ({x: a[0], y: a[1], z: a[2], w: a[3]})
const loads = f => f.calls.filter(c => c.op === 'load' && c.name !== 'empty')
const checks = []
async function check(name, run) {
  const f = fixture()
  let error
  try { await run(f) } catch (e) { error = e }
  try { await f.clean() } catch (e) { error = error || e }
  checks.push({name, status: error ? 'FAIL' : 'PASS'})
  if (error) { console.error('FAIL ' + name + '\n' + error.stack); process.exitCode = 1 }
  else console.log('PASS ' + name)
}
async function failed(f, box, spec) {
  box.apply(spec, theme)
  await f.until(() => !box.running)
  assert.match(box.note, /World rendering failed:/)
}
async function main() {
  const rendererSource = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/components/VeraWorld3D.ets'), 'utf8')
  assert.doesNotMatch(rendererSource, /\$rawfile\(spec\.file\)/)
  assert.match(rendererSource, /let resource = \$rawfile\('models\/treeSmall\.glb'\)\s+resource\.params = \[spec\.file\]/)
  await check('phase-0 spike is absent from product sources, routes and packaged resources', async () => {
    const mainRoot = path.resolve(__dirname, '../../entry/src/main')
    const retired = /WorldSpikeBox|WorldSpikePage|worldSpike|world-spike|spikeNow|VERA-WORLD-SPIKE/
    function inspect(dir) {
      for (const entry of fs.readdirSync(dir, {withFileTypes: true})) {
        const file = path.join(dir, entry.name)
        assert.doesNotMatch(entry.name, retired, file)
        if (entry.isDirectory()) inspect(file)
        else if (/\.(ets|json|json5)$/.test(entry.name)) {
          assert.doesNotMatch(fs.readFileSync(file, 'utf8'), retired, file)
        }
      }
    }
    inspect(mainRoot)
    assert.doesNotMatch(rendererSource, /systemDateTime|hidebug/)
    assert.ok(!fs.existsSync(path.join(__dirname, 'world-spike-check.js')))
    const catalog = new Set(M.MODEL_CATALOG.map(spec => spec.file))
    for (const match of rendererSource.matchAll(/\$rawfile\('([^']+\.glb)'\)/g)) {
      assert.ok(catalog.has(match[1]) || match[1] === 'vera-particle.glb',
        'renderer GLB literal must belong to the product catalogue or the owned internal particle asset: ' + match[1])
    }
  })
  await check('all catalogue transforms preserve support height and apply normalization only beneath the body pose', async f => {
    const box = await f.create()
    for (const spec of M.MODEL_CATALOG) {
      const b = model('sample', spec.name), shape = M.modelShape(spec.name, Math.max(...b.dims))
      await f.apply(box, world([], [b]))
      const entry = box.bodies.get(b.id), imported = f.scenes[0].imports.at(-1)
      assert.equal(imported.source.sourceName, spec.file)
      assert.equal(imported.parent, entry.node)
      assert.deepEqual(entry.node.position, vector(b.position))
      assert.deepEqual(entry.node.rotation, rotation(L.quatXYZ(...b.rotation)))
      assert.deepEqual(entry.node.scale, {x: 1, y: 1, z: 1})
      assert.deepEqual(imported.root.position, vector(shape.offset))
      assert.deepEqual(imported.root.scale, {x: shape.scale, y: shape.scale, z: shape.scale})
      assert.deepEqual(imported.root.rotation, rotation(L.quatXYZ(0, shape.yawDeg, 0)))
      assert.equal(box.bodyOf(imported.leaf), b.id)
      assert.equal(box.partOf(imported.leaf), '')
    }
    assert.equal(loads(f).length, M.MODEL_CATALOG.length)
    assert.equal(f.count('mesh'), 0, 'collision hull is never rendered')
  })
  await check('concurrent same-name bodies share one source, import independently, and survive first-instance deletion', async f => {
    const box = await f.create(), gate = f.hold('load', n => n === 'models/raceCarRed.glb')
    box.apply(world([], [model('first'), model('second')]), theme)
    await f.settle(gate.entered.promise)
    assert.equal(loads(f).length, 1)
    gate.release.resolve()
    await f.until(() => !box.running)
    assert.equal(box.note, '')
    const first = box.bodies.get('first'), second = box.bodies.get('second'), source = f.scenes[0].imports[0].source
    assert.notEqual(first.node, second.node)
    assert.equal(f.scenes[0].imports[1].source, source)
    await f.apply(box, world([], [model('second')]))
    assert.equal(first.node.parent, null)
    assert.equal(first.node.destroys, 1)
    assert.equal(box.bodies.get('second'), second)
    await f.apply(box, world([], [model('second'), model('third')]))
    assert.equal(loads(f).length, 1)
    assert.equal(f.scenes[0].imports.length, 3)
    assert.equal(source.destroys, 0)
    await f.apply(box, world())
    assert.equal(source.destroys, 0)
    box.destroy()
    assert.equal(source.destroys, 1)
    const order = f.calls.filter(c => c.op === 'sceneDestroy').map(c => c.scene)
    assert.equal(order[0], f.scenes[0])
    assert.equal(order[1], source)
    assert.ok(f.logs.some(l => /VERA-WORLD-MODEL name=raceCarRed cache=hit/.test(l)))
    assert.ok(f.logs.some(l => /cache=miss loadMs=\d+/.test(l)))
    assert.ok(f.logs.some(l => /name=raceCarRed importMs=\d+/.test(l)))
  })
  await check('model swaps and primitive transitions use fresh instances without losing cached sources', async f => {
    const box = await f.create()
    await f.apply(box, world([], [model()]))
    const first = box.bodies.get('car').node
    await f.apply(box, world([], [model('car', 'treeSmall')]))
    assert.equal(first.parent, null)
    assert.equal(first.destroys, 1)
    await f.apply(box, world([], [body('car')]))
    assert.ok(box.bodies.get('car').node.mesh)
    await f.apply(box, world([], [model()]))
    assert.equal(loads(f).length, 2)
    assert.equal(box.materialBindings.size, 0)
  })
  await check('themes preserve imported materials and deep raycast picking uses the unique body ancestor', async f => {
    const box = await f.create(), spec = world([], [model()])
    await f.apply(box, spec)
    const imported = f.scenes[0].imports[0], material = imported.leaf.mesh.subMeshes[0].material
    const entry = box.bodies.get('car')
    await f.apply(box, spec, resolveTheme('clean', '#bb2255', false))
    assert.equal(box.bodies.get('car'), entry)
    assert.equal(imported.leaf.mesh.subMeshes[0].material, material)
    assert.equal(f.count('material'), 0)
    box.width = 300; box.height = 200
    box.cam.raycast = async () => [{node: imported.leaf, hitPosition: {x: 1, y: 2, z: 3}}]
    const pick = await f.settle(box.raycast(100, 100))
    assert.equal(pick.body, 'car')
    assert.equal(pick.part, '')
    assert.deepEqual([pick.x, pick.y, pick.z], [1, 2, 3])
    const cycle = {name: 'cycle'}; cycle.parent = cycle
    assert.equal(box.bodyOf(cycle), '')
  })
  await check('rings and marks are body-local decorations and theme rebuilds do not paint imported materials', async f => {
    const box = await f.create(), spec = world([], [model('car', 'raceCarRed', {rings: [2, 2.5], mark: 'accent'})])
    await f.apply(box, spec)
    const entry = box.bodies.get('car'), imported = f.scenes[0].imports[0]
    assert.equal(box.materialBindings.size, 2)
    // Bindings are by node name; the bound nodes are the ring and the mark, children of the body's own node.
    const bound = [...box.materialBindings.keys()]
    const children = Array.from({length: entry.node.children.count()}, (_, i) => entry.node.children.get(i))
    assert.equal(bound.length, 2)
    for (const name of bound) {
      const node = children.find(c => c.name === name)
      assert.ok(node, 'a bound node is a child of the body: ' + name)
      assert.equal(node.parent, entry.node)
      assert.equal(box.bodyOf(node), 'car')
    }
    const ownMaterial = imported.leaf.mesh.subMeshes[0].material
    await f.apply(box, spec, resolveTheme('clean', '#ee2255', false))
    assert.equal(loads(f).length, 1)
    assert.equal(f.scenes[0].imports.at(-1).leaf.mesh.subMeshes[0].material.asset, ownMaterial.asset)
    assert.equal(box.materialBindings.size, 2)
    await f.apply(box, world())
    assert.equal(box.materialBindings.size, 0)
  })
  await check('resolved empty model sources fail visibly, release resources, evict cache and retry', async f => {
    const box = await f.create(), spec = world([], [model()])
    f.faults.add('emptyModel:models/raceCarRed.glb')
    await failed(f, box, spec)
    assert.match(box.note, /Empty model source: raceCarRed/)
    assert.equal(box.modelSources.size, 0)
    assert.equal(box.loadedModels.size, 0)
    assert.equal(box.bodyCount(), 0)
    assert.equal(f.scenes[1].destroys, 1)
    assert.equal(f.scenes[0].imports.length, 0)
    f.faults.clear()
    await f.apply(box, spec)
    assert.equal(loads(f).length, 2)
    assert.equal(box.bodyCount(), 1)
  })
  await check('concurrent rejected source load evicts its promise and later retry succeeds', async f => {
    const box = await f.create(), spec = world([], [model('a'), model('b')])
    f.faults.add('load:models/raceCarRed.glb')
    await failed(f, box, spec)
    assert.equal(loads(f).length, 1)
    assert.equal(box.modelSources.size, 0)
    assert.equal(box.bodyCount(), 0)
    f.faults.clear()
    await f.apply(box, spec)
    assert.equal(loads(f).length, 2)
    assert.equal(box.bodyCount(), 2)
  })
  await check('partially imported hierarchy is detached on import failure and retry retains the original source', async f => {
    const box = await f.create(), spec = world([], [model()])
    f.faults.add('importScene:b1:model')
    await failed(f, box, spec)
    const partial = f.scenes[0].imports[0]
    assert.equal(partial.parent.parent, null)
    assert.equal(partial.parent.destroys, 1)
    assert.equal(box.bodyCount(), 0)
    assert.equal(box.byName.size, 0)
    assert.equal(partial.source.destroys, 0)
    f.faults.clear()
    await f.apply(box, spec)
    assert.equal(loads(f).length, 1)
    assert.equal(box.bodyCount(), 1)
  })
  await check('failed body node creation retries without reloading its retained source', async f => {
    const box = await f.create(), spec = world([], [model()])
    f.faults.add('node:b1')
    await failed(f, box, spec)
    assert.equal(box.bodyCount(), 0)
    assert.equal(box.byName.size, 0)
    f.faults.clear()
    await f.apply(box, spec)
    assert.equal(loads(f).length, 1)
    assert.equal(box.bodyCount(), 1)
  })
  await check('decoration failure cleans the registered imported parent and a retry can reuse the source', async f => {
    const box = await f.create(), spec = world([], [model('car', 'raceCarRed', {mark: 'accent'})])
    f.faults.add('material:vertex:unlit')
    await failed(f, box, spec)
    const partial = f.scenes[0].imports[0]
    assert.equal(partial.parent.parent, null)
    assert.equal(partial.parent.destroys, 1)
    assert.equal(box.bodyCount(), 0)
    assert.equal(box.byName.size + box.materialBindings.size, 0)
    f.faults.clear()
    await f.apply(box, spec)
    assert.equal(loads(f).length, 1)
    assert.equal(box.materialBindings.size, 1)
  })
  await check('failed sibling waits for delayed model loading and superseding retry removes the completed model', async f => {
    const box = await f.create(), gate = f.hold('load', n => n.startsWith('models/'))
    await f.apply(box, world())
    f.faults.add('mesh:b1m')
    box.apply(world([], [body('failure'), model('late')]), theme)
    await f.settle(gate.entered.promise)
    for (let i = 0; i < 40; i++) await Promise.resolve()
    assert.equal(box.running, true)
    const retry = world()
    box.apply(retry, theme)
    gate.release.resolve()
    await f.until(() => !box.running)
    assert.match(box.note, /World rendering failed:/)
    assert.equal(box.bodyCount(), 1)
    const partial = box.bodies.get('late').node
    f.faults.clear()
    await f.apply(box, retry)
    assert.equal(box.bodyCount(), 0)
    assert.equal(partial.parent, null)
    assert.equal(box.byName.size, 0)
    assert.equal([...box.loadedModels][0].destroys, 0)
  })
  await check('failed model replacement can revert to the committed model after its original node was removed', async f => {
    const box = await f.create(), red = world([], [model()])
    await f.apply(box, red)
    f.faults.add('importScene:b2:model')
    await failed(f, box, world([], [model('car', 'treeSmall')]))
    assert.equal(box.bodyCount(), 0)
    f.faults.clear()
    await f.apply(box, red)
    assert.equal(box.bodyCount(), 1)
    assert.equal(f.scenes[0].imports.at(-1).source.sourceName, 'models/raceCarRed.glb')
    assert.equal(box.bodies.get('car').spec.model, 'raceCarRed')
  })
  await check('successful replacement in a failed batch reverts its actual imported model, not just entry spec', async f => {
    const box = await f.create(), red = world([], [model()])
    await f.apply(box, red)
    f.faults.add('mesh:b2m')
    await failed(f, box, world([], [model('car', 'raceCarGreen'), body('failure')]))
    const green = box.bodies.get('car').node
    assert.equal(f.scenes[0].imports.at(-1).source.sourceName, 'models/raceCarGreen.glb')
    f.faults.clear()
    await f.apply(box, red)
    assert.notEqual(box.bodies.get('car').node, green)
    assert.equal(green.destroys, 1)
    assert.equal(f.scenes[0].imports.at(-1).source.sourceName, 'models/raceCarRed.glb')
    assert.equal(box.bodyCount(), 1)
  })
  for (const mode of ['missing', 'mismatched']) {
    await check(mode + ' primitive geometry after a failed replacement is repaired on reversion', async f => {
      const box = await f.create(), original = body('shape'), committed = world([], [original])
      await f.apply(box, committed)
      const replacement = body('shape', {dims: [4, 2, 3]})
      if (mode === 'missing') f.faults.add('mesh:b2m')
      else f.faults.add('mesh:b3m')
      await failed(f, box, world([], mode === 'missing' ? [replacement] : [replacement, body('failure')]))
      assert.equal(box.bodyCount(), mode === 'missing' ? 0 : 1)
      const partial = box.bodies.get('shape')
      f.faults.clear()
      await f.apply(box, committed)
      assert.equal(box.bodyCount(), 1)
      assert.deepEqual(box.bodies.get('shape').node.meshResource.geometry.size, vector(original.dims))
      if (partial) assert.notEqual(box.bodies.get('shape'), partial)
    })
  }
  await check('matching successful partial model and dynamic primitive are reused without resetting pose or materials', async f => {
    const box = await f.create(), car = model(), moving = body('moving', {motion: 'loose', mass: 1})
    const committed = world([], [car, moving])
    await f.apply(box, committed)
    const changed = model('car', 'raceCarGreen')
    const failureName = 'b' + (box.serial + 1) + 'm'
    f.faults.add('mesh:' + failureName)
    await failed(f, box, world([], [changed, moving, body('failure')]))
    const partial = box.bodies.get('car'), dynamic = box.bodies.get('moving')
    const material = dynamic.node.mesh.subMeshes[0].material
    dynamic.node.position = {x: 9, y: 8, z: 7}; dynamic.pos = [9, 8, 7]
    const imports = f.count('importScene')
    f.faults.clear()
    await f.apply(box, world([], [changed, moving]))
    assert.equal(box.bodies.get('car'), partial)
    assert.equal(f.count('importScene'), imports)
    assert.equal(box.bodies.get('moving'), dynamic)
    assert.equal(dynamic.node.mesh.subMeshes[0].material, material)
    assert.deepEqual(dynamic.node.position, {x: 9, y: 8, z: 7})
    const recoloured = world([], [changed, body('moving', {...moving, color: 'accent'})])
    await f.apply(box, recoloured)
    assert.equal(box.bodies.get('moving'), dynamic)
    assert.notEqual(dynamic.node.mesh.subMeshes[0].material, material)
    const colouredMaterial = dynamic.node.mesh.subMeshes[0].material
    await f.apply(box, recoloured, resolveTheme('clean', '#bb2255', false))
    assert.notEqual(dynamic.node.mesh.subMeshes[0].material, colouredMaterial)
    assert.equal(box.bodies.get('car'), partial)
    assert.deepEqual(dynamic.node.position, {x: 9, y: 8, z: 7})
  })
  await check('matching newly created model survives a failed initial apply and is reused on retry', async f => {
    const box = await f.create(), spec = world([], [model(), body('failure')])
    f.faults.add('mesh:b1m')
    await failed(f, box, spec)
    const partial = box.bodies.get('car'), imports = f.count('importScene')
    assert.ok(partial.ready)
    f.faults.clear()
    await f.apply(box, spec)
    assert.equal(box.bodies.get('car'), partial)
    assert.equal(f.count('importScene'), imports)
    assert.equal(box.bodyCount(), 2)
  })
  await check('successful primitive material and pose updates in a failed batch revert in place', async f => {
    const box = await f.create(), original = body('shape'), committed = world([], [original])
    await f.apply(box, committed)
    const entry = box.bodies.get('shape'), material = entry.node.mesh.subMeshes[0].material
    f.faults.add('mesh:b2m')
    await failed(f, box, world([], [body('shape', {color: 'accent', position: [3, 4, 5]}), body('failure')]))
    assert.notEqual(entry.node.mesh.subMeshes[0].material, material)
    assert.deepEqual(entry.node.position, {x: 3, y: 4, z: 5})
    f.faults.clear()
    await f.apply(box, committed)
    assert.equal(box.bodies.get('shape'), entry)
    assert.equal(entry.node.mesh.subMeshes[0].material, material)
    assert.deepEqual(entry.node.position, vector(original.position))
  })
  await check('failed in-place material update keeps the live spec retryable without resetting loose pose', async f => {
    const box = await f.create(), original = body('moving', {motion: 'loose', mass: 1})
    await f.apply(box, world([], [original]))
    const entry = box.bodies.get('moving'), material = entry.node.mesh.subMeshes[0].material
    entry.node.position = {x: 6, y: 7, z: 8}; entry.pos = [6, 7, 8]
    const next = world([], [body('moving', {...original, color: 'accent', glow: true})])
    f.faults.add('material:' + L.lookColorKey(theme, 'accent', true, 'ink'))
    await failed(f, box, next)
    assert.equal(entry.spec, original)
    assert.equal(entry.node.mesh.subMeshes[0].material, material)
    f.faults.clear()
    await f.apply(box, next)
    assert.equal(box.bodies.get('moving'), entry)
    assert.notEqual(entry.node.mesh.subMeshes[0].material, material)
    assert.deepEqual(entry.node.position, {x: 6, y: 7, z: 8})
  })
  for (const mode of ['retire visible', 'retire unmounted', 'destroy']) {
    for (const boundary of ['load', 'node']) {
      await check(mode + ' during model ' + boundary + ' prevents late import and releases each source once', async f => {
        const box = await f.create(), gate = f.hold(boundary, n => boundary === 'load' ? n.startsWith('models/') : /^b\d+$/.test(n))
        box.apply(world([], [model('a'), model('b')]), theme)
        await f.settle(gate.entered.promise)
        if (mode === 'retire visible') box.appeared()
        if (mode === 'destroy') box.destroy()
        else box.retire()
        const imports = f.count('importScene'), published = box.bodyCount()
        gate.release.resolve()
        await f.until(() => !box.running)
        assert.equal(f.count('importScene'), imports)
        assert.equal(box.bodyCount(), published)
        if (boundary === 'node' && mode === 'retire visible') {
          const lateParent = f.resources.find(r => r.name === 'b1' && r.children)
          assert.equal(lateParent.parent, null)
          assert.equal(lateParent.destroys, 1)
        }
        assert.equal(box.loadedModels.size, boundary === 'load' ? 0 : mode === 'retire visible' ? 1 : 0)
        box.disappeared(); box.destroy()
        assert.ok(f.scenes.every(s => s.destroys === 1))
      })
    }
  }
  await check('newly loaded loose model reads the newest physics pose and later frames continue synchronizing it', async f => {
    const box = await f.create(), gate = f.hold('load', n => n.startsWith('models/'))
    const b = model('car', 'raceCarRed', {motion: 'loose', mass: 1})
    box.apply(world([], [b]), theme)
    await f.settle(gate.entered.promise)
    assert.ok(box.sim)
    const live = [9, 8, 7, 0, 0, 0, 1]
    box.sim.poseOf = () => live
    gate.release.resolve()
    await f.until(() => !box.running)
    const node = box.bodies.get('car').node
    assert.deepEqual(node.position, {x: 9, y: 8, z: 7})
    assert.deepEqual(node.rotation, {x: 0, y: 0, z: 0, w: 1})
    box.writePhysics({poseCount: 1, poses: [0, 6, 5, 4, 0, 0, 0, 1], idAt: () => 'car'})
    assert.deepEqual(node.position, {x: 6, y: 5, z: 4})
    assert.equal(f.count('mesh'), 0)
  })
  await check('model source caches are destination-local and one source destroy failure cannot strand others', async f => {
    const a = await f.create(), b = await f.create()
    await f.apply(a, world([], [model(), model('tree', 'treeSmall')]))
    await f.apply(b, world([], [model()]))
    assert.equal(loads(f).length, 3)
    const sources = [...a.loadedModels]
    sources[0].destroy = function () { this.destroys++; throw Error('injected source destroy') }
    a.destroy()
    assert.ok(sources.every(s => s.destroys === 1))
    assert.equal([...b.loadedModels][0].destroys, 0)
    b.destroy()
  })
  console.log(JSON.stringify({passed: checks.filter(c => c.status === 'PASS').length,
    failed: checks.filter(c => c.status === 'FAIL').length, scope: 'Mocked renderer API/control flow; no GLB parsing, ArkTS build, GPU or phone validation'}))
}
main().catch(e => { console.error(e.stack || e); process.exitCode = 1 })
