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
ASSUME_YES=0

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
# útil ("sudo $0 --all --key ...") aunque no reciba argumentos.
ORIG_ARGS="$*"

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

TARGET_USER="$(resolve_target_user)"
if [[ "$TARGET_USER" == "root" ]]; then
  TARGET_HOME="/root"
else
  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  [[ -n "$TARGET_HOME" ]] || TARGET_HOME="/home/$TARGET_USER"
fi

# ---------- helpers ----------
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

detect_aur() {
  local a
  for a in paru yay; do
    if command -v "$a" >/dev/null 2>&1; then printf '%s' "$a"; return; fi
  done
  printf ''
}

# Instala un ayudante de AUR (paru-bin, que viene compilado y no necesita
# base-devel ni compilar nada) en un Arch/CachyOS recién instalado.
# Necesario porque un sistema virgen puede no traer paru ni yay, y sin ellos
# no se puede instalar rustdesk-unattended-wayland.
# Instala RustDesk con capturador DRM en Arch/CachyOS SIN depender de paru.
#
# Tres vías, de la más simple a la más compleja. Se prueba en orden:
#   1. AUR helper (paru/yay) si ya está -> lo más limpio
#   2. El .deb OFICIAL "unattended-wayland" extraído a mano (como en Fedora)
#      -> NO necesita compilar, NO necesita AUR, NO necesita paru
#   3. Instalar paru y usarlo (último recurso)
#
# Motivo: paru encadena dependencias (git + base-devel + red + compilar) y si
# falla cualquier eslabón no hay RustDesk. El .deb oficial trae exactamente el
# mismo binario (verificado por sha256 contra el PKGBUILD del AUR) y ya incluye
# libdrmtap.so, que es lo que habilita la captura DRM en Wayland.
install_rustdesk_arch_unattended() {
  # --- vía 1: ayudante de AUR si ya está ---
  local aur; aur="$(detect_aur)"
  if [[ -n "$aur" ]]; then
    info "Instalando rustdesk-unattended-wayland con $aur..."
    if [[ $DRY_RUN -eq 1 ]]; then
      info "(dry-run) $aur -S --needed rustdesk-unattended-wayland"
      return 0
    fi
    if sudo -u "$TARGET_USER" -H "$aur" -S --needed --noconfirm rustdesk-unattended-wayland; then
      ok "Instalado con $aur"
      return 0
    fi
    warn "$aur falló; probando la vía del .deb oficial (sin AUR)..."
  fi

  # --- vía 2: el .deb oficial, extraído a mano ---
  if install_rustdesk_unattended_deb; then return 0; fi

  # --- vía 3: instalar paru y reintentar ---
  warn "El .deb oficial tampoco funcionó; probando instalar paru..."
  aur="$(ensure_aur)"
  [[ -z "$aur" ]] && return 1
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) $aur -S --needed rustdesk-unattended-wayland"
    return 0
  fi
  sudo -u "$TARGET_USER" -H "$aur" -S --needed --noconfirm rustdesk-unattended-wayland \
    && { ok "Instalado con $aur"; return 0; }
  return 1
}

# Instala el .deb oficial "rustdesk-unattended-wayland" SIN dpkg.
#
# Es PORTABLE: solo necesita curl + ar + tar, así que sirve igual en Arch,
# Fedora, Debian y cualquier otra. Es la vía que trae libdrmtap.so (captura
# DRM en Wayland), a diferencia del .rpm/.deb estándar (ver H-14).
#
# El nombre lleva _deb (no _arch) desde H-24: antes se llamaba
# install_rustdesk_unattended_deb_arch y solo se usaba en la rama arch, así
# que Fedora instalaba el .rpm SIN capturador DRM y el desatendido cascaba al
# portal en silencio.

