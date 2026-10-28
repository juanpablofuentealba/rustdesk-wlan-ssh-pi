# Referencia técnica — configuración manual, herramientas y multi-distro

> Documento de detalle del kit. El resumen y el inicio rápido están en
> [`README.md`](../README.md). Acá está el **cómo** cuando necesitás el paso
> a paso manual, o entender qué hace cada script por dentro.

---

## Qué necesita cada máquina (importante)

No es simétrico. El **operador** solo necesita *salir* hacia los clientes; el
**objetivo** es el que debe *aceptar* conexiones.

| Componente | PC OPERADOR | PC OBJETIVO |
|---|---|---|
| **Tailscale** | ✅ (para alcanzar clientes) | ✅ (para ser alcanzado) |
| **RustDesk (app)** | ✅ (ver/controlar) | ✅ (ser controlado) |
| **RustDesk unattended** (DRM/uinput) | ❌ no aplica | ✅ **sí** |
| **sshd** | ❌ **no necesita** | ✅ **sí** |
| **firewall abierto :22** | ❌ no | ✅ **sí** |
| **clave del operador autorizada** | ❌ no | ✅ **sí** |
| **agente IA (`pi` + modelo)** | ✅ **solo aquí** | ❌ **NUNCA** |

> **`pi` vive SOLO en el operador.** El agente IA es **herramienta de trabajo del
> técnico**, no software del cliente. No se instala ni se configura en el PC
> objetivo: allí solo va la infraestructura de acceso (RustDesk + sshd +
> Tailscale + la clave del operador).
>
> Motivo práctico: `pi` no incluye modelos gratuitos fiables, así que requeriría
> que cada cliente pague un modelo (o que el operador lo pague por todos). El
> cliente **no necesita** el agente: el agente lo usa el operador **desde su
> propio equipo**, alcanzando el PC del cliente por SSH.

> **Error común:** habilitar `sshd`/abrir puertos en el **operador**. No sirve
> de nada: nadie entra en el operador. Solo el objetivo necesita aceptar
> conexiones. El operador solo necesita Tailscale (y RustDesk si va a mirar
> pantallas).

---

## 3. Configurar el PC objetivo (Arch / Debian / Fedora)

