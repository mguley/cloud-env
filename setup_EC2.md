#### AWS automation host and EC2 provisioning

Use a separate **Ubuntu Server 24.04 LTS automation host**. It can be the same `AWS EC2` automation host you use for `GCP`,
or another machine with `AWS API` access and `SSH` access to the new instances. The automation host does not join Kubernetes.

This guide creates one `control plane` EC2 instance and one `worker` EC2 instance in a dedicated VPC. 

Then use [README.md](README.md) and the existing `k8scp.sh` / `k8sWorker.sh` to install Kubernetes 1.36.4. This is self-managed Kubernetes, not Amazon EKS.

Run `AWS CLI`, provisioning scripts and SSH as your normal `automation host` user. Use `sudo` only for host package installation and, later, the node bootstrap scripts.

Keep all commands in this guide on the `automation host` unless a step explicitly says otherwise.

#### 1. Prepare the automation host

```bash
sudo cloud-init status --wait
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y ca-certificates curl unzip jq python3 git openssh-client util-linux
if [ -f /var/run/reboot-required ]; then sudo reboot; fi
```

Reconnect after a reboot. If `aws --version` already reports `aws-cli/2`, use that installation. 

Otherwise install the official AWS CLI v2 Linux distribution for your host architecture:

```bash
(
  set -euo pipefail
  
  case "$(uname -m)" in
    x86_64) aws_cli_arch=x86_64 ;;
    aarch64) aws_cli_arch=aarch64 ;;
    *) echo 'Unsupported automation-host architecture' >&2; exit 1 ;;
  esac
  
  aws_cli_dir=$(mktemp -d)
  
  trap 'rm -rf -- "$aws_cli_dir"' EXIT
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${aws_cli_arch}.zip" -o "$aws_cli_dir/awscliv2.zip"
  unzip -q "$aws_cli_dir/awscliv2.zip" -d "$aws_cli_dir"
  
  if [ -d /usr/local/aws-cli ]; then
    sudo "$aws_cli_dir/aws/install" --update
  else
    sudo "$aws_cli_dir/aws/install"
  fi
)
  
hash -r
aws --version
```

The temporary extraction directory keeps the installer's `aws/` directory separate from this repository's `aws/` directory.
For signature verification or an existing installation in another location, follow the [official AWS CLI installation guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html).

#### 2. Authenticate and verify your account

The `automation host` needs `AWS credentials` with permission to create the `CloudFormation stack` and the `EC2/network resources` used by this deployment.

Choose **one** of the authentication methods below.

##### Option A: EC2 instance IAM role - recommended when the automation host is an EC2 instance

If the `automation host` itself is an `EC2` instance, attach an `IAM role` to it. `AWS CLI` will automatically retrieve temporary credentials for the role from EC2 instance metadata. 
No access keys need to be created or copied to the automation host or Kubernetes nodes.

If the `automation host` does not already have a suitable `IAM role`:

1. In the AWS console, open: **EC2 → Instances → select the automation host → Actions → Security → Modify IAM role**
2. Choose **Create new IAM role**
3. In IAM, create a role with:
    - **Trusted entity type:** `AWS service`
    - **Service or use case:** `EC2`
4. Attach permissions required by this deployment.
    For a simple initial setup, the AWS-managed policies can be used:
     - `AmazonEC2FullAccess`
     - `AWSCloudFormationFullAccess`
     - `AmazonSSMFullAccess`
5. Give the role a descriptive name, for example: `k8s-automation-host-role`
6. Create the role
7. Return to: **EC2 → Instances → automation host → Actions → Security → Modify IAM role**. Select the newly created role and choose `Update IAM role`. No reboot is required.

Make sure environment variables or AWS profiles do not override the EC2 instance role:

```bash
unset AWS_PROFILE AWS_DEFAULT_PROFILE
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```

Verify the active identity:
```bash
aws sts get-caller-identity --region us-east-1 --output json --no-cli-pager
```

A successful response should look similar to:
```json
{
    "UserId": "AROAXXXXXXXXXXXXX:i-0123456789abcdef0",
    "Account": "123456789012",
    "Arn": "arn:aws:sts::123456789012:assumed-role/k8s-automation-host-role/i-0123456789abcdef0"
}
```

Confirm that:
- `Account` is the AWS account where the Kubernetes infrastructure should be created.
- `Arn` shows the expected automation host IAM role.

When using the `EC2 instance role`, do not set `AWS_PROFILE` in the deployment configuration.

##### Option B: IAM Identity Center / SSO

If your organization provides `AWS IAM Identity Center` instead of an `EC2 instance role`, configure a named AWS CLI `profile`:

