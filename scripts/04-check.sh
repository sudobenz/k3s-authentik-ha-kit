#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
load_config
validate_common
export_proxy_environment
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
mkdir -p "$ROOT_DIR/output"

for n in "$NODE1_NAME" "$NODE2_NAME" "$NODE3_NAME"; do
  k3s kubectl wait --for=condition=Ready "node/$n" --timeout=120s
done

for d in authentik-server authentik-worker; do
  k3s kubectl -n authentik rollout status "deployment/$d" --timeout=300s
done
k3s kubectl -n authentik get pods -l app.kubernetes.io/name=authentik -o json > "$ROOT_DIR/output/authentik-pods.json"
python3 - "$ROOT_DIR/output/authentik-pods.json" "$AUTHENTIK_SERVER_REPLICAS" "$AUTHENTIK_WORKER_REPLICAS" <<'PY_CHECK_AUTHENTIK'
import collections,json,sys
items=json.load(open(sys.argv[1],encoding='utf-8')).get('items',[])
expected={'server':int(sys.argv[2]),'worker':int(sys.argv[3])}
for component,wanted in expected.items():
    pods=[p for p in items if p.get('metadata',{}).get('labels',{}).get('app.kubernetes.io/component')==component]
    ready=[p for p in pods if p.get('status',{}).get('phase')=='Running' and p.get('status',{}).get('containerStatuses') and all(c.get('ready') for c in p['status']['containerStatuses'])]
    if len(ready)!=wanted:
        raise SystemExit(f'Authentik {component}: {len(ready)} pods Ready au lieu de {wanted}.')
    distribution=collections.Counter(p.get('spec',{}).get('nodeName') for p in ready)
    if len(distribution)!=3:
        raise SystemExit(f'Authentik {component}: pods répartis sur {len(distribution)} nœuds au lieu de 3.')
    if max(distribution.values())-min(distribution.values())>1:
        raise SystemExit(f'Authentik {component}: répartition déséquilibrée entre les nœuds : {dict(distribution)}')
PY_CHECK_AUTHENTIK
k3s kubectl -n kube-system rollout status deployment/traefik --timeout=300s
TRAEFIK_POLICY="$(k3s kubectl -n kube-system get svc traefik -o jsonpath='{.spec.externalTrafficPolicy}')"
[[ "$TRAEFIK_POLICY" == "Local" ]] || fail "Traefik doit avoir externalTrafficPolicy=Local pour préserver l'IP cliente (valeur actuelle : ${TRAEFIK_POLICY:-absente})."
k3s kubectl -n kube-system rollout status daemonset/kube-vip-ds --timeout=300s
# L'Operator CNPG peut être mono-réplique : il n'est pas nécessaire d'en déployer
# trois pour que PostgreSQL soit HA. On vérifie seulement qu'au moins une instance
# du contrôleur est disponible.
k3s kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout=300s
k3s kubectl -n authentik wait --for=condition=Ready cluster/authentik-db --timeout=300s

k3s kubectl -n authentik get pvc authentik-files -o json > "$ROOT_DIR/output/authentik-files-pvc.json"
k3s kubectl -n authentik get pods -o wide
k3s kubectl -n authentik get pvc
k3s kubectl -n authentik get cluster authentik-db

python3 - "$ROOT_DIR/output/authentik-files-pvc.json" "$AUTHENTIK_FILES_STORAGE_CLASS" <<'PY'
import json,sys
p=json.load(open(sys.argv[1],encoding='utf-8'))
expected=sys.argv[2]
if p.get('status',{}).get('phase')!='Bound': raise SystemExit('PVC authentik-files non Bound')
if p.get('spec',{}).get('storageClassName') != expected:
    raise SystemExit(f'PVC fichiers : StorageClass {p.get("spec",{}).get("storageClassName")} au lieu de {expected}')
if expected != 'longhorn-authentik-rwx': raise SystemExit('La StorageClass /data attendue doit être Longhorn interne à K3s.')
if 'ReadWriteMany' not in p.get('spec',{}).get('accessModes',[]): raise SystemExit('PVC fichiers non RWX')
PY

k3s kubectl -n authentik get pods -l cnpg.io/cluster=authentik-db -o json > "$ROOT_DIR/output/postgres-pods.json"
python3 - "$ROOT_DIR/output/postgres-pods.json" <<'PY'
import json,sys
items=json.load(open(sys.argv[1],encoding='utf-8')).get('items',[])
ready=[];nodes=set()
for p in items:
    statuses=p.get('status',{}).get('containerStatuses',[])
    if p.get('status',{}).get('phase')=='Running' and statuses and all(c.get('ready') for c in statuses):
        ready.append(p)
    node=p.get('spec',{}).get('nodeName')
    if node: nodes.add(node)
if len(ready)!=3: raise SystemExit(f'PostgreSQL : {len(ready)} pods Ready au lieu de 3')
if len(nodes)!=3: raise SystemExit(f'PostgreSQL : instances réparties sur {len(nodes)} nœuds au lieu de 3')
PY

