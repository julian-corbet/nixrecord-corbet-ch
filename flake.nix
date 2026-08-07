{
  description = "nixrecord — declarative capture of the real world (camera, microphone, a physical performance) via OBS: OBS as the capture/encode engine, Nix as the interface. Renders OBS's own profile/scene-collection files under ~/.config/obs-studio instead of hand-editing them, geared at a wlroots/Arch desktop (developed against nixarch and an Intel Lunar Lake / Arc iGPU laptop, but the mechanism assumes nothing machine-specific). Screen/window/region capture is out of scope — that belongs to the repo owning the display surface (nixremote/nixdesktop/nixscroll); see README's placement rule";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

      nixrecordModule = import ./home/nixrecord.nix;
    in
    {
      # ── NO `packages` OUTPUT, AND THAT IS DELIBERATE ─────────────────────────────────────────
      # Unlike nixscroll (which packages scroll itself because scroll has no home in nixpkgs),
      # OBS Studio already lives in two real places: `pkgs.obs-studio` in nixpkgs, and the Arch
      # official repos (`extra/obs-studio`, confirmed against a live CachyOS box while building
      # this repo — not an AUR package, no reconciler `.aur` list involved). Both install planes
      # below point AT one of those two existing sources rather than building a third. There is
      # nothing for this repo to package.

      # ── CONFIG GENERATION ─────────────────────────────────────────────────────────────────
      # Writes ~/.config/obs-studio/basic/profiles/<name>/{basic.ini,recordEncoder.json} and
      # ~/.config/obs-studio/basic/scenes/<name>.json from structured options (namespace:
      # programs.nixrecord). Installs nothing — see README's "The split". Never touches
      # global.ini/user.ini (OBS's own last-used-profile and window-layout state) — see README's
      # "Not managed: global.ini/user.ini".
      homeManagerModules = {
        nixrecord = nixrecordModule;
        default = nixrecordModule;
        install = nixrecordModule;
      };

      # ── SYSTEM SIDE (NixOS) ──────────────────────────────────────────────────────────────────
      # Thin: installs pkgs.obs-studio. Config generation is the home-manager module above,
      # entirely separate — same split nixscroll draws between nixosModules.scroll and
      # homeManagerModules.scroll.
      # `nixosModules.nixrecord` composes two independent concerns: modules/nixos.nix (installs
      # `programs.nixrecord.package`, the config-generation module's own thin install path) and
      # modules/nixos-catalogue.nix (the approved capture-set catalogue's NixOS backend, resolving
      # `nixrecord.capture`/`.control`/`.edit` — see modules/catalogue.nix). Neither depends on the other;
      # a host can compose this output and use either surface, both, or neither.
      nixosModules.nixrecord = { imports = [ ./modules/nixos.nix ./modules/nixos-catalogue.nix ]; };
      nixosModules.default = self.nixosModules.nixrecord;
      nixosModules.install = self.nixosModules.nixrecord;

      # ── ARCH/CACHYOS PLANE ───────────────────────────────────────────────────────────────────
      # Declares "obs-studio" into nixarch's `nixarch.packages.pacman` reconciler (official repo,
      # not AUR — see modules/system-manager.nix for how this was confirmed rather than assumed).
      # That same module also imports modules/catalogue.nix for the approved capture-set catalogue
      # (`nixrecord.capture`/`.control`/`.edit` → `archPackages`/`aurPackages`).
      systemManagerModules.nixrecord = ./modules/system-manager.nix;
      systemManagerModules.default = self.systemManagerModules.nixrecord;
      systemManagerModules.install = self.systemManagerModules.nixrecord;

      # ── CHECKS ───────────────────────────────────────────────────────────────────────────────
      # `nix flake check` does not evaluate `homeManagerModules`/`systemManagerModules` — see
      # nixscroll's own flake.nix comment for the exact mechanism. This closes that gap the same
      # way nixscroll's checks/ does: evaluate the module for real and inspect what it renders.
      #
      # NOT INCLUDED (yet): a real-OBS-binary acceptance check in the style of nixscroll's
      # `checks/config-accepted.nix`, which shells out to the real `scroll` binary inside the
      # Nix build sandbox. The equivalent validation for this repo — actually launching OBS
      # headless (`QT_QPA_PLATFORM=offscreen`) against a rendered profile/scene and grepping its
      # log — was done, and worked, but was done BY HAND against the system OBS package on a live
      # box, not inside `nix flake check`'s sandbox (no display, no PipeWire socket, no
      # substituted `pkgs.obs-studio` build verified fast enough to commit to here). See
      # `studies/obs-config-ground-truth.md` for the full methodology and results, and the
      # project README's Status section for this as an open item.
      checks = forAllSystems (system: {
        config-rendering = import ./checks/config-rendering.nix {
          pkgs = nixpkgs.legacyPackages.${system};
          inherit nixrecordModule;
        };
        # Proves modules/catalogue.nix actually resolves ALL THREE groups — capture, control and
        # edit — not just the two it handled before `edit` was wired in. See that check's own
        # header for the exact regression this catches.
        catalogue-resolution = import ./checks/catalogue-resolution.nix {
          pkgs = nixpkgs.legacyPackages.${system};
        };
      });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
