#!/usr/bin/env bash
#
# lib/sr-t-tailscale.sh — Módulo Tailscale (+ portátil/no-suspensión).
#
# Parte del issue #27 (partir el monolito setup-remote-target.sh en módulos).
# Este archivo NO se ejecuta solo: está pensado para `source`:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/sr-t-tailscale.sh"
#
# Requiere que el script que lo carga ya tenga definidos los helpers del
# script principal (run, err, warn, info, ok, hdr, pkg_install, local_hostname,
# DRY_RUN, DISTRO_FAMILY, TS_AUTHKEY, TS_HOSTNAME, TARGET_HOSTNAME, TARGET_USER).
#
# No lleva `set -e` ni nada más: el script que lo carga ya fija sus opciones.
# El comportamiento es idéntico al bloque que antes vivía inline en
# setup-remote-target.sh.

# ---------- 4. Tailscale ----------
# Acceso fuera de la LAN sin abrir puertos. Modelo B (cuenta del cliente):
# el cliente genera la auth key y la comparte; el equipo queda en SU tailnet,
# así el cliente conserva el control y puede revocar cuando quiera.
setup_tailscale() {
  hdr "Tailscale (acceso fuera de la LAN)"

  if command -v tailscale >/dev/null 2>&1; then
    ok "tailscale ya instalado ($(tailscale version 2>/dev/null | head -1))"
  else
    # En SIMULACRO no se comprueba la red: solo se muestra qué haría. Antes el
    # dry-run fallaba en equipos sin internet (contenedor, equipo recién
    # instalado sin conectar) aunque no fuera a instalar nada.
    if [[ $DRY_RUN -eq 1 ]]; then
      info "(dry-run) instalaría Tailscale con el gestor de paquetes"
      info "(dry-run) habilitaría y arrancaría tailscaled"
    else
      # Sin red no se puede instalar nada: comprobarlo primero da un error útil
      if ! curl -fsS --max-time 8 https://pkgs.tailscale.com >/dev/null 2>&1 \
         && ! curl -fsS --max-time 8 https://archlinux.org >/dev/null 2>&1; then
        err "SIN CONEXIÓN a internet: no puedo instalar Tailscale"
        err "  Comprobá:  curl -sI https://archlinux.org | head -1"
        err "  Conectá el WiFi/hotspot y reintentá."
        return 1
      fi
    fi
    info "Instalando Tailscale..."
    if [[ $DRY_RUN -eq 1 ]]; then
      ok "(dry-run) tailscale se instalaría"
      return 0
    fi
    case "$DISTRO_FAMILY" in
      arch|debian|fedora) pkg_install tailscale ;;
      *)                  pkg_install tailscale || true ;;
    esac
    if command -v tailscale >/dev/null 2>&1; then
      ok "Tailscale instalado ($(tailscale version 2>/dev/null | head -1))"
    else
      err "No pude instalar Tailscale con el gestor de paquetes."
      case "$DISTRO_FAMILY" in
        arch)   err "  Probá a mano:  sudo pacman -S tailscale" ;;
        debian) err "  Probá a mano:  sudo apt-get install -y tailscale" ;;
        fedora) err "  Probá a mano:  sudo dnf install -y tailscale" ;;
      esac
      err "  (la red debe funcionar; el paquete está en los repos oficiales)"
      return 1
    fi
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) habilitaría y arrancaría tailscaled"
  else
    systemctl enable --now tailscaled >/dev/null 2>&1 || true
    # esperar a que el daemon quede activo (hasta 10 s)
    for _ in $(seq 1 10); do
      systemctl is-active --quiet tailscaled 2>/dev/null && break
      sleep 1
    done
    if systemctl is-active --quiet tailscaled 2>/dev/null; then
      ok "tailscaled activo"
    else
      err "tailscaled NO arrancó. Detalle:"
      systemctl status tailscaled --no-pager 2>/dev/null | tail -6 | sed 's/^/    /' || true
      err "  Si es un contenedor/entorno sin systemd, Tailscale no funcionará aquí."
      return 1
    fi
  fi

  # ¿Ya está unido?
  local ip4=""
  ip4="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  if [[ -n "$ip4" ]]; then
    ok "Ya está en la tailnet: $ip4"
    info "Para forzar re-autenticación: sudo tailscale up --auth-key=... --force-reauth"
    return 0
  fi

  if [[ -z "$TS_AUTHKEY" ]]; then
    warn "Sin --authkey: Tailscale quedó INSTALADO pero SIN unir a la tailnet"
    info ""
    info "  La auth key NO se genera en este equipo."
    info "  Se crea en la WEB y se copia acá. Desde CUALQUIER navegador"
    info "  (tu celular sirve; no hace falta Tailscale instalado):"
    info ""
    info "    1) Abrí: https://login.tailscale.com/admin/settings/keys"
    info "       (admin -> Settings -> pestaña 'Keys')"
    info "    2) Click en 'Generate auth key...'"
    info "       Description: lo que quieras   Reusable: NO   Ephemeral: NO"
    info "       Expiry: 1 día (o 90 si vas a instalar varios)"
    info "    3) Copiá el string 'tskey-auth-...' (se muestra UNA SOLA VEZ)"
    info ""
    info "  Y uní el equipo con:"
    info "    ./unir-tailscale.sh "
    info "    (o: sudo tailscale up --auth-key='tskey-auth-...' --hostname=$(local_hostname))"
    return 0
  fi

  case "$TS_AUTHKEY" in
    tskey-*) : ;;
    *) err "La auth key debe empezar con 'tskey-'. Recibido: ${TS_AUTHKEY:0:8}..."; return 1 ;;
  esac

  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) ejecutaría: tailscale up --auth-key=tskey-auth-*** --hostname=${TS_HOSTNAME:-${TARGET_HOSTNAME:-$HOSTNAME}}"
    ok "(dry-run) el equipo se uniría a la tailnet"
    return 0
  fi

  info "Uniendo el equipo a la tailnet..."
  local up_log
  up_log="$(mktemp)"
  if tailscale up --auth-key="$TS_AUTHKEY" \
       --hostname="${TS_HOSTNAME:-$(hostname 2>/dev/null || echo cliente)}" \
       --accept-dns=false >"$up_log" 2>&1; then
    ok "Equipo unido"
  else
    err "tailscale up FALLÓ. Salida:"
    sed 's/^/    /' "$up_log" | head -10
    err "  Causas típicas:"
    err "   · auth key vencida o ya usada (generá otra)"
    err "   · auth key no 'reusable' y este equipo ya estaba en la tailnet"
    err "   · sin internet en este momento"
    rm -f "$up_log"
    return 1
  fi
  rm -f "$up_log"

  # Esperar la IP (el daemon tarda unos segundos en publicarla).
  # El contador del for no se usa dentro: '_' evita el aviso de shellcheck.
  for _ in $(seq 1 15); do
    ip4="$(tailscale ip -4 2>/dev/null | head -1 || true)"
    [[ -n "$ip4" ]] && break
    sleep 1
  done
  if [[ -n "$ip4" ]]; then
    ok "IP Tailscale: $ip4"
    info "Prueba desde el operador: ssh ${TARGET_USER}@${ip4}"
  else
    err "Unido pero sin IP Tailscale tras 15 s."
    err "  Revisá:  sudo tailscale status"
    err "  Si dice 'logged out', la auth key no se aceptó."
    return 1
  fi
}

