#!/bin/bash
#===============================================================================
# Kubernetes Telepítő Script - Ubuntu 24.04 LTS
#===============================================================================
# KubeKey verzió: v3.1.11 (utolsó stabil 3.x)
# Kubernetes verzió: v1.30.8 (stabil, LTS-szerű támogatás)
# CNI: Calico
# Container Runtime: containerd
#
# Használat:
#   chmod +x k8s-ubuntu-install.sh
#   sudo ./k8s-ubuntu-install.sh
#
# Követelmények:
#   - Ubuntu 24.04 LTS (friss telepítés)
#   - Minimum 2 CPU, 4GB RAM, 40GB disk
#   - Root jogosultság
#   - Internet kapcsolat
#===============================================================================

set -e

#-------------------------------------------------------------------------------
# KONFIGURÁCIÓS VÁLTOZÓK - MÓDOSÍTSD IGÉNY SZERINT
#-------------------------------------------------------------------------------
NODE_IP="10.0.0.108"
NODE_NAME="node1"
ROOT_PASSWORD="Almafa123456"

# Kubernetes verzió (KubeKey 3.1.11 támogatja: v1.21.x - v1.33.x)
# Maximum elérhető verzió: v1.33.1
KUBE_VERSION="v1.33.1"

# KubeKey verzió
KUBEKEY_VERSION="v3.1.11"

# Hálózati beállítások
POD_CIDR="10.233.64.0/18"
SERVICE_CIDR="10.233.0.0/18"
CLUSTER_DNS="169.254.25.10"

#-------------------------------------------------------------------------------
# SZÍNEK ÉS LOGOLÁS
#-------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN} $1${NC}"
    echo -e "${GREEN}================================================================${NC}"
}

#-------------------------------------------------------------------------------
# ELŐFELTÉTELEK ELLENŐRZÉSE
#-------------------------------------------------------------------------------
check_prerequisites() {
    log_section "1. Előfeltételek ellenőrzése"
    
    # Root ellenőrzés
    if [ "$EUID" -ne 0 ]; then
        log_error "Kérlek futtasd root-ként: sudo $0"
        exit 1
    fi
    log_success "Root jogosultság OK"
    
    # Ubuntu verzió ellenőrzés
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "ubuntu" ]]; then
            log_error "Ez a script csak Ubuntu-ra készült!"
            exit 1
        fi
        if [[ "$VERSION_ID" != "24.04" ]]; then
            log_warn "Ez a script Ubuntu 24.04-re optimalizált. Jelenlegi: $VERSION_ID"
        fi
    fi
    log_success "Ubuntu $VERSION_ID detektálva"
    
    # Memória ellenőrzés
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$TOTAL_MEM" -lt 3500 ]; then
        log_error "Minimum 4GB RAM szükséges! Jelenlegi: ${TOTAL_MEM}MB"
        exit 1
    fi
    log_success "Memória OK: ${TOTAL_MEM}MB"
    
    # CPU ellenőrzés
    CPU_COUNT=$(nproc)
    if [ "$CPU_COUNT" -lt 2 ]; then
        log_error "Minimum 2 CPU szükséges! Jelenlegi: $CPU_COUNT"
        exit 1
    fi
    log_success "CPU OK: $CPU_COUNT mag"
    
    # Disk ellenőrzés
    FREE_DISK=$(df -BG / | awk 'NR==2{print $4}' | tr -d 'G')
    if [ "$FREE_DISK" -lt 20 ]; then
        log_warn "Ajánlott minimum 40GB szabad hely! Jelenlegi: ${FREE_DISK}GB"
    fi
    log_success "Disk OK: ${FREE_DISK}GB szabad"
}

#-------------------------------------------------------------------------------
# RENDSZER ELŐKÉSZÍTÉS
#-------------------------------------------------------------------------------
prepare_system() {
    log_section "2. Rendszer előkészítése"
    
    # Hostname beállítás
    log_info "Hostname beállítása: $NODE_NAME"
    hostnamectl set-hostname "$NODE_NAME"
    
    # /etc/hosts frissítése
    log_info "/etc/hosts frissítése..."
    cat > /etc/hosts << EOF
127.0.0.1 localhost
$NODE_IP $NODE_NAME
$NODE_IP lb.kubesphere.local

# IPv6
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
    log_success "/etc/hosts OK"
    
    # APT frissítés
    log_info "APT csomagok frissítése..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    log_success "APT frissítés OK"
    
    # Szükséges csomagok telepítése
    log_info "Szükséges csomagok telepítése..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl \
        wget \
        git \
        vim \
        net-tools \
        socat \
        conntrack \
        ebtables \
        ipset \
        ipvsadm \
        util-linux \
        apt-transport-https \
        ca-certificates \
        gnupg \
        lsb-release \
        software-properties-common \
        bash-completion \
        chrony \
        jq \
        tar \
        openssl
    log_success "Csomagok telepítve"
}

