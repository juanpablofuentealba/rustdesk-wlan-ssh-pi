#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# reboot-remoto.sh — habilita y dispara un reinicio remoto UNATTENDED
#
# Problema que resuelve (H-27): en un equipo recién instalado, `sudo` pide
# contraseña y `systemctl reboot`/logind exigen autenticación interactiva
# (polkit). Desde SSH no se puede reiniciar sin un secreto. Este script deja
# una regla NOPASSWD ACOTADA (solo reboot/poweroff, no todo sudo) y luego
# reinicia y verifica que el equipo vuelva solo.
#
# Uso:
#   ./reboot-remoto.sh --host jp@100.x.y.z --enable     # crea la regla (pide sudo 1 vez)
#   ./reboot-remoto.sh --host jp@100.x.y.z --reboot     # reinicia (ya sin contraseña)
#   ./reboot-remoto.sh --host jp@100.x.y.z --verify     # comprueba la vuelta
#   ./reboot-remoto.sh --host jp@100.x.y.z --disable    # borra la regla (rollback)
#   ./reboot-remoto.sh --host jp@100.x.y.z --all        # enable + reboot + verify
#
#   --user NOMBRE     usuario de la regla en el objetivo (por defecto: el de --host)
#   --timeout N       segundos a esperar la vuelta (por defecto: 180)
#   --dry-run         muestra lo que haría, sin ejecutar nada
#
# Requiere: acceso SSH por CLAVE (BatchMode) al objetivo.
# ---------------------------------------------------------------------------
set -uo pipefail

HOST=""
USER_RULE=""
ACTION=""
TIMEOUT=180
DRY=0

SUDOERS_FILE="/etc/sudoers.d/99-reboot"
SUDO_RULE_TMPL='%s ALL=(ALL) NOPASSWD: /usr/bin/systemctl reboot, /usr/bin/systemctl poweroff'

ok()   { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m✘\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m▲\033[0m %s\n' "$*"; }
say()  { printf '\033[1;34m●\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

usage(){ sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)    HOST="${2:-}"; shift 2 ;;
    --user)    USER_RULE="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-180}"; shift 2 ;;
    --enable|--reboot|--verify|--disable|--all) ACTION="$1"; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage ;;
    *) echo "opción desconocida: $1" >&2; usage ;;
  esac
done

[[ -n "$HOST" ]]   || { echo "error: falta --host USUARIO@IP" >&2; usage; }
[[ -n "$ACTION" ]] || { echo "error: falta una acción (--enable/--reboot/--verify/--disable/--all)" >&2; usage; }
[[ -n "$USER_RULE" ]] || USER_RULE="${HOST%@*}"

# Envía un script por stdin con bash -s (H-23: nunca bash suelto a un objetivo
# que puede tener fish). Sin -t: los comandos NO deben pedir interacción aquí.
rsh(){ ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$HOST" bash -s; }

# Igual que rsh, pero con TTY (para el sudo que SÍ pide contraseña una vez).
rsh_tty(){ ssh -t "$HOST" bash -s; }

do_enable(){
  hdr "Habilitar NOPASSWD acotado (solo reboot/poweroff)"
  say "regla : $(printf "$SUDO_RULE_TMPL" "$USER_RULE")"
  say "archivo: $SUDOERS_FILE"
  if [[ $DRY -eq 1 ]]; then warn "(dry-run) no se aplica"; return 0; fi
  # Se escribe con cat> (sin redirección en la línea de SSH), se fija chmod 440
  # y se VALIDA con visudo -cf antes de que sudo la use (un sudoers roto deja el
  # equipo sin sudo). Todo dentro del heredoc, sin líneas partidas por el shell.
  rsh_tty <<EOF
set -e
printf '%s\n' '$(printf "$SUDO_RULE_TMPL" "$USER_RULE")' | sudo tee "$SUDOERS_FILE" >/dev/null
sudo chmod 440 "$SUDOERS_FILE"
sudo chown root:root "$SUDOERS_FILE"
echo "--- validacion ---"
sudo visudo -cf "$SUDOERS_FILE"
echo "--- regla activa ---"
sudo -n -l 2>/dev/null | grep -i NOPASSWD || true
EOF
  local rc=$?
  if [[ $rc -eq 0 ]]; then ok "regla aplicada y validada"; else bad "no se pudo aplicar (rc=$rc)"; return 1; fi
}

do_reboot(){
  hdr "Disparar reinicio remoto"
  local before; before="$(rsh <<'EOF'
cat /proc/sys/kernel/random/boot_id
EOF
)"
  say "boot_id antes: ${before:-?}"
  if [[ $DRY -eq 1 ]]; then warn "(dry-run) no se reinicia"; return 0; fi
  say "reiniciando… (el corte de SSH es esperado)"
  rsh <<'EOF' || true
sudo -n /usr/bin/systemctl reboot
EOF
  echo "$before" > "/tmp/.reboot-remoto-bootid-$$"
  ok "reboot enviado (boot_id guardado para --verify)"
}

do_verify(){
  hdr "Esperar la vuelta (máx ${TIMEOUT}s)"
  local before="" i new=""
  before="$(cat /tmp/.reboot-remoto-bootid-* 2>/dev/null | tail -1 || true)"
  for ((i=0; i<TIMEOUT; i+=5)); do
    sleep 5
    new="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)"
    if [[ -n "$new" ]]; then
      if [[ -z "$before" ]]; then
        ok "el equipo está online (boot_id actual: $new)"
        warn "no hay boot_id previo guardado: no puedo confirmar que reinició"
      elif [[ "$new" != "$before" ]]; then
        ok "volvió online con boot_id NUEVO en ~${i}s: $new"
      else
        warn "responde, pero el boot_id es el mismo (¿no reinició?)"
      fi
      rsh <<'EOF'
echo "--- servicios (deben estar active, enabled) ---"
for s in rustdesk sshd tailscaled ufw; do
  printf '%-10s %-8s %s\n' "$s" "$(systemctl is-active "$s" 2>&1)" "$(systemctl is-enabled "$s" 2>&1)"
done
uptime -p
EOF
      return 0
    fi
  done
  bad "no volvió en ${TIMEOUT}s"
  return 1
}

do_disable(){
  hdr "Rollback: borrar la regla"
  if [[ $DRY -eq 1 ]]; then warn "(dry-run) no se borra"; return 0; fi
  rsh_tty <<EOF
sudo rm -f "$SUDOERS_FILE" && echo "borrado: $SUDOERS_FILE"
EOF
}

case "$ACTION" in
  --enable)  do_enable ;;
  --reboot)  do_reboot ;;
  --verify)  do_verify ;;
  --disable) do_disable ;;
  --all)     do_enable && do_reboot && sleep 3 && do_verify ;;
esac
