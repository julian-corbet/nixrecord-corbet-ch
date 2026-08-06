#!/usr/bin/env bash
# obs-headless-probe.sh — reproduces the ground-truth-gathering technique
# studies/obs-config-ground-truth.md is built on: launch a REAL, installed OBS Studio against a
# throwaway, fully isolated XDG_CONFIG_HOME, let it write its own default profile + scene
# collection, then optionally hand-author a scene item into the JSON and relaunch to see whether
# OBS accepts it silently, warns, or rejects it.
#
# WHY THIS EXISTS: this repo's home/nixrecord.nix renders OBS's own on-disk config format
# directly (JSON scene collections, an INI profile) rather than talking to OBS over its
# websocket API at runtime. That format is not officially documented as a stable public API, so
# every literal key/id/shape this module renders was checked against a REAL OBS binary rather
# than assumed from memory or scraped from a forum post — same evidentiary bar this whole
# project family holds itself to for other compositors' config grammars (see nixscroll's
# checks/config-accepted.nix). This script is that check, made reusable: rerun it after
# upgrading OBS to see whether anything this module depends on moved.
#
# SAFE TO RUN: everything happens under a throwaway temp directory. Nothing under your real
# ~/.config/obs-studio is read or touched. Requires an installed `obs` binary and `python3`
# (used only to pretty-print/diff JSON, not to drive OBS).
#
# Usage: ./obs-headless-probe.sh [workdir]   (workdir defaults to a fresh mktemp -d)
set -euo pipefail

WORKDIR="${1:-$(mktemp -d)}"
mkdir -p "$WORKDIR"/{xdgconfig,xdgcache,xdgdata}
cd "$WORKDIR"

echo "== nixrecord: obs-headless-probe =="
echo "workdir: $WORKDIR"
echo

run_obs() {
  # QT_QPA_PLATFORM=offscreen: no real display needed. --disable-shutdown-check and
  # --minimize-to-tray keep it from popping dialogs offscreen mode can't render anyway.
  # `timeout` because a headless OBS with no compositor never exits on its own once past
  # startup — SIGTERM after a few seconds of settled operation is expected, not a failure; a
  # nonzero/timeout exit code here does NOT mean the config was rejected, only that nothing
  # asked OBS to quit. What matters is what it WROTE and what it LOGGED, checked separately.
  QT_QPA_PLATFORM=offscreen \
    XDG_CONFIG_HOME="$WORKDIR/xdgconfig" \
    XDG_CACHE_HOME="$WORKDIR/xdgcache" \
    XDG_DATA_HOME="$WORKDIR/xdgdata" \
    timeout 15 obs --disable-shutdown-check --minimize-to-tray >"$WORKDIR/obs.log" 2>&1 || true
}

echo "-- pass 1: first launch, let OBS create its own defaults --"
run_obs
SCENE_FILE=$(find "$WORKDIR/xdgconfig/obs-studio/basic/scenes" -maxdepth 1 -name '*.json' ! -name '*.bak' | head -1)
if [ -z "$SCENE_FILE" ]; then
  echo "FAILED: no scene collection file was created — obs-studio may not be installed, or crashed before writing config. Check $WORKDIR/obs.log." >&2
  exit 1
fi
echo "created: $SCENE_FILE"
echo "created: $(find "$WORKDIR/xdgconfig/obs-studio/basic/profiles" -name basic.ini)"
echo

echo "-- pass 2: inject a hand-authored scene item (color_source), relaunch, check for parse warnings --"
python3 - "$SCENE_FILE" <<'PYEOF'
import json, sys, uuid

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

color_uuid = str(uuid.uuid4())
data["sources"].append({
    "prev_ver": 0, "name": "ProbeColor", "uuid": color_uuid,
    "id": "color_source", "versioned_id": "color_source_v3",
    "settings": {"color": 4278190335, "width": 1920, "height": 1080},
    "mixers": 0, "sync": 0, "flags": 0, "volume": 1.0, "balance": 0.5,
    "enabled": True, "muted": False, "push-to-mute": False, "push-to-mute-delay": 0,
    "push-to-talk": False, "push-to-talk-delay": 0, "hotkeys": {},
    "deinterlace_mode": 0, "deinterlace_field_order": 0, "monitoring_type": 0,
    "private_settings": {},
})

for src in data["sources"]:
    if src["id"] == "scene":
        src["settings"]["items"] = [{
            "name": "ProbeColor", "source_uuid": color_uuid,
            "visible": True, "locked": False, "rot": 0.0,
            "pos": {"x": 100.0, "y": 50.0}, "scale": {"x": 1.0, "y": 1.0},
            "align": 5, "bounds_type": 1, "bounds_align": 0, "bounds_crop": False,
            "bounds": {"x": 400.0, "y": 300.0},
            "crop_left": 0, "crop_top": 0, "crop_right": 0, "crop_bottom": 0,
            "id": 1, "group_item_backup": False, "scale_filter": "disable",
            "blend_method": "default", "blend_type": "normal",
            "show_transition": {"duration": 0}, "hide_transition": {"duration": 0},
            "private_settings": {},
        }]
        src["settings"]["id_counter"] = 1

with open(path, "w") as f:
    json.dump(data, f, indent=2)
print(f"injected ProbeColor scene item into {path}")
PYEOF

cp "$SCENE_FILE" "$WORKDIR/before-pass2.json"
run_obs

echo
echo "-- results --"
echo "warnings/errors that look parse-related (ignore GL/swapchain noise — expected offscreen):"
grep -iE "warn|error|unknown|invalid|reject" "$WORKDIR/obs.log" \
  | grep -viE "swap chain|gl_platform|geometry|sentinel|propagateSize|decklink|nvenc|nvidia" \
  || echo "  (none)"
echo
if diff -q "$WORKDIR/before-pass2.json" "$SCENE_FILE" >/dev/null 2>&1; then
  echo "scene file byte-identical after reload (no normalization occurred)"
else
  echo "OBS rewrote the scene file on reload — diff (formatting/added fields are expected; a DROPPED field is the interesting case):"
  diff -u "$WORKDIR/before-pass2.json" "$SCENE_FILE" || true
fi
echo
echo "workdir left in place for inspection: $WORKDIR"