# ¿Están satisfechas las dependencias dinámicas de libdrmtap.so?
#
# Por qué importa: en Arch/Fedora el .deb se inyecta a mano (ar+tar), así que
# el gestor de paquetes NO sabe que existe. libdrmtap.so enlaza contra
# libdrm.so.2, libEGL/libGLESv2, libm, libc. Si una actualización (Arch es
# rolling) sube libdrm/libEGL con ABI incompatible o las quita, el capturador
# DRM deja de cargar EN SILENCIO: RustDesk sigue abriendo pero el desatendido
# en Wayland vuelve al portal y falla. Este chequeo lo hace visible.
#
# Devuelve 0 si todas las dependencias resuelven, 1 si falta alguna (y avisa).
check_drmtap_deps() {
  local lib=""
  # La librería real (el .deb instala .so.0.5.8 + symlink .so.0)
  for lib in /usr/lib/rustdesk/libdrmtap.so.*; do
    [[ -f "$lib" ]] && break
    lib=""
  done
  if [[ -z "$lib" ]]; then
    warn "no encuentro libdrmtap.so.* para comprobar dependencias"
    return 1
  fi

  # ldd no está en todas partes; sin él no se puede comprobar (no es un fallo
  # del kit, solo no se puede verificar).
  if ! command -v ldd >/dev/null 2>&1; then
    info "sin 'ldd' en este sistema: no puedo verificar dependencias de libdrmtap"
    return 0
  fi

  local out; out="$(ldd "$lib" 2>&1 || true)"
  local missing; missing="$(printf '%s\n' "$out" | grep 'not found' || true)"
  if [[ -n "$missing" ]]; then
    warn "libdrmtap tiene dependencias SIN resolver (el DRM podría no cargar):"
    printf '%s\n' "$missing" | sed 's/^/    /'
    if [[ "$DISTRO_FAMILY" == "arch" ]]; then
      warn "  revisá: pacman -Qo /usr/lib/libdrm.so.2  y reinstalá lo que falte"
    elif [[ "$DISTRO_FAMILY" == "fedora" ]]; then
      warn "  revisá: rpm -qf /usr/lib64/libdrm.so.2  y dnf install lo que falte"
    fi
    return 1
  fi

  ok "dependencias de libdrmtap resueltas (ldd)"
  return 0
}

# Comprueba la PILA DE CAPTURA en Wayland: portal XDG + PipeWire.
#
# Por qué importa: en Wayland el capturador DRM (libdrmtap) es la vía
# principal, pero si falla (p. ej. tras un update de libdrm), RustDesk cae al
# portal de escritorio (ScreenCast) para capturar pantalla. Ese portal usa
# xdg-desktop-portal + un backend (KDE/GNOME/wlroots) + PipeWire. Si CUALQUIERA
# falta, el desatendido no captura la pantalla y el operador ve negro — sin
# ningún error evidente para el cliente doméstico.
#
# Este chequeo hace visible esa dependencia ANTES de prometer unattended.
# Devuelve 0 si la pila está completa, 1 si falta algo.
check_wayland_capture_stack() {
  local missing=0
  local portals_dir="/usr/share/xdg-desktop-portal/portals"

  if [[ ! -d "$portals_dir" ]]; then
    warn "no hay $portals_dir: falta xdg-desktop-portal"
    missing=1
  else
    # Backend preferido según el escritorio. En CachyOS suele ser KDE (Plasma).
    local backend="" b
    for b in kde gnome wlr; do
      [[ -e "$portals_dir/$b.portal" ]] && { backend="$b"; break; }
    done
    if [[ -n "$backend" ]]; then
      ok "backend del portal presente: $backend.portal"
    else
      # Sin backend dedicado, queda 'gtk.portal' (último recurso).
      warn "solo hay backend 'gtk' del portal (captura limitada en Wayland)"
      # El mismo nombre de paquete sirve en las 3 familias; pkg_install_hint
      # arma el comando correcto (pacman/apt/dnf) según el cliente.
      warn "  instalá el backend del escritorio, p. ej. KDE: $(pkg_install_hint xdg-desktop-portal-kde)"
      missing=1
    fi
  fi

  # PipeWire: lo necesita el ScreenCast del portal. Se comprueba tanto la
  # presencia del binario como el estado del servicio en el user bus.
  if ! command -v pipewire >/dev/null 2>&1; then
    warn "pipewire no instalado (el portal no puede capturar audio/vídeo)"
    warn "  instalá: $(pkg_install_hint pipewire pipewire-pulse)"
    missing=1
  else
    ok "pipewire presente: $(pipewire --version 2>/dev/null | head -1 | sed 's/.* //')"
    # El servicio vive en el bus de USUARIO, no en systemd de sistema.
    if command -v systemctl >/dev/null 2>&1; then
      local pw_state
      pw_state="$(runuser -u "$TARGET_USER" -- systemctl --user is-active pipewire 2>/dev/null || true)"
      if [[ "$pw_state" == "active" ]]; then
        ok "pipewire activo (sesión de $TARGET_USER)"
      elif [[ -n "$pw_state" ]]; then
        warn "pipewire NO activo en la sesión de $TARGET_USER ($pw_state)"
        warn "  arrancalo: systemctl --user enable --now pipewire wireplumber"
        missing=1
      else
        # No se pudo consultar (sin sesión de usuario systemd, SSH, etc.)
        info "no pude consultar pipewire del usuario (¿sin sesión systemd?)"
      fi
    fi
  fi

  # El ScreenCast del portal también necesita wireplumber (session manager).
  if command -v systemctl >/dev/null 2>&1; then
    local wp_state
    wp_state="$(runuser -u "$TARGET_USER" -- systemctl --user is-active wireplumber 2>/dev/null || true)"
    [[ "$wp_state" == "active" ]] && ok "wireplumber activo" \
      || info "wireplumber ${wp_state:-no verificable} (opcional pero recomendado)"
  fi

  return $missing
}

