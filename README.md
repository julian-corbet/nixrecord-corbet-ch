# nixrecord

Declarative screen/window/region recording via [OBS Studio](https://obsproject.com) — OBS as the
encode engine, Nix as the interface. A user declares a recording INTENT (a named profile: canvas
resolution, codec, bitrate, which sources go where); this repo renders the OBS files that intent
actually needs — `~/.config/obs-studio/basic/profiles/<name>/{basic.ini,recordEncoder.json}` and
`~/.config/obs-studio/basic/scenes/<name>.json` — the same way
[nixscroll](https://github.com/julian-corbet/nixscroll-corbet-ch) renders a compositor config
from structured options instead of hand-edited text.

Geared at a wlroots/Arch desktop — developed and ground-truthed against
[nixarch](https://github.com/julian-corbet/nixarch-corbet-ch) and a real Intel Lunar Lake /
Arc 140V laptop iGPU (see `studies/`) — but nothing in the mechanism assumes a specific machine.

## The split

Two pieces:

**Config generation** (`homeManagerModules.nixrecord`, namespace `programs.nixrecord`) — a
home-manager module that renders the three files above from `programs.nixrecord.profiles.<name>`.
Installs nothing: it assumes an `obs` binary exists somewhere (installed by the NixOS module
below, the Arch module, or by hand) and writes config for it.

**System install** — `nixosModules.nixrecord` (installs `pkgs.obs-studio`) and
`systemManagerModules.nixrecord` (declares `obs-studio` into
[nixarch](https://github.com/julian-corbet/nixarch-corbet-ch)'s `nixarch.packages.pacman`
reconciler — the *official*-repo list, not `.aur`; see `modules/system-manager.nix` for how that
was confirmed rather than assumed).

**No `packages` output.** Unlike nixscroll (which packages `scroll` itself because scroll has no
home in nixpkgs), OBS Studio already lives in both nixpkgs (`pkgs.obs-studio`) and the Arch
official repos. There is nothing here for a third packaging path to add.

| Output | Class | Owns |
|---|---|---|
| `homeManagerModules.nixrecord` (`.default`) | home-manager | `~/.config/obs-studio/basic/{profiles,scenes}/*`, generated from `programs.nixrecord.*`. Installs nothing. |
| `nixosModules.nixrecord` (`.default`) | NixOS | `environment.systemPackages` for `programs.nixrecord.package` (default `pkgs.obs-studio`) |
| `systemManagerModules.nixrecord` (`.default`) | Arch/CachyOS | `nixarch.packages.pacman = [ "obs-studio" ... ]` |

## One profile is one canvas is one encode

`programs.nixrecord.profiles.<name>` bundles four things that might look like independent axes
but are deliberately NOT split apart: a canvas resolution+fps, a codec+bitrate+container, a set
of named capture `sources`, and a `layout` placing each source on the canvas. One name renders
one OBS profile (encode settings) and one identically-named OBS scene collection (the composite).

This pairing is load-bearing, not cosmetic: a scene item's `pos`/`bounds` in OBS's own JSON are
pixels in the currently-ACTIVE PROFILE's base canvas, not scene-collection-local coordinates.
Decoupling "what resolution am I encoding at" from "where did I place this window on the canvas"
would let the two silently drift — a scene collection built assuming a 4K canvas, loaded under a
1080p profile, with every item's declared position now describing the wrong quarter of the
frame. Keeping them 1:1 per named profile makes that drift structurally impossible instead of a
discipline to remember.

## Composite once, encode once

The single most important design principle in this repo, and the reason `layout` exists at all
instead of a bare list of sources: **recording N sources means N entries in ONE scene, composited
onto ONE canvas, encoded by ONE `RecEncoder` — never N separate recording outputs.**

This is not a stylistic preference. `studies/av1-vaapi-pixel-budget.md` measures why, on real
hardware: AV1 VAAPI encode on an integrated GPU is a **pixel-rate ceiling** (~1.05 gigapixels/
second, measured two independent ways), not a stream-count limit the way consumer NVENC's 3-session
cap is. Running one encode at that resolution×fps or three concurrent encodes summing to the same
total pixel rate measure the SAME aggregate throughput — concurrency buys nothing, it only adds
N-1 redundant copies of scene-compositing and container-muxing overhead on top of an unchanged
shared budget. `programs.nixrecord.profiles.<name>.sources`/`.layout` render that composite
directly: there is no option surface anywhere in this module that could produce a second
`RecEncoder` for the same profile.

Realtime recording also needs headroom the study's raw numbers don't include on their own — see
"Plan capacity at roughly 70% of the measured ceiling" in that same document. A dropped frame in
a live capture is unrecoverable, unlike a batch encode that can simply run slower.

## Encoder selection: declared, never detected

`programs.nixrecord.profiles.<name>.codec` is `av1` / `hevc` / `h264` / `software`
(`obs_x264` — CPU, correct on any machine, and the module's default for exactly that reason, not
as a recommendation to actually record on it). AV1/HEVC/H264 hardware encode is **generation-
dependent, not just vendor-dependent**: AMD RDNA2 has AV1 *decode* but not *encode* — that arrived
with RDNA3 — and Intel needs Arc/Xe or roughly an 11th-gen-Core-or-newer Quick Sync block for AV1
encode specifically. This module cannot detect that for you: Nix evaluation happens wherever the
flake is built, not necessarily on the machine the config will run on, so an eval-time hardware
probe would as often as not answer for the wrong box — the same "declared, never detected"
doctrine [nixarch](https://github.com/julian-corbet/nixarch-corbet-ch)'s own `packages.distro`
option documents.

Get it wrong and OBS itself refuses to start the recording with a real, loud error. What this
module adds is `fallbackCodecs` — a list that renders one COMPLETE sibling profile per entry
(`<name>-fallback-<codec>`, identical in every other setting), so an alternative is a one-click
profile switch away in OBS's own UI rather than something to hand-configure while a recording is
already failing. OBS's file format has no config-level "try A, then B" primitive to render even
if this module wanted one — this is the honest shape of what Nix actually can pre-build here.

## Audio: pin the sink, never follow "default"

`programs.nixrecord.audio.sink`/`.micSink` take an exact PipeWire/PulseAudio node name (`pactl
list short sinks`), rendered as the literal `device_id` OBS's `pulse_output_capture`/
`pulse_input_capture` sources use. Left `null` (the default for both), no audio source is
rendered into the scene collection at all — no audio is preferable to silently wrong audio.

**Do not reach for `followSystemDefault` without reading its own docstring first.** `device_id =
"default"` means "whatever PipeWire's policy daemon currently calls the default sink" —
re-evaluated on every device event, not fixed when a recording starts. That is a real, observed
failure mode: a policy daemon re-elects the default sink whenever any device appears or
disappears, and on a machine that also mirrors audio from another host over a network audio
fabric (a sink that "appears" over the network rather than being plugged in locally), that
re-election can silently point a live recording's captured audio at a sink physically producing
sound on a DIFFERENT machine — with the level meters still moving, because something is still
being captured, just not what was intended. This has actually happened, on a real streaming host
in this project's own reference estate. Pinning the literal node name is the fix: PipeWire's
re-election can change what "default" MEANS, never what a literal name resolves to.

## What Nix can and can't declare about a capture source

`programs.nixrecord.profiles.<name>.sources.<name>.type` is `output`, `window`, or `region` —
rendering OBS's real `pipewire-screen-capture-source` / `pipewire-window-capture-source` source
ids (zero-copy DMA-BUF capture, driven by OBS's own `linux-pipewire` plugin through the
`org.freedesktop.portal.ScreenCast` desktop portal — confirmed against the installed plugin
binary, see `studies/obs-config-ground-truth.md`).

What this module CANNOT do, and does not pretend to: pre-select WHICH monitor or WHICH window.
The portal's ScreenCast flow is deliberately interactive — a human picks the target in a live
picker dialog the first time a source of this kind activates, and only a portal-issued restore
token (opaque, minted at runtime, not something Nix can synthesize ahead of time) lets a later
activation skip that picker. `region` mode is not a distinct portal capture type at all on any
compositor this was checked against; it's rendered as an `output` capture plus a scene-item crop
(`sources.<name>.region`), which IS something Nix can fully pre-declare, because it operates on
pixels OBS already has rather than needing the portal to understand "just this rectangle".

This is stated as a property of the underlying capture mechanism, not treated as a gap this
module will close later — see `studies/obs-config-ground-truth.md`'s own closing section for what
was and wasn't confirmed about it.

## Not managed: global.ini / user.ini

`global.ini` and `user.ini` hold OBS's own LAST-USED profile/scene-collection selection, dock
layout, and window geometry — session state, not intent. This module never touches either file.
Rendering a `Profile=`/`SceneCollection=` line into `global.ini` was considered and rejected: it
would mean every manual profile switch in OBS's own UI (a one-off tweak, trying the fallback
profile by hand) gets silently reverted on the next `home-manager switch` — the exact "Nix fights
the running program for control of its own runtime state" footgun nixscroll's own `home/scroll.nix`
avoids for the same reason (it writes `~/.config/scroll/config`, never scroll's own runtime IPC
state). Activation — which profile/scene collection OBS opens by default — stays a manual choice.

## Usage

```nix
{
  imports = [ inputs.nixrecord.homeManagerModules.nixrecord ];

  programs.nixrecord = {
    enable = true;

    encoder.device = "/dev/dri/by-path/pci-0000:00:02.0-render"; # by-path, not renderD1XX — see option doc
    audio.sink = "alsa_output.pci-0000_00_1f.3.analog-stereo.monitor"; # pactl list short sinks

    profiles.screencast = {
      canvas = { width = 1920; height = 1080; };
      fps = "60";
      codec = "av1";
      fallbackCodecs = [ "hevc" "software" ];
      rateControl = "CBR";
      bitrate = 16000;
      sources.desktop = { type = "output"; };
    };

    profiles.demo-with-cam = {
      canvas = { width = 1920; height = 1080; };
      fps = "30";
      codec = "hevc";
      rateControl = "CBR";
      bitrate = 12000;
      sources.desktop = { type = "output"; };
      sources.webcam-window = { type = "window"; };
      layout.webcam-window = { x = 1520; y = 780; width = 360; height = 270; };
    };
  };
}
```

Add the system side only if you want OBS installed by this repo rather than some other way:

```nix
{ imports = [ inputs.nixrecord.nixosModules.nixrecord ]; programs.nixrecord.enable = true; }
# or, on Arch via nixarch:
{ imports = [ inputs.nixrecord.systemManagerModules.nixrecord ]; nixrecord.install.enable = true; }
```

## Mechanism public, values private

Every id/key this module renders is either OBS's own real internal identifier (confirmed against
the real binary — see `studies/obs-config-ground-truth.md`) or a neutral placeholder. No default
here bakes in a specific machine's sink name, output name, GPU render-node path, or bitrate —
`profiles` is `{}` by default, `audio.sink`/`micSink`/`encoder.device` are all `null`. A
consumer's own hardware and hostnames go in their own config, never in this repo's defaults.

## No invented numbers

`bitrate` has no default — the right value depends on resolution, codec, and content in a way no
single number is correct across every profile a consumer might declare (see that option's own
docstring for a starting-point range, explicitly labeled as a starting point, not a fact).
`rateControl` stops at `CBR`/`VBR` rather than also offering `CQP`/`ICQ`, because the settings-dict
key that would carry a CQP/ICQ quality VALUE did not come back confirmed against the real
binary's own string table — left out rather than guessed. See
`studies/obs-config-ground-truth.md`'s "What did NOT come back confirmed" for the full list.

## Status

Pre-alpha scaffold. Verified so far: `home/nixrecord.nix`'s option tree evaluates cleanly
(`lib.evalModules` against a home-manager stand-in, `checks/config-rendering.nix`) and renders
the expected `basic.ini`/`recordEncoder.json`/scene-collection JSON for a representative set of
options, including the `fallbackCodecs` sibling-profile expansion, the composite-once layout
seam (a source with no `layout` entry fills the whole canvas; an explicit entry positions and
sizes it; nothing renders a second `RecEncoder`), and the audio pinning-vs-`followSystemDefault`
distinction. Every literal id/key the renderer emits was checked against a real, installed OBS
Studio 32.1.2 — see `studies/obs-config-ground-truth.md` for the methodology and, importantly,
what was checked and came back UNCONFIRMED (a CQP/ICQ quality key, a couple of enum-integer
values inferred from string ordering rather than round-tripped).

**Not yet verified**: an actual `home-manager switch` producing a profile+scene pair OBS opens
and records from without complaint end to end (the closest proxy — hand-authoring a scene item
and reloading it through the real binary — worked, and is exactly what
`experiments/obs-headless-probe.sh` reproduces, but that is a narrower claim than "this exact
generated file, loaded via OBS's normal Settings/scene-picker UI, records cleanly"). **Not yet
attempted**: a `nix flake check`-sandboxed real-OBS acceptance check in the style of nixscroll's
`checks/config-accepted.nix` — see `flake.nix`'s own comment on why that was left out of v1
rather than built to a lower standard than the rest of this repo's evidentiary bar.

## Related projects

nixrecord is one of several small, independently-usable open-source projects sharing a common
design system: [nixscroll](https://github.com/julian-corbet/nixscroll-corbet-ch) (declarative
compositor config) and [nixarch](https://github.com/julian-corbet/nixarch-corbet-ch) (declarative
Arch/AUR package convergence, which this repo's own Arch install plane depends on) cover adjacent
ground on the same Nix-on-a-real-desktop theme.

## License

[MIT License](LICENSE) © 2026 Julian Corbet
