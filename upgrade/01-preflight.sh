#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_upgrade_config
full_preflight
"$ROOT_DIR/scripts/04-check.sh"
printf '\nPré-contrôle terminé. Aucune ressource n’a été modifiée.\n'
