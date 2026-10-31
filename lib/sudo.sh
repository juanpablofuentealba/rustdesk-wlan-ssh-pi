#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# lib/sudo.sh — helper ÚNICO de sudo para todo el kit (issue #28 / H-68)
#
# Por qué existe:
#   Antes cada script resolvía la contraseña de sudo a su manera:
#     · instalar-todo.sh      -> `printf '%s\n' "$SUDOPASS" | sudo -S -v`
#     · rustdesk-password.sh  -> helper propio `sudow` (SUDO_ASKPASS)
#     · energia-remota.sh     -> archivo -> `sudo -S` por stdin de SSH
#     · reboot-remoto.sh      -> `sudo -n`
#     · .rd-setpass-root.sh   -> --stdin / --stdin-with-pass
#   Esa dispersión causó H-68: `sudo -S` lee la clave de stdin con buffering y
#   se comió el `salt`/`storage` que iban por el MISMO stdin, así que la
#   contraseña permanente de RustDesk NUNCA se aplicaba (en silencio).
#
#   Este helper concentra el manejo en UN sitio y usa SIEMPRE `sudo -A`
#   (SUDO_ASKPASS) cuando hay clave, dejando stdin libre para datos. Así H-68
#   no puede volver: no hay ningún camino en el kit que meta la clave de sudo
#   por el mismo stdin que los datos.
#
# Uso (sourcearlo, NO ejecutarlo):
#   source "$SCRIPT_DIR/lib/sudo.sh"
#   SUDO_PASS='clave' sudo_run systemctl restart rustdesk
#   printf '%s\n%s\n' "$salt" "$storage" | sudo_run bash helper.sh --stdin
#
# Fuentes de la clave, en orden de prioridad:
#   1. $SUDO_PASS            (si está declarada, incluso vacía = NOPASSWD)
#   2. $SUDO_PASS_FILE       (archivo con la clave en la primera línea, 600)
#   3. ~/.config/operador-secrets/sudo   (ubicación por defecto, ver
#      energia-remota.sh; solo si el archivo existe y es legible)
#   4. Nada -> `sudo -n` (solo funciona con NOPASSWD)
# ---------------------------------------------------------------------------

