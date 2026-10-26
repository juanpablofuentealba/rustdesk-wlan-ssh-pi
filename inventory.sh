#!/usr/bin/env bash
#
# inventory.sh — Inventario de specs de una máquina Linux, local o remota.
#
# Uso:
#   ./inventory.sh                      # máquina local
#   ./inventory.sh USUARIO@192.168.1.20      # máquina remota por SSH
#   ./inventory.sh remoto                # alias de ~/.ssh/config
#   ./inventory.sh --json remoto         # salida JSON
#   ./inventory.sh --markdown remoto     # salida Markdown
#
set -uo pipefail

MODE="text"
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)          MODE="json"; shift ;;
    --markdown|--md) MODE="markdown"; shift ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) TARGET="$1"; shift ;;
  esac
done

# ---------- script que corre en la máquina objetivo ----------
# Se pasa por stdin; NO se interpola nada aquí (heredoc citado).
read -r -d '' REMOTE_SCRIPT <<'REMOTE_EOF' || true
j() { printf '%s=%s\n' "$1" "$2"; }

j HOSTNAME "$(hostname 2>/dev/null)"
j USER "$(whoami 2>/dev/null)"
j OS "$(grep -s PRETTY_NAME /etc/os-release | cut -d= -f2- | tr -d '\"')"
j KERNEL "$(uname -r)"
j ARCH "$(uname -m)"
j UPTIME "$(uptime -p 2>/dev/null | sed 's/^up //')"
j CHASSIS "$(cat /sys/class/dmi/id/chassis_type 2>/dev/null)"
j VENDOR "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)"
j MODEL "$(cat /sys/class/dmi/id/product_name 2>/dev/null)"
j BOARD "$(cat /sys/class/dmi/id/board_name 2>/dev/null)"
j BIOS "$(cat /sys/class/dmi/id/bios_version 2>/dev/null) $(cat /sys/class/dmi/id/bios_date 2>/dev/null)"

j CPU_MODEL "$(lscpu 2>/dev/null | awk -F: '/Model name/{sub(/^ +/,"",$2);print $2; exit}')"
j CPU_CORES "$(lscpu 2>/dev/null | awk -F: '/^CPU\(s\)/{gsub(/ /,"",$2);print $2; exit}')"
j CPU_MAXMHZ "$(lscpu 2>/dev/null | awk -F: '/CPU max MHz/{gsub(/ /,"",$2);print $2; exit}')"

j RAM_TOTAL "$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')"
j RAM_USED "$(free -h 2>/dev/null | awk '/^Mem:/{print $3}')"
j SWAP "$(free -h 2>/dev/null | awk '/^Swap:/{print $2}')"

j GPU "$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | cut -d: -f3- | sed 's/^ //' | paste -sd'|' - | sed 's/|/ | /g')"
j NET "$(lspci 2>/dev/null | grep -iE 'ethernet|network' | cut -d: -f3- | sed 's/^ //' | paste -sd'|' - | sed 's/|/ | /g')"
j DISKS "$(lsblk -dno NAME,SIZE,MODEL 2>/dev/null | grep -vE 'zram|loop' | awk '{printf "%s %s %s | ", $1,$2,substr($0, index($0,$3))}' | sed 's/ | $//')"
j DISK_ROOT "$(df -h / 2>/dev/null | awk 'NR==2{printf "%s usados de %s (%s)", $3,$2,$5}')"

j TEMP_CPU "$(sensors 2>/dev/null | awk '/Tctl|Package id|^temp1/{sub(/^ +/,"");print;exit}' | sed 's/.*: *//')"
j BATTERY "$(upower -i "$(upower -e 2>/dev/null | grep -i BAT | head -1)" 2>/dev/null | awk -F: '/percentage|capacity/{sub(/^ +/,"",$2);printf "%s ",$2}')"
j NET_IP "$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
j IFACE "$(ip -br addr show 2>/dev/null | grep -v '^lo' | awk '{printf "%s:%s ", $1,$3}' | head -c 200)"
REMOTE_EOF

# ---------- ejecutar ----------
if [[ -z "$TARGET" || "$TARGET" == "local" || "$TARGET" == "." ]]; then
  RAW="$(printf '%s\n' "$REMOTE_SCRIPT" | bash -s 2>/dev/null)"
  WHERE="local ($(hostname))"
else
  RAW="$(printf '%s\n' "$REMOTE_SCRIPT" | ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" 'bash -s' 2>/dev/null)"
  WHERE="$TARGET"
fi

if [[ -z "$RAW" ]]; then
  echo "Error: no se pudo obtener información de '$WHERE'" >&2
  if [[ -n "$TARGET" && "$TARGET" != "local" && "$TARGET" != "." ]]; then
    echo "  Pista: comprueba 'ssh -o BatchMode=yes $TARGET hostname'" >&2
    echo "         y que exista ~/.ssh/id_ed25519 autorizada en el objetivo." >&2
  fi
  exit 1
fi

declare -A D=()
while IFS='=' read -r k v; do
  [[ -n "$k" ]] && D["$k"]="$v"
