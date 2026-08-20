# nixrecord

**Capturing the real world — light, sound, a thing that happened — and the encode policy for what
you make of it.**

You go outside with a camera and a microphone, or you sit someone down for an interview, or you
play a set. Something happens once, in front of hardware, and it has to end up as a file. This
repo is the declarative half of that: [OBS Studio](https://obsproject.com) as the capture and
composite engine, Nix as the interface. A user declares a recording INTENT — a named profile:
canvas, codec, bitrate, which real inputs go where — and this repo renders the OBS files that
intent actually needs (`~/.config/obs-studio/basic/profiles/<name>/{basic.ini,recordEncoder.json}`
and `~/.config/obs-studio/basic/scenes/<name>.json`), the same way
[nixscroll][nixscroll] renders a compositor config from structured options instead of hand-edited
text.

Alongside the generator, a small **catalogue** of what belongs installed on that same single
host: the capture engine, the capture device's userspace tooling, the physical control surface,
and the editor (`kdenlive`/`shotcut`) that turns a capture into a deliverable. See
[The catalogue](#the-catalogue).

And a second plane, because a recording does not stop mattering when the encode finishes:
**[the cluster plane](#the-cluster-plane)** — the publishing and playout services this repo owns
(a podcast host, a run-of-show timer), declared for a Kubernetes cluster rather than for a desk.

## The placement rule

Stated as a boundary rather than a list, so the next addition is decidable rather than argued:

> **nixrecord captures the REAL world — light, sound, physical events. Capturing a digital
> interface is owned by the repo that owns that interface.**

"Record" is a verb, not a domain. Left undefined it swallows everything, because every subsystem
on a machine can be recorded, and a repo that owned all of them would become a dependency of every
one of those subsystems. That is the failure this rule prevents, and it is concrete:

| What is being captured | Owner | Why not here |
|---|---|---|
| a terminal session (`asciinema`, `vhs`) | [nixsh][nixsh] | Terminal capture is a terminal concern. Every host has a console; pulling it here would make a capture repo a dependency of ordinary shell work on machines that have no camera, no microphone and no encoder. |
| a desktop, a window, a game | the repo owning that display or remote-access surface — [nixremote][nixremote], [nixdesktop][nixdesktop], [nixscroll][nixscroll] | Screen capture needs a compositor, a portal and a session; it is a property of the display substrate, not of a camera. Filing it here would key a single-host repo to something every graphical host does. |
| a camera, a microphone, a line input, a capture card | **here** | It needs physical hardware pointed at a physical event. |

The payoff is what makes the rule worth having: **the real world needs a camera, a microphone and
an encoder — and encoders are not uniform.** That single constraint decides the shape of this
whole repo (next section), which is exactly what a boundary drawn on "record" as a verb could
never have told you.

### Two clauses that settle the recurring arguments

**A capture device's userspace tooling follows the device, not the shell.** `v4l-utils` is a CLI,
and [nixsh][nixsh]'s layer test ("does it default to a graphical window? no → nixsh") would
therefore claim it. It should not: `v4l2-ctl` is the userspace half of a kernel subsystem — the
same category as `alsa-utils` or `pciutils`, not the same category as `ripgrep`. nixsh's catalogue
contains no hardware-enablement packages at all, and adding the first one has a real cost: a
universal terminal catalogue would offer a camera-control tool to hosts with no camera, and the
capture host's actual capability would stop being described in one place. Device tooling is keyed
to the device; it lands wherever the device does.

**A control surface belongs to the session it drives.** A Stream Deck is a physical instrument.
What it drives here is a live capture, so what its buttons DO is declared here — see
[Control surfaces](#control-surfaces-the-stream-deck). What it IS — a USB device that must appear
at a stable node with usable permissions — is [nixusb][nixusb]'s, which owns USB device identity
for the host. Two repos, two questions, no overlap.

## Single-host by construction

AV1 hardware encode is **generation-dependent, not vendor-dependent**, and the gap is not subtle:

| Reference host | AV1 decode | AV1 encode |
|---|---|---|
| a nixarch laptop, Intel Arc iGPU (Lunar Lake) | yes | **yes** |
| a nixarch workstation, Radeon RDNA2 | yes | **no — RDNA2 has no AV1 encoder at all; that arrived with RDNA3** |

Both hosts *play* AV1 in hardware. Exactly one can *produce* it. That is why this repo composes
onto one machine, and why AV1 delivery is pinned to it. Editing — `kdenlive`, `shotcut`, this
repo's own `edit` catalogue group, see [The catalogue](#the-catalogue) — is catalogued on that
SAME host: editing is ruled encoder-adjacent here, not encoder-agnostic, so "you can only cut on
the laptop" is an accepted property of this repo rather than an argument against bundling the
editor with the encoder.

The workstation's GPU is also shared with other workloads on the same box, so it is not a
scheduling-free encode target even for the codecs it *can* encode. The laptop's is not shared with
anything.

**This is a claim about the ENCODE PIPELINE, and only about it.** Capture, composite and encode
compose onto one machine because they need a specific encoder that lives in one machine. What
happens to the artefact afterwards has no such tie — publishing an episode and running a live show
are continuous services with an audience, and an audience does not wait for a laptop to be open.
That is the second plane, and it is why one repo has both: same subject, different substrate. See
[The cluster plane](#the-cluster-plane).

## Codec policy: capture in H.264, deliver in AV1

This is a production principle, not a settings detail, and it is stated here because it is the one
thing a capture repo can get wrong in a way no later step can repair.

**Local capture is always H.264.**

1. **It encodes acceptably on CPU.** That cannot be said of H.265 or AV1 at capture resolution and
   framerate, in real time. This matters more than a benchmark suggests: a capture that misses
   realtime does not run slower, it drops frames, and a dropped frame is unrecoverable. H.264 is
   the only codec here that degrades to "software, on whatever machine you happen to be holding"
   and still lands a usable file.
2. **It is an excellent edit source.** Every NLE, every browser, every phone decodes it, in
   hardware, everywhere.
3. The module's default `codec = "software"` is `obs_x264` — software H.264. That default is the
   policy's floor, deliberately, not a placeholder for a better one.

**AV1 is a DELIVERY codec**, hardware-encoded, on the one host that can:

4. **Realtime AV1 encode is a pixel-rate budget, not a stream count.**
   `studies/av1-vaapi-pixel-budget.md` measures it on real hardware — roughly 1.05 gigapixels per
   second, two independent ways, with realtime capacity planned at about 70% of that. Spending
   that budget at *capture* time, where exceeding it costs frames, instead of at *export* time,
   where exceeding it only costs minutes, is the wrong trade with nothing bought.
5. **Delivery is where AV1 pays.** Both reference hosts decode it in hardware, so an AV1
   deliverable plays everywhere while being produced in exactly one place.

So the pipeline is: **capture H.264 → edit → deliver AV1.** Do not reach for AV1 as a capture
format. `codec = "av1"` exists in the option surface for the case where the capture *is* the
deliverable and there is no edit step at all; it is not the default and should not become one.

The AV1 export itself is an NLE render preset — `kdenlive`/`shotcut`, this repo's own `edit`
catalogue group, see [The catalogue](#the-catalogue) — or a transcoder job in
[nixmedia][nixmedia]. nixrecord states the contract and does not ship a second transcoder to
execute it — the same tool-versus-policy split [nixmedia][nixmedia]'s own placement rule already
draws in the other direction ("a transcoder belongs there **as a tool**, never **as a policy**").

## Composite once, encode once

The single most important design constraint on any capture-source mechanism this module renders —
stated here even while `sources`/`layout` are unimplemented (see
[Sources](#sources-cameras-microphones-capture-cards) and [Status](#status)) because it is what
decides the SHAPE that mechanism must have when it returns: **recording N inputs must mean N
entries in ONE scene, composited onto ONE canvas, encoded by ONE `RecEncoder` — never N separate
recording outputs.**

The pixel-budget study above is why. A hardware encode ceiling expressed in pixels per second is
not a session-count limit the way consumer NVENC's 3-session cap is: one encode at a given
resolution×fps, or three concurrent encodes summing to the same pixel rate, measure the same
aggregate throughput. Concurrency buys nothing and adds N-1 redundant copies of scene compositing
and container muxing on top of an unchanged shared budget.

A camera in the corner of a wide shot will be a scene item, not a second recording.

## The split

| Output | Class | Owns |
|---|---|---|
| `homeManagerModules.nixrecord` (`.default`) | home-manager | `~/.config/obs-studio/basic/{profiles,scenes}/*`, generated from `programs.nixrecord.*`. Installs nothing. |
| `nixosModules.nixrecord` (`.default`) | NixOS | `environment.systemPackages` for the catalogue and `programs.nixrecord.package` (default `pkgs.obs-studio`). |
| `systemManagerModules.nixrecord` (`.default`) | Arch/CachyOS | publishes into [nixarch][nixarch]'s `nixarch.packages.pacman` / `.aur` reconciler. Cannot install anything itself. |
| `nixidyModules.nixrecord` (`.default`) | nixidy / Kubernetes | the second plane: defines the publishing and playout applications into [nixk3s][nixk3s]'s `nixk3s.apps`. Renders no Kubernetes object of its own. See [The cluster plane](#the-cluster-plane). |

**No `packages` output, deliberately.** Unlike [nixscroll][nixscroll] — which packages `scroll`
itself because scroll has no home in nixpkgs — every entry in this catalogue already exists in
nixpkgs, the Arch official repos, or the AUR. There is nothing here for a third packaging path to
add.

## The catalogue

There are two, and they are not variants of each other: this one (`lib/nixrecord.nix`) is what gets
INSTALLED on the capture host, and `lib/applications.nix` is what RUNS in a cluster. This section
is the first. The second is [The cluster plane](#the-cluster-plane).

Same shape as [nixsh][nixsh]'s `lib/tools.nix` and [nixmedia][nixmedia]'s `lib/media.nix`: one
entry per selectable package, each carrying its `arch` name, its `nixpkgs` attribute, and `aur`
(default `false`) where the pacman name lives in the AUR rather than an official repo. That last
field is load-bearing and not cosmetic: `pacman -S` fails the WHOLE transaction on an AUR name
with "target not found", taking every other package in the same converge down with it.

Groups, each of which is a direct application of the placement rule:

- **`capture`** — the engine and what it needs to see and hear real hardware: OBS itself, the V4L2
  userspace tooling, and capture-chain filters that OBS loads.
- **`control`** — physical control surfaces driving a live session, and the client a button press
  actually calls.
- **`edit`** — `kdenlive` and `shotcut`, two faces of the shared MLT engine rather than competing
  alternatives (a project authored in one opens in the other): `kdenlive` for multicam switching
  and mature proxy editing, `shotcut` for the quick stuff. Catalogued here, not in
  [nixcreative][nixcreative], per the operator's ruling that video/audio editing is
  encoder-adjacent — see [Single-host by construction](#single-host-by-construction) and
  [What this repo does not own](#what-this-repo-does-not-own).
- **`perform`** — instruments whose output is a performance that happened once and was recorded.

**ONE PACKAGE, ONE CATALOGUE.** Both this catalogue and its siblings feed the same
`environment.systemPackages` on a NixOS host, so a package declared in two repos is a collision,
not a redundancy. The placement rule decides which repo owns a package; it never licenses a copy
in the other. Nothing catalogued in [nixcreative][nixcreative] (`qtractor`, `inkscape`, `krita`,
`blender` — audio production and illustration/3D, not video editing), [nixmedia][nixmedia]
(players, transcoders), [nixsh][nixsh] (`ffmpeg`, `yt-dlp`, `asciinema`, `vhs`) or
[nixaudio][nixaudio] (the audio fabric) appears here under this repo's own reasoning. Video/audio
editing (`kdenlive`, `shotcut`) is this repo's own `edit` group above, not nixcreative's.

## Sources: cameras, microphones, capture cards

The real inputs this repo intends to composite, and what they would render to in OBS's own file
format — the "Confirmed" column is deliberately honest about which of these have actually cleared
this repo's own bar (a live OBS round-trip, not just a `strings` hit — see the discipline
`home/nixrecord.nix`'s own header documents, and the `av1_vaapi` mistake that discipline exists
because of):

| Source | OBS id | Confirmed |
|---|---|---|
| camera / webcam / HDMI-to-USB bridge | `pipewire-camera-source` (tentative) | found via `strings` only (Method 2, `studies/obs-config-ground-truth.md`) — the weakest of this repo's own confidence tiers, never round-tripped against a live OBS |
| microphone / line in | `pulse_input_capture` | live round-trip (Method 1), `studies/obs-config-ground-truth.md` — already wired, see [Audio](#audio-pin-the-sink-never-follow-default) |
| a monitored output (playback being captured back) | `pulse_output_capture` | as above — already wired |
| SDI/HDMI capture card | DeckLink, via the `decklink.so` OBS ships | plugin observed loaded in a live OBS run; no source id or option surface confirmed |

**`sources`/`layout` do not exist in the module today — removed, not merely narrowed.** Earlier
code rendered `sources.<name>.type` as `output` / `window` / `region`, producing OBS's own
`pipewire-screen-capture-source` / `pipewire-window-capture-source` — screen/window capture, which
[the placement rule](#the-placement-rule) puts outside this repo, in
[nixremote][nixremote]/[nixdesktop][nixdesktop]/[nixscroll][nixscroll]. Those three were the ONLY
source types this module ever implemented, so removing them removed the entire `sources`/`layout`
option surface, not one enum value among several: there is currently no way to declare ANY video
capture source, and `programs.nixrecord.profiles.<name>` has no `sources`/`layout` option at all.
A profile today renders only encode settings (`basic.ini`/`recordEncoder.json`) plus, if
`audio.sink`/`.micSink` are set, an audio-only scene — see
[Audio](#audio-pin-the-sink-never-follow-default).

**What a consumer relying on the old behaviour needs to do.** Screen/window/region capture was
never this repo's to keep; declare that capture in whichever repo owns the actual display surface
([nixremote][nixremote]/[nixdesktop][nixdesktop]/[nixscroll][nixscroll]) instead. A camera,
microphone-as-video-source, or capture-card source has no substitute here yet — that is
[Status](#status) item 1, and the table above is why it is not a quick add: no id in it has
cleared this repo's own confirmation bar the way every id currently in `home/nixrecord.nix` has.

What Nix will be able to declare for a camera is smaller than it is for a screen, and worth noting
for whenever this is built: a V4L2 device node is a path, not an interactive portal grant, so a
camera source should be fully pre-declarable in a way a screen capture never was (the portal's
ScreenCast flow needs a human to pick a target in a live dialog, and only a runtime-minted restore
token skips it). The remaining care will be that the path stays stable across replug and reboot —
which is precisely what [nixusb][nixusb] exists to guarantee, and why a raw `/dev/video0` should
never appear in a declaration.

## Audio: pin the sink, never follow "default"

`programs.nixrecord.audio.sink`/`.micSink` take an exact PipeWire/PulseAudio node name (`pactl
list short sinks`), rendered as the literal `device_id` OBS's `pulse_output_capture` /
`pulse_input_capture` sources use. Left `null` — the default for both — no audio source is
rendered into the scene collection at all. No audio is preferable to silently wrong audio.

**Do not reach for `followSystemDefault` without reading its own docstring first.** `device_id =
"default"` means "whatever the policy daemon currently calls the default sink", re-evaluated on
every device event, not fixed when the recording starts. That is an observed failure, not a
hypothetical: a policy daemon re-elects the default whenever any device appears or disappears, and
on a host that also mirrors audio from another machine over a network audio fabric — where a sink
"appears" over the network rather than being plugged in locally — that re-election can point a
live recording at a sink physically producing sound on a different machine, with the level meters
still moving, because something is still being captured. Just not what was intended.

Pinning the literal node name is the fix: re-election can change what "default" MEANS, never what
a literal name resolves to. On a host composing [nixaudio][nixaudio], the name to pin is the
stable one that repo already declares.

## Encoder selection: declared, never detected

`profiles.<name>.codec` is `av1` / `hevc` / `h264` / `software` (`obs_x264`). This module cannot
detect what the machine supports: Nix evaluation happens wherever the flake is built, not
necessarily on the machine the config will run on, so an eval-time hardware probe would as often
as not answer for the wrong box — the same "declared, never detected" doctrine
[nixarch][nixarch]'s own `packages.distro` option documents. Get it wrong and OBS refuses to start
the recording with a real, loud error.

What this module adds is `fallbackCodecs` — a list that renders one COMPLETE sibling profile per
entry (`<name>-fallback-<codec>`, identical in every other setting), so an alternative is a
one-click profile switch away in OBS's own UI rather than something to hand-configure while a
recording is already failing. OBS's file format has no config-level "try A, then B" primitive to
render even if this module wanted one; this is the honest shape of what Nix can pre-build.

Given [the codec policy](#codec-policy-capture-in-h264-deliver-in-av1), the sane declaration for a
capture profile is `codec = "h264"` with `fallbackCodecs = [ "software" ]` — hardware H.264 when
the GPU is free, software H.264 when it is not, and the same file either way.

## Control surfaces: the Stream Deck

A deck is a grid of physical keys that starts a recording, cuts a scene, mutes a mic. Two facts
shape how it is declared:

**OBS's websocket server ships with OBS.** `obs-websocket.so` is present in the installed OBS's own
plugin directory — a deck needs a *client*, not a plugin. What gets catalogued is the client and
the deck daemon, never a re-implementation of a control channel that already exists.

**Prefer a deck daemon whose entire configuration is a file it reads at startup.** That is exactly
the shape this repo already renders for OBS, and it avoids the failure the next section names: a
GUI that owns its own JSON state will fight a `home-manager switch` for control of it. A
config-file daemon has no such state to fight over.

The USB side is not this repo's. Permissions, stable naming, and the udev rule that makes the
device reachable at all belong to [nixusb][nixusb].

## Live performance

A DJ set is in scope, and the placement rule is what puts it there rather than a taste call: the
instrument is physical, the controllers are physical, the set happens once, and the artifact is a
record of something that happened. Nothing is being captured off a digital interface. The mix's
master output is a capture like any other, and it is composited and encoded under the same policy
as a camera.

What happens to that recording afterwards — cutting it — is this repo's own `edit` catalogue group
(`kdenlive`/`shotcut`, see [The catalogue](#the-catalogue)). Mastering the audio itself is
[nixcreative][nixcreative]'s `qtractor`.

## The cluster plane

Two applications, declared for a cluster rather than for the host with the camera on it:

| Application | What it is | Why it is here |
|---|---|---|
| **castopod** | A podcast host: episodes go in, a feed comes out, and clients all over the internet fetch it. | The publishing end of a recording. It is what the capture side's deliverable is *for*. |
| **ontime** | A live-event timer and rundown editor: build the order of a show, then count it down and drive the stage displays on the day. | The live end of one. A run-of-show is the same physical event this repo's placement rule already claims, seen from the control desk instead of the lens. |

The placement rule reads the same one step further along: this repo owns **the real event and the
artefact made of it**. Playing back somebody else's library is [nixmedia][nixmedia]'s, and
re-encoding a file that already exists is too — the boundary is drawn on the EVENT, not on the
file type, which is exactly why "it touches media" is not an argument for filing something here.

**It is a translator, not a renderer.** The plane defines into the public
[nixk3s][nixk3s] app grammar's `nixk3s.apps` and emits no Kubernetes object of its own. That
grammar already knows how to turn "an image, ports, an exposure class, the directories it writes"
into an Argo CD Application, a Namespace, a Deployment and a Service. What this repo adds is the
half a grammar cannot know: what these two applications *are*.

```nix
{
  imports = [
    inputs.nixk3s.nixidyModules.apps      # the grammar — without it, `nixk3s.apps` does not exist
    inputs.nixrecord.nixidyModules.nixrecord
  ];

  nixrecord.applications.podcast = {
    app = "castopod";
    version = "1.0.0";                               # or a whole `image` reference instead —
    createNamespace = true;                          # the two are alternatives, not a pair
    exposure = "public";
    state.media.hostPath = "/your/media/directory";  # WHERE it mounts is the catalogue's; what
    envFromSecrets = [ "podcast-env" ];              # backs it is only ever yours
    adopt = true;                                    # only if this cluster ALREADY runs it —
                                                     # server-side apply, so the diff is real

    resources.requests = { cpu = "100m"; memory = "256Mi"; };  # a share of YOUR hardware, and
    resources.limits.memory = "1Gi";                           # there is no knowledge half
  };
}
```

`lib/applications.nix` holds what is true of the software wherever anyone runs it — the port, the
directory it writes, the environment variables it cannot start without, the shape of its probes,
what it needs from the kernel. A declaration holds what is true of one cluster. **Neither can
supply the other's half, and that is enforced rather than trusted:** leaving a directory the
application writes unbacked is an eval error, and so is backing one it does not write.

Four terms sit close enough to the line to be worth naming, because each one is cut through the
middle rather than filed on one side — or, in the last two, is not cut at all:

| Term | Catalogue's half | Declaration's half |
|---|---|---|
| **Probes** | Which probes exist, what each asks for, which port it reads — and the one that must not exist. | `probeBudget`: how many seconds a start is given, because that is a fact about a machine. It moves numbers and cannot introduce a probe. |
| **Hardening** | What the process needs from the kernel. An application established to need nothing is hardened *wherever* it is declared; one whose needs are unestablished is left visibly alone. | `readOnlyRootFilesystem`: being the first installation to run it that way is a day somebody picks. Asking where the catalogue says the software writes outside its directory is refused. |
| **Resources** | *Nothing.* There is no knowledge half — a request is a share of one particular node. | `resources.requests` / `.limits`, in full. Stating none is warned about, never guessed at. |
| **Adoption** | *Nothing.* Whether the objects already exist is that cluster's history, not a fact about the software. | `adopt`: renders the Application with server-side apply and diff, for taking over objects somebody already applied. The same application is adopted on one cluster and created fresh on another. |

The two applications are opposites on nearly every axis a workload has, which is what makes two of
them enough to keep the model honest:

- **castopod migrates a schema it does not own**, on start, without being asked. So its image
  wants a digest rather than a tag, its readiness budget is measured in minutes, and it gets **no
  liveness probe at all** — a liveness probe there restarts the container mid-migration, which is
  how a slow start becomes a restart loop that looks like the application's fault.
- **ontime holds a document somebody wrote**, as readable JSON rather than an opaque database, and
  gets both probes: readiness patient because the request most likely to be waiting is the first
  one after an idle period, liveness impatient because the thing it exists to catch is a hang
  during a live show.
- **Only one of them may sleep, and the catalogue decides which.** ontime's web face idles to zero
  happily: between shows nothing fires on a timer and nothing watches a directory. castopod cannot,
  and not because it is large — podcast clients poll a feed on a schedule nobody here controls, so
  "nobody is using it" is not a state it reliably reaches, and a cold start that has to boot PHP
  and shake hands with a remote database in front of a feed fetch is a timeout rather than a wake.
  Declaring it `scale-to-zero` is refused, not warned about.
- **Only one of them is hardened, and again the catalogue decides.** ontime is one Node process on
  one high port that never needs a privilege it did not start with, so every capability is dropped
  and escalation denied *wherever it is declared* — that is knowledge, not a preference somebody
  opts into per cluster. castopod's needs are **unestablished**: it is a PHP application behind a
  web server in one image, with an entrypoint that arranges its own runtime directories, and this
  repo does not assert a profile it has not checked. So nothing is rendered, and the open question
  is legible in the object instead of living in a comment.

**One term is deliberately absent.** There is no option here for handing a state directory's group
ownership to the cluster. The mechanism for doing that recursively rewrites ownership on the volume
at *every* pod start, and both of these keep a directory a person curated from outside — a media
library, a show's rundowns. An absent term cannot be typed by accident.

## What this repo does not own

| Concern | Owner | The line |
|---|---|---|
| Transcoding a file you already have (`handbrake`) | [nixmedia][nixmedia] | You re-encode what you already have; nothing new entered the world. Its encode *policy* is this repo's; the tool is not. |
| Playback (`vlc`, `mpv`) | [nixmedia][nixmedia] / [nixsh][nixsh] | Consumption. |
| Serving somebody else's library (a media server, an archive) | [nixmedia][nixmedia] | Consumption again, on a cluster instead of a desk. [The cluster plane](#the-cluster-plane) owns the publishing end of a recording made HERE, not distribution of a collection. |
| Rendering the Kubernetes objects a cluster application needs | [nixk3s][nixk3s] | The app grammar is its whole subject. The cluster plane declares INTO it and emits no Kubernetes object of its own. |
| Audio routing, patchbays, mixers, per-app volume, stable device names | [nixaudio][nixaudio] | Routing is not capture. A patchbay edits the graph nixaudio declares; separating a graph from its editor helps nobody. |
| The audio *transport* between hosts | [nixaudio][nixaudio] | A capture profile pins a node name; it never moves audio between machines. |
| USB device identity, udev rules, stable device nodes | [nixusb][nixusb] | This repo says what a device is FOR; nixusb makes it reliably addressable. |
| GPU driver stack, VAAPI userspace, card arbitration | [nixgpu][nixgpu] | A codec declaration assumes the driver exists; it does not install one. |
| Terminal session recording (`asciinema`, `vhs`) | [nixsh][nixsh] | The placement rule, first row. |
| Screen, window and game capture; streaming a session to another machine | [nixremote][nixremote], [nixdesktop][nixdesktop] / [nixscroll][nixscroll] | The placement rule, second row. |

## Not managed: global.ini / user.ini

`global.ini` and `user.ini` hold OBS's LAST-USED profile and scene-collection selection, dock
layout and window geometry — session state, not intent. This module never touches either.
Rendering a `Profile=`/`SceneCollection=` line into `global.ini` was considered and rejected: every
manual profile switch in OBS's own UI (trying the fallback profile by hand, mid-shoot) would be
silently reverted on the next `home-manager switch` — the "Nix fights the running program for its
own runtime state" footgun [nixscroll][nixscroll] avoids for the same reason. Which profile OBS
opens with stays a manual choice.

## Usage

```nix
{
  imports = [ inputs.nixrecord.homeManagerModules.nixrecord ];

  programs.nixrecord = {
    enable = true;

    encoder.device = "/dev/dri/by-path/pci-0000:00:02.0-render"; # by-path, not renderD1XX — see option doc
    audio.micSink  = "alsa_input.usb-XXXX_YYYY-00.analog-stereo"; # pactl list short sources

    # An interview's audio track. H.264 master, software fallback. No video capture source yet
    # — see "Sources" above for why `sources`/`layout` (a camera in frame) isn't an option
    # surface here today.
    profiles.interview = {
      canvas = { width = 1920; height = 1080; };
      fps = "30";
      codec = "h264";
      fallbackCodecs = [ "software" ];
      rateControl = "CBR";
      bitrate = 12000;
    };
  };
}
```

The cluster plane composes separately and shares nothing with the above but the subject — see
[The cluster plane](#the-cluster-plane) for the declaration and `examples/all/values.nix` for a
complete, entirely invented one.

Add the system side only if you want the catalogue installed by this repo rather than some other
way:

```nix
{ imports = [ inputs.nixrecord.nixosModules.nixrecord ]; programs.nixrecord.enable = true; }
# or, on Arch via nixarch:
{
  imports = [ inputs.nixrecord.systemManagerModules.nixrecord ];
  nixarch.packages.pacman = config.nixrecord.archPackages;
  nixarch.packages.aur    = config.nixrecord.aurPackages;
}
```

## Mechanism public, values private

Every id and key this module renders is either OBS's own real internal identifier — confirmed
against a real installed binary, see `studies/obs-config-ground-truth.md` — or a neutral
placeholder. No default bakes in a specific machine's sink name, device path, GPU render node or
bitrate: `profiles` is `{}`, and `audio.sink`/`.micSink`/`encoder.device` are all `null`. A
consumer's own hardware goes in their own config, never in this repo's defaults.

The cluster catalogue holds the same kind of thing one substrate over: a port, a mount path inside
a container, the NAMES of environment variables an application documents, a probe budget. No
address, no node, no hostname, no namespace, no storage path and no secret's contents — every one
of those is one deployment's fact, arrives from the consumer, and several of them are refused
outright if the consumer does not supply them.

## No invented numbers

The cluster plane draws the same line: `resources.requests` has no default and no catalogue
counterpart, because a share of a node is a measurement of somebody's hardware rather than a fact
about the software. Declaring none is warned about — a container with no request is scheduled as
if it cost nothing — and never quietly filled in, since a guessed number is obeyed by a scheduler
exactly as if it had been measured.

`bitrate` has no default — the right value depends on resolution, codec and content in a way no
single number survives across every profile a consumer might declare (that option's docstring
gives a starting-point range, labelled as a starting point, not a fact). `rateControl` stops at
`CBR`/`VBR` rather than also offering `CQP`/`ICQ`, because the settings key that would carry a
CQP/ICQ quality VALUE did not come back confirmed against the real binary's string table. Left out
rather than guessed. See `studies/obs-config-ground-truth.md`'s "What did NOT come back confirmed".

## Status

**Pre-alpha. The scope rule above is newer than the code in places, and the code is still catching
up.**

Verified: `home/nixrecord.nix`'s option tree evaluates cleanly (`lib.evalModules` against a
home-manager stand-in, `checks/config-rendering.nix`) and renders the expected
`basic.ini`/`recordEncoder.json`/scene-collection JSON for a representative set of options —
including the `fallbackCodecs` sibling-profile expansion and the audio
pinning-versus-`followSystemDefault` distinction. Every literal id the renderer emits was checked
against a real, installed OBS Studio. The catalogue (`lib/nixrecord.nix`, `modules/catalogue.nix`
and its NixOS/Arch backends) resolves all three of its groups — `capture`, `control`, `edit` —
into `archPackages`/`aurPackages`/`nixosPackages`, also checked
(`checks/catalogue-resolution.nix`).

The cluster plane is verified further than the host side is, because it can be: it renders through
the real [nixk3s][nixk3s] grammar and the real renderer inside `nix flake check`, so both what it
resolves (`checks/cluster-eval.nix` — every guard given a declaration that must be refused, and a
control case that must render, so a typo in the shared base cannot make the refusals pass for the
wrong reason) and what actually comes out (`checks/cluster-render.nix` — assertions read off the
rendered YAML rather than off the options that produced it) are checked. Both were
mutation-tested: moving a catalogued port, dropping the namespace anchor, neutering the state
guard, emptying the required-environment list, removing the digest pin, flipping the idle verdict,
inventing the liveness probe castopod deliberately does not get, weakening the hostPath type and
dropping the declaration-side environment merge each turn one or both red.

The plane declares applications; it does not deploy them. There is no evidence here that either
application has been run from this repo's own declaration against a real cluster — the catalogue's
facts come from a live deployment of each, which is a different claim.

Open, in order:

1. **No video capture source exists.** `sources`/`layout` were removed entirely, not narrowed —
   see [Sources](#sources-cameras-microphones-capture-cards) for what that took out and what a
   consumer relying on the old `output`/`window`/`region` types needs to do instead.
   Camera/microphone-as-video/capture-card sources are the intended replacement and are unbuilt:
   no id for one has cleared this repo's own confirmation bar yet.
2. **Not yet verified end to end**: an actual `home-manager switch` producing a profile+scene pair
   that OBS opens and records from without complaint. The closest proxy — hand-authoring a scene
   item and reloading it through the real binary — works, and
   `experiments/obs-headless-probe.sh` reproduces it, but that is a narrower claim.
3. **Not yet attempted**: a `nix flake check`-sandboxed real-OBS acceptance check in the style of
   [nixscroll][nixscroll]'s `checks/config-accepted.nix` — see `flake.nix`'s own comment for why it
   was left out rather than built below the rest of this repo's evidentiary bar.

## Related projects

Part of the same independently-usable NixOS module family. The boundaries this repo's placement
rule draws are against [nixsh][nixsh] (terminal session capture),
[nixremote][nixremote] / [nixdesktop][nixdesktop] / [nixscroll][nixscroll] (display and
remote-access surfaces), [nixcreative][nixcreative] (audio production and illustration/3D —
`qtractor`, `inkscape`, `krita`, `blender`; video/audio editing itself is this repo's own `edit`
catalogue group, not nixcreative's), [nixmedia][nixmedia] (playback and transcoding),
[nixaudio][nixaudio] (the audio fabric a capture pins a name from), [nixusb][nixusb] (the device
identity a camera and a control surface both need) and [nixgpu][nixgpu] (the encoder a codec
declaration assumes). [nixarch][nixarch] is the Arch host reconciler the `systemManagerModules`
backend publishes into, and [nixk3s][nixk3s] is the app grammar the `nixidyModules` cluster plane
declares into.

[nixsh]: https://github.com/julian-corbet/nixsh-corbet-ch
[nixmedia]: https://github.com/julian-corbet/nixmedia-corbet-ch
[nixcreative]: https://github.com/julian-corbet/nixcreative-corbet-ch
[nixaudio]: https://github.com/julian-corbet/nixaudio-corbet-ch
[nixusb]: https://github.com/julian-corbet/nixusb-corbet-ch
[nixgpu]: https://github.com/julian-corbet/nixgpu-corbet-ch
[nixremote]: https://github.com/julian-corbet/nixremote-corbet-ch
[nixdesktop]: https://github.com/julian-corbet/nixdesktop-corbet-ch
[nixscroll]: https://github.com/julian-corbet/nixscroll-corbet-ch
[nixarch]: https://github.com/julian-corbet/nixarch-corbet-ch
[nixk3s]: https://github.com/julian-corbet/nixk3s-corbet-ch

## License

[MIT License](LICENSE) © 2026 Julian Corbet