# Evitar doble source (los scripts pueden sourcearlo y además llamar a otros
# que lo hagan). Guarda de idempotencia.
if [[ -n "${_KIT_SUDO_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
_KIT_SUDO_SH_LOADED=1

# NOTA de diseño: NO definimos un SUDO_PASS_FILE por defecto aquí. Si lo
# hiciéramos, cualquier script que sourcee este helper leería sin querer la
# clave de ~/.config/operador-secrets/sudo, cambiando su comportamiento. La
# lectura por archivo es OPT-IN: el llamador setea SUDO_PASS_FILE (ver
# energia-remota.sh, que ya tenía su propio ENERGIA_SUDO_FILE).

# --- sudo_load_pass --------------------------------------------------------
# Rellena SUDO_PASS desde $SUDO_PASS_FILE (opt-in) si no viene ya por entorno.
# NO imprime la clave; solo la exporta.
# Devuelve 0 si hay clave disponible (por entorno o archivo), 1 si no.
sudo_load_pass() {
  # Si SUDO_PASS está declarada (aunque sea vacía), respetamos su valor:
  # vacía = "sudo sin contraseña" (NOPASSWD), semántica ya usada en el kit.
  if [[ -n "${SUDO_PASS+x}" ]]; then
    return 0
  fi
  local f="${SUDO_PASS_FILE:-}"
  if [[ -n "$f" && -r "$f" ]]; then
    SUDO_PASS="$(head -n1 "$f" 2>/dev/null || true)"
    export SUDO_PASS
    return 0
  fi
  return 1
}

# --- sudo_have_pass --------------------------------------------------------
# true (0) si hay una clave NO vacía para pasar por askpass. Distingue tres
# estados: SUDO_PASS con clave -> 0; SUDO_PASS vacía o inexistente -> 1.
sudo_have_pass() {
  sudo_load_pass || true
  [[ -n "${SUDO_PASS:-}" ]]
}

# --- _sudo_askpass ---------------------------------------------------------
# Crea un script askpass temporal y lo deja en $_SUDO_ASKPASS_TMP.
# La clave se escribe con %q vía printf (comilla segura) y el archivo es 700:
# no queda en argv ni en `ps`, y se borra tras usarlo.
_sudo_askpass() {
  _SUDO_ASKPASS_TMP="$(mktemp)"
  chmod 700 "$_SUDO_ASKPASS_TMP"
  # %q escapa la clave para el /bin/sh del askpass. shellcheck no sigue el
  # formato dentro de printf -v; lo construimos por format string explícito.
  local q
  q="$(printf '%s' "${SUDO_PASS:-}" | sed "s/'/'\\\\''/g")"
  printf '#!/bin/sh\nprintf "%%s\\n" '\''%s'\''\n' "$q" > "$_SUDO_ASKPASS_TMP"
}

# --- sudo_run --------------------------------------------------------------
# Ejecuta un comando con privilegios.
#   · con clave disponible  -> `sudo -A` (SUDO_ASKPASS); STDIN LIBRE.
#   · sin clave             -> `sudo -n` (NOPASSWD).
# Uso: sudo_run <comando> [args...]
#      printf 'datos\n' | sudo_run bash helper.sh --stdin
sudo_run() {
  if sudo_have_pass; then
    local _SUDO_ASKPASS_TMP="" _rc=0
    _sudo_askpass
    SUDO_ASKPASS="$_SUDO_ASKPASS_TMP" sudo -A "$@" || _rc=$?
    rm -f "$_SUDO_ASKPASS_TMP"
    return $_rc
  fi
  sudo -n "$@"
}

# --- sudo_v ----------------------------------------------------------------
# Refresca el timestamp de sudo SIN consumir stdin y SIN pedir TTY.
# Es el reemplazo de `printf '%s\n' "$SUDOPASS" | sudo -S -v`.
# Devuelve 0 si sudo quedó autenticado (o si ya lo estaba con -n).
sudo_v() {
  # `sudo -A -v` refresca credenciales usando askpass; stdin queda intacto.
  sudo_run -v
}

# --- sudo_need_pass --------------------------------------------------------
# Aviso útil para los scripts: ¿hará falta una clave que no tenemos?
# Devuelve 0 (true) si sudo requiere contraseña y no hay clave disponible.
sudo_need_pass() {
  if sudo_have_pass; then
    return 1
  fi
  # Sin clave: comprobamos si NOPASSWD está activo.
  sudo -n true 2>/dev/null
}

# --- sudo_cleanup ----------------------------------------------------------
# Borra el askpass temporal si quedó algún proceso interrumpido. Los scripts
# pueden registrar esto en un trap EXIT; también se limpia en cada llamada.
sudo_cleanup() {
  rm -f "${_SUDO_ASKPASS_TMP:-}" 2>/dev/null || true
}

# --- remote_sudo_run -------------------------------------------------------
# Igual que sudo_run, pero en un equipo REMOTO alcanzado por SSH (issue #28).
# Resuelve el mismo problema de H-68 al cruzar SSH: la clave NO va por el mismo
# stdin que los datos. Mecanismo:
#   1) se sube la clave (base64, por stdin) a un archivo temporal del destino;
#   2) se crea allí un askpass de 700 que imprime la clave;
#   3) se ejecuta `SUDO_ASKPASS=<askpass> sudo -A <cmd>`: el stdin del comando
#      remoto queda LIBRE para datos (salt/storage, scripts, etc.);
#   4) se borran askpass y clave del destino.
# Uso: remote_sudo_run <usuario@host> "<comando remoto>"
# Requiere una clave disponible (SUDO_PASS o SUDO_PASS_FILE).
remote_sudo_run() {
  local target="$1" cmd="$2"
  sudo_load_pass || true
  if [[ -z "${SUDO_PASS:-}" ]]; then
    # Sin clave: NOPASSWD remoto con stdin libre.
    ssh -o BatchMode=yes "$target" "sudo -n $cmd"
    return $?
  fi
  # Nombres únicos por corrida para no pisar una ejecución concurrente.
  local tag="rd-sudo.$$.$RANDOM"
  local kfile="/tmp/.${tag}.key" apfile="/tmp/.${tag}.ask"
  local rc=0
  # 1) subir la clave en base64 (por stdin; nunca en argv).
  printf '%s' "$SUDO_PASS" | base64 | \
    ssh -o BatchMode=yes "$target" "umask 077; cat > '$kfile'" || rc=$?
  if [[ $rc -eq 0 ]]; then
    # 2) askpass que decodifica la clave y la imprime.
    ssh -o BatchMode=yes "$target" \
      "umask 077; printf '#!/bin/sh\\nbase64 -d %s\\n' '$kfile' > '$apfile'; chmod 700 '$apfile'" || rc=$?
  fi
  if [[ $rc -eq 0 ]]; then
    # 3) + 4) ejecutar con sudo -A y limpiar SIEMPRE lo subido.
    ssh -o BatchMode=yes "$target" \
      "SUDO_ASKPASS='$apfile' sudo -A $cmd; rc=\$?; rm -f '$apfile' '$kfile'; exit \$rc" || rc=$?
  fi
  # Si falló antes de ejecutar, intentamos limpiar igual.
  [[ $rc -eq 0 ]] || ssh -o BatchMode=yes "$target" "rm -f '$apfile' '$kfile'" 2>/dev/null || true
  return $rc
}
