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

# ---------- colores ----------
if [[ -t 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[36m'; N=$'\e[0m'; BD=$'\e[1m'
else
  R=''; G=''; Y=''; B=''; N=''; BD=''
fi

ok()   { printf '%s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s▲%s %s\n' "$Y" "$N" "$*"; }
err()  { printf '%s✘%s %s\n' "$R" "$N" "$*" >&2; }
info() { printf '%s●%s %s\n' "$B" "$N" "$*"; }
hdr()  { printf '\n%s%s== %s ==%s\n' "$BD" "$B" "$*" "$N"; }

# ---------- estado ----------
DO_RUSTDESK=0
DO_SSH=0
DO_TAILSCALE=0
DO_LAPTOP=0
DO_CHECK=0
SSH_PORT=22
KEY=""
TS_AUTHKEY=""
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

# ---------- instalación de RustDesk por familia (aparte) ----------
# Resuelve la URL real del asset en el último release de RustDesk, según un
# patrón (regex extendida). Los nombres incluyen la versión (ej. rustdesk-1.5.0-x86_64.deb),
# por eso no se puede construir la URL a mano.
# Uso: rustdesk_asset_url '\.deb$' 'x86_64'
rustdesk_asset_url() {
  local suffix="$1" want="$2" api list
  api="https://api.github.com/repos/rustdesk/rustdesk/releases/latest"
  list="$(curl -fsSL "$api" 2>/dev/null \
    | grep -oE '"browser_download_url": *"[^"]+"' \
    | sed 's/.*"\(https[^"]*\)"/\1/' \
    | grep -E "${suffix}" \
    | grep -v 'suse' || true)"
  if [[ -n "$want" ]]; then
    # Prefiere el asset estándar (sin -sciter/-var); si no, cualquiera del arch.
    printf '%s\n' "$list" | grep -E "${want}" | grep -v 'sciter' | head -1 | grep -q . \
      && { printf '%s\n' "$list" | grep -E "${want}" | grep -v 'sciter' | head -1; return; }
    printf '%s\n' "$list" | grep -E "${want}" | head -1
  else
    printf '%s\n' "$list" | head -1
  fi
}

# Debian/Ubuntu: .deb oficial de GitHub releases.
install_rustdesk_deb() {
  if command -v rustdesk >/dev/null 2>&1; then
    ok "rustdesk ya instalado (vía .deb)"; return 0
  fi
  info "Resolviendo el .deb oficial de RustDesk..."
  local arch url tmp
  case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
    amd64|x86_64) arch=x86_64 ;;
    arm64|aarch64) arch=aarch64 ;;
    *) arch="$(dpkg --print-architecture 2>/dev/null || uname -m)" ;;
  esac
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '%s[deb]%s URL=$(rustdesk asset .deb %s desde la API de GitHub)\n' "$B" "$N" "$arch"
    printf '%s[deb]%s curl -fsSL -o /tmp/rustdesk.deb <URL>\n' "$B" "$N"
    printf '%s[deb]%s apt-get install -y /tmp/rustdesk.deb\n' "$B" "$N"
    ok "(dry-run) se instalaría RustDesk desde el .deb oficial"
    return 0
  fi
  url="$(rustdesk_asset_url '\.deb$' "$arch")"
  [[ -n "$url" ]] || { err "No se encontró el .deb ($arch) en el último release de RustDesk"; return 1; }
  tmp="/tmp/$(basename "$url")"
  info "Descargando $(basename "$url")..."
  run curl -fsSL -o "$tmp" "$url" || { err "No se pudo descargar $url"; return 1; }
  run apt-get install -y "$tmp" || { err "Falló la instalación del .deb"; return 1; }
  ok "RustDesk instalado (.deb oficial)"
}

# Fedora/RHEL: .rpm oficial de GitHub releases.
install_rustdesk_rpm() {
  if command -v rustdesk >/dev/null 2>&1; then
    ok "rustdesk ya instalado (vía .rpm)"; return 0
  fi
  info "Resolviendo el .rpm oficial de RustDesk..."
  local arch url tmp
  case "$(uname -m)" in
    x86_64)  arch=x86_64 ;;
    aarch64) arch=aarch64 ;;
    *)       arch="$(uname -m)" ;;
  esac
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '%s[rpm]%s URL=$(rustdesk asset .rpm %s desde la API de GitHub)\n' "$B" "$N" "$arch"
    printf '%s[rpm]%s curl -fsSL -o /tmp/rustdesk.rpm <URL>\n' "$B" "$N"
    printf '%s[rpm]%s dnf install -y /tmp/rustdesk.rpm\n' "$B" "$N"
    ok "(dry-run) se instalaría RustDesk desde el .rpm oficial"
    return 0
  fi
  url="$(rustdesk_asset_url '\.rpm$' "$arch")"
  [[ -n "$url" ]] || { err "No se encontró el .rpm ($arch) en el último release de RustDesk"; return 1; }
  tmp="/tmp/$(basename "$url")"
  info "Descargando $(basename "$url")..."
  run curl -fsSL -o "$tmp" "$url" || { err "No se pudo descargar $url"; return 1; }
  run dnf install -y "$tmp" || { err "Falló la instalación del .rpm"; return 1; }
  ok "RustDesk instalado (.rpm oficial)"
}

