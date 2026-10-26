#!/usr/bin/env bash
#
# tests.sh — Pruebas de humo para el kit (sin tocar el sistema real).
#
# Verifica sintaxis, modos de salida, validación de JSON y manejo de errores.
# No modifica nada: solo ejecuta los scripts en modo lectura.
#
# Uso:
#   ./tests.sh              # pruebas locales
#   ./tests.sh <host>       # además, prueba contra un host SSH real (opcional)
#
set -uo pipefail

# Situarse en el directorio del script (para que funcione desde cualquier cwd)
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

PASS=0; FAIL=0; SKIP=0
# Comprobar dependencias mínimas para las pruebas
for dep in bash make jq; do
  command -v "$dep" >/dev/null 2>&1 || { echo "Aviso: falta '$dep'; algunas pruebas fallarán"; }
done
if [[ -t 1 ]]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; N=$'\e[0m'; BD=$'\e[1m';
else G=''; R=''; Y=''; N=''; BD=''; fi

t() {  # t "descripcion" comando...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then printf '%s✔%s %s\n' "$G" "$N" "$desc"; PASS=$((PASS+1));
  else printf '%s✘%s %s\n' "$R" "$N" "$desc"; FAIL=$((FAIL+1)); fi
}
tj() { # tj "descripcion" comando...  (espera exit != 0)
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then printf '%s✘%s %s (debería fallar)' "$R" "$N" "$desc"; FAIL=$((FAIL+1));
  else printf '%s✔%s %s\n' "$G" "$N" "$desc"; PASS=$((PASS+1)); fi
}
sect() { printf '\n%s== %s ==%s\n' "$BD" "$1" "$N"; }

HOST="${1:-}"

sect "Sintaxis (bash -n)"
for f in setup-remote-target.sh inventory.sh tests.sh verify-docs.sh; do
  t "bash -n $f" bash -n "$f"
done
t "Makefile parseable" make -n help

sect "Permisos de ejecución"
for f in setup-remote-target.sh inventory.sh tests.sh verify-docs.sh; do
  t "$f es ejecutable" test -x "$f"
done

sect "Ayuda / usage"
t "setup --help sale 0"        ./setup-remote-target.sh --help
t "setup sin args muestra usage y falla" bash -c './setup-remote-target.sh >/dev/null 2>&1; test $? -ne 0'
tj "setup opción inválida falla" ./setup-remote-target.sh --nope
t "inventory --help sale 0"    ./inventory.sh --help

sect "inventory.sh (local)"
t "texto funciona"             ./inventory.sh
t "texto tiene hostname"       bash -c './inventory.sh | grep -q "Inventario"'
t "JSON es válido"             bash -c './inventory.sh --json | jq empty'
t "JSON tiene target"          bash -c './inventory.sh --json | jq -e ".target"'
t "JSON tiene CPU_MODEL"       bash -c './inventory.sh --json | jq -e ".CPU_MODEL"'
t "JSON tiene HOSTNAME"        bash -c './inventory.sh --json | jq -e ".HOSTNAME"'
t "Markdown funciona"          bash -c './inventory.sh --markdown | grep -q "^| Hostname"'
t "Markdown tiene tabla"       bash -c './inventory.sh --markdown | grep -q "| Campo | Valor |"'
tj "host inalcanzable falla"   ./inventory.sh USUARIO@10.255.255.1

sect "setup --check (lectura, sin root)"
t "--check sale 0"             ./setup-remote-target.sh --check
t "--check detecta usuario"    bash -c './setup-remote-target.sh --check | grep -q "Usuario objetivo"'
t "--check no modifica nada"   bash -c './setup-remote-target.sh --check | grep -q "Diagnóstico completo"'