# Instala el proveedor del icono de bandeja (libayatana-appindicator) si falta.
# Sin él, RustDesk funciona igual pero el log escupe:
#   "Failed to load ayatana-appindicator3 or appindicator3 dynamic library"
# y no muestra icono en la bandeja. Es OPCIONAL: si no se puede instalar, no
# se aborta (la captura y el control no dependen de esto).
maybe_install_appindicator() {
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) instalaría libayatana-appindicator si falta (bandeja)"
    return 0
  fi
  local pkg=""
  case "$DISTRO_FAMILY" in
    arch)   pkg="libayatana-appindicator" ;;
    debian) pkg="libayatana-appindicator3-1" ;;
    fedora) pkg="libayatana-appindicator-gtk3" ;;
  esac
  # ¿ya está resuelta la librería? (evita instalar de más en cada arranque)
  if ldconfig -p 2>/dev/null | grep -q 'libayatana-appindicator3\.so'; then
    return 0
  fi
  [[ -z "$pkg" ]] && return 0
  info "instalando $pkg (icono de bandeja de RustDesk)..."
  case "$DISTRO_FAMILY" in
    arch)   pacman -S --needed --noconfirm "$pkg" >/dev/null 2>&1 || true ;;
    debian) DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1 || true ;;
    fedora) dnf install -y "$pkg" >/dev/null 2>&1 || true ;;
  esac
  if ldconfig -p 2>/dev/null | grep -q 'libayatana-appindicator3\.so'; then
    ok "icono de bandeja disponible ($pkg)"
  else
    warn "no pude instalar $pkg (opcional: la bandeja no aparecerá, el resto sí funciona)"
  fi
  return 0
}

# Verifica que el BINARIO de RustDesk resuelva sus librerías (gtk3, etc.).
# check_drmtap_deps solo mira libdrmtap; si falta una lib del binario principal
# (típico tras un update de sistema en rolling), RustDesk no arranca.
check_rustdesk_bin_deps() {
  local bin=""
  for b in /usr/share/rustdesk/rustdesk /usr/bin/rustdesk; do
    [[ -e "$b" ]] && { bin="$b"; break; }
  done
  [[ -z "$bin" ]] && { warn "no encuentro el binario de RustDesk"; return 1; }
  command -v ldd >/dev/null 2>&1 || return 0
  local out; out="$(ldd "$bin" 2>&1 || true)"
  # libcuda.so.1 y driver de NVIDIA no son obligatorios (los pide el plugin
  # de codificación por GPU si existe). No los tratamos como error.
  local missing; missing="$(printf '%s\n' "$out" | grep 'not found' | grep -v 'libcuda\|libnvidia' || true)"
  if [[ -n "$missing" ]]; then
    warn "al binario de RustDesk le faltan librerías:"
    printf '%s\n' "$missing" | sed 's/^/    /'
    return 1
  fi
  ok "dependencias del binario de RustDesk resueltas (ldd)"
  return 0
}

