#!/usr/bin/env bash
# Standalone Ubuntu 24.04 bootstrap for GCP, AWS and Azure VMs. Fresh installation only.

readonly ROLE=control-plane

set -Eeuo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive

readonly K8S_VERSION=1.36.4
readonly CONTAINERD_VERSION=2.3.5
readonly CONTAINERD_PACKAGE_VERSION='2.3.5-1~ubuntu.24.04~noble'
readonly CRI_TOOLS_VERSION=1.36.0
readonly CRI_SOCKET=unix:///run/containerd/containerd.sock
readonly STATE_DIR=/var/lib/k8s-bootstrap
readonly CONFIG_DIR=/root/k8s-bootstrap

NODE_IP=${NODE_IP:-}
UNDERLAY_CIDRS=${UNDERLAY_CIDRS:-}
POD_CIDR=${POD_CIDR:-192.168.0.0/16}
SERVICE_CIDR=${SERVICE_CIDR:-10.96.0.0/16}
CONTROL_PLANE_IP=${CONTROL_PLANE_IP:-}
TEMP_DIR=

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\n[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
cleanup() {
    if [[ -n "$TEMP_DIR" && "$TEMP_DIR" == /tmp/k8s-bootstrap.* ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}

trap cleanup EXIT
trap 'rc=$?; printf "ERROR: %s failed at line %s (exit %s). Inspect the error above; no cluster reset was performed.\n" "$0" "$LINENO" "$rc" >&2; exit "$rc"' ERR

usage() {
    cat <<EOF
Usage: sudo env NODE_IP=<this-VM-private-IPv4> \\
  UNDERLAY_CIDRS="<VPC-or-VNet-CIDRs-and-peered-or-VPN-ranges>" \\
  [CONTROL_PLANE_IP=<control-plane-private-IPv4>] \\
  [POD_CIDR=192.168.0.0/16] [SERVICE_CIDR=10.96.0.0/16] bash $0

Role: $ROLE. Fresh Ubuntu Server 24.04 LTS, amd64 or arm64 only.
CONTROL_PLANE_IP is required for the worker; on the control plane it equals NODE_IP.
Use identical POD_CIDR and SERVICE_CIDR values on both VMs. UNDERLAY_CIDRS is a
space/comma-separated list of all relevant cloud, peering and VPN network ranges.
The worker script prepares the VM; run kubeadm join afterward as instructed.
The control-plane script also accepts ADMIN_USER and CILIUM_MTU (default 0/auto).
These scripts create a new cluster. They do not upgrade an existing cluster.
EOF
}

preflight() {
    [[ $EUID -eq 0 ]] || die 'Run using sudo env ... bash ./SCRIPT.sh.'

    # shellcheck disable=SC1091
    . /etc/os-release
    [[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 24.04 ]] || die 'Ubuntu Server 24.04 LTS is required.'

    [[ -d /run/systemd/system ]] || die 'A VM booted with systemd is required.'

    for cmd in python3 ip flock dpkg-query modprobe; do
        command -v "$cmd" >/dev/null || die "Missing $cmd. Use a standard Ubuntu Server image."
    done

    ARCH=$(dpkg --print-architecture)
    [[ "$ARCH" == amd64 || "$ARCH" == arm64 ]] || die "Unsupported architecture: $ARCH"

    [[ $(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]] || die 'Boot Ubuntu with its default cgroup v2 configuration.'

    dpkg --compare-versions "$(uname -r | cut -d- -f1)" ge 5.10 || die 'Cilium requires kernel 5.10 or newer.'

    [[ ! -e /var/run/reboot-required ]] || die 'Ubuntu has a pending reboot. Reboot, then run this script.'

    [[ -n "$NODE_IP" && -n "$UNDERLAY_CIDRS" ]] || die 'Set NODE_IP and UNDERLAY_CIDRS; see --help.'

    if [[ "$ROLE" == control-plane ]]; then
        CONTROL_PLANE_IP=${CONTROL_PLANE_IP:-$NODE_IP}
        [[ "$CONTROL_PLANE_IP" == "$NODE_IP" ]] || die 'CONTROL_PLANE_IP must equal NODE_IP on the single control plane.'
    else
        [[ -n "$CONTROL_PLANE_IP" ]] || die 'Set CONTROL_PLANE_IP to the control-plane VM private IPv4 address.'
        [[ "$CONTROL_PLANE_IP" != "$NODE_IP" ]] || die 'The worker and control plane must be different VMs/IPs.'
    fi

    for file in /etc/kubernetes/admin.conf /etc/kubernetes/kubelet.conf \
        /etc/kubernetes/bootstrap-kubelet.conf /var/lib/kubelet/config.yaml \
        /etc/kubernetes/manifests/kube-apiserver.yaml /var/lib/etcd/member; do
        [[ ! -e "$file" ]] || die "Existing cluster state at $file. Use fresh VMs or the kubeadm upgrade/recovery procedure."
    done

    for file in "$STATE_DIR/control-plane.complete" "$STATE_DIR/worker.prepared" \
        /k8scp_run /k8sworker_run; do
        [[ ! -e "$file" ]] || die "Previous installation marker: $file. Do not rerun bootstrap on a prepared node."
    done

    for pkg in docker.io docker-ce podman-docker containerd runc; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -qx 'install ok installed'; then
            die "Conflicting package $pkg is installed. Use a fresh VM; existing runtimes are not removed."
        fi
    done

    python3 - "$NODE_IP" "$CONTROL_PLANE_IP" "$POD_CIDR" "$SERVICE_CIDR" "$UNDERLAY_CIDRS" <<'PY_NETWORK'
import ipaddress as ip
import json
import re
import subprocess
import sys

def fail(message):
    raise SystemExit('ERROR: ' + message)

try:
    node, cp = [ip.IPv4Address(x) for x in sys.argv[1:3]]
    pod, service = [ip.IPv4Network(x, strict=True) for x in sys.argv[3:5]]
    underlay = [ip.IPv4Network(x, strict=True)
                for x in re.split(r'[\s,]+', sys.argv[5].strip()) if x]
except ValueError as exc:
    fail(str(exc))
private_ranges = [ip.IPv4Network(x) for x in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')]
for address in (node, cp):
    if not any(address in net for net in private_ranges):
        fail(f'{address} must be an RFC1918 private node address.')
    if not any(address in net for net in underlay):
        fail(f'UNDERLAY_CIDRS must include the cloud network containing {address}.')
if pod.prefixlen > 23:
    fail('POD_CIDR must contain at least two /24 node blocks (prefix length <= 23).')
if not 12 <= service.prefixlen <= 27:
    fail('Use a SERVICE_CIDR with prefix length between /12 and /27.')
if pod.overlaps(service):
    fail('Pod and Service CIDRs overlap.')
for network in (pod, service):
    if not any(network.subnet_of(net) for net in private_ranges):
        fail(f'{network} must be an RFC1918 private CIDR.')
    for other in underlay:
        if network.overlaps(other):
            fail(f'{network} overlaps cloud/peering/VPN range {other}. Choose different Pod/Service ranges.')
interfaces = json.loads(subprocess.check_output(['ip', '-j', '-4', 'address', 'show', 'scope', 'global']))
addresses = [ip.IPv4Address(a['local']) for dev in interfaces for a in dev.get('addr_info', [])]
if node not in addresses:
    fail(f'NODE_IP {node} is not assigned to a local interface. Do not use a public NAT address.')
routes = json.loads(subprocess.check_output(['ip', '-j', '-4', 'route', 'show', 'table', 'main']))
for route in routes:
    destination = route.get('dst', 'default')
    if destination in ('default', '0.0.0.0/0'):
        continue
    network = ip.IPv4Network(destination, strict=False)
    if any(network.overlaps(net) for net in (pod, service)):
        fail(f'Existing route {network} overlaps Pod or Service CIDR.')
print(f'Validated: node={node}, API={cp}:6443, Pods={pod}, Services={service}')
PY_NETWORK
}

start_logging() {
    exec 9>/run/lock/k8s-bootstrap.lock
    flock -n 9 || die 'Another Kubernetes bootstrap script is running on this VM.'

    install -d -m 0700 "$STATE_DIR" "$CONFIG_DIR"
    local logfile="/var/log/k8s-bootstrap-${ROLE}.log"
    touch "$logfile"

    chmod 0600 "$logfile"
    exec > >(tee -a "$logfile") 2>&1
    TEMP_DIR=$(mktemp -d /tmp/k8s-bootstrap.XXXXXX)
    log "Preparing $ROLE: Kubernetes $K8S_VERSION, containerd $CONTAINERD_VERSION ($ARCH)"
}

download() {
    curl --fail --silent --show-error --location --retry 5 --retry-delay 2 \
        --connect-timeout 15 --max-time 300 "$1" -o "$2"
}

apt_get() { apt-get -o DPkg::Lock::Timeout=300 "$@"; }

resolve_package() {
    local package=$1 upstream=$2 candidate best= available
    available=$(apt-cache madison "$package" | awk '{print $3}')

    while IFS= read -r candidate; do
        [[ "$candidate" == "$upstream"-* ]] || continue
        if [[ -z "$best" ]] || dpkg --compare-versions "$candidate" gt "$best"; then
            best=$candidate
        fi
    done <<< "$available"

    [[ -n "$best" ]] || die "$package $upstream is unavailable in the signed APT repository. No version fallback was selected."
    printf '%s\n' "$best"
}

install_packages() {
    log 'Installing Ubuntu prerequisites and configuring signed APT repositories'
    apt_get update
    apt_get install -y ca-certificates curl gpg jq socat conntrack iptables \
        iproute2 ethtool ebtables python3 openssl

    install -d -m 0755 /etc/apt/keyrings
    download 'https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key' "$TEMP_DIR/kubernetes.key"
    gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg "$TEMP_DIR/kubernetes.key"

    download 'https://download.docker.com/linux/ubuntu/gpg' /etc/apt/keyrings/docker.asc
    chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg /etc/apt/keyrings/docker.asc
    cat > /etc/apt/sources.list.d/kubernetes.list <<EOF
deb [arch=$ARCH signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /
EOF

    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable
EOF
    chmod 0644 /etc/apt/sources.list.d/kubernetes.list /etc/apt/sources.list.d/docker.list
    apt_get update

    local kubelet_pkg kubeadm_pkg kubectl_pkg cri_pkg
    kubelet_pkg=$(resolve_package kubelet "$K8S_VERSION")
    kubeadm_pkg=$(resolve_package kubeadm "$K8S_VERSION")
    kubectl_pkg=$(resolve_package kubectl "$K8S_VERSION")
    cri_pkg=$(resolve_package cri-tools "$CRI_TOOLS_VERSION")

    apt-cache madison containerd.io | awk '{print $3}' | grep -Fx "$CONTAINERD_PACKAGE_VERSION" >/dev/null \
        || die "Docker's noble repository does not offer containerd.io=$CONTAINERD_PACKAGE_VERSION for $ARCH."

    # Exact upstream versions; newest matching Kubernetes/CRI Debian revisions.
    apt_get install -y --no-remove "containerd.io=$CONTAINERD_PACKAGE_VERSION" \
        "kubelet=$kubelet_pkg" "kubeadm=$kubeadm_pkg" "kubectl=$kubectl_pkg" \
        "cri-tools=$cri_pkg" kubernetes-cni
    apt-mark hold kubelet kubeadm kubectl cri-tools kubernetes-cni containerd.io

    [[ $(kubeadm version -o short) == "v$K8S_VERSION" ]] || die 'Unexpected kubeadm binary/version in PATH.'
    [[ $(kubelet --version) == "Kubernetes v$K8S_VERSION" ]] || die 'Unexpected kubelet binary/version in PATH.'
    [[ $(crictl --version) == "crictl version v$CRI_TOOLS_VERSION" ]] || die 'Unexpected crictl in PATH; check for an old /usr/local/bin/crictl.'
}

configure_host() {
    log 'Persisting swap, kernel-module, forwarding and kubelet settings'
    [[ -f "$STATE_DIR/fstab.before" ]] || cp -a /etc/fstab "$STATE_DIR/fstab.before"

    awk '($0 !~ /^[[:space:]]*#/ && $3 == "swap") {$0 = "# Kubernetes disabled swap: " $0} {print}' \
        /etc/fstab > "$TEMP_DIR/fstab"
    cat "$TEMP_DIR/fstab" > /etc/fstab

    if [[ -f /etc/waagent.conf ]]; then
        [[ -f "$STATE_DIR/waagent.conf.before" ]] || cp -a /etc/waagent.conf "$STATE_DIR/waagent.conf.before"
        # Prevent Azure's guest agent from recreating resource-disk swap on reboot.
        sed -i -E '/^[[:space:]]*ResourceDisk\.EnableSwap[[:space:]]*=/d; /^[[:space:]]*ResourceDisk\.SwapSizeMB[[:space:]]*=/d' /etc/waagent.conf
        printf '\nResourceDisk.EnableSwap=n\nResourceDisk.SwapSizeMB=0\n' >> /etc/waagent.conf
    fi

    if [[ -d /etc/cloud/cloud.cfg.d ]]; then
        printf '#cloud-config\nswap:\n  size: 0\n' > /etc/cloud/cloud.cfg.d/99-kubernetes-no-swap.cfg
    fi

    systemctl daemon-reload
    systemctl mask swap.target
    swapoff -a

    [[ -z $(swapon --noheadings --show) ]] || die 'Swap remains active.'

    cat > /etc/modules-load.d/kubernetes.conf <<'EOF'
overlay
br_netfilter
vxlan
EOF
    local module modules_package="linux-modules-extra-$(uname -r)" modules_installed=false

    for module in overlay br_netfilter vxlan; do
        if ! modprobe "$module"; then
            if [[ "$modules_installed" == false ]] && apt-cache show "$modules_package" >/dev/null 2>&1; then
                apt_get install -y --no-remove "$modules_package"
                modules_installed=true
            fi
            modprobe "$module" || die "Cannot load $module. Install the matching Ubuntu kernel modules and reboot if needed."
        fi
    done

    cat > /etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
    chmod 0644 /etc/modules-load.d/kubernetes.conf /etc/sysctl.d/99-kubernetes.conf
    sysctl --system

    [[ $(sysctl -n net.ipv4.ip_forward) == 1 ]] || die 'A conflicting sysctl file disables IPv4 forwarding.'

    # Read by kubeadm's packaged kubelet service during init, join and reboot.
    printf 'KUBELET_EXTRA_ARGS="--node-ip=%s"\n' "$NODE_IP" > /etc/default/kubelet
    chmod 0644 /etc/default/kubelet
}

configure_containerd() {
    log 'Configuring containerd 2.x with systemd cgroups and the kubeadm pause image'
    containerd --version

    install -d -m 0755 /etc/containerd
    if [[ -f /etc/containerd/config.toml && ! -f "$STATE_DIR/containerd.toml.before" ]]; then
        cp -a /etc/containerd/config.toml "$STATE_DIR/containerd.toml.before"
    fi

    local pause_image
    pause_image=$(kubeadm config images list --kubernetes-version "v$K8S_VERSION" | awk '/\/pause:/ {print}')

    [[ "$pause_image" =~ ^registry\.k8s\.io/pause:[a-zA-Z0-9._-]+$ ]] || die 'Could not determine kubeadm pause image.'

    containerd config default > "$TEMP_DIR/containerd.toml"

    python3 - "$TEMP_DIR/containerd.toml" "$pause_image" <<'PY_CONTAINERD'
import pathlib
import re
import sys
import tomllib

def fail(message):
    raise SystemExit('ERROR: containerd configuration: ' + message)

path = pathlib.Path(sys.argv[1])
text = path.read_text()
text, cgroups = re.subn(r'(?m)^(\s*SystemdCgroup\s*=\s*)(?:false|true)\s*$', r'\g<1>true', text)
text, sandboxes = re.subn(r'''(?m)^(\s*sandbox\s*=\s*)(['"]).*?\2\s*$''',
                         lambda match: match[1] + '"' + sys.argv[2] + '"', text)
config = tomllib.loads(text)
# containerd 2.0 introduced format 3; containerd 2.3 introduced format 4.
# Preserve the format generated by the installed binary, including v4's
# server plugin settings. The CRI paths below are shared by both formats.
config_version = config.get('version')
if config_version not in (3, 4):
    fail(f'unsupported format {config_version!r}; expected format 3 or 4')
if cgroups < 1 or sandboxes != 1:
    fail(f'unexpected default layout: {cgroups} cgroup settings, {sandboxes} sandbox images')
try:
    plugins = config['plugins']
    runtime = plugins['io.containerd.cri.v1.runtime']
    systemd_cgroup = runtime['containerd']['runtimes']['runc']['options']['SystemdCgroup']
    sandbox_image = plugins['io.containerd.cri.v1.images']['pinned_images']['sandbox']
except (KeyError, TypeError) as exc:
    fail(f'missing required CRI setting in format {config_version}: {exc}')
if systemd_cgroup is not True:
    fail('the runc runtime must use SystemdCgroup = true')
if sandbox_image != sys.argv[2]:
    fail('the sandbox image must match the image selected by kubeadm')
if any('cri' in item for item in config.get('disabled_plugins', [])):
    fail('CRI must be enabled')
path.write_text(text)
print(f'Validated containerd configuration format {config_version}: systemd cgroups and {sandbox_image}')
PY_CONTAINERD
    # Let this exact containerd binary parse the staged file before replacing
    # the system configuration. RuntimeReady below then checks the live CRI.
    containerd --config "$TEMP_DIR/containerd.toml" config dump > /dev/null

    install -m 0600 "$TEMP_DIR/containerd.toml" /etc/containerd/config.toml
    cat > /etc/crictl.yaml <<EOF
runtime-endpoint: $CRI_SOCKET
image-endpoint: $CRI_SOCKET
timeout: 10
debug: false
EOF
    systemctl enable containerd
    systemctl restart containerd
    systemctl is-active --quiet containerd

    local ready=false attempt
    for ((attempt = 1; attempt <= 30; attempt++)); do
        if crictl info > "$TEMP_DIR/cri-info.json" 2>/dev/null && \
            jq -e 'any(.status.conditions[]; .type == "RuntimeReady" and .status == true)' "$TEMP_DIR/cri-info.json" >/dev/null; then
            ready=true
            break
        fi
        sleep 2
    done

    [[ "$ready" == true ]] || die 'containerd CRI is not ready. Inspect journalctl -u containerd.'

    # NetworkReady=false is expected until the Cilium agent runs on this node.
    systemctl enable --now kubelet
    [[ ! -e /var/run/reboot-required ]] || die 'Package installation requires a reboot. Reboot before continuing bootstrap.'
    {
        date -u +%FT%TZ
        dpkg-query -W kubelet kubeadm kubectl cri-tools kubernetes-cni containerd.io
        containerd --version
        runc --version
        crictl --version
        printf 'NODE_IP=%s\nCONTROL_PLANE_IP=%s\nPOD_CIDR=%s\nSERVICE_CIDR=%s\n' \
            "$NODE_IP" "$CONTROL_PLANE_IP" "$POD_CIDR" "$SERVICE_CIDR"
    } > "$STATE_DIR/versions.txt"
}

prepare_node() {
    install_packages
    configure_host
    configure_containerd
}

readonly CILIUM_VERSION=1.20.1
readonly CILIUM_CLI_VERSION=v0.20.0
readonly HELM_VERSION=v4.3.0
ADMIN_USER=${ADMIN_USER:-${SUDO_USER:-root}}
CILIUM_MTU=${CILIUM_MTU:-0}

install_admin_tools() {
    log "Installing Helm $HELM_VERSION and Cilium CLI $CILIUM_CLI_VERSION"
    local archive="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
    download "https://get.helm.sh/$archive" "$TEMP_DIR/$archive"
    download "https://get.helm.sh/$archive.sha256sum" "$TEMP_DIR/$archive.sha256sum"

    (cd "$TEMP_DIR" && sha256sum --check "$archive.sha256sum")
    tar --extract --gzip --no-same-owner --file "$TEMP_DIR/$archive" \
        --directory "$TEMP_DIR" "linux-$ARCH/helm"
    install -m 0755 "$TEMP_DIR/linux-$ARCH/helm" /usr/local/bin/helm
    archive="cilium-linux-${ARCH}.tar.gz"

    download "https://github.com/cilium/cilium-cli/releases/download/$CILIUM_CLI_VERSION/$archive" "$TEMP_DIR/$archive"
    download "https://github.com/cilium/cilium-cli/releases/download/$CILIUM_CLI_VERSION/$archive.sha256sum" "$TEMP_DIR/$archive.sha256sum"
    (cd "$TEMP_DIR" && sha256sum --check "$archive.sha256sum")
    tar --extract --gzip --no-same-owner --file "$TEMP_DIR/$archive" --directory "$TEMP_DIR" cilium
    install -m 0755 "$TEMP_DIR/cilium" /usr/local/bin/cilium
    helm version --short
    cilium version --client
}

write_cluster_config() {
    cat > "$CONFIG_DIR/kubeadm-init.yaml" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
bootstrapTokens:
  - ttl: 2h
localAPIEndpoint:
  advertiseAddress: "$NODE_IP"
  bindPort: 6443
nodeRegistration:
  name: cp
  criSocket: "$CRI_SOCKET"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: "v$K8S_VERSION"
controlPlaneEndpoint: "$NODE_IP:6443"
networking:
  podSubnet: "$POD_CIDR"
  serviceSubnet: "$SERVICE_CIDR"
  dnsDomain: cluster.local
controllerManager:
  extraArgs:
    - name: node-cidr-mask-size
      value: "24"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
failSwapOn: true
resolvConf: /run/systemd/resolve/resolv.conf
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: iptables
EOF
    # Kubernetes assigns the /24 PodCIDRs; Cilium consumes those assignments.
    # Encapsulation and masquerading avoid cloud-specific Pod routes or IPAM.
    cat > "$CONFIG_DIR/cilium-values.yaml" <<EOF
ipam:
  mode: kubernetes
routingMode: tunnel
tunnelProtocol: vxlan
autoDirectNodeRoutes: false
kubeProxyReplacement: false
k8sServiceHost: "$NODE_IP"
k8sServicePort: "6443"
ipv4:
  enabled: true
ipv6:
  enabled: false
enableIPv4Masquerade: true
bpf:
  masquerade: false
operator:
  replicas: 1
hubble:
  enabled: false
MTU: $CILIUM_MTU
EOF

    kubeadm config validate --config "$CONFIG_DIR/kubeadm-init.yaml"

    # Fetch and render the pinned chart before creating the API server.
    helm pull cilium --repo https://helm.cilium.io --version "$CILIUM_VERSION" --destination "$CONFIG_DIR"
    helm template cilium "$CONFIG_DIR/cilium-$CILIUM_VERSION.tgz" \
        --namespace kube-system --values "$CONFIG_DIR/cilium-values.yaml" \
        --kube-version "$K8S_VERSION" > "$CONFIG_DIR/cilium-rendered.yaml"
}

configure_admin_access() {
    local admin_home admin_gid
    admin_home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
    admin_gid=$(id -g "$ADMIN_USER")
    install -d -m 0700 -o "$ADMIN_USER" -g "$admin_gid" "$admin_home/.kube"

    # Preserve any existing default kubeconfig on the administrator's account.
    local config_target="$admin_home/.kube/config"
    if [[ -e "$config_target" ]]; then
        config_target="$admin_home/.kube/k8s-1.36.4.conf"
    fi

    install -m 0600 -o "$ADMIN_USER" -g "$admin_gid" /etc/kubernetes/admin.conf "$config_target"
    log "kubectl configuration for $ADMIN_USER: $config_target"
    printf 'If needed: export KUBECONFIG=%q\n' "$config_target"
}

main() {
    if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
    [[ $# -eq 0 ]] || die 'Unknown argument; see --help.'

    preflight

    id "$ADMIN_USER" >/dev/null 2>&1 || die "ADMIN_USER $ADMIN_USER does not exist."

    [[ -s /run/systemd/resolve/resolv.conf ]] || die 'The standard Ubuntu systemd-resolved resolver file is missing.'

    [[ "$CILIUM_MTU" =~ ^(0|[1-9][0-9]{2,4})$ ]] || die 'CILIUM_MTU must be 0 (auto) or an integer between 1280 and 65535.'

    (( CILIUM_MTU == 0 || (CILIUM_MTU >= 1280 && CILIUM_MTU <= 65535) )) || die 'Invalid CILIUM_MTU.'

    start_logging
    prepare_node
    install_admin_tools
    write_cluster_config

    log 'Pulling the images selected by kubeadm and initializing the control plane'
    kubeadm config images list --config "$CONFIG_DIR/kubeadm-init.yaml" > "$CONFIG_DIR/kubernetes-images.txt"
    kubeadm config images pull --config "$CONFIG_DIR/kubeadm-init.yaml"
    kubeadm init --config "$CONFIG_DIR/kubeadm-init.yaml" --skip-token-print
    export KUBECONFIG=/etc/kubernetes/admin.conf

    log "Installing Cilium $CILIUM_VERSION and waiting for readiness"
    helm install cilium "$CONFIG_DIR/cilium-$CILIUM_VERSION.tgz" \
        --namespace kube-system --values "$CONFIG_DIR/cilium-values.yaml" \
        --wait=legacy --timeout 10m
    cilium status --wait --wait-duration 10m
    kubectl wait --for=condition=Ready node/cp --timeout=10m
    kubectl -n kube-system rollout status deployment/coredns --timeout=5m

    configure_admin_access

    local join_command
    join_command=$(kubeadm token create --ttl 2h --print-join-command)
    printf 'sudo %s --cri-socket=%s --node-name=worker\n' "$join_command" "$CRI_SOCKET" > "$CONFIG_DIR/join-command.txt"

    chmod 0600 "$CONFIG_DIR/join-command.txt"
    {
        helm version --short
        cilium version --client
        printf 'CILIUM_VERSION=%s\nCILIUM_MTU=%s\n' "$CILIUM_VERSION" "$CILIUM_MTU"
    } >> "$STATE_DIR/versions.txt"

    kubectl get nodes -o wide

    date -u +%FT%TZ > "$STATE_DIR/control-plane.complete"
    log 'Control plane is ready. Now prepare and join the worker VM.'

    cat <<EOF
Run k8sWorker.sh on the other VM with its NODE_IP, CONTROL_PLANE_IP=$NODE_IP,
and matching Pod/Service CIDRs. Then display the join command on THIS VM:
  sudo cat $CONFIG_DIR/join-command.txt
Copy that command to the worker and execute it there. Its token expires in 2 hours.
The control-plane taint remains in place; application workloads run on the worker.
EOF
}

main "$@"
