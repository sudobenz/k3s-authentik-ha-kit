# Kit de déploiement K3s HA + Longhorn + CloudNativePG + Authentik

Version du kit : 1.2.2. Kit indépendant de déploiement K3s HA + Authentik, avec Longhorn, CloudNativePG, Headlamp et outils de maintenance.

> **Important – kit d'installation, pas sauvegarde du cluster.** Cette archive contient les scripts, manifestes et paramètres de déploiement. Elle ne contient ni les données PostgreSQL/AuthentiK, ni les volumes Longhorn, ni les secrets, ni les certificats privés, ni un kubeconfig opérationnel. Ne relancez pas les scripts d'installation initiale sur le cluster déjà déployé.

## 1. Topologie d’exemple

| Élément | Valeur d’exemple à adapter |
|---|---|
| Nœuds | `k3s-1` (`192.0.2.51`), `k3s-2` (`192.0.2.52`), `k3s-3` (`192.0.2.53`) |
| VIP API Kubernetes | `192.0.2.54:6443` |
| VIP Ingress Traefik | `192.0.2.55` |
| K3s | `v1.36.5+k3s1`, etcd embarqué |
| Helm | `v4.3.1` |
| Kube-VIP | `v1.3.1` |
| Traefik | chart K3s, 3 réplicas sur les 3 nœuds, HTTPS exposé sur 443 ; `externalTrafficPolicy: Local` pour préserver l’IP source ; port 80 désactivé par `02b-configure-ingress.sh` |
| Longhorn | `1.13.0` |
| CloudNativePG Operator | `1.30.1`, namespace `cnpg-system`, 1 replica du contrôleur |
| PostgreSQL Authentik | `authentik-db`, 3 instances, stockage strict-local |
| Authentik | `2026.8.5`, 3 Server et 6 Worker |
| Headlamp | release `my-headlamp`, namespace `headlamp`, chart/app `0.46.0`, Service `my-headlamp:80` |
| cert-manager | namespace observé `cert-manager` ; version exacte non fournie dans les éléments du déploiement |

### FQDN

| Service | FQDN | Namespace |
|---|---|---|
| Authentik | `auth-k3s.example.com` | `authentik` |
| Longhorn UI | `longhorn.example.com` | `longhorn-system` |
| Headlamp | `headlamp.example.com` | `headlamp` |

Les adresses `192.0.2.0/24` appartiennent au bloc TEST-NET-1 réservé à la documentation : elles ne sont pas routables. Remplacez les IP et FQDN d’exemple par les valeurs de votre environnement avant le déploiement.

## 2. Contenu

- `config.env.example` : modèle public de paramètres. Copier vers `config.env` et adapter localement ; `config.env` est exclu de Git.
- `scripts/` : bootstrap K3s, VIP, Longhorn, Authentik, contrôle, intégration Portainer, maintenance et outils de test.
- `manifests/storageclasses.yaml` : StorageClasses Longhorn PostgreSQL strict-local et Authentik RWX.
- `config/headlamp-plugins.yml` : versions des deux plugins Headlamp réellement ajoutés.
- `prometheus-values.yaml` : valeurs Helm Prometheus ; ce fichier seul ne déploie pas Prometheus.
- `extend-sdb.sh` : utilitaire séparé d'extension de stockage ; lire le script avant exécution.
- `docs/` : procédures, sécurité, maintenance hôte, réseau et limites connues.
- `portainer/README.md` : procédure pour récupérer le manifeste Edge Agent propre à l'environnement Portainer.

## 3. Installation initiale – ordre d'exécution

Ces étapes décrivent un **nouveau déploiement**. Le kit refuse volontairement certaines opérations si des ressources existent déjà. Ne relancez pas les scripts d’installation initiale sur un cluster déjà déployé.

### Préparation sur les trois nœuds

1. Depuis la racine du kit, créer le fichier local : `cp config.env.example config.env` puis `chmod 600 config.env`.
2. Adapter les IP, l’interface réseau (`KUBEVIP_INTERFACE`), les FQDN, les CIDR et le chemin de données Longhorn.
3. Copier le kit et ce `config.env` local sur chacun des trois nœuds par un canal maîtrisé. Ne jamais ajouter `config.env` au dépôt Git.
4. Préparer et monter un disque Longhorn dédié sur chaque nœud **avant** le bootstrap K3s :

```bash
bash scripts/prepare-longhorn-disk.sh --disk-id /dev/disk/by-id/IDENTIFIANT_DU_DISQUE --mountpoint /var/lib/longhorn
```

