#!/usr/bin/env bash
#
# verify-docs.sh — Comprueba que los comandos y URLs de la documentación
# siguen siendo válidos. Ejecútalo antes de usar el kit con un cliente nuevo
# y después de actualizar Tailscale.
#
# No modifica nada: solo verifica.
#
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

PASS=0; FAIL=0; SKIP=0
if [[ -t 1 ]]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; N=$'\e[0m'; BD=$'\e[1m'; else G='';R='';Y='';N='';BD=''; fi
ok(){ printf '%s✔%s %s\n' "$G" "$N" "$*"; PASS=$((PASS+1)); }
ko(){ printf '%s✘%s %s\n' "$R" "$N" "$*"; FAIL=$((FAIL+1)); }
sk(){ printf '%s▲%s %s\n' "$Y" "$N" "$*"; SKIP=$((SKIP+1)); }
sect(){ printf '\n%s== %s ==%s\n' "$BD" "$1" "$N"; }

have(){ command -v "$1" >/dev/null 2>&1; }

sect "Herramientas locales"
have tailscale && ok "tailscale presente ($(tailscale version 2>/dev/null | head -1))" || sk "tailscale no instalado"
have curl && ok "curl disponible" || ko "curl no disponible (necesario para verificar URLs)"
have ssh && ok "ssh disponible" || ko "ssh no disponible"

sect "Comandos de Tailscale (docs/tailscale.md, docs/onboarding-cliente.md)"
if have tailscale; then
  up_help="$(tailscale up --help 2>&1)"
  grep -q -- "--auth-key"  <<<"$up_help" && ok "--auth-key existe"  || ko "--auth-key NO existe (revisa docs)"
  grep -q -- "--hostname"  <<<"$up_help" && ok "--hostname existe"  || ko "--hostname NO existe"
  grep -q -- "--advertise-tags" <<<"$up_help" && ok "--advertise-tags existe" || sk "--advertise-tags no encontrado"
  tailscale help 2>&1 | grep -q "whois" && ok "subcomando whois existe" || sk "whois no encontrado"
  tailscale help 2>&1 | grep -q "netcheck" && ok "subcomando netcheck existe" || sk "netcheck no encontrado"
  tailscale ip -4 >/dev/null 2>&1 && ok "tailscale ip -4 funciona" || ko "tailscale ip -4 falla"
  # Prefijos de key (fuente: binario). Ojo con pipefail: 'strings | grep -q'
  # falla FALSO-POSITIVO porque strings recibe SIGPIPE cuando grep cierra el
  # pipe. Capturamos la salida a una variable primero.
  if have strings; then
    ts_strings="$(strings -a "$(command -v tailscale)" 2>/dev/null || true)"
    if grep -q "tskey-auth" <<<"$ts_strings"; then
      ok "prefijo tskey-auth presente en el binario"
    else
      ko "prefijo tskey-auth NO encontrado (¿cambió el formato?)"
    fi
  else
    sk "strings no disponible; no se puede verificar el prefijo de key"
  fi
else
  sk "Tailscale no instalado: se omiten las comprobaciones de comandos"
fi

sect "URLs de la documentación oficial"
# check_url URL [codigos-aceptados]
# Las URLs del panel redirigen (302) a login si no hay sesión: es lo esperado.
check_url(){
  local url="$1" want="${2:-200}" code
  code="$(curl -sI -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || echo 000)"
  if [[ " $want " == *" $code "* ]]; then ok "$url ($code)"; else ko "$url devolvió $code (esperado $want)"; fi
}
check_url "https://tailscale.com/docs/features/access-control/auth-keys"
check_url "https://tailscale.com/docs/features/sharing"
check_url "https://login.tailscale.com/start"
check_url "https://login.tailscale.com/admin/settings/keys" "200 302"
check_url "https://console.tailscale.com/admin/settings/keys"
check_url "https://console.tailscale.com/admin/machines"

