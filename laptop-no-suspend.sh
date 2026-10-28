#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# laptop-no-suspend.sh — evita que un PORTÁTIL pierda el acceso remoto por
# suspensión (tapa cerrada o inactividad).
#
# Problema (H-29): en un laptop, cerrar la tapa o dejarlo inactivo hace que
# systemd-logind suspenda el equipo. Al suspender, Tailscale, sshd y RustDesk
# se caen: el operador PIERDE el acceso remoto y no puede recuperarlo hasta
# que alguien abra la tapa. Un PC de escritorio no tiene este problema.
#
# Este script desactiva esas suspensiones, de forma REVERSIBLE.
#
# Uso:
#   ./laptop-no-suspend.sh --check     # muestra qué haría (no cambia nada)
#   ./laptop-no-suspend.sh --apply     # aplica (pide sudo)
#   ./laptop-no-suspend.sh --revert    # deshace (vuelve al comportamiento normal)
#
#   --dry-run    igual que --check
#
# Qué cambia:
#   1. systemd-logind: HandleLidSwitch / *ExternalPower = ignore
#      (que NO suspenda al cerrar la tapa, ni con batería ni con corriente)
#   2. KDE (kwriteconfig6): desactiva "suspender sesión" por inactividad (AC/battery)
#   3. Mask de sleep/suspend/hibernate target como red de seguridad (opcional)
#
# NO cambia: apagado, reinicio, ni bloqueo de pantalla del usuario.
# ---------------------------------------------------------------------------
set -uo pipefail

ACTION=""
# DRY no se usa como flag propio: --dry-run se mapea a ACTION=--check.
# (Se dejó a propósito para compatibilidad conceptual; shellcheck SC2034.)
# shellcheck disable=SC2034
DRY=0

ok()   { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m✘\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m▲\033[0m %s\n' "$*"; }
say()  { printf '\033[1;34m●\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

usage(){ sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check|--apply|--revert) ACTION="$1"; shift ;;
    --dry-run) ACTION="--check"; shift ;;
    -h|--help) usage ;;
    *) echo "opción desconocida: $1" >&2; usage ;;
  esac
done
[[ -n "$ACTION" ]] || { echo "error: falta --check, --apply o --revert" >&2; usage; }

LOGIND_FILE="/etc/systemd/logind.conf.d/99-no-suspend-laptop.conf"

# ¿es portátil? (batería o tapa). En VM no hay batería -> igual se puede forzar.
is_laptop(){
  [[ -d /sys/class/power_supply ]] && \
    compgen -G '/sys/class/power_supply/BAT*' >/dev/null && return 0
  [[ -e /proc/acpi/button/lid ]] && return 0
  # systemd-detect-virt -c devuelve "none" en hardware real; si no es VM, puede ser laptop
  [[ "$(systemd-detect-virt 2>/dev/null || echo none)" == "none" ]] && return 0
  return 1
}

describe(){
  hdr "Diagnóstico"
  if is_laptop; then ok "el equipo parece un PORTÁTIL (batería/tapa) o hardware real"
  else warn "no detecté batería: puede ser una VM o un PC de escritorio"; fi
  say "logind ahora:"
  grep -E '^#?HandleLidSwitch' /etc/systemd/logind.conf 2>/dev/null | sed 's/^/    /' || true
}

do_check(){
  describe
  hdr "Qué haría --apply (no modificado)"
  say "1. crearía $LOGIND_FILE con:"
  echo "       [Login]"
  echo "       HandleLidSwitch=ignore"
  echo "       HandleLidSwitchExternalPower=ignore"
  echo "       HandleLidSwitchDocked=ignore"
  say "2. reiniciaría systemd-logind (aplica sin reiniciar el equipo)"
  say "3. KDE: desactivaría suspensión por inactividad (AC y batería)"
  warn "NO toca apagado, reinicio ni bloqueo de pantalla"
}

do_apply(){
  describe
  hdr "Aplicar (anti-suspensión)"
  if [[ $EUID -ne 0 ]]; then
    bad "requiere root:  sudo $0 --apply"
    return 1
  fi
  mkdir -p /etc/systemd/logind.conf.d
  cat > "$LOGIND_FILE" <<'EOF'
# Generado por laptop-no-suspend.sh (kit de acceso remoto).
# Evita que el portátil suspenda y se pierda el acceso remoto (H-29).
# Revertir: laptop-no-suspend.sh --revert
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
  ok "escrito $LOGIND_FILE"
  if systemctl restart systemd-logind 2>/dev/null; then
    ok "systemd-logind recargado (tapa ya no suspende)"
  else
    warn "no pude recargar systemd-logind; el cambio aplica al reiniciar"
  fi

  # KDE: desactivar suspensión por inactividad (si kwriteconfig6 existe)
  if command -v kwriteconfig6 >/dev/null 2>&1; then
    for grp in AC Battery LowBattery; do
      kwriteconfig6 --file powermanagementprofilesrc --group "$grp" \
        --group SuspendSession --key idleTime 0 2>/dev/null || true
      kwriteconfig6 --file powermanagementprofilesrc --group "$grp" \
        --group SuspendSession --key suspendType 0 2>/dev/null || true
    done
    ok "KDE: suspensión por inactividad desactivada (AC/batería)"
  else
    warn "kwriteconfig6 no está: configurá a mano en Sistema → Energía → Suspender sesión"
  fi
}

do_revert(){
  hdr "Revertir (volver al comportamiento normal)"
  if [[ $EUID -ne 0 ]]; then
    bad "requiere root:  sudo $0 --revert"
    return 1
  fi
  if [[ -f "$LOGIND_FILE" ]]; then
    rm -f "$LOGIND_FILE" && ok "borrado $LOGIND_FILE"
  else
    say "no existía $LOGIND_FILE; nada que borrar"
  fi
  systemctl restart systemd-logind 2>/dev/null && ok "systemd-logind recargado" || true
  if command -v kwriteconfig6 >/dev/null 2>&1; then
    for grp in AC Battery LowBattery; do
      kwriteconfig6 --file powermanagementprofilesrc --group "$grp" \
        --group SuspendSession --key idleTime 300000 2>/dev/null || true
      kwriteconfig6 --file powermanagementprofilesrc --group "$grp" \
        --group SuspendSession --key suspendType 1 2>/dev/null || true
    done
    warn "KDE: valores de inactividad restaurados a un default razonable"
  fi
}

case "$ACTION" in
  --check)  do_check ;;
  --apply)  do_apply ;;
  --revert) do_revert ;;
esac