Le script affiche le périphérique résolu, vérifie qu'il ne participe pas au disque système, puis exige la saisie exacte `FORMAT-LONGHORN` avant de partitionner/formater. Toute donnée présente sur le disque sélectionné peut être détruite. L'identifiant QEMU du kit initial est uniquement une valeur par défaut : renseigner le vrai chemin `/dev/disk/by-id/...` de chaque VM.

### Bootstrap K3s

Sur `k3s-1`, générer une seule fois les secrets :

```bash
./scripts/00-generate-secrets.sh
```

Le fichier `secrets.env` est créé à la racine avec des droits `0600`. Il contient des clés sensibles. Le script `01-install-k3s-node.sh 1` complète ce fichier avec le token de jointure sécurisé K3s.

Sur `k3s-1` :

```bash
./scripts/01-install-k3s-node.sh 1
```

Copier ensuite `secrets.env` de manière sécurisée vers les nœuds 2 et 3, puis exécuter respectivement :

```bash
./scripts/01-install-k3s-node.sh 2
./scripts/01-install-k3s-node.sh 3
```

Ne pas envoyer `secrets.env` par e-mail ou dans un dépôt Git. Ne pas régénérer les secrets d'un cluster existant.

### Services de cluster

Depuis `k3s-1` :

```bash
./scripts/02-install-vips.sh
./scripts/02a-install-longhorn.sh
./scripts/02b-configure-ingress.sh
./scripts/03-deploy-authentik.sh
```

`02a-install-longhorn.sh` applique `manifests/storageclasses.yaml` et contrôle les nœuds/disques Longhorn. `03-deploy-authentik.sh` installe également l'Operator CloudNativePG et crée le cluster PostgreSQL Authentik à 3 instances.

`03-deploy-authentik.sh` crée initialement un certificat autosigné couvrant les trois FQDN et l'enregistre dans `authentik/authentik-tls`. C'est un certificat de bootstrap, pas un certificat publiquement approuvé.

Le contrôleur CloudNativePG est configuré avec une seule instance (valeur par défaut du manifeste Operator utilisé). Cela ne réduit pas le cluster PostgreSQL, qui contient bien trois instances. En cas d'indisponibilité de l'Operator, les processus PostgreSQL en cours continuent à tourner, mais la réconciliation et les actions de gestion assurées par l'Operator peuvent être retardées jusqu'à son retour : le contrôleur lui-même n'est pas redondé dans cette configuration.

`03a-prepare-files.sh` est déjà appelé par `03-deploy-authentik.sh` ; ne pas le lancer séparément sur le PVC existant. `03b-validate-chart.sh` effectue une validation du rendu Helm et peut être exécuté après génération de `output/authentik-values.yaml`.

### cert-manager et Headlamp

cert-manager a été ajouté au cluster pendant le déploiement, mais les éléments fournis ne permettent pas d'identifier sa version Helm/image ni la commande exacte qui a servi à l'installer. **Cette archive n'installe donc pas cert-manager et ne prétend pas le mettre à niveau.** Elle vérifie ses CRD et ses Deployments avec `scripts/13-check-platform-addons.sh`.

Pour figer cette dépendance lors d'une prochaine révision du kit, récupérer sur le cluster :

```bash
helm list -A | grep -i cert-manager || true
kubectl -n cert-manager get deployments -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.template.spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'
```

Ne pas installer une seconde instance de cert-manager : ses CRD sont globales au cluster.

Après installation de cert-manager, déployer Headlamp et ses plugins :

```bash
./scripts/12-install-headlamp.sh
```

Versions incluses dans `config/headlamp-plugins.yml` :

- `cnpg-headlamp-plugin` : `0.1.6` ;
- plugin `cert-manager` : `0.1.1`.

Le script patiente jusqu'à cinq minutes afin de laisser le sidecar télécharger et installer les deux plugins. Il conserve les valeurs Helm existantes lors d'une mise à jour (`--reuse-values`).

### Ingress, TLS et vérifications

Quand les services sont disponibles :

```bash
./scripts/11-configure-dashboard-ingress.sh
./scripts/04-check.sh
./scripts/13-check-platform-addons.sh
```

Le script 11 valide le Secret source dans `authentik`, vérifie expiration, correspondance clé/certificat et SAN des trois FQDN, puis copie le certificat vers `longhorn-system` et `headlamp`. Il crée les Ingress HTTPS Longhorn et Headlamp ainsi que les Middlewares Longhorn.

Si le certificat source a été importé via Portainer, le script 11 synchronise les Secrets des autres namespaces. Voir `docs/TLS-PORTAINER-CERT-MANAGER.md`.

### Intégration Portainer – optionnelle

`08-integrate-portainer.sh` installe uniquement le **Portainer Edge Agent Standard** dans le cluster. Il ne déploie pas Portainer Server. Le manifeste doit être téléchargé depuis l'assistant Portainer Server pour cet environnement précis ; il ne doit pas être fabriqué ou partagé entre environnements. Procédure : `portainer/README.md`.

