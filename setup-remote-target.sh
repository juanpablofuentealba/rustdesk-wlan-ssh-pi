#!/usr/bin/env bash
#
# setup-remote-target.sh — Prepara un PC Linux para ser administrado de forma
# remota con RustDesk (unattended en Wayland) + SSH.
#
# Distros soportadas (con ramas separadas por familia):
#   · Arch / CachyOS / Manjaro   → pacman + AUR (paru/yay)
#   · Debian / Ubuntu / Mint     → apt + .deb oficial de RustDesk
#   · Fedora / RHEL / Rocky      → dnf + .rpm oficial de RustDesk
#
# Ejecutar EN EL PC OBJETIVO. La parte de SSH/firewall necesita root:
#
#   # 0) Diagnóstico (no cambia nada, NO necesita root)
#   ./setup-remote-target.sh --check
#
#   # 1) RustDesk unattended
#   sudo ./setup-remote-target.sh --rustdesk
#
#   # 2) SSH + firewall + clave pública del operador
#   sudo ./setup-remote-target.sh --ssh --key "ssh-ed25519 AAAA... operador@mipc"
#
#   # 3) Todo (simulacro primero, luego aplicar)
#   sudo ./setup-remote-target.sh --all --dry-run
#   sudo ./setup-remote-target.sh --all --key "ssh-ed25519 AAAA... operador@mipc"
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
DO_CHECK=0
SSH_PORT=22
KEY=""
DRY_RUN=0
ASSUME_YES=0

usage() {
  sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Opciones:
  --rustdesk            Instala/configura RustDesk con unattended en Wayland
  --ssh                 Instala y habilita sshd + abre el firewall
  --key "<pubkey>"      Clave pública del operador a autorizar
  --port <n>            Puerto SSH (por defecto 22)
  --check               Solo diagnóstico (no cambia nada; no requiere root)
  --all                 Equivale a --rustdesk --ssh
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rustdesk) DO_RUSTDESK=1; shift ;;
    --ssh)      DO_SSH=1; shift ;;
    --key)      KEY="${2:-}"; shift 2 ;;
    --port)     SSH_PORT="${2:-22}"; shift 2 ;;
    --check)    DO_CHECK=1; shift ;;
    --all)      DO_RUSTDESK=1; DO_SSH=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --yes|-y)   ASSUME_YES=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) err "Opción desconocida: $1"; usage; exit 1 ;;
  esac
done

if [[ $DO_RUSTDESK -eq 0 && $DO_SSH -eq 0 && $DO_CHECK -eq 0 ]]; then
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
    err "Este paso requiere root. Ejecuta con: sudo $0 $*"
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
      # sin root no podemos usar 'ufw status'; leemos el archivo de config
      st=""
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
  printf 'none'
}

