#!/usr/bin/env python3
"""Bake a 3D model into an isometric pixel-art sprite sheet for this project.

This is the headless half of the pipeline `assets/packs/README.md` describes.
Where that document says "Blender, then PixelOver", this module does the same
job with no desktop and no licence: it points a true dimetric camera at a glTF
model, renders it once per grid direction per animation frame, and quantises
the result to a small palette so what comes out is pixel art rather than a
small render.

Everything geometric is derived from `assets/tiles/tiles.json` through
`pixel.geometry()`. There is no 64 and no 32 in this file, and the camera's
vertical foreshortening falls out of the diamond's own proportions, so moving
the production scale moves the bakery with it.
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from pixel import P, Canvas, geometry

# The eight grid directions, in the order the actor manifest stacks its rows.
# docs/architecture/animation.md is the schema; this order is the contract.
DIRECTIONS = ["down", "down_left", "left", "up_left",
              "up", "up_right", "right", "down_right"]

# Grid bearings, in degrees anticlockwise from grid +x. `down` is grid +y.
DIRECTION_ANGLE = {name: 90.0 + 45.0 * i for i, name in enumerate(DIRECTIONS)}

# Which glTF axis the model's nose points down before we rotate it. Blender and
# most exporters put a character's forward on -Z, which lands on grid +y --
# `down`, the direction that shows a face. That is why it is the default.
FORWARD_AXES = {
    "+x": (1.0, 0.0, 0.0), "-x": (-1.0, 0.0, 0.0),
    "+y": (0.0, 1.0, 0.0), "-y": (0.0, -1.0, 0.0),
    "+z": (0.0, 0.0, 1.0), "-z": (0.0, 0.0, -1.0),
}

# One grid cell is this many metres of world. Models exported from Blender,
# Meshy and friends are in metres, so this is the only number that connects a
# real-world size to a tile. A 1.8 m person is a bit over one cell tall.
CELL_METRES = 1.5

# The key light, in grid space. Chosen to match what tools/gen_art.py paints:
# `block(top, left, right)` gets (highlight, base, shadow), the screen-left face
# of a cell is its grid +y side and the screen-right face is its grid +x side.
# So the sun is above, a little toward +y, and away from +x -- and a baked
# sprite stands in the same light as the tiles it walks on.
KEY_LIGHT = (-0.35, 0.45, 0.82)
FILL_LIGHT = (0.45, -0.30, 0.20)   # a weak bounce, so the shadow side reads
AMBIENT = 0.42
FILL_ENERGY = 0.18

# Pixel-art shading: a small number of flat bands, tinted cool in shadow and
# warm in light, rather than a smooth ramp. Tints come from the project palette
# and the daylight profile so a baked character belongs to Port Azure.
SHADOW_TINT = P["dark"][:3]
LIGHT_TINT = (255, 240, 208)       # data/lighting/outdoor_day.json's sun


def normalise(v):
    n = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
    if n < 1e-12:
        return (0.0, 0.0, 1.0)
    return (v[0] / n, v[1] / n, v[2] / n)


# --------------------------------------------------------------------------
# the camera
# --------------------------------------------------------------------------

def camera_basis():
    """(pixels per cell across, per cell down, per cell up, depth axis).

    A genuine orthographic dimetric camera whose ground plane lands exactly on
    this project's diamond. The tilt is not a taste: `sin(phi) = th / tw` is
    the angle at which a square cell projects to a `tw` by `th` diamond, and
    the height scale is the same camera's cosine. Type a different number here
    and a model stops standing on the floor the tiles draw.
    """
    tw, th = geometry()[:2]
    sin_phi = float(th) / float(tw)
    cos_phi = math.sqrt(max(0.0, 1.0 - sin_phi * sin_phi))
    across = tw / 2.0                       # one cell of +x, in screen x
    down = th / 2.0                         # one cell of +x, in screen y
    up = math.sqrt(tw * tw - th * th) / math.sqrt(2.0)   # one cell of +z
    # Toward the camera, so a larger value wins the depth test.
    depth = (cos_phi / math.sqrt(2.0), cos_phi / math.sqrt(2.0), sin_phi)
    return across, down, up, depth


def project(cell, basis):
    """A point in cell units -> (screen_x, screen_y, depth). Floats."""
    across, down, up, axis = basis
    cx, cy, cz = cell
    return ((cx - cy) * across,
            (cx + cy) * down - cz * up,
            cx * axis[0] + cy * axis[1] + cz * axis[2])


def to_grid(p):
    """glTF (Y up, right-handed) -> this project's grid (Z up), handedness kept."""
    return (p[0], -p[2], p[1])


