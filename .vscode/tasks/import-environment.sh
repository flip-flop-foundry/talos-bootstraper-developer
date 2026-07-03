#!/usr/bin/env bash
# Clone a cluster-environment repo — OR seed a new environment from the built-in
# template — into the shared data volume and register it as a folder in the
# *user* workspace file (never the tracked template).
#
# Args:
#   1  repo URL              (optional — leave empty to seed a new environment
#                              from talos-bootstraper/templates/yourCluster-l2)
#   2  environment name      (optional when repo URL is provided — derived from
#                              the URL; required when repo URL is empty)
#   3  workspace file path   (required — must be the gitignored .local/…
#                              workspace file, not the tracked template)
#   4  environments dir      (required — absolute path on the data volume)
#   5  trust all certs       (optional — "true" disables TLS verification for
#                              the git clone; ignored when seeding from the
#                              template; defaults to "false")
set -euo pipefail

repo_url="${1:-}"
env_name="${2:-}"
workspace_file="${3:?workspace file path is required}"
environments_dir="${4:?environments directory is required}"
trust_all_certs="${5:-false}"

readonly TEMPLATE_NAME="yourCluster-l2"

log_info() {
  echo "[import-environment] $*"
}

log_error() {
  echo "ERROR: $*" >&2
}

if [[ -z "$repo_url" ]]; then
  # Seeding from template — an env name is required because we cannot derive one.
  if [[ -z "$env_name" ]]; then
    log_error "No repo URL provided — an environment name is required to seed a new environment from the template."
    exit 1
  fi
else
  # Derive the environment name from the repo URL when the user did not supply one.
  if [[ -z "$env_name" ]]; then
    env_name=$(basename "$repo_url")
    env_name="${env_name%.git}"
  fi
fi

# Guard against path traversal or shell-hostile characters in the name.
if [[ ! "$env_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
  log_error "Invalid environment name: '$env_name' (allowed: letters, digits, '.', '_', '-')"
  exit 1
fi

# Refuse to write to a workspace file outside a .local/ directory. The tracked
# template must never be mutated by this task.
workspace_dir_abs=$(cd "$(dirname "$workspace_file")" 2>/dev/null && pwd) || {
  log_error "Cannot resolve workspace file directory: $(dirname "$workspace_file")"
  exit 1
}
workspace_file_abs="$workspace_dir_abs/$(basename "$workspace_file")"
if [[ "$workspace_file_abs" != */.local/* ]]; then
  log_error "Refusing to write to '$workspace_file_abs':"
  log_error "  the import task must target a .local/ workspace file (gitignored),"
  log_error "  not the tracked template. Re-run post-create.sh to seed it."
  exit 1
fi

if [[ ! -f "$workspace_file" ]]; then
  log_error "User workspace file does not exist: $workspace_file"
  log_error "Run .devcontainer/post-create.sh to seed it from the template."
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  log_error "jq is required to update the workspace file. Install it and retry."
  exit 1
fi

mkdir -p "$environments_dir"
target_dir="$environments_dir/$env_name"

if [[ -e "$target_dir" ]]; then
  log_error "Target directory already exists: $target_dir"
  exit 1
fi

if [[ -z "$repo_url" ]]; then
  # Seed a new environment by copying the built-in template. The template lives
  # in the talos-bootstraper repo, which is checked out as a sibling of the
  # environments directory on the shared data volume.
  template_dir="$(dirname "$environments_dir")/talos-bootstraper/templates/$TEMPLATE_NAME"
  if [[ ! -d "$template_dir" ]]; then
    log_error "Template directory not found: $template_dir"
    exit 1
  fi
  template_env_file="$template_dir/$TEMPLATE_NAME.env"
  if [[ ! -f "$template_env_file" ]]; then
    log_error "Template env file not found: $template_env_file"
    exit 1
  fi

  log_info "Seeding new environment '$env_name' from template $template_dir"
  cp -R "$template_dir" "$target_dir"

  # Rename the env file so it matches <env_name>.env, as expected by all
  # downstream tasks (render-overlay, cluster-bootstrap, etc.), and update
  # OVERLAY_NAME inside it so rendering resolves to the new directory.
  mv "$target_dir/$TEMPLATE_NAME.env" "$target_dir/$env_name.env"
  sed -i "s|^export OVERLAY_NAME=\"$TEMPLATE_NAME\"|export OVERLAY_NAME=\"$env_name\"|" \
    "$target_dir/$env_name.env"

  log_info "Template seeded. Edit '$target_dir/$env_name.env' to configure the cluster."
else
  log_info "Cloning $repo_url into $target_dir"
  git_clone_args=()
  case "${trust_all_certs,,}" in
    true|1|yes)
      log_info "TLS certificate verification disabled for this clone (trust all certs)."
      git_clone_args+=(-c http.sslVerify=false)
      ;;
    false|0|no|"")
      ;;
    *)
      log_error "Invalid value for trust all certs: '$trust_all_certs' (expected true or false)"
      exit 1
      ;;
  esac
  git "${git_clone_args[@]}" clone "$repo_url" "$target_dir"
fi

if jq -e --arg p "$target_dir" '.folders[]? | select(.path == $p)' "$workspace_file" >/dev/null; then
  log_info "Folder '$target_dir' is already registered in $(basename "$workspace_file"); leaving unchanged."
else
  log_info "Adding folder '$env_name' → '$target_dir' to $(basename "$workspace_file")"
  tmp_file=$(mktemp)
  jq --arg name "$env_name" --arg path "$target_dir" \
    '.folders += [{"name": $name, "path": $path}]' \
    "$workspace_file" >"$tmp_file"
  mv "$tmp_file" "$workspace_file"
fi

log_info "Done. Reload the VS Code window to see the new folder."