install_rustdesk_unattended_deb() {
  local ver="${RD_VERSION:-1.5.0}"
  local url="https://github.com/rustdesk/rustdesk/releases/download/${ver}/rustdesk-unattended-wayland-${ver}-x86_64.deb"
  local sha_ok="9eed5e9f4b47af8ed41585c399cb2c0d2870e801c99645330dea1063ad844e09"

  # requisitos: curl, ar y tar (los dos últimos vienen en binutils/tar)
  for c in curl ar tar; do
    command -v "$c" >/dev/null 2>&1 || { warn "falta '$c' para la vía .deb"; return 1; }
  done

  # En simulacro no se comprueba la red (no se va a descargar nada).
  if [[ $DRY_RUN -eq 0 ]] && ! curl -fsS --max-time 10 https://github.com >/dev/null 2>&1; then
    warn "sin conexión a github.com: no puedo bajar el .deb oficial"
    warn "  conectá internet y reintentá"
    return 1
  fi

  info "Descargando el .deb oficial unattended-wayland ${ver}..."
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) curl -o <tmp>/rd.deb $url"
    info "(dry-run) verificaría sha256 $sha_ok"
    info "(dry-run) extraería e instalaría en /usr/share/rustdesk + /usr/lib/rustdesk"
    return 0
  fi

  local tmp; tmp="$(mktemp -d)"
  if ! curl -fsSL --max-time 300 -o "$tmp/rd.deb" "$url"; then
    warn "no pude descargar el .deb"; rm -rf "$tmp"; return 1
  fi

  local actual; actual="$(sha256sum "$tmp/rd.deb" | awk '{print $1}')"
  if [[ "$actual" != "$sha_ok" ]]; then
    warn "sha256 no coincide (esperado $sha_ok, obtenido $actual)"
    warn "  puede haber salido una versión nueva; si es así, actualizá RD_VERSION"
    rm -rf "$tmp"; return 1
  fi
  ok "sha256 verificado"

  info "Extrayendo el .deb..."
  ( cd "$tmp" && ar x rd.deb && mkdir -p root && tar -xf data.tar.* -C root ) || {
    warn "no pude extraer el .deb"; rm -rf "$tmp"; return 1
  }

  info "Instalando (con backup de la config si existía)..."
  local ts; ts="$(date +%s)"
  [[ -d /usr/share/rustdesk ]] && cp -a /usr/share/rustdesk "/root/rustdesk-backup-$ts" 2>/dev/null || true

  rm -rf /usr/share/rustdesk
  cp -a "$tmp/root/usr/share/rustdesk" /usr/share/rustdesk
  mkdir -p /usr/lib/rustdesk
  cp -a "$tmp"/root/usr/lib/rustdesk/libdrmtap.so* /usr/lib/rustdesk/ 2>/dev/null || true
  ln -sf /usr/share/rustdesk/rustdesk /usr/bin/rustdesk

  # El .deb trae .desktop e iconos; sin ellos RustDesk no aparece en el menú
  # de aplicaciones. En Arch/derivados nada los coloca (no hay dpkg), así que
  # se copian a mano (visto en pruebas reales: sin esto, solo se abría por CLI).
  if [[ -d "$tmp/root/usr/share/applications" ]]; then
    mkdir -p /usr/share/applications
    cp -a "$tmp/root/usr/share/applications/"*.desktop /usr/share/applications/ 2>/dev/null || true
  fi
  if [[ -d "$tmp/root/usr/share/icons" ]]; then
    mkdir -p /usr/share/icons
    cp -a "$tmp/root/usr/share/icons/." /usr/share/icons/ 2>/dev/null || true
  fi

  # el .deb trae su propio unit; respetamos uno existente para no romper config
  if [[ ! -f /etc/systemd/system/rustdesk.service && -f "$tmp/root/usr/share/rustdesk/files/systemd/rustdesk.service" ]]; then
    cp -a "$tmp/root/usr/share/rustdesk/files/systemd/rustdesk.service" /etc/systemd/system/rustdesk.service
    sed -i 's|ExecStop=pkill|ExecStop=/usr/bin/pkill|' /etc/systemd/system/rustdesk.service 2>/dev/null || true
  fi

  # dueño correcto (venimos de /tmp)
  chown -R root:root /usr/share/rustdesk /usr/lib/rustdesk 2>/dev/null || true

  rm -rf "$tmp"

  if [[ -f /usr/lib/rustdesk/libdrmtap.so.0 ]]; then
    ok "Instalado con capturador DRM (libdrmtap) — vía .deb oficial, sin AUR"
    # El icono de bandeja necesita libayatana-appindicator: sin ella, el log
    # escupe "Failed to load ayatana-appindicator3" (visto en pruebas). Es
    # opcional (solo afecta la bandeja), así que se intenta sin abortar.
    maybe_install_appindicator
    # El .deb inyectado no lo conoce el gestor de paquetes: si una librería
    # del sistema cambia de ABI, esto lo detecta ahora y no "un día cualquiera".
    check_drmtap_deps || warn "  el capturador DRM podría fallar tras un update del sistema"
    check_rustdesk_bin_deps || warn "  al binario de RustDesk le faltan librerías (revisar arriba)"
    systemctl daemon-reload >/dev/null 2>&1 || true
    return 0
  fi
  warn "instalé el paquete pero no encuentro libdrmtap.so.0"
  return 1
}

