# Reads the plane's promises back off the RENDERED BYTES, not off the options that produced them.
#
# The eval check proves the module resolves and refuses. This one proves the manifests that come
# out say what the module claims — which is a different question, and the only one a cluster ever
# sees. An option can be correct and the rendering still wrong.
{ pkgs, lib, nixidy, appsModule, clusterModule, values }:

let
  env = nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [ appsModule clusterModule (import values) ];
  };
in
pkgs.runCommand "nixrecord-cluster-render"
{
  nativeBuildInputs = [ pkgs.yq-go ];
  manifests = env.environmentPackage;
} ''
  set -euo pipefail
  fail=0
  check() { # name expected actual
    if [ "$2" = "$3" ]; then echo "  ok   $1: $3"
    else echo "  FAIL $1: expected '$2', got '$3'"; fail=1; fi
  }
  y() { yq -r "$1" "$2"; }

  echo "== the environment renders both workloads and nothing else =="
  rendered=$(ls "$manifests" | sort | tr '\n' ' ' | sed 's/ $//')
  check "rendered apps" "apps example-podcast example-showcaller" "$rendered"

  pod="$manifests/example-podcast"
  show="$manifests/example-showcaller"
  podd="$pod/Deployment-example-podcast.yaml"
  showd="$show/Deployment-example-showcaller.yaml"

  echo "== the catalogue's ports reach the container, and the declaration never stated one =="
  check "podcast port"    "8080" "$(y '.spec.template.spec.containers[0].ports[0].containerPort' $podd)"
  check "showcaller port" "4001" "$(y '.spec.template.spec.containers[0].ports[0].containerPort' $showd)"

  echo "== one writer per directory, so neither Deployment may roll =="
  check "podcast strategy"    "Recreate" "$(y '.spec.strategy.type' $podd)"
  check "showcaller strategy" "Recreate" "$(y '.spec.strategy.type' $showd)"

  # An absent `replicas` IS one -- Kubernetes' own default. Asserting it is unset is the honest
  # form: the grammar deliberately does not stamp a count on a workload whose count belongs to a
  # wake front, and a sync that stamped one would fight the autoscaler on every pass.
  check "podcast replicas"            "1"    "$(y '.spec.replicas' $podd)"
  check "showcaller replicas unset"   "null" "$(y '.spec.replicas' $showd)"

  echo "== what each one writes, at the path the catalogue names and on the backing the values do =="
  check "podcast mountPath"    "/var/www/castopod/public/media" "$(y '.spec.template.spec.containers[0].volumeMounts[0].mountPath' $podd)"
  check "showcaller mountPath" "/data"                          "$(y '.spec.template.spec.containers[0].volumeMounts[0].mountPath' $showd)"

  # `Directory` rather than `DirectoryOrCreate`, on both. This is the difference between refusing
  # to start and coming up healthy against an EMPTY media library or an empty rundown tree — which
  # is the failure that looks like nothing is wrong until somebody publishes.
  check "podcast hostPath type"    "Directory" "$(y '.spec.template.spec.volumes[0].hostPath.type' $podd)"
  check "showcaller hostPath type" "Directory" "$(y '.spec.template.spec.volumes[0].hostPath.type' $showd)"

  echo "== the image is a whole reference when one was given and a tag when a version was =="
  check "podcast digest-pinned" "true" "$(y '.spec.template.spec.containers[0].image' $podd | grep -q '@sha256:' && echo true || echo false)"
  check "showcaller image"      "getontime/ontime:0.0.0" "$(y '.spec.template.spec.containers[0].image' $showd)"

  echo "== the probe budgets are the catalogue's, including the one that is deliberately absent =="
  check "podcast readiness delay"      "20"   "$(y '.spec.template.spec.containers[0].readinessProbe.initialDelaySeconds' $podd)"
  check "podcast readiness failures"   "18"   "$(y '.spec.template.spec.containers[0].readinessProbe.failureThreshold' $podd)"
  # NO liveness probe on the one that migrates a schema on start: a liveness probe there restarts
  # the container mid-migration. The absence is the decision, so the absence is what is asserted.
  check "podcast has no liveness"      "null" "$(y '.spec.template.spec.containers[0].livenessProbe' $podd)"
  check "showcaller readiness period"  "5"    "$(y '.spec.template.spec.containers[0].readinessProbe.periodSeconds' $showd)"
  check "showcaller liveness period"   "15"   "$(y '.spec.template.spec.containers[0].livenessProbe.periodSeconds' $showd)"
  check "showcaller liveness failures" "6"    "$(y '.spec.template.spec.containers[0].livenessProbe.failureThreshold' $showd)"

  echo "== the resource block is a declaration's, and absent where no declaration made one =="
  check "podcast cpu request"    "250m"  "$(y '.spec.template.spec.containers[0].resources.requests.cpu' $podd)"
  check "podcast memory request" "512Mi" "$(y '.spec.template.spec.containers[0].resources.requests.memory' $podd)"
  check "podcast memory limit"   "2Gi"   "$(y '.spec.template.spec.containers[0].resources.limits.memory' $podd)"
  # Absent rather than empty. A rendered `resources: {}` is a diff against a live object that does
  # not carry the key, which on an adopted workload is a rollout for the sake of punctuation.
  check "showcaller has no resources at all" "null" "$(y '.spec.template.spec.containers[0].resources' $showd)"

  echo "== hardening comes from the catalogue, and its absence is as deliberate as its presence =="
  check "showcaller escalation denied"  "false" "$(y '.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation' $showd)"
  check "showcaller drops everything"   "ALL"   "$(y '.spec.template.spec.containers[0].securityContext.capabilities.drop[0]' $showd)"
  check "showcaller drops nothing else" "1"     "$(y '.spec.template.spec.containers[0].securityContext.capabilities.drop | length' $showd)"
  # Offered by the catalogue, taken by the declaration — the render cannot tell the two apart, so
  # the split is asserted in the eval check and only its RESULT is asserted here.
  check "showcaller read-only root"     "true"  "$(y '.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem' $showd)"
  # NOTHING on the one whose needs are unestablished. A securityContext this repository invented
  # would be a restriction nobody checked, and the honest rendering of an open question is silence.
  check "podcast has no securityContext" "null" "$(y '.spec.template.spec.containers[0].securityContext' $podd)"

  echo "== a probe budget moves the number it names and nothing else about the probe =="
  check "showcaller readiness failures (budgeted)" "36"   "$(y '.spec.template.spec.containers[0].readinessProbe.failureThreshold' $showd)"
  check "showcaller readiness path (catalogue)"    "/"    "$(y '.spec.template.spec.containers[0].readinessProbe.httpGet.path' $showd)"
  check "showcaller readiness port (catalogue)"    "4001" "$(y '.spec.template.spec.containers[0].readinessProbe.httpGet.port' $showd)"
  check "showcaller liveness failures (untouched)" "6"    "$(y '.spec.template.spec.containers[0].livenessProbe.failureThreshold' $showd)"

  echo "== a Secret is named into the container and its contents are nowhere in this tree =="
  check "podcast envFrom"      "example-podcast-env" "$(y '.spec.template.spec.containers[0].envFrom[0].secretRef.name' $podd)"
  check "showcaller envFrom"   "null"                "$(y '.spec.template.spec.containers[0].envFrom' $showd)"
  # `-L` is load-bearing throughout: the rendered tree is SYMLINKS into the store, so a plain
  # `-type f` matches nothing and returns a confident zero. A count that can only ever be zero is
  # worse than no check, because it passes the moment somebody expects zero.
  check "no Secret object rendered" "0" "$(find -L $manifests -name 'Secret-*.yaml' -type f | wc -l)"

  echo "== where it writes agrees with where it is mounted, because both came from one fact =="
  check "ONTIME_DATA" "/data/" "$(y '.spec.template.spec.containers[0].env[] | select(.name == "ONTIME_DATA") | .value' $showd)"
  check "NODE_ENV"    "docker" "$(y '.spec.template.spec.containers[0].env[] | select(.name == "NODE_ENV") | .value' $showd)"
  # The declaration's own value arrives beside the catalogue's three rather than instead of them.
  check "TZ from the declaration" "UTC" "$(y '.spec.template.spec.containers[0].env[] | select(.name == "TZ") | .value' $showd)"
  check "env count"               "4"   "$(y '.spec.template.spec.containers[0].env | length' $showd)"

  echo "== no address is invented here: the Service is a plain ClusterIP with nothing pinned =="
  for f in $pod/Service-example-podcast.yaml $show/Service-example-showcaller.yaml; do
    check "$(basename $f) type" "ClusterIP" "$(y '.spec.type' $f)"
    check "$(basename $f) no pinned IP" "null" "$(y '.spec.clusterIP' $f)"
    check "$(basename $f) no nodePort" "null" "$(y '.spec.ports[0].nodePort' $f)"
  done

  echo "== the exposure and scaling classes are recorded as labels, never as numbers =="
  check "podcast exposure label"    "public"        "$(y '.metadata.labels."nixk3s.dev/exposure"' $podd)"
  check "showcaller scaling label"  "scale-to-zero" "$(y '.metadata.labels."nixk3s.dev/scaling"' $showd)"
  check "showcaller wake label"     "keda"          "$(y '.metadata.labels."nixk3s.dev/wake"' $showd)"

  # The only promise in this file that is read off the ARGO APPLICATION rather than off the objects
  # it carries. Adoption changes how a live cluster is written to -- server-side apply and diff
  # instead of a client-side reconstruction -- so the thing worth asserting is the Application's own
  # bytes, in both directions: present where a declaration asked, and ABSENT where none did.
  echo "== adoption is rendered on the Application, and only where a declaration asked for it =="
  podapp="$manifests/apps/Application-example-podcast.yaml"
  showapp="$manifests/apps/Application-example-showcaller.yaml"
  check "podcast sync option count"  "1"                    "$(y '.spec.syncPolicy.syncOptions | length' $podapp)"
  check "podcast server-side apply"  "ServerSideApply=true" "$(y '.spec.syncPolicy.syncOptions[0]' $podapp)"
  check "podcast server-side diff"   "ServerSideDiff=true"  "$(y '.metadata.annotations."argocd.argoproj.io/compare-options"' $podapp)"
  # Nothing at all on the one that CREATES its objects. An Application that quietly picked up
  # server-side apply would change how a live object is diffed with nothing in the declaration
  # saying so, which is the same class of surprise the term exists to prevent.
  check "showcaller no sync options" "null" "$(y '.spec.syncPolicy.syncOptions' $showapp)"
  check "showcaller no compare opts" "null" "$(y '.metadata.annotations."argocd.argoproj.io/compare-options"' $showapp)"

  echo "== exactly one workload anchors the shared namespace, and only one =="
  check "namespaces rendered" "1" "$(find -L $manifests -name 'Namespace-*.yaml' -type f | wc -l)"
  check "which namespace"     "example-media" "$(y '.metadata.name' $pod/Namespace-example-media.yaml)"

  if [ "$fail" -ne 0 ]; then
    echo "rendered output does not match the plane's promises" >&2
    exit 1
  fi
  echo "nixrecord: the rendered tree matches every promise asserted here"
  touch $out
''
