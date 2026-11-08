# Keycloak

Serveur d'authentification (SSO) derrière Traefik v3 : `auth.lamiete.fr`.
Nextcloud (sociallogin) et les autres services s'y connectent en OpenID Connect.

| Service | Image | Version (`.env`) |
|---|---|---|
| `keycloak` | `quay.io/keycloak/keycloak:${KEYCLOAK_VERSION}` | `KEYCLOAK_VERSION=26.8.2` (exacte) |
| `keycloack-postgres` | `postgres:${POSTGRES_TAG}-bookworm` | `POSTGRES_TAG=16` |

---

## Au quotidien : le Makefile

```
make up / down / restart    démarre, arrête, redémarre la stack
make logs                   suit les logs de Keycloak
make ps                     état des conteneurs

make backup                 sauvegarde borg maintenant (dump PostgreSQL + config + thèmes)
make check                  vérifie que la dernière sauvegarde est restaurable
make list                   liste les archives du dépôt
make mount / umount         monte les archives en lecture seule (ARCHIVE=<nom>)
make init                   configure la sauvegarde (clé SSH, dépôt BWH, cron)

make update-check           que ferait make update ? (rien ne change)
make update                 mise à jour prudente, retour arrière automatique si KO
```

Tout vit dans `scripts/`, comme pour les stacks Nextcloud, Ghost, Etherpad et
Docuseal ; le Makefile n'est qu'une table des matières :

| Fichier | Rôle |
|---|---|
| `scripts/backup_keycloak.sh` | `pg_dump` dans le conteneur → une archive borg (dump + `.env` + compose + thèmes) → prune |
| `scripts/check_backup.sh` | fraîcheur de la dernière archive, contenu, dump lisible par `pg_restore` |
| `scripts/init_backup.sh` | clé SSH dédiée, dépôt BorgWarehouse, `borg init`, ligne de crontab |
| `scripts/update_stack.sh` + `stack.conf` | mise à jour prudente (voir plus bas) |
| `scripts/.env`, `scripts/.ssh/` | configuration et clé du dépôt borg (ignorés par git) |

Deux `.env`, comme pour Nextcloud : celui de la stack (variables du compose)
et `scripts/.env` (sauvegarde). Sauvegarde chaque nuit par la crontab de
l'utilisateur :

```
@daily bash /poule/miete/auth/Keycloak/scripts/backup_keycloak.sh >> /home/jonas/.borg-backup-keycloack-miete.log 2>&1
```

---

## Installation

```bash
cp env_example .env && chmod 600 .env    # mots de passe, VIRTUAL_HOST, versions
make up
cp scripts/env_example scripts/.env && chmod 600 scripts/.env && make init
```

---

## Mises à jour

Les versions sont dans le `.env`, **pas** dans le compose. Chaque cas a sa
commande, et `make update` refuse ce qui n'est pas prévu, **avant** de couper
quoi que ce soit.

