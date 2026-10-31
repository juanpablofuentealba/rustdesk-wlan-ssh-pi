#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-rustdesk-unattended-fedora.sh
#
# Instala en Fedora/RHEL el paquete OFICIAL "rustdesk-unattended-wayland"
# (que RustDesk publica como .deb en su release de GitHub) para habilitar el
# acceso DESATENDIDO en Wayland, incluso en la pantalla de login (greeter).
#
# Por qué hace falta:
#   El .rpm oficial de RustDesk NO incluye `libdrmtap.so` (captura directa por
#   DRM). Sin él, en Wayland la captura cae al XDG Desktop Portal y falla:
#     "Wayland portal handshake failed: Could not activate remote peer
#      'org.freedesktop.portal.Desktop'"
#   porque el servicio corre como root en contexto de sistema y no tiene portal
#   D-Bus de sesión.
#
# Verificado (2026-10-27) en Fedora 44 KDE Wayland:
#   - .deb sha256 9eed5e9f... (coincide con el del PKGBUILD de AUR)
#   - libdrmtap solo necesita libdrm.so.2 / libm / libc (presentes en Fedora)
#   - el binario del .deb resuelve sus libs contra el sistema (ldd sin "not found")
#
# Uso:
#   ./install-rustdesk-unattended-fedora.sh --dry-run            # plan
#   SUDO_PASS=... ./install-rustdesk-unattended-fedora.sh        # local
#   SUDO_PASS=... ./install-rustdesk-unattended-fedora.sh jp@host  # remoto
#
# Requiere: curl, ar + tar (binutils/tar), sudo
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Helper ÚNICO de sudo (lib/sudo.sh, issue #28 / H-68).
# shellcheck source=lib/sudo.sh
source "$SCRIPT_DIR/lib/sudo.sh"

VERSION="${RD_VERSION:-1.5.0}"
DEB_URL="https://github.com/rustdesk/rustdesk/releases/download/${VERSION}/rustdesk-unattended-wayland-${VERSION}-x86_64.deb"
EXPECTED_SHA="${RD_SHA256:-9eed5e9f4b47af8ed41585c399cb2c0d2870e801c99645330dea1063ad844e09}"

DRY_RUN=0
TARGET=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    -*) echo "opción desconocida: $a" >&2; exit 2 ;;
    *) TARGET="$a" ;;
  esac
done

info() { printf '\033[1;34m●\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m▲\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m✘\033[0m %s\n' "$*" >&2; }

