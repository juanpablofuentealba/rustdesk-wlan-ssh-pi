#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# update.sh — mantiene al día el equipo administrado (RustDesk + Tailscale)
#
# Problema que resuelve: RustDesk y Tailscale publican versiones nuevas a
# menudo (varias cierran brechas de seguridad). Si el equipo del cliente se
# queda en una versión vieja, el soporte remoto se vuelve frágil. Este script
# actualiza el sistema y, en Debian/Ubuntu, reinstala el .deb OFICIAL más
# reciente de RustDesk (el de la web, no el de un repo de terceros).
#
# Ejecutar EN EL EQUIPO ADMINISTRADO (no en la máquina del operador):
#
#   sudo ./update.sh                 # actualiza todo (auto-detecta la distro)
#   ./update.sh --check              # ¿hay actualizaciones? (no aplica nada)
#   ./update.sh --no-rustdesk        # solo el sistema (pacman/apt/dnf)
#   ./update.sh --no-sistema         # solo RustDesk (sin tocar el SO)
#   ./update.sh --dry-run            # muestra qué haría, sin aplicar nada
#   ./update.sh --yes                # sin confirmaciones (cron/desatendido)
#
#   -h, --help                       # esta ayuda
#
# Distros soportadas: Arch/CachyOS (pacman), Debian/Ubuntu (apt),
# Fedora/RHEL (dnf). Tailscale se actualiza por el gestor de paquetes si el
# repositorio oficial está configurado (lo hace setup-remote-target.sh).
#
# ¿AUTOMATIZARLO? Ponlo en un cron semanal del usuario root:
#   0 4 * * 1  /root/kit-rustdesk/update.sh --yes >/var/log/kit-update.log 2>&1
#
# Repositorio (documentación completa, hallazgos y versiones nuevas):
#   https://github.com/juanpablofuentealba/rustdesk-wlan-ssh-pi
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

RUSTDESK_API="https://api.github.com/repos/rustdesk/rustdesk/releases/latest"
RUSTDESK_PAGE="https://rustdesk.com/download"

CHECK_ONLY=0
DO_SISTEMA=1
DO_RUSTDESK=1
DO_TAILSCALE=1
DRY_RUN=0
ASSUME_YES=0

info() { printf '\033[1;34m●\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m▲\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m✘\033[0m %s\n' "$*" >&2; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

usage(){ sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)        CHECK_ONLY=1; shift ;;
    --no-sistema)   DO_SISTEMA=0; shift ;;
    --no-rustdesk)  DO_RUSTDESK=0; shift ;;
    --no-tailscale) DO_TAILSCALE=0; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --yes|-y)       ASSUME_YES=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "opción desconocida: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Detección de distro / gestor de paquetes
# ---------------------------------------------------------------------------
PM=""
DISTRO="desconocida"
detect_pm(){
  if   command -v pacman >/dev/null 2>&1; then PM="pacman"; DISTRO="Arch/CachyOS"
  elif command -v apt-get >/dev/null 2>&1; then PM="apt"; DISTRO="Debian/Ubuntu"
  elif command -v dnf    >/dev/null 2>&1; then PM="dnf"; DISTRO="Fedora/RHEL"
  else PM=""; DISTRO="desconocida"
  fi
}
detect_pm