# ---------- 2. RustDesk ----------
setup_rustdesk() {
  hdr "RustDesk (unattended en Wayland)"

  case "$DISTRO_FAMILY" in
    arch)
      if pkg_installed rustdesk-unattended-wayland; then
        ok "rustdesk-unattended-wayland ya instalado"
      elif install_rustdesk_arch_unattended; then
        : # ya avisó por dentro
      else
        err "No pude instalar RustDesk con capturador DRM."
        err "  El acceso desatendido en Wayland NO funcionará sin él."
        err "  Probá a mano:  paru -S rustdesk-unattended-wayland"
        return 1
      fi
      ;;
    debian)
      install_rustdesk_deb
      ;;
    fedora)
      # OJO: el .rpm oficial NO trae libdrmtap.so (captura DRM en Wayland), así
      # que el acceso desatendido caería al portal y fallaría (H-14).
      # Por eso se intenta PRIMERO la vía portable del .deb con DRM; el .rpm
      # queda como respaldo (funciona bien en X11 y como GUI normal).
      if install_rustdesk_unattended_deb; then
        :
      elif install_rustdesk_rpm; then
        warn "se instaló el .rpm estándar: SIN capturador DRM"
        warn "  En Wayland el acceso desatendido puede cascar al portal."
        warn "  Alternativa: sudo ./install-rustdesk-unattended-fedora.sh"
      fi
      ;;
    *)
      err "Familia de distro no soportada para RustDesk automático."
      err "Instala RustDesk manualmente y vuelve a ejecutar con --rustdesk."
      return 1
      ;;
  esac

  # módulo uinput al arranque
  local modconf=/etc/modules-load.d/rustdesk-uinput.conf
  if [[ ! -f "$modconf" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      info "(dry-run) crearía $modconf"
    else
      printf '# RustDesk: garantiza uinput (inyección de input remoto) al arranque\nuinput\n' > "$modconf"
      ok "Creado $modconf"
    fi
  else
    ok "$modconf ya existe"
  fi

  # regla udev: /dev/uinput accesible al usuario de la sesión activa
  local rule=/etc/udev/rules.d/60-rustdesk-uinput.rules
  if [[ ! -f "$rule" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      info "(dry-run) crearía $rule"
    else
      cat > "$rule" <<'UDEV'
# RustDesk: permite al usuario de la sesión activa usar /dev/uinput
KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"
UDEV
      ok "Creado $rule"
    fi
  else
    ok "$rule ya existe"
  fi

  run modprobe uinput 2>/dev/null || true
  run udevadm control --reload-rules 2>/dev/null || true
  run udevadm trigger /dev/uinput 2>/dev/null || true
  ok "uinput cargado y reglas udev recargadas"

  run systemctl enable rustdesk >/dev/null 2>&1 || true
  run systemctl restart rustdesk 2>/dev/null || true
  ok "rustdesk.service habilitado y reiniciado"

  # enable-drm-display-wake: APLICARLO, no solo sugerirlo (H-24).
  # Evita que la captura falle si el monitor se apagó por inactividad.
  # Se escribe en la config del usuario objetivo Y en la de root (el servicio
  # corre como root y sincroniza la del usuario).
  local rd2="$TARGET_HOME/.config/rustdesk/RustDesk2.toml"
  _set_drm_wake() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    grep -q "enable-drm-display-wake" "$f" && return 0
    cp -a "$f" "$f.bak-$(date +%s)" 2>/dev/null || true
    if grep -q '^\[options\]' "$f"; then
      printf "enable-drm-display-wake = 'Y'\n" >> "$f"
    else
      printf "\n[options]\nenable-drm-display-wake = 'Y'\n" >> "$f"
    fi
    return 0
  }
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) escribiría enable-drm-display-wake = 'Y' en la config de RustDesk"
  else
    local applied=0
    _set_drm_wake "$rd2" && applied=1
    _set_drm_wake /root/.config/rustdesk/RustDesk2.toml && applied=1
    # validar el TOML (un archivo inválido rompe RustDesk al arrancar)
    if [[ $applied -eq 1 ]]; then
      if python3 -c "import tomllib,sys; tomllib.load(open(sys.argv[1],'rb'))" "$rd2" 2>/dev/null \
         || [[ ! -f "$rd2" ]]; then
        ok "enable-drm-display-wake aplicado (evita fallos si el monitor se apaga)"
      else
        warn "el TOML quedó inválido; restaurá el .bak-* de $rd2"
      fi
    else
      info "RustDesk aún no creó RustDesk2.toml (se crea al primer arranque de la GUI)"
    fi
  fi

  hdr "Verificación"
  info "Tras conectar una vez, en $TARGET_HOME/.local/share/logs/RustDesk/server/"
  info "debe aparecer:  drm: consumer cache warmed (N displays) at startup"
  info "Si en su lugar ves 'Please select the screen to be shared', la captura"
  info "cayó al portal (fallback): revisa grupo video y enable-drm-display-wake."

  # Nota por familia: el .deb/.rpm oficial NO trae el parche DRM del AUR de Arch.
  case "$DISTRO_FAMILY" in
    debian|fedora)
      local sess
      sess="$(graphical_session_type)"
      if [[ "$sess" == "wayland" ]]; then
        warn "Wayland detectado en $DISTRO_FAMILY: el paquete oficial NO incluye el parche DRM"
        warn "  de Arch. El acceso desatendido puede caer al portal (pide elegir pantalla)."
        warn "  Con X11 (Cinnamon por defecto en Mint) no aplica este aviso."
      else
        ok "Sesión X11 (o sin Wayland): el aviso de captura DRM no aplica"
      fi
      ;;
  esac
}