detect_aur() {
  local a
  for a in paru yay; do
    if command -v "$a" >/dev/null 2>&1; then printf '%s' "$a"; return; fi
  done
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
local_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

# ---------- 1. diagnóstico ----------
run_check() {
  hdr "Diagnóstico del sistema"
  info "OS: $(grep -s PRETTY_NAME /etc/os-release | cut -d= -f2- | tr -d '"')"
  info "Familia: $DISTRO_FAMILY"
  info "Kernel: $(uname -r)"
  info "Hostname: $(hostname)"
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
  log="$(ls -t "$logdir"/rustdesk_r*.log 2>/dev/null | head -1 || true)"
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
  [[ -e /dev/uinput ]] && ok "/dev/uinput presente" || warn "/dev/uinput ausente"
  lsmod 2>/dev/null | grep -q '^uinput' && ok "módulo uinput cargado" || warn "módulo uinput no cargado (se carga on-demand)"
  # sesión gráfica
  local sess_type
  sess_type="$(loginctl show-session "$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}' | tail -1)" -p Type --value 2>/dev/null || true)"
  info "Tipo de sesión detectada: ${sess_type:-desconocido}"
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
    none)      ok "Sin firewall activo (accesible en LAN, pero menos seguro)" ;;
  esac

  hdr "Red"
  ip -br addr show 2>/dev/null | grep -vE '^lo' | sed 's/^/    /'
  info "IP local: $(local_ip)"

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
      else
        local aur; aur="$(detect_aur)"
        if [[ -n "$aur" ]]; then
          info "Instalando rustdesk-unattended-wayland con $aur..."
          if [[ $DRY_RUN -eq 1 ]]; then
            printf '%s[aur]%s sudo -u %s %s -S --needed --noconfirm rustdesk-unattended-wayland\n' "$B" "$N" "$TARGET_USER" "$aur"
            ok "(dry-run) se instalaría rustdesk-unattended-wayland"
          elif sudo -u "$TARGET_USER" -H "$aur" -S --needed --noconfirm rustdesk-unattended-wayland; then
            ok "Instalado"
          else
            err "Falló la instalación con $aur"
            return 1
          fi
        else
          err "No hay paru/yay disponibles. Instala el paquete desde AUR manualmente:"
          err "  paru -S rustdesk-unattended-wayland"
          return 1
        fi
      fi
      ;;
    debian)
      install_rustdesk_deb
      ;;
    fedora)
      install_rustdesk_rpm
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

  # sugerir enable-drm-display-wake en la config del usuario objetivo
  local rd2="$TARGET_HOME/.config/rustdesk/RustDesk2.toml"
  if [[ -f "$rd2" ]]; then
    if grep -q "enable-drm-display-wake" "$rd2"; then
      ok "enable-drm-display-wake ya configurado"
    else
      warn "Recomendado: añadir a $rd2"
      warn "  [options]"
      warn "  enable-drm-display-wake = 'Y'"
      warn "  (evita fallos de captura si el monitor se apaga)"
    fi
  else
    warn "No existe $rd2 todavía (RustDesk lo crea al primer arranque de la GUI)"
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
      sess="$(loginctl show-session "$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}' | tail -1)" -p Type --value 2>/dev/null || true)"
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
  local i
  for i in 1 2 3 4 5; do
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
      run ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1 || true
      run ufw reload >/dev/null 2>&1 || true
      if [[ $DRY_RUN -eq 1 ]]; then
        info "(dry-run) ufw permitiría ${SSH_PORT}/tcp"
      elif ufw status 2>/dev/null | grep -qE "${SSH_PORT}(/tcp)?[[:space:]]+ALLOW"; then
        ok "ufw: ${SSH_PORT}/tcp permitido"
      elif ufw status 2>/dev/null | grep -q "${SSH_PORT}"; then
        ok "ufw: ${SSH_PORT}/tcp presente en las reglas"
      else
        warn "ufw: no pude confirmar la regla. Comprueba: sudo ufw status"
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
      elif ufw status 2>/dev/null | grep -qE "Status: active"; then
        if ufw status 2>/dev/null | grep -qE "${SSH_PORT}(/tcp)?[[:space:]]+ALLOW"; then
          ok "ufw activado con ${SSH_PORT}/tcp permitido"
        else
          warn "ufw activo pero no veo la regla ${SSH_PORT}/tcp; revisa: sudo ufw status"
        fi
      else
        warn "no pude confirmar; revisa manualmente: sudo ufw status"
      fi
      ;;
    firewalld-inactive)
      warn "firewalld está instalado pero INACTIVO"
      info "Activando firewalld y permitiendo ssh..."
      run systemctl enable --now firewalld >/dev/null 2>&1 || true
      run firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || true
      run firewall-cmd --reload >/dev/null 2>&1 || true
      if [[ $DRY_RUN -eq 1 ]]; then
        info "(dry-run) firewalld se activaría y permitiría ssh"
      else
        ok "firewalld activado con servicio ssh permitido"
      fi
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

# ---------- main ----------
if [[ $DO_CHECK -eq 1 ]]; then
  run_check
  exit 0
fi

# Resumen previo + confirmación (a menos que --yes o --dry-run)
hdr "Acciones a realizar"
[[ $DO_RUSTDESK -eq 1 ]] && info "· RustDesk unattended (DRM + uinput)"
[[ $DO_SSH -eq 1 ]] && info "· sshd habilitado + firewall :${SSH_PORT}"
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

if [[ $DRY_RUN -eq 1 ]]; then
  hdr "Fin del simulacro"
  ok "Nada fue modificado. Ejecuta sin --dry-run para aplicar."
  exit 0
fi

hdr "Hecho"
ok "Verifica con: ./setup-remote-target.sh --check"
