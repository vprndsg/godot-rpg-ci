#!/usr/bin/env python3
"""The inbox pipeline: drop an asset in, get a wired-up, validated pack out.

    tools/ci.sh inbox                 # everything in inbox/, then the gates
    tools/ci.sh inbox -- --dry-run    # say what it would do, touch nothing

One command, no decisions. A file in `inbox/` is identified, baked at the
production geometry, installed as a pack under `assets/packs/<name>/`, and
wired into whichever registry it belongs in -- and then the normal gates run,
so the answer is always either "shipped" or a specific error with a fix in it.

Settings live in `data/inbox.json` and are set once. Anything an individual
asset needs differently goes in `inbox/<name>.json` next to it, or in that
file's `assets` block, so a re-run of the same file is reproducible rather
than a fresh guess. `docs/architecture/inbox.md` is the whole design.

Standard library only, like the rest of tools/.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import glb
import sprite_bake
from pixel import ROOT

INBOX = os.path.join(ROOT, "inbox")
PACKS = os.path.join(ROOT, "assets/packs")
SETTINGS = os.path.join(ROOT, "data/inbox.json")

MODEL_SUFFIXES = (".glb", ".gltf")

# Everything the pipeline will act on. Extending this means teaching
# `process()` what to do with the new kind first.
KNOWN_SUFFIXES = MODEL_SUFFIXES

# Fields a pack cannot ship without. They are not paperwork: this repository
# publishes to GitHub Pages on every merge, and art whose terms nobody wrote
# down is art nobody can safely publish. Set them once in data/inbox.json.
CREDIT_FIELDS = ("author", "source", "license")

BAKE_KEYS = ("forward", "cell_metres", "fit_height", "height_scale",
             "colours", "bands",
             "supersample", "max_frames", "sample_fps", "outline", "pad",
             "no_textures", "only_clips")


class Failure(Exception):
    """A problem the operator has to fix. The message says how."""


def load_settings():
    if not os.path.isfile(SETTINGS):
        return {}
    with open(SETTINGS) as f:
        return json.load(f)


def _clean(block):
    """Drop the `_comment` keys the settings file documents itself with."""
    return {k: (_clean(v) if isinstance(v, dict) else v)
            for k, v in block.items() if not k.startswith("_")}


def settings_for(name, path, settings):
    """Defaults, then this asset's block, then a sidecar next to the file."""
    out = _clean(settings.get("defaults", {}))
    for override in (settings.get("assets", {}).get(name), _sidecar(path)):
        if not override:
            continue
        override = _clean(override)
        for key, value in override.items():
            if key == "bake" and isinstance(value, dict):
                out.setdefault("bake", {}).update(value)
            else:
                out[key] = value
    return out


def sidecar_path(path):
    """The settings file that travels with an asset: foo.glb -> foo.json."""
    return os.path.splitext(path)[0] + ".json"


def _sidecar(path):
    path = sidecar_path(path)
    if not os.path.isfile(path):
        return None
    with open(path) as f:
        return json.load(f)


def slug(text):
    """A file name -> a pack directory and actor name.

    Hyphens survive, because `example-harbour` is what a pack directory in this
    repo looks like; everything else that is not alphanumeric becomes one.
    """
    out = "".join(c.lower() if (c.isalnum() or c in "-_") else "-"
                  for c in text).strip("-_")
    while "--" in out:
        out = out.replace("--", "-")
    return out or "asset"


def find_assets():
    """Everything in inbox/ we are meant to act on, as (name, path) pairs."""
    if not os.path.isdir(INBOX):
        return []
    out = []
    for entry in sorted(os.listdir(INBOX)):
        path = os.path.join(INBOX, entry)
        if not os.path.isfile(path) or entry.startswith("."):
            continue
        stem, ext = os.path.splitext(entry)
        ext = ext.lower()
        # An allowlist, not an ignore list. Godot's importer, an editor's swap
        # file and a stray screenshot all end up in directories like this one,
        # and none of them should ever be mistaken for a job.
        if ext not in KNOWN_SUFFIXES:
            continue
        out.append((slug(stem), path, ext))
    return out


