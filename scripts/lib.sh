#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${ROOT_DIR}/config.env"
SECRETS_FILE="${ROOT_DIR}/secrets.env"

fail() { printf 'ERREUR: %s\n' "$*" >&2; exit 1; }
info() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf 'AVERTISSEMENT: %s\n' "$*" >&2; }

load_config() {
  [[ -f "$CONFIG_FILE" ]] || fail "Fichier absent : $CONFIG_FILE. Placez le fichier config.env à la racine du kit."
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  [[ -f "$SECRETS_FILE" ]] || fail "Fichier absent : $SECRETS_FILE (lancez ./scripts/00-generate-secrets.sh une seule fois)."
  chmod 600 "$SECRETS_FILE" 2>/dev/null || true
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
}

require_root() { [[ "$(id -u)" -eq 0 ]] || fail "Exécuter ce script en root."; }

require_value() {
  local name="$1" value="${!1:-}"
  [[ -n "$value" ]] || fail "Paramètre obligatoire non renseigné : $name"
  [[ "$value" != *A_COMPLETER* ]] || fail "Remplacez le marqueur A_COMPLETER pour : $name"
}

validate_ip() {
  python3 - "$1" <<'PY'
import ipaddress,sys
try: ipaddress.IPv4Address(sys.argv[1])
except ValueError: raise SystemExit(1)
PY
}

validate_cidr() {
  python3 - "$1" <<'PY'
import ipaddress,sys
try: ipaddress.ip_network(sys.argv[1], strict=False)
except ValueError: raise SystemExit(1)
PY
}

validate_quantity() {
  local value="$1"
  [[ "$value" =~ ^[1-9][0-9]*(Ki|Mi|Gi|Ti)$ ]]
}

