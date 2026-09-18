#!/usr/bin/env bash
# Preview or delete the exact CloudFormation stack saved for this deployment.

set -Eeuo pipefail
umask 077
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=aws/common.sh
source "$REPO_ROOT/aws/common.sh"

usage() {
    cat <<'EOF'
Usage: bash aws/delete-vms.sh [--yes]
Export the same AWS_EXPECTED_ACCOUNT_ID, AWS_REGION and AWS_CLUSTER_NAME.
Without --yes, verify identity/ownership and print the stack's resource list.
With --yes, delete the saved stack, both VMs and boot disks, network resources
and imported EC2 public key. Cluster data is lost. Local SSH keys remain.
The saved .state/aws/<account>/<region>/<cluster>.json is required.
EOF
}

main() {
    if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; return; fi

    [[ $# == 0 || ($# == 1 && $1 == --yes) ]] || die 'Unknown argument; use --help.'

    local execute=${1:-} data status
    load_settings
    require_tools
    check_account
    lock_state
    load_state

    data=$(get_stack "${STACK_ID:-$STACK_NAME}")
    if [[ "$data" == null ]]; then
        printf 'The saved stack is absent; no cloud resource will be deleted.\n'
        if [[ "$execute" == --yes ]]; then archive_state; else printf 'Re-run with --yes to archive the saved state.\n'; fi
        return
    fi

    verify_stack "$data"

    # Recover a lost create-stack response only after matching the saved UUID.
    STACK_ID=$(jq -r .StackId <<< "$data")
    status=$(jq -r .StackStatus <<< "$data")
    printf 'Account: %s\nRegion: %s\nStack: %s\nStatus: %s\n' "$AWS_EXPECTED_ACCOUNT_ID" "$AWS_REGION" "$STACK_ID" "$status"

    aws_call cloudformation list-stack-resources --stack-name "$STACK_ID" |
        jq -r '.StackResourceSummaries[] | [.LogicalResourceId,.ResourceType,(.PhysicalResourceId // "pending"),.ResourceStatus] | @tsv'

    [[ "$execute" == --yes ]] || { printf '\nPlan only. Re-run with --yes to delete this deployment.\n'; return; }

    [[ "$status" != *_IN_PROGRESS || "$status" == DELETE_IN_PROGRESS ]] || die 'The stack operation is still in progress. Wait for it to finish, then preview cleanup again.'

    # Re-read the exact ID before a destructive operation.
    data=$(get_stack "$STACK_ID")
    [[ "$data" != null ]] || { archive_state; return; }

    verify_stack "$data"

    status=$(jq -r .StackStatus <<< "$data")
    [[ "$status" != *_IN_PROGRESS || "$status" == DELETE_IN_PROGRESS ]] || die 'The stack operation changed; wait before cleanup.'

    update_state deleting "$STACK_ID"
    if [[ "$status" != DELETE_COMPLETE && "$status" != DELETE_IN_PROGRESS ]]; then
        aws_call cloudformation delete-stack --stack-name "$STACK_ID"
    fi

    if [[ "$status" != DELETE_COMPLETE ]]; then
        aws_call cloudformation wait stack-delete-complete --stack-name "$STACK_ID" ||
            die 'Deletion did not finish. Inspect stack events; state was retained so cleanup can be retried.'
    fi

    archive_state
    printf 'Deployment removed. The automation host, local SSH keys and credentials remain available.\n'
}

main "$@"
