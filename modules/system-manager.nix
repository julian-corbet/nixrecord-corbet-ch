# Arch/CachyOS plane — declares "obs-studio" into nixarch's `nixarch.packages.pacman`
# reconciler. Import alongside `nixarch.systemManagerModules.packages`, or the list is computed
# and nothing acts on it — same contract nixscroll's own modules/system-manager.nix documents.
#
# `.pacman`, NOT `.aur` — confirmed on a live CachyOS box while building this repo, not assumed
# by analogy with nixscroll (whose AUR module this one otherwise mirrors closely):
#
#   $ pacman -Qi obs-studio | grep 'Installed From'
#   Installed From  : cachyos-extra-v3
#
# obs-studio ships from Arch's own `extra` repository (mirrored/rebuilt as `cachyos-extra-v3` on
# a CachyOS box, but the point stands on plain Arch too — `extra/obs-studio` is upstream, no AUR
# helper or `aurUser` bootstrap required). Routing an official-repo name to `nixarch.packages.aur`
# would still install it (paru/yay resolve repo packages too) but through the wrong reconciler
# path — the one that needs a bootstrapped AUR helper and a non-root `aurUser` for a package that
# never needed either, exactly the failure nixarch's own pacman/AUR split exists to avoid.
#
# Also imports ./catalogue.nix: the plain catalogue-selection surface (`nixrecord.capture`/
# `.control`, resolved to `archPackages`/`aurPackages`) for the approved capture set — see that
# module's own header for why it is a separate option shape from `nixrecord.install` below rather
# than folded into it. Composing THIS module (`systemManagerModules.default`) is what a host needs
# for either surface; there is no second module to import for the catalogue half.
{ lib, config, ... }:
let
  cfg = config.nixrecord.install;
in
{
  imports = [ ./catalogue.nix ];

  options.nixrecord.install = {
    enable = lib.mkEnableOption "installing OBS Studio on an Arch/CachyOS host via nixarch's package reconciler";

    package = lib.mkOption {
      type = lib.types.str;
      default = "obs-studio";
      description = ''
        Official-repo package name for OBS Studio. Left as a plain string rather than an enum of
        one, the same way nixscroll's `aurPackage` stays a string even with a documented default
        — a hard-coded distro-specific fork name (some derivative's own OBS rebuild, say) is a
        real, if rare, reason to override this without waiting on this repo to add an option
        for it.
      '';
    };

    vaapiOptionalDeps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "intel-media-driver" "libva-mesa-driver" ];
      example = [ "intel-media-driver" ];
      description = ''
        VAAPI driver packages to install alongside OBS — these are pacman OPTIONAL dependencies
        of `obs-studio` (`pacman -Qi obs-studio` lists them under "Optional Deps", confirmed on a
        live box), so pacman itself never pulls them in automatically; a hardware-encode `codec`
        in `programs.nixrecord.profiles.<name>` silently has no working VAAPI driver underneath
        it unless one of these (or the box's own equivalent) is actually installed.

        `intel-media-driver` is the modern driver for Broadwell-and-newer Intel iGPUs (including
        Lunar Lake / Arc, this repo's own primary target — see studies/); `libva-mesa-driver` is
        Mesa's own VAAPI implementation, covering AMD GPUs (RDNA2 for H264/HEVC; see
        `programs.nixrecord.profiles.<name>.codec`'s own doc for why RDNA2 specifically does NOT
        cover AV1 encode) and older Intel hardware `intel-media-driver` doesn't support. Both are
        declared by default because they're small and mutually harmless to have installed
        together; set this to just the one your GPU actually needs if you'd rather not carry
        the other.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    nixarch.packages.pacman = [ cfg.package ] ++ cfg.vaapiOptionalDeps;
  };
}
