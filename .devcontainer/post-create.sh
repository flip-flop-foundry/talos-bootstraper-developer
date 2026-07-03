#!/usr/bin/env bash
# Initialize the shared data volume mounted at /workspaces/talos-bootstrapper-data.
# This volume holds the talos-bootstraper checkout and all imported cluster
# environments so they persist across container rebuilds and are kept
# separate from the devenv git repository.
#
# Also seeds a per-checkout, gitignored user workspace file at
# devenv/.local/talos-bootstrapper.code-workspace from the tracked template
# so the "Import environment" task can register new folders without ever
# mutating anything tracked by git.
set -euo pipefail

DATA_DIR="${DATA_DIR:-/workspaces/talos-bootstrapper-data}"
TALOS_BOOTSTRAPER_REPO_URL="${TALOS_BOOTSTRAPER_REPO_URL:-https://github.com/flip-flop-foundry/talos-bootstraper.git}"
TALOS_BOOTSTRAPER_DIR="$DATA_DIR/talos-bootstraper"
ENVIRONMENTS_DIR="$DATA_DIR/environments"

# post-create runs with cwd set to the container workspace folder (the devenv repo).
DEVENV_DIR="${DEVENV_DIR:-$PWD}"
TEMPLATE_WORKSPACE="$DEVENV_DIR/.devcontainer/assets/talos-bootstrapper.code-workspace.template"
USER_WORKSPACE_DIR="$DEVENV_DIR/.local"
USER_WORKSPACE="$USER_WORKSPACE_DIR/talos-bootstrapper.code-workspace"

log() {
  echo -e "[post-create] $*"
}

# The volume is created by Docker as root-owned. Take ownership so the
# vscode user can write to it without sudo from here on.
if [[ ! -w "$DATA_DIR" ]]; then
  log "Taking ownership of $DATA_DIR"
  sudo chown -R "$(id -u):$(id -g)" "$DATA_DIR"
fi

mkdir -p "$ENVIRONMENTS_DIR"

if [[ -d "$TALOS_BOOTSTRAPER_DIR/.git" ]]; then
  log "talos-bootstraper already present at $TALOS_BOOTSTRAPER_DIR"
else
  log "Cloning $TALOS_BOOTSTRAPER_REPO_URL into $TALOS_BOOTSTRAPER_DIR"
  git clone "$TALOS_BOOTSTRAPER_REPO_URL" "$TALOS_BOOTSTRAPER_DIR"
fi

# --- Seed / merge the user workspace file --------------------------------
# The user workspace lives at devenv/.local/talos-bootstrapper.code-workspace
# (gitignored). Folder paths in it are:
#   - ".." for the devenv repo itself (template writes ".", we rewrite it)
#   - absolute paths for anything on the data volume
#
# Behavior:
#   - If the user workspace does not exist yet, copy the template and
#     rewrite the "." folder path to "..".
#   - If it already exists, merge: add any template folders whose "name"
#     is not already present in the user file, and shallow-merge every
#     other top-level key with the user winning on conflicts.
if ! command -v jq >/dev/null 2>&1; then
  log "WARNING: jq is not installed; skipping user workspace seed/merge."
  log "         Install jq and re-run this script to seed .local/talos-bootstrapper.code-workspace."
else
  mkdir -p "$USER_WORKSPACE_DIR"

  if [[ ! -f "$TEMPLATE_WORKSPACE" ]]; then
    log "WARNING: template workspace $TEMPLATE_WORKSPACE not found; skipping seed."
  else
    template_rewritten=$(mktemp)
    # Rewrite the devenv folder's path (".") so it works from .local/.
    jq '
      .folders |= map(
        if .path == "." then .path = ".." else . end
      )
    ' "$TEMPLATE_WORKSPACE" >"$template_rewritten"

    if [[ ! -f "$USER_WORKSPACE" ]]; then
      log "Seeding user workspace at $USER_WORKSPACE"
      mv "$template_rewritten" "$USER_WORKSPACE"
    else
      log "Merging template into existing $USER_WORKSPACE (user values win)"
      merged=$(mktemp)
      # $tpl * $user shallow-merges with $user winning; then rebuild folders
      # as user's folders + any template folders whose name is new.
      jq -s '
        .[0] as $tpl | .[1] as $user
        | ($tpl * $user) as $base
        | ($user.folders // []) as $uf
        | ($tpl.folders  // []) as $tf
        | ($uf | map(.name)) as $names
        | $base
        | .folders = ($uf + ($tf | map(select(.name as $n | $names | index($n) | not))))
      ' "$template_rewritten" "$USER_WORKSPACE" >"$merged"
      mv "$merged" "$USER_WORKSPACE"
      rm -f "$template_rewritten"
    fi
  fi
fi

log "✅ Data volume ready:"
log "  📁 $TALOS_BOOTSTRAPER_DIR"
log "  📁 $ENVIRONMENTS_DIR"
log "📝 User workspace (gitignored):"
log "  📄 $USER_WORKSPACE"
log ""
log "🎯 \033[1;32mOpen .local/talos-bootstrapper.code-workspace to enter the multi-root view.\033[0m"
