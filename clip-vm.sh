#!/usr/bin/env bash
#
# clip-vm.sh — Puente de portapapeles entre el host y una VM por SSH.
#
# Uso:
#   ./clip-vm.sh get  [USUARIO@IP]   # trae el portapapeles de la VM al host
#   ./clip-vm.sh put  [USUARIO@IP]   # envía el portapapeles del host a la VM
#   ./clip-vm.sh show [USUARIO@IP]   # muestra el portapapeles de la VM
#
#   ./clip-vm.sh --verbose get       # con detalles de cada paso
#   CLIP_VM=jp@10.0.0.5 ./clip-vm.sh get   # otro destino (o export CLIP_VM)
#
# Por qué existe: en Wayland el spice-vdagent de Fedora solo propaga
# host->guest; guest->host no funciona (el agente es una build X11 y no ve
# los cambios que hace el compositor Wayland). Este script usa SSH como
# puente fiable en ambas direcciones.
#
# Requiere: wl-clipboard en host y guest, y clave SSH autorizada (BatchMode).
#
set -uo pipefail

# Destino por defecto. Configurable sin editar el script:
#   CLIP_VM=jp@10.0.0.5 ./clip-vm.sh get
#   export CLIP_VM=jp@10.0.0.5   (en ~/.bashrc o ~/.config/fish/config.fish)
VM_DEFAULT="${CLIP_VM:-jp@192.168.122.11}"
VERBOSE=0
CMD=""
TARGET=""

for arg in "$@"; do
  case "$arg" in
    get|put|show) CMD="$arg" ;;
    -v|--verbose) VERBOSE=1 ;;
    -h|--help)
      sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *@*) TARGET="$arg" ;;   # destino tipo USUARIO@HOST
    *)
      echo "Argumento no reconocido: $arg" >&2
      echo "Usa: $0 get|put|show [USUARIO@HOST] [-v]" >&2
      exit 2 ;;
  esac
done

TARGET="${TARGET:-$VM_DEFAULT}"

say() { [[ $VERBOSE -eq 1 ]] && echo "  $*" >&2; return 0; }

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Error: falta '$1' en el host" >&2; exit 1; }
}

# SSH sin contraseña: si no entra en BatchMode, avisar con claridad en vez de
# dejar que pida password y contamine el portapapeles con "password:".
ssh_ok() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$TARGET" 'true' 2>/dev/null
}

guest_has_wl() {
  ssh -o BatchMode=yes "$TARGET" 'command -v wl-copy >/dev/null 2>&1' 2>/dev/null
}

# Descubre el entorno gráfico del guest. Por SSH, WAYLAND_DISPLAY suele venir
# VACÍO (no se hereda la sesión gráfica), así que wl-copy/wl-paste fallan con
# "Failed to connect to a Wayland server". Hay que reconstruirlo:
#   - WAYLAND_DISPLAY: el socket real (wayland-0, wayland-1, ...).
#   - XDG_RUNTIME_DIR: /run/user/<uid>.
# El nombre del socket no es fijo: KDE suele usar wayland-1. Se deduce del
# sistema de archivos del guest (primer /run/user/<uid>/wayland-*).
guest_env() {
  ssh -o BatchMode=yes "$TARGET" 'bash -s' 2>/dev/null <<'REMOTE'
uid="$(id -u)"
rt="${XDG_RUNTIME_DIR:-/run/user/$uid}"
wd="${WAYLAND_DISPLAY:-}"
# Si no hay WAYLAND_DISPLAY, elegir el socket disponible (preferir wayland-1,0).
if [ -z "$wd" ] || [ ! -S "$rt/$wd" ]; then
  for s in "$rt"/wayland-*; do
    [ -S "$s" ] || continue
    case "$s" in *.lock) continue ;; esac
    wd="$(basename "$s")"
    case "$wd" in wayland-1) break ;; esac
  done
fi
printf 'XDG_RUNTIME_DIR=%s WAYLAND_DISPLAY=%s\n' "$rt" "$wd"
REMOTE
}

check_all() {
  need wl-copy
  need wl-paste
  if ! ssh_ok; then
    echo "Error: no se pudo entrar a '$TARGET' sin contraseña." >&2
    echo "  Comprueba: ssh -o BatchMode=yes $TARGET 'echo ok'" >&2
    exit 1
  fi
  if ! guest_has_wl; then
    echo "Error: el guest no tiene wl-clipboard (wl-copy/wl-paste)." >&2
    echo "  Instálalo: ssh $TARGET 'sudo dnf install -y wl-clipboard'" >&2
    exit 1
  fi
  # Entorno gráfico del guest (WAYLAND_DISPLAY vacío por SSH es lo normal).
  local env
  env="$(guest_env)" || env=""
  if [[ -n "$env" ]]; then
    # Formato: XDG_RUNTIME_DIR=... WAYLAND_DISPLAY=...  -> exportar una a una.
    local k v
    for pair in $env; do
      k="${pair%%=*}"; v="${pair#*=}"
      case "$k" in
        XDG_RUNTIME_DIR|WAYLAND_DISPLAY) export "$k=$v" ;;
      esac
    done
    say "entorno del guest: $env"
  fi
  if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
    echo "Aviso: no pude detectar WAYLAND_DISPLAY en el guest." >&2
    echo "  ¿Hay sesión gráfica activa en $TARGET? El portapapeles la necesita." >&2
  fi
}

