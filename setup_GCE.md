#### GCP automation host and VM provisioning

Use this guide on a separate **Ubuntu Server 24.04 LTS automation host**. It may run on `AWS EC2`, `GCP`, `Azure` or another network with access to `Google Cloud APIs` and `SSH access` to the new VMs.

It provisions two `GCP` VMs, then hands off to [README.md](README.md) for Kubernetes installation.

For `AWS EC2` node provisioning, use [setup_EC2.md](setup_EC2.md). Both workflows share the same Kubernetes node scripts and can use the same `automation host`.

Run `gcloud`, SSH and the provisioning scripts as your normal automation host user. Use `sudo` for the APT installation commands. 

The Kubernetes node scripts (`k8scp.sh`/`k8sWorker.sh`) run later on their respective VMs.

#### 1. Prepare the automation host

Wait for initial provisioning to finish, then update the host:

```bash
sudo cloud-init status --wait
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y ca-certificates curl gnupg jq python3 git openssh-client util-linux
if [ -f /var/run/reboot-required ]; then sudo reboot; fi
```

Reconnect after a reboot. Install `Google Cloud CLI` from its signed APT repository:

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/google-cloud.gpg
sudo chmod 0644 /etc/apt/keyrings/google-cloud.gpg

echo 'deb [signed-by=/etc/apt/keyrings/google-cloud.gpg] https://packages.cloud.google.com/apt cloud-sdk main' | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
sudo apt-get update
sudo apt-get install -y google-cloud-cli

