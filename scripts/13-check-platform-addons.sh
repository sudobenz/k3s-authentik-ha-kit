#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
require_root
load_config
validate_common
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

WARNINGS=0
check_crd() {
  local crd="$1"
  if k3s kubectl get crd "$crd" >/dev/null 2>&1; then
    printf 'OK       CRD %s\n' "$crd"
  else
    printf 'MANQUANT CRD %s\n' "$crd"
    WARNINGS=$((WARNINGS + 1))
  fi
}
check_deployment() {
  local ns="$1" deployment="$2"
  if k3s kubectl -n "$ns" get deployment "$deployment" >/dev/null 2>&1; then
    local ready desired image
    ready="$(k3s kubectl -n "$ns" get deployment "$deployment" -o jsonpath='{.status.readyReplicas}')"
    desired="$(k3s kubectl -n "$ns" get deployment "$deployment" -o jsonpath='{.spec.replicas}')"
    image="$(k3s kubectl -n "$ns" get deployment "$deployment" -o jsonpath='{.spec.template.spec.containers[0].image}')"
    printf 'OK       Deployment %s/%s ready=%s/%s image=%s\n' "$ns" "$deployment" "${ready:-0}" "${desired:-1}" "$image"
    [[ "${ready:-0}" == "${desired:-1}" ]] || WARNINGS=$((WARNINGS + 1))
  else
    printf 'MANQUANT Deployment %s/%s\n' "$ns" "$deployment"
    WARNINGS=$((WARNINGS + 1))
  fi
}

printf '=== CloudNativePG Operator ===\n'
check_deployment cnpg-system cnpg-controller-manager
k3s kubectl -n authentik get cluster authentik-db \
  -o custom-columns='NAME:.metadata.name,INSTANCES:.spec.instances,READY:.status.readyInstances,PRIMARY:.status.currentPrimary,PHASE:.status.phase' \
  || WARNINGS=$((WARNINGS + 1))
printf '\n=== cert-manager ===\n'
for crd in \
  certificates.cert-manager.io \
  certificaterequests.cert-manager.io \
  issuers.cert-manager.io \
  clusterissuers.cert-manager.io \
  orders.acme.cert-manager.io \
  challenges.acme.cert-manager.io
do check_crd "$crd"; done
for deployment in cert-manager cert-manager-cainjector cert-manager-webhook; do
  check_deployment "$CERT_MANAGER_NAMESPACE" "$deployment"
done

printf '\n=== Headlamp ===\n'
check_deployment "$HEADLAMP_NAMESPACE" "$HEADLAMP_HELM_RELEASE"
k3s kubectl -n "$HEADLAMP_NAMESPACE" get service "$HEADLAMP_SERVICE_NAME" -o wide \
  || WARNINGS=$((WARNINGS + 1))
for plugin in cnpg-headlamp-plugin cert-manager; do
  if k3s kubectl -n "$HEADLAMP_NAMESPACE" exec "deployment/${HEADLAMP_HELM_RELEASE}" \
      -c headlamp-plugin -- test -d "/headlamp/plugins/${plugin}" >/dev/null 2>&1; then
    printf 'OK       Plugin %s installé\n' "$plugin"
  else
    printf 'MANQUANT Plugin %s\n' "$plugin"
    WARNINGS=$((WARNINGS + 1))
  fi
done

SA_NAME="$(k3s kubectl -n "$HEADLAMP_NAMESPACE" get deployment "$HEADLAMP_HELM_RELEASE" \
  -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true)"
if [[ -z "$SA_NAME" ]]; then
  printf 'MANQUANT ServiceAccount utilisé par Headlamp (deployment %s/%s)\n' "$HEADLAMP_NAMESPACE" "$HEADLAMP_HELM_RELEASE"
  WARNINGS=$((WARNINGS + 1))
  SA_NAME="$HEADLAMP_HELM_RELEASE"
fi
SA="system:serviceaccount:${HEADLAMP_NAMESPACE}:${SA_NAME}"
printf '\n=== RBAC Headlamp (lecture des ressources cert-manager) ===\n'
printf 'ServiceAccount : %s\n' "$SA"
ALL_API_ACCESS="$(k3s kubectl auth can-i '*' '*' --all-namespaces --as="$SA" 2>/dev/null || echo no)"
if [[ "$ALL_API_ACCESS" == "yes" ]]; then
  printf 'ALERTE SÉCURITÉ : cette ServiceAccount semble disposer de droits globaux sur toutes les API/ressources (profil cluster-admin probable). Réserver Headlamp aux administrateurs tant que le RBAC n’est pas restreint.\n'
fi
for resource in certificates.cert-manager.io certificaterequests.cert-manager.io issuers.cert-manager.io clusterissuers.cert-manager.io orders.acme.cert-manager.io challenges.acme.cert-manager.io; do
  for verb in get list watch; do
    answer="$(k3s kubectl auth can-i "$verb" "$resource" --all-namespaces --as="$SA" 2>/dev/null || echo no)"
    printf '%-7s %-48s %s\n' "$verb" "$resource" "$answer"
    [[ "$answer" == yes ]] || WARNINGS=$((WARNINGS + 1))
  done
done

printf '\n=== Résultat ===\n'
if (( WARNINGS > 0 )); then
  printf 'Terminé avec %s avertissement(s). Consulter les éléments MANQUANT / permissions no ci-dessus.\n' "$WARNINGS"
  exit 1
fi
printf 'Tous les contrôles des composants complémentaires sont passés.\n'
