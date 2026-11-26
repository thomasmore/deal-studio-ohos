import argparse
import copy
import hashlib
import itertools
import json
import math
import struct
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'entry/src/main/resources/rawfile/models'
MODULE = ROOT / 'entry/src/main/ets/vera/VeraModels.ets'
COMMIT = '11ff7082e566a6278553bf7623980cb93dd41e27'
SELECTION = {
    'raceCarRed': 'Red low racing car with four exposed wheels and a dark windscreen',
    'raceCarGreen': 'Green low racing car with four exposed wheels and a dark windscreen',
    'raceCarOrange': 'Orange low racing car with four exposed wheels and a dark windscreen',
    'raceCarWhite': 'White low racing car with four exposed wheels and a dark windscreen',
    'treeSmall': 'Small low-poly tree with a narrow trunk and angular green foliage',
    'treeLarge': 'Tall low-poly tree with a narrow trunk and angular green foliage',
    'pylon': 'Small tapered traffic cone on a square base',
    'ramp': 'Compact wedge-shaped stunt ramp',
    'barrierRed': 'Low red rectangular track barrier',
    'barrierWhite': 'Low white rectangular track barrier',
    'barrierWall': 'Solid long trackside wall section',
    'fenceStraight': 'Straight open trackside fence section',
    'fenceCurved': 'Curved open trackside fence section',
    'flagCheckers': 'Checkered racing flag on a slender pole',
    'flagRed': 'Red racing flag on a slender pole',
    'billboard': 'Tall rectangular advertising board on supports',
    'grandStand': 'Open stepped spectator grandstand',
    'grandStandCovered': 'Stepped spectator grandstand with an overhead roof',
    'pitsGarage': 'Open-front pit garage building',
    'pitsGarageClosed': 'Pit garage building with a closed front',
    'pitsOffice': 'Boxy pit office building with windows',
    'tent': 'Open-sided square canopy tent with a peaked roof',
    'tentClosed': 'Square canopy tent with enclosed sides',
    'tentLong': 'Long open-sided canopy tent with a peaked roof',
    'lightPostLarge': 'Tall trackside lamp post with a broad lamp head',
    'lightPostModern': 'Slim modern trackside lamp post',
    'overheadLights': 'Overhead racing gantry with signal lights',
    'roadStraight': 'Square straight road tile with lane markings',
    'roadStraightLong': 'Long straight road section with lane markings',
    'roadCornerSmall': 'Tight curved road corner tile',
    'roadCrossing': 'Four-way road intersection tile',
    'roadStart': 'Road start section with an overhead racing gantry',
    'roadRamp': 'Sloping road ramp section',
    'roadBump': 'Short raised road bump section',
    'radarEquipment': 'Trackside radar equipment on a compact pedestal',
    'rail': 'Straight trackside safety rail section',
}
FORMATS = {5120: 'b', 5121: 'B', 5122: 'h', 5123: 'H', 5125: 'I', 5126: 'f'}
WIDTHS = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()

# Text files are hashed as committed; a windows checkout may hold them with CRLF
# while the manifest records LF (or the reverse), so accept either line ending.
TEXT_FILES = {'models.json', 'LICENSE.txt', 'VeraModels.ets'}

def text_bytes(data):
    return data.replace(b'\r\n', b'\n')

def matches_sha(path, digest):
    data = path.read_bytes()
    return sha(data) == digest or (path.name in TEXT_FILES and sha(text_bytes(data)) == digest)

def same_text(path, expected):
    data = path.read_bytes()
    return data == expected or (path.name in TEXT_FILES and text_bytes(data) == text_bytes(expected))

def close(a, b, tol=1e-9):
    """Compare geometry across platforms: the same GLB can round its last bits
    differently, so floats match within a relative tolerance."""
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(close(x, y, tol) for x, y in zip(a, b))
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return abs(a - b) <= tol * max(1.0, abs(a), abs(b))
    return a == b

