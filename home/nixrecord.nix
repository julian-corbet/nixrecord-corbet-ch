# home/nixrecord.nix — homeManagerModules.nixrecord: generates OBS Studio's own on-disk config
# (namespace: programs.nixrecord) instead of hand-editing it through OBS's Settings dialog. Two
# files per named profile: `~/.config/obs-studio/basic/profiles/<name>/{basic.ini,
# recordEncoder.json}` (what to encode, and how) and one matching
# `~/.config/obs-studio/basic/scenes/<name>.json` (what to composite). See README's "One profile
# is one canvas is one encode" for why those two are rendered as a PAIR under the same name rather
# than as independent axes — OBS itself couples them through canvas coordinate space (a scene
# item's `pos`/`bounds` are pixels in the ACTIVE PROFILE's base canvas, not scene-collection-local),
# so keeping them 1:1 here is what stops that coupling from becoming a footgun.
#
# Installs nothing. This module never touches home.packages — see README for why (mechanism vs
# platform-backend split, same doctrine as nixscroll/nixdesktop/nixremote).
#
# GROUND TRUTH, NOT GUESSED — AND `strings` ALONE WAS NOT ENOUGH. Every literal below (source
# ids, every basic.ini key, the scene-collection JSON's top-level shape, the per-item transform
# fields) was checked against a real, installed OBS Studio 32.1.2 (Arch `extra/obs-studio`)
# three ways: `strings` on the actual binaries for literal keys/ids, a live headless round-trip
# (`QT_QPA_PLATFORM=offscreen obs` against a throwaway `XDG_CONFIG_HOME`) that generated a real
# default profile+scene and accepted a hand-authored scene item back with zero parse warnings,
# AND — because the first two still got the VAAPI encoder ids wrong — actually pointing a
# headless OBS at THIS module's own rendered output and reading which `RecEncoder` it accepted.
# `strings` found `av1_vaapi`/`hevc_vaapi`/`h264_vaapi` as real literals and this file's first
# draft assumed they were the modern/preferred ids; the live run proved that wrong
# (`error: Encoder ID 'av1_vaapi' not found` — see `codecEncoderId` below and
# `studies/obs-config-ground-truth.md`'s "Method 4"). `studies/obs-config-ground-truth.md` has
# the full methodology, every command run, and — just as importantly — the specific fields this
# process did NOT confirm (an OBS-side CQP/ICQ quality key chief among them, which is why
# `rateControl` below stops at CBR/VBR rather than including a value this module could not
# verify).
#
# NOT AN OPTION PER OBS UI SETTING. OBS's Settings dialog has far more surface than is modeled
# here (network buffering, replay buffer, multiple audio tracks, stream targets, hotkeys, ...).
# This module's scope is the one job stated in this repo's README: turn a named recording
# INTENT into the two files above. Anything else goes through a scene collection or profile you
# edit by hand in OBS — this module only ever writes files under its own named profiles/scenes,
# never touches `global.ini`/`user.ini` (OBS's own last-used-selection and window-layout state —
# see README's "Not managed").
{ lib, config, ... }:
let
  cfg = config.programs.nixrecord;

  inherit (lib) mkEnableOption mkOption types mkIf mkMerge filter concatStringsSep concatMapStringsSep optional optionals mapAttrsToList attrNames;

  # ── codec / encoder id tables ────────────────────────────────────────────────────────────
  # CORRECTED BY RUNTIME EVIDENCE, NOT BY `strings` ALONE — worth stating plainly because it
  # reversed this file's own first draft. `strings` on obs-ffmpeg.so finds `av1_vaapi`,
  # `hevc_vaapi` and `h264_vaapi` as real, standalone literals, and it is reasonable (this
  # module's own first version did exactly this) to read that as "the native/preferred VAAPI
  # encoder ids, with `*_ffmpeg_vaapi_tex` as an older compat path". A live headless OBS run
  # (`experiments/obs-headless-probe.sh`'s technique, against real obs-studio 32.1.2) proved
  # that reading wrong: `RecEncoder=av1_vaapi` was rejected outright —
  # `error: Encoder ID 'av1_vaapi' not found` — while OBS's own "Loaded Modules" log for
  # `obs-ffmpeg.so` enumerated exactly `ffmpeg_vaapi_tex`, `av1_ffmpeg_vaapi_tex` and
  # `hevc_ffmpeg_vaapi_tex` as what it actually registered. Whatever `av1_vaapi` etc. name
  # inside the binary, they are NOT the `obs_encoder` ids this OBS build registers — see
  # `studies/obs-config-ground-truth.md`'s "Method 4" for the full log excerpt and reasoning.
  # This is exactly why `studies/` ranks a live round-trip above a `strings` literal: a string
  # existing in a binary proves it is spelled that way SOMEWHERE, never that it is the specific
  # thing you assumed.
  codecEncoderId = {
    av1 = "av1_ffmpeg_vaapi_tex";
    hevc = "hevc_ffmpeg_vaapi_tex";
    # Note the missing "h264" in the id itself — confirmed from the same log line
    # ("ffmpeg_vaapi_tex (FFmpeg VAAPI H.264)"), not a typo here.
    h264 = "ffmpeg_vaapi_tex";
    # `obs_x264` — OBS's built-in software x264 encoder. The one codec value that needs no GPU
    # generation caveat at all (see studies/av1-vaapi-pixel-budget.md and the `codec` option
    # below): correct on every machine, at the cost of CPU load an iGPU-VAAPI path doesn't pay.
    software = "obs_x264";
  };

  audioEncoderId = {
    # ffmpeg_opus — modern, better quality-per-bit than AAC, and MKV (this module's default
    # container) has always supported Opus natively, unlike MP4 where Opus support is a much
    # newer and less universally-deployed addition. AAC stays available for a consumer who
    # needs MP4/CDN compatibility outside this module's own default container choice.
    opus = "ffmpeg_opus";
    aac = "ffmpeg_aac";
  };

  # `pipewire-desktop-capture-source` (the unified picker OBS's own UI calls "Screen Capture
  # (PipeWire)") is deliberately NOT used here — see README's "What Nix can and can't declare
  # about a capture source" for why the two purpose-specific ids below are the honest choice:
  # they at least declare INTENT (this source is a whole output / a single window) even though,
  # like the unified source, neither can pre-select a specific monitor or window without the
  # portal's own one-time interactive consent.
  captureSourceId = {
    output = "pipewire-screen-capture-source";
    window = "pipewire-window-capture-source";
    # "region" is not a distinct portal capture type on any compositor this module has been
    # checked against — see the `sources.<name>.region` option below for how it's actually
    # implemented (a crop on an output capture, not a fourth source id).
    region = "pipewire-screen-capture-source";
  };

  # ── basic.ini rendering ───────────────────────────────────────────────────────────────────
  # `FPSType = 0` selects OBS's "Common FPS Values" mode (`FPSCommon` below) rather than the
  # Integer/Fraction modes (`FPSInt`/`FPSNum`+`FPSDen`) — this is the one field in this module
  # inferred from OBS's own locale-string ordering and long-standing product convention (the
  # first item in OBS's own Video Settings FPS-type combo box), NOT independently round-tripped
  # the way the scene-item schema below was. See studies/obs-config-ground-truth.md. Restricting
  # `fps` to the literal strings OBS's `FPSCommon` combo actually ships side-steps ever needing
  # to know the Integer/Fraction mode numbers at all.
  renderBasicIni = name: p: ''
    [General]
    Name=${name}

    [Video]
    BaseCX=${toString p.canvas.width}
    BaseCY=${toString p.canvas.height}
    OutputCX=${toString p.canvas.width}
    OutputCY=${toString p.canvas.height}
    FPSType=0
    FPSCommon=${p.fps}
    ColorFormat=NV12
    ColorSpace=709
    ColorRange=Partial
    ScaleType=bicubic

    [Output]
    Mode=Advanced

    [AdvOut]
    RecType=Standard
    RecFormat2=${p.container}
    RecEncoder=${codecEncoderId.${p.codec}}
    RecAudioEncoder=${audioEncoderId.${p.audioCodec}}
    RecTracks=1
  '' + lib.optionalString (p.outputDirectory != null) "RecFilePath=${p.outputDirectory}\n";

  # ── recordEncoder.json rendering ─────────────────────────────────────────────────────────
  # Keys confirmed present in obs-ffmpeg.so's own string table: rate_control, bitrate, profile,
  # level, preset, keyint_sec, device. `bf` (b-frames) and a CQP/ICQ quality-value key were NOT
  # found as literal strings in that binary and are deliberately absent here rather than guessed
  # — see the module header and studies/obs-config-ground-truth.md. `device`, when set, should be
  # a `/dev/dri/by-path/*-render` udev symlink (stable across boots and hot-plug) rather than a
  # bare `/dev/dri/renderD1XX` (probe-order-assigned, can renumber) — the same stable-vs-probe-
  # order distinction nixscroll's own README documents for DRM card paths, without pulling in a
  # flake dependency to enforce it: this module just recommends the right kind of path.
  renderRecordEncoderJson = p:
    builtins.toJSON (
      { rate_control = p.rateControl; }
      // (if p.rateControl == "CBR" || p.rateControl == "VBR" then { bitrate = p.bitrate; } else { })
      // { keyint_sec = p.keyframeIntervalSeconds; }
      // lib.optionalAttrs (p.encoderPreset != null) { preset = p.encoderPreset; }
      // lib.optionalAttrs (p.codec != "software" && cfg.encoder.device != null) { device = cfg.encoder.device; }
    );

  # ── scene collection rendering ───────────────────────────────────────────────────────────
  # Shape confirmed by a live OBS load/re-save round trip — see the module header. Every field
  # below appears verbatim in that captured output; the fields OBS computes and re-adds itself
  # on save (`pos_rel`, `scale_rel`, `bounds_rel`, `scale_ref`) are deliberately omitted here,
  # exactly as they were omitted from the hand-authored fixture that round-tripped cleanly.
  # A stable, UUID-SHAPED (8-4-4-4-12 hex) identity derived from the profile+source name, not a
  # real random v4 UUID — OBS itself never re-derives this value, it only stores and echoes
  # back whatever string was already in the file (confirmed by the live round-trip: OBS re-saved
  # the hand-authored fixture's `uuid`/`source_uuid` byte-for-byte unchanged), so what matters is
  # that it's unique-enough and CONSISTENT between a source's own `uuid` and every scene item's
  # `source_uuid` referencing it — which deriving both from the same `name` guarantees for free,
  # deterministically, on every rebuild (a real random UUID would churn on every eval instead).
  mkUuid = seed:
    let h = builtins.hashString "sha256" seed; in
    "${builtins.substring 0 8 h}-${builtins.substring 8 4 h}-${builtins.substring 12 4 h}-${builtins.substring 16 4 h}-${builtins.substring 20 12 h}";

  audioSource = { name, kind, deviceId }: {
    prev_ver = 0;
    inherit name;
    uuid = mkUuid name;
    id = kind;
    versioned_id = kind;
    settings = { device_id = deviceId; };
    mixers = 255;
    sync = 0;
    flags = 0;
    volume = 1.0;
    balance = 0.5;
    enabled = true;
    muted = false;
    "push-to-mute" = false;
    "push-to-mute-delay" = 0;
    "push-to-talk" = false;
    "push-to-talk-delay" = 0;
    hotkeys = { };
    deinterlace_mode = 0;
    deinterlace_field_order = 0;
    monitoring_type = 0;
    private_settings = { };
  };

  captureSource = srcName: s: {
    prev_ver = 0;
    name = srcName;
    uuid = mkUuid srcName;
    id = captureSourceId.${s.type};
    versioned_id = captureSourceId.${s.type};
    # Deliberately near-empty: which monitor/window this source actually shows is negotiated
    # live through the portal's own picker the first time it activates, and (if the portal and
    # OBS version support it) remembered via a restore token OBS itself writes back into this
    # same settings dict on save — a token this module cannot pre-supply because the portal
    # mints it, not Nix. See README's "What Nix can and can't declare about a capture source".
    settings = { };
    mixers = 0;
    sync = 0;
    flags = 0;
    volume = 1.0;
    balance = 0.5;
    enabled = true;
    muted = false;
    "push-to-mute" = false;
    "push-to-mute-delay" = 0;
    "push-to-talk" = false;
    "push-to-talk-delay" = 0;
    hotkeys = { };
    deinterlace_mode = 0;
    deinterlace_field_order = 0;
    monitoring_type = 0;
    private_settings = { };
  };

  # bounds_type = 1 ("Stretch"): inferred from OBS's own locale-string enum ORDER
  # (None/Stretch/ScaleInner/ScaleOuter/ScaleToWidth/ScaleToHeight/MaxOnly, recovered from the
  # `obs` binary's string table) matching the well-documented `obs_bounds_type` C enum order —
  # a weaker confirmation tier than the item schema's own fields, which were round-tripped
  # live. Stretch is the only bounds mode that makes a declared `layout.<name>.width/height`
  # authoritative regardless of the source's native capture resolution, which is the point of
  # offering width/height at all here rather than a raw scale factor.
  sceneItem = { srcName, x, y, width, height, cropTop ? 0, cropBottom ? 0, cropLeft ? 0, cropRight ? 0 }: {
    name = srcName;
    source_uuid = mkUuid srcName;
    visible = true;
    locked = false;
    rot = 0.0;
    align = 5;
    bounds_type = 1; # Stretch — see comment above
    bounds_align = 0;
    bounds_crop = false;
    crop_left = cropLeft;
    crop_top = cropTop;
    crop_right = cropRight;
    crop_bottom = cropBottom;
    id = 0; # OBS renumbers on load; a placeholder here does not survive a real save, unlike
    # every other field, which is exactly why it doesn't need to be unique across items.
    group_item_backup = false;
    pos = { x = x * 1.0; y = y * 1.0; };
    scale = { x = 1.0; y = 1.0; };
    bounds = { x = width * 1.0; y = height * 1.0; };
    scale_filter = "disable";
    blend_method = "default";
    blend_type = "normal";
    show_transition = { duration = 0; };
    hide_transition = { duration = 0; };
    private_settings = { };
  };

  renderSceneCollection = name: p:
    let
      sourceNames = attrNames p.sources;
      captureSources = map (n: captureSource n p.sources.${n}) sourceNames;

      items = map
        (n:
          let
            s = p.sources.${n};
            l = p.layout.${n} or { x = 0; y = 0; width = p.canvas.width; height = p.canvas.height; };
            region = if s.type == "region" then s.region else null;
          in
          sceneItem {
            srcName = n;
            inherit (l) x y width height;
            cropTop = if region != null then region.top else 0;
            cropBottom = if region != null then region.bottom else 0;
            cropLeft = if region != null then region.left else 0;
            cropRight = if region != null then region.right else 0;
          })
        sourceNames;

      sceneSource = {
        prev_ver = 0;
        name = "Scene";
        uuid = mkUuid "${name}-scene";
        id = "scene";
        versioned_id = "scene";
        settings = {
          id_counter = lib.length items;
          custom_size = false;
          inherit items;
        };
        mixers = 0;
        sync = 0;
        flags = 0;
        volume = 1.0;
        balance = 0.5;
        enabled = true;
        muted = false;
        "push-to-mute" = false;
        "push-to-mute-delay" = 0;
        "push-to-talk" = false;
        "push-to-talk-delay" = 0;
        hotkeys = { };
        deinterlace_mode = 0;
        deinterlace_field_order = 0;
        monitoring_type = 0;
        private_settings = { };
      };

      audioSinkDeviceId = if cfg.audio.followSystemDefault then "default" else cfg.audio.sink;
      audioMicDeviceId = if cfg.audio.followSystemDefault then "default" else cfg.audio.micSink;

      topLevel =
        { inherit name; }
        // lib.optionalAttrs (cfg.audio.sink != null || cfg.audio.followSystemDefault) {
          DesktopAudioDevice1 = audioSource {
            name = "Desktop Audio";
            kind = "pulse_output_capture";
            deviceId = audioSinkDeviceId;
          };
        }
        // lib.optionalAttrs (cfg.audio.micSink != null || cfg.audio.followSystemDefault) {
          AuxAudioDevice1 = audioSource {
            name = "Mic/Aux";
            kind = "pulse_input_capture";
            deviceId = audioMicDeviceId;
          };
        };
    in
    builtins.toJSON (topLevel // {
      sources = captureSources ++ [ sceneSource ];
      groups = [ ];
      scene_order = [{ name = "Scene"; }];
      current_scene = "Scene";
      current_program_scene = "Scene";
      canvases = [ ];
      current_transition = "Fade";
      transition_duration = 300;
      transitions = [ ];
      quick_transitions = [
        { name = "Cut"; duration = 300; hotkeys = [ ]; id = 1; fade_to_black = false; }
        { name = "Fade"; duration = 300; hotkeys = [ ]; id = 2; fade_to_black = false; }
      ];
      saved_projectors = [ ];
      preview_locked = false;
      scaling_enabled = false;
      scaling_level = 0;
      scaling_off_x = 0.0;
      scaling_off_y = 0.0;
      modules = {
        scripts-tool = [ ];
      };
      version = 2;
    });

  fpsCommonValues = [ "10" "20" "24 NTSC" "25" "29.97" "30" "48" "50" "59.94" "60" ];

  sourceType = types.submodule {
    options = {
      type = mkOption {
        type = types.enum [ "output" "window" "region" ];
        example = "output";
        description = ''
          What this capture source shows once its portal session is granted (see README's
          "What Nix can and can't declare about a capture source" — this is INTENT, not a
          pre-selected monitor or window). `output` and `window` render OBS's own dedicated
          `pipewire-screen-capture-source`/`pipewire-window-capture-source` ids. `region` also
          renders `pipewire-screen-capture-source` (there is no distinct portal capture type for
          a sub-rectangle) and additionally requires `region` below, applied as a scene-item crop.
        '';
      };

      region = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            top = mkOption { type = types.ints.unsigned; default = 0; description = "Pixels cropped off the top of the captured output before compositing."; };
            bottom = mkOption { type = types.ints.unsigned; default = 0; description = "Pixels cropped off the bottom."; };
            left = mkOption { type = types.ints.unsigned; default = 0; description = "Pixels cropped off the left."; };
            right = mkOption { type = types.ints.unsigned; default = 0; description = "Pixels cropped off the right."; };
          };
        });
        default = null;
        description = ''
          Required when `type = "region"`, ignored otherwise. Crop insets in the SOURCE output's
          own native pixels (not the profile's canvas) — OBS applies `crop_*` before `bounds`
          scaling, so these numbers stay correct regardless of what `layout.<name>` later scales
          the cropped result to.
        '';
      };
    };
  };

  layoutType = types.submodule {
    options = {
      x = mkOption { type = types.number; description = "Left edge, in the profile's canvas pixels (see `canvas` above)."; };
      y = mkOption { type = types.number; description = "Top edge, in canvas pixels."; };
      width = mkOption { type = types.number; description = "Rendered width, in canvas pixels. Stretches the source to fit regardless of its native resolution — see `sceneItem`'s comment on `bounds_type`."; };
      height = mkOption { type = types.number; description = "Rendered height, in canvas pixels."; };
    };
  };

  profileType = types.submodule {
    options = {
      canvas = {
        width = mkOption { type = types.ints.positive; example = 1920; description = "Base AND output canvas width — this module does not model a separate downscale between the two (see README's Status/left-out-of-v1)."; };
        height = mkOption { type = types.ints.positive; example = 1080; description = "Base AND output canvas height."; };
      };

      fps = mkOption {
        type = types.enum fpsCommonValues;
        default = "60";
        description = ''
          One of OBS's own `FPSCommon` values (`${concatStringsSep ", " fpsCommonValues}`) — a
          closed, real set rather than an arbitrary integer, chosen so this module never has to
          resolve which FPSType mode number pairs with FPSInt/FPSNum+FPSDen (see the header
          comment on `FPSType` above). Ordinary integer frame rates that AREN'T in this list
          (e.g. 90, 120) are a real OBS capability this module does not expose in v1.
        '';
      };

      codec = mkOption {
        type = types.enum (attrNames codecEncoderId);
        default = "software";
        description = ''
          `software` (OBS's `obs_x264`) is the only value guaranteed correct on any machine —
          the reason it is the default, not a recommendation to actually use it for real
          recording. AV1/HEVC/H264 hardware encode is GENERATION-DEPENDENT, not merely
          vendor-dependent: AMD RDNA2 has AV1 *decode* but not *encode* (arrived with RDNA3);
          Intel needs Arc/Xe or roughly 11th-gen-Core-or-newer Quick Sync for AV1 encode. This
          module cannot detect that for you (declared, never probed — the same doctrine
          nixarch's own `distro` option documents: evaluation happens wherever the flake is
          built, not necessarily on the target machine, so an eval-time hardware probe would as
          often as not answer for the WRONG box). Get this wrong and OBS itself refuses to start
          the recording with a real, loud error — not a silent failure — but see `fallbackCodecs`
          below for not discovering that mid-capture.
        '';
      };

      fallbackCodecs = mkOption {
        type = types.listOf (types.enum (attrNames codecEncoderId));
        default = [ ];
        example = [ "hevc" "software" ];
        description = ''
          Renders one COMPLETE SIBLING PROFILE per entry — named `<profile>-fallback-<codec>`,
          identical in every other setting — rather than an automatic runtime chain. OBS's own
          profile file format names exactly one `RecEncoder`; there is no config-level "try A,
          then B" primitive to render even if this module wanted one. What Nix CAN do, and what
          this renders, is make every fallback a real, already-configured, one-click-away OBS
          profile instead of something to hand-type while a recording is already failing —
          worth doing given `studies/av1-vaapi-pixel-budget.md`'s own point that a dropped frame
          in a live capture is unrecoverable, unlike a batch encode that can simply run slower.
        '';
      };

      rateControl = mkOption {
        type = types.enum [ "CBR" "VBR" ];
        default = "CBR";
        description = ''
          `rate_control` in the rendered `recordEncoder.json`. CBR (the default) gives a
          predictable file-size-per-minute, which is usually what you want for a recording tool
          rather than a stream. CQP/ICQ (bounded-quality, unbounded size) are real modes OBS's
          VAAPI encoders support but are NOT modeled here — this module could not confirm the
          settings-dict key that carries their quality value against the real binary's own
          string table (`rate_control`/`bitrate`/`profile`/`level`/`preset`/`keyint_sec` all
          confirmed; a CQP/ICQ value key did not turn up the same way — see
          studies/obs-config-ground-truth.md). Left out rather than guessed.
        '';
      };

      bitrate = mkOption {
        type = types.ints.positive;
        example = 20000;
        description = ''
          Kbps. NO DEFAULT — the right value depends on resolution, codec and content in a way
          no single number is correct across profiles (see README's "no invented numbers"). As
          a starting point to tune from, not a measured fact: AV1/HEVC at 1080p60 archive
          quality is commonly quoted around 12000-20000; scale roughly with pixel count for
          other resolutions, and roughly halve it (AV1 vs H264) or by a smaller factor (HEVC vs
          H264) for the same perceptual quality.
        '';
      };

      keyframeIntervalSeconds = mkOption {
        type = types.ints.positive;
        default = 2;
        description = "`keyint_sec` in the rendered recordEncoder.json. 2s is OBS's own long-standing default.";
      };

      encoderPreset = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "balanced";
        description = ''
          Raw passthrough to the encoder's own `preset` key. Deliberately not an enum: VAAPI
          preset names are driver-dependent (Intel's media-driver and Mesa's gallium VAAPI
          driver do not necessarily expose the same preset vocabulary), and modeling one finite
          set here risks being wrong for a real device the same way `rateControl`'s dropped
          CQP/ICQ key would have been if guessed — same "write raw, no natural finite option
          tree" reasoning nixscroll uses for scroll's animation-curve grammar.
        '';
      };

      container = mkOption {
        type = types.enum [ "mkv" "mp4" "mov" "fragmented_mp4" ];
        default = "mkv";
        description = ''
          `RecFormat2`. `mkv` is OBS's own long-standing recommendation for recording
          specifically (crash-safe and resumable — a `.mkv` from a killed process still plays;
          an interrupted `.mp4` frequently does not) and this module's default for the same
          reason. Remux to mp4/mov after the fact if you need it for editing-software
          compatibility; OBS ships a "Remux" tool for exactly that.
        '';
      };

      outputDirectory = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/home/me/Videos/nixrecord";
        description = ''
          `RecFilePath`. `null` (the default) omits the key and leaves OBS's own default
          (typically `~/Videos`) in effect — "render only what you set", same as nixscroll's
          `outputs`.
        '';
      };

      audioCodec = mkOption {
        type = types.enum (attrNames audioEncoderId);
        default = "opus";
        description = "`RecAudioEncoder`. See the `audioEncoderId` comment above for why Opus is the default.";
      };

      audioTrackBitrate = mkOption {
        type = types.ints.positive;
        default = 160;
        description = "Kbps for the recorded audio track. 160 is a reasonable, commonly-used default for either codec at this default.";
      };

      sources = mkOption {
        type = types.attrsOf sourceType;
        default = { };
        description = ''
          Named capture sources composited into this profile's own scene collection (same
          name). Empty by default: a video-only or audio-only profile is valid, and a consumer
          who wants no default sources at all should not have to override anything to get that
          — same "render only what you set" reasoning as everywhere else in this module.
        '';
      };

      layout = mkOption {
        type = types.attrsOf layoutType;
        default = { };
        description = ''
          Where each `sources.<name>` is placed on the canvas. A source with no entry here
          defaults to filling the WHOLE canvas (0,0 at `canvas.width`x`canvas.height`) — the
          right default for the single-source case, which is most of them; multi-source layouts
          need an entry per source that should NOT cover the whole frame.

          THIS is where "composite once, encode once" (see README and
          studies/av1-vaapi-pixel-budget.md) actually becomes structural rather than just
          advice: there is no option anywhere in this module that produces more than one scene
          collection, more than one `RecEncoder`, or more than one recording output per profile.
          Recording three windows means three entries here feeding ONE scene, ONE canvas, ONE
          encode — never three independent captures.
        '';
      };
    };
  };
