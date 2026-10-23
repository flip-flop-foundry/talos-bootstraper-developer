#!/bin/bash

# ============================================================================
# lib/volume-encryption.sh — Talos volume encryption policy
# ============================================================================
# When TALOS_DISK_ENCRYPTION_KMS_URL is set, every system volume (STATE,
# EPHEMERAL) and every user/raw/swap volume must be encrypted.
#
# Talos cannot encrypt a volume in place: if a machine config asks for LUKS2 on a
# partition that already holds a plain filesystem, the volume fails with
# "block dev type mismatch" on the next boot and stays unmounted (for STATE the
# encryption settings are persisted to META immediately, so the node cannot even
# load its config after a reboot). Such volumes therefore keep their current,
# unencrypted config and are reported, together with the steps to migrate them.
#
# Dependencies: talosctl, yq, jq, logging.sh
# Globals read: TALOS_DISK_ENCRYPTION_KMS_URL, TALOSCONFIG
# Globals written: VOLUME_ENCRYPTION_FINDINGS (array of "node|volume|filesystem|device")
# ============================================================================

VOLUME_ENCRYPTION_FINDINGS=()

# Fetch a Talos resource as a JSON array, falling back to the maintenance-mode API
# (--insecure) for nodes that are not configured yet.
# Usage: talos_get_resource_json <node> <resource> [talosconfig]
talos_get_resource_json() {
  local node="$1"
  local resource="$2"
  local talosconfig="${3:-${TALOSCONFIG:-}}"
  local cmd=(talosctl)
  [[ -n "$talosconfig" && -f "$talosconfig" ]] && cmd+=(--talosconfig "$talosconfig")

  local out
  if ! out=$("${cmd[@]}" get "$resource" --nodes "$node" --endpoints "$node" -o json 2>&1); then
    if grep -qE "certificate signed by unknown authority|certificate is not valid for any names" <<<"$out"; then
      if ! out=$("${cmd[@]}" get "$resource" --nodes "$node" --endpoints "$node" --insecure -o json 2>&1); then
        log_error "Failed to query $resource on $node (also with --insecure): $out"
        return 1
      fi
    else
      log_error "Failed to query $resource on $node: $out"
      return 1
    fi
  fi

  # talosctl emits a stream of JSON objects (and \xNN escapes, which are not valid JSON)
  grep -v '^WARNING:' <<<"$out" | sed 's/\\x\([0-9a-fA-F]\{2\}\)/\\u00\1/g' \
    | jq -s '[.[] | if type == "array" then .[] else . end]' 2>/dev/null || {
      log_error "Unexpected (non-JSON) $resource output from $node: $(head -3 <<<"$out")"
      return 1
    }
}