def json_bytes(value, pretty=False):
    return (json.dumps(value, sort_keys=True, allow_nan=False,
                       indent=2 if pretty else None,
                       separators=None if pretty else (',', ':'))
            + ('\n' if pretty else '')).encode()


def read_glb(data):
    require(len(data) >= 28, 'truncated GLB')
    require(struct.unpack_from('<4sII', data) == (b'glTF', 2, len(data)), 'bad GLB header')
    chunks = []
    offset = 12
    while offset < len(data):
        require(offset + 8 <= len(data), 'truncated chunk header')
        size, kind = struct.unpack_from('<II', data, offset)
        require(size % 4 == 0 and offset + 8 + size <= len(data), 'bad chunk bounds')
        chunks.append((kind, data[offset + 8:offset + 8 + size]))
        offset += size + 8
    require([c[0] for c in chunks] == [0x4E4F534A, 0x004E4942], 'expected JSON and BIN')
    doc = json.loads(chunks[0][1])
    binary = chunks[1][1]
    require(doc['asset']['version'] == '2.0', 'not glTF 2.0')
    require(len(doc['buffers']) == 1 and 'uri' not in doc['buffers'][0], 'external buffer')
    require(0 <= len(binary) - doc['buffers'][0]['byteLength'] <= 3, 'buffer length mismatch')
    require(not doc.get('extensionsRequired'), 'unsupported required extensions')
    require(not doc.get('animations') and not doc.get('skins'), 'static models only')
    for image in doc.get('images', []):
        require('uri' not in image and 'bufferView' in image, 'external image')
    return doc, binary


def write_glb(doc, binary):
    text = json_bytes(doc)
    text += b' ' * (-len(text) % 4)
    binary += b'\0' * (-len(binary) % 4)
    return (struct.pack('<4sII', b'glTF', 2, 28 + len(text) + len(binary))
            + struct.pack('<II', len(text), 0x4E4F534A) + text
            + struct.pack('<II', len(binary), 0x004E4942) + binary)


def accessor_rows(doc, binary, index):
    acc = doc['accessors'][index]
    require('sparse' not in acc, 'sparse accessor unsupported')
    require(acc['type'] in WIDTHS and acc['componentType'] in FORMATS, 'unsupported accessor')
    view = doc['bufferViews'][acc['bufferView']]
    require(view.get('buffer', 0) == 0, 'external bufferView')
    fmt = '<' + FORMATS[acc['componentType']] * WIDTHS[acc['type']]
    width = struct.calcsize(fmt)
    stride = view.get('byteStride', width)
    start = view.get('byteOffset', 0) + acc.get('byteOffset', 0)
    end = start + (acc['count'] - 1) * stride + width
    require(acc['count'] > 0 and stride >= width and start >= view.get('byteOffset', 0)
            and end <= view.get('byteOffset', 0) + view['byteLength']
            and end <= doc['buffers'][0]['byteLength'], 'accessor out of bounds')
    return [struct.unpack_from(fmt, binary, start + i * stride) for i in range(acc['count'])]


