#!/usr/bin/env bash
# Remove only the resources belonging to one saved GCP deployment.

set -Eeuo pipefail
umask 077
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=gcp/common.sh
source "$REPO_ROOT/gcp/common.sh"

usage() {
    cat <<'EOF'
Usage: bash gcp/delete-vms.sh [--yes]
Export the same PROJECT_ID and CLUSTER_NAME used for creation.
Without --yes, checks ownership and prints the deletion plan only.
With --yes, deletes both VMs and their boot disks, the four firewall rules,
the subnet and network recorded by this deployment. Cluster data is lost.
The saved .state/<CLUSTER_NAME>.json is required; do not publish it.
EOF
}

main() {
    if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; return; fi

    [[ $# == 0 || ($# == 1 && $1 == --yes) ]] || die 'Unknown argument; use --help.'

    local execute=${1:-} data name
    load_settings
    require_tools
    lock_state

    [[ -f "$STATE_FILE" ]] || die "No saved deployment at $STATE_FILE. Refusing to infer ownership from resource names."

    jq -e --arg project "$PROJECT_ID" --arg cluster "$CLUSTER_NAME" '
        .schema == 1 and .project_id == $project and .cluster_name == $cluster and
        (.deployment_id | test("^[0-9a-f]{32}$")) and
        (.region | type == "string") and (.zone | type == "string")
    ' "$STATE_FILE" >/dev/null || die 'State file does not match this project/cluster or has an unsupported format.'

    DEPLOYMENT_ID=$(jq -r .deployment_id "$STATE_FILE")
    REGION=$(jq -r .region "$STATE_FILE")
    ZONE=$(jq -r .zone "$STATE_FILE")

    set_owner

    printf 'Project: %s\nCluster: %s\nDeployment: %s\n' "$PROJECT_ID" "$CLUSTER_NAME" "$DEPLOYMENT_ID"

    # Precheck the whole set before any mutation, then recheck each deletion.
    if [[ -n "$ZONE" ]]; then
        for name in "$CP_VM" "$WORKER_VM"; do
            data=$(get_resource instance "$name" "$ZONE")
            if [[ "$data" != null ]]; then verify_owner instance "$data"; printf 'VM and boot disk: %s (%s)\n' "$name" "$ZONE"; fi
        done
    fi

    for name in "${FIREWALL_RULES[@]}"; do
        data=$(get_resource firewall "$name")
        if [[ "$data" != null ]]; then verify_owner firewall "$data"; printf 'Firewall: %s\n' "$name"; fi
    done

    data=$(get_resource subnet "$SUBNET" "$REGION")

    if [[ "$data" != null ]]; then verify_owner subnet "$data"; printf 'Subnet: %s (%s)\n' "$SUBNET" "$REGION"; fi

    data=$(get_resource network "$NETWORK")

    if [[ "$data" != null ]]; then verify_owner network "$data"; printf 'Network: %s\n' "$NETWORK"; fi

    [[ "$execute" == --yes ]] || { printf '\nPlan only. Re-run with --yes to delete this deployment.\n'; return; }

    if [[ -n "$ZONE" ]]; then
        delete_owned instance "$WORKER_VM" "$ZONE"
        delete_owned instance "$CP_VM" "$ZONE"
    fi

    for name in "${FIREWALL_RULES[@]}"; do delete_owned firewall "$name"; done

    delete_owned subnet "$SUBNET" "$REGION"
    delete_owned network "$NETWORK"

    mv "$STATE_FILE" "$STATE_FILE.deleted.$(date -u +%Y%m%dT%H%M%SZ)"
    printf 'Deployment removed. SSH keys and the automation host remain available.\n'
}

main "$@"