validate_common() {
  local k
  for k in NODE1_NAME NODE1_IP NODE2_NAME NODE2_IP NODE3_NAME NODE3_IP \
    K3S_VERSION K3S_POD_CIDR K3S_SERVICE_CIDR K3S_LOCAL_STORAGE_PATH \
    K3S_API_VIP INGRESS_VIP KUBEVIP_INTERFACE KUBEVIP_VERSION HELM_VERSION \
    AUTHENTIK_VERSION AUTHENTIK_CHART_VERSION CNPG_VERSION POSTGRES_IMAGE \
    PG_STORAGE_CLASS PG_STORAGE_SIZE PG_SYNC_MODE \
    AUTHENTIK_FQDN AUTHENTIK_SERVER_REPLICAS AUTHENTIK_WORKER_REPLICAS \
    AUTHENTIK_TRUSTED_PROXY_CIDRS AUTHENTIK_FILES_STORAGE_CLASS AUTHENTIK_FILES_SIZE \
    AUTHENTIK_SERVER_CPU_REQUEST AUTHENTIK_SERVER_MEMORY_REQUEST \
    AUTHENTIK_WORKER_CPU_REQUEST AUTHENTIK_WORKER_MEMORY_REQUEST \
    POSTGRES_CPU_REQUEST POSTGRES_MEMORY_REQUEST AUTHENTIK_TLS_MODE AUTHENTIK_USE_PROXY \
    LONGHORN_VERSION LONGHORN_DATA_PATH LONGHORN_REQUIRE_MOUNT \
    LONGHORN_FQDN HEADLAMP_NAMESPACE HEADLAMP_FQDN HEADLAMP_HELM_RELEASE \
    HEADLAMP_CHART_VERSION HEADLAMP_SERVICE_NAME HEADLAMP_SERVICE_PORT CERT_MANAGER_NAMESPACE; do
    require_value "$k"
  done

  for k in NODE1_IP NODE2_IP NODE3_IP K3S_API_VIP INGRESS_VIP; do
    validate_ip "${!k}" || fail "$k n'est pas une adresse IPv4 valide : ${!k}"
  done
  for k in K3S_POD_CIDR K3S_SERVICE_CIDR; do
    validate_cidr "${!k}" || fail "$k n'est pas un CIDR valide : ${!k}"
  done
  python3 - "$K3S_POD_CIDR" "$K3S_SERVICE_CIDR" <<'PY'
import ipaddress,sys
pod,svc=(ipaddress.ip_network(x, strict=False) for x in sys.argv[1:])
if pod.version != 4 or svc.version != 4 or pod.overlaps(svc):
    raise SystemExit("Les CIDR Pod et Service doivent être IPv4 et ne pas se chevaucher.")
PY

  [[ "$K3S_VERSION" =~ ^v1\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] || fail "K3S_VERSION doit être une version exacte v1.x.y+k3sN."
  [[ "$HELM_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "HELM_VERSION doit être une version exacte (ex. v4.3.1)."
  [[ "$AUTHENTIK_VERSION" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]] || fail "AUTHENTIK_VERSION doit être au format YYYY.MINOR.PATCH."
  [[ "$AUTHENTIK_CHART_VERSION" == "$AUTHENTIK_VERSION" ]] || fail "AUTHENTIK_CHART_VERSION doit être identique à AUTHENTIK_VERSION."
  python3 - "$AUTHENTIK_VERSION" <<'PY'
import sys
v=tuple(map(int,sys.argv[1].split('.')))
if v < (2026,8,5):
    raise SystemExit("La version Authentik doit être au moins 2026.8.5.")
PY
  [[ "$CNPG_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "CNPG_VERSION doit être une version exacte X.Y.Z; valider la compatibilité avec Kubernetes avant upgrade."
  [[ "$LONGHORN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "LONGHORN_VERSION doit être une version exacte X.Y.Z; suivre le chemin Longhorn supporté avant upgrade."
  for host_var in AUTHENTIK_FQDN LONGHORN_FQDN HEADLAMP_FQDN; do
    [[ "${!host_var}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "${!host_var}" != *..* ]] || fail "$host_var n'est pas un FQDN valide : ${!host_var}"
  done
  [[ "$HEADLAMP_CHART_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "HEADLAMP_CHART_VERSION doit être au format X.Y.Z."
  [[ "$HEADLAMP_HELM_RELEASE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "HEADLAMP_HELM_RELEASE invalide."
  [[ "$HEADLAMP_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "HEADLAMP_NAMESPACE invalide."
  [[ "$HEADLAMP_SERVICE_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "HEADLAMP_SERVICE_NAME invalide."
  [[ "$HEADLAMP_SERVICE_PORT" =~ ^[0-9]+$ ]] || fail "HEADLAMP_SERVICE_PORT doit être numérique."
  (( HEADLAMP_SERVICE_PORT >= 1 && HEADLAMP_SERVICE_PORT <= 65535 )) || fail "HEADLAMP_SERVICE_PORT hors plage."
  [[ "$CERT_MANAGER_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "CERT_MANAGER_NAMESPACE invalide."

  for k in NODE1_NAME NODE2_NAME NODE3_NAME; do
    [[ "${!k}" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]] || fail "$k contient des caractères non autorisés."
  done
  [[ "$KUBEVIP_INTERFACE" =~ ^[a-zA-Z0-9_.:-]+$ ]] || fail "KUBEVIP_INTERFACE contient des caractères non autorisés."
  [[ "$PG_STORAGE_CLASS" == "longhorn-pg-local" ]] || fail "PG_STORAGE_CLASS doit être longhorn-pg-local."
  [[ "$AUTHENTIK_FILES_STORAGE_CLASS" == "longhorn-authentik-rwx" ]] || fail "AUTHENTIK_FILES_STORAGE_CLASS doit être longhorn-authentik-rwx (StorageClass Longhorn interne au cluster)."
  validate_quantity "$PG_STORAGE_SIZE" || fail "PG_STORAGE_SIZE doit être une quantité Kubernetes (ex. 50Gi)."
  validate_quantity "$AUTHENTIK_FILES_SIZE" || fail "AUTHENTIK_FILES_SIZE doit être une quantité Kubernetes (ex. 20Gi)."
  [[ "$K3S_LOCAL_STORAGE_PATH" == /* ]] || fail "K3S_LOCAL_STORAGE_PATH doit être absolu."
  [[ "$LONGHORN_DATA_PATH" =~ ^/[a-zA-Z0-9_./-]+$ ]] || fail "LONGHORN_DATA_PATH doit être absolu."
  [[ "$LONGHORN_REQUIRE_MOUNT" == "true" || "$LONGHORN_REQUIRE_MOUNT" == "false" ]] || fail "LONGHORN_REQUIRE_MOUNT doit être true ou false."
  [[ "$AUTHENTIK_TLS_MODE" == "secret" || "$AUTHENTIK_TLS_MODE" == "external" ]] || fail "AUTHENTIK_TLS_MODE doit être secret ou external."
  [[ "$PG_SYNC_MODE" == "async" || "$PG_SYNC_MODE" == "preferred" || "$PG_SYNC_MODE" == "required" ]] || fail "PG_SYNC_MODE doit être async, preferred ou required."
  [[ "$AUTHENTIK_USE_PROXY" == "true" || "$AUTHENTIK_USE_PROXY" == "false" ]] || fail "AUTHENTIK_USE_PROXY doit être true ou false."
  [[ "$AUTHENTIK_SERVER_REPLICAS" == "3" ]] || fail "Le kit est qualifié pour exactement 3 réplicas Server."
  [[ "$AUTHENTIK_WORKER_REPLICAS" =~ ^[0-9]+$ ]] || fail "AUTHENTIK_WORKER_REPLICAS doit être un entier."
  (( AUTHENTIK_WORKER_REPLICAS >= 3 )) || fail "Il faut au minimum 3 réplicas Worker pour répartir les traitements sur les trois nœuds."
  [[ "$NODE1_NAME" != "$NODE2_NAME" && "$NODE1_NAME" != "$NODE3_NAME" && "$NODE2_NAME" != "$NODE3_NAME" ]] || fail "Les trois NODE*_NAME doivent être différents."
  [[ "$NODE1_IP" != "$NODE2_IP" && "$NODE1_IP" != "$NODE3_IP" && "$NODE2_IP" != "$NODE3_IP" ]] || fail "Les trois NODE*_IP doivent être différents."
  [[ "$K3S_API_VIP" != "$INGRESS_VIP" ]] || fail "K3S_API_VIP et INGRESS_VIP doivent être deux adresses distinctes."

  for spec in "${POSTGRES_CPU_REQUEST}" "${AUTHENTIK_SERVER_CPU_REQUEST}" "${AUTHENTIK_WORKER_CPU_REQUEST}"; do
    [[ "$spec" =~ ^([1-9][0-9]*([.][0-9]+)?|[1-9][0-9]*m)$ ]] || fail "Demande CPU invalide : $spec"
  done
  for spec in "${POSTGRES_MEMORY_REQUEST}" "${AUTHENTIK_SERVER_MEMORY_REQUEST}" "${AUTHENTIK_WORKER_MEMORY_REQUEST}"; do
    [[ "$spec" =~ ^[1-9][0-9]*(Ki|Mi|Gi|Ti)$ ]] || fail "Demande mémoire invalide : $spec"
  done

  python3 - "$AUTHENTIK_TRUSTED_PROXY_CIDRS" <<'PY'
import ipaddress,sys
items=[x.strip() for x in sys.argv[1].split(',') if x.strip()]
if not items: raise SystemExit("AUTHENTIK_TRUSTED_PROXY_CIDRS doit contenir au moins un CIDR.")
for item in items:
    try: net=ipaddress.ip_network(item, strict=False)
    except ValueError: raise SystemExit(f"CIDR invalide : {item}")
    if net.prefixlen == 0: raise SystemExit("Les CIDR /0 sont interdits pour les proxys de confiance.")
PY

  if [[ -n "${CORPORATE_CA_FILE:-}" ]]; then
    [[ -r "$CORPORATE_CA_FILE" ]] || fail "CORPORATE_CA_FILE absent ou illisible : $CORPORATE_CA_FILE"
    command -v openssl >/dev/null 2>&1 || fail "openssl est nécessaire pour contrôler CORPORATE_CA_FILE."
    openssl x509 -in "$CORPORATE_CA_FILE" -noout >/dev/null 2>&1 || fail "CORPORATE_CA_FILE doit contenir un certificat PEM X.509 lisible."
  fi
  [[ -n "${K3S_TOKEN:-}" && -n "${PG_PASSWORD:-}" && -n "${AUTHENTIK_SECRET_KEY:-}" ]] || fail "secrets.env incomplet. Ne régénérez pas les secrets d'un cluster existant."
}

node_values() {
  case "$1" in
    1) NODE_NAME="$NODE1_NAME"; NODE_IP="$NODE1_IP" ;;
    2) NODE_NAME="$NODE2_NAME"; NODE_IP="$NODE2_IP" ;;
    3) NODE_NAME="$NODE3_NAME"; NODE_IP="$NODE3_IP" ;;
    *) fail "Identifiant de nœud attendu : 1, 2 ou 3." ;;
  esac
  export NODE_NAME NODE_IP
}

make_no_proxy() {
  local base="${NO_PROXY:-}"
  # Exclusions automatiques : loopback, DNS Kubernetes, réseaux Pod/Service,
  # identifiants et adresses des nœuds, VIP, FQDN public d'Authentik et PostgreSQL RW.
  # Les domaines et services internes propres à l'entreprise restent à ajouter dans NO_PROXY.
  local internal="localhost,127.0.0.1,::1,.svc,.svc.cluster.local,.cluster.local,kubernetes,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.cluster.local,${K3S_POD_CIDR},${K3S_SERVICE_CIDR},${NODE1_NAME},${NODE1_IP},${NODE2_NAME},${NODE2_IP},${NODE3_NAME},${NODE3_IP},${K3S_API_VIP},${INGRESS_VIP},${AUTHENTIK_FQDN},authentik-db-rw.authentik.svc.cluster.local"
  if [[ -n "$base" ]]; then printf '%s,%s' "$base" "$internal"; else printf '%s' "$internal"; fi
}

export_proxy_environment() {
  local np; np="$(make_no_proxy)"
  if [[ -n "${HTTP_PROXY:-}" ]]; then export HTTP_PROXY http_proxy="$HTTP_PROXY"; fi
  if [[ -n "${HTTPS_PROXY:-}" ]]; then export HTTPS_PROXY https_proxy="$HTTPS_PROXY"; fi
  export NO_PROXY="$np" no_proxy="$np"
}

systemd_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

write_k3s_proxy_env() {
  local np; np="$(make_no_proxy)"
  install -d -m 0755 /etc/systemd/system
  {
    [[ -z "${HTTP_PROXY:-}" ]] || printf 'HTTP_PROXY="%s"\n' "$(systemd_escape "$HTTP_PROXY")"
    [[ -z "${HTTPS_PROXY:-}" ]] || printf 'HTTPS_PROXY="%s"\n' "$(systemd_escape "$HTTPS_PROXY")"
    printf 'NO_PROXY="%s"\n' "$(systemd_escape "$np")"
    [[ -z "${HTTP_PROXY:-}" ]] || printf 'http_proxy="%s"\n' "$(systemd_escape "$HTTP_PROXY")"
    [[ -z "${HTTPS_PROXY:-}" ]] || printf 'https_proxy="%s"\n' "$(systemd_escape "$HTTPS_PROXY")"
    printf 'no_proxy="%s"\n' "$(systemd_escape "$np")"
  } > /etc/systemd/system/k3s.service.env
  chmod 600 /etc/systemd/system/k3s.service.env
}

configure_os_proxy() {
  [[ -r /etc/os-release ]] || fail "Impossible de déterminer la distribution Linux (/etc/os-release absent)."
  . /etc/os-release
  if [[ -n "${HTTP_PROXY:-}" || -n "${HTTPS_PROXY:-}" ]]; then
    case "${ID:-}" in
      ubuntu|debian)
        install -d -m 0755 /etc/apt/apt.conf.d
        {
          [[ -z "${HTTP_PROXY:-}" ]] || printf 'Acquire::http::Proxy "%s";\n' "$HTTP_PROXY"
          [[ -z "${HTTPS_PROXY:-}" ]] || printf 'Acquire::https::Proxy "%s";\n' "$HTTPS_PROXY"
        } > /etc/apt/apt.conf.d/90-corporate-proxy
        chmod 600 /etc/apt/apt.conf.d/90-corporate-proxy
        ;;
      rhel|rocky|almalinux|centos|fedora)
        install -d -m 0755 /etc/dnf/dnf.conf.d
        {
          printf '[main]\n'
          [[ -z "${HTTP_PROXY:-}${HTTPS_PROXY:-}" ]] || printf 'proxy=%s\n' "${HTTPS_PROXY:-$HTTP_PROXY}"
        } > /etc/dnf/dnf.conf.d/90-corporate-proxy.conf
        chmod 600 /etc/dnf/dnf.conf.d/90-corporate-proxy.conf
        ;;
      *) warn "Proxy gestionnaire de paquets non configuré pour ID=${ID:-inconnu}." ;;
    esac
  fi
}

install_host_ca() {
  [[ -n "${CORPORATE_CA_FILE:-}" ]] || return 0
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian)
      install -d -m 0755 /usr/local/share/ca-certificates
      install -m 0644 "$CORPORATE_CA_FILE" /usr/local/share/ca-certificates/corporate-proxy.crt
      if command -v update-ca-certificates >/dev/null 2>&1; then
        update-ca-certificates
      elif [[ -f /etc/ssl/certs/ca-certificates.crt && ! -e /var/lib/corporate-proxy-ca.bootstrap-done ]]; then
        cat "$CORPORATE_CA_FILE" >> /etc/ssl/certs/ca-certificates.crt
        install -d -m 0755 /var/lib
        touch /var/lib/corporate-proxy-ca.bootstrap-done
      else
        fail "Magasin CA Debian absent et update-ca-certificates indisponible."
      fi
      ;;
    rhel|rocky|almalinux|centos|fedora)
      install -d -m 0755 /etc/pki/ca-trust/source/anchors
      install -m 0644 "$CORPORATE_CA_FILE" /etc/pki/ca-trust/source/anchors/corporate-proxy.crt
      update-ca-trust extract
      ;;
    *) fail "Installation automatique du CA non prévue pour ${ID:-inconnu}. Installez le CA système manuellement." ;;
  esac
}

check_interface() { ip link show dev "$KUBEVIP_INTERFACE" >/dev/null 2>&1 || fail "Interface réseau absente : $KUBEVIP_INTERFACE"; }