> **Hay dos caminos:** el **automático** (recomendado, script) o el **manual**
> (para entender qué hace). El script ejecuta exactamente los pasos manuales,
> pero además resuelve el usuario correcto bajo `sudo`, evita claves duplicadas
> y detecta el firewall. **Soporta Arch, Debian/Ubuntu y Fedora/RHEL** con
> ramas separadas por familia. En **todas** el kit prefiere el `.deb` con
> capturador DRM; los gestores nativos (`pacman`/`apt`/`dnf`) se usan para el
> resto de los paquetes. Ver [§ 11](#11-soporte-multi-distro-arch--debian--fedora).

### 3.0 Automático (recomendado)

```fish
# En el PC objetivo, con el kit copiado (ej. por scp o git clone):

# a) Diagnóstico: no cambia nada, no necesita root
./setup-remote-target.sh --check

# b) SIMULACRO: muestra qué haría, sin aplicar nada (seguro, sin root)
./setup-remote-target.sh --all --dry-run --key "ssh-ed25519 AAAA... operador@mipc"

# c) Aplicar todo (pide confirmación y tu contraseña sudo):
#    - RustDesk unattended (DRM + uinput)
#    - sshd habilitado
#    - firewall abierto en :22
#    - clave del operador autorizada
sudo ./setup-remote-target.sh --all --key "ssh-ed25519 AAAA... operador@mipc"
#    (usa --yes para no preguntar; útil en automatización)
```

Si ya lo copiaste vía `make target-setup`, el comando exacto se te imprime al final.

### 3.1 RustDesk con acceso desatendido en Wayland

Instalar el paquete con soporte de captura DRM:

```fish
# Ruta recomendada (la que usa el kit): el kit baja y verifica el .deb oficial
sudo ./setup-remote-target.sh --rustdesk

# Alternativa en Arch, si preferís el AUR y tenés paru/yay:
paru -S rustdesk-unattended-wayland
```

### Requisitos del PC objetivo

**Lo instala el kit solo** (no tenés que hacer nada):

| Dependencia | Para qué | Cómo la resuelve |
|---|---|---|
| `curl` | descargar paquetes | viene en toda distro de escritorio |
| `ar` + `tar` | extraer el `.deb` con DRM | vienen en `binutils`/`tar` |
| `python3` + PyNaCl | generar el hash de la contraseña | el kit **instala PyNaCl** si falta |
| `openssh-server` | acceso por SSH | `--ssh` lo instala |
| `tailscale` | acceso fuera de la LAN | `--tailscale` lo instala |
| **`paru`/`yay`** | AUR (opcional) | **el kit instala `paru` solo**: primero desde el repo (`cachyos`/`extra`), y si no está, compilando `paru-bin` desde AUR |
| RustDesk con DRM | acceso desatendido | el kit baja el `.deb` oficial y lo verifica |

> **Sobre paru:** en CachyOS y Arch **no hace falta instalarlo a mano**. `paru`
> está en el repo binario (`cachyos` en CachyOS, `extra` en Arch), así que el kit
> hace `pacman -S paru` directo — sin compilar. Solo si no estuviera en ningún
> repo lo compilaría desde AUR. Y para RustDesk, **la vía del `.deb` con DRM ni
> siquiera necesita paru**.

**Lo tiene que cumplir el equipo** (el kit lo comprueba y avisa):

```fish
# El servicio corre como root y necesita acceso a /dev/dri
ls -la /dev/dri/            # renderD128 debe existir
id $USER                   # debe incluir el grupo 'video'

# uinput para inyección de teclado/ratón
ls -la /dev/uinput
lsmod | grep uinput

# sesión Wayland (para saber si aplica el capturador DRM)
echo $XDG_SESSION_TYPE
```

Todo esto lo verifica de una sola pasada:

```fish
./setup-remote-target.sh --check
```

Los **logs del server** confirman la ruta correcta (captura DRM ≠ portal):

```fish
grep -iE "uinput|drm:|ipc server" ~/.local/share/logs/RustDesk/server/rustdesk_rCURRENT.log | tail
```

Salida esperada:

```
UInput keyboard created
UInput mouse created
drm: consumer cache warmed (1 displays) at startup    ← captura DRM activa
Started ipc server at path: /tmp/RustDesk-1000/ipc
```

> **Por qué importa:** la captura **DRM directa** evita el diálogo de
> xdg-desktop-portal, y es lo que permite el **acceso desatendido**
> (conectar sin que nadie acepte en pantalla). El fallback PipeWire/portal
> muestra *"Please select the screen to be shared"*.

Refuerzos opcionales:

```fish
# que el monitor apagado se despierte (si no hay scanout no hay captura)
# ~/.config/rustdesk/RustDesk2.toml
[options]
enable-drm-display-wake = 'Y'
```

```fish
# uinput garantizado al arranque y accesible al usuario de la sesión
# /etc/modules-load.d/rustdesk-uinput.conf
uinput

# /etc/udev/rules.d/60-rustdesk-uinput.rules
KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"
```

### 3.2 SSH

```fish
# instalar (si no está) y habilitar el demonio
sudo pacman -S --needed openssh
sudo systemctl enable --now sshd

# comprobar que escucha
ss -tlnp | grep :22
```

### 3.3 Firewall (el paso que se olvida)

`sshd` puede estar escuchando y aun así la conexión **da timeout**: el firewall
está bloqueando los paquetes. En KDE/CachyOS lo típico es **ufw**:

```fish
sudo ufw allow 22/tcp
sudo ufw reload
sudo ufw status
```

Salida esperada:

```
22/tcp                     ALLOW       Anywhere
22/tcp (v6)                ALLOW       Anywhere (v6)
```

> ⚠️ **Diagnóstico clave:** si `ss -tln` muestra `:22` LISTEN pero `ssh` da
> *"Connection timed out"*, **es el firewall**, no sshd. Prueba
> `ssh USUARIO@localhost` en la propia máquina: si funciona local pero no remoto,
> confirmado — firewall.

### 3.4 Autorizar la clave pública del operador

En el PC objetivo, agregar la clave del operador a `authorized_keys`:

```fish
mkdir -p ~/.ssh; and chmod 700 ~/.ssh
echo "ssh-ed25519 AAAA... operador@mipc" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

> ⚠️ **Si haces esto con `sudo`**, `~` apunta a `/root` y la clave quedará en el
> lugar equivocado (SSH la ignorará). En ese caso, opera sobre el HOME real y
> ajusta el dueño:
>
> ```fish
> sudo mkdir -p /home/jp/.ssh
> sudo sh -c 'echo "ssh-ed25519 AAAA... operador@mipc" >> /home/USUARIO/.ssh/authorized_keys'
> sudo chmod 700 /home/USUARIO/.ssh; and sudo chmod 600 /home/USUARIO/.ssh/authorized_keys
> sudo chown -R USUARIO:USUARIO /home/USUARIO/.ssh
> ```
>
> El script `setup-remote-target.sh --key` ya gestiona esto automáticamente
> (detecta el usuario real vía `SUDO_USER`).

---

## 4. Configurar el PC operador

---

## 10. Herramientas incluidas

### `setup-remote-target.sh` — configurar el PC objetivo

```fish
# diagnóstico (no cambia nada)
./setup-remote-target.sh --check

# simulacro: muestra las acciones SIN aplicar nada (no necesita root)
./setup-remote-target.sh --all --dry-run --key "ssh-ed25519 AAAA..."

# RustDesk unattended + SSH + firewall + clave del operador
sudo ./setup-remote-target.sh --all --key (cat ~/.ssh/id_ed25519.pub)
#                                    ↑ en fish, ( ) sustituye el comando.
# En bash sería:  --key "$(cat ~/.ssh/id_ed25519.pub)"

# solo una parte
sudo ./setup-remote-target.sh --ssh --key "ssh-ed25519 AAAA... operador@mipc"
sudo ./setup-remote-target.sh --rustdesk

# acceso fuera de la LAN (Tailscale, modelo B: cuenta del cliente)
sudo ./setup-remote-target.sh --tailscale --authkey "tskey-auth-..."
#                        ↑ la auth key la genera el CLIENTE en su panel
#                          (Reusable: NO · Ephemeral: NO · Expiry: 1 día)
```

Detecta el firewall (ufw/firewalld/nftables) y abre el puerto SSH solo. Evita
duplicar claves en `authorized_keys`. Pide **confirmación** antes de aplicar
(salta con `--yes`). Flag `--dry-run`: simula sin tocar el sistema.

### `inventory.sh` — inventario de specs

```fish
./inventory.sh                      # máquina local
./inventory.sh remoto                # alias SSH
./inventory.sh USUARIO@192.168.1.20      # IP directa
./inventory.sh --json remoto         # JSON
./inventory.sh --markdown remoto     # Markdown (para issues/README)
```

### `clip-vm.sh` — portapapeles host↔VM por SSH

Puente de portapapeles por **SSH**, para **scripting/automatización** desde el
operador (donde el portapapeles de la sesión gráfica del objetivo puede no
existir).

> Para el uso **normal** (una persona frente a la VM) el portapapeles de SPICE
> **ya funciona en ambas direcciones** por la vía Wayland nativa — ver
> [H-13](docs/hallazgos.md). `clip-vm.sh` no hace falta para eso.

```fish
./clip-vm.sh get                       # portapapeles de la VM → host
./clip-vm.sh put                       # portapapeles del host → VM
./clip-vm.sh show                      # qué hay en el portapapeles de la VM

./clip-vm.sh get jp@10.0.0.5           # otro destino
CLIP_VM=jp@10.0.0.5 ./clip-vm.sh get   # o export CLIP_VM (config de fish)
```

Requiere `wl-clipboard` en host y guest, y clave SSH autorizada (`BatchMode`).
Por defecto apunta a `jp@192.168.122.11` (red NAT de libvirt).

> **Nota:** en Wayland el `spice-vdagent` de Fedora solo propaga **host→guest**
> (es una build X11 y no ve los cambios del compositor Wayland). Para
> copy-paste nativo en ambas direcciones, cambia el guest a sesión **X11** en el
> login de SDDM. `clip-vm.sh` es la alternativa que funciona sin tocar el guest.

### `tests.sh` — pruebas antes de un cliente nuevo

> **¿Vas a preparar el PC de un cliente?** Lee
> [`docs/onboarding-cliente.md`](docs/onboarding-cliente.md): modelos de acceso,
> auth keys de Tailscale (verificado con la doc oficial) y qué NO hacer.

```fish
./tests.sh                      # ~448 comprobaciones locales
./tests.sh USUARIO@192.168.1.20 # + los hallazgos contra un host real (~462)
```

Cubre: sintaxis, permisos, modos de salida (texto/JSON/Markdown), validez del
JSON, manejo de errores, modo `--check`, fuga de secretos, enlaces de la
documentación, **regresiones de hallazgos** (H-07 `hostname -I`, H-08 pipefail)
y **comportamiento en el host remoto** (servicios enabled, IP Tailscale,
captura DRM, tipo de login screen, `tailscale ping`).

### `verify-docs.sh` — valida la documentación

```fish
./verify-docs.sh
```

Comprueba que los **comandos de Tailscale** de la doc siguen existiendo
(`--auth-key`, `--hostname`, `netcheck`...) y que las **URLs oficiales**
responden. Córrelo antes de un cliente nuevo o después de actualizar Tailscale:
si algo cambió, lo detecta antes de que falles en terreno ajeno.

### `update.sh` — mantenimiento a largo plazo

> RustDesk y Tailscale publican versiones nuevas a menudo (varias cierran
> brechas de seguridad). Dejar el equipo del cliente en una versión vieja hace
> frágil el soporte remoto. Este script lo mantiene al día **sin volver a la
> casa del cliente**.

```fish
sudo ./update.sh                 # sistema + RustDesk + Tailscale
./update.sh --check              # ¿hay pendientes? (no aplica nada, sin root)
./update.sh --dry-run            # simulacro: muestra qué haría
./update.sh --no-sistema         # solo RustDesk (no toca el SO)
./update.sh --yes                # sin confirmaciones (cron/desatendido)
```

Cubre las tres familias: **pacman** (`-Syu`), **apt** (`update`+`upgrade`) y
**dnf** (`upgrade`). En Debian/Ubuntu, además, reinstala el **`.deb` oficial
`unattended-wayland`** de RustDesk (el que trae `libdrmtap.so`, igual que
`setup-remote-target.sh`; ver H-14/H-24). **No usa el `.deb` estándar**, que
carece de capturador DRM y rompería el desatendido en Wayland.

Una versión fija (`RD_VERSION`) con su **`sha256` verificado** (`RD_SHA256`)
hace el resultado reproducible: si el hash no coincide, el script **se niega a
instalar** y avisa de que probablemente salió una versión nueva. Tras instalar
**comprueba que `libdrmtap.so` esté presente** (anti-regresión), **reinicia el
servicio** y verifica que `rustdesk`, `sshd` y `tailscaled` sigan activos.

Detalle de comportamiento:
- `--check` y `--dry-run` no requieren root y nunca aplican cambios.
- **Sin TTY y sin `--yes` aborta** (no asume "sí" en silencio): actualizar es
  una acción destructiva y debe ser explícita.
- Si un paso falla, el script **termina con error** (no imprime "listo" en
  verde tras un fallo silencioso; ver H-22).

Desde el operador, con `make`:

```fish
make HOST=USUARIO@<hostname> update       # copia update.sh al host
make HOST=USUARIO@<hostname> update-now   # lo ejecuta (--yes, vía sudo -n)
```

Automatizarlo en el cron de root del objetivo (semanal):

```fish
0 4 * * 1  /root/kit/update.sh --yes >/var/log/kit-update.log 2>&1
```

### `Makefile` — atajos

```fish
make HOST=remoto help                # lista los targets
make HOST=remoto check               # SSH + sshd + firewall + RustDesk
make HOST=remoto inventory           # specs
make HOST=remoto inventory-md        # specs en Markdown
make HOST=remoto ports               # puertos escuchando
make HOST=remoto rustdesk-log        # log del server
make HOST=remoto key                 # genera clave si no existe
make HOST=remoto push-key            # ssh-copy-id al objetivo
make HOST=remoto test                # pruebas de humo (local + remoto)
```

---

## 11. Soporte multi-distro (Arch / Debian / Fedora)

El mismo script sirve para las tres familias; detecta la distro y usa el camino
adecuado. No hay que elegir nada a mano.

### Detección automática

```
$ ./setup-remote-target.sh --check
● OS: Ubuntu 24.04.1 LTS
● Familia: debian          ← detectado por /etc/os-release
```

| Familia | Detección | Gestor | Instalación de RustDesk |
|---|---|---|---|
| `arch` | ID/ID_LIKE contiene `arch` (o existe `pacman`) | `pacman` | `.deb` oficial con DRM; AUR (`paru`/`yay`) como alternativa |
| `debian` | `debian`/`ubuntu`/`linuxmint` (o existe `apt-get`) | `apt-get` | `.deb` oficial (resuelto en la API de GitHub) |
| `fedora` | `fedora`/`rhel` (o existe `dnf`) | `dnf`¹ | `.rpm` oficial (resuelto en la API de GitHub) |

¹ **Fedora 41+** usa **dnf5**, y `/usr/bin/dnf` es un **symlink a `dnf5`**: los
comandos `dnf install -y ...` funcionan igual, así que el kit no necesita
cambiar nada. El diagnóstico sí informa la versión real (`Gestor: dnf5 5.4.x`),
que se obtiene con `LC_ALL=C` para que no salga traducida. Verificado en
Fedora 41 y Fedora 44 (KDE) reales.

### Qué cambia por familia

| Paso | Arch | Debian/Ubuntu | Fedora/RHEL |
|---|---|---|---|
| Paquete SSH | `openssh` | `openssh-server` | `openssh-server` |
| Servicio SSH | `sshd` | `ssh` (alias `sshd`) | `sshd` |
| Firewall por defecto | ufw / nftables | ufw | **firewalld** |
| Abrir puerto | `ufw allow 22/tcp` | `ufw allow 22/tcp` | `firewall-cmd --add-service=ssh` |
| RustDesk unattended | AUR (`DRM`) | `.deb` oficial | `.rpm` oficial |

> **Nota (Debian/Ubuntu/Mint):** RustDesk se instala desde el `.deb` oficial. En
> Wayland, la captura puede requerir el portal PipeWire en algunas versiones;
> el script verifica el log y avisa. Para unattended completo en Wayland, el
> camino más probado sigue siendo Arch (paquete con parche DRM).

### Linux Mint (base Ubuntu)

Mint trae `ID_LIKE="ubuntu debian"`, así que **detecta como `debian`** sin
configurar nada. Dos detalles propios de Mint que el script ya cubre:

- **`ufw` viene instalado pero INACTIVO** (GUFW sin activar). El script lo
  detecta como `ufw-inactive`, avisa y con `--ssh` **lo activa y abre :22**
  (en vez de asumir que no hay firewall).
- **Cinnamon usa X11 por defecto** → la captura de RustDesk funciona directo.
  Si usas la sesión **Wayland** de Mint, el `.deb` oficial no trae el parche DRM
  de Arch y el script te avisa (puede caer al portal "elige la pantalla").

#### Versiones de Mint

> **Cambio de esquema (2026):** Mint abandonó el versionado `22.x` con point
> releases y pasó a **un número por año, sin puntos**. El número representa el
> año de la serie; cada año hay **una** versión.

| Versión | Nombre | Base | Estado |
|---|---|---|---|
| **22.3** | Zena | Ubuntu 24.04 | estable anterior (última con points) |
| **27** | **Adrien** | **Ubuntu 26.04** | **próxima — sale en Navidad** (en desarrollo/pre-beta) |
| 28 | (por anunciar) | — | siguiente serie (2027) |

- Tras la 27 ya **no habrá 27.1/27.2**: se salta directo a la 28, 29, etc.
- Cambio de tradición: nombres **masculinos** ("Adrien" sucede a "Zena").
- Base Ubuntu **26.04** (LTS siguiente), no 24.04.
- Fuente oficial: [Monthly News – Septiembre 2026](https://blog.linuxmint.com/?s=27).

**Para el kit no cambia nada:** la 27 seguirá trayendo `ID_LIKE="ubuntu debian"`
(base Ubuntu 26.04), así que seguirá detectándose como `debian`. Las mismas dos
particularidades (ufw inactivo, X11 por defecto) aplican igual.

#### Probado

Rama probada contra `/etc/os-release` real de **Mint 22.3 "Zena"** en contenedor
`debian:12`. Para la **27 "Adrien"** la detección es idéntica (misma familia),
pero conviene re-verificar cuando salga la ISO:

```fish
./setup-remote-target.sh --check   # debe decir: Familia: debian
```

### Forzar la familia (pruebas)

```fish
# Útil para simular una distro antes de ir al cliente
DISTRO_FAMILY_OVERRIDE=debian ./setup-remote-target.sh --all --dry-run
DISTRO_FAMILY_OVERRIDE=fedora ./setup-remote-target.sh --all --dry-run
```

### Resolución del paquete de RustDesk

Los nombres de los assets incluyen la versión (ej. `rustdesk-1.5.0-x86_64.deb`),
así que el script consulta la API de releases y elige el asset estándar (excluye
variantes `-sciter` y `-suse`):

```
Resolviendo el .deb oficial de RustDesk...
Descargando rustdesk-1.5.0-x86_64.deb...
✔ RustDesk instalado (.deb oficial)
```

---

## 12. Antes de instalar en un cliente nuevo (checklist del operador)

```fish
# 1. Pruebas locales del kit
./tests.sh

# 2. Copiar el kit al cliente
scp setup-remote-target.sh inventory.sh cliente:~/     # o git clone

# 3. Diagnóstico remoto (no cambia nada)
ssh cliente 'bash ~/setup-remote-target.sh --check'

# 3b. Simulacro remoto (muestra qué haría, sin aplicar; no necesita root)
ssh cliente 'bash ~/setup-remote-target.sh --all --dry-run --key "(clave publica)"'

# 4. Aplicar (el cliente teclea su sudo; pide confirmación con --yes para no bloquear)
ssh cliente 'bash ~/setup-remote-target.sh --all --yes --key "(clave publica)"'

# 5. Verificar desde el operador
./tests.sh cliente                    # o: make HOST=cliente check
./inventory.sh cliente                # specs
```

**Errores ya conocidos y evitados por el kit:**

| Síntoma | Causa | Cómo lo cubre el kit |
|---|---|---|
| Clave no funciona | `sudo` escribió en `/root/.ssh` | Detecta `SUDO_USER` y usa su HOME |
| "escucha pero timeout" | firewall (ufw/firewalld) | Detecta y abre `:22` |
| Clave duplicada | `>>` repetido | `grep -F` antes de añadir |
| `IP local` vacío | `hostname -I` no existe | Usa `ip route get` |
| Comandos fallan en el cliente | shell es fish | Scripts son bash; se invocan con `bash` |
| Captura pide confirmación | cayó al portal, no DRM | Verifica `drm: consumer cache` |
| Aplicar cambios sin querer | script ejecuta y ya | `--dry-run` simula; pide confirmación salvo `--yes` |

---

## 13. Comandos de referencia rápida

```fish
# ---------- OBJETIVO ----------
sudo pacman -S --needed openssh
sudo systemctl enable --now sshd
sudo ufw allow 22/tcp
ss -tlnp | grep :22
systemctl status sshd --no-pager

# ---------- OPERADOR ----------
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "operador@mipc"
ssh -o BatchMode=yes USUARIO@<ip> 'hostname; uname -r'
ssh remoto                                   # con alias en ~/.ssh/config

# ---------- DIAGNÓSTICO ----------
ssh USUARIO@localhost 'echo ok'                   # ¿sshd local bien?
timeout 5 bash -c 'echo > /dev/tcp/<ip>/22'  # ¿puerto alcanzable?
avahi-browse -art | grep -i <hostname>       # ¿dónde está el host?

# ---------- VPN (fuera de la LAN) ----------
sudo wg show                                 # estado WireGuard
tailscale status                             # estado Tailscale
ssh remoto 'hostname'                         # por túnel, desde cualquier red
```

---

## Licencia

MIT — ver [`LICENSE`](LICENSE).