#-------------------------------------------------------------------------------
# SWAP KIKAPCSOLÁSA
#-------------------------------------------------------------------------------
disable_swap() {
    log_section "3. Swap kikapcsolása"
    
    log_info "Swap leállítása..."
    swapoff -a
    
    log_info "Swap eltávolítása /etc/fstab-ból..."
    sed -i '/\sswap\s/d' /etc/fstab
    
    # Ellenőrzés
    if [ "$(swapon --show | wc -l)" -eq 0 ]; then
        log_success "Swap sikeresen kikapcsolva"
    else
        log_warn "Swap még aktív lehet, kézi ellenőrzés szükséges"
    fi
}

#-------------------------------------------------------------------------------
# KERNEL MODULOK ÉS SYSCTL
#-------------------------------------------------------------------------------
configure_kernel() {
    log_section "4. Kernel modulok és sysctl beállítása"
    
    # Kernel modulok betöltése
    log_info "Kernel modulok konfigurálása..."
    cat > /etc/modules-load.d/k8s.conf << EOF
# Kubernetes szükséges modulok
overlay
br_netfilter
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF

    # Modulok azonnali betöltése
    modprobe overlay
    modprobe br_netfilter
    modprobe ip_vs
    modprobe ip_vs_rr
    modprobe ip_vs_wrr
    modprobe ip_vs_sh
    modprobe nf_conntrack
    log_success "Kernel modulok betöltve"
    
    # Sysctl beállítások
    log_info "Sysctl paraméterek beállítása..."
    cat > /etc/sysctl.d/99-kubernetes.conf << EOF
# Kubernetes hálózati beállítások
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.conf.all.forwarding        = 1
net.ipv6.conf.all.forwarding        = 1

# Kapcsolat követés
net.netfilter.nf_conntrack_max = 1000000

# Memória optimalizáció
vm.swappiness = 0
vm.overcommit_memory = 1
vm.panic_on_oom = 0

# Fájl leírók
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
fs.file-max = 2097152
EOF

    sysctl --system > /dev/null 2>&1
    log_success "Sysctl beállítások alkalmazva"
}

#-------------------------------------------------------------------------------
# TŰZFAL KIKAPCSOLÁSA
#-------------------------------------------------------------------------------
disable_firewall() {
    log_section "5. Tűzfal kikapcsolása"
    
    if systemctl is-active --quiet ufw; then
        log_info "UFW tűzfal kikapcsolása..."
        ufw disable
        systemctl stop ufw
        systemctl disable ufw
        log_success "UFW kikapcsolva"
    else
        log_info "UFW nem aktív"
    fi
    
    if systemctl is-active --quiet firewalld; then
        log_info "Firewalld kikapcsolása..."
        systemctl stop firewalld
        systemctl disable firewalld
        log_success "Firewalld kikapcsolva"
    else
        log_info "Firewalld nem aktív"
    fi
}

#-------------------------------------------------------------------------------
# IDŐ SZINKRONIZÁCIÓ
#-------------------------------------------------------------------------------
configure_time() {
    log_section "6. Idő szinkronizáció"
    
    log_info "Chrony konfigurálása..."
    systemctl enable chrony
    systemctl start chrony
    
    # Timezone beállítás (opcionális - módosítható)
    timedatectl set-timezone Europe/Budapest
    
    log_success "Idő szinkronizáció OK"
    log_info "Aktuális idő: $(date)"
}

