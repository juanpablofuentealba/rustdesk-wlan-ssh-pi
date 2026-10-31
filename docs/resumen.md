# Resumen ejecutivo (1 página)

> **¿Poco tiempo?** Esta es la página para ti. Resume el README + `INSTALAR.md` +
> `PASOS-EN-ORDEN.txt` + `LEEME-PRIMERO.txt` (~900 líneas) en lo mínimo para operar.
> Para el detalle, bajá a los documentos enlazados al final.

## ¿Qué es?

Kit para dejar un PC de cliente (Linux, desde cero) **administrable remoto**:
**RustDesk** (pantalla) + **SSH** (shell) + **Tailscale** (llegar desde cualquier
red sin abrir puertos). Nada de esto tiene CLI propio para operar → se combinan.

## Las 3 piezas

| Pieza | Para qué |
|---|---|
| RustDesk unattended | Ver/controlar pantalla (incluso en login). Wayland = captura DRM + uinput |
| SSH | Trabajar de verdad: shell, logs, paquetes, specs |
| Tailscale | Llegar desde otra red (CGNAT, sin abrir puertos) |

## Instalación (el camino corto)

```bash
# 1. En el PC cliente, copiar el kit (pendrive o git)
cp -r /run/media/$USER/Ventoy/kit-rustdesk ~/kit && cd ~/kit
# o: git clone https://github.com/juanpablofuentealba/rustdesk-wlan-ssh-pi ~/kit

./setup-remote-target.sh --check                                        # diagnóstico (no cambia nada)
./instalar-todo.sh --dry-run --authkey 'tskey-auth-XXXX' --rdpass 'Clave'  # simulacro
sudo ./instalar-todo.sh --authkey 'tskey-auth-XXXX' --rdpass 'Clave'    # aplicar

# Sin auth key todavía:
sudo ./instalar-todo.sh --tailscale-luego --rdpass 'Clave'   # y luego: ./unir-tailscale.sh
```

`instalar-todo.sh` hace **todo**: RustDesk unattended + sshd + firewall + clave
del operador + Tailscale + anti-suspensión + contraseña + verificación.

## Antes de salir (checklist)

- [ ] Pendrive: Ventoy + ISO CachyOS + carpeta `kit-rustdesk/`
- [ ] **`operador.pub`** en el kit (el repo NO la trae; se agrega con
      `./make-kit.sh --with-key` o se pasa `--key "$(cat ~/.ssh/id_ed25519.pub)"`)
- [ ] **Auth key de Tailscale**: se genera en la WEB
      → https://login.tailscale.com/admin/settings/keys
      (Reusable: NO · Ephemeral: NO · Expiry: 1 día)
- [ ] Contraseña permanente de RustDesk
- [ ] Contraseña sudo del usuario del cliente

## Desde el PC operador (verificar)

```bash
tailscale status | grep <hostname>                        # ¿está en la tailnet?
ssh -o BatchMode=yes USUARIO@<hostname> 'hostname'        # SSH responde
./verify-offlan.sh <hostname>                             # acceso FUERA de la LAN
./reboot-remoto.sh --host USUARIO@<hostname> --all        # reinicio unattended
```

> `verify-offlan.sh`: correr con el notebook en **otra red** (hotspot 4G), si no
> da falso positivo. Ver `test-fuera-de-lan.md`.

## Mantenimiento

```bash
sudo ./update.sh          # sistema + RustDesk + Tailscale
./update.sh --check       # solo consultar pendientes
```

## Scripts clave

| Script | Qué hace |
|---|---|
| `instalar-todo.sh` | Un comando: instala todo en el cliente |
| `setup-remote-target.sh` | RustDesk + SSH + firewall + Tailscale (`--check`, `--dry-run`, `--laptop`) |
| `unir-tailscale.sh` | Unir a la tailnet pidiendo/pegando auth key |
| `wol-despertar.sh` | **Encender** equipo apagado por WoL (operador = relé) |
| `energia-remota.sh` | **Apagar/reiniciar** sin exponer la clave sudo (STDIN) |
| `reboot-remoto.sh` | Reinicio unattended (NOPASSWD acotado) |
| `update.sh` | Actualiza sistema + RustDesk + Tailscale |
| `verify-offlan.sh` | Prueba acceso desde fuera de la LAN |
| `inventory.sh` | Ficha de specs del equipo (texto/JSON/MD) |
| `tests.sh` | Pruebas antes de un cliente nuevo |
| `make-kit.sh` | Empaqueta el kit para pendrive/tarball |
| `windows/` | Kit Windows 10/11 (PowerShell) |

## Distros soportadas

| Familia | Distros | Gestor | RustDesk |
|---|---|---|---|
| Arch | CachyOS, Arch, Manjaro, EndeavourOS | pacman (+AUR) | `.deb` oficial → AUR alternativa |
| Debian | Debian, Ubuntu, Mint, Pop!_OS | apt | `.deb` oficial |

Detecta la familia por `/etc/os-release`.

## Orden correcto de instalación

```
1. Pendrive → instalar SO CON WiFi (sin red no bajan paquetes)
2. Reiniciar sin pendrive → cambiar a HOTSPOT (prueba el caso CGNAT real)
3. Copiar kit-rustdesk/ del pendrive al PC
4. ./setup-remote-target.sh --check → ./instalar-todo.sh
5. ./verify-offlan.sh desde OTRA red → verde = listo
```

## Dónde está cada cosa (docs largos del repo)

| Necesito… | Archivo |
|---|---|
| Paso a paso desde cero | `INSTALAR.md` |
| Checklist del pendrive | `PASOS-EN-ORDEN.txt` |
| Qué hay en el pendrive | `LEEME-PRIMERO.txt` |
| Detalle técnico / manual | `docs/referencia.md` |
| Problemas reales resueltos (H-01..H-66) | `docs/hallazgos.md` |
| Caso real punta a punta | `docs/caso-real-msi.md` |
| Encendido/apagado remoto (WoL) | `docs/wol-y-energia-remota.md` |
| Operador Android/Termux | `docs/android-operador.md` |
| Varios operadores (flota) | `docs/operador-multiple.md` |
