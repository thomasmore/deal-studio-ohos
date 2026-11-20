import argparse
import binascii
import hashlib
import json
import math
import struct
import sys
import tempfile
import zlib
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
JSON_CHUNK = 0x4E4F534A
BIN_CHUNK = 0x004E4942


def require(condition, message):
    if not condition:
        raise ValueError(message)


def checker_png():
    def chunk(kind, payload):
        return (struct.pack('>I', len(payload)) + kind + payload
                + struct.pack('>I', binascii.crc32(kind + payload) & 0xFFFFFFFF))

    rows = bytearray()
    for y in range(16):
        rows.append(0)
        for x in range(16):
            rows.extend((245, 240, 220, 255) if (x // 4 + y // 4) % 2 == 0
                        else (30, 45, 65, 255))
    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>2I5B', 16, 16, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(bytes(rows), 9)) + chunk(b'IEND', b''))


def box_faces():
    return [
        [(-.5, -.5, .5), (.5, -.5, .5), (.5, .5, .5), (-.5, .5, .5)],
        [(.5, -.5, -.5), (-.5, -.5, -.5), (-.5, .5, -.5), (.5, .5, -.5)],
        [(.5, -.5, .5), (.5, -.5, -.5), (.5, .5, -.5), (.5, .5, .5)],
        [(-.5, -.5, -.5), (-.5, -.5, .5), (-.5, .5, .5), (-.5, .5, -.5)],
        [(-.5, .5, .5), (.5, .5, .5), (.5, .5, -.5), (-.5, .5, -.5)],
        [(-.5, -.5, -.5), (.5, -.5, -.5), (.5, -.5, .5), (-.5, -.5, .5)],
    ]


def pyramid_faces():
    base = [(-.5, 0, -.5), (.5, 0, -.5), (.5, 0, .5), (-.5, 0, .5)]
    return [base] + [[base[(i + 1) % 4], base[i], (0, 1, 0)] for i in range(4)]


def cylinder_faces():
    ring = [(.5 * math.cos(i * math.tau / 12), 0,
             .5 * math.sin(i * math.tau / 12)) for i in range(12)]
    top = [(x, 1, z) for x, _, z in ring]
    return [ring, list(reversed(top))] + [
        [ring[(i + 1) % 12], ring[i], top[i], top[(i + 1) % 12]]
        for i in range(12)
    ]


class Fixture:
    def __init__(self, name):
        self.data = bytearray()
        self.doc = {
            'asset': {'version': '2.0', 'generator': 'Vera synthetic world spike'},
            'scene': 0,
            'scenes': [{'name': name, 'nodes': [0]}],
            'nodes': [{'name': name, 'children': []}],
            'meshes': [], 'materials': [], 'accessors': [], 'bufferViews': [],
        }

    def view(self, payload, target=None):
        self.data.extend(b'\0' * (-len(self.data) % 4))
        view = {'buffer': 0, 'byteOffset': len(self.data), 'byteLength': len(payload)}
        if target is not None:
            view['target'] = target
        self.data.extend(payload)
        self.doc['bufferViews'].append(view)
        return len(self.doc['bufferViews']) - 1

    def accessor(self, values, kind, component=5126, target=34962):
        width = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3}[kind]
        flat = [v for row in values for v in row]
        code = 'f' if component == 5126 else 'H'
        payload = struct.pack('<' + code * len(flat), *flat)
        stored = list(struct.iter_unpack('<' + code * width, payload))
        accessor = {
            'bufferView': self.view(payload, target), 'componentType': component,
            'count': len(values), 'type': kind,
            'min': [min(row[i] for row in stored) for i in range(width)],
            'max': [max(row[i] for row in stored) for i in range(width)],
        }
        self.doc['accessors'].append(accessor)
        return len(self.doc['accessors']) - 1

    def material(self, name, color, metallic, roughness, checker=False):
        pbr = {'baseColorFactor': [*color, 1], 'metallicFactor': metallic,
               'roughnessFactor': roughness}
        if checker:
            self.doc['images'] = [{'name': 'Authored checker', 'mimeType': 'image/png',
                                   'bufferView': self.view(checker_png())}]
            self.doc['samplers'] = [{'magFilter': 9728, 'minFilter': 9728,
                                     'wrapS': 10497, 'wrapT': 10497}]
            self.doc['textures'] = [{'sampler': 0, 'source': 0}]
            pbr['baseColorTexture'] = {'index': 0, 'texCoord': 0}
        self.doc['materials'].append({'name': name, 'pbrMetallicRoughness': pbr})
        return len(self.doc['materials']) - 1

    def mesh(self, name, faces, material, textured=False):
        positions, normals, uvs, indices = [], [], [], []
        for face in faces:
            a = [face[1][i] - face[0][i] for i in range(3)]
            b = [face[2][i] - face[0][i] for i in range(3)]
            normal = (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2],
                      a[0] * b[1] - a[1] * b[0])
            length = math.sqrt(sum(v * v for v in normal))
            normal = tuple(v / length for v in normal)
            start = len(positions)
            positions.extend(face)
            normals.extend([normal] * len(face))
            uvs.extend([(0, 0), (1, 0), (1, 1), (0, 1)][:len(face)])
            for i in range(1, len(face) - 1):
                indices.extend([(start,), (start + i,), (start + i + 1,)])
        attributes = {'POSITION': self.accessor(positions, 'VEC3'),
                      'NORMAL': self.accessor(normals, 'VEC3')}
        if textured:
            require(len(uvs) == len(positions), 'Textured faces must be triangles or quads')
            attributes['TEXCOORD_0'] = self.accessor(uvs, 'VEC2')
        self.doc['meshes'].append({'name': name, 'primitives': [{
            'attributes': attributes, 'indices': self.accessor(indices, 'SCALAR', 5123, 34963),
            'material': material, 'mode': 4,
        }]})
        return len(self.doc['meshes']) - 1

    def node(self, name, mesh=None, translation=None, scale=None, parent=0):
        node = {'name': name}
        for key, value in (('mesh', mesh), ('translation', translation), ('scale', scale)):
            if value is not None:
                node[key] = value
        self.doc['nodes'].append(node)
        index = len(self.doc['nodes']) - 1
        self.doc['nodes'][parent].setdefault('children', []).append(index)
        return index

    def encode(self):
        self.doc['buffers'] = [{'byteLength': len(self.data)}]
        text = json.dumps(self.doc, sort_keys=True, separators=(',', ':'),
                          allow_nan=False).encode('utf-8')
        text += b' ' * (-len(text) % 4)
        binary = bytes(self.data) + b'\0' * (-len(self.data) % 4)
        return (struct.pack('<3I', 0x46546C67, 2, 28 + len(text) + len(binary))
                + struct.pack('<2I', len(text), JSON_CHUNK) + text
                + struct.pack('<2I', len(binary), BIN_CHUNK) + binary)


