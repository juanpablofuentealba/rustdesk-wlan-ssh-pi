# AGENTS.md — Guía para agentes IA (Pi, OpenCode, Claude, Cursor)

> Pi carga este archivo automáticamente al trabajar en este repositorio.
> Si sos otro agente, leelo completo antes de tocar nada.
> Complementa a `PROMPT-AGENTE.txt` (que describe el flujo de instalación en
> un equipo objetivo). Este archivo describe cómo **trabajar en el repo**.

---

## Qué es este proyecto

Kit para **administrar Linux remoto**: RustDesk (ver/controlar, unattended en
Wayland) + **SSH** (trabajar: shell, logs, paquetes) + **Tailscale** (llegar
desde cualquier red sin abrir puertos).

El objetivo real es **dar mantención remota a clientes**, usando un agente IA
(Pi) **desde el PC del operador**, alcanzando el PC del cliente por SSH.

**`pi` NO se instala en el PC del cliente.** El agente vive solo en el equipo
del operador. El cliente recibe RustDesk + sshd + Tailscale + la clave del
operador en `authorized_keys`.

Modelo de producto y contexto completo: [`docs/estado-sesion.md`](docs/estado-sesion.md)
(sección "Modelo de producto").

---

## REGLAS DURAS (no negociables)

Heredadas de `PROMPT-AGENTE.txt` + lecciones propias del repo:

1. **Antes de improvisar, BUSCÁ en [`docs/hallazgos.md`](docs/hallazgos.md)**
   (H-01..H-35). Casi todo problema ya tiene solución documentada. Reinventarla
   suele dar una versión peor.
2. **Shell del objetivo puede ser fish.** Mandá comandos remotos por
   `bash -s` por stdin, NUNCA bash suelto pegado (H-23):
   ```bash
   ssh USUARIO@IP bash -s <<'EOF'
   ... comandos ...
   EOF
   ```
3. **NUNCA pegues comandos multilínea largos por SSH**: se parten y rompen
   (H-27). Usá `scp` de un script + ejecutarlo, o `git clone`.
4. **Firewall**: Fedora/RHEL usan `firewalld`; Debian/Ubuntu/Arch usan `ufw`.
   El kit lo detecta. NO mezcles.
5. **RustDesk en Fedora/Arch**: el paquete estándar NO trae `libdrmtap` →
   usá el `.deb` `rustdesk-unattended-wayland` (H-14, H-24, H-32).
6. **NO reinicies un equipo remoto sin avisar.** Para eso: `./reboot-remoto.sh`
   (H-27).
7. **Portátil**: cerrar la tapa suspende y se pierde el acceso (H-29). Usá
   `--laptop` / `./laptop-no-suspend.sh --apply`.
8. **La auth key de Tailscale NO se genera en el equipo**: se crea en
   `https://login.tailscale.com/admin/settings/keys` y se copia. Se muestra
   UNA vez. Si no la tenés, `--tailscale-luego` y luego `./unir-tailscale.sh`
   (H-26, H-30).
9. **Sudo en equipo recién instalado pide contraseña** (polkit para reboot/
   logind). NO es un bug (H-27).

---

## Documentos para agentes

| Doc | Para qué |
|---|---|
| [`PROMPT-AGENTE.txt`](PROMPT-AGENTE.txt) | **Instalar** el kit en un cliente (pegar como primer mensaje) |
| [`docs/agente-operador.md`](docs/agente-operador.md) | **Operar** clientes ya instalados: flujos, reglas, seguridad |
| Este `AGENTS.md` | Cómo **trabajar en el repo** (Pi lo carga automáticamente) |

## Estructura del repo

