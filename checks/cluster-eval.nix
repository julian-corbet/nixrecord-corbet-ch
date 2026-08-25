# Proves the cluster module resolves what it claims and REFUSES what it claims to refuse, both
# directions, through the real renderer and the real app grammar.
#
# Both halves matter and neither is enough alone. A guard nobody has watched fire is a comment; a
# guard that fires on everything is a wall. So every case below is a complete, otherwise-valid
# surface with exactly one thing wrong, and the `control` case is the same shape with nothing wrong
# and MUST render -- without it, a typo in the shared base would make every other case "pass" for
# the wrong reason.
#
# ONE OF THE REFUSALS IS NOT A GUARD AT ALL. Naming an application the catalogue does not hold
# fails as a TYPE ERROR -- the stronger kind of boundary, because it is unwritable rather than
# refused, and nobody has to remember it. `tryEval` cannot tell that apart from a guard, so
# everything that IS a guard additionally has its message asserted by content.
#
# THE VERSION USED TO BE A SECOND ONE, and it was the weaker kind of unwritable: a required option
# is only required when something forces the value, and a declaration that stated a whole `image`
# reference forced nothing, so it could leave the version unstated forever and never hear about it.
# The rule is an assertion now, and the two are honest alternatives rather than a required pair.
{ pkgs, lib, nixidy, appsModule, clusterModule, values }:

let
  base = import values;

  mkEnv = v: nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [ appsModule clusterModule v ];
  };

  # `tryEval` alone forces only WHNF. Forcing the derivation path is what actually runs the module
  # system's type checks and the assertions underneath.
  renders = v: (builtins.tryEval (builtins.seq (mkEnv v).environmentPackage.drvPath true)).success;

  # An assertion fired, AND it is the one meant: a refusal that happens for an unrelated reason is
  # a false pass, which is exactly the failure this repository's checks exist to make impossible.
  failsWith = infix: v:
    let
      r = builtins.tryEval (lib.any
        (a: !a.assertion && lib.hasInfix infix a.message)
        (mkEnv v).config.nixidy.assertions);
    in
    r.success && r.value;

  warnsWith = infix: v:
    lib.any (w: w.when && lib.hasInfix infix w.message) (mkEnv v).config.nixidy.warnings;

  # A surface with nothing declared at all, to prove the module is inert until something asks.
  emptyCfg = (mkEnv {
    nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
    nixidy.target.branch = "main";
  }).config;

  goodCfg = (mkEnv base).config;
  podcast = goodCfg.nixk3s.apps.example-podcast;

  # The same app under a MODIFIED surface, for the properties that have to compare one declaration
  # against another rather than read the example's own.
  podcastIn = v: (mkEnv v).config.nixk3s.apps.example-podcast;
  showcaller = goodCfg.nixk3s.apps.example-showcaller;

  with' = f: lib.recursiveUpdate base f;

  results = {
    # ── The control, and the floor ────────────────────────────────────────────────────────────
    "the example surface renders -- without this every refusal below could pass for the wrong reason" =
      renders base;

    "an undeclared surface renders no apps at all, rather than a default one" =
      emptyCfg.nixk3s.apps == { };

    "both declared workloads reach the grammar" =
      lib.sort (a: b: a < b) (lib.attrNames goodCfg.nixk3s.apps)
      == [ "example-podcast" "example-showcaller" ];

    "the catalogue supplies the port, and the declaration never states one" =
      podcast.ports.http.number == 8080 && showcaller.ports.http.number == 4001;

    "a version becomes the tag, and a whole reference overrides it" =
      showcaller.image == "getontime/ontime:0.0.0"
      && lib.hasInfix "@sha256:" podcast.image;

    "the catalogue supplies WHERE a directory lives and the declaration supplies WHAT BACKS IT" =
      podcast.state.media.mountPath == "/var/www/castopod/public/media"
      && podcast.state.media.hostPath == "/example/state/podcast-media"
      && showcaller.state.data.mountPath == "/data";

    # NAMED KEYS rather than a wholesale envFrom: every variable this software reads is already
    # known by name, so a key added to the Secret later has no business reaching the process.
    "a Secret is named, never carried, and reaches the process key by key" =
      podcast.secrets ? example-podcast-env
      && podcast.secrets.example-podcast-env.env ? CP_DATABASE_PASSWORD
      && podcast.secrets.example-podcast-env.env.CP_DATABASE_PASSWORD == "CP_DATABASE_PASSWORD";

    "an application that needs no credential is given none" =
      showcaller.secrets == { };

    # ── The two probe shapes, which are the whole reason a catalogue beats a default ──────────
    "the readiness budget is the migration rather than the traffic" =
      podcast.probes.readiness.initialDelaySeconds == 20
      && podcast.probes.readiness.failureThreshold == 18
      && podcast.probes.readiness.port == "http";

    # The grammar declares `liveness` on every app with a null default, so its ABSENCE is the value
    # null rather than a missing attribute -- and asserting the missing attribute is a check that
    # can only ever be false. Assert what the grammar actually renders from: nothing.
    "the application that migrates on start is given NO liveness probe, deliberately" =
      podcast.probes.liveness == null && showcaller.probes.liveness != null;

    "the application that does not migrate is given both, because a hang mid-show is real" =
      showcaller.probes.readiness.periodSeconds == 5
      && showcaller.probes.liveness.periodSeconds == 15
      && showcaller.probes.liveness.failureThreshold == 6;

    # ── The environment split ─────────────────────────────────────────────────────────────────
    "where it writes is knowledge, and agrees with the mount path by construction" =
      showcaller.env.ONTIME_DATA == "${showcaller.state.data.mountPath}/"
      && showcaller.env.NODE_ENV == "docker";

    "which clock a show runs on is a value, so the catalogue does not carry one" =
      showcaller.env.TZ == "UTC"
      && !((import ../lib/applications.nix { }).applications.ontime.env ? TZ);

    # ── Unwritable, not merely refused ────────────────────────────────────────────────────────
    "an application the catalogue does not hold is not a value this option has" =
      !renders (with' { nixrecord.applications.example-podcast.app = "nonesuch"; });


    # ── The guards, each with its message asserted ────────────────────────────────────────────
    "a workload with neither a version nor a whole reference is refused" =
      failsWith "neither which version it runs"
        (with' { nixrecord.applications.x = { app = "ontime"; }; });

    # The other side of the same rule: a whole reference is enough on its own, and the example
    # states no version for the workload that carries one.
    "and a whole reference alone is enough -- the two are alternatives, not a pair" =
      goodCfg.nixrecord.applications.example-podcast.version == null && renders base;

    "backing a directory the application does not write is refused" =
      failsWith "must back every directory it writes"
        (with' { nixrecord.applications.example-podcast.state.data.hostPath = "/example/nope"; });

    "leaving a directory it DOES write unbacked is refused" =
      failsWith "must back every directory it writes"
        (lib.recursiveUpdate base { nixrecord.applications.example-showcaller.state = lib.mkForce { }; });

    "a directory backed by both a claim and a node path is refused" =
      failsWith "EXACTLY ONE of a claim"
        (with' { nixrecord.applications.example-podcast.state.media.claim = "example-claim"; });

    "an application that cannot start without credentials is refused without a Secret" =
      failsWith "names no Secret to deliver"
        (with' { nixrecord.applications.example-podcast.credentials.secret = lib.mkForce null; });

    "an application the catalogue says may not idle is refused scale-to-zero" =
      failsWith "unsafe to idle"
        (with' { nixrecord.applications.example-podcast.scaling = "scale-to-zero"; });

    "and the one that MAY idle is not refused it -- the guard reads the catalogue, not the class" =
      showcaller.scaling == "scale-to-zero";

    "two workloads anchoring one namespace is refused" =
      failsWith "Exactly one workload may create a namespace"
        (with' { nixrecord.applications.example-showcaller.createNamespace = true; });

    "two workloads on one slot is refused" =
      failsWith "is claimed by 2 workloads"
        (with' { nixrecord.applications.example-showcaller.slot = 10; });

    # ── Hardening: what the kernel is asked for, and who gets to ask ──────────────────────────
    # The catalogue establishes what a process NEEDS, so the application it has cleared is hardened
    # wherever it is declared rather than one cluster at a time. The other is left alone, visibly:
    # nothing is rendered, so the open question is legible in the object rather than in a comment.
    "the application the catalogue has cleared is hardened without anyone asking" =
      showcaller.security.allowPrivilegeEscalation == false
      && showcaller.security.capabilitiesDrop == [ "ALL" ];

    "and the one whose needs are unestablished is left entirely alone" =
      podcast.security.allowPrivilegeEscalation == null
      && podcast.security.capabilitiesDrop == [ ]
      && podcast.security.readOnlyRootFilesystem == null;

    # The catalogue's `writable` renders NOTHING rather than an explicit false: false is already
    # the platform's default, so writing it out says nothing about the software and everything
    # about what one live container happens to carry -- which is a cluster's history, and belongs
    # in a typed merge where somebody types it on purpose and a reader can count it.
    "the one catalogued as needing to write renders no field at all" =
      podcast.security.readOnlyRootFilesystem == null;

    # ── Adoption: a cluster's history, which no catalogue can hold a half of ──────────────────
    # Two workloads of one repository, differing here and in nothing else that matters, is the
    # whole argument for the term living on the declaration side: one of these clusters already
    # holds the objects and the other does not, and the software is the same either way.
    "taking over objects a cluster already holds is the declaration's to say, and reaches the grammar" =
      podcast.adopt == true;

    "and a workload that says nothing creates its objects rather than adopting them" =
      showcaller.adopt == false;

    # ── Resources: the one term with no knowledge half at all ─────────────────────────────────
    "a share of one cluster's hardware comes from the declaration and from nowhere else" =
      podcast.resources.requests == { cpu = "250m"; memory = "512Mi"; }
      && podcast.resources.limits == { memory = "2Gi"; };

    "and the workload that states none is given none rather than a number nobody measured" =
      showcaller.resources.requests == { } && showcaller.resources.limits == { };

    # ── Probe budgets: the numbers move, the shape does not ───────────────────────────────────
    "a budget moves the number it names" =
      showcaller.probes.readiness.failureThreshold == 36;

    "and leaves every other part of the catalogue's probe exactly as it was" =
      showcaller.probes.readiness.periodSeconds == 5
      && showcaller.probes.readiness.path == "/"
      && showcaller.probes.readiness.port == "http"
      && showcaller.probes.liveness.periodSeconds == 15
      && showcaller.probes.liveness.failureThreshold == 6;

    "the un-budgeted workload keeps the catalogue's numbers untouched" =
      podcast.probes.readiness.failureThreshold == 18
      && podcast.probes.readiness.initialDelaySeconds == 20;

    # The sharpest of the new refusals. On this application the missing liveness probe IS the
    # decision -- budgeting one is not filling a gap, it is asking for the container to be
    # restarted part-way through a schema migration.
    "budgeting a probe the catalogue deliberately withholds is refused" =
      failsWith "does not warrant"
        (with' { nixrecord.applications.example-podcast.probes.liveness.periodSeconds = 10; });

    # ── The warnings that are not refusals ────────────────────────────────────────────────────
    # A workload the scheduler places as if it were free is a real mistake and still not an eval
    # error: what it costs is a measurement of somebody's hardware, and a repository that refused
    # the omission would be demanding a number it cannot check.
    "a workload with no resource requests warns rather than being filled in" =
      warnsWith "places it as if it cost nothing" base
      && !(lib.any
        (w: w.when && lib.hasInfix "example-podcast" w.message && lib.hasInfix "as if it cost nothing" w.message)
        goodCfg.nixidy.warnings);

    # Sleeping with nothing to wake it is a real mistake and still not an eval error: which front a
    # cluster runs is its own business, and a repository that refused the combination would be
    # legislating routing it cannot see.
    "scale-to-zero with no wake front warns rather than refuses" =
      warnsWith "nothing brings it back"
        (with' { nixrecord.applications.example-showcaller.wake = lib.mkForce null; });

    # A moving tag on an application that rewrites what it reads is the same class of mistake, and
    # gets the same treatment: which version a deployment runs is its call, and it should hear that
    # this one is a data migration.
    # THE GRAMMAR'S WARNING, read where the grammar actually puts it -- on the rendered
    # Application rather than in the environment's own list. This repository used to emit a second
    # one of its own saying the same thing; the translator that did is gone, and duplicating a
    # warning the layer underneath already makes would only teach people to skim them.
    "an unpinned reference warns, and the digest-pinned one does not" =
      let
        pinWarn = n:
          lib.any
            (w: w.when && lib.hasInfix "unpinned image" w.message)
            (goodCfg.applications.${n}.warnings or [ ]);
      in
      pinWarn "example-showcaller" && !(pinWarn "example-podcast");
  };

  failed = lib.filter (n: !results.${n}) (lib.attrNames results);
in
pkgs.runCommand "nixrecord-cluster-eval" { } (
  if failed == [ ]
  then ''
    echo "nixrecord: all ${toString (lib.length (lib.attrNames results))} cluster-eval properties hold"
    touch $out
  ''
  else ''
    echo "nixrecord cluster-eval FAILED (${toString (lib.length failed)}/${toString (lib.length (lib.attrNames results))}):" >&2
    ${lib.concatMapStringsSep "\n" (n: ''echo "  - ${n}" >&2'') failed}
    exit 1
  ''
)