SUDO_PASS="${SUDO_PASS:-}"
run_root() { # ejecuta el script de instalación como root (local o remoto)
  # El script llega por STDIN y debe llegar COMPLETO a bash. Mezclar la clave
  # de sudo en ese mismo stdin es el patrón de H-68 (`sudo -S` puede llevarse
  # más de una línea). Por eso:
  #   local  -> sudo_run usa SUDO_ASKPASS y deja stdin libre para el script.
  #   remoto -> primero dejamos el script en un archivo del destino y luego
  #             corremos con la clave por el stdin de SSH (ya sin script).
  if [[ -n "$TARGET" ]]; then
    ssh -o BatchMode=yes "$TARGET" 'cat > /tmp/rd-unatt-install.sh'
    printf '%s\n' "$SUDO_PASS" | ssh -o BatchMode=yes "$TARGET" \
      "sudo -S -p '' bash /tmp/rd-unatt-install.sh '$1'; rc=\$?; rm -f /tmp/rd-unatt-install.sh; exit \$rc"
  else
    sudo_run bash -s -- "$1"
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

info "Descargando rustdesk-unattended-wayland ${VERSION} (.deb oficial)..."
if [[ $DRY_RUN -eq 1 ]]; then
  echo "  curl -fsSL -o \$WORK/rd.deb '$DEB_URL'"
else
  curl -fsSL -o "$WORK/rd.deb" "$DEB_URL"
fi

info "Verificando sha256..."
if [[ $DRY_RUN -eq 1 ]]; then
  echo "  sha256sum   # esperado: $EXPECTED_SHA"
else
  actual="$(sha256sum "$WORK/rd.deb" | awk '{print $1}')"
  if [[ "$actual" != "$EXPECTED_SHA" ]]; then
    err "sha256 no coincide.\n  esperado=$EXPECTED_SHA\n  obtenido=$actual"
    exit 1
  fi
  ok "sha256 OK"
fi

info "Extrayendo..."
if [[ $DRY_RUN -eq 1 ]]; then
  echo "  ar x rd.deb && tar -xf data.tar.xz -C \$WORK/root"
else
  ( cd "$WORK" && ar x rd.deb && mkdir root && tar -xf data.tar.xz -C root )
  ok "extraído ($(find "$WORK/root" -type f | wc -l) archivos)"
fi

cat <<EOF

$(info "Plan de instalación:")
  1. Respaldo del RustDesk actual → /root/rustdesk-backup-<fecha>/
  2. Reemplazar /usr/share/rustdesk/ con el paquete unattended
  3. Instalar /usr/lib/rustdesk/libdrmtap.so* (capturador DRM directo)
  4. Instalar el rustdesk.service del .deb (con ExecStop absoluto)
  5. systemctl daemon-reload && restart rustdesk
  6. Verificar que libdrmtap se cargue y que el capturador reporte DRM
EOF

if [[ $DRY_RUN -eq 1 ]]; then
  ok "(dry-run) nada fue modificado"
  exit 0
fi

# --- copiar el árbol al objetivo remoto si aplica ---
SRC_TREE="$WORK/root"
if [[ -n "$TARGET" ]]; then
  info "Copiando árbol extraído a $TARGET ..."
  ssh -o BatchMode=yes "$TARGET" 'rm -rf /tmp/rd-unatt-root'
  scp -q -o BatchMode=yes -r "$WORK/root" "$TARGET:/tmp/rd-unatt-root"
  SRC_TREE="/tmp/rd-unatt-root"
  ok "copiado"
fi

# --- script de instalación que corre como root ---
read -r -d '' INSTALL_SCRIPT <<'EOS' || true
set -euo pipefail
SRC="$1"
TS="$(date +%s)"
BK="/root/rustdesk-backup-$TS"

echo "→ Respaldo en $BK"
mkdir -p "$BK"
[ -d /usr/share/rustdesk ] && cp -a /usr/share/rustdesk "$BK/"
rpm -qa rustdesk > "$BK/rpm-list.txt" 2>/dev/null || true
cp -a /usr/lib/systemd/system/rustdesk.service "$BK/" 2>/dev/null || true

echo "→ Reemplazando /usr/share/rustdesk/"
rm -rf /usr/share/rustdesk
cp -a "$SRC/usr/share/rustdesk" /usr/share/rustdesk

echo "→ Instalando libdrmtap (capturador DRM)"
mkdir -p /usr/lib/rustdesk
cp -a "$SRC"/usr/lib/rustdesk/libdrmtap.so* /usr/lib/rustdesk/

echo "→ Enlazando ejecutable"
ln -sf /usr/share/rustdesk/rustdesk /usr/bin/rustdesk

# Clave en Fedora: el árbol viene de /tmp (dueño jp, contexto user_tmp_t).
# Restaurar root:root y SELinux o systemd falla con 203/EXEC (Permission denied).
echo "→ Corrigiendo dueño y contextos SELinux"
chown -R root:root /usr/share/rustdesk /usr/lib/rustdesk
type -P restorecon >/dev/null 2>&1 && restorecon -R /usr/share/rustdesk /usr/lib/rustdesk /usr/bin/rustdesk 2>/dev/null || true

echo "→ Instalando servicio"
SVC=/etc/systemd/system/rustdesk.service
if [ -f /usr/share/rustdesk/files/systemd/rustdesk.service ]; then
  cp -a /usr/share/rustdesk/files/systemd/rustdesk.service "$SVC"
fi
sed -i 's|ExecStop=pkill|ExecStop=/usr/bin/pkill|' "$SVC" 2>/dev/null || true
systemctl daemon-reload
systemctl restart rustdesk
sleep 3
echo "→ rustdesk.service: $(systemctl is-active rustdesk)"
echo "→ libdrmtap presente: $(ls /usr/lib/rustdesk/libdrmtap.so.* 2>/dev/null | head -1)"
EOS

info "Instalando (requiere sudo)..."
run_root "$SRC_TREE" <<<"$INSTALL_SCRIPT"

ok "Instalación completa"
warn "Contraseña permanente: si quedó vacía, aplicala con ./rustdesk-password.sh install"
info "Conectate por RustDesk y verificá en el log de captura:"
info "  drm: consumer cache warmed (N displays) at startup"
