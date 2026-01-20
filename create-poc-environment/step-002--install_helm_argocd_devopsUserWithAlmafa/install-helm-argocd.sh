#!/bin/bash
set -euo pipefail

# ============================================================================
# HELM 3 + ARGOCD INSTALL SCRIPT (Single Host) - FIXED VERSION
# ============================================================================
# Telepítés: Helm 3, ArgoCD (latest stable), devops user bcrypt jelszóval
# Letöltés és futtatás: bash ./install-helm-argocd.sh
# ============================================================================

# Konfigurációs változók
PASSWORD="Almafa123456"
DEVOPS_USERNAME="devops"
NAMESPACE="argocd"
ARGOCD_RELEASE="argocd"
CHART_VERSION="9.3.3"  # Explicit verzió - ArgoCD 3.2.x-et telepít

# ANSI colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Utility functions
log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
  exit 1
}

# ============================================================================
# 1. HELM 3 TELEPÍTÉS
# ============================================================================
log_info "Helm 3 telepítése indul..."

if command -v helm &> /dev/null; then
  HELM_VERSION=$(helm version --short 2>/dev/null | cut -d: -f2 | tr -d ' v')
  log_warn "Helm már telepítve van: $HELM_VERSION"
else
  log_info "Helm letöltése és telepítése..."
  curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod +x /tmp/get_helm.sh
  /tmp/get_helm.sh --no-sudo || log_error "Helm telepítés sikertelen"
  rm /tmp/get_helm.sh
  log_success "Helm 3 telepítve"
fi

helm version --short
log_success "Helm 3 ready"

# ============================================================================
# 2. KUBECTL ELLENŐRZÉSE
# ============================================================================
log_info "Kubectl és cluster ellenőrzése..."

if ! command -v kubectl &> /dev/null; then
  log_error "kubectl nincs telepítve. Kérjük telepítsd először!"
fi

if ! kubectl cluster-info &> /dev/null; then
  log_error "Kubernetes cluster nem elérhető. Ellenőrizd a kubeconfig-ot!"
fi

log_success "Kubernetes cluster connected"

# ============================================================================
# 3. ARGOCD NAMESPACE LÉTREHOZÁSA
# ============================================================================
log_info "ArgoCD namespace ($NAMESPACE) létrehozása..."

if kubectl get namespace "$NAMESPACE" &> /dev/null; then
  log_warn "Namespace '$NAMESPACE' már létezik"
else
  kubectl create namespace "$NAMESPACE"
  log_success "Namespace '$NAMESPACE' létrehozva"
fi

# ============================================================================
# 4. HELM REPO HOZZÁADÁSA
# ============================================================================
log_info "Argo Helm repository hozzáadása..."

# Repo hozzáadása (ha már van, nem okoz hibát)
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo 2>/dev/null || true

log_success "Argo repo updated"

# ============================================================================
# 5. ARGOCD TELEPÍTÉSE HELM-MEL (explicit verzió)
# ============================================================================
log_info "ArgoCD telepítése Helm-mel (chart verzió: $CHART_VERSION)..."

# Ellenőrzés: Helm release már létezik-e
EXISTING_RELEASE=$(helm list -n "$NAMESPACE" 2>/dev/null | grep "$ARGOCD_RELEASE" || true)

if [ -n "$EXISTING_RELEASE" ]; then
  log_warn "ArgoCD már telepítve van. Skip install..."
else
  log_info "Helm install futtatása..."
  
  helm install "$ARGOCD_RELEASE" argo/argo-cd \
    --namespace "$NAMESPACE" \
    --version "$CHART_VERSION" \
    --set server.service.type=ClusterIP \
    --wait \
    --timeout 5m \
    2>&1 | tee /tmp/helm-install.log || log_error "ArgoCD Helm install sikertelen (check /tmp/helm-install.log)"
fi

log_success "ArgoCD telepítve"

# ============================================================================
# 6. ARGOCD CLI TELEPÍTÉSE
# ============================================================================
log_info "ArgoCD CLI telepítése..."

if command -v argocd &> /dev/null; then
  ARGOCD_VERSION=$(argocd version --client 2>/dev/null | grep "argocd" | awk '{print $2}' || echo "unknown")
  log_warn "ArgoCD CLI már telepítve van: $ARGOCD_VERSION"
else
  log_info "ArgoCD CLI letöltése..."
  
  # Hardcode a legfrissebb stable verzió (2026. január alapján)
  ARGOCD_CLI_URL="https://github.com/argoproj/argo-cd/releases/download/v3.2.5/argocd-linux-amd64"
  
  if ! curl -sSL -f "$ARGOCD_CLI_URL" -o /tmp/argocd-linux-amd64 2>/dev/null; then
    log_warn "Hardcoded URL nem működött, fallback a latest release-re..."
    ARGOCD_CLI_URL=$(curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest 2>/dev/null | \
      grep -m1 '"browser_download_url".*linux-amd64"' | cut -d '"' -f 4 || echo "")
    
    [ -z "$ARGOCD_CLI_URL" ] && log_error "ArgoCD CLI download URL nem elérhető"
    
    log_info "Latest URL: $ARGOCD_CLI_URL"
    curl -sSL -o /tmp/argocd-linux-amd64 "$ARGOCD_CLI_URL" || log_error "ArgoCD CLI download failed"
  fi
  
  chmod +x /tmp/argocd-linux-amd64
  sudo mv /tmp/argocd-linux-amd64 /usr/local/bin/argocd
  
  log_success "ArgoCD CLI telepítve"