gcloud version
```

If this host already has the `Google Cloud repository` configured, keep one consistent repository entry and signing-key path. 
Avoid duplicate entries with conflicting `signed-by` values. [Google Cloud CLI installation](https://docs.cloud.google.com/sdk/docs/install-sdk#deb)

#### 2. Authenticate and choose a project

You need an existing `Google Cloud project` with billing enabled, adequate VM/disk quota in the intended region, and permissions to create/delete instances,
boot disks, networks, subnets and firewall rules. 

Enabling `Compute Engine` also requires permission to enable services. The scripts do not create a project or grant IAM permissions.

From a remote host without a browser:

```bash
gcloud auth login --no-launch-browser
```

Follow the CLI's authentication instructions using your own Google account. Keep authorization codes and tokens private. 

For more information, please visit the official documentation - [gcloud authentication](https://docs.cloud.google.com/sdk/docs/authorizing)

Set your project ID, replacing the example:

```bash
export PROJECT_ID=your-project-id
gcloud config set project "$PROJECT_ID"
gcloud projects describe "$PROJECT_ID"
gcloud services enable compute.googleapis.com --project="$PROJECT_ID"
```

The provisioning scripts pass `--project` and the relevant region/zone explicitly. They do not change the active gcloud configuration.

This guide uses metadata-based SSH keys; an organization that requires OS Login, private-only VMs or other controls needs a compatible 
provisioning configuration before using these scripts. [SSH keys and OS Login](https://docs.cloud.google.com/compute/docs/connect/add-ssh-keys)

#### 3. Place the repository files on the host

Copy or extract this repository directory onto the `automation host` and change into it. 

Run the remaining automation host commands from the directory containing `README.md` and `setup_GCE.md`.

```bash
cp gcp/config.env.example gcp/config.env
chmod 0600 gcp/config.env
```

Edit **gcp/config.env**. Set `PROJECT_ID` to your project and `ADMIN_CIDRS` to the public egress IPv4 address of the automation host, 
normally as a `/32`, or to your trusted administration CIDR(s). 

If the host uses NAT, use the NAT egress address. Use comma-separated ranges if several trusted sources need SSH access.

For an `AWS EC2 `automation host, this is the `public/NAT` address used to reach the `GCP VMs`.

Its `EC2` private subnet does not automatically have private connectivity to the new `GCP VPC`. The `GCP VMs` must be able to receive `TCP/22` from the configured source.

Export your settings:

```bash
set -a
source gcp/config.env
set +a
```

`config.env` is a local Bash configuration file; only source a file you control. Re-export it after making changes.

| Setting | Default | Meaning |
| --- | --- | --- |
| `CLUSTER_NAME` | `k8s-cluster` | Unique prefix for this deployment's GCP resources |
| `REGION` | `us-central1` | All resources and retry zones remain in this region |
| `ZONES` | Empty | Discover UP zones that offer the machine type; otherwise use an ordered comma-separated list within `REGION` |
| `MAX_ATTEMPTS` | `3` | Maximum number of zone attempts |
| `SUBNET_RANGE` | `172.16.0.0/20` | Dedicated private IPv4 subnet |
| `CP_INTERNAL_IP` | `172.16.0.2` | Requested private IP for the `control plane` |
| `WORKER_INTERNAL_IP` | `172.16.0.3` | Requested private IP for the `worker` |
| `MACHINE_TYPE` | `e2-standard-2` | 2 vCPUs and 8 GB memory per VM |
| `DISK_SIZE_GB` | `30` | Each VM's balanced persistent boot disk |
| `IMAGE_PROJECT` | `ubuntu-os-cloud` | Ubuntu image project |
| `IMAGE_FAMILY` | `ubuntu-2404-lts-amd64` | Ubuntu 24.04 amd64 image family |
| `SSH_USER` | `k8sadmin` | Metadata-created guest login account |
| `SSH_KEY` | `$HOME/.ssh/${CLUSTER_NAME}_ed25519` | Existing private key; matching `.pub` file required |
| `VM_MAX_RUN_DURATION` | Empty | No automatic deletion unless a duration is explicitly configured |

The image family selects the current `Ubuntu 24.04` image when each `VM` is created. OS packages and the Google Cloud CLI are also maintained through their repositories. 
`Kubernetes component pins` are documented separately in `README.md`. 

For an arm64 deployment, select an available arm64 machine type and the corresponding Ubuntu 24.04 image family together.

The first two and last two primary-subnet addresses are reserved by GCP; the defaults above use available addresses. 

If you change the subnet, update both node addresses and the Kubernetes `UNDERLAY_CIDRS` values. 
Avoid overlap with the Pod and Service ranges. [GCP subnet ranges](https://docs.cloud.google.com/vpc/docs/subnets)

#### 4. Create the SSH key

Check whether your configured pair already exists:

```bash
ls -l "$SSH_KEY" "$SSH_KEY.pub"
```

If neither file exists, generate a new key interactively:

```bash
mkdir -p "$(dirname "$SSH_KEY")"
chmod 0700 "$(dirname "$SSH_KEY")"
ssh-keygen -t ed25519 -f "$SSH_KEY" -C "$CLUSTER_NAME"
```

Choose a passphrase appropriate to your automation workflow. Reuse an existing intended pair; do not overwrite one accidentally. 

If using a passphrase, an SSH agent can cache it for the current session:

```bash
eval "$(ssh-agent -s)"
ssh-add "$SSH_KEY"
```

Only the `public key` is placed in each VM's instance metadata. Project-wide SSH keys are blocked for these VMs, and no VM service account is attached.

The `automation host` keeps the `private key` and its own `gcloud credentials`.

#### 5. Create the GCP resources

```bash
bash gcp/create-vms.sh
```

With the default prefix, this creates:

| Resource | Name / behavior |
| --- | --- |
| Custom-mode VPC | `k8s-cluster-network` |
| Subnet | `k8s-cluster-subnet` in `REGION` |
| Control-plane VM | `k8s-cluster-cp`; Kubernetes node name later becomes `cp` |
| Worker VM | `k8s-cluster-worker`; Kubernetes node name later becomes `worker` |
| SSH firewall | `k8s-cluster-ssh`: TCP/22 from `ADMIN_CIDRS` to the node tag |
| API firewall | `k8s-cluster-api`: TCP/6443 from the node tag to the control plane tag |
| Kubelet firewall | `k8s-cluster-kubelet`: TCP/10250 from the control plane tag to both nodes |
| Cilium firewall | `k8s-cluster-cilium`: UDP/8472, TCP/4240 and ICMP between nodes |

The VMs receive ephemeral public IPv4 addresses for outbound access and SSH. 
Their requested private IPs remain fixed while they exist. The network permits the required private node traffic.
Apply any additional organization firewall policy, guest firewall requirements or application access rules separately. [GCP firewall rules](https://docs.cloud.google.com/firewall/docs/firewalls)

The script refuses pre-existing matching resource names.
It generates a unique deployment marker and records settings in `.state/<CLUSTER_NAME>.json` before creating resources.

Keep this file on the `automation host`; cleanup uses it to verify ownership. Its `ready` status means **VM provisioning** succeeded, not Kubernetes readiness.

Zone-capacity failures trigger deletion of only the VMs from that attempt and a retry in another configured zone. 
Authentication, quota, billing or configuration errors stop the process. 

On failure or interruption, resources may remain: inspect the error and use the cleanup procedure before trying again. 
The script does not adopt existing resources or resume from an existing state file.

To select zones explicitly, set, for example, `ZONES=us-central1-a,us-central1-b,us-central1-c` in your private config. 

For a different region, clean up the current deployment, change `REGION`, and clear or update `ZONES` before creating again. Capacity and quotas are provider-controlled.

#### 6. Connect and copy the node scripts

Load the selected zone from the saved deployment:

```bash
STATE_FILE=".state/${CLUSTER_NAME}.json"
ZONE=$(jq -r .zone "$STATE_FILE")

