#!/usr/bin/env bash
#
# Notas de shellcheck que son INTENCIONALES (no arreglar):
#   SC1091  `. /etc/os-release` es la detección de distro; shellcheck no sigue
#           archivos del sistema y `-x` no aplica a un script genérico.
#   SC2012  `ls -t` para elegir el log MÁS RECIENTE de RustDesk: el orden por
#           fecha es justamente el propósito; `find` no ordena por mtime de
#           forma portable sin más código.
#   SC2015  `A && ok || warn`: `ok()` siempre devuelve 0, así que la rama `warn`
#           solo corre si A falla. Es el patrón buscado, no un if-then-else.
# Ninguna de estas es un warning: shellcheck las clasifica como `note`.
#
# setup-remote-target.sh — Prepara un PC Linux para ser administrado de forma
# remota con RustDesk (unattended en Wayland) + SSH.
#
# Distros soportadas (con ramas separadas por familia):
#   · Arch / CachyOS / Manjaro   → pacman (+ AUR si hace falta helper)
#   · Debian / Ubuntu / Mint     → apt
#   · Fedora / RHEL / Rocky      → dnf
# En las TRES familias RustDesk se instala desde el .deb oficial con capturador
# DRM (ver H-14/H-24): trae libdrmtap.so, que es lo que habilita el acceso
# desatendido en Wayland. El paquete nativo (.rpm/deb estándar, AUR) NO lo trae.
#
# Ejecutar EN EL PC OBJETIVO. La parte de SSH/firewall necesita root:
#
#   # 0) Diagnóstico (no cambia nada, NO necesita root)
#   ./setup-remote-target.sh --check
#
#   # 1) TODO de una vez: RustDesk unattended + SSH + firewall + clave + Tailscale
#   sudo ./setup-remote-target.sh --all \
#     --key "$(cat operador.pub)" \
#     --authkey 'tskey-auth-XXXX'
#
#   # 2) O por partes:
#   sudo ./setup-remote-target.sh --rustdesk
#   sudo ./setup-remote-target.sh --ssh --key "ssh-ed25519 AAAA... operador@mipc"
#   sudo ./setup-remote-target.sh --tailscale --authkey 'tskey-auth-XXXX'
#
#   # 3) Simulacro (no aplica cambios)
#   sudo ./setup-remote-target.sh --all --dry-run
#
# RECORDÁ: aparte hay que fijar la contraseña permanente de RustDesk, sin la
# cual NO hay acceso desatendido:
#   SUDO_PASS='<clave-sudo>' ./rustdesk-password.sh install "$USER@localhost" 'tu-password'
#
# Runbook completo (desde el PC sin sistema operativo): INSTALAR.md
#
# Repositorio (hallazgos, versiones nuevas, documentación):
#   https://github.com/juanpablofuentealba/rustdesk-wlan-ssh-pi
#
# Importante: al usar sudo, el script detecta el usuario real vía SUDO_USER y
# opera sobre SU $HOME (authorized_keys, logs de RustDesk), no sobre /root.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# UI/estado: ver lib/sr-t-ui.sh (issue #27)
source "$SCRIPT_DIR/lib/sr-t-ui.sh"

# ---------- estado ----------
DO_RUSTDESK=0
DO_SSH=0
DO_TAILSCALE=0
DO_LAPTOP=0
DO_CHECK=0
SSH_PORT=22
KEY=""
TS_AUTHKEY=""
# Hostname en la tailnet (--tailnet-host); vacío = usar $(hostname).
# Se EXPORTA: la usan los módulos sourceados (lib/sr-t-tailscale.sh);
# el analizador no ve ese uso en este archivo (aviso SC2034).
export TS_HOSTNAME="${TARGET_HOSTNAME:-}"
DRY_RUN=0
# ASSUME_YES: la usa confirm() en lib/sr-t-core.sh; se EXPORTA para que el
# analizador no la marque como no usada en este archivo (aviso SC2034).
export ASSUME_YES=0

usage() {
  # Se salta el bloque de notas de shellcheck (líneas del encabezado) y se
  # imprime desde el título del script hasta la línea del repositorio.
  sed -n '/^# setup-remote-target.sh/,/^#   https:\/\/github.com/p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Opciones:
  --rustdesk            Instala/configura RustDesk con unattended en Wayland
  --ssh                 Instala y habilita sshd + abre el firewall
  --tailscale           Instala Tailscale y une el equipo (acceso fuera de LAN)
  --authkey "<key>"     Auth key de Tailscale (tskey-auth-...) para --tailscale
  --key "<pubkey>"      Clave pública del operador a autorizar
  --port <n>            Puerto SSH (por defecto 22)
  --laptop              Portátil: evita que suspenda (tapa/inactividad) -> H-29
  --install-tailscale   Instala Tailscale pero NO lo une (la key se pide despues)
  --check               Solo diagnóstico (no cambia nada; no requiere root)
  --all                 Equivale a --rustdesk --ssh --tailscale --laptop
  --dry-run             Muestra qué haría SIN aplicar cambios (seguro)
  --yes, -y             No preguntar confirmación antes de aplicar
  -h, --help            Muestra esta ayuda

Detección de distro:
  El script detecta la familia (arch|debian|fedora) vía /etc/os-release y usa
  el gestor nativo. El paquete de RustDesk se instala aparte por familia.

Ejemplos:
  ./setup-remote-target.sh --check
  sudo ./setup-remote-target.sh --all --dry-run      # simulacro
  sudo ./setup-remote-target.sh --all --key "ssh-ed25519 AAAA... operador@mipc"
EOF
}

