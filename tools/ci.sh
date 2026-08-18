#!/usr/bin/env bash
#
# One entry point for every check, so CI and a human run exactly the same thing.
#
#   tools/ci.sh setup     download Godot + the web export templates into .tools/
#   tools/ci.sh import     re-import assets (must run before anything else)
#   tools/ci.sh generate   regenerate the art, the baked tileset and the sheets
#   tools/ci.sh sheets     re-render docs/art/ only (no Godot needed)
#   tools/ci.sh test       run the headless test suite
#   tools/ci.sh export     build the web export into build/web/
#   tools/ci.sh all        import + test + export
#
# Set GODOT_BIN to use a Godot you already have; otherwise `setup` puts one in
# .tools/ and everything else picks it up from there.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
GODOT_VERSION="$(tr -d '[:space:]' < .godot-version)"
TOOLS_DIR="$ROOT/.tools"
GODOT_BIN="${GODOT_BIN:-$TOOLS_DIR/godot}"
RELEASES="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable"
TEMPLATE_DIR="${HOME}/.local/share/godot/export_templates/${GODOT_VERSION}.stable"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

need_godot() {
  [ -x "$GODOT_BIN" ] || die "no Godot at $GODOT_BIN -- run tools/ci.sh setup (or set GODOT_BIN)"
}

# Godot reports broken scripts and failed resources on stdout/stderr but still
# exits 0. Every gate below therefore runs through this: it echoes the output,
# preserves the real exit code, and fails on any engine-level error.
run_godot() {
  local log
  log="$(mktemp)"
  set +e
  "$GODOT_BIN" --headless --path "$ROOT" "$@" 2>&1 | tee "$log"
  local status=${PIPESTATUS[0]}
  set -e
  if grep -qE 'SCRIPT ERROR|Parse Error|^ERROR:|^USER ERROR:' "$log"; then
    rm -f "$log"
    die "Godot reported an error above (see SCRIPT ERROR / ERROR lines)"
  fi
  rm -f "$log"
  return $status
}

cmd_setup() {
  mkdir -p "$TOOLS_DIR"
  if [ ! -x "$TOOLS_DIR/godot" ]; then
    say "Downloading Godot ${GODOT_VERSION}"
    curl -fsSL -o "$TOOLS_DIR/godot.zip" "$RELEASES/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip"
    unzip -q -o "$TOOLS_DIR/godot.zip" -d "$TOOLS_DIR"
    mv "$TOOLS_DIR/Godot_v${GODOT_VERSION}-stable_linux.x86_64" "$TOOLS_DIR/godot"
    chmod +x "$TOOLS_DIR/godot"
    rm -f "$TOOLS_DIR/godot.zip"
  fi
  "$TOOLS_DIR/godot" --headless --version

  if [ "${WITH_EXPORT_TEMPLATES:-1}" = "1" ] && [ ! -f "$TEMPLATE_DIR/web_nothreads_release.zip" ]; then
    say "Downloading export templates (only the web ones are kept)"
    local tmp
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/templates.tpz" "$RELEASES/Godot_v${GODOT_VERSION}-stable_export_templates.tpz"
    unzip -q -o "$tmp/templates.tpz" -d "$tmp"
    mkdir -p "$TEMPLATE_DIR"
    # The full set is ~2 GB; the web build needs ~85 MB of it.
    cp "$tmp"/templates/web_* "$tmp"/templates/version.txt "$TEMPLATE_DIR/"
    rm -rf "$tmp"
    du -sh "$TEMPLATE_DIR"
  fi
}

cmd_import() {
  need_godot
  say "Importing assets"
  # Twice on purpose: the first pass generates the script class cache that the
  # second pass needs to resolve class_name references inside scenes.
  run_godot --import >/dev/null
  run_godot --import >/dev/null
  echo "import ok"
}

# Split out from generate on purpose: rendering the sheets needs no engine, so
# an agent can look at the art without installing Godot at all.
cmd_sheets() {
  say "Rendering contact sheets"
  python3 tools/art_sheet.py
  say "Rendering maps"
  python3 tools/render_map.py
}

cmd_generate() {
  need_godot
  say "Regenerating art"
  python3 tools/gen_art.py
  say "Baking the tileset"
  run_godot --script res://tools/build_tileset.gd
  cmd_sheets
}

cmd_test() {
  need_godot
  say "Running tests"
  run_godot --script res://tests/run_tests.gd -- "$@"
}

cmd_export() {
  need_godot
  [ -f "$TEMPLATE_DIR/web_nothreads_release.zip" ] \
    || die "web export templates missing -- run tools/ci.sh setup"
  say "Exporting for the web"
  rm -rf "$ROOT/build/web"
  mkdir -p "$ROOT/build/web"
  run_godot --export-release "Web" build/web/index.html >/dev/null
  [ -f "$ROOT/build/web/index.wasm" ] || die "export produced no index.wasm"
  # GitHub Pages serves any path starting with _ or . through Jekyll and would
  # eat some of these files; .nojekyll turns that off.
  touch "$ROOT/build/web/.nojekyll"
  ls -la "$ROOT/build/web"
}

case "${1:-all}" in
  setup)    cmd_setup ;;
  import)   cmd_import ;;
  generate) cmd_generate ;;
  sheets)   cmd_sheets ;;
  test)     shift; cmd_test "$@" ;;
  export)   cmd_export ;;
  all)      cmd_import; cmd_test; cmd_export ;;
  *)        die "unknown command '$1' (try: setup, import, generate, sheets, test, export, all)" ;;
esac