def make_fixtures():
    fixtures = []
    for name, faces, color, metallic, roughness, translation in (
        ('Coral cube', box_faces(), (.85, .16, .09), 0, .9, (0, .5, 0)),
        ('Gold pyramid', pyramid_faces(), (.9, .58, .12), 1, .22, None),
        ('Blue cylinder', cylinder_faces(), (.04, .3, .8), .35, .45, None),
    ):
        fixture = Fixture(name)
        material = fixture.material(name, color, metallic, roughness)
        fixture.node(name + ' mesh', fixture.mesh(name, faces, material), translation)
        fixtures.append(fixture.encode())

    robot = Fixture('Nested robot')
    robot.doc['nodes'][0]['rotation'] = [0, math.sqrt(.5), 0, math.sqrt(.5)]
    meshes = []
    for name, color, metallic, roughness in (
        ('Mint body', (.15, .75, .5), .1, .65),
        ('Navy limbs', (.025, .06, .15), .65, .3),
        ('Amber head', (1, .55, .06), 0, .8),
    ):
        material = robot.material(name, color, metallic, roughness)
        meshes.append(robot.mesh(name, box_faces(), material))
    body = robot.node('Body group', translation=(0, .55, 0))
    robot.node('Torso', meshes[0], scale=(.5, .4, .32), parent=body)
    head = robot.node('Head group', translation=(0, .325, 0), parent=body)
    robot.node('Head', meshes[2], scale=(.3, .25, .3), parent=head)
    limbs = robot.node('Limbs group')
    for side, x in (('Left', -.35), ('Right', .35)):
        robot.node(side + ' arm', meshes[1], (x, .55, 0), (.2, .4, .25), limbs)
    for side, x in (('Left', -.16), ('Right', .16)):
        robot.node(side + ' foot', meshes[1], (x, .175, 0), (.22, .35, .4), limbs)
    fixtures.append(robot.encode())

    checker = Fixture('Checker pedestal')
    tile = checker.material('White checker texture', (1, 1, 1), 0, .7, checker=True)
    base = checker.material('Purple metallic base', (.35, .06, .6), .8, .25)
    checker.node('Checker cube', checker.mesh('UV cube', box_faces(), tile, textured=True),
                 (0, .6, 0), (.8, .8, .8))
    checker.node('Plinth', checker.mesh('Plinth', box_faces(), base), (0, .1, 0), (1, .2, 1))
    fixtures.append(checker.encode())
    return fixtures


