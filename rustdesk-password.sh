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

# Salida con formato. OJO: no llamar a estas funciones `info`, `test` ni `[`:
# `info` colisiona con el comando info(1) del sistema y rompe el script con
# "No menu item ... in node (dir)Top". Usamos `say`.
# --- helper de sudo con contraseña (H-68) ---------------------------------
# El manejo de sudo vive ahora en UN SOLO sitio (lib/sudo.sh, issue #28): así
# el bug H-68 (`sudo -S` se come stdin) no puede reaparecer por una copia
# distinta en cada script. Aquí conservamos `sudow` como alias de `sudo_run`
# para no romper llamadas existentes ni el comportamiento externo.
# shellcheck source=lib/sudo.sh
source "$SCRIPT_DIR/lib/sudo.sh"
# Alias histórico: sudow == sudo_run (clave por SUDO_ASKPASS, stdin libre).
sudow() { sudo_run "$@"; }

say()  { printf '\033[1;34m●\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
warnf() { printf '\033[1;33m▲\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m✘\033[0m %s\n' "$*" >&2; }
DRY_RUN=0

# --- PyNaCl: comprobar e instalar si falta --------------------------------
# Sin PyNaCl el hash no se puede generar. Antes fallaba tarde y con un
# ModuleNotFoundError de Python; ahora se comprueba antes y se ofrece instalarlo.
ensure_pynacl() {
  "$PY_BIN" -c 'import nacl.secret' 2>/dev/null && return 0

  local manager="" cmd=""
  if command -v pacman >/dev/null 2>&1; then manager=pacman; cmd="pacman -S --needed --noconfirm python-pynacl"
  elif command -v apt-get >/dev/null 2>&1; then manager=apt; cmd="apt-get install -y python3-nacl"
  elif command -v dnf >/dev/null 2>&1; then manager=dnf; cmd="dnf install -y python3-pynacl"
  fi

  if [[ -z "$manager" ]]; then
    err "falta PyNaCl y no reconozco el gestor de paquetes."
    err "  Instalalo a mano (paquete: python-pynacl / python3-nacl) y reintentá."
    return 1
  fi

  say "PyNaCl no está instalado; instalando con $manager..."
  if [[ $DRY_RUN -eq 1 ]]; then
    say "(dry-run) $cmd"
    return 0
  fi

  # Necesita root. Con SUDO_PASS declarado lo usamos; si no, sudo directo.
  if [[ $EUID -eq 0 ]]; then
    $cmd >/dev/null 2>&1 || { err "falló: $cmd"; return 1; }
  elif [[ -n "${SUDO_PASS:-}" ]]; then
    sudow bash -c "$cmd" >/dev/null 2>&1 \
      || { err "falló: $cmd"; return 1; }
  else
    sudo bash -c "$cmd" >/dev/null 2>&1 || { err "falló: $cmd (probá con SUDO_PASS)"; return 1; }
  fi

  if "$PY_BIN" -c 'import nacl.secret' 2>/dev/null; then
    ok "PyNaCl instalado"
    return 0
  fi
  err "seguimos sin PyNaCl tras instalarlo."
  err "  Probá a mano:  $cmd"
  return 1
}

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
  # SUDO_PASS vacío pero DECLARADO (SUDO_PASS=) significa "sudo sin contraseña"
  # (NOPASSWD). Solo es error si la variable no está declarada en absoluto.
  if [[ -z "${SUDO_PASS+x}" && "$dry" != "--dry-run" ]]; then
    echo "error: definí SUDO_PASS." >&2
    echo "  · con contraseña:  SUDO_PASS='clave' $0 install ..." >&2
    echo "  · sin contraseña:  SUDO_PASS= $0 install ...   (NOPASSWD)" >&2
    echo "  · solo simular:    $0 install ... --dry-run" >&2
    return 1
  fi
  # ¿El target es ESTE equipo? Entonces no hace falta SSH.
  # Motivo: al correr con sudo no hay clave SSH para llegar a jp@localhost, así
  # que fallaba con "Host key verification failed" o "Permission denied".
  # Además el caso local es el más común (instalación presencial del kit).
  local is_local=0
  case "$target" in
    *localhost*|*127.0.0.1*|*"$(hostname 2>/dev/null)"*) is_local=1 ;;
  esac
  [[ "$target" == "$(whoami)@$HOSTNAME" || "$target" == "$(whoami)@localhost" ]] && is_local=1

  echo "→ Leyendo machine-id ..."
  local mid
  if [[ $is_local -eq 1 ]]; then
    mid="$(cat /etc/machine-id 2>/dev/null)"
    say "modo LOCAL (sin SSH): aplico en este mismo equipo"
  else
    mid="$(ssh -o BatchMode=yes "$target" cat /etc/machine-id 2>/dev/null)"
  fi
  [[ -n "$mid" ]] || { echo "error: no pude leer el machine-id" >&2; return 1; }
  ensure_pynacl || return 1

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

  echo "→ Aplicando (con backup) ..."
  local sudo_pass="${SUDO_PASS:-}"
  local helper="$SCRIPT_DIR/.rd-setpass-root.sh"
  [[ -f "$helper" ]] || { echo "error: falta $helper" >&2; return 1; }

  # El salt/storage van por STDIN, no como argumentos de línea de comandos:
  # así no aparecen en `ps` mientras corre (P2 del reporte).
  if [[ $is_local -eq 1 ]]; then
    # --- LOCAL: sin SSH, sin scp ---
    # OJO (H-68): NO se puede mezclar la contraseña de sudo con los datos en el
    # mismo stdin. `sudo -S` lee la clave de stdin con buffering y se lleva
    # (parte de) el salt/storage, dejando al helper sin datos → `read` falla y
    # con `set -e` el helper aborta. La contraseña de RustDesk NUNCA se aplicaba
    # en modo local, silenciosamente.
    #
    # Solución robusta: dar la clave a sudo por SUDO_ASKPASS (un fd aparte),
    # dejando stdin libre para salt/storage. Así los datos llegan intactos.
    if [[ -n "$sudo_pass" ]]; then
      # La clave de sudo va por SUDO_ASKPASS (ver sudow): así stdin queda libre
      # para salt/storage y el helper los recibe intactos.
      printf '%s\n%s\n' "$salt" "$storage" | sudow bash "$helper" --stdin \
        || { err "falló la escritura de la config (¿sudo?)"; return 1; }
    else
      printf '%s\n%s\n' "$salt" "$storage" | sudo -n bash "$helper" --stdin \
        || { err "falló la escritura de la config (¿sudo?)"; return 1; }
    fi
  else
    # --- REMOTO: helper por scp, args por stdin ---
    # NO usamos `bash -s < archivo`: sudo -S lee la contraseña de stdin.
    scp -q -o BatchMode=yes "$helper" "$target:/tmp/rd-setpass-root.sh"
    # Trap: si algo falla de aquí en adelante (sudo mal, corte de red), el
    # helper no debe quedar en el /tmp del cliente.
    # OJO: $target es 'local' de esta función; el trap EXIT corre al SALIR, con
    # la función ya desmontada. Hay que incrustar el valor AHORA (no diferir el
    # "$target"), o con set -u revienta con "target: variable sin asignar".
    # shellcheck disable=SC2064
    trap "ssh -o BatchMode=yes $(printf '%q' "$target") 'rm -f /tmp/rd-setpass-root.sh' 2>/dev/null || true" EXIT
    if [[ -n "$sudo_pass" ]]; then
      # remote_sudo_run sube la clave por un askpass (no por el stdin que
      # llevan salt/storage) => H-68 imposible también en remoto (issue #28).
      # SUDO_PASS ya está declarada (la exige install_remote), así que el
      # helper la toma de ahí sin más.
      printf '%s\n%s\n' "$salt" "$storage" | \
        remote_sudo_run "$target" "bash /tmp/rd-setpass-root.sh --stdin" \
        || { err "falló la escritura de la config remota (¿contraseña de sudo incorrecta?)"; \
             err "  verificala a mano:  ssh $target 'sudo true'"; \
             ssh -o BatchMode=yes "$target" 'rm -f /tmp/rd-setpass-root.sh' 2>/dev/null || true; return 1; }
    else
      printf '%s\n%s\n' "$salt" "$storage" | \
        ssh -o BatchMode=yes "$target" "sudo -n bash /tmp/rd-setpass-root.sh --stdin" \
        || { err "falló la escritura de la config remota (¿sudo NOPASSWD no configurado?)"; \
             err "  probá con:  SUDO_PASS='clave' $0 install $target <password>"; \
             ssh -o BatchMode=yes "$target" 'rm -f /tmp/rd-setpass-root.sh' 2>/dev/null || true; return 1; }
    fi
    # Limpiar SIEMPRE el helper del /tmp del objetivo, aunque sudo fallara:
    # aquí (caso normal) y en el trap de salida (casos de error).
    ssh -o BatchMode=yes "$target" 'rm -f /tmp/rd-setpass-root.sh' 2>/dev/null || true
  fi

  echo "→ Reiniciando rustdesk.service ..."
  if [[ $is_local -eq 1 ]]; then
    if [[ -n "$sudo_pass" ]]; then
      sudow systemctl restart rustdesk && sleep 2 && systemctl is-active rustdesk
    else
      sudo -n systemctl restart rustdesk && sleep 2 && systemctl is-active rustdesk
    fi
  elif [[ -n "$sudo_pass" ]]; then
    # remote_sudo_run: clave por askpass, stdin libre (issue #28).
    remote_sudo_run "$target" \
      "systemctl restart rustdesk && sleep 2 && systemctl is-active rustdesk"
  else
    ssh -o BatchMode=yes "$target" \
      "sudo -n systemctl restart rustdesk && sleep 2 && systemctl is-active rustdesk"
  fi

  echo "→ Verificación (contraseña = '01...'):"
  # OJO (H-23): no mandar `bash -c` con comillas anidadas por SSH (el shell
  # remoto puede ser fish y rompe el string). Se usa `bash -s` por STDIN.
  # Para sudo se usa -n (sin contraseña): el timestamp global (timestamp_type=global)
  # ya suele estar activo tras el reinicio del servicio. Si pide contraseña,
  # se avisa y se omite la verificación de root (no es crítica: el config de
  # usuario siempre se verifica).
  local vercmd="grep -c '^password = '\''01' /root/.config/rustdesk/RustDesk.toml"
  local jpcfg="$HOME/.config/rustdesk/RustDesk.toml"
  local rootn
  if [[ $is_local -eq 1 ]]; then
    rootn="$(sudow bash -s <<<"$vercmd" 2>/dev/null || echo '?')"
    grep -c "^password = '01" "$jpcfg" 2>/dev/null | sed 's/^/  líneas password=01 en config jp:   /'
  else
    rootn="$(ssh -o BatchMode=yes "$target" 'sudo -n bash -s' <<<"$vercmd" 2>/dev/null || echo '?')"
    ssh -o BatchMode=yes "$target" "grep -c \"^password = '01\" '$jpcfg' 2>/dev/null" \
      | sed 's/^/  líneas password=01 en config jp:   /'
  fi
  if [[ "$rootn" == "?" || -z "$rootn" ]]; then
    warnf "no se pudo verificar el config de root (sudo pidió contraseña)"
    say  "verificá a mano: sudo grep -c \"^password = '01\" /root/.config/rustdesk/RustDesk.toml"
  else
    printf '  líneas password=01 en config root: %s\n' "$rootn"
  fi
  echo "✔ Listo. Probá conectar por RustDesk a la ID del equipo."
}

case "${1:-}" in
  hash)    shift; gen_hash "$@" ;;
  salt)    gen_salt ;;
  install) shift; install_remote "$@" ;;
  ""|-h|--help|help) usage ;;
  *) echo "error: comando desconocido: $1" >&2; usage; exit 1 ;;
esac
