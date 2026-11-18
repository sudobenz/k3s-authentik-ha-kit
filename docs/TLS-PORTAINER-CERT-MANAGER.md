# Certificat TLS existant : Portainer, Kubernetes, Traefik et cert-manager

## Import depuis Portainer

Dans l'environnement Kubernetes géré par Portainer :

1. Ouvrir **ConfigMaps & Secrets** puis **Secrets**.
2. Créer ou modifier un Secret dans le namespace `authentik`.
3. Nom : `authentik-tls` (doit correspondre à `AUTHENTIK_TLS_SECRET_NAME` dans `config.env`).
4. Type : `kubernetes.io/tls`.
5. Clé `tls.crt` : contenu PEM du certificat et de sa chaîne intermédiaire (`fullchain.pem`).
6. Clé `tls.key` : contenu PEM de la clé privée correspondante (`privkey.pem`). La clé privée doit être non chiffrée pour que les contrôles et le contrôleur TLS la lisent sans interaction.

N'importer jamais une clé privée dans un namespace public ou accessible à des comptes non autorisés. Les Secrets Kubernetes sont encodés en base64, pas chiffrés par ce seul encodage ; K3s secrets-encryption est activé par le bootstrap du kit, mais l'accès RBAC reste déterminant.

## Synchroniser vers les autres interfaces

Depuis un nœud K3s avec le kubeconfig administrateur :

```bash
./scripts/11-configure-dashboard-ingress.sh
```

Le script :

- valide le type du Secret et la présence de `tls.crt`/`tls.key` ;
- vérifie l'expiration du certificat ;
- vérifie que la clé privée correspond au certificat ;
- vérifie que les SAN couvrent `AUTHENTIK_FQDN`, `LONGHORN_FQDN` et `HEADLAMP_FQDN` ;
- copie le couple certificat/clé dans `longhorn-system/longhorn-dashboard-tls` et `${HEADLAMP_NAMESPACE}/headlamp-dashboard-tls` ;
- active TLS sur l'Ingress Authentik et crée les Ingress Longhorn et Headlamp.

Le script ne génère plus de certificat autosigné de remplacement en cas de Secret source absent ou invalide. Il s'arrête sans remplacer le certificat. Il conserve aussi le Secret `longhorn-basic-auth` déjà présent, sauf demande explicite de rotation :

```bash
./scripts/11-configure-dashboard-ingress.sh --rotate-longhorn-auth
```

Cette option demande de nouveaux identifiants BasicAuth dans un terminal interactif.

## Renouvellement

L'import dans un Secret ne crée pas de ressource cert-manager `Certificate`. cert-manager ne renouvelle donc pas automatiquement un certificat importé uniquement de cette manière. À chaque renouvellement externe, mettre à jour `authentik/authentik-tls` via Portainer puis relancer le script de synchronisation.

Pour confier l'émission et le renouvellement à cert-manager, définir un `Issuer`/`ClusterIssuer` approprié et une ressource `Certificate` qui écrit dans le Secret cible. Il s'agit d'un changement de gestion de cycle de vie, distinct de l'import d'un certificat existant.

Le port HTTP 80 étant fermé par `scripts/02b-configure-ingress.sh`, le challenge ACME HTTP-01 n'est pas disponible dans la configuration actuelle. Utiliser DNS-01 ou revoir explicitement la stratégie d'exposition HTTP.
