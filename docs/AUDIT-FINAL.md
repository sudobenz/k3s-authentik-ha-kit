# Rapport d'audit – kit K3s + Authentik

Date de consolidation : 12 novembre 2026.

## Résultat général

Le kit a été complété et corrigé pour mieux représenter le déploiement connu. Les vérifications statiques effectuées sur cette archive sont positives : tous les scripts Bash passent `bash -n`, le script Python passe `py_compile`, les YAML livrés sont analysables et les chemins locaux indispensables repérés dans les scripts sont présents.

**Cette validation n'est pas un test d'exécution sur le cluster.** Aucun script de bootstrap, Helm ou `kubectl apply` n'a été exécuté contre l'infrastructure réelle pendant l'audit de l'archive.

## Corrections et ajouts

| Élément | Intervention | Importance |
|---|---|---|
| `manifests/storageclasses.yaml` | Ajout des deux StorageClasses référencées par l'installation Longhorn : PostgreSQL strict-local (1 réplique Longhorn par volume) et Authentik RWX (3 réplicas, non-migratable). | Bloquant corrigé |
| `config.env.example` | Publication d’un modèle de configuration non sensible ; les paramètres propres à un cluster restent dans le fichier local `config.env`, exclu de Git. | Séparation public/local |
| `scripts/config.env` | Suppression de la copie ancienne et divergente qui créait une ambiguïté. Les scripts lisent `config.env` à la racine. | Ambiguïté corrigée |
| `config/headlamp-plugins.yml` | Ajout des plugins CNPG `0.1.6` et cert-manager `0.1.1`, correspondant aux versions communiquées pendant le déploiement. | Ajout |
| `scripts/12-install-headlamp.sh` | Ajout de l'installation/mise à jour Headlamp 0.46.0, activation du gestionnaire de plugins et attente de leur téléchargement (5 minutes maximum). | Ajout |
| `scripts/13-check-platform-addons.sh` | Ajout des contrôles Operator CNPG, cluster PostgreSQL, CRD/Deployments cert-manager, Headlamp, plugins et permissions de lecture cert-manager. Le nom de ServiceAccount est désormais découvert depuis le Deployment. | Ajout |
| `scripts/11-configure-dashboard-ingress.sh` | Le script ne remplace plus silencieusement un Secret TLS manquant/invalide par un certificat autosigné ; validation SAN, dates et clé/certificat ; conservation de BasicAuth Longhorn par défaut. Rotation uniquement avec `--rotate-longhorn-auth`. | Sécurité renforcée |
| `scripts/04-check.sh` | Ajout du contrôle de disponibilité du contrôleur CNPG ; vérification TLS séparée ; `curl --insecure` réservé au contrôle de readiness avec certificat de bootstrap autosigné. | Contrôle corrigé |
| `scripts/00-install-helm.sh` | Correction de l'URL de checksum Helm : fichier officiel `.sha256sum` au lieu de `.sha256`. | Bloquant corrigé |
| `scripts/prepare-longhorn-disk.sh` | Paramétrage du disque, de la partition et du point de montage ; validation du disque parent de la partition avant formatage. | Sécurité / portabilité |
| `scripts/06-http-benchmark.py` | Ajout d'une option `--insecure` explicite pour le benchmark avec certificat autosigné. | Ajout |
| Documentation | Ajout du guide racine, des procédures TLS/cert-manager/Portainer, de l'allowlist proxy, et des instructions Edge Agent. | Ajout |
| `.gitignore` | Exclusion des secrets, kubeconfigs, données générées, clés/certificats et manifeste Edge Agent propre à l'environnement. | Sécurité |

## Points non embarqués ou non prouvés

