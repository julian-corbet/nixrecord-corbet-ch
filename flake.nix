{
  description = "nixrecord — declarative capture of the real world (camera, microphone, a physical performance) via OBS: OBS as the capture/encode engine, Nix as the interface. Renders OBS's own profile/scene-collection files under ~/.config/obs-studio instead of hand-editing them, geared at a wlroots/Arch desktop (developed against nixarch and an Intel Lunar Lake / Arc iGPU laptop, but the mechanism assumes nothing machine-specific). Screen/window/region capture is out of scope — that belongs to the repo owning the display surface (nixremote/nixdesktop/nixscroll); see README's placement rule";

  # NO INPUTS FOR CONSUMERS BEYOND NIXPKGS. What this flake exports is options and catalogues,
  # taking `pkgs`/`config`/`lib` from whichever evaluation composes it, so a real host or a real
  # cluster render never puts a sibling flake's whole input closure into its own. The two inputs
  # below are used by `checks` ALONE; nothing this flake exports reaches into either of them.
  #
  # They arrived with the cluster surface, and the reason is worth stating rather than assuming:
  # `nix flake check` evaluates no module output on its own, so a cluster module with no way to be
  # rendered would have been verified by nobody and would have passed on flake syntax alone.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The renderer the cluster module defines into. A real input rather than a name in a comment:
    # without it there is no module system to evaluate the cluster side against.
    nixidy = {
      url = "github:arnarg/nixidy";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # THE APP GRAMMAR THIS REPOSITORY CONSUMES, and the point being proven rather than a shortcut:
    # a consumer imports the grammar itself, and this input exists so the checks can render the
    # cluster module through the REAL grammar and assert what comes out -- rather than asserting
    # that a module which merely mentions `nixk3s.apps` evaluates.
    nixk3s = {
      url = "github:julian-corbet/nixk3s-corbet-ch";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixidy.follows = "nixidy";
    };
  };

  outputs = { self, nixpkgs, nixidy, nixk3s }:
    let
      lib = nixpkgs.lib;
      forAllSystems = lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

      # The cluster checks build a real nixidy environment, which is x86_64-linux only here. A
      # declared platform that cannot be built is a platform `nix flake check` SKIPS while exiting
      # 0 -- a check that passed having tested nothing -- so the cluster checks are offered on the
      # narrower list rather than the whole one. The host-side checks stay on both.
      clusterSystems = [ "x86_64-linux" ];

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

      # ── CLUSTER PLANE ────────────────────────────────────────────────────────────────────────
      # The second plane of the same subject. Everything above configures the ONE host that holds a
      # camera, a microphone and an encoder; this one declares the applications that carry a
      # recording onward — publishing it, and running the live show it came from — which are
      # continuous services with an audience and therefore do not belong on somebody's desk.
      #
      # It is a TRANSLATOR, not a renderer: it defines into the public nixk3s app grammar's
      # `nixk3s.apps` and emits no Kubernetes object of its own. Compose it alongside that grammar
      # (`nixk3s.nixidyModules.apps`); on its own it fails with "the option `nixk3s.apps' does not
      # exist", which is the correct failure rather than a silent one.
      # BUILT FROM THE GRAMMAR'S CONSUMER FACTORY. The 759-line translator this replaces held the
      # same addressing, image, port, state, probe and secret helpers a dozen sibling repositories
      # each kept a copy of; what was actually nixrecord's is entirely in lib/applications.nix.
      #
      # One rule of this repository's own went the other way and is now everybody's: a version and
      # a whole image reference are ALTERNATIVES, not a pair, so a declaration pinning a digest no
      # longer has to carry a version that decides nothing.
      nixidyModules.nixrecord = nixk3s.lib.mkConsumerModule {
        namespace = "nixrecord";
        catalogue = self.lib.applications;
      };
      nixidyModules.default = self.nixidyModules.nixrecord;

      # The cluster catalogue, exposed so a consumer can inspect or validate it without re-reading
      # the file. `lib.nixrecord` is deliberately NOT taken here — that name belongs to the host
      # catalogue in lib/nixrecord.nix, and one name for two catalogues is how they start being
      # confused for each other.
      lib.applications = (import ./lib/applications.nix { }).applications;

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
      checks = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          config-rendering = import ./checks/config-rendering.nix {
            inherit pkgs nixrecordModule;
          };
          # Proves modules/catalogue.nix actually resolves ALL THREE groups — capture, control and
          # edit — not just the two it handled before `edit` was wired in. See that check's own
          # header for the exact regression this catches.
          catalogue-resolution = import ./checks/catalogue-resolution.nix { inherit pkgs; };
        }
        # The cluster plane's own two, on the platform they can actually be built for. Same gap as
        # above, one plane over: `nix flake check` evaluates `nixidyModules` no more than it
        # evaluates the home-manager ones, so the module is rendered here for real and read back.
        // lib.optionalAttrs (lib.elem system clusterSystems) {
          # The cluster module's own resolution and every guard it makes, in BOTH directions: an
          # empty surface renders nothing, a declared one resolves, and each refusal gets a
          # declaration that must be refused.
          cluster-eval = import ./checks/cluster-eval.nix {
            inherit pkgs lib nixidy;
            appsModule = nixk3s.nixidyModules.apps;
            clusterModule = self.nixidyModules.nixrecord;
            values = ./examples/all/values.nix;
          };

          # The manifests that actually come out, read back off the rendered bytes rather than off
          # the options that produced them.
          cluster-render = import ./checks/cluster-render.nix {
            inherit pkgs lib nixidy;
            appsModule = nixk3s.nixidyModules.apps;
            clusterModule = self.nixidyModules.nixrecord;
            values = ./examples/all/values.nix;
          };
        });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
