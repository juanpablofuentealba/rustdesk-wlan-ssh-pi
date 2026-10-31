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
# OJO CON LA AUTH KEY EN EL HISTORIAL: si la pasás en la linea de comandos,
# queda en ~/.bash_history del equipo y es visible en 'ps'. Mejor por STDIN:
#
#   printf %s 'tskey-auth-XXXX' | sudo ./instalar-todo.sh --authkey-stdin \
#     --rdpass 'MiClaveRustDesk2026'
#
# La clave del operador se toma de ./operador.pub (viene en el kit) o de
# --key. Si no hay ninguna, se avisa (el operador no podría entrar por SSH).
#
# Opciones:
#   --authkey "tskey-auth-..."  Auth key de Tailscale (obligatoria salvo -luego/-skip)
#   --authkey-stdin             Lee la auth key por STDIN (no queda en el historial)
#                               Uso: printf %s "tskey-..." | ./instalar-todo.sh --authkey-stdin
#   --rdpass  "..."             Contraseña permanente de RustDesk (obligatoria)
#   --key "ssh-ed25519 ..."     Clave pública del operador (o usa operador.pub)
#   --sudopass "..."            Contraseña de sudo, si sudo la pide
#   --tailnet-host "nombre"     Nombre en la tailnet (ej: cliente-juan). Sin esto
#                               se usa el hostname del equipo.
#   --tailscale-luego           Instala Tailscale SIN unir; te guia para unir despues
#                               (util si todavia no tenes la auth key: no bloquea)
#   --skip-tailscale            No tocar Tailscale (instalar solo para LAN)
#   --dry-run                   Muestra qué haría, sin aplicar nada
#   --yes, -y                   No preguntar (modo desatendido)
#   -h, --help                  Esta ayuda
#
# ¿NO TENES LA AUTH KEY TODAVIA?  No se genera en el equipo: se crea en la WEB
# (login.tailscale.com -> Settings -> Keys) desde cualquier navegador y se copia.
# Para no quedarte a mitad, usa --tailscale-luego y luego: ./unir-tailscale.sh
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
TAILNET_HOST=""
SKIP_TS=0
TS_LUEGO=0
DRY_RUN=0
ASSUME_YES=0

# Helper ÚNICO de sudo (lib/sudo.sh, issue #28 / H-68). Antes este script
# tenía su propia copia de `sudow`; se centralizó para que H-68 (`sudo -S` se
# come stdin) no pueda reaparecer por una implementación distinta.
# shellcheck source=lib/sudo.sh
source "$SCRIPT_DIR/lib/sudo.sh"
# `sudow` se mantiene como alias: mapea la clave del flag --sudopass ($SUDOPASS)
# a SUDO_PASS que entiende el helper, y delega en sudo_run.
sudow() {
  [[ -n "$SUDOPASS" ]] && export SUDO_PASS="$SUDOPASS"
  sudo_run "$@"
}

info() { printf '\033[1;34m●\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m▲\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m✘\033[0m %s\n' "$*" >&2; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

usage() { sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'; }

AUTHKEY_POR_ARGV=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --authkey)        AUTHKEY="${2:-}"; AUTHKEY_POR_ARGV=1; shift 2 ;;
    # --authkey-stdin: lee la key por STDIN. NO queda en ~/.bash_history ni en
    # 'ps' (a diferencia de --authkey 'tskey-...'). Recomendado:
    #   printf %s "tskey-auth-..." | sudo ./instalar-todo.sh --authkey-stdin ...
    --authkey-stdin)  IFS= read -rs AUTHKEY || true; shift ;;
    --rdpass)         RDPASS="${2:-}"; shift 2 ;;
    --key)            OPKEY="${2:-}"; shift 2 ;;
    --sudopass)       SUDOPASS="${2:-}"; shift 2 ;;
    --tailnet-host)   TAILNET_HOST="${2:-}"; shift 2 ;;
    --skip-tailscale) SKIP_TS=1; shift ;;
    --tailscale-luego) TS_LUEGO=1; AUTHKEY="__PENDIENTE__"; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --yes|-y)         ASSUME_YES=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) err "opción desconocida: $1"; usage; exit 2 ;;
  esac
done

# Si la auth key vino por --authkey (argv), queda en ~/.bash_history del equipo
# y es visible en 'ps' durante toda la instalación. Se avisa (no se aborta:
# el flag sigue siendo válido para scripts, donde el operador controla el
# entorno). Preferí --authkey-stdin, que no deja rastro.
if [[ $AUTHKEY_POR_ARGV -eq 1 ]]; then
  warn "--authkey en la linea de comandos queda en el historial y en 'ps'."
  warn "  Mejor:  printf %s \"tskey-...\" | sudo ./instalar-todo.sh --authkey-stdin ..."
fi

# ---------- validaciones previas ----------
# Versión del kit, si viene de make-kit.sh (para depurar desde fuera).
KV=""
[[ -f "$SCRIPT_DIR/.kit-version" ]] && KV="$(sed -n 's/^kit_version=//p' "$SCRIPT_DIR/.kit-version" | head -1)"
[[ -n "$KV" ]] && info "kit versión: $KV"

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

