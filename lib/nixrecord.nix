#
# The capture catalogue: what a capture session needs installed on the one host that can run one
# — see README's "The catalogue" for the shape this file follows (same as nixsh's lib/tools.nix
# and nixmedia's lib/media.nix) and the placement rule that decides what belongs here at all.
#
# Three groups today, each a direct application of that rule:
#
#   capture — the engine and what it needs to see and hear real hardware: OBS itself, the V4L2
#             userspace tooling, and the capture-chain filters OBS loads (noise suppression,
#             per-application PipeWire audio capture).
#   control — physical control surfaces driving a live session, and the client a button press
#             actually calls. OBS's own websocket server ships in-tree (obs-websocket.so, part of
#             the `obs-studio` entry below) — nothing here re-implements a control channel that
#             already exists.
#   edit    — kdenlive and shotcut, two faces of the shared MLT engine rather than competing
#             alternatives: kdenlive for the involved stuff (multicam switching, mature proxy
#             editing), shotcut for the quick stuff (maintained by MLT's own maintainer, its
#             `.mlt` project file raw MLT XML). A project authored in one opens in the other.
#
# No `perform` group yet: README describes it (instruments whose output is a performance that
# happened once), but nothing catalogued below belongs there — a group with no approved entry
# stays unwritten rather than pre-declared empty, same restraint nixmedia's own lib/media.nix
# documents for why a third `players`-shaped group waited for an actual second entry.
#
# `arch` is the pacman package, `nixpkgs` the attribute (dotted path for a nested one, e.g. the
# `obs-pipewire-audio-capture` entry below). `aur` (default false) marks a pacman name that lives
# in the AUR rather than an official repo — load-bearing, not cosmetic: `pacman -S` fails the
# WHOLE transaction on an AUR name with "target not found", taking every other package in the same
# converge down with it.
#
# Every (arch, nixpkgs) pair below was verified against a REAL system, not guessed, on
# The reference laptop — the one host this repo targets (see README's "Single-host by construction"):
# `pacman -Si <name>` (official repo) or `paru -Si <name>` (AUR) for the Arch side, and a
# force-evaluating `nix eval --impure` (`builtins.tryEval (builtins.seq pkgs.<attr> true)`, not
# `hasAttrByPath` alone — see nixmedia's own lib/media.nix header for the exact class of
# rename-to-`throw` a weaker check would miss) against the nixpkgs revision this repo's own
# `flake.lock` had pinned at the time (148bab9c1c3c53136ecb44a6ea356a0ed5b39b06) for the nixpkgs
# side — both sides cross-checked by `meta.homepage`/pacman `URL` against each other. One entry
# needed more than a plain 1:1 name mapping and is written up properly rather than left as a terse
# comment: see studies/noise-suppression-for-voice-nixpkgs-is-rnnoise-plugin.md.
{ ... }:
{
  # ── Capture: the engine, device tooling, and capture-chain filters it loads ────────────────
  capture = {
    obs-studio = {
      arch = "obs-studio";
      nixpkgs = "obs-studio";
      note = "the capture and composite engine this whole repo renders profile/scene config for. obs-websocket.so ships in its own plugin directory, which is why `control` below only ever needs a websocket CLIENT, never a second control-channel implementation.";
    };

    v4l-utils = {
      arch = "v4l-utils";
      nixpkgs = "v4l-utils";
      note = "V4L2 userspace tooling — the device side of the `v4l2_input` source id OBS's own linux-v4l2.so renders (see README's Sources table). Device-enablement tooling, the same category as alsa-utils/pciutils, not a shell tool — see README's 'A capture device's userspace tooling follows the device, not the shell.'";
    };

    noise-suppression-for-voice = {
      arch = "noise-suppression-for-voice";
      nixpkgs = "rnnoise-plugin";
      note = "RNNoise-based real-time noise suppression filter, loaded by OBS as a filter on an audio source. nixpkgs packages the identical upstream project (github.com/werman/noise-suppression-for-voice, confirmed by matching `meta.homepage` against the Arch package's own `URL`) under the different name `rnnoise-plugin` — not `noise-suppression-for-voice`, which does not exist in nixpkgs, and not `rnnoise` (that attribute is the bare Xiph library this plugin links against, not the filter itself). See studies/noise-suppression-for-voice-nixpkgs-is-rnnoise-plugin.md.";
    };

    obs-pipewire-audio-capture = {
      arch = "obs-pipewire-audio-capture";
      aur = true;
      nixpkgs = "obs-studio-plugins.obs-pipewire-audio-capture";
      note = "per-application PipeWire audio capture — a capture-chain filter OBS loads, same category as the RNNoise entry above.";
    };
  };

  # ── Control: physical control surfaces, and the client a button press actually calls ───────
  control = {
    obs-cli = {
      arch = "obs-cli";
      aur = true;
      nixpkgs = "obs-cli";
      note = "what a Stream Deck button actually calls — a websocket CLIENT for the server `obs-studio` above already ships in-tree. See README's Control surfaces section.";
    };

    deckmaster = {
      arch = "deckmaster";
      aur = true;
      nixpkgs = "deckmaster";
      note = "the Stream Deck daemon. Configuration is a file it reads at startup, not GUI state that would fight a `home-manager switch` for control of it — see README's 'Prefer a deck daemon whose entire configuration is a file it reads at startup.'";
    };
  };

  # ── Edit: two faces of one shared engine, not competing alternatives ───────────────────────
  edit = {
    kdenlive = {
      arch = "kdenlive";
      nixpkgs = "kdePackages.kdenlive";
      note = "for the involved stuff — multicam switching and mature proxy editing, which is what makes a 3–4 angle 4K30 project tractable on the one laptop this repo targets. NOT a bare `kdenlive` attribute in nixpkgs: it lives under `kdePackages`, forcing that path is what confirms it (a bare `pkgs.kdenlive` throws `attribute 'kdenlive' missing`). Shares the MLT engine with `shotcut` below, so a project file authored in one opens in the other — see that entry's note for why both are catalogued rather than one.";
    };

    shotcut = {
      arch = "shotcut";
      nixpkgs = "shotcut";
      note = "for the quick stuff — maintained by MLT's own maintainer, and its `.mlt` project file is raw MLT XML, the same engine `kdenlive` above wraps. They are two faces of one engine rather than competing alternatives, which is why both are catalogued: a project started here opens there and back.";
    };
  };
}
