#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-offlan.sh — verifica el acceso remoto FUERA DE LA LAN (punto 2, prueba A)
#
# Se corre en el equipo OPERADOR después de conectarlo a otra red (p. ej. el
# hotspot 4G del teléfono). Comprueba que el acceso por Tailscale funciona sin
# depender de la ruta LAN, que es el caso real de un cliente en otra casa.
#
# Uso:
#   ./verify-offlan.sh                    # autodetecta el primer peer online
#   ./verify-offlan.sh 100.x.y.z          # IP Tailscale del objetivo
#   ./verify-offlan.sh <alias-ssh>
#
# Salida: lista de comprobaciones ✔/✘ con el veredicto final.
# ---------------------------------------------------------------------------
set -uo pipefail   # sin -e: queremos seguir aunque una comprobación falle

PASS=0; FAIL=0
ON_LAN=0   # se enciende si detectamos ruta privada hacia el objetivo
ok()   { printf '\033[1;32m✔\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '\033[1;31m✘\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '\033[1;33m▲\033[0m %s\n' "$*"; }
# OJO: NO llamarla 'info': colisiona con info(1) del sistema y rompe el script
# con "No menu item ... in node (dir)Top" cuando hay texinfo instalado.
say()  { printf '\033[1;34m●\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }


# El peer NO tiene valor por defecto: antes era 'fedora' (un resto de
# desarrollo) y en otro entorno daba un mensaje confuso. Si no se pasa,
# se autodetecta el primer peer ONLINE de la tailnet que no sea este equipo.
PEER="${1:-}"
SSH_USER="${SSH_USER:-$(whoami)}"

if [[ -z "$PEER" ]]; then
  if command -v tailscale >/dev/null 2>&1; then
    PEER="$(tailscale status --json 2>/dev/null \
      | jq -r '[.Peer[] | select(.Online==true)][0].HostName // empty' 2>/dev/null || true)"
  fi
  if [[ -n "$PEER" ]]; then
    say "peer no indicado; uso el primer equipo online de la tailnet: $PEER"
    echo "  (podés pasar otro: $0 <ip-o-nombre>)" >&2
  else
    echo "error: no indicaste el equipo a verificar y no pude autodetectarlo." >&2
    echo "  Uso: $0 <ip-tailscale-o-nombre>" >&2
    echo "  Ver equipos:  tailscale status" >&2
    exit 2
  fi
fi

hdr "1. Estado de la red del operador"
PQ="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
say "IP local del operador: ${PQ:-?}"
IFACE="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
say "Interfaz de salida    : ${IFACE:-?}"
PUB="$(timeout 8 curl -s https://api.ipify.org 2>/dev/null || true)"
say "IP pública (salida)   : ${PUB:-no se pudo obtener}"
if [[ -z "$PUB" ]]; then
  warn "sin internet: revisá el hotspot antes de seguir"
fi

# ¿Sigue habiendo ruta a la red LAN del objetivo? Si sí, la prueba no sirve.
# Comprobar si el OBJETIVO es alcanzable por una IP privada directa (eso sí
# invalidaría la prueba). Mirar las rutas locales del operador NO sirve: sus
# propias redes 192.168.x son normales y no dicen nada del objetivo.
PEER_LOCAL_IPS="$( (tailscale status --json 2>/dev/null | \
  jq -r --arg ip "$PEER" '.Peer[] | select(.TailscaleIPs[0]==$ip or .HostName==$ip) | .TailscaleIPs[]' 2>/dev/null) )"
PRIV_DEST=0
for pip in $PEER_LOCAL_IPS; do
  [[ -z "$pip" ]] && continue
  # ¿hay ruta directa a alguna IP del peer sin pasar por tailscale0?
  # OJO: `ip route get` imprime 2 líneas (ruta + cache); hay que mirar SOLO
  # la primera, o el 'cache' de la segunda da falso positivo.
  first_hop="$(ip route get "$pip" 2>/dev/null | head -1)"
  if [[ -n "$first_hop" ]] && ! grep -q 'tailscale0' <<<"$first_hop"; then
    PRIV_DEST=1
  fi
done
if [[ $PRIV_DEST -eq 1 ]]; then
  ON_LAN=1
  warn "el objetivo es alcanzable sin pasar por tailscale0 → posible ruta LAN"
else
  ok "el objetivo se alcanza por tailscale0 (no por ruta local)"
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
  # Ruta LAN = la IP de destino del pong pertenece a MI red local.
  # Ojo: 'via 10.x' puede ser legítimo (CGNAT del operador móvil del peer).
  VIA_IP="$(echo "$PING_OUT" | sed -n 's/.*via \([0-9.]*\):.*/\1/p' | head -1)"
  if [[ -n "$VIA_IP" ]] && ip -4 route get "$VIA_IP" 2>/dev/null | grep -qv 'tailscale0' \
     && ip -4 addr 2>/dev/null | grep -q "$VIA_IP/" 2>/dev/null; then
    ON_LAN=1
    warn "la ruta es LOCAL/privada → NO es una prueba fuera de la LAN"
    warn "  revisá que el WiFi del portátil esté apagado"
  elif echo "$PING_OUT" | grep -qi "via DERP"; then
    say "va por RELAY (DERP). Funciona, pero más lento que directo."
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
  say "ID de RustDesk del objetivo: $RID"
  say "  Probalo a mano: abrí RustDesk y conectá a $RID con la contraseña permanente."
  say "  (RustDesk no tiene CLI de conexión — ver H-17)"
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
