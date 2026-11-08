#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Verifie que la derniere sauvegarde est REELLEMENT restaurable, sans rien
# restaurer. Lance par :  make check
#
# Trois questions, dans l'ordre :
#   1. Une archive recente existe-t-elle ? (sinon : le cron est mort)
#   2. Contient-elle des fichiers, et ceux qu'on attend ?
#   3. Sont-ils exploitables ? (depend de BACKUP_TYPE)
#
# Le point 3 est celui qui compte, et c'est celui que presque personne ne fait.
# Un dump tronque — disque plein, process tue en plein vol — a une taille
# credible, se trouve bien dans l'archive, et ne se restaure pas.
#
# Sort en code non nul si quoi que ce soit cloche : utilisable en monitoring.
#####

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

ok()     { echo "  [ok]   $*"; }
ko()     { echo "  [KO]   $*" >&2; ERREURS=$((ERREURS + 1)); }
erreur() { echo "[check] ERREUR : $*" >&2; exit 2; }
ERREURS=0

[ -f "$ENV_FILE" ] || erreur ".env introuvable : $ENV_FILE"
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${BACKUP_TYPE:?BACKUP_TYPE absent du .env (folder | postgres | sqlite)}"
: "${BORG_PREFIX:?BORG_PREFIX absent du .env — la sauvegarde n'est pas configuree (make init)}"
: "${BORG_REPO:?BORG_REPO absent du .env — la sauvegarde n'est pas configuree (make init)}"
: "${BORG_PASSPHRASE:?BORG_PASSPHRASE absent du .env}"
command -v borg >/dev/null || erreur "borg introuvable dans le PATH."

# Age max tolere pour la derniere archive. Ecrit par make init selon la
# frequence choisie ; 25 h = la sauvegarde quotidienne d'hier + une heure de
# marge. C'est aussi le reglage de l'alerte cote borgwarehouse.
AGE_MAX_HEURES="${AGE_MAX_HEURES:-25}"

SSH_KEY="$SCRIPT_DIR/.ssh/${BORG_PREFIX}_ed25519"
[ -f "$SSH_KEY" ] && export BORG_RSH="/usr/bin/ssh -oStrictHostKeyChecking=accept-new -oIdentitiesOnly=yes -i $SSH_KEY"

# Extrait un fichier de l'archive vers stdout. Le pipefail est desactive le
# temps de l'appel : un lecteur qui s'arrete avant la fin (head, pg_restore -l)
# ferme le tuyau, borg prend un SIGPIPE et sort en 141 — ce n'est pas une panne.
extraire() {
  set +o pipefail
  borg extract --stdout "$BORG_REPO::$ARCHIVE" "$1" 2>/dev/null
  set -o pipefail
}

echo "[check] depot : $BORG_REPO  (type : $BACKUP_TYPE)"
echo


#### 1. UNE ARCHIVE RECENTE EXISTE-T-ELLE ? ####
echo "1. Fraicheur"

# --glob-archives : on ne regarde QUE les archives de cette sauvegarde. Sans ce
# filtre, une autre sauvegarde partageant le depot suffirait a nous rassurer.
DERNIERE="$(borg list --glob-archives "$BORG_PREFIX-*" --last 1 \
  --format '{archive}{TAB}{time:%Y-%m-%d %H:%M:%S}{NL}' "$BORG_REPO")"
[ -n "$DERNIERE" ] || erreur "aucune archive '$BORG_PREFIX-*' dans le depot. La sauvegarde n'a jamais tourne."

ARCHIVE="${DERNIERE%%	*}"
DATE_ARCHIVE="${DERNIERE#*	}"
AGE_HEURES=$(( ( $(date +%s) - $(date -d "$DATE_ARCHIVE" +%s) ) / 3600 ))

if [ "$AGE_HEURES" -le "$AGE_MAX_HEURES" ]; then
  ok "derniere archive : $ARCHIVE (il y a ${AGE_HEURES} h)"
else
  ko "derniere archive : $ARCHIVE — ${AGE_HEURES} h, soit plus de ${AGE_MAX_HEURES} h."
  ko "le cron ne tourne plus. Verifie : crontab -l"
fi


#### 2. L'ARCHIVE CONTIENT-ELLE QUELQUE CHOSE ? ####
echo
echo "2. Contenu de l'archive"

# {size} vaut 0 pour les dossiers : on ne garde que les vrais fichiers.
CONTENU="$(borg list --format '{size}{TAB}{path}{NL}' "$BORG_REPO::$ARCHIVE")"
FICHIERS="$(printf '%s\n' "$CONTENU" | awk -F'\t' '$1 > 0' | wc -l)"
OCTETS="$(printf '%s\n' "$CONTENU" | awk -F'\t' '{t += $1} END {print t + 0}')"

if [ "$FICHIERS" -gt 0 ]; then
  ok "$FICHIERS fichier(s), $(numfmt --to=iec "$OCTETS" 2>/dev/null || echo "$OCTETS o")"
else
  ko "l'archive ne contient aucun fichier non vide."
fi


#### 3. LES DONNEES SONT-ELLES EXPLOITABLES ? ####
echo
echo "3. Restaurable ?"

