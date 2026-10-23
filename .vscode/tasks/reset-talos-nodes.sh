#!/usr/bin/env bash
# Interactive multi-select reset for Talos node system volumes (STATE + EPHEMERAL).
# Optionally also wipes the disks holding the nodes' user volumes (Longhorn data),
# e.g. to re-provision them encrypted (see lib/volume-encryption.sh).
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/logging.sh
source "$SCRIPT_DIR/lib/logging.sh"
# shellcheck source=./lib/volume-encryption.sh
source "$SCRIPT_DIR/lib/volume-encryption.sh"

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

# Disks backing user/raw/swap volumes on a node (never the system disk).
# Usage: user_volume_disks <node>
user_volume_disks() {
  local node="$1" discovered systemdisk system_disk
  discovered=$(talos_get_resource_json "$node" discoveredvolumes "$TALOSCONFIG") || return 1
  systemdisk=$(talos_get_resource_json "$node" systemdisk "$TALOSCONFIG") || return 1
  system_disk=$(jq -r '.[0].spec.devPath // ""' <<<"$systemdisk")
  if [[ -z "$system_disk" ]]; then
    echo "ERROR: could not determine the system disk of $node" >&2
    return 1
  fi
  jq -r --arg sys "$system_disk" '
    [.[].spec | select((.partition_label // "") | test("^[urs]-")) | .parent_dev_path // empty]
    | unique[] | select(. != $sys)' <<<"$discovered"
}

echo ""
echo "Also wipe the disks holding the user volumes (Longhorn data) of the selected nodes,"
echo "so they are re-created (encrypted, if TALOS_DISK_ENCRYPTION_KMS_URL is set)? [y/N]"
read -r WIPE_USER_DISKS

declare -A USER_DISKS=()
if [[ "$WIPE_USER_DISKS" =~ ^[Yy]$ ]]; then
  for NODE in "${SELECTED_NODES[@]}"; do
    if ! DISKS=$(user_volume_disks "$NODE"); then
      echo "ERROR: could not determine the user-volume disks of $NODE. Aborting." >&2
      exit 1
    fi
    [[ -n "$DISKS" ]] && USER_DISKS[$NODE]=$(tr '\n' ' ' <<<"$DISKS" | xargs)
  done
fi

echo ""
echo "The following nodes will have STATE and EPHEMERAL wiped and will REBOOT:"
for NODE in "${SELECTED_NODES[@]}"; do
  if [[ -n "${USER_DISKS[$NODE]:-}" ]]; then
    echo "  - $NODE  (+ user-volume disks: ${USER_DISKS[$NODE]})"
  elif [[ "$WIPE_USER_DISKS" =~ ^[Yy]$ ]]; then
    echo "  - $NODE  (no user-volume disks found)"
  else
    echo "  - $NODE"
  fi
done
echo ""
echo "⚠️  This is DESTRUCTIVE and IRREVERSIBLE. Type 'yes' to confirm:"
read -r CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
  echo "Aborted." >&2
  exit 1
fi

if [[ ${#USER_DISKS[@]} -gt 0 ]]; then
  echo ""
  echo "⚠️  Wiping user-volume disks destroys every Longhorn replica on them. Only continue if"
  echo "   all affected Longhorn volumes have healthy replicas on other nodes."
  echo "   Type 'wipe user disks' to confirm:"
  read -r CONFIRM_USER
  if [[ "$CONFIRM_USER" != "wipe user disks" ]]; then
    echo "Aborted." >&2
    exit 1
  fi
fi

# Nodes with user disks to wipe need their own reset call (the disk list is per node)
BATCH_NODES=()
for NODE in "${SELECTED_NODES[@]}"; do
  if [[ -n "${USER_DISKS[$NODE]:-}" ]]; then
    echo ""
    echo "Resetting $NODE (user-volume disks: ${USER_DISKS[$NODE]})"
    talosctl reset \
      --talosconfig "$TALOSCONFIG" \
      --graceful=false \
      --reboot=true \
      --user-disks-to-wipe "$(tr ' ' ',' <<<"${USER_DISKS[$NODE]}")" \
      --nodes "$NODE"
  else
    BATCH_NODES+=("$NODE")
  fi
done

if [[ ${#BATCH_NODES[@]} -gt 0 ]]; then
  NODE_LIST=$(IFS=','; echo "${BATCH_NODES[*]}")
  echo ""
  echo "Resetting nodes: $NODE_LIST"
  talosctl reset \
    --talosconfig "$TALOSCONFIG" \
    --graceful=false \
    --reboot=true \
    --nodes "$NODE_LIST"
fi

echo ""
echo "Reset command sent to: $(IFS=','; echo "${SELECTED_NODES[*]}")"
