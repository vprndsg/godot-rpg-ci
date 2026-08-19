#!/usr/bin/env python3
"""Generate reference art with an OpenAI image model, to draw *from*.

    export OPENAI_API_KEY=sk-...
    python3 tools/gen_art_ai.py "SNES-era grass-to-shoreline transition, isometric 2:1 diamond tiles"
    python3 tools/gen_art_ai.py --model gpt-image-1.5 --size 1024x1024 "bartender portrait"

Writes docs/art/refs/<slug>.png, which is gitignored.

These are references, not assets. Nothing this script produces goes into
assets/ -- the shipped art stays reproducible from tools/gen_art.py, which is
what makes the CI drift check meaningful and every art change reviewable as a
diff. The workflow is: generate a reference, look at it, then write the
painter that matches it in the project's palette.

Ask for isometric references, not top-down ones: the world is a 2:1 diamond
grid, and a reference drawn from overhead tells you nothing about the two
faces of a wall or where a roof's eaves fall.

Standard library only (urllib), so there is no `openai` package to install.

Model notes, current as of August 2026:
  * gpt-image-2 is the default and the strongest general model.
  * gpt-image-2 does NOT support transparent backgrounds. For anything needing
    alpha (sprites), either pass --model gpt-image-1.5 --transparent, or
    generate on a flat background and key it out afterwards.
  * gpt-image-1 is scheduled for shutdown on 2026-10-23. Do not target it.
  * Sizes must have both edges a multiple of 16.
"""

import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "docs/art/refs")
ENDPOINT = "https://api.openai.com/v1/images/generations"

DEFAULT_MODEL = "gpt-image-2"
DEFAULT_SIZE = "1024x1024"

# Prepended to every prompt so references land in this game's idiom rather
# than generic "pixel art", which models tend to render at the wrong scale.
STYLE_PREFIX = (
    "Top-down 2D tile RPG art in the style of a 16-bit SNES or GBA game. "
    "Chunky readable pixels, limited palette, hard edges, no anti-aliasing, "
    "no gradients, no modern lighting. Flat orthographic top-down view. "
)


def slugify(text):
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return (slug[:60] or "ref")


def generate(prompt, model, size, quality, transparent):
    key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not key:
        sys.exit(
            "OPENAI_API_KEY is not set.\n"
            "This script is the only thing in the toolchain that needs it -- "
            "gen_art.py, art_sheet.py, render_map.py and the tests all run without one."
        )

    body = {
        "model": model,
        "prompt": STYLE_PREFIX + prompt,
        "size": size,
        "quality": quality,
        "n": 1,
    }
    if transparent:
        if model.startswith("gpt-image-2"):
            sys.exit(
                "%s does not support transparent backgrounds.\n"
                "Use --model gpt-image-1.5 for alpha, or drop --transparent and key "
                "the background out afterwards." % model
            )
        body["background"] = "transparent"
        body["output_format"] = "png"

    request = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as err:
        detail = err.read().decode("utf-8", "replace")[:800]
        sys.exit("OpenAI API returned %s:\n%s" % (err.code, detail))

    entry = payload["data"][0]
    if "b64_json" in entry:
        return base64.b64decode(entry["b64_json"])
    with urllib.request.urlopen(entry["url"], timeout=300) as response:
        return response.read()


def main(argv):
    model, size, quality, transparent = DEFAULT_MODEL, DEFAULT_SIZE, "high", False
    words = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--model":
            model = argv[i + 1]; i += 2
        elif arg == "--size":
            size = argv[i + 1]; i += 2
        elif arg == "--quality":
            quality = argv[i + 1]; i += 2
        elif arg == "--transparent":
            transparent = True; i += 1
        else:
            words.append(arg); i += 1

    prompt = " ".join(words).strip()
    if not prompt:
        sys.exit(__doc__)

    for edge in size.split("x"):
        if int(edge) % 16:
            sys.exit("size %s is invalid: both edges must be multiples of 16" % size)

    png = generate(prompt, model, size, quality, transparent)
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, slugify(prompt) + ".png")
    with open(path, "wb") as f:
        f.write(png)
    print("wrote %s (%d bytes, %s)" % (os.path.relpath(path, ROOT), len(png), model))
    print("Reference only -- draw the painter in tools/gen_art.py from it, do not ship it.")


if __name__ == "__main__":
    main(sys.argv[1:])
