# modules/nixos-catalogue.nix — NixOS backend for the catalogue in modules/catalogue.nix, resolving
# `nixrecord.capture`/`.control` into environment.systemPackages. The catalogue remains the single
# source of package names; Arch hands its names to nixarch's reconciler (modules/system-manager.nix)
# while NixOS resolves the nixpkgs attributes directly in the same evaluation, here.
#
# Force-evaluates every nixpkgs attribute rather than trusting `hasAttrByPath` alone — the same fix
# nixmedia's own modules/nixos.nix and nixremote's modules/nixos-tools.nix carry, forced by the same
# class of bug: `hasAttrByPath` only proves the ATTRIBUTE exists, not that it is a usable package.
# nixpkgs converts a renamed package to `<oldName> = throw "renamed to ...";`, which keeps the key
# present and only breaks when the value is actually forced — exactly what building
# `environment.systemPackages` does. `tryEval` turns that from a hard failure of the whole system
# evaluation into a skip + a warning: lib/nixrecord.nix is a data table, edited far less carefully
# than code, and a single stale mapping in it should not be able to take a host down.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixrecord;

  named = lib.filter (t: t.nixpkgs != null) cfg.selected;

  evaluated = map
    (t: {
      inherit t;
      try = builtins.tryEval (builtins.seq (lib.getAttrFromPath (lib.splitString "." t.nixpkgs) pkgs) true);
    })
    named;
  installable = map (r: r.t) (lib.filter (r: r.try.success) evaluated);
  staleMappings = map
    (r: "nixrecord: nixpkgs attribute \"${r.t.nixpkgs}\" (catalogue arch name \"${r.t.arch}\") no longer resolves -- lib/nixrecord.nix's mapping is stale, most likely a nixpkgs rename")
    (lib.filter (r: !r.try.success) evaluated);
in
{
  imports = [ ./catalogue.nix ];

  config = {
    environment.systemPackages =
      lib.unique (map (t: lib.getAttrFromPath (lib.splitString "." t.nixpkgs) pkgs) installable);

    warnings =
      lib.optional (cfg.unavailableOnNixos != [ ])
        "nixrecord: no nixpkgs equivalent for: ${lib.concatStringsSep ", " cfg.unavailableOnNixos}"
      ++ staleMappings;
  };
}
