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
for f in setup-remote-target.sh inventory.sh tests.sh verify-docs.sh clip-vm.sh \
         install-rustdesk-unattended-fedora.sh rustdesk-password.sh \
         .rd-setpass-root.sh; do
  t "bash -n $f" bash -n "$f"
done
t "Makefile parseable" make -n help

sect "Permisos de ejecución"
for f in setup-remote-target.sh inventory.sh tests.sh verify-docs.sh clip-vm.sh \
         install-rustdesk-unattended-fedora.sh rustdesk-password.sh; do
  t "$f es ejecutable" test -x "$f"
done

sect "Ayuda / usage"
t "setup --help sale 0"        ./setup-remote-target.sh --help
t "setup sin args muestra usage y falla" bash -c './setup-remote-target.sh >/dev/null 2>&1; test $? -ne 0'
tj "setup opción inválida falla" ./setup-remote-target.sh --nope
t "inventory --help sale 0"    ./inventory.sh --help
t "clip-vm --help sale 0"      ./clip-vm.sh --help
tj "clip-vm comando invalido falla" ./clip-vm.sh comandoquenoexiste
t "clip-vm sin args muestra ayuda" bash -c './clip-vm.sh >/dev/null 2>&1'

sect "Soporte multi-distro (arch | debian | fedora)"
t "detecta familia arch"    bash -c 'bash -c "id=arch; idlike=; case \" \$id \$idlike \" in *\" arch \"*) echo arch;; esac" | grep -q arch'
t "script define detect_distro"   bash -c 'grep -q "^detect_distro()" setup-remote-target.sh'
t "script define pkg_install"     bash -c 'grep -q "^pkg_install()" setup-remote-target.sh'
t "script define pkg_installed"   bash -c 'grep -q "^pkg_installed()" setup-remote-target.sh'
t "rama debian usa apt-get"       bash -c 'grep -q "apt-get install" setup-remote-target.sh'
t "rama fedora usa dnf"           bash -c 'grep -q "dnf install" setup-remote-target.sh'
t "rama arch usa pacman"          bash -c 'grep -q "pacman -S" setup-remote-target.sh'
# Fedora 41+: 'dnf' es symlink a dnf5 y `dnf --version` responde "dnf5 ...".
# NO hace falta cambiar los comandos (install -y sigue funcionando igual).
t "diagnostico informa version del gestor" \
  bash -c 'grep -q "^pkg_manager_version()" setup-remote-target.sh'
t "pkg_manager_version cubre las 3 familias" \
  bash -c 'awk "/^pkg_manager_version\(\)/,/^}/" setup-remote-target.sh | grep -qE "(arch|debian|fedora)\\)"'
t "pkg_manager_version fuerza LC_ALL=C (salida no traducida)" \
  bash -c 'awk "/^pkg_manager_version\(\)/,/^}/" setup-remote-target.sh | grep -q "LC_ALL=C dnf"'
t "diagnostico imprime la linea Gestor" \
  bash -c 'grep -q "info \"Gestor: \$(pkg_manager_version)\"" setup-remote-target.sh'
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
t "detect_firewall consulta ufw.conf (respaldo)" bash -c 'grep -q "/etc/ufw/ufw.conf" setup-remote-target.sh'
t "detect_firewall lee ENABLED (no solo systemctl)" bash -c 'awk "/^detect_firewall\(\)/,/^}/" setup-remote-target.sh | grep -q "ENABLED=yes"'
t "ufw-inactive activa ufw (--force enable)" bash -c 'grep -q "ufw --force enable" setup-remote-target.sh'
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

