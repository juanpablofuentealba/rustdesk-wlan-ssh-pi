#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# instalar-todo.sh — un solo comando para dejar un PC listo para admón remota
#
# Hace, en orden, todo lo que hay que hacer en el PC del cliente:
#   1. Diagnóstico previo (y se detiene si algo no cuadra)
#   2. RustDesk unattended + sshd + firewall + tu clave + Tailscale
#   3. Contraseña permanente de RustDesk (sin ella no hay desatendido)
#   4. Verificación final (tests + captura DRM + IP Tailscale)
#
# Ejecutar EN EL PC OBJETIVO, recién instalado el sistema:
#
#   sudo ./instalar-todo.sh \
#     --authkey 'tskey-auth-XXXX' \
#     --rdpass  'MiClaveRustDesk2026'
#
# La clave del operador se toma de ./operador.pub (viene en el kit) o de
# --key. Si no hay ninguna, se avisa (el operador no podría entrar por SSH).
#
# Opciones:
#   --authkey "tskey-auth-..."  Auth key de Tailscale (obligatoria)
#   --rdpass  "..."             Contraseña permanente de RustDesk (obligatoria)
#   --key "ssh-ed25519 ..."     Clave pública del operador (o usa operador.pub)
#   --sudopass "..."            Contraseña de sudo, si sudo la pide
#   --skip-tailscale            No unir a Tailscale (solo LAN)
#   --dry-run                   Muestra qué haría, sin aplicar nada
#   --yes, -y                   No preguntar (modo desatendido)
#   -h, --help                  Esta ayuda
#
# Repositorio (documentación completa, hallazgos y versiones nuevas):
#   https://github.com/juanpablofuentealba/rustdesk-wlan-ssh-pi
#
# Si algo falla, actualizá el kit desde el repo en vez de parchear a mano:
#   git clone https://github.com/juanpablofuentealba/rustdesk-wlan-ssh-pi
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

AUTHKEY=""
RDPASS=""
OPKEY=""
SUDOPASS=""
SKIP_TS=0
DRY_RUN=0
ASSUME_YES=0

info() { printf '\033[1;34m●\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m▲\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m✘\033[0m %s\n' "$*" >&2; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --authkey)        AUTHKEY="${2:-}"; shift 2 ;;
    --rdpass)         RDPASS="${2:-}"; shift 2 ;;
    --key)            OPKEY="${2:-}"; shift 2 ;;
    --sudopass)       SUDOPASS="${2:-}"; shift 2 ;;
    --skip-tailscale) SKIP_TS=1; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --yes|-y)         ASSUME_YES=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) err "opción desconocida: $1"; usage; exit 2 ;;
  esac
done

# ---------- validaciones previas ----------
hdr "Comprobaciones previas"

# Primero validamos los ARGUMENTOS (así el mensaje de error es el correcto,
# sin exigir sudo solo para descubrir que faltaba un flag).

# contraseña de RustDesk
if [[ -z "$RDPASS" ]]; then
  err "falta --rdpass (contraseña permanente de RustDesk)."
  err "  Sin ella el acceso desatendido NO funciona (pide aceptación cada vez)."
  err "  Ej:  sudo ./instalar-todo.sh --authkey 'tskey-auth-...' --rdpass 'MiClave2026'"
  exit 1