def yaw(p, cos_a, sin_a):
    """Rotate a grid-space point about the up axis."""
    return (p[0] * cos_a - p[1] * sin_a, p[0] * sin_a + p[1] * cos_a, p[2])


# --------------------------------------------------------------------------
# shading
# --------------------------------------------------------------------------

def band_colour(albedo, level):
    """One albedo at one lighting band -> a final RGB.

    `level` runs 0 (deepest shadow) to 1 (brightest). The ramp darkens toward a
    cool tint and brightens toward a warm one, which is what stops flat-shaded
    3D from reading as grey plastic when it is reduced to a handful of colours.
    """
    if level >= 0.5:
        u = (level - 0.5) * 2.0
        gain = 1.0 + 0.30 * u
        tint, mix = LIGHT_TINT, 0.22 * u
    else:
        u = 1.0 - level * 2.0
        gain = 1.0 - 0.46 * u
        tint, mix = SHADOW_TINT, 0.30 * u
    out = []
    for c, t in zip(albedo, tint):
        v = c * gain
        v = v + (t - v) * mix
        out.append(max(0, min(255, int(round(v)))))
    return tuple(out)


def shade_level(normal, bands):
    """Lambert against the key and fill lights, quantised to `bands` steps."""
    key = max(0.0, normal[0] * KEY_LIGHT[0] + normal[1] * KEY_LIGHT[1]
              + normal[2] * KEY_LIGHT[2])
    fill = max(0.0, normal[0] * FILL_LIGHT[0] + normal[1] * FILL_LIGHT[1]
               + normal[2] * FILL_LIGHT[2])
    lit = AMBIENT + (1.0 - AMBIENT) * key + FILL_ENERGY * fill
    lit = max(0.0, min(1.0, lit))
    step = int(lit * bands)
    if step >= bands:
        step = bands - 1
    return step / float(bands - 1) if bands > 1 else 1.0


# --------------------------------------------------------------------------
# the rasteriser
# --------------------------------------------------------------------------

class Frame(object):
    """One rendered frame at output resolution: albedo + band + coverage."""

    __slots__ = ("w", "h", "albedo", "level", "alpha")

    def __init__(self, w, h):
        self.w = w
        self.h = h
        self.albedo = [None] * (w * h)
        self.level = [0.0] * (w * h)
        self.alpha = bytearray(w * h)


