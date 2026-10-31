#!/usr/bin/env bash
#
# verify-docs-consistency.sh — Comprueba que la documentación sea COHERENTE
# ENTRE SÍ (no solo que los comandos/URLs existan, eso lo hace verify-docs.sh).
#
# Revisa 3 cosas:
#   1. Conteo de tests citado en los docs.
#   2. Versión citada en README.md vs. la última del CHANGELOG.md.
#   3. Enlaces markdown internos rotos entre .md del repo.
#
# No modifica nada: solo verifica. Sin dependencias raras (bash + grep/sed/find).
#
# Uso:
#   ./verify-docs-consistency.sh
#
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

PASS=0; FAIL=0; SKIP=0
if [[ -t 1 ]]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; N=$'\e[0m'; BD=$'\e[1m'; else G='';R='';Y='';N='';BD=''; fi
ok(){ printf '%s✔%s %s\n' "$G" "$N" "$*"; PASS=$((PASS+1)); }
ko(){ printf '%s✘%s %s\n' "$R" "$N" "$*"; FAIL=$((FAIL+1)); }
sk(){ printf '%s▲%s %s\n' "$Y" "$N" "$*"; SKIP=$((SKIP+1)); }
sect(){ printf '\n%s== %s ==%s\n' "$BD" "$1" "$N"; }

# ---------------------------------------------------------------------------
# Chequeo 1 — Conteo de tests coherente
# ---------------------------------------------------------------------------
# Interpretación (simple y documentada):
#   - Cada doc puede citar el total de tests una o más veces. Contamos las
#     citas en los "docs que citan número": README.md y AGENTS.md.
#   - Patrones aceptados:
#       * "N tests"        (ej. "~474 tests", "667 tests")
#       * "**N**" en la fila de la tabla que menciona tests.sh
#       * "N OK"           (ej. "# 667 OK / 0 fallos")
#   - REGLA: los números ENCONTRADOS deben coincidir entre docs. Si no,
#     WARN (no aborta el build): suele ser doc desactualizada, no código roto.
#   - Si un doc no cita número, WARN informativo (no fallo).
# ---------------------------------------------------------------------------
sect "Chequeo 1: conteo de tests en la documentación"

# Extrae de un archivo el número de tests citado (puede haber varios).
# Devuelve una línea por número encontrado (únicos, ordenados).
tests_citados(){
  local f="$1"
  [[ -f "$f" ]] || return 0
  {
    # "N tests" / "~N tests"
    grep -oE '~?[0-9]{2,4}[[:space:]]+tests?' "$f" 2>/dev/null | grep -oE '[0-9]{2,4}'
    # "**N**" en una línea que habla de tests.sh
    grep -n 'tests\.sh' "$f" 2>/dev/null | grep -oE '\*\*[0-9]{2,4}\*\*' | grep -oE '[0-9]{2,4}'
    # "N OK" citado como conteo de pruebas
    grep -oE '[0-9]{2,4}[[:space:]]+OK' "$f" 2>/dev/null | grep -oE '[0-9]{2,4}'
  } | sort -u
}

n_readme="$(tests_citados README.md | tr '\n' ' ')"
n_agents="$(tests_citados AGENTS.md | tr '\n' ' ')"

read -r -a list_readme <<<"$n_readme"
read -r -a list_agents <<<"$n_agents"

