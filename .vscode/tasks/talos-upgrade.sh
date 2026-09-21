#!/usr/bin/env bash
# Plan and optionally execute a one-hop Talos upgrade.
#
# Usage: talos-upgrade.sh <environment> <read-only:true|false> <interactive:true|false> [target-version]

set -euo pipefail

env_name="${1:?environment name is required}"
requested_read_only="${2:?read-only mode must be explicitly true or false}"
requested_interactive="${3:?interactive mode must be explicitly true or false}"
requested_target="${4:-}"

if [[ "$requested_read_only" != true && "$requested_read_only" != false ]]; then
  printf 'ERROR: read-only mode must be true or false\n' >&2
  exit 2
fi
if [[ "$requested_interactive" != true && "$requested_interactive" != false ]]; then
  printf 'ERROR: interactive mode must be true or false\n' >&2
  exit 2
fi
if [[ ! "$env_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
  printf 'ERROR: invalid environment name: %s\n' "$env_name" >&2
  exit 2
fi

# talosctl cordons and drains via the Kubernetes eviction API, so PodDisruptionBudgets apply.
readonly DRAIN_TIMEOUT="${TALOS_UPGRADE_DRAIN_TIMEOUT:-30m}"
readonly UPGRADE_TIMEOUT="${TALOS_UPGRADE_TIMEOUT:-60m}"
readonly NODE_SETTLE_TIMEOUT="${TALOS_UPGRADE_NODE_SETTLE_TIMEOUT:-900}"
readonly CLUSTER_SETTLE_TIMEOUT="${TALOS_UPGRADE_CLUSTER_SETTLE_TIMEOUT:-600}"
readonly STORAGE_SETTLE_TIMEOUT="${TALOS_UPGRADE_STORAGE_SETTLE_TIMEOUT:-3600}"
readonly HEALTH_WAIT_TIMEOUT="${TALOS_UPGRADE_HEALTH_WAIT_TIMEOUT:-20m}"

# talosctl aborts the whole upgrade at --timeout, so it must outlast the drain.
to_seconds() {
  local value="$1"
  case "$value" in
    *h) printf '%s\n' $(( ${value%h} * 3600 )) ;;
    *m) printf '%s\n' $(( ${value%m} * 60 )) ;;
    *s) printf '%s\n' "${value%s}" ;;
    *) printf '%s\n' "$value" ;;
  esac
}
if [[ $(to_seconds "$UPGRADE_TIMEOUT") -le $(to_seconds "$DRAIN_TIMEOUT") ]]; then
  printf 'ERROR: TALOS_UPGRADE_TIMEOUT (%s) must be greater than TALOS_UPGRADE_DRAIN_TIMEOUT (%s)\n' \
    "$UPGRADE_TIMEOUT" "$DRAIN_TIMEOUT" >&2
  exit 2
fi

: "${TALOS_BOOTSTRAPPER_DATA_DIR:?TALOS_BOOTSTRAPPER_DATA_DIR must be set}"

overlay_dir="$TALOS_BOOTSTRAPPER_DATA_DIR/environments/$env_name"
config_file="$overlay_dir/$env_name.env"
talosconfig="$overlay_dir/talos/talosconfig"

if [[ ! -f "$config_file" ]]; then
  printf 'ERROR: environment file not found: %s\n' "$config_file" >&2
  exit 2
fi
if [[ ! -f "$talosconfig" ]]; then
  printf 'ERROR: talosconfig not found: %s\n' "$talosconfig" >&2
  exit 2
fi

# shellcheck source=/dev/null
source "$config_file"
export TALOSCONFIG="$talosconfig"
read_only="$requested_read_only"
interactive="$requested_interactive"

for command_name in talosctl curl jq yq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'ERROR: required command not found: %s\n' "$command_name" >&2
    exit 2
  }
done

