# Gestion du cycle de vie et mises à niveau — K3s HA + Authentik

Ce document complète le kit d'installation et de protection. Il décrit les mises à niveau **après déploiement**. Les scripts d'installation `scripts/01-*` à `scripts/13-*` restent des scripts de bootstrap ; ils ne doivent pas être relancés pour mettre à jour un composant déjà présent. Les scripts `upgrade/` sont les seules procédures de mise à niveau intégrées à ce kit.

## 1. Politique d'exploitation

- Aucun composant n'est mis à jour automatiquement vers `latest`.
- L'opérateur choisit une version cible exacte, consulte ses notes de version et vérifie la compatibilité K3s/Kubernetes, CNPG, Longhorn et application.
- Chaque action d'écriture exige `--apply`. Sans cette option, la procédure est une simulation (`--plan`).
- Les procédures de données/CRD demandent un fichier privé de preuves de sauvegarde, incluant une restauration réellement testée.
- Un seul changement de composant à la fois. Après chaque changement, le post-contrôle doit réussir avant la suite.
- Aucun script n'effectue un downgrade automatique. Les mises à niveau majeures PostgreSQL sont bloquées par la procédure PostgreSQL mineure.
- APT et les redémarrages autonomes restent désactivés. Les mises à jour OS passent par PatchMon et les scripts `09-patchmon-precheck.sh` / `10-patchmon-postcheck.sh`, un seul hôte par cycle.

Les scripts ne constituent pas un orchestrateur autonome ni un système de découverte des dernières versions. Les versions doivent être choisies et approuvées explicitement.

## 2. Préparer une opération

Exécuter depuis la racine du kit, avec le kubeconfig administrateur et les outils `kubectl` (ou `k3s kubectl`), `helm`, `curl`, `python3` et `sha256sum` disponibles :

```bash
sudo bash upgrade/00-inventory.sh
sudo bash upgrade/01-preflight.sh
sudo bash upgrade/02-backup-postgres.sh
```

L'inventaire est enregistré dans `upgrade/reports/`. Le pré-contrôle vérifie les trois nœuds, Kube-VIP, Traefik (dont `externalTrafficPolicy: Local` et trois pods répartis), Longhorn, les trois instances CNPG et Authentik Server/Worker. Il appelle également `scripts/04-check.sh`.

### Preuves de sauvegarde

```bash
cp upgrade/backup-evidence.env.example upgrade/backup-evidence.env
chmod 600 upgrade/backup-evidence.env
```

Renseigner ce fichier privé avec :

- la référence d'un snapshot etcd K3s copié hors des nœuds ;
- la référence d'une sauvegarde CNPG/Barman hors cluster ;
- le chemin absolu et le SHA-256 du dump produit par `02-backup-postgres.sh` ;
- la référence d'une sauvegarde Longhorn conservée sur une cible externe ;
- `RESTORE_TESTED="yes"` uniquement après un essai réel de restauration ;
- l'identité de l'opérateur.

Un snapshot local, un dump local ou une capture Longhorn sans copie externe ni test de restauration ne constitue pas un PRA. Le script vérifie le fichier et le SHA-256 du dump ; les références de sauvegarde externe et `RESTORE_TESTED` restent une attestation explicite de l'opérateur.

Ne jamais ajouter `upgrade/backup-evidence.env`, `upgrade/backups/`, `upgrade/reports/` ou `secrets.env` à une archive partagée.

## 3. Ordre de maintenance recommandé

Après pré-contrôle et sauvegardes validées, mettre à jour les composants dans cet ordre, un seul à la fois :

1. K3s, serveur par serveur, en commençant par un nœud qui n'héberge pas le primaire CNPG ;
2. Kube-VIP ;
3. Longhorn ;
4. CloudNativePG Operator ;
5. image PostgreSQL (correctif/minor dans la même version majeure) ;
6. Authentik ;
7. Headlamp, s'il est installé.

Après chaque étape, lancer :

```bash
sudo bash upgrade/99-postcheck.sh
```

Si un pré-contrôle, une attente ou un post-contrôle échoue, **arrêter la séquence**. Ne pas commencer le nœud ou le composant suivant.

## 4. Mises à niveau par composant

### 4.1 K3s — un seul nœud à la fois

`upgrade/10-upgrade-k3s-node.sh` doit être exécuté localement sur l'hôte ciblé. Le kit, `config.env`, `secrets.env` (requis par le post-contrôle Authentik) et le fichier de preuves doivent être présents sur cet hôte. Il n'administre pas un hôte distant.

Exemple de plan :

```bash
sudo bash upgrade/10-upgrade-k3s-node.sh k3s-1 <VERSION_K3S_EXACTE> --plan --backup-evidence upgrade/backup-evidence.env
```

Après revue, remplacer `--plan` par `--apply`. Le script :

