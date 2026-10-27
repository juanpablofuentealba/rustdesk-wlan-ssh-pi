#!/usr/bin/env bash
# Script interno (root): escribe password+salt en las configs de RustDesk.
# Uso: bash rd-setpass-root.sh <salt> <storage>
set -euo pipefail
salt="$1"; storage="$2"

apply() {
  local dir="$1"
  local f="$dir/RustDesk.toml"
  if [[ ! -f "$f" ]]; then
    echo "  (omitido: no existe $f)"
    return 0
  fi
  cp -a "$f" "$f.bak-$(date +%s)"
  python3 - "$f" "$salt" "$storage" <<'PYEOF'
import re, sys
path, salt, storage = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
def setkey(text, key, value):
    pat = re.compile(rf"^{key}\s*=.*$", re.M)
    line = f"{key} = '{value}'"
    return pat.sub(line, text) if pat.search(text) else text.rstrip() + "\n" + line + "\n"
text = setkey(text, "password", storage)
text = setkey(text, "salt", salt)
open(path, "w").write(text)
PYEOF
  echo "  ✔ actualizado $f (backup .bak-*)"
}

apply /root/.config/rustdesk
# El usuario objetivo (si existe su config)
for h in /home/*; do
  [ -f "$h/.config/rustdesk/RustDesk.toml" ] || continue
  apply "$h/.config/rustdesk"
  chown "$(stat -c %U:%G "$h")" "$h/.config/rustdesk/RustDesk.toml"
done