fi
if [[ ${#RDPASS} -lt 8 ]]; then
  warn "la contraseña tiene menos de 8 caracteres; considerá una más larga"
fi
ok "contraseña de RustDesk definida (${#RDPASS} caracteres)"

# auth key de Tailscale
if [[ $SKIP_TS -eq 0 ]]; then
  if [[ -z "$AUTHKEY" ]]; then
    err "falta --authkey (auth key de Tailscale)."
    err "  Generala en: https://console.tailscale.com/admin/settings/keys"
    err "  O usá --skip-tailscale para instalar solo para LAN."
    exit 1
  fi
  case "$AUTHKEY" in
    tskey-*) ok "auth key con formato válido (tskey-…)" ;;
    *) err "la auth key debe empezar con 'tskey-'. Recibido: ${AUTHKEY:0:8}…"; exit 1 ;;
  esac
else
  warn "--skip-tailscale: el equipo NO tendrá acceso fuera de la LAN"
fi

# root (el simulacro puede correr sin root)
if [[ $EUID -ne 0 && $DRY_RUN -eq 0 ]]; then
  err "ejecutá con sudo:  sudo ./instalar-todo.sh --authkey 'tskey-auth-...' --rdpass '...'"
  err "  (para solo simular:  ./instalar-todo.sh ... --dry-run  sin sudo)"
  exit 1
fi

# usuario objetivo (con sudo, el real está en SUDO_USER)
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
[[ "$TARGET_USER" == "root" ]] && TARGET_USER="$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd)"
ok "usuario objetivo: $TARGET_USER"

# scripts del kit
for s in setup-remote-target.sh rustdesk-password.sh .rd-setpass-root.sh tests.sh; do
  [[ -f "$SCRIPT_DIR/$s" ]] || { err "falta $s en el kit"; exit 1; }
done
ok "scripts del kit presentes"

# clave del operador
if [[ -z "$OPKEY" ]]; then
  if [[ -f "$SCRIPT_DIR/operador.pub" ]]; then
    OPKEY="$(cat "$SCRIPT_DIR/operador.pub")"
    ok "clave del operador tomada de operador.pub ($(awk '{print $3}' <<<"$OPKEY"))"
  else
    warn "NO hay clave del operador (ni --key ni ./operador.pub)."
    warn "  -> El equipo quedará SIN acceso SSH por clave."
    warn "  -> Si es una prueba, pasala asi:"
    warn "       --key \"\$(cat ~/.ssh/id_ed25519.pub)\""
  fi
else
  case "$OPKEY" in
    ssh-ed25519*|ssh-rsa*|ecdsa-sha2-*|sk-ssh-ed25519*) ok "clave del operador válida (--key)" ;;
    *) warn "--key no parece una clave pública SSH válida (¿falta el tipo al inicio?)" ;;
  esac
fi

# sudo sin contraseña disponible?
if [[ -z "$SUDOPASS" ]] && ! sudo -n true 2>/dev/null; then
  warn "sudo pide contraseña. Pasala con --sudopass '...'"
  warn "  (si no, rustdesk-password.sh fallará al escribir la config de root)"
fi

# ---------- resumen y confirmación ----------
hdr "Se va a hacer"
info "1. Diagnóstico del sistema"
info "2. RustDesk unattended + sshd + firewall + clave del operador"
[[ $SKIP_TS -eq 0 ]] && info "3. Tailscale: unir el equipo a la tailnet"
info "4. Contraseña permanente de RustDesk"
info "5. Verificación final"
echo
info "usuario objetivo : $TARGET_USER"
[[ $SKIP_TS -eq 0 ]] && info "tailscale        : sí (authkey ${AUTHKEY:0:12}…)"
info "clave operador   : $([[ -n "$OPKEY" ]] && echo sí || echo NO)"
info "contraseña RD    : ${#RDPASS} caracteres"

if [[ $DRY_RUN -eq 1 ]]; then
  echo
  warn "MODO SIMULACRO: no se aplicará ningún cambio"
elif [[ $ASSUME_YES -eq 0 ]]; then
  echo
  read -r -p "¿Aplicar? [y/N] " resp
  case "$resp" in
    y|Y|yes|YES|s|S) : ;;
    *) err "cancelado"; exit 1 ;;
  esac
fi

ARGS_ALL=(--all --yes)
[[ -n "$OPKEY" ]] && ARGS_ALL+=(--key "$OPKEY")
[[ $SKIP_TS -eq 0 ]] && ARGS_ALL+=(--authkey "$AUTHKEY")
[[ $DRY_RUN -eq 1 ]] && ARGS_ALL+=(--dry-run)

# ---------- 1. diagnóstico ----------
hdr "1/5 · Diagnóstico"
./setup-remote-target.sh --check 2>&1 | tail -n +1 | sed 's/^/  /' || true

if [[ $DRY_RUN -eq 0 ]]; then
  FAM="$(grep -E '^● Familia:' <(./setup-remote-target.sh --check 2>/dev/null) | awk '{print $3}')"
  info "familia detectada: ${FAM:-?}"
fi

# ---------- 2 y 3. kit completo ----------
hdr "2/5 · RustDesk unattended + SSH + firewall$([[ $SKIP_TS -eq 0 ]] && echo ' + Tailscale')"
if ! ./setup-remote-target.sh "${ARGS_ALL[@]}"; then
  err "setup-remote-target.sh falló. Revisá la salida de arriba."
  err "  Reintentá solo esa parte para ver el detalle:"
  err "    sudo ./setup-remote-target.sh ${ARGS_ALL[*]}"
  exit 1
