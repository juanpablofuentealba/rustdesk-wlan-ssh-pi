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

RUSTDESK_PAGE="https://rustdesk.com/download"
# Versión y sha256 del asset con capturador DRM (libdrmtap). Es el MISMO que
# usa setup-remote-target.sh (H-14/H-24): el .deb estándar NO trae DRM y
# rompería el acceso desatendido en Wayland. Si sale una versión nueva,
# actualizá RD_VERSION y RD_SHA256 aquí y en setup-remote-target.sh.
RD_VERSION="1.5.0"
RD_SHA256="9eed5e9f4b47af8ed41585c399cb2c0d2870e801c99645330dea1063ad844e09"

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
  # Sin TTY (cron, make update-now, redirección a log) NO se puede preguntar.
  # Antes se asumía "sí" en silencio, lo que volvía decorativo el flag --yes y
  # hacía que 'actualizar en cron' fuera implícito. Ahora, sin TTY y sin --yes,
  # se ABORTA con aviso: actualizar es una acción destructiva; que sea explícito.
  if [[ ! -t 0 ]]; then
    err "sin TTY y sin --yes: no puedo pedir confirmación; aborto"
    err "si es intencional (cron), usá:  $0 --yes"
    return 1
  fi
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
        # checkupdates viene de pacman-contrib; si no está, usamos -Qu
        if command -v checkupdates >/dev/null 2>&1; then
          if checkupdates; then :; else ok "sistema al día"; fi
        else
          pacman -Sy --noconfirm >/dev/null 2>&1 || true
          local cups; cups="$(pacman -Qu 2>/dev/null | wc -l | tr -d ' ')"
          [[ "$cups" -eq 0 ]] && ok "sistema al día" || warn "$cups paquete(s) por actualizar"
          pacman -Qu 2>/dev/null | sed 's/^/  /' | head -30 || true
        fi
        return 0
      elif [[ $DRY_RUN -eq 1 ]]; then
        warn "(dry-run) haría: pacman -Syu --noconfirm"
        return 0
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
        apt list --upgradable 2>/dev/null | tail -n +2 | sed 's/^/  /' | head -30 || true
        return 0
      elif [[ $DRY_RUN -eq 1 ]]; then
        warn "(dry-run) haría: apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y"
        return 0
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
        if dnf -q check-update; then ok "sistema al día"; else warn "hay actualizaciones (ver arriba)"; fi
        return 0
      elif [[ $DRY_RUN -eq 1 ]]; then
        warn "(dry-run) haría: dnf -y upgrade"
        return 0
      else
        info "dnf upgrade"
        dnf -y upgrade && ok "sistema actualizado" || { err "dnf falló"; return 1; }
      fi
      ;;
    *)
      # Sin gestor reconocido: en --check/dry-run NO es un fallo del script
      # (solo informa); al aplicar de verdad, sí.
      warn "no reconozco el gestor de paquetes; actualiza a mano"
      [[ $CHECK_ONLY -eq 1 || $DRY_RUN -eq 1 ]] && return 0
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

# ¿El RustDesk instalado es el que trae libdrmtap (captura DRM en Wayland)?
# En Debian/Ubuntu no hay un nombre de paquete distinto: se comprueba que la
# instalación incluya libdrmtap.so*. Sin eso, el desatendido en Wayland casca
# al portal XDG (H-14).
#
# OJO con las rutas reales: el .deb de unattended-wayland instala
#   /usr/lib/rustdesk/libdrmtap.so.0.5.8   (archivo)
#   /usr/lib/rustdesk/libdrmtap.so.0       (symlink)
# NO existe un 'libdrmtap.so' a secas, así que se busca con glob.
tiene_drm(){
  local f
  for f in /usr/lib/rustdesk/libdrmtap.so*; do
    [[ -e "$f" ]] && return 0
  done
  # Fallback: dpkg sabe qué instaló el paquete (cubre rutas no estándar).
  dpkg -L rustdesk 2>/dev/null | grep -q 'libdrmtap' && return 0
  return 1
}

