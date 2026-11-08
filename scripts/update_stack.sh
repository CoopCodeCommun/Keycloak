#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Mise a jour prudente d'une stack docker compose, avec retour arriere.
# Lance par :  make update        (make update-check : verifications seules)
#
# Script GENERIQUE, identique dans chaque depot (Traefik, librespeed,
# Keycloak...). Ce qui est propre a la stack vit dans scripts/stack.conf.
#
#   1. etat avant : image de chaque conteneur, et code HTTP de chaque site
#      (hotes lus dans les labels Traefik des conteneurs)
#   2. pull : quels services ont une nouvelle image ? Aucun -> fin.
#   3. GARDE-FOUS, avant de toucher a quoi que ce soit :
#      - retour en arriere de version : refus
#      - version majeure differente : refus sauf CONFIRME=1
#      - version mineure differente, pour les services de CONFIRMER_MINEURE :
#        refus sauf CONFIRME=1
#      - systeme de base change (Debian 12 -> 13...) pour les services de
#        FIGER_OS (bases de donnees : le tri du texte depend de la glibc) :
#        refus, figer le tag (ex. postgres:16-bookworm)
#      - garde_fous() de stack.conf (version des donnees...)
#      Sur refus, les anciennes images reprennent leur tag : rien ne change,
#      meme au prochain `docker compose up`.
#   4. avant_maj() de stack.conf (ex. sauvegarde + verification)
#   5. copie locale des dossiers SNAPSHOT_DIRS (services SNAPSHOT_SERVICES
#      arretes le temps de la copie), dans .snapshots/ (3 dernieres gardees)
#   6. up -d
#   7. CONTROLES : conteneurs demarres et stables, chaque site qui repondait
#      avant repond encore (< 500), controle_apres() de stack.conf
#   8. si un controle echoue : RETOUR ARRIERE automatique (anciennes images,
#      dossiers restaures depuis la copie), puis nouveau controle
#
#   ./update_stack.sh              # mise a jour
#   ./update_stack.sh --verifier   # etapes 1 a 3 seulement, rien ne change
#   CONFIRME=1 ./update_stack.sh   # accepte un changement de version voulu
#####

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
STACK_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$STACK_DIR/docker-compose.yml"
CONFIRME="${CONFIRME:-0}"
VERIFIER_SEUL=0; [ "${1:-}" = "--verifier" ] && VERIFIER_SEUL=1

# Valeurs par defaut, a surcharger dans stack.conf
STACK_NOM="$(basename "$STACK_DIR")"
SITES_PORTEE=stack        # "tous" : tous les sites du serveur (stack Traefik)
SITES_EXTRA=""            # URL completes en plus des hotes trouves dans les labels
SNAPSHOT_DIRS=""          # dossiers (relatifs a la stack) copies avant la mise a jour
SNAPSHOT_SERVICES=""      # services arretes le temps de la copie
CONFIRMER_MINEURE=""      # services dont une version mineure demande CONFIRME=1
FIGER_OS=""               # services dont le systeme de base ne doit pas changer
ATTENTE="${ATTENTE:-180}" # secondes max pour que tout reponde apres up -d
# Petite image pour copier/restaurer des dossiers root sans sudo.
OUTIL_IMAGE="alpine:3.22"
avant_maj()          { :; }
garde_fous()         { :; }    # $@ : services changes ; return 1 = refus
controle_apres()     { :; }    # return 1 = retour arriere
version_specifique() { return 1; }   # $1 service, $2 image -> echo version
# shellcheck disable=SC1091
[ -f "$SCRIPT_DIR/stack.conf" ] && . "$SCRIPT_DIR/stack.conf"

compose() { docker compose -f "$COMPOSE_FILE" "$@"; }
log()     { echo "[$STACK_NOM] $*"; }
etape()   { echo; echo "[$STACK_NOM] ===== $* ====="; }
dans()    { case " $2 " in *" $1 "*) return 0;; *) return 1;; esac; }

[ -f "$COMPOSE_FILE" ] || { log "compose introuvable : $COMPOSE_FILE" >&2; exit 1; }
compose config -q
command -v jq >/dev/null || { log "jq introuvable (apt install jq)" >&2; exit 1; }

SERVICES="$(compose config --services)"
ref_image()   { compose config --format json | jq -r --arg s "$1" '.services[$s].image'; }
id_conteneur(){ compose ps -aq "$1" 2>/dev/null | head -n1; }
id_image()    { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null || true; }

