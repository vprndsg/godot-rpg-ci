#!/usr/bin/env python3
"""Shared pixel-pushing toolkit: an RGBA canvas, PNG read/write, and a 3x5 font.

Imported by tools/gen_art.py (which draws the game's art), tools/art_sheet.py
and tools/render_map.py (which render it back out so an agent can look at it).

Standard library only -- zlib and struct. No Pillow, nothing to install, so
every generator runs in any sandbox with no setup step. Keep it that way.
"""

import os
import struct
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

CLEAR = (0, 0, 0, 0)


def rgb(h):
    h = h.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), 255)


def noise(x, y, salt=0):
    """Deterministic hash -> [0, 1). Keeps the art stable across runs."""
    n = (x * 374761393 + y * 668265263 + salt * 2147483647) & 0xFFFFFFFF
    n = (n ^ (n >> 13)) * 1274126177 & 0xFFFFFFFF
    return ((n ^ (n >> 16)) & 0xFFFF) / 65536.0


# --------------------------------------------------------------------------
# the project palette -- the single source of truth for colour
# --------------------------------------------------------------------------

P = {
    # Salt-air greens and sea-glass blues keep Port Azure coastal rather than
    # generic fantasy. Values stay separated enough to read at 16x16.
    "grass":     rgb("587a3e"), "grass_hi": rgb("75934f"), "grass_lo": rgb("3d5c35"),
    "dirt":      rgb("9a7147"), "dirt_hi":  rgb("bd9360"), "dirt_lo":  rgb("705039"),
    "stone":     rgb("858d8b"), "stone_hi": rgb("b1b6aa"), "stone_lo": rgb("596567"),
    "water":     rgb("176c86"), "water_hi": rgb("42b7b7"), "water_lo": rgb("174969"),
    "foam":      rgb("bde4d5"),
    "sand":      rgb("d9bd79"), "sand_hi":  rgb("f0d99b"), "sand_lo": rgb("b08c55"),
    "leaf":      rgb("356442"), "leaf_hi":  rgb("5c8a4a"), "leaf_lo": rgb("233f39"),
    "bark":      rgb("765037"), "bark_lo":  rgb("4b342c"),
    "wood":      rgb("97613b"), "wood_hi":  rgb("c18750"), "wood_lo": rgb("63402f"),
    "wallw":     rgb("795039"), "wallw_hi": rgb("a46e45"), "wallw_lo": rgb("4f352d"),
    "walls":     rgb("657073"), "walls_hi": rgb("929b96"), "walls_lo": rgb("414c55"),
    "roof":      rgb("a84d35"), "roof_hi":  rgb("d16a45"), "roof_lo": rgb("71362f"),
    "rug":       rgb("7f405b"), "rug_hi":   rgb("af5d70"), "rug_lo": rgb("563247"),
    "cloth":     rgb("d7c39a"),
    "metal":     rgb("9ba9a7"), "metal_lo": rgb("5c6b70"),
    "fire":      rgb("e77b34"), "fire_hi":  rgb("f6cf62"), "fire_lo": rgb("ad4930"),
    "glass":     rgb("4c9eb2"), "glass_hi": rgb("a5d8ce"),
    "dark":      rgb("17222b"), "black": rgb("0d151c"),
    "shadow":    (12, 22, 28, 78), "shadow_soft": (12, 22, 28, 42),
}


# --------------------------------------------------------------------------
# canvas
# --------------------------------------------------------------------------