def render(pose, basis, scale, origin, frame_w, frame_h, anchor, opts):
    """Rasterise one posed model into a Frame.

    `scale` is cells per model unit, `origin` the model-space point that should
    land on `anchor` inside the frame. Rendered at `opts.supersample` and
    reduced by a mode filter, which is how a 3D render becomes pixel art: the
    commonest colour in a block wins outright instead of everything being
    averaged into mush.
    """
    ss = opts.supersample
    w, h = frame_w * ss, frame_h * ss
    ax, ay = anchor[0] * ss, anchor[1] * ss
    cos_a, sin_a = opts.cos_a, opts.sin_a
    lift = opts.height_scale

    # Project every vertex once.
    sx = [0.0] * len(pose.verts)
    sy = [0.0] * len(pose.verts)
    sd = [0.0] * len(pose.verts)
    for i, v in enumerate(pose.verts):
        g = yaw(to_grid((v[0] - origin[0], v[1] - origin[1], v[2] - origin[2])),
                cos_a, sin_a)
        px, py, pd = project((g[0] * scale, g[1] * scale, g[2] * scale * lift),
                             basis)
        sx[i] = px * ss + ax
        sy[i] = py * ss + ay
        sd[i] = pd

    normals = [None] * len(pose.norms)
    for i, n in enumerate(pose.norms):
        normals[i] = yaw(to_grid(n), cos_a, sin_a)

    depth = [-1e30] * (w * h)
    albedo = [None] * (w * h)
    level = [0.0] * (w * h)
    axis = basis[3]
    bands = opts.bands

    for i0, i1, i2, material in pose.tris:
        x0, y0, x1, y1, x2, y2 = sx[i0], sy[i0], sx[i1], sy[i1], sx[i2], sy[i2]
        area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
        if area == 0.0:
            continue

        # Backface cull against the real view direction rather than screen
        # winding, so a model exported with mirrored scale still culls right.
        e1 = tuple(a - b for a, b in zip(pose.verts[i1], pose.verts[i0]))
        e2 = tuple(a - b for a, b in zip(pose.verts[i2], pose.verts[i0]))
        face = yaw(to_grid((e1[1] * e2[2] - e1[2] * e2[1],
                            e1[2] * e2[0] - e1[0] * e2[2],
                            e1[0] * e2[1] - e1[1] * e2[0])), cos_a, sin_a)
        facing = face[0] * axis[0] + face[1] * axis[1] + face[2] * axis[2]
        if facing <= 0.0 and not material.double_sided:
            continue

        lo_x = max(0, int(math.floor(min(x0, x1, x2))))
        hi_x = min(w - 1, int(math.ceil(max(x0, x1, x2))))
        lo_y = max(0, int(math.floor(min(y0, y1, y2))))
        hi_y = min(h - 1, int(math.ceil(max(y0, y1, y2))))
        if lo_x > hi_x or lo_y > hi_y:
            continue

        inv_area = 1.0 / area
        n0, n1, n2 = normals[i0], normals[i1], normals[i2]
        flip = -1.0 if facing < 0.0 else 1.0   # two-sided faces light from front
        d0, d1, d2 = sd[i0], sd[i1], sd[i2]
        texture = None if opts.no_textures else material.texture
        base = material.base_color
        c0, c1, c2 = pose.colors[i0], pose.colors[i1], pose.colors[i2]
        u0, u1, u2 = pose.uvs[i0], pose.uvs[i1], pose.uvs[i2]
        cutoff = material.alpha_cutoff if material.alpha_mode == "MASK" else 0.0

        for py in range(lo_y, hi_y + 1):
            fy = py + 0.5
            row = py * w
            for px in range(lo_x, hi_x + 1):
                fx = px + 0.5
                w0 = ((x1 - fx) * (y2 - fy) - (x2 - fx) * (y1 - fy)) * inv_area
                if w0 < 0.0:
                    continue
                w1 = ((x2 - fx) * (y0 - fy) - (x0 - fx) * (y2 - fy)) * inv_area
                if w1 < 0.0:
                    continue
                w2 = 1.0 - w0 - w1
                if w2 < 0.0:
                    continue
                d = w0 * d0 + w1 * d1 + w2 * d2
                at = row + px
                if d <= depth[at]:
                    continue

                r = base[0] * (w0 * c0[0] + w1 * c1[0] + w2 * c2[0])
                g = base[1] * (w0 * c0[1] + w1 * c1[1] + w2 * c2[1])
                b = base[2] * (w0 * c0[2] + w1 * c1[2] + w2 * c2[2])
                a = base[3] * (w0 * c0[3] + w1 * c1[3] + w2 * c2[3])
                if texture is not None:
                    tu = w0 * u0[0] + w1 * u1[0] + w2 * u2[0]
                    tv = w0 * u0[1] + w1 * u1[1] + w2 * u2[1]
                    tx = int(tu * texture.w) % texture.w
                    ty = int(tv * texture.h) % texture.h
                    tr, tg, tb, ta = texture.get(tx, ty)
                    r *= tr / 255.0
                    g *= tg / 255.0
                    b *= tb / 255.0
                    a *= ta / 255.0
                if a <= cutoff or a < 0.35:
                    continue

                nx = (w0 * n0[0] + w1 * n1[0] + w2 * n2[0]) * flip
                ny = (w0 * n0[1] + w1 * n1[1] + w2 * n2[1]) * flip
                nz = (w0 * n0[2] + w1 * n1[2] + w2 * n2[2]) * flip
                depth[at] = d
                albedo[at] = (r * 255.0, g * 255.0, b * 255.0)
                level[at] = shade_level(normalise((nx, ny, nz)), bands)

    return _reduce(albedo, level, w, h, frame_w, frame_h, ss)


