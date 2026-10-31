#!/usr/bin/env bash
#
# lib/sr-t-check.sh — Módulo de diagnóstico (--check).
#
# Parte del issue #27 (partir el monolito setup-remote-target.sh en módulos).
# Este archivo NO se ejecuta solo: está pensado para `source`:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/sr-t-check.sh"
#
# No lleva `set -e` ni nada más: el script que lo carga ya fija sus opciones.
# Requiere helpers del script principal y de los módulos ya sourceados:
# hdr/info/ok/warn/err, DISTRO_FAMILY, pkg_installed, pkg_manager_version,
# local_ip, local_hostname, graphical_session_type, detect_firewall,
# check_wayland_capture_stack, detect_aur, TARGET_USER, TARGET_HOME, SSH_PORT.
# El comportamiento es idéntico al bloque que antes vivía inline.

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
