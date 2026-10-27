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
    if ! ssh -o BatchMode=yes "$TARGET" 'wl-paste' >"$tmp" 2>/dev/null; then
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
    wl-copy <"$tmp"
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
    # wl-copy se queda RESIDENTE sirviendo el portapapeles. Si se lanza en
    # primer plano por SSH, el comando NO termina nunca. Se guarda el contenido
    # en un archivo del guest y se lanza desacoplado con nohup + disown,
    # heredando el stdin desde ese archivo. Asi el SSH cierra con exit 0.
    timeout 20 ssh -o BatchMode=yes "$TARGET" '
      f="$(mktemp)"
      cat > "$f"
      pkill -u "$(id -u)" -x wl-copy 2>/dev/null || true
      sleep 0.2
      nohup wl-copy < "$f" >/dev/null 2>&1 &
      disown 2>/dev/null || true
      sleep 0.8
      rm -f "$f"
      exit 0
    ' <"$tmp"
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
    out="$(ssh -o BatchMode=yes "$TARGET" 'wl-paste' 2>/dev/null)"
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
