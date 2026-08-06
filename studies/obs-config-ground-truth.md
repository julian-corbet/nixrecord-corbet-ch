# Ground-truthing OBS's on-disk config format

OBS's own scene-collection JSON and profile INI are not a documented, versioned public API —
unlike e.g. sway/scroll's config grammar, which has man pages this project family's nixscroll
already leans on. `home/nixrecord.nix` renders both directly (per this repo's brief: OBS as the
encode engine, Nix as the interface — not a runtime websocket client), so every field it emits
needed to be checked against a real binary rather than assumed from memory or a forum post. This
is the writeup of that process: what was checked, how, and — as importantly — what was tried and
came back unconfirmed, or came back CONFIRMED WRONG (Method 4 caught a real mistake in this
module's own first draft, not just a hypothetical one), which is why some fields this module
could plausibly render (a CQP/ICQ quality value, a couple of `FPSType` mode numbers) don't appear
in v1, and why the VAAPI encoder ids below don't match what a `strings` search alone would have
suggested.

Methods 1-3 are reproducible end-to-end via
[`../experiments/obs-headless-probe.sh`](../experiments/obs-headless-probe.sh). Method 4 (feeding
this module's OWN rendered output back into a headless OBS) was run ad hoc against a `nix eval`
of `home/nixrecord.nix` during development rather than scripted into `experiments/` — a real gap;
turning it into a rerunnable script (ideally the same one `checks/config-rendering.nix` could
eventually call from inside `nix flake check`, per that check's own header) is the natural next
step here, not yet done.

Performed against OBS Studio 32.1.2 (Arch `extra/obs-studio`, package `32.1.2-7.1`); a version
bump could move any of this, which is exactly why the script is kept runnable rather than this
document being treated as permanent truth.

## Method 1: run the real binary headless, let it write its own defaults

```
QT_QPA_PLATFORM=offscreen XDG_CONFIG_HOME=$scratch/xdgconfig timeout 15 obs \
  --disable-shutdown-check --minimize-to-tray
```

`QT_QPA_PLATFORM=offscreen` needs no display server at all — OBS still runs its full startup
path (module loading, PipeWire/PulseAudio device enumeration, default-scene creation), just
without a window. It cannot render actual GPU frames this way (`gl_platform_init_swapchain
failed` shows up in the log every time — expected noise, not a real failure, and this repo's
`experiments/obs-headless-probe.sh` explicitly filters it out of the warnings it greps for), but
config load/parse/save all happen on the CPU side and work fully.

This produced a REAL default profile (`basic/profiles/Untitled/basic.ini`) and a REAL default
scene collection (`basic/scenes/Untitled.json`), confirming:

- The exact directory layout `home/nixrecord.nix` targets:
  `basic/profiles/<name>/{basic.ini,recordEncoder.json}` and `basic/scenes/<name>.json`.
- The scene collection's top-level shape: `sources` (a flat list — scenes are just another entry
  in it, `id == "scene"`), `scene_order`, `current_scene`/`current_program_scene`, `transitions`/
  `quick_transitions`, `modules`, `version`.
- The default audio sources OBS itself creates (`DesktopAudioDevice1`/`AuxAudioDevice1`) and,
  critically, their settings shape: `"settings": {"device_id": "default"}` — CONFIRMING that
  `device_id` is the literal key `programs.nixrecord.audio.sink`/`micSink` needed to target, and
  that `"default"` (not e.g. `null` or an empty string) is what OBS's own default-following mode
  actually writes, which is exactly what `followSystemDefault` renders when opted into.
- The real source ids: `pulse_output_capture`, `pulse_input_capture` for audio.

## Method 2: `strings` on the installed binaries, for literal keys and ids

INI keys and encoder/source ids are compiled-in literals — `strings` on the actual `.so`/binary
finds them without needing to trigger the UI path that would write them. This is how every
`basic.ini` key this module renders (`BaseCX`, `BaseCY`, `OutputCX`, `OutputCY`, `FPSType`,
`FPSCommon`, `ColorFormat`, `ColorSpace`, `ColorRange`, `ScaleType`, `RecType`, `RecFormat2`,
`RecEncoder`, `RecAudioEncoder`, `RecFilePath`, `RecTracks`) and every source id
(`pipewire-screen-capture-source`, `pipewire-window-capture-source`,
`pipewire-desktop-capture-source`, `pipewire-camera-source`, `pulse_output_capture`,
`pulse_input_capture`, `obs_x264`, `ffmpeg_aac`, `ffmpeg_opus`, `color_source`) was confirmed
present, literally, in `/usr/sbin/obs` or the relevant `/usr/lib/obs-plugins/*.so` before being
used in `home/nixrecord.nix` — never typed from memory alone.

Also how the `recordEncoder.json` KEYS (not yet the VAAPI encoder IDs — see Method 4 below for
why those needed a stronger check) were confirmed: `rate_control`, `bitrate`, `profile`, `level`,
`preset`, `keyint_sec`, `device` all appear as literal strings in `obs-ffmpeg.so`.

**This method also found `av1_vaapi`/`hevc_vaapi`/`h264_vaapi` as real, standalone strings in
`obs-ffmpeg.so` — and this project's first draft trusted them as the modern/preferred VAAPI
encoder ids, reading `*_ffmpeg_vaapi`/`*_ffmpeg_vaapi_tex` as an older compatibility path by
name-pattern intuition alone. Method 4 proved that reading wrong.** A string existing in a
binary proves it is spelled that way somewhere in the source (a comment, a different subsystem,
a name only used internally); it does not prove it is the specific `obs_encoder` id a given
build actually registers. This is the concrete reason Method 2 is ranked below Method 1/3's live
round-trip and Method 4's live registration check in this document's own confidence ordering.

## Method 3: hand-author, reload, diff — does the real binary accept it?

The scene-item transform schema (`pos`, `scale`, `bounds`, `crop_*`, `align`, `bounds_type`, ...)
is the part with no man page and no bundled example to read off of, so it was tested the way
nixscroll's `checks/config-accepted.nix` tests scroll directives: write a plausible item by hand,
point a real OBS at it, and see what comes back.

A `color_source` (needs no portal, no display, no real capture device — the cheapest source type
that still exercises the full scene-item path) was appended to a default scene's `sources`, and
one hand-authored item referencing it was appended to the scene's own `settings.items`, using a
field set built from general OBS domain knowledge (this part WAS a plausible guess going in, not
yet a confirmed one): `name`, `source_uuid`, `visible`, `locked`, `rot`, `pos`, `scale`, `align`,
`bounds_type`, `bounds_align`, `bounds_crop`, `bounds`, `crop_{left,top,right,bottom}`, `id`,
`group_item_backup`, `scale_filter`, `blend_method`, `blend_type`, `show_transition`,
`hide_transition`, `private_settings`.

Reloading OBS against this file produced **zero parse warnings or errors**, and OBS re-saved the
item with every hand-authored field preserved byte-for-byte (modulo JSON re-indentation) — it
ADDED four fields of its own (`scale_ref`, `pos_rel`, `scale_rel`, `bounds_rel`, all
auto-computed bookkeeping for the editor's own canvas-resize rescaling, not required input) but
dropped nothing and complained about nothing. That is a genuine positive result, not an absence
of evidence: OBS's ini/JSON loaders are known to warn loudly on an unrecognized command/key in
other contexts (this is exactly the failure mode nixscroll's own `config-accepted.nix` exists to
catch for scroll), so a silent, unmodified accept is real signal that the field set above is
both sufficient and exactly what OBS expects — not just "didn't crash".

`home/nixrecord.nix`'s own `sceneItem` renders precisely this confirmed field set (see that
function).

## Method 4: point a headless OBS at THIS module's OWN rendered output

The strongest check available, run last, after `home/nixrecord.nix` had a first working draft:
actually `nix eval` the module's real `renderBasicIni`/`renderRecordEncoderJson`/
`renderSceneCollection` output for a representative profile, write it into a throwaway
`XDG_CONFIG_HOME` (plus a `user.ini` `[Basic]` stanza pointing OBS at that profile/collection by
name — NOT `global.ini`, which holds no such section; see README's "Not managed" for why this
repo's own module never writes either file itself), and read the log.

This is what caught the encoder-id mistake Method 2 had walked into. The rendered
`RecEncoder=av1_vaapi` was rejected outright:

```
error: Encoder ID 'av1_vaapi' not found
```

while the same log's own module-loading section showed exactly which encoder ids `obs-ffmpeg.so`
actually registered:

```
info: VAAPI: API version 1.24
info: FFmpeg VAAPI H264 encoding supported
info: FFmpeg VAAPI AV1 encoding supported
info: FFmpeg VAAPI HEVC encoding supported
info:   Loaded Modules:
info:     obs-ffmpeg.so
info: 	- ffmpeg_vaapi_tex (FFmpeg VAAPI H.264)
info: 	- av1_ffmpeg_vaapi_tex (FFmpeg VAAPI AV1)
info: 	- hevc_ffmpeg_vaapi_tex (FFmpeg VAAPI HEVC)
```

`home/nixrecord.nix`'s `codecEncoderId` was corrected to these three ids (note the H264 one
carries no "h264" in its own name — confirmed from this same log line, not a typo). Re-running
the same check with the corrected ids produced no further encoder-related error.

**Why this doesn't extend to the capture SOURCE ids the same way.** The same run also logged:

```
info: [pipewire] No capture sources available
error: Source ID 'pipewire-window-capture-source' not found
error: Source ID 'pipewire-screen-capture-source' not found
```

— structurally the same "not found" shape as the encoder mistake, which is worth being honest
about rather than waving away. The distinguishing evidence is the *self-explanatory* preceding
line: `linux-pipewire.so` explicitly reports zero available capture sources, which is exactly
what this headless container (no `xdg-desktop-portal` backend reachable, no live ScreenCast
service) would produce regardless of whether the id strings are right — unlike the encoder case,
where the log gave no "unavailable" framing at all and instead listed concrete, different,
successfully-registered alternatives in the same breath as the rejection. Both ids were also
independently confirmed as real `strings` literals in `linux-pipewire.so` (Method 2) with no
`*_tex`/`ffmpeg_*`-style alternate spelling anywhere in that binary's string table the way the
VAAPI encoders had one — a second, independent signal the encoder case didn't have going for it
either. Kept as-is on that basis, but flagged here rather than asserted with the same confidence
as the encoder correction: this repo has NOT yet run this exact check inside a real desktop
session with a live portal, which is the only way to close this gap completely.

## What did NOT come back confirmed

Stated here rather than silently omitted, because absence-of-evidence is a genuinely different
claim from a field this project actively decided against:

- **A CQP/ICQ quality-value key for the VAAPI encoders.** `strings` on `obs-ffmpeg.so` turned up
  `rate_control` (the mode selector) and the format string `"cqp:          %d"` in a debug log
  line — evidence the CONCEPT exists — but no standalone `cqp`/`qp`/`quality`-shaped literal
  that would be the actual JSON key for its value. `programs.nixrecord.profiles.<name>.rateControl`
  is therefore `CBR`/`VBR` only in v1; see that option's own description.
- **The exact `FPSType` mode integers for Integer/Fraction FPS.** Only the locale-string LABELS
  (`Basic.Settings.Video.FPSCommon`/`FPSInteger`/`FPSFraction`) were found, and a `strings | sort`
  pass (this document's own author's first attempt) throws away the binary's original ordering,
  which is the only weak signal available short of reading source — so it tells you nothing.
  `FPSType = 0` for the "Common" mode is used in `home/nixrecord.nix` on product-convention
  confidence (it is OBS's own first/default FPS mode, universally so in every real config this
  project's author has seen), explicitly flagged in that file as a WEAKER confirmation tier than
  the round-tripped scene-item schema above — and `fps` is restricted to OBS's actual
  `FPSCommon` literal value set specifically so the Integer/Fraction modes never have to be
  resolved at all.
- **`bounds_type`'s exact integer for "Stretch".** Same tier as `FPSType`: the locale strings
  recovered from the binary (`None`, `Stretch`, `ScaleInner`, `ScaleOuter`, `ScaleToWidth`,
  `ScaleToHeight`, `MaxOnly`) came back in an order matching the well-known `obs_bounds_type` C
  enum — moderately strong circumstantial evidence, not the same tier as a round-tripped value.
- **A real capture-source `settings` payload for `pipewire-screen-capture-source`/
  `pipewire-window-capture-source`.** Both were only ever created empty, un-activated, offscreen
  — actually negotiating a portal ScreenCast session needs a live compositor and a human
  approving a picker dialog, neither available in this harness. What's confirmed is that the
  SOURCE IDS are real and that empty `settings = {}` is at minimum not rejected at load time
  (Method 1/2's default-scene sources loaded fine); what's NOT confirmed is what OBS itself
  fills in once a real portal session starts, including any restore-token field it might add.
  See README's "What Nix can and can't declare about a capture source" for why this is treated
  as an architectural fact rather than a gap to close later.
