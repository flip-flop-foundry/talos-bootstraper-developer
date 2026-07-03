#!/usr/bin/env bash
# Interactive multi-select reset for Talos node system volumes (STATE + EPHEMERAL).
#
# Usage: reset-talos-nodes.sh <env-name>
#
# Env: TALOS_BOOTSTRAPPER_DATA_DIR (required — set by devcontainer.json)
set -euo pipefail

env_name="${1:?environment name is required}"

: "${TALOS_BOOTSTRAPPER_DATA_DIR:?TALOS_BOOTSTRAPPER_DATA_DIR must be set (see .devcontainer/devcontainer.json)}"

env_dir="$TALOS_BOOTSTRAPPER_DATA_DIR/environments/$env_name"
ENV_FILE="$env_dir/$env_name.env"
TALOSCONFIG="$env_dir/talos/talosconfig"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: env file not found: $ENV_FILE" >&2
  exit 1
fi
if [[ ! -f "$TALOSCONFIG" ]]; then
  echo "ERROR: talosconfig not found: $TALOSCONFIG" >&2
  echo "       Run 'Apply Talos configs' for this environment first." >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

# Collect all nodes
ALL_NODES=("${TALOS_CONTROL_NODES[@]}" ${TALOS_WORKER_NODES[@]+"${TALOS_WORKER_NODES[@]}"})

if [[ ${#ALL_NODES[@]} -eq 0 ]]; then
  echo "ERROR: No nodes found in env file." >&2
  exit 1
fi

echo ""
echo "============================================"
echo "  Talos Node Reset — STATE + EPHEMERAL"
echo "  Overlay: $OVERLAY_NAME"
echo "============================================"
echo ""
echo "Available nodes:"
for i in "${!ALL_NODES[@]}"; do
  printf "  [%d] %s\n" "$((i + 1))" "${ALL_NODES[$i]}"
done
echo ""
echo "Enter node numbers to reset (space-separated, e.g. '1 3'), or 'all' for all nodes:"
read -r SELECTION

SELECTED_NODES=()
if [[ "$SELECTION" == "all" ]]; then
  SELECTED_NODES=("${ALL_NODES[@]}")
else
  for NUM in $SELECTION; do
    if [[ "$NUM" =~ ^[0-9]+$ ]] && (( NUM >= 1 && NUM <= ${#ALL_NODES[@]} )); then
      SELECTED_NODES+=("${ALL_NODES[$((NUM - 1))]}")
    else
      echo "WARNING: '$NUM' is not a valid selection, skipping." >&2
    fi
  done
fi

if [[ ${#SELECTED_NODES[@]} -eq 0 ]]; then
  echo "No nodes selected. Aborting." >&2
  exit 1
fi

NODE_LIST=$(IFS=','; echo "${SELECTED_NODES[*]}")

echo ""
echo "The following nodes will have STATE and EPHEMERAL wiped and will REBOOT:"
for NODE in "${SELECTED_NODES[@]}"; do
  echo "  - $NODE"
done
echo ""
echo "⚠️  This is DESTRUCTIVE and IRREVERSIBLE. Type 'yes' to confirm:"
read -r CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
  echo "Aborted." >&2
  exit 1
fi

echo ""
echo "Resetting nodes: $NODE_LIST"
talosctl reset \
  --system-labels-to-wipe STATE \
  --system-labels-to-wipe EPHEMERAL \
  --talosconfig "$TALOSCONFIG" \
  --graceful=false \
  --reboot=true \
  --nodes "$NODE_LIST"

echo ""
echo "Reset command sent to: $NODE_LIST"
