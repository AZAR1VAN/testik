#!/usr/bin/env bash
# ============================================================
#  cleanup.sh — Повне очищення середовища
#  Видаляє: Minikube кластер, Docker контейнери/images, iptables правила
# ============================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

echo ""
echo -e "${RED}═══════════════════════════════════════════════════════${NC}"
echo -e "${RED}  ⚠️  This will DELETE everything: Minikube, containers, images${NC}"
echo -e "${RED}═══════════════════════════════════════════════════════${NC}"
echo ""
read -p "Continue? (y/N): " CONFIRM
if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
  echo "Cancelled."
  exit 0
fi

# ─── 1. Delete Minikube cluster ───────────────────────────────
if command -v minikube &>/dev/null; then
  info "Deleting Minikube cluster..."
  minikube delete --all --purge 2>/dev/null || true
  rm -rf ~/.minikube 2>/dev/null || true
  info "Minikube deleted ✅"
else
  warn "minikube not found, skipping"
fi

# ─── 2. Clean Docker ──────────────────────────────────────────
if command -v docker &>/dev/null; then
  info "Stopping all Docker containers..."
  docker stop $(docker ps -aq) 2>/dev/null || true
  
  info "Removing all Docker containers..."
  docker rm -f $(docker ps -aq) 2>/dev/null || true
  
  info "Removing all Docker images..."
  docker rmi -f $(docker images -aq) 2>/dev/null || true
  
  info "Pruning Docker system (volumes, networks, cache)..."
  docker system prune -af --volumes 2>/dev/null || true
  
  info "Docker cleaned ✅"
else
  warn "docker not found, skipping"
fi

# ─── 3. Clean iptables rules ─────────────────────────────────
info "Cleaning iptables NAT rules..."
iptables -t nat -F PREROUTING 2>/dev/null || true
iptables -t nat -F POSTROUTING 2>/dev/null || true
info "iptables cleaned ✅"

# ─── 4. Remove generated files ───────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rm -f "${SCRIPT_DIR}/credentials.txt" 2>/dev/null || true
info "credentials.txt removed ✅"

# ─── 5. Remove Helm cache ────────────────────────────────────
rm -rf ~/.cache/helm 2>/dev/null || true
rm -rf ~/.local/share/helm 2>/dev/null || true
info "Helm cache removed ✅"

# ─── 6. Remove kubectl config ────────────────────────────────
rm -f ~/.kube/config 2>/dev/null || true
info "kubectl config removed ✅"

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅  Cleanup complete! VM is ready for fresh deploy.${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "  Run: ./setup.sh"
echo ""
