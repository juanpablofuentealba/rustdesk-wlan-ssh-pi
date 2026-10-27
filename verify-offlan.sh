#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-offlan.sh — verifica el acceso remoto FUERA DE LA LAN (punto 2, prueba A)
#
# Se corre en el equipo OPERADOR después de conectarlo a otra red (p. ej. el
# hotspot 4G del teléfono). Comprueba que el acceso por Tailscale funciona sin
# depender de la ruta LAN, que es el caso real de un cliente en otra casa.
#
# Uso:
#   ./verify-offlan.sh                    # usa el peer 'fedora' por defecto
#   ./verify-offlan.sh 100.x.y.z          # IP Tailscale del objetivo
#   ./verify-offlan.sh <alias-ssh>
#
# Salida: lista de comprobaciones ✔/✘ con el veredicto final.
# ---------------------------------------------------------------------------
set -uo pipefail   # sin -e: queremos seguir aunque una comprobación falle

PEER="${1:-fedora}"
SSH_USER="${SSH_USER:-jp}"

PASS=0; FAIL=0
ON_LAN=0   # se enciende si detectamos ruta privada hacia el objetivo
ok()   { printf '\033[1;32m✔\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '\033[1;31m✘\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '\033[1;33m▲\033[0m %s\n' "$*"; }
info() { printf '\033[1;34m●\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

hdr "1. Estado de la red del operador"
PQ="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
info "IP local del operador: ${PQ:-?}"
IFACE="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
info "Interfaz de salida    : ${IFACE:-?}"
PUB="$(timeout 8 curl -s https://api.ipify.org 2>/dev/null || true)"
info "IP pública (salida)   : ${PUB:-no se pudo obtener}"
if [[ -z "$PUB" ]]; then
  warn "sin internet: revisá el hotspot antes de seguir"
fi

# ¿Sigue habiendo ruta a la red LAN del objetivo? Si sí, la prueba no sirve.
if ip route 2>/dev/null | grep -qE '192\.168\.122\.|192\.168\.1\.'; then
  ON_LAN=1
  warn "hay rutas a 192.168.x → puede que sigas en la LAN del objetivo"
  warn "  el resultado NO probaría el acceso fuera de la LAN"
else
  ok "sin rutas evidentes a la LAN del objetivo"
fi

hdr "2. Tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  bad "tailscale no está instalado en el operador"
  exit 1
fi
if tailscale status >/dev/null 2>&1; then
  ok "tailscaled responde"
else
  bad "tailscaled no responde (sudo systemctl status tailscaled)"
fi

# Resolver el peer
PEER_IP="$PEER"
if [[ ! "$PEER" =~ ^100\. ]]; then
  PEER_IP="$(tailscale ip -4 "$PEER" 2>/dev/null | head -1 || true)"
  [[ -z "$PEER_IP" ]] && PEER_IP="$(getent hosts "$PEER" 2>/dev/null | awk '{print $1}' | head -1 || true)"
fi
if [[ -n "$PEER_IP" ]]; then
  ok "objetivo resuelto: $PEER → $PEER_IP"
else
  bad "no pude resolver '$PEER' (¿existe en la tailnet? ¿MagicDNS activo?)"
  exit 1
fi

if tailscale status 2>/dev/null | grep -q "$PEER_IP"; then
  ok "el objetivo aparece en 'tailscale status'"
else
  bad "el objetivo NO aparece en 'tailscale status'"
fi

hdr "3. Ruta real hacia el objetivo (lo que importa)"
PING_OUT="$(timeout 20 tailscale ping -c 3 "$PEER_IP" 2>&1 || true)"
echo "$PING_OUT" | sed 's/^/    /'
if echo "$PING_OUT" | grep -qi "pong"; then
  ok "responde (tailscale ping)"
  if echo "$PING_OUT" | grep -qiE "via 192\.168\.|via 10\.|via 172\.(1[6-9]|2[0-9]|3[01])\."; then
    ON_LAN=1
    warn "la ruta es LOCAL/privada → NO es una prueba fuera de la LAN"
    warn "  revisá que el WiFi del portátil esté apagado"
  elif echo "$PING_OUT" | grep -qi "via DERP"; then
    info "va por RELAY (DERP). Funciona, pero más lento que directo."
    ok "conexión funciona fuera de la LAN (vía relay)"
  else
    ok "ruta DIRECTA (perforación de NAT) → funciona fuera de la LAN"
  fi
else
  bad "no responde (tailscale ping). Revisá tailscale netcheck"
fi

hdr "4. SSH por Tailscale"
if ssh -o BatchMode=yes -o ConnectTimeout=12 -o StrictHostKeyChecking=accept-new \
       "${SSH_USER}@${PEER_IP}" 'echo OK' >/dev/null 2>&1; then
  H="$(ssh -o BatchMode=yes -o ConnectTimeout=12 "${SSH_USER}@${PEER_IP}" 'hostname; tailscale ip -4' 2>/dev/null | tr '\n' ' ')"
  ok "SSH entra por la IP Tailscale: $H"
else
  bad "SSH no entra por $PEER_IP"
  if ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
         "${SSH_USER}@${PEER_IP}" 'true' 2>&1 | grep -qi "permission denied"; then
    warn "  'permission denied' → la clave del operador no está autorizada en el objetivo"
  fi
fi

hdr "5. RustDesk (recordatorio manual)"
RID="$(ssh -o BatchMode=yes -o ConnectTimeout=12 "${SSH_USER}@${PEER_IP}" \
        'rustdesk --get-id 2>/dev/null' 2>/dev/null | tr -d '\r' | head -1 || true)"
if [[ -n "$RID" ]]; then
  info "ID de RustDesk del objetivo: $RID"
  info "  Probalo a mano: abrí RustDesk y conectá a $RID con la contraseña permanente."
  info "  (RustDesk no tiene CLI de conexión — ver H-17)"
else
  warn "no pude leer el ID de RustDesk por SSH"
fi

hdr "Veredicto"
printf '  %d OK · %d fallos\n' "$PASS" "$FAIL"
if [[ $FAIL -ne 0 ]]; then
  printf '\033[1;31m  Hay fallos: revisá los ✘ de arriba.\033[0m\n'
  exit 1
elif [[ $ON_LAN -eq 1 ]]; then
  printf '\033[1;33m  El acceso funciona, PERO por la ruta LAN.\033[0m\n'
  printf '\033[1;33m  Esto NO prueba el caso de un cliente en otra red.\033[0m\n'
  printf '\033[1;33m  Apagá el WiFi y usá el hotspot 4G; después repetí.\033[0m\n'
  exit 2
else
  printf '\033[1;32m  El acceso remoto funciona fuera de la LAN.\033[0m\n'
  exit 0
fi
