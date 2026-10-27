#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# .rd-setpass-root.sh — escribe password+salt en las configs de RustDesk.
# Auxiliar de rustdesk-password.sh. Corre como root.
#
# Uso:
#   bash .rd-setpass-root.sh --stdin              # salt y storage por stdin
#   bash .rd-setpass-root.sh --stdin-with-pass    # sudo_pass, salt, storage
#   bash .rd-setpass-root.sh <salt> <storage>     # compatibilidad (args)
#
# Por qué stdin: los argumentos de línea de comandos son visibles en `ps`
# mientras el proceso corre. Por stdin (fd) no quedan expuestos.
#
# Alcance: por defecto escribe solo en /root y en el HOME del usuario que
# invocó (SUDO_USER). Para todos los usuarios de /home/*  -> --all-users.
#
# PRUEBAS SIN RIESGO (evita sobrescribir la config real):
#   RDP_CONFIG_ROOT=/tmp/prueba RDP_HOME_BASE=/tmp/prueba/home \
#     bash .rd-setpass-root.sh --stdin
# ---------------------------------------------------------------------------
set -euo pipefail

ALL_USERS=0
SALT=""
STORAGE=""

case "${1:-}" in
  --stdin)
    IFS= read -r SALT
    IFS= read -r STORAGE
    ;;
  --stdin-with-pass)
    IFS= read -r _SUDO_PASS   # ya lo consumió sudo; se lee para no desalinear
    IFS= read -r SALT
    IFS= read -r STORAGE
    ;;
  --all-users) ALL_USERS=1 ;;
  "") echo "error: falta salt/storage (usá --stdin)" >&2; exit 2 ;;
  *) SALT="$1"; STORAGE="${2:-}" ;;
esac

[[ -n "$SALT" && -n "$STORAGE" ]] || { echo "error: salt o storage vacío" >&2; exit 2; }

apply() {
  local dir="$1"
  local f="$dir/RustDesk.toml"
  if [[ ! -f "$f" ]]; then
    echo "  (omitido: no existe $f)"
    return 0
  fi
  # Backup con sufijo único (date +%s colisiona si dos corridas caen en el
  # mismo segundo y la segunda pisa a la primera) y rotación: se conservan los
  # 3 más recientes para no acumular archivos sin fin en el cliente.
  local bk
  bk="$(mktemp -u "$f.bak-XXXXXXXX")"
  cp -a "$f" "$bk"
  ls -1t "$f".bak-* 2>/dev/null | tail -n +4 | xargs -r rm -f 2>/dev/null || true

  # salt/storage por variables de entorno, no como argv de python (no aparecen
  # en /proc/<pid>/cmdline).
  RDP_SALT="$SALT" RDP_STORAGE="$STORAGE" "$PY" - "$f" <<'PYEOF'
import os, re, sys
path = sys.argv[1]
salt = os.environ["RDP_SALT"]
storage = os.environ["RDP_STORAGE"]
text = open(path).read()
def setkey(text, key, value):
    pat = re.compile(rf"^{key}\s*=.*$", re.M)
    line = f"{key} = '{value}'"
    return pat.sub(line, text) if pat.search(text) else text.rstrip() + "\n" + line + "\n"
text = setkey(text, "password", storage)
text = setkey(text, "salt", salt)
open(path, "w").write(text)
PYEOF
  echo "  ✔ actualizado $f (backup .bak-*)"
}

PY="${PY_BIN:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python3

# RDP_CONFIG_ROOT permite redirigir las rutas para PRUEBAS sin tocar el sistema
# real (p.ej. RDP_CONFIG_ROOT=/tmp/prueba). Sin esta variable, una prueba
# descuidada sobrescribe la config real del operador.
ROOT_CFG="${RDP_CONFIG_ROOT:-/root}/.config/rustdesk"
USER_HOME_BASE="${RDP_HOME_BASE:-/home}"

# 1. siempre la config de root (es la que usa rustdesk.service)
apply "$ROOT_CFG"

# 2. el usuario objetivo
if [[ $ALL_USERS -eq 1 ]]; then
  for h in "$USER_HOME_BASE"/*; do
    [[ -d "$h/.config/rustdesk" ]] || continue
    apply "$h/.config/rustdesk"
    chown "$(stat -c %U:%G "$h")" "$h/.config/rustdesk/RustDesk.toml" 2>/dev/null || true
  done
else
  # solo el usuario que invocó sudo (el resto no debería tocarse)
  TU="${SUDO_USER:-}"
  if [[ -z "$TU" || "$TU" == "root" ]]; then
    TU="$(logname 2>/dev/null || true)"
  fi
  if [[ -n "$TU" && -d "$USER_HOME_BASE/$TU/.config/rustdesk" ]]; then
    apply "$USER_HOME_BASE/$TU/.config/rustdesk"
    chown "$TU:$(id -gn "$TU" 2>/dev/null || echo "$TU")" \
      "$USER_HOME_BASE/$TU/.config/rustdesk/RustDesk.toml" 2>/dev/null || true
  else
    echo "  (sin HOME de usuario objetivo; usá --all-users para incluir todos)"
  fi
fi