case "$CMD" in
  get)
    # guest -> host.
    # OJO: NO usar --paste-once. Verificado en CachyOS (wl-clipboard 2.3.0):
    # deja el portapapeles con el caracter '1' en vez del contenido. wl-copy
    # normal SI funciona (queda un proceso residente sirviendo el contenido,
    # que es el comportamiento esperado de wl-clipboard).
    check_all
    say "leyendo portapapeles de $TARGET..."
    tmp="$(mktemp)"
    # wl-paste necesita el entorno Wayland del guest (WAYLAND_DISPLAY), que por
    # SSH no se hereda: se pasa explícitamente con 'bash -s' y export.
    # shellcheck disable=SC2087  # queremos expandir WAYLAND_DISPLAY en el cliente
    if ! ssh -o BatchMode=yes "$TARGET" 'bash -s' >"$tmp" 2>/dev/null <<REMOTE
set -e
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"
export WAYLAND_DISPLAY="$WAYLAND_DISPLAY"
wl-paste
REMOTE
    then
      rm -f "$tmp"
      echo "Error: falló wl-paste en el guest" >&2
      exit 1
    fi
    if [[ ! -s "$tmp" ]]; then
      rm -f "$tmp"
      echo "El portapapeles del guest está vacío. Copia algo dentro de la VM primero." >&2
      exit 1
    fi
    say "copiado al portapapeles del host ($(wc -c <"$tmp") bytes)"
    # wl-copy queda RESIDENTE sirviendo el portapapeles. Si se lanza en primer
    # plano, el script no termina (parece colgado). Se lanza en segundo plano
    # con nohup + disown; el proceso sobrevive y sirve el contenido.
    nohup wl-copy <"$tmp" >/dev/null 2>&1 &
    disown 2>/dev/null || true
    rm -f "$tmp"
    echo "OK: portapapeles del guest → host"
    ;;

  put)
    # host -> guest. Se pasa por stdin con heredoc para no depender de
    # caracteres especiales en la línea de comandos.
    check_all
    say "leyendo portapapeles del host..."
    tmp="$(mktemp)"
    if ! timeout 5 wl-paste >"$tmp" 2>/dev/null; then
      rm -f "$tmp"
      echo "El portapapeles del host está vacío. Copia algo en el host primero." >&2
      exit 1
    fi
    if [[ ! -s "$tmp" ]]; then
      rm -f "$tmp"
      echo "El portapapeles del host está vacío. Copia algo en el host primero." >&2
      exit 1
    fi
    say "enviando a $TARGET ($(wc -c <"$tmp") bytes)"
    # El shell del guest puede ser fish: NO se le puede mandar un script bash
    # suelto por SSH (lo interpretaría fish y fallaría; ver H-23). Se construye
    # un script bash AUTOCONTENIDO con el contenido codificado en base64 y se
    # envía con 'bash -s'. Así el stdin lleva el propio script (no el contenido)
    # y no hay conflicto.
    #
    # wl-copy se queda RESIDENTE sirviendo el portapapeles; si se lanza en
    # primer plano por SSH, el comando NO termina. Se guarda el contenido en un
    # archivo del guest y se lanza desacoplado con nohup + disown, de modo que
    # el SSH cierra con exit 0.
    b64="$(base64 -w0 <"$tmp")"
    timeout 20 ssh -o BatchMode=yes "$TARGET" 'bash -s' <<REMOTE
set -e
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"
export WAYLAND_DISPLAY="$WAYLAND_DISPLAY"
f="\$(mktemp)"
printf '%s' '$b64' | base64 -d > "\$f"
pkill -u "\$(id -u)" -x wl-copy 2>/dev/null || true
sleep 0.2
nohup wl-copy < "\$f" >/dev/null 2>&1 &
disown 2>/dev/null || true
sleep 0.8
rm -f "\$f"
exit 0
REMOTE
    rc=$?
    rm -f "$tmp"
    if [[ $rc -ne 0 ]]; then
      echo "Aviso: falló el envío al guest (rc=$rc)" >&2
      exit 1
    fi
    echo "OK: portapapeles del host → guest"
    ;;

  show)
    # Solo lectura: qué hay en el portapapeles de la VM.
    check_all
    # shellcheck disable=SC2087  # queremos expandir WAYLAND_DISPLAY en el cliente
    out="$(ssh -o BatchMode=yes "$TARGET" 'bash -s' 2>/dev/null <<REMOTE
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"
export WAYLAND_DISPLAY="$WAYLAND_DISPLAY"
wl-paste
REMOTE
)"
    if [[ -z "$out" ]]; then
      echo "(portapapeles del guest vacío)"
    else
      printf '%s\n' "$out"
    fi
    ;;

  ""|-h|--help)
    sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
    ;;

  *)
    echo "Comando desconocido: $CMD" >&2
    echo "Usa: $0 get|put|show [USUARIO@IP]" >&2
    exit 1
    ;;
esac