# ¿Tenemos root? Sin él no se puede actualizar. --check sí funciona sin root.
if [[ $CHECK_ONLY -eq 0 && $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then
  err "se necesita root para actualizar. Usa: sudo $0"
  err "(o ejecuta $0 --check para solo consultar)"
  exit 1
fi

confirmar(){
  [[ $ASSUME_YES -eq 1 ]] && return 0
  [[ ! -t 0 ]] && return 0   # sin TTY (cron): asumir sí
  local r
  printf '\033[1;33m?\033[0m %s [s/N] ' "$1"
  read -r r
  [[ "$r" =~ ^[sSyY]$ ]]
}

# ---------------------------------------------------------------------------
# 1. Sistema operativo (pacman / apt / dnf)
# ---------------------------------------------------------------------------
update_sistema(){
  hdr "Sistema ($DISTRO · $PM)"
  case "$PM" in
    pacman)
      if [[ $CHECK_ONLY -eq 1 ]]; then
        info "consultando actualizaciones…"
        # checkupdates viene de pacman-contrib; si no está, usamos -Sy -Qu
        if command -v checkupdates >/dev/null 2>&1; then
          checkupdates || ok "sistema al día"
        else
          pacman -Sy --noconfirm >/dev/null 2>&1
          local cups; cups="$(pacman -Qu 2>/dev/null | wc -l | tr -d ' ')"
          [[ "$cups" -eq 0 ]] && ok "sistema al día" || warn "$cups paquete(s) por actualizar"
          pacman -Qu 2>/dev/null | sed 's/^/  /' | head -30
        fi
      elif [[ $DRY_RUN -eq 1 ]]; then
        warn "(dry-run) haría: pacman -Syu --noconfirm"
      else
        info "pacman -Syu (sin pedir confirmación)"
        pacman -Syu --noconfirm && ok "sistema actualizado" || { err "pacman falló"; return 1; }
      fi
      ;;
    apt)
      if [[ $CHECK_ONLY -eq 1 ]]; then
        info "apt-get update + list --upgradable"
        apt-get update -qq >/dev/null 2>&1 || warn "apt-get update falló (¿red?)"
        local cups; cups="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || true)"
        [[ "$cups" -eq 0 ]] && ok "sistema al día" || warn "$cups paquete(s) por actualizar"
        apt list --upgradable 2>/dev/null | tail -n +2 | sed 's/^/  /' | head -30
      elif [[ $DRY_RUN -eq 1 ]]; then
        warn "(dry-run) haría: apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y"
      else
        info "apt-get update && upgrade"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq && apt-get upgrade -y \
          && ok "sistema actualizado" || { err "apt falló"; return 1; }
      fi
      ;;
    dnf)
      if [[ $CHECK_ONLY -eq 1 ]]; then
        info "dnf check-update"
        dnf -q check-update && ok "sistema al día" || warn "hay actualizaciones (ver arriba)"
      elif [[ $DRY_RUN -eq 1 ]]; then
        warn "(dry-run) haría: dnf -y upgrade"
      else
        info "dnf upgrade"
        dnf -y upgrade && ok "sistema actualizado" || { err "dnf falló"; return 1; }
      fi
      ;;
    *)
      warn "no reconozco el gestor de paquetes; actualiza a mano"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 2. RustDesk — en Debian/Ubuntu se reinstala el .deb OFICIAL más reciente.
#    En Arch/Fedora lo cubre el paso anterior (pacman/dnf); se verifica versión.
# ---------------------------------------------------------------------------
version_rustdesk(){
  if   command -v dpkg   >/dev/null 2>&1; then dpkg -s rustdesk 2>/dev/null | awk -F': ' '/^Version:/{print $2}'
  elif command -v rpm    >/dev/null 2>&1; then rpm -q --qf '%{VERSION}' rustdesk 2>/dev/null
  elif command -v pacman >/dev/null 2>&1; then pacman -Q rustdesk-unattended-wayland 2>/dev/null | awk '{print $2}' \
    || pacman -Q rustdesk 2>/dev/null | awk '{print $2}'
  fi
}

update_rustdesk(){
  hdr "RustDesk"
  local v; v="$(version_rustdesk)"
  info "versión instalada: ${v:-no detectada}"

  if [[ $CHECK_ONLY -eq 1 ]]; then
    info "última versión y .deb oficial: $RUSTDESK_PAGE"
    warn "para ver si hay una más nueva, compara a mano en la web"
    return 0
  fi

  if [[ "$PM" == "apt" ]]; then
    # El .deb de GitHub Releases es la fuente OFICIAL de RustDesk en
    # Debian/Ubuntu. Se consulta la ÚLTIMA release por API (no se fija una
    # versión en el script, que quedaría obsoleta). Si la API no responde
    # (rate limit, sin red), se cae a la página de descargas.
    local tmp url="" tag="" meta arch
    tmp="$(mktemp -d)"
    # La arquitectura del .deb debe coincidir con la del equipo (los releases
    # traen x86_64 y aarch64). dpkg --print-architecture: amd64/arm64.
    arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
    info "consultando la última release de RustDesk (arch: $arch)…"
    meta="$(curl -fsSL --retry 2 --connect-timeout 15 \
      -H 'Accept: application/vnd.github+json' "$RUSTDESK_API" 2>/dev/null || true)"
    if [[ -n "$meta" ]]; then
      tag="$(printf '%s' "$meta" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
      # Busca el .deb de ESTA arquitectura; si no, el x86_64; si no, cualquiera.
      url="$(printf '%s' "$meta" | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*'"$arch"'\.deb"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
      [[ -z "$url" ]] && url="$(printf '%s' "$meta" | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*x86_64\.deb"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
      [[ -z "$url" ]] && url="$(printf '%s' "$meta" | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*\.deb"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
    fi
    [[ -n "$tag" ]] && info "última versión publicada: $tag"
    if [[ -z "$url" ]]; then
      warn "no pude resolver el .deb por API (¿rate limit o sin red?)"
      warn "bájalo a mano desde: $RUSTDESK_PAGE"
      return 1
    fi
    info "asset: $url"
    if [[ $DRY_RUN -eq 1 ]]; then
      warn "(dry-run) haría: curl -fL $url -o $tmp/rustdesk.deb && apt-get install -y $tmp/rustdesk.deb"
      rm -rf "$tmp"; return 0
    fi
    if curl -fL --retry 3 --connect-timeout 15 "$url" -o "$tmp/rustdesk.deb"; then
      info "instalando .deb (apt resuelve dependencias)…"
      if DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmp/rustdesk.deb"; then
        ok "RustDesk actualizado a $(version_rustdesk)"
        # El servicio puede quedar caído tras reinstalar: se reactiva.
        systemctl restart rustdesk 2>/dev/null && ok "servicio rustdesk reiniciado"
      else
        err "apt no pudo instalar el .deb"
      fi
    else
      warn "no se pudo descargar el .deb (¿red?). Bájalo a mano: $RUSTDESK_PAGE"
    fi
    rm -rf "$tmp"
  else
    # Arch/Fedora: se actualiza con el gestor del sistema (paso 1) o el repo
    # oficial de RustDesk si está configurado.
    info "en $DISTRO RustDesk se actualiza con $PM (ya hecho en el paso anterior)"
    local after; after="$(version_rustdesk)"
    [[ -n "$after" ]] && ok "versión tras actualizar: $after"
    warn "si quieres la última, revisa: $RUSTDESK_PAGE"
  fi
}

