# modules/nixos.nix — nixosModules.nixrecord: the system-install half of this repo's split
# (see flake.nix and README's "The split"). Config generation lives entirely in
# homeManagerModules.nixrecord — this module never touches it.
#
# Kept thin on purpose, same doctrine as nixscroll's own modules/nixos.nix: install the package
# (nixpkgs already has one — see flake.nix's "NO packages output" comment), nothing more. No
# attempt to manage VAAPI driver packages here the way modules/system-manager.nix does for Arch —
# on NixOS that's `hardware.graphics.extraPackages` (or the equivalent for whichever GPU stack a
# given host uses), a system-wide concern this module has no business opinion-ing about per host.
{ config, lib, ... }:
let
  cfg = config.programs.nixrecord;
in
{
  imports = [ ./nixrecord.nix ];

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
  };
}
