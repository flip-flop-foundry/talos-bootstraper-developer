#!/usr/bin/env zsh
set -euo pipefail

################################################################################
# bootstrap-customer-repo.sh
#
# Usage:
#   bootstrap-customer-repo.sh <env-name> <org-name> <repo-name> [OPTIONS]
#
# Adds an application repository to an existing customer org (created by
# bootstrap-customer.sh). Safe to re-run.
#   1. Creates the Gitea repository <org>/<repo> if it does not exist
#   2. With --with-template: pushes the example application from the template
#      repo — only into a repo created by this run, never over existing content
#
# Nothing else is needed per repo: registry push credentials are org-level
# secrets, the workflow derives image/namespace names from the repository,
# ArgoCD creates the <org>-<repo> namespace, and nodes pull the org's images
# with the central registry-pull account (granted in bootstrap-customer.sh).
#
# Options:
#   --with-template          Seed the new repo with the example application
#   --template-branch <br>   Template repo branch (default: master)
#   --customer-name <name>   Customer name used in template placeholders (default: org)
#   --ingress-host <host>    Ingress host for the template (default: <org>-<repo>.CLUSTER_EXTERNAL_DOMAIN)
#
# Env:
#   TALOS_BOOTSTRAPPER_DATA_DIR  (required — set by devcontainer.json)
#
# Requirements: kubectl curl jq git rsync
################################################################################

: "${TALOS_BOOTSTRAPPER_DATA_DIR:?TALOS_BOOTSTRAPPER_DATA_DIR must be set (see .devcontainer/devcontainer.json)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/logging.sh"
source "$LIB_DIR/gitea-api.sh"

readonly CUSTOMER_TEMPLATE_REPO="https://github.com/flip-flop-foundry/talos-bootstraper-customer-template"
readonly CUSTOMER_TEMPLATE_BRANCH_DEFAULT="master"

readonly GITEA_ADMIN_SECRET="gitea-bootstrap-admin-secret"
readonly ADMIN_TOKEN_SCOPES='["write:repository","write:organization","write:admin","write:user"]'

# Kubernetes DNS-1123 label (namespace = <org>-<repo>)
readonly NAME_REGEX='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'

GITEA_TOKEN_ID=""
GITEA_CREDENTIALS=""
GITEA_API_URL=""

cleanup_token() {
    if [[ -n "$GITEA_TOKEN_ID" && -n "$GITEA_CREDENTIALS" && -n "$GITEA_API_URL" ]]; then
        delete_gitea_token "$GITEA_CREDENTIALS" "$GITEA_TOKEN_ID" "$GITEA_API_URL"
    fi
}
trap cleanup_token EXIT

################################################################################
# Helpers
################################################################################

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} <env-name> <org-name> <repo-name> [OPTIONS]

Arguments:
  env-name          Name of the environment under \$TALOS_BOOTSTRAPPER_DATA_DIR/environments/
  org-name          Existing customer Gitea org (see bootstrap-customer.sh)
  repo-name         Repository to add; namespace becomes <org-name>-<repo-name>

Options:
  --with-template           Seed the new repo with the example application
  --template-branch <br>    Template repo branch  (default: ${CUSTOMER_TEMPLATE_BRANCH_DEFAULT})
  --customer-name <name>    Customer name for template placeholders (default: org-name)
  --ingress-host <host>     Ingress host for the template (default: <org>-<repo>.CLUSTER_EXTERNAL_DOMAIN)

Examples:
  ${SCRIPT_NAME} tuborgnetes acme webshop
  ${SCRIPT_NAME} tuborgnetes acme demo --with-template
EOF
    exit 1
}

check_dependencies() {
    local missing=()
    for dep in kubectl curl jq git rsync; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi
}

load_env_file() {
    local env_file="$1"
    log_info "Loading environment from: $env_file"
    set -o allexport
    source "$env_file"
    set +o allexport

    [[ -z "${GITEA_DOMAIN_NAME:-}"       ]] && { log_error "GITEA_DOMAIN_NAME not set";       exit 1; }
    [[ -z "${CLUSTER_EXTERNAL_DOMAIN:-}" ]] && { log_error "CLUSTER_EXTERNAL_DOMAIN not set"; exit 1; }
    [[ -z "${TALOS_CLUSTER_NAME:-}"      ]] && { log_error "TALOS_CLUSTER_NAME not set";      exit 1; }
    return 0
}

substitute_placeholders() {
    local src_dir="$1"
    local dest_dir="$2"
    local org_name="$3"
    local app_name="$4"
    local namespace="$5"
    local customer_name="$6"
    local ingress_host="$7"
    local cluster_issuer="${TALOS_CLUSTER_NAME}-ca-issuer"

    log_info "Substituting placeholders into template..."

    rsync -a --exclude='.git' "$src_dir/" "$dest_dir/"

    find "$dest_dir" -type f | while read -r file; do
        sed -i \
            -e "s|PLACEHOLDER_GITEA_DOMAIN|${GITEA_DOMAIN_NAME}|g" \
            -e "s|PLACEHOLDER_ORG|${org_name}|g" \
            -e "s|PLACEHOLDER_APP|${app_name}|g" \
            -e "s|PLACEHOLDER_NAMESPACE|${namespace}|g" \
            -e "s|PLACEHOLDER_CLUSTER_DOMAIN|${CLUSTER_EXTERNAL_DOMAIN}|g" \
            -e "s|PLACEHOLDER_CUSTOMER_NAME|${customer_name}|g" \
            -e "s|PLACEHOLDER_INGRESS_HOST|${ingress_host}|g" \
            -e "s|PLACEHOLDER_CLUSTER_ISSUER|${cluster_issuer}|g" \
            "$file"
    done

    log_success "Placeholders substituted"
}