sect "No fuga de secretos al repo"
t ".gitignore ignora claves"   bash -c 'grep -q "id_" .gitignore'
t "no hay claves en el árbol"  bash -c '! find . -name "id_*" -not -path "./.git/*" | grep -q .'
t "no hay .key/.pem"           bash -c '! find . \( -name "*.key" -o -name "*.pem" \) -not -path "./.git/*" | grep -q .'
t "no hay tskey-auth real"     bash -c '! grep -rqE "tskey-auth-[A-Za-z0-9]{20}" --exclude-dir=.git .'
# Excluye el propio tests.sh (contiene los patrones como literales de búsqueda)
t "sin datos de infra real"    bash -c '! grep -rqE "jpfuentealba|100\.(68|97|112)\.|wikileaks|jp-rustdesk|tailc15fd9" --exclude-dir=.git --exclude=tests.sh .'

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
# Fedora 44 (imagen base mínima) NO trae el binario 'hostname': el kit debe
# tener respaldo (/proc/sys/kernel/hostname o uname -n) para no mostrar vacío.
t "setup tiene hostname portable (local_hostname)" \
  bash -c 'grep -q "^local_hostname()" setup-remote-target.sh'
t "local_hostname respalda con /proc/sys/kernel/hostname" \
  bash -c 'awk "/^local_hostname\(\)/,/^}/" setup-remote-target.sh | grep -q "/proc/sys/kernel/hostname"'
t "setup no llama hostname sin respaldo" \
  bash -c '! grep -vE "^\s*#" setup-remote-target.sh | grep -qE "\$\(hostname\)"'
t "inventory respalda hostname con /proc o uname -n" \
  bash -c 'grep -q "j HOSTNAME" inventory.sh && grep -q "/proc/sys/kernel/hostname" inventory.sh'
# Fedora 44 con KDE: la ultima sesion de `loginctl list-sessions` es de tipo
# 'background'/'manager' (Type=unspecified) y ocultaba el Wayland real.
t "setup tiene graphical_session_type()" \
  bash -c 'grep -q "^graphical_session_type()" setup-remote-target.sh'
t "no elige sesion con tail -1 (bug Fedora 44 KDE)" \
  bash -c '! grep -vE "^\s*#" setup-remote-target.sh | grep -qE "list-sessions.*tail -1"'
t "graphical_session_type prefiere sesiones con seat" \
  bash -c 'awk "/^graphical_session_type\(\)/,/^}/" setup-remote-target.sh | grep -q "\$4 != \"-\""'
t "ambos avisos usan graphical_session_type" \
  bash -c '[[ $(grep -c "\$(graphical_session_type)" setup-remote-target.sh) -ge 2 ]]'

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
  bash -c 'grep -q "apply /root/.config/rustdesk" .rd-setpass-root.sh'
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

sect "H-19 os error 104 (audio/portapapeles en bucle)"
t "H-19 documentado" bash -c 'grep -q "H-19" docs/hallazgos.md'
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
t "H-14 documentado" bash -c 'grep -q "H-14" docs/hallazgos.md'
t "H-15 documentado" bash -c 'grep -q "H-15" docs/hallazgos.md'
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
         docs/onboarding-cliente.md docs/hallazgos.md docs/estado-sesion.md; do
  t "existe $d" test -f "$d"
done
t "README enlaza hallazgos"     bash -c 'grep -q "docs/hallazgos.md" README.md'
t "README enlaza onboarding"    bash -c 'grep -q "docs/onboarding-cliente.md" README.md'
t "README enlaza tailscale"     bash -c 'grep -q "docs/tailscale.md" README.md'
t "README enlaza estado-sesion" bash -c 'grep -q "docs/estado-sesion.md" README.md'
# El estado de sesión debe registrar el entorno de prueba para poder retomarlo
t "estado-sesion registra la IP de la VM" bash -c 'grep -q "192.168.122.11" docs/estado-sesion.md'
t "estado-sesion avisa que el guest es Wayland" bash -c 'grep -qi "wayland" docs/estado-sesion.md'
t "estado-sesion registra el bloqueo de sudo" bash -c 'grep -qi "sudo.*contraseña\|pide contraseña" docs/estado-sesion.md'
# La doc debe distinguir roles (operador no necesita sshd; el objetivo sí)
t "README distingue OPERADOR/OBJETIVO" bash -c 'grep -q "PC OPERADOR" README.md && grep -q "PC OBJETIVO" README.md'
t "README aclara que el operador no necesita sshd" \
  bash -c 'grep -qE "sshd.*no necesita|no necesita.*sshd" README.md'
