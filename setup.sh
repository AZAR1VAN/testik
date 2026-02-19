#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# setup.sh — One-command GitOps infrastructure bootstrap
# Repo: https://github.com/AZAR1VAN/testik
#
# What this does:
#   1. Installs prerequisites (Docker, kubectl, minikube, helm)
#   2. Adds Helm repos
#   3. Starts Minikube (Docker driver, 4 CPU, 8GB RAM)
#   4. Installs ArgoCD
#   5. Deploys spam2000 via Helm (port 3000, tag 1.1394.355)
#   6. Deploys VictoriaMetrics (scrapes spam2000, kubelet, cadvisor)
#   7. Deploys Grafana (dashboards: cluster + spam2000)
#   8. Creates RBAC for VictoriaMetrics kubelet scraping
#   9. Pushes Grafana dashboards via API
#  10. Prints access info
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_FILE="${SCRIPT_DIR}/credentials.txt"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Generate random password (hex — no special chars that could break --set)
GRAFANA_ADMIN_PASS="${GRAFANA_ADMIN_PASS:-$(openssl rand -hex 12)}"
DEPLOY_USER="deployer"

# ─── 1. Install prerequisites if missing ──────────────────────
install_if_missing() {
  local cmd="$1"
  if command -v "$cmd" &>/dev/null; then
    info "$cmd: $(command -v $cmd)"
    return
  fi
  warn "$cmd not found — installing..."
  case "$cmd" in
    docker)
      curl -fsSL https://get.docker.com | sudo sh
      sudo usermod -aG docker "$USER"
      sudo systemctl enable --now docker
      ;;
    kubectl)
      KVER=$(curl -L -s https://dl.k8s.io/release/stable.txt)
      curl -sLO "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"
      sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
      rm kubectl
      ;;
    minikube)
      curl -sLO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
      sudo install minikube-linux-amd64 /usr/local/bin/minikube
      rm minikube-linux-amd64
      ;;
    helm)
      curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
      ;;
    iptables)
      sudo apt-get update -qq && sudo apt-get install -y -qq iptables
      ;;
  esac
}

# ─── 0. Fix host DNS if broken (systemd-resolved stub) ────────
if ! host github.com &>/dev/null; then
  warn "DNS broken — fixing /etc/resolv.conf..."
  sudo rm -f /etc/resolv.conf 2>/dev/null || true
  printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' | sudo tee /etc/resolv.conf >/dev/null
  info "DNS fixed → 8.8.8.8 / 1.1.1.1 ✅"
fi

# ─── 0.5. Create dedicated deploy user ───────────────────────
if ! id "${DEPLOY_USER}" &>/dev/null; then
  info "Creating user '${DEPLOY_USER}'..."
  sudo useradd -m -s /bin/bash "${DEPLOY_USER}"
  sudo usermod -aG docker "${DEPLOY_USER}"
  # Allow passwordless sudo for deploy operations
  echo "${DEPLOY_USER} ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/${DEPLOY_USER} >/dev/null
  info "User '${DEPLOY_USER}' created with docker + sudo access ✅"
else
  info "User '${DEPLOY_USER}' already exists ✅"
  # Ensure docker group membership
  sudo usermod -aG docker "${DEPLOY_USER}" 2>/dev/null || true
fi

info "=== Step 1: Prerequisites ==="
for tool in docker kubectl minikube helm iptables; do
  install_if_missing "$tool"
done

# ─── 2. Helm repos ────────────────────────────────────────────
info "=== Step 2: Helm repositories ==="
helm repo add vm      https://victoriametrics.github.io/helm-charts/ 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts          2>/dev/null || true
helm repo add argo    https://argoproj.github.io/argo-helm           2>/dev/null || true
helm repo update 2>&1 | tail -3

# ─── 3. Minikube ──────────────────────────────────────────────
info "=== Step 3: Minikube ==="
if minikube status 2>/dev/null | grep -q "Running"; then
  warn "Minikube already running."
else
  minikube start \
    --driver=docker \
    --cpus=4 \
    --memory=8192 \
    --disk-size=30g \
    --cni=calico \
    --extra-config=kubeadm.pod-network-cidr=10.244.0.0/16 \
    --service-cluster-ip-range=10.96.0.0/16 \
    --addons=metrics-server \
    --force
