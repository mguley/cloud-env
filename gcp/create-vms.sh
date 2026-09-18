#!/usr/bin/env bash
# Provision two Ubuntu VMs in one GCP region, with bounded capacity retries.

set -Eeuo pipefail
umask 077
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=gcp/common.sh
source "$REPO_ROOT/gcp/common.sh"

usage() {
    cat <<'EOF'
Usage: bash gcp/create-vms.sh
Export settings from your private gcp/config.env first (see setup_GCE.md).
Required: PROJECT_ID, ADMIN_CIDRS and an existing SSH key pair.
Optional: CLUSTER_NAME, REGION, ZONES, MAX_ATTEMPTS, SUBNET_RANGE,
          CP_INTERNAL_IP, WORKER_INTERNAL_IP, MACHINE_TYPE, DISK_SIZE_GB,
          SSH_USER, SSH_KEY, IMAGE_PROJECT, IMAGE_FAMILY, VM_MAX_RUN_DURATION.
Creates a dedicated network, subnet, four firewall rules and two VMs.
Existing matching resource names cause a stop. No lifetime limit is set by default.
EOF
}

find_zones() {
    local zones_json machines_json zone available_text
    local -a available_zones requested_zones

    zones_json=$(gcloud compute zones list --project="$PROJECT_ID" --format=json)

    machines_json=$(gcloud compute machine-types list --project="$PROJECT_ID" \
        --filter="name=$MACHINE_TYPE" --format=json)

    available_text=$(jq -r --arg region "$REGION" --arg machine "$MACHINE_TYPE" \
        --argjson machines "$machines_json" '
        [$machines[] | select(.name == $machine) | .zone | split("/")[-1]] as $supported |
        [.[] | select(.status == "UP" and (.region | split("/")[-1]) == $region) |
          .name | select(. as $name | $supported | index($name))] | sort | .[]
    ' <<< "$zones_json")

    [[ -n "$available_text" ]] || die "No UP zones in $REGION offer $MACHINE_TYPE."

    mapfile -t available_zones <<< "$available_text"

    CANDIDATE_ZONES=()
    if [[ -n "$ZONES" ]]; then
        IFS=',' read -ra requested_zones <<< "$ZONES"
        for zone in "${requested_zones[@]}"; do
            [[ " ${available_zones[*]} " == *" $zone "* ]] || die "Zone $zone is unavailable or outside $REGION."
            CANDIDATE_ZONES+=("$zone")
        done
    else
        CANDIDATE_ZONES=("${available_zones[@]}")
    fi
}

require_unused_names() {
    local name data

    [[ ! -e "$STATE_FILE" ]] || die "Saved deployment exists at $STATE_FILE. Inspect it and use delete-vms.sh for intentional cleanup."

    data=$(get_resource network "$NETWORK")
    [[ "$data" == null ]] || die "Network $NETWORK already exists; choose another CLUSTER_NAME."

    data=$(get_resource subnet "$SUBNET" "$REGION")
    [[ "$data" == null ]] || die "Subnet $SUBNET already exists."

    for name in "${FIREWALL_RULES[@]}"; do
        data=$(get_resource firewall "$name")
        [[ "$data" == null ]] || die "Firewall rule $name already exists."
    done

    for name in "$CP_VM" "$WORKER_VM"; do
        data=$(get_resource instance "$name")
        [[ "$data" == null ]] || die "VM $name already exists."
    done
}

create_network() {
    gcloud compute networks create "$NETWORK" --project="$PROJECT_ID" \
        --subnet-mode=custom --description="$OWNER"

    gcloud compute networks subnets create "$SUBNET" --project="$PROJECT_ID" \
        --network="$NETWORK" --region="$REGION" --range="$SUBNET_RANGE" --description="$OWNER"

    local -a shared=("--project=$PROJECT_ID" "--network=$NETWORK" --direction=INGRESS --priority=1000 "--description=$OWNER")

    gcloud compute firewall-rules create "${FIREWALL_RULES[0]}" "${shared[@]}" \
        --allow=tcp:22 --source-ranges="$ADMIN_CIDRS" --target-tags="$NODE_TAG"

    gcloud compute firewall-rules create "${FIREWALL_RULES[1]}" "${shared[@]}" \
        --allow=tcp:6443 --source-tags="$NODE_TAG" --target-tags="$CP_TAG"

    gcloud compute firewall-rules create "${FIREWALL_RULES[2]}" "${shared[@]}" \
        --allow=tcp:10250 --source-tags="$CP_TAG" --target-tags="$NODE_TAG"

    gcloud compute firewall-rules create "${FIREWALL_RULES[3]}" "${shared[@]}" \
        --allow=udp:8472,tcp:4240,icmp --source-tags="$NODE_TAG" --target-tags="$NODE_TAG"
}

create_vm() {
    local name=$1 zone=$2 private_ip=$3 role=$4 public_key_type public_key_data
    local -a flags=("--tags=$NODE_TAG")

    [[ "$role" != control-plane ]] || flags=("--tags=$NODE_TAG,$CP_TAG")
    if [[ -n "$VM_MAX_RUN_DURATION" ]]; then
        flags+=("--max-run-duration=$VM_MAX_RUN_DURATION" --instance-termination-action=DELETE)
    fi

    read -r public_key_type public_key_data _ < "$SSH_KEY.pub"
    printf '%s:%s %s %s\n' "$SSH_USER" "$public_key_type" "$public_key_data" "$CLUSTER_NAME" > "$WORK_DIR/ssh-metadata"

    gcloud compute instances create "$name" --project="$PROJECT_ID" --zone="$zone" \
        --machine-type="$MACHINE_TYPE" --network="$NETWORK" --subnet="$SUBNET" \
        --private-network-ip="$private_ip" --can-ip-forward \
        --image-project="$IMAGE_PROJECT" --image-family="$IMAGE_FAMILY" \
        --boot-disk-size="${DISK_SIZE_GB}GB" --boot-disk-type=pd-balanced --boot-disk-auto-delete \
        --no-service-account --no-scopes \
        --metadata=enable-oslogin=FALSE,block-project-ssh-keys=TRUE \
        --metadata-from-file="ssh-keys=$WORK_DIR/ssh-metadata" \
        --labels="managed-by=k8s-bootstrap,cluster=$CLUSTER_NAME,deployment=$DEPLOYMENT_ID,role=$role" \
        "${flags[@]}"
}

print_result() {
    local zone=$1

    gcloud compute instances list --project="$PROJECT_ID" \
        --filter="labels.deployment=$DEPLOYMENT_ID" \
        --format='table(name,zone.basename(),networkInterfaces[0].networkIP,networkInterfaces[0].accessConfigs[0].natIP,status)'

    printf '\nSaved deployment: %s\nSelected zone: %s\n' "$STATE_FILE" "$zone"
    printf 'Next: follow setup_GCE.md to copy the scripts, then README.md to initialize and join the nodes.\n'
}

main() {
    if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; return; fi

    [[ $# == 0 ]] || die 'Unknown argument; use --help.'

    load_settings
    require_tools
    validate_create_settings
    lock_state

    gcloud projects describe "$PROJECT_ID" >/dev/null

    find_zones
    require_unused_names

    DEPLOYMENT_ID=$(python3 -c 'import uuid; print(uuid.uuid4().hex)')

    set_owner

    WORK_DIR=$(mktemp -d "$GCP_STATE_DIR/work.XXXXXX")

    trap 'rm -rf -- "$WORK_DIR"' EXIT
    trap 'rc=$?; printf "Provisioning stopped (exit %s). Inspect %s and the error above. Resources may remain; use the cleanup guide.\n" "$rc" "$STATE_FILE" >&2; exit "$rc"' ERR

    save_state creating
    create_network

    local zone attempt=0 name ip role failed
    for zone in "${CANDIDATE_ZONES[@]}"; do
        (( attempt < MAX_ATTEMPTS )) || break
        attempt=$((attempt + 1))
        save_state creating "$zone"

        log "Attempt $attempt/$MAX_ATTEMPTS: creating both VMs in $zone"
        failed=false

        for role in control-plane worker; do
            if [[ "$role" == control-plane ]]; then name=$CP_VM; ip=$CP_INTERNAL_IP; else name=$WORKER_VM; ip=$WORKER_INTERNAL_IP; fi

            if create_vm "$name" "$zone" "$ip" "$role" > "$WORK_DIR/create.log" 2>&1; then
                cat "$WORK_DIR/create.log"
            else
                cat "$WORK_DIR/create.log" >&2
                if grep -Eq 'ZONE_RESOURCE_POOL_EXHAUSTED|RESOURCE_POOL_EXHAUSTED|does not have enough resources available' "$WORK_DIR/create.log"; then
                    # Only this deployment's VMs in this attempt may be removed.
                    delete_owned instance "$WORKER_VM" "$zone"
                    delete_owned instance "$CP_VM" "$zone"
                    failed=true
                    break
                fi
                die 'Creation failed for a reason other than zone capacity. Inspect the error; no further zones will be tried.'
            fi
        done

        if [[ "$failed" == false ]]; then
            save_state ready "$zone"
            print_result "$zone"
            return
        fi

    done

    save_state capacity-exhausted
    die 'No candidate zone had capacity. The network remains recorded for cleanup. Choose another region after cleanup.'
}

main "$@"