# ¿Están satisfechas las dependencias dinámicas de libdrmtap.so?
#
# En Arch/Fedora el .deb se inyecta a mano (ar+tar), así que pacman/dnf NO
# sabe que existe. libdrmtap enlaza contra libdrm.so.2, libEGL/libGLESv2, etc.
# Si una actualización (Arch es rolling) sube esas libs con ABI incompatible o
# las quita, el capturador DRM deja de cargar EN SILENCIO y el desatendido en
# Wayland vuelve al portal. Este chequeo lo hace visible al actualizar.
# Devuelve 0 si todo resuelve; 1 si falta algo (y avisa).
check_drmtap_deps(){
  local f lib=""
  for f in /usr/lib/rustdesk/libdrmtap.so.*; do
    [[ -f "$f" ]] && { lib="$f"; break; }
  done
  if [[ -z "$lib" ]]; then
    warn "no encuentro libdrmtap.so.* para comprobar dependencias"
    return 1
  fi
  if ! command -v ldd >/dev/null 2>&1; then
    info "sin 'ldd': no puedo verificar dependencias de libdrmtap"
    return 0
  fi
  local out missing
  out="$(ldd "$lib" 2>&1 || true)"
  missing="$(printf '%s\n' "$out" | grep 'not found' || true)"
  if [[ -n "$missing" ]]; then
    warn "libdrmtap tiene dependencias SIN resolver (el DRM podría no cargar):"
    printf '%s\n' "$missing" | sed 's/^/    /'
    case "$PM" in
      pacman) warn "  revisá: pacman -Qo /usr/lib/libdrm.so.2  e instalá lo que falte" ;;
      dnf)    warn "  revisá: rpm -qf /usr/lib64/libdrm.so.2  e instalá lo que falte" ;;
      apt)    warn "  revisá: apt-get install -f  y dpkg -S libdrm.so.2" ;;
    esac
    return 1
  fi
  ok "dependencias de libdrmtap resueltas (ldd)"
  return 0
}

