#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root; load_config; validate_common; export_proxy_environment
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
if helm status longhorn -n longhorn-system >/dev/null 2>&1; then
  fail "Release Longhorn déjà présente : ce script est réservé à l'installation initiale. Utilisez upgrade/13-upgrade-longhorn.sh pour une mise à niveau contrôlée."
fi
"$SCRIPT_DIR/00-install-helm.sh"
for n in "$NODE1_NAME" "$NODE2_NAME" "$NODE3_NAME"; do
  k3s kubectl wait --for=condition=Ready node/"$n" --timeout=300s
done
mkdir -p "$ROOT_DIR/output"
cat > "$ROOT_DIR/output/longhorn-values.yaml" <<EOF
persistence:
  defaultClass: false
csi:
  kubeletRootDir: /var/lib/kubelet
  attacherReplicaCount: 3
  provisionerReplicaCount: 3
  resizerReplicaCount: 3
  snapshotterReplicaCount: 3
defaultSettings:
  defaultDataPath: "$LONGHORN_DATA_PATH"
  defaultReplicaCount: 3
  replicaSoftAntiAffinity: false
  storageOverProvisioningPercentage: 100
  storageMinimalAvailablePercentage: 25
  upgradeChecker: false
EOF
helm repo add longhorn https://charts.longhorn.io --force-update
helm repo update longhorn
helm show chart longhorn/longhorn --version "$LONGHORN_VERSION" > "$ROOT_DIR/output/longhorn-chart-metadata.yaml"
helm upgrade --install longhorn longhorn/longhorn --namespace longhorn-system --create-namespace   --version "$LONGHORN_VERSION" -f "$ROOT_DIR/output/longhorn-values.yaml" --wait --timeout 20m
k3s kubectl -n longhorn-system rollout status daemonset/longhorn-manager --timeout=600s
k3s kubectl -n longhorn-system rollout status daemonset/longhorn-csi-plugin --timeout=600s
k3s kubectl apply -f "$ROOT_DIR/manifests/storageclasses.yaml"
# Kubernetes nodes Ready is insufficient: validate Longhorn nodes and disks.
k3s kubectl -n longhorn-system get nodes.longhorn.io -o json > "$ROOT_DIR/output/longhorn-nodes.json"
python3 - "$ROOT_DIR/output/longhorn-nodes.json" "$NODE1_NAME" "$NODE2_NAME" "$NODE3_NAME" <<'PYCHECK'
import json,sys
nodes={n['metadata']['name']:n for n in json.load(open(sys.argv[1]))['items']}
for name in sys.argv[2:]:
    n=nodes.get(name)
    if not n: raise SystemExit('Nœud Longhorn absent : '+name)
    conditions=n.get('status',{}).get('conditions',[])
    if not any(c['type']=='Ready' and c['status']=='True' for c in conditions):
        raise SystemExit('Nœud Longhorn non Ready : '+name)
    disks=n.get('status',{}).get('diskStatus',{})
    if not any(any(c['type']=='Schedulable' and c['status']=='True' for c in d.get('conditions',[])) for d in disks.values()):
        raise SystemExit('Aucun disque Longhorn planifiable : '+name)
PYCHECK
