#!/usr/bin/env bash
# Shared helpers; use create-vms.sh and delete-vms.sh as entry points.

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*" >&2; }
aws_call() { aws --region "$AWS_REGION" --output json --no-cli-pager "$@"; }

load_settings() {
    AWS_REGION=${AWS_REGION:-us-east-1}
    AWS_EXPECTED_ACCOUNT_ID=${AWS_EXPECTED_ACCOUNT_ID:-}
    AWS_CLUSTER_NAME=${AWS_CLUSTER_NAME:-k8s-cluster}
    AWS_AVAILABILITY_ZONE=${AWS_AVAILABILITY_ZONE:-}
    AWS_INSTANCE_TYPE=${AWS_INSTANCE_TYPE:-t3.medium}
    AWS_ARCH=${AWS_ARCH:-amd64}
    AWS_DISK_SIZE_GB=${AWS_DISK_SIZE_GB:-30}
    AWS_AMI_ID=${AWS_AMI_ID:-}
    AWS_VPC_CIDR=${AWS_VPC_CIDR:-172.20.0.0/16}
    AWS_SUBNET_CIDR=${AWS_SUBNET_CIDR:-172.20.1.0/24}
    AWS_CP_PRIVATE_IP=${AWS_CP_PRIVATE_IP:-172.20.1.10}
    AWS_WORKER_PRIVATE_IP=${AWS_WORKER_PRIVATE_IP:-172.20.1.11}
    AWS_ADMIN_CIDR=${AWS_ADMIN_CIDR:-}
    AWS_SSH_KEY=${AWS_SSH_KEY:-$HOME/.ssh/${AWS_CLUSTER_NAME}_aws_ed25519}
    AWS_CPU_CREDITS=${AWS_CPU_CREDITS:-standard}
    AWS_STATE_DIR=${AWS_STATE_DIR:-$REPO_ROOT/.state/aws}

    [[ "$AWS_EXPECTED_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || die 'Set AWS_EXPECTED_ACCOUNT_ID to your 12-digit AWS account ID.'
    [[ "$AWS_CLUSTER_NAME" =~ ^[a-z]([a-z0-9-]{0,28}[a-z0-9])?$ ]] || die 'AWS_CLUSTER_NAME must be 1-30 lowercase letters/digits/hyphens, starting with a letter and ending with a letter/digit.'
    [[ "$AWS_REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]] || die 'Use an AWS commercial region, for example us-east-1.'

    STACK_NAME=$AWS_CLUSTER_NAME
    STATE_DIRECTORY=$AWS_STATE_DIR/$AWS_EXPECTED_ACCOUNT_ID/$AWS_REGION
    STATE_FILE=$STATE_DIRECTORY/$AWS_CLUSTER_NAME.json
}

require_tools() {
    local name cli_version
    for name in aws jq python3 flock ssh-keygen; do
        command -v "$name" >/dev/null || die "Install $name on the automation host; see setup_EC2.md."
    done

    cli_version=$(aws --version 2>&1)
    [[ "$cli_version" == aws-cli/2.* ]] || die 'Install AWS CLI version 2; see setup_EC2.md.'
}

check_account() {
    local identity
    identity=$(aws_call sts get-caller-identity)
    jq -e --arg account "$AWS_EXPECTED_ACCOUNT_ID" '
        .Account == $account and (.Arn | startswith("arn:aws:"))
    ' <<< "$identity" >/dev/null || die 'AWS identity does not match AWS_EXPECTED_ACCOUNT_ID or the supported commercial partition.'
}

lock_state() {
    mkdir -p "$STATE_DIRECTORY"
    chmod 0700 "$AWS_STATE_DIR" "$STATE_DIRECTORY"
    exec 9> "$STATE_DIRECTORY/$AWS_CLUSTER_NAME.lock"
    flock -n 9 || die "Another operation is using $AWS_CLUSTER_NAME."

    WORK_DIR=$(mktemp -d "$STATE_DIRECTORY/work.XXXXXX")
    trap 'rm -rf -- "$WORK_DIR"' EXIT
}

get_stack() {
    local reference=$1 response rc

    if response=$(aws_call cloudformation describe-stacks --stack-name "$reference" 2> "$WORK_DIR/describe.err"); then
        jq -ce '.Stacks | if length == 1 then .[0] else error("Expected exactly one stack") end' <<< "$response"
    else
        rc=$?
        if grep -Fq '(ValidationError)' "$WORK_DIR/describe.err" &&
           grep -Fq "Stack with id $reference does not exist" "$WORK_DIR/describe.err"; then
            printf 'null\n'
        else
            cat "$WORK_DIR/describe.err" >&2
            return "$rc"
        fi
    fi
}

verify_stack() {
    local data=$1

    jq -e --arg name "$STACK_NAME" --arg deployment "$DEPLOYMENT_ID" \
        --arg id "${STACK_ID:-}" --arg account "$AWS_EXPECTED_ACCOUNT_ID" --arg region "$AWS_REGION" '
        .StackName == $name and
        (.StackId | startswith("arn:aws:cloudformation:" + $region + ":" + $account + ":stack/" + $name + "/")) and
        ($id == "" or .StackId == $id) and
        ((.Tags // [] | map({key:.Key,value:.Value}) | from_entries) as $tags |
          $tags["managed-by"] == "k8s-bootstrap" and $tags.cluster == $name and $tags.deployment == $deployment)
    ' <<< "$data" >/dev/null || die 'Stack identity or ownership does not match the saved deployment. No deletion is allowed.'
}

save_initial_state() {
    jq -n --arg account "$AWS_EXPECTED_ACCOUNT_ID" --arg region "$AWS_REGION" \
        --arg cluster "$AWS_CLUSTER_NAME" --arg deployment "$DEPLOYMENT_ID" \
        --arg zone "$AWS_AVAILABILITY_ZONE" --arg ami "$AWS_AMI_ID" \
        --arg vpc "$AWS_VPC_CIDR" --arg subnet "$AWS_SUBNET_CIDR" \
        --arg cp "$AWS_CP_PRIVATE_IP" --arg worker "$AWS_WORKER_PRIVATE_IP" \
        --arg key "$AWS_SSH_KEY" '
        {schema:1, provider:"aws", account_id:$account, region:$region,
         cluster_name:$cluster, stack_name:$cluster, stack_id:null,
         deployment_id:$deployment, status:"creating", availability_zone:$zone,
         ami_id:$ami, vpc_cidr:$vpc, subnet_cidr:$subnet, cp_private_ip:$cp,
         worker_private_ip:$worker, ssh_user:"ubuntu", ssh_key:$key}
    ' > "$STATE_FILE.tmp"

    chmod 0600 "$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"
}

update_state() {
    local status=$1 stack_id=${2:-}
    jq --arg status "$status" --arg id "$stack_id" '
        .status = $status | if $id != "" then .stack_id = $id else . end
    ' "$STATE_FILE" > "$STATE_FILE.tmp"

    chmod 0600 "$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"
}

load_state() {
    [[ -f "$STATE_FILE" ]] || die "No saved deployment at $STATE_FILE. Refusing to infer ownership from names."
    jq -e --arg account "$AWS_EXPECTED_ACCOUNT_ID" --arg region "$AWS_REGION" --arg name "$STACK_NAME" '
        .schema == 1 and .provider == "aws" and .account_id == $account and
        .region == $region and .cluster_name == $name and .stack_name == $name and
        (.deployment_id | type == "string" and test("^[0-9a-f]{32}$")) and
        (.stack_id == null or (.stack_id | type == "string" and
          startswith("arn:aws:cloudformation:" + $region + ":" + $account + ":stack/" + $name + "/")))
    ' "$STATE_FILE" >/dev/null || die 'Invalid state or account/region/cluster mismatch.'

    DEPLOYMENT_ID=$(jq -r .deployment_id "$STATE_FILE")
    STACK_ID=$(jq -r '.stack_id // ""' "$STATE_FILE")
}

archive_state() {
    mv "$STATE_FILE" "$STATE_FILE.deleted.$(date -u +%Y%m%dT%H%M%SZ)"
}

validate_create_settings() {
    [[ "$AWS_INSTANCE_TYPE" =~ ^[a-z0-9]+\.[a-z0-9]+$ ]] || die 'Invalid AWS_INSTANCE_TYPE.'

    [[ "$AWS_ARCH" == amd64 || "$AWS_ARCH" == arm64 ]] || die 'AWS_ARCH must be amd64 or arm64.'

    [[ "$AWS_DISK_SIZE_GB" =~ ^[1-9][0-9]*$ ]] && (( AWS_DISK_SIZE_GB >= 30 )) || die 'Use at least 30 GiB for AWS_DISK_SIZE_GB.'

    [[ "$AWS_CPU_CREDITS" == standard || "$AWS_CPU_CREDITS" == unlimited ]] || die 'AWS_CPU_CREDITS must be standard or unlimited.'

    [[ -z "$AWS_AMI_ID" || "$AWS_AMI_ID" =~ ^ami-[0-9a-f]{8,17}$ ]] || die 'Invalid AWS_AMI_ID.'

    [[ -f "$AWS_SSH_KEY" && -f "$AWS_SSH_KEY.pub" ]] || die "Create $AWS_SSH_KEY and its .pub file first; see setup_EC2.md."

    local key_type key_data extra
    read -r key_type key_data extra < "$AWS_SSH_KEY.pub"

    [[ "$key_type" == ssh-ed25519 || "$key_type" == ssh-rsa ]] || die 'Use an OpenSSH Ed25519 or RSA public key.'

    ssh-keygen -l -f "$AWS_SSH_KEY.pub" >/dev/null || die 'Invalid SSH public key.'
    PUBLIC_KEY_MATERIAL="$key_type $key_data"

    python3 - "$AWS_VPC_CIDR" "$AWS_SUBNET_CIDR" "$AWS_CP_PRIVATE_IP" "$AWS_WORKER_PRIVATE_IP" "$AWS_ADMIN_CIDR" <<'PY_NETWORK'
import ipaddress as ip
import sys
try:
    vpc, subnet = (ip.IPv4Network(value, strict=True) for value in sys.argv[1:3])
    nodes = [ip.IPv4Address(value) for value in sys.argv[3:5]]
    admin = ip.IPv4Network(sys.argv[5], strict=True)
    private = [ip.IPv4Network(value) for value in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')]
    if not any(vpc.subnet_of(value) for value in private):
        raise ValueError('AWS_VPC_CIDR must be an RFC1918 private range')
    if not (16 <= vpc.prefixlen <= subnet.prefixlen <= 28 and subnet.subnet_of(vpc)):
        raise ValueError('VPC/subnet prefixes must be /16 through /28, with the subnet inside the VPC')
    if len(set(nodes)) != 2:
        raise ValueError('Node private addresses must differ')
    for node in nodes:
        if not int(subnet.network_address) + 4 <= int(node) < int(subnet.broadcast_address):
            raise ValueError(f'{node} is outside the usable AWS subnet addresses (first four and last are reserved)')
    if admin.prefixlen == 0:
        raise ValueError('AWS_ADMIN_CIDR cannot be /0')
except ValueError as exc:
    raise SystemExit('ERROR: ' + str(exc))
PY_NETWORK
}
