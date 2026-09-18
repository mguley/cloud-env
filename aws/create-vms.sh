#!/usr/bin/env bash
# Create two Ubuntu EC2 instances and their dedicated network in one stack.

set -Eeuo pipefail
umask 077
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=aws/common.sh
source "$REPO_ROOT/aws/common.sh"

usage() {
    cat <<'EOF'
Usage: bash aws/create-vms.sh
Export aws/config.env first; see setup_EC2.md.
Required: AWS_EXPECTED_ACCOUNT_ID, AWS_ADMIN_CIDR, existing SSH key pair.
Creates one CloudFormation stack with two EC2 instances and a dedicated VPC.
Stops on existing state/stack/key names; never replaces an existing deployment.
No automatic expiration or capacity retry. Uses the same node scripts as GCP.
EOF
}

discover_compute() {
    local arch data zones offerings available root_size
    if [[ "$AWS_ARCH" == amd64 ]]; then arch=x86_64; else arch=arm64; fi

    data=$(aws_call ec2 describe-instance-types --instance-types "$AWS_INSTANCE_TYPE")
    jq -e --arg arch "$arch" '
        .InstanceTypes | length == 1 and (.[0] |
        .VCpuInfo.DefaultVCpus >= 2 and .MemoryInfo.SizeInMiB >= 4096 and
        (.ProcessorInfo.SupportedArchitectures | index($arch) != null))
    ' <<< "$data" >/dev/null || die 'Instance type must support the selected architecture, at least 2 vCPUs and 4 GiB RAM.'

    zones=$(aws_call ec2 describe-availability-zones --filters Name=state,Values=available Name=zone-type,Values=availability-zone)
    offerings=$(aws_call ec2 describe-instance-type-offerings --location-type availability-zone --filters "Name=instance-type,Values=$AWS_INSTANCE_TYPE")
    available=$(jq -r --argjson offerings "$offerings" '
        [$offerings.InstanceTypeOfferings[].Location] as $supported |
        [.AvailabilityZones[] | select(.State == "available" and .ZoneType == "availability-zone") |
         .ZoneName | select(. as $zone | $supported | index($zone))] | sort | .[]
    ' <<< "$zones")

    [[ -n "$available" ]] || die 'No available standard AZ offers this instance type in the selected region.'

    if [[ -n "$AWS_AVAILABILITY_ZONE" ]]; then
        grep -Fxq -- "$AWS_AVAILABILITY_ZONE" <<< "$available" || die 'AWS_AVAILABILITY_ZONE is unavailable or does not offer this instance type.'
    else
        AWS_AVAILABILITY_ZONE=${available%%$'\n'*}
    fi

    local -a image_args=(--owners 099720109477 --filters
        "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-$AWS_ARCH-server-*"
        "Name=architecture,Values=$arch" Name=state,Values=available
        Name=root-device-type,Values=ebs Name=virtualization-type,Values=hvm)

    [[ -z "$AWS_AMI_ID" ]] || image_args+=(--image-ids "$AWS_AMI_ID")

    data=$(aws_call ec2 describe-images "${image_args[@]}")
    AMI=$(jq -ce --arg arch "$arch" --arg name "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-$AWS_ARCH-server-" '
        [.Images[] | select(.OwnerId == "099720109477" and .State == "available" and
         .Architecture == $arch and .RootDeviceType == "ebs" and .VirtualizationType == "hvm" and
         (.Name | startswith($name)))] | sort_by(.CreationDate) | last // empty
    ' <<< "$data") || die 'No matching official Ubuntu Server 24.04 LTS AMI; check region, architecture and AWS_AMI_ID.'

    AWS_AMI_ID=$(jq -r .ImageId <<< "$AMI")
    ROOT_DEVICE=$(jq -er .RootDeviceName <<< "$AMI")
    root_size=$(jq -er --arg root "$ROOT_DEVICE" '.BlockDeviceMappings[] | select(.DeviceName == $root) | .Ebs.VolumeSize' <<< "$AMI")
    (( AWS_DISK_SIZE_GB >= root_size )) || die 'AWS_DISK_SIZE_GB is smaller than the AMI root volume.'
}

write_parameters() {
    local credits=false

    [[ "$AWS_INSTANCE_TYPE" =~ ^(t2|t3|t3a|t4g)\. ]] && credits=true

    jq -n --arg ClusterName "$AWS_CLUSTER_NAME" --arg DeploymentId "$DEPLOYMENT_ID" \
        --arg VpcCidr "$AWS_VPC_CIDR" --arg SubnetCidr "$AWS_SUBNET_CIDR" \
        --arg AvailabilityZone "$AWS_AVAILABILITY_ZONE" --arg AmiId "$AWS_AMI_ID" \
        --arg InstanceType "$AWS_INSTANCE_TYPE" --arg RootDeviceName "$ROOT_DEVICE" \
        --arg DiskSize "$AWS_DISK_SIZE_GB" --arg ControlPlaneIP "$AWS_CP_PRIVATE_IP" \
        --arg WorkerIP "$AWS_WORKER_PRIVATE_IP" --arg AdminCidr "$AWS_ADMIN_CIDR" \
        --arg PublicKeyMaterial "$PUBLIC_KEY_MATERIAL" --arg CpuCredits "$AWS_CPU_CREDITS" \
        --arg UseCpuCredits "$credits" '
        $ARGS.named | to_entries | map({ParameterKey:.key, ParameterValue:.value})
    ' > "$WORK_DIR/parameters.json"

    jq -n --arg cluster "$AWS_CLUSTER_NAME" --arg deployment "$DEPLOYMENT_ID" '
        [{Key:"managed-by",Value:"k8s-bootstrap"},{Key:"cluster",Value:$cluster},{Key:"deployment",Value:$deployment}]
    ' > "$WORK_DIR/tags.json"
}

main() {
    if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; return; fi

    [[ $# == 0 ]] || die 'Unknown argument; use --help.'

    load_settings
    require_tools
    validate_create_settings
    check_account
    lock_state

    [[ ! -e "$STATE_FILE" ]] || die "Saved deployment exists at $STATE_FILE. Inspect it and use delete-vms.sh for cleanup."

    local data result status
    data=$(get_stack "$STACK_NAME")
    [[ "$data" == null ]] || die 'Stack name already exists. Choose another AWS_CLUSTER_NAME.'

    data=$(aws_call ec2 describe-key-pairs --filters "Name=key-name,Values=$AWS_CLUSTER_NAME-ssh")
    jq -e '.KeyPairs | length == 0' <<< "$data" >/dev/null || die 'EC2 key pair name already exists. Choose another AWS_CLUSTER_NAME.'

    discover_compute

    aws_call cloudformation validate-template --template-body "file://$REPO_ROOT/aws/stack.json" >/dev/null
    DEPLOYMENT_ID=$(python3 -c 'import uuid; print(uuid.uuid4().hex)')

    write_parameters
    save_initial_state

    trap 'rc=$?; printf "Provisioning stopped (exit %s). State: %s. Inspect CloudFormation events and setup_EC2.md before cleanup.\n" "$rc" "$STATE_FILE" >&2; exit "$rc"' ERR

    log "Creating $STACK_NAME in $AWS_REGION/$AWS_AVAILABILITY_ZONE using $AWS_AMI_ID"
    result=$(aws_call cloudformation create-stack --stack-name "$STACK_NAME" \
        --template-body "file://$REPO_ROOT/aws/stack.json" \
        --parameters "file://$WORK_DIR/parameters.json" --tags "file://$WORK_DIR/tags.json" \
        --client-request-token "$DEPLOYMENT_ID" --timeout-in-minutes 30)

    STACK_ID=$(jq -er .StackId <<< "$result")

    update_state creating "$STACK_ID"

    if ! aws_call cloudformation wait stack-create-complete --stack-name "$STACK_ID"; then
        data=$(get_stack "$STACK_ID")
        [[ "$data" != null ]] || die 'The submitted stack is no longer present. Inspect state before cleanup.'

        verify_stack "$data"
        status=$(jq -r .StackStatus <<< "$data")

        update_state "$status" "$STACK_ID"

        aws_call cloudformation describe-stack-events --stack-name "$STACK_ID" |
            jq -r '.StackEvents[] | select(.ResourceStatus | endswith("FAILED")) | [.LogicalResourceId,.ResourceStatus,.ResourceStatusReason] | @tsv' >&2
        die "Stack status is $status. Follow the failure/cleanup section of setup_EC2.md; no other deployment was selected."
    fi

    data=$(get_stack "$STACK_ID")
    verify_stack "$data"

    [[ $(jq -r .StackStatus <<< "$data") == CREATE_COMPLETE ]] || die 'Unexpected stack status after waiter.'

    update_state ready "$STACK_ID"

    printf '\n'
    jq -r '.Outputs[] | [.OutputKey,.OutputValue] | @tsv' <<< "$data"
    printf '\nSaved deployment: %s\n' "$STATE_FILE"
    printf 'Next: follow setup_EC2.md to connect and copy scripts, then README.md to initialize and join the nodes.\n'
}

main "$@"
