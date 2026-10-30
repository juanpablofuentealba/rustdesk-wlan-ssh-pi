#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# onboarding.sh — instalar un cliente nuevo en UNA linea
#
# Pensado para "llegar e instalar": baja el kit oficial, lo verifica y corre
# instalar-todo.sh con valores por defecto sensatos. Al terminar imprime una
# FICHA lista para pegar en el chat del operador (ID de RustDesk, contraseña,
# IP de Tailscale, hostname).
#
# Uso tipico EN LA MAQUINA DEL CLIENTE (con sudo):
#
#   curl -fsSL https://raw.githubusercontent.com/juanpablofuentealba/rustdesk-wlan-ssh-pi/main/onboarding.sh \
#     | sudo bash -s -- --nombre cliente-juan --rdpass 'ClaveLarga2026'
#
# Con auth key de Tailscale (evita que quede en el historial: se pide por STDIN):
#
#   curl -fsSL .../onboarding.sh | sudo bash -s -- --nombre cliente-juan --rdpass 'X' --authkey-stdin
#
# Sin Tailscale (solo LAN) o dejandolo para despues:
#   ... | sudo bash -s -- --nombre c --rdpass 'X' --skip-tailscale
#   ... | sudo bash -s -- --nombre c --rdpass 'X' --tailscale-luego
#
# OJO: no pongas la auth key ni la contraseña en la linea de comandos de un
# equipo ajeno: queda en el historial. Para la auth key usa --authkey-stdin.
#
# Opciones:
#   --nombre   <cliente>      Nombre corto del cliente (ficha + hostname tailnet). Obligatorio.
#   --rdpass   <clave>        Contraseña permanente de RustDesk. Obligatorio.
#   --tailnet-host <nombre>   Nombre en la tailnet (por defecto: cliente-<nombre>).
#   --operador-hosts "a b c"  Claves públicas de los operadores: descarga
#                             <host>.pub del repo y las encadena en --key.
#                             (cada identidad por operador: H-43)
#   --key      "ssh-ed25519 ..."  Clave pública suelta (alternativa a --operador-hosts)
#   --authkey-stdin           Lee la auth key de Tailscale por STDIN.
#   --authkey  "tskey-..."    (menos seguro: queda en historial/ps)
#   --skip-tailscale          No instalar Tailscale (solo LAN).
#   --tailscale-luego         Instalar Tailscale sin unir todavia.
#   --ref      <git-ref>      Rama/tag/commit del repo (por defecto: main).
#   --local    <dir>          Usar un kit ya descargado en <dir> (modo offline).
#   --no-ficha                No imprimir la ficha final.
#   --dry-run / --yes         Se pasan tal cual a instalar-todo.sh.
#   -h, --help                Esta ayuda.
#
# Repositorio: https://github.com/juanpablofuentealba/rustdesk-wlan-ssh-pi
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_SLUG="juanpablofuentealba/rustdesk-wlan-ssh-pi"
REF="main"
NOMBRE=""
RDPASS=""
OPHOSTS=""
OPKEY=""
TAILNET_HOST=""
LOCALDIR=""

NO_FICHA=0
PASSTHRU=()

info() { printf '\033[1;34m●\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m▲\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m✘\033[0m %s\n' "$*" >&2; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

usage() { sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nombre)          NOMBRE="${2:-}"; shift 2 ;;
    --rdpass)          RDPASS="${2:-}"; shift 2 ;;
    --operador-hosts)  OPHOSTS="${2:-}"; shift 2 ;;
    --tailnet-host)    TAILNET_HOST="${2:-}"; shift 2 ;;
    --key)             OPKEY="${2:-}"; shift 2 ;;
    --ref)             REF="${2:-}"; shift 2 ;;
    --local)           LOCALDIR="${2:-}"; shift 2 ;;
    --no-ficha)        NO_FICHA=1; shift ;;
    --authkey)         PASSTHRU+=(--authkey "${2:-}"); shift 2 ;;
    --authkey-stdin)   PASSTHRU+=(--authkey-stdin); shift ;;
    --skip-tailscale)  PASSTHRU+=(--skip-tailscale); shift ;;
    --tailscale-luego) PASSTHRU+=(--tailscale-luego); shift ;;
    --dry-run)         PASSTHRU+=(--dry-run); shift ;;
    --yes|-y)          PASSTHRU+=(--yes); shift ;;
    -h|--help)         usage; exit 0 ;;
    *) err "opción desconocida: $1"; usage; exit 2 ;;
  esac