# auth key de Tailscale
if [[ $SKIP_TS -eq 0 && $TS_LUEGO -eq 1 ]]; then
  warn "--tailscale-luego: se instala Tailscale pero NO se une todavia"
  info "  Al terminar, el script te dice como obtener la key y unir el equipo."
elif [[ $SKIP_TS -eq 0 ]]; then
  if [[ -z "$AUTHKEY" ]]; then
    err "falta --authkey (auth key de Tailscale)."
    err "  NO se genera en el equipo: se crea en la WEB y se copia aca."
    err "  Desde cualquier navegador (tu celular sirve):"
    err "    1) https://login.tailscale.com/admin/settings/keys"
    err "    2) pestana 'Keys' -> 'Generate auth key...'"
    err "    3) copiar el string tskey-auth-..."
    err "  O usá --tailscale-luego (instala TS y te guia para unir despues)"
    err "  O usá --skip-tailscale (instalar solo para LAN)."
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
  # Si nos dieron --sudopass, ELEVAMOS nosotros en vez de exigir que el usuario
  # escriba `sudo` delante. Antes --sudopass solo servía por dentro y el script
  # moría con "a terminal is required to read the password" aunque se hubiera
  # pasado la contraseña: era un nombre engañoso.
  if [[ -n "$SUDOPASS" ]]; then
    info "elevando con la contraseña de --sudopass..."
    # sudo_v refresca las credenciales por SUDO_ASKPASS sin consumir stdin
    # (el `printf ... | sudo -S -v` anterior era justo el patrón de H-68).
    if SUDO_PASS="$SUDOPASS" sudo_v 2>/dev/null; then
      # -E preserva el entorno; --sudopass se re-pasa para los hijos
      exec sudo -E bash "$0" "$@"
    else
      err "la contraseña de --sudopass no es válida"
      exit 1
    fi
  fi
  err "ejecutá con sudo, o pasá la contraseña con --sudopass:"
  err "  sudo ./instalar-todo.sh --authkey 'tskey-auth-...' --rdpass '...'"
  err "  ./instalar-todo.sh --authkey '...' --rdpass '...' --sudopass 'tu-clave'"
  err "  (para solo simular:  ./instalar-todo.sh ... --dry-run  sin sudo)"
  exit 1
fi

