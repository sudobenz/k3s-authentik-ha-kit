#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_root
load_config
validate_common

[[ -f /etc/rancher/k3s/k3s.yaml ]] || fail "À exécuter sur le nœud 1."
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export_proxy_environment

# Le script ne fait que l'installation initiale. Il ne doit jamais servir à une mise à niveau.
if helm status authentik -n authentik >/dev/null 2>&1; then
  fail "Une release Helm authentik existe déjà. Ce script n'effectue aucune mise à niveau."
fi
if k3s kubectl -n authentik get cluster authentik-db >/dev/null 2>&1; then
  fail "Le cluster PostgreSQL authentik-db existe déjà. Refus de réinitialiser une installation existante."
fi
if k3s kubectl -n authentik get pvc authentik-files >/dev/null 2>&1; then
  fail "Le PVC authentik-files existe déjà. Vérifiez l'installation existante avant de continuer."
fi
if [[ "$AUTHENTIK_TLS_MODE" == "secret" ]]; then
  require_value AUTHENTIK_TLS_SECRET_NAME
  command -v openssl >/dev/null 2>&1 || fail "openssl est requis pour générer le certificat TLS autosigné."
fi

for n in "$NODE1_NAME" "$NODE2_NAME" "$NODE3_NAME"; do
  k3s kubectl wait --for=condition=Ready "node/$n" --timeout=180s
done

"${SCRIPT_DIR}/00-install-helm.sh"
k3s kubectl get storageclass "$PG_STORAGE_CLASS" "$AUTHENTIK_FILES_STORAGE_CLASS" >/dev/null \
  || fail "La StorageClass Longhorn PostgreSQL ou RWX est absente. Exécuter scripts/02a-install-longhorn.sh."

info "Installation CloudNativePG ${CNPG_VERSION}"
k3s kubectl apply --server-side -f "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-${CNPG_VERSION%.*}/releases/cnpg-${CNPG_VERSION}.yaml"
k3s kubectl rollout status deployment/cnpg-controller-manager -n cnpg-system --timeout=600s

k3s kubectl create namespace authentik --dry-run=client -o yaml | k3s kubectl apply -f -

info "Création des secrets PostgreSQL et Authentik"
k3s kubectl -n authentik create secret generic authentik-db-credentials \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=authentik \
  --from-literal=password="$PG_PASSWORD" \
  --dry-run=client -o yaml | k3s kubectl apply -f -

CONFIG_ENV_FILE="$(mktemp)"
chmod 600 "$CONFIG_ENV_FILE"
trap 'rm -f "$CONFIG_ENV_FILE"' EXIT
{
  printf 'AUTHENTIK_SECRET_KEY=%s\n' "$AUTHENTIK_SECRET_KEY"
  printf 'AUTHENTIK_POSTGRESQL__HOST=%s\n' 'authentik-db-rw.authentik.svc.cluster.local'
  printf 'AUTHENTIK_POSTGRESQL__NAME=%s\n' 'authentik'
  printf 'AUTHENTIK_POSTGRESQL__USER=%s\n' 'authentik'
  printf 'AUTHENTIK_POSTGRESQL__PORT=%s\n' '5432'
  printf 'AUTHENTIK_POSTGRESQL__PASSWORD=%s\n' "$PG_PASSWORD"
  printf 'AUTHENTIK_ERROR_REPORTING__ENABLED=%s\n' 'false'
  printf 'AUTHENTIK_LOG_LEVEL=%s\n' 'info'
  printf 'AUTHENTIK_WEB__PATH=%s\n' '/'
  printf 'AUTHENTIK_OUTPOSTS__CONTAINER_IMAGE_BASE=%s\n' 'ghcr.io/goauthentik/%(type)s:%(version)s'
  printf 'AUTHENTIK_STORAGE__BACKEND=%s\n' 'file'
} > "$CONFIG_ENV_FILE"
k3s kubectl -n authentik create secret generic authentik-config \
  --from-env-file="$CONFIG_ENV_FILE" --dry-run=client -o yaml | k3s kubectl apply -f -
rm -f "$CONFIG_ENV_FILE"
trap - EXIT

