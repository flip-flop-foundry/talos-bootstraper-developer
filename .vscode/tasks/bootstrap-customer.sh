#!/usr/bin/env zsh
set -euo pipefail

################################################################################
# bootstrap-customer.sh
#
# Usage:
#   bootstrap-customer.sh <env-name> <CUSTOMER_NAME> [OPTIONS]
#
# Bootstraps a new customer (org-level setup) on the cluster:
#   1. Creates a Gitea organisation for the customer
#   2. Adds the ArgoCD service account as an org member (needed for SCM scanning)
#      and gives the central registry-pull account packages:read in the org, so
#      every node can pull the customer's images (no per-namespace pull secrets)
#   3. Writes customers/<name>/<name>.yaml in the env repo and commits the rendered
#      descriptor to cluster-services so the customer-apps ApplicationSet
#      discovers the customer's org immediately
#   4. Creates an ArgoCD AppProject scoped to <orgName>-* namespaces and
#      <orgName>/* source repos
#   5. Creates the ci-<org> user (team ci-packages, packages:write) and stores its
#      token as org secrets CI_REGISTRY_USER / CI_REGISTRY_TOKEN
#   6. Runs bootstrap-customer-repo.sh --with-template for the initial repo
#      (repo + example app push)
#
# Further repos for the same customer: bootstrap-customer-repo.sh
# (VS Code task "Bootstrap Customer Repo").
#
# Options:
#   --org-name <name>        Gitea org name (default: CUSTOMER_NAME)
#   --repo-name <name>       Initial repo / app name (default: example-repo)
#   --ingress-host <host>    Ingress hostname (default: <org>-<repo>.CLUSTER_EXTERNAL_DOMAIN)
#   --template-branch <br>   Branch of the template repo to clone (default: master)
#   --force-recreate         Delete and re-create the Gitea org/repo if they exist
#
# Env:
#   TALOS_BOOTSTRAPPER_DATA_DIR  (required — set by devcontainer.json)
#
# Requirements: kubectl curl jq git rsync openssl
################################################################################

: "${TALOS_BOOTSTRAPPER_DATA_DIR:?TALOS_BOOTSTRAPPER_DATA_DIR must be set (see .devcontainer/devcontainer.json)}"

# Shared libraries are co-located in devenv/.vscode/tasks/lib/.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/logging.sh"
source "$LIB_DIR/gitea-api.sh"

# Gitea admin secret (same as used by gitea-bootstrap.sh)
readonly GITEA_ADMIN_SECRET="gitea-bootstrap-admin-secret"

# Admin token scopes used during bootstrap
readonly ADMIN_TOKEN_SCOPES='["write:repository","write:organization","write:admin","write:user"]'

# ArgoCD service account that must be a member of every customer org
readonly ARGOCD_SVC_USER="argocd-cluster-services"
readonly ARGOCD_SVC_SECRET="gitea-argocd-cluster-services-credentials"

readonly CI_TEAM_NAME="ci-packages"

# Global for cleanup trap
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
Usage: $(basename "$0") <env-name> <CUSTOMER_NAME> [OPTIONS]

Arguments:
  env-name          Name of the environment under
                    \$TALOS_BOOTSTRAPPER_DATA_DIR/environments/
  CUSTOMER_NAME     Short identifier for the customer (used as default org name)

Options:
  --org-name <name>         Gitea org name        (default: CUSTOMER_NAME)
  --repo-name <name>        Initial repo / app    (default: example-repo)
  --ingress-host <host>     Ingress hostname      (default: <org>-<repo>.CLUSTER_EXTERNAL_DOMAIN)
  --template-branch <br>    Template repo branch  (default: master)
  --force-recreate          Delete and re-create existing Gitea org/repo

Note: namespace is always derived as <orgName>-<repoName>.
Add more repos later with bootstrap-customer-repo.sh.

Examples:
  $(basename "$0") tuborgnetes acme
  $(basename "$0") tuborgnetes acme --repo-name hello-world --force-recreate
  $(basename "$0") tuborgnetes acme --template-branch my-feature
EOF
    exit 1
}

