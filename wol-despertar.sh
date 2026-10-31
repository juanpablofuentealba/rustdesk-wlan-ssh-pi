#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# wol-despertar.sh — despierta un equipo por Wake-on-LAN desde el operador.
#
# Por qué existe:
#   Tailscale NO puede despertar un equipo apagado. El magic packet de WoL es
#   un broadcast Ethernet (capa 2) y Tailscale solo transporta IP (capa 3).
#   Pero si el OPERADOR (que sí está encendido) comparte la LAN con el equipo
#   apagado, puede enviar el magic packet localmente. Encadenando:
#
#       móvil --Tailscale--> operador --magic packet LAN--> equipo apagado
#
#   ...se logra "despertar por Tailscale" sin que Tailscale despierte nada.
#
# Requisitos: python3 (para el magic packet). NO necesita paquetes extra.
#
# Uso:
#   ./wol-despertar.sh --mac XX:XX:XX:XX:XX:XX             # enviar
#   ./wol-despertar.sh --mac ... --wait                     # enviar y esperar
#   ./wol-despertar.sh --mac ... --bcast 192.168.1.255
#   ./wol-despertar.sh --mac ... --wait --check 'ssh host hostname'
#
#   --check / WOL_CHECK reciben un COMANDO simple (se ejecuta tal cual, sin
#   evaluación de shell: no admite pipes, redirecciones, &&, ; ni $() ).
#   Para algo más complejo, envolvé en un script propio:
#     --check '/home/jp/mi-check-wol.sh'
#
#   Alternativa sin --mac: exportar WOL_MAC o usar --learn-iface <iface> para
#   aprender la MAC de un equipo Linux encendido vía SSH.
# ---------------------------------------------------------------------------
set -euo pipefail

MAC=""
BCAST="${WOL_BCAST:-255.255.255.255}"
WAIT=0
CHECK_CMD="${WOL_CHECK:-}"
LEARN_SSH=""

say()  { printf '\033[1;34m●\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m✘\033[0m %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mac)   MAC="${2:?falta MAC}"; shift 2 ;;
    --bcast) BCAST="${2:?falta broadcast}"; shift 2 ;;
    --wait)  WAIT=1; shift ;;
    --check) CHECK_CMD="${2:?falta comando}"; shift 2 ;;
    --learn-ssh) LEARN_SSH="${2:?falta host ssh}"; shift 2 ;;
    -h|--help) sed -n '3,26p' "$0"; exit 0 ;;
    *) err "opción desconocida: $1"; exit 2 ;;
  esac
done

# Aprender MAC de un equipo Linux encendido (por SSH)
if [[ -z "$MAC" && -n "$LEARN_SSH" ]]; then
  say "Aprendiendo MAC de $LEARN_SSH por SSH..."
  iface_guess="$(timeout 10 ssh -o ConnectTimeout=6 -o BatchMode=yes "$LEARN_SSH" \
    "ip -o link show | grep -v 'lo:' | grep 'state UP' | head -1 | cut -d: -f2 | tr -d ' '" 2>/dev/null || true)"
  if [[ -n "$iface_guess" ]]; then
    MAC="$(timeout 10 ssh -o ConnectTimeout=6 -o BatchMode=yes "$LEARN_SSH" \
      "cat /sys/class/net/$iface_guess/address" 2>/dev/null | tr -d '\r' || true)"
  fi
fi
[[ -z "$MAC" ]] && MAC="${WOL_MAC:-}"

if [[ ! "$MAC" =~ ^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$ ]]; then
  err "MAC inválida o ausente: '$MAC'. Usa --mac XX:XX:XX:XX:XX:XX"
  exit 1
fi

# Enviar magic packet (python3, sin dependencias)
say "Enviando magic packet a $MAC → $BCAST"
python3 - "$MAC" "$BCAST" <<'PY'
import socket, sys
mac = sys.argv[1].replace(':','').replace('-','').lower()
bcast = sys.argv[2]
payload = bytes.fromhex('ff'*6 + mac*16)     # 6x FF + MAC repetida 16 veces = 102 B
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
for port in (9, 7):
    s.sendto(payload, (bcast, port))
s.close()
PY
ok "Paquete enviado."

# Esperar a que el equipo responda
if [[ "$WAIT" == "1" ]]; then
  [[ -z "$CHECK_CMD" ]] && { err "--wait requiere --check 'comando'"; exit 1; }
  # Sin eval: se parte el comando en argv y se ejecuta directo. Si el primer
  # elemento no es un ejecutable válido, se aborta con un error claro.
  read -ra CHECK_ARGV <<<"$CHECK_CMD"
  if ! command -v "${CHECK_ARGV[0]}" >/dev/null 2>&1; then
    err "--check no apunta a un ejecutable válido: '${CHECK_ARGV[0]}'"
    exit 1
  fi
  say "Esperando a que el equipo responda (máx. 120s)..."
  for i in $(seq 1 24); do
    if "${CHECK_ARGV[@]}" >/dev/null 2>&1; then
      ok "Equipo despierto tras ~$((i*5))s"
      exit 0
    fi
    sleep 5
  done
  err "No respondió en 120s. ¿WoL activo en la NIC? ¿BIOS mantiene la NIC?"
  exit 1
fi