# Make the node's volume documents follow the encryption policy, based on what is
# already on its disks (discoveredvolumes):
#   - new/empty or already-LUKS volumes: must carry an encryption block (else fail);
#   - existing unencrypted volumes: encryption block is removed, finding recorded;
#   - KMS URL empty: fail if the node has LUKS volumes the config would no longer open.
# Usage: reconcile_node_volume_encryption <node_fqdn> <config_file>
reconcile_node_volume_encryption() {
  local node="$1"
  local config_file="$2"
  local kms_url="${TALOS_DISK_ENCRYPTION_KMS_URL:-}"
  local node_hostname="${node%%.*}"

  local discovered
  discovered=$(talos_get_resource_json "$node" discoveredvolumes) || return 1

  # Partition label -> filesystem/device of what currently exists on the node
  local partitions
  partitions=$(jq -c '
    map(.spec | select((.partition_label // "") != "")
        | {key: .partition_label, value: {fs: (.name // ""), dev: (.dev_path // "")}})
    | from_entries' <<<"$discovered")

  # One line per encryptable volume document: index, kind, partition label, encryption state
  local volumes
  volumes=$(yq -o=json -I=0 '.' "$config_file" | jq -c -s --argjson parts "$partitions" '
    to_entries[]
    | .key as $di | .value as $doc
    | ({"VolumeConfig": "", "UserVolumeConfig": "u-", "RawVolumeConfig": "r-", "SwapVolumeConfig": "s-"}[$doc.kind? // ""]) as $prefix
    | select($prefix != null)
    | select($doc.kind != "VolumeConfig" or $doc.name == "STATE" or $doc.name == "EPHEMERAL")
    | ($prefix + $doc.name) as $label
    | {
        di: $di,
        kind: $doc.kind,
        label: $label,
        encrypted: ($doc.encryption != null),
        emptyKms: ([$doc.encryption.keys[]? | select(has("kms") and ((.kms.endpoint // "") == ""))] | length > 0),
        onlyEncryption: (($doc | del(.apiVersion, .kind, .name, .encryption) | length) == 0),
        fs: ($parts[$label].fs // null),
        dev: ($parts[$label].dev // "")
      }')

  local errors=0
  local drop_docs=()
  local vol di kind label encrypted empty_kms only_encryption fs dev
  while IFS= read -r vol; do
    [[ -z "$vol" ]] && continue
    di=$(jq -r '.di' <<<"$vol")
    kind=$(jq -r '.kind' <<<"$vol")
    label=$(jq -r '.label' <<<"$vol")
    encrypted=$(jq -r '.encrypted' <<<"$vol")
    empty_kms=$(jq -r '.emptyKms' <<<"$vol")
    only_encryption=$(jq -r '.onlyEncryption' <<<"$vol")
    fs=$(jq -r '.fs // "<none>"' <<<"$vol")
    dev=$(jq -r '.dev' <<<"$vol")

    if [[ "$encrypted" == "true" && "$empty_kms" == "true" ]]; then
      log_error "  $node_hostname: $kind $label has a KMS key without an endpoint (is TALOS_DISK_ENCRYPTION_KMS_URL empty?)"
      errors=$((errors + 1))
      continue
    fi

    if [[ -z "$kms_url" ]]; then
      if [[ "$fs" == "luks" && "$encrypted" != "true" ]]; then
        log_error "  $node_hostname: $label ($dev) is LUKS-encrypted, but TALOS_DISK_ENCRYPTION_KMS_URL is empty."
        log_error "  Applying this config would leave the volume unmountable after the next reboot. Set the KMS URL again."
        errors=$((errors + 1))
      fi
      continue
    fi

    case "$fs" in
      "<none>" | "" | luks)
        # Not provisioned yet, empty, or already encrypted: encryption is required
        if [[ "$encrypted" != "true" ]]; then
          log_error "  $node_hostname: $kind $label has no encryption block, but TALOS_DISK_ENCRYPTION_KMS_URL is set."
          log_error "  Add an 'encryption:' section (LUKS2 + KMS) to the patch that defines it."
          errors=$((errors + 1))
        fi
        ;;
      *)
        # Provisioned without encryption: keep it that way until it is wiped
        VOLUME_ENCRYPTION_FINDINGS+=("$node_hostname|$label|$fs|$dev")
        if [[ "$encrypted" == "true" ]]; then
          if [[ "$only_encryption" == "true" ]]; then
            drop_docs+=("$di")
          else
            yq -i "select(document_index == $di) |= del(.encryption)" "$config_file"
          fi
        fi
        ;;
    esac
  done <<<"$volumes"

  if [[ ${#drop_docs[@]} -gt 0 ]]; then
    local filter
    filter=$(printf 'document_index != %s and ' "${drop_docs[@]}")
    yq -i "select(${filter% and })" "$config_file"
  fi

  if [[ $errors -gt 0 ]]; then
    log_error "  Volume encryption check failed for $node ($errors problem(s)) — not applying configs."
    return 1
  fi
}

# Print the unencrypted volumes found by reconcile_node_volume_encryption and how
# to migrate them with the devenv tasks. No-op when nothing was found.
# Usage: print_volume_encryption_summary <control_plane_node_fqdn...>
print_volume_encryption_summary() {
  local control_nodes=("$@")

  if [[ -z "${TALOS_DISK_ENCRYPTION_KMS_URL:-}" ]]; then
    log_warn "Disk encryption is DISABLED (TALOS_DISK_ENCRYPTION_KMS_URL is empty): STATE, EPHEMERAL and user volumes are not encrypted."
    return 0
  fi

  [[ ${#VOLUME_ENCRYPTION_FINDINGS[@]} -eq 0 ]] && {
    log_success "Volume encryption: all configured volumes are (or will be provisioned) encrypted."
    return 0
  }

  local nodes=() finding node has_cp=false
  for finding in "${VOLUME_ENCRYPTION_FINDINGS[@]}"; do
    node="${finding%%|*}"
    [[ " ${nodes[*]} " == *" $node "* ]] || nodes+=("$node")
  done

  log_warn "════════════════════════════════════════════════════════════════════"
  log_warn "UNENCRYPTED VOLUMES — TALOS_DISK_ENCRYPTION_KMS_URL is set, so encryption is required."
  log_warn "These volumes were provisioned before encryption was configured. Talos cannot encrypt"
  log_warn "them in place, so their config keeps them unencrypted (adding encryption to them would"
  log_warn "make them fail to mount on the next reboot). Their data is not touched."
  log_warn ""
  local label fs dev line user_volumes
  for node in "${nodes[@]}"; do
    line=""
    user_volumes=false
    for finding in "${VOLUME_ENCRYPTION_FINDINGS[@]}"; do
      [[ "${finding%%|*}" == "$node" ]] || continue
      IFS='|' read -r _ label fs dev <<<"$finding"
      line+="${line:+, }$label ($dev, $fs)"
      [[ "$label" == STATE || "$label" == EPHEMERAL ]] || user_volumes=true
    done
    local role=""
    for cp in ${control_nodes[@]+"${control_nodes[@]}"}; do
      [[ "${cp%%.*}" == "$node" ]] && { role=" [control plane]"; has_cp=true; }
    done
    log_warn "  $node$role: $line"
    [[ "$user_volumes" == "true" ]] && log_warn "    ↳ has unencrypted user volumes: answer 'yes' to the user-volume wipe in step 2"
  done
  log_warn ""
  log_warn "To encrypt them, migrate ONE node at a time:"
  log_warn "  1. Run task 'Prepare Node for Downtime' for the node. Make sure every Longhorn volume"
  log_warn "     with a replica on it has healthy replicas on other nodes before continuing."
  log_warn "  2. Run task 'Reset Talos Node System Volumes' and select only that node. If it has"
  log_warn "     unencrypted user volumes, also accept wiping its user-volume disks (destroys the"
  log_warn "     Longhorn replicas on them)."
  log_warn "  3. Run task 'Apply Talos configs' — the node is reinstalled and provisions the wiped"
  log_warn "     volumes encrypted."
  log_warn "  4. kubectl uncordon <node>, wait until Longhorn has rebuilt all replicas, then continue"
  log_warn "     with the next node."
  if [[ "$has_cp" == "true" ]]; then
    log_warn "  Control-plane nodes: only migrate one while the others are healthy (etcd quorum). The"
    log_warn "  reset is not graceful, so afterwards remove its stale etcd member from a healthy control"
    log_warn "  plane: talosctl -n <healthy-cp> etcd members / etcd remove-member <old-member-id>."
  fi
  log_warn "════════════════════════════════════════════════════════════════════"
}