check_dependencies() {
    local missing=()
    for dep in kubectl curl jq git rsync openssl; do
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

    [[ -z "${CLUSTER_NAME:-}"          ]] && { log_error "CLUSTER_NAME not set";          exit 1; }
    [[ -z "${GITEA_DOMAIN_NAME:-}"     ]] && { log_error "GITEA_DOMAIN_NAME not set";     exit 1; }
    [[ -z "${GITEA_NAMESPACE:-}"       ]] && { log_error "GITEA_NAMESPACE not set";       exit 1; }
    [[ -z "${ARGOCD_NAMESPACE:-}"      ]] && { log_error "ARGOCD_NAMESPACE not set";      exit 1; }
    [[ -z "${CLUSTER_EXTERNAL_DOMAIN:-}" ]] && { log_error "CLUSTER_EXTERNAL_DOMAIN not set"; exit 1; }

    log_success "Loaded environment for cluster: $CLUSTER_NAME"
}

################################################################################
# Main
################################################################################

main() {
    [[ $# -lt 2 ]] && usage

    local env_name="$1"
    local env_file="$TALOS_BOOTSTRAPPER_DATA_DIR/environments/$env_name/$env_name.env"
    local customer_name="$2"
    shift 2

    # Defaults
    local org_name="$customer_name"
    local repo_name="example-repo"
    local ingress_host=""
    local template_branch=""
    local force_recreate="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --org-name)        org_name="$2";        shift 2 ;;
            --repo-name)       repo_name="$2";       shift 2 ;;
            --ingress-host)    ingress_host="$2";    shift 2 ;;
            --template-branch) template_branch="$2"; shift 2 ;;
            --force-recreate)  force_recreate="true"; shift ;;
            *) log_error "Unknown argument: $1"; usage ;;
        esac
    done

    # Namespace is always <orgName>-<repoName> — matches the ApplicationSet template
    local namespace="${org_name}-${repo_name}"

    # Kubernetes DNS-1123 label: org is the namespace prefix of every repo
    if [[ ! "$org_name" =~ '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$' ]]; then
        log_error "Org name must be lowercase alphanumerics or '-' (got '$org_name')"
        exit 1
    fi

    # Confirm destructive operation before doing anything else
    if [[ "$force_recreate" == "true" ]]; then
        log_warn "--force-recreate will DELETE and re-create the Gitea org '${org_name}' and repo '${org_name}/${repo_name}'."
        log_warn "All existing repository content and settings will be lost."
        printf "Type the org name to confirm deletion [%s]: " "$org_name"
        local confirm_input
        read -r confirm_input
        if [[ "$confirm_input" != "$org_name" ]]; then
            log_error "Confirmation failed — aborting."
            exit 1
        fi
        log_info "Confirmed. Proceeding with --force-recreate."
    fi

    [[ ! -f "$env_file" ]] && { log_error "Env file not found: $env_file"; exit 1; }

    check_dependencies
    load_env_file "$env_file"

    local overlay_dir
    overlay_dir="$(cd "$(dirname "$env_file")" && pwd)"

    local gitea_api_url="https://${GITEA_DOMAIN_NAME}/api/v1"

    log_info "============================================================"
    log_info "Customer bootstrap"
    log_info "  Customer name     : $customer_name"
    log_info "  Gitea org         : $org_name"
    log_info "  Initial repo      : $repo_name"
    log_info "  Namespace         : $namespace  (derived: <orgName>-<repoName>)"
    log_info "  Gitea API         : $gitea_api_url"
    log_info "============================================================"
    echo ""

    # ------------------------------------------------------------------
    # 1. Gitea admin credentials + temporary token
    # ------------------------------------------------------------------
    log_info "=== Step 1/5: Gitea credentials ==="
    local credentials
    credentials=$(fetch_gitea_admin_credentials) || exit 1
    GITEA_CREDENTIALS="$credentials"
    GITEA_API_URL="$gitea_api_url"

    local token_result
    local token_name="customer-bootstrap-$(date +%s)"
    token_result=$(create_gitea_token "$credentials" "$gitea_api_url" "$token_name" "$ADMIN_TOKEN_SCOPES") || exit 1
    GITEA_TOKEN_ID="${token_result%%|*}"
    local token="${token_result#*|}"
    echo ""

    # ------------------------------------------------------------------
    # 2. Gitea org
    # ------------------------------------------------------------------
    log_info "=== Step 2/5: Gitea organisation ==="
    local org_status
    org_status=$(check_gitea_organization "$org_name" "$gitea_api_url" "$token")

    if [[ "$org_status" == "200" ]]; then
        if [[ "$force_recreate" == "true" ]]; then
            local repo_check
            repo_check=$(check_gitea_repository "$org_name" "$repo_name" "$gitea_api_url" "$token")
            [[ "$repo_check" == "200" ]] && \
                delete_gitea_repository "$org_name" "$repo_name" "$gitea_api_url" "$token"
            delete_gitea_organization "$org_name" "$gitea_api_url" "$token"
            create_gitea_organization "$org_name" "$gitea_api_url" "$token" "$customer_name" || exit 1
        else
            log_success "Org already exists: $org_name"
        fi
    elif [[ "$org_status" == "404" ]]; then
        create_gitea_organization "$org_name" "$gitea_api_url" "$token" "$customer_name" || exit 1
    else
        log_error "Unexpected status checking org: $org_status"; exit 1
    fi

    # Add ArgoCD service account as an org member so it can access customer repos
    add_user_to_org "$org_name" "$ARGOCD_SVC_USER" "$gitea_api_url" "$token" || true

    # Nodes pull this org's images with the central registry-pull token (packages:read only)
    ensure_registry_pull_account "$gitea_api_url" "$token" "$org_name" || exit 1
    echo ""

    # ------------------------------------------------------------------
    # 3. Customer descriptor + ArgoCD AppProject
    # ------------------------------------------------------------------
    log_info "=== Step 3/5: Customer descriptor + ArgoCD AppProject ==="

    # Commit _rendered/customers/<name>/<name>.yaml to the cluster-services repo.
    # The customer-apps ApplicationSet reads from _rendered/customers/ — the same
    # rendered path that render-overlay.sh produces and push-to-gitea.sh pushes.
    local cluster_services_owner="${GITEA_CLUSTER_GITEA_ORG_NAME}"
    local cluster_services_repo="${GITEA_CLUSTER_SERVICES_REPO_NAME}"
    local descriptor_path="_rendered/customers/${customer_name}/${customer_name}.yaml"
    local descriptor_content
    descriptor_content=$(cat <<YAML
customerName: ${customer_name}
gitea:
  orgName: ${org_name}
YAML
)

    # Source copy (customers/) survives re-renders; the _rendered/ copy keeps the
    # next push-to-gitea identical to the API commit below.
    local source_descriptor_file="${overlay_dir}/customers/${customer_name}/${customer_name}.yaml"
    local rendered_descriptor_file="${overlay_dir}/${descriptor_path}"
    local f
    for f in "$source_descriptor_file" "$rendered_descriptor_file"; do
        mkdir -p "$(dirname "$f")"
        printf '%s\n' "$descriptor_content" > "$f"
    done
    log_success "Customer descriptor written: $source_descriptor_file"

    # Also commit it directly to the Gitea cluster-services repo via the API
    # so ArgoCD picks it up immediately without waiting for the next push.
    create_or_update_gitea_file \
        "$cluster_services_owner" \
        "$cluster_services_repo" \
        "$descriptor_path" \
        "$descriptor_content" \
        "feat(customers): add descriptor for customer ${customer_name}" \
        "$gitea_api_url" \
        "$token" || exit 1

    # Create (or update) the ArgoCD AppProject for this customer.
    # - destinations: org-name-* namespace glob (covers all current + future repos)
    # - sourceRepos: only this customer's Gitea org
    # - no cluster-scoped resources allowed
    log_info "Applying ArgoCD AppProject: customer-${customer_name}"
    kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: customer-${customer_name}
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    managed-by: bootstrap-customer
spec:
  description: "ArgoCD project for customer ${customer_name} (org: ${org_name})"
  sourceRepos:
    - "https://${GITEA_DOMAIN_NAME}/${org_name}/*"
  destinations:
    - namespace: "${org_name}-*"
      server: "*"
  clusterResourceWhitelist: []
  namespaceResourceWhitelist:
    - group: "*"
      kind: "*"