CP_VM="${CLUSTER_NAME}-cp"
WORKER_VM="${CLUSTER_NAME}-worker"

CP_PUBLIC_IP=$(gcloud compute instances describe "$CP_VM" \
  --project="$PROJECT_ID" --zone="$ZONE" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')

WORKER_PUBLIC_IP=$(gcloud compute instances describe "$WORKER_VM" \
  --project="$PROJECT_ID" --zone="$ZONE" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')

# Connect to the `cp` VM
ssh -i "$SSH_KEY" "$SSH_USER@$CP_PUBLIC_IP"

# Connect to the `worker` VM
ssh -i "$SSH_KEY" "$SSH_USER@$WORKER_PUBLIC_IP"
``` 

On the `cp` VM (when connected), complete the Ubuntu update/reboot step in `README.md`, then exit back to the `automation host`. Do the same for the `worker` VM.

```bash
sudo cloud-init status --wait
sudo apt-get update
sudo apt-get upgrade -y
if [ -f /var/run/reboot-required ]; then sudo reboot; fi
```

If SSH is not ready immediately after creation, allow first boot to finish and retry. 

If it remains inaccessible, check your actual egress address, `ADMIN_CIDRS`, effective firewall policy and the guest agent.

Copy the corresponding script to each node:

```bash
scp -i "$SSH_KEY" ./k8scp.sh "$SSH_USER@$CP_PUBLIC_IP:~/k8scp.sh"
scp -i "$SSH_KEY" ./k8sWorker.sh "$SSH_USER@$WORKER_PUBLIC_IP:~/k8sWorker.sh"
```

Follow [README.md](README.md) on `each node`: 
- initialize the `control plane` 
- prepare the `worker` 
- run the generated `join command` on the `worker` 
- verify the cluster 

`NODE_IP` must be the **private** address, not either public address above. Helm, Cilium CLI and the administrator kubeconfig are installed on the `control plane`.

#### 7. Optional automatic deletion

By default the `VMs` have `no lifetime limit` and continue incurring charges until stopped or deleted. 

If you explicitly want temporary VMs, set `VM_MAX_RUN_DURATION=6h` (or another supported duration) **before creation**. 
The script then adds `--max-run-duration` and `--instance-termination-action=DELETE` to each VM.

Expiration deletes each VM and its auto-deleted boot disk, including its Kubernetes data. Firewall rules, the subnet, the VPC and the automation host remain. 
Use the `cleanup script` afterward. 

Stopping and restarting a VM starts a new runtime period; a reset does not restart that period. [VM runtime limits](https://docs.cloud.google.com/compute/docs/instances/limit-vm-runtime)

Inspect the configured scheduling values from the `automation host`:

```bash
for VM in "$CP_VM" "$WORKER_VM"; do
  gcloud compute instances describe "$VM" \
    --project="$PROJECT_ID" --zone="$ZONE" \
    --format='yaml(name,status,scheduling.maxRunDuration,scheduling.instanceTerminationAction)'
done
```

#### 8. Delete this deployment

Export the same private configuration and retain the saved `.state/` directory. First preview the exact resources and verify their ownership:

```bash
bash gcp/delete-vms.sh
```

To delete the displayed deployment, including the VMs and their boot disks:

```bash
bash gcp/delete-vms.sh --yes
```

The script checks the project, cluster and deployment marker. It stops on ownership mismatches or API errors instead of inferring ownership from names.

Already absent resources are skipped, so you can retry after resolving a partial cleanup failure. 
After successful cleanup it archives the state file in `.state/`; the same cluster prefix can then be used for a new deployment.

Additional resources you create separately, such as extra firewall rules, disks are outside its scope and can prevent network deletion.

Inspect and remove those deliberately. Cleanup keeps SSH keys, gcloud credentials and the automation host. Do not delete the whole project to remove this cluster.
