#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Sauvegarde de la stack Keycloak vers borgwarehouse.
# Lance par :  make backup   (et chaque nuit par la crontab de l'utilisateur,
#              et avant chaque make update)
#
# Principe : pg_dump coherent DANS le conteneur keycloack-postgres (son propre
# utilisateur, pas de mot de passe ici) -> UNE archive borg avec le dump et
# les EXTRA_PATHS (.env, docker-compose.yml, themes) -> prune -> nettoyage.
# postgres_data/ n'est PAS archive : des fichiers copies a chaud = base
# corrompue, le dump est la seule forme fiable.
#
# CONFIGURATION : aucun secret ici. Tout est dans scripts/.env (ignore par
# git, voir scripts/env_example), ecrit par `make init` : BORG_PREFIX,
# BORG_REPO, BORG_PASSPHRASE. Cle SSH dediee au depot : scripts/.ssh/.
# Ce n'est pas le .env de la stack : celui-ci reste aux variables du compose.
#
# Ce script vient du kit borgwarehouse (borgwarehouse/scripts/
# backup_postgres_example.sh), integre ici comme dans les stacks Nextcloud,
# Ghost, Etherpad et Docuseal.
#
#   ./backup_keycloak.sh --init   # initialise le depot (fait par make init)
#   ./backup_keycloak.sh          # sauvegarde
#####

## Surveillance optionnelle via Sentry :
# export SENTRY_DSN=''
# eval "$(sentry-cli bash-hook)"


SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"

# Secrets et config : dans le .env à côté du script (voir env_example).
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
[ -f "$ENV_FILE" ] || { echo "[pg-borg] .env introuvable : $ENV_FILE (cp env_example .env)" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

# Connexion PostgreSQL (valeurs par défaut si absentes du .env).
export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-}"   # ou vide, et un ~/.pgpass (chmod 600)
# Base à sauvegarder. Vide = TOUTES les bases (pg_dumpall).
PGDATABASE="${PGDATABASE:-}"

# Mode Docker : si PG_DOCKER_CONTAINER est renseigné, pg_dump tourne DANS ce
# conteneur (docker exec), avec son POSTGRES_USER via le socket local : pas
# besoin de port exposé ni de mot de passe dans le .env.
PG_DOCKER_CONTAINER="${PG_DOCKER_CONTAINER:-}"

# Chemins supplémentaires archivés avec le dump (config, thèmes…), séparés par
# des espaces. Les chemins relatifs le sont au dossier du script.
EXTRA_PATHS="${EXTRA_PATHS:-}"

PREFIX="${BORG_PREFIX:?BORG_PREFIX doit être renseigné dans le .env}"

# Clé SSH dédiée à ce dépôt (une clé = un dépôt sur borgwarehouse)
SSH_KEY="${SSH_KEY:-$SCRIPT_DIR/.ssh/${PREFIX}_ed25519}"

# Dossier de travail pour le dump (supprimé après l'archivage)
DUMP_DIR="${DUMP_DIR:-$SCRIPT_DIR/pg-dump-$PREFIX}"


#### PRÉPARATION ####
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes

# Une seule sauvegarde à la fois. Sans ce verrou, un lancement manuel qui tombe
# pendant le cron partagerait le même DUMP_DIR : le premier à finir le supprime
# (trap EXIT) pendant que l'autre archive encore, et on obtient une archive SANS
# DUMP, silencieusement.
exec 9>"$SCRIPT_DIR/.backup-pg.lock"
flock -n 9 || { echo "[pg-borg] une sauvegarde est déjà en cours — abandon." >&2; exit 1; }

: "${BORG_REPO:?BORG_REPO doit être renseigné dans le .env}"
: "${BORG_PASSPHRASE:?BORG_PASSPHRASE doit être renseigné dans le .env}"
command -v borg    >/dev/null || { echo "[pg-borg] borg introuvable dans le PATH" >&2; exit 1; }
if [ -n "$PG_DOCKER_CONTAINER" ]; then
  docker inspect -f '{{.State.Running}}' "$PG_DOCKER_CONTAINER" 2>/dev/null | grep -qx true \
    || { echo "[pg-borg] conteneur $PG_DOCKER_CONTAINER absent ou arrêté" >&2; exit 1; }
else
  command -v pg_dump >/dev/null || { echo "[pg-borg] pg_dump introuvable dans le PATH" >&2; exit 1; }
fi

DATE_NOW=$(date +%Y-%m-%d-%H-%M)

