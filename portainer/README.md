# Portainer Edge Agent – manifeste propre à l'environnement

Le script `scripts/08-integrate-portainer.sh` installe uniquement le Portainer Edge Agent Standard dans le cluster K3s. Il ne déploie pas Portainer Server.

Le manifeste Edge Agent Standard est généré par le Portainer Server qui gère l'environnement. Il contient des informations d'association propres à cet environnement (notamment Edge Key / Edge ID). Il ne faut pas fabriquer ces valeurs, réutiliser un manifeste d'un autre environnement ou versionner le manifeste généré.

Procédure :

1. Dans Portainer Server, ajouter un environnement Kubernetes avec **Edge Agent Standard**.
2. Choisir/générer le manifeste Kubernetes proposé pour cet environnement.
3. Télécharger le YAML et le transférer de manière sécurisée sur `k3s-1`.
4. Le placer sous `portainer/portainer-agent-edge-k8s.yaml` avec des droits `0600`.
5. Vérifier `PORTAINER_NAMESPACE` et `PORTAINER_USE_PROXY` dans `config.env`.
6. Exécuter :

```bash
./scripts/08-integrate-portainer.sh
```

Le script valide le manifeste, exige trois nœuds K3s Ready, installe l'agent et attend son démarrage. Dans Portainer Server, l'environnement doit ensuite passer à l'état **Up**.

Ne pas ajouter le manifeste généré à l'archive ou à un dépôt Git. `.gitignore` l'exclut volontairement.
