#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# unir-tailscale.sh — une ESTE equipo a la tailnet, pidiendo la auth key.
#
# La auth key NO se genera en el equipo: se crea en la WEB de Tailscale y se
# copia acá. Se puede generar desde CUALQUIER navegador (el celular sirve),
# sin necesidad de tener Tailscale instalado donde la generás.
#
# Uso:
#   ./unir-tailscale.sh                 # pide la key y une (interactivo)
#   ./unir-tailscale.sh --hostname PC   # nombre del equipo en la tailnet
#   ./unir-tailscale.sh --check         # explica y verifica, sin unir
#
#   --key "tskey-auth-..."   pasar la key directo (sin prompt)
#
# Requiere: Tailscale instalado (lo hace instalar-todo.sh --tailscale-luego).
# ---------------------------------------------------------------------------
set -uo pipefail

HOSTNAME_TS=""
AUTHKEY=""
CHECK=0

ok()   { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m✘\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m▲\033[0m %s\n' "$*"; }
say()  { printf '\033[1;34m●\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

usage(){ sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname) HOSTNAME_TS="${2:-}"; shift 2 ;;
    --key)      AUTHKEY="${2:-}"; shift 2 ;;
    --check)    CHECK=1; shift ;;
    -h|--help)  usage ;;
    *) echo "opción desconocida: $1" >&2; usage ;;
  esac
done

# ---------- de dónde sale la key (esto es lo que la gente no sabe) ----------
explicar_key(){
  hdr "De dónde sale la auth key (importante)"
  cat <<'EOF'
  La auth key NO se genera en este equipo, ni la da Tailscale instalado.
  Se crea en la WEB de Tailscale, logueado con TU cuenta, desde cualquier
  navegador (el celular alcanza). Después se copia acá como texto.

    1) Abrí en un navegador:
         https://login.tailscale.com/admin/settings/keys
       (camino manual: admin -> Settings -> pestaña "Keys")

    2) Click en "Generate auth key..."
         Description : lo que quieras (ej. "laptop-cliente")
         Reusable    : NO   (un equipo)  |  SÍ (varios equipos)
         Ephemeral   : NO   (el equipo es permanente)
         Pre-approved: SÍ   (evita aprobar a mano)
         Expiry      : 1 día (o 90 si vas a instalar varios)

    3) Copiá el string que empieza con  tskey-auth-...
       OJO: se muestra UNA SOLA VEZ. Si cerrás el diálogo, generá otra.

  Pegalo abajo (o pasalo con:  --key 'tskey-auth-...').
EOF
}

# ---------- ¿está Tailscale instalado? ----------
if ! command -v tailscale >/dev/null 2>&1; then
  bad "Tailscale NO está instalado en este equipo."
  say "Instalalo primero:"
  say "  sudo ./setup-remote-target.sh --install-tailscale"
  say "  (o volvé a correr instalar-todo.sh con --tailscale-luego)"
  exit 1
fi
ok "Tailscale instalado ($(tailscale version 2>/dev/null | head -1))"

# ---------- ¿ya está unido? ----------
ip4="$(tailscale ip -4 2>/dev/null | head -1 || true)"
if [[ -n "$ip4" ]]; then
  ok "Este equipo YA está en la tailnet: $ip4"
  info_st="$(tailscale status 2>/dev/null | head -1 || true)"
  [[ -n "$info_st" ]] && say "$info_st"
  say "Para re-autenticar con otra key: sudo tailscale up --auth-key='...' --force-reauth"
  exit 0
fi

explicar_key

if [[ $CHECK -eq 1 ]]; then
  say "--check: no se une nada. Corré sin --check para unir."
  exit 0
fi

# ---------- pedir la key si no vino por argumento ----------
if [[ -z "$AUTHKEY" ]]; then
  printf '\nPegá la auth key (tskey-auth-...): '
  read -r AUTHKEY
fi

AUTHKEY="${AUTHKEY// /}"   # sin espacios accidentales
case "$AUTHKEY" in
  tskey-*) : ;;
  "") bad "no pegaste ninguna key"; exit 1 ;;
  *) bad "no parece una auth key (debe empezar con 'tskey-'). Recibido: ${AUTHKEY:0:8}…"; exit 1 ;;
esac
ok "formato de key correcto"

# ---------- hostname ----------
if [[ -z "$HOSTNAME_TS" ]]; then
  HOSTNAME_TS="$(hostname 2>/dev/null || echo cliente)"
fi

# ---------- unir ----------
hdr "Uniendo a la tailnet (hostname: $HOSTNAME_TS)"
log="$(mktemp)"
if sudo tailscale up --auth-key="$AUTHKEY" --hostname="$HOSTNAME_TS" --accept-dns=false >"$log" 2>&1; then
  ok "unido"
else
  bad "tailscale up FALLÓ. Salida:"
  sed 's/^/    /' "$log" | head -12
  bad "  Causas típicas:"
  bad "   · key vencida o ya usada (generá otra)"
  bad "   · key no 'reusable' y el equipo ya estaba en la tailnet"
  bad "   · sin internet en este momento"
  rm -f "$log"; exit 1
fi
rm -f "$log"

# ---------- esperar la IP ----------
for _ in $(seq 1 15); do
  ip4="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  [[ -n "$ip4" ]] && break
  sleep 1
done
if [[ -n "$ip4" ]]; then
  ok "IP Tailscale: $ip4"
  say "Prueba desde el operador:  ssh $(whoami)@$ip4"
else
  bad "unido pero sin IP tras 15 s. Revisá: sudo tailscale status"
  exit 1
fi