ensure_aur() {
  local aur; aur="$(detect_aur)"
  if [[ -n "$aur" ]]; then printf '%s' "$aur"; return 0; fi

  info "No hay ayudante de AUR (paru/yay). Instalando paru..."

  # --- vía 1: el repo BINARIO (rápida y sin compilar) ---
  # CachyOS trae `paru` en su repo oficial; Arch lo tiene en extra. Intentarlo
  # primero evita compilar paru-bin desde AUR (que exige git + base-devel y
  # tarda varios minutos). Antes se iba directo al AUR: funcionaba, pero era
  # innecesariamente lento y frágil en un CachyOS recién instalado (H-25).
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) pacman -S paru   (desde el repo binario)"
    info "(dry-run) si no está en los repos, compilaría paru-bin desde AUR"
    printf '%s' "paru"; return 0
  fi

  if pacman -S --needed --noconfirm paru >/dev/null 2>&1 \
     && command -v paru >/dev/null 2>&1; then
    ok "paru instalado desde el repositorio (sin compilar)"
    printf '%s' "paru"; return 0
  fi
  info "no está como paquete binario; paso a compilarlo desde AUR"

  # --- vía 2: compilar paru-bin desde AUR ---
  # Comprobar red ANTES: sin internet no hay AUR.
  if ! curl -fsS --max-time 8 https://aur.archlinux.org >/dev/null 2>&1; then
    warn "SIN CONEXIÓN a aur.archlinux.org"
    warn "  · ¿conectaste el WiFi/hotspot? Comprobá:  curl -sI https://aur.archlinux.org | head -1"
    warn "  · Si no hay red, el AUR no se puede usar. Conectate y reintentá."
    printf ''; return 0
  fi

  # paru-bin necesita git para clonarse; base-devel solo si se compila.
  info "Instalando git + base-devel..."
  if ! pacman -S --needed --noconfirm git base-devel >/dev/null 2>&1; then
    warn "no pude instalar git/base-devel"
    warn "  Probá a mano:  sudo pacman -S --needed git base-devel"
  fi

  # El directorio de compilación debe pertenecer al USUARIO, no a root:
  # `mktemp -d` crea en /tmp con dueño root y modo 700, y makepkg (que corre
  # como usuario) no podría escribir ahí.
  local ubuild="$TARGET_HOME/.cache/paru-build"
  mkdir -p "$ubuild"
  chown "$TARGET_USER" "$ubuild" 2>/dev/null || true
  rm -rf "$ubuild/paru-bin"

  info "Clonando paru-bin desde AUR..."
  if ! sudo -u "$TARGET_USER" -H git clone --depth 1 \
         https://aur.archlinux.org/paru-bin.git "$ubuild/paru-bin" >/dev/null 2>&1; then
    warn "no pude clonar paru-bin (¿sin red o sin git?)"
    printf ''; return 0
  fi

  info "Compilando e instalando paru-bin (puede tardar un poco)..."
  if sudo -u "$TARGET_USER" -H bash -c \
       "cd '$ubuild/paru-bin' && makepkg -si --noconfirm" >/dev/null 2>&1 \
     && command -v paru >/dev/null 2>&1; then
    rm -rf "$ubuild"
    ok "paru instalado (compilado desde AUR)"
    printf '%s' "paru"; return 0
  fi

  warn "No pude instalar paru automáticamente"
  printf ''
}