# Args: org repo namespace customer_name ingress_host template_branch credentials
push_template() {
    local org_name="$1"
    local repo_name="$2"
    local namespace="$3"
    local customer_name="$4"
    local ingress_host="$5"
    local template_branch="$6"
    local credentials="$7"

    local template_dir push_dir
    template_dir=$(mktemp -d "${TMPDIR:-/tmp}/customer-template.XXXXXX")
    push_dir=$(mktemp -d "${TMPDIR:-/tmp}/customer-bootstrap.XXXXXX")

    log_info "Cloning template: $CUSTOMER_TEMPLATE_REPO (branch: $template_branch)"
    if ! git clone --depth=1 --branch "$template_branch" "$CUSTOMER_TEMPLATE_REPO" "$template_dir" 2>&1; then
        log_error "Failed to clone template repository"
        rm -rf "$template_dir" "$push_dir"
        exit 1
    fi

    substitute_placeholders "$template_dir" "$push_dir" \
        "$org_name" "$repo_name" "$namespace" "$customer_name" "$ingress_host"

    push_dir_to_gitea_repo "$push_dir" "$org_name" "$repo_name" \
        "$credentials" "$GITEA_DOMAIN_NAME" "main"

    rm -rf "$template_dir" "$push_dir"
}

################################################################################
# Main
################################################################################

main() {
    [[ $# -lt 3 ]] && usage

    local env_name="$1"
    local org_name="$2"
    local repo_name="$3"
    shift 3

    local with_template="false"
    local template_branch="$CUSTOMER_TEMPLATE_BRANCH_DEFAULT"
    local customer_name="$org_name"
    local ingress_host=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --with-template)   with_template="true";  shift ;;
            --template-branch) template_branch="$2";  shift 2 ;;
            --customer-name)   customer_name="$2";    shift 2 ;;
            --ingress-host)    ingress_host="$2";     shift 2 ;;
            "")                shift ;;  # empty pickString value from the VS Code task
            *) log_error "Unknown argument: $1"; usage ;;
        esac
    done

    local namespace="${org_name}-${repo_name}"
    if [[ ! "$org_name" =~ $NAME_REGEX || ! "$repo_name" =~ $NAME_REGEX || ${#namespace} -gt 63 ]]; then
        log_error "Org and repo names must be lowercase alphanumerics or '-', and '<org>-<repo>' at most 63 chars (got '$namespace')"
        exit 1
    fi

    local env_file="$TALOS_BOOTSTRAPPER_DATA_DIR/environments/$env_name/$env_name.env"
    [[ ! -f "$env_file" ]] && { log_error "Env file not found: $env_file"; exit 1; }

    check_dependencies
    load_env_file "$env_file"

    [[ -z "$ingress_host" ]] && ingress_host="${namespace}.${CLUSTER_EXTERNAL_DOMAIN}"

    local gitea_api_url="https://${GITEA_DOMAIN_NAME}/api/v1"

    log_info "============================================================"
    log_info "Customer repository bootstrap"
    log_info "  Gitea repo    : $org_name/$repo_name"
    log_info "  Namespace     : $namespace  (created by ArgoCD on first sync)"
    log_info "  With template : $with_template"
    log_info "============================================================"

    # ------------------------------------------------------------------
    log_info "=== Step 1/2: Gitea repository ==="
    local credentials
    credentials=$(fetch_gitea_admin_credentials) || exit 1
    GITEA_CREDENTIALS="$credentials"
    GITEA_API_URL="$gitea_api_url"

    local token_result
    token_result=$(create_gitea_token "$credentials" "$gitea_api_url" "customer-repo-bootstrap-$(date +%s)" "$ADMIN_TOKEN_SCOPES") || exit 1
    GITEA_TOKEN_ID="${token_result%%|*}"
    local token="${token_result#*|}"

    if [[ "$(check_gitea_organization "$org_name" "$gitea_api_url" "$token")" != "200" ]]; then
        log_error "Gitea org '$org_name' not found — run the Bootstrap Customer task first"
        exit 1
    fi

    local repo_created="false"
    local repo_status
    repo_status=$(check_gitea_repository "$org_name" "$repo_name" "$gitea_api_url" "$token")
    if [[ "$repo_status" == "200" ]]; then
        log_success "Repo already exists: $org_name/$repo_name"
    elif [[ "$repo_status" == "404" ]]; then
        create_gitea_repository "$org_name" "$repo_name" "$gitea_api_url" "$token" || exit 1
        repo_created="true"
    else
        log_error "Unexpected status checking repo: $repo_status"; exit 1
    fi
    echo ""

    # ------------------------------------------------------------------
    log_info "=== Step 2/2: Example application ==="
    if [[ "$with_template" != "true" ]]; then
        log_info "Skipped (no --with-template)"
    elif [[ "$repo_created" != "true" ]]; then
        log_warn "Skipped: $org_name/$repo_name already existed — not overwriting its content"
    else
        push_template "$org_name" "$repo_name" "$namespace" "$customer_name" \
            "$ingress_host" "$template_branch" "$credentials"
    fi
    echo ""

    log_success "============================================================"
    log_success "Repository ready: https://${GITEA_DOMAIN_NAME}/${org_name}/${repo_name}"
    log_success "  Namespace : ${namespace}  (created by ArgoCD; images pulled with the node-level registry-pull account)"
    log_success "  ArgoCD deploys it once the repo contains a deploy/ directory."
    log_success "  CI: copy .gitea/workflows/build-and-deploy.yaml from the template —"
    log_success "      org secrets CI_REGISTRY_USER/CI_REGISTRY_TOKEN are inherited."
    log_success "============================================================"
}

main "$@"
