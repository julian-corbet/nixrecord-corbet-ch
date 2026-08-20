# Proves the cluster module resolves what it claims and REFUSES what it claims to refuse, both
# directions, through the real renderer and the real app grammar.
#
# Both halves matter and neither is enough alone. A guard nobody has watched fire is a comment; a
# guard that fires on everything is a wall. So every case below is a complete, otherwise-valid
# surface with exactly one thing wrong, and the `control` case is the same shape with nothing wrong
# and MUST render -- without it, a typo in the shared base would make every other case "pass" for
# the wrong reason.
#
# TWO OF THE REFUSALS ARE NOT GUARDS AT ALL. Naming an application the catalogue does not hold, and
# leaving out the version, fail as a type error and a missing required option -- not as assertions.
# That is the stronger kind: a boundary nobody has to remember, because it is unwritable rather than
# refused. `tryEval` cannot tell those apart from a guard, so the ones that ARE guards additionally
# have their message asserted by content.
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

    "a Secret is named and never carried" =
      podcast.secrets ? example-podcast-env
      && podcast.secrets.example-podcast-env.envFrom;

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

    "a workload with no version is refused, because a floating tag is not a default anyone can pick" =
      !renders {
        nixidy.target.repository = "https://example.com/x.git";
        nixidy.target.branch = "main";
        nixrecord.applications.x = { app = "ontime"; };
      };

    # ── The guards, each with its message asserted ────────────────────────────────────────────
    "backing a directory the application does not write is refused" =
      failsWith "must back every directory it writes"
        (with' { nixrecord.applications.example-podcast.state.data.hostPath = "/example/nope"; });

    "leaving a directory it DOES write unbacked is refused" =
      failsWith "must back every directory it writes"
        (lib.recursiveUpdate base { nixrecord.applications.example-showcaller.state = lib.mkForce { }; });

    "a directory backed by both a claim and a node path is refused" =
      failsWith "EITHER an existing claim OR a node path"
        (with' { nixrecord.applications.example-podcast.state.media.claim = "example-claim"; });

    "an application that cannot start without credentials is refused without a Secret" =
      failsWith "cannot start without 6 environment variables"
        (with' { nixrecord.applications.example-podcast.envFromSecrets = [ ]; });

    "an application the catalogue says may not idle is refused scale-to-zero" =
      failsWith "may not idle"
        (with' { nixrecord.applications.example-podcast.scaling = "scale-to-zero"; });

    "and the one that MAY idle is not refused it -- the guard reads the catalogue, not the class" =
      showcaller.scaling == "scale-to-zero";

    "two workloads anchoring one namespace is refused" =
      failsWith "Exactly one workload may create a namespace"
        (with' { nixrecord.applications.example-showcaller.createNamespace = true; });

    "two workloads on one slot is refused" =
      failsWith "is claimed by 2 applications"
        (with' { nixrecord.applications.example-showcaller.slot = 10; });

    # ── The warnings that are not refusals ────────────────────────────────────────────────────
    # Sleeping with nothing to wake it is a real mistake and still not an eval error: which front a
    # cluster runs is its own business, and a repository that refused the combination would be
    # legislating routing it cannot see.
    "scale-to-zero with no wake front warns rather than refuses" =
      warnsWith "nothing brings it back"
        (with' { nixrecord.applications.example-showcaller.wake = lib.mkForce null; });

    # A moving tag on an application that rewrites what it reads is the same class of mistake, and
    # gets the same treatment: which version a deployment runs is its call, and it should hear that
    # this one is a data migration.
    "an unpinned reference warns, and the digest-pinned one does not" =
      warnsWith "Pin it by digest" base
      && !(lib.any
        (w: w.when && lib.hasInfix "example-podcast" w.message && lib.hasInfix "Pin it by digest" w.message)
        goodCfg.nixidy.warnings);
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