# Version lisible d'une image : stack.conf, puis label OCI, puis env.
version_de() {
  local svc="$1" img="$2" v
  v="$(version_specifique "$svc" "$img" 2>/dev/null)" && [ -n "$v" ] && { echo "$v"; return; }
  v="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$img" 2>/dev/null || true)"
  [ -n "$v" ] && [ "$v" != "<no value>" ] && { echo "$v"; return; }
  v="$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$img" 2>/dev/null \
       | sed -n 's/^\(PG_VERSION\|MYSQL_VERSION\|VERSION\)=//p' | head -n1)"
  echo "${v:-?}"
}
# "v3.6.23" -> "3 6" ; "16.15-1.pgdg13+2" -> "16 15"
maj_min() { printf '%s' "$1" | sed 's/^v//' | awk -F'[.-]' '{print $1+0, $2+0}'; }
# Systeme de base : "debian-12", "alpine-3"
os_de() {
  docker run --rm --network none --entrypoint cat "$1" /etc/os-release 2>/dev/null \
    | awk -F= '/^ID=/{gsub(/"/,"",$2);id=$2} /^VERSION_ID=/{gsub(/"/,"",$2);split($2,a,".");v=a[1]} END{print id"-"v}'
}

# Hotes des routeurs Traefik (labels) : de cette stack, ou de tout le serveur.
hotes() {
  local ids
  if [ "$SITES_PORTEE" = tous ]; then ids="$(docker ps -q)"; else ids="$(compose ps -q)"; fi
  [ -n "$ids" ] || return 0
  # shellcheck disable=SC2086
  docker inspect -f '{{range $k, $v := .Config.Labels}}{{$k}}={{$v}}{{"\n"}}{{end}}' $ids \
    | grep -E '^traefik\.http\.routers\.[^=]+\.rule=' | grep -oE 'Host\(`[^`]+`\)' \
    | sed 's/^Host(`//; s/`)$//' | sort -u
}
urls() { hotes | sed 's#^#https://#; s#$#/#'; for u in $SITES_EXTRA; do echo "$u"; done; }
code_http() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$1" 2>/dev/null || true; }
repond() { local c="$1"; [ -n "$c" ] && [ "$c" != 000 ] && [ "$c" -lt 500 ]; }
# PIEGE (vecu) : pendant qu'un conteneur demarre, Traefik n'a plus de route et
# repond 404 (< 500) : "repond" ne suffit pas. On exige la meme famille de
# code qu'avant la mise a jour (200 -> 2xx, 302 -> 3xx).
comme_avant() { [ -n "$2" ] && [ "${1:0:1}" = "${2:0:1}" ]; }


# Derniere configuration qui a fonctionne (compose + .env), pour revenir en
# arriere quand une version a ete changee dans le .env : a ce moment-la, le
# .env contient deja la NOUVELLE version, ce n'est pas lui qu'il faut garder.
CONF_OK="$STACK_DIR/.snapshots/config-ok"
sauver_conf_ok() {
  mkdir -p "$CONF_OK"; chmod 700 "$STACK_DIR/.snapshots" "$CONF_OK"
  cp -p "$COMPOSE_FILE" "$CONF_OK/compose.yml"
  [ -f "$STACK_DIR/.env" ] && cp -p "$STACK_DIR/.env" "$CONF_OK/env"
  return 0
}


#### 1. ETAT AVANT ####
etape "1. etat avant"
declare -A ANCIEN_ID ANCIEN_REF REF CODE_AVANT
for s in $SERVICES; do
  REF[$s]="$(ref_image "$s")"
  c="$(id_conteneur "$s")"
  ANCIEN_ID[$s]="$( [ -n "$c" ] && docker inspect -f '{{.Image}}' "$c" || true)"
  ANCIEN_REF[$s]="$( [ -n "$c" ] && docker inspect -f '{{.Config.Image}}' "$c" || true)"
  if [ -n "${ANCIEN_ID[$s]}" ]; then
    log "$s : ${REF[$s]} ($(version_de "$s" "${ANCIEN_ID[$s]}"))"
  else
    log "$s : ${REF[$s]} (pas de conteneur)"
  fi
done
URLS="$(urls)"
# Les conteneurs tournent sur les tags du compose : c'est une config qui marche.
TAG_CHANGE=0
for s in $SERVICES; do
  [ -z "${ANCIEN_REF[$s]}" ] || [ "${ANCIEN_REF[$s]}" = "${REF[$s]}" ] || TAG_CHANGE=1
done
[ "$TAG_CHANGE" = 1 ] || [ "$VERIFIER_SEUL" = 1 ] || sauver_conf_ok
for u in $URLS; do
  CODE_AVANT[$u]="$(code_http "$u")"
  log "site $u -> ${CODE_AVANT[$u]}"