fi
kubectl wait --for=condition=Ready node/minikube --timeout=120s
info "Node Ready: $(kubectl get nodes --no-headers | awk '{print $1, $2}')"

# ─── 4. Namespaces ────────────────────────────────────────────
info "=== Step 4: Namespaces ==="
for ns in argocd apps monitoring; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# ─── 4.5. Persistent Volumes (hostPath) ──────────────────────
info "=== Step 4.5: Persistent Volumes ==="
kubectl apply -f "${SCRIPT_DIR}/monitoring/persistent-volumes.yaml"
# Fix ownership for Grafana hostPath (UID 472 = grafana user)
minikube ssh 'sudo mkdir -p /data/grafana /data/victoria-metrics && sudo chown -R 472:472 /data/grafana'
info "PV/PVC created: grafana-pv (1Gi, /data/grafana), victoria-metrics-pv (5Gi, /data/victoria-metrics) ✅"

# ─── 5. Fix CoreDNS for external DNS resolution ──────────────
info "=== Step 5: CoreDNS fix (external DNS) ==="
# Minikube CoreDNS may use /etc/resolv.conf which fails for external domains.
# Patch to use Google/Cloudflare DNS so ArgoCD can reach github.com.
CORE_DNS_FWD=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' 2>/dev/null | grep -c 'forward . /etc/resolv.conf' || true)
if [ "${CORE_DNS_FWD}" -gt 0 ]; then
  kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' \
    | sed 's|forward . /etc/resolv.conf|forward . 8.8.8.8 1.1.1.1|' > /tmp/corefile.txt
  kubectl create configmap coredns -n kube-system \
    --from-file=Corefile=/tmp/corefile.txt --dry-run=client -o yaml | kubectl apply -f -
  kubectl rollout restart deployment coredns -n kube-system
  kubectl rollout status deployment/coredns -n kube-system --timeout=60s
  rm -f /tmp/corefile.txt
  info "CoreDNS patched: forward → 8.8.8.8 / 1.1.1.1 ✅"
else
  info "CoreDNS already configured ✅"
fi

# ─── 6. ArgoCD ────────────────────────────────────────────────
info "=== Step 6: ArgoCD ==="
kubectl apply -n argocd --server-side -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml 2>&1 | tail -3
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
info "ArgoCD ready. Password: ${ARGOCD_PASS}"

# Reduce ArgoCD polling interval from 3min to 30s for faster GitOps sync
kubectl patch cm argocd-cm -n argocd --type merge \
  -p '{"data":{"timeout.reconciliation":"30s"}}' 2>/dev/null || true
# Restart repo-server to pick up new interval
kubectl rollout restart deployment argocd-repo-server -n argocd 2>/dev/null || true
info "ArgoCD polling interval set to 30s ✅"

# ─── 6. spam2000 (port 3000, tag 1.1394.355) ─────────────────
info "=== Step 7: spam2000 app ==="
helm upgrade --install spam2000 "${SCRIPT_DIR}/charts/spam2000" \
  --namespace apps --wait --timeout=180s
kubectl get pods -n apps

# ─── 7. RBAC for VictoriaMetrics (kubelet/cadvisor scraping) ──
info "=== Step 8: RBAC for VictoriaMetrics ==="
kubectl apply -f "${SCRIPT_DIR}/monitoring/rbac.yaml"

# ─── 8. VictoriaMetrics ───────────────────────────────────────
info "=== Step 9: VictoriaMetrics ==="
helm upgrade --install victoria-metrics vm/victoria-metrics-single \
  --namespace monitoring \
  -f "${SCRIPT_DIR}/monitoring/victoria-values.yaml"

# Create scrape ConfigMap (for kubelet/cadvisor scraping)
kubectl apply -f "${SCRIPT_DIR}/monitoring/victoria-scrape-config.yaml"

# Patch VictoriaMetrics StatefulSet: mount scrape config + search limits
kubectl patch statefulset victoria-metrics-victoria-metrics-single-server -n monitoring --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/args", "value": [
    "--storageDataPath=/storage",
    "--retentionPeriod=1",
    "--promscrape.config=/config/scrape.yaml",
    "--search.maxUniqueTimeseries=5000000",
    "--search.maxSeries=5000000"
  ]},
  {"op": "add", "path": "/spec/template/spec/volumes/-", "value": {
    "name": "scrape-config",
    "configMap": {"name": "victoria-scrape-config"}
  }},
  {"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts/-", "value": {
    "name": "scrape-config",
    "mountPath": "/config"
  }}
]' 2>/dev/null || true