def optimize(data):
    original, binary = read_glb(data)
    doc = copy.deepcopy(original)
    indices = {p['indices'] for mesh in doc['meshes'] for p in mesh['primitives'] if 'indices' in p}
    attribute_indices = {a for mesh in doc['meshes'] for p in mesh['primitives']
                         for a in p['attributes'].values()}
    require(not indices.intersection(attribute_indices), 'index accessor used as attribute')
    out = bytearray()
    views = []
    dedup = {}

    def append(payload, target=None):
        key = (target, payload)
        if key in dedup:
            return dedup[key]
        out.extend(b'\0' * (-len(out) % 4))
        view = {'buffer': 0, 'byteOffset': len(out), 'byteLength': len(payload)}
        if target is not None:
            view['target'] = target
        out.extend(payload)
        dedup[key] = len(views)
        views.append(view)
        return len(views) - 1

    compacted = 0
    for i, acc in enumerate(doc['accessors']):
        rows = accessor_rows(original, binary, i)
        if i in indices:
            require(acc['type'] == 'SCALAR' and not acc.get('normalized', False), 'invalid indices')
            maximum = max(row[0] for row in rows)
            if acc['componentType'] == 5125 and maximum <= 65535:
                acc['componentType'] = 5123
                compacted += 1
        fmt = '<' + FORMATS[acc['componentType']] * WIDTHS[acc['type']]
        payload = b''.join(struct.pack(fmt, *row) for row in rows)
        old_view = original['bufferViews'][original['accessors'][i]['bufferView']]
        acc['bufferView'] = append(payload, old_view.get('target'))
        acc.pop('byteOffset', None)
        if acc.get('normalized') is False:
            acc.pop('normalized')
    for image in doc.get('images', []):
        view = original['bufferViews'][image['bufferView']]
        start = view.get('byteOffset', 0)
        image['bufferView'] = append(binary[start:start + view['byteLength']])
    doc['bufferViews'] = views
    doc['buffers'] = [{'byteLength': len(out)}]
    result = write_glb(doc, bytes(out))
    check, check_bin = read_glb(result)
    for i in range(len(doc['accessors'])):
        require(accessor_rows(original, binary, i) == accessor_rows(check, check_bin, i),
                'optimization changed accessor values')
    for key in ['nodes', 'meshes', 'materials', 'textures', 'samplers', 'scenes', 'scene']:
        require(original.get(key) == check.get(key), 'optimization changed ' + key)
    for before, after in zip(original.get('images', []), check.get('images', [])):
        a = original['bufferViews'][before['bufferView']]
        b = check['bufferViews'][after['bufferView']]
        require(binary[a.get('byteOffset', 0):a.get('byteOffset', 0) + a['byteLength']]
                == check_bin[b['byteOffset']:b['byteOffset'] + b['byteLength']], 'changed image')
    return result, {'lossless': True, 'operations': ['minify-json', 'repack-accessors',
                    'deduplicate-identical-buffer-views', 'uint32-indices-to-uint16'],
                    'compactedIndexAccessors': compacted, 'newExtensions': []}


def matmul(a, b):
    return [sum(a[r + 4 * k] * b[k + 4 * c] for k in range(4))
            for c in range(4) for r in range(4)]


def node_matrix(node):
    if 'matrix' in node:
        require(not any(k in node for k in ['translation', 'rotation', 'scale']), 'matrix and TRS')
        require(len(node['matrix']) == 16, 'invalid matrix')
        return node['matrix']
    x, y, z, w = node.get('rotation', [0, 0, 0, 1])
    require(abs(x*x + y*y + z*z + w*w - 1) < 1e-5, 'non-unit quaternion')
    sx, sy, sz = node.get('scale', [1, 1, 1])
    tx, ty, tz = node.get('translation', [0, 0, 0])
    return [(1-2*(y*y+z*z))*sx, 2*(x*y+z*w)*sx, 2*(x*z-y*w)*sx, 0,
            2*(x*y-z*w)*sy, (1-2*(x*x+z*z))*sy, 2*(y*z+x*w)*sy, 0,
            2*(x*z+y*w)*sz, 2*(y*z-x*w)*sz, (1-2*(x*x+y*y))*sz, 0,
            tx, ty, tz, 1]


def transform(matrix, point):
    return tuple(sum(matrix[r + 4*k] * point[k] for k in range(3)) + matrix[r + 12]
                 for r in range(3))


def mesh_vertices(doc, binary):
    vertices = []
    identity = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

    def visit(index, parent, ancestors):
        require(index not in ancestors, 'node cycle')
        node = doc['nodes'][index]
        matrix = matmul(parent, node_matrix(node))
        require(all(math.isfinite(v) for v in matrix), 'non-finite transform')
        if 'mesh' in node:
            for primitive in doc['meshes'][node['mesh']]['primitives']:
                require(not primitive.get('targets'), 'morph targets unsupported')
                require(primitive.get('mode', 4) == 4, 'non-triangle mesh')
                acc = primitive['attributes']['POSITION']
                require(doc['accessors'][acc]['type'] == 'VEC3'
                        and not doc['accessors'][acc].get('normalized'), 'invalid position')
                vertices.extend(transform(matrix, p) for p in accessor_rows(doc, binary, acc))
        for child in node.get('children', []):
            visit(child, matrix, ancestors | {index})

    for index in doc['scenes'][doc.get('scene', 0)]['nodes']:
        visit(index, identity, set())
    require(vertices and all(math.isfinite(c) for v in vertices for c in v), 'invalid vertices')
    return sorted(set(vertices))