# Guardamos los flags originales: los usa need_root() para dar un mensaje
# útil ("sudo $0 --all --key ...") aunque no reciba argumentos. Se EXPORTA
# porque need_root() vive en lib/sr-t-core.sh (el analizador no ve ese uso).
export ORIG_ARGS="$*"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rustdesk)  DO_RUSTDESK=1; shift ;;
    --ssh)       DO_SSH=1; shift ;;
    --tailscale) DO_TAILSCALE=1; shift ;;
    --laptop)    DO_LAPTOP=1; shift ;;
    --install-tailscale) DO_TAILSCALE=1; shift ;;
    --authkey)   TS_AUTHKEY="${2:-}"; shift 2 ;;
    # --authkey-env: la key viene en la variable de entorno KIT_AUTHKEY (no en
    # argv). Lo usa instalar-todo.sh para no exponerla en 'ps'.
    --authkey-env)
      TS_AUTHKEY="${KIT_AUTHKEY:-}"
      if [[ -z "$TS_AUTHKEY" ]]; then
        err "--authkey-env: falta la variable KIT_AUTHKEY en el entorno"
        exit 1
      fi
      shift ;;
    # --authkey-stdin: leer la key por STDIN (no queda en el historial).
    --authkey-stdin) IFS= read -rs TS_AUTHKEY || true; shift ;;
    # --tailnet-host: hostname con el que el equipo aparece en la tailnet.
    # Sin esto se usa $(hostname); con clientes conviene 'cliente-<nombre>'.
    --tailnet-host) TS_HOSTNAME="${2:-}"; shift 2 ;;
    --key)       KEY="${2:-}"; shift 2 ;;
    --port)      SSH_PORT="${2:-22}"; shift 2 ;;
    --check)     DO_CHECK=1; shift ;;
    --all)       DO_RUSTDESK=1; DO_SSH=1; DO_TAILSCALE=1; DO_LAPTOP=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --yes|-y)   ASSUME_YES=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) err "Opción desconocida: $1"; usage; exit 1 ;;
  esac
done

if [[ $DO_RUSTDESK -eq 0 && $DO_SSH -eq 0 && $DO_TAILSCALE -eq 0 && $DO_LAPTOP -eq 0 && $DO_CHECK -eq 0 ]]; then
  usage; exit 1
fi

# ---------- módulos ----------
# Abstracción de distro: ver lib/sr-t-distro.sh (issue #27)
source "$SCRIPT_DIR/lib/sr-t-distro.sh"

# Helpers base (run/confirm/need_root/firewall): ver lib/sr-t-core.sh (issue #27)
source "$SCRIPT_DIR/lib/sr-t-core.sh"

# Dependencias/AUR de RustDesk: ver lib/sr-t-deps.sh (issue #27)
source "$SCRIPT_DIR/lib/sr-t-deps.sh"

# RustDesk (instalación por familia + setup): ver lib/sr-t-rustdesk.sh (issue #27)
source "$SCRIPT_DIR/lib/sr-t-rustdesk.sh"

# SSH (sshd + firewall): ver lib/sr-t-ssh.sh (issue #27)
source "$SCRIPT_DIR/lib/sr-t-ssh.sh"

# Tailscale (y laptop): ver lib/sr-t-tailscale.sh (issue #27)
source "$SCRIPT_DIR/lib/sr-t-tailscale.sh"

# Diagnóstico (--check): ver lib/sr-t-check.sh (issue #27)
source "$SCRIPT_DIR/lib/sr-t-check.sh"

# ---------- resolver usuario objetivo y su HOME ----------
# resolve_target_user() vive en lib/sr-t-core.sh (issue #27).
TARGET_USER="$(resolve_target_user)"
if [[ "$TARGET_USER" == "root" ]]; then
  TARGET_HOME="/root"
else
  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  [[ -n "$TARGET_HOME" ]] || TARGET_HOME="/home/$TARGET_USER"
fi

# ---------- main ----------
if [[ $DO_CHECK -eq 1 ]]; then
  run_check
  exit 0
fi

# Resumen previo + confirmación (a menos que --yes o --dry-run)
hdr "Acciones a realizar"
[[ $DO_RUSTDESK -eq 1 ]] && info "· RustDesk unattended (DRM + uinput)"
[[ $DO_SSH -eq 1 ]] && info "· sshd habilitado + firewall :${SSH_PORT}"
[[ $DO_TAILSCALE -eq 1 ]] && info "· Tailscale (acceso fuera de la LAN)"
[[ $DO_LAPTOP -eq 1 ]] && info "· Portátil: impedir suspensión por tapa/inactividad (H-29)"
if [[ -n "$KEY" ]]; then info "· Autorizar la clave del operador"; else
  [[ $DO_SSH -eq 1 ]] && warn "· Sin --key: el operador no podrá entrar sin contraseña"; fi
info "· Usuario objetivo: ${TARGET_USER} (HOME: ${TARGET_HOME})"
if [[ $DRY_RUN -eq 1 ]]; then
  warn "MODO SIMULACRO (--dry-run): no se aplicará ningún cambio"
fi
confirm

# En simulacro no se necesita root: solo mostramos qué haría.
if [[ $DRY_RUN -eq 0 ]]; then need_root; fi
if [[ $DO_RUSTDESK -eq 1 ]]; then setup_rustdesk; fi
if [[ $DO_SSH -eq 1 ]]; then setup_ssh; fi
if [[ $DO_TAILSCALE -eq 1 ]]; then setup_tailscale; fi
if [[ $DO_LAPTOP -eq 1 ]]; then setup_laptop; fi

if [[ $DRY_RUN -eq 1 ]]; then
  hdr "Fin del simulacro"
  ok "Nada fue modificado. Ejecuta sin --dry-run para aplicar."
  exit 0
fi

hdr "Hecho"
ok "Verifica con: ./setup-remote-target.sh --check"