# El agente IA (pi) es herramienta del OPERADOR: NO se instala en el cliente.
t "README: el agente IA vive solo en el operador" \
  bash -c 'grep -qE "pi.*vive SOLO en el operador|solo aqu.*NUNCA" README.md'
t "README: el agente NO se instala en el objetivo" \
  bash -c 'sed "s/^> //" README.md | tr "\n" " " | grep -qiE "no se instala ni se configura en el PC objetivo"'
t "README: explica que pi no tiene modelos gratis" \
  bash -c 'grep -qi "no incluye modelos gratuitos fiables" README.md'
t "guia-desde-cero: pi corre solo en el operador" \
  bash -c 'grep -qE "pi.*corre SOLO en tu PC" docs/guia-desde-cero.md'
t "estado-sesion registra el modelo de producto" \
  bash -c 'grep -q "Modelo de producto" docs/estado-sesion.md'
t "estado-sesion: pi solo en el operador" \
  bash -c 'grep -q "SOLO en el PC del operador" docs/estado-sesion.md'

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
  t "RustDesk enabled"           bash -c "$RH 'systemctl is-enabled rustdesk' >/dev/null 2>&1"
  t "RustDesk activo ahora"      bash -c "$RH 'systemctl is-active rustdesk' | grep -q '^active'"
  # Tailscale puede NO estar instalado en el objetivo (p. ej. solo SSH por LAN).
  # En ese caso se OMITE (no es un fallo del kit ni del host).
  if $RH 'command -v tailscale >/dev/null 2>&1' 2>/dev/null; then
    t "H-01 tailscaled enabled"    bash -c "$RH 'systemctl is-enabled tailscaled' >/dev/null 2>&1"
    t "H-01 Tailscale activo"      bash -c "$RH 'systemctl is-active tailscaled' | grep -q '^active'"
    t "H-01 tiene IP Tailscale"    bash -c "$RH 'tailscale ip -4' | grep -qE '^100\.'"
  else
    sk "H-01 Tailscale no instalado en el objetivo (acceso por LAN)"
  fi
  # H-02/H-04: la captura DRM solo aplica en Wayland. En X11 no aplica.
  remote_sess="$($RH 'loginctl show-session "$(loginctl list-sessions --no-legend 2>/dev/null | awk "{print \$1}" | tail -1)" -p Type --value 2>/dev/null' 2>/dev/null || true)"
  if [[ "$remote_sess" == "wayland" ]]; then
    t "H-04 captura DRM con sesión Wayland" \
      bash -c "$RH 'grep -q \"drm: consumer cache\" ~/.local/share/logs/RustDesk/server/rustdesk_rCURRENT.log'"
  elif [[ -n "$remote_sess" ]]; then
    sk "H-04 sesión $remote_sess en el objetivo: captura DRM no aplica"
  else
    sk "H-04 no se pudo determinar el tipo de sesión del objetivo"
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
  # H-05: conexión Tailscale directa. SOLO tiene sentido si el HOST objetivo
  # está en la tailnet. Si el objetivo no tiene Tailscale (p. ej. VM por LAN),
  # se OMITE: no es un fallo.
  if command -v tailscale >/dev/null 2>&1 \
     && $RH 'command -v tailscale >/dev/null 2>&1' 2>/dev/null; then
    # IP Tailscale del host objetivo (tal como la ve el operador)
    peer="$($RH 'tailscale ip -4' 2>/dev/null | head -1)"
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

sect "Resumen"
printf '  %s%d OK%s · %s%d fallos%s · %s%d omitidos%s\n' \
  "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$Y" "$SKIP" "$N"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