if [[ "$AUTHENTIK_TLS_MODE" == "secret" ]]; then
  TLS_TMP_DIR="$(mktemp -d)"
  chmod 700 "$TLS_TMP_DIR"
  trap 'rm -rf "$TLS_TMP_DIR"' EXIT
  TLS_SAN_LIST="DNS:${AUTHENTIK_FQDN}"
  for optional_host in "${LONGHORN_FQDN:-}" "${HEADLAMP_FQDN:-}"; do
    if [[ -n "$optional_host" ]]; then
      [[ "$optional_host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$optional_host" != *..* ]] \
        || fail "Nom DNS invalide dans config.env : $optional_host"
      TLS_SAN_LIST+=",DNS:${optional_host}"
    fi
  done
  info "Génération du certificat TLS autosigné (SAN : ${TLS_SAN_LIST})"
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 397 \
    -keyout "$TLS_TMP_DIR/tls.key" -out "$TLS_TMP_DIR/tls.crt" \
    -subj "/CN=${AUTHENTIK_FQDN}" \
    -addext "subjectAltName=${TLS_SAN_LIST}" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth"
  chmod 600 "$TLS_TMP_DIR/tls.crt" "$TLS_TMP_DIR/tls.key"
  k3s kubectl -n authentik create secret tls "$AUTHENTIK_TLS_SECRET_NAME" \
    --cert="$TLS_TMP_DIR/tls.crt" --key="$TLS_TMP_DIR/tls.key" \
    --dry-run=client -o yaml | k3s kubectl apply -f -
  rm -rf "$TLS_TMP_DIR"
  trap - EXIT
fi

# Le reverse proxy d'entreprise et les services internes ne doivent pas passer par le proxy HTTP.
NO_PROXY_EFFECTIVE="$(make_no_proxy)"
PROXY_ARGS=()
if [[ "$AUTHENTIK_USE_PROXY" == "true" ]]; then
  [[ -z "${HTTP_PROXY:-}" ]] || PROXY_ARGS+=(--from-literal="HTTP_PROXY=${HTTP_PROXY}" --from-literal="http_proxy=${HTTP_PROXY}")
  [[ -z "${HTTPS_PROXY:-}" ]] || PROXY_ARGS+=(--from-literal="HTTPS_PROXY=${HTTPS_PROXY}" --from-literal="https_proxy=${HTTPS_PROXY}")
  PROXY_ARGS+=(--from-literal="NO_PROXY=${NO_PROXY_EFFECTIVE}" --from-literal="no_proxy=${NO_PROXY_EFFECTIVE}")
fi
k3s kubectl -n authentik create secret generic authentik-runtime \
  --from-literal="AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS=${AUTHENTIK_TRUSTED_PROXY_CIDRS}" \
  "${PROXY_ARGS[@]}" \
  --dry-run=client -o yaml | k3s kubectl apply -f -

SYNC_YAML=""
case "$PG_SYNC_MODE" in
  async) SYNC_YAML='  postgresql: {}' ;;
  preferred)
    SYNC_YAML=$(cat <<'EOF_SYNC'
  postgresql:
    synchronous:
      method: any
      number: 1
      dataDurability: preferred
      failoverQuorum: true
EOF_SYNC
)
    ;;
  required)
    SYNC_YAML=$(cat <<'EOF_SYNC'
  postgresql:
    synchronous:
      method: any
      number: 1
      dataDurability: required
      failoverQuorum: true
EOF_SYNC
)
    ;;
esac

mkdir -p "${ROOT_DIR}/output"
PG_MANIFEST="${ROOT_DIR}/output/authentik-postgres.yaml"
cat > "$PG_MANIFEST" <<EOF_PG
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: authentik-db
  namespace: authentik
spec:
  instances: 3
  imageName: "${POSTGRES_IMAGE}"
  resources:
    requests:
      cpu: "${POSTGRES_CPU_REQUEST}"
      memory: "${POSTGRES_MEMORY_REQUEST}"
  storage:
    storageClass: "${PG_STORAGE_CLASS}"
    size: "${PG_STORAGE_SIZE}"
  affinity:
    podAntiAffinityType: required
    topologyKey: kubernetes.io/hostname
  bootstrap:
    initdb:
      database: authentik
      owner: authentik
      secret:
        name: authentik-db-credentials
${SYNC_YAML}
EOF_PG