def sub(a, b):
    return tuple(x-y for x, y in zip(a, b))


def dot(a, b):
    return sum(x*y for x, y in zip(a, b))


def cross(a, b):
    return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])


def hull_faces(points):
    require(len(points) >= 4, 'too few hull points')
    a = 0
    b = max(range(len(points)), key=lambda i: dot(sub(points[i], points[a]), sub(points[i], points[a])))
    line = sub(points[b], points[a])
    c = max(range(len(points)), key=lambda i: dot(cross(line, sub(points[i], points[a])),
                                                 cross(line, sub(points[i], points[a]))))
    normal = cross(line, sub(points[c], points[a]))
    d = max(range(len(points)), key=lambda i: abs(dot(normal, sub(points[i], points[a]))))
    require(abs(dot(normal, sub(points[d], points[a]))) > 1e-16, 'flat hull')
    inside = tuple(sum(points[i][k] for i in [a, b, c, d]) / 4 for k in range(3))

    def face(i, j, k):
        n = cross(sub(points[j], points[i]), sub(points[k], points[i]))
        if dot(n, sub(inside, points[i])) > 0:
            j, k = k, j
        return (i, j, k)

    faces = [face(a, b, c), face(a, d, b), face(a, c, d), face(b, d, c)]
    for i, point in enumerate(points):
        visible = []
        for f in faces:
            n = cross(sub(points[f[1]], points[f[0]]), sub(points[f[2]], points[f[0]]))
            if dot(n, sub(point, points[f[0]])) > 1e-11 * math.sqrt(dot(n, n)):
                visible.append(f)
        if not visible:
            continue
        edges = set()
        for f in visible:
            for edge in [(f[0], f[1]), (f[1], f[2]), (f[2], f[0])]:
                reverse = (edge[1], edge[0])
                if reverse in edges:
                    edges.remove(reverse)
                else:
                    edges.add(edge)
        gone = set(visible)
        faces = [f for f in faces if f not in gone]
        faces.extend(face(j, k, i) for j, k in sorted(edges))
    return faces


def contains(points, vertices, tolerance=1e-8):
    for face in hull_faces(points):
        a, b, c = [points[i] for i in face]
        normal = cross(sub(b, a), sub(c, a))
        length = math.sqrt(dot(normal, normal))
        if any(dot(normal, sub(p, a)) > tolerance * length for p in vertices):
            return False
    return True


def support_polytope(vertices):
    normals = [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)]
    normals += list(itertools.product([-1, 1], repeat=3))
    distances = [max(dot(n, p) for p in vertices) for n in normals]
    points = []
    for i, j, k in itertools.combinations(range(len(normals)), 3):
        a, b, c = normals[i], normals[j], normals[k]
        det = dot(a, cross(b, c))
        if abs(det) < 1e-12:
            continue
        p = tuple((distances[i]*cross(b, c)[d] + distances[j]*cross(c, a)[d]
                   + distances[k]*cross(a, b)[d]) / det for d in range(3))
        if all(dot(n, p) <= distance + 1e-10 for n, distance in zip(normals, distances)):
            if not any(max(abs(p[d]-q[d]) for d in range(3)) < 1e-9 for q in points):
                points.append(p)
    return sorted(points)