#-------------------------------------------------------------------------------
# CONTAINERD TELEPÍTÉSE
#-------------------------------------------------------------------------------
install_containerd() {
    log_section "7. Containerd telepítése"
    
    # Docker GPG kulcs és repo hozzáadása
    log_info "Docker repository hozzáadása..."
    install -m 0755 -d /etc/apt/keyrings
    
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi
    
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt-get update -qq
    
    # Containerd telepítése
    log_info "Containerd telepítése..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq containerd.io
    
    # Containerd konfiguráció
    log_info "Containerd konfigurálása..."
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    
    # SystemdCgroup engedélyezése
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    
    # Sandbox image beállítása (K8s 1.33+ pause:3.10)
    sed -i 's|sandbox_image = "registry.k8s.io/pause:.*"|sandbox_image = "registry.k8s.io/pause:3.10"|g' /etc/containerd/config.toml
    
    # Containerd újraindítása
    systemctl daemon-reload
    systemctl enable containerd
    systemctl restart containerd
    
    # Ellenőrzés
    sleep 2
    if systemctl is-active --quiet containerd; then
        log_success "Containerd telepítve és fut"
        containerd --version
    else
        log_error "Containerd nem indult el!"
        journalctl -u containerd --no-pager -n 20
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# KUBEKEY LETÖLTÉSE
#-------------------------------------------------------------------------------
download_kubekey() {
    log_section "8. KubeKey letöltése"
    
    # Munkakönyvtár létrehozása
    WORK_DIR="/root/kubekey"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    # KubeKey letöltése
    log_info "KubeKey ${KUBEKEY_VERSION} letöltése..."
    
    if [ -f "./kk" ]; then
        log_info "KubeKey már létezik, törlés..."
        rm -f ./kk
    fi
    
    # Letöltés
    curl -sfL https://get-kk.kubesphere.io | VERSION=${KUBEKEY_VERSION} sh -
    
    if [ -f "./kk" ]; then
        chmod +x ./kk
        log_success "KubeKey letöltve"
        ./kk version
    else
        log_error "KubeKey letöltés sikertelen!"
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# KUBEKEY KONFIGURÁCIÓ LÉTREHOZÁSA
#-------------------------------------------------------------------------------
create_kubekey_config() {
    log_section "9. KubeKey konfiguráció létrehozása"
    
    cd /root/kubekey
    
    log_info "config-cluster.yaml létrehozása..."
    
    cat > config-cluster.yaml << EOF
apiVersion: kubekey.kubesphere.io/v1alpha2
kind: Cluster
metadata:
  name: k8s-cluster
spec:
  hosts:
  - {name: ${NODE_NAME}, address: ${NODE_IP}, internalAddress: ${NODE_IP}, user: root, password: "${ROOT_PASSWORD}"}
  roleGroups:
    etcd:
    - ${NODE_NAME}
    control-plane:
    - ${NODE_NAME}
    worker:
    - ${NODE_NAME}
  controlPlaneEndpoint:
    domain: lb.kubesphere.local
    address: "${NODE_IP}"
    port: 6443
  kubernetes:
    version: ${KUBE_VERSION}
    clusterName: cluster.local
    autoRenewCerts: true
    containerManager: containerd
  etcd:
    type: kubekey
  network:
    plugin: calico
    kubePodsCIDR: ${POD_CIDR}
    kubeServiceCIDR: ${SERVICE_CIDR}
  registry:
    privateRegistry: ""
    namespaceOverride: ""
    registryMirrors: []
    insecureRegistries: []
EOF

    log_success "config-cluster.yaml létrehozva"
    
    # Konfiguráció megjelenítése
    log_info "Konfiguráció tartalma:"
    echo "---"
    cat config-cluster.yaml
    echo "---"
}

#-------------------------------------------------------------------------------
# KUBERNETES CLUSTER LÉTREHOZÁSA
#-------------------------------------------------------------------------------
create_cluster() {
    log_section "10. Kubernetes cluster létrehozása"
    
    cd /root/kubekey
    
    log_warn "Ez a lépés több percig is eltarthat..."
    log_info "Cluster létrehozása KubeKey-jel..."
    
    # Cluster létrehozása
    ./kk create cluster -f config-cluster.yaml -y
    
    if [ $? -eq 0 ]; then
        log_success "Kubernetes cluster sikeresen létrehozva!"
    else
        log_error "Cluster létrehozás sikertelen!"
        log_info "Ellenőrizd a logokat: /root/kubekey/logs/"
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# KUBECTL BEÁLLÍTÁSA
#-------------------------------------------------------------------------------
setup_kubectl() {
    log_section "11. kubectl beállítása"
    
    # Kubeconfig másolása root-nak
    log_info "Kubeconfig beállítása root felhasználónak..."
    mkdir -p /root/.kube
    if [ -f /etc/kubernetes/admin.conf ]; then
        cp /etc/kubernetes/admin.conf /root/.kube/config
        chown root:root /root/.kube/config
        chmod 600 /root/.kube/config
        log_success "Kubeconfig beállítva"
    else
        log_error "/etc/kubernetes/admin.conf nem található!"
    fi
    
    # Bash completion
    log_info "kubectl bash completion beállítása..."
    kubectl completion bash > /etc/bash_completion.d/kubectl
    
    # Alias hozzáadása
    if ! grep -q "alias k=" /root/.bashrc; then
        echo "" >> /root/.bashrc
        echo "# Kubernetes aliases" >> /root/.bashrc
        echo "alias k='kubectl'" >> /root/.bashrc
        echo "alias kgp='kubectl get pods'" >> /root/.bashrc
        echo "alias kgn='kubectl get nodes'" >> /root/.bashrc
        echo "alias kga='kubectl get all -A'" >> /root/.bashrc
        echo "source <(kubectl completion bash)" >> /root/.bashrc
        echo "complete -F __start_kubectl k" >> /root/.bashrc
    fi
    log_success "kubectl aliasok beállítva"
}

#-------------------------------------------------------------------------------
# CLUSTER ELLENŐRZÉSE
#-------------------------------------------------------------------------------
verify_cluster() {
    log_section "12. Cluster ellenőrzése"
    
    log_info "Node-ok állapota:"
    kubectl get nodes -o wide
    
    log_info ""
    log_info "Rendszer podok állapota:"
    kubectl get pods -n kube-system
    
    log_info ""
    log_info "Cluster információk:"
    kubectl cluster-info
    
    # Node Ready ellenőrzés
    NODE_STATUS=$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')
    if [ "$NODE_STATUS" == "True" ]; then
        log_success "Node státusz: Ready"
    else
        log_warn "Node státusz: Not Ready - várd meg amíg Ready lesz"
    fi
}

#-------------------------------------------------------------------------------
# ÖSSZEFOGLALÓ
#-------------------------------------------------------------------------------
print_summary() {
    log_section "TELEPÍTÉS BEFEJEZVE!"
    
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           KUBERNETES CLUSTER SIKERESEN TELEPÍTVE             ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC} Node IP:           ${BLUE}${NODE_IP}${NC}"
    echo -e "${GREEN}║${NC} Node név:          ${BLUE}${NODE_NAME}${NC}"
    echo -e "${GREEN}║${NC} Kubernetes:        ${BLUE}${KUBE_VERSION}${NC}"
    echo -e "${GREEN}║${NC} KubeKey:           ${BLUE}${KUBEKEY_VERSION}${NC}"
    echo -e "${GREEN}║${NC} CNI:               ${BLUE}Calico${NC}"
    echo -e "${GREEN}║${NC} Container Runtime: ${BLUE}containerd${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC} API Server:        ${BLUE}https://${NODE_IP}:6443${NC}"
    echo -e "${GREEN}║${NC} Kubeconfig:        ${BLUE}/root/.kube/config${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC} Hasznos parancsok:                                         ${NC}"
    echo -e "${GREEN}║${NC}   kubectl get nodes                                        ${NC}"
    echo -e "${GREEN}║${NC}   kubectl get pods -A                                      ${NC}"
    echo -e "${GREEN}║${NC}   kubectl cluster-info                                     ${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    log_info "Újraindítás ajánlott: reboot"
}

#-------------------------------------------------------------------------------
# CLEANUP FÜGGVÉNY (ha újra kell futtatni)
#-------------------------------------------------------------------------------
cleanup_cluster() {
    log_section "Cluster tisztítása (cleanup)"
    
    cd /root/kubekey 2>/dev/null || true
    
    if [ -f "./kk" ]; then
        log_info "Cluster törlése KubeKey-jel..."
        ./kk delete cluster -f config-cluster.yaml -y || true
    fi
    
    log_info "Maradék fájlok törlése..."
    rm -rf /etc/kubernetes
    rm -rf /var/lib/etcd
    rm -rf /var/lib/kubelet
    rm -rf /var/lib/calico
    rm -rf /etc/cni
    rm -rf /var/lib/cni
    rm -rf /run/calico
    rm -rf /root/.kube
    
    log_info "Containerd konténerek törlése..."
    crictl rm -af 2>/dev/null || true
    crictl rmp -af 2>/dev/null || true
    
    log_info "Hálózati interfészek törlése..."
    ip link delete cali+ 2>/dev/null || true
    ip link delete tunl0 2>/dev/null || true
    ip link delete vxlan.calico 2>/dev/null || true
    
    log_success "Cleanup befejezve"
}

#-------------------------------------------------------------------------------
# MAIN
#-------------------------------------------------------------------------------
main() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     KUBERNETES TELEPÍTŐ - Ubuntu 24.04 + KubeKey 3.1.11      ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Paraméter ellenőrzés
    if [ "$1" == "--cleanup" ]; then
        cleanup_cluster
        exit 0
    fi
    
    # Telepítési lépések
    check_prerequisites
    prepare_system
    disable_swap
    configure_kernel
    disable_firewall
    configure_time
    install_containerd
    download_kubekey
    create_kubekey_config
    create_cluster
    setup_kubectl
    verify_cluster
    print_summary
}

# Script indítása
main "$@"
