# Liste d'autorisation proxy – endpoints utilisés par le kit

Cette liste sert de base à une politique de proxy sortant. Les noms d'hôtes et chemins peuvent évoluer avec les versions des dépôts et des images ; les vérifier lors d'un changement de version.

| Usage | Destination / domaine |
|---|---|
| Installer K3s | `get.k3s.io` |
| Récupérer Helm | `get.helm.sh` |
| Installer kube-vip | `kube-vip.io` |
| Manifests et release CloudNativePG | `raw.githubusercontent.com`, `github.com` |
| Images OCI CloudNativePG / Authentik | `ghcr.io` |
| Dépôt Helm Longhorn | `charts.longhorn.io` |
| Dépôt Helm Authentik | `charts.goauthentik.io` |
| Dépôt Helm Headlamp | `kubernetes-sigs.github.io` |
| Métadonnées / plugins Headlamp | `artifacthub.io` |
| Images système Kubernetes | `registry.k8s.io`, `docker.io` (selon les images et miroirs effectivement utilisés) |

## NO_PROXY

Le kit ajoute automatiquement les destinations locales du cluster : loopback, IP/noms des trois nœuds, VIP API et Ingress, CIDR Pod, CIDR Service, suffixes `.svc` et `.cluster.local`, FQDN Authentik et service PostgreSQL RW.

Compléter `NO_PROXY` dans `config.env` avec les destinations internes de l'organisation qui doivent être jointes directement : contrôleurs AD/LDAP/Kerberos, SMTP interne, DNS applicatif, Portainer, PatchMon et registres privés. Ne pas ajouter aveuglément des plages RFC1918 entières : cela peut contourner le proxy pour des destinations qui doivent le traverser.

## Inspection TLS du proxy

Si le proxy effectue une inspection TLS, renseigner `CORPORATE_CA_FILE` dans `config.env` avec le chemin vers un bundle PEM CA disponible sur chacun des nœuds. Le bootstrap installe ce CA dans le magasin de confiance système et le transmet aux composants Authentik prévus par le kit.