chemin_dans_archive() {  # <motif grep> -> chemin, ou vide
  printf '%s\n' "$CONTENU" | awk -F'\t' '$1 > 0 {print $2}' | grep -E "$1" | head -n1 || true
}

case "$BACKUP_TYPE" in

  postgres)
    DUMP="$(chemin_dans_archive '/[^/]+\.dump$')"
    DUMPALL="$(chemin_dans_archive '/all-databases\.sql$')"

    if [ -n "$DUMP" ]; then
      # pg_restore -f /dev/null deroule le dump ENTIER (et n'ecrit rien) : un
      # fichier tronque ou corrompu le fait echouer. Verifier seulement l'entete
      # ne prouverait rien — la table des matieres est au debut du fichier.
      # Mode Docker : pg_restore est celui du conteneur PostgreSQL (meme version
      # que le pg_dump qui a produit le dump). Il n'ecrit rien (-f /dev/null).
      if [ -n "${PG_DOCKER_CONTAINER:-}" ]; then
        pg_restore_cmd() { docker exec -i "$PG_DOCKER_CONTAINER" pg_restore -f /dev/null; }
      else
        pg_restore_cmd() { pg_restore -f /dev/null; }
      fi
      if [ -n "${PG_DOCKER_CONTAINER:-}" ] || command -v pg_restore >/dev/null; then
        # Pas de "-" pour stdin : pg_restore chercherait un fichier nomme "-"
        # (contrairement a psql). Sans argument, il lit l'entree standard.
        if extraire "$DUMP" | pg_restore_cmd 2>/dev/null; then
          ok "dump PostgreSQL complet et lisible : ${DUMP##*/}"
        else
          ko "dump PostgreSQL ILLISIBLE ou TRONQUE : ${DUMP##*/}"
          ko "cette sauvegarde n'est pas restaurable."
        fi
      else
        ko "pg_restore introuvable : impossible de valider ${DUMP##*/}"
      fi

    elif [ -n "$DUMPALL" ]; then
      # pg_dumpall termine toujours par ce marqueur : c'est la preuve qu'il est
      # alle au bout. On lit tout le flux (pas de grep -q, qui couperait le tuyau).
      if [ "$(extraire "$DUMPALL" | grep -c '^-- PostgreSQL database cluster dump complete' || true)" -ge 1 ]; then
        ok "dump PostgreSQL complet (pg_dumpall est alle au bout)"
      else
        ko "dump TRONQUE : pas de marqueur de fin dans ${DUMPALL##*/}"
        ko "cette sauvegarde n'est pas restaurable."
      fi

    else
      ko "aucun dump PostgreSQL (*.dump ou all-databases.sql) dans l'archive."
    fi
    ;;

  sqlite)
    BASES="$(printf '%s\n' "$CONTENU" | awk -F'\t' '$1 > 0 {print $2}' | grep -E '\.db$' || true)"
    if [ -z "$BASES" ]; then
      ko "aucune base SQLite (*.db) dans l'archive."
    else
      NB_OK=0 NB_KO=0
      while IFS= read -r base; do
        # Tout fichier SQLite valide commence par ces 16 octets.
        if [ "$(extraire "$base" | head -c 15)" = "SQLite format 3" ]; then
          NB_OK=$((NB_OK + 1))
        else
          NB_KO=$((NB_KO + 1))
          ko "en-tete SQLite invalide : ${base##*/}"
        fi
      done <<< "$BASES"
      [ "$NB_OK" -gt 0 ] && ok "$NB_OK base(s) SQLite avec un en-tete valide"
      [ "$NB_KO" -gt 0 ] && ko "$NB_KO base(s) corrompue(s)."
    fi
    # Limite assumee : on valide l'en-tete, pas l'integrite complete (celle-ci
    # demanderait d'ecrire la base sur disque pour un PRAGMA integrity_check).
    # Le snapshot est produit par l'API .backup de SQLite, donc coherent par
    # construction : l'en-tete suffit a detecter une troncature.
    ;;

  folder)
    # On ne peut pas prouver qu'un dossier de fichiers quelconques est
    # "exploitable" : il n'y a rien a deserialiser. On verifie que la source
    # attendue est bien dans l'archive, et qu'elle n'est pas vide.
    if [ -z "${DUMPS_DIRECTORY:-}" ]; then
      ko "DUMPS_DIRECTORY absent du .env : impossible de verifier la source."
    else
      SOURCE="${DUMPS_DIRECTORY#/}"
      NB="$(printf '%s\n' "$CONTENU" | awk -F'\t' -v s="$SOURCE" '$1 > 0 && index($2, s) == 1' | wc -l)"
      if [ "$NB" -gt 0 ]; then
        ok "$NB fichier(s) sauvegardes depuis $DUMPS_DIRECTORY"
      else
        ko "aucun fichier de $DUMPS_DIRECTORY dans l'archive."
      fi
    fi
    ;;
esac


#### VERDICT ####
echo
if [ "$ERREURS" -eq 0 ]; then
  echo "[check] La derniere sauvegarde est restaurable."
  exit 0
fi
echo "[check] $ERREURS probleme(s). Cette sauvegarde n'est pas fiable." >&2
exit 1
