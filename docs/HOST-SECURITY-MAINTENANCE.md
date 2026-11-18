# Protection des hôtes et maintenance du cluster K3s / Authentik

## 1. Périmètre constaté dans ce kit

- Trois nœuds K3s serveurs/etcd : `k3s-1`, `k3s-2`, `k3s-3`.
- K3s, Longhorn et CloudNativePG sont répartis sur ces trois hôtes.
- CloudNativePG exécute trois instances PostgreSQL dans le namespace `authentik`.
- Les volumes PostgreSQL utilisent `longhorn-pg-local`, `dataLocality: strict-local` et une seule réplique Longhorn par volume. La disponibilité PostgreSQL repose sur la réplication CNPG.
- Les fichiers Authentik utilisent un volume RWX Longhorn de trois réplicas; Authentik Server est déployé en trois réplicas et Worker en six.
- Le kit contient déjà `scripts/09-patchmon-precheck.sh` et `scripts/10-patchmon-postcheck.sh`. Ils sont des garde-fous, pas un moteur d'installation automatique des mises à jour.

## 2. Décisions de protection

| Contrôle | Décision | Portée / raison |
|---|---|---|
| Fail2ban | **À installer** | Uniquement le service SSH de chaque hôte, avec backend systemd. |
| Fail2ban sur Authentik/HTTP | **Ne pas configurer** | Les journaux applicatifs de pods ne sont pas les journaux SSH de l'hôte; ne pas créer de jail HTTP sans pipeline de logs qualifié. |
| Politique de réputation Authentik | **À configurer** | Utiliser la protection native contre les tentatives répétées, avec un flux de test/captcha correctement chaîné. |
| Rate limiting Traefik global | **Ne pas activer par défaut** | Sans stockage de compteurs partagé, les trois réplicas Traefik ne disposent pas d’un compteur global; un seuil arbitraire peut bloquer des utilisateurs légitimes. |
| CrowdSec / sshguard en plus de Fail2ban | **Ne pas empiler** | Un seul mécanisme de bannissement SSH est configuré dans ce kit. Ne pas faire piloter plusieurs moteurs sans règles de priorité et de déblocage testées. |
| UFW / pare-feu hôte générique | **Ne pas activer automatiquement** | Un profil générique risque de couper API K3s, etcd, Flannel, kubelet ou les flux iSCSI/Longhorn. Appliquer les ACL réseau après validation de la matrice. |
| AppArmor | **Conserver** | Ne pas appliquer de correctif global. `fix-k3s-apparmor-stacked-peer.sh` reste conditionnel au diagnostic. |
| NetworkPolicy Kubernetes | **Ne pas ajouter de politique globale** | Conserver les règles livrées et vérifier leur effet réel avec le CNI, Traefik et les proxies autorisés. |
| Mises à jour APT automatiques | **Désactivées par défaut** | Les installations doivent être coordonnées entre les trois nœuds. |
| Redémarrage automatique | **Désactivé** | Aucun nœud etcd/CNPG ne doit redémarrer sur le seul déclenchement local d'APT. |

## 3. Installer la protection hôte

Avant d'exécuter le script, éditer `config.env` sur chaque hôte et renseigner `FAIL2BAN_IGNORE_IPS` avec les adresses ou réseaux réels depuis lesquels l'administration SSH est autorisée. Cette liste est obligatoire; ne pas utiliser des plages d'exemple comme valeurs de production.

Exemple de syntaxe uniquement :

```bash
FAIL2BAN_IGNORE_IPS="192.0.2.10/32,192.0.2.0/24,2001:db8::/64"
FAIL2BAN_SSH_PORT="ssh"
```

Si SSH utilise un port non standard, remplacer `ssh` par son numéro TCP réel. Appliquer sur **chacun des trois hôtes** :

```bash
sudo bash scripts/configure-host-protection.sh
sudo bash scripts/check-host-protection.sh
```

Le script, prévu pour les hôtes Ubuntu/Debian du kit, installe `fail2ban` et `python3-systemd`, active uniquement le jail `sshd`, et écrit une surcharge APT qui désactive l'installation autonome de mises à jour et les redémarrages automatiques. Fail2ban ajoute ses propres règles de bannissement SSH via son action système; le script ne remplace ni ne vide le ruleset, ne modifie pas `sshd_config`, n'active pas UFW et ne touche pas aux règles réseau K3s ou aux services K3s/Longhorn.

Avant de laisser Fail2ban en production, contrôler `ignoreip` et tester une nouvelle connexion SSH depuis le réseau d'administration. Garder une session console/hyperviseur disponible pendant le test.

## 4. Protection propre à Authentik

Authentik fournit une politique Reputation pour gérer les tentatives répétées : les échecs diminuent le score et les succès l'augmentent; une politique qui passe sur un score faible peut servir à déclencher un CAPTCHA. Configurer cette protection dans le flux d'authentification réellement utilisé :

