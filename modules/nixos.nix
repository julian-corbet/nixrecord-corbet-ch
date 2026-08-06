# modules/nixos.nix — nixosModules.nixrecord: the system-install half of this repo's split (see
# flake.nix and README's "The split"). Config generation lives entirely in
# homeManagerModules.nixrecord — this module never touches it.
#
# Kept thin on purpose, same doctrine as nixscroll's own modules/nixos.nix: install the package
# (nixpkgs already has one — see flake.nix's "NO packages output" comment), nothing more. No
# attempt to manage VAAPI driver packages here the way modules/system-manager.nix does for Arch —
# on NixOS that's `hardware.graphics.extraPackages` (or the equivalent for whichever GPU stack a
# given host uses), a system-wide concern this module has no business opinion-ing about per host.
{ config, lib, pkgs, ... }:
let
  cfg = config.programs.nixrecord;
in
{
  options.programs.nixrecord.package = lib.mkOption {
    type = lib.types.package;
    default = pkgs.obs-studio;
    defaultText = lib.literalExpression "pkgs.obs-studio";
    description = ''
      The OBS Studio package to install. Note this option lives under the SAME
      `programs.nixrecord` namespace the home-manager config-generation module (also this repo,
      `homeManagerModules.nixrecord`) uses, matching how nixscroll shares `programs.scroll`
      across its own NixOS and home-manager modules — but unlike that pairing, this module's own
      `enable`-gated install here does not need to be composed at all for the config-generation
      module to work: a NixOS host can install OBS any other way (nixpkgs' own more elaborate
      module, a distro package, by hand) and `homeManagerModules.nixrecord` renders correct
      config either way, exactly as nixscroll's home module assumes only that a `scroll` binary
      exists somewhere.
    '';
  };

  options.programs.nixrecord.enable = lib.mkEnableOption ''
    installing OBS Studio at the system level via nixpkgs' pkgs.obs-studio (programs.nixrecord.package).
    Does not generate config — see homeManagerModules.nixrecord for that. Same option NAME as
    the home-manager module's own programs.nixrecord.enable, same non-collision reasoning as
    nixscroll's identical choice for programs.scroll.enable: a NixOS system config and a
    home-manager user config are separate evalModules trees, never composed together, so the
    shared name never actually clashes
  '';

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
  };
}
