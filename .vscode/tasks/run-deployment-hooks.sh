#!/usr/bin/env zsh
# Run trusted current-source hooks against an isolated, fresh desired-state render.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
[[ $# -ge 2 ]] || { echo "Usage: $0 <env-file> beforeArgo [VAR=value ...] [--dry-run]" >&2; exit 2; }
env_file="$1"
phase="$2"
shift 2
[[ "$phase" == beforeArgo ]] || { echo "Unsupported hook phase: $phase (beforeTalos is reserved)" >&2; exit 2; }
typeset -a overrides=()
dry_run=false
for arg in "$@"; do
    if [[ "$arg" == --dry-run ]]; then
        dry_run=true
    elif [[ "$arg" =~ ^[A-Za-z_][A-Za-z0-9_]*=.* ]]; then
        overrides+=("$arg")
    else
        echo "Invalid hook argument: $arg" >&2
        exit 2
    fi
done
if [[ "$dry_run" == true ]]; then
    echo "[deployment-hooks] DRY-RUN: skip $phase; no scripts executed"
    exit 0
fi
[[ -f "$env_file" ]] || { echo "Environment file not found: $env_file" >&2; exit 2; }
env_file="${env_file:A}"
set -a
source "$env_file"
set +a
for override in "${overrides[@]}"; do
    export "$override"
done
: "${TALOS_BOOTSTRAPPER_DATA_DIR:?required}"
export HOOK_BASE_DIR="${TALOS_BOOTSTRAPER_DIR:-$TALOS_BOOTSTRAPPER_DATA_DIR/talos-bootstraper}/base"
export HOOK_OVERLAY_DIR="${env_file:h}"
export HOOK_ENV_FILE="$env_file"
export HOOK_PHASE="$phase"
export HOOK_TOOL_DIR="$SCRIPT_DIR"
[[ -n "${OVERLAY_NAME:-}" && "$OVERLAY_NAME" == "${HOOK_OVERLAY_DIR:t}" ]] || {
    echo "OVERLAY_NAME must match the selected environment directory" >&2; exit 2;
}
[[ -d "$HOOK_BASE_DIR" ]] || { echo "Base directory not found: $HOOK_BASE_DIR" >&2; exit 2; }
typeset -a exclusions=("${EXCLUDED_BASE[@]:-}")
# Capture first, not process substitution: discovery errors must propagate.
inventory="$(python3 "$SCRIPT_DIR/lib/deployment-hooks.py" list "$HOOK_BASE_DIR" "$HOOK_OVERLAY_DIR" "$phase" "${exclusions[@]}")"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export HOOK_RENDERED_DIR="$scratch/_rendered"
"$SCRIPT_DIR/render-overlay.sh" "$env_file" "${overrides[@]}" --output-dir "$HOOK_RENDERED_DIR"
python3 "$SCRIPT_DIR/lib/deployment-hooks.py" check-requirements "$HOOK_BASE_DIR" "$HOOK_OVERLAY_DIR" "$HOOK_RENDERED_DIR" "${exclusions[@]}"
[[ -n "$inventory" ]] || { echo "[deployment-hooks] No enabled $phase hooks or dependent Applications"; exit 0; }

# Validate kubeconfig identity without conflating an absent API with connection errors.
: "${TALOS_CLUSTER_NAME:?required for deployment hook context validation}"
context="$(kubectl config current-context)"
cluster="$(kubectl config view --minify -o jsonpath='{.contexts[0].context.cluster}')"
[[ "$cluster" == "$TALOS_CLUSTER_NAME" ]] || {
    echo "Wrong Kubernetes cluster: '$cluster'; expected '$TALOS_CLUSTER_NAME' ($context)" >&2; exit 1;
}
server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
: "${TALOS_CLUSTER_ENDPOINT:?required for deployment hook endpoint validation}"
expected_server="${DEPLOYMENT_HOOK_KUBE_SERVER:-https://$TALOS_CLUSTER_ENDPOINT:6443}"
[[ "$server" == "$expected_server" ]] || {
    echo "Wrong Kubernetes API endpoint: '$server'; expected '$expected_server'" >&2; exit 1;
}
if [[ -n "${DEPLOYMENT_HOOK_KUBE_CONTEXT:-}" && "$context" != "$DEPLOYMENT_HOOK_KUBE_CONTEXT" ]]; then
    echo "Wrong Kubernetes context: $context; expected $DEPLOYMENT_HOOK_KUBE_CONTEXT" >&2
    exit 1
fi
# Pin every subsequent hook kubectl invocation to the validated context.
export HOOK_KUBE_CONTEXT="$context"
for hook in "${(@f)inventory}"; do
    echo "[deployment-hooks] $phase: $hook"
    # Scripts need not have executable mode, but must declare Bash-compatible shell.
    bash "$hook"
done