# ---------- 3. SSH ----------
setup_ssh() {
  hdr "SSH"

  # ¿sshd presente? (comando o paquete, según familia)
  if command -v sshd >/dev/null 2>&1 || [[ -x /usr/sbin/sshd ]]; then
    ok "openssh ya instalado"
  elif pkg_installed openssh-server || pkg_installed openssh; then
    ok "openssh ya instalado (paquete)"
  else
    info "Instalando openssh server..."
    case "$DISTRO_FAMILY" in
      arch)   pkg_install openssh ;;
      debian) pkg_install openssh-server ;;
      fedora) pkg_install openssh-server ;;
      *)      pkg_install openssh-server || return 1 ;;
    esac
  fi

  # Fedora/Debian modernos usan 'sshd' como alias; probamos y caemos a ssh.service
  run systemctl enable --now sshd 2>/dev/null \
    || run systemctl enable --now ssh 2>/dev/null \
    || true
  ok "sshd habilitado y arrancado"

  # sshd a veces tarda en bindear; esperamos y comprobamos
  for _ in 1 2 3 4 5; do
    ss -tln 2>/dev/null | grep -q ":${SSH_PORT}\b" && break
    sleep 1
  done
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) sshd escucharía en :${SSH_PORT}"
  elif ss -tln 2>/dev/null | grep -q ":${SSH_PORT}\b"; then
    ok "sshd escuchando en :${SSH_PORT}"
  else
    err "sshd no escucha en :${SSH_PORT}"
    systemctl status sshd --no-pager 2>/dev/null | tail -5 || true
    return 1
  fi

  hdr "Firewall"
  local fw; fw="$(detect_firewall)"
  info "Detectado: $fw"
  case "$fw" in
    ufw)
      # 'limit' en vez de 'allow': ufw aplica rate-limit (6 conexiones/30 s
      # por IP). Frena la fuerza bruta de bots y no afecta el uso legítimo
      # (ni siquiera reconexiones normales de SSH).
      run ufw limit "${SSH_PORT}/tcp" >/dev/null 2>&1 \
        || run ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1 || true
      run ufw reload >/dev/null 2>&1 || true
      if [[ $DRY_RUN -eq 1 ]]; then
        info "(dry-run) ufw limitaría ${SSH_PORT}/tcp (rate-limit anti fuerza bruta)"
      else
        ufw_verify "ufw: ${SSH_PORT}/tcp limitado (rate-limit)"
      fi
      ;;
    firewalld)
      run firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || true
      run firewall-cmd --reload >/dev/null 2>&1 || true
      if [[ $DRY_RUN -eq 1 ]]; then
        info "(dry-run) firewalld permitiría el servicio ssh"
      elif firewall-cmd --list-services 2>/dev/null | grep -qw ssh; then
        ok "firewalld: servicio ssh permitido"
      else
        warn "firewalld: no pude confirmar la regla. Comprueba: sudo firewall-cmd --list-services"
      fi
      ;;
    nftables)
      warn "nftables activo: añade manualmente una regla para tcp/${SSH_PORT}"
      warn "  sudo nft add rule inet filter input tcp dport ${SSH_PORT} accept"
      warn "  (y persístela en /etc/nftables.conf)"
      ;;
    iptables)
      warn "iptables activo: añade manualmente una regla para tcp/${SSH_PORT}"
      warn "  sudo iptables -A INPUT -p tcp --dport ${SSH_PORT} -j ACCEPT"
      ;;
    ufw-inactive)
      # Caso típico de Linux Mint: ufw instalado pero apagado.
      warn "ufw está instalado pero INACTIVO (habitual en Linux Mint)"
      info "Activando ufw y permitiendo ${SSH_PORT}/tcp..."
      run ufw --force enable >/dev/null 2>&1 || true
      run ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1 || true
      if [[ $DRY_RUN -eq 1 ]]; then
        info "(dry-run) ufw se activaría y permitiría ${SSH_PORT}/tcp"
      else
        ufw_verify "ufw activado con ${SSH_PORT}/tcp permitido"
      fi
      ;;
    firewalld-inactive)
      warn "firewalld está instalado pero INACTIVO"
      info "Activando firewalld y permitiendo ssh..."
      run systemctl enable --now firewalld >/dev/null 2>&1 || true
      run firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || true
      # rich rule con rate-limit, además del servicio ssh (cinturón y tirantes)
      run firewall-cmd --permanent --add-rich-rule='rule service name="ssh" limit value="6/m" accept' >/dev/null 2>&1 || true
      run firewall-cmd --reload >/dev/null 2>&1 || true
      if [[ $DRY_RUN -eq 1 ]]; then
        info "(dry-run) firewalld se activaría y permitiría ssh (con rate-limit)"
      else
        ok "firewalld activado con servicio ssh permitido"
      fi
      ;;
    sin-herramientas)
      warn "Firewall NO verificable (sin systemctl/firewall-cmd/ufw): no se toca nada"
      warn "  Si es un escritorio real, revisa a mano el filtrado antes de exponer ssh"
      ;;
    none)
      ok "Sin firewall: no hace falta abrir nada"
      ;;
  esac

  if [[ -n "$KEY" ]]; then
    hdr "Autorizando clave del operador"
    local sshdir="$TARGET_HOME/.ssh" ak="$TARGET_HOME/.ssh/authorized_keys"
    if [[ $DRY_RUN -eq 1 ]]; then
      printf '%s[auth]%s añadiría la clave a %s\n' "$B" "$N" "$ak"
      ok "(dry-run) clave del operador se autorizaría"
    else
      mkdir -p "$sshdir"
      touch "$ak"
      if grep -qF -- "$KEY" "$ak" 2>/dev/null; then
        ok "La clave ya estaba autorizada (no se duplica)"
      elif grep -qF "$(awk '{print $2}' <<<"$KEY")" "$ak" 2>/dev/null; then
        ok "Ya existe una clave con esa misma parte pública (se omite)"
      else
        printf '%s\n' "$KEY" >> "$ak"
        ok "Clave añadida a $ak"
      fi
      # propietario y permisos correctos (clave: si corremos como root,
      # authorized_keys DEBE pertenecer al usuario objetivo o SSH lo ignora)
      chmod 700 "$sshdir"
      chmod 600 "$ak"
      if [[ "$TARGET_USER" != "root" ]]; then
        chown -R "$TARGET_USER":"$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$sshdir"
      fi
      ok "Permisos aplicados (700 .ssh, 600 authorized_keys, owner $TARGET_USER)"
    fi
  else
    warn "No se pasó --key: el operador NO podrá entrar sin contraseña"
    warn "  Vuelve a ejecutar con: sudo $0 --ssh --key \"(tu clave pública)\""
  fi

  hdr "Listo"
  local ip; ip="$(local_ip)"
  ok "IP local: $ip"
  info "Prueba desde el operador:"
  info "  ssh -o BatchMode=yes ${TARGET_USER}@${ip} 'hostname'"
}