done


#### 2. NOUVELLES IMAGES ####
etape "2. pull"
compose pull -q
[ -z "$SNAPSHOT_DIRS" ] || docker image inspect "$OUTIL_IMAGE" >/dev/null 2>&1 || docker pull -q "$OUTIL_IMAGE" >/dev/null
CHANGES=""
for s in $SERVICES; do
  nouveau="$(id_image "${REF[$s]}")"
  if [ -n "${ANCIEN_ID[$s]}" ] && [ "$nouveau" != "${ANCIEN_ID[$s]}" ]; then
    CHANGES="$CHANGES $s"
  fi
done
CHANGES="${CHANGES# }"
if [ -z "$CHANGES" ]; then
  log "toutes les images sont a jour : rien a faire."
  exit 0
fi

# Remet les anciennes images sous leur tag : un refus ne laisse rien en plan.
# Seulement si le tag est le meme qu'avant (nouvelle image sous le meme tag).
# Si le tag a change (version modifiee dans le .env), l'ancien tag pointe
# toujours sur l'ancienne image : c'est le compose/.env qu'on restaure.
remettre_tags() {
  for s in $CHANGES; do
    [ "${ANCIEN_REF[$s]}" = "${REF[$s]}" ] && docker tag "${ANCIEN_ID[$s]}" "${REF[$s]}"
  done
  return 0
}


#### 3. GARDE-FOUS ####
etape "3. garde-fous"
REFUS=0
for s in $CHANGES; do
  va="$(version_de "$s" "${ANCIEN_ID[$s]}")"; vn="$(version_de "$s" "${REF[$s]}")"
  log "$s : $va -> $vn"
  read -r ma mia <<<"$(maj_min "$va")"; read -r mn min <<<"$(maj_min "$vn")"
  if [ "$va" != "?" ] && [ "$vn" != "?" ]; then
    if [ "$(printf '%s\n%s\n' "$va" "$vn" | sort -V | head -n1)" = "$vn" ] && [ "$va" != "$vn" ]; then
      log "  REFUS : retour en arriere de version." >&2; REFUS=1
    elif [ "$mn" != "$ma" ] && [ "$CONFIRME" != 1 ]; then
      log "  REFUS : version majeure differente. Lire les notes de version, puis CONFIRME=1." >&2; REFUS=1
    elif dans "$s" "$CONFIRMER_MINEURE" && [ "$min" != "$mia" ] && [ "$CONFIRME" != 1 ]; then
      log "  REFUS : version mineure differente. Lire les notes de version, puis CONFIRME=1." >&2; REFUS=1
    fi
  fi
  if dans "$s" "$FIGER_OS"; then
    oa="$(os_de "${ANCIEN_ID[$s]}")"; on="$(os_de "${REF[$s]}")"
    if [ "$oa" != "$on" ]; then
      log "  REFUS : systeme de base $oa -> $on. Figer le tag (ex. ...-bookworm)." >&2; REFUS=1
    fi
  fi
done
garde_fous $CHANGES || REFUS=1
if [ "$REFUS" = 1 ]; then
  remettre_tags
  log "ABANDON : rien n'a ete modifie." >&2
  exit 1
fi
if [ "$VERIFIER_SEUL" = 1 ]; then
  remettre_tags
  log "verifications OK : 'make update' mettrait a jour : $CHANGES"
  exit 0
fi


#### 4. AVANT LA MISE A JOUR ####
etape "4. preparation"
avant_maj $CHANGES || { remettre_tags; log "ABANDON : preparation en echec, rien n'a ete modifie." >&2; exit 1; }


#### 5. COPIE LOCALE ####
SNAP=""
copie_utile=0
for s in $CHANGES; do dans "$s" "$SNAPSHOT_SERVICES" && copie_utile=1; done
if [ -n "$SNAPSHOT_DIRS" ] && [ "$copie_utile" = 1 ]; then
  etape "5. copie locale : $SNAPSHOT_DIRS"
  SNAP="$STACK_DIR/.snapshots/$(date +%Y-%m-%d-%H%M%S)"
  mkdir -p "$SNAP"; chmod 700 "$STACK_DIR/.snapshots"
  # shellcheck disable=SC2086
  compose stop $SNAPSHOT_SERVICES
  # Dossiers souvent en root : copie par un conteneur (pas besoin de sudo).
  # Echec : on relance les MEMES conteneurs (anciennes images), rien d'autre.
  # shellcheck disable=SC2086
  if ! docker run --rm --network none -v "$STACK_DIR:/s:ro" -v "$SNAP:/o" "$OUTIL_IMAGE" \
       tar -czf /o/copie.tgz -C /s $SNAPSHOT_DIRS; then
    remettre_tags; compose start $SNAPSHOT_SERVICES
    log "ABANDON : copie locale impossible, services relances tels quels." >&2; exit 1
  fi
  log "copie : $SNAP/copie.tgz ($(du -h --apparent-size "$SNAP/copie.tgz" | cut -f1))"
  # shellcheck disable=SC2012
  ls -1dt "$STACK_DIR"/.snapshots/20*/ | tail -n +4 | while read -r vieux; do
    docker run --rm --network none -v "$STACK_DIR/.snapshots:/x" "$OUTIL_IMAGE" rm -rf "/x/$(basename "$vieux")"
  done
