#!/usr/bin/env bash
#
# lib/sr-t-ui.sh — Módulo de UI/estado (colores + ok/warn/err/info/hdr).
#
# Parte del issue #27 (partir el monolito setup-remote-target.sh en módulos).
# Este archivo NO se ejecuta solo: está pensado para `source`:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/sr-t-ui.sh"
#
# No lleva `set -e` ni nada más: el script que lo carga ya fija sus opciones.
# El comportamiento (mensajes y códigos de color) es idéntico al bloque que
# antes vivía inline en setup-remote-target.sh.

# ---------- colores ----------
if [[ -t 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[36m'; N=$'\e[0m'; BD=$'\e[1m'
else
  R=''; G=''; Y=''; B=''; N=''; BD=''
fi

ok()   { printf '%s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s▲%s %s\n' "$Y" "$N" "$*"; }
err()  { printf '%s✘%s %s\n' "$R" "$N" "$*" >&2; }
info() { printf '%s●%s %s\n' "$B" "$N" "$*"; }
hdr()  { printf '\n%s%s== %s ==%s\n' "$BD" "$B" "$*" "$N"; }
