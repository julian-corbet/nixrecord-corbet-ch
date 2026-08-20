#
# nixrecord's cluster surface: declare which of this repository's applications run in the cluster,
# and render them.
#
# ── THIS MODULE DOES NOT IMPLEMENT KUBERNETES, AND THAT IS THE DESIGN ──────────────────────────
#
# A sibling repository's whole subject is the app grammar: a workload declares WHAT IT NEEDS -- an
# image, ports, an exposure class, whether it may sleep, which directories it writes and what backs
# them -- and that grammar renders the Argo CD Application, the Namespace, the Deployment and the
# Service. Everything expressible in those terms is expressed in them: this module DEFINES INTO
# `nixk3s.apps` and renders no Kubernetes object of its own.
#
# So it is a translator. What it adds is the one thing the grammar cannot know: what these
# particular applications ARE. Which of them migrates a schema it does not own and therefore must
# never be judged dead mid-start; which keeps a document somebody wrote rather than a cache; which
# is called by an audience on a schedule nobody here controls and therefore never reaches idle.
#
# IMPORT THE GRAMMAR ALONGSIDE IT. `nixk3s.apps` is declared there, not here, and a render that
# composes this module without it fails with "the option `nixk3s.apps' does not exist".
#
# ── WHY A CAPTURE REPOSITORY HAS A CLUSTER PLANE ───────────────────────────────────────────────
#
# The rest of this repository configures one host, because that is where a camera, a microphone and
# an encoder physically are. What happens to a capture afterwards is not a single-host concern:
# publishing an episode and running a show are continuous services with an audience. Same subject,
# second plane -- and the two share nothing but the subject, which is why this module composes
# alone and imports none of the host-side options.
#
# ── THE KNOWLEDGE/VALUE SPLIT, ENFORCED RATHER THAN TRUSTED ────────────────────────────────────
#
# `lib/applications.nix` holds what is true of the software anywhere. A declaration holds what is
# true of one cluster. The two cannot supply each other's half: the catalogue says WHERE inside the
# container a directory lives and only a declaration can say WHAT BACKS IT, so an application that
# writes a media library and is declared without a backing is refused rather than quietly rendered
# onto a pod's ephemeral filesystem.
#
# THE SAME CUT, FOUR MORE TIMES, because these are the ones that look like they belong on the
# wrong side until you say what they mean:
#
#   * PROBES. Which ones exist, what each asks for, and which one must not exist is the software --
#     catalogue. How many seconds a start is given is the machine it starts on -- declaration, and
#     it may move numbers only: `probeBudget` cannot bring a probe into existence.
#   * HARDENING. What a process needs from the kernel is the software -- catalogue, and an
#     application established to need nothing is hardened wherever it is declared rather than one
#     cluster at a time. Whether to hold its root filesystem read-only is a day somebody picks --
#     declaration, checked against the catalogue before it is granted.
#   * RESOURCES. A request is a share of one particular node's hardware. There is no knowledge half
#     at all, which is why `resources` is a declaration term with no catalogue counterpart, and why
#     an empty one is warned about rather than filled in with a number nobody measured.
#   * ADOPTION. Whether the objects already exist is a cluster's HISTORY -- the same application is
#     adopted where somebody once applied it by hand and created fresh where nobody did. No
#     knowledge half either, so `adopt` is a declaration term, and it changes the rendered
#     Application rather than the Deployment: server-side apply and diff instead of client-side.
#
# ── ONE TERM IS DELIBERATELY ABSENT ────────────────────────────────────────────────────────────
#
# There is no option here for handing a state directory's group ownership to the cluster. The
# grammar has one, and its effect is a RECURSIVE CHOWN of the volume on every pod start. Both
# applications catalogued here keep a directory a person curated from outside -- a media library,
# a show's rundowns -- so the mechanism that would rewrite that ownership is not exposed rather
# than exposed and warned about. An absent term cannot be typed by accident.
{ config, lib, ... }:

let
  cfg = config.nixrecord;
  platform = cfg.clusterPlatform;
  catalogue = (import ../lib/applications.nix { }).applications;

  declared = lib.filterAttrs (_: w: w.enable) cfg.applications;
  workloads = lib.mapAttrsToList (name: w: { inherit name w; entry = catalogue.${w.app}; }) declared;

  # A whole reference wins over a repository plus a tag, which is what pinning by digest looks
  # like. The catalogue never carries either: a version is a deployment's choice and a digest is
  # one deployment's proof of what it is running.
  #
  # The third case -- neither stated -- is REFUSED by an assertion below, and this falls back to
  # the bare repository rather than interpolating a null so that the refusal is what the reader
  # sees. A message about a missing version says what to do; a type error inside a string does not.
  imageOf = entry: w:
    if w.image != null then w.image
    else if w.version != null then "${entry.image}:${w.version}"
    else entry.image;

  portsOf = entry: lib.mapAttrs (_: number: { inherit number; }) entry.ports;

  # The split in one function: WHERE inside the container comes from the catalogue, WHAT BACKS IT
  # comes from the declaration, and neither side can supply the other's half.
  stateOf = entry: w:
    lib.mapAttrs
      (key: backing: {
        mountPath = entry.state.${key};
        inherit (backing) claim hostPath hostPathType readOnly;
      })
      w.state;

  # Only the timings a declaration actually stated. Everything it left null stays the catalogue's,
  # which is what makes a budget a TUNING rather than a replacement: naming one number never
  # silently resets the other three.
  budgeted = b: lib.filterAttrs (_: v: v != null) b;

  # Readiness AND liveness, both from the catalogue and neither synthesized. A liveness probe is
  # the one a repository must not invent: guessed, it restarts a container that is merely starting
  # slowly, and the catalogue says `null` for exactly the application where that would happen.
  #
  # THE SHAPE IS THE CATALOGUE'S AND THE PATIENCE IS THE DEPLOYMENT'S. Which probes exist, what
  # each one asks for and which port it reads are properties of the software; how many seconds a
  # start is given is a property of the machine it starts on, and the same image is slower on cold
  # storage than on the disk somebody measured. So a budget may move the numbers and may not
  # introduce a probe -- asking for a probe the catalogue does not declare is refused below.
  probesOf = entry: w:
    (lib.optionalAttrs (entry.readiness != null) {
      readiness = { port = entry.primaryPort; } // entry.readiness // budgeted w.probeBudget.readiness;
    })
    // (lib.optionalAttrs (entry.liveness != null) {
      liveness = { port = entry.primaryPort; } // entry.liveness // budgeted w.probeBudget.liveness;
    });

  # CONTAINER HARDENING, and every term in it only ever RESTRICTS -- there is no `privileged`, no
  # capability to ADD and no per-container user, here or in the grammar underneath.
  #
  # The two halves come from opposite sides on purpose. What a process needs from the kernel is a
  # property of the software, so an application the catalogue has established needs nothing is
  # hardened WHEREVER it is declared rather than one cluster at a time; an application whose needs
  # are unestablished is left alone, and the absence is visible in the rendered object instead of
  # being a comment somewhere. Whether to hold the root filesystem read-only is the deployment's
  # call even where the catalogue says it is possible, because somebody has to be the first
  # installation to run it that way.
  securityOf = entry: w:
    lib.optionalAttrs (entry.hardening.privileges == "none")
      {
        allowPrivilegeEscalation = false;
        capabilitiesDrop = [ "ALL" ];
      }
    // lib.optionalAttrs (w.readOnlyRootFilesystem != null) {
      inherit (w) readOnlyRootFilesystem;
    };

  # Whole Secrets, loaded wholesale. Nothing here can carry a secret's CONTENT, which is what makes
  # a declaration written against this module safe to publish.
  secretsOf = w:
    lib.listToAttrs (map (s: lib.nameValuePair s { secret = s; envFrom = true; }) w.envFromSecrets);

  # Handed to the band model only when the consumer says it is part of the render: `origin` and
  # `slot` are ITS terms, and defining them into a render that does not declare them is an eval
  # error rather than a graceful no-op.
  addressingOf = w:
    lib.optionalAttrs (platform.origin != null) {
      origin = platform.origin;
      inherit (w) slot;
    };

  mkApp = x:
    let inherit (x) entry w; in
    {
      inherit (w) namespace createNamespace project adopt exposure scaling;
      image = imageOf entry w;
      ports = portsOf entry;
      state = stateOf entry w;
      secrets = secretsOf w;
      env = entry.env // w.env;
      args = entry.args ++ w.args;
      probes = probesOf entry w;
      security = securityOf entry w;
      resources = { inherit (w.resources) requests limits; };
    }
    // lib.optionalAttrs (w.wake != null) { inherit (w) wake; }
    // addressingOf w;

  # ── Assertions ────────────────────────────────────────────────────────────────────────────────

  stateAssertions = lib.concatMap
    (x:
      let inherit (x) name w entry; in
      [
        {
          assertion = lib.attrNames w.state == lib.attrNames entry.state;
          message =
            "nixrecord: application `${name}` must back every directory it writes, and backs "
            + (if w.state == { } then "none" else lib.concatMapStringsSep ", " (k: "`${k}`") (lib.attrNames w.state))
            + ". It writes: "
            + (if entry.state == { } then "nothing"
            else lib.concatStringsSep ", " (lib.mapAttrsToList (k: p: "`${k}` at ${p}") entry.state))
            + ".";
        }
        {
          assertion = lib.all
            (backing: (backing.claim == null) != (backing.hostPath == null))
            (lib.attrValues w.state);
          message =
            "nixrecord: application `${name}` must back each directory with EITHER an existing claim OR "
            + "a node path, never both and never neither. A directory with no backing is a pod's own "
            + "filesystem, and what these applications keep there is a finished episode or the rundown "
            + "of a show -- work somebody made, not a cache that regenerates.";
        }
      ])
    workloads;

  # An application that cannot start without a credential is not made runnable by hoping one is
  # around. The catalogue lists the variable NAMES the software documents; the declaration has to
  # name a Secret that carries them. Neither half can be the other.
  secretEnvAssertions = lib.map
    (x:
      let inherit (x) name w entry; in
      {
        assertion = entry.secretEnv == [ ] || w.envFromSecrets != [ ];
        message =
          "nixrecord: application `${name}` cannot start without ${toString (lib.length entry.secretEnv)} "
          + "environment variables it has no default for ("
          + lib.concatMapStringsSep ", " (v: "`${v}`") entry.secretEnv
          + "), and no Secret was named in `envFromSecrets`. Every one of those values is either a "
          + "credential or one installation's address, so this repository cannot supply them and will "
          + "not render a workload that starts, fails and reports it as the application's fault.";
      })
    workloads;

  # A version and a whole reference are the only two places a tag can come from, and there is no
  # third. This used to be enforced by `version` having no default -- which only fired when
  # something forced it, so a declaration that overrode `image` could leave it unstated and never
  # find out. Stated as an assertion, the rule holds whether or not anything reads the value.
  referenceAssertions = lib.map
    (x:
      let inherit (x) name w; in
      {
        assertion = w.image != null || w.version != null;
        message =
          "nixrecord: application `${name}` states neither a version nor a whole image reference, "
          + "and there is no third place to get one from. An unstated version is not a sensible "
          + "default here -- it is `latest`, on an application that rewrites what it reads on start.";
      })
    workloads;

  # A budget says HOW PATIENT a probe is. It cannot bring one into existence, and the refusal is
  # sharper than it looks: for one of the two applications catalogued here the missing liveness
  # probe IS the decision, so a declaration that budgets one is not filling a gap, it is asking for
  # the container to be restarted part-way through a schema migration.
  probeBudgetAssertions = lib.concatMap
    (x:
      let inherit (x) name w entry; in
      lib.mapAttrsToList
        (probe: declared: {
          assertion = budgeted w.probeBudget.${probe} == { } || declared != null;
          message =
            "nixrecord: application `${name}` budgets a `${probe}` probe, and the catalogue gives "
            + "`${w.app}` none. A budget says how patient a probe is; it cannot bring one into "
            + "existence -- and a probe missing from this catalogue is missing on purpose. See the "
            + "catalogue note for `${w.app}`.";
        })
        { readiness = entry.readiness; liveness = entry.liveness; })
    workloads;

  # Whether a read-only root is POSSIBLE is the catalogue's answer and whether to take it is the
  # declaration's. Asking for one where the software writes outside the directories it declares is
  # not hardening -- it is a container that fails on its first write, reporting a permission rather
  # than the setting that denied it.
  rootFilesystemAssertions = lib.map
    (x:
      let inherit (x) name w entry; in
      {
        assertion =
          w.readOnlyRootFilesystem != true || entry.hardening.rootFilesystem == "state-only";
        message =
          "nixrecord: application `${name}` asks for a read-only root filesystem, and `${w.app}` "
          + (if entry.hardening.rootFilesystem == "writable"
          then
            "writes outside the directory it declares. That is a documented property of the image "
            + "rather than an accident, so the read-only root does not harden it -- it stops it "
            + "starting."
          else
            "has not been established to write only inside it. An unverified read-only root is not "
            + "a restriction anybody checked; it is a failure waiting for the first write.")
          + " See the catalogue note for `${w.app}`.";
      })
    workloads;

  # Whether an application MAY idle is a property of the software and of who calls it, so the
  # catalogue owns it and this is a refusal rather than a warning. Whether an application that may
  # idle DOES is a deployment's call, and that direction is left entirely open.
  idleAssertions = lib.map
    (x:
      let inherit (x) name w entry; in
      {
        assertion = w.scaling == "always" || entry.idle == "safe";
        message =
          "nixrecord: application `${name}` is declared `scaling = \"${w.scaling}\"`, and `${w.app}` may "
          + "not idle. Something outside this cluster calls it on a schedule nobody here sets, so zero "
          + "replicas is not a rested workload -- it is a caller receiving a timeout and recording the "
          + "service as broken. See the catalogue note for `${w.app}`.";
      })
    workloads;

  # A namespace outlives every workload in it, so exactly one thing may own it. Two anchors is not a
  # merge, it is two Namespace objects Argo will fight over.
  anchorAssertions =
    let
      anchors = lib.filter (x: x.w.createNamespace) workloads;
      byNs = lib.groupBy (x: x.w.namespace) anchors;
    in
    lib.mapAttrsToList
      (ns: xs: {
        assertion = lib.length xs == 1;
        message =
          "nixrecord: namespace `${ns}` is anchored by ${toString (lib.length xs)} applications ("
          + lib.concatMapStringsSep ", " (x: "`${x.name}`") xs
          + "). Exactly one workload may create a namespace.";
      })
      byNs;

  slotAssertions =
    let
      claimed = lib.filter (x: x.w.slot != null) workloads;
      bySlot = lib.groupBy (x: toString x.w.slot) claimed;
    in
    lib.mapAttrsToList
      (slot: xs: {
        assertion = lib.length xs == 1;
        message =
          "nixrecord: slot ${slot} is claimed by ${toString (lib.length xs)} applications ("
          + lib.concatMapStringsSep ", " (x: "`${x.name}`") xs
          + "). A slot is one identity in several address spaces at once; two workloads on one number "
          + "is two workloads on one address.";
      })
      bySlot;

  # A warning is `{ when; message; }` -- the renderer decides whether to print it, so the condition
  # travels with the text rather than being applied here.
  warnings = lib.concatMap
    (x:
      let inherit (x) name w; in
      [
        {
          when = w.scaling == "scale-to-zero" && w.wake == null;
          message =
            "nixrecord: application `${name}` is declared scale-to-zero with no wake front, so nothing "
            + "brings it back. At zero replicas that is not an idle workload, it is an unreachable one.";
        }
        {
          # The test is the DIGEST rather than "did somebody set `image`". A whole reference with no
          # digest -- a bare repository, or a repository and a tag -- resolves to whatever the
          # registry is serving today, and the old test called that pinned because it had been
          # typed into the right option.
          when = !(lib.hasInfix "@sha256:" (imageOf x.entry w));
          message =
            "nixrecord: application `${name}` runs `${imageOf x.entry w}`, a reference with no digest. "
            + "Both applications catalogued here rewrite what they read on start -- a schema in one "
            + "case, an on-disk format in the other -- so a reference that resolves somewhere else "
            + "tomorrow is a data migration nobody reviewed. Pin it by digest.";
        }
        {
          when = w.resources.requests == { };
          message =
            "nixrecord: application `${name}` is declared with no resource requests, so the scheduler "
            + "places it as if it cost nothing. On a cluster running one thing that is true enough; on "
            + "a busy one it is how a node ends up oversubscribed by workloads that all looked small. "
            + "What it costs on YOUR hardware is not something this repository can know, which is why "
            + "this is a warning and not a value.";
        }
        {
          when = w.slot != null && platform.origin == null;
          message =
            "nixrecord: application `${name}` claims slot ${toString w.slot}, and "
            + "`nixrecord.clusterPlatform.origin` is unset -- so the number is checked for collisions "
            + "inside this repository and by nothing for which RANGE it may come from.";
        }
      ])
    workloads;

  # The four numbers a probe is allowed to be re-tuned by, and nothing else. There is no `path`
  # here and no `port`: what a probe ASKS FOR is the software's business, and a term that let a
  # deployment change it would let a probe point somewhere the application does not serve while
  # still reading like a tuning knob.
  budgetType = lib.types.submodule {
    options = {
      initialDelaySeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "Delay before the first probe. Null leaves the catalogue's.";
      };
      periodSeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Interval between probes. Null leaves the catalogue's.";
      };
      failureThreshold = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = ''
          Consecutive failures before the verdict is acted on. With `periodSeconds` this is the
          whole budget, and it is the number worth moving on slow hardware: it decides how long a
          start is tolerated, not how often it is looked at.
        '';
      };
      timeoutSeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "How long one probe may take before it counts as failed. Null leaves the catalogue's.";
      };
    };
  };

  commonOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to render this workload. Declaring the attribute is declaring the workload, so this
        defaults to true; set false to park a declaration without rendering it.
      '';
    };

    namespace = lib.mkOption {
      type = lib.types.str;
      default = platform.namespace;
      defaultText = lib.literalExpression "config.nixrecord.clusterPlatform.namespace";
      description = "Namespace this workload lands in.";
    };

    createNamespace = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether this workload anchors its namespace. Defaults to false, because these applications
        share one namespace by default and exactly one of them may own it.
      '';
    };

    project = lib.mkOption {
      type = lib.types.str;
      default = platform.project;
      defaultText = lib.literalExpression "config.nixrecord.clusterPlatform.project";
      description = "Delivery project this workload's Application belongs to.";
    };

    adopt = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether this workload TAKES OVER objects that already exist in the cluster rather than
        creating them -- applied once by hand, by an addon, or by a manifest this declaration
        replaces. The grammar renders such an Application with server-side apply and server-side
        diff, so Argo compares against what the API server actually holds instead of against a
        client-side reconstruction of it.

        A DECLARATION'S TERM, and it is the knowledge/value split in one line: whether an object
        already exists is that cluster's HISTORY, not a fact about the software. The same
        application is adopted on the cluster that has been running it under a hand-written
        manifest and created fresh on the one that never has -- identical in every other term here
        and different in this one. So the catalogue has no half of it at all, the way `resources`
        has none.

        AND IT IS NOT COSMETIC. A rendered spec is never byte-identical to the YAML it replaces:
        labels differ, fields this grammar sets appear, fields it does not set disappear. Argo sees
        that diff and acts on it -- and every application catalogued here backs a directory, which
        forces `Recreate`: the old pod stops before the new one starts, and on the publishing end
        that can land part-way through a schema migration. Server-side apply shrinks the diff to
        what genuinely changed; it does not make it zero. Render it, diff it against what is live,
        and decide knowingly.
      '';
    };

    slot = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = null;
      description = ''
        THE POSITION this workload holds in the fleet's ordered identity space. Not an address --
        the layers underneath map it into however many address spaces the fleet keeps, which is
        why nothing here moves one. The VALUE is a fleet fact and belongs to the consumer.
      '';
    };

    exposure = lib.mkOption {
      type = lib.types.enum [ "internal" "nb" "public" ];
      default = "internal";
      description = ''
        Who can reach it, as a CLASS rather than an address. Defaults to the closed answer: an
        application that has not been thought about is not on the internet -- which matters here,
        because both of these have a web face that edits real work and one of them publishes to
        the whole internet by design.
      '';
    };

    scaling = lib.mkOption {
      type = lib.types.enum [ "always" "scale-to-zero" ];
      default = "always";
      description = ''
        Whether the workload may idle to zero replicas.

        The catalogue records whether idling is POSSIBLE for a given application -- whether anybody
        outside calls it on their own schedule, and whether the first request after a cold start
        can afford one. That half is a refusal, not a suggestion: an application the catalogue says
        may not idle is refused here rather than warned about. Whether an application that MAY idle
        DOES is a deployment's call, because the wake path is one cluster's routing and this
        repository cannot see whether that path is healthy.
      '';
    };

    wake = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "keda" "sablier" ]);
      default = null;
      description = ''
        Which front wakes it from zero. Meaningless unless `scaling = "scale-to-zero"`, and its
        absence there is warned about: nothing brings the workload back.
      '';
    };

    state = lib.mkOption {
      default = { };
      description = ''
        What backs each directory the catalogue says this application writes, keyed by the SAME
        names. Backing a directory it does not write, or leaving one it does write unbacked, is an
        eval error rather than a surprise at runtime.
      '';
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          claim = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "An existing PersistentVolumeClaim, by name. Nothing here creates one.";
          };
          hostPath = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "A directory on the node. Pins the workload to whichever node holds it.";
          };
          hostPathType = lib.mkOption {
            type = lib.types.str;
            default = "Directory";
            description = ''
              The hostPath type, when a node path is what backs it. `Directory` refuses to start
              when the path is missing, and that refusal is the point: the alternative comes up
              with an EMPTY media library or an empty rundown tree and looks healthy doing it.
            '';
          };
          readOnly = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether the mount is read-only.";
          };
        };
      });
    };

    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Environment this deployment adds, merged over whatever the catalogue sets. Values only --
        anything secret belongs in a Secret and arrives through `envFromSecrets`. The time zone a
        show runs on lives here, because which clock a rundown counts against is a property of the
        show rather than of the software.
      '';
    };

    envFromSecrets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Secrets loaded wholesale, by name. Named rather than carried: nothing in this repository
        can hold a secret's contents, which is what makes a declaration written here publishable.
        An application whose catalogue entry lists `secretEnv` is refused without one.
      '';
    };

    args = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Arguments appended to whatever the catalogue sets.";
    };

    resources = {
      requests = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = { cpu = "100m"; memory = "256Mi"; };
        description = ''
          What the scheduler must find before it will place this workload. A DEPLOYMENT'S value in
          the strictest sense: it is a share of one particular machine, and the same application is
          sized differently on a node that also holds an encoder than on one that does not. The
          catalogue cannot know either number, and a number it guessed would be obeyed by a
          scheduler as if somebody had measured it.

          Leaving it empty is not free, and it is warned about rather than refused: a container with
          no request is placed as though it cost nothing.
        '';
      };

      limits = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = { memory = "1Gi"; };
        description = ''
          Ceilings -- and they are not one instrument used twice. A memory limit is a KILL
          threshold; a cpu limit is a THROTTLE. Which one you are setting matters most on the
          application that migrates a schema on start: a kill part-way through is exactly the
          failure the catalogue's patient readiness budget exists to avoid, arriving by a different
          door.
        '';
      };
    };

    readOnlyRootFilesystem = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = ''
        Whether the container's own root filesystem is mounted read-only, leaving only the
        directories the workload declares writable.

        WHETHER IT IS POSSIBLE is the catalogue's answer, and asking where it is not is refused
        rather than rendered: an application that writes outside the directory it declares does not
        get harder to attack this way, it gets stopped. WHETHER TO TAKE IT is this deployment's,
        which is the reason the term lives here -- somebody has to be the first installation to run
        an application under a read-only root, and that is a day somebody picks.

        Three states, all of them meant. `null` states nothing and renders nothing, which is what a
        workload already running without the field needs; `false` says out loud that the root stays
        writable; `true` asks for it and is checked against the catalogue.
      '';
    };

    probeBudget = lib.mkOption {
      default = { };
      description = ''
        HOW PATIENT the catalogue's probes are, on this cluster's hardware.

        The catalogue owns the SHAPE -- which probes exist, what each asks for, which port it reads,
        and the one deliberate absence -- because all of that is true of the software wherever it
        runs. It cannot own the numbers past a point: the same image starts slower on cold storage
        or a busy node than on the machine somebody measured, and a budget that was right there is a
        restart loop here.

        So this moves numbers and only numbers. It cannot introduce a probe, change what one asks
        for, or point one somewhere else; every timing left unstated stays the catalogue's, and
        budgeting a probe the application does not have is refused.
      '';
      type = lib.types.submodule {
        options = {
          readiness = lib.mkOption {
            type = budgetType;
            default = { };
            description = "Re-tuned timings for the readiness probe the catalogue declares.";
          };
          liveness = lib.mkOption {
            type = budgetType;
            default = { };
            description = ''
              Re-tuned timings for the liveness probe the catalogue declares. Refused where it
              declares none -- there, the absence is the decision.
            '';
          };
        };
      };
    };

    image = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        A whole image reference, overriding the catalogue's repository and this workload's version.
        This is where a digest pin goes, and pinning by digest is what makes two syncs of an
        identical rendered tree run identical code. Leaving it null warns: both applications here
        rewrite what they read on start, so a moving tag is an unreviewed data migration.
      '';
    };
  };
