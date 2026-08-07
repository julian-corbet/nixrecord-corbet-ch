# Evaluates home/nixrecord.nix for real against a minimal home-manager stub, and asserts what it
# renders — the same "Nix inspecting Nix" tier nixscroll's checks/layout-outputs.nix and
# checks/startup-contract.nix are: this proves the module renders what it INTENDS, not that OBS
# agrees. It does NOT replace a real-binary acceptance check (nixscroll's own
# checks/config-accepted.nix asks the real `scroll` binary; this repo has no equivalent yet — see
# flake.nix's own comment on `checks` and studies/obs-config-ground-truth.md for the manual
# validation that stands in for one today).
#
# WHY THIS FILE EXISTS AT ALL: `nix flake check` does not evaluate `homeManagerModules` — see
# nixscroll's own checks/startup-contract.nix header for the exact mechanism (unchanged here). A
# green `nix flake check` on this repo without this file would cover nothing but flake syntax.
{ pkgs, lib ? pkgs.lib, nixrecordModule }:
let
  stubs = { lib, ... }: {
    options = {
      xdg.configFile = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
        default = { };
      };
      home.packages = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
      assertions = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
      warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
    };
  };

  baseProfile = {
    canvas = { width = 1920; height = 1080; };
    fps = "60";
    codec = "av1";
    fallbackCodecs = [ "hevc" "software" ];
    rateControl = "CBR";
    bitrate = 16000;
  };

  evalWith = extraConfig: (lib.evalModules {
    modules = [
      stubs
      nixrecordModule
      {
        programs.nixrecord = {
          enable = true;
          profiles.archive = baseProfile;
        } // extraConfig;
      }
    ];
    specialArgs = { inherit pkgs; };
  }).config;

  cfgOut = (evalWith { }).xdg.configFile;

  basicIni = cfgOut."obs-studio/basic/profiles/archive/basic.ini".text;
  recordEncoderJson = builtins.fromJSON cfgOut."obs-studio/basic/profiles/archive/recordEncoder.json".text;
  sceneJson = builtins.fromJSON cfgOut."obs-studio/basic/scenes/archive.json".text;

  fallbackHevcIni = cfgOut."obs-studio/basic/profiles/archive-fallback-hevc/basic.ini".text;
  fallbackSoftwareIni = cfgOut."obs-studio/basic/profiles/archive-fallback-software/basic.ini".text;

  has = haystack: needle: lib.hasInfix needle haystack;

  scene = lib.findFirst (s: s.id == "scene") null sceneJson.sources;
  items = scene.settings.items;

  # Audio wiring — pinned sink, not "default".
  withAudio = evalWith { audio.sink = "alsa_output.pci-0000_00_1f.3.analog-stereo.monitor"; };
  audioConfigFile = withAudio.xdg.configFile."obs-studio/basic/scenes/archive.json".text;
  audioScene = builtins.fromJSON audioConfigFile;

  withDefaultAudio = evalWith {
    audio.sink = "alsa_output.pci-0000_00_1f.3.analog-stereo.monitor";
    audio.followSystemDefault = true;
  };
  defaultAudioScene = builtins.fromJSON withDefaultAudio.xdg.configFile."obs-studio/basic/scenes/archive.json".text;

  results = {
    # ── basic.ini ──────────────────────────────────────────────────────────────────────────
    "canvas resolution renders as BaseCX/BaseCY/OutputCX/OutputCY" =
      has basicIni "BaseCX=1920" && has basicIni "BaseCY=1080" && has basicIni "OutputCX=1920" && has basicIni "OutputCY=1080";
    "fps renders as FPSType=0 / FPSCommon" =
      has basicIni "FPSType=0" && has basicIni "FPSCommon=60";
    "codec resolves to the real, runtime-confirmed av1_ffmpeg_vaapi_tex encoder id" =
      has basicIni "RecEncoder=av1_ffmpeg_vaapi_tex";
    "container defaults to mkv" =
      has basicIni "RecFormat2=mkv";
    "no RecFilePath line when outputDirectory is unset (render only what you set)" =
      !(has basicIni "RecFilePath");

    # ── fallback profiles ──────────────────────────────────────────────────────────────────
    "fallbackCodecs renders one full sibling profile per entry, same canvas" =
      has fallbackHevcIni "RecEncoder=hevc_ffmpeg_vaapi_tex" && has fallbackHevcIni "BaseCX=1920";
    "the software fallback resolves to obs_x264, not a vaapi id" =
      has fallbackSoftwareIni "RecEncoder=obs_x264";

    # ── recordEncoder.json ────────────────────────────────────────────────────────────────
    "rate_control and bitrate render for CBR" =
      recordEncoderJson.rate_control == "CBR" && recordEncoderJson.bitrate == 16000;
    "no CQP/quality key invented for a mode that doesn't use one" =
      !(recordEncoderJson ? cqp) && !(recordEncoderJson ? quality);

    # ── scene collection: no video capture source exists (removed — see README's "Sources") ──
    "no video capture source is rendered: sceneJson.sources is just the Scene itself" =
      lib.length sceneJson.sources == 1;
    "the Scene's own items list is empty (nothing left to place on the canvas)" =
      items == [ ];

    # ── audio: pinning vs the default-sink footgun ────────────────────────────────────────
    "no audio source at all when audio.sink is unset (silence over a guess)" =
      !(sceneJson ? DesktopAudioDevice1);
    "audio.sink pins the literal device_id, never bare \"default\"" =
      audioScene.DesktopAudioDevice1.settings.device_id == "alsa_output.pci-0000_00_1f.3.analog-stereo.monitor";
    "followSystemDefault, when explicitly opted into, renders literal \"default\"" =
      defaultAudioScene.DesktopAudioDevice1.settings.device_id == "default";
    "the audio source uses the real pulse_output_capture id" =
      audioScene.DesktopAudioDevice1.id == "pulse_output_capture";

    # ── assertions fire for real misconfiguration ─────────────────────────────────────────
    # `config.assertions` is DATA — a list of `{assertion, message}` — not something
    # `lib.evalModules` enforces on its own; a real home-manager activation is what turns a
    # failing entry into an actual build failure (the same division of labour NixOS's own
    # `assertions` option has). The stub above deliberately does not reimplement that
    # aggregator, so this checks the data home-manager WOULD act on, not a `tryEval` around
    # rendering — rendering itself stays lazy and never forces `assertions`.
    "followSystemDefault without any sink/micSink populates a failing assertion, correctly named" =
      let
        badAssertions = (evalWith { audio.followSystemDefault = true; }).assertions;
        failing = lib.filter (a: !a.assertion) badAssertions;
      in
      lib.length failing == 1 && has (lib.head failing).message "followSystemDefault";

    # ── non-vacuity ────────────────────────────────────────────────────────────────────────
    "rendered basic.ini is real and non-trivial" = lib.stringLength basicIni > 50;
    "rendered scene JSON is real and non-trivial" = lib.stringLength (builtins.toJSON sceneJson) > 200;
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) results);
in
# pkgs.emptyFile, not runCommand — same fixed-output-vs-per-system reasoning as nixscroll's own
# checks/startup-contract.nix: this check decides everything at EVALUATION time, and
# `--all-systems` must not turn the formality into a real cross-arch build.
if failed == [ ]
then pkgs.emptyFile
else throw ''
  nixrecord: config-rendering check failed. Failing assertions:
  ${lib.concatMapStringsSep "\n" (f: "  - ${f}") failed}
''
