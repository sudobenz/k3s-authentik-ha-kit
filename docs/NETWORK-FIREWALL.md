# Réseau et pare-feu du cluster K3s / Authentik

Les règles doivent être appliquées sur les ACL réseau de l'hyperviseur, du commutateur ou du pare-feu périmétrique après validation depuis les trois nœuds. Ce document donne les flux correspondant au kit; il ne constitue pas un fichier UFW/nftables à appliquer tel quel.

## 1. Réseau inter-nœuds K3s

Autoriser les flux suivants entre `k3s-1` (`192.0.2.51`), `k3s-2` (`192.0.2.52`) et `k3s-3` (`192.0.2.53`) :

| Port / protocole | Usage | Source / destination |
|---|---|---|
| TCP 6443 | API K3s | Nœuds K3s, VIP API et postes d'administration explicitement autorisés |
| TCP 2379-2380 | etcd embarqué / quorum | Uniquement les trois serveurs K3s |
| TCP 10250 | kubelet | Nœuds K3s et composants autorisés du plan de contrôle |
| UDP 8472 | Flannel VXLAN | Uniquement les trois nœuds K3s |
| TCP 3260 | iSCSI Longhorn | Nœuds K3s, selon attachement des volumes |
| TCP 9500 | Moteurs/réplicas Longhorn | Uniquement les nœuds K3s |
| UDP/TCP 53 | DNS | Vers les résolveurs réellement utilisés |
| UDP 123 | NTP | Vers la source de temps réellement utilisée |

Ne pas exposer etcd, kubelet, iSCSI ou le port Longhorn 9500 aux réseaux utilisateurs.

## 2. Entrée utilisateur et administration

Le kit utilise :

- VIP Ingress : `192.0.2.55`, HTTPS TCP 443 vers Traefik;
- VIP API : `192.0.2.54`, TCP 6443 depuis les postes/systèmes d'administration autorisés uniquement;
- SSH : depuis le réseau d'administration uniquement, sur le port défini par `FAIL2BAN_SSH_PORT`;
- Headlamp et Longhorn : interfaces d'administration, à limiter au réseau/VPN d'administration; ne pas considérer leur Ingress HTTPS comme une raison de les ouvrir au public.

Le port TCP 80 n'est pas à ouvrir par défaut : le kit utilise HTTPS et le bootstrap ne doit pas rendre l'Ingress HTTP public sans décision explicite.

## Préservation de l'adresse IP source

Le Service LoadBalancer Traefik doit rester configuré avec `spec.externalTrafficPolicy: Local` (valeur persistée par le `HelmChartConfig` du kit). Le déploiement Traefik utilise trois réplicas avec anti-affinité obligatoire afin qu'un endpoint local soit disponible sur chacun des trois nœuds susceptibles de porter la VIP. Vérifier cette propriété après toute mise à niveau ou réconciliation Helm. En mode `Cluster`, Kubernetes peut masquer l'adresse source avant que Traefik ne la voie. Ne pas compenser en faisant confiance aux en-têtes `X-Forwarded-*` non vérifiés.

## 3. Sorties des hôtes

Autoriser selon les composants effectivement activés :

- TCP 443 vers les dépôts Ubuntu, sources des images OCI (`registry.k8s.io`, `docker.io`, GHCR et autres registres effectivement utilisés), dépôts Helm et endpoints de téléchargement nécessaires;
- DNS et NTP vers les serveurs internes configurés;
- TCP 443 vers le proxy d'entreprise si `HTTP_PROXY`/`HTTPS_PROXY` sont configurés;
- TCP 443 depuis l'agent PatchMon vers le serveur PatchMon configuré, si l'agent est installé. Ce trafic est sortant depuis les hôtes; aucun port entrant n'est nécessaire pour l'agent;
- SMTP vers le relais interne uniquement si les notifications e-mail Authentik sont utilisées.

Authentik ne déclare pas de serveur AD/LDAP dans le `config.env` de ce kit. Ne pas ouvrir LDAP/LDAPS/Kerberos sur la seule base de ce document. Si une source LDAP/AD est ajoutée ensuite, documenter les IPs et ports réellement utilisés (par exemple LDAPS TCP 636, LDAP/StartTLS TCP 389, Kerberos TCP/UDP 88 et changement de mot de passe TCP/UDP 464) puis limiter les destinations aux contrôleurs concernés.

## 4. Protection des hôtes

- Fail2ban est limité au jail SSH et lit le journal systemd.
- Ne pas activer un jeu de règles UFW ou nftables générique sur les hôtes : il pourrait casser le trafic K3s, Flannel, kubelet, iSCSI ou Longhorn.
- Restreindre les flux par ACL source/destination au niveau réseau, en préservant les ports inter-nœuds ci-dessus.
- Ne pas exposer directement les NodePorts ou ClusterIPs aux réseaux clients.

Voir également `HOST-SECURITY-MAINTENANCE.md` pour les règles de mise à jour séquentielle et de redémarrage.