done <<<"$RAW"

case "${D[CHASSIS]:-}" in
  8|9|10|14) CTYPE="laptop" ;;
  3|4|5|6|7) CTYPE="desktop" ;;
  *)         CTYPE="desconocido" ;;
esac
D[CHASSIS_TYPE]="$CTYPE"

# ---------- salida ----------
case "$MODE" in
  json)
    printf '{\n'
    printf '  "target": "%s",\n' "$WHERE"
    keys=(HOSTNAME USER OS KERNEL ARCH UPTIME CHASSIS_TYPE VENDOR MODEL BOARD BIOS \
          CPU_MODEL CPU_CORES CPU_MAXMHZ RAM_TOTAL RAM_USED SWAP \
          GPU NET DISKS DISK_ROOT TEMP_CPU BATTERY NET_IP IFACE)
    last=$(( ${#keys[@]} - 1 ))
    for i in "${!keys[@]}"; do
      k="${keys[$i]}"
      v="${D[$k]:-}"
      v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
      comma=","
      [[ $i -eq $last ]] && comma=""
      printf '  "%s": "%s"%s\n' "$k" "$v" "$comma"
    done
    printf '}\n'
    ;;

  markdown)
    cat <<EOF
## Inventario: \`$WHERE\`

| Campo | Valor |
|---|---|
| Hostname | ${D[HOSTNAME]:-?} |
| Usuario | ${D[USER]:-?} |
| Tipo | ${D[CHASSIS_TYPE]:-?} |
| Marca/Modelo | ${D[VENDOR]:-?} ${D[MODEL]:-?} |
| Placa / BIOS | ${D[BOARD]:-?} / ${D[BIOS]:-?} |
| SO | ${D[OS]:-?} |
| Kernel | ${D[KERNEL]:-?} (${D[ARCH]:-?}) |
| CPU | ${D[CPU_MODEL]:-?} |
| Núcleos | ${D[CPU_CORES]:-?} @ ${D[CPU_MAXMHZ]:-?} MHz |
| RAM | ${D[RAM_TOTAL]:-?} (${D[RAM_USED]:-?} en uso) |
| Swap | ${D[SWAP]:-?} |
| GPU | ${D[GPU]:-?} |
| Red | ${D[NET]:-?} |
| Discos | ${D[DISKS]:-?} |
| Disco / | ${D[DISK_ROOT]:-?} |
| Temperatura | ${D[TEMP_CPU]:-?} |
| Batería | ${D[BATTERY]:-?} |
| IP | ${D[NET_IP]:-?} |
| Uptime | ${D[UPTIME]:-?} |
EOF
    ;;

  *)
    if [[ -t 1 ]]; then BD=$'\e[1m'; CY=$'\e[36m'; N=$'\e[0m'; else BD=''; CY=''; N=''; fi
    printf '%s%s== Inventario: %s ==%s\n' "$BD" "$CY" "$WHERE" "$N"
    sec() { printf '\n%s-- %s --%s\n' "$BD" "$1" "$N"; }

    sec "Sistema"
    printf '  Hostname    : %s\n' "${D[HOSTNAME]:-?}"
    printf '  Usuario     : %s\n' "${D[USER]:-?}"
    printf '  Tipo        : %s\n' "${D[CHASSIS_TYPE]:-?}"
    printf '  Marca/Modelo: %s %s\n' "${D[VENDOR]:-?}" "${D[MODEL]:-?}"
    printf '  Placa/BIOS  : %s / %s\n' "${D[BOARD]:-?}" "${D[BIOS]:-?}"
    printf '  SO          : %s\n' "${D[OS]:-?}"
    printf '  Kernel      : %s (%s)\n' "${D[KERNEL]:-?}" "${D[ARCH]:-?}"
    printf '  Uptime      : %s\n' "${D[UPTIME]:-?}"

    sec "CPU"
    printf '  %s\n' "${D[CPU_MODEL]:-?}"
    printf '  Núcleos     : %s @ %s MHz\n' "${D[CPU_CORES]:-?}" "${D[CPU_MAXMHZ]:-?}"

    sec "Memoria"
    printf '  RAM         : %s (%s en uso)\n' "${D[RAM_TOTAL]:-?}" "${D[RAM_USED]:-?}"
    printf '  Swap        : %s\n' "${D[SWAP]:-?}"

    sec "Almacenamiento"
    printf '  Discos      : %s\n' "${D[DISKS]:-?}"
    printf '  Raíz /      : %s\n' "${D[DISK_ROOT]:-?}"

    sec "Gráficos y red"
    printf '  GPU         : %s\n' "${D[GPU]:-?}"
    printf '  Red         : %s\n' "${D[NET]:-?}"
    printf '  IP          : %s\n' "${D[NET_IP]:-?}"

    sec "Sensores"
    printf '  Temperatura : %s\n' "${D[TEMP_CPU]:-?}"
    printf '  Batería     : %s\n' "${D[BATTERY]:-?}"
    printf '\n'
    ;;
esac
