#!/usr/bin/env bash
# Point the devcontainer's TALOSCONFIG and KUBECONFIG at a specific imported
# environment.
#
# The devcontainer wires:
#   TALOSCONFIG = <devenv>/.vscode/current/talosconfig
#   KUBECONFIG  = <devenv>/.vscode/current/kubeconfig
#
# This script creates/refreshes those two files based on the chosen environment.
#
# Args:
#   1  environment name (required — a subdirectory of $TALOS_BOOTSTRAPPER_DATA_DIR/environments)
set -euo pipefail

log_info() {
  echo "[set-active-talos-kube-context] $*"
}

log_warn() {
  echo "[set-active-talos-kube-context] WARN: $*" >&2
}

install_cert_trust() {
  local cert_file="$1"
  local trusted_cert_path="/usr/local/share/ca-certificates/${OVERLAY_NAME}-ca.crt"

  if ! command -v sudo >/dev/null 2>&1; then
    log_warn "sudo is not available; cannot update the devcontainer trust store."
    return 1
  fi

  sudo -n install -o root -g root -m 0644 "$cert_file" "$trusted_cert_path"
  sudo -n update-ca-certificates >/dev/null
}

env_name="${1:?environment name is required}"

: "${TALOS_BOOTSTRAPPER_DATA_DIR:?TALOS_BOOTSTRAPPER_DATA_DIR must be set (see .devcontainer/devcontainer.json)}"

environments_dir="$TALOS_BOOTSTRAPPER_DATA_DIR/environments"
env_dir="$environments_dir/$env_name"
env_file="$env_dir/$env_name.env"
talosconfig_src="$env_dir/talos/talosconfig"

if [[ ! -d "$env_dir" ]]; then
  echo "ERROR: environment directory not found: $env_dir" >&2
  exit 1
fi
if [[ ! -f "$env_file" ]]; then
  echo "ERROR: env file not found: $env_file" >&2
  exit 1
fi
if [[ ! -f "$talosconfig_src" ]]; then
  echo "ERROR: talosconfig not found: $talosconfig_src" >&2
  echo "       Run cluster-initialSetup.sh for this environment first." >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$env_file"

OVERLAY_NAME="${OVERLAY_NAME:-$env_name}"
: "${CERT_MGR_NAMESPACE:=cert-manager}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
active_dir="$(cd "$script_dir/.." && pwd)/current"
mkdir -p "$active_dir"

ln -sfn "$talosconfig_src" "$active_dir/talosconfig"

first_node=$(yq -r '.contexts[].nodes[0]' "$active_dir/talosconfig" | head -n1)
if [[ -z "$first_node" || "$first_node" == "null" ]]; then
  echo "ERROR: could not determine first Talos node from $active_dir/talosconfig" >&2
  exit 1
fi

talosctl --talosconfig "$active_dir/talosconfig" \
  kubeconfig "$active_dir/kubeconfig" \
  --nodes "$first_node" --merge

export KUBECONFIG="$active_dir/kubeconfig"

trusted_cert_path="/usr/local/share/ca-certificates/${OVERLAY_NAME}-ca.crt"

if [[ -f "$trusted_cert_path" ]]; then
  log_info "Cluster CA already present in the devcontainer trust store: $trusted_cert_path"
else
  if ! command -v kubectl >/dev/null 2>&1; then
    log_warn "kubectl is not available; cannot fetch $CERT_MGR_NAMESPACE/k8s-ca-secret."
  else
    tmp_ca_dir=$(mktemp -d)
    tmp_ca_file="$tmp_ca_dir/${OVERLAY_NAME}-ca.crt"

    log_info "Fetching cluster CA certificate into a temporary file"
    if kubectl --kubeconfig "$active_dir/kubeconfig" \
      get secret k8s-ca-secret \
      -n "$CERT_MGR_NAMESPACE" \
      -o jsonpath='{.data.ca\.crt}' 2>/dev/null \
      | base64 -d >"$tmp_ca_file"; then
      if [[ -s "$tmp_ca_file" ]]; then
        log_info "Installing cluster CA into $trusted_cert_path"
        if ! install_cert_trust "$tmp_ca_file"; then
          log_warn "Could not update the devcontainer trust store for $trusted_cert_path"
        fi
      else
        log_warn "Secret $CERT_MGR_NAMESPACE/k8s-ca-secret did not return a CA certificate; skipping trust-store update."
      fi
    else
      log_warn "Could not fetch CA certificate from $CERT_MGR_NAMESPACE/k8s-ca-secret; skipping trust-store update."
    fi
    rm -rf "$tmp_ca_dir"
  fi
fi

echo "Active environment: $env_name"
echo "TALOSCONFIG:        $active_dir/talosconfig"
echo "KUBECONFIG:         $active_dir/kubeconfig"
echo "Selected node:      $first_node"
echo
echo "Open a new terminal to pick up updated env vars."