sect "Multi-distro: assets de RustDesk (API de releases)"
# El script resuelve los .deb/.rpm desde la API; verificamos que existan assets.
if command -v curl >/dev/null 2>&1; then
  assets="$(curl -fsSL --max-time 10 \
    https://api.github.com/repos/rustdesk/rustdesk/releases/latest 2>/dev/null \
    | grep -oE '"name": *"[^"]+\.(deb|rpm)"' || true)"
  if printf '%s' "$assets" | grep -q '\.deb'; then ok "hay assets .deb en el último release"
  else ko "no se encontraron assets .deb"; fi
  if printf '%s' "$assets" | grep -q '\.rpm'; then ok "hay assets .rpm en el último release"
  else ko "no se encontraron assets .rpm"; fi
  # Preferencia: los scripts deben excluir variantes sciter/suse
  # Tras el #27 la elección de asset vive en lib/sr-t-rustdesk.sh
  # (antes en setup-remote-target.sh). Aceptamos cualquiera de los dos.
  _asset_src="lib/sr-t-rustdesk.sh"; [ -f "$_asset_src" ] || _asset_src="setup-remote-target.sh"
  if grep -q "grep -v 'suse'" "$_asset_src" && grep -q "grep -v 'sciter'" "$_asset_src"; then
    ok "excluye variantes sciter/suse al elegir asset"
  else
    ko "no excluye variantes sciter/suse"
  fi
else
  sk "curl no disponible para verificar assets"
fi

sect "Hallazgos: login screen (docs/hallazgos.md H-03)"
# Determina si la PANTALLA DE LOGIN corre en X11 o Wayland.
# Importante: no basta con ver si hay Xorg (el greeter X11 usa Xorg legítimamente),
# hay que mirar el display server DEL GREETER.
if pgrep -f 'plasmalogin|startplasma-wayland' >/dev/null 2>&1; then
  if pgrep -f 'startplasma-wayland' >/dev/null 2>&1; then
    sk "login screen Wayland (plasmalogin) → allow-logon-screen-password NO aplica (H-03)"
  else
    ok "login screen plasmalogin (revisar display server)"
  fi
elif pgrep -f 'sddm|gdm|lightdm|greetd' >/dev/null 2>&1; then
  # Si el greeter usa Xorg propio (xauth en /run/sddm) → X11
  if pgrep -af Xorg 2>/dev/null | grep -qE 'run/(sddm|gdm|lightdm)'; then
    ok "login screen X11 (greeter con Xorg) → allow-logon-screen-password aplica"
  else
    sk "greeter detectado, display server indeterminado"
  fi
else
  sk "sin greeter activo ahora mismo (¿sesión ya iniciada?)"
fi

sect "Archivos y enlaces internos"
for d in docs/tailscale.md docs/onboarding-cliente.md docs/vpn-remoto.md docs/guia-desde-cero.md docs/hallazgos.md README.md; do
  [[ -f "$d" ]] && ok "existe $d" || ko "FALTA $d"
done
# Enlaces relativos entre docs
bad=0
for f in docs/*.md; do
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    tgt="$(cd "$(dirname "$f")" && cd "$(dirname "$rel")" 2>/dev/null && pwd)/$(basename "$rel")"
    [[ -e "$tgt" ]] || { ko "enlace roto en $f → $rel"; bad=1; }
  done < <(grep -oE '\]\(\.\.?/[^)]+\)' "$f" | sed -E 's/^\]\(//; s/\)$//')
done
[[ $bad -eq 0 ]] && ok "enlaces relativos entre docs válidos"

sect "Scripts del kit"
for s in setup-remote-target.sh inventory.sh tests.sh reboot-remoto.sh laptop-no-suspend.sh unir-tailscale.sh wol-despertar.sh energia-remota.sh; do
  [[ -f "$s" ]] || { ko "FALTA $s"; continue; }
  bash -n "$s" && ok "sintaxis OK: $s" || ko "error de sintaxis: $s"
  [[ -x "$s" ]] && ok "ejecutable: $s" || sk "no ejecutable: $s (chmod +x)"
done

sect "Resumen"
printf '  %s%d OK%s · %s%d fallos%s · %s%d omitidos%s\n' \
  "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$Y" "$SKIP" "$N"
if [[ $FAIL -gt 0 ]]; then
  echo
  echo "Corrige los fallos antes de usar el kit con un cliente."
  exit 1
fi