info "Déploiement PostgreSQL (3 instances, une par nœud, stockage strict-local)"
k3s kubectl apply -f "$PG_MANIFEST"
k3s kubectl -n authentik wait --for=condition=Ready cluster/authentik-db --timeout=1800s
k3s kubectl -n authentik wait --for=condition=Ready pod -l cnpg.io/cluster=authentik-db --timeout=1800s

info "Préparation du PVC partagé /data"
"${SCRIPT_DIR}/03a-prepare-files.sh"

info "Préparation de la configuration Helm Authentik ${AUTHENTIK_CHART_VERSION}"
helm repo add authentik https://charts.goauthentik.io --force-update
helm repo update authentik

VALUES_FILE="${ROOT_DIR}/output/authentik-values.yaml"
if [[ "$AUTHENTIK_TLS_MODE" == "secret" ]]; then
  AUTHENTIK_INGRESS_ENTRYPOINT="websecure"
  TLS_VALUES=$(cat <<EOF_TLS
    tls:
      - secretName: "${AUTHENTIK_TLS_SECRET_NAME}"
        hosts:
          - "${AUTHENTIK_FQDN}"
EOF_TLS
)
else
  AUTHENTIK_INGRESS_ENTRYPOINT="web"
  TLS_VALUES='    tls: []'
fi

CORPORATE_CA_VALUES=""
if [[ -n "${CORPORATE_CA_FILE:-}" ]]; then
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) HOST_CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt" ;;
    rhel|rocky|almalinux|centos|fedora) HOST_CA_BUNDLE="/etc/pki/tls/certs/ca-bundle.crt" ;;
    *) fail "Chemin du magasin CA non pris en charge pour ${ID:-distribution inconnue}." ;;
  esac
  [[ -s "$HOST_CA_BUNDLE" ]] || fail "Magasin CA système introuvable : $HOST_CA_BUNDLE"
  # Le CA entreprise a déjà été ajouté au magasin système pendant le bootstrap des hôtes.
  CA_BUNDLE_TMP="$(mktemp)"
  trap 'rm -f "$CA_BUNDLE_TMP"' EXIT
  cp "$HOST_CA_BUNDLE" "$CA_BUNDLE_TMP"
  k3s kubectl -n authentik create configmap corporate-proxy-ca \
    --from-file=ca-certificates.crt="$CA_BUNDLE_TMP" \
    --dry-run=client -o yaml | k3s kubectl apply -f -
  rm -f "$CA_BUNDLE_TMP"
  trap - EXIT
  CORPORATE_CA_VALUES=$(cat <<'EOF_CA_VALUES'
  env:
    - name: SSL_CERT_FILE
      value: /etc/ssl/certs/ca-certificates.crt
    - name: REQUESTS_CA_BUNDLE
      value: /etc/ssl/certs/ca-certificates.crt
  volumes:
    - name: corporate-ca-bundle
      configMap:
        name: corporate-proxy-ca
  volumeMounts:
    - name: corporate-ca-bundle
      mountPath: /etc/ssl/certs/ca-certificates.crt
      subPath: ca-certificates.crt
      readOnly: true
EOF_CA_VALUES
)
fi

cat > "$VALUES_FILE" <<EOF_VALUES
global:
  image:
    tag: "${AUTHENTIK_VERSION}"
  affinity:
    podAntiAffinity: soft
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    fsGroupChangePolicy: OnRootMismatch
  deploymentStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 0
      maxUnavailable: 1
  envFrom:
    - secretRef:
        name: authentik-runtime
${CORPORATE_CA_VALUES}
authentik:
  existingSecret:
    secretName: authentik-config
  postgresql:
    host: authentik-db-rw.authentik.svc.cluster.local
    name: authentik
    user: authentik
    port: 5432
postgresql:
  enabled: false
server:
  volumes:
    - name: authentik-files
      persistentVolumeClaim:
        claimName: authentik-files
  volumeMounts:
    - name: authentik-files
      mountPath: /data
  replicas: ${AUTHENTIK_SERVER_REPLICAS}
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: ScheduleAnyway
  resources:
    requests:
      cpu: "${AUTHENTIK_SERVER_CPU_REQUEST}"
      memory: "${AUTHENTIK_SERVER_MEMORY_REQUEST}"
  pdb:
    enabled: true
    minAvailable: 2
  ingress:
    enabled: true
    ingressClassName: traefik
    annotations:
      traefik.ingress.kubernetes.io/router.entrypoints: ${AUTHENTIK_INGRESS_ENTRYPOINT}
    hosts:
      - "${AUTHENTIK_FQDN}"