done

if [[ -z "$NOMBRE" ]]; then
  err "falta --nombre (nombre corto del cliente, ej: cliente-juan)."
  usage; exit 2
fi
if [[ -z "$RDPASS" ]]; then
  err "falta --rdpass (contraseña permanente de RustDesk)."
  err "  Sin ella no hay acceso desatendido. Ej: --rdpass 'ClaveLarga2026'"
  exit 2
fi
case "$NOMBRE" in
  *[!a-z0-9._-]*) err "--nombre solo admite a-z 0-9 . _ -  (recibido: $NOMBRE)"; exit 2 ;;
esac

# Ser root no es obligatorio para descargar, pero instalar-todo.sh sí lo exige.
if [[ "$(id -u)" -ne 0 && $LOCALDIR == "" ]]; then
  warn "no sos root: se permite para --dry-run, pero la instalación real necesita sudo."
fi

# ---------------------------------------------------------------------------
# 1. Obtener el kit: local (offline) o descargado del repo (tarball del ref)
# ---------------------------------------------------------------------------
WORK=""
cleanup() { [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"; }
trap cleanup EXIT

if [[ -n "$LOCALDIR" ]]; then
  if [[ ! -f "$LOCALDIR/instalar-todo.sh" ]]; then
    err "--local '$LOCALDIR' no contiene instalar-todo.sh"; exit 2
  fi
  KIT="$LOCALDIR"
  ok "Usando kit local: $KIT (modo offline)"
else
  command -v curl >/dev/null 2>&1 || { err "falta curl (instalalo y reintentá)."; exit 1; }
  command -v tar  >/dev/null 2>&1 || { err "falta tar (instalalo y reintentá).";  exit 1; }
  WORK="$(mktemp -d /tmp/onboarding.XXXXXX)"
  TARBALL_URL="https://codeload.github.com/$REPO_SLUG/tar.gz/refs/heads/$REF"
  # Codeload no sirve tags con /refs/heads; para tags hay /refs/tags. Probamos ambos.
  info "Descargando el kit ($REF)…"
  if ! curl -fsSL "$TARBALL_URL" -o "$WORK/kit.tar.gz"; then
    TARBALL_URL="https://codeload.github.com/$REPO_SLUG/tar.gz/$REF"
    curl -fsSL "$TARBALL_URL" -o "$WORK/kit.tar.gz" \
      || { err "no pude descargar el kit de $REPO_SLUG@$REF"; exit 1; }
  fi
  tar -xzf "$WORK/kit.tar.gz" -C "$WORK" || { err "tarball corrupto"; exit 1; }
  KIT="$(find "$WORK" -maxdepth 2 -name instalar-todo.sh -printf '%h\n' | head -1)"
  [[ -n "$KIT" ]] || { err "el tarball no trae instalar-todo.sh"; exit 1; }
  # Verificación de integridad si el tarball trae el manifiesto del kit.
  if [[ -f "$KIT/MANIFEST.sha256" ]]; then
    if (cd "$KIT" && sha256sum -c MANIFEST.sha256 >/dev/null 2>&1); then
      ok "integridad del kit verificada (MANIFEST.sha256)"
    else
      warn "MANIFEST.sha256 presente pero la verificación falló (¿ref en movimiento?)"
    fi
  fi
  ok "Kit listo en $KIT"
fi

# ---------------------------------------------------------------------------
# 2. Clave(s) pública(s) del operador
# ---------------------------------------------------------------------------
resolve_opkey() {
  # $1 = host del operador -> descarga <host>.pub del repo
  local host="$1" url out
  url="https://raw.githubusercontent.com/$REPO_SLUG/$REF/operadores/$host.pub"
  out="$(mktemp)"
  if curl -fsSL "$url" -o "$out" 2>/dev/null && [[ -s "$out" ]]; then
    cat "$out"; rm -f "$out"
    return 0
  fi
  rm -f "$out"
  # Fallback: el host puede ser la clave pública completa (ssh-ed25519 ...)
  case "$host" in
    ssh-*) printf '%s\n' "$host"; return 0 ;;
  esac
  return 1
}

KEYS_TMP=""
addkey() { # acumula claves, una por linea
  KEYS_TMP="${KEYS_TMP}${1}"$'\n'
}

if [[ -n "$OPHOSTS" ]]; then
  for h in $OPHOSTS; do
    if k="$(resolve_opkey "$h")"; then
      addkey "$k"; ok "clave de operador resuelta: $h"
    else
      warn "no encontré clave para '$h' (ni operadores/$h.pub ni una clave ssh-…)"
    fi
  done
fi
if [[ -n "$OPKEY" ]]; then addkey "$OPKEY"; fi

# Si el kit trae operador.pub (make-kit.sh --with-key) y no dimos ninguna, úsala.
if [[ -z "$KEYS_TMP" && -f "$KIT/operador.pub" ]]; then
  addkey "$(cat "$KIT/operador.pub")"
  ok "usando operador.pub incluido en el kit"
fi

KEYARG=()
if [[ -n "$KEYS_TMP" ]]; then
  # --key acepta varias claves separadas por salto de linea
  KEYARG+=(--key "$(printf '%s' "$KEYS_TMP" | sed '/^$/d')")
else
  warn "sin clave de operador: el operador NO podrá entrar por SSH hasta autorizarla."
  warn "  Pasá --operador-hosts 'hp-operador msi-operador' o --key 'ssh-ed25519 ...'"
fi

# ---------------------------------------------------------------------------
# 3. Ejecutar instalar-todo.sh
# ---------------------------------------------------------------------------
# Hostname en la tailnet: por defecto 'cliente-<nombre>', para que la flota se
# reconozca de un vistazo. Se puede sobreescribir con --tailnet-host.
[[ -z "$TAILNET_HOST" ]] && TAILNET_HOST="cliente-$NOMBRE"

hdr "Instalando ($NOMBRE)"
info "hostname en la tailnet: $TAILNET_HOST"
MPASS=()
[[ -n "$RDPASS" ]] && MPASS+=(--rdpass "$RDPASS")
MPASS+=(--tailnet-host "$TAILNET_HOST")
[[ ${#KEYARG[@]} -gt 0 ]] && MPASS+=("${KEYARG[@]}")
[[ ${#PASSTHRU[@]} -gt 0 ]] && MPASS+=("${PASSTHRU[@]}")

(cd "$KIT" && bash ./instalar-todo.sh "${MPASS[@]}")
RC=$?

# ---------------------------------------------------------------------------
# 4. Ficha final (para pegar en el chat del operador)
# ---------------------------------------------------------------------------
if [[ $RC -ne 0 ]]; then
  err "instalar-todo.sh terminó con código $RC — revisá la salida de arriba."
  exit $RC
fi

if [[ $NO_FICHA -eq 1 ]]; then
  ok "Instalación completada."
  exit 0
fi

echo
hdr "FICHA DEL CLIENTE — copiá y pegá al operador"

TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
TS_NAME="$(tailscale status --json 2>/dev/null | sed -n 's/.*"DNSName": "\([^"]*\)".*/\1/p' | head -1 || true)"
RD_ID="$(rustdesk --get-id 2>/dev/null | tail -1 || true)"
[[ -z "$RD_ID" ]] && RD_ID="$(grep -oE '[0-9]{9,}' /root/.config/rustdesk/RustDesk.toml 2>/dev/null | head -1 || true)"
DISTRO="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"' || true)"
HOST="$(hostname 2>/dev/null || true)"

cat <<FICHA

  cliente      : $NOMBRE
  host         : $HOST
  distro       : $DISTRO
  rustdesk id  : ${RD_ID:-(no detectado — revisá 'rustdesk --get-id')}
  rustdesk pass: $RDPASS
  tailscale ip : ${TS_IP:-(sin tailscale)}
  tailnet name : ${TS_NAME:-(sin tailscale)}

  Verificación desde el operador:
    ssh $TS_NAME true && echo "SSH OK"
    rustdesk -> conectar al ID ${RD_ID:?}

FICHA

ok "Onboarding de '$NOMBRE' terminado."