def geometry(data):
    doc, binary = read_glb(data)
    vertices = mesh_vertices(doc, binary)
    low = [min(p[k] for p in vertices) for k in range(3)]
    high = [max(p[k] for p in vertices) for k in range(3)]
    require(all(high[k] > low[k] for k in range(3)), 'zero-volume mesh bounds')
    faces = hull_faces(vertices)
    points = [vertices[i] for i in sorted({i for face in faces for i in face})]
    exact_count = len(points)
    exact_contains = contains(points, vertices)
    method = 'exact-convex-hull'
    reason = None
    if exact_count > 64 or not exact_contains:
        reason = ('Exact hull has ' + str(exact_count) + ' points (limit 64). '
                  if exact_count > 64 else 'Exact hull failed containment validation. ')
        reason += 'Use intersection of 14 mesh supporting planes, never an inscribed subset.'
        points = support_polytope(vertices)
        method = 'conservative-14-plane-polytope'
    if not 4 <= len(points) <= 64 or not contains(points, vertices):
        points = list(itertools.product(*zip(low, high)))
        method = 'conservative-bbox-fallback'
        reason = 'Supporting-plane reduction failed point budget or containment validation.'
    require(4 <= len(points) <= 64 and contains(points, vertices), 'unsafe collision hull')
    return {'min': low, 'max': high, 'points': [c for p in points for c in p],
            'support': [(low[0]+high[0])/2, low[1], (low[2]+high[2])/2],
            'forward': [0, 0, 1], 'collision': {'method': method, 'reason': reason,
            'pointCount': len(points), 'containsAllVertices': True,
            'containmentTolerance': 1e-8,
            'approximation': 'One convex solid fills mesh concavities and openings; not a triangle collider.'}}


def module_text(models):
    entries = []
    for model in models:
        fields = ['  {']
        for key in ['name', 'description', 'file', 'min', 'max', 'points', 'forward']:
            if key == 'points':
                fields.append('    points: [')
                for start in range(0, len(model[key]), 6):
                    fields.append('      ' + ', '.join(str(v) for v in model[key][start:start + 6]) + ',')
                fields.append('    ],')
            else:
                fields.append('    ' + key + ': ' + json.dumps(model[key]) + ',')
        fields.append('  },')
        entries.append('\n'.join(fields))
    return '''export class ModelSpec {
  name: string = ''
  description: string = ''
  file: string = ''
  min: number[] = []
  max: number[] = []
  points: number[] = []
  forward: number[] = [0, 0, 1]
}

export class ModelShape {
  dims: number[] = []
  points: number[] = []
  scale: number = 1
  offset: number[] = []
  yawDeg: number = 90
}

export const MODEL_CATALOG: ModelSpec[] = [
''' + '\n'.join(entries) + '''
]

export function modelSpec(name: string): ModelSpec | null {
  for (let spec of MODEL_CATALOG) { if (spec.name === name) { return spec } }
  return null
}

export function modelNames(): string[] {
  let names: string[] = []
  for (let spec of MODEL_CATALOG) { names.push(spec.name) }
  return names
}

export function modelShape(name: string, size: number): ModelShape | null {
  let spec = modelSpec(name)
  if (spec === null || !Number.isFinite(size) || size <= 0) { return null }
  let dx = spec.max[0] - spec.min[0]
  let dy = spec.max[1] - spec.min[1]
  let dz = spec.max[2] - spec.min[2]
  let scale = size / Math.max(dx, dy, dz)
  if (!Number.isFinite(scale) || scale <= 0) { return null }
  let cx = (spec.min[0] + spec.max[0]) / 2
  let cy = (spec.min[1] + spec.max[1]) / 2
  let cz = (spec.min[2] + spec.max[2]) / 2
  let shape = new ModelShape()
  shape.dims = [dz * scale, dy * scale, dx * scale]
  shape.scale = scale
  shape.offset = [-cz * scale, -cy * scale, cx * scale]
  for (let i = 0; i < spec.points.length; i += 3) {
    shape.points.push((spec.points[i + 2] - cz) * scale,
      (spec.points[i + 1] - cy) * scale, -(spec.points[i] - cx) * scale)
  }
  return shape
}
'''


