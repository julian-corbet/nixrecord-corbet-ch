# Shared option surface for nixrecord's program namespace.
{ config, lib, pkgs, ... }:
let
  cfg = config.programs.nixrecord;
in
{
  options.programs.nixrecord = {
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.obs-studio;
      defaultText = lib.literalExpression "pkgs.obs-studio";
      description = ''
        The OBS Studio package to install. Same namespace as this module's own
        config-generation layer (`home/nixrecord.nix`) so both planes can refer to a
        consistent `programs.nixrecord` name.
      '';
    };

    enable = lib.mkEnableOption ''
      installing OBS Studio at the system level via nixpkgs' pkgs.obs-studio.
      Does not generate config — see homeManagerModules.nixrecord for that.
    '';
  };
}
