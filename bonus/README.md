# Bonus — GitLab local + Argo CD

Ce dossier ajoute une instance **GitLab** au laboratoire de la Partie 3 et
rebranche toute la chaîne de déploiement continu dessus : ce n'est plus GitHub
qui sert de source à Argo CD, mais un GitLab qui tourne **dans le cluster**.

## Ce qui tourne

| Namespace | Contenu |
|-----------|---------|
| `gitlab`  | GitLab CE, image omnibus officielle `gitlab/gitlab-ce:latest` |
| `argocd`  | Argo CD |
| `dev`     | l'application `wil42/playground`, déployée par Argo CD |

Le tout dans un cluster **K3d** dédié au bonus (`iot-bonus`), pour que la
Partie 3 reste démontrable séparément.

## Installation

```bash
# 1. Outils (Docker, kubectl, k3d, helm, git) — une seule fois
sudo bonus/scripts/install_tools.sh
#    puis se déconnecter/reconnecter pour que le groupe docker s'applique

# 2. Tout le reste (~15 à 25 min, GitLab est long à démarrer)
bonus/scripts/setup.sh
```

`setup.sh` enchaîne quatre étapes, qui peuvent aussi être lancées une par une :

| Script | Rôle |
|---|---|
| `create_cluster.sh`    | cluster K3d, namespaces `argocd`/`dev`/`gitlab`, installation d'Argo CD |
| `install_gitlab.sh`    | déploie GitLab dans le namespace `gitlab` |
| `setup_gitlab_repo.sh` | crée le dépôt sur ce GitLab et y pousse les manifestes |
| `deploy_app.sh`        | branche Argo CD sur ce dépôt et attend `Synced` + `Healthy` |
| `info.sh`              | affiche les URLs, les identifiants et l'état du cluster |
| `switch_version.sh`    | bascule l'application en v1 ou v2 **depuis GitLab** |

## Accès

`bonus/scripts/info.sh` affiche tout, mais en résumé :

| Service | URL | Identifiants |
|---|---|---|
| GitLab | http://gitlab.local:8080 | `root` / voir `info.sh` |
| Argo CD | http://argocd.local:8080 | `admin` / voir `info.sh` |
| Application | http://localhost:8888/ | — |

Aucun mot de passe n'est écrit dans le dépôt : ils sont lus dans les Secrets
Kubernetes (`gitlab-root-password` et `argocd-initial-admin-secret`).

## Démonstration v1 → v2

```bash
curl http://localhost:8888/          # {"status":"ok", "message": "v1"}

bonus/scripts/switch_version.sh v2   # commit + push sur le GitLab local

curl http://localhost:8888/          # {"status":"ok", "message": "v2"}
```

Le script modifie le tag de l'image dans `app/deployment.yaml`, pousse le
commit **sur GitLab**, puis attend qu'Argo CD s'en aperçoive tout seul (il
interroge le dépôt toutes les 3 minutes). `switch_version.sh v2 --now` force
un rafraîchissement immédiat quand on ne veut pas attendre pendant la défense.

La même manipulation peut se faire entièrement à la main depuis l'interface web
de GitLab : éditer `app/deployment.yaml`, commiter, et regarder Argo CD
resynchroniser.

## Choix techniques

### Pourquoi l'image omnibus et pas le chart Helm ?

C'est le point le plus important à savoir expliquer.

Le sujet demande « la dernière version disponible de GitLab sur le site
officiel ». Or **depuis la version 10 du chart Helm officiel (GitLab 19), le
chart ne fournit plus PostgreSQL, Redis ni MinIO** :

```
REMOVALS:
postgresql:
    The bundled PostgreSQL chart has been removed, and thus
    `postgresql.install` does not have any effect.
```

Installer la dernière version *via Helm* imposerait donc de fournir soi-même
une base PostgreSQL (avec les deux bases décomposées `main` et `ci`), un Redis
et un stockage objet compatible S3 — quatre composants supplémentaires à
maintenir, et autant de points de panne le jour de la défense.

L'image `gitlab/gitlab-ce` (dite « omnibus ») est la distribution officielle
tout-en-un documentée sur <https://docs.gitlab.com/install/docker/> : elle
embarque PostgreSQL, Redis, Gitaly, Puma, Sidekiq et Nginx. Elle donne donc la
dernière version officielle de GitLab, dans un seul objet Kubernetes, sans
dépendance externe. Le sujet laisse ce choix libre : « You are allowed to use
whatever you need to achieve this extra. For example, helm **could** be
useful ».

### Comment Argo CD parle-t-il à GitLab ?

Par le Service Kubernetes interne :