if [[ ${#list_readme[@]} -gt 0 ]]; then
  ok "README.md cita tests: ${list_readme[*]}"
else
  sk "README.md no cita un número de tests (informativo)"
fi

if [[ ${#list_agents[@]} -gt 0 ]]; then
  ok "AGENTS.md cita tests: ${list_agents[*]}"
else
  sk "AGENTS.md no cita un número de tests (informativo)"
fi

# Coherencia entre docs (solo si ambos citan al menos un número).
if [[ ${#list_readme[@]} -gt 0 && ${#list_agents[@]} -gt 0 ]]; then
  # ¿Comparten al menos un número?
  coincide=0
  for a in "${list_readme[@]}"; do
    for b in "${list_agents[@]}"; do
      [[ "$a" == "$b" ]] && coincide=1
    done
  done
  if [[ $coincide -eq 1 ]]; then
    ok "README.md y AGENTS.md coinciden en el conteo de tests"
  else
    sk "conteo de tests DESINCRONIZADO: README.md=${list_readme[*]}, AGENTS.md=${list_agents[*]}"
  fi
else
  sk "no se puede comparar el conteo: falta número en algún doc"
fi

# ---------------------------------------------------------------------------
# Chequeo 2 — Versión coherente (README vs. CHANGELOG)
# ---------------------------------------------------------------------------
# Interpretación (simple y documentada):
#   - La "última versión" es la primera cabecera "## [x.y.z]" del CHANGELOG.
#   - Del README tomamos la MENOR versión semver citada (ver nota más abajo).
#   - Si coinciden -> ok. Si no -> FALLO.
#   - Si README no cita versión -> WARN (no fallo).
# ---------------------------------------------------------------------------
sect "Chequeo 2: versión coherente (README vs. CHANGELOG)"

CHANGELOG_LAST=""
if [[ -f CHANGELOG.md ]]; then
  CHANGELOG_LAST="$(grep -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
fi

if [[ -n "$CHANGELOG_LAST" ]]; then
  ok "última versión en CHANGELOG.md: $CHANGELOG_LAST"
else
  sk "no se encontró una cabecera '## [x.y.z]' en CHANGELOG.md"
fi

README_VER=""
if [[ -f README.md ]]; then
  # Citas explícitas de versión: "**v1.2.3**" o "versión 1.2.3".
  # NOTA: NO tomamos cualquier "1.2.3" suelto del README (aparecen versiones
  # de herramientas citadas, p.ej. "RustDesk 1.4.5", que no son la del kit).
  README_VER="$(grep -oE '\*\*v[0-9]+\.[0-9]+\.[0-9]+\*\*|versi[oó]n[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+' README.md \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
fi

if [[ -z "$README_VER" ]]; then
  sk "README.md no cita una versión explícita del kit (informativo)"
elif [[ -z "$CHANGELOG_LAST" ]]; then
  sk "README cita $README_VER pero no hay versión en CHANGELOG para comparar"
elif [[ "$README_VER" == "$CHANGELOG_LAST" ]]; then
  ok "versión coherente: README=$README_VER == CHANGELOG=$CHANGELOG_LAST"
else
  ko "versión DESINCRONIZADA: README=$README_VER ≠ CHANGELOG=$CHANGELOG_LAST"
fi

# ---------------------------------------------------------------------------
# Chequeo 3 — Enlaces internos entre docs
# ---------------------------------------------------------------------------
# Recorre los .md de la raíz y docs/*.md. Para cada enlace markdown del tipo
# [texto](destino) que apunte a un archivo local (sin esquema http/https/mailto
# y sin ancla pura "#..."), comprueba que el archivo exista (relativo al .md).
# ---------------------------------------------------------------------------
sect "Chequeo 3: enlaces internos entre documentos"

revisados=0
rotos=0
while IFS= read -r md; do
  [[ -f "$md" ]] || continue
  dir="$(dirname "$md")"
  # Extrae destinos de enlaces markdown locales.
  while IFS= read -r dest; do
    [[ -z "$dest" ]] && continue
    # Quita ancla (#...) y query string.
    path="${dest%%#*}"
    path="${path%%\?*}"
    [[ -z "$path" ]] && continue
    # Salta URLs absolutas y protocolos.
    case "$path" in
      http://*|https://*|mailto:*|tel:*|ftp://*|//*) continue ;;
    esac
    revisados=$((revisados+1))
    if [[ ! -e "$dir/$path" ]]; then
      ko "enlace roto en $md → $dest"
      rotos=$((rotos+1))
    fi
  done < <(grep -oE '\]\([^)]+\)' "$md" 2>/dev/null | sed -E 's/^\]\(//; s/\)$//' | sed -E 's/[[:space:]]+"[^"]*"$//')
done < <( { ls -1 ./*.md 2>/dev/null; ls -1 docs/*.md 2>/dev/null; } | sort -u )

if [[ $rotos -eq 0 ]]; then
  ok "enlaces internos válidos ($revisados enlaces revisados)"
else
  sk "se revisaron $revisados enlaces; $rotos roto(s) (ver arriba)"
fi

sect "Resumen"
printf '  %s%d OK%s · %s%d fallos%s · %s%d avisos%s\n' \
  "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$Y" "$SKIP" "$N"
if [[ $FAIL -gt 0 ]]; then
  echo
  echo "Corrige los fallos de coherencia antes de publicar la documentación."
  exit 1
fi
exit 0