if [ -f "$SSH_KEY" ]; then
  chmod 600 "$SSH_KEY" 2>/dev/null || true
  export BORG_RSH="/usr/bin/ssh -oStrictHostKeyChecking=accept-new -oIdentitiesOnly=yes -i $SSH_KEY"
else
  echo "[pg-borg] [INFO] aucune clé à $SSH_KEY — SSH utilisera la config système." >&2
fi

# Mode init
if [ "${1:-}" = "--init" ]; then
  echo "$DATE_NOW initialisation du dépôt borg ($BORG_REPO) avec repokey-blake2"
  /usr/bin/borg init -e repokey-blake2 "$BORG_REPO"
  exit 0
fi


#### DUMP POSTGRES ####
# Nettoyage garanti du dump même en cas d'erreur.
trap 'rm -rf "$DUMP_DIR"' EXIT
rm -rf "$DUMP_DIR"
mkdir -p "$DUMP_DIR"

if [ -n "$PG_DOCKER_CONTAINER" ]; then
  # Base et utilisateur : ceux du .env s'ils sont donnés, sinon ceux du conteneur.
  DB_NAME="${PGDATABASE:-$(docker exec "$PG_DOCKER_CONTAINER" printenv POSTGRES_DB)}"
  DUMP_FILE="$DUMP_DIR/$DB_NAME.dump"
  echo "$DATE_NOW dump de la base '$DB_NAME' via docker exec $PG_DOCKER_CONTAINER (format custom)"
  # sh -c côté conteneur pour lire SON $POSTGRES_USER ; la base est passée en
  # argument positionnel ($1), jamais interpolée dans la commande.
  docker exec "$PG_DOCKER_CONTAINER" sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$1"' _ "$DB_NAME" > "$DUMP_FILE"
elif [ -n "$PGDATABASE" ]; then
  DUMP_FILE="$DUMP_DIR/$PGDATABASE.dump"
  echo "$DATE_NOW dump de la base '$PGDATABASE' (format custom)"
  # -Fc : format compressé, restaurable avec pg_restore
  pg_dump -Fc "$PGDATABASE" -f "$DUMP_FILE"
else
  DUMP_FILE="$DUMP_DIR/all-databases.sql"
  echo "$DATE_NOW dump de TOUTES les bases (pg_dumpall)"
  command -v pg_dumpall >/dev/null || { echo "[pg-borg] pg_dumpall introuvable" >&2; exit 1; }
  pg_dumpall -f "$DUMP_FILE"
fi

# Garde-fou : un dump vide = on n'archive pas.
if [ ! -s "$DUMP_FILE" ]; then
  echo "[pg-borg] dump vide ($DUMP_FILE) — abandon" >&2
  exit 1
fi


#### BORG CREATE ####
# Codes de sortie borg : 0 = succès, 1 = avertissement (fichier illisible), 2 et
# plus = vraie erreur. Avec `set -e`, un simple warning tuerait le script : on
# capture le code, on tolère 1, on n'echoue que sur >= 2. Le dump PostgreSQL,
# lui, reste strict (un dump raté est une vraie erreur, déjà géré plus haut).
borg_tolerant() {
  local rc=0
  "$@" || rc=$?
  if [ "$rc" -ge 2 ]; then
    echo "[pg-borg] ERREUR : '$1' a échoué (code $rc)" >&2
    exit "$rc"
  fi
  [ "$rc" -eq 1 ] && echo "[pg-borg] (avertissement borg ignoré, code 1)" >&2
  return 0
}

SOURCES=("$DUMP_DIR")
for p in $EXTRA_PATHS; do
  case "$p" in /*) : ;; *) p="$SCRIPT_DIR/$p" ;; esac
  p="$(realpath -m "$p")"
  if [ -e "$p" ]; then SOURCES+=("$p"); else echo "[pg-borg] [WARN] EXTRA_PATHS absent : $p" >&2; fi
done

echo "$DATE_NOW on crée l'archive borg"
borg_tolerant /usr/bin/borg create -vs --compression lz4 \
  "$BORG_REPO::$PREFIX-$DATE_NOW" \
  "${SOURCES[@]}"

echo "$DATE_NOW on prune les vieux borg :"
# --glob-archives : le prune ne touche QUE les archives de cette sauvegarde. Si
# deux sauvegardes partagent un depot, chacune garde sa retention — sans ce
# filtre, elles se rognent mutuellement, en silence.
borg_tolerant /usr/bin/borg prune -v --list \
  --glob-archives "$PREFIX-*" \
  --keep-within=7d --keep-daily=30 --keep-weekly=12 --keep-monthly=-1 --keep-yearly=-1 \
  "$BORG_REPO"

echo "$DATE_NOW terminé"