def read_glb(payload):
    require(len(payload) >= 28, 'Truncated GLB')
    magic, version, length = struct.unpack_from('<3I', payload)
    require((magic, version, length) == (0x46546C67, 2, len(payload)), 'Invalid GLB header')
    chunks = []
    offset = 12
    while offset < length:
        require(offset + 8 <= length, 'Truncated chunk header')
        size, kind = struct.unpack_from('<2I', payload, offset)
        offset += 8
        require(size % 4 == 0 and offset + size <= length, 'Invalid chunk range/alignment')
        chunks.append((kind, payload[offset:offset + size]))
        offset += size
    require([kind for kind, _ in chunks] == [JSON_CHUNK, BIN_CHUNK], 'Expected JSON and BIN')
    doc = json.loads(chunks[0][1])
    require(doc['asset']['version'] == '2.0', 'Expected glTF 2.0')
    require(not doc.get('extensionsRequired'), 'Extensions are not supported by these fixtures')
    binary = chunks[1][1]
    require(len(doc['buffers']) == 1 and 'uri' not in doc['buffers'][0], 'Buffer must be embedded')
    used = doc['buffers'][0]['byteLength']
    require(0 < used <= len(binary) and len(binary) - used <= 3, 'Invalid BIN size')
    require(not any(binary[used:]), 'Invalid BIN padding')
    return doc, binary[:used]