1. Créer une politique de type **Reputation** avec des seuils de test adaptés.
2. L'associer au flow d'authentification ciblé, par une étape CAPTCHA ou une branche de refus selon le comportement attendu.
3. Pour lier la politique directement au flow afin de refuser les requêtes à faible réputation, activer **Negate**. Sans Negate, la logique peut verrouiller tous les utilisateurs légitimes à l'exception des attaquants. Pour une liaison à une étape CAPTCHA, configurer l'évaluation sur l'étape afin qu'elle utilise le contexte de la tentative courante.
4. Tester connexion réussie, mot de passe incorrect répété, utilisateur inconnu, MFA, récupération de compte, accès depuis plusieurs IP et comportement après expiration du score.
5. Configurer des notifications pour `login_failed` et `suspicious_request` selon les règles d'exploitation.

Ne pas appliquer un blocage HTTP global à tous les chemins Traefik sans mesure préalable. L'interface d'administration Authentik, les endpoints de santé, les callbacks OIDC/SAML et les flux MFA doivent être testés séparément. Ne pas brancher Fail2ban sur les logs des pods sans pipeline explicite et source IP vérifiée.

## 5. Politique de mises à jour hôte : ce qui est possible et ce qui ne l'est pas

### Configuration sûre fournie

- Les mises à jour de paquets APT ne sont pas installées automatiquement par `unattended-upgrades`.
- Les redémarrages automatiques sont désactivés.
- PatchMon peut rester utilisé pour l'inventaire et une action ciblée sur un hôte.
- Les scripts PatchMon du kit contrôlent Authentik, CloudNativePG et Longhorn avant/après maintenance.

### Limite à ne pas contourner

Une politique PatchMon de groupe qui met à jour les trois hôtes n'est **pas** cluster-aware. Elle ne garantit pas que le quorum etcd, les volumes Longhorn, CNPG et Authentik reviennent à leur état nominal avant de toucher le nœud suivant. L'action Linux `patch_all` ne fournit pas de dry-run; elle peut mettre à jour tous les paquets obsolètes, pas seulement les correctifs de sécurité. Les scripts de pré/post-contrôle du kit ne constituent pas des hooks PatchMon qui bloquent automatiquement les jobs.

En conséquence : **ne pas planifier une politique `patch_all` simultanée sur le groupe des trois nœuds**, et ne pas activer `unattended-upgrades` avec redémarrage autonome. Pour PatchMon, préférer `patch_package` par hôte avec dry-run, revue des dépendances puis approbation; `patch_all` Linux ne peut pas être dry-run. Une politique horaire ne constitue pas une barrière de santé Kubernetes.

Pour une autonomie réellement sûre, l'orchestrateur doit être externe au cluster et, pour chaque hôte : (1) vérifier snapshot etcd et sauvegarde CNPG hors cluster; (2) valider quorum etcd, les trois nœuds Kubernetes/Longhorn et les volumes; (3) refuser le primaire CNPG ou exécuter un switchover planifié vérifié; (4) cordon/drain les charges évictables en excluant `cnpg.io/cluster`; (5) mettre à jour un seul hôte; (6) redémarrer uniquement si nécessaire; (7) attendre Kubernetes Ready puis Longhorn Node Ready, faire `uncordon` et attendre les trois instances CNPG, Authentik Server/Worker, le volume RWX et l'endpoint HTTPS; (8) arrêter immédiatement la séquence à la moindre anomalie. Cet orchestrateur n'est pas déployé par le kit : **les mises à jour restent donc déclenchées et autorisées par un opérateur**, pas autonomes de bout en bout.

## 6. Procédure de maintenance séquentielle avec PatchMon

À exécuter depuis un nœud serveur K3s qui reste Ready et qui n'est pas le nœud en maintenance (de préférence `k3s-1`). Les scripts utilisent le binaire local `k3s` et `/etc/rancher/k3s/k3s.yaml`; le kit, `config.env` et le `secrets.env` opérationnel doivent être présents sur le nœud d'administration. Si la cible est `k3s-1`, exécuter les contrôles depuis `k3s-2` ou `k3s-3`. Traiter **un seul hôte par cycle**.

### 6.1 Avant les mises à jour

1. Vérifier les trois nœuds `Ready`, l'API K3s (`readyz=ok`), trois pods PostgreSQL sains, les trois Authentik Server, les six Worker, Traefik, le volume fichiers RWX et tous les volumes Longhorn PostgreSQL strict-local.
2. Vérifier qu'une sauvegarde etcd récente et une sauvegarde CNPG exploitable existent hors cluster. Le volume Longhorn RWX répliqué n'est pas une sauvegarde applicative.
3. Depuis le répertoire du kit :

```bash
sudo bash scripts/09-patchmon-precheck.sh k3s-2
```

Remplacer `k3s-2` par le seul nœud ciblé. Si le nœud héberge le primaire CNPG, le script bloque. Effectuer un **switchover planifié** vers une instance de secours saine avec la procédure CloudNativePG validée, puis relancer le pré-contrôle. Ne pas supprimer/drainer le primaire pour provoquer le basculement.

