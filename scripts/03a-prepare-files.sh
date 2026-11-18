#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
load_config
validate_common
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

SC_JSON="${ROOT_DIR}/output/authentik-rwx-storageclass.json"
k3s kubectl get storageclass "$AUTHENTIK_FILES_STORAGE_CLASS" -o json > "$SC_JSON" \
  || fail "StorageClass Longhorn RWX absente. Exécuter d'abord scripts/02a-install-longhorn.sh."
python3 - "$SC_JSON" <<'PY'
import json,sys
sc=json.load(open(sys.argv[1],encoding='utf-8'))
if sc.get('provisioner') != 'driver.longhorn.io':
    raise SystemExit('La StorageClass RWX doit être provisionnée par Longhorn, dans le cluster K3s.')
p=sc.get('parameters',{})
if p.get('numberOfReplicas') != '3':
    raise SystemExit('La StorageClass RWX doit utiliser trois réplicas Longhorn.')
if p.get('migratable','false').lower() != 'false':
    raise SystemExit('La StorageClass doit créer un volume RWX générique non-migratable.')
PY
if k3s kubectl -n authentik get pvc authentik-files >/dev/null 2>&1; then
  fail "Le PVC authentik-files existe déjà. Vérifiez son état avant toute réexécution."
fi

cat <<EOF_YAML | k3s kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: authentik-files
  namespace: authentik
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: "${AUTHENTIK_FILES_STORAGE_CLASS}"
  resources:
    requests:
      storage: "${AUTHENTIK_FILES_SIZE}"
EOF_YAML

info "Attente du PVC RWX provisionné par Longhorn dans le cluster K3s"
k3s kubectl -n authentik wait --for=jsonpath='{.status.phase}'=Bound pvc/authentik-files --timeout=900s
PV_NAME="$(k3s kubectl -n authentik get pvc authentik-files -o jsonpath='{.spec.volumeName}')"
[[ -n "$PV_NAME" ]] || fail "Le PVC authentik-files est Bound mais aucun PV n'est associé."
VOLUME_NAME="$(k3s kubectl get pv "$PV_NAME" -o jsonpath='{.spec.csi.volumeHandle}')"
[[ -n "$VOLUME_NAME" ]] || fail "Le PV $PV_NAME ne fournit pas de volumeHandle CSI Longhorn."
mkdir -p "${ROOT_DIR}/output"
VOLUME_JSON="${ROOT_DIR}/output/longhorn-authentik-files-volume.json"
REPLICAS_JSON="${ROOT_DIR}/output/longhorn-authentik-files-replicas.json"
info "Vérification de la planification Longhorn /data (3 réplicas sur 3 nœuds)"
info "Le volume RWX peut rester detached/unknown tant qu'aucun pod ne le monte ; le contrôle healthy sera fait après installation d'Authentik."
DEADLINE=$((SECONDS + 900))
SCHEDULED_OK=false
while (( SECONDS < DEADLINE )); do
  if k3s kubectl -n longhorn-system get volumes.longhorn.io "$VOLUME_NAME" -o json > "$VOLUME_JSON" 2>/dev/null \
    && k3s kubectl -n longhorn-system get replicas.longhorn.io -o json > "$REPLICAS_JSON" 2>/dev/null; then
    if python3 - "$VOLUME_JSON" "$REPLICAS_JSON" <<'PY'
import json,sys
v=json.load(open(sys.argv[1],encoding='utf-8'))
all_replicas=json.load(open(sys.argv[2],encoding='utf-8')).get('items',[])
spec=v.get('spec',{})
conditions={c.get('type'): c.get('status') for c in v.get('status',{}).get('conditions',[])}
name=v.get('metadata',{}).get('name')
replicas=[r for r in all_replicas if r.get('spec',{}).get('volumeName') == name]
nodes={r.get('spec',{}).get('nodeID') for r in replicas if r.get('spec',{}).get('nodeID')}
failed=[r.get('metadata',{}).get('name') for r in replicas if r.get('spec',{}).get('failedAt')]
if spec.get('numberOfReplicas') != 3:
    raise SystemExit(1)
if conditions.get('Scheduled') != 'True':
    raise SystemExit(1)
if len(replicas) != 3 or len(nodes) != 3 or failed:
    raise SystemExit(1)
PY
    then
      SCHEDULED_OK=true
      break
    fi
  fi
  sleep 5
done
if [[ "$SCHEDULED_OK" != "true" ]]; then
  echo "État du volume Longhorn :" >&2
  k3s kubectl -n longhorn-system get volumes.longhorn.io "$VOLUME_NAME" -o wide >&2 || true
  echo "Réplicas Longhorn associés :" >&2
  k3s kubectl -n longhorn-system get replicas.longhorn.io -o wide 2>/dev/null | grep "$VOLUME_NAME" >&2 || true
  fail "Longhorn n'a pas planifié trois réplicas sur trois nœuds en 900 secondes."
fi

k3s kubectl -n authentik get pvc authentik-files -o json > "${ROOT_DIR}/output/authentik-files-pvc.json"
python3 - "${ROOT_DIR}/output/authentik-files-pvc.json" "$AUTHENTIK_FILES_STORAGE_CLASS" <<'PY'
import json,sys
p=json.load(open(sys.argv[1],encoding='utf-8'))
expected_storage_class=sys.argv[2]
if 'ReadWriteMany' not in p.get('spec',{}).get('accessModes',[]):
    raise SystemExit('Le PVC authentik-files ne déclare pas ReadWriteMany.')
if p.get('status',{}).get('phase') != 'Bound':
    raise SystemExit('Le PVC authentik-files n’est pas Bound.')
if p.get('spec',{}).get('storageClassName') != expected_storage_class:
    raise SystemExit('Le PVC authentik-files n’utilise pas la StorageClass Longhorn interne.')
PY

printf '\nPVC /data lié : %s (%s), Longhorn 3 réplicas.\n' "$AUTHENTIK_FILES_STORAGE_CLASS" "$AUTHENTIK_FILES_SIZE"
printf 'Le volume RWX est servi par un share-manager NFS déployé dans longhorn-system, au sein de ce cluster K3s.\n'
