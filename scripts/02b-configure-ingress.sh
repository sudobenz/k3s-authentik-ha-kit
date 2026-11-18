#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_root
load_config
validate_common
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

[[ "$AUTHENTIK_TLS_MODE" == "secret" ]] || fail "Définir AUTHENTIK_TLS_MODE=secret dans config.env pour terminer le HTTPS sur Traefik."
command -v jq >/dev/null 2>&1 || fail "jq est requis pour vérifier les ports Traefik."

info "Configuration de Traefik en terminaison TLS directe"
cat <<YAML_EOF | k3s kubectl apply -f -
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    deployment:
      replicas: 3
    affinity:
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app.kubernetes.io/name: traefik
            topologyKey: kubernetes.io/hostname
    ports:
      web:
        expose:
          default: false
      websecure:
        expose:
          default: true
    service:
      annotations:
        kube-vip.io/loadbalancerIPs: "$INGRESS_VIP"
      spec:
        externalTrafficPolicy: Local
YAML_EOF

info "Attente de la réconciliation Traefik (port 443 présent, port 80 absent)"
TRAEFIK_SERVICE_JSON=""
PORTS_OK="false"
for attempt in $(seq 1 120); do
  TRAEFIK_SERVICE_JSON="$(k3s kubectl -n kube-system get svc traefik -o json 2>/dev/null || true)"
  if [[ -n "$TRAEFIK_SERVICE_JSON" ]] \
    && jq -e '.spec.externalTrafficPolicy == "Local" and any(.spec.ports[]?; .port == 443) and (all(.spec.ports[]?; .port != 80))' \
      <<< "$TRAEFIK_SERVICE_JSON" >/dev/null 2>&1; then
    PORTS_OK="true"
    break
  fi
  sleep 5
done
if [[ "$PORTS_OK" != "true" ]]; then
  [[ -z "$TRAEFIK_SERVICE_JSON" ]] || jq -r '.spec.ports[]? | [.name, .port, .nodePort] | @tsv' <<< "$TRAEFIK_SERVICE_JSON" >&2
  k3s kubectl -n kube-system get helmchartconfig traefik -o yaml >&2 || true
  fail "Traefik n'a pas appliqué la configuration attendue après 10 minutes."
fi
k3s kubectl -n kube-system rollout status deployment/traefik --timeout=600s
TRAEFIK_POLICY="$(k3s kubectl -n kube-system get svc traefik -o jsonpath='{.spec.externalTrafficPolicy}')"
[[ "$TRAEFIK_POLICY" == "Local" ]] || fail "Traefik doit conserver externalTrafficPolicy=Local ; valeur actuelle : ${TRAEFIK_POLICY:-absente}."

info "Traefik publie uniquement le port 443 sur la VIP ${INGRESS_VIP}, avec conservation de l'IP source (externalTrafficPolicy=Local)."
printf '\nÉtape suivante : exécuter scripts/11-configure-dashboard-ingress.sh pour générer le certificat autosigné SAN et créer les Ingress HTTPS.\n'
