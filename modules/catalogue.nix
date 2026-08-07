# modules/catalogue.nix — resolves ../lib/nixrecord.nix into platform-neutral selections. Same
# shape as nixmedia's modules/nixmedia.nix and nixremote's modules/tools.nix: declares WHICH
# catalogue entries a host wants, and publishes the resolved package names both platform backends
# consume — see modules/system-manager.nix (Arch: names for nixarch's reconciler) and
# modules/nixos-catalogue.nix (NixOS: nixpkgs derivations for environment.systemPackages).
#
# Separate option namespace from `programs.nixrecord` (the config-generation surface in
# home/nixrecord.nix and its shared package/enable options in modules/nixrecord.nix) and from
# `nixrecord.install` (modules/system-manager.nix's own pre-existing OBS+VAAPI-driver install
# surface) — this is the plain catalogue-selection shape the rest of this nix* family already uses
# for a list of otherwise-unconfigured packages, the same split nixremote draws between its own
# `nixremote.install.moonlight.enable` and `nixremote.transport`.
{ config, lib, ... }:
let
  cfg = config.nixrecord;
  cat = import ../lib/nixrecord.nix { };

  mkGroup = what: table: lib.mkOption {
    type = lib.types.listOf (lib.types.enum (lib.attrNames table));
    default = [ ];
    description = "Which ${what} to install. Available: ${lib.concatStringsSep ", " (lib.attrNames table)}.";
  };

  selected = lib.flatten [
    (map (k: cat.capture.${k}) cfg.capture)
    (map (k: cat.control.${k}) cfg.control)
    (map (k: cat.edit.${k}) cfg.edit)
  ];
in
{
  options.nixrecord = {
    capture = mkGroup "capture-engine and device tooling entries" cat.capture;
    control = mkGroup "control-surface entries" cat.control;
    edit = mkGroup "edit entries (kdenlive, shotcut)" cat.edit;

    selected = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      internal = true;
      description = ''
        The resolved catalogue entries for every name in `capture`, `control` and `edit` combined,
        in one flat list — the canonical "what did this host actually ask for" a platform backend
        consumes.
      '';
    };

    archPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Selections as pacman names, for the host's own reconciler:

          nixarch.packages.pacman = config.nixrecord.archPackages;
      '';
    };

    aurPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Selections that live in the AUR rather than an official repo, kept SEPARATE because
        `pacman -S` cannot resolve them — it fails the whole transaction with "target not found",
        taking every other package in the same converge down with it. Three of today's eight
        entries (obs-cli, deckmaster, obs-pipewire-audio-capture) land here; kdenlive and shotcut
        do not — both are official-repo Arch packages. Wire it regardless:

          nixarch.packages.aur = config.nixrecord.aurPackages;
      '';
    };

    nixosPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Selections' nixpkgs attribute names (dotted paths), for introspection. The NixOS backend
        (modules/nixos-catalogue.nix) does NOT install straight off this list — it force-evaluates
        each name against the real `pkgs` first, the same "declared intent, not an install
        guarantee" doctrine nixmedia's own modules/nixos.nix documents.
      '';
    };

    unavailableOnNixos = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = "Selections with no nixpkgs equivalent, surfaced rather than silently dropped. Empty for today's eight entries — every one resolves on both platforms.";
    };
  };

  config = {
    nixrecord.selected = selected;
    nixrecord.archPackages =
      lib.unique (map (t: t.arch) (lib.filter (t: !(t.aur or false)) selected));
    nixrecord.aurPackages =
      lib.unique (map (t: t.arch) (lib.filter (t: t.aur or false) selected));
    nixrecord.nixosPackages =
      lib.unique (map (t: t.nixpkgs) (lib.filter (t: t.nixpkgs != null) selected));
    nixrecord.unavailableOnNixos =
      lib.unique (map (t: t.arch) (lib.filter (t: t.nixpkgs == null) selected));
  };
}