```
http://gitlab.gitlab.svc.cluster.local:8080/root/iot-kahoumou.git
```

Le trafic ne sort jamais du cluster : ni DNS de la machine, ni TLS, ni accès
Internet. Le Service écoute volontairement sur le **port 8080**, celui-là même
que GitLab annonce dans son `external_url` — l'adresse du dépôt a donc la même
forme vue de l'intérieur du cluster et depuis un navigateur.

### Pourquoi `external_url` contient-il le port 8080 ?

GitLab génère des liens absolus (redirections, adresses de clone affichées dans
l'interface). Si son `external_url` ne mentionnait pas le port réellement
publié, ces liens pointeraient vers un port fermé. La configuration résout ça
en deux lignes :

```ruby
external_url 'http://gitlab.local:8080'   # ce que voit l'utilisateur
nginx['listen_port'] = 80                 # ce qu'écoute le conteneur
```

Traefik fait la correspondance entre les deux.

### Pourquoi Argo CD est-il reconfiguré à 30 secondes ?

Par défaut, Argo CD empile deux caches de 3 minutes : le cache de révision du
`repo-server`, puis l'intervalle de réconciliation du contrôleur. Un commit
peut donc mettre **jusqu'à 6 minutes** à être vu — mesuré à 5 min 50 s lors des
essais, ce qui est intenable pendant une soutenance.

`create_cluster.sh` ramène les deux à 30 secondes :

```
argocd-cmd-params-cm : reposerver.revision.cache.expiration = 30s
argocd-cm            : timeout.reconciliation                = 30s
```

Sur un dépôt local, le coût est négligeable. Après ce réglage, la bascule
v1 → v2 est déployée en **une dizaine de secondes**, sans aucune action
manuelle dans l'interface Argo CD.

### Pourquoi deux ports publiés par K3d ?

Les deux pointent vers le port 80 du load balancer :

- `8080` sert les interfaces web, que Traefik distingue par nom d'hôte
  (`gitlab.local`, `argocd.local`) ;
- `8888` sert l'application, dont l'Ingress n'a **pas** de `host` : c'est la
  route par défaut. On retrouve donc exactement le `curl http://localhost:8888/`
  de la Partie 3.

`create_cluster.sh` ajoute `gitlab.local` et `argocd.local` dans `/etc/hosts`.

### Deux détails de configuration GitLab

`gitlab_rails['monitoring_whitelist']` autorise les réseaux du cluster.
GitLab restreint ses endpoints de supervision (`/-/health`) à `127.0.0.1` et
répond **404** à tout le reste : sans cette liste, la sonde du kubelet — qui
arrive depuis `10.42.0.1` en K3d — échouerait indéfiniment et le pod ne
passerait jamais `Ready`.

Le clone SSH est publié sur le port 32022 : le port 22 du nœud n'est pas
disponible dans le conteneur K3d.

### Pourquoi GitLab est-il allégé ?

`confs/gitlab.yaml` désactive la supervision Prometheus, le registre d'images,
l'agent Kubernetes, Pages et Mattermost, et fait tourner Puma en mono-processus.
Sans ces réglages, l'omnibus réclame plus de 8 Go de RAM. Chaque désactivation
est commentée dans le fichier.

## Fichiers de configuration

| Fichier | Rôle |
|---|---|
| `confs/gitlab.yaml`            | GitLab : ConfigMap omnibus, Service, StatefulSet, Ingress |
| `confs/application.yaml`       | Application Argo CD pointant sur le dépôt **GitLab** |
| `confs/argocd-repo-secret.yaml`| identifiants du dépôt GitLab pour Argo CD (mot de passe injecté à l'exécution) |
| `confs/argocd-ingress.yaml`    | accès navigateur à Argo CD |
| `confs/app/`                   | manifestes de l'application, poussés dans le dépôt GitLab |

## Vérifié en conditions réelles

L'ensemble a été déroulé de bout en bout sur un cluster K3d :

| Étape | Résultat |
|---|---|
| GitLab | `gitlab-ce 19.3.1`, pod `1/1 Running` |
| Interface GitLab via Traefik | `HTTP 200`, redirection vers `http://gitlab.local:8080/users/sign_in` |
| Dépôt créé et poussé | `root/iot-kahoumou`, branche `main` |
| Argo CD → dépôt GitLab local | `Synced` / `Healthy` |
| `curl http://localhost:8888/` | `{"status":"ok", "message": "v1"}` |
| `switch_version.sh v2` | déployé en **10 s**, `{"status":"ok", "message": "v2"}` |

## Remise à zéro

```bash
k3d cluster delete iot-bonus
rm -rf ~/.iot-bonus
```