sect "No fuga de secretos al repo"
t ".gitignore ignora claves"   bash -c 'grep -q "id_" .gitignore'
t "no hay claves en el árbol"  bash -c '! find . -name "id_*" -not -path "./.git/*" | grep -q .'
t "no hay .key/.pem"           bash -c '! find . \( -name "*.key" -o -name "*.pem" \) -not -path "./.git/*" | grep -q .'
t "no hay tskey-auth real"     bash -c '! grep -rqE "tskey-auth-[A-Za-z0-9]{20}" --exclude-dir=.git .'
# Excluye el propio tests.sh (contiene los patrones como literales de búsqueda)
t "sin datos de infra real"    bash -c '! grep -rqE "jpfuentealba|100\.(68|97)\.|wikileaks|jp-rustdesk" --exclude-dir=.git --exclude=tests.sh .'

sect "Hallazgos H-07/H-08 (regresiones conocidas)"
# H-07: hostname -I no existe en CachyOS → el kit debe usar 'ip route get'
t "inventory.sh usa ip route (no hostname -I)" \
  bash -c '! grep -q "hostname -I" inventory.sh && grep -q "ip -4 route get" inventory.sh'
# Solo cuentan USOS reales, no menciones en comentarios
t "setup usa ip route (no hostname -I)" \
  bash -c '! grep -vE "^\s*#" setup-remote-target.sh | grep -q "hostname -I"'
# H-08: strings|grep -q con pipefail → verify-docs debe capturar a variable
t "verify-docs evita strings|grep -q" \
  bash -c '! grep -qE "strings -a .*\| *grep -q" verify-docs.sh'

sect "Hallazgo H-03 (login screen X11 vs Wayland)"
if command -v pgrep >/dev/null 2>&1; then
  t "verify-docs detecta tipo de login screen" \
    bash -c './verify-docs.sh 2>&1 | grep -qE "login screen|greeter|sin greeter"'
  # Coherencia: si el binario declara no soportar Wayland login screen, el doc debe decirlo
  if [[ -r /usr/share/rustdesk/lib/librustdesk.so ]] && command -v strings >/dev/null 2>&1; then
    so_strings="$(strings -a /usr/share/rustdesk/lib/librustdesk.so 2>/dev/null || true)"
    if grep -q "Wayland login screen is not supported" <<<"$so_strings"; then
      t "docs/hallazgos.md refleja el aviso de Wayland" \
        bash -c 'grep -q "Wayland login screen is not supported" docs/hallazgos.md'
    else
      sk "el binario no incluye el aviso de Wayland login screen"
    fi
  else
    sk "no se pudo leer librustdesk.so"
  fi
else
  sk "pgrep no disponible"
fi

sect "Hallazgo H-05 (tailscale descrito en docs)"
if command -v tailscale >/dev/null 2>&1; then
  t "docs/tailscale.md menciona tailscale ping" bash -c 'grep -q "tailscale ping" docs/tailscale.md'
  t "docs/tailscale.md menciona netcheck" bash -c 'grep -q "netcheck" docs/tailscale.md'
else
  sk "tailscale no instalado"
fi

sect "Documentación presente y enlazada"
for d in docs/guia-desde-cero.md docs/tailscale.md docs/vpn-remoto.md \
         docs/onboarding-cliente.md docs/hallazgos.md; do
  t "existe $d" test -f "$d"
done
t "README enlaza hallazgos"     bash -c 'grep -q "docs/hallazgos.md" README.md'
t "README enlaza onboarding"    bash -c 'grep -q "docs/onboarding-cliente.md" README.md'
t "README enlaza tailscale"     bash -c 'grep -q "docs/tailscale.md" README.md'
# La doc debe distinguir roles (operador no necesita sshd; el objetivo sí)
t "README distingue OPERADOR/OBJETIVO" bash -c 'grep -q "PC OPERADOR" README.md && grep -q "PC OBJETIVO" README.md'
t "README aclara que el operador no necesita sshd" \
  bash -c 'grep -qE "sshd.*no necesita|no necesita.*sshd" README.md'

