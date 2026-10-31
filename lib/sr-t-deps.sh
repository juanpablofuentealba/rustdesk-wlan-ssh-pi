#!/usr/bin/env bash
#
# lib/sr-t-deps.sh — Módulo de dependencias/AUR de RustDesk.
#
# Parte del issue #27 (partir el monolito setup-remote-target.sh en módulos).
# Este archivo NO se ejecuta solo: está pensado para `source`:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/sr-t-deps.sh"
#
# No lleva `set -e` ni nada más: el script que lo carga ya fija sus opciones.
# Requiere helpers/estado del script principal y de los módulos ya sourceados:
#   - warn/info/ok  (de lib/sr-t-ui.sh)
#   - run/confirm/need_root/detect_firewall/ufw_verify (de lib/sr-t-core.sh)
#   - pkg_install_hint/pkg_installed (de lib/sr-t-distro.sh)
#   - DRY_RUN, TARGET_USER, TARGET_HOME, DISTRO_FAMILY, RD_VERSION
# El comportamiento es idéntico al bloque que antes vivía inline en
# setup-remote-target.sh.

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