def validate_png(payload):
    require(payload[:8] == b'\x89PNG\r\n\x1a\n', 'Invalid PNG signature')
    offset, chunks = 8, []
    while offset < len(payload):
        require(offset + 12 <= len(payload), 'Truncated PNG chunk')
        size = struct.unpack_from('>I', payload, offset)[0]
        kind = payload[offset + 4:offset + 8]
        end = offset + 8 + size
        require(end + 4 <= len(payload), 'PNG chunk out of range')
        body = payload[offset + 8:end]
        crc = struct.unpack_from('>I', payload, end)[0]
        require(crc == binascii.crc32(kind + body) & 0xFFFFFFFF, 'PNG CRC mismatch')
        chunks.append((kind, body))
        offset = end + 4
    require([kind for kind, _ in chunks] == [b'IHDR', b'IDAT', b'IEND'], 'Invalid PNG chunks')
    require(struct.unpack('>2I5B', chunks[0][1]) == (16, 16, 8, 6, 0, 0, 0), 'Invalid PNG format')
    pixels = zlib.decompress(chunks[1][1])
    require(len(pixels) == 16 * 65 and chunks[2][1] == b'', 'Invalid PNG data size')
    colors = set()
    for y in range(16):
        require(pixels[y * 65] == 0, 'Expected unfiltered PNG rows')
        for x in range(16):
            color = tuple(pixels[y * 65 + 1 + x * 4:y * 65 + 5 + x * 4])
            expected = ((245, 240, 220, 255) if (x // 4 + y // 4) % 2 == 0
                        else (30, 45, 65, 255))
            require(color == expected, 'Invalid checker pixel')
            colors.add(color)
    require(len(colors) == 2, 'Expected two checker colors')


def transform(point, node):
    scaled = [v * s for v, s in zip(point, node.get('scale', (1, 1, 1)))]
    x, y, z, w = node.get('rotation', (0, 0, 0, 1))
    require(math.isclose(x * x + y * y + z * z + w * w, 1, abs_tol=1e-6),
            'Invalid rotation quaternion')
    q = (x, y, z)
    dot = sum(a * b for a, b in zip(q, scaled))
    cross = (y * scaled[2] - z * scaled[1], z * scaled[0] - x * scaled[2],
             x * scaled[1] - y * scaled[0])
    return tuple(2 * dot * q[i] + (2 * w * w - 1) * scaled[i] + 2 * w * cross[i] + t
                 for i, t in enumerate(node.get('translation', (0, 0, 0))))


def validate(payload, fixture_index):
    doc, binary = read_glb(payload)
    views = doc['bufferViews']
    for view in views:
        start, size = view.get('byteOffset', 0), view['byteLength']
        require(view['buffer'] == 0 and start >= 0 and size > 0 and start % 4 == 0
                and start + size <= len(binary), 'Invalid bufferView range')
    arrays = []
    for accessor in doc['accessors']:
        view = views[accessor['bufferView']]
        code, size = {5126: ('f', 4), 5123: ('H', 2)}[accessor['componentType']]
        width = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3}[accessor['type']]
        offset, count = accessor.get('byteOffset', 0), accessor['count']
        stride = view.get('byteStride', size * width)
        require(count > 0 and offset >= 0 and offset % size == 0 and stride >= size * width
                and stride % size == 0
                and offset + (count - 1) * stride + size * width <= view['byteLength'],
                'Invalid accessor range/alignment')
        values = [struct.unpack_from('<' + code * width, binary,
                                     view.get('byteOffset', 0) + offset + i * stride)
                  for i in range(count)]
        require(all(math.isfinite(v) for row in values for v in row), 'Nonfinite accessor')
        for key, operation in (('min', min), ('max', max)):
            require(accessor[key] == [operation(row[i] for row in values) for i in range(width)],
                    'Incorrect accessor bounds')
        arrays.append(values)
    for material in doc['materials']:
        pbr = material['pbrMetallicRoughness']
        require(all(0 <= v <= 1 for v in pbr['baseColorFactor'])
                and len(pbr['baseColorFactor']) == 4
                and 0 <= pbr['metallicFactor'] <= 1 and 0 <= pbr['roughnessFactor'] <= 1,
                'Invalid metallic-roughness material')
        if 'baseColorTexture' in pbr:
            texture = doc['textures'][pbr['baseColorTexture']['index']]
            require(pbr['baseColorTexture'].get('texCoord', 0) == 0, 'Expected UV set 0')
            require(0 <= texture['source'] < len(doc['images']), 'Invalid texture image')
            require(0 <= texture['sampler'] < len(doc['samplers']), 'Invalid sampler')
    for mesh in doc['meshes']:
        for primitive in mesh['primitives']:
            attributes = primitive['attributes']
            pos, normals = arrays[attributes['POSITION']], arrays[attributes['NORMAL']]
            require(doc['accessors'][attributes['POSITION']]['type'] == 'VEC3'
                    and doc['accessors'][attributes['NORMAL']]['type'] == 'VEC3',
                    'Expected VEC3 positions/normals')
            require(len(pos) == len(normals), 'Normal count mismatch')
            require(all(math.isclose(sum(v * v for v in n), 1, abs_tol=1e-6) for n in normals),
                    'Nonunit normal')
            index_accessor = doc['accessors'][primitive['indices']]
            indices = [row[0] for row in arrays[primitive['indices']]]
            require(primitive.get('mode', 4) == 4 and len(indices) % 3 == 0
                    and index_accessor['componentType'] == 5123
                    and index_accessor['type'] == 'SCALAR'
                    and all(0 <= i < len(pos) for i in indices), 'Invalid triangle indices')
            for start in range(0, len(indices), 3):
                i, j, k = indices[start:start + 3]
                a = [pos[j][axis] - pos[i][axis] for axis in range(3)]
                b = [pos[k][axis] - pos[i][axis] for axis in range(3)]
                cross = (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2],
                         a[0] * b[1] - a[1] * b[0])
                require(sum(c * n for c, n in zip(cross, normals[i])) > 1e-8,
                        'Degenerate triangle or winding/normal mismatch')
            require(0 <= primitive['material'] < len(doc['materials']), 'Invalid material index')
            pbr = doc['materials'][primitive['material']]['pbrMetallicRoughness']
            if 'baseColorTexture' in pbr:
                uv = attributes['TEXCOORD_0']
                require(doc['accessors'][uv]['type'] == 'VEC2' and len(arrays[uv]) == len(pos),
                        'Invalid texture coordinates')
                require(all(0 <= v <= 1 for row in arrays[uv] for v in row), 'UV out of range')
    images = doc.get('images', [])
    require(len(images) == (1 if fixture_index == 4 else 0), 'Unexpected image count')
    for image in images:
        require(image['mimeType'] == 'image/png' and 'uri' not in image, 'Image must be embedded PNG')
        view = views[image['bufferView']]
        start = view.get('byteOffset', 0)
        validate_png(binary[start:start + view['byteLength']])
    points, seen = [], set()

    def visit(index, ancestors):
        require(0 <= index < len(doc['nodes']) and index not in seen, 'Invalid node tree')
        seen.add(index)
        node = doc['nodes'][index]
        chain = [node, *ancestors]
        if 'mesh' in node:
            require(0 <= node['mesh'] < len(doc['meshes']), 'Invalid mesh index')
            for primitive in doc['meshes'][node['mesh']]['primitives']:
                for point in arrays[primitive['attributes']['POSITION']]:
                    for parent in chain:
                        point = transform(point, parent)
                    points.append(point)
        for child in node.get('children', []):
            visit(child, chain)

    for root in doc['scenes'][doc['scene']]['nodes']:
        visit(root, [])
    require(len(seen) == len(doc['nodes']) and points, 'Unreachable nodes or empty scene')
    low = [min(p[i] for p in points) for i in range(3)]
    high = [max(p[i] for p in points) for i in range(3)]
    require(abs(low[1]) < 1e-6 and abs(low[0] + high[0]) < 1e-6
            and abs(low[2] + high[2]) < 1e-6, 'Expected centered x/z and bottom y=0')
    require(math.isclose(max(b - a for a, b in zip(low, high)), 1, abs_tol=1e-6),
            'Expected largest dimension of one meter')
    require(len(payload) < 16 * 1024, 'Fixture exceeds 16 KiB')
    return (f"{doc['scenes'][0]['name']}: {len(payload)} bytes, "
            f"{len(doc['nodes'])} nodes, {len(doc['meshes'])} meshes, "
            f"{len(doc['materials'])} materials, {len(images)} PNG; "
            f"bounds {tuple(round(v, 3) for v in low)}..{tuple(round(v, 3) for v in high)}")


