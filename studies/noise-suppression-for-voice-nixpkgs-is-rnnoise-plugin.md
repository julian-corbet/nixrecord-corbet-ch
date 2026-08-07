# noise-suppression-for-voice: the nixpkgs attribute is `rnnoise-plugin`, not the Arch name

**Finding:** Arch's official `extra` repository packages this RNNoise-based OBS filter as
`noise-suppression-for-voice` (`pacman -Si noise-suppression-for-voice`, `URL:
https://github.com/werman/noise-suppression-for-voice`). nixpkgs has no attribute of that name —
`pkgs ? noise-suppression-for-voice` is `false`, at top level and inside `obs-studio-plugins`
alike. The same upstream project exists in nixpkgs under a different name entirely: `rnnoise-plugin`.

**Why the obvious guesses are wrong.** nixpkgs also ships `rnnoise` and `pkgs.obs-studio-plugins.obs-noise`,
both plausible-looking candidates that are NOT this package:

- `rnnoise` (homepage `https://people.xiph.org/~jm/demo/rnnoise/`) is the bare Xiph library this
  plugin links against, not the OBS/LADSPA/LV2 filter itself.
- `obs-studio-plugins.obs-noise` (description "Plug-in for noise generation and noise effects for
  OBS") is a *noise-generation* effect — the opposite of what this repo's `capture` group needs.

`rnnoise-plugin` is the real match: `meta.homepage` is
`https://github.com/werman/noise-suppression-for-voice`, byte-for-byte the same URL as the Arch
package's own `URL` field, confirming both names point at the identical upstream project.

**Evidence** (against the nixpkgs revision this repo's `flake.lock` had pinned at the time,
`148bab9c1c3c53136ecb44a6ea356a0ed5b39b06`):

```
$ pacman -Si noise-suppression-for-voice | grep -E 'Repository|URL'
Repository      : extra
URL             : https://github.com/werman/noise-suppression-for-voice

$ nix eval --impure --expr '(import (builtins.getFlake
    "github:NixOS/nixpkgs/148bab9c1c3c53136ecb44a6ea356a0ed5b39b06").outPath
    { system = "x86_64-linux"; }) ? noise-suppression-for-voice'
false

$ nix eval --impure --expr '(import (builtins.getFlake
    "github:NixOS/nixpkgs/148bab9c1c3c53136ecb44a6ea356a0ed5b39b06").outPath
    { system = "x86_64-linux"; }).rnnoise-plugin.meta.homepage'
"https://github.com/werman/noise-suppression-for-voice"
```

A force-evaluating `builtins.tryEval (builtins.seq pkgs.rnnoise-plugin true)` against the same
revision also confirms `rnnoise-plugin` is a live derivation, not a stale `throw` alias — the same
class of failure `nvtop-nixpkgs-attribute-is-nvtopPackages-full.md` (nixmedia) and
`delta-pacman-name-is-git-delta.md` (nixsh) document for the same reason a plain
`hasAttrByPath`/`pacman -Ss` guess would miss.

**Decision this drove:** `lib/nixrecord.nix`'s `capture.noise-suppression-for-voice` entry carries
`arch = "noise-suppression-for-voice"` and `nixpkgs = "rnnoise-plugin"` — a genuine platform
divergence in the package name, not a typo or an omission. The entry's own inline note states the
divergence directly, the same way nixsh's `delta` entry does, so a future reader auditing
`nixosPackages` for a `rnnoise-plugin` line does not go looking for a bug in the resolution logic
instead of the catalogue's own deliberate choice.

**Method:** `pacman -Si` against a live CachyOS host (`CORBET-ELITEBOOK`, the one host this repo
targets) for the Arch side; a force-evaluating `nix eval --impure` against the nixpkgs revision
this repo's own `flake.lock` had pinned at the time, plus the `meta.homepage`/pacman `URL`
cross-check, for the nixpkgs side — same method this family's other naming-divergence studies use.
