#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# make-kit.sh — empaqueta el kit para llevarlo a un cliente (presencial)
#
# Produce un directorio (o tar.gz / pendrive) autocontenido con TODO lo necesario
# para preparar el PC de un cliente estando delante de él, SIN depender de
# internet para traer el kit (solo para descargar paquetes del sistema).
#
# Contenido del paquete:
#   INSTALAR.md            ← runbook: qué hacer paso a paso, en orden
#   setup-remote-target.sh ← RustDesk unattended + sshd + firewall + Tailscale
#   inventory.sh           ← inventario de specs (para la ficha del cliente)
#   rustdesk-password.sh   ← fija la contraseña permanente de RustDesk
#   install-rustdesk-unattended-fedora.sh  (Fedora/RHEL)
#   .rd-setpass-root.sh    ← auxiliar de rustdesk-password.sh
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
  setup-remote-target.sh
  inventory.sh
  rustdesk-password.sh
  install-rustdesk-unattended-fedora.sh
  .rd-setpass-root.sh
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

# --- runbook INSTALAR.md ---
cat > "$DEST/INSTALAR.md" <<'RUNBOOK'
# Preparar el PC de un cliente (presencial)

> Este paquete tiene todo lo necesario. No necesitás internet para traer el kit;
> sí lo vas a necesitar para que se descarguen los paquetes del sistema.

## Antes de salir (en tu PC)

- [ ] Copiar este kit a un pendrive
- [ ] Tener a mano tu **clave pública SSH** (`cat ~/.ssh/id_ed25519.pub`)
- [ ] Pedirle al cliente una **auth key de Tailscale** (modelo B):
      `https://console.tailscale.com/admin/settings/keys`
      → Reusable: **NO** · Ephemeral: **NO** · Expiry: **1 día**
- [ ] Definir la **contraseña permanente de RustDesk** para ese equipo

## En casa del cliente

### 0. Copiar el kit al PC

```bash
# desde el pendrive (ajustá el punto de montaje)
cp -r /run/media/$USER/PENDRIVE/kit-rustdesk ~/kit
cd ~/kit
```

### 1. Diagnóstico (no cambia nada)

```bash
./setup-remote-target.sh --check
```

Anotá: familia de distro, si hay firewall, si el RustDesk ya está instalado y el
tipo de sesión (Wayland/X11).

### 2. Inventario de specs (para la ficha del cliente)

```bash
./inventory.sh | tee fichas/<cliente>-$(date +%F).txt
```

### 3. RustDesk con contraseña permanente

```bash
# 3a. fijar la contraseña permanente (imprescindible para desatendido)
SUDO_PASS='<clave-sudo>' ./rustdesk-password.sh install "$USER@localhost" '<password>'
#     (con el equipo delante, el "install" remoto también sirve a localhost)

# 3b. en Fedora/RHEL, instalar el paquete con capturador DRM
sudo ./install-rustdesk-unattended-fedora.sh
#     en Arch/CachyOS: paru -S rustdesk-unattended-wayland
#     en Debian/Mint:  el .deb oficial (lo hace setup-remote-target.sh --rustdesk)
```

### 4. SSH + firewall + tu clave + Tailscale

```bash
sudo ./setup-remote-target.sh --all \
  --key "$(cat ~/.ssh/id_ed25519.pub)" \
  --authkey 'tskey-auth-XXXX'
```

### 5. Verificar

```bash
./tests.sh "$USER@localhost"          # suite de humo
sudo tail -20 /var/lib/plasmalogin/.local/share/logs/RustDesk/server/rustdesk_rCURRENT.log
#     debe aparecer: drm: consumer cache warmed (N displays) at startup
```

### 6. Entregar al cliente

- [ ] Mostrarle que el equipo aparece en SU panel de Tailscale
- [ ] Explicarle que puede revocarlo cuando quiera (Machines → Disable)
- [ ] Dejarle la contraseña permanente de RustDesk en un papel/gestor suyo
- [ ] Completa la ficha con el checklist de `docs/onboarding-cliente.md`

## Verificar la integridad del paquete

```bash
sha256sum -c MANIFEST.sha256
```
RUNBOOK

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
  for f in *.sh *.md operador.pub; do
    [[ -f "$f" ]] && sha256sum "$f"
  done > MANIFEST.sha256
  exit 0
)
nfiles="$(wc -l < "$DEST/MANIFEST.sha256" | tr -d ' ')"
ok "MANIFEST.sha256 generado (${nfiles} archivos)"

if [[ $TARBALL -eq 1 ]]; then
  tar -czf "$SCRIPT_DIR/kit-rustdesk.tar.gz" -C "$(dirname "$DEST")" "$(basename "$DEST")"
  tsize="$(du -h "$SCRIPT_DIR/kit-rustdesk.tar.gz" | cut -f1)"
  ok "Tarball: $SCRIPT_DIR/kit-rustdesk.tar.gz ($tsize)"
fi

echo
ok "Kit listo en: $DEST"
info "Contenido:"
ls -1 "$DEST" | sed 's/^/    /'
info "Copialo a un pendrive:  cp -r '$DEST' /run/media/\$USER/PENDRIVE/"