# ---------------------------------------------------------------------------
# 3. Tailscale — sigue el stack del repo oficial (si está configurado).
# ---------------------------------------------------------------------------
update_tailscale(){
  hdr "Tailscale"
  if ! command -v tailscale >/dev/null 2>&1; then
    warn "Tailscale no está instalado en este equipo; nada que hacer"
    return 0
  fi
  local v; v="$(tailscale version 2>/dev/null | head -1)"
  info "versión instalada: ${v:-?}"
  local st; st="$(tailscale status 2>/dev/null | head -1 || true)"
  [[ -n "$st" ]] && info "estado: $st"

  if [[ $CHECK_ONLY -eq 1 ]]; then
    info "se actualiza con $PM si el repo oficial de Tailscale está configurado"
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    warn "(dry-run) haría: $PM actualizar tailscale (ya cubierto por el paso 1)"
    return 0
  fi
  # El paso 1 ya actualizó el paquete; solo confirmamos que sigue activo.
  systemctl is-active tailscaled >/dev/null 2>&1 && ok "tailscaled activo" \
    || warn "tailscaled no está activo (¿lo uniste? usa unir-tailscale.sh)"
}

# ---------------------------------------------------------------------------
# 4. Reinicio del servicio RustDesk + verificación (H-27 y consistencia)
# ---------------------------------------------------------------------------
verificar(){
  hdr "Verificación final"
  local s
  for s in rustdesk sshd tailscaled; do
    local act; act="$(systemctl is-active "$s" 2>/dev/null || echo inactivo)"
    case "$act" in
      active) ok "$s: $act" ;;
      *)      warn "$s: $act" ;;
    esac
  done
  local v; v="$(version_rustdesk)"
  [[ -n "$v" ]] && ok "RustDesk $v"
}

# ---------------------------------------------------------------------------
# Flujo
# ---------------------------------------------------------------------------
hdr "update.sh — $DISTRO"
[[ $CHECK_ONLY -eq 1 ]] && info "MODO CONSULTA (no se aplica nada)"
[[ $DRY_RUN  -eq 1 ]] && info "MODO SIMULACRO (no se aplica nada)"

if [[ $CHECK_ONLY -eq 0 && $DRY_RUN -eq 0 && $ASSUME_YES -eq 0 ]]; then
  confirmar "¿Actualizar el sistema ahora?" || { warn "cancelado"; exit 0; }
fi

[[ $DO_SISTEMA   -eq 1 ]] && update_sistema
[[ $DO_RUSTDESK  -eq 1 ]] && update_rustdesk
[[ $DO_TAILSCALE -eq 1 ]] && update_tailscale
[[ $CHECK_ONLY   -eq 0 && $DRY_RUN -eq 0 ]] && verificar

echo
ok "listo. Si algo quedó raro, revisa el log y el repo del kit."