fi

argocd version --client

# ============================================================================
# 7. POD-OK VÁRAKOZÁSA
# ============================================================================
log_info "ArgoCD pod-ok indulásának várakozása (max 3 perc)..."

for i in {1..18}; do
  POD_COUNT=$(kubectl get pods -n "$NAMESPACE" 2>/dev/null | grep -c "Running" || echo "0")
  if [ "$POD_COUNT" -ge 3 ]; then
    log_success "Pod-ok elindultak (Ready: $POD_COUNT)"
    break
  fi
  log_info "Waiting... ($i/18) - Running pods: $POD_COUNT"
  sleep 10
done

sleep 3

# ============================================================================
# 8. DEVOPS USER KONFIGURÁLÁSA
# ============================================================================
log_info "Devops user konfigurálása..."

# ---- argocd-cm ConfigMap szerkesztése (user hozzáadása) ----
log_info "User felvétele argocd-cm-be..."

kubectl patch configmap argocd-cm \
  -n "$NAMESPACE" \
  --type merge \
  -p '{"data":{"accounts.'"${DEVOPS_USERNAME}"'":"apiKey, login","accounts.'"${DEVOPS_USERNAME}"'.enabled":"true"}}' \
  2>/dev/null || log_warn "argocd-cm patch - lehet már be van állítva"

log_success "Devops user enabled in argocd-cm"

# ============================================================================
# 9. BCRYPT HASH GENERÁLÁS
# ============================================================================
log_info "Bcrypt hash generálása jelszóhoz: $PASSWORD..."

BCRYPT_HASH=$(argocd account bcrypt --password "$PASSWORD" 2>/dev/null || echo "")

if [ -z "$BCRYPT_HASH" ]; then
  log_error "Bcrypt hash generálás sikertelen"
fi

log_success "Bcrypt hash generálva (first 30 chars): ${BCRYPT_HASH:0:30}..."

# ============================================================================
# 10. JELSZÓ BEÁLLÍTÁSA (DIRECT SECRET PATCH)
# ============================================================================
log_info "Jelszó beállítása argocd-secret-be..."

TIMESTAMP=$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "2026-01-16T21:53:00Z")

# Base64 encode a hash-t (kubernetes secret expects base64)
BCRYPT_HASH_B64=$(echo -n "$BCRYPT_HASH" | base64 -w0)

# Patch secret - StringData autom base64-ozza, de direct base64 data-t is lehet
kubectl patch secret argocd-secret \
  -n "$NAMESPACE" \
  --type merge \
  -p "{\"data\":{\"accounts.${DEVOPS_USERNAME}.password\":\"${BCRYPT_HASH_B64}\"}}" \
  2>/dev/null || log_error "Secret patch sikertelen"

log_success "Jelszó beállítva argocd-secret-ben"

# ============================================================================
# 11. ADMIN RBAC ROLE BEÁLLÍTÁSA
# ============================================================================
log_info "Admin RBAC role beállítása devops usernek..."

# argocd-rbac-cm létrehozása/patchelése
RBAC_POLICY="g, ${DEVOPS_USERNAME}, role:admin"

kubectl patch configmap argocd-rbac-cm \
  -n "$NAMESPACE" \
  --type merge \
  -p "{\"data\":{\"policy.csv\":\"${RBAC_POLICY}\n\",\"policy.default\":\"role:readonly\"}}" \
  2>/dev/null || log_warn "RBAC policy update - lehet már be van állítva"

log_success "Admin RBAC role beállítva"

# ============================================================================
# 12. SERVER POD ÚJRAINDÍTÁSA
# ============================================================================
log_info "ArgoCD server pod újraindítása (konfiguráció alkalmazásához)..."

kubectl rollout restart deployment/argocd-server -n "$NAMESPACE" 2>/dev/null || true
kubectl rollout status deployment/argocd-server -n "$NAMESPACE" --timeout=3m || log_warn "Server restart waited 3min"

sleep 5

log_success "Server újraindítva"

# ============================================================================
# 13. INITIAL ADMIN JELSZÓ (csak info)
# ============================================================================
log_info "Initial admin jelszó lekérése..."

INITIAL_PASS=$(kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A")

log_warn "Initial admin password: $INITIAL_PASS"

# ============================================================================
# 14. PORT-FORWARD ÉS ELLENŐRZÉS
# ============================================================================
log_info "Port-forward létrehozása: localhost:8080 -> argocd-server:443"

# Meglévő port-forward leállítása
pkill -f "kubectl port-forward.*argocd-server" || true
sleep 1

# Új port-forward háttérben
kubectl port-forward svc/argocd-server -n "$NAMESPACE" --address 0.0.0.0 8080:443 > /dev/null 2>&1 &
PF_PID=$!
sleep 3

log_success "Port-forward aktív (PID: $PF_PID)"
