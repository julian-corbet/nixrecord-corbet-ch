# Evaluates modules/catalogue.nix for real, with every group selected, and proves `edit`
# resolves into `archPackages`/`nixosPackages` exactly like `capture`/`control` already do.
#
# WHY THIS FILE EXISTS AT ALL: lib/nixrecord.nix grew a third group (`edit`: kdenlive, shotcut —
# commit 5f1a93b) before modules/catalogue.nix's own `selected` list was updated to read it, so
# `capture`/`control` resolved into `archPackages`/`aurPackages`/`nixosPackages` while `edit` was
# catalogued but could never actually be selected — a host declaring `nixrecord.edit = [
# "kdenlive" ]` would evaluate cleanly and install nothing. `nix flake check` does not exercise
# `modules/catalogue.nix` on its own (it is a plain module, not a flake output), so nothing catches
# that regression without a check that imports and evaluates it directly, the same reason
# checks/config-rendering.nix exists for `home/nixrecord.nix`.
{ pkgs, lib ? pkgs.lib }:
let
  cat = import ../lib/nixrecord.nix { };

  evaluated = (lib.evalModules {
    modules = [
      ../modules/catalogue.nix
      {
        nixrecord.capture = lib.attrNames cat.capture;
        nixrecord.control = lib.attrNames cat.control;
        nixrecord.edit = lib.attrNames cat.edit;
      }
    ];
  }).config.nixrecord;

  expectedSelectedCount =
    lib.length (lib.attrNames cat.capture)
    + lib.length (lib.attrNames cat.control)
    + lib.length (lib.attrNames cat.edit);

  results = {
    # ── the regression this file exists to catch ──────────────────────────────────────────
    "kdenlive (edit group) resolves into archPackages" = lib.elem "kdenlive" evaluated.archPackages;
    "shotcut (edit group) resolves into archPackages" = lib.elem "shotcut" evaluated.archPackages;
    "kdenlive's nixpkgs attribute (kdePackages.kdenlive) resolves into nixosPackages" =
      lib.elem "kdePackages.kdenlive" evaluated.nixosPackages;
    "shotcut's nixpkgs attribute resolves into nixosPackages" =
      lib.elem "shotcut" evaluated.nixosPackages;
    "neither edit entry is miscategorised into aurPackages (both are official-repo)" =
      !(lib.elem "kdenlive" evaluated.aurPackages) && !(lib.elem "shotcut" evaluated.aurPackages);

    # ── the other two groups still resolve (no regression from wiring the third) ──────────
    "capture group still resolves (obs-studio in archPackages)" =
      lib.elem "obs-studio" evaluated.archPackages;
    "control group still resolves into aurPackages (obs-cli)" =
      lib.elem "obs-cli" evaluated.aurPackages;

    # ── selected combines all THREE groups, not just capture+control ──────────────────────
    "selected's length accounts for capture + control + edit combined" =
      lib.length evaluated.selected == expectedSelectedCount;
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) results);
in
if failed == [ ]
then pkgs.emptyFile
else throw ''
  nixrecord: catalogue-resolution check failed. Failing assertions:
  ${lib.concatMapStringsSep "\n" (f: "  - ${f}") failed}
''
