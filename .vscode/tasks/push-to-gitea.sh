#!/usr/bin/env bash
# Push the rendered manifests of an environment to its Gitea cluster-services repo.
#
# Scope-limited by design: only files under $ENV/_rendered/ are ever committed.
# Source overlays (env file, talos configs, per-node patches, customer descriptors)
# stay local and never leak to Gitea.
#
# Uses an ephemeral /tmp clone so the env folder's own git state is untouched.
# Push is non-force; if Gitea has diverged the user is asked to resolve manually.
#
# Prereq: the target cluster must be reachable (KUBECONFIG must resolve) because
# credentials are pulled from the gitea admin Secret in the cluster.
#
# Args:
#   1  environment name (required)
#
# Env:
#   TALOS_BOOTSTRAPPER_DATA_DIR  (required — set by devcontainer.json)
set -euo pipefail

env_name="${1:?environment name is required}"

: "${TALOS_BOOTSTRAPPER_DATA_DIR:?TALOS_BOOTSTRAPPER_DATA_DIR must be set (see .devcontainer/devcontainer.json)}"

env_dir="$TALOS_BOOTSTRAPPER_DATA_DIR/environments/$env_name"
env_file="$env_dir/$env_name.env"
rendered_dir="$env_dir/_rendered"

if [[ ! -f "$env_file" ]]; then
  echo "ERROR: env file not found: $env_file" >&2
  exit 1
fi
if [[ ! -d "$rendered_dir" ]]; then
  echo "ERROR: rendered directory not found: $rendered_dir" >&2
  echo "       Run the 'Render Overlay' task first." >&2
  exit 1
fi

# Load env file (export every variable so lib functions see them).
set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

# Shared libraries are co-located in devenv/.vscode/tasks/lib/.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/logging.sh
source "$SCRIPT_DIR/lib/logging.sh" \
  || { echo "ERROR: failed to load $SCRIPT_DIR/lib/logging.sh" >&2; exit 1; }
# shellcheck source=./lib/gitea-api.sh
source "$SCRIPT_DIR/lib/gitea-api.sh" \
  || { echo "ERROR: failed to load $SCRIPT_DIR/lib/gitea-api.sh" >&2; exit 1; }

# --- fetch credentials from cluster ---
log_info "Fetching Gitea admin credentials from cluster ($GITEA_NAMESPACE/${GITEA_ADMIN_SECRET:-gitea-bootstrap-admin-secret})"
creds="$(fetch_gitea_admin_credentials)" || {
  log_error "Could not fetch Gitea admin credentials. Is the cluster reachable and Gitea installed?"
  exit 1
}
username="${creds%%:*}"
password="${creds#*:}"

# --- prepare repo URLs ---
repo_url="https://${GITEA_DOMAIN_NAME}/${GITEA_CLUSTER_GITEA_ORG_NAME}/${GITEA_CLUSTER_SERVICES_REPO_NAME}.git"
auth_url="https://${username}:${password}@${GITEA_DOMAIN_NAME}/${GITEA_CLUSTER_GITEA_ORG_NAME}/${GITEA_CLUSTER_SERVICES_REPO_NAME}.git"
branch="${GITEA_CLUSTER_SERVICES_REPO_BRANCH:-main}"

# --- ephemeral clone ---
tmp_root="$(mktemp -d "/tmp/gitea-push.${env_name}.XXXXXX")"
tmp_repo="$tmp_root/repo"
trap 'rm -rf "$tmp_root"' EXIT

log_info "Cloning $repo_url (branch: $branch) into $tmp_repo"
if ! git -c http.sslVerify=false clone --depth=1 --branch "$branch" "$auth_url" "$tmp_repo" >/dev/null 2>&1; then
  log_error "Failed to clone $repo_url on branch $branch"
  log_error "Verify the branch exists and credentials have push access."
  exit 1
fi

git -C "$tmp_repo" config user.email "render-and-push@${GITEA_DOMAIN_NAME}"
git -C "$tmp_repo" config user.name  "render-and-push (${env_name})"

# --- mirror only _rendered/ into the clone ---
# --delete removes files in the clone that no longer exist in the local render,
# so Gitea's _rendered/ tracks the current render exactly.
log_info "Syncing $rendered_dir/ -> $tmp_repo/_rendered/"
rsync -a --delete "$rendered_dir/" "$tmp_repo/_rendered/"

# Only stage files under _rendered/. Nothing else can ever get committed.
git -C "$tmp_repo" add -A -- _rendered/

if git -C "$tmp_repo" diff --cached --quiet; then
  log_success "No changes under _rendered/ to push."
  exit 0
fi

# --- commit + push (non-force) ---
commit_msg="Render ${env_name} at $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
git -C "$tmp_repo" commit -m "$commit_msg" >/dev/null

log_info "Pushing to Gitea: $repo_url (branch: $branch, non-force)"
if ! push_output="$(GIT_TERMINAL_PROMPT=0 git -C "$tmp_repo" -c http.sslVerify=false push origin "HEAD:$branch" 2>&1)"; then
  log_error "Push rejected — Gitea branch '$branch' likely diverged from the last known state."
  log_error "Resolve manually (e.g. inspect Gitea, then re-run) before retrying."
  log_error "git output:"
  echo "$push_output" >&2
  exit 1
fi

log_success "$commit_msg"
log_success "Pushed ${env_name}/_rendered/ to $repo_url ($branch)"