DATA_PV_NAME="$(k3s kubectl -n authentik get pvc authentik-files -o jsonpath='{.spec.volumeName}')"
DATA_VOLUME_NAME="$(k3s kubectl get pv "$DATA_PV_NAME" -o jsonpath='{.spec.csi.volumeHandle}')"
[[ -n "$DATA_VOLUME_NAME" ]] || fail "VolumeHandle Longhorn du PVC authentik-files introuvable."
k3s kubectl -n longhorn-system get volumes.longhorn.io -o json > "$ROOT_DIR/output/longhorn-authentik-volumes.json"
python3 - "$ROOT_DIR/output/longhorn-authentik-volumes.json" "$DATA_VOLUME_NAME" <<'PY'
import json,sys
vols=json.load(open(sys.argv[1],encoding='utf-8')).get('items',[])
data_volume_name=sys.argv[2]
selected=[v for v in vols if v.get('status',{}).get('kubernetesStatus',{}).get('namespace')=='authentik']
pg=[v for v in selected if v.get('spec',{}).get('dataLocality')=='strict-local']
file_vol=[v for v in vols if v.get('metadata',{}).get('name')==data_volume_name]
if len(pg)!=3: raise SystemExit(f'Longhorn : {len(pg)} volumes PostgreSQL strict-local trouvés au lieu de 3')
for v in pg:
    spec=v.get('spec',{}); status=v.get('status',{})
    if status.get('robustness')!='healthy': raise SystemExit('Volume PostgreSQL Longhorn non sain : '+v['metadata']['name'])
    if spec.get('numberOfReplicas')!=1:
        raise SystemExit('Volume PostgreSQL non configuré à une copie strict-local : '+v['metadata']['name'])
if len(file_vol)!=1: raise SystemExit(f'Longhorn : volume /data Authentik {data_volume_name} trouvé {len(file_vol)} fois au lieu de 1')
fv=file_vol[0]
if fv.get('status',{}).get('robustness')!='healthy': raise SystemExit('Volume Longhorn RWX /data non healthy.')
if fv.get('spec',{}).get('numberOfReplicas')!=3: raise SystemExit('Volume Longhorn RWX /data ne possède pas trois réplicas.')
PY

scheme=https
port=443
CURL_TLS_ARGS=()
if [[ "$AUTHENTIK_TLS_MODE" == "external" ]]; then
  scheme=http
  port=80
else
  # Le kit génère initialement un certificat autosigné. -k ne valide que la
  # connectivité applicative ; la validité, la clé et les SAN sont contrôlés après.
  CURL_TLS_ARGS+=(--insecure)
fi
code=$(curl --noproxy '*' --resolve "${AUTHENTIK_FQDN}:${port}:${INGRESS_VIP}" \
  "${CURL_TLS_ARGS[@]}" --connect-timeout 5 --max-time 30 -sS -o /dev/null -w '%{http_code}' \
  "${scheme}://${AUTHENTIK_FQDN}/-/health/ready/")
[[ "$code" == 200 ]] || fail "Readiness HTTP : $code au lieu de 200"

if [[ "$AUTHENTIK_TLS_MODE" == "secret" ]]; then
  command -v openssl >/dev/null 2>&1 || fail "openssl est requis pour vérifier le certificat TLS."
  TLS_CHECK_FILE="$(mktemp)"
  trap 'rm -f "$TLS_CHECK_FILE"' EXIT
  k3s kubectl -n authentik get secret "$AUTHENTIK_TLS_SECRET_NAME" \
    -o jsonpath='{.data.tls\.crt}' | base64 -d > "$TLS_CHECK_FILE"
  openssl x509 -in "$TLS_CHECK_FILE" -noout -checkend 0 >/dev/null 2>&1 \
    || fail "Le certificat TLS Authentik est expiré ou illisible."
  for host in "$AUTHENTIK_FQDN" "$LONGHORN_FQDN" "$HEADLAMP_FQDN"; do
    openssl x509 -in "$TLS_CHECK_FILE" -noout -checkhost "$host" >/dev/null 2>&1 \
      || fail "Le certificat TLS ne couvre pas $host."
  done
  rm -f "$TLS_CHECK_FILE"
  trap - EXIT
fi

printf '\nContrôles réussis : 3 nœuds, Traefik (externalTrafficPolicy=Local), kube-vip, Operator CNPG disponible, Authentik Server %s, Worker %s minimum répartis sur 3 nœuds, PostgreSQL 3/3, PVC Longhorn RWX /data (3 réplicas), volumes DB strict-local et endpoint Authentik.\n' "$AUTHENTIK_SERVER_REPLICAS" "$AUTHENTIK_WORKER_REPLICAS"
printf 'La recette fonctionnelle, les scénarios de panne et les tests OIDC/SAML/LDAP restent à réaliser.\n'