kubectl rollout status statefulset/victoria-metrics-victoria-metrics-single-server \
  -n monitoring --timeout=120s || warn "VM rollout timed out, retrying..."

# ─── 9. Grafana ───────────────────────────────────────────────
info "=== Step 10: Grafana ==="

# Password is passed via --set (never stored in Git, generated at top of script)
helm upgrade --install grafana grafana/grafana \
  --namespace monitoring \
  -f "${SCRIPT_DIR}/monitoring/grafana-values.yaml" \
  --set adminPassword="${GRAFANA_ADMIN_PASS}"
kubectl rollout status deployment/grafana -n monitoring --timeout=120s

# ─── 10. Dashboard ConfigMaps (for Grafana sidecar) ──────────
info "=== Step 11: Grafana Dashboard ConfigMaps ==="
# Grafana sidecar watches ConfigMaps with label grafana_dashboard=1
# Dashboards survive pod restarts and ArgoCD re-syncs

if [ -f "${SCRIPT_DIR}/monitoring/dashboards/cluster-dashboard.json" ]; then
  kubectl create configmap grafana-dash-cluster \
    --from-file=cluster-dashboard.json="${SCRIPT_DIR}/monitoring/dashboards/cluster-dashboard.json" \
    -n monitoring --dry-run=client -o yaml | kubectl apply -f -
  kubectl label configmap grafana-dash-cluster -n monitoring grafana_dashboard=1 --overwrite
  info "Cluster dashboard ConfigMap created ✅"
fi

if [ -f "${SCRIPT_DIR}/monitoring/dashboards/spam2000-dashboard.json" ]; then
  kubectl create configmap grafana-dash-spam2000 \
    --from-file=spam2000-dashboard.json="${SCRIPT_DIR}/monitoring/dashboards/spam2000-dashboard.json" \
    -n monitoring --dry-run=client -o yaml | kubectl apply -f -
  kubectl label configmap grafana-dash-spam2000 -n monitoring grafana_dashboard=1 --overwrite
  info "spam2000 dashboard ConfigMap created ✅"
fi

# ─── 11. Apply ArgoCD Application (GitOps for spam2000) ──────
info "=== Step 12: ArgoCD Application (GitOps) ==="
# Only spam2000 is managed via ArgoCD GitOps
# Grafana & VictoriaMetrics are infra — managed by setup.sh/Helm directly
kubectl apply -f "${SCRIPT_DIR}/argocd/apps/spam2000-app.yaml" 2>/dev/null || warn "ArgoCD app may need manual apply"
info "ArgoCD will auto-sync spam2000 from https://github.com/AZAR1VAN/testik (polling: 30s)"

# ─── 12. Expose services via NodePort ─────────────────────────
info "=== Step 13: Expose Services ==="
# Grafana NodePort is already set via grafana-values.yaml (30300)

# Expose ArgoCD on NodePort 30080
kubectl patch svc argocd-server -n argocd -p '{"spec":{"type":"NodePort","ports":[{"port":443,"targetPort":8080,"nodePort":30080}]}}' 2>/dev/null || true

# Expose VictoriaMetrics on NodePort 30428 (headless svc can't be patched, so create separate)
kubectl apply -f "${SCRIPT_DIR}/monitoring/victoria-nodeport-svc.yaml"

MINIKUBE_IP=$(minikube ip)

