#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# make-kit.sh — empaqueta el kit para llevarlo a un cliente (presencial)
#
# Produce un directorio (o tar.gz / pendrive) autocontenido con TODO lo necesario
# para preparar el PC de un cliente estando delante de él, SIN depender de
# internet para traer el kit (solo para descargar paquetes del sistema).
#
# Contenido del paquete:
#   instalar-todo.sh       ← UN SOLO COMANDO: hace todo lo de abajo
#   INSTALAR.md            ← runbook: qué hacer paso a paso, en orden
#   setup-remote-target.sh ← RustDesk unattended + sshd + firewall + Tailscale
#   inventory.sh           ← inventario de specs (para la ficha del cliente)
#   rustdesk-password.sh   ← fija la contraseña permanente de RustDesk
#   install-rustdesk-unattended-fedora.sh  (Fedora/RHEL)
#   .rd-setpass-root.sh    ← auxiliar de rustdesk-password.sh
#   verify-offlan.sh       ← prueba el acceso desde fuera de la LAN
#   make-kit.sh            ← para regenerar el kit desde el propio pendrive
#   tests.sh               ← verificación
#   MANIFEST.sha256        ← integridad del paquete
#
# Uso:
#   ./make-kit.sh                      # crea ./kit-rustdesk/
#   ./make-kit.sh --dest /run/media/jp/PENDRIVE
#   ./make-kit.sh --tarball            # además, kit-rustdesk.tar.gz
#   ./make-kit.sh --with-key            # incluye tu clave pública (~/.ssh/id_ed25519.pub)
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$SCRIPT_DIR/kit-rustdesk"
TARBALL=0
WITH_KEY=0
KEYFILE="${KEYFILE:-$HOME/.ssh/id_ed25519.pub}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)     DEST="${2:-}"; shift 2 ;;
    --tarball)  TARBALL=1; shift ;;
    --with-key) WITH_KEY=1; shift ;;
    -h|--help)  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "opción desconocida: $1" >&2; exit 2 ;;
  esac
done

info() { printf '\033[1;34m●\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m▲\033[0m %s\n' "$*"; }

FILES=(
  instalar-todo.sh
  setup-remote-target.sh
  inventory.sh
  rustdesk-password.sh
  install-rustdesk-unattended-fedora.sh
  .rd-setpass-root.sh
  verify-offlan.sh
  make-kit.sh
  tests.sh
)

info "Destino: $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"

for f in "${FILES[@]}"; do
  [[ -f "$SCRIPT_DIR/$f" ]] || { echo "falta $f" >&2; exit 1; }
  cp -a "$SCRIPT_DIR/$f" "$DEST/$f"
done
chmod +x "$DEST"/*.sh

# --- runbook: INSTALAR.md (detalle) + PASOS-EN-ORDEN.txt (checklist) ---
# Fuente única de verdad: los del repo. Si no existen, se avisa.
for doc in INSTALAR.md PASOS-EN-ORDEN.txt REPO.txt; do
  if [[ -f "$SCRIPT_DIR/$doc" ]]; then
    cp -a "$SCRIPT_DIR/$doc" "$DEST/$doc"
  else
    echo "error: falta $doc en el repo (es documentación del kit)" >&2
    exit 1
  fi
done

# --- LEEME-PRIMERO.txt: también en la raíz del pendrive si el destino es uno ---
# El pendrive tiene el kit en una subcarpeta; el LEEME va al lado, para que se
# vea al abrirlo. Se copia a la raíz del disco que contiene el destino.
if [[ -f "$SCRIPT_DIR/LEEME-PRIMERO.txt" ]]; then
  cp -a "$SCRIPT_DIR/LEEME-PRIMERO.txt" "$DEST/LEEME-PRIMERO.txt"
  KIT_PARENT="$(dirname "$DEST")"
  # Solo si el destino está dentro de un punto de montaje (/run/media, /mnt)
  case "$KIT_PARENT" in
    /run/media/*|/mnt/*|/media/*)
      cp -a "$SCRIPT_DIR/LEEME-PRIMERO.txt" "$KIT_PARENT/LEEME-PRIMERO.txt" 2>/dev/null || true
      cp -a "$SCRIPT_DIR/PASOS-EN-ORDEN.txt" "$KIT_PARENT/PASOS-EN-ORDEN.txt" 2>/dev/null || true
      cp -a "$SCRIPT_DIR/REPO.txt" "$KIT_PARENT/REPO.txt" 2>/dev/null || true
      ;;
  esac
fi


# --- clave pública del operador (opcional) ---
if [[ $WITH_KEY -eq 1 ]]; then
  if [[ -f "$KEYFILE" ]]; then
    cp -a "$KEYFILE" "$DEST/operador.pub"
    ok "Clave pública incluida: operador.pub"
  else
    warn "No encontré $KEYFILE; el paquete va sin clave (usá --with-key tras crearla)"
  fi
fi

# --- manifiesto de integridad ---
(
  set +e   # el último [[ -f ]] puede devolver 1 y matar el subshell con set -e
  cd "$DEST"
  shopt -s nullglob
  for f in *.sh *.md *.txt operador.pub .kit-version; do
    [[ -f "$f" ]] && sha256sum "$f"
  done > MANIFEST.sha256
  exit 0
)
nfiles="$(wc -l < "$DEST/MANIFEST.sha256" | tr -d ' ')"
ok "MANIFEST.sha256 generado (${nfiles} archivos)"

# --- versión del kit (#6 del reporte) ---
# Sirve para depurar desde fuera: "¿qué versión del kit corrió ese cliente?".
# Se toma del tag/commit de git; si no hay repo, de la fecha.
KIT_VER="$(git -C "$SCRIPT_DIR" describe --tags --always --dirty 2>/dev/null || date +%Y%m%d-%H%M)"
KIT_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
  echo "kit_version=$KIT_VER"
  echo "built_at=$KIT_DATE"
  echo "repo=https://github.com/juanpablofuentealba/rustdesk-wlan-ssh-pi"
} > "$DEST/.kit-version"
ok "Versión del kit: $KIT_VER"

if [[ $TARBALL -eq 1 ]]; then
  tar -czf "$SCRIPT_DIR/kit-rustdesk.tar.gz" -C "$(dirname "$DEST")" "$(basename "$DEST")"
  tsize="$(du -h "$SCRIPT_DIR/kit-rustdesk.tar.gz" | cut -f1)"
  ok "Tarball: $SCRIPT_DIR/kit-rustdesk.tar.gz ($tsize)"
fi

echo
ok "Kit listo en: $DEST"
info "Contenido:"
find "$DEST" -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | sort | sed 's/^/    /'
info "Copialo a un pendrive:  cp -r '$DEST' /run/media/\$USER/PENDRIVE/"
