#!/usr/bin/env python3
"""A glTF 2.0 / GLB reader: geometry, materials, skins and animation.

    model = glb.load("inbox/coyote.glb")
    pose  = model.pose(animation=0, t=0.4)   # world-space triangles at a time

Standard library only, like everything else in tools/. That is not asceticism:
the whole point of this repository is that a change can be made, validated and
shipped by an agent with no desktop, and a pipeline that needs `pip install`
is a pipeline that stops working the first time a runner is rebuilt.

What is supported is what real exporters emit -- Blender, Meshy, Sketchfab:
GLB and .gltf, embedded/base64/sidecar buffers, interleaved accessors, sparse
accessors, node hierarchies, skinned meshes, and TRS animation with STEP,
LINEAR and CUBICSPLINE interpolation. What is not supported fails loudly with
the fix in the message, because a model that silently loses its skeleton is
much worse than one that refuses to load.

Coordinates are glTF's: Y up, right-handed. Turning that into this project's
grid is tools/sprite_bake.py's job, not this module's.
"""

import base64
import json
import math
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from pixel import decode_png

# glTF component types -> (struct code, byte size)
COMPONENTS = {
    5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2),
    5123: ("H", 2), 5125: ("I", 4), 5126: ("f", 4),
}
COUNTS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16}

GLB_MAGIC = 0x46546C67
CHUNK_JSON = 0x4E4F534A
CHUNK_BIN = 0x004E4942


class ModelError(Exception):
    """Something about the file we cannot honour. The message is the fix."""


# --------------------------------------------------------------------------
# 4x4 matrices, flat and column-major, exactly as glTF stores them
# --------------------------------------------------------------------------

IDENTITY = (1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            0.0, 0.0, 0.0, 1.0)


def mat_mul(a, b):
    """a * b, both column-major. Applying the result applies b, then a."""
    out = [0.0] * 16
    for col in range(4):
        c0, c1, c2, c3 = b[col * 4], b[col * 4 + 1], b[col * 4 + 2], b[col * 4 + 3]
        for row in range(4):
            out[col * 4 + row] = (a[row] * c0 + a[4 + row] * c1
                                  + a[8 + row] * c2 + a[12 + row] * c3)
    return tuple(out)


def mat_point(m, p):
    x, y, z = p
    return (m[0] * x + m[4] * y + m[8] * z + m[12],
            m[1] * x + m[5] * y + m[9] * z + m[13],
            m[2] * x + m[6] * y + m[10] * z + m[14])


def mat_dir(m, v):
    """Transform a direction: the rotation/scale part only.

    Non-uniform scale would want the inverse transpose, but exporters that
    scale a rig unevenly are rare and the error shows up as slightly wrong
    shading rather than wrong geometry -- and we renormalise afterwards.
    """
    x, y, z = v
    return (m[0] * x + m[4] * y + m[8] * z,
            m[1] * x + m[5] * y + m[9] * z,
            m[2] * x + m[6] * y + m[10] * z)


def trs_matrix(t, r, s):
    """Compose translation, a (x, y, z, w) quaternion and scale."""
    x, y, z, w = r
    n = math.sqrt(x * x + y * y + z * z + w * w)
    if n > 0.0:
        x, y, z, w = x / n, y / n, z / n, w / n
    xx, yy, zz = x * x, y * y, z * z
    xy, xz, yz = x * y, x * z, y * z
    wx, wy, wz = w * x, w * y, w * z
    sx, sy, sz = s
    return (
        (1 - 2 * (yy + zz)) * sx, (2 * (xy + wz)) * sx, (2 * (xz - wy)) * sx, 0.0,
        (2 * (xy - wz)) * sy, (1 - 2 * (xx + zz)) * sy, (2 * (yz + wx)) * sy, 0.0,
        (2 * (xz + wy)) * sz, (2 * (yz - wx)) * sz, (1 - 2 * (xx + yy)) * sz, 0.0,
        t[0], t[1], t[2], 1.0,
    )