### Scripts facultatifs

- `09-patchmon-precheck.sh <nom-du-noeud>` et `10-patchmon-postcheck.sh <nom-du-noeud>` encadrent la maintenance séquentielle d'un nœud. Le drain exclut les pods CloudNativePG strict-local et le post-contrôle attend le retour Ready du nœud Longhorn avant `uncordon`. Ne pas patcher deux nœuds simultanément.
- `configure-host-protection.sh` et `check-host-protection.sh` installent/valident Fail2ban SSH et bloquent les mises à jour APT/redémarrages automatiques non coordonnés. Voir `docs/HOST-SECURITY-MAINTENANCE.md`.
- `06-http-benchmark.py` et `07-pgbench-isolated.sh` sont des outils de benchmark, pas des tests à lancer en continu en production. Pour tester uniquement la disponibilité HTTPS avec le certificat autosigné de bootstrap, ajouter `--insecure` à `06-http-benchmark.py` ; ne pas utiliser cette option avec un certificat public de confiance.
- `fix-k3s-apparmor-stacked-peer.sh` est un correctif ciblé à une situation AppArmor ; ne l'exécuter que si le diagnostic correspondant est établi.
- `extend-sdb.sh` modifie le stockage ; lire son contenu et contrôler le périphérique ciblé avant toute exécution.

### Protection des hôtes et maintenance

Sur chacun des trois hôtes, renseigner `FAIL2BAN_IGNORE_IPS` dans `config.env`, puis exécuter :

```bash
sudo bash scripts/configure-host-protection.sh
sudo bash scripts/check-host-protection.sh
```

Fail2ban est limité à SSH. Ne pas activer UFW ou un pare-feu nftables générique sur les nœuds. Ne pas planifier `patch_all` PatchMon sur les trois nœuds et ne pas activer les redémarrages APT autonomes : PatchMon n'orchestre pas les contrôles du quorum K3s, de CNPG et de Longhorn. La procédure, les limites et les contrôles sont dans `docs/HOST-SECURITY-MAINTENANCE.md`.
Les flux inter-nœuds et l’exposition des VIP sont détaillés dans `docs/NETWORK-FIREWALL.md`.

## 4. TLS et cert-manager : limites de fonctionnement

Le certificat importé est stocké comme Secret Kubernetes TLS. Le plugin Headlamp cert-manager sert à visualiser/administrer les ressources cert-manager (`Certificate`, `Issuer`, `ClusterIssuer`, `Order`, `Challenge`, etc.) ; il ne constitue pas un assistant d'importation de fichiers PEM.

L'import d'un certificat externe dans un Secret ne crée pas de ressource `Certificate` et ne donne pas à cert-manager la responsabilité de son renouvellement. Pour renouveler automatiquement ce certificat, il faut un mécanisme d'émission compatible avec un `Issuer`/`ClusterIssuer` ou un processus externe qui actualise les Secrets.

Le script `02b-configure-ingress.sh` désactive l'entrée HTTP port 80 et n'expose que HTTPS port 443. Un challenge ACME HTTP-01 ne peut donc pas fonctionner dans cette configuration sans réouvrir/rerouter le port 80. Pour Let's Encrypt avec ce choix réseau, prévoir un challenge DNS-01.

## 5. Sécurité – points à traiter avant ouverture large

### Headlamp et RBAC

Le chart Headlamp 0.46.0 active par défaut un `ClusterRoleBinding` vers `cluster-admin` si ses valeurs RBAC ne sont pas remplacées. Les contrôles `kubectl auth can-i` fournis pendant le déploiement ont confirmé que la ServiceAccount Headlamp disposait de droits de lecture/écriture/suppression sur les CRD CloudNativePG et d'accès aux pods/log/exec du namespace Authentik. Considérer l'interface comme **administrateur Kubernetes** tant que le RBAC n'a pas été explicitement restreint.

L'authentification OIDC Headlamp avec Authentik a été discutée, mais n'a pas été configurée dans les éléments fournis. Ne pas considérer le SSO ni l'autorisation Kubernetes individuelle par groupe AD comme déjà déployés. Pour une production multi-utilisateurs, définir le fournisseur OIDC du kube-apiserver K3s et les rôles RBAC Kubernetes par groupes avant d'ouvrir Headlamp aux utilisateurs.

### Secrets et sauvegardes