def strays():
    """Files in inbox/ that are neither an asset nor a sidecar, for reporting."""
    if not os.path.isdir(INBOX):
        return []
    keep = KNOWN_SUFFIXES + (".json", ".md", ".txt")
    return sorted(e for e in os.listdir(INBOX)
                  if os.path.isfile(os.path.join(INBOX, e))
                  and not e.startswith(".")
                  and os.path.splitext(e)[1].lower() not in keep)


def check_credit(name, path, config):
    missing = [f for f in CREDIT_FIELDS if not config.get(f)]
    if missing:
        raise Failure(
            "'%s' has no %s.\n"
            "    Set them once for everything you make in data/inbox.json under\n"
            "    \"defaults\", or for this asset alone in %s.\n"
            "    They end up in pack.json and CREDITS.md, which is why the\n"
            "    pipeline will not guess them."
            % (name, " or ".join(missing),
               os.path.relpath(sidecar_path(path), ROOT)))


def bake_options(config):
    bake = dict(config.get("bake", {}))
    unknown = set(bake) - set(BAKE_KEYS)
    if unknown:
        raise Failure("unknown bake setting(s) %s -- try one of: %s"
                      % (", ".join(sorted(unknown)), ", ".join(BAKE_KEYS)))
    if "forward" in bake and bake["forward"] not in sprite_bake.FORWARD_AXES:
        raise Failure("forward must be one of %s, not '%s'"
                      % (", ".join(sorted(sprite_bake.FORWARD_AXES)), bake["forward"]))
    return sprite_bake.Options(**bake)