# ---------- 4. Tailscale ----------
# Acceso fuera de la LAN sin abrir puertos. Modelo B (cuenta del cliente):
# el cliente genera la auth key y la comparte; el equipo queda en SU tailnet,
# así el cliente conserva el control y puede revocar cuando quiera.
setup_tailscale() {
  hdr "Tailscale (acceso fuera de la LAN)"

  if command -v tailscale >/dev/null 2>&1; then
    ok "tailscale ya instalado ($(tailscale version 2>/dev/null | head -1))"
  else
    # En SIMULACRO no se comprueba la red: solo se muestra qué haría. Antes el
    # dry-run fallaba en equipos sin internet (contenedor, equipo recién
    # instalado sin conectar) aunque no fuera a instalar nada.
    if [[ $DRY_RUN -eq 1 ]]; then
      info "(dry-run) instalaría Tailscale con el gestor de paquetes"
      info "(dry-run) habilitaría y arrancaría tailscaled"
    else
      # Sin red no se puede instalar nada: comprobarlo primero da un error útil
      if ! curl -fsS --max-time 8 https://pkgs.tailscale.com >/dev/null 2>&1 \
         && ! curl -fsS --max-time 8 https://archlinux.org >/dev/null 2>&1; then
        err "SIN CONEXIÓN a internet: no puedo instalar Tailscale"
        err "  Comprobá:  curl -sI https://archlinux.org | head -1"
        err "  Conectá el WiFi/hotspot y reintentá."
        return 1
      fi
    fi
    info "Instalando Tailscale..."
    if [[ $DRY_RUN -eq 1 ]]; then
      ok "(dry-run) tailscale se instalaría"
      return 0
    fi
    case "$DISTRO_FAMILY" in
      arch|debian|fedora) pkg_install tailscale ;;
      *)                  pkg_install tailscale || true ;;
    esac
    if command -v tailscale >/dev/null 2>&1; then
      ok "Tailscale instalado ($(tailscale version 2>/dev/null | head -1))"
    else
      err "No pude instalar Tailscale con el gestor de paquetes."
      case "$DISTRO_FAMILY" in
        arch)   err "  Probá a mano:  sudo pacman -S tailscale" ;;
        debian) err "  Probá a mano:  sudo apt-get install -y tailscale" ;;
        fedora) err "  Probá a mano:  sudo dnf install -y tailscale" ;;
      esac
      err "  (la red debe funcionar; el paquete está en los repos oficiales)"
      return 1
    fi
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) habilitaría y arrancaría tailscaled"
  else
    systemctl enable --now tailscaled >/dev/null 2>&1 || true
    # esperar a que el daemon quede activo (hasta 10 s)
    for _ in $(seq 1 10); do
      systemctl is-active --quiet tailscaled 2>/dev/null && break
      sleep 1
    done
    if systemctl is-active --quiet tailscaled 2>/dev/null; then
      ok "tailscaled activo"
    else
      err "tailscaled NO arrancó. Detalle:"
      systemctl status tailscaled --no-pager 2>/dev/null | tail -6 | sed 's/^/    /' || true
      err "  Si es un contenedor/entorno sin systemd, Tailscale no funcionará aquí."
      return 1
    fi
  fi

  # ¿Ya está unido?
  local ip4=""
  ip4="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  if [[ -n "$ip4" ]]; then
    ok "Ya está en la tailnet: $ip4"
    info "Para forzar re-autenticación: sudo tailscale up --auth-key=... --force-reauth"
    return 0
  fi

  if [[ -z "$TS_AUTHKEY" ]]; then
    warn "Sin --authkey: Tailscale quedó INSTALADO pero SIN unir a la tailnet"
    info ""
    info "  La auth key NO se genera en este equipo."
    info "  Se crea en la WEB y se copia acá. Desde CUALQUIER navegador"
    info "  (tu celular sirve; no hace falta Tailscale instalado):"
    info ""
    info "    1) Abrí: https://login.tailscale.com/admin/settings/keys"
    info "       (admin -> Settings -> pestaña 'Keys')"
    info "    2) Click en 'Generate auth key...'"
    info "       Description: lo que quieras   Reusable: NO   Ephemeral: NO"
    info "       Expiry: 1 día (o 90 si vas a instalar varios)"
    info "    3) Copiá el string 'tskey-auth-...' (se muestra UNA SOLA VEZ)"
    info ""
    info "  Y uní el equipo con:"
    info "    ./unir-tailscale.sh "
    info "    (o: sudo tailscale up --auth-key='tskey-auth-...' --hostname=$(local_hostname))"
    return 0
  fi

  case "$TS_AUTHKEY" in
    tskey-*) : ;;
    *) err "La auth key debe empezar con 'tskey-'. Recibido: ${TS_AUTHKEY:0:8}..."; return 1 ;;
  esac

  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) ejecutaría: tailscale up --auth-key=tskey-auth-*** --hostname=${TARGET_HOSTNAME:-$HOSTNAME}"
    ok "(dry-run) el equipo se uniría a la tailnet"
    return 0
  fi

  info "Uniendo el equipo a la tailnet..."
  local up_log
  up_log="$(mktemp)"
  if tailscale up --auth-key="$TS_AUTHKEY" \
       --hostname="$(hostname 2>/dev/null || echo cliente)" \
       --accept-dns=false >"$up_log" 2>&1; then
    ok "Equipo unido"
  else
    err "tailscale up FALLÓ. Salida:"
    sed 's/^/    /' "$up_log" | head -10
    err "  Causas típicas:"
    err "   · auth key vencida o ya usada (generá otra)"
    err "   · auth key no 'reusable' y este equipo ya estaba en la tailnet"
    err "   · sin internet en este momento"
    rm -f "$up_log"
    return 1
  fi
  rm -f "$up_log"

  # Esperar la IP (el daemon tarda unos segundos en publicarla).
  # El contador del for no se usa dentro: '_' evita el aviso de shellcheck.
  for _ in $(seq 1 15); do
    ip4="$(tailscale ip -4 2>/dev/null | head -1 || true)"
    [[ -n "$ip4" ]] && break
    sleep 1
  done
  if [[ -n "$ip4" ]]; then
    ok "IP Tailscale: $ip4"
    info "Prueba desde el operador: ssh ${TARGET_USER}@${ip4}"
  else
    err "Unido pero sin IP Tailscale tras 15 s."
    err "  Revisá:  sudo tailscale status"
    err "  Si dice 'logged out', la auth key no se aceptó."
    return 1
  fi
}

