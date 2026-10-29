# rustdesk-wlan-ssh-pi

Kit para **administrar computadoras de forma remota**: RustDesk (acceso
visual / unattended) + **SSH + Tailscale** para trabajar de verdad dentro de la
máquina. Probado de punta a punta en **Arch, Debian y Fedora** (Linux) y con un
**kit para Windows 10/11** en [`windows/`](windows/).

> **¿Primera vez?** Leé [`docs/guia-desde-cero.md`](docs/guia-desde-cero.md)
> (explica sin tecnicismos) y después [`PASOS-EN-ORDEN.txt`](PASOS-EN-ORDEN.txt).
> Si vas a usar un agente IA, pegale [`PROMPT-AGENTE.txt`](PROMPT-AGENTE.txt)
> (para instalar) o leé [`docs/agente-operador.md`](docs/agente-operador.md)
> (para administrar clientes ya instalados).

---

## 🔑 Auth key de Tailscale: DÓNDE SE OBTIENE

> **LA AUTH KEY NO SE GENERA EN EL EQUIPO.** Se crea en la **página web de
> Tailscale**, logueado con tu cuenta, desde **cualquier navegador** (el celular
> sirve). No hace falta tener Tailscale instalado donde la generás: es un
> **string de texto** que copiás de la web y pegás en el equipo del cliente.

### 👉 Página para generar la auth key:

# https://login.tailscale.com/admin/settings/keys

(alias: `https://console.tailscale.com/admin/settings/keys`)

**Camino manual:** `login.tailscale.com/admin` → **Settings** → pestaña **Keys**
→ **"Generate auth key..."**. Se muestra **UNA SOLA VEZ**.

| Campo | Un equipo | Varios |
|---|---|---|
| Reusable | ❌ NO | ✅ SÍ |
| Ephemeral | ❌ NO | ❌ NO |
| Pre-approved | ✅ SÍ | ✅ SÍ |
| Expiry | 1 día | 90 días |

**No está** en *Machines*, ni en *DNS*, ni en la app de escritorio. Solo en
**Settings → Keys**.

**¿Todavía no tenés la key? No te bloquees** — instalá y uní después:

```fish
sudo ./instalar-todo.sh --tailscale-luego --rdpass 'MiClave2026'
./unir-tailscale.sh --hostname laptop-cliente   # pide/pega la key y une
```

