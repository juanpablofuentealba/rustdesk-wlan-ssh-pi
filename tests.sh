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

# Detecta si un test depende de archivos que solo existen en el repo completo
# (docs/, README.md, Makefile, .gitignore). Fuera del repo (kit copiado) esos
# tests se OMITEN: el kit no está roto, simplemente no trae la documentación.
needs_repo() {
  [[ $IN_REPO -eq 1 ]] && return 1
  local joined="$*"
  [[ "$joined" == *docs/* || "$joined" == *README.md* || "$joined" == *Makefile* \
     || "$joined" == *.gitignore* || "$joined" == *estado-sesion* \
     || "$joined" == *hallazgos* || "$joined" == *clip-vm* \
     || "$joined" == *verify-docs* ]] && return 0
  return 1
}

t() {  # t "descripcion" comando...
  local desc="$1"; shift
  if needs_repo "$@" "$desc"; then sk "$desc (requiere el repo)"; return; fi
  if "$@" >/dev/null 2>&1; then printf '%s✔%s %s\n' "$G" "$N" "$desc"; PASS=$((PASS+1));
  else printf '%s✘%s %s\n' "$R" "$N" "$desc"; FAIL=$((FAIL+1)); fi
}
tj() { # tj "descripcion" comando...  (espera exit != 0)
  local desc="$1"; shift
  if needs_repo "$@" "$desc"; then sk "$desc (requiere el repo)"; return; fi
  if "$@" >/dev/null 2>&1; then printf '%s✘%s %s (debería fallar)' "$R" "$N" "$desc"; FAIL=$((FAIL+1));
  else printf '%s✔%s %s\n' "$G" "$N" "$desc"; PASS=$((PASS+1)); fi
}
sk() { # sk "descripcion"  (omitido: no cuenta como fallo)
  printf '%s▲%s %s\n' "$Y" "$N" "$1"
  SKIP=$((SKIP+1))
}
sect() { printf '\n%s== %s ==%s\n' "$BD" "$1" "$N"; }

# --- ¿estamos en el repo completo o en un kit copiado? ---
# El kit (make-kit.sh) copia los scripts pero NO docs/ ni README.md ni Makefile.
# Las pruebas que verifican esos archivos se OMITEN fuera del repo, en vez de
# fallar: el kit no está roto, simplemente no trae la documentación.
IN_REPO=0
[[ -d docs && -f README.md && -f Makefile ]] && IN_REPO=1

# tdoc: como t(), pero se omite si no estamos en el repo (exige docs/README/Makefile)
tdoc() {
  local desc="$1"; shift
  if [[ $IN_REPO -eq 1 ]]; then t "$desc" "$@"; else sk "$desc (requiere el repo)"; fi
}
tjdoc() {
  local desc="$1"; shift
  if [[ $IN_REPO -eq 1 ]]; then tj "$desc" "$@"; else sk "$desc (requiere el repo)"; fi
}

HOST="${1:-}"

sect "Sintaxis (bash -n)"
for f in setup-remote-target.sh inventory.sh tests.sh clip-vm.sh \
         install-rustdesk-unattended-fedora.sh rustdesk-password.sh \
         .rd-setpass-root.sh verify-offlan.sh make-kit.sh update.sh; do
  [[ -f "$f" ]] || continue
  t "bash -n $f" bash -n "$f"
done
tdoc "bash -n verify-docs.sh" bash -n verify-docs.sh
tdoc "Makefile parseable" make -n help

sect "Permisos de ejecución"
for f in setup-remote-target.sh inventory.sh tests.sh clip-vm.sh \
         install-rustdesk-unattended-fedora.sh rustdesk-password.sh \
         verify-offlan.sh make-kit.sh update.sh; do
  [[ -f "$f" ]] || continue
  t "$f es ejecutable" test -x "$f"
done
tdoc "verify-docs.sh es ejecutable" test -x verify-docs.sh
# issue #30: coherencia ENTRE documentos (tests, versión, enlaces internos)
tdoc "#30: existe verify-docs-consistency.sh" test -f verify-docs-consistency.sh
tdoc "#30: verify-docs-consistency.sh es ejecutable" test -x verify-docs-consistency.sh
tdoc "#30: bash -n verify-docs-consistency.sh" bash -n verify-docs-consistency.sh

sect "Ayuda / usage"
t "setup --help sale 0"        ./setup-remote-target.sh --help
t "setup sin args muestra usage y falla" bash -c './setup-remote-target.sh >/dev/null 2>&1; test $? -ne 0'
tj "setup opción inválida falla" ./setup-remote-target.sh --nope
t "inventory --help sale 0"    ./inventory.sh --help
tdoc "clip-vm --help sale 0"      ./clip-vm.sh --help
tj "clip-vm comando invalido falla" ./clip-vm.sh comandoquenoexiste
tdoc "clip-vm sin args muestra ayuda" bash -c './clip-vm.sh >/dev/null 2>&1'

sect "Soporte multi-distro (arch | debian | fedora)"
t "detecta familia arch"    bash -c 'bash -c "id=arch; idlike=; case \" \$id \$idlike \" in *\" arch \"*) echo arch;; esac" | grep -q arch'
t "script define detect_distro"   bash -c 'grep -q "^detect_distro()" lib/sr-t-distro.sh'
t "script define pkg_install"     bash -c 'grep -q "^pkg_install()" lib/sr-t-distro.sh'
t "script define pkg_installed"   bash -c 'grep -q "^pkg_installed()" lib/sr-t-distro.sh'
t "rama debian usa apt-get"       bash -c 'grep -q "apt-get install" setup-remote-target.sh'
t "rama fedora usa dnf"           bash -c 'grep -q "dnf install" setup-remote-target.sh'
t "rama arch usa pacman"          bash -c 'grep -q "pacman -S" setup-remote-target.sh'
# Fedora 41+: 'dnf' es symlink a dnf5 y `dnf --version` responde "dnf5 ...".
# NO hace falta cambiar los comandos (install -y sigue funcionando igual).
t "diagnostico informa version del gestor" \
  bash -c 'grep -q "^pkg_manager_version()" lib/sr-t-distro.sh'
t "pkg_manager_version cubre las 3 familias" \
  bash -c 'awk "/^pkg_manager_version\(\)/,/^}/" lib/sr-t-distro.sh | grep -qE "(arch|debian|fedora)\\)"'
t "pkg_manager_version fuerza LC_ALL=C (salida no traducida)" \
  bash -c 'awk "/^pkg_manager_version\(\)/,/^}/" lib/sr-t-distro.sh | grep -q "LC_ALL=C dnf"'
t "diagnostico imprime la linea Gestor" \
  bash -c 'grep -q "info \"Gestor: \$(pkg_manager_version)\"" setup-remote-target.sh'
t "resuelve .deb via API GitHub"  bash -c 'grep -q "rustdesk_asset_url" lib/sr-t-rustdesk.sh && grep -q "releases/latest" lib/sr-t-rustdesk.sh'
t "usa .deb en rama debian"       bash -c 'grep -q "install_rustdesk_deb" lib/sr-t-rustdesk.sh'
t "usa .rpm en rama fedora"       bash -c 'grep -q "install_rustdesk_rpm" lib/sr-t-rustdesk.sh'
# No debe quedar 'pacman' fuera de la rama arch (debe usar pkg_install)
t "SSH usa pkg_install (no pacman directo)" bash -c 'grep -q "pkg_install openssh-server\|pkg_install openssh" lib/sr-t-ssh.sh'
# Linux Mint: base Ubuntu/Debian → familia debian; y ufw suele estar inactivo
t "detecta Linux Mint como debian"       bash -c 'bash -c "id=linuxmint; idlike=\"ubuntu debian\"; case \" \$id \$idlike \" in *\" debian \"*) echo debian;; esac" | grep -q debian'
t "detecta ufw instalado pero inactivo"  bash -c 'grep -q "ufw-inactive" setup-remote-target.sh'
t "maneja ufw-inactive en setup"         bash -c 'grep -q "ufw --force enable" lib/sr-t-ssh.sh'
t "avisa Wayland sin parche DRM (deb/rpm)" bash -c 'grep -q "NO incluye el parche DRM" lib/sr-t-rustdesk.sh'
# Regresiones detectadas en prueba real (VM Mint 22.3, reporte de opencode):
t "tests.sh define sk() (skip)"        bash -c 'grep -q "^sk()" tests.sh'
# detect_firewall debe leer ENABLED de ufw.conf, no solo systemctl is-active
t "detect_firewall lee /etc/ufw/ufw.conf" bash -c 'grep -q "/etc/ufw/ufw.conf" setup-remote-target.sh'
t "detect_firewall consulta ufw.conf (respaldo)" bash -c 'grep -q "/etc/ufw/ufw.conf" setup-remote-target.sh'
t "detect_firewall lee ENABLED (no solo systemctl)" bash -c 'awk "/^detect_firewall\(\)/,/^}/" setup-remote-target.sh | grep -q "ENABLED=yes"'
t "ufw-inactive activa ufw (--force enable)" bash -c 'grep -q "ufw --force enable" lib/sr-t-ssh.sh'
# Imágenes base mínimas (fedora:44) sin systemctl/firewall-cmd/ufw: NO se
# puede afirmar "sin firewall"; debe decirlo como no verificable.
t "detect_firewall devuelve sin-herramientas" \
  bash -c 'awk "/^detect_firewall\(\)/,/^}/" setup-remote-target.sh | grep -q "printf .sin-herramientas."'
t "distingue sin-herramientas de none" \
  bash -c 'awk "/^detect_firewall\(\)/,/^}/" setup-remote-target.sh | grep -q "pkg_installed firewalld"'
t "--check maneja sin-herramientas (no afirma seguro)" \
  bash -c 'grep -q "sin-herramientas)" setup-remote-target.sh'
t "--check dice no verificable sin loginctl" \
  bash -c 'grep -q "no verificable (falta loginctl)" setup-remote-target.sh'
# Mint 27 "Adrien": documentado (esquema nuevo, sin point releases)
tdoc "referencia documenta Mint 27 Adrien"    bash -c 'grep -q "Adrien" docs/referencia.md'
tdoc "referencia explica esquema sin points"  bash -c 'grep -qi "no habrá 27.1\|sin point releases\|abandonó el versionado" docs/referencia.md'
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
# Punto 4 (H-20): la detección de tipo debe usar solo datos del remoto.
t "inventory detecta virt (para tipo vm)" \
  bash -c 'grep -q "systemd-detect-virt" inventory.sh'
t "inventory NO ejecuta hostnamectl en el operador" \
  bash -c '! grep -qE "_hostchassis=\\\$\\(hostnamectl" inventory.sh'
t "inventory mapea virt -> vm" \
  bash -c 'grep -q "CTYPE=\"vm\"" inventory.sh'
t "inventory reconoce chassis_type=1 como VM con virt" \
  bash -c 'grep -q "1)" inventory.sh && grep -q "CTYPE=\"vm\"" inventory.sh'
tj "host inalcanzable falla"   ./inventory.sh USUARIO@10.255.255.1

sect "setup --check (lectura, sin root)"
t "--check sale 0"             ./setup-remote-target.sh --check
t "--check detecta usuario"    bash -c './setup-remote-target.sh --check | grep -q "Usuario objetivo"'
t "--check no modifica nada"   bash -c './setup-remote-target.sh --check | grep -q "Diagnóstico completo"'

sect "Kit de instalación (make-kit.sh / punto 3)"
t "bash -n make-kit.sh"        bash -n make-kit.sh
t "make-kit.sh es ejecutable"  test -x make-kit.sh
t "make-kit --help sale 0"     ./make-kit.sh --help
tdoc "Makefile tiene target kit"  bash -c 'make -n kit >/dev/null 2>&1'
tdoc "Makefile tiene target kit-usb" bash -c 'grep -q "^kit-usb:" Makefile'
t "make-kit genera el runbook INSTALAR.md" \
  bash -c 'grep -q "INSTALAR.md" make-kit.sh'
t "make-kit incluye el generador de contraseña" \
  bash -c 'grep -q "rustdesk-password.sh" make-kit.sh'
t "make-kit incluye el instalador de Fedora" \
  bash -c 'grep -q "install-rustdesk-unattended-fedora.sh" make-kit.sh'
t "make-kit calcula el manifiesto sha256" \
  bash -c 'grep -q "MANIFEST.sha256" make-kit.sh'
t "make-kit soporta --dest (pendrive)" \
  bash -c 'grep -q "\-\-dest" make-kit.sh'
t "make-kit soporta --with-key" \
  bash -c 'grep -q "\-\-with-key" make-kit.sh'
t "make-kit soporta --tarball" \
  bash -c 'grep -q "\-\-tarball" make-kit.sh'
# End-to-end: empaquetar, verificar integridad y que el kit extraído sirva.
_kitdir="$(mktemp -d)"
t "make-kit se ejecuta sin error" \
  bash -c "./make-kit.sh --dest '$_kitdir/kit' >/dev/null 2>&1"
t "el kit tiene el runbook" \
  test -f "$_kitdir/kit/INSTALAR.md"
t "el kit tiene setup-remote-target.sh" \
  test -x "$_kitdir/kit/setup-remote-target.sh"
t "el manifiesto valida (sha256sum -c)" \
  bash -c "cd '$_kitdir/kit' && sha256sum -c MANIFEST.sha256 >/dev/null 2>&1"
t "el manifiesto cubre TODOS los archivos del kit (incl. ocultos)" \
  bash -c "cd '$_kitdir/kit' && comm -13 <(grep -oP '(?<=  ).*' MANIFEST.sha256 | sort) <(find . -type f ! -name MANIFEST.sha256 -printf '%P\n' | sort) | grep -q . && exit 1 || exit 0"
t "el manifiesto incluye .kit-version" \
  bash -c "grep -q '.kit-version' '$_kitdir/kit/MANIFEST.sha256'"
t "el manifiesto incluye .rd-setpass-root.sh (oculto)" \
  bash -c "grep -q '.rd-setpass-root.sh' '$_kitdir/kit/MANIFEST.sha256'"
t "el kit extraído pasa su propio --check" \
  bash -c "'$_kitdir/kit/setup-remote-target.sh' --check 2>&1 | grep -q 'Diagnóstico completo'"
rm -rf "$_kitdir"

sect "H-13 portapapeles SPICE (conclusión corregida)"
t "H-13 documenta ambas direcciones" \
  bash -c 'grep -q "guest → host" docs/hallazgos.md && grep -q "host → guest" docs/hallazgos.md'
t "H-13 dice que Wayland nativo SÍ propaga" \
  bash -c 'grep -q "Wayland nativo" docs/hallazgos.md'
t "H-13 atribuye el fallo a xclip/X11, no a la dirección" \
  bash -c 'grep -q "por qué vía se escribe" docs/hallazgos.md'
t "H-13 ya NO titula \"una sola dirección\"" \
  bash -c '! grep -q "funciona en una sola dirección" docs/hallazgos.md'
t "H-13 registra el historial de la medición" \
  bash -c 'grep -q "Historial" docs/hallazgos.md'
t "referencia aclara que clip-vm es para scripting" \
  bash -c 'grep -q "scripting/automatización" docs/referencia.md'
t "estado-sesion refleja la conclusión nueva" \
  bash -c 'grep -q "ambas direcciones" docs/estado-sesion.md'

sect "verify-offlan.sh (prueba fuera de la LAN)"
t "bash -n verify-offlan.sh"    bash -n verify-offlan.sh
t "verify-offlan es ejecutable" test -x verify-offlan.sh
t "detecta la ruta LAN (no da falso positivo)" \
  bash -c 'grep -q "ON_LAN=1" verify-offlan.sh'
t "distingue DERP de ruta directa" \
  bash -c 'grep -q "via DERP" verify-offlan.sh'
t "detecta ruta LAN con ip route get (mirando solo la 1a linea)" \
  bash -c 'grep -q "ip route get" verify-offlan.sh && grep -q "head -1" verify-offlan.sh'
t "no da falso positivo por la linea 'cache'" \
  bash -c 'grep -q "first_hop" verify-offlan.sh'
t "usa BatchMode en el SSH de comprobación" \
  bash -c 'grep -q "BatchMode=yes" verify-offlan.sh'
t "verifica SSH y RustDesk por Tailscale" \
  bash -c 'grep -q "SSH entra por la IP Tailscale" verify-offlan.sh && grep -q "rustdesk --get-id" verify-offlan.sh'
t "avisa si no hay internet" \
  bash -c 'grep -q "sin internet" verify-offlan.sh'
t "no modifica nada (solo lectura)" \
  bash -c '! grep -qE "^[[:space:]]*(sudo|apt|dnf|pacman)[[:space:]]" verify-offlan.sh && ! grep -qE "systemctl (start|restart|enable|disable)" verify-offlan.sh'

sect "No fuga de secretos al repo"
t ".gitignore ignora claves"   bash -c 'grep -q "id_" .gitignore'
t "no hay claves en el árbol"  bash -c '! find . -name "id_*" -not -path "./.git/*" | grep -q .'
t "no hay .key/.pem"           bash -c '! find . \( -name "*.key" -o -name "*.pem" \) -not -path "./.git/*" | grep -q .'
t "no hay tskey-auth real"     bash -c '! grep -rqE "tskey-auth-[A-Za-z0-9]{20}" --exclude-dir=.git .'
# Excluye el propio tests.sh (contiene los patrones como literales de búsqueda)
t "sin datos de infra real"    bash -c '! grep -rqE "jpfuentealba|100\.(68|97|112)\.|wikileaks|jp-rustdesk|tailc15fd9" --exclude-dir=.git --exclude-dir=fichas --exclude-dir=kit-rustdesk --exclude=tests.sh .'

sect "Hallazgos H-07/H-08 (regresiones conocidas)"
# H-07: hostname -I no existe en CachyOS → el kit debe usar 'ip route get'
t "inventory.sh usa ip route (no hostname -I)" \
  bash -c '! grep -q "hostname -I" inventory.sh && grep -q "ip -4 route get" inventory.sh'
# setup usa `ip route` como metodo principal; `hostname -I` solo como RESPALDO
# cuando no hay ruta por defecto (contenedor, equipo recien instalado).
# Antes un fallo de `ip` mataba el script con exit 127 (bug detectado en CI).
t "setup usa ip route como metodo principal" \
  bash -c 'grep -q "ip -4 route get" lib/sr-t-distro.sh'
t "setup local_ip no muere sin red (respaldo + return 0)" \
  bash -c 'sed -n "/^local_ip()/,/^}/p" lib/sr-t-distro.sh | grep -q "return 0"'
t "setup local_ip devuelve 'sin-red' si no hay IP" \
  bash -c 'grep -q "sin-red" lib/sr-t-distro.sh'
# H-08: strings|grep -q con pipefail → verify-docs debe capturar a variable
t "verify-docs evita strings|grep -q" \
  bash -c '! grep -qE "strings -a .*\| *grep -q" verify-docs.sh'
# Fedora 44 (imagen base mínima) NO trae el binario 'hostname': el kit debe
# tener respaldo (/proc/sys/kernel/hostname o uname -n) para no mostrar vacío.
t "setup tiene hostname portable (local_hostname)" \
  bash -c 'grep -q "^local_hostname()" lib/sr-t-distro.sh'
t "local_hostname respalda con /proc/sys/kernel/hostname" \
  bash -c 'awk "/^local_hostname\(\)/,/^}/" lib/sr-t-distro.sh | grep -q "/proc/sys/kernel/hostname"'
t "setup no llama hostname sin respaldo" \
  bash -c '! grep -vE "^\s*#" setup-remote-target.sh | grep -qE "\$\(hostname\)"'
t "inventory respalda hostname con /proc o uname -n" \
  bash -c 'grep -q "j HOSTNAME" inventory.sh && grep -q "/proc/sys/kernel/hostname" inventory.sh'
# Fedora 44 con KDE: la ultima sesion de `loginctl list-sessions` es de tipo
# 'background'/'manager' (Type=unspecified) y ocultaba el Wayland real.
t "setup tiene graphical_session_type()" \
  bash -c 'grep -q "^graphical_session_type()" lib/sr-t-distro.sh'
t "no elige sesion con tail -1 (bug Fedora 44 KDE)" \
  bash -c '! grep -vE "^\s*#" setup-remote-target.sh | grep -qE "list-sessions.*tail -1"'
t "graphical_session_type prefiere sesiones con seat" \
  bash -c 'awk "/^graphical_session_type\(\)/,/^}/" lib/sr-t-distro.sh | grep -q "\$4 != \"-\""'
t "ambos avisos usan graphical_session_type" \
  bash -c '[[ $(cat setup-remote-target.sh lib/sr-t-rustdesk.sh | grep -c "\$(graphical_session_type)") -ge 2 ]]'

sect "Hallazgo H-03 (login screen X11 vs Wayland)"
if command -v pgrep >/dev/null 2>&1; then
  t "verify-docs detecta tipo de login screen" \
    bash -c './verify-docs.sh 2>&1 | grep -qE "login screen|greeter|sin greeter"'
  # Coherencia: si el binario declara no soportar Wayland login screen, el doc debe decirlo
  if [[ -r /usr/share/rustdesk/lib/librustdesk.so ]] && command -v strings >/dev/null 2>&1; then
    so_strings="$(strings -a /usr/share/rustdesk/lib/librustdesk.so 2>/dev/null || true)"
    if grep -q "Wayland login screen is not supported" <<<"$so_strings"; then
      tdoc "docs/hallazgos.md refleja el aviso de Wayland" \
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
  tdoc "docs/tailscale.md menciona tailscale ping" bash -c 'grep -q "tailscale ping" docs/tailscale.md'
  tdoc "docs/tailscale.md menciona netcheck" bash -c 'grep -q "netcheck" docs/tailscale.md'
else
  sk "tailscale no instalado"
fi

sect "H-14 install-rustdesk-unattended-fedora.sh (capturador DRM en Fedora)"
t "H-14 el instalador fija el sha256 esperado" \
  bash -c 'grep -q "9eed5e9f4b47af8ed41585c399cb2c0d2870e801c99645330dea1063ad844e09" install-rustdesk-unattended-fedora.sh'
t "H-14 verifica el sha256 antes de instalar" \
  bash -c 'grep -q "sha256sum" install-rustdesk-unattended-fedora.sh && grep -q "EXPECTED_SHA" install-rustdesk-unattended-fedora.sh'
t "H-14 descarga el .deb unattended-wayland oficial" \
  bash -c 'grep -q "rustdesk-unattended-wayland" install-rustdesk-unattended-fedora.sh'
t "H-14 instala libdrmtap (capturador DRM)" \
  bash -c 'grep -q "libdrmtap" install-rustdesk-unattended-fedora.sh'
t "H-14 corrige dueño root:root" \
  bash -c 'grep -q "chown -R root:root" install-rustdesk-unattended-fedora.sh'
t "H-14 corrige contextos SELinux (restorecon)" \
  bash -c 'grep -q "restorecon" install-rustdesk-unattended-fedora.sh'
t "H-14 usa /etc/systemd/system (ruta de Fedora)" \
  bash -c 'grep -q "/etc/systemd/system/rustdesk.service" install-rustdesk-unattended-fedora.sh'
t "H-14 hace respaldo antes de reemplazar" \
  bash -c 'grep -q "rustdesk-backup" install-rustdesk-unattended-fedora.sh'
t "H-14 soporta --dry-run" \
  grep -q -- '--dry-run' install-rustdesk-unattended-fedora.sh

sect "H-15 rustdesk-password.sh (contraseña permanente)"
t "H-15 implementa SHA256(password||salt)" \
  bash -c 'grep -q "sha256" rustdesk-password.sh'
t "H-15 usa salt de 32 chars (DEFAULT_SALT_LEN)" \
  bash -c 'grep -q "range(32)" rustdesk-password.sh'
t "H-15 cifra con secretbox (PyNaCl)" \
  bash -c 'grep -q "SecretBox" rustdesk-password.sh'
t "H-15 deriva la key del machine-id" \
  bash -c 'grep -q "machine-id" rustdesk-password.sh'
t "H-15 usa prefijo de version 01" \
  bash -c 'grep -q '"'"'"01"'"'"' rustdesk-password.sh'
t "H-15 escribe password y salt en RustDesk.toml" \
  bash -c 'grep -q "setkey(text, .password." .rd-setpass-root.sh && grep -q "setkey(text, .salt." .rd-setpass-root.sh'
t "H-15 aplica a root y al usuario" \
  bash -c 'grep -q "apply" .rd-setpass-root.sh && grep -q "ROOT_CFG" .rd-setpass-root.sh && grep -q "SUDO_USER" .rd-setpass-root.sh'
t "H-15 el helper lee por stdin (no argv visible en ps)" \
  bash -c 'grep -q "\-\-stdin" .rd-setpass-root.sh'
t "H-15 el helper permite pruebas aisladas" \
  bash -c 'grep -q "RDP_CONFIG_ROOT" .rd-setpass-root.sh'
t "H-15 puede limitarse al usuario objetivo" \
  bash -c 'grep -q "RDP_HOME_BASE" .rd-setpass-root.sh'
t "H-15 rustdesk-password tiene modo LOCAL (sin SSH)" \
  bash -c 'grep -q "modo LOCAL" rustdesk-password.sh'
t "H-15 comprueba PyNaCl antes de usarlo" \
  bash -c 'grep -q "^ensure_pynacl()" rustdesk-password.sh'
t "H-15 instala PyNaCl segun el gestor de paquetes" \
  bash -c 'grep -q "python-pynacl" rustdesk-password.sh && grep -q "python3-nacl" rustdesk-password.sh'
t "H-15 no usa la funcion 'info' (colisiona con info(1))" \
  bash -c '! grep -qE "^\s*info \"" rustdesk-password.sh'
t "H-48: la verificación NO manda bash -c con comillas anidadas por SSH" \
  bash -c '! grep -qE "bash -c \\\\\"\$vercmd" rustdesk-password.sh'
t "H-48: la verificación usa bash -s por STDIN" \
  bash -c 'grep -q "bash -s" rustdesk-password.sh'
t "H-48: verifica el config del usuario (jp)" \
  bash -c 'grep -q "config jp" rustdesk-password.sh && grep -q '\''\$jpcfg'\'' rustdesk-password.sh'
t "H-48: avisa si sudo pide contraseña en la verificación" \
  bash -c 'grep -q "no se pudo verificar el config de root" rustdesk-password.sh'

sect "H-49: pam_faillock y reintentos de contraseña"
t "H-49 documentado" bash -c 'grep -q "H-49" docs/hallazgos.md'
t "H-49 menciona pam_faillock" \
  bash -c 'grep -q "pam_faillock" docs/hallazgos.md'
t "H-49 explica el auto-bloqueo por reintentos" \
  bash -c 'grep -qi "bloquea la autenticaci" docs/hallazgos.md'
t "H-49 recomienda su para probar credenciales" \
  bash -c 'grep -q "su -c" docs/hallazgos.md'
t "H-49 explica faillock --reset" \
  bash -c 'grep -q "faillock --user" docs/hallazgos.md'
t "instalar-todo: --sudopass eleva el sudo inicial" \
  bash -c 'grep -q "exec sudo -E bash" instalar-todo.sh'
t "instalar-todo: avisa de contraseñas debiles" \
  bash -c 'grep -q "patrón predecible" instalar-todo.sh'
t "instalar-todo: avisa si la clave contiene el usuario" \
  bash -c 'grep -q "contiene el nombre de usuario" instalar-todo.sh'
t "H-15 exige SUDO_PASS (no hardcodea secretos)" \
  bash -c '! grep -qE "SUDO_PASS:-[a-z]" rustdesk-password.sh && grep -q "definí SUDO_PASS" rustdesk-password.sh'
t "H-15 comando salt genera 32 chars" \
  bash -c './rustdesk-password.sh salt | grep -qE "^[A-Za-z0-9]{32}$"'
t "H-15 comando hash produce SALT= y PASSWORD=" \
  bash -c './rustdesk-password.sh hash prueba abc123 | grep -q "^SALT=" && ./rustdesk-password.sh hash prueba abc123 | grep -q "^PASSWORD=01"'
t "H-15 hash es determinista para el mismo salt" \
  bash -c 'a=$(./rustdesk-password.sh hash p m salt1 | grep PASSWORD); b=$(./rustdesk-password.sh hash p m salt1 | grep PASSWORD); test "$a" != "$b"'
t "H-15 rechaza password vacía" \
  bash -c '! ./rustdesk-password.sh hash "" abc 2>/dev/null'

t "H-15 el repo no contiene la contraseña de prueba" \
  bash -c '! grep -rq "Prueba-Unattended" README.md docs/ setup-remote-target.sh install-rustdesk-unattended-fedora.sh rustdesk-password.sh .rd-setpass-root.sh 2>/dev/null'

# H-39: manejo de error de rustdesk-password.sh. Salió de probarlo contra un
# cliente real cuyo sudo pedía contraseña: el script fallaba con un confuso
# 'target: variable sin asignar' en vez de decir que la contraseña era mala.
sect "H-39 rustdesk-password.sh: manejo de error del modo remoto"
t "H-39 la rama REMOTA detecta el fallo de sudo (|| { err ...; return 1; })" \
  bash -c 'grep -q "falló la escritura de la config remota" rustdesk-password.sh'
t "H-39 el mensaje sugiere verificar la contraseña de sudo" \
  bash -c 'grep -q "¿contraseña de sudo incorrecta?" rustdesk-password.sh'
t "H-39 el trap incrusta el valor de target al definirlo (printf %q)" \
  bash -c 'grep -q "trap \"ssh.*printf.*%q.*\$target" rustdesk-password.sh'
t "H-39 el trap ya no referencia \$target diferido (que rompía con set -u)" \
  bash -c '! grep -qE "trap .ssh.*\"\$target\".* EXIT" rustdesk-password.sh'
t "H-39 documentado" \
  bash -c 'grep -q "H-39" docs/hallazgos.md'

sect "instalar-todo.sh (un solo comando)"
t "bash -n instalar-todo.sh"   bash -n instalar-todo.sh
t "es ejecutable"              test -x instalar-todo.sh
t "--help sale 0"              ./instalar-todo.sh --help
t "exige --rdpass (sin sudo da el error correcto)" \
  bash -c './instalar-todo.sh --authkey tskey-auth-X 2>&1 | grep -q "falta --rdpass"'
t "exige --authkey" \
  bash -c './instalar-todo.sh --rdpass UnaClave123 2>&1 | grep -q "falta --authkey"'
t "valida el prefijo tskey-" \
  bash -c './instalar-todo.sh --authkey malaclave --rdpass UnaClave123 2>&1 | grep -q "debe empezar con"'
# Sin root y sin --sudopass: debe AVISAR (mensaje de sudo) o CANCELAR por
# falta de TTY, pero NUNCA llegar a aplicar cambios. Depende del entorno
# (en CI 'ubuntu' tiene sudo sin contraseña), asi que aceptamos ambos.
t "sin root no aplica cambios (avisa o cancela)" \
  bash -c './instalar-todo.sh --authkey tskey-auth-X --rdpass UnaClave123 >/dev/null 2>&1; test $? -ne 0'
t "--dry-run corre sin root" \
  bash -c './instalar-todo.sh --authkey tskey-auth-X --rdpass UnaClave123 --dry-run --yes >/dev/null 2>&1'
t "toma la clave de operador.pub si existe" \
  bash -c 'grep -q "operador.pub" instalar-todo.sh'
t "soporta --sudopass (sudo con contraseña)" \
  bash -c 'grep -q "\-\-sudopass" instalar-todo.sh'
t "soporta --skip-tailscale" \
  bash -c 'grep -q "\-\-skip-tailscale" instalar-todo.sh'
t "llama a rustdesk-password.sh (contraseña incluida)" \
  bash -c 'grep -q "rustdesk-password.sh install" instalar-todo.sh'
t "verifica la captura DRM en las 4 rutas de log" \
  bash -c 'grep -q "plasmalogin" instalar-todo.sh && grep -q "DRM_LOG" instalar-todo.sh'
t "detecta el fallo al portal y da la solución" \
  bash -c 'grep -q "portal handshake failed" instalar-todo.sh'
t "resume con el ID de RustDesk y la IP Tailscale" \
  bash -c 'grep -q "rustdesk --get-id" instalar-todo.sh'
t "make-kit incluye instalar-todo.sh" \
  bash -c 'grep -q "instalar-todo.sh" make-kit.sh'

sect "H-23 compatibilidad con objetivos de shell fish"
t "tests.sh envía los comandos por bash -s" \
  bash -c 'grep -q "HOST bash -s" tests.sh'
t "tests.sh NO ejecuta bash -lc en el código" \
  bash -c '! grep -E "^[[:space:]]*(RH=|rsh\(\))" tests.sh | grep -q "bash -l"'
t "tests.sh define rsh() para comandos remotos" \
  bash -c 'grep -q "^  rsh() " tests.sh'
t "tests.sh documenta por qué (flags comidos por bash)" \
  bash -c 'grep -q "se come los flags" tests.sh'
t "make check usa bash -s por stdin" \
  bash -c 'grep -q "HOST) bash -s" Makefile'
t "make check ya no manda bash suelto" \
  bash -c '! grep -qE "\\\$\(SSH\) \\\$\(HOST\) .[a-z]+=" Makefile'
t "make check busca el log también en plasmalogin (H-16)" \
  bash -c 'grep -q "plasmalogin" Makefile'
t "H-23 documentado" bash -c 'grep -q "H-23" docs/hallazgos.md'
t "H-23 explica el caso tailscale ip -4 / ayuda" \
  bash -c 'grep -q "tailscale ip -4\|imprime la AYUDA" docs/hallazgos.md'

sect "Ruta del repositorio (visible en todo el material)"
REPO_URL="github.com/juanpablofuentealba/rustdesk-wlan-ssh-pi"
t "existe REPO.txt"                 test -f REPO.txt
t "REPO.txt tiene la URL"           bash -c "grep -q '$REPO_URL' REPO.txt"
t "REPO.txt explica para qué sirve" bash -c 'grep -qi "clonar\|git clone" REPO.txt'
t "REPO.txt dice cómo regenerar el kit" bash -c 'grep -q "make-kit.sh" REPO.txt'
t "REPO.txt lista el contenido del repo" bash -c 'grep -q "docs/hallazgos.md" REPO.txt'
t "REPO.txt tiene uso rapido con git clone" \
  bash -c 'grep -qi "Uso rapido" REPO.txt && grep -q "git clone" REPO.txt'
t "REPO.txt menciona PROMPT-AGENTE (agentes)" \
  bash -c 'grep -q "PROMPT-AGENTE" REPO.txt'
t "REPO.txt ya no dice H-01..H-22 (desactualizado)" \
  bash -c '! grep -q "H-01..H-22" REPO.txt'
t "REPO.txt lista las herramientas nuevas" \
  bash -c 'grep -q "reboot-remoto.sh" REPO.txt && grep -q "laptop-no-suspend.sh" REPO.txt'
t "REPO.txt tiene orden de lectura sugerido" \
  bash -c 'grep -q "ORDEN DE LECTURA" REPO.txt'
t "LEEME ubica la auth key y el repo arriba" \
  bash -c 'grep -q "AUTH KEY DE TAILSCALE: ACA SE GENERA" LEEME-PRIMERO.txt && grep -q "REPOSITORIO:" LEEME-PRIMERO.txt'
t "LEEME lista REPO.txt como punto 1" \
  bash -c 'grep -q "1) REPO.txt" LEEME-PRIMERO.txt'
t "LEEME-PRIMERO.txt tiene la URL"   bash -c "grep -q '$REPO_URL' LEEME-PRIMERO.txt"
t "PASOS-EN-ORDEN.txt tiene la URL"  bash -c "grep -q '$REPO_URL' PASOS-EN-ORDEN.txt"
t "INSTALAR.md tiene la URL"         bash -c "grep -q '$REPO_URL' INSTALAR.md"
t "--help de instalar-todo muestra el repo" \
  bash -c "./instalar-todo.sh --help 2>&1 | grep -q '$REPO_URL'"
t "--help de setup-remote-target muestra el repo" \
  bash -c "./setup-remote-target.sh --help 2>&1 | grep -q '$REPO_URL'"
t "make-kit copia REPO.txt al kit"    bash -c 'grep -q "REPO.txt" make-kit.sh'
t "make-kit copia REPO.txt a la raíz del pendrive" \
  bash -c 'grep -q "KIT_PARENT/REPO.txt" make-kit.sh'

sect "PASOS-EN-ORDEN.txt (checklist del pendrive)"
t "existe PASOS-EN-ORDEN.txt" test -f PASOS-EN-ORDEN.txt
t "tiene los pasos numerados (1-9 + variantes b)" \
  bash -c 'for n in 1 2 3 4 5 7 8 9; do grep -q "PASO $n " PASOS-EN-ORDEN.txt || exit 1; done; grep -q "PASO 5b" PASOS-EN-ORDEN.txt && grep -q "PASO 6b" PASOS-EN-ORDEN.txt'
t "paso 1 = instalar el SO" \
  bash -c 'grep -q "PASO 1 — INSTALAR EL SISTEMA OPERATIVO" PASOS-EN-ORDEN.txt'
t "paso 2 = cambiar a hotspot" \
  bash -c 'grep -q "PASO 2 — CAMBIAR AL HOTSPOT" PASOS-EN-ORDEN.txt'
t "paso 5 = instalar-todo.sh (un comando)" \
  bash -c 'grep -q "instalar-todo.sh" PASOS-EN-ORDEN.txt'
t "paso 5 pasa authkey y rdpass" \
  bash -c 'grep -q "authkey" PASOS-EN-ORDEN.txt && grep -q "rdpass" PASOS-EN-ORDEN.txt'
t "documenta la variante por partes (5b/6b)" \
  bash -c 'grep -q "PASO 5b" PASOS-EN-ORDEN.txt && grep -q "PASO 6b" PASOS-EN-ORDEN.txt'
t "avisa que la contraseña es obligatoria" \
  bash -c 'grep -q "rustdesk-password.sh install" PASOS-EN-ORDEN.txt'
t "paso 7 verifica la captura DRM" \
  bash -c 'grep -q "consumer cache warmed" PASOS-EN-ORDEN.txt'
t "paso 9 explica la revocación al cliente" \
  bash -c 'grep -q "Disable" PASOS-EN-ORDEN.txt'
t "los fallos apuntan a hallazgos (no duplican tabla)" \
  bash -c 'grep -q "docs/hallazgos.md" PASOS-EN-ORDEN.txt'
t "LEEME tiene la tabla de fallos comunes" \
  bash -c 'grep -q "portal handshake failed" LEEME-PRIMERO.txt && grep -q "RustDesk failed" LEEME-PRIMERO.txt'
t "recuerda la auth key antes de salir" \
  bash -c 'grep -q "tskey-auth" PASOS-EN-ORDEN.txt'
t "make-kit copia PASOS-EN-ORDEN.txt" \
  bash -c 'grep -q "PASOS-EN-ORDEN.txt" make-kit.sh'

sect "URL de auth keys visible en los puntos de entrada"
KEYS_URL="login.tailscale.com/admin/settings/keys"
t "README tiene la URL de auth keys" \
  bash -c "grep -q '$KEYS_URL' README.md"
t "README la destaca con encabezado propio" \
  bash -c 'grep -q "Auth key de Tailscale: DÓNDE SE OBTIENE" README.md'
t "README dice que NO se genera en el equipo" \
  bash -c 'grep -q "NO SE GENERA EN EL EQUIPO" README.md'
t "REPO.txt (raiz pendrive) tiene la URL destacada" \
  bash -c "grep -q 'AUTH KEY DE TAILSCALE: ACA SE GENERA' REPO.txt && grep -q '$KEYS_URL' REPO.txt"
t "LEEME-PRIMERO tiene la URL destacada" \
  bash -c "grep -q 'AUTH KEY DE TAILSCALE: ACA SE GENERA' LEEME-PRIMERO.txt && grep -q '$KEYS_URL' LEEME-PRIMERO.txt"
t "PASOS-EN-ORDEN tiene la URL en el encabezado" \
  bash -c 'sed -n "1,12p" PASOS-EN-ORDEN.txt | grep -q "settings/keys"'
t "PROMPT-AGENTE tiene bloque URL EXACTA" \
  bash -c "grep -q 'AUTH KEY DE TAILSCALE: URL EXACTA' PROMPT-AGENTE.txt"
t "INSTALAR.md tiene la URL" bash -c "grep -q '$KEYS_URL' INSTALAR.md"
t "docs/tailscale.md tiene la URL" bash -c "grep -q '$KEYS_URL' docs/tailscale.md"
t "setup-remote-target la muestra al faltar la key" \
  bash -c "grep -q '$KEYS_URL' setup-remote-target.sh"
t "unir-tailscale la muestra" \
  bash -c "grep -q '$KEYS_URL' unir-tailscale.sh"

sect "H-30 la auth key se genera en la web (no en el equipo)"
t "H-30 documentado" bash -c 'grep -q "H-30" docs/hallazgos.md'
t "H-30 dice que se crea en la WEB" \
  bash -c 'grep -q "se \*\*crea en la WEB\*\*" docs/hallazgos.md'
t "existe unir-tailscale.sh" bash -c 'test -f unir-tailscale.sh'
t "unir-tailscale es ejecutable" bash -c 'test -x unir-tailscale.sh'
t "unir-tailscale sintaxis OK" bash -c 'bash -n unir-tailscale.sh'
t "unir-tailscale explica de dónde sale la key" \
  bash -c 'grep -q "De dónde sale la auth key" unir-tailscale.sh'
t "unir-tailscale apunta a la URL de keys" \
  bash -c 'grep -q "login.tailscale.com/admin/settings/keys" unir-tailscale.sh'
t "unir-tailscale valida el formato tskey-" \
  bash -c 'grep -q "debe empezar con .tskey-" unir-tailscale.sh'
t "instalar-todo tiene --tailscale-luego" \
  bash -c 'grep -q -- "--tailscale-luego" instalar-todo.sh'
t "setup-remote-target tiene --install-tailscale" \
  bash -c 'grep -q -- "--install-tailscale" setup-remote-target.sh'
t "el mensaje sin authkey explica de dónde sale" \
  bash -c 'grep -q "NO se genera en este equipo" setup-remote-target.sh'
t "make-kit incluye unir-tailscale.sh" \
  bash -c 'grep -q "unir-tailscale.sh" make-kit.sh'
t "el kit generado trae unir-tailscale.sh" \
  bash -c 'd="$(mktemp -d)"; ./make-kit.sh --dest "$d/kit" >/dev/null 2>&1; test -f "$d/kit/unir-tailscale.sh"; r=$?; rm -rf "$d"; exit $r'

sect "H-29 anti-suspensión para portátiles"
t "H-29 documentado" bash -c 'grep -q "H-29" docs/hallazgos.md'
t "H-29 explica el riesgo (pierde acceso)" \
  bash -c 'grep -q "pierde el acceso remoto" docs/hallazgos.md'
t "existe laptop-no-suspend.sh" bash -c 'test -f laptop-no-suspend.sh'
t "laptop-no-suspend es ejecutable" bash -c 'test -x laptop-no-suspend.sh'
t "laptop-no-suspend tiene sintaxis OK" bash -c 'bash -n laptop-no-suspend.sh'
t "laptop-no-suspend soporta --check/--apply/--revert" \
  bash -c 'grep -q -- "--check|--apply|--revert" laptop-no-suspend.sh'
t "escribe HandleLidSwitch=ignore" \
  bash -c 'grep -q "HandleLidSwitch=ignore" laptop-no-suspend.sh'
t "setup-remote-target tiene --laptop" \
  bash -c 'grep -q -- "--laptop" setup-remote-target.sh'
t "--all incluye --laptop" \
  bash -c 'grep -q "DO_RUSTDESK=1; DO_SSH=1; DO_TAILSCALE=1; DO_LAPTOP=1" setup-remote-target.sh'
t "el --check diagnostica la energía" \
  bash -c './setup-remote-target.sh --check 2>&1 | grep -q "Energía / suspensión"'
t "make-kit incluye laptop-no-suspend.sh" \
  bash -c 'grep -q "laptop-no-suspend.sh" make-kit.sh'
t "el kit generado trae laptop-no-suspend.sh" \
  bash -c 'd="$(mktemp -d)"; ./make-kit.sh --dest "$d/kit" >/dev/null 2>&1; test -f "$d/kit/laptop-no-suspend.sh"; r=$?; rm -rf "$d"; exit $r'

sect "Prompt para agentes IA (PROMPT-AGENTE.txt)"
t "existe PROMPT-AGENTE.txt" bash -c 'test -f PROMPT-AGENTE.txt'
t "ordena leer hallazgos ANTES de actuar" \
  bash -c 'grep -q "LEER ANTES DE ACTUAR" PROMPT-AGENTE.txt'
t "menciona firewalld vs ufw" \
  bash -c 'grep -q "firewalld" PROMPT-AGENTE.txt'
t "advierte del .deb con DRM en Fedora" \
  bash -c 'grep -q "libdrmtap" PROMPT-AGENTE.txt'
t "advierte de fish (bash -s)" \
  bash -c 'grep -q "bash -s" PROMPT-AGENTE.txt'
t "dice de dónde sale la auth key (H-26)" \
  bash -c 'grep -q "settings/keys" PROMPT-AGENTE.txt'
t "avisa que no reinicie sin permiso" \
  bash -c 'grep -q "NO REINICIES" PROMPT-AGENTE.txt'
t "make-kit incluye PROMPT-AGENTE.txt" \
  bash -c 'grep -q "PROMPT-AGENTE.txt" make-kit.sh'
t "el kit generado trae PROMPT-AGENTE.txt" \
  bash -c 'd="$(mktemp -d)"; ./make-kit.sh --dest "$d/kit" >/dev/null 2>&1; test -f "$d/kit/PROMPT-AGENTE.txt"; r=$?; rm -rf "$d"; exit $r'
t "LEEME-PRIMERO lista el prompt" \
  bash -c 'grep -q "PROMPT-AGENTE.txt" LEEME-PRIMERO.txt'
t "README enlaza el prompt" \
  bash -c 'grep -q "PROMPT-AGENTE.txt" README.md'

sect "Agente operador (docs/agente-operador.md)"
t "existe docs/agente-operador.md" \
  bash -c 'test -f docs/agente-operador.md'
t "distingue operar de instalar" \
  bash -c 'grep -qi "operar.*despu\|administrar clientes" docs/agente-operador.md'
t "el agente NO vive en el cliente" \
  bash -c 'grep -q "no.*vive en el PC del cliente" docs/agente-operador.md'
t "usa bash -s (fish)" \
  bash -c 'grep -q "bash -s" docs/agente-operador.md'
t "avisa no reiniciar sin permiso" \
  bash -c 'grep -q "reiniciar\|reiniciés\|reinicies" docs/agente-operador.md'
t "advierte no pegar tokens en el chat" \
  bash -c 'grep -qi "tokens en el chat\|No pegues tokens" docs/agente-operador.md'
t "menciona H-14 y H-32" \
  bash -c 'grep -q "H-14" docs/agente-operador.md && grep -q "H-32" docs/agente-operador.md'
t "README enlaza agente-operador" \
  bash -c 'grep -q "agente-operador.md" README.md'
t "AGENTS.md enlaza agente-operador" \
  bash -c 'grep -q "agente-operador.md" AGENTS.md'

sect "Caso real (docs/caso-real-msi.md)"
t "existe docs/caso-real-msi.md" \
  bash -c 'test -f docs/caso-real-msi.md'
t "documenta que se instaló con el kit (libdrmtap)" \
  bash -c 'grep -q "libdrmtap" docs/caso-real-msi.md'
t "incluye la verificación por boot_id" \
  bash -c 'grep -q "boot_id" docs/caso-real-msi.md'
t "menciona el bloqueo de sudo como cuello de botella" \
  bash -c 'grep -qi "sudo" docs/caso-real-msi.md'
t "usa pactree -r antes de desinstalar metapaquetes" \
  bash -c 'grep -q "pactree -r" docs/caso-real-msi.md'
t "README enlaza el caso real" \
  bash -c 'grep -q "caso-real-msi.md" README.md'

sect "Las pruebas nuevas están en TODOS los documentos"
t "INSTALAR.md documenta la prueba de reinicio" \
  bash -c 'grep -q "reboot-remoto.sh" INSTALAR.md'
t "INSTALAR.md advierte de la IP pública compartida" \
  bash -c 'grep -q "IPs públicas distintas" INSTALAR.md'
t "LEEME-PRIMERO.txt lista las pruebas de validación" \
  bash -c 'grep -q "PRUEBAS DESDE TU EQUIPO OPERADOR" LEEME-PRIMERO.txt'
t "LEEME-PRIMERO.txt menciona reboot-remoto" \
  bash -c 'grep -q "reboot-remoto.sh" LEEME-PRIMERO.txt'
t "onboarding-cliente cubre las dos pruebas" \
  bash -c 'grep -q "reboot-remoto.sh" docs/onboarding-cliente.md'
t "guia-desde-cero menciona las dos pruebas" \
  bash -c 'grep -q "reboot-remoto.sh" docs/guia-desde-cero.md'

sect "Servidor RustDesk verificado (DRM + contraseña)"
t "estado-sesion registra el servidor listo para unattended" \
  bash -c 'grep -q "listo para conexión desatendida" docs/estado-sesion.md'
t "estado-sesion confirma captura DRM activa" \
  bash -c 'grep -q "drm_capturer.rs" docs/estado-sesion.md'
t "estado-sesion confirma contrasena permanente presente" \
  bash -c 'grep -q "Contraseña permanente\*\* | \*\*PRESENTE" docs/estado-sesion.md'
t "estado-sesion advierte H-19 (audio/clipboard)" \
  bash -c 'grep -q "reset by the peer" docs/estado-sesion.md'

sect "H-28 local-ip-addr obsoleto al cambiar de red"
t "H-28 documentado" bash -c 'grep -q "H-28" docs/hallazgos.md'
t "H-28 explica que el ID/Tailscale no se afectan" \
  bash -c 'grep -q "LAN discovery" docs/hallazgos.md'
t "H-28 advierte que el proceso no relee el TOML" \
  bash -c 'grep -qi "no relee el TOML\|lee la config al arrancar" docs/hallazgos.md'
t "H-28 valida el TOML antes de aplicar" \
  bash -c 'grep -q "tomllib" docs/hallazgos.md'
t "H-28 propone sudoer acotado para el restart" \
  bash -c 'grep -q "NOPASSWD: /usr/bin/systemctl restart rustdesk" docs/hallazgos.md'

sect "H-27 herramienta reboot-remoto.sh"
t "existe reboot-remoto.sh" bash -c 'test -f reboot-remoto.sh'
t "es ejecutable" bash -c 'test -x reboot-remoto.sh'
t "sintaxis OK" bash -c 'bash -n reboot-remoto.sh'
t "tiene --help" bash -c './reboot-remoto.sh --help | grep -q "reinicio remoto"'
t "soporta --enable/--reboot/--verify/--disable/--all" \
  bash -c 'grep -q -- "--enable|--reboot|--verify|--disable|--all" reboot-remoto.sh'
t "usa NOPASSWD acotado (no ALL)" \
  bash -c 'grep -q "NOPASSWD: /usr/bin/systemctl reboot" reboot-remoto.sh'
t "valida con visudo -cf antes de aplicar" \
  bash -c 'grep -q "visudo -cf" reboot-remoto.sh'
t "documenta el rollback" bash -c 'grep -q -- "--disable" reboot-remoto.sh'
t "envia comandos con bash -s (objetivo fish)" \
  bash -c 'grep -q "bash -s" reboot-remoto.sh'
t "make-kit incluye reboot-remoto.sh" \
  bash -c 'grep -q "reboot-remoto.sh" make-kit.sh'
t "PASOS menciona la prueba de reinicio" \
  bash -c 'grep -q "reboot-remoto.sh --host" PASOS-EN-ORDEN.txt'

sect "H-33 inyeccion en sudoers via --user (reboot-remoto.sh)"
# Un --user con comilla simple podia inyectar una regla NOPASSWD: ALL valida
# por visudo -cf. Debe rechazarse el nombre antes de escribir nada.
t "rechaza un --user con comilla/inyeccion" \
  bash -c './reboot-remoto.sh --host "evil@1.2.3.4" --user "evil'"'"' ALL=(ALL) NOPASSWD: ALL #" --enable --dry-run 2>&1 | grep -qi "usuario invalido"'
t "rechaza usuario con espacios" \
  bash -c './reboot-remoto.sh --host "a b@1.2.3.4" --enable --dry-run 2>&1 | grep -qi "usuario invalido"'
t "el usuario llega como argumento al heredoc (no interpolado)" \
  bash -c 'grep -q "rsh_tty -- \"\$rule\"" reboot-remoto.sh'
t "valida el nombre de usuario con regex POSIX" \
  bash -c 'grep -qE "USER_RULE.*=~.*\[a-z_\]" reboot-remoto.sh'

sect "H-34 aviso de auth key por argv (instalar-todo.sh)"
# --authkey quedaba en el historial/ps sin avisar (AUTHKEY_POR_ARGV muerta).
t "usa AUTHKEY_POR_ARGV (ya no es variable muerta)" \
  bash -c 'grep -q "AUTHKEY_POR_ARGV" instalar-todo.sh && [ "$(grep -c AUTHKEY_POR_ARGV instalar-todo.sh)" -ge 2 ]'
t "avisa que --authkey queda en historial/ps" \
  bash -c 'grep -q "queda en el historial" instalar-todo.sh'
t "sugiere --authkey-stdin" \
  bash -c 'grep -q "authkey-stdin" instalar-todo.sh'

sect "H-27 reinicio remoto (bloqueo sudo/polkit)"
t "H-27 documentado" bash -c 'grep -q "H-27" docs/hallazgos.md'
t "H-27 explica el bloqueo de polkit" \
  bash -c 'grep -qi "polkit\|InteractiveAuthorizationRequired" docs/hallazgos.md'
t "H-27 propone NOPASSWD acotado (no todo sudo)" \
  bash -c 'grep -q "NOPASSWD: /usr/bin/systemctl reboot" docs/hallazgos.md'
t "H-27 da el rollback" \
  bash -c 'grep -q "rm /etc/sudoers.d" docs/hallazgos.md'
t "H-27 advierte validar con visudo -cf" \
  bash -c 'grep -q "visudo -cf" docs/hallazgos.md'
t "estado-sesion registra la prueba de reinicio" \
  bash -c 'grep -q "Prueba de reinicio (unattended real): superada" docs/estado-sesion.md'
t "estado-sesion muestra boot_id distinto" \
  bash -c 'grep -q "fue un reinicio real" docs/estado-sesion.md'

sect "Prueba fuera de LAN: ruta directa vs LAN-local"
t "verify-offlan.sh distingue ruta directa de DERP" \
  bash -c 'grep -q "ruta DIRECTA (perforación de NAT)" verify-offlan.sh'
t "tailscale.md advierte de la trampa LAN-local" \
  bash -c 'grep -qi "no siempre significa.*fuera de la LAN\|trampa.*LAN-local" docs/tailscale.md'
t "tailscale.md: mismo IP publica = misma casa (prueba no vale)" \
  bash -c 'grep -q "la misma.*IP pública" docs/tailscale.md'
t "estado-sesion registra la confirmacion en PC real" \
  bash -c 'grep -q "Prueba A confirmada en PC real" docs/estado-sesion.md'
t "estado-sesion documenta la trampa LAN-local" \
  bash -c 'grep -q "la prueba LAN-local que parece fuera de LAN" docs/estado-sesion.md'
t "fuera de LAN verificado con 7 OK (sin datos reales)" \
  bash -c 'grep -q "7 OK" docs/estado-sesion.md'

sect "H-26 ubicación de la auth key en el panel de Tailscale"
t "H-26 documentado" bash -c 'grep -q "H-26" docs/hallazgos.md'
t "H-26 explica la ruta Settings -> Keys" \
  bash -c 'grep -q "pestaña .Keys.\|pestaña \"Keys\"" docs/hallazgos.md'
t "H-26 advierte que solo se muestra una vez" \
  bash -c 'grep -qi "solo se muestra una vez" docs/hallazgos.md'
t "tailscale.md tiene la guía de generación" \
  bash -c 'grep -q "Generar la auth key" docs/tailscale.md'
t "tailscale.md nombra la pestaña Keys" \
  bash -c 'grep -q "pestaña.*Keys" docs/tailscale.md'
t "setup-remote-target.sh apunta a login.tailscale.com" \
  bash -c 'grep -q "login.tailscale.com/admin/settings/keys" setup-remote-target.sh'
t "onboarding usa login.tailscale.com (no solo console)" \
  bash -c 'grep -q "login.tailscale.com/admin/settings/keys" docs/onboarding-cliente.md'

t "H-24 Fedora con capturador DRM (no el .rpm estándar)"
t "la función del .deb es portable (no _arch)" \
  bash -c 'grep -q "^install_rustdesk_unattended_deb()" setup-remote-target.sh'
t "Fedora intenta PRIMERO el .deb con DRM" \
  bash -c 'sed -n "/^    fedora)$/,/^      ;;$/p" lib/sr-t-rustdesk.sh | grep -q "install_rustdesk_unattended_deb"'
t "Fedora avisa si cae al .rpm estándar (sin DRM)" \
  bash -c 'grep -q "se instaló el .rpm estándar: SIN capturador DRM" lib/sr-t-rustdesk.sh'
t "Fedora sugiere el instalador especializado como alternativa" \
  bash -c 'grep -q "install-rustdesk-unattended-fedora.sh" lib/sr-t-rustdesk.sh'

sect "Hardening y comodidad (reporte GLM)"
t "ufw usa limit (rate-limit), no solo allow" \
  bash -c 'grep -q "ufw limit" lib/sr-t-ssh.sh'
t "firewalld tiene rate-limit" \
  bash -c 'grep -q "limit value=\"6/m\"" lib/sr-t-ssh.sh'
t "enable-drm-display-wake se APLICA (no solo sugiere)" \
  bash -c 'grep -q "_set_drm_wake" lib/sr-t-rustdesk.sh'
t "drm-wake valida el TOML tras escribirlo" \
  bash -c 'sed -n "/_set_drm_wake /,+20p" lib/sr-t-rustdesk.sh | grep -q tomllib'
t "verify-offlan autodetecta el peer (sin default 'fedora')" \
  bash -c '! grep -q "PEER=\"\${1:-fedora}\"" verify-offlan.sh && grep -q "autodetect" verify-offlan.sh'
t "verify-offlan no usa la función 'info' (colisiona con info(1))" \
  bash -c '! grep -qE "^info\(\)" verify-offlan.sh && grep -q "^say()" verify-offlan.sh'
t "instalar-todo corre --check UNA sola vez" \
  bash -c '[ "$(grep -c "setup-remote-target.sh --check" instalar-todo.sh)" -le 1 ]'
t "el kit lleva versión (.kit-version)" \
  bash -c 'grep -q "kit-version" make-kit.sh'
t "los backups del helper rotan (no acumulan)" \
  bash -c 'grep -q "tail -n +4" .rd-setpass-root.sh'
t "el helper remoto se limpia con trap" \
  bash -c 'grep -q "trap .*rm -f /tmp/rd-setpass-root.sh" rustdesk-password.sh'
t "referencia ya no presenta paru como ruta primaria en Arch" \
  bash -c 'grep -q "Ruta recomendada" docs/referencia.md'

sect "Calidad de código (shellcheck sin notas accionables)"
t "setup usa find (no ls) para el log más reciente" \
  bash -c 'grep -q "find \"\$logdir\" -maxdepth 1 -name" setup-remote-target.sh'
t "verify-offlan no usa sed para indentar" \
  bash -c '! grep -qE "echo .PING_OUT. \| sed" verify-offlan.sh'
t "setup documenta las notas intencionales de shellcheck" \
  bash -c 'grep -q "Notas de shellcheck que son INTENCIONALES" setup-remote-target.sh'
t "--help NO muestra el bloque de notas de shellcheck" \
  bash -c '! ./setup-remote-target.sh --help 2>&1 | grep -q "SC1091"'
t "make-kit usa find para listar el contenido" \
  bash -c 'grep -q "find \"\$DEST\" -maxdepth 1" make-kit.sh'

sect "H-25 paru en el repo (no compilar desde AUR)"
t "ensure_aur intenta el repo binario PRIMERO" \
  bash -c 'sed -n "/^ensure_aur()/,/^}/p" setup-remote-target.sh | grep -q "pacman -S --needed --noconfirm paru"'
t "ensure_aur cae al AUR solo si no está en el repo" \
  bash -c 'sed -n "/^ensure_aur()/,/^}/p" setup-remote-target.sh | grep -q "paru-bin"'
t "ensure_aur avisa que instaló sin compilar" \
  bash -c 'grep -q "instalado desde el repositorio (sin compilar)" setup-remote-target.sh'
t "referencia documenta los requisitos del objetivo" \
  bash -c 'grep -q "Requisitos del PC objetivo" docs/referencia.md'
t "referencia dice que paru NO hace falta a mano" \
  bash -c 'grep -q "no hace falta instalarlo a mano" docs/referencia.md'
t "INSTALAR.md explica la cascada de paru" \
  bash -c 'grep -q "Hay que instalar .paru. a mano? NO" INSTALAR.md'
t "PASOS-EN-ORDEN avisa que no hay que instalar nada a mano" \
  bash -c 'grep -q "NO hace falta instalar nada a mano" PASOS-EN-ORDEN.txt'
t "PASOS avisa que CachyOS virgen no tiene paru" \
  bash -c 'grep -q "normal que no haya paru" PASOS-EN-ORDEN.txt'

sect "PC virgen: instalación de RustDesk sin ayudante de AUR"
t "existe la vía .deb sin AUR" \
  bash -c 'grep -q "^install_rustdesk_unattended_deb()" setup-remote-target.sh'
t "la vía .deb verifica el sha256" \
  bash -c 'sed -n "/^install_rustdesk_unattended_deb()/,/^}/p" setup-remote-target.sh | grep -q "sha256"'
t "la vía .deb comprueba la red antes" \
  bash -c 'sed -n "/^install_rustdesk_unattended_deb()/,/^}/p" setup-remote-target.sh | grep -q "github.com"'
t "la vía .deb instala libdrmtap" \
  bash -c 'sed -n "/^install_rustdesk_unattended_deb()/,/^}/p" setup-remote-target.sh | grep -q "libdrmtap"'
t "arch prueba 3 vías en cascada" \
  bash -c 'grep -q "^install_rustdesk_arch_unattended()" setup-remote-target.sh'
t "la cascada usa el .deb si el AUR falla" \
  bash -c 'sed -n "/^install_rustdesk_arch_unattended()/,/^}/p" setup-remote-target.sh | grep -q "install_rustdesk_unattended_deb"'
t "avisa si falta red antes de instalar RustDesk" \
  bash -c 'grep -q "SIN CONEXIÓN a aur.archlinux.org" setup-remote-target.sh'
t "tailscale avisa si falta red" \
  bash -c 'grep -q "SIN CONEXIÓN a internet: no puedo instalar Tailscale" setup-remote-target.sh'
t "tailscale espera a que tailscaled arranque" \
  bash -c 'grep -q "tailscaled NO arrancó" setup-remote-target.sh'
t "tailscale up muestra su error real" \
  bash -c 'grep -q "tailscale up FALLÓ" setup-remote-target.sh'
t "tailscale espera la IP (hasta 15s)" \
  bash -c 'grep -q "seq 1 15" setup-remote-target.sh'
t "--check diagnostica dependencias faltantes" \
  bash -c 'grep -q "Dependencias que suelen faltar" setup-remote-target.sh'
t "--check informa si hay AUR helper" \
  bash -c 'grep -q "ayudante de AUR:" setup-remote-target.sh'
t "--check comprueba internet" \
  bash -c 'grep -q "internet: github.com alcanzable" setup-remote-target.sh'
t "existe ensure_aur (instala paru si falta)" \
  bash -c 'grep -q "^ensure_aur()" setup-remote-target.sh'
t "ensure_aur usa paru-bin (precompilado, sin build largo)" \
  bash -c 'grep -q "paru-bin" setup-remote-target.sh'
t "ensure_aur instala git+base-devel" \
  bash -c 'grep -q "git base-devel" setup-remote-target.sh'
t "ensure_aur respeta --dry-run" \
  bash -c 'sed -n "/^ensure_aur()/,/^}/p" setup-remote-target.sh | grep -q "DRY_RUN"'
t "setup_rustdesk usa ensure_aur, no detect_aur" \
  bash -c 'grep -q "aur=\"\$(ensure_aur)\"" setup-remote-target.sh'
t "el error final da los pasos manuales completos" \
  bash -c 'grep -q "makepkg -si" setup-remote-target.sh'
t "--help documenta el flujo --all con authkey" \
  bash -c './setup-remote-target.sh --help 2>&1 | grep -q "authkey"'
t "--help menciona la contraseña permanente" \
  bash -c './setup-remote-target.sh --help 2>&1 | grep -q "rustdesk-password.sh"'
t "--help enlaza INSTALAR.md" \
  bash -c './setup-remote-target.sh --help 2>&1 | grep -q "INSTALAR.md"'

sect "Tailscale integrado en setup-remote-target.sh"
t "setup acepta --tailscale" \
  bash -c './setup-remote-target.sh --tailscale --dry-run --yes 2>&1 | grep -q "Tailscale"'
t "setup acepta --authkey" \
  bash -c 'grep -q "\-\-authkey" setup-remote-target.sh'
t "setup valida el prefijo tskey-" \
  bash -c 'grep -q "tskey-" setup-remote-target.sh'
t "setup hace enable de tailscaled" \
  bash -c 'grep -q "enable --now tailscaled" setup-remote-target.sh'
t "setup --check diagnostica Tailscale" \
  bash -c 'grep -q "Tailscale (acceso fuera de la LAN)" setup-remote-target.sh'
t "setup --all incluye tailscale" \
  bash -c 'grep -q "DO_RUSTDESK=1; DO_SSH=1; DO_TAILSCALE=1" setup-remote-target.sh'
t "setup detecta tailscale ya unido (idempotente)" \
  bash -c 'grep -q "Ya está en la tailnet" setup-remote-target.sh'
t "setup usa --accept-dns=false (no romper DNS local)" \
  bash -c 'grep -q "accept-dns=false" setup-remote-target.sh'

sect "Auth key fuera del historial (seguridad)"
# La key en argv queda en ~/.bash_history y en 'ps'. Los scripts ofrecen
# leerla por STDIN y no pasarla por argv a los hijos (variable de entorno).
t "instalar-todo acepta --authkey-stdin" \
  bash -c 'grep -q -- "--authkey-stdin" instalar-todo.sh'
t "instalar-todo lee la key con read -s (sin eco)" \
  bash -c 'grep -q "read -rs" instalar-todo.sh'
t "instalar-todo NO pasa la key por argv al hijo" \
  bash -c '! grep -q -- "--authkey \"\$AUTHKEY\"" instalar-todo.sh'
t "instalar-todo exporta KIT_AUTHKEY (entorno, no argv)" \
  bash -c 'grep -q "export KIT_AUTHKEY" instalar-todo.sh'
# No se exige exit 0: el dry-run completo llama a setup-remote-target.sh, que
# depende de herramientas del host (getent, etc.) que en este entorno CI/Termux
# pueden faltar. Se verifica que la key por STDIN se LEA y valide (el objetivo
# de este test), no el éxito del dry-run entero.
t "instalar-todo --authkey-stdin lee y valida la key" \
  bash -c 'printf %s tskey-auth-TESTSTDIN | ./instalar-todo.sh --dry-run --authkey-stdin --rdpass ClaveSegura123 2>&1 | grep -q "auth key con formato válido"'
t "la key por STDIN NO se imprime completa en la salida" \
  bash -c '! printf %s tskey-auth-SECRETO999XYZ | ./instalar-todo.sh --dry-run --authkey-stdin --rdpass ClaveSegura123 2>&1 | grep -q SECRETO999XYZ'
t "setup acepta --authkey-env" \
  bash -c 'grep -q -- "--authkey-env" setup-remote-target.sh'
t "setup --authkey-env sin KIT_AUTHKEY falla" \
  bash -c '! env -u KIT_AUTHKEY ./setup-remote-target.sh --authkey-env >/dev/null 2>&1'
t "setup acepta --authkey-stdin" \
  bash -c 'grep -q -- "--authkey-stdin" setup-remote-target.sh'
t "unir-tailscale acepta --key-stdin" \
  bash -c 'grep -q -- "--key-stdin" unir-tailscale.sh'
t "unir-tailscale lee la key con read -s" \
  bash -c 'grep -q "read -rs" unir-tailscale.sh'
t "unir-tailscale avisa si la key vino por argv" \
  bash -c 'grep -q "KEY_POR_ARGV" unir-tailscale.sh'

sect "H-19 os error 104 (audio/portapapeles en bucle)"
tdoc "H-19 documentado" bash -c 'grep -q "H-19" docs/hallazgos.md'
t "H-19 explica la causa (arboard/X11)" \
  bash -c 'grep -q "arboard" docs/hallazgos.md'
t "H-19 da la mitigación desde el cliente" \
  bash -c 'grep -q "disable_audio" docs/hallazgos.md'
t "H-19 avisa validar el TOML tras editarlo" \
  bash -c 'grep -q "tomllib" docs/hallazgos.md'
t "estado-sesion registra la conexión confirmada" \
  bash -c 'grep -q "CONECTADO" docs/estado-sesion.md'
t "estado-sesion guarda la evidencia (libdrmtap/encoder)" \
  bash -c 'grep -q "libdrmtap loaded" docs/estado-sesion.md && grep -q "new encoder" docs/estado-sesion.md'

sect "H-16/H-17/H-18 documentación de hallazgos"
tdoc "H-14 documentado" bash -c 'grep -q "H-14" docs/hallazgos.md'
tdoc "H-15 documentado" bash -c 'grep -q "H-15" docs/hallazgos.md'
t "H-16 documentado (rutas de log)" \
  bash -c 'grep -q "plasmalogin/.local/share/logs" docs/hallazgos.md'
t "H-17 documentado (sin CLI de conexión)" \
  bash -c 'grep -q "no tiene CLI de conexión" docs/hallazgos.md'
t "H-18 documentado (server anclado a seat0)" \
  bash -c 'grep -q "seat0" docs/hallazgos.md'
t "README enlaza el instalador unattended" \
  bash -c 'grep -q "install-rustdesk-unattended-fedora.sh" README.md'
t "README enlaza el generador de contraseña" \
  bash -c 'grep -q "rustdesk-password.sh" README.md'
t "H-14 explica la causa (libdrmtap ausente)" \
  bash -c 'grep -q "libdrmtap" docs/hallazgos.md'
t "H-15 explica el formato del hash" \
  bash -c 'grep -q "SHA256(password || salt)" docs/hallazgos.md'

sect "clip-vm.sh (puente de portapapeles por SSH)"
t "clip-vm define VM_DEFAULT configurable (CLIP_VM)" \
  bash -c 'grep -q "CLIP_VM:-\|CLIP_VM:-" clip-vm.sh'
t "clip-vm usa BatchMode (no pide password)" \
  bash -c 'grep -q "BatchMode=yes" clip-vm.sh'
t "clip-vm NO usa --paste-once (rompia el portapapeles)" \
  bash -c '! grep -vE "^\s*#" clip-vm.sh | grep -q "paste-once"'
t "clip-vm desacopla wl-copy con nohup+disown" \
  bash -c 'grep -q "nohup wl-copy" clip-vm.sh && grep -q "disown" clip-vm.sh'
t "clip-vm documenta por que existe (vdagent Wayland)" \
  bash -c 'grep -qi "spice-vdagent\|vdagent" clip-vm.sh'
t "clip-vm soporta get|put|show" \
  bash -c 'for c in get put show; do grep -q "$c)" clip-vm.sh || exit 1; done'
t "clip-vm manda bash -s (el guest puede ser fish, H-23)" \
  bash -c 'grep -q "bash -s" clip-vm.sh'
t "clip-vm define guest_env (descubre WAYLAND_DISPLAY)" \
  bash -c 'grep -q "^guest_env()" clip-vm.sh'
t "clip-vm detecta el entorno Wayland del guest" \
  bash -c 'grep -q "guest_env" clip-vm.sh'
t "clip-vm exporta WAYLAND_DISPLAY en los 3 comandos" \
  bash -c 'n=$(grep -c "export WAYLAND_DISPLAY" clip-vm.sh); test "$n" -ge 3'
t "clip-vm desacopla tambien el wl-copy del get (no cuelga)" \
  bash -c 'awk "/^  get\)/,/^  ;;/" clip-vm.sh | grep -q "nohup wl-copy"'

sect "Hallazgo H-09 (MagicDNS / resolved-NM)"
tdoc "docs/hallazgos.md documenta H-09" bash -c 'grep -q "H-09" docs/hallazgos.md'
tdoc "H-09 menciona resolved-NM"       bash -c 'grep -qi "resolved-nm\|systemd-resolved" docs/hallazgos.md'
tdoc "H-09 menciona resolv.conf stub"  bash -c 'grep -q "stub-resolv.conf" docs/hallazgos.md'
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
         docs/onboarding-cliente.md docs/hallazgos.md docs/estado-sesion.md; do
  t "existe $d" test -f "$d"
done
tdoc "README enlaza hallazgos"     bash -c 'grep -q "docs/hallazgos.md" README.md'
tdoc "README enlaza onboarding"    bash -c 'grep -q "docs/onboarding-cliente.md" README.md'
tdoc "README enlaza tailscale"     bash -c 'grep -q "docs/tailscale.md" README.md'
tdoc "README enlaza estado-sesion" bash -c 'grep -q "docs/estado-sesion.md" README.md'
# El estado de sesión debe registrar el entorno de prueba para poder retomarlo
tdoc "estado-sesion registra la IP de la VM" bash -c 'grep -q "192.168.122.11" docs/estado-sesion.md'
tdoc "estado-sesion avisa que el guest es Wayland" bash -c 'grep -qi "wayland" docs/estado-sesion.md'
tdoc "estado-sesion registra el bloqueo de sudo" bash -c 'grep -qi "sudo.*contraseña\|pide contraseña" docs/estado-sesion.md'
# La doc debe distinguir roles (operador no necesita sshd; el objetivo sí)
tdoc "README distingue OPERADOR/OBJETIVO" bash -c 'grep -q "PC objetivo" README.md && grep -q "PC operador" README.md'
t "referencia aclara que el operador no necesita sshd" \
  bash -c 'grep -qE "sshd.*no necesita|no necesita.*sshd" docs/referencia.md'
# El agente IA (pi) es herramienta del OPERADOR: NO se instala en el cliente.
t "referencia: el agente IA vive solo en el operador" \
  bash -c 'grep -qE "pi.*vive SOLO en el operador|solo aqu.*NUNCA" docs/referencia.md'
t "referencia: el agente NO se instala en el objetivo" \
  bash -c 'sed "s/^> //" docs/referencia.md | tr "\n" " " | grep -qiE "no se instala ni se configura en el PC objetivo"'
t "referencia: explica que pi no tiene modelos gratis" \
  bash -c 'grep -qi "no incluye modelos gratuitos fiables" docs/referencia.md'
t "guia-desde-cero: pi corre solo en el operador" \
  bash -c 'grep -qE "pi.*corre SOLO en tu PC" docs/guia-desde-cero.md'
t "estado-sesion registra el modelo de producto" \
  bash -c 'grep -q "Modelo de producto" docs/estado-sesion.md'
t "estado-sesion: pi solo en el operador" \
  bash -c 'grep -q "SOLO en el PC del operador" docs/estado-sesion.md'

if [[ -n "$HOST" ]]; then
  # OJO 1: el shell del objetivo puede ser fish (CachyOS lo usa por defecto).
  # Todos los comandos remotos se envuelven para que la sintaxis
  # ($(...), >/dev/null 2>&1, awk "{print $1}") funcione siempre.
  #
  # OJO 2: NO usar `ssh host bash -lc 'cmd'` con $RH. Al expandir $RH, ssh
  # recibe los argumentos por separado y bash se come los flags del comando
  # (p.ej. `tailscale ip -4` -> bash interpreta -4 y muestra la AYUDA).
  # Solución: enviar el comando por STDIN a `bash -s`, que no reinterpreta
  # argumentos.
  #
  # rsh: ejecuta un comando en el objetivo, compatible con fish y bash local.
  # Evita el 'expansion splitting' usando un heredoc por stdin.
  rsh() { printf '%s\n' "$*" | ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" bash -s; }
  sect "Remoto: $HOST"
  t "SSH alcanza el host"        rsh 'hostname'
  t "inventory remoto"           ./inventory.sh "$HOST"
  t "inventory remoto JSON"      bash -c "./inventory.sh --json '$HOST' | jq empty"
  # 'make check' solo existe en el repo (el kit no copia el Makefile).
  if [[ $IN_REPO -eq 1 ]]; then
    t "make check"                 make HOST="$HOST" check
  else
    sk "make check (requiere el repo)"
  fi

  sect "Hallazgos en el host remoto"
  # Todos los comandos van por rsh(), que envía el comando por stdin a
  # `bash -s` en el objetivo: funciona aunque el shell remoto sea fish y sin
  # el problema de argumentos separados.

  # H-06/H-01: servicios enabled (sobreviven reboot)
  t "H-06 sshd enabled"          rsh 'systemctl is-enabled sshd 2>/dev/null || systemctl is-enabled ssh 2>/dev/null'
  t "RustDesk enabled"           rsh 'systemctl is-enabled rustdesk 2>/dev/null'
  t "RustDesk activo ahora"      rsh 'systemctl is-active rustdesk 2>/dev/null | grep -q active'

  # ¿Tiene Tailscale el objetivo? (si no: se omite, puede ser acceso solo por LAN)
  if rsh 'command -v tailscale >/dev/null 2>&1'; then
    t "H-01 tailscaled enabled"    rsh 'systemctl is-enabled tailscaled 2>/dev/null'
    t "H-01 Tailscale activo"      rsh 'systemctl is-active tailscaled 2>/dev/null | grep -q active'
    t "H-01 tiene IP Tailscale"    rsh 'tailscale ip -4 2>/dev/null | grep -qE "^100\."'
  else
    sk "H-01 Tailscale no instalado en el objetivo (acceso por LAN)"
  fi

  # H-02/H-04: la captura DRM solo aplica en Wayland. En X11 no aplica.
  # Detección de la sesión GRAFICA: la de seat0, no la última de loginctl (H-11).
  remote_sess="$(rsh 'for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk "{print \$1}"); do t=$(loginctl show-session "$s" -p Type --value 2>/dev/null); case "$t" in wayland|x11) echo "$t"; break;; esac; done' 2>/dev/null | head -1)"
  if [[ "$remote_sess" == "wayland" ]]; then
    t "H-04 captura DRM con sesión Wayland" \
      rsh 'grep -q "drm: consumer cache" ~/.local/share/logs/RustDesk/server/rustdesk_rCURRENT.log 2>/dev/null'
  elif [[ -n "$remote_sess" ]]; then
    sk "H-04 sesión $remote_sess en el objetivo: captura DRM no aplica"
  else
    sk "H-04 no se pudo determinar el tipo de sesión del objetivo"
  fi

  # H-03: tipo de login screen del host remoto
  if rsh 'pgrep -f plasmalogin >/dev/null 2>&1 || pgrep -f "sddm|gdm|lightdm" >/dev/null 2>&1'; then
    if rsh 'pgrep -f startplasma-wayland >/dev/null 2>&1'; then
      t "H-03 login screen Wayland (allow-logon-screen-password no aplica)" true
    else
      t "H-03 login screen presente (revisar tipo)" true
    fi
  else
    sk "H-03 sin greeter visible en el host remoto"
  fi

  # H-05: conexión Tailscale. Solo si AMBOS lados tienen Tailscale.
  if command -v tailscale >/dev/null 2>&1 \
     && rsh 'command -v tailscale >/dev/null 2>&1'; then
    peer="$(rsh 'tailscale ip -4 2>/dev/null' | head -1)"
    if [[ "$peer" =~ ^100\. ]]; then
      # OJO: 'tailscale ping' NO acepta -c; sin flag hace intentos y sale solo
      t "H-05 tailscale ping responde ($peer)" bash -c "tailscale ping '$peer' 2>&1 | grep -q pong"
    else
      sk "H-05 el objetivo tiene tailscale pero sin IP 100.x"
    fi
  elif ! command -v tailscale >/dev/null 2>&1; then
    sk "H-05 tailscale no instalado en el operador"
  else
    sk "H-05 el objetivo no tiene Tailscale (acceso por LAN): H-05 no aplica"
  fi
else
  sect "Remoto"
  printf '%s▲%s Omitido (pasa un host: ./tests.sh USUARIO@192.168.1.20)\n' "$Y" "$N"
  SKIP=$((SKIP+1))
fi

sect "update.sh (mantenimiento)"
t "bash -n update.sh"              bash -n update.sh
t "update.sh es ejecutable"        test -x update.sh
t "--help sale 0"                  ./update.sh --help
tj "opción inválida falla"          ./update.sh --nope
t "--check funciona sin root"       ./update.sh --check
t "--check sale 0 (consultar no es fallo)" \
  bash -c './update.sh --check >/dev/null 2>&1'
t "--check no menciona aplicar cambios" \
  bash -c './update.sh --check 2>&1 | grep -q "MODO CONSULTA"'

# --- comportamiento real (no grep de cadenas) ---
t "--dry-run funciona sin root"       bash -c './update.sh --dry-run >/dev/null 2>&1'
t "--dry-run NO toca el sistema" \
  bash -c './update.sh --dry-run 2>&1 | grep -q "MODO SIMULACRO"'
tj "sin TTY y sin --yes ABORTA (no asume sí)" \
  bash -c './update.sh < /dev/null >/dev/null 2>&1'
# Para probar el camino del TTY sin depender de ser root, se extrae confirmar()
# del propio update.sh y se ejecuta aislada con stdin cerrado (comportamiento real).
t "confirmar() sin TTY rechaza (extraída del script)" \
  bash -c 'ASSUME_YES=0; err(){ :; }; eval "$(sed -n "/^confirmar()/,/^}/p" update.sh)"; confirmar "?" < /dev/null; test $? -ne 0'
t "confirmar() con --yes acepta sin preguntar" \
  bash -c 'ASSUME_YES=1; err(){ :; }; eval "$(sed -n "/^confirmar()/,/^}/p" update.sh)"; confirmar "?" < /dev/null'
tj "--yes sin root rechaza" \
  bash -c './update.sh --yes < /dev/null >/dev/null 2>&1'
t "--yes sin root dice 'se necesita root'" \
  bash -c './update.sh --yes < /dev/null 2>&1 | grep -q "se necesita root"'

# --- el .deb DEBE ser el de DRM, y con sha256 verificado (H-14/H-24) ---
t "usa el asset unattended-wayland (DRM), no el estándar" \
  bash -c 'grep -q "rustdesk-unattended-wayland-\${RD_VERSION}-x86_64\.deb" update.sh'
tj "NO descarga el .deb estándar sin DRM" \
  bash -c 'grep -qE "releases/download/\$\{RD_VERSION\}/rustdesk-\$\{RD_VERSION\}-x86_64\.deb" update.sh'
t "verifica sha256 antes de instalar" \
  bash -c 'grep -q "sha256sum .*RD_SHA256\|actual.*RD_SHA256" update.sh'
t "se NIEGA a instalar si el sha256 no coincide" \
  bash -c 'grep -q "sha256 NO coincide" update.sh'
t "comprueba libdrmtap tras instalar (anti-regresión H-14)" \
  bash -c 'grep -q "tiene_drm\|libdrmtap" update.sh'
# tiene_drm() es crítica (si falla, update.sh rechazaría una instalación buena
# o aceptaría una sin DRM). Se prueba de verdad con archivos simulados:
# el .deb real instala libdrmtap.so.0.5.8 + symlink libdrmtap.so.0, NO .so pelado.
# Se escribe un script auxiliar en un tmp para no pelear con el escaping.
t "tiene_drm detecta libdrmtap.so.0.5.8 (caso real)" \
  bash -c 'W=$(mktemp -d); mkdir -p "$W/usr/lib/rustdesk"; : > "$W/usr/lib/rustdesk/libdrmtap.so.0.5.8"; ln -s libdrmtap.so.0.5.8 "$W/usr/lib/rustdesk/libdrmtap.so.0"; awk "/^tiene_drm\\(\\)\\{/,/^\\}/{print}" update.sh | sed "s#/usr/lib/rustdesk#$W/usr/lib/rustdesk#g" > "$W/fn.sh"; printf "%s\n" "source $W/fn.sh" "tiene_drm" > "$W/run.sh"; bash "$W/run.sh"; rc=$?; rm -rf "$W"; test $rc -eq 0'
t "tiene_drm NO da falso positivo sin libdrmtap" \
  bash -c 'W=$(mktemp -d); mkdir -p "$W/usr/lib/rustdesk"; awk "/^tiene_drm\\(\\)\\{/,/^\\}/{print}" update.sh | sed "s#/usr/lib/rustdesk#$W/usr/lib/rustdesk#g" > "$W/fn.sh"; printf "%s\n" "source $W/fn.sh" "tiene_drm" > "$W/run.sh"; bash "$W/run.sh"; rc=$?; rm -rf "$W"; test $rc -ne 0'
t "tiene_drm NO usa '-e glob' roto (SC2144)" \
  bash -c '! grep -qE -- "-e .*libdrmtap\.so\.\*" update.sh'

# check_drmtap_deps(): el .deb inyectado no lo conoce pacman/dnf; si una lib
# del sistema cambia de ABI, el DRM muere en silencio. Se prueba de verdad con
# ldd simulado (no resuelto -> rc 1, resuelto -> rc 0).
t "check_drmtap_deps FALLA si libdrm no resuelve" \
  bash -c 'W=$(mktemp -d); mkdir -p "$W/usr/lib/rustdesk"; : > "$W/usr/lib/rustdesk/libdrmtap.so.0.5.8"; { echo "warn(){ :; }"; echo "info(){ :; }"; echo "ok(){ :; }"; echo "PM=pacman"; awk "/^check_drmtap_deps\\(\\)\\{/,/^\\}/{print}" update.sh | sed "s#/usr/lib/rustdesk#$W/usr/lib/rustdesk#g"; } > "$W/fn.sh"; cat "$W/fn.sh" - > "$W/run.sh" <<EOF
ldd(){ echo "not found"; }
check_drmtap_deps
exit \$?
EOF
bash "$W/run.sh"; rc=$?; rm -rf "$W"; test $rc -ne 0'
t "check_drmtap_deps PASA si todo resuelve" \
  bash -c 'W=$(mktemp -d); mkdir -p "$W/usr/lib/rustdesk"; : > "$W/usr/lib/rustdesk/libdrmtap.so.0.5.8"; { echo "warn(){ :; }"; echo "info(){ :; }"; echo "ok(){ :; }"; echo "PM=pacman"; awk "/^check_drmtap_deps\\(\\)\\{/,/^\\}/{print}" update.sh | sed "s#/usr/lib/rustdesk#$W/usr/lib/rustdesk#g"; } > "$W/fn.sh"; cat "$W/fn.sh" - > "$W/run.sh" <<EOF
ldd(){ echo "libdrm.so.2 => /usr/lib/libdrm.so.2"; }
check_drmtap_deps
exit \$?
EOF
bash "$W/run.sh"; rc=$?; rm -rf "$W"; test $rc -eq 0'
t "setup-remote-target llama a check_drmtap_deps tras inyectar el .deb" \
  bash -c 'grep -q "check_drmtap_deps ||" setup-remote-target.sh'
sect "Arch: RustDesk completo (.desktop, iconos, bandeja, deps del binario)"
t "la vía .deb copia los .desktop (si no, no aparece en el menú)" \
  bash -c 'grep -q "usr/share/applications" setup-remote-target.sh'
t "la vía .deb copia los iconos" \
  bash -c 'grep -q "usr/share/icons" setup-remote-target.sh'
t "existe maybe_install_appindicator" \
  bash -c 'grep -q "^maybe_install_appindicator()" setup-remote-target.sh'
t "cubre las 3 familias para el appindicator" \
  bash -c 'grep -A4 "case \"\$DISTRO_FAMILY\" in" setup-remote-target.sh | grep -q "libayatana-appindicator3-1" && grep -q "libayatana-appindicator-gtk3" setup-remote-target.sh'
t "el appindicator es OPCIONAL (no aborta)" \
  bash -c 'grep -B6 "^maybe_install_appindicator()" setup-remote-target.sh | grep -qi "OPCIONAL"'
t "existe check_rustdesk_bin_deps" \
  bash -c 'grep -q "^check_rustdesk_bin_deps()" setup-remote-target.sh'
t "check_rustdesk_bin_deps ignora libcuda/libnvidia (no son error)" \
  bash -c 'grep -q "grep -v .libcuda\\|libnvidia" setup-remote-target.sh'
t "el .deb llama a check_rustdesk_bin_deps" \
  bash -c 'grep -q "check_rustdesk_bin_deps ||" setup-remote-target.sh'
t "check_rustdesk_bin_deps PASA con libs resueltas" \
  bash -c 'W=$(mktemp -d); mkdir -p "$W/bin"; : > "$W/bin/rustdesk"; { echo "warn(){ :; }"; echo "info(){ :; }"; echo "ok(){ :; }"; sed -n "/^check_rustdesk_bin_deps() {/,/^}/p" setup-remote-target.sh; } > "$W/fn.sh"; printf "ldd(){ echo %s; echo %s; }\ncheck_rustdesk_bin_deps\nexit \$?\n" "\"libgtk-3.so.0 => /usr/lib/libgtk-3.so.0\"" "\"libcuda.so.1 => not found\"" >> "$W/fn.sh"; sed -i "s#/usr/share/rustdesk/rustdesk#$W/bin/rustdesk#g;s#/usr/bin/rustdesk#$W/bin/nope#g" "$W/fn.sh"; bash "$W/fn.sh"; rc=$?; rm -rf "$W"; test $rc -eq 0'
t "check_rustdesk_bin_deps FALLA si falta una lib real" \
  bash -c 'W=$(mktemp -d); mkdir -p "$W/bin"; : > "$W/bin/rustdesk"; { echo "warn(){ :; }"; echo "info(){ :; }"; echo "ok(){ :; }"; sed -n "/^check_rustdesk_bin_deps() {/,/^}/p" setup-remote-target.sh; } > "$W/fn.sh"; printf "ldd(){ echo %s; }\ncheck_rustdesk_bin_deps\nexit \$?\n" "\"libgtk-3.so.0 => not found\"" >> "$W/fn.sh"; sed -i "s#/usr/share/rustdesk/rustdesk#$W/bin/rustdesk#g;s#/usr/bin/rustdesk#$W/bin/nope#g" "$W/fn.sh"; bash "$W/fn.sh"; rc=$?; rm -rf "$W"; test $rc -ne 0'

# check_wayland_capture_stack(): en Wayland, si el DRM falla RustDesk cae al
# portal XDG (ScreenCast) + PipeWire. Si falta cualquiera, el desatendido no
# captura y el cliente doméstico ve negro. Se prueba de verdad con un árbol
# de portales simulado (no solo grep de cadenas).
sect "Pila de captura Wayland: portal XDG + PipeWire"
t "existe check_wayland_capture_stack" \
  bash -c 'grep -q "^check_wayland_capture_stack()" setup-remote-target.sh'
t "el diagnóstico llama a check_wayland_capture_stack" \
  bash -c 'grep -q "check_wayland_capture_stack ||" setup-remote-target.sh'
t "check_wayland_capture_stack PASA con portal kde + pipewire" \
  bash -c 'W=$(mktemp -d); mkdir -p "$W/portals"; : > "$W/portals/kde.portal"; { echo "warn(){ :; }"; echo "info(){ :; }"; echo "ok(){ :; }"; echo "TARGET_USER=root"; sed -n "/^check_wayland_capture_stack() {/,/^}/p" setup-remote-target.sh | sed "s#/usr/share/xdg-desktop-portal/portals#$W/portals#g"; } > "$W/fn.sh"; printf "pipewire(){ echo pipewire 1.0.0; }\nrunuser(){ shift; shift; \"\$\"\"@\"; }\ncommand(){ return 0; }\ncheck_wayland_capture_stack\nexit \$?\n" >> "$W/fn.sh"; bash "$W/fn.sh"; rc=$?; rm -rf "$W"; test $rc -eq 0'
t "check_wayland_capture_stack FALLA sin backend del portal" \
  bash -c 'W=$(mktemp -d); mkdir -p "$W/portals"; : > "$W/portals/gtk.portal"; { echo "warn(){ :; }"; echo "info(){ :; }"; echo "ok(){ :; }"; echo "TARGET_USER=root"; sed -n "/^check_wayland_capture_stack() {/,/^}/p" setup-remote-target.sh | sed "s#/usr/share/xdg-desktop-portal/portals#$W/portals#g"; } > "$W/fn.sh"; printf "pipewire(){ echo pipewire 1.0.0; }\nrunuser(){ shift; shift; \"\$\"\"@\"; }\ncommand(){ return 0; }\ncheck_wayland_capture_stack\nexit \$?\n" >> "$W/fn.sh"; bash "$W/fn.sh"; rc=$?; rm -rf "$W"; test $rc -ne 0'
t "check_wayland_capture_stack FALLA sin pipewire" \
  bash -c 'W=$(mktemp -d); mkdir -p "$W/portals"; : > "$W/portals/kde.portal"; { echo "warn(){ :; }"; echo "info(){ :; }"; echo "ok(){ :; }"; echo "TARGET_USER=root"; sed -n "/^check_wayland_capture_stack() {/,/^}/p" setup-remote-target.sh | sed "s#/usr/share/xdg-desktop-portal/portals#$W/portals#g"; } > "$W/fn.sh"; printf "runuser(){ return 1; }\ncommand(){ return 1; }\ncheck_wayland_capture_stack\nexit \$?\n" >> "$W/fn.sh"; bash "$W/fn.sh"; rc=$?; rm -rf "$W"; test $rc -ne 0'
t "reconoce los 3 backends (kde/gnome/wlr)" \
  bash -c 'grep -qE "for b in kde gnome wlr" setup-remote-target.sh'
t "el mensaje sugiere el backend xdg-desktop-portal-kde" \
  bash -c 'grep -q "pkg_install_hint xdg-desktop-portal-kde" setup-remote-target.sh'
t "existe pkg_install_hint (mensajes de arreglo por familia)" \
  bash -c 'grep -q "^pkg_install_hint()" lib/sr-t-distro.sh'
t "pkg_install_hint da pacman en Arch" \
  bash -c 'W=$(mktemp -d); sed -n "/^pkg_install_hint() {/,/^}/p" lib/sr-t-distro.sh > "$W/fn.sh"; printf "DISTRO_FAMILY=arch\npkg_install_hint zstd ssh\n" >> "$W/fn.sh"; out=$(bash "$W/fn.sh"); rm -rf "$W"; test "$out" = "sudo pacman -S zstd ssh"'
t "pkg_install_hint da apt en Debian" \
  bash -c 'W=$(mktemp -d); sed -n "/^pkg_install_hint() {/,/^}/p" lib/sr-t-distro.sh > "$W/fn.sh"; printf "DISTRO_FAMILY=debian\npkg_install_hint pipewire\n" >> "$W/fn.sh"; out=$(bash "$W/fn.sh"); rm -rf "$W"; test "$out" = "sudo apt-get install -y pipewire"'
t "pkg_install_hint da dnf en Fedora" \
  bash -c 'W=$(mktemp -d); sed -n "/^pkg_install_hint() {/,/^}/p" lib/sr-t-distro.sh > "$W/fn.sh"; printf "DISTRO_FAMILY=fedora\npkg_install_hint pipewire\n" >> "$W/fn.sh"; out=$(bash "$W/fn.sh"); rm -rf "$W"; test "$out" = "sudo dnf install -y pipewire"'
t "H-40 documentado (clip-vm fish+wayland)" \
  bash -c 'grep -q "## H-40 — El portapapeles por SSH" docs/hallazgos.md'

# H-38: aviso de otros agentes de acceso remoto (dwagent/anydesk/...) y filtro
# de discos de tamaño 0 en el inventario. Ambos salieron de la prueba real
# contra un cliente (msi con DWAgent activo + locales es_ES).
sect "H-38: otros agentes de acceso remoto + inventario robusto a locale"
t "setup-remote-target avisa de otros agentes de acceso remoto" \
  bash -c 'grep -q "Otros agentes de acceso remoto" setup-remote-target.sh'
t "cubre dwagent, anydesk, teamviewer, etc." \
  bash -c 'grep -q "dwagent anydesk teamviewer chrome-remote-desktop" setup-remote-target.sh'
t "detecta procesos sueltos (no solo unidades systemd)" \
  bash -c 'grep -q "pgrep -x" setup-remote-target.sh'
t "avisa de conflicto por la captura (uinput/DRM/portal)" \
  bash -c 'grep -q "competir con RustDesk por la captura" setup-remote-target.sh'
t "inventory.sh fuerza LC_ALL=C (locale del cliente puede no ser inglés)" \
  bash -c 'test "$(grep -c "LC_ALL=C" inventory.sh)" -ge 5'
t "inventory.sh filtra discos de tamaño 0 (lectores vacíos)" \
  bash -c 'grep -q "0B" inventory.sh && grep -q "2>/dev/null | grep -vE" inventory.sh'
t "inventory.sh tiene fallback a /proc/cpuinfo para la CPU" \
  bash -c 'grep -q "/proc/cpuinfo" inventory.sh'
t "H-38 documentado" \
  bash -c 'grep -q "H-38" docs/hallazgos.md'
t "H-36 documentado" \
  bash -c 'grep -q "H-36" docs/hallazgos.md'
t "update.sh verifica dependencias en el paso final" \
  bash -c 'grep -q "check_drmtap_deps" update.sh'
t "reinicia el servicio rustdesk tras actualizar" \
  bash -c 'grep -q "systemctl restart rustdesk" update.sh'

# --- el sha256 del script COINCIDE con el asset real (dato duro) ---
t "RD_SHA256 es un hash sha256 válido (64 hex)" \
  bash -c 'grep -qE "RD_SHA256=\"[0-9a-f]{64}\"" update.sh'
t "RD_VERSION del update.sh == la de setup-remote-target.sh" \
  bash -c 'test "$(grep -oE "RD_VERSION=\"?[0-9.]+" update.sh | grep -oE "[0-9.]+")" = "$(grep -oE "RD_VERSION:-[0-9.]+" setup-remote-target.sh | grep -oE "[0-9.]+")"'
t "RD_SHA256 del update.sh == la de setup-remote-target.sh" \
  bash -c 'test "$(grep -oE "RD_SHA256=\"[0-9a-f]{64}\"" update.sh | grep -oE "[0-9a-f]{64}")" = "$(grep -oE "sha_ok=\"[0-9a-f]{64}\"" setup-remote-target.sh | grep -oE "[0-9a-f]{64}")"'

tdoc "el README documenta update.sh" \
  bash -c 'grep -q "update.sh" README.md'

# --- H-41: `ls` alias de eza contamina variables en fish ---
sect "H-41: scripts fish robustos al alias de ls (eza --color)"
t "H-41 recomienda path filter en vez de ls" \
  bash -c 'grep -q "path filter" docs/hallazgos.md'
t "H-41 documentado" \
  bash -c 'grep -q "H-41" docs/hallazgos.md'
t "H-41 menciona el riesgo de ls/eza" \
  bash -c 'grep -qiE "alias.*eza|eza.*color" docs/hallazgos.md'
t "recomienda path filter (no ls) en scripts fish" \
  bash -c 'grep -q "path filter" docs/hallazgos.md'

# --- H-42: migrar disco cambia machine-id -> cambia ID de RustDesk ---
sect "H-42: machine-id y ID de RustDesk"
t "H-42 documentado" \
  bash -c 'grep -q "H-42" docs/hallazgos.md'
t "H-42 menciona machine-id" \
  bash -c 'grep -q "machine-id" docs/hallazgos.md'
t "H-42 menciona que el ID de RustDesk cambia" \
  bash -c 'grep -qiE "ID de RustDesk.*camb|machine-id.*RustDesk|RustDesk.*machine-id" docs/hallazgos.md'
t "H-42 explica cómo conservar el ID (guardar/restaurar machine-id)" \
  bash -c 'grep -q "/var/lib/dbus/machine-id" docs/hallazgos.md'

# --- H-43: claves SSH compartidas entre operadores (mala practica) ---
sect "H-43: una identidad SSH por operador"
t "H-43 documentado" \
  bash -c 'grep -q "H-43" docs/hallazgos.md'
t "H-43 recomienda clave propia por operador" \
  bash -c 'grep -q "id_<rol>_operador\|id_<rol>\|_operador" docs/hallazgos.md'
t "docs/operador-multiple.md existe" \
  bash -c 'test -f docs/operador-multiple.md'
t "operador-multiple explica la autorizacion cruzada" \
  bash -c 'grep -qiE "autoriza|authorized_keys" docs/operador-multiple.md'
t "operador-multiple menciona flota.sh con dos bloques" \
  bash -c 'grep -qiE "CLIENTES|OPERADORES" docs/operador-multiple.md'
t "operador-multiple refiere a H-41, H-42 y H-43" \
  bash -c 'grep -q "H-41" docs/operador-multiple.md && grep -q "H-42" docs/operador-multiple.md && grep -q "H-43" docs/operador-multiple.md'
tdoc "el README enlaza docs/operador-multiple.md" \
  bash -c 'grep -q "operador-multiple.md" README.md'
tdoc "el README lista hallazgos hasta H-43" \
  bash -c 'grep -qE "H-01\.\.H-[0-9]+" README.md'
t "operador-multiple describe la lista fija de OPERADORES" \
  bash -c 'grep -q "set -l OPERADORES" docs/operador-multiple.md'

# --- H-44: migrar disco deja libvirt sin credential.secret ---
sect "H-44: libvirt tras migrar (credential.secret)"
t "H-44 documentado" \
  bash -c 'grep -q "H-44" docs/hallazgos.md'
t "H-44 menciona status=243/CREDENTIALS" \
  bash -c 'grep -q "243/CREDENTIALS" docs/hallazgos.md'
t "H-44 menciona credential.secret de systemd" \
  bash -c 'grep -q "credential.secret" docs/hallazgos.md'
t "H-44 menciona virt-secret-init-encryption" \
  bash -c 'grep -q "virt-secret-init-encryption" docs/hallazgos.md'
t "H-44 explica como regenerar la clave" \
  bash -c 'grep -q "secrets-encryption-key" docs/hallazgos.md'
t "H-44 enlaza con H-42 (machine-id)" \
  bash -c 'grep -q "H-42" docs/hallazgos.md'

# --- Kit Windows: scripts .ps1 + H-45..H-47 ---
# --- Kit Windows: sintaxis real con pwsh (si está disponible) ---
# H-50: se cazó un `}` sobrante en inventory.ps1 que rompía el script por
# completo. Si pwsh está instalado, se valida la SINTAXIS de verdad, no grep.
sect "Kit Windows: encoding (BOM UTF-8 para PowerShell 5.1)"
# H-51: Windows PowerShell 5.1 (el que trae Windows) lee los .ps1 como ANSI si
# no tienen BOM UTF-8. Con caracteres no-ASCII (—, á, é, box-drawing) el parser
# revienta con "Token '}' inesperado". Los .ps1 DEBEN llevar BOM UTF-8.
for f in windows/setup-remote-target.ps1 windows/inventory.ps1 windows/rustdesk-password.ps1 windows/diagnostico.ps1; do
  t "BOM UTF-8 presente: $(basename "$f")" \
    bash -c "head -c 3 '$f' | od -An -tx1 | grep -qi 'ef bb bf'"
done

sect "Kit Windows: sintaxis (pwsh)"
PWSH=""
for cand in pwsh "$HOME/.local/opt/pwsh/pwsh"; do
  command -v "$cand" >/dev/null 2>&1 && { PWSH="$cand"; break; }
done
if [[ -n "$PWSH" ]]; then
  for f in windows/setup-remote-target.ps1 windows/inventory.ps1 windows/rustdesk-password.ps1 windows/diagnostico.ps1; do
    t "sintaxis PowerShell valida: $(basename "$f")" \
      "$PWSH" -NoProfile -Command "\$t=\$null;\$e=\$null;\$null=[System.Management.Automation.Language.Parser]::ParseFile('$PWD/$f',[ref]\$t,[ref]\$e); if(\$e.Count){exit 1}"
  done
else
  sk "sintaxis PowerShell (falta pwsh; instalar o usar ~/.local/opt/pwsh)"
fi

t "H-50: setup-remote-target usa -RdPass (no es parametro muerto)" \
  bash -c 'grep -q "if (\$RdPass)" windows/setup-remote-target.ps1'
t "H-50: setup-remote-target usa -Hostname" \
  bash -c 'grep -q "if (\$Hostname)" windows/setup-remote-target.ps1'

sect "Kit Windows: diagnostico.ps1 (apagones/hardware)"
t "diagnostico.ps1 existe" test -f windows/diagnostico.ps1
t "detecta apagones bruscos (Kernel-Power 41)" \
  bash -c 'grep -q "Id=41,6008,1074" windows/diagnostico.ps1'
t "explica que 41=brusco y 1074=planeado" \
  bash -c 'grep -q "APAGÓN BRUSCO" windows/diagnostico.ps1 && grep -q "apagado planeado" windows/diagnostico.ps1'
t "lee temperaturas ACPI" \
  bash -c 'grep -q "MSAcpi_ThermalZoneTemperature" windows/diagnostico.ps1'
t "lee SMART / salud de discos" \
  bash -c 'grep -q "Get-StorageReliabilityCounter" windows/diagnostico.ps1 && grep -q "HealthStatus" windows/diagnostico.ps1'
t "lee RAM y errores de memoria" \
  bash -c 'grep -q "Win32_PhysicalMemory" windows/diagnostico.ps1 && grep -q "MemoryDiagnostics" windows/diagnostico.ps1'
t "detecta batería (portátil)" \
  bash -c 'grep -q "Win32_Battery" windows/diagnostico.ps1 && grep -q "batteryreport" windows/diagnostico.ps1'
t "busca minidumps de BSOD" \
  bash -c 'grep -q "Minidump" windows/diagnostico.ps1'
t "no cambia nada (solo lee)" \
  bash -c '! grep -qE "Remove-Item|Set-Service|Stop-Service|Restart-Computer|Format-Volume" windows/diagnostico.ps1'
t "guarda informe txt y json" \
  bash -c 'grep -q "diag.txt" windows/diagnostico.ps1 && grep -q "diag.json" windows/diagnostico.ps1'
t "el README de Windows documenta el diagnostico" \
  bash -c 'grep -q "diagnostico.ps1" windows/README.md'
t "el README da la linea irm | iex" \
  bash -c 'grep -q "diagnostico.ps1 | iex" windows/README.md'

sect "Kit Windows: setup-remote-target.ps1"
t "setup-remote-target.ps1 existe" test -f windows/setup-remote-target.ps1
t "setup reconoce -Check"   bash -c 'grep -q "\[switch\]\$Check" windows/setup-remote-target.ps1'
t "setup reconoce -DryRun"  bash -c 'grep -q "\[switch\]\$DryRun" windows/setup-remote-target.ps1'
t "setup reconoce -Apply"   bash -c 'grep -q "\[switch\]\$Apply" windows/setup-remote-target.ps1'
t "setup exige Administrador para -Apply" \
  bash -c 'grep -q "Test-Admin" windows/setup-remote-target.ps1 && grep -qi "Administrador" windows/setup-remote-target.ps1'
t "setup instala RustDesk (msi)" bash -c 'grep -q "rustdesk-.*-x86_64.msi" windows/setup-remote-target.ps1'
t "setup instala OpenSSH.Server (capability)" \
  bash -c 'grep -q "Add-WindowsCapability" windows/setup-remote-target.ps1'
t "setup crea regla de firewall SSH" \
  bash -c 'grep -q "New-NetFirewallRule" windows/setup-remote-target.ps1'
t "setup une Tailscale con la auth key" \
  bash -c 'grep -q "tailscale up --authkey" windows/setup-remote-target.ps1'
t "setup valida que la auth key empiece con tskey-auth-" \
  bash -c 'grep -q "tskey-auth-" windows/setup-remote-target.ps1'
t "setup reporta winget" bash -c 'grep -q "winget" windows/setup-remote-target.ps1'
t "setup H-45: Add-WindowsCapability en try/catch" \
  bash -c 'grep -q "no se pudo instalar OpenSSH.Server" windows/setup-remote-target.ps1'

sect "Kit Windows: inventory.ps1"
t "inventory.ps1 existe" test -f windows/inventory.ps1
t "H-45: inventory define su propia funcion Ok" \
  bash -c 'grep -q "function Ok" windows/inventory.ps1'
t "H-45: inventory define su propia funcion Warn" \
  bash -c 'grep -q "function Warn" windows/inventory.ps1'
t "H-45: inventory define Get-Markdown" \
  bash -c 'grep -q "function Get-Markdown" windows/inventory.ps1'
t "H-45: inventory guarda inventory.md" \
  bash -c 'grep -q '\''\$base.md'\'' windows/inventory.ps1'
t "inventory recoge servicios sshd/Tailscale/RustDesk" \
  grep -qF "foreach (\$s in 'sshd', 'Tailscale', 'RustDesk')" windows/inventory.ps1
t "inventory expone JSON" bash -c 'grep -q "ConvertTo-Json" windows/inventory.ps1'

sect "Kit Windows: rustdesk-password.ps1"
t "rustdesk-password.ps1 existe" test -f windows/rustdesk-password.ps1
t "H-46: documenta -Set -Password (no -Set 'Clave')" \
  bash -c 'grep -q -- "-Set -Password" windows/rustdesk-password.ps1'
t "H-46: README de Windows usa -Set -Password" \
  bash -c 'grep -q -- "-Set -Password" windows/README.md'
t "H-46: avisa si -Set sin -Password" \
  bash -c 'grep -q -- "-Set requiere -Password" windows/rustdesk-password.ps1'
t "H-47: usa 2>&1 | Out-Null (no 2>\$null) para el exe" \
  bash -c 'grep -q "2>&1 | Out-Null" windows/rustdesk-password.ps1'
tj "H-47: rustdesk-password NO usa 2>\$null con el exe nativo" \
  bash -c 'grep -q -- "& \$rdExe --password \$Password 2>\$null" windows/rustdesk-password.ps1'
t "rustdesk-password guia por GUI si la CLI no acepta --password" \
  bash -c 'grep -q "Contraseña permanente" windows/rustdesk-password.ps1'

sect "Kit Windows: docs y empaquetado"
t "existe windows/README.md" test -f windows/README.md
t "windows/README enlaza los hallazgos" \
  bash -c 'grep -q "H-45" windows/README.md && grep -q "H-47" windows/README.md'
t "H-45 documentado" bash -c 'grep -q "H-45" docs/hallazgos.md'
t "H-46 documentado" bash -c 'grep -q "H-46" docs/hallazgos.md'
t "H-47 documentado" bash -c 'grep -q "H-47" docs/hallazgos.md'
t "H-46 explica que [switch] es un flag, no un dato" \
  bash -c 'grep -q "es un ..flag." docs/hallazgos.md'
t "H-47 explica 2>&1 | Out-Null" \
  bash -c 'grep -q "2>&1 | Out-Null" docs/hallazgos.md'

tdoc "el README raiz lista el kit de Windows" \
  bash -c 'grep -q "windows/" README.md'
tdoc "el README lista hallazgos hasta H-47" \
  bash -c 'grep -qE "H-01\.\.H-[0-9]+" README.md'
t "make-kit.sh copia la carpeta windows" \
  bash -c 'grep -q "\$SCRIPT_DIR/windows" make-kit.sh'

sect "H-51/H-52/H-53 + acceso-primero"
t "H-51 documentado (BOM UTF-8)" \
  bash -c 'grep -q "H-51" docs/hallazgos.md && grep -q "BOM UTF-8" docs/hallazgos.md'
t "H-51 menciona Windows PowerShell 5.1" \
  bash -c 'grep -q "PowerShell 5.1" docs/hallazgos.md'
t "H-52 documentado (cache de GitHub raw)" \
  bash -c 'grep -q "H-52" docs/hallazgos.md'
t "H-53 documentado (acceso primero)" \
  bash -c 'grep -q "H-53" docs/hallazgos.md'
t "existe docs/acceso-primero.md" \
  test -f docs/acceso-primero.md
t "acceso-primero explica el orden correcto" \
  bash -c 'grep -qi "LO PRIMERO" docs/acceso-primero.md'
t "acceso-primero tiene checklist" \
  bash -c 'grep -q "Contraseña PERMANENTE fijada" docs/acceso-primero.md'
tdoc "el README enlaza docs/acceso-primero.md" \
  bash -c 'grep -q "acceso-primero.md" README.md'
t "H-54 documentado (modern standby vs apagon)" \
  bash -c 'grep -q "H-54" docs/hallazgos.md && grep -qi "Modern Standby" docs/hallazgos.md'
t "H-54 menciona sleepstudy y 506/507" \
  bash -c 'grep -q "sleepstudy" docs/hallazgos.md && grep -q "506/507" docs/hallazgos.md'
t "H-54 explica Id 41 vs 1074/506" \
  bash -c 'grep -q "Kernel-Power 41" docs/hallazgos.md'
t "H-55 documentado (EncodedCommand)" \
  bash -c 'grep -q "H-55" docs/hallazgos.md && grep -q "EncodedCommand" docs/hallazgos.md'
t "el README de Windows documenta EncodedCommand" \
  bash -c 'grep -q "EncodedCommand" windows/README.md'
t "H-56 documentado (no actualizar con overclock/exploits)" \
  bash -c 'grep -q "H-56" docs/hallazgos.md && grep -qi "overclock" docs/hallazgos.md'
t "H-56 menciona exploits/flags" \
  bash -c 'grep -qi "exploit" docs/hallazgos.md'
t "H-57 documentado (OpenSSH sin Windows Update)" \
  bash -c 'grep -q "H-57" docs/hallazgos.md'
t "H-57 usa Win32-OpenSSH directo" \
  bash -c 'grep -q "Win32-OpenSSH" docs/hallazgos.md'
t "H-57 explica el grupo Administradores en espanol" \
  bash -c 'grep -q "Administradores" docs/hallazgos.md'
tdoc "existe docs/caso-real-apagon-solo.md" \
  test -f docs/caso-real-apagon-solo.md
tdoc "el README enlaza el caso real de apagon" \
  bash -c 'grep -q "caso-real-apagon-solo.md" README.md'
tdoc "el caso real enlaza H-51..H-57" \
  bash -c 'grep -q "H-53" docs/caso-real-apagon-solo.md && grep -q "H-57" docs/caso-real-apagon-solo.md'

t "H-58 documentado (verificar overclock con log XTU)" \
  bash -c 'grep -q "H-58" docs/hallazgos.md && grep -q "XtuCore" docs/hallazgos.md'
t "H-58 explica OCMB invalid platform" \
  bash -c 'grep -q "invalid platform" docs/hallazgos.md'
t "H-58 dice que chip -H no admite OC" \
  bash -c 'grep -qE "chip .?-H|RaptorLake" docs/hallazgos.md'
t "H-59 documentado (no confundir XTU con OC)" \
  bash -c 'grep -q "H-59" docs/hallazgos.md'
tdoc "el caso real menciona la verificacion de XTU" \
  bash -c 'grep -q "H-58" docs/caso-real-apagon-solo.md'

# --- H-64/H-65: WoL remoto y operador Android (proot) ---
t "H-64 documentado (Tailscale no despierta equipos apagados)" \
  bash -c 'grep -q "H-64" docs/hallazgos.md'
t "H-64 explica que el magic packet es capa 2" \
  bash -c 'grep -q "capa 2" docs/hallazgos.md'
t "H-65 documentado (proot + userspace como alternativa)" \
  bash -c 'grep -q "H-65" docs/hallazgos.md'
t "H-60/H-61/H-63 de la otra sesion siguen" \
  bash -c 'grep -q "H-60" docs/hallazgos.md && grep -q "H-61" docs/hallazgos.md && grep -q "H-63" docs/hallazgos.md'
tdoc "existe docs/wol-y-energia-remota.md" \
  test -f docs/wol-y-energia-remota.md
tdoc "existe docs/android-operador.md" \
  test -f docs/android-operador.md
tdoc "la guia de WoL explica el operador como rele" \
  bash -c 'grep -qi "rele\|relé" docs/wol-y-energia-remota.md'
tdoc "la guia de android menciona proot-distro" \
  bash -c 'grep -q "proot-distro" docs/android-operador.md'
t "wol-despertar.sh existe" test -f wol-despertar.sh
t "energia-remota.sh existe" test -f energia-remota.sh
t "wol-despertar.sh valida la MAC" \
  bash -c 'grep -q "MAC inv" wol-despertar.sh'
t "wol-despertar.sh usa userspace-safe (python3)" \
  bash -c 'grep -q "python3" wol-despertar.sh'
t "issue #31: wol-despertar.sh no usa eval" \
  bash -c '! grep -qE "^[^#]*eval " wol-despertar.sh'
t "issue #31: instalar-todo.sh chk() no usa eval" \
  bash -c '! grep -qE "^[^#]*eval " instalar-todo.sh'
t "energia-remota.sh NO mete la clave en argv" \
  bash -c '! grep -vE "^#" energia-remota.sh | grep -q "echo .*PASS\|echo .*sudo -S"'
t "energia-remota.sh lee la clave de un archivo" \
  bash -c 'grep -q "ENERGIA_SUDO_FILE\|operador-secrets" energia-remota.sh'

# --- H-67: trusted_devices activo sin unlock_pin => pide clave personal ---
t "H-67 documentado (trusted_devices pide clave personal)" \
  bash -c 'grep -q "H-67" docs/hallazgos.md'
t "H-67 menciona trusted_devices y unlock_pin" \
  bash -c 'grep -q "trusted_devices" docs/hallazgos.md && grep -q "unlock_pin" docs/hallazgos.md'
t "H-67 distingue las tres contrasenas" \
  bash -c 'grep -q "tres contraseñas distintas" docs/hallazgos.md'
t "H-67 avisa de que el servicio corre como root" \
  bash -c 'grep -q "/root/.config/rustdesk" docs/hallazgos.md'
t "H-67 trae el arreglo con systemctl restart rustdesk" \
  bash -c 'grep -q "systemctl restart rustdesk" docs/hallazgos.md'
t "H-67 dice que no afecta a la contrasena de acceso remoto" \
  bash -c 'tr "\n" " " < docs/hallazgos.md | grep -q "acceso remoto sigue funcionando"'
t "H-67 no pisa IDs de otras sesiones" \
  bash -c 'grep -q "H-66" docs/hallazgos.md && grep -q "H-65" docs/hallazgos.md'
t "H-66 de la otra sesion (SSH caido) sigue intacto" \
  bash -c 'tr "\n" " " < docs/hallazgos.md | grep -q "tailscale ping. OK"'

# --- onboarding.sh: instalador de una linea ---
t "existe onboarding.sh" test -f onboarding.sh
t "onboarding.sh es ejecutable" test -x onboarding.sh
t "onboarding.sh pasa bash -n" bash -c 'bash -n onboarding.sh'
t "onboarding.sh valida el nombre del cliente" \
  bash -c 'grep -q "solo admite a-z" onboarding.sh'
t "onboarding.sh exige --rdpass" \
  bash -c 'grep -q "falta --rdpass" onboarding.sh'
t "onboarding.sh avisa del historial con la authkey" \
  bash -c 'grep -q -e "--authkey-stdin" onboarding.sh && grep -q "historial" onboarding.sh'
t "onboarding.sh verifica MANIFEST del kit" \
  bash -c 'grep -q "MANIFEST.sha256" onboarding.sh'
t "onboarding.sh soporta modo offline (--local)" \
  bash -c 'grep -q "\-\-local" onboarding.sh'
t "#32: onboarding.sh acepta --sha256 para verificar el tarball" \
  bash -c 'grep -q "\-\-sha256" onboarding.sh && grep -q "sha256sum" onboarding.sh'
t "#32: onboarding.sh aborta si el hash no coincide (no ejecuta)" \
  bash -c 'grep -q "hash SHA-256 del kit NO coincide" onboarding.sh'
t "#32: README ya no muestra curl-pipe-sudo-bash" \
  bash -c '! grep -q "onboarding.sh \\" README.md || ! grep -q "| sudo bash" README.md'
t "onboarding.sh resuelve claves de operadores/" \
  bash -c 'grep -q "operadores/\$host.pub\|operadores/" onboarding.sh'
t "onboarding.sh imprime la ficha del cliente" \
  bash -c 'grep -q "FICHA DEL CLIENTE" onboarding.sh'
t "onboarding.sh usa cliente-<nombre> como hostname tailnet" \
  bash -c 'grep -q "cliente-\$NOMBRE" onboarding.sh'
t "onboarding.sh pasa --tailnet-host a instalar-todo.sh" \
  bash -c 'grep -q "tailnet-host" onboarding.sh'
t "onboarding.sh reproduce el flujo en dry-run (offline)" \
  bash -c './onboarding.sh --local . --nombre prueba-ci --rdpass Test123 --skip-tailscale --dry-run --no-ficha >/dev/null 2>&1'
t "onboarding.sh rechaza nombre invalido (exit != 0)" \
  bash -c '! ./onboarding.sh --local . --nombre "Mal Nombre" --rdpass x --skip-tailscale --dry-run --no-ficha >/dev/null 2>&1'
t "existe operadores/README.md" test -f operadores/README.md
t "operadores/ solo publica .pub (H-43)" \
  bash -c '! ls operadores/ | grep -qvE "(\.pub|\.md)$"'
t "hay al menos una clave de operador publicada" \
  bash -c 'ls operadores/*.pub >/dev/null 2>&1'
t "make-kit.sh incluye onboarding.sh" \
  bash -c 'grep -q "^  onboarding.sh$" make-kit.sh'
t "instalar-todo.sh acepta --tailnet-host" \
  bash -c 'grep -q "\-\-tailnet-host" instalar-todo.sh'
# --- H-68: contraseña de RustDesk no se aplicaba (sudo -S se come stdin) ---
t "H-68: rustdesk-password.sh define la funcion sudow (askpass)" \
  bash -c 'grep -q "^sudow()" rustdesk-password.sh'
t "H-68: rustdesk-password.sh usa sudow (askpass) para escribir la config" \
  bash -c 'grep -q "sudow bash \"\$helper\" --stdin" rustdesk-password.sh'
t "H-68: el helper de sudo usa sudo -A (no -S) en codigo (lib/sudo.sh)" \
  bash -c 'grep -vE "^\s*#" lib/sudo.sh | grep -q "sudo -A"'
t "H-68: ya NO queda el pipe peligroso \(printf ... | sudo -S\\) en la escritura" \
  bash -c '! grep -q "printf .%s..n.%s..n. .\$salt. .\$storage. | sudo -S" rustdesk-password.sh'
t "H-68: sudow usa SUDO_ASKPASS" \
  bash -c 'grep -q "SUDO_ASKPASS" rustdesk-password.sh'
t "H-68b: instalar-todo.sh separa los pasos CRITICOS de Tailscale" \
  bash -c 'grep -q "ARGS_CORE=" instalar-todo.sh && grep -q "ARGS_TS=" instalar-todo.sh'
t "H-68b: los pasos criticos no incluyen --all (que arrastra Tailscale)" \
  bash -c 'grep -q "ARGS_CORE=(--rustdesk --ssh --laptop --yes)" instalar-todo.sh'
t "H-68b: un fallo de Tailscale no aborta (marca TS_FALLO)" \
  bash -c 'grep -q "TS_FALLO=1" instalar-todo.sh'
t "H-68b: avisa que Tailscale es opcional si falla" \
  bash -c 'grep -qi "Tailscale FALLÓ (paso opcional)" instalar-todo.sh'
t "H-68b: instalar-todo.sh tambien tiene sudow" \
  bash -c 'grep -q "^sudow()" instalar-todo.sh'
t "H-68b: chk_root usa sudow para leer la config de root" \
  bash -c 'grep -q "chk_root()" instalar-todo.sh'
t "H-68 documentado en hallazgos" \
  bash -c 'grep -q "H-68" docs/hallazgos.md'
t "H-68 explica que sudo -S se come el salt de stdin" \
  bash -c 'tr "\n" " " < docs/hallazgos.md | grep -qi "sudo -S. lee. la .* de stdin\|stdin.*buffering"'
t "H-68 explica que Tailscale no esta en repos Debian/Ubuntu" \
  bash -c 'tr "\n" " " < docs/hallazgos.md | grep -qi "repos.*Debian/Ubuntu\|no está en los repos"'

# --- issue #28: helper UNICO de sudo (lib/sudo.sh) ---
t "#28: existe lib/sudo.sh (helper unico de sudo)" \
  bash -c 'test -f lib/sudo.sh'
t "#28: lib/sudo.sh usa sudo -A (askpass), nunca -S en codigo" \
  bash -c 'grep -q "sudo -A" lib/sudo.sh && ! grep -vE "^\s*#" lib/sudo.sh | grep -q "sudo -S"'
t "#28: lib/sudo.sh define sudo_run" \
  bash -c 'grep -q "^sudo_run()" lib/sudo.sh'
t "#28: lib/sudo.sh define sudo_v (refresco sin consumir stdin)" \
  bash -c 'grep -q "^sudo_v()" lib/sudo.sh'
t "#28: instalar-todo.sh sourcea lib/sudo.sh" \
  bash -c 'grep -q "source .*lib/sudo.sh" instalar-todo.sh'
t "#28: rustdesk-password.sh sourcea lib/sudo.sh" \
  bash -c 'grep -q "source .*lib/sudo.sh" rustdesk-password.sh'
t "#28: energia-remota.sh sourcea lib/sudo.sh" \
  bash -c 'grep -q "source .*lib/sudo.sh" energia-remota.sh'
t "#28: make-kit.sh incluye lib/sudo.sh en el kit" \
  bash -c 'grep -q "^  lib/sudo.sh$" make-kit.sh'
t "#28: ya NO queda 'sudo -S -v' suelto en instalar-todo.sh (patron de H-68)" \
  bash -c '! grep -q "printf .%s..n. .\$SUDOPASS. | sudo -S" instalar-todo.sh'
t "#28: CI lint-ea lib/*.sh (shellcheck)" \
  bash -c 'grep -q "lib/\*.sh" .github/workflows/ci.yml'

# --- issue #27 (sub-tarea 1/6): modulo de UI/estado (lib/sr-t-ui.sh) ---
t "#27: existe lib/sr-t-ui.sh (modulo UI/estado)" \
  bash -c 'test -f lib/sr-t-ui.sh'
t "#27: lib/sr-t-ui.sh define ok/warn/err/info/hdr" \
  bash -c 'for f in ok warn err info hdr; do grep -q "^$f()" lib/sr-t-ui.sh || exit 1; done'
t "#27: setup-remote-target.sh sourcea lib/sr-t-ui.sh" \
  bash -c 'grep -q "source .*lib/sr-t-ui.sh" setup-remote-target.sh'
t "#27: make-kit.sh incluye lib/sr-t-ui.sh en el kit" \
  bash -c 'grep -q "^  lib/sr-t-ui.sh$" make-kit.sh'

# --- issue #27 (sub-tarea 2/6): modulo de abstraccion de distro ---
t "#27: existe lib/sr-t-distro.sh (modulo abstraccion de distro)" \
  bash -c 'test -f lib/sr-t-distro.sh'
t "#27: lib/sr-t-distro.sh define detect_distro/pkg_install/pkg_installed" \
  bash -c 'for f in detect_distro pkg_install pkg_installed; do grep -q "^$f()" lib/sr-t-distro.sh || exit 1; done'
t "#27: setup-remote-target.sh sourcea lib/sr-t-distro.sh" \
  bash -c 'grep -q "source .*lib/sr-t-distro.sh" setup-remote-target.sh'
t "#27: make-kit.sh incluye lib/sr-t-distro.sh en el kit" \
  bash -c 'grep -q "^  lib/sr-t-distro.sh$" make-kit.sh'

# --- issue #27 (sub-tarea 3/6): modulo de RustDesk ---
t "#27: existe lib/sr-t-rustdesk.sh (modulo RustDesk)" \
  bash -c 'test -f lib/sr-t-rustdesk.sh'
t "#27: lib/sr-t-rustdesk.sh define setup_rustdesk + instalacion por familia" \
  bash -c 'for f in rustdesk_asset_url install_rustdesk_deb install_rustdesk_rpm setup_rustdesk; do grep -q "^$f()" lib/sr-t-rustdesk.sh || exit 1; done'
t "#27: setup-remote-target.sh sourcea lib/sr-t-rustdesk.sh" \
  bash -c 'grep -q "source .*lib/sr-t-rustdesk.sh" setup-remote-target.sh'
t "#27: make-kit.sh incluye lib/sr-t-rustdesk.sh en el kit" \
  bash -c 'grep -q "^  lib/sr-t-rustdesk.sh$" make-kit.sh'

# --- issue #27 (sub-tarea 4/6): modulo SSH (lib/sr-t-ssh.sh) ---
t "#27: existe lib/sr-t-ssh.sh (modulo SSH)" \
  bash -c 'test -f lib/sr-t-ssh.sh'
t "#27: lib/sr-t-ssh.sh define setup_ssh" \
  bash -c 'grep -q "^setup_ssh()" lib/sr-t-ssh.sh'
t "#27: setup-remote-target.sh sourcea lib/sr-t-ssh.sh" \
  bash -c 'grep -q "source .*lib/sr-t-ssh.sh" setup-remote-target.sh'
t "#27: make-kit.sh incluye lib/sr-t-ssh.sh en el kit" \
  bash -c 'grep -q "^  lib/sr-t-ssh.sh$" make-kit.sh'

sect "Resumen"
printf '  %s%d OK%s · %s%d fallos%s · %s%d omitidos%s\n' \
  "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$Y" "$SKIP" "$N"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