def source_file(source, entry):
    path = Path(entry['path'])
    require(not path.is_absolute() and '..' not in path.parts, 'unsafe source path')
    data = (source / path).read_bytes()
    require(len(data) == entry['size'] and sha(data) == entry['sha256'], 'input hash mismatch: ' + str(path))
    blob = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
    require(blob == entry['expected_git_blob_sha1'], 'input Git blob mismatch: ' + str(path))
    return data


def generate(source):
    manifest_bytes = (source / 'source-manifest.json').read_bytes()
    manifest = json.loads(manifest_bytes)
    require(manifest['origin']['repository'] == 'Tiddybub/3d-assets'
            and manifest['origin']['commit'] == COMMIT, 'unexpected source mirror')
    files = {entry['path']: entry for entry in manifest['files']}
    license_data = source_file(source, files['License.txt'])
    require(b'Creative Commons Zero, CC0' in license_data, 'missing CC0 license')
    outputs = {'LICENSE.txt': license_data}
    models = []
    for name, description in SELECTION.items():
        source_path = 'Models/GLTF format/' + name + '.glb'
        entry = files[source_path]
        original = source_file(source, entry)
        data, optimization = optimize(original)
        require(len(data) <= 100000, name + ' exceeds per-file budget')
        outputs[name + '.glb'] = data
        model = {'name': name, 'description': description, 'file': 'models/' + name + '.glb',
                 **geometry(data), 'bytes': len(data), 'sha256': sha(data),
                 'source': {'path': source_path, 'sha256': sha(original), 'bytes': len(original),
                            'gitBlobSha1': entry['expected_git_blob_sha1']},
                 'optimization': optimization,
                 'normalization': {'yawDeg': 0, 'forward': [0, 0, 1],
                     'note': 'Source orientation retained: front wheel nodes are on +z for cars; nondirectional props use +z by convention. Full source node transforms retained, including root translation.'}}
        models.append(model)
    catalogue = {'schemaVersion': 1, 'pack': 'Kenney Racing Kit 2.0', 'license': 'CC0-1.0',
                 'provenance': {**manifest['origin'], 'sourceManifestSha256': sha(manifest_bytes),
                     'sourceArchiveSha256': None,
                     'archiveNote': 'Inputs are extracted files from the pinned public Git mirror, not an official ZIP; no source archive was acquired or hashed.',
                     'mirrorSourceNote': manifest['original_mirror_provenance']['text'],
                     'licenseSha256': sha(license_data)},
                 'coordinates': {'up': '+y', 'forward': '+z', 'units': 'metres at scale 1',
                     'support': 'raw bounding-box bottom midpoint',
                     'bodyYawDeg': 90, 'bodyMapping': ["x'=z", "y'=y", "z'=-x"],
                     'renderOffset': 'negative rotated raw bounding-box center times scale; translation after yaw and uniform scale',
                     'worldAnchor': 'caller x,y,z is bottom midpoint; body center is x,y+dims[1]/2,z'},
                 'limits': {'maxFileBytes': 100000, 'maxTotalBytes': 3000000, 'maxHullPoints': 64},
                 'models': models}
    outputs['models.json'] = json_bytes(catalogue, pretty=True)
    outputs['SHA256SUMS'] = ''.join(sha(data) + '  ' + name + '\n'
                                  for name, data in sorted(outputs.items())).encode()
    require(sum(map(len, outputs.values())) <= 3000000, 'total asset budget exceeded')
    return outputs, module_text(models).encode()