| Archivo | Rol |
|---|---|
| `instalar-todo.sh` | Orquestador: hace todo en el cliente |
| `setup-remote-target.sh` | El motor: RustDesk + SSH + firewall + Tailscale (+1433 líneas) |
| `unir-tailscale.sh` | Une a la tailnet pidiendo/pegando auth key |
| `laptop-no-suspend.sh` | Evita suspensión en portátiles |
| `reboot-remoto.sh` | Reinicio unattended (NOPASSWD acotado) |
| `update.sh` | Mantenimiento: sistema + RustDesk + Tailscale |
| `rustdesk-password.sh` | Fija contraseña permanente de RustDesk |
| `install-rustdesk-unattended-fedora.sh` | RustDesk con DRM en Fedora/RHEL |
| `verify-offlan.sh` | Prueba acceso fuera de la LAN |
| `inventory.sh` | Ficha de specs (texto/JSON/MD) |
| `tests.sh` | ~474 tests (se corre en CI y antes de un cliente nuevo) |
| `verify-docs.sh` | Verifica que la doc no se desincronice |
| `make-kit.sh` | Empaqueta para pendrive/tarball |
| `PROMPT-AGENTE.txt` | Prompt de instalación (para el equipo OBJETIVO) |

Documentación: [`docs/`](docs/) — guía, referencia, hallazgos, Tailscale,
onboarding, estado de sesión, alternativas VPN.

---

## Flujo de trabajo al INSTALAR en un cliente

```bash
git clone https://github.com/juanpablofuentealba/rustdesk-wlan-ssh-pi ~/kit
cd ~/kit

./setup-remote-target.sh --check                                    # 1. diagnóstico
./instalar-todo.sh --dry-run --authkey 'tskey-auth-...' --rdpass 'X' # 2. simulacro
sudo ./instalar-todo.sh --authkey 'tskey-auth-...' --rdpass 'X'      # 3. aplicar
./tests.sh "$USER@localhost"                                         # 4. verificar
```

Preferí **`--authkey-stdin`** en vez de `--authkey` (la key no queda en el
historial ni en `ps`):
```bash
printf %s 'tskey-auth-...' | sudo ./instalar-todo.sh --authkey-stdin --rdpass 'X'
```

Desde el PC operador:
```bash
tailscale status | grep <hostname>
ssh USUARIO@<hostname> 'hostname'
./verify-offlan.sh <hostname>
./reboot-remoto.sh --host USUARIO@<hostname> --all
```

---

## Convenciones al MODIFICAR el repo

- **Estilo**: bash estricto (`set -euo pipefail`), funciones `info/ok/warn/err`,
  mensajes en español.
- **Shellcheck**: el CI corre `shellcheck -S warning -e SC1090,SC1091`.
  El CI actual instala 0.9.0 vía apt; conviene fijar 0.10.0 (ver abajo).
- **Tests**: cada fix debe traer su test en `tests.sh` (patrón `t "desc" bash -c '...'`).
  El CI debe quedar verde.
- **Docs**: cada hallazgo nuevo va a `docs/hallazgos.md` con ID correlativo
  (`H-NN`), síntoma, causa raíz y solución. `verify-docs.sh` comprueba que no
  se desincronicen.
- **Secretos**: nunca claves privadas ni auth keys en el repo (job `secrets` del CI).

---

## Estado de la revisión externa (Pi, 28 oct 2025)

Se hizo una revisión del commit `ea87efe`. Bugs encontrados y parcheados:

- **H-33 (nuevo)** — Inyección en `/etc/sudoers.d` vía `--user` en
  `reboot-remoto.sh`: un nombre con comilla inyectaba `NOPASSWD: ALL`.
  Fix: validar con regex POSIX + pasar el usuario como argumento al heredoc.
- **H-34 (nuevo)** — `AUTHKEY_POR_ARGV` muerta en `instalar-todo.sh`: faltaba
  el aviso de que `--authkey` queda en historial/`ps`. Fix: bloque de aviso.
- **H-35 (nuevo)** — `printf` sin escapar en `unir-tailscale.sh` (SC2183).
  Fix: `%s` → `%%s`.
- **CI**: `apt-get install shellcheck` trae 0.9.0, que no caza los dos últimos.
  Conviene fijar 0.10.0.

Detalle completo y parches: ver el bundle de revisión (si está aplicado) o
`git log --oneline --grep="H-33\|H-34\|H-35"`.

---

## Pendientes / ideas

- Verificar `verify-offlan.sh` en un cliente real (0 clientes hoy).
- Evaluar `gh`/atajo para que el operador abra PRs más rápido.
- Posible skill de Pi para "administrar cliente remoto" (SSH+Tailscale+RustDesk).
