#!/usr/bin/env bash
# Shared helpers; use create-vms.sh and delete-vms.sh as entry points.

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*" >&2; }

load_settings() {
    PROJECT_ID=${PROJECT_ID:-}
    CLUSTER_NAME=${CLUSTER_NAME:-k8s-cluster}
    REGION=${REGION:-us-central1}
    ZONES=${ZONES:-}
    MAX_ATTEMPTS=${MAX_ATTEMPTS:-3}
    SUBNET_RANGE=${SUBNET_RANGE:-172.16.0.0/20}
    CP_INTERNAL_IP=${CP_INTERNAL_IP:-172.16.0.2}
    WORKER_INTERNAL_IP=${WORKER_INTERNAL_IP:-172.16.0.3}
    MACHINE_TYPE=${MACHINE_TYPE:-e2-standard-2}
    DISK_SIZE_GB=${DISK_SIZE_GB:-30}
    IMAGE_PROJECT=${IMAGE_PROJECT:-ubuntu-os-cloud}
    IMAGE_FAMILY=${IMAGE_FAMILY:-ubuntu-2404-lts-amd64}
    ADMIN_CIDRS=${ADMIN_CIDRS:-}
    SSH_USER=${SSH_USER:-k8sadmin}
    SSH_KEY=${SSH_KEY:-$HOME/.ssh/${CLUSTER_NAME}_ed25519}
    VM_MAX_RUN_DURATION=${VM_MAX_RUN_DURATION:-}
    GCP_STATE_DIR=${GCP_STATE_DIR:-$REPO_ROOT/.state}

    [[ "$PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ && "$PROJECT_ID" != your-project-id ]] || die 'Set PROJECT_ID to an existing Google Cloud project ID.'
    [[ "$CLUSTER_NAME" =~ ^[a-z]([a-z0-9-]{0,28}[a-z0-9])?$ ]] || die 'CLUSTER_NAME must be 1-30 lowercase letters/digits/hyphens, starting with a letter and ending with a letter/digit.'
    [[ "$REGION" =~ ^[a-z]+(-[a-z]+)+[0-9]+$ ]] || die 'Invalid REGION.'

    NETWORK=${CLUSTER_NAME}-network
    SUBNET=${CLUSTER_NAME}-subnet
    CP_VM=${CLUSTER_NAME}-cp
    WORKER_VM=${CLUSTER_NAME}-worker
    NODE_TAG=${CLUSTER_NAME}-node
    CP_TAG=${CLUSTER_NAME}-control-plane
    FIREWALL_RULES=("${CLUSTER_NAME}-ssh" "${CLUSTER_NAME}-api" "${CLUSTER_NAME}-kubelet" "${CLUSTER_NAME}-cilium")
    STATE_FILE=$GCP_STATE_DIR/$CLUSTER_NAME.json
}

require_tools() {
    local command_name
    for command_name in gcloud jq python3 flock; do
        command -v "$command_name" >/dev/null || die "Install $command_name on the automation host; see setup_GCE.md."
    done
}

lock_state() {
    mkdir -p "$GCP_STATE_DIR"
    chmod 0700 "$GCP_STATE_DIR"
    exec 9> "$GCP_STATE_DIR/$CLUSTER_NAME.lock"
    flock -n 9 || die "Another operation is using $CLUSTER_NAME."
}

set_owner() {
    OWNER="Managed by k8s-bootstrap; cluster=$CLUSTER_NAME; deployment=$DEPLOYMENT_ID"
}

# A successful empty list means absent. Authentication/API/list errors propagate.
# Exact matching after server-side filtering avoids deleting similarly named items.
get_resource() {
    local kind=$1 name=$2 location=${3:-} data
    local -a resource_command

    case "$kind" in
        network) resource_command=(networks) ;;
        subnet) resource_command=(networks subnets) ;;
        firewall) resource_command=(firewall-rules) ;;
        instance) resource_command=(instances) ;;
        *) die "Unknown resource kind: $kind" ;;
    esac

    data=$(gcloud compute "${resource_command[@]}" list --project="$PROJECT_ID" \
        --format=json) || return
    jq -ce --arg name "$name" --arg location "$location" '
        map(select(.name == $name and ($location == "" or
            ((.zone // .region // "") | split("/")[-1]) == $location))) |
        if length == 0 then null elif length == 1 then .[0]
        else error("More than one matching resource; specify its location") end
    ' <<< "$data" || {
        # jq -e returns 1 for the deliberately emitted null; other errors fail.
        local rc=$?
        [[ $rc == 1 ]] || return "$rc"
    }
}

verify_owner() {
    local kind=$1 data=$2

    if [[ "$kind" == instance ]]; then
        jq -e --arg cluster "$CLUSTER_NAME" --arg deployment "$DEPLOYMENT_ID" '
            .labels["managed-by"] == "k8s-bootstrap" and
            .labels.cluster == $cluster and .labels.deployment == $deployment
        ' <<< "$data" >/dev/null || die 'Instance ownership does not match the saved deployment. No deletion of this instance is allowed.'
    else
        jq -e --arg owner "$OWNER" '.description == $owner' <<< "$data" >/dev/null \
            || die "$kind ownership does not match the saved deployment. No deletion of this resource is allowed."
    fi
}

delete_owned() {
    local kind=$1 name=$2 location=${3:-} data
    local -a command_args

    data=$(get_resource "$kind" "$name" "$location") || return

    [[ "$data" != null ]] || return 0

    verify_owner "$kind" "$data"

    case "$kind" in
        instance) command_args=(instances delete "$name" "--zone=$location") ;;
        firewall) command_args=(firewall-rules delete "$name") ;;
        subnet) command_args=(networks subnets delete "$name" "--region=$location") ;;
        network) command_args=(networks delete "$name") ;;
    esac

    log "Deleting $kind $name ${location:+in $location}"
    gcloud compute "${command_args[@]}" --project="$PROJECT_ID" --quiet
}