fi

# ---------- 4. contraseña de RustDesk ----------
hdr "4/5 · Contraseña permanente de RustDesk"
if [[ $DRY_RUN -eq 1 ]]; then
  info "(dry-run) se fijaría la contraseña en $TARGET_USER y en root"
else
  SUDO_PASS="$SUDOPASS" ./rustdesk-password.sh install "${TARGET_USER}@localhost" "$RDPASS" || {
    err "no pude fijar la contraseña de RustDesk"
    err "  Si el fallo fue de sudo, reintentá con: --sudopass 'tu-clave-sudo'"
    exit 1
  }
fi

# ---------- 5. verificación ----------
hdr "5/5 · Verificación"

if [[ $DRY_RUN -eq 1 ]]; then
  info "(dry-run) se verificaría: sshd, rustdesk, captura DRM y IP Tailscale"
  echo
  ok "Simulacro terminado. Nada fue modificado."
  exit 0
fi

# relanzar rustdesk para que tome la config nueva
systemctl restart rustdesk >/dev/null 2>&1 || true
sleep 3

FAILED=0
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else err "$1"; FAILED=$((FAILED+1)); fi; }

chk "rustdesk.service activo"        'systemctl is-active --quiet rustdesk'
chk "sshd activo"                    'systemctl is-active --quiet sshd || systemctl is-active --quiet ssh'
chk "contraseña permanente escrita"  'grep -q "^password = .01" /root/.config/rustdesk/RustDesk.toml'
chk "uinput disponible"              'test -e /dev/uinput'

# captura DRM: buscar en las ubicaciones posibles (varía según el usuario de sesión)
DRM_LOG=""
for d in "$HOME" "/var/lib/plasmalogin" "/root" "/home/$TARGET_USER"; do
  l="$d/.local/share/logs/RustDesk/server/rustdesk_rCURRENT.log"
  [[ -f "$l" ]] && DRM_LOG="$l" && break
done
if [[ -n "$DRM_LOG" ]] && grep -q "drm: consumer cache warmed" "$DRM_LOG" 2>/dev/null; then
  ok "captura DRM activa (consumer cache warmed)"
elif [[ -n "$DRM_LOG" ]] && grep -q "portal handshake failed" "$DRM_LOG" 2>/dev/null; then
  err "la captura cayó al portal (falta el capturador DRM)"
  err "  Arch/CachyOS: paru -S rustdesk-unattended-wayland"
  err "  Fedora:       ./install-rustdesk-unattended-fedora.sh"
  FAILED=$((FAILED+1))
else
  warn "sin conexión entrante aún: la captura DRM se confirma al primer acceso"
fi

if [[ $SKIP_TS -eq 0 ]]; then
  TSIP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  if [[ -n "$TSIP" ]]; then
    ok "Tailscale: $TSIP"
  else
    err "Tailscale sin IP (revisá: sudo tailscale status)"
    FAILED=$((FAILED+1))
  fi
fi

# suite de pruebas del kit (contra localhost)
if ./tests.sh "${TARGET_USER}@localhost" >/tmp/kit-tests.log 2>&1; then
  ok "tests.sh del kit: $(grep -oE '[0-9]+ OK' /tmp/kit-tests.log | head -1)"
else
  warn "tests.sh reportó fallos; detalle en /tmp/kit-tests.log"
fi

# ---------- resumen ----------
hdr "Resultado"
RID="$(rustdesk --get-id 2>/dev/null || echo '?')"
echo
ok "ID de RustDesk de este equipo: $RID"
[[ $SKIP_TS -eq 0 && -n "${TSIP:-}" ]] && ok "IP Tailscale: $TSIP"
echo
info "Desde tu equipo operador probá:"
[[ $SKIP_TS -eq 0 && -n "${TSIP:-}" ]] && info "  ssh ${TARGET_USER}@${TSIP} 'hostname'"
info "  ./verify-offlan.sh ${TSIP:-<host>}"
info "  RustDesk → $RID  (contraseña: la que pasaste en --rdpass)"
echo

if [[ $FAILED -eq 0 ]]; then
  ok "Todo listo. El equipo queda administrable de forma remota."
  exit 0
else
  err "$FAILED comprobación(es) fallaron. Revisá arriba."
  exit 1
fi
