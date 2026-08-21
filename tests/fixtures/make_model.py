#!/usr/bin/env python3
"""Build a small rigged, textured, animated GLB for the inbox pipeline's tests.

    python3 tests/fixtures/make_model.py /tmp/quadruped.glb

Generated rather than committed, because a binary blob in git is a thing
nobody can review. It is deliberately the awkward case: indexed triangles, a
PNG packed into the BIN chunk, a skin whose joints are nested two deep, and
two animations at different lengths -- everything tools/glb.py claims to read.
"""

import json
import os
import struct
import sys
import zlib

# A four-legged animal, roughly a metre long, standing on the ground plane.
# glTF axes: Y up, -Z forward, so it faces `down` on this project's grid with
# no rotation, which is what tools/sprite_bake.py assumes by default.
PARTS = [
    # (name, centre, half-extent, colour index, joint)
    ("body",     (0.00, 0.52, 0.00), (0.13, 0.13, 0.38), 0, 0),
    ("head",     (0.00, 0.66, -0.46), (0.11, 0.11, 0.12), 1, 0),
    ("snout",    (0.00, 0.60, -0.62), (0.05, 0.05, 0.06), 2, 0),
    ("tail",     (0.00, 0.60, 0.48), (0.04, 0.04, 0.14), 0, 0),
    ("leg_fl",   (-0.09, 0.20, -0.26), (0.04, 0.20, 0.04), 3, 1),
    ("leg_fr",   (0.09, 0.20, -0.26), (0.04, 0.20, 0.04), 3, 2),
    ("leg_bl",   (-0.09, 0.20, 0.24), (0.04, 0.20, 0.04), 3, 3),
    ("leg_br",   (0.09, 0.20, 0.24), (0.04, 0.20, 0.04), 3, 4),
]

COLOURS = [(176, 138, 88), (150, 116, 74), (232, 226, 210), (74, 58, 42)]

# joint 0 is the body; the four legs hang off it and are what the walk swings.
JOINTS = [
    ("root", (0.0, 0.52, 0.0), [1, 2, 3, 4]),
    ("fl", (-0.09, 0.40, -0.26), []),
    ("fr", (0.09, 0.40, -0.26), []),
    ("bl", (-0.09, 0.40, 0.24), []),
    ("br", (0.09, 0.40, 0.24), []),
]

FACES = [
    ((0, 0, 1), [(-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)]),
    ((0, 0, -1), [(1, -1, -1), (-1, -1, -1), (-1, 1, -1), (1, 1, -1)]),
    ((1, 0, 0), [(1, -1, 1), (1, -1, -1), (1, 1, -1), (1, 1, 1)]),
    ((-1, 0, 0), [(-1, -1, -1), (-1, -1, 1), (-1, 1, 1), (-1, 1, -1)]),
    ((0, 1, 0), [(-1, 1, 1), (1, 1, 1), (1, 1, -1), (-1, 1, -1)]),
    ((0, -1, 0), [(-1, -1, -1), (1, -1, -1), (1, -1, 1), (-1, -1, 1)]),
]


def png(colours):
    """A 1-pixel-tall strip, one pixel per part colour."""
    w, h = len(colours), 1
    raw = bytearray([0])
    for r, g, b in colours:
        raw += bytes((r, g, b, 255))

    def chunk(tag, data):
        out = struct.pack(">I", len(data)) + tag + data
        return out + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def build():
    positions, normals, uvs, joints, weights, indices = [], [], [], [], [], []
    for _name, centre, half, colour, joint in PARTS:
        u = (colour + 0.5) / len(COLOURS)
        for normal, corners in FACES:
            base = len(positions)
            for corner in corners:
                positions.append(tuple(c + h * s for c, h, s
                                       in zip(centre, half, corner)))
                normals.append(normal)
                uvs.append((u, 0.5))
                joints.append((joint, 0, 0, 0))
                weights.append((1.0, 0.0, 0.0, 0.0))
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
    return positions, normals, uvs, joints, weights, indices


class Blob(object):
    """Accumulates the BIN chunk and hands back bufferView indices."""

    def __init__(self):
        self.data = bytearray()
        self.views = []

    def add(self, payload, stride=None):
        while len(self.data) % 4:
            self.data.append(0)
        offset = len(self.data)
        self.data += payload
        view = {"buffer": 0, "byteOffset": offset, "byteLength": len(payload)}
        if stride:
            view["byteStride"] = stride
        self.views.append(view)
        return len(self.views) - 1


def accessor(blob, accessors, values, kind, component, fmt, minmax=False):
    count = len(values)
    packed = bytearray()
    for v in values:
        packed += struct.pack("<" + fmt, *(v if isinstance(v, tuple) else (v,)))
    view = blob.add(bytes(packed))
    spec = {"bufferView": view, "componentType": component,
            "count": count, "type": kind}
    if minmax:
        rows = [v if isinstance(v, tuple) else (v,) for v in values]
        cols = list(zip(*rows))
        spec["min"] = [min(c) for c in cols]
        spec["max"] = [max(c) for c in cols]
    accessors.append(spec)
    return len(accessors) - 1


