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

echo "Active environment: $env_name"
echo "TALOSCONFIG:        $active_dir/talosconfig"
echo "KUBECONFIG:         $active_dir/kubeconfig"
echo "Selected node:      $first_node"
echo
echo "Open a new terminal to pick up updated env vars."