update_rustdesk(){
  hdr "RustDesk"
  local v; v="$(version_rustdesk)"
  info "versión instalada: ${v:-no detectada}"

  if [[ $CHECK_ONLY -eq 1 ]]; then
    if tiene_drm; then ok "capturador DRM (libdrmtap) presente";
    else warn "NO tiene libdrmtap: el desatendido en Wayland puede fallar (H-14)"; fi
    info "última versión y .deb oficial: $RUSTDESK_PAGE"
    return 0
  fi

  if [[ "$PM" == "apt" ]]; then
    # SIEMPRE el asset 'unattended-wayland' (con DRM), nunca el estándar.
    # Se usa RD_VERSION (fijada) en vez de "auto-descubrir la última por API":
    # así el nombre y el sha256 son conocidos y verificables. Si sale una
    # versión nueva, el aviso al fallar el sha256 lo dice.
    local url="https://github.com/rustdesk/rustdesk/releases/download/${RD_VERSION}/rustdesk-unattended-wayland-${RD_VERSION}-x86_64.deb"
    local tmp; tmp="$(mktemp -d)"

    info "asset oficial con DRM: unattended-wayland ${RD_VERSION}"
    if [[ $DRY_RUN -eq 1 ]]; then
      warn "(dry-run) curl -fL $url -o $tmp/rustdesk.deb"
      warn "(dry-run) verificaría sha256 $RD_SHA256"
      warn "(dry-run) apt-get install -y $tmp/rustdesk.deb && systemctl restart rustdesk"
      rm -rf "$tmp"; return 0
    fi

    # Requisitos para descargar y verificar
    command -v sha256sum >/dev/null 2>&1 || { err "falta sha256sum (coreutils)"; rm -rf "$tmp"; return 1; }

    info "descargando el .deb oficial…"
    if ! curl -fL --retry 3 --connect-timeout 15 --max-time 300 "$url" -o "$tmp/rustdesk.deb"; then
      err "no se pudo descargar el .deb (¿red?). Bájalo a mano: $RUSTDESK_PAGE"
      rm -rf "$tmp"; return 1
    fi

    # Verificación de integridad (igual que setup-remote-target.sh). Instalar
    # como root un binario bajado de internet SIN comprobar el hash no es
    # aceptable.
    local actual; actual="$(sha256sum "$tmp/rustdesk.deb" | awk '{print $1}')"
    if [[ "$actual" != "$RD_SHA256" ]]; then
      err "sha256 NO coincide: el .deb no es el esperado"
      err "  esperado: $RD_SHA256"
      err "  obtenido: $actual"
      warn "puede haber salido una versión nueva; si es así, actualizá"
      warn "RD_VERSION y RD_SHA256 en update.sh y setup-remote-target.sh"
      rm -rf "$tmp"; return 1
    fi
    ok "sha256 verificado"

    # Antes de instalar, registramos qué había (para detectar regresión de DRM).
    local drm_antes=0
    if tiene_drm; then drm_antes=1; fi

    info "instalando .deb (apt resuelve dependencias)…"
    if DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmp/rustdesk.deb"; then
      ok "RustDesk actualizado a $(version_rustdesk)"
      # Comprobación CRÍTICA: que el paquete instalado traiga el capturador DRM.
      if tiene_drm; then
        ok "capturador DRM (libdrmtap) presente"
      else
        err "tras instalar NO aparece libdrmtap: el Wayland desatendido fallará (H-14)"
        err "revisá el paquete o reinstalá con setup-remote-target.sh"
        rm -rf "$tmp"; return 1
      fi
      # El servicio puede quedar caído tras reinstalar: se reactiva.
      if systemctl restart rustdesk 2>/dev/null; then
        ok "servicio rustdesk reiniciado"
      else
        warn "no se pudo reiniciar rustdesk (revisá: systemctl status rustdesk)"
      fi
    else
      err "apt no pudo instalar el .deb"
      rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"
    [[ $drm_antes -eq 1 ]] && info "(el equipo ya tenía DRM; se conserva)"
  else
    # Arch/Fedora: se actualiza con el gestor del sistema (paso 1) o el repo
    # oficial de RustDesk si está configurado.
    info "en $DISTRO RustDesk se actualiza con $PM (ya hecho en el paso anterior)"
    local after; after="$(version_rustdesk)"
    [[ -n "$after" ]] && ok "versión tras actualizar: $after"
    if tiene_drm; then ok "capturador DRM presente";
    else warn "NO se detecta libdrmtap (H-14); revisá el paquete de RustDesk"; fi
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
  # Solo se exige lo que este equipo realmente usa: si sshd/tailscaled no están
  # instalados, no es un fallo (aviso informativo, no alarma).
  for s in rustdesk sshd tailscaled; do
    if ! systemctl list-unit-files "$s.service" >/dev/null 2>&1 \
       || [[ -z "$(systemctl list-unit-files "$s.service" 2>/dev/null)" ]]; then
      info "$s: no instalado (no aplica)"
      continue
    fi
    local act; act="$(systemctl is-active "$s" 2>/dev/null || echo inactivo)"
    case "$act" in
      active) ok "$s: $act" ;;
      *)      warn "$s: $act" ;;
    esac
  done
  local v; v="$(version_rustdesk)"
  [[ -n "$v" ]] && ok "RustDesk $v"
  # Tras actualizar el sistema, es cuando más probable es que una librería
  # haya cambiado de ABI y roto libdrmtap sin avisar (sobre todo en Arch).
  if tiene_drm; then check_drmtap_deps || warn "  el capturador DRM podría fallar"; fi
}

# ---------------------------------------------------------------------------
# Flujo
# ---------------------------------------------------------------------------
hdr "update.sh — $DISTRO"
[[ $CHECK_ONLY -eq 1 ]] && info "MODO CONSULTA (no se aplica nada)"
[[ $DRY_RUN  -eq 1 ]] && info "MODO SIMULACRO (no se aplica nada)"

if [[ $CHECK_ONLY -eq 0 && $DRY_RUN -eq 0 && $ASSUME_YES -eq 0 ]]; then
  confirmar "¿Actualizar el sistema ahora?" || { warn "cancelado (no se aplicó nada)"; exit 1; }
fi

# El flujo NO debe seguir si un paso falla: si apt/pacman/dnf falla, no tiene
# sentido (ni es honesto) terminar con "listo" en verde. H-22 es explícito:
# un fallo silencioso cuesta una visita al cliente.
RC=0
if [[ $DO_SISTEMA -eq 1 ]]; then update_sistema || RC=1; fi
if [[ $DO_RUSTDESK -eq 1 ]]; then update_rustdesk || RC=1; fi
if [[ $DO_TAILSCALE -eq 1 ]]; then update_tailscale || RC=1; fi

if [[ $RC -ne 0 ]]; then
  echo
  err "hubo fallos: revisá la salida de arriba (NO se completó todo)"
  exit 1
fi

if [[ $CHECK_ONLY -eq 0 && $DRY_RUN -eq 0 ]]; then verificar; fi

echo
ok "listo. Si algo quedó raro, revisa el log y el repo del kit."
