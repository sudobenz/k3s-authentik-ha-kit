#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_upgrade_config; require_cluster
[[ $# -ge 3 ]] || fail "Usage: $0 <AUTHENTIK_TARGET_YYYY.M.P> --plan|--apply --backup-evidence <fichier>"
TARGET="$1"; APPLY="$2"; [[ "$APPLY" == --apply || "$APPLY" == --plan ]] || fail 'Utiliser --plan ou --apply.'
EVIDENCE="${4:-}"; [[ "${3:-}" == --backup-evidence && -n "$EVIDENCE" ]] || fail '--backup-evidence obligatoire.'
verify_backup_evidence "$EVIDENCE" yes yes yes
CURRENT="$AUTHENTIK_VERSION"
python3 - "$CURRENT" "$TARGET" <<'PYVER'
import re,sys
p=r'^(\d{4})\.(\d+)\.(\d+)$'
a=re.fullmatch(p,sys.argv[1]); b=re.fullmatch(p,sys.argv[2])
if not a or not b: raise SystemExit('Authentik attend une version exacte YYYY.M.P.')
if tuple(map(int,b.groups()))<=tuple(map(int,a.groups())): raise SystemExit('La cible Authentik doit être supérieure à la version actuelle.')
PYVER
full_preflight
helm repo add authentik https://charts.goauthentik.io --force-update >/dev/null
helm repo update authentik >/dev/null
helm show chart authentik/authentik --version "$TARGET" >/dev/null || fail "Chart Authentik $TARGET introuvable."
printf 'Authentik: image/chart %s -> %s. Les Outposts gérés séparément doivent être alignés après cette opération.\n' "$CURRENT" "$TARGET"
if [[ "$APPLY" == --plan ]]; then
  printf 'Commande prévue: helm upgrade authentik authentik/authentik -n authentik --version %s --reuse-values --set global.image.tag=%s --wait --timeout 30m\n' "$TARGET" "$TARGET"
  echo 'PLAN SEUL : aucune modification.'; exit 0
fi
cp -a "$CONFIG_FILE" "$BACKUP_DIR/config.env.$(date +%Y%m%d-%H%M%S).bak"
helm upgrade authentik authentik/authentik --namespace authentik --version "$TARGET" --reuse-values --set "global.image.tag=$TARGET" --wait --timeout 30m
k -n authentik rollout status deployment/authentik-server --timeout=1800s
k -n authentik rollout status deployment/authentik-worker --timeout=1800s
set_config_var AUTHENTIK_VERSION "$TARGET"
set_config_var AUTHENTIK_CHART_VERSION "$TARGET"
full_preflight
"$ROOT_DIR/scripts/04-check.sh"
printf '\nAuthentik mis à niveau vers %s. Vérifier les Outposts externes, LDAP/OIDC/SAML, MFA et flux d’authentification.\n' "$TARGET"
