#!/usr/bin/env bash
#
# setup-remote-target.sh — Prepara un PC Linux (CachyOS/Arch) para ser
# administrado de forma remota con RustDesk (unattended en Wayland) + SSH.
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

detect_firewall() {
  for fw in ufw firewalld nftables iptables; do
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
  info "Kernel: $(uname -r)"
  info "Hostname: $(hostname)"
  info "Usuario objetivo: $TARGET_USER  (HOME: $TARGET_HOME)"
  if [[ $EUID -eq 0 ]]; then info "Ejecutando como: root (correcto para --ssh/--rustdesk)";
  else warn "Ejecutando como usuario normal: --ssh/--rustdesk requerirán sudo"; fi

  hdr "RustDesk"
  if pacman -Q rustdesk-unattended-wayland >/dev/null 2>&1; then
    ok "Paquete rustdesk-unattended-wayland instalado"
  elif pacman -Q rustdesk >/dev/null 2>&1; then
    warn "rustdesk estándar instalado (sin soporte unattended Wayland)"
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
  if id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx video; then
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
  if command -v sshd >/dev/null 2>&1; then ok "openssh instalado"; else err "openssh NO instalado"; fi
  if systemctl is-enabled --quiet sshd 2>/dev/null; then ok "sshd enabled"; else warn "sshd no enabled"; fi
  if systemctl is-active --quiet sshd 2>/dev/null; then ok "sshd activo"; else warn "sshd inactivo"; fi
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

# ---------- 2. RustDesk ----------
setup_rustdesk() {
  hdr "RustDesk (unattended en Wayland)"

  if pacman -Q rustdesk-unattended-wayland >/dev/null 2>&1; then
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

  # módulo uinput al arranque
  local modconf=/etc/modules-load.d/rustdesk-uinput.conf
  if [[ ! -f "$modconf" ]]; then
    if [[ $DRY_RUN -eq 0 ]]; then
      printf '# RustDesk: garantiza uinput (inyección de input remoto) al arranque\nuinput\n' > "$modconf"
    fi
    ok "Creado $modconf"
  else
    ok "$modconf ya existe"
  fi

  # regla udev: /dev/uinput accesible al usuario de la sesión activa
  local rule=/etc/udev/rules.d/60-rustdesk-uinput.rules
  if [[ ! -f "$rule" ]]; then
    if [[ $DRY_RUN -eq 0 ]]; then
      cat > "$rule" <<'UDEV'
# RustDesk: permite al usuario de la sesión activa usar /dev/uinput
KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"
UDEV
    fi
    ok "Creado $rule"
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
}

# ---------- 3. SSH ----------
setup_ssh() {
  hdr "SSH"

  if command -v sshd >/dev/null 2>&1; then
    ok "openssh ya instalado"
  else
    info "Instalando openssh..."
    run pacman -S --needed --noconfirm openssh
  fi

  run systemctl enable --now sshd
  ok "sshd habilitado y arrancado"

  # sshd a veces tarda en bindear; esperamos y comprobamos
  local i
  for i in 1 2 3 4 5; do
    ss -tln 2>/dev/null | grep -q ":${SSH_PORT}\b" && break
    sleep 1
  done
  if ! ss -tln 2>/dev/null | grep -q ":${SSH_PORT}\b"; then
    if [[ $DRY_RUN -eq 1 ]]; then
      info "(dry-run) sshd escucharía en :${SSH_PORT}"
    else
      err "sshd no escucha en :${SSH_PORT}"
      systemctl status sshd --no-pager 2>/dev/null | tail -5 || true
      return 1
    fi
  fi
  ok "sshd escuchando en :${SSH_PORT}"

  hdr "Firewall"
  local fw; fw="$(detect_firewall)"
  info "Detectado: $fw"
  case "$fw" in
    ufw)
      run ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1 || true
      run ufw reload >/dev/null 2>&1 || true
      if [[ $DRY_RUN -eq 1 ]]; then
        info "(dry-run) ufw permitiría ${SSH_PORT}/tcp"
      elif ufw status 2>/dev/null | grep -q "${SSH_PORT}/tcp"; then
        ok "ufw: ${SSH_PORT}/tcp permitido"
      else
        warn "ufw: no pude confirmar la regla. Comprueba: sudo ufw status"
      fi
      ;;
    firewalld)
      firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || true
      firewall-cmd --reload >/dev/null 2>&1 || true
      ok "firewalld: servicio ssh permitido"
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