EOF
    log_success "AppProject customer-${customer_name} applied"
    echo ""

    # ------------------------------------------------------------------
    # 4. CI service user + org secrets
    # ------------------------------------------------------------------
    log_info "=== Step 4/5: CI service user + org secrets ==="

    # Per-org CI user with packages:write only (no code access). A leaked token
    # can only push images to this org's registry.
    local ci_username="ci-${org_name}"
    local ci_email="ci-${org_name}@cluster.local"
    local ci_password
    ci_password=$(openssl rand -base64 32 | tr -d '+/=' | head -c 40)

    create_or_ensure_gitea_user \
        "$ci_username" "$ci_email" "$ci_password" \
        "$gitea_api_url" "$token" || exit 1

    local ci_team_id
    ci_team_id=$(ensure_gitea_org_team "$org_name" "$CI_TEAM_NAME" "write" '{"repo.packages":"write"}' \
        "$gitea_api_url" "$token") || exit 1
    add_user_to_team "$ci_team_id" "$ci_username" "$gitea_api_url" "$token" || exit 1
    # Earlier versions of this script made the CI user an org owner
    remove_user_from_org_owners "$org_name" "$ci_username" "$gitea_api_url" "$token"

    local pkg_token_value
    pkg_token_value=$(recreate_gitea_user_token "$ci_username" "$ci_password" "ci-package-${org_name}" \
        '["write:package"]' "$gitea_api_url") || exit 1

    # Store credentials as org-level secrets so every repo in this org inherits
    # them automatically — no per-repo wiring needed for future repos.
    # Gitea 1.22+ injects org secrets into workflow contexts; org variables are
    # NOT inherited by repo workflows, so both are stored as secrets.
    #   CI_REGISTRY_TOKEN  — write:package token for docker login
    #   CI_REGISTRY_USER   — username (stored as secret for org-level inheritance)
    set_gitea_org_secret   "$org_name" "CI_REGISTRY_TOKEN" "$pkg_token_value" "$gitea_api_url" "$token" || exit 1
    set_gitea_org_secret   "$org_name" "CI_REGISTRY_USER"  "$ci_username"     "$gitea_api_url" "$token" || exit 1
    echo ""

    # ------------------------------------------------------------------
    # 5. Initial repository (repo, namespace, pull credentials, example app)
    # ------------------------------------------------------------------
    # Runs last: the template push triggers CI, which needs the org secrets above.
    log_info "=== Step 5/5: Initial repository ==="
    local repo_args=(--with-template --customer-name "$customer_name")
    [[ -n "$template_branch" ]] && repo_args+=(--template-branch "$template_branch")
    [[ -n "$ingress_host"    ]] && repo_args+=(--ingress-host "$ingress_host")
    "$SCRIPT_DIR/bootstrap-customer-repo.sh" "$env_name" "$org_name" "$repo_name" "${repo_args[@]}"
    echo ""

    # ------------------------------------------------------------------
    # Done
    # ------------------------------------------------------------------
    log_success "============================================================"
    log_success "Customer '$customer_name' bootstrapped successfully!"
    log_success ""
    log_success "  Customer     : ${customer_name}"
    log_success "  Gitea org    : ${org_name}"
    log_success "  Gitea repo   : https://${GITEA_DOMAIN_NAME}/${org_name}/${repo_name}"
    log_success "  Namespace    : ${namespace}"
    log_success "  AppProject   : customer-${customer_name}  (scoped to ${org_name}-* namespaces)"
    log_success "  Descriptor   : customers/${customer_name}/${customer_name}.yaml  (already live in cluster-services)"
    log_success ""
    log_success "Next steps:"
    log_success "  1. Commit and push customers/${customer_name}/ in the '${env_name}' env repo."
    log_success "     No Apply Overlay needed — the descriptor was committed to cluster-services directly."
    log_success "  2. The 'customer-apps' ApplicationSet will scan org '${org_name}' within"
    log_success "     ~3 minutes and create an Application for each repo with a deploy/ dir."
    log_success "  3. For additional repos, run the 'Bootstrap Customer Repo' task"
    log_success "     (bootstrap-customer-repo.sh ${env_name} ${org_name} <repo>)."
    log_success ""
    log_success "  Offboarding: remove customers/${customer_name}/ and run 'Render and Push to Gitea'"
    log_success "  BEFORE deleting the Gitea org — a descriptor pointing at a missing org"
    log_success "  stops the ApplicationSet for every customer."
    log_success "============================================================"
}

main "$@"