save_state() {
    local status=$1 zone=${2:-}

    jq -n --arg project "$PROJECT_ID" --arg cluster "$CLUSTER_NAME" \
        --arg deployment "$DEPLOYMENT_ID" --arg region "$REGION" --arg zone "$zone" \
        --arg status "$status" --arg subnet "$SUBNET_RANGE" \
        --arg cp_ip "$CP_INTERNAL_IP" --arg worker_ip "$WORKER_INTERNAL_IP" \
        --arg ssh_user "$SSH_USER" --arg ssh_key "$SSH_KEY" \
        '{schema:1, project_id:$project, cluster_name:$cluster, deployment_id:$deployment,
          region:$region, zone:$zone, status:$status, subnet_range:$subnet,
          cp_internal_ip:$cp_ip, worker_internal_ip:$worker_ip,
          ssh_user:$ssh_user, ssh_key:$ssh_key}' > "$STATE_FILE.tmp"

    chmod 0600 "$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"
}

validate_create_settings() {
    [[ "$MAX_ATTEMPTS" =~ ^[1-9][0-9]?$ ]] || die 'MAX_ATTEMPTS must be 1-99.'

    [[ "$DISK_SIZE_GB" =~ ^[1-9][0-9]*$ ]] && (( DISK_SIZE_GB >= 30 )) || die 'Use a boot disk of at least 30 GB.'

    [[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$SSH_USER" != root ]] || die 'SSH_USER must be a non-root Linux username.'

    [[ -f "$SSH_KEY" && -f "$SSH_KEY.pub" ]] || die "Create the SSH key pair $SSH_KEY first; see setup_GCE.md."

    [[ "$MACHINE_TYPE" =~ ^[a-z][a-z0-9-]+$ ]] || die 'Invalid MACHINE_TYPE.'

    [[ "$IMAGE_PROJECT" =~ ^[a-z][a-z0-9-]+$ && "$IMAGE_FAMILY" =~ ^ubuntu-2404-lts-(amd64|arm64)$ ]] || die 'Use an Ubuntu 24.04 image family matching your machine architecture.'

    if [[ -n "$VM_MAX_RUN_DURATION" ]]; then
        [[ "$VM_MAX_RUN_DURATION" =~ ^([1-9][0-9]*h)?([1-9][0-9]*m)?([1-9][0-9]*s)?$ ]] || die 'VM_MAX_RUN_DURATION must use h/m/s, for example 6h or 2h30m.'
    fi

    python3 - "$SUBNET_RANGE" "$CP_INTERNAL_IP" "$WORKER_INTERNAL_IP" "$ADMIN_CIDRS" <<'PY_NETWORK'
import ipaddress as ip
import sys
try:
    subnet = ip.IPv4Network(sys.argv[1], strict=True)
    nodes = [ip.IPv4Address(value) for value in sys.argv[2:4]]
    admins = [ip.IPv4Network(value.strip(), strict=True) for value in sys.argv[4].split(',') if value.strip()]
    private = [ip.IPv4Network(value) for value in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')]
    if not any(subnet.subnet_of(value) for value in private):
        raise ValueError('SUBNET_RANGE must be an RFC1918 private IPv4 range')
    if len(set(nodes)) != 2:
        raise ValueError('The control-plane and worker addresses must differ')
    for node in nodes:
        # GCP reserves the first two and last two addresses of the primary range.
        if not int(subnet.network_address) + 2 <= int(node) <= int(subnet.broadcast_address) - 2:
            raise ValueError(f'{node} is outside the usable GCP subnet addresses')
    if not admins or any(value.prefixlen == 0 for value in admins):
        raise ValueError('Set ADMIN_CIDRS to the trusted SSH source CIDR(s); a /0 is not accepted')
except ValueError as exc:
    raise SystemExit('ERROR: ' + str(exc))
PY_NETWORK
}
