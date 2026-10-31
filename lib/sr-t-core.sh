#!/usr/bin/env bash
#
# lib/sr-t-core.sh — Módulo de helpers base del setup.
#
# Parte del issue #27 (partir el monolito setup-remote-target.sh en módulos).
# Este archivo NO se ejecuta solo: está pensado para `source`:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/sr-t-core.sh"
#
# No lleva `set -e` ni nada más: el script que lo carga ya fija sus opciones.
# Requiere helpers/estado del script principal y de los módulos ya sourceados:
#   - err/ok/warn/info  (de lib/sr-t-ui.sh)
#   - pkg_installed     (de lib/sr-t-distro.sh)
#   - DRY_RUN, ASSUME_YES, EUID, ORIG_ARGS, SSH_PORT, B/N/BD (estado/UI)
# El comportamiento es idéntico al bloque que antes vivía inline en
# setup-remote-target.sh.

# ---------- resolver usuario objetivo y su HOME ----------
# Con sudo, $USER/$HOME apuntan a root; el usuario real está en SUDO_USER.
resolve_target_user() {
  local u
  u="${SUDO_USER:-}"
  if [[ -z "$u" || "$u" == "root" ]]; then
    u="$(logname 2>/dev/null || true)"
  fi
  if [[ -z "$u" || "$u" == "root" ]]; then
    # sesión gráfica activa (Wayland/X11)
    u="$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' | grep -v '^$' | head -1 || true)"
  fi
  if [[ -z "$u" ]]; then
    u="${USER:-root}"
  fi
  printf '%s' "$u"
}

# Ejecuta un comando real, o solo lo muestra si DRY_RUN=1.
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '%s[sudo]%s %s\n' "$B" "$N" "$*"
  else
    "$@"
  fi
}

# Pide confirmación (salvo --yes o --dry-run).
confirm() {
  [[ $DRY_RUN -eq 1 || $ASSUME_YES -eq 1 ]] && return 0
  local r
  printf '%s¿Aplicar estos cambios?%s [y/N] ' "$BD" "$N"
  read -r r || r=""
  case "$r" in [yYsS]) return 0 ;; *) err "Cancelado por el usuario"; exit 1 ;; esac
}

need_root() {
  if [[ $EUID -ne 0 ]]; then
    # Muestra los flags reales con los que se invocó (no "$*": aquí no llegan
    # argumentos, y shellcheck lo señalaba como SC2120).
    err "Este paso requiere root. Ejecuta con: sudo $0 ${ORIG_ARGS:-<flags>}"
    exit 1
  fi
}

# Devuelve el firewall ACTIVO, o 'ufw-inactive'/'firewalld-inactive' si el
# gestor está instalado pero apagado (caso típico de Linux Mint: ufw sin activar).
#
# IMPORTANTE: no basta con 'systemctl is-active ufw' — en Linux Mint el servicio
# ufw.service puede estar ACTIVE mientras el firewall está DESACTIVADO
# (/etc/ufw/ufw.conf → ENABLED=no). Hay que mirar el estado REAL del filtrado.
detect_firewall() {
  # --- ufw ---
  if command -v ufw >/dev/null 2>&1; then
    local st
    if [[ $EUID -eq 0 ]]; then
      st="$(ufw status 2>/dev/null | head -1)"
    else
      st=""
    fi
    # Si 'ufw status' no dijo nada concluyente (p. ej. salida vacía, o sin
    # root), caer a /etc/ufw/ufw.conf — que es la fuente de verdad de ENABLED.
    if [[ "$st" != *active* ]]; then
      if [[ -r /etc/ufw/ufw.conf ]]; then
        grep -qi '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null && st="active" || st="inactive"
      fi
    fi
    # OJO con el orden: "inactive" CONTIENE "active", así que hay que
    # comprobar *inactive* ANTES que *active*.
    if [[ "$st" == *inactive* ]]; then printf 'ufw-inactive'; return; fi
    if [[ "$st" == *active* ]]; then printf 'ufw'; return; fi
    # No se pudo determinar: usar el servicio como pista, pero preferir inactivo
    if systemctl is-active --quiet ufw 2>/dev/null; then printf 'ufw'; return; fi
    printf 'ufw-inactive'; return
  fi
  # --- firewalld ---
  if command -v firewall-cmd >/dev/null 2>&1; then
    if [[ $EUID -eq 0 ]]; then
      systemctl is-active --quiet firewalld 2>/dev/null && { printf 'firewalld'; return; }
    else
      firewall-cmd --state 2>/dev/null | grep -q running && { printf 'firewalld'; return; }
    fi
    printf 'firewalld-inactive'; return
  fi
  # --- nftables / iptables (solo si el servicio está activo) ---
  local fw
  for fw in nftables iptables; do
    if systemctl is-active --quiet "$fw" 2>/dev/null; then printf '%s' "$fw"; return; fi
  done
  # --- no se pudo determinar ---
  # Sin systemctl/firewall-cmd/ufw (imágenes base mínimas como fedora:44) NO se
  # puede afirmar "sin firewall": el filtrado puede existir a nivel nftables o
  # de la plataforma. Distinguir 'none' (verificado) de 'sin-herramientas'.
  if pkg_installed firewalld 2>/dev/null || pkg_installed ufw 2>/dev/null \
     || ! command -v systemctl >/dev/null 2>&1; then
    printf 'sin-herramientas'; return
  fi
  printf 'none'
}

# Verifica ufw con reintentos: recién activado, ufw tarda un instante en reportar.
ufw_verify() {
  local msg="$1" active=0 rule=0
  for _ in 1 2 3; do
    if ufw status 2>/dev/null | grep -qE "Status: active"; then
      active=1
      if ufw status 2>/dev/null | grep -qE "${SSH_PORT}(/tcp)?[[:space:]]+ALLOW"; then
        rule=1; break
      fi
    fi
    sleep 1
  done
  if [[ $rule -eq 1 ]]; then ok "$msg"
  elif [[ $active -eq 1 ]]; then ok "ufw activo (regla ${SSH_PORT}/tcp aplicada)"
  else warn "no pude confirmar el estado de ufw; revisa: sudo ufw status"
  fi
}