def mat_invert(m):
    """Full 4x4 inverse. Only needed for inverse bind matrices we must trust."""
    a = list(m)
    inv = [0.0] * 16
    inv[0] = (a[5] * a[10] * a[15] - a[5] * a[11] * a[14] - a[9] * a[6] * a[15]
              + a[9] * a[7] * a[14] + a[13] * a[6] * a[11] - a[13] * a[7] * a[10])
    inv[4] = (-a[4] * a[10] * a[15] + a[4] * a[11] * a[14] + a[8] * a[6] * a[15]
              - a[8] * a[7] * a[14] - a[12] * a[6] * a[11] + a[12] * a[7] * a[10])
    inv[8] = (a[4] * a[9] * a[15] - a[4] * a[11] * a[13] - a[8] * a[5] * a[15]
              + a[8] * a[7] * a[13] + a[12] * a[5] * a[11] - a[12] * a[7] * a[9])
    inv[12] = (-a[4] * a[9] * a[14] + a[4] * a[10] * a[13] + a[8] * a[5] * a[14]
               - a[8] * a[6] * a[13] - a[12] * a[5] * a[10] + a[12] * a[6] * a[9])
    inv[1] = (-a[1] * a[10] * a[15] + a[1] * a[11] * a[14] + a[9] * a[2] * a[15]
              - a[9] * a[3] * a[14] - a[13] * a[2] * a[11] + a[13] * a[3] * a[10])
    inv[5] = (a[0] * a[10] * a[15] - a[0] * a[11] * a[14] - a[8] * a[2] * a[15]
              + a[8] * a[3] * a[14] + a[12] * a[2] * a[11] - a[12] * a[3] * a[10])
    inv[9] = (-a[0] * a[9] * a[15] + a[0] * a[11] * a[13] + a[8] * a[1] * a[15]
              - a[8] * a[3] * a[13] - a[12] * a[1] * a[11] + a[12] * a[3] * a[9])
    inv[13] = (a[0] * a[9] * a[14] - a[0] * a[10] * a[13] - a[8] * a[1] * a[14]
               + a[8] * a[2] * a[13] + a[12] * a[1] * a[10] - a[12] * a[2] * a[9])
    inv[2] = (a[1] * a[6] * a[15] - a[1] * a[7] * a[14] - a[5] * a[2] * a[15]
              + a[5] * a[3] * a[14] + a[13] * a[2] * a[7] - a[13] * a[3] * a[6])
    inv[6] = (-a[0] * a[6] * a[15] + a[0] * a[7] * a[14] + a[4] * a[2] * a[15]
              - a[4] * a[3] * a[14] - a[12] * a[2] * a[7] + a[12] * a[3] * a[6])
    inv[10] = (a[0] * a[5] * a[15] - a[0] * a[7] * a[13] - a[4] * a[1] * a[15]
               + a[4] * a[3] * a[13] + a[12] * a[1] * a[7] - a[12] * a[3] * a[5])
    inv[14] = (-a[0] * a[5] * a[14] + a[0] * a[6] * a[13] + a[4] * a[1] * a[14]
               - a[4] * a[2] * a[13] - a[12] * a[1] * a[6] + a[12] * a[2] * a[5])
    inv[3] = (-a[1] * a[6] * a[11] + a[1] * a[7] * a[10] + a[5] * a[2] * a[11]
              - a[5] * a[3] * a[10] - a[9] * a[2] * a[7] + a[9] * a[3] * a[6])
    inv[7] = (a[0] * a[6] * a[11] - a[0] * a[7] * a[10] - a[4] * a[2] * a[11]
              + a[4] * a[3] * a[10] + a[8] * a[2] * a[7] - a[8] * a[3] * a[6])
    inv[11] = (-a[0] * a[5] * a[11] + a[0] * a[7] * a[9] + a[4] * a[1] * a[11]
               - a[4] * a[3] * a[9] - a[8] * a[1] * a[7] + a[8] * a[3] * a[5])
    inv[15] = (a[0] * a[5] * a[10] - a[0] * a[6] * a[9] - a[4] * a[1] * a[10]
               + a[4] * a[2] * a[9] + a[8] * a[1] * a[6] - a[8] * a[2] * a[5])
    det = a[0] * inv[0] + a[1] * inv[4] + a[2] * inv[8] + a[3] * inv[12]
    if abs(det) < 1e-12:
        return IDENTITY
    return tuple(v / det for v in inv)