- `secrets.env`, les kubeconfigs, les clés privées TLS et le manifeste Edge Agent Portainer sont exclus de l'archive par `.gitignore`.
- Le kubeconfig généré par `02-install-vips.sh` contient des informations d'accès privilégiées. Le conserver en mode `0600` et hors du kit versionné.
- Prévoir une sauvegarde etcd K3s, des sauvegardes CloudNativePG/Barman vers un stockage externe et une sauvegarde séparée des données Longhorn. Le kit n'embarque pas ces sauvegardes.
- Les valeurs `reclaimPolicy: Retain` des StorageClasses limitent le risque de suppression automatique des volumes lors de la suppression de PVC, mais imposent un nettoyage manuel maîtrisé.

## 6. Contrôles après déploiement

Sur `k3s-1` :

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
./scripts/04-check.sh
./scripts/13-check-platform-addons.sh
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get ingress -A -o wide
kubectl -n authentik get cluster authentik-db
helm list -A
```

Les scripts de contrôle vérifient l'état observable au moment de leur exécution. Ils ne remplacent pas des essais de panne, de bascule PostgreSQL, de restauration de sauvegarde, de renouvellement de certificat ou de perte d'un nœud.

## 7. Portée de la validation de cette version du kit

Les scripts ont fait l'objet d'une vérification statique de syntaxe Bash et les fichiers YAML embarqués ont été analysés. Un contrôle de cohérence des composants applicatifs a également été effectué sur l'ensemble des fichiers du kit. Les scripts n'ont pas été rejoués contre le cluster réel : une telle exécution modifierait l'infrastructure et certaines étapes sont volontairement réservées au bootstrap initial.

## 8. Références techniques

- [Helm – installation et vérification SHA-256](https://helm.sh/docs/intro/install/) : checksum `.sha256sum`.
- [Headlamp – Helm chart](https://artifacthub.io/packages/helm/headlamp/headlamp) : valeurs RBAC, ServiceAccount et plugin manager.
- [Headlamp – plugins](https://headlamp.dev/docs/latest/installation/in-cluster/) : configuration du gestionnaire de plugins.
- [CloudNativePG – documentation](https://cloudnative-pg.io/documentation/).
- [Longhorn – documentation](https://longhorn.io/docs/1.13.0/).
- [cert-manager – installation](https://cert-manager.io/docs/installation/) : n'installer qu'une seule instance de cert-manager par cluster.


## Préservation de l'adresse IP cliente à l'entrée

Le `HelmChartConfig` Traefik livré par `scripts/02b-configure-ingress.sh` fixe explicitement `service.spec.externalTrafficPolicy: Local`. Cela évite la translation d'adresse source réalisée par le chemin Service Kubernetes en mode `Cluster` et permet à Traefik de recevoir l'adresse source réelle de la connexion. Les trois réplicas Traefik sont soumis à une anti-affinité obligatoire : le déploiement doit donc disposer d'un pod Traefik prêt sur chacun des trois nœuds qui peuvent porter la VIP Ingress. Le script de configuration et `scripts/04-check.sh` échouent si le Service ne reste pas en mode `Local`.

Ne pas activer `forwardedHeaders.insecure` pour résoudre un problème d'adresse IP : les en-têtes `X-Forwarded-*` envoyés par un client non approuvé ne doivent pas devenir une source de confiance. La terminaison TLS reste directement sur Traefik ; aucun reverse proxy intermédiaire n'est présumé par ce kit.
## Cycle de vie et mises à niveau

Les procédures de mise à niveau post-déploiement sont séparées des scripts de bootstrap. Lire [`docs/UPGRADE.md`](docs/UPGRADE.md) et utiliser exclusivement les scripts version-ciblés du répertoire [`upgrade/`](upgrade/). Ne pas relancer un script d’installation initiale pour mettre à jour un composant existant.

## Gestion des mises à niveau

Les mises à niveau post-déploiement sont traitées par les procédures dédiées de `upgrade/` et documentées dans `docs/UPGRADE.md`. Commencer par `upgrade/00-inventory.sh` puis `upgrade/01-preflight.sh`. Les scripts sont en simulation par défaut (`--plan`) et exigent `--apply` explicitement. Les composants critiques demandent des preuves de sauvegarde vérifiées. Ne pas relancer les scripts de bootstrap pour mettre à jour une installation existante.


## Publication et configuration locale

Le dépôt ne contient que `config.env.example`, avec des adresses de documentation et des FQDN réservés aux exemples. Avant toute installation, exécuter `cp config.env.example config.env`, puis adapter le fichier à l’environnement cible. Ne jamais committer `config.env`, `secrets.env`, les certificats, les kubeconfigs ou les manifestes générés contenant des données propres au cluster.

Les IP du bloc `192.0.2.0/24` sont des adresses de documentation (TEST-NET-1) et doivent impérativement être remplacées. Les domaines sous `example.com` sont des noms d’exemple.