in
{
  options.programs.nixrecord = {
    enable = mkEnableOption "generating OBS Studio profile + scene-collection config from declared recording intents (see README)";

    profiles = mkOption {
      type = types.attrsOf profileType;
      default = { };
      description = ''
        Named recording intents. Each key becomes an OBS profile directory AND a same-named
        scene collection — see the module header for why the two are paired rather than
        independent. Empty by default; a consumer names their own profiles (`archive`,
        `screencast`, `quick`, ...), there is no house default profile shipped here (this
        module has no idea what resolution or bitrate is right for someone else's machine —
        same "mechanism public, values private" doctrine as every repo in this family).
      '';
    };

    encoder.device = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/dev/dri/by-path/pci-0000:00:02.0-render";
      description = ''
        `device` in every hardware-encoded profile's recordEncoder.json (omitted for
        `codec = "software"` profiles, and when this is left null). `null`, the default, lets
        VAAPI auto-select — correct on a single-iGPU laptop, which covers most of this module's
        intended audience. On a multi-GPU box, point this at a `/dev/dri/by-path/*-render`
        symlink (udev's own stable-across-boots identity for a render node), never a bare
        `/dev/dri/renderD1XX` — that name is assigned in PROBE ORDER and can renumber on a
        kernel/driver update, silently pointing this at the wrong GPU after a reboot.
      '';
    };

    audio = {
      sink = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "alsa_output.pci-0000_00_1f.3.analog-stereo.monitor";
        description = ''
          The exact PipeWire/PulseAudio node name (`pactl list short sinks`, or that sink's own
          `.monitor` source for desktop-audio capture) to pin as `device_id` for every profile's
          `DesktopAudioDevice1`. `null`, the default, means no desktop-audio source is rendered
          into any scene collection at all — silence over a guess.

          READ THIS BEFORE SETTING `followSystemDefault` INSTEAD. `device_id = "default"`
          (what OBS itself falls back to, and what `followSystemDefault` below opts back into)
          means "whatever PipeWire's policy daemon currently calls the default sink" —
          re-evaluated on EVERY device event, not fixed at recording start. That is a real
          failure mode, not a hypothetical one: a policy daemon re-elects the default sink when
          any device appears or disappears, and on a machine that also mirrors audio from
          another host over a network audio fabric (a sink that "appears" over the network, not
          plugged in locally), that re-election can point a live recording's captured audio at a
          sink physically producing sound on a DIFFERENT machine — silently, mid-recording, with
          the level meters still moving because SOMETHING is still being captured, just not what
          you meant. This has actually happened, on a real streaming host in this project's own
          reference estate. Pinning the exact node name here is the fix: PipeWire's policy
          re-election can only ever change what "default" MEANS, never what a literal node name
          resolves to.
        '';
      };

      micSink = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "alsa_input.usb-Corsair_HS80-00.mono-fallback";
        description = "Same pinning, for `AuxAudioDevice1` (microphone/input capture). `null` renders no mic source.";
      };

      followSystemDefault = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Escape hatch: renders `device_id = "default"` instead of `sink`/`micSink`, restoring
          the exact re-election failure mode `sink`'s own description warns about. Off by
          default — this module does not silently fall back to "default" just because `sink`
          was left null; it renders no audio source at all in that case (see `sink` above).
          Turn this on only with a specific, considered reason (a single-purpose recording box
          with genuinely no other audio devices ever attached, say); it is not the "just make it
          work" setting.
        '';
      };
    };
  };

  config = mkIf cfg.enable (
    let
      profileNames = attrNames cfg.profiles;

      # Expands each declared profile into itself plus one sibling per `fallbackCodecs` entry —
      # see that option's own description for why this is real sibling profiles and not a
      # runtime chain.
      expandedProfiles = lib.concatMap
        (name:
          let p = cfg.profiles.${name}; in
          [{ inherit name; profile = p; }]
          ++ map
            (fc: {
              name = "${name}-fallback-${fc}";
              profile = p // { codec = fc; fallbackCodecs = [ ]; };
            })
            p.fallbackCodecs)
        profileNames;
    in
    {
      xdg.configFile = lib.listToAttrs (lib.concatMap
        ({ name, profile }: [
          {
            name = "obs-studio/basic/profiles/${name}/basic.ini";
            value.text = renderBasicIni name profile;
          }
          {
            name = "obs-studio/basic/profiles/${name}/recordEncoder.json";
            value.text = renderRecordEncoderJson profile;
          }
          {
            name = "obs-studio/basic/scenes/${name}.json";
            value.text = renderSceneCollection name profile;
          }
        ])
        expandedProfiles);

      assertions = [
        {
          assertion = cfg.audio.sink != null || cfg.audio.micSink != null || !cfg.audio.followSystemDefault;
          message = "programs.nixrecord.audio.followSystemDefault is set but neither `sink` nor `micSink` is — there is no audio source for it to affect. Set at least one, or drop followSystemDefault.";
        }
      ] ++ lib.concatMap
        ({ name, profile }: [{
          assertion = lib.all (n: profile.sources ? ${n}) (attrNames profile.layout);
          message = "programs.nixrecord.profiles.${name}.layout names a source not present in programs.nixrecord.profiles.${name}.sources.";
        }])
        expandedProfiles;
    }
  );
}