- refuse un autre nœud, un nœud déjà cordonné, le primaire PostgreSQL, un cluster ou un volume dégradé ;
- vérifie le chemin de version K3s : même minor ou minor immédiatement suivante, sans saut ;
- crée et vérifie un snapshot etcd local avant le drain ; la copie hors hôte doit déjà être référencée dans le fichier de preuves ;
- cordonne et draine le nœud en excluant les pods `cnpg.io/cluster`, afin de ne pas déplacer les instances PostgreSQL dont le PVC Longhorn est strict-local ;
- exécute l'installateur officiel K3s avec une version exacte, conserve `/etc/rancher/k3s/config.yaml`, attend Kubernetes et Longhorn Ready, puis réintègre le nœud ;
- exécute les contrôles applicatifs. En cas d'échec, il tente de re-cordonner le nœud.

Après succès complet, répéter le pré-contrôle puis exécuter le script sur le deuxième nœud, puis le troisième. Ne jamais redémarrer deux serveurs K3s simultanément. Le changement de `K3S_VERSION` dans `config.env` est effectué après le succès de chaque nœud ; une différence temporaire entre le pin cible et les deux nœuds non encore mis à niveau est normale pendant le cycle.

### 4.2 Kube-VIP

À exécuter sur le serveur qui détient le manifeste source `/var/lib/rancher/k3s/server/manifests/kube-vip-ds.yaml` :

```bash
sudo bash upgrade/14-upgrade-kube-vip.sh <VERSION_EXACTE_SANS_v> --plan
sudo bash upgrade/14-upgrade-kube-vip.sh <VERSION_EXACTE_SANS_v> --apply
```

Le script sauvegarde le manifeste source et remplace uniquement le tag de l'image `ghcr.io/kube-vip/kube-vip`. Il conserve les arguments, interfaces, VIP, règles ARP et élections existants. Après la mise à niveau, vérifier depuis un poste extérieur l'API sur la VIP et l'Ingress. Ne pas régénérer le manifeste avec le script d'installation initiale.

### 4.3 Longhorn

```bash
sudo bash upgrade/13-upgrade-longhorn.sh <VERSION_LONGHORN_EXACTE> --plan --backup-evidence upgrade/backup-evidence.env
sudo bash upgrade/13-upgrade-longhorn.sh <VERSION_LONGHORN_EXACTE> --apply --backup-evidence upgrade/backup-evidence.env
```

Le script :

- exige des nœuds Longhorn Ready, les volumes PostgreSQL `strict-local` sains et les volumes attachés sans dégradation ;
- vérifie que la cible est un correctif dans la même minor ou la minor immédiatement suivante ; les sauts et downgrades sont refusés ;
- bloque la procédure automatisée si des volumes Longhorn V2 sont détectés ;
- réutilise les valeurs Helm en place et ne fait pas de rollback automatique.

Avant `--apply`, lire le guide de mise à niveau de la version source et cible. Longhorn interdit les downgrades ; un `helm rollback` n'est pas un plan de retour valide. Pour Longhorn 1.13.0, les volumes V2 Data Engine exigent une procédure préalable spécifique (mise à niveau live non prise en charge dans ce chemin). Toute cible non qualifiée doit être traitée manuellement en fenêtre de maintenance.

### 4.4 CloudNativePG Operator

```bash
sudo bash upgrade/11-upgrade-cnpg-operator.sh <VERSION_CNPG_X.Y.Z> --plan --backup-evidence upgrade/backup-evidence.env
sudo bash upgrade/11-upgrade-cnpg-operator.sh <VERSION_CNPG_X.Y.Z> --apply --backup-evidence upgrade/backup-evidence.env
```

La procédure intégrée ne prend en charge automatiquement que les correctifs dans la même branche `X.Y`. Un changement de minor/major demande une revue de la matrice de compatibilité Kubernetes/CNPG, des CRD et des notes de migration, puis une procédure spécifique. Le manifeste exact est téléchargé, sauvegardé, soumis à `--dry-run=server`, puis appliqué en server-side. Le script attend le retour des trois instances CNPG Ready.

### 4.5 PostgreSQL — correctif mineur dans la même version majeure

```bash
sudo bash upgrade/12-upgrade-postgresql-minor.sh <IMAGE_POSTGRESQL_EXACTE> --plan --backup-evidence upgrade/backup-evidence.env
sudo bash upgrade/12-upgrade-postgresql-minor.sh <IMAGE_POSTGRESQL_EXACTE> --apply --backup-evidence upgrade/backup-evidence.env
```

La cible doit conserver le dépôt, le suffixe de distribution et le numéro de version majeure, avec un numéro mineur supérieur. CloudNativePG effectue le rolling update des réplicas puis du primaire. Le script attend trois instances Ready et vérifie que les trois images correspondent à la cible.

Un passage PostgreSQL 18 vers 19 (ou toute autre montée majeure) est refusé. Il faut une migration CNPG majeure distincte (dump/restore, réplication logique blue/green ou `pg_upgrade`), testée en préproduction et avec un plan de retour/restauration dédié.

### 4.6 Authentik