in
{
  options.nixrecord.clusterPlatform = {
    namespace = lib.mkOption {
      type = lib.types.str;
      default = "broadcast";
      description = ''
        Namespace these applications share unless a declaration says otherwise. The default is a
        word for what they DO, not a copy of anybody's cluster: which namespace an installation
        actually uses is one of the facts this repository refuses to know.
      '';
    };

    project = lib.mkOption {
      type = lib.types.str;
      default = "broadcast";
      description = "Delivery project their Applications belong to unless a declaration says otherwise.";
    };

    origin = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        THE IDENTITY THIS REPOSITORY'S APPS ARE ADDRESSED UNDER, when the render composes the band
        model. A repository naming itself is not a fleet fact; which band that name binds is, and it
        lives in whatever repository owns the fleet. Left null, slots are still checked for
        collisions here and by nothing for range.
      '';
    };
  };

  options.nixrecord.applications = lib.mkOption {
    default = { };
    description = ''
      The applications this repository runs in a cluster, keyed by a name of your choosing.

      THE ENUM IS THE HOUSE RULE. It is built from `lib/applications.nix`, so an application this
      repository does not catalogue is not a refused value here -- it is not a value. What belongs
      in that catalogue is the publishing and playout end of this repository's own subject: what
      becomes of a recording, and what runs a live show. Not playback of somebody else's library,
      and not transcoding a file that already exists.
    '';
    example = lib.literalExpression ''
      {
        example-podcast = {
          app = "castopod";
          version = "0.0.0";
          exposure = "public";
          slot = 10;
          state.media.hostPath = "/example/state/podcast-media";
          envFromSecrets = [ "example-podcast-env" ];
        };
      }
    '';
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
      options = commonOptions // {
        app = lib.mkOption {
          type = lib.types.enum (lib.attrNames catalogue);
          description = "Which application, from the catalogue. Available: ${lib.concatStringsSep ", " (lib.attrNames catalogue)}.";
        };

        version = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Which version this workload runs, used as the image tag. Defaulted nowhere, and null
            only when `image` carries a whole reference instead -- which is the better answer, and
            the reason the two are not both required. Stating neither is refused: an unstated
            version is not a conservative default, it is `latest`.
          '';
        };
      };
    }));
  };

  # ── Computed, read-only ───────────────────────────────────────────────────────────────────────
  options.nixrecord.clusterSlots = lib.mkOption {
    type = lib.types.attrsOf lib.types.ints.unsigned;
    readOnly = true;
    default = lib.listToAttrs
      (map (x: lib.nameValuePair x.name x.w.slot) (lib.filter (x: x.w.slot != null) workloads));
    defaultText = lib.literalExpression "every declared workload that claims a slot";
    description = ''
      workload -> the position it claims. Nothing is rendered from it here: what an address looks
      like is the private layer's business, and this is what that layer reads to build one.
    '';
  };

  config = {
    nixk3s.apps = lib.listToAttrs (map (x: lib.nameValuePair x.name (mkApp x)) workloads);
    nixidy.assertions =
      stateAssertions ++ secretEnvAssertions ++ referenceAssertions ++ probeBudgetAssertions
      ++ rootFilesystemAssertions ++ idleAssertions ++ anchorAssertions ++ slotAssertions;
    nixidy.warnings = warnings;
  };
}