| Ce qu'on veut | Comment |
|---|---|
| correctifs PostgreSQL (16.x) | `make update` |
| nouvelle version de Keycloak | lire les guides de migration (https://www.keycloak.org/docs/latest/upgrading/), tester sur une copie de la base (voir Historique, 26.8.2), `KEYCLOAK_VERSION=26.x.y` dans le `.env`, puis `make update CONFIRME=1` |
| PostgreSQL 16 → 17 | pas par `make update` : dump / restauration (à scripter le jour venu, voir le `pg_upgrade.sh` du dépôt Nextcloud) |

Ce que fait `make update` :

1. relève l'image de chaque conteneur et le code HTTP de `auth.lamiete.fr` et
   de la découverte OIDC (`/realms/master/.well-known/openid-configuration`) ;
2. `pull` : rien de nouveau → fin ;
3. **garde-fous** : refus (et rien ne change) si
   - la nouvelle image est une version plus ancienne ;
   - Keycloak change de version sans `CONFIRME=1`, ou `KEYCLOAK_VERSION` n'est pas
     une version exacte (`latest` est refusé), ou elle est plus ancienne que la
     base (Keycloak migre la base, il ne sait pas revenir en arrière) ;
   - `POSTGRES_TAG` n'est pas la version des données ;
   - l'image PostgreSQL change de Debian (12 → 13) : la glibc, donc le tri du
     texte et les index, changeraient sous la base ;
4. sauvegarde borg **et** vérification qu'elle est restaurable ;
5. copie physique de `postgres_data/` (Keycloak et PostgreSQL arrêtés, ~8 Mo
   compressés) dans `.snapshots/` (3 dernières gardées) ;
6. `up -d` ;
7. contrôles : conteneurs démarrés et stables, les URL répondent comme avant,
   collations PostgreSQL inchangées, realms lisibles ;
8. si un contrôle échoue : **retour arrière automatique** (anciennes images,
   `postgres_data/` restauré depuis la copie et, si une version avait été
   changée dans le `.env`, compose et `.env` remis à la dernière configuration
   qui a marché, gardée dans `.snapshots/config-ok/`), puis nouveau contrôle.

Les contrôles d'URL exigent **la même famille de code qu'avant** (200 → 2xx,
302 → 3xx) : pendant le démarrage de Keycloak, Traefik répond 404, ce qui n'est
pas une preuve que le site marche.

La copie de l'étape 5 est ce qui rend le retour arrière possible même après une
migration de Keycloak : remettre l'ancienne image ne suffirait pas.

### Retour arrière à la main

```bash
make down
docker run --rm -v "$PWD:/s" -v "$PWD/.snapshots/<date>:/o:ro" alpine:3.22 \
  sh -c 'cd /s && rm -rf postgres_data && tar -xzf /o/copie.tgz'
# remettre les versions d'avant dans le .env, puis
make up
```

Ou depuis borg : `make list`, puis restaurer `keycloak.dump` avec `pg_restore`.

---

## Historique

- **8 nov. 2026** — versions sorties du compose vers le `.env`
  (`KEYCLOAK_VERSION=latest`, inutilisé, remplacé par `26.0.7`) ; PostgreSQL figé
  sur `-bookworm` (`postgres:16` est passé à Debian 13, alors que la base a été
  créée sous Debian 12) ; `make update` avec garde-fous et retour arrière ;
  `.gitignore` ; `.env` passé en `chmod 600` (il était lisible par tous).
  Mise à jour PostgreSQL 16.6 → 16.15 par `make update` : ~1 min de coupure, OK.
- **8 nov. 2026** — sauvegarde alignée sur les autres stacks : le kit
  `backup/` (Makefile, `.env` et scripts à part) est fondu dans `scripts/`
  (`backup_postgres_example.sh` → `backup_keycloak.sh`, `backup/.env` →
  `scripts/.env`, clé SSH dans `scripts/.ssh/`), un seul Makefile, crontab
  mise à jour. Même dépôt borg, mêmes archives. Vérifié : `make backup`,
  `make check`, `make list`.
- **8 nov. 2026** — **Keycloak 26.0.7 → 26.8.2.**
  - Guides de migration 26.1 → 26.8 lus. Passage direct possible (Keycloak
    arrêté). Vérifié dans la base, sans impact ici : un seul client (Nextcloud,
    redirection `https://nuage.lamiete.fr/*`, pas de joker d'hôte, refusés
    depuis 26.6.3), base en UTF-8, SMTP en SSL 465 (pas de STARTTLS, durci en
    26.8.1), « Remember Me » désactivé, aucune session hors ligne, Nextcloud ne
    demande que `openid`, pas de fédération ni de fournisseur d'identité.
  - Compose : retrait des options hostname v1 (`KC_HOSTNAME_ADMIN_URL`,
    `KC_HOSTNAME_STRICT_HTTPS`, `KC_PROXY`, `PROXY_ADDRESS_FORWARDING`,
    `KC_HOSTNAME`, `VIRTUAL_HOST`) ; `--http-enabled=true` explicite (Traefik
    parle en HTTP ; c'était `KC_PROXY=edge`) ; `--features-disabled=scim-api`
    (API SCIM activée par défaut en 26.8, inutilisée).
  - Test préalable sur une **copie** de la base (réseau docker isolé) :
    migration 26.1 → 26.8.2 en 6 s, émetteur OIDC, page de connexion du client
    Nextcloud, refus d'une redirection étrangère, console d'admin : OK.
  - Production : `make update CONFIRME=1`, ~30 s de coupure. Vérifié : émetteur
    `https://auth.lamiete.fr/realms/master`, connexion Nextcloud → Keycloak,
    console d'admin, SCIM fermé (404).
  - Défauts du script corrigés au passage : contrôle d'URL qui acceptait le 404
    de Traefik pendant le démarrage ; retour arrière qui ne savait pas revenir
    à l'ancienne version quand elle avait été changée dans le `.env`.
  - Retour à 26.0.7 possible à la main (voir « Retour arrière à la main ») avec
    `.snapshots/2026-11-08-103323/` (base d'avant la migration),
    `KEYCLOAK_VERSION=26.0.7` et l'ancienne ligne `command`.
