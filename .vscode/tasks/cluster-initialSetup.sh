#!/bin/bash
#
# cluster-initialSetup.sh
#
# Generate Talos machine configs from the overlay's rendered templates, apply
# them to nodes (in maintenance mode), bootstrap etcd, fetch kubeconfig,
# approve node CSRs, and then hand off to cluster-bootstrap.sh to install
# Cilium/ArgoCD and drive the Gitea+GitOps bootstrap.
#
# Usage:
#   cluster-initialSetup.sh [--diff] [--talos-apply-mode=auto|staged|no-reboot] <env-name>
#
# Env:
#   TALOS_BOOTSTRAPPER_DATA_DIR  (required — set by devcontainer.json)
#   TALOS_BOOTSTRAPER_DIR        (optional — defaults to
#                                 $TALOS_BOOTSTRAPPER_DATA_DIR/talos-bootstraper)
#
# Required tools: talosctl, helm@3, yq, kubectl, curl, jq, cilium-cli

set -euo pipefail

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

DIFF_MODE=false
TALOS_APPLY_MODE=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --diff)
      DIFF_MODE=true
      shift
      ;;
    --talos-apply-mode=*)
      TALOS_APPLY_MODE="${1#--talos-apply-mode=}"
      shift
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [[ ${#POSITIONAL[@]} -ne 1 ]]; then
  echo "Usage: $0 [--diff] [--talos-apply-mode=auto|staged|no-reboot] <env-name>" >&2
  exit 1
fi

env_name="${POSITIONAL[0]}"

: "${TALOS_BOOTSTRAPPER_DATA_DIR:?TALOS_BOOTSTRAPPER_DATA_DIR must be set (see .devcontainer/devcontainer.json)}"
export TALOS_BOOTSTRAPER_DIR="${TALOS_BOOTSTRAPER_DIR:-$TALOS_BOOTSTRAPPER_DATA_DIR/talos-bootstraper}"

CONFIG_FILE="$TALOS_BOOTSTRAPPER_DATA_DIR/environments/$env_name/$env_name.env"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config file $CONFIG_FILE not found!" >&2
  exit 2
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# ============================================================================
# ENVIRONMENT SETUP AND VALIDATION
# ============================================================================

export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LIB_DIR="$SCRIPT_DIR/lib"

# Load libraries (now co-located with the scripts in devenv/.vscode/tasks/lib/).
# shellcheck source=./lib/logging.sh
source "$LIB_DIR/logging.sh" || { echo "Error: Failed to load logging.sh"; exit 1; }
# shellcheck source=./lib/disk-detection.sh
source "$LIB_DIR/disk-detection.sh" || { log_error "Failed to load disk-detection.sh"; exit 1; }
# shellcheck source=./lib/kubernetes.sh
source "$LIB_DIR/kubernetes.sh" || { log_error "Failed to load kubernetes.sh"; exit 1; }
# shellcheck source=./lib/image-factory.sh
source "$LIB_DIR/image-factory.sh" || { log_error "Failed to load image-factory.sh"; exit 1; }
# shellcheck source=./lib/talos.sh
source "$LIB_DIR/talos.sh" || { log_error "Failed to load talos.sh"; exit 1; }

export OVERLAY_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"
export NR_OF_CONTROL_NODES=${#TALOS_CONTROL_NODES[@]}
export TALOSCONFIG="$OVERLAY_DIR/talos/talosconfig"

# base/ lives in the talos-bootstraper repo (public shared templates).
# Rendered output lives inside the overlay directory as _rendered/.
export BASE_DIR="$TALOS_BOOTSTRAPER_DIR/base"
export RENDERED_DIR="$OVERLAY_DIR/_rendered"


log_info "Using Environment:       $env_name"
log_info "Using Script Directory:  $SCRIPT_DIR"
log_info "Using Base Directory:    $BASE_DIR"
log_info "Using Overlay Directory: $OVERLAY_DIR"
log_info "Using Rendered Directory: $RENDERED_DIR"
log_info "Using Talos config file: $TALOSCONFIG"

cd "$OVERLAY_DIR" || exit 1

if [ -z "${TALOS_INSTALL_VERSION:-}" ] || [ -z "${TALOS_INSTALLER_TYPE:-}" ] || [ -z "$POD_CIDR" ] || [ -z "$SERVICE_CIDR" ]; then
  log_error "TALOS_INSTALL_VERSION, TALOS_INSTALLER_TYPE, POD_CIDR, and SERVICE_CIDR must be set in the config file."
  exit 3
fi

# base/talos patches use Talos 1.14 documents; older contracts or talosctl reject them.
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }
TALOSCTL_CLIENT_VERSION=$(talosctl version --client --short 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if ! version_ge "${TALOS_VERSION:-v0}" "v1.14.0"; then
  log_error "TALOS_VERSION (config contract) must be >= v1.14.0, got '${TALOS_VERSION:-}'."
  exit 3
fi
if ! version_ge "${TALOSCTL_CLIENT_VERSION:-v0}" "${TALOS_VERSION%.*}.0"; then
  log_error "talosctl ${TALOSCTL_CLIENT_VERSION:-<missing>} is older than TALOS_VERSION ${TALOS_VERSION}; upgrade talosctl."
  exit 3
fi

# ============================================================================
# DERIVE INSTALL IMAGE FROM IMAGE FACTORY SCHEMATIC
# ============================================================================

log_info "Creating Image Factory schematic to derive install image..."
SCHEMATIC_ID=$(create_schematic)

if [[ -z "$SCHEMATIC_ID" ]]; then
  log_error "Failed to create Image Factory schematic."
  exit 3
fi

export TALOS_INSTALL_IMAGE="factory.talos.dev/${TALOS_INSTALLER_TYPE}/${SCHEMATIC_ID}:${TALOS_INSTALL_VERSION}"
log_success "Install image: $TALOS_INSTALL_IMAGE"

# ============================================================================
# NODE RESET (IF ENABLED)
# ============================================================================

# Reset nodes if TALOS_RESET_NODES is true
if [[ "${TALOS_RESET_NODES:-false}" == "true" ]]; then
  RESET_NODES=("${TALOS_CONTROL_NODES[@]}" ${TALOS_WORKER_NODES[@]+"${TALOS_WORKER_NODES[@]}"})
  log_info "TALOS_RESET_NODES is true. Checking ${#RESET_NODES[@]} node(s) for reset..."

  for NODE in "${RESET_NODES[@]}"; do
    reset_talos_node "$NODE" "$TALOSCONFIG"
  done

  # Give nodes time to start resetting before probing them
  log_info "Waiting 10s for nodes to begin resetting..."
  sleep 10
fi

# ============================================================================
# PXE BOOT: ENSURE NODES ARE EITHER IN MAINTENANCE MODE OR ALREADY BOOTSTRAPPED BEFORE PROCEEDING
# ============================================================================

if [[ "${TALOS_PXE_ENABLED:-false}" == "true" ]]; then
  log_info "PXE boot is enabled. Checking node status before starting PXE server..."

  ALL_NODES=("${TALOS_CONTROL_NODES[@]}" ${TALOS_WORKER_NODES[@]+"${TALOS_WORKER_NODES[@]}"})
  NODES_READY=()
  NODES_NEED_PXE=()

  # Pre-check: probe all nodes in parallel to see if they're already reachable
  # This allows re-running the script without blocking on PXE boot for already-deployed nodes
  PROBE_TMPDIR=$(mktemp -d)
  for NODE in "${ALL_NODES[@]}"; do
    (
      set +e
      # Try with talosconfig first (works for bootstrapped nodes), fall back to --insecure (maintenance mode)
      STATUS=$(talosctl get machinestatus --nodes "$NODE" --endpoints "$NODE" 2>&1 &
               PID=$!; sleep 2 && kill "$PID" 2>/dev/null & wait "$PID")
      if [[ $? -ne 0 ]]; then
        STATUS=$(talosctl get machinestatus --nodes "$NODE" --endpoints "$NODE" --insecure 2>&1 &
                 PID=$!; sleep 2 && kill "$PID" 2>/dev/null & wait "$PID")
      fi
      if echo "$STATUS" | grep -qi "maintenance\|booting\|running"; then
        echo "ready"
      else
        echo "pxe"
      fi
    ) > "$PROBE_TMPDIR/${NODE}" &
  done
  wait

  for NODE in "${ALL_NODES[@]}"; do
    RESULT=$(cat "$PROBE_TMPDIR/${NODE}" 2>/dev/null || echo "pxe")
    if [[ "$RESULT" == "ready" ]]; then
      log_success "Node $NODE is already reachable (skipping PXE boot)."
      NODES_READY+=("$NODE")
    else
      NODES_NEED_PXE+=("$NODE")
    fi
  done
  rm -rf "$PROBE_TMPDIR"

  if [[ ${#NODES_NEED_PXE[@]} -eq 0 ]]; then
    log_success "All ${#ALL_NODES[@]} nodes are already reachable. Skipping PXE boot."
  else
    log_info "${#NODES_NEED_PXE[@]} node(s) need PXE boot: ${NODES_NEED_PXE[*]}"
    log_info "Starting PXE server..."
    "$SCRIPT_DIR/pxe-setup.sh" "$env_name"

    PXE_TIMEOUT=${PXE_BOOT_TIMEOUT:-600}
    START_TIME=$(date +%s)

    log_info "Waiting for ${#NODES_NEED_PXE[@]} node(s) to PXE boot into maintenance mode (timeout: ${PXE_TIMEOUT}s)..."

    while [[ ${#NODES_READY[@]} -lt ${#ALL_NODES[@]} ]]; do
      for NODE in "${NODES_NEED_PXE[@]}"; do
        # Skip if already confirmed ready
        if printf '%s\n' ${NODES_READY[@]+"${NODES_READY[@]}"} | grep -qxF "$NODE"; then
          continue
        fi

        # Check if node is in maintenance mode by probing with talosctl
        set +e
        STATUS=$(talosctl get machinestatus --nodes "$NODE" --endpoints "$NODE" --insecure 2>&1)
        set -e

        if echo "$STATUS" | grep -qi "maintenance\|booting"; then
          log_success "Node $NODE is in maintenance mode."
          NODES_READY+=("$NODE")
        fi

        # Recheck if node has already booted (reachable with talosconfig) - if so, add to ready list to avoid blocking on PXE boot
        # Skip if the previous check timed out — the node is unreachable, no point trying the authenticated endpoint
        if ! echo "$STATUS" | grep -qi "context deadline exceeded"; then
          set +e
          STATUS=$(talosctl get machinestatus --nodes "$NODE" --endpoints "$NODE" --talosconfig "$TALOSCONFIG" -o jsonpath='{.spec.status.ready}' 2>&1)
          set -e
        fi

        if [[ "$STATUS" == "true" ]]; then
          log_success "Node $NODE is already ready"
          NODES_READY+=("$NODE")
        fi

      done

      if [[ ${#NODES_READY[@]} -lt ${#ALL_NODES[@]} ]]; then
        CURRENT_TIME=$(date +%s)
        ELAPSED=$((CURRENT_TIME - START_TIME))
        if [[ $ELAPSED -ge $PXE_TIMEOUT ]]; then
          log_error "Timeout waiting for nodes to PXE boot after ${PXE_TIMEOUT}s."
          log_error "Nodes not yet ready: $(comm -23 <(printf '%s\n' "${NODES_NEED_PXE[@]}" | sort) <(printf '%s\n' ${NODES_READY[@]+"${NODES_READY[@]}"} | sort) | tr '\n' ' ')"
          exit 4
        fi
        REMAINING=$((${#ALL_NODES[@]} - ${#NODES_READY[@]}))
        PENDING_NODES=$(comm -23 <(printf '%s\n' "${NODES_NEED_PXE[@]}" | sort) <(printf '%s\n' ${NODES_READY[@]+"${NODES_READY[@]}"} | sort) | tr '\n' ' ')
        log_info "Waiting for $REMAINING more node(s): ${PENDING_NODES}(${ELAPSED}s elapsed)"
        sleep 5
      fi
    done

    log_success "All ${#ALL_NODES[@]} nodes are in maintenance mode."

    # Stop and remove PXE server containers — no longer needed
    log_info "Stopping PXE server containers..."
    PXE_DIR="$(cd "$SCRIPT_DIR/../../pxe" && pwd)"
    PXE_COMPOSE_ARGS=(-f "$PXE_DIR/docker-compose.yml")
    if [[ "${TALOS_PXE_PROXY_DHCP_ENABLED:-false}" == "true" ]]; then
      PXE_COMPOSE_ARGS+=(--profile proxydhcp)
    else
      PXE_COMPOSE_ARGS+=(--profile tftp)
    fi
    if detect_container_runtime; then
      "$CONTAINER_RUNTIME" compose "${PXE_COMPOSE_ARGS[@]}" down 2>/dev/null || true
    else
      log_warn "No container runtime found for PXE cleanup. Skipping container shutdown."
    fi
    log_success "PXE server containers stopped and removed."
  fi
fi

# ============================================================================
# DIRECTORY AND SECRETS SETUP
# ============================================================================

mkdir -p talos
mkdir -p "$RENDERED_DIR/talos"

if [ "$TALOS_OVERWRITE_CONF" = "true" ]; then
  rm -f "$OVERLAY_DIR/talos/controlplane.yaml"
  rm -f "$OVERLAY_DIR/talos/worker.yaml"
  rm -f "$RENDERED_DIR/talos/"controlplane-*.yaml
  rm -f "$RENDERED_DIR/talos/"worker-*.yaml

  log_warn "TALOS_OVERWRITE_CONF is true: will delete existing machineconfigs and talosconfig, if they exist."
fi

if [ "$TALOS_OVERWRITE_SECRETS" = "true" ]; then
  rm -f "$OVERLAY_DIR/talos/talos-secrets.yaml"
  rm -f "$OVERLAY_DIR/talos/talosconfig"
  log_warn "TALOS_OVERWRITE_SECRETS is true: will delete existing secrets, if they do exist."
fi

#set -x

if [ ! -f "$OVERLAY_DIR/talos/talos-secrets.yaml" ]; then
  log_info "Generating talos secrets"
  talosctl gen secrets -o "$OVERLAY_DIR/talos/talos-secrets.yaml"
else
  log_info "Talos secrets file already exists, skipping generation."
fi

# ============================================================================
# TALOS CONFIGURATION GENERATION
# ============================================================================

  log_info "Creating patch for Talos config..."

  "$SCRIPT_DIR/render-overlay.sh" "$CONFIG_FILE"

  TALOS_PATCH_DIR=$(mktemp -d)
  trap 'rm -rf "$TALOS_PATCH_DIR"' EXIT

  CONFIG_PATCH_ARGS=(--config-patch "@$RENDERED_DIR/talos/talosPatchConfig.yaml")
  CONFIG_PATCH_CONTROLPLANE_ARGS=(--config-patch-control-plane "@$RENDERED_DIR/talos/talosPatchConfigControlplane.yaml")

  # Skip small disks (e.g. USB installer sticks) when picking the install disk
  if [ -n "${TALOS_MIN_INSTALL_DISK_SIZE_GB:-}" ]; then
    log_info "TALOS_MIN_INSTALL_DISK_SIZE_GB is set: install disk selector disk.size >= ${TALOS_MIN_INSTALL_DISK_SIZE_GB}GB"
    cat > "$TALOS_PATCH_DIR/install-disk.yaml" <<EOF
apiVersion: v1alpha1
kind: UnattendedInstallConfig
provisioning:
  diskSelector:
    match: disk.size >= ${TALOS_MIN_INSTALL_DISK_SIZE_GB}u * GB
EOF
    CONFIG_PATCH_ARGS+=(--config-patch "@$TALOS_PATCH_DIR/install-disk.yaml")
  fi

  if [[ "${TALOS_ALLOW_SCHEDULING_ON_CONTROLPLANES:-false}" == "true" ]]; then
    log_info "TALOS_ALLOW_SCHEDULING_ON_CONTROLPLANES is true: removing the control-plane NoSchedule taint"
    cat > "$TALOS_PATCH_DIR/controlplane-schedulable.yaml" <<'EOF'
apiVersion: v1alpha1
kind: KubeNodeConfig
taints:
  node-role.kubernetes.io/control-plane:
    $patch: delete
EOF
    CONFIG_PATCH_CONTROLPLANE_ARGS+=(--config-patch-control-plane "@$TALOS_PATCH_DIR/controlplane-schedulable.yaml")
  fi

  for CERT_FILE in ${TALOS_ADDITIONAL_TRUSTEDROOT_FILES[@]+"${TALOS_ADDITIONAL_TRUSTEDROOT_FILES[@]}"}; do
    if [ -f "$OVERLAY_DIR/$CERT_FILE" ]; then
      CA_NAME="$(basename "$CERT_FILE" | sed 's/\.[^.]*$//')_ca"
      log_info "Adding trusted root CA $CERT_FILE (TrustedRootsConfig $CA_NAME) to all nodes"
      CA_CERT_BODY=$(sed 's/^/    /' "$OVERLAY_DIR/$CERT_FILE") CA_NAME="$CA_NAME" \
        envsubst < "${BASE_DIR}/talos/trustedRootsConfigTemplate.yaml" > "$TALOS_PATCH_DIR/trusted-root-${CA_NAME}.yaml"
      CONFIG_PATCH_ARGS+=(--config-patch "@$TALOS_PATCH_DIR/trusted-root-${CA_NAME}.yaml")
    else
      log_warn "Trusted root CA cert file $CERT_FILE not found, skipping."
    fi
  done

  # Registry TLS trust + node pull credentials for the in-cluster Gitea registry.
  # Only possible once the cluster runs; on first bootstrap they are patched in at the end.
  REGISTRY_PATCH="$TALOS_PATCH_DIR/registry.yaml"
  REGISTRY_CONFIG_IN_NODE_CONFIGS=false
  if talosctl kubeconfig --nodes "${TALOS_CONTROL_NODES[0]}" --force "$TALOS_PATCH_DIR/kubeconfig" &>/dev/null \
     && build_registry_config_patch "$REGISTRY_PATCH" "$TALOS_PATCH_DIR/kubeconfig"; then
    log_info "Including Gitea registry TLS/auth documents in node configs"
    CONFIG_PATCH_ARGS+=(--config-patch "@$REGISTRY_PATCH")
    REGISTRY_CONFIG_IN_NODE_CONFIGS=true
  else
    log_info "Cluster CA not reachable yet — registry config will be patched in after bootstrap"
  fi


log_info "Generating Talos config..."

# In --diff mode, do NOT regenerate talosconfig: it's the auth material used
# by talosctl to reach the running cluster, and regenerating it from a
# possibly-drifted local talos-secrets.yaml can break authentication. The
# machine configs (controlplane.yaml, worker.yaml) still need to be produced
# so the diff can be computed.
OUTPUT_TYPES_ARGS=()
if [[ "$DIFF_MODE" == "true" ]]; then
  OUTPUT_TYPES_ARGS=(--output-types controlplane,worker)
  log_info "[DIFF] Skipping talosconfig regeneration (--output-types controlplane,worker)"
fi

#set -x
talosctl gen config --with-secrets "$OVERLAY_DIR/talos/talos-secrets.yaml" \
  --install-image "$TALOS_INSTALL_IMAGE" \
  --output "$OVERLAY_DIR/talos/" \
  "$TALOS_CLUSTER_NAME" "https://${TALOS_CLUSTER_ENDPOINT}:6443" \
  "${CONFIG_PATCH_ARGS[@]}" \
  "${CONFIG_PATCH_CONTROLPLANE_ARGS[@]}" \
  "${OUTPUT_TYPES_ARGS[@]}" \
  --force \
  --kubernetes-version ${KUBERNETES_VERSION} \
  --talos-version ${TALOS_VERSION}


  # DISABLED DISABLED DISABLED, replaced by KMS only for now
  # read -rsp "Enter Talos system disk LUKS passphrase (will not be echoed): " LUKS_PASSPHRASE
  # echo
  # echo "Please make sure you have saved the Talos system disk LUKS passphrase somewhere safe. Press Enter to continue."
  # read

  # export TALOS_SYSTEMDISK_LUKS_PASSPHRASE="$LUKS_PASSPHRASE"

# ============================================================================
# TALOSCONFIG UPDATE
# ============================================================================

  if [[ "$DIFF_MODE" == "true" ]]; then
    log_info "[DIFF] Skipping talosconfig context update"
  else
    update_talosconfig_context "$TALOS_CLUSTER_NAME" "$TALOSCONFIG" "$TALOS_CLUSTER_ENDPOINT" "${TALOS_CONTROL_NODES[@]}"
  fi

# ============================================================================
# APPEND MANIFESTS TO CONTROL NODES
# ============================================================================

# Append system volume encryption config only if KMS URL is configured
if [ -n "${TALOS_DISK_ENCRYPTION_KMS_URL:-}" ]; then
  log_info "Disk encryption enabled (KMS URL: $TALOS_DISK_ENCRYPTION_KMS_URL), appending systemVolumes.yaml"
  TALOS_APPEND_MANIFESTS_CONTROL_NODES+=("${BASE_DIR}/talos/systemVolumes.yaml")
else
  log_info "Disk encryption disabled (TALOS_DISK_ENCRYPTION_KMS_URL is empty), skipping systemVolumes.yaml"
fi

# ============================================================================
# DYNAMIC DISK DETECTION AND PER-NODE CONFIG GENERATION
# ============================================================================

log_info "Generating per-node configs for control plane nodes..."
for NODE in "${TALOS_CONTROL_NODES[@]}"; do
  NODE_HOSTNAME=$(echo "$NODE" | cut -d'.' -f1)
  NODE_CONFIG_FILE="$RENDERED_DIR/talos/controlplane-${NODE_HOSTNAME}.yaml"
  generate_node_config "$NODE" "$OVERLAY_DIR/talos/controlplane.yaml" "$NODE_CONFIG_FILE" "$OVERLAY_DIR" \
    ${TALOS_APPEND_MANIFESTS_CONTROL_NODES[@]+"${TALOS_APPEND_MANIFESTS_CONTROL_NODES[@]}"}
done

if [[ ${#TALOS_WORKER_NODES[@]} -gt 0 ]]; then
  log_info "Generating per-node configs for worker nodes..."
  for NODE in "${TALOS_WORKER_NODES[@]}"; do
    NODE_HOSTNAME=$(echo "$NODE" | cut -d'.' -f1)
    NODE_CONFIG_FILE="$RENDERED_DIR/talos/worker-${NODE_HOSTNAME}.yaml"
    generate_node_config "$NODE" "$OVERLAY_DIR/talos/worker.yaml" "$NODE_CONFIG_FILE" "$OVERLAY_DIR"
  done
fi



# ============================================================================
# APPLY TALOS CONFIG TO CONTROL NODES
# ============================================================================

if [[ "$DIFF_MODE" == "true" ]]; then
  log_info "[DRY RUN] Showing config diff for control plane nodes (no changes will be applied)..."
else
  log_info "Applying Talos config to controlplane nodes"
fi

for NODE in "${TALOS_CONTROL_NODES[@]}"; do
  NODE_HOSTNAME=$(echo "$NODE" | cut -d'.' -f1)
  NODE_CONFIG_FILE="$RENDERED_DIR/talos/controlplane-${NODE_HOSTNAME}.yaml"
  
  log_info "  Applying Talos config to controlplane node $NODE from $NODE_CONFIG_FILE..."
  apply_talos_config "$NODE" "$NODE_CONFIG_FILE" "$DIFF_MODE" "$TALOS_APPLY_MODE"

  if [[ "$DIFF_MODE" != "true" && "$TALOS_APPLY_MODE" != "staged" ]]; then
    wait_for_node_ready "$NODE" "${PREPARING_TIMEOUT:-300}" || exit 4
  fi
done

# In diff mode: show worker diffs immediately then exit (skipping bootstrap)
if [[ "$DIFF_MODE" == "true" ]]; then
  if [[ ${#TALOS_WORKER_NODES[@]} -gt 0 ]]; then
    log_info "[DRY RUN] Showing config diff for worker nodes..."
    for NODE in "${TALOS_WORKER_NODES[@]}"; do
      NODE_HOSTNAME=$(echo "$NODE" | cut -d'.' -f1)
      NODE_CONFIG_FILE="$RENDERED_DIR/talos/worker-${NODE_HOSTNAME}.yaml"
      apply_talos_config "$NODE" "$NODE_CONFIG_FILE" "true"
    done
  fi
  log_success "Diff complete — no changes were applied."
  exit 0
fi

# ============================================================================
# FETCH KUBECONFIG
# ============================================================================
KUBECONFIG_FETCHED=false
for NODE in "${TALOS_CONTROL_NODES[@]}"; do
  if fetch_kubeconfig "$NODE"; then
    KUBECONFIG_FETCHED=true
    break
  fi
  log_warn "Failed to fetch kubeconfig from $NODE, trying next control node..."
done
if [[ "$KUBECONFIG_FETCHED" != "true" ]]; then
  log_error "Failed to fetch kubeconfig from any control node."
  exit 6
fi

# ============================================================================
# BOOTSTRAP CLUSTER
# ============================================================================

log_info "Running bootstrap..."
BOOTSTRAP_MAX_ATTEMPTS=10
BOOTSTRAP_STATUS=0
BOOTSTRAP_OUTPUT=""
for _BOOTSTRAP_ATTEMPT in $(seq 1 "$BOOTSTRAP_MAX_ATTEMPTS"); do
  set +e
  BOOTSTRAP_OUTPUT=$(talosctl --nodes "${TALOS_CONTROL_NODES[0]}" bootstrap 2>&1)
  BOOTSTRAP_STATUS=$?
  set -e
  if echo "$BOOTSTRAP_OUTPUT" | grep -qi "bootstrap is not available yet"; then
    log_warn "Bootstrap not available yet (attempt ${_BOOTSTRAP_ATTEMPT}/${BOOTSTRAP_MAX_ATTEMPTS}), retrying in 5s..."
    sleep 5
    continue
  fi
  break
done
if echo "$BOOTSTRAP_OUTPUT" | grep -qi "bootstrap is not available yet"; then
  log_error "Bootstrap not available after ${BOOTSTRAP_MAX_ATTEMPTS} attempts."
  exit 1
fi
if [ $BOOTSTRAP_STATUS -eq 0 ]; then
  log_success "Cluster bootstrapped successfully."
elif echo "$BOOTSTRAP_OUTPUT" | grep -qi "etcd data directory is not empty"; then
  log_info "Cluster already bootstrapped (etcd data directory is not empty)."
else
  log_error "Bootstrap failed: $BOOTSTRAP_OUTPUT"
  exit $BOOTSTRAP_STATUS
fi

# ============================================================================
# WAIT FOR KUBERNETES API
# ============================================================================

log_info "Waiting for Kubernetes API to be responsive..."
KUBECONFIG=~/.kube/config
TIMEOUT_SECONDS=${K8S_READY_TIMEOUT:-300}
START_TIME=$(date +%s)
while true; do
    # Temporarily disable error exit to allow polling command to fail
    set +e
    kubectl --kubeconfig="$KUBECONFIG" get nodes >/dev/null 2>&1
    STATUS=$?
    set -e
    if [ $STATUS -eq 0 ]; then
        log_success "Kubernetes API is responsive."
        break
    fi
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    if [ $ELAPSED -ge $TIMEOUT_SECONDS ]; then
        log_error "Timeout waiting for Kubernetes API to be responsive after $TIMEOUT_SECONDS seconds."
        exit 5
    fi
    sleep 2
done

# ============================================================================
# CSR APPROVAL WATCHER AND DEPLOYMENT
# ============================================================================

log_info "Starting CSR approval for control plane nodes..."
# Approve node CSRs for all expected nodes (max_timeout: 300s, inter_node_timeout: 120s)
approve_node_csrs 300 120 "${TALOS_CONTROL_NODES[@]}"


DEPLOY_STATUS=0
"$SCRIPT_DIR/cluster-bootstrap.sh" "$env_name" || DEPLOY_STATUS=$?

# ============================================================================
# WAIT FOR CILIUM AND DEPLOY WORKER NODES
# ============================================================================

if [ ${#TALOS_WORKER_NODES[@]} -gt 0 ]; then
  log_info "Worker nodes configured, waiting for Cilium to be ready on control plane nodes before deploying workers..."
  
  CILIUM_TIMEOUT=${CILIUM_READY_TIMEOUT:-300}
  CILIUM_START=$(date +%s)
  while true; do
    READY_PODS=$(kubectl get daemonset/cilium -n kube-system -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
    if [[ "$READY_PODS" -ge "$NR_OF_CONTROL_NODES" ]]; then
      break
    fi
    CILIUM_ELAPSED=$(( $(date +%s) - CILIUM_START ))
    if [[ $CILIUM_ELAPSED -ge $CILIUM_TIMEOUT ]]; then
      log_error "Timeout waiting for Cilium (${READY_PODS}/${NR_OF_CONTROL_NODES} ready after ${CILIUM_TIMEOUT}s)."
      DEPLOY_STATUS=6
      break
    fi
    log_info "Cilium pods ready: ${READY_PODS}/${NR_OF_CONTROL_NODES} (${CILIUM_ELAPSED}s elapsed)"
    sleep 5
  done

  if [[ "$READY_PODS" -ge "$NR_OF_CONTROL_NODES" ]]; then
    log_success "Cilium is ready on all ${NR_OF_CONTROL_NODES} control plane nodes. Proceeding with worker node deployment..."
    
    # Apply worker configuration (configs were already generated earlier)
    log_info "Applying Talos config to worker nodes..."
    for NODE in "${TALOS_WORKER_NODES[@]}"; do
      NODE_HOSTNAME=$(echo "$NODE" | cut -d'.' -f1)
      NODE_CONFIG_FILE="$RENDERED_DIR/talos/worker-${NODE_HOSTNAME}.yaml"
      
      log_info "  Applying config to worker node $NODE from $NODE_CONFIG_FILE..."
      apply_talos_config "$NODE" "$NODE_CONFIG_FILE" "false" "$TALOS_APPLY_MODE"
    done
    
    log_success "Worker nodes deployed successfully."
  else
    log_error "Cilium failed to become ready within timeout. Worker nodes will not be deployed."
    DEPLOY_STATUS=6
  fi
else
  log_warn "WARNING: No worker nodes configured in TALOS_WORKER_NODES array."
  log_warn "         Storage classes with -wn suffix will not be able to provision volumes."
  log_warn "         Consider adding worker nodes to enable worker-specific storage."
fi


# ============================================================================
# CSR APPROVAL WATCHER AND DEPLOYMENT
# ============================================================================

if [[ ${#TALOS_WORKER_NODES[@]} -gt 0 ]]; then
  log_info "Starting CSR approval for worker nodes..."
  # Approve node CSRs for all expected nodes (max_timeout: 300s, inter_node_timeout: 120s)
  approve_node_csrs 300 120 "${TALOS_WORKER_NODES[@]}"
else
  log_info "No worker nodes configured, skipping worker CSR approval."
fi

# ============================================================================
# NODE REGISTRY CONFIG — first bootstrap only
# ============================================================================
# On a running cluster the registry documents are already part of the node configs
# applied above. On first bootstrap the cluster CA (cert-manager) and the
# registry-pull token (gitea-bootstrap.sh) only exist now, so patch the same
# documents in; later runs of this task include them directly.

if [[ "$REGISTRY_CONFIG_IN_NODE_CONFIGS" != "true" ]]; then
  log_info "Waiting for the cluster CA to patch registry TLS/auth into all nodes..."
  REGISTRY_WAIT_TIMEOUT="${CLUSTER_CA_TRUST_TIMEOUT:-900}"
  REGISTRY_WAIT_START=$(date +%s)
  until build_registry_config_patch "$REGISTRY_PATCH" "$HOME/.kube/config"; do
    if (( $(date +%s) - REGISTRY_WAIT_START >= REGISTRY_WAIT_TIMEOUT )); then
      log_error "Cluster CA not available after ${REGISTRY_WAIT_TIMEOUT}s; re-run 'Apply Talos configs' once cert-manager is healthy."
      DEPLOY_STATUS=7
      break
    fi
    sleep 10
  done
  if [[ -s "$REGISTRY_PATCH" ]]; then
    patch_running_nodes "$REGISTRY_PATCH" "${TALOS_CONTROL_NODES[@]}" ${TALOS_WORKER_NODES[@]+"${TALOS_WORKER_NODES[@]}"} \
      || { log_error "Registry config patch failed on some nodes; re-run 'Apply Talos configs'."; DEPLOY_STATUS=7; }
  fi
fi

# ============================================================================
# CLEANUP
# ============================================================================

# #kill $CSR_WATCHER_PID 2>/dev/null || true
# # Wait for CSR watcher to finish (or timeout)
# wait $CSR_WATCHER_PID 2>/dev/null || true

exit $DEPLOY_STATUS