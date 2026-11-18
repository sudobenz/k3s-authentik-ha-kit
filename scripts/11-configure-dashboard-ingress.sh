#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_root
load_config
validate_common
case "${1:-}" in
  "") ROTATE_LONGHORN_AUTH=false ;;
  --rotate-longhorn-auth) ROTATE_LONGHORN_AUTH=true ;;
  *) fail "Usage : $0 [--rotate-longhorn-auth]" ;;
esac
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

for name in LONGHORN_FQDN HEADLAMP_FQDN HEADLAMP_NAMESPACE HEADLAMP_SERVICE_NAME HEADLAMP_SERVICE_PORT AUTHENTIK_TLS_SECRET_NAME; do
  require_value "$name"
done
HEADLAMP_HELM_RELEASE="${HEADLAMP_HELM_RELEASE:-}"

validate_fqdn() {
  local name="$1" value="${!1}"
  [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || fail "$name n'est pas un FQDN valide : $value"
  [[ "$value" != *..* ]] || fail "$name contient deux points consécutifs."
  [[ "$value" != *A_COMPLETER* ]] || fail "Renseigner $name dans config.env."
}
validate_fqdn AUTHENTIK_FQDN
validate_fqdn LONGHORN_FQDN
validate_fqdn HEADLAMP_FQDN
[[ "$LONGHORN_FQDN" != "$HEADLAMP_FQDN" ]] || fail "LONGHORN_FQDN et HEADLAMP_FQDN doivent être différents."
[[ "$LONGHORN_FQDN" != "$AUTHENTIK_FQDN" && "$HEADLAMP_FQDN" != "$AUTHENTIK_FQDN" ]] || fail "Les trois interfaces doivent avoir des FQDN distincts."
[[ "$HEADLAMP_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "HEADLAMP_NAMESPACE invalide."
[[ "$HEADLAMP_SERVICE_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "HEADLAMP_SERVICE_NAME invalide."
[[ "$HEADLAMP_SERVICE_PORT" =~ ^[0-9]+$ ]] || fail "HEADLAMP_SERVICE_PORT doit être un port numérique."
(( HEADLAMP_SERVICE_PORT >= 1 && HEADLAMP_SERVICE_PORT <= 65535 )) || fail "HEADLAMP_SERVICE_PORT hors plage."
[[ "$AUTHENTIK_TLS_MODE" == "secret" ]] || fail "Définir AUTHENTIK_TLS_MODE=secret dans config.env."
command -v jq >/dev/null 2>&1 || fail "jq est requis."
command -v openssl >/dev/null 2>&1 || fail "openssl est requis."

info "Vérification des ressources Kubernetes"
k3s kubectl get ingressclass traefik >/dev/null 2>&1 || fail "IngressClass traefik introuvable."
k3s kubectl get crd middlewares.traefik.io >/dev/null 2>&1 || fail "CRD middlewares.traefik.io introuvable."
k3s kubectl -n authentik get ingress authentik-server >/dev/null 2>&1 || fail "Ingress authentik/authentik-server introuvable."
k3s kubectl -n longhorn-system get svc longhorn-frontend >/dev/null 2>&1 || fail "Service Longhorn longhorn-frontend introuvable."
k3s kubectl -n "$HEADLAMP_NAMESPACE" get svc "$HEADLAMP_SERVICE_NAME" >/dev/null 2>&1 \
  || fail "Service $HEADLAMP_NAMESPACE/$HEADLAMP_SERVICE_NAME introuvable."

# Résoudre la release Headlamp : HEADLAMP_HELM_RELEASE doit être un nom de release,
# mais le script tolère une ancienne valeur contenant la version du chart.
HELM_RELEASES_JSON="$(helm list -n "$HEADLAMP_NAMESPACE" -o json)"
if [[ -n "$HEADLAMP_HELM_RELEASE" ]] && jq -e --arg r "$HEADLAMP_HELM_RELEASE" \
  'any(.[]; .name == $r and (.chart | startswith("headlamp-")))' <<< "$HELM_RELEASES_JSON" >/dev/null; then
  HEADLAMP_RELEASE_RESOLVED="$HEADLAMP_HELM_RELEASE"
else
  HEADLAMP_RELEASE_COUNT="$(jq -r '[.[] | select(.chart | startswith("headlamp-"))] | length' <<< "$HELM_RELEASES_JSON")"
  [[ "$HEADLAMP_RELEASE_COUNT" == "1" ]] || {
    jq -r '.[] | [.name, .namespace, .chart, .status] | @tsv' <<< "$HELM_RELEASES_JSON" >&2
    fail "Impossible d'identifier une release Headlamp unique dans $HEADLAMP_NAMESPACE."
  }
  HEADLAMP_RELEASE_RESOLVED="$(jq -r '.[] | select(.chart | startswith("headlamp-")) | .name' <<< "$HELM_RELEASES_JSON")"
  printf '[WARN] Release Headlamp détectée automatiquement : %s.\n' "$HEADLAMP_RELEASE_RESOLVED" >&2
fi
HEADLAMP_HELM_RELEASE="$HEADLAMP_RELEASE_RESOLVED"
HEADLAMP_CHART="$(jq -r --arg r "$HEADLAMP_HELM_RELEASE" '.[] | select(.name == $r) | .chart' <<< "$HELM_RELEASES_JSON")"
HEADLAMP_CHART_VERSION="${HEADLAMP_CHART#headlamp-}"
[[ "$HEADLAMP_CHART_VERSION" != "$HEADLAMP_CHART" && -n "$HEADLAMP_CHART_VERSION" ]] || fail "Version du chart Headlamp illisible : $HEADLAMP_CHART."

HEADLAMP_SERVICE_TYPE="$(k3s kubectl -n "$HEADLAMP_NAMESPACE" get svc "$HEADLAMP_SERVICE_NAME" -o jsonpath='{.spec.type}')"
if [[ "$HEADLAMP_SERVICE_TYPE" != "ClusterIP" ]]; then
  [[ "$HEADLAMP_SERVICE_TYPE" == "NodePort" || "$HEADLAMP_SERVICE_TYPE" == "LoadBalancer" ]] \
    || fail "Type de Service Headlamp inattendu : $HEADLAMP_SERVICE_TYPE."
  info "Passage du Service Headlamp en ClusterIP."
  if ! helm repo list -o json | jq -e 'any(.[]; .name == "headlamp")' >/dev/null; then
    helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ >/dev/null
  fi
  helm upgrade "$HEADLAMP_HELM_RELEASE" headlamp/headlamp \
    --namespace "$HEADLAMP_NAMESPACE" --version "$HEADLAMP_CHART_VERSION" \
    --reuse-values --set service.type=ClusterIP --wait --timeout 5m
fi

k3s kubectl -n longhorn-system get svc longhorn-frontend -o json |
  jq -e 'any(.spec.ports[]?; .port == 80)' >/dev/null || fail "longhorn-frontend n'expose pas le port 80 attendu."
k3s kubectl -n "$HEADLAMP_NAMESPACE" get svc "$HEADLAMP_SERVICE_NAME" -o json |
  jq -e --argjson p "$HEADLAMP_SERVICE_PORT" 'any(.spec.ports[]?; .port == $p)' >/dev/null \
  || fail "Le Service Headlamp n'expose pas le port $HEADLAMP_SERVICE_PORT."

TRAEFIK_SERVICE_JSON="$(k3s kubectl -n kube-system get svc traefik -o json)"
jq -e 'any(.spec.ports[]?; .port == 443)' <<< "$TRAEFIK_SERVICE_JSON" >/dev/null || fail "Traefik ne publie pas le port 443. Exécuter d'abord scripts/02b-configure-ingress.sh."
if jq -e 'any(.spec.ports[]?; .port == 80)' <<< "$TRAEFIK_SERVICE_JSON" >/dev/null; then
  fail "Traefik publie encore le port 80. Exécuter d'abord scripts/02b-configure-ingress.sh et vérifier sa réconciliation."
fi

TMP_DIR="$(mktemp -d)"
chmod 700 "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT
TLS_CERT="$TMP_DIR/tls.crt"
TLS_KEY="$TMP_DIR/tls.key"

# Le certificat est préparé par 03-deploy-authentik.sh ou importé via Portainer
# dans le Secret authentik/authentik-tls. Ne jamais le remplacer silencieusement
# par un autosigné lors d'une opération de synchronisation.
if ! k3s kubectl -n authentik get secret "$AUTHENTIK_TLS_SECRET_NAME" -o json > "$TMP_DIR/source-secret.json" 2>/dev/null; then
  fail "Secret TLS authentik/${AUTHENTIK_TLS_SECRET_NAME} absent. Importez le certificat dans Portainer (namespace authentik, type TLS) ou terminez l'installation initiale."
fi
jq -e '.type == "kubernetes.io/tls" and .data["tls.crt"] != null and .data["tls.key"] != null' \
  "$TMP_DIR/source-secret.json" >/dev/null \
  || fail "Secret authentik/${AUTHENTIK_TLS_SECRET_NAME} invalide : type attendu kubernetes.io/tls avec tls.crt et tls.key."
jq -r '.data["tls.crt"]' "$TMP_DIR/source-secret.json" | base64 -d > "$TLS_CERT"
jq -r '.data["tls.key"]' "$TMP_DIR/source-secret.json" | base64 -d > "$TLS_KEY"
chmod 600 "$TLS_CERT" "$TLS_KEY"
openssl x509 -in "$TLS_CERT" -noout -checkend 0 >/dev/null 2>&1 \
  || fail "Le certificat importé est expiré ou illisible. Aucun remplacement automatique effectué."
openssl pkey -in "$TLS_KEY" -noout >/dev/null 2>&1 \
  || fail "La clé privée importée est illisible ou chiffrée. Utilisez une clé PEM privée non chiffrée."
CERT_PUB="$(openssl x509 -in "$TLS_CERT" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')"
KEY_PUB="$(openssl pkey -in "$TLS_KEY" -pubout -outform DER | sha256sum | awk '{print $1}')"
[[ "$CERT_PUB" == "$KEY_PUB" ]] || fail "La clé privée ne correspond pas au certificat importé."
for host in "$AUTHENTIK_FQDN" "$LONGHORN_FQDN" "$HEADLAMP_FQDN"; do
  openssl x509 -in "$TLS_CERT" -noout -checkhost "$host" >/dev/null 2>&1 \
    || fail "Le certificat importé ne couvre pas le SAN ${host}. Il doit couvrir les trois FQDN du kit."
done
info "Certificat TLS vérifié : SAN, dates, clé privée et correspondance cryptographique OK."
openssl x509 -in "$TLS_CERT" -noout -subject -issuer -dates

LONGHORN_TLS_SECRET="longhorn-dashboard-tls"
HEADLAMP_TLS_SECRET="headlamp-dashboard-tls"
k3s kubectl -n longhorn-system create secret tls "$LONGHORN_TLS_SECRET" \
  --cert="$TLS_CERT" --key="$TLS_KEY" --dry-run=client -o yaml | k3s kubectl apply -f -
k3s kubectl -n "$HEADLAMP_NAMESPACE" create secret tls "$HEADLAMP_TLS_SECRET" \
  --cert="$TLS_CERT" --key="$TLS_KEY" --dry-run=client -o yaml | k3s kubectl apply -f -

# Activer également HTTPS sur l'Ingress Authentik déjà déployé.
AUTH_TLS_PATCH="$(jq -n --arg secret "$AUTHENTIK_TLS_SECRET_NAME" --arg host "$AUTHENTIK_FQDN" \
  '{metadata:{annotations:{"traefik.ingress.kubernetes.io/router.entrypoints":"websecure"}},spec:{tls:[{secretName:$secret,hosts:[$host]}]}}')"
k3s kubectl -n authentik patch ingress authentik-server --type=merge -p "$AUTH_TLS_PATCH"

# Longhorn UI ne possède pas d'authentification intégrée : protéger l'Ingress avec BasicAuth.
# Préserver les identifiants existants lors d'une simple resynchronisation du certificat.
if [[ "$ROTATE_LONGHORN_AUTH" == "true" ]] || ! k3s kubectl -n longhorn-system get secret longhorn-basic-auth >/dev/null 2>&1; then
  if [[ -t 0 ]]; then
    read -r -p "Utilisateur BasicAuth Longhorn : " LONGHORN_BASIC_AUTH_USER
    [[ "$LONGHORN_BASIC_AUTH_USER" =~ ^[A-Za-z0-9._-]{2,64}$ ]] || fail "Nom utilisateur invalide (2-64 caractères alphanumériques, ., _ ou -)."
    read -r -s -p "Mot de passe Longhorn (16 caractères minimum) : " LONGHORN_BASIC_AUTH_PASSWORD
    printf '\n'
    read -r -s -p "Confirmer le mot de passe : " LONGHORN_BASIC_AUTH_CONFIRM
    printf '\n'
  else
    fail "Le secret BasicAuth Longhorn n'existe pas. Exécuter en terminal interactif ou créer ce Secret avant de poursuivre."
  fi
  [[ "$LONGHORN_BASIC_AUTH_PASSWORD" == "$LONGHORN_BASIC_AUTH_CONFIRM" ]] || fail "Les deux mots de passe ne correspondent pas."
  [[ ${#LONGHORN_BASIC_AUTH_PASSWORD} -ge 16 ]] || fail "Le mot de passe Longhorn doit contenir au moins 16 caractères."
  AUTH_HASH="$(printf '%s' "$LONGHORN_BASIC_AUTH_PASSWORD" | openssl passwd -apr1 -stdin)"
  [[ "$AUTH_HASH" == '$apr1$'* ]] || fail "Impossible de produire le hash APR1 BasicAuth."
  printf '%s:%s\n' "$LONGHORN_BASIC_AUTH_USER" "$AUTH_HASH" > "$TMP_DIR/users"
  chmod 600 "$TMP_DIR/users"
  k3s kubectl -n longhorn-system create secret generic longhorn-basic-auth \
    --from-file=users="$TMP_DIR/users" --dry-run=client -o yaml | k3s kubectl apply -f -
  unset LONGHORN_BASIC_AUTH_PASSWORD LONGHORN_BASIC_AUTH_CONFIRM AUTH_HASH
else
  info "Secret BasicAuth Longhorn existant conservé (aucune rotation demandée)."
fi

mkdir -p "$ROOT_DIR/output"
cat > "$ROOT_DIR/output/dashboard-middlewares.yaml" <<'MIDDLEWARES_EOF'
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: longhorn-auth
  namespace: longhorn-system
spec:
  basicAuth:
    secret: longhorn-basic-auth
    realm: "Longhorn UI"
    removeHeader: true
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: longhorn-buffering
  namespace: longhorn-system
spec:
  buffering:
    maxRequestBodyBytes: 10485760000
MIDDLEWARES_EOF

cat > "$ROOT_DIR/output/longhorn-ingress.yaml" <<LONGHORN_EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: longhorn-ui
  namespace: longhorn-system
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.middlewares: longhorn-system-longhorn-auth@kubernetescrd,longhorn-system-longhorn-buffering@kubernetescrd
spec:
  ingressClassName: traefik
  tls:
    - secretName: ${LONGHORN_TLS_SECRET}
      hosts:
        - ${LONGHORN_FQDN}
  rules:
    - host: ${LONGHORN_FQDN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: longhorn-frontend
                port:
                  number: 80
LONGHORN_EOF

cat > "$ROOT_DIR/output/headlamp-ingress.yaml" <<HEADLAMP_EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: headlamp
  namespace: ${HEADLAMP_NAMESPACE}
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  ingressClassName: traefik
  tls:
    - secretName: ${HEADLAMP_TLS_SECRET}
      hosts:
        - ${HEADLAMP_FQDN}
  rules:
    - host: ${HEADLAMP_FQDN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${HEADLAMP_SERVICE_NAME}
                port:
                  number: ${HEADLAMP_SERVICE_PORT}
HEADLAMP_EOF

info "Application des Middlewares et des Ingress HTTPS"
k3s kubectl apply -f "$ROOT_DIR/output/dashboard-middlewares.yaml"
k3s kubectl apply -f "$ROOT_DIR/output/longhorn-ingress.yaml"
k3s kubectl apply -f "$ROOT_DIR/output/headlamp-ingress.yaml"

info "Vérification des trois Ingress HTTPS"
k3s kubectl -n authentik get ingress authentik-server
k3s kubectl -n longhorn-system get ingress longhorn-ui
k3s kubectl -n "$HEADLAMP_NAMESPACE" get ingress headlamp
printf '\nDNS requis vers la VIP %s :\n  %s\n  %s\n  %s\n' \
  "$INGRESS_VIP" "$AUTHENTIK_FQDN" "$LONGHORN_FQDN" "$HEADLAMP_FQDN"
printf '\nURLs :\n  https://%s\n  https://%s\n  https://%s\n' \
  "$AUTHENTIK_FQDN" "$LONGHORN_FQDN" "$HEADLAMP_FQDN"
printf '\nVérifier la chaîne de confiance du certificat sur les postes clients.\n'
printf 'Longhorn est protégé par BasicAuth. Headlamp conserve son authentification Kubernetes configurée dans sa release Helm.\n'