def main(out_path):
    positions, normals, uvs, joints, weights, indices = build()
    blob, accessors = Blob(), []

    a_pos = accessor(blob, accessors, positions, "VEC3", 5126, "fff", minmax=True)
    a_nrm = accessor(blob, accessors, [tuple(float(c) for c in n) for n in normals],
                     "VEC3", 5126, "fff")
    a_uv = accessor(blob, accessors, uvs, "VEC2", 5126, "ff")
    a_jnt = accessor(blob, accessors, joints, "VEC4", 5123, "HHHH")
    a_wgt = accessor(blob, accessors, weights, "VEC4", 5126, "ffff")
    a_idx = accessor(blob, accessors, indices, "SCALAR", 5125, "I")

    # Inverse bind matrices: joints only translate, so the inverse is -t.
    binds = []
    for _name, origin, _children in JOINTS:
        binds.append((1.0, 0.0, 0.0, 0.0,
                      0.0, 1.0, 0.0, 0.0,
                      0.0, 0.0, 1.0, 0.0,
                      -origin[0], -origin[1], -origin[2], 1.0))
    a_bind = accessor(blob, accessors, binds, "MAT4", 5126, "f" * 16)

    image_view = blob.add(png(COLOURS))

    nodes = [{"name": "quadruped", "mesh": 0, "skin": 0}]
    joint_base = len(nodes)
    for name, origin, children in JOINTS:
        parent = JOINTS[0][1] if name != "root" else (0.0, 0.0, 0.0)
        nodes.append({
            "name": name,
            "translation": [origin[i] - parent[i] for i in range(3)],
            "children": [joint_base + c for c in children] or None,
        })
    for node in nodes:
        if node.get("children") is None:
            node.pop("children", None)

    # Two animations of different lengths, so clip planning has to do real work.
    times = [0.0, 0.25, 0.5, 0.75, 1.0]
    a_time = accessor(blob, accessors, times, "SCALAR", 5126, "f", minmax=True)
    breathe = [(0.0, 0.0, 0.0, 1.0), (0.02, 0.0, 0.0, 0.9998),
               (0.0, 0.0, 0.0, 1.0), (-0.02, 0.0, 0.0, 0.9998),
               (0.0, 0.0, 0.0, 1.0)]
    a_breathe = accessor(blob, accessors, breathe, "VEC4", 5126, "ffff")

    animations = [{
        "name": "Idle",
        "samplers": [{"input": a_time, "output": a_breathe, "interpolation": "LINEAR"}],
        "channels": [{"sampler": 0, "target": {"node": joint_base, "path": "rotation"}}],
    }]

    swings, channels, samplers = [], [], []
    for leg in range(4):
        phase = 1.0 if leg in (0, 3) else -1.0
        keys = []
        for t in times:
            angle = 0.35 * phase * (1.0 if t in (0.25,) else
                                    (-1.0 if t == 0.75 else 0.0))
            s = angle / 2.0
            keys.append((s, 0.0, 0.0, (1.0 - s * s) ** 0.5))
        swings.append(accessor(blob, accessors, keys, "VEC4", 5126, "ffff"))
    for leg in range(4):
        samplers.append({"input": a_time, "output": swings[leg],
                         "interpolation": "LINEAR"})
        channels.append({"sampler": leg,
                         "target": {"node": joint_base + 1 + leg, "path": "rotation"}})
    animations.append({"name": "Walk", "samplers": samplers, "channels": channels})

    gltf = {
        "asset": {"version": "2.0", "generator": "port-azure test fixture"},
        "scene": 0,
        "scenes": [{"nodes": [0, joint_base]}],
        "nodes": nodes,
        "meshes": [{"primitives": [{
            "attributes": {"POSITION": a_pos, "NORMAL": a_nrm, "TEXCOORD_0": a_uv,
                           "JOINTS_0": a_jnt, "WEIGHTS_0": a_wgt},
            "indices": a_idx, "material": 0, "mode": 4,
        }]}],
        "skins": [{"inverseBindMatrices": a_bind,
                   "joints": [joint_base + i for i in range(len(JOINTS))],
                   "skeleton": joint_base}],
        "materials": [{
            "name": "pelt",
            "pbrMetallicRoughness": {
                "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
                "baseColorTexture": {"index": 0},
            },
        }],
        "textures": [{"source": 0}],
        "images": [{"name": "pelt", "bufferView": image_view, "mimeType": "image/png"}],
        "samplers": [],
        "buffers": [{"byteLength": len(blob.data)}],
        "bufferViews": blob.views,
        "accessors": accessors,
        "animations": animations,
    }
    gltf.pop("samplers")

    payload = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    payload += b" " * (-len(payload) % 4)
    binary = bytes(blob.data)
    binary += b"\x00" * (-len(binary) % 4)
    out = struct.pack("<III", 0x46546C67, 2,
                      12 + 8 + len(payload) + 8 + len(binary))
    out += struct.pack("<II", len(payload), 0x4E4F534A) + payload
    out += struct.pack("<II", len(binary), 0x004E4942) + binary

    directory = os.path.dirname(os.path.abspath(out_path))
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(out_path, "wb") as f:
        f.write(out)
    print("wrote %s (%d bytes, %d triangles)"
          % (out_path, len(out), len(indices) // 3))
    return out_path


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "quadruped.glb")