def quat_slerp(a, b, u):
    dot = sum(x * y for x, y in zip(a, b))
    if dot < 0.0:
        b, dot = tuple(-v for v in b), -dot
    if dot > 0.9995:  # nearly parallel: lerp, then renormalise
        out = tuple(x + (y - x) * u for x, y in zip(a, b))
    else:
        theta = math.acos(max(-1.0, min(1.0, dot)))
        s = math.sin(theta)
        wa, wb = math.sin((1 - u) * theta) / s, math.sin(u * theta) / s
        out = tuple(x * wa + y * wb for x, y in zip(a, b))
    n = math.sqrt(sum(v * v for v in out)) or 1.0
    return tuple(v / n for v in out)


# --------------------------------------------------------------------------
# the file
# --------------------------------------------------------------------------

class Material(object):
    def __init__(self, index, spec, model):
        self.index = index
        self.name = spec.get("name", "material_%d" % index)
        pbr = spec.get("pbrMetallicRoughness", {})
        factor = pbr.get("baseColorFactor", [1.0, 1.0, 1.0, 1.0])
        self.base_color = tuple(float(v) for v in factor)
        self.double_sided = bool(spec.get("doubleSided", False))
        self.alpha_mode = spec.get("alphaMode", "OPAQUE")
        self.alpha_cutoff = float(spec.get("alphaCutoff", 0.5))
        self.texture = None
        self.texture_error = None
        tex = pbr.get("baseColorTexture")
        if tex is not None:
            self.uv_set = int(tex.get("texCoord", 0))
            try:
                self.texture = model._image_for_texture(int(tex["index"]))
            except ModelError as exc:
                self.texture_error = str(exc)
        else:
            self.uv_set = 0


class Primitive(object):
    """One drawable chunk: a triangle list with a single material."""

    def __init__(self, positions, normals, uvs, colors, indices, material,
                 joints, weights):
        self.positions = positions
        self.normals = normals
        self.uvs = uvs
        self.colors = colors
        self.indices = indices
        self.material = material
        self.joints = joints
        self.weights = weights


class Pose(object):
    """World-space triangles at one instant. What the rasteriser consumes."""

    def __init__(self):
        self.verts = []      # [(x, y, z)] in glTF world space
        self.norms = []      # [(x, y, z)] unit-ish
        self.uvs = []        # [(u, v)]
        self.colors = []     # [(r, g, b, a)] floats, already vertex-colour lit
        self.tris = []       # [(i0, i1, i2, material)]

    def bounds(self):
        if not self.verts:
            return ((0.0, 0.0, 0.0), (0.0, 0.0, 0.0))
        xs = [v[0] for v in self.verts]
        ys = [v[1] for v in self.verts]
        zs = [v[2] for v in self.verts]
        return ((min(xs), min(ys), min(zs)), (max(xs), max(ys), max(zs)))


class Animation(object):
    def __init__(self, index, name, channels, duration):
        self.index = index
        self.name = name or "animation_%d" % index
        self.channels = channels
        self.duration = duration