```bash
aws configure sso --profile k8s-admin --use-device-code --no-browser
```

When prompted, provide:
- `SSO session name`: any descriptive local name, for example `company-sso`
- `SSO start URL`: the actual IAM Identity Center access portal URL provided by your organization
- `SSO region`: the AWS region where IAM Identity Center is configured
- `SSO registration scopes`: press Enter to accept `sso:account:access`

Because the `automation host` has no browser, AWS CLI will display a device authorization `URL` and `code`. Open that URL on another computer with a browser,
enter the code, authenticate, and select the appropriate AWS account and role.

Then:
```bash
export AWS_PROFILE=k8s-admin
```

For subsequent sign-ins:

```bash
aws sso login --profile k8s-admin --use-device-code --no-browser
```

See [AWS CLI Identity Center authentication](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html).

Check the identity you intend to use:

```bash
aws sts get-caller-identity --region us-east-1 --output json --no-cli-pager
```

Copy the expected 12-digit account ID into `AWS_EXPECTED_ACCOUNT_ID` in the next step. Every provisioning and cleanup operation verifies that account.
`AWS_REGION` is passed explicitly to every API call.

#### Required access

The scripts use **AWS CloudFormation through AWS CLI v2** to manage the network and instances together. 

The active identity needs:

- CloudFormation `ValidateTemplate`, `CreateStack`, `DescribeStacks`, `DescribeStackEvents`, `ListStackResources` and `DeleteStack` for the intended stack.
- EC2 `describe` access for images, instance types, offerings, availability zones, key pairs and the provisioned resources.
- EC2 permissions to create, tag, configure and remove the VPC, subnet, internet gateway, routes, security groups, imported key pair, instances, network interfaces and boot volumes in [aws/stack.json](aws/stack.json). 
  This includes ingress/egress rules, instance attributes, CPU credit settings and tags.
- Access to the EBS encryption key if your account requires a customer-managed default KMS key.

The template creates no IAM resources, passes no instance role, and imports only your public SSH key. 

No CloudFormation service role is supplied, so CloudFormation uses the caller's permissions. [CloudFormation access control](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/control-access-with-iam.html)

#### 3. Configure this deployment

Copy or extract the repository onto the `automation host`. Change into the directory containing `README.md`, `setup_EC2.md`, `aws/` and `gcp/`.

```bash
cp aws/config.env.example aws/config.env
chmod 0600 aws/config.env
```

Edit `aws/config.env` and set:

- `AWS_EXPECTED_ACCOUNT_ID`: your actual 12-digit account ID.
- `AWS_ADMIN_CIDR`: one trusted SSH source IPv4 CIDR. Normally use the automation host's public egress address followed by `/32`; if it uses NAT, use the NAT egress address.
- `AWS_REGION`: AWS region for this deployment 
- `AWS_PROFILE`: leave empty when using the EC2 instance IAM role. Set it only when using a named AWS CLI `profile` such as the IAM Identity Center profile configured above.
- `AWS_CLUSTER_NAME` and the remaining settings below.

The new VPC has no peering with the automation host's VPC. 
This workflow connects to the new instances' **public addresses**, even when the automation host is also in AWS. 

Its outbound policy must allow HTTPS to AWS/download endpoints and SSH to those instances.

Export the configuration:

```bash
set -a
source aws/config.env
set +a
```

Only source a file you control. Re-export after edits and in each new shell. AWS settings use an `AWS_` prefix and a separate state directory so `GCP` settings can coexist on the same host.

| Setting | Default | Meaning |
| --- | --- | --- |
| `AWS_REGION` | `us-east-1` | Explicit region for this deployment |
| `AWS_CLUSTER_NAME` | `k8s-cluster` | Unique stack name and resource name prefix in the account/region |
| `AWS_AVAILABILITY_ZONE` | Empty | Select the first available standard AZ offering the instance type |
| `AWS_INSTANCE_TYPE` | `t3.medium` | 2 vCPUs and 4 GiB RAM; both nodes use the same type |
| `AWS_ARCH` | `amd64` | Use `arm64` with a compatible instance type, for example `t4g.medium` |
| `AWS_DISK_SIZE_GB` | `30` | Encrypted gp3 root volume size in GiB per node |
| `AWS_AMI_ID` | Empty | Discover the newest official Canonical Ubuntu Server 24.04 LTS AMI for the selected region/architecture |
| `AWS_VPC_CIDR` | `172.20.0.0/16` | Dedicated VPC range; pass this as `UNDERLAY_CIDRS` to both node scripts |
| `AWS_SUBNET_CIDR` | `172.20.1.0/24` | Public subnet containing both nodes in one AZ |
| `AWS_CP_PRIVATE_IP` | `172.20.1.10` | Stable control plane private IPv4 address |
| `AWS_WORKER_PRIVATE_IP` | `172.20.1.11` | Stable worker private IPv4 address |
| `AWS_SSH_KEY` | `$HOME/.ssh/${AWS_CLUSTER_NAME}_aws_ed25519` | Local key pair; only its public part is imported into EC2 |
| `AWS_CPU_CREDITS` | `standard` | Applied to T2/T3/T3a/T4g only |

