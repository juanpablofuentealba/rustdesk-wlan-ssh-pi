#!/usr/bin/env bash
#
# lib/sr-t-distro.sh — Módulo de abstracción de distro.
#
# Parte del issue #27 (partir el monolito setup-remote-target.sh en módulos).
# Este archivo NO se ejecuta solo: está pensado para `source`:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/sr-t-distro.sh"
#
# Requiere que el script que lo carga ya tenga definidos:
#   - run() y err()  (de lib/sr-t-ui.sh / helpers del script principal)
#   - TARGET_USER    (usado por as_user())
#
# No lleva `set -e` ni nada más: el script que lo carga ya fija sus opciones.
# El comportamiento es idéntico al bloque que antes vivía inline en
# setup-remote-target.sh.

# ---------- abstracción de distro ----------
# Detecta la familia de la distribución: arch | debian | fedora | unknown
DISTRO_FAMILY=""
detect_distro() {
  local id="" idlike=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    id="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}")"
    # shellcheck disable=SC1091
    idlike="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID_LIKE:-}")"
  fi
  case " $id $idlike " in
    *" arch "*|*" archlinux "*) printf 'arch' ;;
    *" debian "*|*" ubuntu "*)  printf 'debian' ;;
    *" fedora "*|*" rhel "*)    printf 'fedora' ;;
    *)
      # Fallback por gestor de paquetes
      if command -v pacman >/dev/null 2>&1; then printf 'arch'
      elif command -v apt-get >/dev/null 2>&1; then printf 'debian'
      elif command -v dnf >/dev/null 2>&1; then printf 'fedora'
      else printf 'unknown'; fi ;;
  esac
}

# Devuelve una línea de comandos para instalar paquetes, adaptada a la
# familia detectada. Se usa en los mensajes de arreglo (warn/info) para que
# el operador copie/pegue el comando correcto SIN saber de qué distro es el
# cliente (puede no ser Arch). NO ejecuta nada.
# Uso:  $(pkg_install_hint pipewire pipewire-pulse)
#   arch   -> sudo pacman -S pipewire pipewire-pulse
#   debian -> sudo apt-get install -y pipewire pipewire-pulse
#   fedora -> sudo dnf install -y pipewire pipewire-pulse
#   otro   -> instala con tu gestor: pipewire pipewire-pulse
pkg_install_hint() {
  case "$DISTRO_FAMILY" in
    arch)   printf 'sudo pacman -S %s'   "$*" ;;
    debian) printf 'sudo apt-get install -y %s' "$*" ;;
    fedora) printf 'sudo dnf install -y %s'     "$*" ;;
    *)      printf 'instala con tu gestor de paquetes: %s' "$*" ;;
  esac
}

# Instala paquetes con el gestor nativo de la familia detectada.
# Uso: pkg_install zstd openssh
pkg_install() {
  case "$DISTRO_FAMILY" in
    arch)   run pacman -S --needed --noconfirm "$@" ;;
    debian) run apt-get update && run apt-get install -y "$@" ;;
    fedora) run dnf install -y "$@" ;;
    *)      err "Familia de distro no soportada; instala manualmente: $*"; return 1 ;;
  esac
}

# ¿Está instalado un paquete? (consulta nativa por familia)
pkg_installed() {
  case "$DISTRO_FAMILY" in
    arch)   pacman -Q "$1" >/dev/null 2>&1 ;;
    debian) dpkg -s "$1" >/dev/null 2>&1 ;;
    fedora) rpm -q "$1" >/dev/null 2>&1 ;;
    *)      command -v "$1" >/dev/null 2>&1 ;;
  esac
}

# Familia de la distro (ya con las funciones definidas)
# Override manual: DISTRO_FAMILY_OVERRIDE=debian ./setup-remote-target.sh ...
DISTRO_FAMILY="${DISTRO_FAMILY_OVERRIDE:-$(detect_distro)}"

# Ejecuta un comando como el usuario objetivo (para consultar su entorno).
as_user() {
  if [[ "$TARGET_USER" == "root" || $EUID -eq 0 && "$TARGET_USER" == "$(id -un)" ]]; then
    bash -lc "$*" 2>/dev/null || true
  elif [[ $EUID -eq 0 ]]; then
    sudo -u "$TARGET_USER" -H bash -lc "$*" 2>/dev/null || true
  else
    bash -lc "$*" 2>/dev/null || true
  fi
}

# IP local primaria: ip route es portable; hostname -I no existe en algunos hostname
# IP local primaria. NO debe fallar ni matar el script cuando no hay red
# configurada (contenedor sin ruta por defecto, equipo recién instalado sin
# conectar): antes eso hacía salir el script con 127 en el paso final.
local_ip() {
  local out=""
  if command -v ip >/dev/null 2>&1; then
    out="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')" || true
  fi
  if [[ -z "$out" ]] && command -v hostname >/dev/null 2>&1; then
    out="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
  fi
  printf '%s' "${out:-sin-red}"
  return 0
}

# Nombre del host portable: el binario 'hostname' NO existe en imágenes base
# mínimas (p. ej. fedora:44 trae solo /proc/sys/kernel/hostname).
local_hostname() {
  if command -v hostname >/dev/null 2>&1; then hostname
  elif [[ -r /proc/sys/kernel/hostname ]]; then cat /proc/sys/kernel/hostname
  else uname -n; fi
}

# Tipo de sesión de la sesión GRÁFICA (wayland|x11|tty|...).
# No sirve tomar la última de `loginctl list-sessions`: en Fedora 44 con KDE
# las sesiones de tipo 'manager'/'background' (ej. 'c15') salen al final y su
# Type es 'unspecified', ocultando el Wayland real de la sesión con seat.
# Estrategia: preferir sesiones con seat asignado; si no hay, usar la Type
# concreta más informativa que se encuentre.
graphical_session_type() {
  local id t
  # 1) sesiones con seat (las gráficas de verdad), de la más antigua a la nueva
  while read -r id; do
    [[ -z "$id" ]] && continue
    t="$(loginctl show-session "$id" -p Type --value 2>/dev/null || true)"
    case "$t" in wayland|x11) printf '%s' "$t"; return 0 ;; esac
  done < <(loginctl list-sessions --no-legend 2>/dev/null \
             | awk '$4 != "-" {print $1}')
  # 2) respaldo: cualquier sesión con Type concreto
  while read -r id; do
    [[ -z "$id" ]] && continue
    t="$(loginctl show-session "$id" -p Type --value 2>/dev/null || true)"
    case "$t" in wayland|x11|tty) printf '%s' "$t"; return 0 ;; esac
  done < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}')
  printf ''
}

# Versión del gestor de paquetes de la familia detectada (informativo).
# En Fedora 41+ 'dnf' es un symlink a dnf5, y `dnf --version` responde
# "dnf5 ...". Se fuerza LC_ALL=C para que la salida no salga traducida.
pkg_manager_version() {
  case "$DISTRO_FAMILY" in
    # pacman imprime primero una línea en blanco (banner ASCII): filtramos
    arch)   LC_ALL=C pacman --version 2>/dev/null | grep -m1 -o 'Pacman v[0-9.]*' ;;
    debian) LC_ALL=C apt-get --version 2>/dev/null | head -1 ;; # "apt 2.x"
    fedora)
      # dnf5 imprime "dnf5 version X" (C) o "dnf5 versión X" (es); normalizamos
      LC_ALL=C dnf --version 2>/dev/null | head -1 | sed 's/^dnf5 version /dnf5 /'
      ;;
    *) printf '' ;;
  esac
}