def _reduce(albedo, level, w, h, frame_w, frame_h, ss):
    """Mode-filter the supersampled buffer down to one pixel per output cell."""
    out = Frame(frame_w, frame_h)
    half = (ss * ss) // 2
    for oy in range(frame_h):
        for ox in range(frame_w):
            groups = {}
            covered = 0
            for dy in range(ss):
                row = (oy * ss + dy) * w + ox * ss
                for dx in range(ss):
                    at = row + dx
                    c = albedo[at]
                    if c is None:
                        continue
                    covered += 1
                    # Coarse key: near-identical colours at the same band are
                    # one candidate, so the vote is about surfaces, not noise.
                    key = (int(c[0]) >> 4, int(c[1]) >> 4, int(c[2]) >> 4,
                           int(level[at] * 32))
                    slot = groups.get(key)
                    if slot is None:
                        groups[key] = [1, c[0], c[1], c[2], level[at]]
                    else:
                        slot[0] += 1
                        slot[1] += c[0]
                        slot[2] += c[1]
                        slot[3] += c[2]
            if covered <= half:
                continue   # under half covered: this pixel is background
            best = max(groups.values(), key=lambda s: s[0])
            n = float(best[0])
            at = oy * frame_w + ox
            out.albedo[at] = (best[1] / n, best[2] / n, best[3] / n)
            out.level[at] = best[4]
            out.alpha[at] = 255
    return out


# --------------------------------------------------------------------------
# palette
# --------------------------------------------------------------------------

def median_cut(histogram, colours):
    """Reduce an {rgb: count} histogram to `colours` representative RGBs."""
    entries = [(k, v) for k, v in histogram.items() if v]
    if not entries:
        return [(128, 128, 128)]
    boxes = [entries]
    while len(boxes) < colours:
        # Split whichever box spans the most, weighted by how much art is in it.
        target, best = None, -1.0
        for box in boxes:
            if len(box) < 2:
                continue
            spans = [max(c[i] for c, _ in box) - min(c[i] for c, _ in box)
                     for i in range(3)]
            weight = max(spans) * math.log(1 + sum(n for _, n in box))
            if weight > best:
                target, best = box, weight
        if target is None:
            break
        spans = [max(c[i] for c, _ in target) - min(c[i] for c, _ in target)
                 for i in range(3)]
        axis = spans.index(max(spans))
        target.sort(key=lambda e: e[0][axis])
        total = sum(n for _, n in target)
        half, seen, cut = total / 2.0, 0, 1
        for i, (_, n) in enumerate(target):
            seen += n
            if seen >= half:
                cut = max(1, min(len(target) - 1, i))
                break
        boxes.remove(target)
        boxes.append(target[:cut])
        boxes.append(target[cut:])

    out = []
    for box in boxes:
        total = sum(n for _, n in box) or 1
        out.append(tuple(int(round(sum(c[i] * n for c, n in box) / total))
                         for i in range(3)))
    return sorted(set(out)) or [(128, 128, 128)]


def nearest(colour, palette):
    best, best_d = palette[0], None
    for c in palette:
        d = ((c[0] - colour[0]) ** 2 + (c[1] - colour[1]) ** 2
             + (c[2] - colour[2]) ** 2)
        if best_d is None or d < best_d:
            best, best_d = c, d
    return best


# --------------------------------------------------------------------------
# clips
# --------------------------------------------------------------------------

# An exported animation's name is the only clue we get about what it is. These
# are matched in order against a lowercased name; the first hit wins. A name
# nothing matches keeps its own name as the clip, which is why an unknown
# animation is never lost -- it just needs a `clip_fallbacks` entry to be
# reachable from code that asks for something else.
CLIP_PATTERNS = [
    ("idle", ("idle", "rest", "stand", "breath", "tpose", "t-pose")),
    ("walk", ("walk",)),
    ("trot", ("trot", "jog", "canter")),
    ("run", ("run", "gallop", "sprint")),
    ("sniff", ("sniff", "smell", "eat", "graze", "search")),
    ("sit", ("sit", "lie", "lay", "sleep")),
    ("attack", ("attack", "bite", "bark", "howl", "growl")),
    ("hurt", ("hurt", "hit", "damage", "flinch")),
    ("die", ("die", "death", "dead")),
    ("jump", ("jump", "leap")),
]