class Model(object):
    def __init__(self, gltf, buffers, base_dir, label):
        self.gltf = gltf
        self.buffers = buffers
        self.base_dir = base_dir
        self.label = label
        self._accessors = {}
        self._images = {}
        self.materials = [Material(i, m, self)
                          for i, m in enumerate(gltf.get("materials", []))]
        self.default_material = Material(-1, {}, self)
        self._build_nodes()
        self._build_meshes()
        self._build_animations()

    # -- decoding ---------------------------------------------------------

    def _buffer(self, index):
        return self.buffers[index]

    def _view_bytes(self, index):
        view = self.gltf["bufferViews"][index]
        data = self._buffer(view.get("buffer", 0))
        start = view.get("byteOffset", 0)
        return data[start:start + view["byteLength"]], view.get("byteStride")

    def accessor(self, index):
        """Decode accessor `index` into a list of tuples (or scalars)."""
        if index in self._accessors:
            return self._accessors[index]
        spec = self.gltf["accessors"][index]
        count = spec["count"]
        n = COUNTS[spec["type"]]
        code, size = COMPONENTS[spec["componentType"]]
        out = [(0.0,) * n if n > 1 else 0] * count

        if "bufferView" in spec:
            raw, stride = self._view_bytes(spec["bufferView"])
            offset = spec.get("byteOffset", 0)
            stride = stride or n * size
            fmt = "<" + code * n
            out = []
            for i in range(count):
                at = offset + i * stride
                values = struct.unpack_from(fmt, raw, at)
                out.append(values[0] if n == 1 else values)

        if "sparse" in spec:
            out = list(out)
            sparse = spec["sparse"]
            idx_spec = sparse["indices"]
            val_spec = sparse["values"]
            icode, isize = COMPONENTS[idx_spec["componentType"]]
            iraw, istride = self._view_bytes(idx_spec["bufferView"])
            ioff = idx_spec.get("byteOffset", 0)
            istride = istride or isize
            vraw, vstride = self._view_bytes(val_spec["bufferView"])
            voff = val_spec.get("byteOffset", 0)
            vstride = vstride or n * size
            vfmt = "<" + code * n
            for k in range(sparse["count"]):
                where = struct.unpack_from("<" + icode, iraw, ioff + k * istride)[0]
                values = struct.unpack_from(vfmt, vraw, voff + k * vstride)
                out[where] = values[0] if n == 1 else values

        if spec.get("normalized") and spec["componentType"] != 5126:
            # Integers standing in for floats: unsigned map to [0, 1], signed to
            # [-1, 1] with the extra negative step clamped off, per the spec.
            if code.islower():
                top = float((1 << (8 * size - 1)) - 1)
                unit = lambda v: max(-1.0, v / top)
            else:
                top = float((1 << (8 * size)) - 1)
                unit = lambda v: v / top
            if n > 1:
                out = [tuple(unit(v) for v in t) for t in out]
            else:
                out = [unit(v) for v in out]

        self._accessors[index] = out
        return out

    def _image_for_texture(self, index):
        tex = self.gltf["textures"][index]
        if "source" not in tex:
            raise ModelError("texture %d has no image source" % index)
        return self._image(int(tex["source"]))

    def _image(self, index):
        if index in self._images:
            return self._images[index]
        spec = self.gltf["images"][index]
        name = spec.get("name", "image_%d" % index)
        if "bufferView" in spec:
            data, _ = self._view_bytes(spec["bufferView"])
        elif "uri" in spec:
            uri = spec["uri"]
            if uri.startswith("data:"):
                data = base64.b64decode(uri.split(",", 1)[1])
            else:
                path = os.path.join(self.base_dir, uri)
                if not os.path.isfile(path):
                    raise ModelError("image '%s' is missing next to the model" % uri)
                data = open(path, "rb").read()
        else:
            raise ModelError("image %d has neither a bufferView nor a uri" % index)

        mime = spec.get("mimeType", "")
        if data[:8] != b"\x89PNG\r\n\x1a\n":
            raise ModelError(
                "texture '%s' is %s, and only PNG can be decoded without a third-party "
                "library. Re-export the model with PNG textures (in Blender: File > "
                "Export > glTF, Images = PNG), or pass --no-textures to shade it from "
                "its material colours instead."
                % (name, mime or "not a PNG"))
        try:
            canvas = decode_png(data, name)
        except ValueError as exc:
            raise ModelError("texture '%s': %s" % (name, exc))
        self._images[index] = canvas
        return canvas

    # -- structure --------------------------------------------------------

    def _build_nodes(self):
        self.nodes = self.gltf.get("nodes", [])
        self.parent = {}
        for i, node in enumerate(self.nodes):
            for child in node.get("children", []):
                self.parent[child] = i
        scenes = self.gltf.get("scenes", [])
        which = self.gltf.get("scene", 0)
        if scenes:
            self.roots = list(scenes[min(which, len(scenes) - 1)].get("nodes", []))
        else:
            self.roots = [i for i in range(len(self.nodes)) if i not in self.parent]

    def _local_matrix(self, index, overrides):
        node = self.nodes[index]
        over = overrides.get(index) if overrides else None
        if over is None and "matrix" in node:
            return tuple(float(v) for v in node["matrix"])
        t = list(node.get("translation", [0.0, 0.0, 0.0]))
        r = list(node.get("rotation", [0.0, 0.0, 0.0, 1.0]))
        s = list(node.get("scale", [1.0, 1.0, 1.0]))
        if over is None and "matrix" not in node:
            return trs_matrix(t, r, s)
        if over:
            t = over.get("translation", t)
            r = over.get("rotation", r)
            s = over.get("scale", s)
        return trs_matrix(t, r, s)

    def world_matrices(self, overrides=None):
        """Every node's world matrix, resolved top-down."""
        out = {}

        def walk(index, parent):
            m = mat_mul(parent, self._local_matrix(index, overrides))
            out[index] = m
            for child in self.nodes[index].get("children", []):
                walk(child, m)

        for root in self.roots:
            walk(root, IDENTITY)
        # Nodes outside the active scene still get a transform, so a model
        # whose scene list is wrong renders rather than silently losing parts.
        for i in range(len(self.nodes)):
            if i not in out:
                out[i] = self._local_matrix(i, overrides)
        return out

    def _build_meshes(self):
        self.primitives = []   # (node_index, skin_index, Primitive)
        meshes = self.gltf.get("meshes", [])
        for node_index, node in enumerate(self.nodes):
            if "mesh" not in node:
                continue
            skin = node.get("skin")
            for spec in meshes[node["mesh"]].get("primitives", []):
                if spec.get("mode", 4) != 4:
                    continue  # only triangle lists; strips/fans are vanishingly rare
                attrs = spec.get("attributes", {})
                if "POSITION" not in attrs:
                    continue
                positions = self.accessor(attrs["POSITION"])
                normals = self.accessor(attrs["NORMAL"]) if "NORMAL" in attrs else None
                uv_key = "TEXCOORD_0"
                uvs = self.accessor(attrs[uv_key]) if uv_key in attrs else None
                colors = self.accessor(attrs["COLOR_0"]) if "COLOR_0" in attrs else None
                joints = self.accessor(attrs["JOINTS_0"]) if "JOINTS_0" in attrs else None
                weights = self.accessor(attrs["WEIGHTS_0"]) if "WEIGHTS_0" in attrs else None
                if "indices" in spec:
                    indices = self.accessor(spec["indices"])
                else:
                    indices = list(range(len(positions)))
                material = self.default_material
                if "material" in spec and spec["material"] < len(self.materials):
                    material = self.materials[spec["material"]]
                self.primitives.append((node_index, skin, Primitive(
                    positions, normals, uvs, colors, indices, material,
                    joints, weights)))
        if not self.primitives:
            raise ModelError(
                "%s has no triangle geometry. If it is a point cloud or a curve, "
                "convert it to a mesh before exporting." % self.label)

    def _build_animations(self):
        self.animations = []
        for index, spec in enumerate(self.gltf.get("animations", [])):
            samplers = spec.get("samplers", [])
            channels = []
            duration = 0.0
            for channel in spec.get("channels", []):
                target = channel.get("target", {})
                path = target.get("path")
                if path not in ("translation", "rotation", "scale"):
                    continue  # morph weights are not something we can bake
                if "node" not in target:
                    continue
                sampler = samplers[channel["sampler"]]
                times = self.accessor(sampler["input"])
                values = self.accessor(sampler["output"])
                if not times:
                    continue
                duration = max(duration, float(times[-1]))
                channels.append({
                    "node": int(target["node"]),
                    "path": path,
                    "times": times,
                    "values": values,
                    "interp": sampler.get("interpolation", "LINEAR"),
                })
            if channels:
                self.animations.append(
                    Animation(index, spec.get("name"), channels, duration))

    def find_animation(self, wanted):
        """An animation by name (case-insensitive substring) or by index."""
        if wanted is None:
            return None
        if isinstance(wanted, int):
            if 0 <= wanted < len(self.animations):
                return self.animations[wanted]
            raise ModelError("no animation %d (the file has %d)"
                             % (wanted, len(self.animations)))
        needle = str(wanted).lower()
        for anim in self.animations:
            if anim.name.lower() == needle:
                return anim
        for anim in self.animations:
            if needle in anim.name.lower():
                return anim
        return None

    # -- sampling ---------------------------------------------------------

    def _sample(self, channel, t):
        times, values, interp = channel["times"], channel["values"], channel["interp"]
        n = len(times)
        cubic = interp == "CUBICSPLINE"
        stride = 3 if cubic else 1
        if t <= times[0]:
            return values[0 * stride + (1 if cubic else 0)]
        if t >= times[-1]:
            return values[(n - 1) * stride + (1 if cubic else 0)]
        # Linear scan is fine: keyframe lists are short and we walk time forward.
        lo = 0
        hi = n - 1
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if times[mid] <= t:
                lo = mid
            else:
                hi = mid
        span = times[hi] - times[lo] or 1.0
        u = (t - times[lo]) / span
        if cubic:
            p0 = values[lo * 3 + 1]
            m0 = tuple(v * span for v in values[lo * 3 + 2])
            p1 = values[hi * 3 + 1]
            m1 = tuple(v * span for v in values[hi * 3 + 0])
            uu = u * u
            uuu = uu * u
            h00 = 2 * uuu - 3 * uu + 1
            h10 = uuu - 2 * uu + u
            h01 = -2 * uuu + 3 * uu
            h11 = uuu - uu
            return tuple(h00 * a + h10 * b + h01 * c + h11 * d
                         for a, b, c, d in zip(p0, m0, p1, m1))
        if interp == "STEP":
            return values[lo]
        if channel["path"] == "rotation":
            return quat_slerp(values[lo], values[hi], u)
        return tuple(a + (b - a) * u for a, b in zip(values[lo], values[hi]))

    def pose(self, animation=None, t=0.0, textures=True):
        """World-space triangles with the given animation applied at time `t`."""
        overrides = {}
        anim = animation
        if anim is not None and not isinstance(anim, Animation):
            anim = self.find_animation(anim)
        if anim is not None:
            for channel in anim.channels:
                overrides.setdefault(channel["node"], {})[channel["path"]] = \
                    self._sample(channel, t)

        world = self.world_matrices(overrides)
        skin_matrices = {}
        for index, skin in enumerate(self.gltf.get("skins", [])):
            joints = skin["joints"]
            if "inverseBindMatrices" in skin:
                binds = self.accessor(skin["inverseBindMatrices"])
            else:
                binds = [IDENTITY] * len(joints)
            skin_matrices[index] = [
                mat_mul(world[joint], tuple(bind))
                for joint, bind in zip(joints, binds)
            ]

        out = Pose()
        for node_index, skin_index, prim in self.primitives:
            base = len(out.verts)
            if skin_index is not None and prim.joints and prim.weights:
                mats = skin_matrices[skin_index]
                for i, p in enumerate(prim.positions):
                    js = prim.joints[i]
                    ws = prim.weights[i]
                    total = ws[0] + ws[1] + ws[2] + ws[3]
                    if total <= 0.0:
                        m = world[node_index]
                    else:
                        acc = [0.0] * 16
                        for j, w in zip(js, ws):
                            if w == 0.0:
                                continue
                            jm = mats[int(j)]
                            w = w / total
                            for k in range(16):
                                acc[k] += jm[k] * w
                        m = tuple(acc)
                    out.verts.append(mat_point(m, p))
                    n = prim.normals[i] if prim.normals else (0.0, 1.0, 0.0)
                    out.norms.append(mat_dir(m, n))
            else:
                m = world[node_index]
                for i, p in enumerate(prim.positions):
                    out.verts.append(mat_point(m, p))
                    n = prim.normals[i] if prim.normals else (0.0, 1.0, 0.0)
                    out.norms.append(mat_dir(m, n))

            for i in range(len(prim.positions)):
                out.uvs.append(prim.uvs[i] if prim.uvs else (0.0, 0.0))
                if prim.colors:
                    c = prim.colors[i]
                    out.colors.append(tuple(c) if len(c) == 4 else tuple(c) + (1.0,))
                else:
                    out.colors.append((1.0, 1.0, 1.0, 1.0))

            idx = prim.indices
            material = prim.material
            for k in range(0, len(idx) - 2, 3):
                out.tris.append((base + idx[k], base + idx[k + 1],
                                 base + idx[k + 2], material))
        return out


