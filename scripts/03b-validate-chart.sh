#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
source "$(dirname "$0")/lib.sh"
require_root
load_config
validate_common
export_proxy_environment
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

out="$ROOT_DIR/output/authentik-rendered.yaml"
helm template authentik authentik/authentik -n authentik \
  --version "$AUTHENTIK_CHART_VERSION" \
  -f "$ROOT_DIR/output/authentik-values.yaml" > "$out"

python3 - "$out" "$AUTHENTIK_VERSION" "$AUTHENTIK_SERVER_REPLICAS" "$AUTHENTIK_WORKER_REPLICAS" <<'PY'
import sys,yaml
path,version,server_replicas,worker_replicas=sys.argv[1:]
objects=[o for o in yaml.safe_load_all(open(path,encoding='utf-8')) if o]
if int(worker_replicas) < 3:
    raise SystemExit('Le chart doit déployer au minimum trois Workers.')
for name,expected_replicas in (
    ('authentik-server',int(server_replicas)),
    ('authentik-worker',int(worker_replicas)),
):
    deploy=next((o for o in objects if o.get('kind')=='Deployment' and o.get('metadata',{}).get('name')==name),None)
    if deploy is None: raise SystemExit(f'Deployment absent : {name}')
    if deploy.get('spec',{}).get('replicas') != expected_replicas:
        raise SystemExit(f'Nombre de réplicas inattendu pour {name}')
    pod=deploy['spec']['template']['spec']
    spread=pod.get('topologySpreadConstraints',[])
    if not any(
        c.get('topologyKey')=='kubernetes.io/hostname'
        and c.get('maxSkew')==1
        and c.get('whenUnsatisfiable')=='ScheduleAnyway'
        for c in spread
    ):
        raise SystemExit(f'Répartition best-effort entre nœuds absente ou incorrecte : {name}')
    app=next((c for c in pod.get('containers',[]) if c.get('name') in ('server','worker')),None)
    if app is None: raise SystemExit(f'Conteneur principal absent : {name}')
    if not app.get('image','').endswith(':'+version):
        raise SystemExit(f'Tag image inattendu pour {name}: {app.get("image")}')
    volumes={v['name']:v for v in pod.get('volumes',[])}
    if not any(
        m.get('mountPath')=='/data'
        and volumes.get(m.get('name'),{}).get('persistentVolumeClaim',{}).get('claimName')=='authentik-files'
        for m in app.get('volumeMounts',[])
    ):
        raise SystemExit(f'PVC authentik-files non monté sur /data dans {name}')
    refs={e.get('secretRef',{}).get('name') for e in app.get('envFrom',[])}
    if 'authentik-runtime' not in refs:
        raise SystemExit(f'Secret authentik-runtime absent de {name}: {refs}')
    if len([m.get('mountPath') for m in app.get('volumeMounts',[])]) != len(set(m.get('mountPath') for m in app.get('volumeMounts',[]))):
        raise SystemExit(f'Montages dupliqués dans {name}')
    if pod.get('securityContext',{}).get('fsGroup') != 1000:
        raise SystemExit(f'fsGroup 1000 absent de {name}')
pdbs=[o for o in objects if o.get('kind')=='PodDisruptionBudget']
def pdb_for(component):
    return next((o for o in pdbs if o.get('spec',{}).get('selector',{}).get('matchLabels',{}).get('app.kubernetes.io/component')==component),None)
server_pdb=pdb_for('server')
worker_pdb=pdb_for('worker')
if server_pdb is None or server_pdb.get('spec',{}).get('minAvailable') != 2:
    raise SystemExit('PDB Server absent ou minAvailable différent de 2.')
if worker_pdb is None or worker_pdb.get('spec',{}).get('maxUnavailable') != 1:
    raise SystemExit('PDB Worker absent ou maxUnavailable différent de 1.')
if any(o.get('kind')=='StatefulSet' and 'postgresql' in o.get('metadata',{}).get('name','') for o in objects):
    raise SystemExit('La base PostgreSQL embarquée du chart ne doit pas être installée.')
PY

k3s kubectl apply --dry-run=server -f "$out" >/dev/null
printf 'Rendu du chart valide : image %s, Server %s, Worker %s.\n' \
  "$AUTHENTIK_VERSION" "$AUTHENTIK_SERVER_REPLICAS" "$AUTHENTIK_WORKER_REPLICAS"
