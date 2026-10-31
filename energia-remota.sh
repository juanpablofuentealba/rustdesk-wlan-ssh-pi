#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# energia-remota.sh — apaga / reinicia un equipo remoto por SSH, de forma
# segura (confirmación) y sin exponer la contraseña sudo.
#
# Por qué existe:
#   Apagar un equipo remoto con `ssh host "echo PASS | sudo -S poweroff"`
#   deja la contraseña VISIBLE en `ps` del equipo remoto (argumento) y en el
#   historial del operador. Este script lee la clave de un archivo aparte
#   (permisos 600) y la pasa por STDIN → invisible en `ps`.
#
# La contraseña sudo NO vive en este script. Se lee de:
#   ${ENERGIA_SUDO_FILE:-~/.config/operador-secrets/sudo}
#
# Uso:
#   ./energia-remota.sh apagar     <user@host>       # pide confirmación
#   ./energia-remota.sh reiniciar  <user@host>
#   ./energia-remota.sh apagar     <user@host> --delay 10
#   ./energia-remota.sh cancelar   <user@host>
#
#   Para automatizar sin confirmación: exportar ENERGIA_SIN_CONFIRMAR=si
#   Con otro archivo de clave: exportar ENERGIA_SUDO_FILE=/ruta
# ---------------------------------------------------------------------------
set -euo pipefail

SECRET_FILE="${ENERGIA_SUDO_FILE:-$HOME/.config/operador-secrets/sudo}"

# Helper ÚNICO de sudo (lib/sudo.sh, issue #28 / H-68). Aquí la clave viaja al
# sudo del equipo REMOTO por el stdin de SSH, no al sudo local: por eso no se
# puede usar `sudo_run` directamente (actuaría en el equipo del operador).
# Lo que sí se centraliza es la LECTURA de la clave desde archivo. El `sudo -S`
# remoto es una excepción DOCUMENTADA (ver informe del issue #28): no compite
# con ningún otro dato en ese stdin, así que H-68 no aplica.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sudo.sh
source "$SCRIPT_DIR/lib/sudo.sh"

notify() { command -v notify-send >/dev/null 2>&1 && notify-send -u "${2:-normal}" -i "${3:-system-shutdown}" "$1" "$4" 2>/dev/null || true; }

accion="${1:-}"; shift || true
target="${1:-}";  shift || true
delay=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --delay) delay="${2:?falta minutos}"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$accion" || -z "$target" ]]; then
  sed -n '15,27p' "$0"; exit 2
fi

err() { printf '\033[1;31m✘\033[0m %s\n' "$*" >&2; }

# leer_clave: emite la clave por stdout (la consume el sudo REMOTO por SSH).
# Usa la lógica compartida de lib/sudo.sh: SUDO_PASS por entorno, o el archivo
# indicado en SUDO_PASS_FILE, o el de ENERGIA_SUDO_FILE (compatibilidad).
leer_clave() {
  if [[ -n "${SUDO_PASS:-}" ]]; then
    printf '%s\n' "$SUDO_PASS"
    return 0
  fi
  local f="${SUDO_PASS_FILE:-$SECRET_FILE}"
  [[ -r "$f" ]] || { err "falta $f (chmod 600)"; exit 1; }
  head -n1 "$f"
}

case "$accion" in
  apagar)
    verbo="apagar"; icon="system-shutdown"; [[ -n "$delay" ]] && rc="sudo -S shutdown -h $delay" || rc="sudo -S systemctl poweroff" ;;
  reiniciar|reinicio)
    verbo="reiniciar"; icon="system-reboot"; [[ -n "$delay" ]] && rc="sudo -S shutdown -r $delay" || rc="sudo -S systemctl reboot" ;;
  cancelar)
    leer_clave | timeout 10 ssh -o ConnectTimeout=5 "$target" 'sudo -S -p "" shutdown -c 2>/dev/null' >/dev/null 2>&1 || true
    notify "✅ Cancelado" normal system-shutdown "Acción cancelada en $target"
    exit 0 ;;
  *) err "acción inválida: $accion"; exit 2 ;;
esac

if [[ "${ENERGIA_SIN_CONFIRMAR:-no}" != "si" ]]; then
  aviso="¿${verbo^} $target ahora?"; [[ -n "$delay" ]] && aviso="¿${verbo^} $target en $delay min?"
  if command -v kdialog >/dev/null 2>&1; then
    kdialog --yesno "$aviso" --title "${verbo^}" --icon "$icon" 2>/dev/null || exit 0
  else
    read -r -p "$aviso [s/N] " r; [[ "${r,,}" == "s" ]] || exit 0
  fi
fi

notify "🔌 Enviando: $verbo..." low "$icon" "$target"
if leer_clave | timeout 20 ssh -o ConnectTimeout=5 "$target" "$rc" >/dev/null 2>&1; then
  notify "✅ Orden enviada — $verbo" normal "$icon" "$target"
else
  notify "⚠️ No se pudo $verbo" critical "$icon" "$target"
  exit 1
fi
