# Table des matieres de la stack Keycloak. La logique vit dans scripts/.
# Memes cibles que les stacks Ghost, Etherpad, Docuseal et Nextcloud.
.PHONY: help up down restart logs ps init backup check list mount umount update update-check

DC := docker compose

# Point de montage pour 'make mount', hors de la stack : sinon la prochaine
# sauvegarde parcourrait le depot monte.
MOUNTPOINT ?= /tmp/borg-mount-keycloak

help:
	@echo "Stack Keycloak — cibles disponibles :"
	@echo ""
	@echo "  make up        demarre la stack"
	@echo "  make down      arrete la stack"
	@echo "  make restart   redemarre la stack"
	@echo "  make logs      suit les logs de Keycloak"
	@echo "  make ps        etat des conteneurs"
	@echo ""
	@echo "  make init      configure la sauvegarde borg (cle SSH, depot BWH, cron)"
	@echo "  make backup    lance une sauvegarde maintenant"
	@echo "  make check     verifie que la derniere sauvegarde est restaurable"
	@echo "  make list      liste les archives du depot"
	@echo "  make mount     monte les archives en lecture seule (ARCHIVE=<nom> pour une seule)"
	@echo "  make umount    demonte"
	@echo ""
	@echo "  make update-check  que ferait make update ? (rien ne change)"
	@echo "  make update        sauvegarde + copie de la base, mise a jour, controles,"
	@echo "                     retour arriere automatique si KO"
	@echo "                     (CONFIRME=1 apres avoir change KEYCLOAK_VERSION dans le .env)"

up:
	$(DC) up -d

down:
	$(DC) down

restart:
	$(DC) restart

logs:
	$(DC) logs -f keycloak

ps:
	$(DC) ps

init:
	@bash scripts/init_backup.sh

backup:
	@bash scripts/backup_keycloak.sh

check:
	@bash scripts/check_backup.sh

# Meme acces au depot que les scripts : la cle SSH dediee, et elle seule.
BORG_ENV = set -a; . scripts/.env; set +a; \
	   cle="$(CURDIR)/scripts/.ssh/$$BORG_PREFIX""_ed25519"; \
	   test ! -f "$$cle" || export BORG_RSH="/usr/bin/ssh -oStrictHostKeyChecking=accept-new -oIdentitiesOnly=yes -i $$cle";

list:
	@$(BORG_ENV) borg list --glob-archives "$$BORG_PREFIX-*" "$$BORG_REPO"

mount:
	@$(BORG_ENV) mkdir -p "$(MOUNTPOINT)"; \
	 cible="$$BORG_REPO"; test -z "$(ARCHIVE)" || cible="$$BORG_REPO::$(ARCHIVE)"; \
	 borg mount -o ro "$$cible" "$(MOUNTPOINT)" && echo "[mount] $(MOUNTPOINT) — demonter : make umount"

umount:
	@borg umount "$(MOUNTPOINT)" && echo "[umount] $(MOUNTPOINT) demonte"

update:
	@env CONFIRME=$(CONFIRME) bash scripts/update_stack.sh

update-check:
	@bash scripts/update_stack.sh --verifier
