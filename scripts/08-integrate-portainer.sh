#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_root
[[ -r "$CONFIG_FILE" ]] || fail "Fichier absent : ${CONFIG_FILE}. Configurez d'abord le cluster."
# shellcheck disable=SC1090
source "$CONFIG_FILE"

PORTAINER_NAMESPACE="${PORTAINER_NAMESPACE:-portainer}"
PORTAINER_USE_PROXY="${PORTAINER_USE_PROXY:-false}"
MANIFEST="${1:-${ROOT_DIR}/portainer/portainer-agent-edge-k8s.yaml}"

[[ "$PORTAINER_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "PORTAINER_NAMESPACE invalide : ${PORTAINER_NAMESPACE}"
[[ "$PORTAINER_USE_PROXY" == "true" || "$PORTAINER_USE_PROXY" == "false" ]] || fail "PORTAINER_USE_PROXY doit être true ou false."
[[ -s "$MANIFEST" ]] || fail "Manifeste absent ou vide : ${MANIFEST}. Récupérez le manifeste généré par l'assistant Portainer et placez-le dans portainer/."
[[ -r "$MANIFEST" ]] || fail "Manifeste illisible : ${MANIFEST}"
chmod 600 "$MANIFEST" 2>/dev/null || true

command -v k3s >/dev/null 2>&1 || fail "La commande k3s est absente. Exécuter ce script sur un nœud du cluster."
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
k3s kubectl cluster-info >/dev/null 2>&1 || fail "Impossible de joindre l'API Kubernetes locale."

ready_nodes="$(k3s kubectl get nodes --no-headers 2>/dev/null | awk '$2 ~ /^Ready/ {n++} END {print n+0}')"
(( ready_nodes == 3 )) || fail "Le cluster doit avoir ses trois nœuds Ready avant l'intégration Portainer (actuellement : ${ready_nodes}/3)."

if ! grep -Eqi 'portainer/agent|portainer-agent|edge-agent' "$MANIFEST"; then
  fail "Le fichier ne semble pas être un manifeste Portainer Agent. Utilisez le manifeste Kubernetes produit par Portainer > Add environment > Kubernetes > Edge Agent Standard."
fi
if ! grep -Eqi 'EDGE_KEY|EDGE_ID|edge.key|edge-key' "$MANIFEST"; then
  warn "Aucune variable EDGE_KEY/EDGE_ID explicite détectée. Vérifiez que le manifeste contient les informations d'association générées par Portainer."
fi

info "Préparation de l'espace de noms ${PORTAINER_NAMESPACE}"
k3s kubectl create namespace "$PORTAINER_NAMESPACE" --dry-run=client -o yaml | k3s kubectl apply -f - >/dev/null

info "Validation serveur du manifeste Portainer"
k3s kubectl apply --dry-run=server -f "$MANIFEST" >/dev/null

info "Déploiement du Portainer Edge Agent"
k3s kubectl apply -f "$MANIFEST"

workloads=""
for _ in $(seq 1 60); do
  workloads="$(k3s kubectl -n "$PORTAINER_NAMESPACE" get deployments,daemonsets -o name 2>/dev/null | grep -Ei 'agent' || true)"
  [[ -n "$workloads" ]] && break
  sleep 2
done
[[ -n "$workloads" ]] || {
  k3s kubectl -n "$PORTAINER_NAMESPACE" get all -o wide || true
  fail "Aucun Deployment/DaemonSet Portainer Agent détecté dans le namespace ${PORTAINER_NAMESPACE}. Vérifiez le namespace du manifeste généré par Portainer."
}

if [[ "$PORTAINER_USE_PROXY" == "true" ]]; then
  [[ -n "${HTTP_PROXY:-}${HTTPS_PROXY:-}" ]] || fail "PORTAINER_USE_PROXY=true mais HTTP_PROXY et HTTPS_PROXY sont vides dans config.env."
  no_proxy_effective="$(make_no_proxy)"
  proxy_args=()
  if [[ -n "${HTTP_PROXY:-}" ]]; then proxy_args+=("HTTP_PROXY=${HTTP_PROXY}" "http_proxy=${HTTP_PROXY}"); fi
  if [[ -n "${HTTPS_PROXY:-}" ]]; then proxy_args+=("HTTPS_PROXY=${HTTPS_PROXY}" "https_proxy=${HTTPS_PROXY}"); fi
  proxy_args+=("NO_PROXY=${no_proxy_effective}" "no_proxy=${no_proxy_effective}")
  while IFS= read -r workload; do
    [[ -n "$workload" ]] || continue
    info "Application des paramètres proxy sur ${workload}"
    k3s kubectl -n "$PORTAINER_NAMESPACE" set env "$workload" "${proxy_args[@]}" >/dev/null
  done <<< "$workloads"
fi

while IFS= read -r workload; do
  [[ -n "$workload" ]] || continue
  info "Attente de ${workload}"
  k3s kubectl -n "$PORTAINER_NAMESPACE" rollout status "$workload" --timeout=600s
done <<< "$workloads"

k3s kubectl -n "$PORTAINER_NAMESPACE" get pods -o wide
printf '\nPortainer Edge Agent déployé dans le cluster.\n'
printf 'Dans Portainer, attendez que l’environnement Kubernetes créé avec Edge Agent Standard passe à l’état Up.\n'
printf 'Un seul environnement Portainer représente les trois nœuds ; ne créez pas un environnement par nœud.\n'
printf 'Manifeste utilisé : %s\n' "$MANIFEST"
printf 'Ce script ne déploie pas le serveur Portainer ; il ajoute uniquement l’agent au cluster existant.\n'