fi


#### 6. MISE A JOUR ####
etape "6. up -d ($CHANGES)"
DEBUT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
compose up -d


#### 7. CONTROLES ####
controles() {
  local fin=$(( $(date +%s) + ATTENTE )) ok s c etat redem u code
  while :; do
    ok=1
    for s in $SERVICES; do
      c="$(id_conteneur "$s")"
      [ -n "$c" ] || { ok=0; continue; }
      etat="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$c")"
      case "$etat" in "running -"|"running healthy") ;; *) ok=0 ;; esac
    done
    if [ "$ok" = 1 ]; then
      for u in $URLS; do
        repond "${CODE_AVANT[$u]}" || continue   # deja en panne avant : pas notre affaire
        code="$(code_http "$u")"
        comme_avant "${CODE_AVANT[$u]}" "$code" || { ok=0; DERNIER_ECHEC="$u -> $code (avant : ${CODE_AVANT[$u]})"; }
      done
    fi
    [ "$ok" = 1 ] && break
    [ "$(date +%s)" -ge "$fin" ] && { log "controle en echec : ${DERNIER_ECHEC:-conteneur non demarre}" >&2; compose ps >&2; return 1; }
    sleep 5
  done
  # Stable ? Un conteneur qui redemarre en boucle passe "running" par moments.
  sleep 15
  for s in $CHANGES; do
    redem="$(docker inspect -f '{{.RestartCount}} {{.State.Status}}' "$(id_conteneur "$s")")"
    [ "$redem" = "0 running" ] || { log "$s instable : $redem" >&2; return 1; }
  done
  controle_apres || return 1
}

retour_arriere() {
  etape "RETOUR ARRIERE"
  compose logs --since "${DEBUT}" --tail 30 >&2 || true
  remettre_tags
  # Tag change : retour a la derniere config qui a marche (versions comprises).
  # `cat >` : le .env garde ses droits. La config tentee est gardee a cote.
  if [ "$TAG_CHANGE" = 1 ]; then
    if [ -f "$CONF_OK/compose.yml" ]; then
      cp -p "$COMPOSE_FILE" "$CONF_OK/compose.yml.echec"
      [ -f "$STACK_DIR/.env" ] && cp -p "$STACK_DIR/.env" "$CONF_OK/env.echec"
      cat "$CONF_OK/compose.yml" > "$COMPOSE_FILE"
      [ -f "$CONF_OK/env" ] && cat "$CONF_OK/env" > "$STACK_DIR/.env"
      log "compose et .env remis a la derniere config qui marchait ; config tentee : $CONF_OK/*.echec" >&2
    else
      log "ATTENTION : pas de config-ok enregistree, compose et .env laisses tels quels." >&2
    fi
  fi
  if [ -n "$SNAP" ]; then
    # shellcheck disable=SC2086
    compose stop $SNAPSHOT_SERVICES
    # shellcheck disable=SC2086
    docker run --rm --network none -v "$STACK_DIR:/s" -v "$SNAP:/o:ro" "$OUTIL_IMAGE" \
      sh -c "cd /s && rm -rf $SNAPSHOT_DIRS && tar -xzf /o/copie.tgz"
    log "dossiers restaures depuis $SNAP"
  fi
  compose up -d
  if controles; then
    log "revenu aux anciennes versions : tout repond. Voir les logs ci-dessus." >&2
  else
    log "ATTENTION : meme apres retour arriere, un controle echoue. Intervenir a la main." >&2
  fi
  exit 1
}

etape "7. controles (max ${ATTENTE}s)"
controles || retour_arriere

etape "termine"
sauver_conf_ok
for s in $CHANGES; do log "$s : $(version_de "$s" "${ANCIEN_ID[$s]}") -> $(version_de "$s" "${REF[$s]}")"; done
for u in $URLS; do log "site $u -> $(code_http "$u")"; done
log "Anciennes images gardees pour un retour a la main (docker image prune pour les supprimer)."