# Abstracción de distro: ver lib/sr-t-distro.sh (issue #27)
source "$SCRIPT_DIR/lib/sr-t-distro.sh"

# ---------- 1. diagnóstico ----------
run_check() {
  hdr "Diagnóstico del sistema"
  info "OS: $(grep -s PRETTY_NAME /etc/os-release | cut -d= -f2- | tr -d '"')"
  info "Familia: $DISTRO_FAMILY"
  info "Gestor: $(pkg_manager_version)"
  info "Kernel: $(uname -r)"
  info "Hostname: $(local_hostname)"
  info "Usuario objetivo: $TARGET_USER  (HOME: $TARGET_HOME)"
  if [[ $EUID -eq 0 ]]; then info "Ejecutando como: root (correcto para --ssh/--rustdesk)";
  else warn "Ejecutando como usuario normal: --ssh/--rustdesk requerirán sudo"; fi

  hdr "RustDesk"
  if pkg_installed rustdesk-unattended-wayland; then
    ok "Paquete rustdesk-unattended-wayland instalado"
  elif pkg_installed rustdesk; then
    warn "rustdesk estándar instalado (sin soporte unattended Wayland)"
  elif [[ "$DISTRO_FAMILY" == "debian" ]] && command -v rustdesk >/dev/null 2>&1; then
    ok "RustDesk instalado (vía .deb/script oficial)"
  else
    err "RustDesk no instalado"
  fi
  if systemctl is-active --quiet rustdesk 2>/dev/null; then ok "rustdesk.service activo"; else warn "rustdesk.service inactivo"; fi

  local logdir="$TARGET_HOME/.local/share/logs/RustDesk/server"
  local log
  # Elegir el log MÁS RECIENTE. Con `find -printf '%T@ %p'` se ordena por mtime
  # de forma segura con cualquier nombre de archivo (SC2012).
  log="$(find "$logdir" -maxdepth 1 -name 'rustdesk_r*.log' -printf '%T@ %p\n' 2>/dev/null \
         | sort -rn | head -1 | cut -d' ' -f2- || true)"
  if [[ -n "$log" ]]; then
    info "Log del server: $log"
    grep -iE "UInput|drm:|ipc server" "$log" 2>/dev/null | tail -4 | sed 's/^/    /' \
      || warn "Sin líneas drm/uinput todavía (¿alguien se conectó ya?)"
  else
    warn "No hay log del server en $logdir"
  fi

  hdr "Pila de captura Wayland (portal + PipeWire)"
  check_wayland_capture_stack || true

  hdr "Requisitos RustDesk unattended"
  if compgen -G "/dev/dri/renderD*" >/dev/null; then ok "dispositivo(s) /dev/dri/renderD* presentes"; else err "/dev/dri/renderD* ausente (¿sin GPU?)"; fi
  if ! getent group video >/dev/null 2>&1; then
    info "grupo 'video' no existe en esta distro (no aplica el aviso)"
  elif id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx video; then
    ok "usuario '$TARGET_USER' en grupo video"
  else
    warn "usuario '$TARGET_USER' NO está en grupo video → añade: sudo usermod -aG video $TARGET_USER"
  fi
  # shellcheck disable=SC2015  # A && ok || warn: ok() nunca falla, es intencional
  [[ -e /dev/uinput ]] && ok "/dev/uinput presente" || warn "/dev/uinput ausente"
  lsmod 2>/dev/null | grep -q '^uinput' && ok "módulo uinput cargado" || warn "módulo uinput no cargado (se carga on-demand)"
  # sesión gráfica
  local sess_type
  sess_type="$(graphical_session_type)"
  if ! command -v loginctl >/dev/null 2>&1; then
    # Imágenes base mínimas (fedora:44) no traen loginctl: no es lo mismo que
    # "hay sesión pero no sé de qué tipo".
    info "Tipo de sesión detectada: no verificable (falta loginctl)"
  else
    info "Tipo de sesión detectada: ${sess_type:-desconocido}"
  fi
  [[ "$sess_type" == "wayland" ]] && ok "Wayland detectado (ruta DRM aplica)" || true

  hdr "SSH"
  if command -v sshd >/dev/null 2>&1 || [[ -x /usr/sbin/sshd ]] || pkg_installed openssh-server; then
    ok "openssh instalado"
  else
    err "openssh NO instalado"
  fi
  # El servicio puede llamarse 'sshd' (Arch/Fedora) o 'ssh' (Debian/Ubuntu)
  local ssh_unit=""
  for u in sshd ssh; do
    if systemctl list-unit-files "${u}.service" >/dev/null 2>&1 \
       && systemctl list-unit-files "${u}.service" 2>/dev/null | grep -q "^${u}.service"; then
      ssh_unit="$u"; break
    fi
  done
  ssh_unit="${ssh_unit:-sshd}"
  if systemctl is-enabled --quiet "$ssh_unit" 2>/dev/null; then ok "$ssh_unit enabled"; else warn "$ssh_unit no enabled"; fi
  if systemctl is-active --quiet "$ssh_unit" 2>/dev/null; then ok "$ssh_unit activo"; else warn "$ssh_unit inactivo"; fi
  echo
  info "Puertos SSH escuchando:"
  ss -tlnp 2>/dev/null | grep -E ":(${SSH_PORT})\b" | sed 's/^/    /' || warn "    nada en :${SSH_PORT}"
  echo
  local ak="$TARGET_HOME/.ssh/authorized_keys"
  if [[ -f "$ak" ]]; then
    info "authorized_keys ($ak): $(wc -l < "$ak") línea(s)"
    local dup
    dup="$(sort "$ak" | uniq -d | wc -l)"
    [[ "$dup" -gt 0 ]] && warn "  hay $dup clave(s) duplicada(s) → limpia con: sort -u -o $ak $ak"
  else
    warn "No existe $ak (el operador aún no puede entrar sin contraseña)"
  fi

  hdr "Firewall"
  local fw; fw="$(detect_firewall)"
  info "Detectado: $fw"
  case "$fw" in
    ufw)
      if [[ $EUID -eq 0 ]]; then ufw status 2>/dev/null | sed 's/^/    /';
      else warn "    ufw activo (estado requiere root; ejecuta: sudo ufw status)"; fi ;;
    firewalld)
      if [[ $EUID -eq 0 ]]; then firewall-cmd --list-all 2>/dev/null | sed 's/^/    /';
      else warn "    firewalld activo (requiere root para ver reglas)"; fi ;;
    nftables)  warn "    nftables activo: revisa 'sudo nft list ruleset'" ;;
    ufw-inactive)
      warn "    ufw instalado pero INACTIVO (típico en Linux Mint: GUFW sin activar)"
      warn "    --ssh lo activará y abrirá :${SSH_PORT}; si lo activas a mano: sudo ufw allow ${SSH_PORT}/tcp" ;;
    firewalld-inactive)
      warn "    firewalld instalado pero INACTIVO; --ssh lo activará y permitirá ssh" ;;
    sin-herramientas)
      warn "    Firewall NO verificable: falta systemctl/firewall-cmd/ufw"
      warn "    (imagen mínima o contenedor). No se puede afirmar que no haya filtrado." ;;
    none)      ok "Sin firewall activo (accesible en LAN, pero menos seguro)" ;;
  esac

  hdr "Red"
  ip -br addr show 2>/dev/null | grep -vE '^lo' | sed 's/^/    /'
  info "IP local: $(local_ip)"

  hdr "Energía / suspensión (H-29)"
  # En un portátil, cerrar la tapa o dejarlo inactivo suspende el equipo y se
  # pierde el acceso remoto hasta que alguien lo abra.
  local is_lap=0
  if compgen -G '/sys/class/power_supply/BAT*' >/dev/null; then is_lap=1; fi
  [[ -e /proc/acpi/button/lid ]] && is_lap=1
  if [[ $is_lap -eq 1 ]]; then
    warn "Portátil detectado (batería/tapa): puede suspender y perder el acceso"
    if [[ -f /etc/systemd/logind.conf.d/99-no-suspend-laptop.conf ]]; then
      ok "Suspensión por tapa YA desactivada (99-no-suspend-laptop.conf)"
    else
      info "  Arreglo:  sudo $0 --laptop   (o --all, que lo incluye)"
    fi
  else
    info "sin batería/tapa: parece un equipo de escritorio o VM (no aplica)"
  fi

  hdr "Otros agentes de acceso remoto (H-38)"
  # Dos agentes de control remoto pueden competir por la captura en Wayland
  # (uinput/DRM/portal de ScreenCast): uno captura, el otro ve negro. Avisar
  # si hay otros agentes además de RustDesk, sin tocarlos.
  local agents="" a
  for a in dwagent anydesk teamviewer chrome-remote-desktop xrdp vncserver tigervnc guacamole; do
    if systemctl list-unit-files "${a}.service" >/dev/null 2>&1 \
       && systemctl is-active --quiet "${a}" 2>/dev/null; then
      agents="$agents $a"
    fi
  done
  # Processo sueltos por nombre (cubre instalaciones sin unidad systemd).
  for a in anydesk teamviewer; do
    pgrep -x "$a" >/dev/null 2>&1 && [[ "$agents" != *" $a"* ]] && agents="$agents $a"
  done
  if [[ -n "$agents" ]]; then
    warn "hay otros agentes de acceso remoto ACTIVOS:$agents"
    warn "  pueden competir con RustDesk por la captura (uinput/DRM/portal)"
    warn "  si RustDesk ve negro, probá detener uno de ellos y reconectar"
  else
    ok "sin otros agentes de acceso remoto detectados (RustDesk queda solo)"
  fi

  hdr "Dependencias que suelen faltar"
  if command -v curl >/dev/null 2>&1; then ok "curl presente"
  else warn "FALTA curl (necesario para descargar el .deb oficial de RustDesk)"; fi
  if command -v git >/dev/null 2>&1; then ok "git presente"
  else warn "FALTA git (necesario solo para la vía AUR)"; fi
  if command -v makepkg >/dev/null 2>&1; then ok "makepkg presente"
  else info "makepkg ausente (normal en Debian/Fedora)"; fi
  if command -v ar >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then ok "ar + tar presentes (vía .deb)"
  else warn "FALTAN ar/tar (necesarios para la vía .deb)"; fi
  local aur_d; aur_d="$(detect_aur)"
  if [[ -n "$aur_d" ]]; then ok "ayudante de AUR: $aur_d"
  else info "sin paru/yay (el kit usará el .deb oficial, no hace falta)"; fi
  if curl -fsS --max-time 6 https://github.com >/dev/null 2>&1; then ok "internet: github.com alcanzable"
  else warn "SIN internet (los paquetes no se podrán instalar)"; fi

  hdr "Tailscale (acceso fuera de la LAN)"
  if command -v tailscale >/dev/null 2>&1; then
    local tsip; tsip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
    if [[ -n "$tsip" ]]; then
      ok "En la tailnet: $tsip"
      if systemctl is-active --quiet tailscaled 2>/dev/null; then
        ok "tailscaled activo"
      else
        warn "tailscaled inactivo"
      fi
    else
      warn "tailscale instalado pero NO unido a la tailnet"
      info "Unir con: sudo $0 --tailscale --authkey \"tskey-auth-...\""
    fi
  else
    info "Tailscale no instalado (solo acceso por LAN)"
    info "Para acceso fuera de la LAN: sudo $0 --tailscale --authkey \"tskey-auth-...\""
  fi

  hdr "Resumen"
  ok "Diagnóstico completo. Nada fue modificado."
  echo
  info "Siguientes pasos sugeridos:"
  [[ $EUID -ne 0 ]] && info "  sudo $0 --all --key \"(tu clave pública)\"" || true
}

# RustDesk (instalación por familia + setup): ver lib/sr-t-rustdesk.sh (issue #27)
source "$SCRIPT_DIR/lib/sr-t-rustdesk.sh"

# SSH (sshd + firewall): ver lib/sr-t-ssh.sh (issue #27)
source "$SCRIPT_DIR/lib/sr-t-ssh.sh"

# Tailscale (y laptop): ver lib/sr-t-tailscale.sh (issue #27)
source "$SCRIPT_DIR/lib/sr-t-tailscale.sh"

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