def host_directory(value, output=False):
    directory = Path(value).expanduser().resolve(strict=True)
    require(directory.is_dir(), f'Expected an existing host directory: {directory}')
    require(directory != REPO_ROOT and REPO_ROOT not in directory.parents,
            'Fixture directories must be outside the product repository')
    if output:
        temporary = Path(tempfile.gettempdir()).resolve()
        require(directory == temporary or temporary in directory.parents,
                f'Output must be inside the host temporary directory: {temporary}')
    return directory


def main():
    parser = argparse.ArgumentParser(description='Host-only synthetic phase-0 GLBs; default self-check writes nothing')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--check', nargs='?', const='', metavar='HOST_DIR',
                      help='Validate an explicit existing host directory, or self-check in memory; no writes')
    mode.add_argument('--output', metavar='HOST_TMP_DIR',
                      help='Write fixtures only to an explicit existing host temporary directory outside the repository')
    args = parser.parse_args()
    directory = None
    if args.output is not None:
        directory = host_directory(args.output, output=True)
    elif args.check:
        directory = host_directory(args.check)
    fixtures = make_fixtures()
    require(fixtures == make_fixtures(), 'Nondeterministic generation')
    require(len(fixtures) == 5, 'Expected five fixtures')
    summaries = [validate(payload, index) for index, payload in enumerate(fixtures)]
    if args.output is not None:
        for index in range(len(fixtures)):
            path = directory / f'world-spike-{index}.glb'
            require(not path.is_symlink() and (not path.exists() or path.is_file()),
                    f'Output must be a regular file, not a symlink or directory: {path}')
    for index, expected in enumerate(fixtures):
        name = f'world-spike-{index}.glb'
        if directory is not None:
            path = directory / name
            if args.output is not None:
                path.write_bytes(expected)
            else:
                actual = path.read_bytes()
                validate(actual, index)
                require(actual == expected, f'{name}: differs from deterministic regeneration')
        digest = hashlib.sha256(expected).hexdigest()
        action = 'WROTE' if args.output is not None else 'OK'
        print(f'{action} {name}: {summaries[index]}; sha256={digest}')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, IndexError, TypeError, struct.error, zlib.error) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        sys.exit(1)