AWS reserves the first four and last addresses of each IPv4 subnet. The GCP defaults ending in `.2` and `.3` are unsuitable for the equivalent AWS subnet. 
The scripts validate both node addresses. [AWS subnet sizing](https://docs.aws.amazon.com/vpc/latest/userguide/subnet-sizing.html)

The AMI lookup checks Canonical's public owner ID `099720109477`, the Ubuntu 24.04 server name, architecture and EBS backing. It excludes Minimal/Pro variants. 
The selected AMI is saved in local state; set `AWS_AMI_ID` to that ID for a repeatable image selection later. [Canonical's AWS image guide](https://ubuntu.com/aws/docs/aws-how-to/instances/find-ubuntu-images/)

#### 4. Create an SSH key pair

Create the configured key if it does not already exist:

```bash
mkdir -p "$(dirname -- "$AWS_SSH_KEY")"
chmod 0700 "$(dirname -- "$AWS_SSH_KEY")"

if [ ! -e "$AWS_SSH_KEY" ] && [ ! -e "$AWS_SSH_KEY.pub" ]; then
  ssh-keygen -t ed25519 -f "$AWS_SSH_KEY" -C "${AWS_CLUSTER_NAME}-aws"
fi

ssh-keygen -lf "$AWS_SSH_KEY.pub"
chmod 0600 "$AWS_SSH_KEY"
```

You can use a passphrase and an SSH agent. 

```bash
eval "$(ssh-agent -s)"
ssh-add "$AWS_SSH_KEY"
```

Keep the private key on the automation host; the template imports the `.pub` content into a dedicated EC2 key pair named `${AWS_CLUSTER_NAME}-ssh`.
Existing stack or key-pair names cause creation to stop. [CloudFormation key-pair import](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-keypair.html)

The instance SSH username is **ubuntu**, as provided by the official Ubuntu image.

#### 5. Provision the two instances

```bash
bash aws/create-vms.sh
```

The script checks account identity, input ranges, SSH key format, image ownership, instance architecture/capacity specifications and template syntax before submitting the stack. 
It does not guarantee AZ capacity. 

`CloudFormation` then creates:

- One VPC, one subnet, an internet gateway, route table and internet route.
- Two security groups and six ingress rules: SSH from `AWS_ADMIN_CIDR`; API TCP/6443 to the control plane from nodes; kubelet TCP/10250 from the control plane;
  VXLAN UDP/8472, health TCP/4240 and ICMP between nodes.
- One imported public SSH key and two On-Demand instances with public IPv4 addresses, IMDSv2 required, and encrypted gp3 root disks.

Outbound IPv4 traffic is allowed. Kubernetes API and `NodePort` ports `are not` publicly opened. 
Cilium uses VXLAN and masquerading; this configuration does not require VPC Pod routes, ENI IPAM or disabling EC2 source/destination checking. 

Use `kubectl` through SSH on the control plane.

`CloudFormation` rolls back newly created stack resources when creation fails. It does not roll back unrelated deployments. 
There is no automatic cross-AZ retry and no default instance lifetime limit. EC2, EBS, public IPv4 and applicable traffic incur normal charges. 

A stopped VM still retains its disk; use the cleanup step when finished. [Public IPv4 behavior](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-properties-ec2-instance-networkinterface.html#cfn-ec2-instance-networkinterface-associatepublicipaddress)

The script prints the outputs and saves the stack ARN, deployment UUID, account, region, selected AMI, zone, private IPs and SSH key path in:

```text
.state/aws/<account-id>/<region>/<cluster-name>.json
```

Keep this file private and backed up. It is required for automated cleanup. If provisioning is interrupted, do not remove the state file and blindly rerun creation; see recovery below.

#### 6. Retrieve addresses and copy the node scripts

After creation completes:

```bash
AWS_DEPLOYMENT_STATE=".state/aws/$AWS_EXPECTED_ACCOUNT_ID/$AWS_REGION/$AWS_CLUSTER_NAME.json"
AWS_STACK_ID=$(jq -er '.stack_id' "$AWS_DEPLOYMENT_STATE")
AWS_STACK_JSON=$(aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$AWS_STACK_ID" --output json --no-cli-pager)
  
CP_PUBLIC_IP=$(jq -er '.Stacks[0].Outputs[] | select(.OutputKey == "ControlPlanePublicIP") | .OutputValue' <<< "$AWS_STACK_JSON")
WORKER_PUBLIC_IP=$(jq -er '.Stacks[0].Outputs[] | select(.OutputKey == "WorkerPublicIP") | .OutputValue' <<< "$AWS_STACK_JSON")

printf 'Control plane: %s\nWorker: %s\n' "$CP_PUBLIC_IP" "$WORKER_PUBLIC_IP"
```

If you override `AWS_STATE_DIR`, adjust `AWS_DEPLOYMENT_STATE` accordingly. Allow initial boot to finish. 

Verify SSH host fingerprints on first connection using a trusted channel, such as the EC2 console's instance system log, then connect normally:

```bash
# `cp` VM
ssh -i "$AWS_SSH_KEY" "ubuntu@$CP_PUBLIC_IP"

# `worker` VM
ssh -i "$AWS_SSH_KEY" "ubuntu@$WORKER_PUBLIC_IP"
```

Exit back to the `automation host` after checking the connection. Copy one script to each node:

```bash
scp -i "$AWS_SSH_KEY" k8scp.sh "ubuntu@$CP_PUBLIC_IP:~/k8scp.sh"
scp -i "$AWS_SSH_KEY" k8sWorker.sh "ubuntu@$WORKER_PUBLIC_IP:~/k8sWorker.sh"
```

On **each node**, perform the update/reboot prerequisites in [README.md](README.md#node-prerequisites), then use the README's AWS bootstrap commands. For this template's defaults:

| Bootstrap setting | Control plane | Worker |
| --- | --- | --- |
| `NODE_IP` | `172.20.1.10` | `172.20.1.11` |
| `CONTROL_PLANE_IP` | Inferred from `NODE_IP` | `172.20.1.10` |
| `UNDERLAY_CIDRS` | `172.20.0.0/16` | `172.20.0.0/16` |
| `POD_CIDR` | `192.168.0.0/16` | `192.168.0.0/16` |
| `SERVICE_CIDR` | `10.96.0.0/16` | `10.96.0.0/16` |

Use your configured values if you changed the defaults. Include any additional peering/VPN ranges in `UNDERLAY_CIDRS`. 

Install the `control plane` first, prepare the `worker`, then run the generated `join command` on the worker and verify both nodes as described in `README`.

Public IPs can change after stop/start. Rerun the address commands when needed; the configured private IPs are used by Kubernetes and remain with the instances. 
These scripts do not manage cloud load balancers or persistent volume provisioning.

#### 7. Failures and recovery

For stack creation failures, the script prints failed resource events and preserves the deployment state. Use the saved ARN to inspect details:

```bash
aws cloudformation describe-stack-events --region "$AWS_REGION" --stack-name "$AWS_STACK_ID" --output table --no-cli-pager
```

If the create response was lost and `stack_id` is null, inspect the configured stack name in the CloudFormation console. 
Cleanup may recover its ARN only when the account, region, stack name and saved deployment UUID tags all match. It never adopts a differently owned stack. 

A stack with `CREATE_IN_PROGRESS` or `ROLLBACK_IN_PROGRESS` must finish before cleanup proceeds.

For `InsufficientInstanceCapacity`, preview and delete the failed deployment after rollback finishes, select another `AWS_AVAILABILITY_ZONE` or instance type,
re-export `aws/config.env`, then rerun creation. 

An offered instance type can still have no capacity in that AZ. Permission, quota and organization-policy errors require fixing their specific cause.

If only SSH fails, check the actual public egress source, TCP/22 rule, instance status and first-boot logs. 
CloudFormation `CREATE_COMPLETE` does not mean that cloud-init or Kubernetes installation has finished. 
If only Kubernetes bootstrap fails, use [README.md](README.md#logs-and-recovery); provisioning scripts do not reset the cluster.

If state is lost, automatic cleanup deliberately stops. Inspect the exact CloudFormation stack and its resource list in the AWS console for manual cleanup.

#### 8. Cleanup

Export the original account, region and cluster settings. Preview first:

```bash
bash aws/delete-vms.sh
```

The preview verifies ownership and prints the saved stack's resources. To delete that deployment:

```bash
bash aws/delete-vms.sh --yes
```

This deletes both instances and their root disks, including Kubernetes state and local workload data, then removes the stack's network resources and imported EC2 public key.
It does not delete your local key files or the automation host. 

CloudFormation handles dependency order; the script waits for completion and archives local state only after successful deletion or confirmed stack absence.

If deletion fails, state remains so you can inspect stack events, resolve the cause and retry.