# usuario objetivo (con sudo, el real está en SUDO_USER)
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
[[ "$TARGET_USER" == "root" ]] && TARGET_USER="$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd)"
# Calidad de la contraseña: es la llave PERMANENTE de entrada a este equipo,
# así que avisamos de los casos débiles típicos (sin bloquear, pero claro).
PW_WEAK=0
if [[ ${#RDPASS} -lt 8 ]]; then
  warn "la contraseña tiene menos de 8 caracteres"
  PW_WEAK=1
fi

# nombre de usuario (o parte) dentro de la contraseña
_lc_pw="$(tr '[:upper:]' '[:lower:]' <<<"$RDPASS")"
_lc_user="$(tr '[:upper:]' '[:lower:]' <<<"$TARGET_USER")"
if [[ -n "$_lc_user" && ${#_lc_user} -ge 3 && "$_lc_pw" == *"$_lc_user"* ]]; then
  warn "la contraseña contiene el nombre de usuario ('$TARGET_USER')"
  PW_WEAK=1
fi

# patrón Nombre+dd  (p.ej. Juanpablo44): letras seguidas de 1-4 dígitos
if [[ "$RDPASS" =~ ^[A-Za-z]{4,}[0-9]{1,4}$ ]]; then
  warn "la contraseña parece 'nombre + números' (patrón predecible)"
  PW_WEAK=1
fi

# palabras demasiado comunes
for _c in password contrasena 123456 admin rustdesk; do
  if [[ "$_lc_pw" == *"$_c"* ]]; then
    warn "la contraseña contiene una palabra común ('$_c')"
    PW_WEAK=1
  fi
done

if [[ $PW_WEAK -eq 1 ]]; then
  warn "recomendado: una contraseña de 16+ caracteres de tu gestor de claves."
  warn "  Esta clave da acceso permanente a TODOS los equipos de clientes."
fi
ok "contraseña de RustDesk definida (${#RDPASS} caracteres)"
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
[[ $SKIP_TS -eq 0 && $TS_LUEGO -eq 0 ]] && info "3. Tailscale: unir el equipo a la tailnet"
[[ $TS_LUEGO -eq 1 ]] && info "3. Tailscale: INSTALAR (unir queda para la etapa 2)"
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

# TS_FALLO: marca si Tailscale falló (paso opcional) para el resumen final.
TS_FALLO=0
# (La construcción de ARGS_CORE/ARGS_TS se hace más abajo, antes de cada paso.)

# ---------- 1. diagnóstico ----------
hdr "1/5 · Diagnóstico"
# Se corre UNA sola vez y se reutiliza la salida: antes se ejecutaba dos veces
# (una para mostrar y otra solo para sacar la familia).
CHECK_OUT="$(./setup-remote-target.sh --check 2>&1 || true)"
printf '%s\n' "$CHECK_OUT" | sed 's/^/  /'
FAM="$(grep -E 'Familia:' <<<"$CHECK_OUT" | awk '{print $3}' | head -1)"
info "familia detectada: ${FAM:-?}"

# ---------- 2 y 3. kit completo ----------
hdr "2/5 · RustDesk unattended + SSH + firewall + anti-suspensión (portátil)"
# H-68b: los pasos CRÍTICOS (RustDesk + SSH + firewall + contraseña) no deben
# abortarse si Tailscale falla. Tailscale es OPCIONAL para el acceso remoto
# (solo añade alcance fuera de la LAN) y su paquete NO está en los repos de
# Debian/Ubuntu/Mint por defecto → era el fallo típico que rompía TODA la
# instalación y dejaba el desatendido sin contraseña.
#
# Por eso: primero los críticos (sin Tailscale); Tailscale se intenta APARTE.
ARGS_CORE=(--rustdesk --ssh --laptop --yes)
[[ -n "$OPKEY" ]] && ARGS_CORE+=(--key "$OPKEY")
[[ $DRY_RUN -eq 1 ]] && ARGS_CORE+=(--dry-run)
if ! ./setup-remote-target.sh "${ARGS_CORE[@]}"; then
  err "setup-remote-target.sh falló en los pasos CRÍTICOS. Revisá la salida de arriba."
  err "  Reintentá solo eso para ver el detalle:"
  err "    sudo ./setup-remote-target.sh ${ARGS_CORE[*]}"
  exit 1
fi

# Tailscale por separado (opcional en la práctica: solo da acceso fuera de LAN)
if [[ $SKIP_TS -eq 0 ]]; then
  hdr "2b/5 · Tailscale (acceso fuera de la LAN)"
  ARGS_TS=(--tailscale --yes)
  [[ -n "$TAILNET_HOST" ]] && ARGS_TS+=(--tailnet-host "$TAILNET_HOST")
  [[ $DRY_RUN -eq 1 ]] && ARGS_TS+=(--dry-run)
  # Auth key por entorno (no por argv), para no dejarla en 'ps'.
  if [[ $TS_LUEGO -eq 1 ]]; then
    ARGS_TS+=(--install-tailscale)
  else
    KIT_AUTHKEY="$AUTHKEY"; export KIT_AUTHKEY
    ARGS_TS+=(--authkey-env)
  fi
  if ./setup-remote-target.sh "${ARGS_TS[@]}"; then
    ok "Tailscale OK"
  else
    warn "Tailscale FALLÓ (paso opcional). El acceso por LAN/SSH sigue funcionando."
    warn "  Causa típica: el paquete no está en los repos (Debian/Ubuntu/Mint)."
    warn "  Se instala después con el repo oficial:"
    warn "    curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up --authkey=..."
    warn "  O reejecutá:  sudo ./setup-remote-target.sh --tailscale --yes --authkey-env"
    TS_FALLO=1
  fi
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

# relanzar rustdesk para que tome la config nueva (con sudo si hace falta)
sudow systemctl restart rustdesk >/dev/null 2>&1 || sudo -n systemctl restart rustdesk >/dev/null 2>&1 || true
sleep 3

FAILED=0
# chk_root: comprueba algo que requiere leer config de root (usa sudow/sudo -n)
chk_root() {
  if sudow test -r /root/.config/rustdesk/RustDesk.toml >/dev/null 2>&1 \
     && sudow grep -q "^password = .01" /root/.config/rustdesk/RustDesk.toml >/dev/null 2>&1; then
    ok "$1"
  else
    err "$1"
    FAILED=$((FAILED+1))
  fi
}
# chk: recibe una descripción y el nombre de una función de chequeo (sin eval).
# La función devuelve 0 si pasa. Los chequeos internos viven en chk_impl_*.
chk() {
  if "$2" >/dev/null 2>&1; then ok "$1"; else err "$1"; FAILED=$((FAILED+1)); fi
}
chk_impl_rustdesk() { systemctl is-active --quiet rustdesk; }
chk_impl_sshd()     { systemctl is-active --quiet sshd || systemctl is-active --quiet ssh; }
chk_impl_uinput()   { test -e /dev/uinput; }

chk "rustdesk.service activo"        chk_impl_rustdesk
chk "sshd activo"                    chk_impl_sshd
chk_root "contraseña permanente escrita"
chk "uinput disponible"              chk_impl_uinput

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
  elif [[ ${TS_FALLO:-0} -eq 1 ]]; then
    # Ya sabíamos que Tailscale falló (paso opcional): no cuenta como fallo global.
    warn "Tailscale sin IP (paso opcional; el acceso por LAN/SSH sigue OK)"
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