all_nodes=("${TALOS_CONTROL_NODES[@]}" "${TALOS_WORKER_NODES[@]}")
if [[ ${#all_nodes[@]} -eq 0 ]]; then
  printf 'ERROR: no Talos nodes are configured\n' >&2
  exit 2
fi

declare -A seen_nodes=()
for node in "${all_nodes[@]}"; do
  if [[ -n "${seen_nodes[$node]:-}" ]]; then
    printf 'ERROR: duplicate node configured in the cluster list: %s\n' "$node" >&2
    exit 2
  fi
  seen_nodes["$node"]=1
done

for node in "${TALOS_CONTROL_NODES[@]}"; do
  for worker in "${TALOS_WORKER_NODES[@]}"; do
    if [[ "$node" == "$worker" ]]; then
      printf 'ERROR: node appears in both control-plane and worker lists: %s\n' "$node" >&2
      exit 2
    fi
  done
done

log() {
  printf '[talos-upgrade] %s\n' "$*"
}

fail() {
  printf '[talos-upgrade] ERROR: %s\n' "$*" >&2
  exit 1
}

talosctl_filtered() {
  talosctl "$@" 2> >(sed -E '/^WARNING: .*: server version [^ ]+ is older than client version [^ ]+$/d' >&2)
}

# Reads one line, failing closed when stdin is not interactive instead of letting
# `set -e` abort on EOF with no explanation. The locals are prefixed because
# `printf -v` would otherwise assign to a same-named local declared here.
ask() {
  local _ask_prompt="$1" _ask_varname="$2" _ask_reply
  if ! IFS= read -r -p "$_ask_prompt" _ask_reply; then
    fail 'no input available on stdin; run this task from an interactive terminal'
  fi
  printf -v "$_ask_varname" '%s' "$_ask_reply"
}

confirm() {
  local _confirm_reply
  ask "$1 [y/N] " _confirm_reply
  [[ "$_confirm_reply" =~ ^[Yy]$ ]]
}

# Gate for any command that mutates a node. Always prompts when interactive=true.
gate() {
  local description="$1"
  [[ "$interactive" == true ]] || return 0
  confirm "APPLY: $description" || fail "operator declined: $description"
}

k8s_name() {
  printf '%s\n' "${1%%.*}"
}

require_kubectl() {
  command -v kubectl >/dev/null 2>&1 || fail 'kubectl is required for live upgrades'
  [[ -n "${KUBECONFIG:-}" && -f "$KUBECONFIG" ]] ||
    fail "KUBECONFIG is not set or missing: '${KUBECONFIG:-<unset>}'. Run 'Set Active Talos/Kube Context' first."
  kubectl get --raw /readyz >/dev/null 2>&1 || fail 'the Kubernetes API server is not reachable'
}

node_version() {
  talosctl_filtered get version --talosconfig "$TALOSCONFIG" --nodes "$1" -o json 2>/dev/null |
    jq -r '.spec.version'
}

# Returns the first control-plane node that answers, so health checks keep working
# while the node that happens to be first in the list is rebooting.
etcd_probe_node() {
  local candidate
  for candidate in "${TALOS_CONTROL_NODES[@]}"; do
    if talosctl_filtered etcd members --talosconfig "$TALOSCONFIG" --nodes "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

check_etcd_health() {
  local members_output status_output alarm_output member_count status_count probe cp_csv
  local expected="${#TALOS_CONTROL_NODES[@]}"

  probe=$(etcd_probe_node) || { log 'etcd: no control-plane node answered'; return 1; }

  members_output=$(talosctl_filtered etcd members --talosconfig "$TALOSCONFIG" --nodes "$probe" 2>&1) ||
    { log 'etcd: unable to list members'; return 1; }
  member_count=$(awk 'NR > 1 && NF > 0' <<<"$members_output" | wc -l)
  if [[ "$member_count" -ne "$expected" ]]; then
    log "etcd: expected $expected members, found $member_count"
    return 1
  fi
  if awk 'NR > 1 && $NF == "true"' <<<"$members_output" | grep -q .; then
    log 'etcd: one or more members are still learners'
    return 1
  fi

  cp_csv=$(IFS=','; printf '%s' "${TALOS_CONTROL_NODES[*]}")
  status_output=$(talosctl_filtered etcd status --talosconfig "$TALOSCONFIG" --nodes "$cp_csv" 2>&1) ||
    { log 'etcd: status query failed'; return 1; }
  status_count=$(awk 'NR > 1 && NF > 0' <<<"$status_output" | wc -l)
  if [[ "$status_count" -ne "$expected" ]]; then
    log "etcd: only $status_count of $expected members reported status"
    return 1
  fi

  alarm_output=$(talosctl_filtered etcd alarm list --talosconfig "$TALOSCONFIG" --nodes "$cp_csv" 2>&1) ||
    { log 'etcd: alarm query failed'; return 1; }
  if grep -q '[^[:space:]]' <<<"$alarm_output"; then
    log 'etcd: active alarms present:'
    printf '%s\n' "$alarm_output"
    return 1
  fi
  return 0
}

check_k8s_nodes() {
  local expected="${#all_nodes[@]}"
  local nodes_json not_ready cordoned total

  nodes_json=$(kubectl get nodes -o json 2>/dev/null) ||
    { log 'kubernetes: unable to list nodes'; return 1; }

  total=$(jq '.items | length' <<<"$nodes_json") ||
    { log 'kubernetes: unable to parse the node list'; return 1; }
  if [[ "$total" -ne "$expected" ]]; then
    log "kubernetes: expected $expected nodes, found $total"
    return 1
  fi

  not_ready=$(jq -r '.items[] | select([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length == 0) | .metadata.name' <<<"$nodes_json") ||
    { log 'kubernetes: unable to evaluate node readiness'; return 1; }
  if [[ -n "$not_ready" ]]; then
    log "kubernetes: nodes not Ready: $(tr '\n' ' ' <<<"$not_ready")"
    return 1
  fi

  cordoned=$(jq -r '.items[] | select(.spec.unschedulable == true) | .metadata.name' <<<"$nodes_json") ||
    { log 'kubernetes: unable to evaluate node schedulability'; return 1; }
  if [[ -n "$cordoned" ]]; then
    log "kubernetes: nodes still cordoned: $(tr '\n' ' ' <<<"$cordoned")"
    return 1
  fi
  return 0
}

# kubelet and the CNI need time to mark a rebooted node Ready, so poll instead of
# aborting on the first negative result.
wait_for_cluster_settled() {
  local deadline
  deadline=$(( $(date +%s) + CLUSTER_SETTLE_TIMEOUT ))
  while true; do
    if check_k8s_nodes; then
      return 0
    fi
    if [[ $(date +%s) -ge $deadline ]]; then
      log "kubernetes: cluster did not settle within ${CLUSTER_SETTLE_TIMEOUT}s"
      return 1
    fi
    sleep 15
  done
}

# Distinguishes "this CRD is genuinely absent" (1) from "the API could not be queried" (2),
# so a transient API failure is never mistaken for "this component is not installed".
crd_present() {
  local crd="$1" output
  if output=$(kubectl get crd "$crd" 2>&1 >/dev/null); then
    return 0
  fi
  if grep -qi 'not found\|could not find' <<<"$output"; then
    return 1
  fi
  log "kubernetes: unable to query CRD $crd: $output"
  return 2
}

# Rebooting a node degrades every Longhorn volume that had a replica on it. Moving to
# the next node before the rebuild finishes can take the last healthy replica offline.
wait_for_longhorn_healthy() {
  local deadline degraded crd_rc=0
  crd_present volumes.longhorn.io || crd_rc=$?
  [[ "$crd_rc" -eq 1 ]] && return 0
  [[ "$crd_rc" -eq 0 ]] || return 1
  deadline=$(( $(date +%s) + STORAGE_SETTLE_TIMEOUT ))
  while true; do
    degraded=$(kubectl -n longhorn-system get volumes.longhorn.io -o json 2>/dev/null |
      jq -r '[.items[] | select(.status.robustness != "healthy" and .status.robustness != "" and .status.robustness != null)] | length') ||
      { log 'longhorn: unable to query volume robustness'; return 1; }
    if [[ "${degraded:-1}" == 0 ]]; then
      return 0
    fi
    if [[ $(date +%s) -ge $deadline ]]; then
      log "longhorn: $degraded volume(s) still degraded after ${STORAGE_SETTLE_TIMEOUT}s"
      kubectl -n longhorn-system get volumes.longhorn.io -o json 2>/dev/null |
        jq -r '.items[] | select(.status.robustness != "healthy" and .status.robustness != "" and .status.robustness != null) | "    \(.metadata.name) \(.status.robustness)"' || true
      return 1
    fi
    log "longhorn: waiting for $degraded volume(s) to finish rebuilding..."
    sleep 15
  done
}

# CNPG switches the primary away from a cordoned node, but only if the standby is in
# sync. Draining the next node too early blocks on the primary PDB.
wait_for_cnpg_healthy() {
  local deadline unready crd_rc=0
  crd_present clusters.postgresql.cnpg.io || crd_rc=$?
  [[ "$crd_rc" -eq 1 ]] && return 0
  [[ "$crd_rc" -eq 0 ]] || return 1
  deadline=$(( $(date +%s) + STORAGE_SETTLE_TIMEOUT ))
  while true; do
    unready=$(kubectl get clusters.postgresql.cnpg.io -A -o json 2>/dev/null |
      jq -r '[.items[] | select((.status.readyInstances // 0) != .spec.instances)] | length') ||
      { log 'cnpg: unable to query cluster readiness'; return 1; }
    if [[ "${unready:-1}" == 0 ]]; then
      return 0
    fi
    if [[ $(date +%s) -ge $deadline ]]; then
      log "cnpg: $unready cluster(s) still not fully replicated after ${STORAGE_SETTLE_TIMEOUT}s"
      kubectl get clusters.postgresql.cnpg.io -A -o json 2>/dev/null |
        jq -r '.items[] | select((.status.readyInstances // 0) != .spec.instances) | "    \(.metadata.namespace)/\(.metadata.name) \(.status.readyInstances // 0)/\(.spec.instances)"' || true
      return 1
    fi
    log "cnpg: waiting for $unready cluster(s) to finish replicating..."
    sleep 15
  done
}

# The installer path encodes the image type, and that path has changed between Talos
# releases, so swapping only the tag can produce an image that does not exist.
verify_target_image() {
  local image="$1" repository tag status
  repository="${image%:*}"
  tag="${image##*:}"
  [[ "$repository" == factory.talos.dev/* ]] || return 0
  status=$(curl -sS --connect-timeout 10 --max-time 30 -o /dev/null -w '%{http_code}' \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://factory.talos.dev/v2/${repository#factory.talos.dev/}/manifests/${tag}" 2>/dev/null) || {
    log "image check: unable to reach the Image Factory for $image (skipping verification)"
    return 0
  }
  case "$status" in
    200) return 0 ;;
    404) log "image check: $image does not exist (HTTP 404)"; return 1 ;;
    *) log "image check: unexpected HTTP $status for $image (skipping verification)"; return 0 ;;
  esac
}

run_talos_health() {
  local cp_csv worker_csv
  cp_csv=$(IFS=','; printf '%s' "${TALOS_CONTROL_NODES[*]}")
  if [[ ${#TALOS_WORKER_NODES[@]} -eq 0 ]]; then
    talosctl_filtered health --talosconfig "$TALOSCONFIG" \
      --control-plane-nodes "$cp_csv" --wait-timeout "$HEALTH_WAIT_TIMEOUT"
    return
  fi
  worker_csv=$(IFS=','; printf '%s' "${TALOS_WORKER_NODES[*]}")
  talosctl_filtered health --talosconfig "$TALOSCONFIG" \
    --control-plane-nodes "$cp_csv" --worker-nodes "$worker_csv" \
    --wait-timeout "$HEALTH_WAIT_TIMEOUT"
}

# Waits for a node to report the target version and a running/ready machine status.
wait_for_node() {
  local node="$1" target="$2" deadline
  deadline=$(( $(date +%s) + NODE_SETTLE_TIMEOUT ))
  log "Waiting for $node to report $target (timeout ${NODE_SETTLE_TIMEOUT}s)..."
  while true; do
    local observed ready
    observed=$(node_version "$node" || true)
    ready=$(talosctl_filtered get machinestatus --talosconfig "$TALOSCONFIG" --nodes "$node" -o json 2>/dev/null |
      jq -r '(.spec.stage == "running" and .spec.status.ready == true)' || true)
    if [[ -n "$observed" ]] && version_eq "$observed" "$target" && [[ "$ready" == true ]]; then
      log "  $node is running $observed and reports ready"
      return 0
    fi
    if [[ $(date +%s) -ge $deadline ]]; then
      fail "$node did not reach $target within ${NODE_SETTLE_TIMEOUT}s (observed '${observed:-unreachable}', ready='${ready:-unknown}')"
    fi
    sleep 10
  done
}

# Lists "<node>\t<volume>" for every Longhorn volume whose last healthy replica sits on a node.
longhorn_last_replica_nodes() {
  local crd_rc=0
  crd_present replicas.longhorn.io || crd_rc=$?
  [[ "$crd_rc" -eq 1 ]] && return 0
  [[ "$crd_rc" -eq 0 ]] || return 1
  kubectl get replicas.longhorn.io -n longhorn-system -o json 2>/dev/null |
    jq -r '[.items[] | select(.status.currentState == "running") | {v: .spec.volumeName, n: .spec.nodeID}]
           | group_by(.v)[] | select(length == 1) | "\(.[0].n)\t\(.[0].v)"'
}

longhorn_drain_policy() {
  kubectl get settings.longhorn.io node-drain-policy -n longhorn-system -o jsonpath='{.value}' 2>/dev/null || true
}

# Lists "<namespace>/<name>" for Longhorn ArgoCD applications that still have automated
# sync, because those will revert a drain-policy patch mid-upgrade.
longhorn_argocd_autosync() {
  local crd_rc=0
  crd_present applications.argoproj.io || crd_rc=$?
  [[ "$crd_rc" -eq 0 ]] || return 1
  kubectl get applications.argoproj.io -A -o json 2>/dev/null |
    jq -r '[.items[]
            | select(.metadata.name | test("longhorn"; "i"))
            | select(.spec.syncPolicy.automated != null)
            | "\(.metadata.namespace)/\(.metadata.name)"] | join(" ")'
}

restore_longhorn_policy=""
restore_longhorn_drain_policy() {
  [[ -n "$restore_longhorn_policy" ]] || return 0
  log "Restoring Longhorn node-drain-policy to '$restore_longhorn_policy'"
  kubectl patch settings.longhorn.io node-drain-policy -n longhorn-system \
    --type merge -p "{\"value\":\"$restore_longhorn_policy\"}" >/dev/null ||
    printf '[talos-upgrade] WARNING: failed to restore Longhorn node-drain-policy to %s\n' "$restore_longhorn_policy" >&2
  log 'Remember to re-enable ArgoCD auto-sync for the Longhorn application.'
  restore_longhorn_policy=""
}

normalize_version() {
  local version="$1"
  version="${version#v}"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  printf 'v%s\n' "$version"
}

version_key() {
  printf '%s\n' "${1#v}" | awk -F. '{ printf "%06d%06d%06d\n", $1, $2, $3 }'
}

version_lt() {
  [[ "$(version_key "$1")" < "$(version_key "$2")" ]]
}

version_gt() {
  [[ "$(version_key "$1")" > "$(version_key "$2")" ]]
}

version_eq() {
  [[ "$(version_key "$1")" == "$(version_key "$2")" ]]
}

minor_key() {
  printf '%s\n' "${1#v}" | awk -F. '{ print $1 "." $2 }'
}

release_tags=()
load_release_tags() {
  local page releases_json page_count tag normalized_tag
  local -a discovered_tags=()

  for page in $(seq 1 10); do
    releases_json=$(curl -fsSL \
      -H 'Accept: application/vnd.github+json' \
      -H 'User-Agent: talos-bootstrapper-upgrade-task' \
      "https://api.github.com/repos/siderolabs/talos/releases?per_page=100&page=$page") ||
      fail "unable to query the Talos GitHub releases API (page $page)"

    while read -r tag; do
      if normalized_tag=$(normalize_version "$tag"); then
        discovered_tags+=("$normalized_tag")
      fi
    done < <(jq -r '.[] | select(.draft == false and .prerelease == false) | .tag_name' <<<"$releases_json")

    page_count=$(jq 'length' <<<"$releases_json")
    if [[ "$page" -eq 10 && "$page_count" -eq 100 ]]; then
      fail 'Talos release history exceeds the supported GitHub API pagination limit'
    fi
    [[ "$page_count" -lt 100 ]] && break
  done

  mapfile -t release_tags < <(printf '%s\n' "${discovered_tags[@]}" | sort -Vu)
  [[ ${#release_tags[@]} -gt 0 ]] || fail 'GitHub API returned no stable Talos releases'
}

is_known_release() {
  local candidate="$1"
  local tag
  for tag in "${release_tags[@]}"; do
    version_eq "$tag" "$candidate" && return 0
  done
  return 1
}

latest_patch_for_minor() {
  local minor="$1"
  local tag
  for tag in "${release_tags[@]}"; do
    [[ "$(minor_key "$tag")" == "$minor" ]] && printf '%s\n' "$tag"
  done | tail -n1
}

next_minor_after() {
  local current_minor="$1"
  local tag
  for tag in "${release_tags[@]}"; do
    if [[ "$(version_key "$tag")" > "$(version_key "${current_minor}.999")" ]]; then
      printf '%s\n' "$(minor_key "$tag")"
      return 0
    fi
  done
  return 1
}

latest_release_for_next_minor() {
  local current_minor="$1"
  local next_minor
  next_minor=$(next_minor_after "$current_minor") || return 1
  latest_patch_for_minor "$next_minor"
}

recommended_hop() {
  local current="$1"
  local upper_bound="${2:-}"
  local current_minor latest_current next_release

  current_minor=$(minor_key "$current")
  latest_current=$(latest_patch_for_minor "$current_minor") || true
  if [[ -n "$latest_current" ]] && version_gt "$latest_current" "$current"; then
    if [[ -z "$upper_bound" ]] || ! version_gt "$latest_current" "$upper_bound"; then
      printf '%s\n' "$latest_current"
      return 0
    fi
  fi

  next_release=$(latest_release_for_next_minor "$current_minor") || true
  if [[ -n "$next_release" ]]; then
    if [[ -z "$upper_bound" ]] || ! version_gt "$next_release" "$upper_bound"; then
      printf '%s\n' "$next_release"
      return 0
    fi
  fi

  if [[ -n "$upper_bound" ]] && version_gt "$upper_bound" "$current"; then
    printf '%s\n' "$upper_bound"
    return 0
  fi

  printf '%s\n' "$current"
}

declare -A node_version node_ready node_image node_platform node_arch node_role
versions=()

log "Environment: $env_name"
log "Talos config: $talosconfig"
log "Read-only: $read_only"
log "Configured nodes: ${all_nodes[*]}"

log "Cluster membership command: talosctl get members --nodes ${all_nodes[0]}"
talosctl_filtered get members --talosconfig "$TALOSCONFIG" --nodes "${all_nodes[0]}" ||
  fail 'unable to read cluster membership'

for node in "${all_nodes[@]}"; do
  log "Inspecting node: $node"

  version_json=$(talosctl_filtered get version --talosconfig "$TALOSCONFIG" --nodes "$node" -o json) ||
    fail "unable to query Talos version on $node"
  node_version["$node"]=$(jq -r '.spec.version' <<<"$version_json")
  normalize_version "${node_version[$node]}" >/dev/null || fail "invalid Talos version on $node"

  status_json=$(talosctl_filtered get machinestatus --talosconfig "$TALOSCONFIG" --nodes "$node" -o json) ||
    fail "unable to query machine status on $node"
  node_ready["$node"]=$(jq -r '(.spec.stage == "running" and .spec.status.ready == true)' <<<"$status_json")
  [[ "${node_ready[$node]}" == true ]] || fail "$node is not reporting ready/running"

  node_image["$node"]=$(talosctl_filtered get machineconfig --talosconfig "$TALOSCONFIG" --nodes "$node" -o json |
    jq -r '.spec' | yq 'select(.machine.install.image != null) | .machine.install.image' | sed -n '1p')
  [[ "${node_image[$node]}" =~ ^factory\.talos\.dev/[A-Za-z0-9._-]+/[A-Fa-f0-9]{32,}:[A-Za-z0-9._-]+$ ]] ||
    fail "unable to parse the existing Image Factory installer image for $node"

  node_platform["$node"]=$(talosctl_filtered get platformmetadata --talosconfig "$TALOSCONFIG" --nodes "$node" -o json |
    jq -r '.spec.platform')
  version_output=$(talosctl_filtered version --talosconfig "$TALOSCONFIG" --nodes "$node")
  node_arch["$node"]=$(awk '/Server:/{server=1; next} server && /OS\/Arch:/{split($2, parts, "/"); print parts[2]}' <<<"$version_output")
  [[ -n "${node_platform[$node]}" && -n "${node_arch[$node]}" ]] ||
    fail "unable to determine platform and architecture for $node"

  if [[ " ${TALOS_CONTROL_NODES[*]} " == *" $node "* ]]; then
    node_role["$node"]='controlplane'
  else
    node_role["$node"]='worker'
  fi

  versions+=("${node_version[$node]}")
  printf '  %-36s role=%-11s version=%-8s ready=%-5s platform=%-8s arch=%-6s image=%s\n' \
    "$node" "${node_role[$node]}" "${node_version[$node]}" "${node_ready[$node]}" \
    "${node_platform[$node]}" "${node_arch[$node]}" "${node_image[$node]}"
done

mapfile -t unique_versions < <(printf '%s\n' "${versions[@]}" | sort -Vu)
if [[ ${#unique_versions[@]} -gt 2 ]]; then
  fail "more than two Talos versions detected: ${unique_versions[*]}"
fi

load_release_tags
oldest_version="${unique_versions[0]}"
newest_version="${unique_versions[${#unique_versions[@]}-1]}"
if [[ ${#unique_versions[@]} -eq 2 ]]; then
  suggested_target=$(recommended_hop "$oldest_version" "$newest_version")
else
  suggested_target=$(recommended_hop "$oldest_version")
fi

if [[ -n "$suggested_target" ]] && ! is_known_release "$suggested_target"; then
  fail "the suggested target is not a known stable Talos release: $suggested_target"
fi

log "Observed versions: ${unique_versions[*]}"
log "Suggested next version: $suggested_target"

if [[ -z "$requested_target" ]]; then
  ask 'Target Talos version (Enter accepts the suggestion): ' requested_target
fi
if [[ -z "$requested_target" ]]; then
  requested_target="$suggested_target"
fi
selected_target=$(normalize_version "$requested_target") || fail "invalid target version: $requested_target"
is_known_release "$selected_target" || fail "target is not a stable Talos release: $selected_target"

override_needed=false
for node in "${all_nodes[@]}"; do
  if version_gt "$selected_target" "${node_version[$node]}"; then
    node_hop=$(recommended_hop "${node_version[$node]}" "$selected_target")
    if ! version_eq "$node_hop" "$selected_target"; then
      override_needed=true
      break
    fi
  elif version_lt "$selected_target" "${node_version[$node]}"; then
    fail "target $selected_target would downgrade $node from ${node_version[$node]}"
  fi
done

log "Selected target version: $selected_target"
log "Suggested-path override required: $override_needed"
if [[ "$override_needed" == true ]]; then
  confirm 'The selected target breaks the recommended path. Override?' ||
    fail 'operator declined the unsupported path override'
fi

release_url="https://github.com/siderolabs/talos/releases/tag/${selected_target}"
minor_release="${selected_target%.*}.0"
minor_release_url="https://github.com/siderolabs/talos/releases/tag/${minor_release}"
printf '\nSelected release: %s\n' "$release_url"
if [[ "$minor_release" != "$selected_target" ]] && is_known_release "$minor_release"; then
  printf 'Minor-series release and breaking changes: %s\n' "$minor_release_url"
else
  printf 'Minor-series release and breaking changes: same release as selected (%s)\n' "$release_url"
fi
printf 'Review breaking changes before proceeding.\n'
confirm 'Have you reviewed both the minor .0 release and the intended final release?' ||
  fail 'release review was not confirmed'

controlplane_upgrade_nodes=()
worker_upgrade_nodes=()
for node in "${TALOS_CONTROL_NODES[@]}"; do
  version_eq "${node_version[$node]}" "$selected_target" || controlplane_upgrade_nodes+=("$node")
done
for node in "${TALOS_WORKER_NODES[@]}"; do
  version_eq "${node_version[$node]}" "$selected_target" || worker_upgrade_nodes+=("$node")
done
upgrade_order=(
  ${controlplane_upgrade_nodes[@]+"${controlplane_upgrade_nodes[@]}"}
  ${worker_upgrade_nodes[@]+"${worker_upgrade_nodes[@]}"}
)

target_image_for() {
  printf '%s\n' "${node_image[$1]%:*}:$selected_target"
}

upgrade_command() {
  printf 'talosctl upgrade --nodes %q --image %q --talosconfig %q --wait --drain --drain-timeout %q --timeout %q' \
    "$1" "$(target_image_for "$1")" "$TALOSCONFIG" "$DRAIN_TIMEOUT" "$UPGRADE_TIMEOUT"
}

printf '\nProposed upgrades (control-plane first, then workers, strictly one node at a time):\n'
for node in "${all_nodes[@]}"; do
  if version_eq "${node_version[$node]}" "$selected_target"; then
    printf '  %-36s %-12s already at %s; skip\n' "$node" "${node_role[$node]}" "$selected_target"
  else
    printf '  %-36s %-12s %s -> %s (%s)\n' \
      "$node" "${node_role[$node]}" "${node_version[$node]}" "$selected_target" "$(target_image_for "$node")"
  fi
done

if [[ ${#upgrade_order[@]} -eq 0 ]]; then
  log 'No nodes require an upgrade.'
  exit 0
fi

if [[ "$read_only" == true ]]; then
  printf '\nIntended commands (not executed), in order:\n'
  for node in "${upgrade_order[@]}"; do
    printf '  [%-12s] %s\n' "${node_role[$node]}" "$(upgrade_command "$node")"
  done
  printf '\nValidation the live run performs:\n'
  printf '  before each node   etcd quorum, Kubernetes nodes Ready, Longhorn volumes healthy, CNPG fully replicated\n'
  printf '  after each node    node reports %s and running+ready, etcd quorum, Kubernetes nodes Ready\n' "$selected_target"
  printf '  once at the end    all of the above plus talosctl health across control-plane and worker nodes\n'
  printf '  before it starts   every target installer image is confirmed to exist in the Image Factory\n'
  printf '\nRead-only mode: nothing was changed.\n'
  exit 0
fi

# ── Live execution ───────────────────────────────────────────────────────────
require_kubectl

log 'Pre-flight: verifying every target installer image exists'
image_check_failed=false
for node in "${upgrade_order[@]}"; do
  verify_target_image "$(target_image_for "$node")" || image_check_failed=true
done
if [[ "$image_check_failed" == true ]]; then
  fail 'at least one target installer image does not exist; check TALOS_INSTALLER_TYPE and the schematic for this Talos version'
fi

[[ -n "${TALOS_CLUSTER_NAME:-}" ]] || fail 'TALOS_CLUSTER_NAME is unset or empty in the environment file'

printf '\nLIVE UPGRADE: every node below is cordoned, drained and rebooted, one at a time.\n'
ask "Type the cluster name ($TALOS_CLUSTER_NAME) to continue: " typed_cluster_name
[[ -n "$typed_cluster_name" && "$typed_cluster_name" == "$TALOS_CLUSTER_NAME" ]] ||
  fail 'cluster name confirmation did not match'

trap restore_longhorn_drain_policy EXIT
trap 'fail "interrupted by signal"' INT TERM

log 'Pre-flight: etcd health'
check_etcd_health || fail 'etcd is not healthy; refusing to start the upgrade'
log 'Pre-flight: Kubernetes node readiness'
check_k8s_nodes || fail 'the Kubernetes cluster is not healthy; refusing to start the upgrade'

# Longhorn blocks eviction of the instance-manager pod on any node holding the last healthy
# replica of a volume, which stalls the drain until the drain timeout. Longhorn recommends
# block-for-eviction-if-contains-last-replica during planned maintenance so those replicas are
# relocated automatically instead of having to be evicted by hand.
current_drain_policy=$(longhorn_drain_policy)
if [[ -n "$current_drain_policy" ]]; then
  log "Pre-flight: Longhorn node-drain-policy is '$current_drain_policy'"
  declare -A upgrade_short_names=()
  for node in "${upgrade_order[@]}"; do
    upgrade_short_names["$(k8s_name "$node")"]=1
  done
  blocking_rows=()
  last_replica_output=$(longhorn_last_replica_nodes) ||
    fail 'unable to query Longhorn replica placement; refusing to start the upgrade'
  while IFS=$'\t' read -r replica_node volume_name; do
    [[ -n "$replica_node" ]] || continue
    [[ -n "${upgrade_short_names[$replica_node]:-}" ]] && blocking_rows+=("$replica_node -> $volume_name")
  done <<<"$last_replica_output"

  if [[ ${#blocking_rows[@]} -gt 0 ]]; then
    printf '\nLonghorn volumes whose only running replica sits on a node due for upgrade:\n'
    printf '  %s\n' "${blocking_rows[@]}"
    printf "With policy '%s' the drain of those nodes will block until the replicas are relocated.\\n" \
      "$current_drain_policy"
    if [[ "$current_drain_policy" == block-for-eviction* ]]; then
      log 'Policy already evicts replicas automatically; drains will be slow but will complete.'
    else
      policy_switched=false
      if confirm 'Temporarily switch node-drain-policy to block-for-eviction-if-contains-last-replica (restored on exit)?'; then
        autosync_apps=$(longhorn_argocd_autosync) || autosync_apps=''
        if [[ -n "$autosync_apps" ]]; then
          printf '\nArgoCD auto-sync is STILL ENABLED on: %s\n' "$autosync_apps"
          printf 'It will revert this patch mid-upgrade and the drain will then block. Pause it first:\n'
          read -ra autosync_app_list <<<"$autosync_apps"
          for app in "${autosync_app_list[@]}"; do
            printf "  kubectl -n %s patch application %s --type merge -p '{\"spec\":{\"syncPolicy\":{\"automated\":null}}}'\n" \
              "${app%%/*}" "${app##*/}"
          done
        else
          printf '\nNo Longhorn ArgoCD application currently reports automated sync.\n'
        fi
        if confirm 'Has ArgoCD auto-sync been paused for Longhorn?'; then
          kubectl patch settings.longhorn.io node-drain-policy -n longhorn-system \
            --type merge -p '{"value":"block-for-eviction-if-contains-last-replica"}' >/dev/null ||
            fail 'failed to update the Longhorn node-drain-policy'
          restore_longhorn_policy="$current_drain_policy"
          policy_switched=true
          log 'Longhorn will now relocate last replicas automatically; expect considerably longer drains.'
        else
          log 'Leaving the policy unchanged: ArgoCD would revert it mid-upgrade anyway.'
        fi
      fi
      if [[ "$policy_switched" == false ]]; then
        confirm 'Continue anyway (a drain may block until the drain timeout and abort the upgrade)?' ||
          fail 'operator aborted at the Longhorn pre-flight'
      fi
    fi
  fi
fi

upgraded_nodes=()
for node in "${upgrade_order[@]}"; do
  printf '\n────────────────────────────────────────────────────────────\n'
  printf '  %s (%s): %s -> %s\n' "$node" "${node_role[$node]}" "${node_version[$node]}" "$selected_target"
  printf '────────────────────────────────────────────────────────────\n'

  log 'Checking etcd quorum before touching this node'
  check_etcd_health || fail "etcd became unhealthy before upgrading $node; aborting"
  log 'Checking Kubernetes node readiness'
  wait_for_cluster_settled || fail "the Kubernetes cluster became unhealthy before upgrading $node; aborting"
  log 'Checking Longhorn volume robustness'
  wait_for_longhorn_healthy || fail "Longhorn volumes are still degraded before upgrading $node; aborting"
  log 'Checking CloudNativePG replication'
  wait_for_cnpg_healthy || fail "CloudNativePG clusters are not fully replicated before upgrading $node; aborting"

  # Replica placement shifts as earlier nodes are drained, so re-evaluate per node.
  node_short="$(k8s_name "$node")"
  node_blockers=()
  node_replica_output=$(longhorn_last_replica_nodes) ||
    fail "unable to query Longhorn replica placement before upgrading $node"
  while IFS=$'\t' read -r replica_node volume_name; do
    [[ -n "$replica_node" ]] || continue
    [[ "$replica_node" == "$node_short" ]] && node_blockers+=("$volume_name")
  done <<<"$node_replica_output"
  if [[ ${#node_blockers[@]} -gt 0 && "$(longhorn_drain_policy)" != block-for-eviction* ]]; then
    log "$node currently holds the only running replica of: ${node_blockers[*]}"
    confirm 'Its drain will block until those replicas are relocated. Continue?' ||
      fail "operator aborted before upgrading $node"
  fi

  gate "upgrade $node to $selected_target"

  set +e
  talosctl_filtered upgrade \
    --talosconfig "$TALOSCONFIG" \
    --nodes "$node" \
    --image "$(target_image_for "$node")" \
    --wait --drain \
    --drain-timeout "$DRAIN_TIMEOUT" \
    --timeout "$UPGRADE_TIMEOUT"
  upgrade_rc=$?
  set -e

  if [[ $upgrade_rc -ne 0 ]]; then
    printf '\n'
    observed_after_failure=$(node_version "$node" || true)
    log "Upgrade of $node failed (exit $upgrade_rc). The node is probably still cordoned."
    log "  Inspect:  kubectl describe node $(k8s_name "$node")"
    log "  Uncordon: kubectl uncordon $(k8s_name "$node")"
    if [[ -n "$observed_after_failure" ]] && version_eq "$observed_after_failure" "$selected_target"; then
      log "  $node already runs $observed_after_failure, so the install succeeded and a later step failed."
      log "  Roll back only if the new version misbehaves: talosctl rollback --nodes $node --talosconfig $TALOSCONFIG"
    else
      log "  $node still runs ${observed_after_failure:-an unknown version}, so the install did not happen (most likely a blocked drain)."
      log '  Do NOT roll back. Resolve the drain blocker (PodDisruptionBudgets, Longhorn replicas) and rerun.'
    fi
    fail "aborting after a failed upgrade of $node"
  fi

  wait_for_node "$node" "$selected_target"
  node_version["$node"]="$selected_target"

  log 'Post-node validation: etcd'
  check_etcd_health || fail "etcd is unhealthy after upgrading $node"
  log 'Post-node validation: Kubernetes nodes'
  wait_for_cluster_settled || fail "the Kubernetes cluster is unhealthy after upgrading $node"

  upgraded_nodes+=("$node")
  log "$node upgraded and validated."
done

restore_longhorn_drain_policy

printf '\n────────────────────────────────────────────────────────────\n'
printf '  Final cluster validation\n'
printf '────────────────────────────────────────────────────────────\n'

validation_failed=false
for node in "${all_nodes[@]}"; do
  observed=$(node_version "$node" || true)
  if [[ -n "$observed" ]] && version_eq "$observed" "$selected_target"; then
    printf '  %-36s %s\n' "$node" "$observed"
  else
    printf '  %-36s %s (expected %s)\n' "$node" "${observed:-unreachable}" "$selected_target"
    validation_failed=true
  fi
done

check_etcd_health || validation_failed=true
wait_for_cluster_settled || validation_failed=true
wait_for_longhorn_healthy || validation_failed=true
wait_for_cnpg_healthy || validation_failed=true
run_talos_health || validation_failed=true

if [[ "$validation_failed" == true ]]; then
  fail "upgraded ${#upgraded_nodes[@]} node(s) but post-upgrade validation failed"
fi

log "Upgrade to $selected_target complete and validated on ${#upgraded_nodes[@]} node(s)."