### 6.2 Cordon et drain

Après succès du pré-contrôle, appliquer les commandes affichées :

```bash
sudo k3s kubectl cordon k3s-2
sudo k3s kubectl drain k3s-2 --ignore-daemonsets --delete-emptydir-data --pod-selector='!cnpg.io/cluster' --timeout=10m
```

Les pods CloudNativePG sont volontairement exclus du drain : leur PVC strict-local reste sur son nœud. Le nœud ciblé ne doit pas héberger le primaire. Authentik Server/Worker et les pods évictables peuvent se replacer sur les deux nœuds restants dans la limite de leurs contraintes de scheduling.

Si le drain est bloqué par un PodDisruptionBudget, un volume Longhorn, une dernière réplique ou un pod non évictable : **arrêter**. Conserver la politique Longhorn de protection de la dernière réplique saine; ne pas la remplacer par `Always Allow` pour forcer un drain. Ne pas utiliser `--disable-eviction`, `--force` ou supprimer un pod CNPG pour faire passer le drain. Examiner `kubectl describe node`, les PDB, les pods Longhorn et les CR `Volume`/`Node` Longhorn.

### 6.3 Mise à jour et redémarrage éventuel

Dans PatchMon, cibler uniquement l'hôte cordonné. Ne lancer aucune action sur un deuxième hôte tant que le post-contrôle du premier n'est pas terminé.

Si un redémarrage est requis :

- attendre la fin de la transaction APT/dpkg;
- laisser le nœud cordonné et les charges applicatives évictables drainées;
- redémarrer uniquement ce nœud depuis PatchMon ou la console hyperviseur;
- ne pas forcer un redémarrage si le gestionnaire de paquets travaille encore;
- ne jamais redémarrer un deuxième serveur K3s pendant la récupération.

Si aucun redémarrage n'est requis, passer directement au post-contrôle.

### 6.4 Réintégration et post-contrôle

Après retour du système, exécuter depuis le nœud d'administration :

```bash
sudo bash scripts/10-patchmon-postcheck.sh k3s-2
```

Le script attend le retour `Ready` de Kubernetes **et** du nœud Longhorn avant `uncordon`, puis attend le succès de `scripts/04-check.sh` : trois nœuds, Authentik, CNPG, volumes PostgreSQL strict-local, volume RWX et endpoint applicatif.

En cas d'échec après `uncordon`, le script tente de re-cordonner le nœud si l'API est disponible; le cycle s'arrête : ne pas maintenir le nœud suivant. Vérifier côté OS `systemctl is-active k3s`, `systemctl is-active iscsid`, le montage `/var/lib/longhorn` et les événements AppArmor/containerd.

Ne commencer le nœud suivant que lorsque les trois nœuds sont `Ready`, les trois instances PostgreSQL sont `Ready`, les réplicas Authentik/Worker sont disponibles, le volume fichiers RWX et les volumes PostgreSQL sont sains, et l'endpoint Authentik HTTPS répond.

## 7. Redémarrages et mises à niveau à traiter séparément

- **Paquets OS / noyau** : procédure séquentielle ci-dessus; redémarrage selon `/var/run/reboot-required` et les paquets concernés.
- **K3s** : ne pas le traiter comme une simple mise à jour APT. Conserver la version épinglée dans `config.env`; mise à niveau dédiée des serveurs un par un avec contrôle du quorum entre chaque nœud.
- **Longhorn / CNPG / Authentik / Traefik** : mises à niveau séparées des paquets OS, avec procédures de versions, snapshots et sauvegardes propres à chaque composant.
- **AppArmor** : ne pas relancer le correctif automatiquement à chaque mise à jour; diagnostiquer le profil et le noyau avant toute action.

## 8. Réseau et références

La matrice de flux K3s/etcd/Flannel/kubelet/Longhorn, les VIP, SSH et sorties hôtes est fournie dans `docs/NETWORK-FIREWALL.md`. Elle doit être appliquée sous forme d’ACL adaptées aux réseaux réels, pas comme un ruleset générique UFW/nftables sur chaque hôte. Les destinations proxy autorisées sont détaillées dans `docs/PROXY-ALLOWLIST.md`.

Documentation officielle : [PatchMon Admin Guide](https://patchmon.net/docs/patchmon-admin-guide), [Ubuntu unattended-upgrades](https://ubuntu.com/server/docs/how-to/software/automatic-updates), [K3s automated upgrades](https://docs.k3s.io/upgrades/automated), [Kubernetes Safely Drain a Node](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/), [Longhorn Node Maintenance](https://longhorn.io/docs/1.13.0/maintenance/maintenance/), [CloudNativePG](https://cloudnative-pg.io/documentation/1.30/), [Authentik Reputation policies](https://docs.goauthentik.io/policies/reputation/).