def process_model(name, path, config, log):
    """A 3D model -> a baked pack directory. Returns the pack manifest."""
    try:
        model = glb.load(path)
    except glb.ModelError as exc:
        raise Failure(str(exc))
    for line in glb.describe(model):
        log("  " + line)
    broken = [m for m in model.materials if m.texture_error]
    if broken and not config.get("bake", {}).get("no_textures"):
        raise Failure(broken[0].texture_error)

    opts = bake_options(config)
    sheet, actor, notes = sprite_bake.bake(model, opts, log=log)

    pack_dir = os.path.join(PACKS, name)
    os.makedirs(pack_dir, exist_ok=True)
    sheet.save(os.path.join(pack_dir, "sheet.png"))
    # The model travels with the pixels: it is the source the sheet was cut
    # from, and without it a re-bake at a new production scale is a re-download.
    # It lives in a `source/` subdirectory carrying a `.gdignore`, because Godot
    # would otherwise import the .glb as a 3D scene and spray its extracted
    # textures and .import sidecars through the pack. The sheet beside it still
    # imports normally, which is the point of ignoring the subdirectory rather
    # than the pack.
    source_dir = os.path.join(pack_dir, "source")
    os.makedirs(source_dir, exist_ok=True)
    open(os.path.join(source_dir, ".gdignore"), "w").close()
    model_file = "model" + os.path.splitext(path)[1]
    shutil.copyfile(path, os.path.join(source_dir, model_file))

    manifest = {
        "name": name,
        "source": config["source"],
        "author": config["author"],
        "license": config["license"],
        "attribution": config.get("attribution") or "%s by %s (%s)" % (
            name, config["author"], config["license"]),
        "sheet": "sheet.png",
        "cell_size": list(actor["frame_size"]),
        "anchor": list(actor["anchor"]),
        "scale": 1,
        "tiles": {},
        "baked_from": "source/" + model_file,
        "bake": config.get("bake", {}),
        "actors": {
            name: {
                "sheet": "sheet.png",
                "frame_size": actor["frame_size"],
                "anchor": actor["anchor"],
                "directions": actor["directions"],
                "clips": actor["clips"],
            }
        },
    }
    path_out = os.path.join(pack_dir, "pack.json")
    with open(path_out, "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    log("  wrote %s" % os.path.relpath(path_out, ROOT))
    return manifest, notes


def process(name, path, ext, config, log):
    if ext in MODEL_SUFFIXES:
        return process_model(name, path, config, log)
    raise Failure(
        "'%s' is a %s file and the pipeline does not know what to do with it.\n"
        "    It bakes %s into isometric sprite sheets. A finished PNG sheet is\n"
        "    not an inbox job -- install it directly, per assets/packs/README.md."
        % (os.path.basename(path), ext or "extensionless",
           " and ".join(MODEL_SUFFIXES)))


def run_gates(log):
    """The normal gates, in the order that fails fastest and most clearly."""
    # `art` first because it needs no engine and catches the common failure
    # (a sprite that does not fit its cell) in a second. `import` before
    # `generate` because a sheet Godot has never seen has no `res://` path yet,
    # and every gate after it would fail on a texture that is plainly there.
    steps = [("art", ["tools/ci.sh", "art"]),
             ("import", ["tools/ci.sh", "import"]),
             ("generate", ["tools/ci.sh", "generate"]),
             ("test", ["tools/ci.sh", "test"])]
    for label, command in steps:
        log("\n==> %s" % label)
        result = subprocess.run(command, cwd=ROOT)
        if result.returncode != 0:
            raise Failure("`%s` failed. Nothing was rolled back -- read the "
                          "error above, fix it, and re-run." % " ".join(command))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("assets", nargs="*",
                        help="names to process (default: everything in inbox/)")
    parser.add_argument("--dry-run", action="store_true",
                        help="report what would happen without writing anything")
    parser.add_argument("--no-verify", action="store_true",
                        help="skip the art/generate/test gates after baking")
    parser.add_argument("--keep", action="store_true",
                        help="leave the source file in inbox/ after installing it")
    args = parser.parse_args(argv)

    log = print
    found = find_assets()
    if args.assets:
        wanted = {slug(a) for a in args.assets}
        found = [f for f in found if f[0] in wanted]
        missing = wanted - {f[0] for f in found}
        if missing:
            print("error: nothing in inbox/ named %s" % ", ".join(sorted(missing)),
                  file=sys.stderr)
            return 1
    if not found:
        left = strays()
        if left:
            print("nothing in inbox/ the pipeline handles. Ignored: %s\n"
                  "It bakes %s." % (", ".join(left), " and ".join(MODEL_SUFFIXES)))
        else:
            print("inbox/ is empty -- nothing to do.\n"
                  "Drop a .glb or .gltf in there and run this again.")
        return 0

    settings = load_settings()
    installed, problems = [], []
    for name, path, ext in found:
        log("\n==> %s (%s)" % (name, os.path.relpath(path, ROOT)))
        config = settings_for(name, path, settings)
        try:
            if ext in MODEL_SUFFIXES:
                check_credit(name, path, config)
            if args.dry_run:
                log("  would install assets/packs/%s/ as a %s"
                    % (name, config.get("kind", "actor")))
                continue
            _manifest, notes = process(name, path, ext, config, log)
            for note in notes:
                log("  note: %s" % note)
            installed.append(name)
            if not args.keep:
                os.remove(path)
                sidecar = sidecar_path(path)
                if os.path.isfile(sidecar):
                    os.remove(sidecar)
                log("  cleared inbox/%s" % os.path.basename(path))
        except Failure as exc:
            problems.append((name, str(exc)))
            log("  error: %s" % exc)

    if problems:
        print("\n%d asset(s) could not be installed:" % len(problems),
              file=sys.stderr)
        for name, message in problems:
            print("  %s: %s" % (name, message), file=sys.stderr)
        return 1
    if args.dry_run or not installed:
        return 0

    print("\ninstalled: %s" % ", ".join(installed))
    if args.no_verify:
        print("skipped the gates (--no-verify); run tools/ci.sh test before "
              "you push.")
        return 0
    try:
        run_gates(print)
    except Failure as exc:
        print("\nerror: %s" % exc, file=sys.stderr)
        return 1
    print("\nall gates green. Look at docs/art/actors.png, then commit "
          "assets/packs/ and the regenerated files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