1. **Installation cert-manager** : sa présence est confirmée par les CRD communiquées et son plugin est configuré, mais la version du contrôleur et sa méthode d'installation n'ont pas été communiquées. Le kit ne contient donc pas de commande d'installation arbitraire ni de mise à niveau. Récupérer la version via `helm list -A` et les images des Deployments avant de figer cette étape.
2. **Portainer Edge Agent** : le manifeste est généré par Portainer Server et contient des données de jumelage propres à l'environnement. Il ne doit pas être inclus dans une archive partageable. La procédure de génération et d'intégration est documentée.
3. **Certificat/clé TLS** : les fichiers privés ne sont pas livrés. Le kit crée un certificat autosigné de bootstrap lors de l'installation initiale. Un certificat externe peut être importé dans le Secret `authentik/authentik-tls` avec Portainer, puis synchronisé vers les autres namespaces par le script 11.
4. **Renouvellement du certificat importé** : importer un Secret TLS ne crée pas de ressource cert-manager `Certificate`. L'émission/renouvellement automatique par cert-manager reste à configurer avec un Issuer/ClusterIssuer adapté ou un mécanisme externe.
5. **Headlamp OIDC avec Authentik** : le plugin Headlamp et les deux plugins spécialisés sont inclus ; la configuration SSO OIDC avec Authentik et le mapping des groupes AD vers Kubernetes RBAC ne sont pas inclus car ils n'ont pas été déployés dans les éléments fournis.
6. **Headlamp RBAC** : les valeurs par défaut du chart Headlamp 0.46.0 peuvent associer sa ServiceAccount à `cluster-admin`. Les tests `kubectl auth can-i` communiqués pendant le déploiement montrent des privilèges étendus. Traiter l'interface comme réservée aux administrateurs tant qu'un RBAC restreint n'est pas déployé et vérifié.
7. **Prometheus/Grafana/Loki** : seul `prometheus-values.yaml` est présent ; il n'y a pas de script d'installation de la stack de supervision dans cette archive. Le fichier de valeurs ne doit pas être présenté comme un déploiement effectif.
8. **Backups et restauration** : aucune sauvegarde de bases, de volumes Longhorn, d'etcd ou procédure de restauration testée n'est incluse dans l'archive.

## Validation exécutée sur les fichiers

- `bash -n` sur les scripts `scripts/*.sh` et `extend-sdb.sh` : OK.
- `python3 -m py_compile scripts/06-http-benchmark.py` : OK.
- Analyse PyYAML de `manifests/storageclasses.yaml`, `config/headlamp-plugins.yml` et `prometheus-values.yaml` : OK.
- Vérification présence des dépendances locales : OK.
- Test `scripts/prepare-longhorn-disk.sh --help` : OK.

## Séquence de prudence

L'archive est destinée à documenter et reproduire l'installation sur un environnement neuf après adaptation de `config.env`. Sur un cluster déjà déployé, ne pas relancer les scripts de bootstrap `00`, `01` ou `03` : ils sont conçus pour une installation initiale et certains contrôlent/refusent les ressources existantes. Utiliser les scripts `04` et `13` pour les contrôles, et les scripts `11`/`12` uniquement pour leurs opérations spécifiques après sauvegarde de la révision Helm concernée.


## Extension du 12 novembre 2026 – protection des hôtes et maintenance

- Ajout de `docs/HOST-SECURITY-MAINTENANCE.md` : choix Fail2ban, protection Authentik native, règles de non-activation UFW générique, limites PatchMon et procédure de maintenance séquentielle.
- Ajout de `docs/NETWORK-FIREWALL.md` : flux K3s/etcd/Flannel/Longhorn, entrée VIP, SSH et sorties des hôtes.
- Ajout de `scripts/configure-host-protection.sh` et `scripts/check-host-protection.sh` : jail SSH Fail2ban avec backend systemd, liste d'exclusion d'administration obligatoire et désactivation de l'installation automatique APT/redémarrage local.
- Renforcement des scripts PatchMon : contrôle préalable de l'état Ready Longhorn, exclusion des pods CNPG du drain pour préserver les PVC strict-local, attente du nœud Longhorn Ready avant `uncordon`, puis tentative de re-cordon si les contrôles complets expirent après la réintégration.
- Les contrôles sont statiques; aucun changement de pare-feu ni de paquet n'a été appliqué à l'infrastructure réelle. Le kit ne configure pas un orchestrateur autonome externe de mise à jour OS; cette limite est explicitement documentée car PatchMon, seul, ne fournit pas de barrière cluster-aware suffisante dans la configuration fournie.


## Correctif complémentaire — conservation de l'IP source Traefik

- `scripts/02b-configure-ingress.sh` persiste `service.spec.externalTrafficPolicy: Local` dans le `HelmChartConfig` K3s/Traefik.
- Le script attend et vérifie explicitement cette valeur après la réconciliation Helm ; il échoue si le Service revient à `Cluster`.
- `scripts/04-check.sh` vérifie également cette propriété lors du contrôle général du cluster.
- Le README et la matrice réseau documentent la nécessité de conserver un endpoint Traefik prêt sur chacun des nœuds pouvant porter la VIP (trois réplicas avec anti-affinité obligatoire).
- Aucun réglage `forwardedHeaders.insecure`, CIDR proxy Authentik ou paramètre Kube-VIP superflu n'a été ajouté.

## Recontrôle de publication — 18 novembre 2026

La révision 1.2.2 a fait l'objet d'un second contrôle statique après nettoyage du contenu publié : syntaxe Bash de tous les scripts, analyse YAML, vérification des références documentaires et recherche globale de références à des composants applicatifs hors périmètre. Les scripts de maintenance et de mise à niveau ont été spécialisés sur la solution de ce dépôt. Aucun essai de déploiement sur cluster n'a été exécuté dans le cadre de ce recontrôle.
