#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# rustdesk-password.sh — genera el hash de contraseña permanente de RustDesk
#
# Por qué existe:
#   RustDesk (>= 1.5) NO expone un flag CLI para fijar la contraseña permanente
#   (`rustdesk --password` no existe; la GUI es la única vía oficial). Fijarla a
#   mano es imprescindible para el acceso DESATENDIDO: sin contraseña permanente
#   cada conexión pide aceptación o contraseña temporal.
#
# Formato exacto de RustDesk 1.5.0 (verificado en el código fuente:
#   libs/hbb_common/src/config/permanent_password.rs + password_security.rs):
#
#     salt    = 32 caracteres aleatorios           (DEFAULT_SALT_LEN = 32)
#     h1      = SHA256(password || salt)           (32 bytes)
#     inner   = "00" + base64_original(h1)         (PASSWORD_HASH_PREFIX)
#     key     = machine_uid() padded a 32 bytes    (= /etc/machine-id en Linux)
#     sealed  = FORMAT_V1(0x01) || nonce(24B) || secretbox_seal(inner, nonce, key)
#     storage = "01" + base64_original(sealed)     (PERMANENT_PASSWORD_ENC_VERSION)
#
#   Se escribe `storage` en  RustDesk.toml -> password = '<storage>'
#                          RustDesk.toml -> salt     = '<salt>'
#
# Uso:
#   ./rustdesk-password.sh hash  <password> <machine-id> [salt]
#   ./rustdesk-password.sh salt
#   SUDO_PASS=<clave-sudo> ./rustdesk-password.sh install <usuario@host> <password> [--dry-run]
#
# Requiere: python3 + PyNaCl  (pacman -S python-pynacl)
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_BIN="${PY_BIN:-python3}"

# --- generación del hash ---------------------------------------------------
gen_hash() {
  local password="$1" machine_id="$2" salt="${3:-}"
  if [[ -z "$password" ]]; then
    echo "error: la contraseña no puede estar vacía" >&2
    return 1
  fi
  if [[ -z "$machine_id" ]]; then
    echo "error: falta el machine-id (leé /etc/machine-id en el equipo objetivo)" >&2
    return 1
  fi
  "$PY_BIN" - "$password" "$machine_id" "$salt" <<'PYEOF'
import base64, hashlib, secrets, string, sys

password, machine_id, salt = sys.argv[1], sys.argv[2], sys.argv[3]

# salt: 32 chars alfanuméricos si no se provee (DEFAULT_SALT_LEN = 32)
if not salt:
    alphabet = string.ascii_letters + string.digits
    salt = "".join(secrets.choice(alphabet) for _ in range(32))

# key = machine_uid() padded a 32 bytes (machine_uid en Linux == /etc/machine-id)
key = machine_id.encode()[:32].ljust(32, b"\x00")

# h1 = SHA256(password || salt)  ->  inner = "00" + base64(h1)
h1 = hashlib.sha256(password.encode() + salt.encode()).digest()
inner = "00" + base64.b64encode(h1).decode()

try:
    from nacl.secret import SecretBox
except ImportError:
    sys.exit("error: falta PyNaCl (pacman -S python-pynacl)")

box = SecretBox(key)
nonce = secrets.token_bytes(24)
sealed = bytes([1]) + nonce + box.encrypt(inner.encode(), nonce).ciphertext
storage = "01" + base64.b64encode(sealed).decode()

print(f"SALT={salt}")
print(f"PASSWORD={storage}")
PYEOF
}

# --- salt suelto -----------------------------------------------------------
gen_salt() {
  "$PY_BIN" - <<'PYEOF'
import secrets, string
print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(32)))
PYEOF
}

usage() {
  cat <<'EOF'
rustdesk-password.sh — hash de contraseña permanente de RustDesk (>= 1.5)

  hash <password> <machine-id> [salt]   imprime SALT= / PASSWORD= (stdout)
  salt                                  imprime un salt nuevo de 32 chars
  install <usuario@host> <password> [--dry-run]
                                        lee el machine-id remoto, genera el
                                        hash y lo aplica por SSH (backup previo)

Ejemplos:
  ./rustdesk-password.sh salt
  MID=$(ssh jp@192.168.122.11 cat /etc/machine-id)
  ./rustdesk-password.sh hash 'MiClave2026' "$MID"
  ./rustdesk-password.sh install jp@192.168.122.11 'MiClave2026'
EOF
}

# --- instalación remota ----------------------------------------------------
install_remote() {
  local target="$1" password="$2" dry="${3:-}"
  if [[ -z "${SUDO_PASS:-}" && "$dry" != "--dry-run" ]]; then
    echo "error: definí SUDO_PASS (contraseña de sudo del objetivo) o usá --dry-run" >&2
    return 1
  fi
  echo "→ Leyendo machine-id de $target ..."
  local mid
  mid="$(ssh -o BatchMode=yes "$target" cat /etc/machine-id)"
  [[ -n "$mid" ]] || { echo "error: no pude leer el machine-id remoto" >&2; return 1; }

  echo "→ Generando hash ..."
  local out salt storage
  out="$(gen_hash "$password" "$mid")"
  salt="$(sed -n 's/^SALT=//p' <<<"$out")"
  storage="$(sed -n 's/^PASSWORD=//p' <<<"$out")"

  local cfg="\$HOME/.config/rustdesk/RustDesk.toml"
  if [[ "$dry" == "--dry-run" ]]; then
    echo "[dry-run] machine-id: $mid"
    echo "[dry-run] salt:        $salt"
    echo "[dry-run] storage:     ${storage:0:40}... (${#storage} chars)"
    echo "[dry-run] se escribiría en $cfg (sin cambios)"
    return 0
  fi

  echo "→ Aplicando en $target (con backup) ..."
  local sudo_pass="${SUDO_PASS:-}"
  # El script auxiliar va como archivo (más fiable que un heredoc por stdin,
  # que sudo -S se come al leer la contraseña).
  local helper="$SCRIPT_DIR/.rd-setpass-root.sh"
  [[ -f "$helper" ]] || { echo "error: falta $helper" >&2; return 1; }

  # Copiamos el helper al objetivo y lo ejecutamos con sudo. NO usamos
  # `bash -s < archivo`: sudo -S lee la contraseña de stdin y compiten.
  scp -q -o BatchMode=yes "$helper" "$target:/tmp/rd-setpass-root.sh"
  printf '%s\n' "$sudo_pass" | ssh -o BatchMode=yes "$target" \
    "sudo -S -p '' bash /tmp/rd-setpass-root.sh '$salt' '$storage'"
  ssh -o BatchMode=yes "$target" 'rm -f /tmp/rd-setpass-root.sh' || true

  echo "→ Reiniciando rustdesk.service ..."
  printf '%s\n' "$sudo_pass" | ssh -o BatchMode=yes "$target" \
    "sudo -S -p '' systemctl restart rustdesk && sleep 2 && systemctl is-active rustdesk"

  echo "→ Verificación (config root debe tener password = '01...'):"
  printf '%s\n' "$sudo_pass" | ssh -o BatchMode=yes "$target" \
    "sudo -S -p '' grep -c \"^password = '01\" /root/.config/rustdesk/RustDesk.toml" \
    | sed 's/^/  líneas password=01 en config root: /'
  echo "✔ Listo. Probá conectar por RustDesk a la ID del equipo."
}

case "${1:-}" in
  hash)    shift; gen_hash "$@" ;;
  salt)    gen_salt ;;
  install) shift; install_remote "$@" ;;
  ""|-h|--help|help) usage ;;
  *) echo "error: comando desconocido: $1" >&2; usage; exit 1 ;;
esac
