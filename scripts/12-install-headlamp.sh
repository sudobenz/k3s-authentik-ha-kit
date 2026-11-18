#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
require_root
load_config
validate_common
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

PLUGIN_CONFIG="${ROOT_DIR}/config/headlamp-plugins.yml"
[[ -s "$PLUGIN_CONFIG" ]] || fail "Configuration des plugins absente : $PLUGIN_CONFIG"
command -v helm >/dev/null 2>&1 || fail "Helm est requis."
command -v jq >/dev/null 2>&1 || fail "jq est requis."
k3s kubectl cluster-info >/dev/null 2>&1 || fail "API Kubernetes inaccessible."

info "Préparation du dépôt Helm Headlamp"
helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ --force-update
helm repo update headlamp
helm show chart headlamp/headlamp --version "$HEADLAMP_CHART_VERSION" >/dev/null \
  || fail "Chart Headlamp ${HEADLAMP_CHART_VERSION} introuvable dans le dépôt."

k3s kubectl create namespace "$HEADLAMP_NAMESPACE" --dry-run=client -o yaml \
  | k3s kubectl apply -f - >/dev/null

if helm status "$HEADLAMP_HELM_RELEASE" -n "$HEADLAMP_NAMESPACE" >/dev/null 2>&1; then
  info "Mise à jour de la release Headlamp existante ${HEADLAMP_HELM_RELEASE} (conservation des valeurs existantes)"
  helm upgrade "$HEADLAMP_HELM_RELEASE" headlamp/headlamp \
    --namespace "$HEADLAMP_NAMESPACE" \
    --version "$HEADLAMP_CHART_VERSION" \
    --reuse-values \
    --set service.type=ClusterIP \
    --set pluginsManager.enabled=true \
    --set config.watchPlugins=true \
    --set-file pluginsManager.configContent="$PLUGIN_CONFIG" \
    --wait --timeout 5m
else
  info "Installation initiale Headlamp ${HEADLAMP_CHART_VERSION}"
  helm install "$HEADLAMP_HELM_RELEASE" headlamp/headlamp \
    --namespace "$HEADLAMP_NAMESPACE" \
    --version "$HEADLAMP_CHART_VERSION" \
    --set service.type=ClusterIP \
    --set pluginsManager.enabled=true \
    --set config.watchPlugins=true \
    --set-file pluginsManager.configContent="$PLUGIN_CONFIG" \
    --wait --timeout 5m
fi

k3s kubectl -n "$HEADLAMP_NAMESPACE" rollout status \
  "deployment/${HEADLAMP_HELM_RELEASE}" --timeout=180s \
  || fail "Le déploiement Headlamp n'est pas Ready."
k3s kubectl -n "$HEADLAMP_NAMESPACE" get svc "$HEADLAMP_SERVICE_NAME" >/dev/null \
  || fail "Service Headlamp absent : ${HEADLAMP_NAMESPACE}/${HEADLAMP_SERVICE_NAME}."

info "Attente de l'installation des plugins (maximum 5 minutes)"
MISSING=(cnpg-headlamp-plugin cert-manager)
for attempt in $(seq 1 100); do
  MISSING=()
  for plugin in cnpg-headlamp-plugin cert-manager; do
    if ! k3s kubectl -n "$HEADLAMP_NAMESPACE" exec "deployment/${HEADLAMP_HELM_RELEASE}" \
        -c headlamp-plugin -- test -d "/headlamp/plugins/${plugin}" >/dev/null 2>&1; then
      MISSING+=("$plugin")
    fi
  done
  ((${#MISSING[@]} == 0)) && break
  sleep 3
done
if ((${#MISSING[@]} > 0)); then
  warn "Plugin(s) absent(s) du volume partagé après 5 minutes : ${MISSING[*]}"
  warn "Logs du gestionnaire de plugins :"
  k3s kubectl -n "$HEADLAMP_NAMESPACE" logs "deployment/${HEADLAMP_HELM_RELEASE}" \
    -c headlamp-plugin --since=20m >&2 || true
  fail "Headlamp est déployé, mais tous les plugins ne sont pas installés."
fi

printf '\nHeadlamp opérationnel.\n'
printf 'Release : %s\nNamespace : %s\nChart : %s\nService : %s:%s (%s)\n' \
  "$HEADLAMP_HELM_RELEASE" "$HEADLAMP_NAMESPACE" "$HEADLAMP_CHART_VERSION" \
  "$HEADLAMP_SERVICE_NAME" "$HEADLAMP_SERVICE_PORT" "$(k3s kubectl -n "$HEADLAMP_NAMESPACE" get svc "$HEADLAMP_SERVICE_NAME" -o jsonpath='{.spec.type}')"
printf 'Plugins installés : cnpg-headlamp-plugin 0.1.6 ; cert-manager 0.1.1\n'
printf 'L’Ingress HTTPS est créé séparément par scripts/11-configure-dashboard-ingress.sh.\n'
printf 'SÉCURITÉ : contrôler le ClusterRoleBinding de la ServiceAccount Headlamp ; le chart peut attribuer cluster-admin par défaut.\n'
