# Makefile — atajos para administrar un PC remoto con RustDesk + SSH + pi
#
# Configura el host por defecto:
#   make HOST=remoto check
#   make HOST=USUARIO@192.168.1.20 inventory
#
HOST      ?= remoto
KEYFILE   ?= $(HOME)/.ssh/id_ed25519
SSH       ?= ssh -o BatchMode=yes -o ConnectTimeout=10
.DEFAULT_GOAL := help

.PHONY: help test verify-docs key push-key check target-setup dry-run inventory inventory-md inventory-json \
        ssh ping rustdesk-log rustdesk-id reboot-services ports update

help: ## Muestra esta ayuda
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n",$$1,$$2}'
	@printf "\n  HOST actual: \033[1m%s\033[0m\n" "$(HOST)"

key: ## Genera una clave SSH ed25519 (sin passphrase) si no existe
	@test -f $(KEYFILE) || ssh-keygen -t ed25519 -f $(KEYFILE) -N "" -C "pi-agent@$$(hostname)"
	@echo "Clave pública ($(KEYFILE).pub):"
	@cat $(KEYFILE).pub

push-key: ## Copia la clave pública al host remoto (pide contraseña una vez)
	ssh-copy-id -i $(KEYFILE).pub $(HOST)

ping: ## Comprueba alcance del host
	@echo "→ ping $(HOST)"
	@ping -c 2 -W 2 $${HOST#*@} 2>/dev/null | tail -2 || echo "  (sin ping; puede estar filtrando ICMP)"

check: ## Verifica SSH + RustDesk + firewall en el host
	@echo "→ conectividad SSH a $(HOST)"
	@$(SSH) $(HOST) 'echo "  ✔ SSH OK: $$(hostname) — $$(uname -r)"' || { echo "  ✘ SSH falló"; exit 1; }
	@echo "→ sshd"
	@$(SSH) $(HOST) 'u=""; for x in sshd ssh; do systemctl list-unit-files "$$x.service" 2>/dev/null | grep -q "^$$x.service" && { u=$$x; break; }; done; u=$${u:-sshd}; printf "  unidad : %s\n" "$$u"; printf "  enabled: %s\n" "$$(systemctl is-enabled $$u 2>/dev/null || echo desconocido)"; printf "  active : %s\n" "$$(systemctl is-active $$u 2>/dev/null || echo inactivo)"'
	@echo "→ firewall"
	@$(SSH) $(HOST) 'if command -v ufw >/dev/null 2>&1; then \
	  if sudo -n true 2>/dev/null; then sudo -n ufw status 2>/dev/null | head -6 | sed "s/^/  /"; \
	  else \
	    st="$$(grep -is ^ENABLED /etc/ufw/ufw.conf 2>/dev/null || echo ENABLED=desconocido)"; \
	    printf "  %s (no se puede leer con sudo -n; usa: sudo ufw status)\n" "$$st"; \
	    printf "  hint: añade --key al setup o revisa el firewall en el host\n"; \
	  fi; \
	elif command -v firewall-cmd >/dev/null 2>&1; then \
	  firewall-cmd --state 2>/dev/null | sed "s/^/  firewalld: /" || echo "  firewalld: no consultable"; \
	else echo "  (sin ufw ni firewalld)"; fi'
	@echo "→ RustDesk"
	@$(SSH) $(HOST) 'if command -v dpkg >/dev/null 2>&1; then dpkg -s rustdesk 2>/dev/null | grep -E "^Version:" | sed "s/^/  pkg: rustdesk /"; \
	elif command -v rpm >/dev/null 2>&1; then rpm -q rustdesk 2>/dev/null | sed "s/^/  pkg: /"; \
	elif command -v pacman >/dev/null 2>&1; then pacman -Q rustdesk-unattended-wayland 2>/dev/null | sed "s/^/  pkg: /" || pacman -Q rustdesk 2>/dev/null | sed "s/^/  pkg: /"; fi; \
	true'
	@$(SSH) $(HOST) 'systemctl is-active rustdesk 2>/dev/null | sed "s/^/  servicio: /"'
	@$(SSH) $(HOST) 'grep -hiE "UInput|drm: consumer|ipc server" ~/.local/share/logs/RustDesk/server/rustdesk_rCURRENT.log 2>/dev/null | tail -3 | sed "s/^/  /" || echo "  (sin log)"'

test: ## Ejecuta las pruebas de humo (local; añade HOST=... para remoto)
	@./tests.sh $(HOST)

verify-docs: ## Valida comandos de Tailscale y URLs de la documentación
	@./verify-docs.sh

target-setup: ## Copia setup-remote-target.sh al host y muestra cómo ejecutarlo
	@echo "→ copiando setup a $(HOST)"
	@scp setup-remote-target.sh $(HOST):~/setup-remote-target.sh
	@$(SSH) $(HOST) 'chmod +x ~/setup-remote-target.sh'
	@echo "  ✔ copiado a ~/setup-remote-target.sh en $(HOST)"
	@echo ""
	@echo "  Ejecuta EN EL HOST (con su contraseña sudo):"
	@echo "    sudo ~/setup-remote-target.sh --all --key \"$$(cat $(KEYFILE).pub)\""
	@echo ""
	@echo "  O primero solo el diagnóstico (sin root):"
	@echo "    ~/setup-remote-target.sh --check"
	@echo ""
	@echo "  Simulacro (qué haría, sin aplicar cambios):"
	@echo "    ~/setup-remote-target.sh --all --dry-run --key \"$$(cat $(KEYFILE).pub)\""

dry-run: ## Simula setup-remote-target.sh en el host (sin aplicar cambios)
	@$(SSH) $(HOST) '~/setup-remote-target.sh --all --dry-run --key "$$(cat /dev/null)" 2>&1 || true'

inventory: ## Inventario de specs (texto)
	@./inventory.sh $(HOST)

inventory-md: ## Inventario de specs (Markdown)
	@./inventory.sh --markdown $(HOST)

inventory-json: ## Inventario de specs (JSON)
	@./inventory.sh --json $(HOST)

ssh: ## Abre una shell interactiva en el host
	@ssh $(HOST)

ports: ## Puertos escuchando en el host
	@$(SSH) $(HOST) 'ss -tlnp 2>/dev/null | grep LISTEN'

rustdesk-id: ## Muestra el ID de RustDesk del host
	@$(SSH) $(HOST) 'rustdesk --get-id 2>/dev/null | sed "s/^/  ID: /"' || echo "  (no se pudo)"

rustdesk-log: ## Últimas líneas del log del server RustDesk
	@$(SSH) $(HOST) 'tail -20 ~/.local/share/logs/RustDesk/server/rustdesk_rCURRENT.log 2>/dev/null'

reboot-services: ## Reinicia rustdesk y sshd en el host
	@$(SSH) $(HOST) 'sudo -n systemctl restart rustdesk sshd && echo "  reiniciados"' \
	  || echo "  ✘ necesita sudo sin contraseña en el host"

update: ## Actualiza el sistema del host (pacman)
	@$(SSH) $(HOST) 'sudo -n pacman -Syu --noconfirm' || echo "  ✘ necesita sudo en el host"