class Canvas:
    def __init__(self, w, h):
        self.w = w
        self.h = h
        self.px = bytearray(w * h * 4)  # RGBA, starts fully transparent

    def get(self, x, y):
        if not (0 <= x < self.w and 0 <= y < self.h):
            return CLEAR
        i = (y * self.w + x) * 4
        return tuple(self.px[i:i + 4])

    def set(self, x, y, c):
        if not (0 <= x < self.w and 0 <= y < self.h):
            return
        i = (y * self.w + x) * 4
        self.px[i:i + 4] = bytes(c)

    def blend(self, x, y, c):
        """Source-over. Only needed by the renderers -- the art itself is
        hard-edged and uses set()."""
        if c[3] == 255:
            self.set(x, y, c)
            return
        if c[3] == 0:
            return
        dst = self.get(x, y)
        a = c[3] / 255.0
        out = tuple(int(round(c[i] * a + dst[i] * (1 - a))) for i in range(3))
        self.set(x, y, out + (max(dst[3], c[3]),))

    def rect(self, x, y, w, h, c):
        for yy in range(y, y + h):
            for xx in range(x, x + w):
                self.set(xx, yy, c)

    def hline(self, x, y, w, c):
        self.rect(x, y, w, 1, c)

    def vline(self, x, y, h, c):
        self.rect(x, y, 1, h, c)

    def frame(self, x, y, w, h, c):
        self.hline(x, y, w, c)
        self.hline(x, y + h - 1, w, c)
        self.vline(x, y, h, c)
        self.vline(x + w - 1, y, h, c)

    def save(self, path):
        raw = bytearray()
        stride = self.w * 4
        for y in range(self.h):
            raw.append(0)  # filter type 0 (None)
            raw += self.px[y * stride:(y + 1) * stride]

        def chunk(tag, data):
            out = struct.pack(">I", len(data)) + tag + data
            return out + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

        png = b"\x89PNG\r\n\x1a\n"
        png += chunk(b"IHDR", struct.pack(">IIBBBBB", self.w, self.h, 8, 6, 0, 0, 0))
        png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        png += chunk(b"IEND", b"")
        directory = os.path.dirname(path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        with open(path, "wb") as f:
            f.write(png)
        print("wrote %s (%dx%d)" % (os.path.relpath(path, ROOT), self.w, self.h))


# --------------------------------------------------------------------------
# PNG reading -- 8-bit RGBA/RGB only, which is all this project writes
# --------------------------------------------------------------------------

def load_png(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("%s is not a PNG" % path)

    pos, width, height, depth, colour = 8, None, None, None, None
    idat = bytearray()
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if tag == b"IHDR":
            width, height, depth, colour = struct.unpack(">IIBB", body[:10])
        elif tag == b"IDAT":
            idat += body
        elif tag == b"IEND":
            break

    if depth != 8 or colour not in (2, 6):
        raise ValueError("%s: only 8-bit RGB/RGBA is supported (depth=%s colour=%s)"
                         % (path, depth, colour))
    channels = 4 if colour == 6 else 3

    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    out = Canvas(width, height)
    prev = bytearray(stride)
    pos = 0
    for y in range(height):
        filt = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if filt == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 255
        elif filt == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif filt == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 255
        elif filt == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 255
        elif filt != 0:
            raise ValueError("%s: unsupported filter type %d on row %d" % (path, filt, y))

        for x in range(width):
            i = x * channels
            if channels == 4:
                out.set(x, y, (line[i], line[i + 1], line[i + 2], line[i + 3]))
            else:
                out.set(x, y, (line[i], line[i + 1], line[i + 2], 255))
        prev = line
    return out


# --------------------------------------------------------------------------
# composition
# --------------------------------------------------------------------------

def scale(src, factor):
    out = Canvas(src.w * factor, src.h * factor)
    for y in range(src.h):
        for x in range(src.w):
            c = src.get(x, y)
            for dy in range(factor):
                for dx in range(factor):
                    out.set(x * factor + dx, y * factor + dy, c)
    return out


def blit(dst, src, x, y, sx=0, sy=0, w=None, h=None, factor=1, alpha=True):
    """Copy a region of src into dst at (x, y), optionally magnified."""
    w = src.w if w is None else w
    h = src.h if h is None else h
    for yy in range(h):
        for xx in range(w):
            c = src.get(sx + xx, sy + yy)
            if alpha and c[3] == 0:
                continue
            for dy in range(factor):
                for dx in range(factor):
                    px, py = x + xx * factor + dx, y + yy * factor + dy
                    if alpha and c[3] < 255:
                        dst.blend(px, py, c)
                    else:
                        dst.set(px, py, c)


# --------------------------------------------------------------------------
# a 3x5 bitmap font, so the contact sheets can label things
# --------------------------------------------------------------------------

_GLYPHS = {
    "A": "111101111101101", "B": "110101110101110", "C": "011100100100011",
    "D": "110101101101110", "E": "111100110100111", "F": "111100110100100",
    "G": "011100101101011", "H": "101101111101101", "I": "111010010010111",
    "J": "001001001101010", "K": "101101110101101", "L": "100100100100111",
    "M": "101111111101101", "N": "101111111111101", "O": "010101101101010",
    "P": "110101110100100", "Q": "010101101111011", "R": "110101110101101",
    "S": "011100010001110", "T": "111010010010010", "U": "101101101101011",
    "V": "101101101101010", "W": "101101111111101", "X": "101101010101101",
    "Y": "101101010010010", "Z": "111001010100111",
    "0": "111101101101111", "1": "010110010010111", "2": "110001010100111",
    "3": "110001010001110", "4": "101101111001001", "5": "111100110001110",
    "6": "011100110101010", "7": "111001010010010", "8": "010101010101010",
    "9": "010101011001110",
    "_": "000000000000111", "-": "000000111000000", ".": "000000000000010",
    ",": "000000000010100", ":": "000010000010000", "/": "001001010100100",
    "(": "001010010010001", ")": "100010010010001", "*": "000101010101000",
    "+": "000010111010000", "=": "000111000111000", "#": "101111101111101",
    "!": "010010010000010", "?": "110001010000010", "'": "010010000000000",
    "<": "001010100010001", ">": "100010001010100", "%": "101001010100101",
    " ": "000000000000000",
}

FONT_W, FONT_H = 3, 5


def text_width(s, scale_=1, spacing=1):
    if not s:
        return 0
    return (len(s) * (FONT_W + spacing) - spacing) * scale_


def draw_text(c, x, y, s, colour, scale_=1, spacing=1):
    """Uppercase 3x5 text. Unknown characters render as a solid block so a
    missing glyph is obvious rather than silently invisible."""
    cx = x
    for ch in s.upper():
        bits = _GLYPHS.get(ch)
        if bits is None:
            bits = "111111111111111"
        for row in range(FONT_H):
            for col in range(FONT_W):
                if bits[row * FONT_W + col] == "1":
                    for dy in range(scale_):
                        for dx in range(scale_):
                            c.set(cx + col * scale_ + dx, y + row * scale_ + dy, colour)
        cx += (FONT_W + spacing) * scale_
    return cx