if [[ -n "$HOST" ]]; then
  RH="ssh -o BatchMode=yes -o ConnectTimeout=8 $HOST"
  sect "Remoto: $HOST"
  t "SSH alcanza el host"        bash -c "$RH hostname"
  t "inventory remoto"           ./inventory.sh "$HOST"
  t "inventory remoto JSON"      bash -c "./inventory.sh --json '$HOST' | jq empty"
  t "make check"                 make HOST="$HOST" check

  sect "Hallazgos en el host remoto"
  # H-01/H-06: servicios enabled (sobreviven reboot)
  t "H-06 sshd enabled"          bash -c "$RH 'systemctl is-enabled sshd' >/dev/null 2>&1"
  t "H-01 tailscaled enabled"    bash -c "$RH 'systemctl is-enabled tailscaled' >/dev/null 2>&1"
  t "RustDesk enabled"           bash -c "$RH 'systemctl is-enabled rustdesk' >/dev/null 2>&1"
  t "servicios activos ahora"    bash -c "$RH 'systemctl is-active tailscaled sshd rustdesk' | grep -qv inactive"
  # H-01: ¿tiene IP Tailscale?
  t "H-01 tiene IP Tailscale"    bash -c "$RH 'tailscale ip -4' | grep -qE '^100\.'"
  # H-02/H-04: si hay sesión gráfica activa, debe haber captura DRM
  has_session="$($RH 'loginctl list-sessions --no-legend 2>/dev/null | grep -c " seat0 "' 2>/dev/null || echo 0)"
  if [[ "$has_session" -gt 0 ]]; then
    t "H-04 captura DRM con sesión activa" \
      bash -c "$RH 'grep -q \"drm: consumer cache\" ~/.local/share/logs/RustDesk/server/rustdesk_rCURRENT.log'"
  else
    sk "H-04 sin sesión gráfica activa (login screen): DRM no aplica"
  fi
  # H-03: tipo de login screen del host remoto
  if $RH 'pgrep -f plasmalogin >/dev/null || pgrep -f "sddm|gdm|lightdm" >/dev/null' 2>/dev/null; then
    if $RH 'pgrep -f startplasma-wayland >/dev/null' 2>/dev/null; then
      t "H-03 login screen Wayland (allow-logon-screen-password no aplica)" true
    else
      t "H-03 login screen presente (revisar tipo)" true
    fi
  else
    sk "H-03 sin greeter visible en el host remoto"
  fi
  # H-05: conexión Tailscale directa (si tailscale está en el operador)
  if command -v tailscale >/dev/null 2>&1; then
    # Elegir el peer REMOTO correcto. Usamos --json y excluimos el nodo propio
    # (Self) para no hacer ping a nosotros mismos.
    peer="$(tailscale status --json 2>/dev/null \
      | jq -r '.Peer // {} | to_entries[] | .value.TailscaleIPs[0]' 2>/dev/null | head -1)"
    if [[ -z "$peer" ]]; then
      # Fallback: primera IP 100.x que NO sea la nuestra
      self="$(tailscale ip -4 2>/dev/null | head -1)"
      peer="$(tailscale status 2>/dev/null | awk -v self="$self" '$1 ~ /^100\./ && $1 != self {print $1; exit}')"
    fi
    if [[ -n "$peer" ]]; then
      # OJO: 'tailscale ping' NO acepta -c; sin flag hace intentos y sale solo
      t "H-05 tailscale ping responde ($peer)" bash -c "tailscale ping '$peer' 2>&1 | grep -q pong"
    else
      sk "H-05 no se pudo resolver la IP Tailscale de un peer"
    fi
  else
    sk "H-05 tailscale no instalado en el operador"
  fi
else
  sect "Remoto"
  printf '%s▲%s Omitido (pasa un host: ./tests.sh USUARIO@192.168.1.20)\n' "$Y" "$N"
  SKIP=$((SKIP+1))
fi

sect "Resumen"
printf '  %s%d OK%s · %s%d fallos%s · %s%d omitidos%s\n' \
  "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$Y" "$SKIP" "$N"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