# H-29: un portátil que suspende (tapa cerrada o inactividad) PIERDE el
# acceso remoto: Tailscale/sshd/RustDesk se caen hasta que alguien abra la
# tapa. En un PC de escritorio no pasa. Esto lo desactiva (reversible).
setup_laptop() {
  hdr "Portátil: impedir suspensión (H-29)"
  local logind_dir="/etc/systemd/logind.conf.d"
  local logind_file="$logind_dir/99-no-suspend-laptop.conf"

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "sin systemd: no puedo configurar logind; hacelo a mano si es portátil"
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) escribiría $logind_file con HandleLidSwitch=ignore"
    info "(dry-run) reiniciaría systemd-logind y quitaría la suspensión por inactividad en KDE"
    return 0
  fi

  mkdir -p "$logind_dir"
  cat > "$logind_file" <<'EOF'
# Generado por setup-remote-target.sh --laptop (H-29).
# Evita que el portátil suspenda y se pierda el acceso remoto.
# Revertir: borrar este archivo y: systemctl restart systemd-logind
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
  ok "escrito $logind_file (tapa ya no suspende)"

  if systemctl restart systemd-logind 2>/dev/null; then
    ok "systemd-logind recargado"
  else
    warn "no pude recargar systemd-logind; aplica al reiniciar"
  fi

  # KDE: sin suspensión por inactividad (AC y batería).
  if command -v kwriteconfig6 >/dev/null 2>&1; then
    local grp
    for grp in AC Battery LowBattery; do
      kwriteconfig6 --file powermanagementprofilesrc --group "$grp" \
        --group SuspendSession --key idleTime 0 2>/dev/null || true
      kwriteconfig6 --file powermanagementprofilesrc --group "$grp" \
        --group SuspendSession --key suspendType 0 2>/dev/null || true
    done
    ok "KDE: suspensión por inactividad desactivada"
  else
    warn "kwriteconfig6 ausente: desactivá a mano en Energía → Suspender sesión"
  fi
  info "Reversible: ./laptop-no-suspend.sh --revert"
}
