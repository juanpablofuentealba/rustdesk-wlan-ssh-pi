#!/usr/bin/env bash
#
# lib/sr-t-ssh.sh — Módulo SSH (sshd + firewall + clave del operador).
#
# Parte del issue #27 (partir el monolito setup-remote-target.sh en módulos).
# Este archivo NO se ejecuta solo: está pensado para `source`:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/sr-t-ssh.sh"
#
# Requiere que el script que lo carga ya tenga definidos los helpers del
# script principal (run, err, warn, info, ok, hdr, detect_firewall,
# ufw_verify, pkg_install, need_root, as_user, pkg_installed, local_ip,
# DRY_RUN, DISTRO_FAMILY, TARGET_HOME, TARGET_USER, SSH_PORT, KEY, B, N).
#
# No lleva `set -e` ni nada más: el script que lo carga ya fija sus opciones.
# El comportamiento es idéntico al bloque que antes vivía inline en
# setup-remote-target.sh.

setup_ssh() {
  hdr "SSH"

  # ¿sshd presente? (comando o paquete, según familia)
  if command -v sshd >/dev/null 2>&1 || [[ -x /usr/sbin/sshd ]]; then
    ok "openssh ya instalado"
  elif pkg_installed openssh-server || pkg_installed openssh; then
    ok "openssh ya instalado (paquete)"
  else
    info "Instalando openssh server..."
    case "$DISTRO_FAMILY" in
      arch)   pkg_install openssh ;;
      debian) pkg_install openssh-server ;;
      fedora) pkg_install openssh-server ;;
      *)      pkg_install openssh-server || return 1 ;;
    esac
  fi

  # Fedora/Debian modernos usan 'sshd' como alias; probamos y caemos a ssh.service
  run systemctl enable --now sshd 2>/dev/null \
    || run systemctl enable --now ssh 2>/dev/null \
    || true
  ok "sshd habilitado y arrancado"

  # sshd a veces tarda en bindear; esperamos y comprobamos
  for _ in 1 2 3 4 5; do
    ss -tln 2>/dev/null | grep -q ":${SSH_PORT}\b" && break
    sleep 1
  done
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) sshd escucharía en :${SSH_PORT}"
  elif ss -tln 2>/dev/null | grep -q ":${SSH_PORT}\b"; then
    ok "sshd escuchando en :${SSH_PORT}"
  else
    err "sshd no escucha en :${SSH_PORT}"
    systemctl status sshd --no-pager 2>/dev/null | tail -5 || true
    return 1
  fi

  hdr "Firewall"
  local fw; fw="$(detect_firewall)"
  info "Detectado: $fw"
  case "$fw" in
    ufw)
      # 'limit' en vez de 'allow': ufw aplica rate-limit (6 conexiones/30 s
      # por IP). Frena la fuerza bruta de bots y no afecta el uso legítimo
      # (ni siquiera reconexiones normales de SSH).
      run ufw limit "${SSH_PORT}/tcp" >/dev/null 2>&1 \
        || run ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1 || true
      run ufw reload >/dev/null 2>&1 || true
      if [[ $DRY_RUN -eq 1 ]]; then
        info "(dry-run) ufw limitaría ${SSH_PORT}/tcp (rate-limit anti fuerza bruta)"
      else
        ufw_verify "ufw: ${SSH_PORT}/tcp limitado (rate-limit)"
      fi
      ;;
    firewalld)
      run firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || true
      run firewall-cmd --reload >/dev/null 2>&1 || true
      if [[ $DRY_RUN -eq 1 ]]; then
        info "(dry-run) firewalld permitiría el servicio ssh"
      elif firewall-cmd --list-services 2>/dev/null | grep -qw ssh; then
        ok "firewalld: servicio ssh permitido"
      else
        warn "firewalld: no pude confirmar la regla. Comprueba: sudo firewall-cmd --list-services"
      fi
      ;;
    nftables)
      warn "nftables activo: añade manualmente una regla para tcp/${SSH_PORT}"
      warn "  sudo nft add rule inet filter input tcp dport ${SSH_PORT} accept"
      warn "  (y persístela en /etc/nftables.conf)"
      ;;
    iptables)
      warn "iptables activo: añade manualmente una regla para tcp/${SSH_PORT}"
      warn "  sudo iptables -A INPUT -p tcp --dport ${SSH_PORT} -j ACCEPT"
      ;;
    ufw-inactive)
      # Caso típico de Linux Mint: ufw instalado pero apagado.
      warn "ufw está instalado pero INACTIVO (habitual en Linux Mint)"
      info "Activando ufw y permitiendo ${SSH_PORT}/tcp..."
      run ufw --force enable >/dev/null 2>&1 || true
      run ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1 || true
      if [[ $DRY_RUN -eq 1 ]]; then
        info "(dry-run) ufw se activaría y permitiría ${SSH_PORT}/tcp"
      else
        ufw_verify "ufw activado con ${SSH_PORT}/tcp permitido"
      fi
      ;;
    firewalld-inactive)
      warn "firewalld está instalado pero INACTIVO"
      info "Activando firewalld y permitiendo ssh..."
      run systemctl enable --now firewalld >/dev/null 2>&1 || true
      run firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || true
      # rich rule con rate-limit, además del servicio ssh (cinturón y tirantes)
      run firewall-cmd --permanent --add-rich-rule='rule service name="ssh" limit value="6/m" accept' >/dev/null 2>&1 || true
      run firewall-cmd --reload >/dev/null 2>&1 || true
      if [[ $DRY_RUN -eq 1 ]]; then
        info "(dry-run) firewalld se activaría y permitiría ssh (con rate-limit)"
      else
        ok "firewalld activado con servicio ssh permitido"
      fi
      ;;
    sin-herramientas)
      warn "Firewall NO verificable (sin systemctl/firewall-cmd/ufw): no se toca nada"
      warn "  Si es un escritorio real, revisa a mano el filtrado antes de exponer ssh"
      ;;
    none)
      ok "Sin firewall: no hace falta abrir nada"
      ;;
  esac

  if [[ -n "$KEY" ]]; then
    hdr "Autorizando clave del operador"
    local sshdir="$TARGET_HOME/.ssh" ak="$TARGET_HOME/.ssh/authorized_keys"
    if [[ $DRY_RUN -eq 1 ]]; then
      printf '%s[auth]%s añadiría la clave a %s\n' "$B" "$N" "$ak"
      ok "(dry-run) clave del operador se autorizaría"
    else
      mkdir -p "$sshdir"
      touch "$ak"
      if grep -qF -- "$KEY" "$ak" 2>/dev/null; then
        ok "La clave ya estaba autorizada (no se duplica)"
      elif grep -qF "$(awk '{print $2}' <<<"$KEY")" "$ak" 2>/dev/null; then
        ok "Ya existe una clave con esa misma parte pública (se omite)"
      else
        printf '%s\n' "$KEY" >> "$ak"
        ok "Clave añadida a $ak"
      fi
      # propietario y permisos correctos (clave: si corremos como root,
      # authorized_keys DEBE pertenecer al usuario objetivo o SSH lo ignora)
      chmod 700 "$sshdir"
      chmod 600 "$ak"
      if [[ "$TARGET_USER" != "root" ]]; then
        chown -R "$TARGET_USER":"$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$sshdir"
      fi
      ok "Permisos aplicados (700 .ssh, 600 authorized_keys, owner $TARGET_USER)"
    fi
  else
    warn "No se pasó --key: el operador NO podrá entrar sin contraseña"
    warn "  Vuelve a ejecutar con: sudo $0 --ssh --key \"(tu clave pública)\""
  fi

  hdr "Listo"
  local ip; ip="$(local_ip)"
  ok "IP local: $ip"
  info "Prueba desde el operador:"
  info "  ssh -o BatchMode=yes ${TARGET_USER}@${ip} 'hostname'"
}