# One-shots: everything else loops. A `die` that loops is a corpse that keeps
# dying, and a `hurt` that loops is a character stuck flinching.
ONE_SHOT = ("attack", "hurt", "die", "jump", "sniff")


def clip_name_for(animation_name, taken):
    lowered = animation_name.lower()
    for clip, keys in CLIP_PATTERNS:
        if any(k in lowered for k in keys) and clip not in taken:
            return clip
    safe = "".join(c if c.isalnum() else "_" for c in lowered).strip("_")
    safe = safe or "clip"
    candidate = safe
    n = 2
    while candidate in taken:
        candidate = "%s_%d" % (safe, n)
        n += 1
    return candidate


class Clip(object):
    def __init__(self, name, animation, frames, fps, loop):
        self.name = name
        self.animation = animation
        self.frames = frames
        self.fps = fps
        self.loop = loop

    def times(self):
        """Sample times. The last frame is never the first one repeated."""
        if self.animation is None or self.frames <= 1:
            return [0.0]
        step = self.animation.duration / float(self.frames)
        return [i * step for i in range(self.frames)]


def plan_clips(model, opts):
    """Decide which animations become which clips, at how many frames."""
    if not model.animations:
        return [Clip("idle", None, 1, 0.0, False)]
    out, taken = [], set()
    for anim in model.animations:
        if opts.only_clips and not any(
                k in anim.name.lower() for k in opts.only_clips):
            continue
        name = clip_name_for(anim.name, taken)
        taken.add(name)
        if anim.duration <= 0.0:
            out.append(Clip(name, anim, 1, 0.0, False))
            continue
        frames = int(round(anim.duration * opts.sample_fps))
        frames = max(1, min(opts.max_frames, frames))
        fps = 0.0 if frames <= 1 else frames / anim.duration
        out.append(Clip(name, anim, frames, round(fps, 2),
                        name not in ONE_SHOT))
    if not out:
        return [Clip("idle", None, 1, 0.0, False)]
    # `idle` first: it is the fallback of last resort, so row 0 is the row a
    # broken manifest is most likely to be asked for.
    out.sort(key=lambda c: (c.name != "idle", c.name))
    return out


# --------------------------------------------------------------------------
# framing
# --------------------------------------------------------------------------

class Options(object):
    def __init__(self, **kw):
        self.bands = kw.get("bands", 4)
        self.colours = kw.get("colours", 10)
        self.supersample = kw.get("supersample", 4)
        self.no_textures = kw.get("no_textures", False)
        self.outline = kw.get("outline", True)
        self.forward = kw.get("forward", "-z")
        self.cell_metres = kw.get("cell_metres", CELL_METRES)
        # Applied to the model's up axis before the camera sees it, so the
        # camera stays a true dimetric one and depth stays consistent with the
        # drawing. 1.0 is geometrically correct. The shipped painters are more
        # squashed than that (a cell-high wall is 0.82 cells at true scale),
        # so match them with something nearer 0.8 if new art has to sit beside
        # the placeholders rather than replace them.
        self.height_scale = kw.get("height_scale", 1.0)
        self.fit_height = kw.get("fit_height", None)
        self.max_frames = kw.get("max_frames", 8)
        self.sample_fps = kw.get("sample_fps", 10.0)
        self.only_clips = kw.get("only_clips", None)
        self.directions = kw.get("directions", list(DIRECTIONS))
        self.pad = kw.get("pad", 1)
        self.cos_a = 1.0
        self.sin_a = 0.0

    def face(self, direction):
        """Point the model down a grid direction by turning it, not the camera."""
        offset = DIRECTION_ANGLE[direction] - self.forward_angle
        radians = math.radians(offset)
        self.cos_a, self.sin_a = math.cos(radians), math.sin(radians)

    @property
    def forward_angle(self):
        """The grid bearing the untouched model already faces."""
        fx, fy, _fz = to_grid(FORWARD_AXES[self.forward])
        return math.degrees(math.atan2(fy, fx))