def check_local():
    catalogue = json.loads((OUTPUT / 'models.json').read_bytes())
    models = catalogue['models']
    require([m['name'] for m in models] == list(SELECTION), 'selection drift')
    expected_files = {'LICENSE.txt', 'models.json', 'SHA256SUMS'} | {m['name'] + '.glb' for m in models}
    require({p.name for p in OUTPUT.iterdir()} == expected_files, 'unexpected or missing model files')
    sums = {}
    for line in (OUTPUT / 'SHA256SUMS').read_text().splitlines():
        digest, name = line.split('  ')
        require(name in expected_files and name not in sums and name != 'SHA256SUMS', 'bad checksum entry')
        sums[name] = digest
        require(matches_sha(OUTPUT / name, digest), 'checksum mismatch: ' + name)
    require(set(sums) == expected_files - {'SHA256SUMS'}, 'incomplete checksums')
    require(matches_sha(OUTPUT / 'LICENSE.txt', catalogue['provenance']['licenseSha256']), 'license hash')
    for model in models:
        data = (OUTPUT / (model['name'] + '.glb')).read_bytes()
        require(len(data) == model['bytes'] <= 100000 and sha(data) == model['sha256'], 'model hash/size')
        require(model['description'] == SELECTION[model['name']], 'description drift')
        for key, value in geometry(data).items():
            require(close(model[key], value), model['name'] + ': geometry drift in ' + key)
    require(sum(p.stat().st_size for p in OUTPUT.iterdir()) <= 3000000, 'total budget')
    require(same_text(MODULE, module_text(models).encode()), 'VeraModels.ets is stale')
    return models


def self_test():
    node = {'translation': [3, 4, 5], 'rotation': [0, math.sqrt(0.5), 0, math.sqrt(0.5)], 'scale': [2, 3, 4]}
    p = transform(node_matrix(node), [1, 1, 1])
    require(max(abs(a-b) for a, b in zip(p, [7, 7, 3])) < 1e-12, 'TRS order')
    parent = node_matrix({'translation': [-1, 2, 8]})
    require(max(abs(a-b) for a, b in zip(transform(matmul(parent, node_matrix(node)), [1, 1, 1]),
                                           [6, 9, 11])) < 1e-12, 'nested transforms')
    points = [(math.sin(i)*math.cos(j), math.sin(i)*math.sin(j), math.cos(i))
              for i in [k*math.pi/16 for k in range(1, 16)]
              for j in [k*math.pi/16 for k in range(32)]]
    reduced = support_polytope(points)
    require(4 <= len(reduced) <= 64 and contains(reduced, points), 'conservative hull reduction')
    require(not contains(list(itertools.product([-0.1, 0.1], repeat=3)), [(1, 0, 0)]), 'containment negative')
    cube = list(itertools.product([-1.0, 1.0], repeat=3))
    binary = b''.join(struct.pack('<3f', *p) for p in cube)
    doc = {'asset': {'version': '2.0'}, 'scene': 0, 'scenes': [{'nodes': [0]}],
           'nodes': [{'matrix': parent, 'children': [1]}, {**node, 'mesh': 0}],
           'meshes': [{'primitives': [{'attributes': {'POSITION': 0}}]}],
           'buffers': [{'byteLength': len(binary)}],
           'bufferViews': [{'buffer': 0, 'byteLength': len(binary)}],
           'accessors': [{'bufferView': 0, 'componentType': 5126, 'type': 'VEC3', 'count': 8}]}
    result = mesh_vertices(doc, binary)
    expected = sorted(transform(matmul(parent, node_matrix(node)), p) for p in cube)
    require(result == expected, 'full node traversal with matrix, rotation and nonuniform scale')
    _, compacted = read_glb(optimize(write_glb(doc, binary))[0])
    require(compacted == binary, 'lossless float accessor repacking')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    self_test()
    if args.check:
        models = check_local()
        if args.source:
            outputs, module = generate(args.source)
            for name, data in outputs.items():
                require((OUTPUT / name).read_bytes() == data, 'non-reproducible output: ' + name)
            require(MODULE.read_bytes() == module, 'non-reproducible module')
        print('Verified', len(models), 'models; checksums, transformed bounds, hull containment, budgets and catalogue API')
    else:
        require(args.source is not None, 'generation requires --source PATH')
        outputs, module = generate(args.source)
        OUTPUT.mkdir(exist_ok=True)
        for name, data in outputs.items():
            (OUTPUT / name).write_bytes(data)
        MODULE.write_bytes(module)
        check_local()
        print('Generated', len(SELECTION), 'models;', sum(map(len, outputs.values())), 'asset bytes')


if __name__ == '__main__':
    main()