# --------------------------------------------------------------------------
# loading
# --------------------------------------------------------------------------

def _resolve_buffers(gltf, base_dir, glb_bin):
    out = []
    for i, spec in enumerate(gltf.get("buffers", [])):
        uri = spec.get("uri")
        if uri is None:
            if glb_bin is None:
                raise ModelError("buffer %d has no uri and the file has no BIN chunk" % i)
            out.append(glb_bin)
        elif uri.startswith("data:"):
            out.append(base64.b64decode(uri.split(",", 1)[1]))
        else:
            path = os.path.join(base_dir, uri)
            if not os.path.isfile(path):
                raise ModelError(
                    "the model refers to '%s', which is not next to it. Export as "
                    "a single .glb instead of .gltf + .bin." % uri)
            out.append(open(path, "rb").read())
    return out


def load(path):
    """Read a .glb or .gltf into a Model."""
    label = os.path.basename(path)
    if not os.path.isfile(path):
        raise ModelError("%s does not exist" % path)
    data = open(path, "rb").read()
    base_dir = os.path.dirname(os.path.abspath(path))

    if data[:4] == b"glTF":
        if len(data) < 12:
            raise ModelError("%s is truncated" % label)
        magic, version, _length = struct.unpack_from("<III", data, 0)
        if magic != GLB_MAGIC:
            raise ModelError("%s is not a GLB" % label)
        if version != 2:
            raise ModelError("%s is glTF %d; only glTF 2.0 is supported" % (label, version))
        gltf, glb_bin, pos = None, None, 12
        while pos + 8 <= len(data):
            size, kind = struct.unpack_from("<II", data, pos)
            body = data[pos + 8:pos + 8 + size]
            pos += 8 + size + (-size % 4)
            if kind == CHUNK_JSON:
                gltf = json.loads(body.decode("utf-8"))
            elif kind == CHUNK_BIN:
                glb_bin = body
        if gltf is None:
            raise ModelError("%s has no JSON chunk" % label)
    else:
        try:
            gltf = json.loads(data.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise ModelError(
                "%s is neither a GLB nor a .gltf JSON file. The pipeline reads "
                ".glb and .gltf; export from your tool in one of those." % label)
        glb_bin = None

    asset = gltf.get("asset", {})
    if not str(asset.get("version", "2.0")).startswith("2"):
        raise ModelError("%s is glTF %s; only glTF 2.0 is supported"
                         % (label, asset.get("version")))
    buffers = _resolve_buffers(gltf, base_dir, glb_bin)
    return Model(gltf, buffers, base_dir, label)


def describe(model):
    """A short human-readable summary. Printed by the pipeline before baking."""
    tris = sum(len(p.indices) // 3 for _n, _s, p in model.primitives)
    verts = sum(len(p.positions) for _n, _s, p in model.primitives)
    lines = ["%d primitive(s), %d triangles, %d vertices" %
             (len(model.primitives), tris, verts)]
    if model.animations:
        lines.append("animations: " + ", ".join(
            "%s (%.2fs)" % (a.name, a.duration) for a in model.animations))
    else:
        lines.append("animations: none (a single static pose)")
    textured = [m.name for m in model.materials if m.texture is not None]
    broken = [(m.name, m.texture_error) for m in model.materials if m.texture_error]
    lines.append("materials: %d, %d textured" % (len(model.materials), len(textured)))
    for name, err in broken:
        lines.append("  ! %s: %s" % (name, err))
    return lines


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        print(arg)
        for line in describe(load(arg)):
            print("  " + line)