def ground_origin(pose):
    """The model-space point the sprite stands on: the centre of its feet.

    Taken from the lowest slice of the model rather than the whole bounding
    box, so a creature with its nose out front or its tail up does not have
    its contact point dragged away from the ground it is actually touching.
    """
    (lo_x, lo_y, lo_z), (hi_x, hi_y, hi_z) = pose.bounds()
    height = hi_y - lo_y
    cut = lo_y + max(1e-6, height * 0.08)
    feet = [v for v in pose.verts if v[1] <= cut]
    if not feet:
        feet = pose.verts
    xs = [v[0] for v in feet]
    zs = [v[2] for v in feet]
    return ((min(xs) + max(xs)) / 2.0, lo_y, (min(zs) + max(zs)) / 2.0)


def model_scale(pose, opts):
    """Cells per model unit, plus the height in model units for reporting."""
    (_lo_x, lo_y, _lo_z), (_hi_x, hi_y, _hi_z) = pose.bounds()
    height = max(1e-6, hi_y - lo_y)
    if opts.fit_height:
        up = camera_basis()[2] * opts.height_scale
        return (opts.fit_height / (height * up), height)
    return (1.0 / opts.cell_metres, height)


# --------------------------------------------------------------------------
# the bake
# --------------------------------------------------------------------------

def bake(model, opts, log=print):
    """Render `model` into (sheet Canvas, actor manifest fragment, notes).

    Three passes, each of which holds exactly one pose at a time. A walk cycle
    across eight directions is a few hundred frames; keeping them all in memory
    to decide a palette afterwards is how a bake turns into a swap storm.
    """
    basis = camera_basis()
    clips = plan_clips(model, opts)
    reference = model.pose(clips[0].animation, clips[0].times()[0])
    origin = ground_origin(reference)
    scale, height = model_scale(reference, opts)

    notes = []
    cells_tall = height * scale
    if not 0.05 <= cells_tall <= 6.0:
        notes.append(
            "the model is %.2f cells tall at the current scale, which is either "
            "not in metres or not a character. Pass --cell-metres or --fit-height."
            % cells_tall)

    total = sum(c.frames for c in clips)
    log("  clips: " + ", ".join("%s x%d @%.1ffps" % (c.name, c.frames, c.fps)
                                for c in clips))
    log("  %.2f cells tall; measuring %d pose(s) x %d direction(s)"
        % (cells_tall, total, len(opts.directions)))

    # 1. framing: every silhouette this sheet will ever hold, unioned, so no
    #    frame is cropped and nothing shifts between frames of a cycle.
    box = _Box()
    for clip in clips:
        for t in clip.times():
            _extend(box, model.pose(clip.animation, t), scale, origin, opts, basis)
    frame_w, frame_h, anchor = box.frame(opts)
    log("  frame %dx%d, anchor %s" % (frame_w, frame_h, anchor))
    if frame_w * frame_h > 256 * 256:
        notes.append("a %dx%d frame is very large for this grid; consider "
                     "--fit-height" % (frame_w, frame_h))

    # 2. palette: the albedo set is a property of the materials, not the pose,
    #    so one pose seen from every side is a complete sample of it.
    histogram = {}
    for direction in opts.directions:
        opts.face(direction)
        frame = render(reference, basis, scale, origin, frame_w, frame_h,
                       anchor, opts)
        for c in frame.albedo:
            if c is None:
                continue
            key = _key(c)
            histogram[key] = histogram.get(key, 0) + 1
    palette = median_cut(histogram, opts.colours)
    outline = _outline_colour(palette)
    log("  palette: %d albedo colours x %d light bands"
        % (len(palette), opts.bands))

    # 3. the sheet. Rows run one per direction from each clip's own row, frames
    #    run along the columns -- docs/architecture/animation.md's only layout
    #    rule, and the one the runtime, the validator and art_sheet all read.
    columns = max(c.frames for c in clips)
    sheet = Canvas(columns * frame_w,
                   len(clips) * len(opts.directions) * frame_h)
    mapped = {}
    for clip_index, clip in enumerate(clips):
        for frame_index, t in enumerate(clip.times()):
            pose = model.pose(clip.animation, t)
            for d, direction in enumerate(opts.directions):
                opts.face(direction)
                frame = render(pose, basis, scale, origin, frame_w, frame_h,
                               anchor, opts)
                ox = frame_index * frame_w
                oy = (clip_index * len(opts.directions) + d) * frame_h
                _composite(sheet, frame, ox, oy, frame_w, frame_h,
                           palette, mapped, opts, outline)
            log("  rendered %s %d/%d" % (clip.name, frame_index + 1, clip.frames))

    manifest = {
        "frame_size": [frame_w, frame_h],
        "anchor": [anchor[0], anchor[1]],
        "directions": list(opts.directions),
        "clips": {},
    }
    for clip_index, clip in enumerate(clips):
        manifest["clips"][clip.name] = {
            "row": clip_index * len(opts.directions),
            "frames": clip.frames,
            "fps": clip.fps,
            "loop": clip.loop,
        }
    return sheet, manifest, notes


