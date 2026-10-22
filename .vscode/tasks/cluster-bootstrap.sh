#!/bin/bash

##############################################################################
# cluster-bootstrap.sh
#
# Bootstraps a Talos cluster with ArgoCD and Gitea for GitOps-based management.
# Handles both initial cluster setup and subsequent re-bootstrapping.
#
# Called by cluster-initialSetup.sh once the Talos API + Kubernetes API are
# reachable; can also be invoked standalone via the "Apply Overlay" VS Code
# task once nodes are already up.
#
# Usage:
#   cluster-bootstrap.sh <env-name>
#
# Env:
#   TALOS_BOOTSTRAPPER_DATA_DIR  (required — set by devcontainer.json)
#   TALOS_BOOTSTRAPER_DIR        (optional — defaults to
#                                 $TALOS_BOOTSTRAPPER_DATA_DIR/talos-bootstraper)
##############################################################################

set -euo pipefail

# ============================================================================
# ARGUMENT PARSING AND CONFIGURATION LOADING
# ============================================================================

if [ $# -ne 1 ]; then
  echo "Usage: $0 <env-name>" >&2
  exit 1
fi

env_name="$1"

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
# ENVIRONMENT SETUP AND VARIABLE EXPORTS
# ============================================================================

#Build whitelist of all exported variables
#This is needed to avoid envsubst replacing variables that are not defined in the environment, but are present in the manifests/charts
export ENVSUBST_VARS=$(env | cut -d= -f1 | sed 's/^/\$/' | paste -sd: -)


export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LIB_DIR="$SCRIPT_DIR/lib"

export OVERLAY_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"
export TALOSCONFIG="$OVERLAY_DIR/talos/talosconfig"
export BASE_DIR="$TALOS_BOOTSTRAPER_DIR/base"
export RENDERED_OVERLAY_DIR="$OVERLAY_DIR/_rendered"

export NR_OF_CONTROL_NODES=${#TALOS_CONTROL_NODES[@]}


# ============================================================================
# LOAD LIBRARIES
# ============================================================================

source "$LIB_DIR/logging.sh"
source "$LIB_DIR/gitea-api.sh"
source "$LIB_DIR/argocd-api.sh"



log_info "Using Environment:             $env_name"
log_info "Using Script Directory:        $SCRIPT_DIR"
log_info "Using Base Directory:          $BASE_DIR"
log_info "Using Overlay Directory:       $OVERLAY_DIR"
log_info "Using Rendered Overlay Dir:    $RENDERED_OVERLAY_DIR"
log_info "Using Talos config file:       $TALOSCONFIG"

# ============================================================================
# GITEA BOOTSTRAP STATUS CHECK
# ============================================================================

if check_gitea_bootstrap_status; then
    GITEA_ALREADY_BOOTSTRAPPED=true
   log_info "Gitea already bootstrapped, proceeding with normal settings."
else
    GITEA_ALREADY_BOOTSTRAPPED=false
    log_info "Gitea not yet bootstrapped, will use temporary git-bootstrap-server for bootstrapping."
fi

# ============================================================================
# KUBERNETES ACCESS SETUP
# ============================================================================

cd "$OVERLAY_DIR" || exit 1

log_info "Setting up kubeconfig for kubectl and helm..."
talosctl kubeconfig --merge --force --nodes "${TALOS_CONTROL_NODES[0]}" ~/.kube/config
export KUBECONFIG="$(cd ~/.kube && pwd)/config"

# ============================================================================
# HELM REPOSITORY SETUP
# ============================================================================

# Check if the helm repo https://helm.cilium.io/ has been added, if not add it
if ! helm repo list | grep -q "cilium"; then
  log_info "Adding Cilium Helm repository..."
  helm repo add cilium https://helm.cilium.io/
  helm repo update
else
  log_info "Cilium Helm repository already exists, skipping addition."
fi

if ! helm repo list | grep -q "argo"; then
  log_info "Adding Argo Helm repository..."
  helm repo add argo https://argoproj.github.io/argo-helm
  helm repo update
else
  log_info "Argo Helm repository already exists, skipping addition."
fi

# ============================================================================
# RENDER OVERLAY MANIFESTS
# ============================================================================

if [[ "$GITEA_ALREADY_BOOTSTRAPPED" == "false" ]]; then
    log_info "Gitea not yet bootstrapped, replacing GITEA_CLUSTER_SERVICES_REPO_URL with git-bootstrap-server URL for rendering."

    # Temporarily override GITEA_CLUSTER_SERVICES_REPO_URL to point to the git-bootstrap-server
    OVERRIDE_GITEA_CLUSTER_SERVICES_REPO_URL="git://git-bootstrap-server:8080/git/repo.git"
    OVERRIDE_GITEA_CLUSTER_SERVICES_BRANCH_NAME="argo-cd-bootstrap"

    log_info "Rendering overlay manifests..."
    "$SCRIPT_DIR/render-overlay.sh" "$CONFIG_FILE" "GITEA_CLUSTER_SERVICES_REPO_URL=$OVERRIDE_GITEA_CLUSTER_SERVICES_REPO_URL" "GITEA_CLUSTER_SERVICES_REPO_BRANCH=$OVERRIDE_GITEA_CLUSTER_SERVICES_BRANCH_NAME"

else
    log_info "Gitea already bootstrapped, proceeding with normal settings."
fi



# ============================================================================
# CILIUM INSTALLATION
# ============================================================================

#Cilium is applied as template and service side, so that ArgoCD can take over management later

if kubectl get daemonset cilium -n kube-system &>/dev/null; then
  log_info "Cilium installed, skipping installation."
  # After initial install, ArgoCD will manage Cilium
else

  log_info "Installing Cilium with Helm..."
  helm template \
    cilium \
    cilium/cilium \
    --version "$CILIUM_HELM_VERSION" \
    --namespace kube-system \
    --values "$RENDERED_OVERLAY_DIR/cilium/ciliumHelmValues.yaml" \
    --set hubble.tls.enabled="false" \
     | kubectl apply --server-side -f -
    

  cilium status --wait

  log_success "Finished installing Cilium"
fi

# ============================================================================
# ARGOCD INSTALLATION
# ============================================================================

if kubectl get deployment argocd-server -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
  log_info "ArgoCD installed, skipping installation."
  # After initial install, ArgoCD will manage Cilium
else

  kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "${ARGOCD_NAMESPACE}" reloader-enabled=true --overwrite

  log_info "Installing/Upgrading ArgoCD with simplified values for bootstrapping..."
  helm upgrade argocd argo/argo-cd \
    --install \
    --namespace "${ARGOCD_NAMESPACE}" \
    --create-namespace \
    --version "$ARGOCD_HELM_VERSION" \
    --wait \
    --values "$RENDERED_OVERLAY_DIR/argocd/argocdHelmBootstrapValues.yaml"

  log_success "Finished installing ArgoCD for bootstrapping"

fi

# ============================================================================
# BOOTSTRAP GIT SERVER (IF GITEA NOT YET BOOTSTRAPPED)
# ============================================================================

if [[ "$GITEA_ALREADY_BOOTSTRAPPED" == "false" ]]; then
  # Sets up a temporary git server in the cluster to bootstrap ArgoCD with the initial manifests

  if kubectl get pod git-bootstrap-server -n argocd &>/dev/null; then
      log_info "Deleting existing git-bootstrap-server pod..."
      kubectl delete pod git-bootstrap-server -n argocd
  fi


  envsubst "$ENVSUBST_VARS" <  "$BASE_DIR/argocd/bootstrap/bootstrapGitServer.yaml" | kubectl apply -f - || {
        log_error "Failed to apply git-bootstrap-server manifest"
        exit 1
      }

  #kubectl apply -f "$BASE_DIR/argocd/bootstrap/bootstrapGitServer.yaml"
  kubectl wait --for=condition=Ready pod/git-bootstrap-server -n argocd

  # Copy overlay directory to git-bootstrap-server pod (only overlay content, not the full repo)
  log_info "Copying overlay directory to git-bootstrap-server pod"
  kubectl cp "$OVERLAY_DIR/." "argocd/git-bootstrap-server:/tmp/gitsrc"
  kubectl cp "$BASE_DIR/argocd/bootstrap/commitAndPush.sh" "argocd/git-bootstrap-server:/tmp/commitAndPush.sh"

  if ! kubectl exec -n argocd git-bootstrap-server -- test -d /tmp/gitsrc; then
    log_error "Expected /tmp/gitsrc to exist inside git-bootstrap-server pod after copy."
    exit 1
  fi

  if ! kubectl exec -n argocd git-bootstrap-server -- test -f /tmp/commitAndPush.sh; then
    log_error "Expected /tmp/commitAndPush.sh to exist inside git-bootstrap-server pod after copy."
    exit 1
  fi

  if ! kubectl exec -n argocd git-bootstrap-server -- /bin/sh -c 'command -v git >/dev/null'; then
    log_error "git is not available inside git-bootstrap-server pod."
    exit 1
  fi

  kubectl exec -n argocd git-bootstrap-server -- chmod +x /tmp/commitAndPush.sh
  kubectl exec -n argocd git-bootstrap-server -- /tmp/commitAndPush.sh


  # ==========================================================================
  # DEPLOY INITIAL MANIFESTS
  # ==========================================================================

  log_info "Deploying manifests with initial-deploy-with-kubectl label..."

  # First, deploy all manifests with the initial-deploy-with-kubectl label
  for manifest in "$RENDERED_OVERLAY_DIR"/*/*.yaml; do
    # Skip if no files found (glob didn't match)
    [[ -e "$manifest" ]] || continue
    
    # Extract and apply only objects with the initial-deploy-with-kubectl label
    if ! filtered_output=$(yq eval 'select(.metadata.labels."initial-deploy-with-kubectl" == "true")' "$manifest" 2>&1); then
      log_warn "  yq failed to process $(basename "$manifest"), skipping..."
      continue
    fi
    
    if [[ -n "$filtered_output" ]]; then
      log_info "  Applying objects from: $(basename "$manifest")"
      echo "$filtered_output" | kubectl apply -f - || {
        log_error "Failed to apply objects from $(basename "$manifest")"
        exit 1
      }
    fi
  done


  # ==========================================================================
  # DEPLOY ARGOCD APPLICATIONS
  # ==========================================================================

  log_info "Deploying ArgoCD applications from rendered overlay..."

  # Then, deploy all ArgoCD Application manifests
  for manifest in "$RENDERED_OVERLAY_DIR"/*/*.yaml; do
    # Skip if no files found (glob didn't match)
    [[ -e "$manifest" ]] || continue
    
    # Extract and apply ArgoCD Application and ApplicationSet objects
    if ! filtered_output=$(yq eval 'select(.apiVersion == "argoproj.io/v1alpha1" and (.kind == "Application" or .kind == "ApplicationSet"))' "$manifest" 2>&1); then
      log_warn "  yq failed to process $(basename "$manifest"), skipping..."
      continue
    fi
    
    if [[ -n "$filtered_output" ]]; then
      log_info "  Applying ArgoCD app from: $(basename "$manifest")"
      echo "$filtered_output" | kubectl apply -f - || {
        log_error "Failed to apply ArgoCD app from $(basename "$manifest")"
        exit 1
      }
    fi
  done

  log_success "Finished deploying initial manifests and ArgoCD applications"


  log_info "Refreshing all ArgoCD applications to sync with git-bootstrap-server..."
  refresh_all_argocd_apps


  # ==========================================================================
  # GITEA BOOTSTRAP
  # ==========================================================================

  log_info "Starting bootstrap of Gitea"

  "$SCRIPT_DIR/gitea-bootstrap.sh" "$env_name"

  gitea_bootstrap_status=$?
  if [ $gitea_bootstrap_status -ne 0 ]; then
      log_error "Gitea bootstrap failed with status $gitea_bootstrap_status"
      exit $gitea_bootstrap_status
  fi


fi

# ============================================================================
# FINAL RENDERING AND ARGOCD UPDATE
# ============================================================================

log_info "Gitea has now been bootstrapped, rendering with normal settings."
log_info "Rendering overlay manifests..."
"$SCRIPT_DIR/render-overlay.sh" "$CONFIG_FILE"


# ============================================================================
# CODER ↔ GITEA INTEGRATION (idempotent, every apply)
# ============================================================================
# Coder's OIDC / external-auth secrets are provisioned by gitea-bootstrap.sh.
# On an already-bootstrapped cluster that full flow is skipped, so run just the
# Coder integration here on every apply. It no-ops when Coder is not rendered or
# when the secrets already exist. Coder hard-fails to boot if a provider is
# declared with an empty client_id, so these secrets must always be populated.
log_info "Ensuring Coder ↔ Gitea integration secrets are provisioned..."
"$SCRIPT_DIR/gitea-bootstrap.sh" "$env_name" --coder-integration-only

# Keeps the node registry-pull token and its per-org read access in sync with
# customers/*/*.yaml; the Talos side picks the token up in Apply Talos configs.
log_info "Ensuring the registry-pull account has access to all customer orgs..."
"$SCRIPT_DIR/gitea-bootstrap.sh" "$env_name" --registry-pull-only


log_info "Checking if ArgoCD Helm release needs upgrading..."
helm diff upgrade argocd argo/argo-cd \
  --detailed-exitcode \
  --no-hooks \
  --suppress-secrets \
  --namespace "argocd" \
  --version "$ARGOCD_HELM_VERSION" \
  --values "$RENDERED_OVERLAY_DIR/argocd/argocdHelmValues.yaml" \
  && argocd_diff_exit=0 || argocd_diff_exit=$?

if [[ $argocd_diff_exit -eq 0 ]]; then
  log_info "ArgoCD already up to date, skipping upgrade."
elif [[ $argocd_diff_exit -eq 2 ]]; then
  log_info "Changes detected, installing/upgrading ArgoCD with Helm..."
  helm upgrade argocd argo/argo-cd \
    --install \
    --namespace "argocd" \
    --create-namespace \
    --version "$ARGOCD_HELM_VERSION" \
    --wait \
    --values "$RENDERED_OVERLAY_DIR/argocd/argocdHelmValues.yaml"
else
  log_error "helm diff failed with unexpected exit code $argocd_diff_exit"
  exit 1
fi

# ============================================================================
# PUSH TO GITEA AND FINAL DEPLOYMENT
# ============================================================================

# Push the (re-)rendered manifests to Gitea. Scoped to $env/_rendered/ only,
# non-force, real commit history. Uses the same devenv push script as the
# manual "Render and Push to Gitea" task.
"$SCRIPT_DIR/push-to-gitea.sh" "$env_name"

# ============================================================================
# DEPLOY FINAL MANIFESTS
# ============================================================================

log_info "Deploying manifests with initial-deploy-with-kubectl label..."

# First, deploy all manifests with the initial-deploy-with-kubectl label
for manifest in "$RENDERED_OVERLAY_DIR"/*/*.yaml; do
  # Skip if no files found (glob didn't match)
  [[ -e "$manifest" ]] || continue
  
  # Extract and apply only objects with the initial-deploy-with-kubectl label
  if ! filtered_output=$(yq eval 'select(.metadata.labels."initial-deploy-with-kubectl" == "true")' "$manifest" 2>&1); then
    log_warn "  yq failed to process $(basename "$manifest"), skipping..."
    continue
  fi
  
  if [[ -n "$filtered_output" ]]; then
    log_info "  Applying objects from: $(basename "$manifest")"
    echo "$filtered_output" | kubectl apply -f - || {
      log_error "Failed to apply objects from $(basename "$manifest")"
      exit 1
    }
  fi
done

# ============================================================================
# DEPLOY FINAL ARGOCD APPLICATIONS
# ============================================================================

log_info "Deploying ArgoCD applications from rendered overlay..."

# Then, deploy all ArgoCD Application manifests
for manifest in "$RENDERED_OVERLAY_DIR"/*/*.yaml; do
  # Skip if no files found (glob didn't match)
  [[ -e "$manifest" ]] || continue
  
  # Extract and apply ArgoCD Application and ApplicationSet objects
  if ! filtered_output=$(yq eval 'select(.apiVersion == "argoproj.io/v1alpha1" and (.kind == "Application" or .kind == "ApplicationSet"))' "$manifest" 2>&1); then
    log_warn "  yq failed to process $(basename "$manifest"), skipping..."
    continue
  fi
  
  if [[ -n "$filtered_output" ]]; then
    log_info "  Applying ArgoCD app from: $(basename "$manifest")"
    echo "$filtered_output" | kubectl apply -f - || {
      log_error "Failed to apply ArgoCD app from $(basename "$manifest")"
      exit 1
    }
  fi
done

# ============================================================================
# CODER SESSION TOKEN (greenfield: publish in the same run)
# ============================================================================
# The Coder ArgoCD app was just applied; wait for Coder to become Available and
# publish CODER_SESSION_TOKEN to Gitea now, so greenfield needs no second apply.
# No-ops when Coder is not rendered or the repo secret already exists; defers to
# the next apply if Coder does not come up in time.
log_info "Publishing CODER_SESSION_TOKEN (waits for Coder; no-op if already published)..."
"$SCRIPT_DIR/gitea-bootstrap.sh" "$env_name" --coder-token-only || log_warn "CODER_SESSION_TOKEN publish deferred to next apply"

# ============================================================================
# CLEANUP
# ============================================================================

if kubectl get pod git-bootstrap-server -n argocd &>/dev/null; then
  log_info "Deleting git-bootstrap-server pod..."
  kubectl delete pod git-bootstrap-server -n argocd
fi

log_success "Finished deploying initial manifests and ArgoCD applications"