#!/usr/bin/env bash
#
# lib/sr-t-rustdesk.sh — Módulo de RustDesk (instalación por familia + setup).
#
# Parte del issue #27 (partir el monolito setup-remote-target.sh en módulos).
# Este archivo NO se ejecuta solo: está pensado para `source`:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/sr-t-rustdesk.sh"
#
# Requiere que el script que lo carga ya tenga definidos los helpers del
# script principal (run, err, warn, info, ok, hdr, pkg_installed,
# install_rustdesk_arch_unattended, install_rustdesk_unattended_deb,
# graphical_session_type, DRY_RUN, DISTRO_FAMILY, TARGET_HOME, B, N).
#
# No lleva `set -e` ni nada más: el script que lo carga ya fija sus opciones.
# El comportamiento es idéntico al bloque que antes vivía inline en
# setup-remote-target.sh.

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