def _key(colour):
    """Colours this close together are one entry in the palette histogram."""
    return (int(colour[0]) >> 3 << 3, int(colour[1]) >> 3 << 3,
            int(colour[2]) >> 3 << 3)


class _Box(object):
    def __init__(self):
        self.lo_x = self.lo_y = 1e30
        self.hi_x = self.hi_y = -1e30

    def frame(self, opts):
        pad = opts.pad + (1 if opts.outline else 0)
        # Clamped so the ground point -- which projects to (0, 0) -- is always
        # inside the frame. ActorManifest rejects an anchor outside its own
        # frame, and an actor whose contact point is off-sheet cannot be placed.
        left = min(int(math.floor(self.lo_x)) - pad, 0)
        top = min(int(math.floor(self.lo_y)) - pad, 0)
        right = max(int(math.ceil(self.hi_x)) + pad, 1)
        bottom = max(int(math.ceil(self.hi_y)) + pad, 1)
        return (right - left, bottom - top, (-left, -top))


def _extend(box, pose, scale, origin, opts, basis):
    for direction in opts.directions:
        opts.face(direction)
        cos_a, sin_a = opts.cos_a, opts.sin_a
        for v in pose.verts:
            g = yaw(to_grid((v[0] - origin[0], v[1] - origin[1],
                             v[2] - origin[2])), cos_a, sin_a)
            px, py, _d = project((g[0] * scale, g[1] * scale,
                                  g[2] * scale * opts.height_scale), basis)
            if px < box.lo_x:
                box.lo_x = px
            if px > box.hi_x:
                box.hi_x = px
            if py < box.lo_y:
                box.lo_y = py
            if py > box.hi_y:
                box.hi_y = py


def _composite(sheet, frame, ox, oy, frame_w, frame_h, palette, mapped,
               opts, outline):
    for i in range(frame_w * frame_h):
        if not frame.alpha[i]:
            continue
        key = _key(frame.albedo[i])
        base = mapped.get(key)
        if base is None:
            base = mapped[key] = nearest(key, palette)
        sheet.set(ox + i % frame_w, oy + i // frame_w,
                  band_colour(base, frame.level[i]) + (255,))
    if opts.outline:
        _draw_outline(sheet, frame, ox, oy, frame_w, frame_h, outline)


def _outline_colour(palette):
    """A dark edge that belongs to the sprite: its own darkest tone, pushed
    toward the palette's cool shadow rather than to flat black."""
    darkest = min(palette, key=lambda c: c[0] + c[1] + c[2])
    return tuple(max(0, min(255, int(round(c * 0.45 + t * 0.35))))
                 for c, t in zip(darkest, SHADOW_TINT)) + (255,)


def _draw_outline(sheet, frame, ox, oy, frame_w, frame_h, colour):
    """A one-pixel dark edge around the silhouette, inside this frame only.

    Baked 3D at this size loses its edges against a busy tile floor; the
    outline is what every iso pipeline adds and what makes a character read as
    a character rather than a smudge. It never leaves its own frame, so it
    cannot bleed into the neighbouring direction on the sheet.
    """
    alpha = frame.alpha
    for y in range(frame_h):
        for x in range(frame_w):
            if alpha[y * frame_w + x]:
                continue
            if ((x > 0 and alpha[y * frame_w + x - 1])
                    or (x + 1 < frame_w and alpha[y * frame_w + x + 1])
                    or (y > 0 and alpha[(y - 1) * frame_w + x])
                    or (y + 1 < frame_h and alpha[(y + 1) * frame_w + x])):
                sheet.set(ox + x, oy + y, colour)
