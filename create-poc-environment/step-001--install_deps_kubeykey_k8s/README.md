# Kubernetes Telepítés Ubuntu 24.04 LTS-re

## Áttekintés

Ez a script egy egyszerű, 1 node-os Kubernetes cluster telepítését végzi Ubuntu 24.04 LTS-en KubeKey 3.1.11 használatával.

## Specifikációk

| Komponens | Verzió |
|-----------|--------|
| OS | Ubuntu 24.04 LTS |
| KubeKey | v3.1.11 |
| Kubernetes | v1.33.1 |
| CNI | Calico |
| Container Runtime | containerd |
| etcd | embedded (KubeKey) |

## Előfeltételek

### Hardver
- **CPU**: Minimum 2 mag
- **RAM**: Minimum 4 GB
- **Disk**: Minimum 40 GB

### Szoftver
- Friss Ubuntu 24.04 LTS telepítés
- Root hozzáférés
- Internet kapcsolat

## Gyors telepítés

```bash
# 1. Script letöltése a szerverre (pl. scp-vel)
scp k8s-ubuntu-install.sh root@10.0.0.108:/root/

# 2. SSH a szerverre
ssh root@10.0.0.108

# 3. Script futtatható
chmod +x k8s-ubuntu-install.sh

# 4. Konfiguráció módosítása (opcionális)
# Nyisd meg a scriptet és módosítsd az elejét:
#   NODE_IP="10.0.0.108"
#   NODE_NAME="node1"
#   ROOT_PASSWORD="Almafa123456"
#   KUBE_VERSION="v1.30.8"
nano k8s-ubuntu-install.sh

# 5. Telepítés indítása
sudo ./k8s-ubuntu-install.sh

# 6. Telepítés után újraindítás (ajánlott)
reboot
```

## Konfigurációs paraméterek

A script elején módosítható paraméterek:

```bash
NODE_IP="10.0.0.108"        # A szerver IP címe
NODE_NAME="node1"            # Hostname
ROOT_PASSWORD="Almafa123456" # Root jelszó (KubeKey SSH-hoz)
KUBE_VERSION="v1.33.1"       # Kubernetes verzió (max elérhető)
KUBEKEY_VERSION="v3.1.11"    # KubeKey verzió
POD_CIDR="10.233.64.0/18"    # Pod hálózat
SERVICE_CIDR="10.233.0.0/18" # Service hálózat
```

## Támogatott Kubernetes verziók

KubeKey 3.1.11 támogatott verziók:

| Verzió | Státusz | Ajánlott |
|--------|---------|----------|
| v1.30.x | Stabil | Konzervatív |
| v1.31.x | Stabil | Konzervatív |
| v1.32.x | Stabil | Jó választás |
| v1.33.x | Legújabb | ✅ **Maximum** |

## Telepítés után

### Ellenőrzés

```bash
# Node állapot
kubectl get nodes

# Összes pod
kubectl get pods -A

# Cluster info
kubectl cluster-info
```

### Hasznos aliasok (automatikusan beállítva)

```bash
k       # kubectl
kgp     # kubectl get pods
kgn     # kubectl get nodes
kga     # kubectl get all -A
```

### Kubeconfig lokális gépre másolása

```bash
# A szerveren
cat /root/.kube/config

# Vagy scp-vel
scp root@10.0.0.108:/root/.kube/config ~/.kube/config-remote

# Lokálisan használat
export KUBECONFIG=~/.kube/config-remote
kubectl get nodes
```

## Cleanup / Újratelepítés

Ha újra szeretnéd telepíteni a clustert:

```bash
# 1. Cluster törlése
sudo ./k8s-ubuntu-install.sh --cleanup

# 2. Újratelepítés
sudo ./k8s-ubuntu-install.sh
```

## Hibaelhárítás

### Telepítési hibák

```bash
# KubeKey logok
ls -la /root/kubekey/logs/
cat /root/kubekey/logs/*.log

# Kubelet logok
journalctl -u kubelet -f

# Containerd logok
journalctl -u containerd -f
```

### Node NotReady

```bash
# Calico podok ellenőrzése
kubectl get pods -n kube-system -l k8s-app=calico-node

# DNS ellenőrzése
kubectl get pods -n kube-system -l k8s-app=kube-dns
```

### Hálózati problémák

```bash
# Kernel modulok ellenőrzése
lsmod | grep -E "br_netfilter|overlay|ip_vs"

# Sysctl ellenőrzése
sysctl net.bridge.bridge-nf-call-iptables
sysctl net.ipv4.ip_forward
```

## Fájlok

```
/root/kubekey/
├── kk                      # KubeKey binary
├── config-cluster.yaml     # Cluster konfiguráció
└── logs/                   # Telepítési logok

/etc/kubernetes/            # Kubernetes konfiguráció
├── admin.conf              # Admin kubeconfig
├── kubelet.conf            # Kubelet konfiguráció
└── manifests/              # Static podok

/root/.kube/
└── config                  # kubectl kubeconfig
```

## Támogatás

- **KubeKey GitHub**: https://github.com/kubesphere/kubekey
- **Kubernetes Docs**: https://kubernetes.io/docs/
- **Ubuntu 24.04 támogatás**: 2029 április (standard), 2034 április (ESM)

## Verziók és kompatibilitás

| Ubuntu | KubeKey | Támogatás |
|--------|---------|-----------|
| 24.04 | 3.1.x ✅ | Hivatalos |
| 22.04 | 3.1.x ✅ | Hivatalos |
| 20.04 | 3.1.x ✅ | Hivatalos |
| Debian 12 | ❌ | Nem támogatott |
| Debian 11 | 3.1.x ✅ | LTS 2026-ig |