# ─── 13. External access (iptables forwarding) ───────────────
info "=== Step 14: External Access ==="
# Detect external (public) IP if available
EXTERNAL_IP=$(ip -4 route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[0-9.]+')
if [ -n "${EXTERNAL_IP}" ] && [ "${EXTERNAL_IP}" != "${MINIKUBE_IP}" ]; then
  info "External IP detected: ${EXTERNAL_IP}"
  info "Setting up iptables forwarding to Minikube (${MINIKUBE_IP})..."

  # Enable IP forwarding
  sudo sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true

  # Forward external ports → Minikube NodePorts
  for RULE in "3001:${MINIKUBE_IP}:30300" "8080:${MINIKUBE_IP}:30080" "8428:${MINIKUBE_IP}:30428"; do
    EXT_PORT="${RULE%%:*}"
    DEST="${RULE#*:}"
    sudo iptables -t nat -D PREROUTING -p tcp --dport "${EXT_PORT}" -j DNAT --to-destination "${DEST}" 2>/dev/null || true
    sudo iptables -t nat -A PREROUTING -p tcp --dport "${EXT_PORT}" -j DNAT --to-destination "${DEST}"
    sudo iptables -D FORWARD -p tcp -d "${DEST%%:*}" --dport "${DEST##*:}" -j ACCEPT 2>/dev/null || true
    sudo iptables -A FORWARD -p tcp -d "${DEST%%:*}" --dport "${DEST##*:}" -j ACCEPT
    # Also add OUTPUT DNAT (for curl from server itself to its external IP)
    sudo iptables -t nat -D OUTPUT -p tcp -d "${EXTERNAL_IP}" --dport "${EXT_PORT}" -j DNAT --to-destination "${DEST}" 2>/dev/null || true
    sudo iptables -t nat -A OUTPUT -p tcp -d "${EXTERNAL_IP}" --dport "${EXT_PORT}" -j DNAT --to-destination "${DEST}"
  done

  # Ensure Minikube-bound forwarded traffic is accepted (insert at top, before Docker's DROP)
  MINIKUBE_SUBNET="$(echo "${MINIKUBE_IP}" | sed 's/\.[0-9]*$/.0\/24/')"
  sudo iptables -D FORWARD -d "${MINIKUBE_SUBNET}" -j ACCEPT 2>/dev/null || true
  sudo iptables -I FORWARD 1 -d "${MINIKUBE_SUBNET}" -j ACCEPT

  # MASQUERADE for Minikube bridge interface
  MKBRIDGE=$(ip route | grep "${MINIKUBE_SUBNET%/*}" | awk '{print $3}')
  sudo iptables -t nat -D POSTROUTING -o "${MKBRIDGE}" -j MASQUERADE 2>/dev/null || true
  sudo iptables -t nat -A POSTROUTING -o "${MKBRIDGE}" -j MASQUERADE
  info "iptables forwarding configured ✅"
  ACCESS_PREFIX="http://${EXTERNAL_IP}"
  ARGOCD_ACCESS="https://${EXTERNAL_IP}:8080"
else
  warn "No external IP detected — services accessible only via Minikube IP"
  ACCESS_PREFIX="http://${MINIKUBE_IP}"
  ARGOCD_ACCESS="https://${MINIKUBE_IP}:8080"
fi

# ─── 14. Save credentials & Summary ──────────────────────────
cat > "${CREDS_FILE}" <<CREDS
# ═══════════════════════════════════════════════════════
#  Credentials  (generated at $(date '+%Y-%m-%d %H:%M:%S'))
#  ⚠️  This file is gitignored — do NOT commit to repo!
# ═══════════════════════════════════════════════════════

Minikube IP:     ${MINIKUBE_IP}
External IP:     ${EXTERNAL_IP:-none}

Grafana:         ${ACCESS_PREFIX}:3001  (internal: http://${MINIKUBE_IP}:30300)
  User:          admin
  Password:      ${GRAFANA_ADMIN_PASS}
  Dashboards:    Kubernetes Cluster Overview, spam2000 Application Metrics

ArgoCD:          ${ARGOCD_ACCESS}  (internal: https://${MINIKUBE_IP}:30080)
  User:          admin
  Password:      ${ARGOCD_PASS}

VictoriaMetrics: ${ACCESS_PREFIX}:8428  (internal: http://${MINIKUBE_IP}:30428)

GitOps demo:
  Edit charts/spam2000/values.yaml → git push → ArgoCD auto-syncs
CREDS
chmod 600 "${CREDS_FILE}"

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅  Deployment Complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "  📦 Pods:"
kubectl get pods -A | grep -E 'apps|monitoring'
echo ""
cat "${CREDS_FILE}"
echo ""
echo -e "${YELLOW}  🔑 Credentials saved to: ${CREDS_FILE}${NC}"
echo -e "${YELLOW}     (gitignored — will NOT be committed)${NC}"
echo ""