${TLS_VALUES}
worker:
  volumes:
    - name: authentik-files
      persistentVolumeClaim:
        claimName: authentik-files
  volumeMounts:
    - name: authentik-files
      mountPath: /data
  replicas: ${AUTHENTIK_WORKER_REPLICAS}
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: ScheduleAnyway
  resources:
    requests:
      cpu: "${AUTHENTIK_WORKER_CPU_REQUEST}"
      memory: "${AUTHENTIK_WORKER_MEMORY_REQUEST}"
  pdb:
    enabled: true
    maxUnavailable: 1
EOF_VALUES

"${SCRIPT_DIR}/03b-validate-chart.sh"

info "Installation initiale Authentik (chart ${AUTHENTIK_CHART_VERSION}, image ${AUTHENTIK_VERSION})"
helm install authentik authentik/authentik \
  --namespace authentik --create-namespace \
  --version "$AUTHENTIK_CHART_VERSION" \
  --values "$VALUES_FILE" \
  --wait --timeout 1800s

k3s kubectl -n authentik rollout status deployment/authentik-server --timeout=900s
k3s kubectl -n authentik rollout status deployment/authentik-worker --timeout=900s

# Le montage des pods Authentik déclenche l'attachement du volume RWX et le démarrage du share-manager.
# C'est seulement à partir de ce moment que l'état healthy est attendu.
PV_NAME="$(k3s kubectl -n authentik get pvc authentik-files -o jsonpath='{.spec.volumeName}')"
[[ -n "$PV_NAME" ]] || fail "Le PVC authentik-files ne référence aucun PersistentVolume après installation."
VOLUME_NAME="$(k3s kubectl get pv "$PV_NAME" -o jsonpath='{.spec.csi.volumeHandle}')"
[[ -n "$VOLUME_NAME" ]] || fail "Le PersistentVolume $PV_NAME ne fournit pas de volumeHandle Longhorn."
VOLUME_JSON="${ROOT_DIR}/output/longhorn-authentik-files-volume.json"
info "Vérification du volume RWX après montage par les pods Authentik (healthy + share-manager running)"
DEADLINE=$((SECONDS + 600))
RWX_HEALTHY=false
while (( SECONDS < DEADLINE )); do
  if k3s kubectl -n longhorn-system get volumes.longhorn.io "$VOLUME_NAME" -o json > "$VOLUME_JSON" 2>/dev/null; then
    if python3 - "$VOLUME_JSON" <<'PY'
import json,sys
v=json.load(open(sys.argv[1],encoding='utf-8'))
status=v.get('status',{})
if status.get('robustness') == 'healthy' and status.get('shareState') == 'running':
    raise SystemExit(0)
raise SystemExit(1)
PY
    then
      RWX_HEALTHY=true
      break
    fi
  fi
  sleep 5
done
if [[ "$RWX_HEALTHY" != "true" ]]; then
  echo "État détaillé du volume Longhorn :" >&2
  k3s kubectl -n longhorn-system describe volumes.longhorn.io "$VOLUME_NAME" >&2 || true
  echo "Share Manager :" >&2
  k3s kubectl -n longhorn-system get pods -o wide | grep share-manager >&2 || true
  fail "Le volume RWX n'est pas healthy ou son share-manager n'est pas running après 600 secondes."
fi

info "Installation terminée"
k3s kubectl -n authentik get pods -o wide
k3s kubectl -n authentik get pvc
k3s kubectl -n authentik get cluster authentik-db
k3s kubectl -n kube-system get svc traefik -o wide
printf '\nURL Authentik : %s://%s\n' "$( [[ "$AUTHENTIK_TLS_MODE" == "secret" ]] && echo https || echo http )" "$AUTHENTIK_FQDN"
printf 'VIP Ingress à publier en DNS : %s\n' "$INGRESS_VIP"
printf 'Manifests générés dans : %s/output\n' "$ROOT_DIR"
printf 'Mise à niveau Authentik : opération séparée, non exécutée par ce kit.\n'