Detalle: [`docs/tailscale.md`](docs/tailscale.md#generar-la-auth-key-paso-a-paso-en-la-web) · [H-26](docs/hallazgos.md) · [H-30](docs/hallazgos.md)

---

## Inicio rápido

### En el PC objetivo (cliente)

```fish
# Copiá el kit (por pendrive o git) y entrá
cp -r /run/media/$USER/Ventoy/kit-rustdesk ~/kit && cd ~/kit
# o:  git clone https://github.com/juanpablofuentealba/rustdesk-wlan-ssh-pi ~/kit

./setup-remote-target.sh --check          # 1. diagnóstico (no cambia nada)
./instalar-todo.sh --dry-run --authkey 'tskey-auth-XXXX' --rdpass 'Clave'   # 2. simulacro
sudo ./instalar-todo.sh --authkey 'tskey-auth-XXXX' --rdpass 'Clave'        # 3. aplicar
```

Un solo comando hace **RustDesk unattended + sshd + firewall + clave del
operador + Tailscale + anti-suspensión de portátil + contraseña + verificación**.

Si todavía no tenés la auth key, usá `--tailscale-luego` y después
`./unir-tailscale.sh` (ver arriba).

### Desde el PC operador (tu equipo)

```fish
tailscale status | grep <hostname>              # ¿aparece en la tailnet?
ssh -o BatchMode=yes USUARIO@<hostname> 'hostname'
./verify-offlan.sh <hostname>                   # acceso fuera de la LAN (7 OK)
./reboot-remoto.sh --host USUARIO@<hostname> --all   # reinicio unattended
```

**Mantenimiento** (en el PC del cliente, con root):

```bash
sudo ./update.sh             # sistema + RustDesk + Tailscale
./update.sh --check          # solo consultar si hay pendientes
```

RustDesk: conectate al ID del equipo con la contraseña permanente.

---

## Qué resuelve (el problema)

RustDesk da pantalla y control, pero **no tiene CLI/API** (es GUI pura) y en
Wayland el unattended necesita setup especial (captura DRM, uinput, portal).
Para *trabajar* (logs, paquetes, specs) hace falta **shell** → SSH. Y para
llegar **fuera de la LAN** sin abrir puertos → **Tailscale**.

| Pieza | Para qué |
|---|---|
| **RustDesk** unattended | Ver y controlar la pantalla (incluso en el login) |
| **SSH** | Trabajar de verdad: shell, logs, paquetes, specs |
| **Tailscale** | Llegar desde cualquier red, sin abrir puertos en el router |
| **Agente IA** | Opcional: solo en TU equipo, nunca en el del cliente |

---

## Archivos del kit

| Archivo | Qué es |
|---|---|
| [`instalar-todo.sh`](instalar-todo.sh) | **Un solo comando**: hace todo en el cliente |
| [`setup-remote-target.sh`](setup-remote-target.sh) | RustDesk + SSH + firewall + Tailscale (`--laptop`, `--check`, `--dry-run`) |
| [`unir-tailscale.sh`](unir-tailscale.sh) | Unir a la tailnet pidiendo/pegando la auth key · [H-30](docs/hallazgos.md) |
| [`laptop-no-suspend.sh`](laptop-no-suspend.sh) | **Portátiles**: evita que suspenda y se pierda el acceso · [H-29](docs/hallazgos.md) |
| [`reboot-remoto.sh`](reboot-remoto.sh) | Reinicio remoto unattended (NOPASSWD acotado) · [H-27](docs/hallazgos.md) |
| [`update.sh`](update.sh) | **Mantenimiento**: actualiza el sistema + RustDesk + Tailscale (Arch/Debian/Fedora) |
| [`rustdesk-password.sh`](rustdesk-password.sh) | Fija la contraseña permanente de RustDesk · [H-15](docs/hallazgos.md) |
| [`install-rustdesk-unattended-fedora.sh`](install-rustdesk-unattended-fedora.sh) | RustDesk con DRM en Fedora/RHEL (desde el `.deb`) · [H-14](docs/hallazgos.md) |
| [`verify-offlan.sh`](verify-offlan.sh) | Prueba el acceso desde fuera de la LAN |
| [`inventory.sh`](inventory.sh) | Ficha de specs del equipo (texto/JSON/Markdown) |
| [`tests.sh`](tests.sh) | Pruebas antes de un cliente nuevo (**627**) |
| [`make-kit.sh`](make-kit.sh) | Empaqueta el kit para un pendrive/tarball |
| [`windows/`](windows/) | **Kit para Windows 10/11**: `setup-remote-target.ps1`, `inventory.ps1`, `rustdesk-password.ps1` · [H-45..H-47](docs/hallazgos.md) |
| [`PROMPT-AGENTE.txt`](PROMPT-AGENTE.txt) | Prompt para agentes IA, fase de **instalación** (OpenCode/Claude/pi) |
| [`docs/agente-operador.md`](docs/agente-operador.md) | Agente IA como **operador** remoto: flujos y reglas para mantener clientes |
| [`docs/operador-multiple.md`](docs/operador-multiple.md) | **Varios operadores** (flota con 2+ PCs operadores): identidad SSH propia por operador, operación cruzada, `flota.sh` con dos bloques |
| [`docs/caso-real-msi.md`](docs/caso-real-msi.md) | **Caso real**: instalación y mantención de punta a punta en un cliente de trabajo |
| [`PASOS-EN-ORDEN.txt`](PASOS-EN-ORDEN.txt) | Checklist del pendrive, en orden |
| [`LEEME-PRIMERO.txt`](LEEME-PRIMERO.txt) | Qué hay en el pendrive + resumen |
| [`REPO.txt`](REPO.txt) | Este repositorio: URL, uso rápido, índice |

**Documentación:**

| Doc | Contenido |
|---|---|
| [`docs/guia-desde-cero.md`](docs/guia-desde-cero.md) | Explicación para principiantes |
| [`docs/referencia.md`](docs/referencia.md) | **Detalle técnico**: pasos manuales, herramientas, multi-distro |
| [`docs/hallazgos.md`](docs/hallazgos.md) | H-01..H-50: problemas reales y sus soluciones |
| [`docs/tailscale.md`](docs/tailscale.md) | Tailscale: acceso sin abrir puertos |
| [`docs/onboarding-cliente.md`](docs/onboarding-cliente.md) | Cómo dar de alta un cliente (modelo B) |
| [`docs/estado-sesion.md`](docs/estado-sesion.md) | Estado del trabajo, para retomar |
| [`docs/vpn-remoto.md`](docs/vpn-remoto.md) | WireGuard / Cloudflare como alternativas |

---

## Distros soportadas

El script detecta la familia vía `/etc/os-release` y usa el camino correcto.

| Familia | Distros | Gestor | RustDesk |
|---|---|---|---|
| **Arch** | CachyOS, Arch, Manjaro, EndeavourOS | `pacman` (+ AUR) | **`.deb` oficial unattended** → AUR como alternativa |
| **Debian** | Debian, Ubuntu, Mint, Pop!_OS | `apt` | `.deb` oficial |
| **Fedora** | Fedora, RHEL, Rocky, AlmaLinux | `dnf` | **`.deb` oficial unattended** → `.rpm` como alternativa |

> **¿Por qué el `.deb` también en Arch y Fedora?** Es el único que trae
> `libdrmtap.so`, el capturador DRM del unattended en Wayland. El kit lo
> descarga, verifica su sha256 y lo extrae a mano (solo `curl`+`ar`+`tar`).
> Ver [H-14](docs/hallazgos.md) y [H-24](docs/hallazgos.md).

Detalle por familia, firewall y Linux Mint: [`docs/referencia.md`](docs/referencia.md#11-soporte-multi-distro-arch--debian--fedora).

---

## Seguridad

- El tráfico de Tailscale va cifrado (WireGuard); SSH autentica por clave.
- El kit **no** pide ni guarda la contraseña del cliente: usa **auth key** +
  tu clave pública SSH.
- El cliente **conserva el control**: puede revocar tu acceso en su panel
  (Machines → equipo → Disable) o quitando tu línea de `authorized_keys`.
- Las reglas `NOPASSWD` que agrega el kit son **acotadas** (`reboot`), no todo sudo.

---

## Licencia

MIT — ver [`LICENSE`](LICENSE).
