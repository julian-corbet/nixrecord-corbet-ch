# Placeholder values for the cluster module — the file that makes the render check real.
# `nix flake check` renders the whole surface from here, so a module that stops evaluating, or that
# grows a required value nobody supplies, fails in CI rather than in somebody's cluster.
#
# NOTHING HERE IS REAL. Every namespace, path, name, number and image is invented for this file, and
# no credential appears in any form — only the NAME of a Secret that would hold one.
#
# The two declarations are chosen to cover the paths that differ in what gets RENDERED rather than
# merely in what evaluates:
#
#   - a publishing service that cannot idle, takes its whole database configuration from a named
#     Secret, is pinned by digest because it migrates a schema on start, and is judged by a patient
#     readiness probe with no liveness probe at all;
#   - a playout service that CAN idle, holds no credential, carries a time zone the catalogue
#     refuses to guess, sleeps behind a wake front, and is judged by both probes.
#
# Both write a directory, so both render `Recreate` — which is the one thing they agree on, and the
# reason it is asserted on each of them rather than on one.
{
  # Required by the nixidy environment itself, not by any module here.
  nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
  nixidy.target.branch = "main";

  nixrecord.clusterPlatform = {
    namespace = "example-media";
    project = "example-media";
  };

  # Anchors the shared namespace. Digest-pinned, because it runs a schema migration on start and a
  # tag that moves is a migration nobody reviewed. Names the Secret its database coordinates arrive
  # in — without which the module refuses to render it at all. Never idles, and the module would
  # refuse it if it were asked to.
  nixrecord.applications.example-podcast = {
    app = "castopod";
    version = "0.0.0";
    image = "registry.example.com/example-org/example-podcast:0.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000";
    createNamespace = true;
    exposure = "public";
    slot = 10;
    state.media.hostPath = "/example/state/podcast-media";
    envFromSecrets = [ "example-podcast-env" ];
  };

  # Joins the namespace above rather than anchoring a second one. Sleeps, and names the front that
  # wakes it — without which the module warns that nothing brings it back. Carries a version tag
  # rather than a whole reference, which the module warns about too: both are warnings rather than
  # refusals, and having one of each rendered here is what keeps the warning path exercised.
  nixrecord.applications.example-showcaller = {
    app = "ontime";
    version = "0.0.0";
    exposure = "nb";
    slot = 11;
    scaling = "scale-to-zero";
    wake = "keda";
    state.data.hostPath = "/example/state/showcaller-data";

    # Which clock a show counts against is a property of the show, so the catalogue does not guess
    # one and this is where it arrives.
    env.TZ = "UTC";
  };
}