```bash
sudo bash upgrade/15-upgrade-authentik.sh <VERSION_AUTHENTIK_YYYY.M.P> --plan --backup-evidence upgrade/backup-evidence.env
sudo bash upgrade/15-upgrade-authentik.sh <VERSION_AUTHENTIK_YYYY.M.P> --apply --backup-evidence upgrade/backup-evidence.env
```

Le script met à niveau le chart et l'image vers la même version, conserve les valeurs Helm en place (`--reuse-values`), attend les déploiements Server et Worker, met à jour les deux pins de `config.env` uniquement après le post-contrôle et exécute `scripts/04-check.sh`.

Avant `--apply`, lire le guide Authentik et les release notes de chaque version intermédiaire requise. Ne pas sauter les étapes de migration de version majeure/mineure indiquées par l'éditeur. Tout Outpost déployé séparément doit être aligné sur la version du serveur ; les Outposts externes ne sont pas gérés automatiquement par ce kit. Tester LDAP, OIDC, SAML, MFA, invitations, récupération de compte et flux personnalisés.

### 4.7 Headlamp (optionnel)

```bash
sudo bash upgrade/16-upgrade-headlamp.sh <VERSION_CHART_X.Y.Z> --plan
sudo bash upgrade/16-upgrade-headlamp.sh <VERSION_CHART_X.Y.Z> --apply
```

La commande n'est disponible que si la release Headlamp existe. Elle conserve les valeurs Helm et modifie `HEADLAMP_CHART_VERSION` après le rollout.

## 5. Mises à jour hôte (APT) et redémarrages

Les mises à jour OS restent distinctes des mises à jour Kubernetes. Les paquets APT ne sont pas appliqués automatiquement et les redémarrages automatiques restent désactivés.

Pour PatchMon, utiliser les scripts existants :

```bash
sudo bash scripts/09-patchmon-precheck.sh <NODE_NAME>
# Appliquer ensuite les paquets sur ce seul hôte via PatchMon.
# Si un reboot est requis, attendre la fin de dpkg/apt et ne redémarrer que ce nœud.
sudo bash scripts/10-patchmon-postcheck.sh <NODE_NAME>
```

Le pré-contrôle bloque notamment si la cible héberge le primaire CNPG. Le drain exclut CNPG strict-local. Ne jamais contourner un PDB, Longhorn ou un volume strict-local avec `--force`, `--disable-eviction` ou suppression manuelle de pods CNPG. Ne commencer l'hôte suivant qu'après le post-contrôle intégral.

## 6. Composants non automatisés par le sous-système upgrade

- cert-manager : ce kit n'en fixe pas une version de référence unique ni une release Helm qu'il possède. Si cert-manager a été installé/administré séparément, le mettre à niveau depuis son gestionnaire propriétaire, après lecture des notes de migration CRD ; ne pas l'adopter automatiquement.
- Portainer Edge Agent : le manifeste est fourni/généré par l'installation Portainer externe. Gérer sa version depuis Portainer et respecter la compatibilité Server/Agent.
- Prometheus : le fichier `prometheus-values.yaml` fourni est un exemple de valeurs, pas une release Prometheus installée par le kit.
- Helm CLI : binaire d'administration installé sur les hôtes, à gérer séparément ; son upgrade ne doit pas être confondu avec l'upgrade du cluster.
- Les Outposts Authentik hors de cette release Helm, providers/plugins personnalisés et intégrations externes doivent être recensés et mis à jour séparément.

## 7. Limitations et interdictions explicites

- Les scripts ne mettent jamais à jour simultanément les trois nœuds.
- Les versions cibles ne sont pas calculées automatiquement depuis `latest`.
- Le changement de version PostgreSQL majeur est bloqué.
- Le changement de branche CNPG est bloqué par l'outil automatique.
- Les sauts Longhorn et la détection des volumes V2 provoquent un arrêt.
- Il n'y a pas de rollback automatique des changements de schéma applicatifs ou PostgreSQL ; restaurer une sauvegarde compatible peut être nécessaire.
- Les procédures ne remplacent pas un test de restauration, une préproduction ou un exercice de PRA.

## 8. Références officielles

- K3s upgrades manuels : https://docs.k3s.io/upgrades/manual
- K3s snapshots : https://docs.k3s.io/cli/etcd-snapshot
- Kubernetes drain : https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/
- Kube-VIP upgrade : https://kube-vip.io/docs/upgrade/
- Longhorn 1.13 upgrade : https://longhorn.io/docs/1.13.0/deploy/upgrade/
- Longhorn Engine upgrade : https://longhorn.io/docs/1.13.0/deploy/upgrade/upgrade-engine/
- CloudNativePG PostgreSQL upgrades : https://cloudnative-pg.io/docs/current/postgres_upgrades/
- CloudNativePG documentation : https://cloudnative-pg.io/documentation/
- Authentik upgrade : https://docs.goauthentik.io/install-config/upgrade/
- Authentik Helm chart : https://docs.goauthentik.io/install-config/installation/