# H-29: un portátil que suspende (tapa cerrada o inactividad) PIERDE el
# acceso remoto: Tailscale/sshd/RustDesk se caen hasta que alguien abra la
# tapa. En un PC de escritorio no pasa. Esto lo desactiva (reversible).
setup_laptop() {
  hdr "Portátil: impedir suspensión (H-29)"
  local logind_dir="/etc/systemd/logind.conf.d"
  local logind_file="$logind_dir/99-no-suspend-laptop.conf"

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "sin systemd: no puedo configurar logind; hacelo a mano si es portátil"
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) escribiría $logind_file con HandleLidSwitch=ignore"
    info "(dry-run) reiniciaría systemd-logind y quitaría la suspensión por inactividad en KDE"
    return 0
  fi

  mkdir -p "$logind_dir"
  cat > "$logind_file" <<'EOF'
# Generado por setup-remote-target.sh --laptop (H-29).
# Evita que el portátil suspenda y se pierda el acceso remoto.
# Revertir: borrar este archivo y: systemctl restart systemd-logind
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
  ok "escrito $logind_file (tapa ya no suspende)"

  if systemctl restart systemd-logind 2>/dev/null; then
    ok "systemd-logind recargado"
  else
    warn "no pude recargar systemd-logind; aplica al reiniciar"
  fi

  # KDE: sin suspensión por inactividad (AC y batería).
  if command -v kwriteconfig6 >/dev/null 2>&1; then
    local grp
    for grp in AC Battery LowBattery; do
      kwriteconfig6 --file powermanagementprofilesrc --group "$grp" \
        --group SuspendSession --key idleTime 0 2>/dev/null || true
      kwriteconfig6 --file powermanagementprofilesrc --group "$grp" \
        --group SuspendSession --key suspendType 0 2>/dev/null || true
    done
    ok "KDE: suspensión por inactividad desactivada"
  else
    warn "kwriteconfig6 ausente: desactivá a mano en Energía → Suspender sesión"
  fi
  info "Reversible: ./laptop-no-suspend.sh --revert"
}

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
