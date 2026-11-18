#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_upgrade_config
full_preflight
"$ROOT_DIR/scripts/04-check.sh"
printf '\nPOST-CHECK GLOBAL OK : le cluster est revenu à son état nominal. Aucun autre upgrade n’est déclenché.\n'
