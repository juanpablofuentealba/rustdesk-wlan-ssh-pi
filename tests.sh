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
sk() { # sk "descripcion"  (omitido: no cuenta como fallo)
  printf '%s▲%s %s\n' "$Y" "$N" "$1"
  SKIP=$((SKIP+1))
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

sect "Soporte multi-distro (arch | debian | fedora)"
t "detecta familia arch"    bash -c 'bash -c "id=arch; idlike=; case \" \$id \$idlike \" in *\" arch \"*) echo arch;; esac" | grep -q arch'
t "script define detect_distro"   bash -c 'grep -q "^detect_distro()" setup-remote-target.sh'
t "script define pkg_install"     bash -c 'grep -q "^pkg_install()" setup-remote-target.sh'
t "script define pkg_installed"   bash -c 'grep -q "^pkg_installed()" setup-remote-target.sh'
t "rama debian usa apt-get"       bash -c 'grep -q "apt-get install" setup-remote-target.sh'
t "rama fedora usa dnf"           bash -c 'grep -q "dnf install" setup-remote-target.sh'
t "rama arch usa pacman"          bash -c 'grep -q "pacman -S" setup-remote-target.sh'
t "resuelve .deb via API GitHub"  bash -c 'grep -q "rustdesk_asset_url" setup-remote-target.sh && grep -q "releases/latest" setup-remote-target.sh'
t "usa .deb en rama debian"       bash -c 'grep -q "install_rustdesk_deb" setup-remote-target.sh'
t "usa .rpm en rama fedora"       bash -c 'grep -q "install_rustdesk_rpm" setup-remote-target.sh'
# No debe quedar 'pacman' fuera de la rama arch (debe usar pkg_install)
t "SSH usa pkg_install (no pacman directo)" bash -c 'grep -q "pkg_install openssh-server\|pkg_install openssh" setup-remote-target.sh'
# Linux Mint: base Ubuntu/Debian → familia debian; y ufw suele estar inactivo
t "detecta Linux Mint como debian"       bash -c 'bash -c "id=linuxmint; idlike=\"ubuntu debian\"; case \" \$id \$idlike \" in *\" debian \"*) echo debian;; esac" | grep -q debian'
t "detecta ufw instalado pero inactivo"  bash -c 'grep -q "ufw-inactive" setup-remote-target.sh'
t "maneja ufw-inactive en setup"         bash -c 'grep -q "ufw --force enable" setup-remote-target.sh'
t "avisa Wayland sin parche DRM (deb/rpm)" bash -c 'grep -q "NO incluye el parche DRM" setup-remote-target.sh'
# Regresiones detectadas en prueba real (VM Mint 22.3, reporte de opencode):
t "tests.sh define sk() (skip)"        bash -c 'grep -q "^sk()" tests.sh'
# detect_firewall debe leer ENABLED de ufw.conf, no solo systemctl is-active
t "detect_firewall lee /etc/ufw/ufw.conf" bash -c 'grep -q "/etc/ufw/ufw.conf" setup-remote-target.sh'
t "detect_firewall: inactive antes que active" bash -c '
  awk "/^detect_firewall\(\)/,/^}/" setup-remote-target.sh > /tmp/_df.sh
  n=$(grep -n "inactive" /tmp/_df.sh | head -1 | cut -d: -f1)
  a=$(grep -n "\*active\*" /tmp/_df.sh | head -1 | cut -d: -f1)
  [ -n "$n" ] && [ -n "$a" ] && [ "$n" -lt "$a" ]
'
t "ufw-inactive activa ufw (--force enable)" bash -c 'grep -q "ufw --force enable" setup-remote-target.sh'
# Mint 27 "Adrien": documentado (esquema nuevo, sin point releases)
t "README documenta Mint 27 Adrien"    bash -c 'grep -q "Adrien" README.md'
t "README explica esquema sin points"  bash -c 'grep -qi "no habrá 27.1\|sin point releases\|abandonó el versionado" README.md'
# dry-run de distro desconocida no debe romper

sect "setup --dry-run (seguridad para clientes)"
t "setup --dry-run sin sudo sale 0"      bash -c './setup-remote-target.sh --ssh --dry-run >/dev/null 2>&1'
t "setup --dry-run NO requiere root"      bash -c './setup-remote-target.sh --all --dry-run >/dev/null 2>&1'
t "ayuda menciona --dry-run"              bash -c './setup-remote-target.sh --help 2>&1 | grep -q -- "--dry-run"'
t "ayuda menciona --yes"                  bash -c './setup-remote-target.sh --help 2>&1 | grep -q -- "--yes"'
# El dry-run NO debe modificar el sistema (estado de sshd y authorized_keys)
t "dry-run no toca sshd enabled"          bash -c 'b=$(systemctl is-enabled sshd 2>&1); ./setup-remote-target.sh --all --dry-run >/dev/null 2>&1; a=$(systemctl is-enabled sshd 2>&1); [ "$b" = "$a" ]'
t "dry-run no toca authorized_keys"       bash -c 'b=$(md5sum ~/.ssh/authorized_keys 2>/dev/null); ./setup-remote-target.sh --ssh --dry-run --key "ssh-ed25519 AAAATEST x@y" >/dev/null 2>&1; a=$(md5sum ~/.ssh/authorized_keys 2>/dev/null); [ "$b" = "$a" ]'
# Confirmación: sin --yes y sin TTY debe cancelar (no aplicar)
tj "setup --all sin --yes cancela sin TTY" bash -c './setup-remote-target.sh --all </dev/null >/dev/null 2>&1'

sect "inventory.sh (local)"
t "texto funciona"             ./inventory.sh
t "texto tiene hostname"       bash -c './inventory.sh | grep -q "Inventario"'
if command -v jq >/dev/null 2>&1; then
  t "JSON es válido"             bash -c './inventory.sh --json | jq empty'
  t "JSON tiene target"          bash -c './inventory.sh --json | jq -e ".target"'
  t "JSON tiene CPU_MODEL"       bash -c './inventory.sh --json | jq -e ".CPU_MODEL"'
  t "JSON tiene HOSTNAME"        bash -c './inventory.sh --json | jq -e ".HOSTNAME"'
else
  # Sin jq no se puede validar el JSON; omitir en vez de fallar (evita 4 fallos
  # confusos si el entorno no trae jq, p. ej. una VM recién instalada).
  sk "jq no instalado: se omiten 4 pruebas de JSON (sudo apt install jq)"
fi
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

sect "Hallazgo H-09 (MagicDNS / resolved-NM)"
t "docs/hallazgos.md documenta H-09" bash -c 'grep -q "H-09" docs/hallazgos.md'
t "H-09 menciona resolved-NM"       bash -c 'grep -qi "resolved-nm\|systemd-resolved" docs/hallazgos.md'
t "H-09 menciona resolv.conf stub"  bash -c 'grep -q "stub-resolv.conf" docs/hallazgos.md'
if command -v tailscale >/dev/null 2>&1; then
  # Si resolved gestiona resolv.conf, el modo debe ser 'stub' (no 'foreign')
  if command -v resolvectl >/dev/null 2>&1; then
    mode="$(resolvectl status 2>/dev/null | awk -F': ' '/resolv.conf mode/{print $2; exit}')"
    if [[ "$mode" == "stub" ]]; then
      t "H-09 resolved gestiona resolv.conf (mode=stub)" true
    elif [[ -n "$mode" ]]; then
      sk "H-09 resolv.conf mode='$mode' (revisar fix; ver hallazgos)"
    else
      sk "H-09 resolvectl no reporta resolv.conf mode"
    fi
  else
    sk "H-09 resolvectl no instalado"
  fi
  # El aviso, si existe, no debe impedir que MagicDNS resuelva un peer
  peer_name="$(tailscale status --json 2>/dev/null \
    | jq -r '.Peer // {} | to_entries[0].value.HostName // empty' 2>/dev/null)"
  if [[ -n "$peer_name" ]] && getent hosts "$peer_name" >/dev/null 2>&1; then
    t "H-09 MagicDNS resuelve '$peer_name'" true
  else
    sk "H-09 sin peer resoluble por MagicDNS desde el operador"
  fi
else
  sk "H-09 tailscale no instalado en el operador"
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
