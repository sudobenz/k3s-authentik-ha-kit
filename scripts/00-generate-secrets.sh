#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
OUT="${ROOT_DIR}/secrets.env"
command -v openssl >/dev/null 2>&1 || { echo "openssl est requis." >&2; exit 1; }
if [[ -e "$OUT" ]]; then
  echo "${OUT} existe déjà. Refus de l'écraser pour ne pas changer les secrets d'un cluster existant." >&2
  exit 1
fi
umask 077
K3S_TOKEN="$(openssl rand -hex 32)"
PG_PASSWORD="$(openssl rand -hex 32)"
AUTHENTIK_SECRET_KEY="$(openssl rand -hex 48)"
{
  printf 'K3S_TOKEN="%s"\n' "$K3S_TOKEN"
  printf 'K3S_JOIN_TOKEN=""\n'
  printf 'PG_PASSWORD="%s"\n' "$PG_PASSWORD"
  printf 'AUTHENTIK_SECRET_KEY="%s"\n' "$AUTHENTIK_SECRET_KEY"
} > "$OUT"
chmod 600 "$OUT"
echo "Secrets créés dans secrets.env (mode 600). Copiez ce fichier initial uniquement sur le nœud 1. Le script 01 générera ensuite un token de jointure sécurisé à recopier sur les nœuds 2 et 3. Ne le versionnez pas."
