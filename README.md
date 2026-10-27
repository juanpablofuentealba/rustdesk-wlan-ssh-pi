# rustdesk-wlan-ssh-pi

Flujo de trabajo para **administrar computadoras Linux de forma remota** combinando
RustDesk (acceso visual / unattended en Wayland) con **SSH + agente IA (`pi`)** para
trabajar de verdad dentro de la máquina.

Probado de punta a punta sobre **WLAN** entre dos equipos CachyOS, sin cable de red.

**Distros soportadas** (ramas separadas por familia, con su gestor nativo):

| Familia | Distros | Gestor | RustDesk |
|---|---|---|---|
| **Arch** | CachyOS, Arch, Manjaro, EndeavourOS | `pacman` + AUR (`paru`/`yay`) | `rustdesk-unattended-wayland` (AUR) |
| **Debian** | Debian, Ubuntu, **Linux Mint**, Pop!_OS | `apt` | `.deb` oficial |
| **Fedora** | Fedora, RHEL, Rocky, AlmaLinux | `dnf` | `.rpm` oficial |

El script detecta la familia vía `/etc/os-release` y usa el camino correcto.
Se puede forzar con `DISTRO_FAMILY_OVERRIDE=debian` para pruebas.

## Contenido

| Archivo | Qué es |
|---|---|
| [`README.md`](README.md) | Esta guía |
| [`docs/guia-desde-cero.md`](docs/guia-desde-cero.md) | **Explicación para principiantes**: qué hace cada pieza y paso a paso |
| [`setup-remote-target.sh`](setup-remote-target.sh) | Prepara el PC objetivo (RustDesk + SSH + firewall + clave) · **Arch/Debian/Fedora** |
| [`inventory.sh`](inventory.sh) | Inventario de specs (texto / JSON / Markdown) |
| [`clip-vm.sh`](clip-vm.sh) | Puente de portapapeles host↔VM por SSH (`get` / `put` / `show`) |
| [`install-rustdesk-unattended-fedora.sh`](install-rustdesk-unattended-fedora.sh) | Instala el paquete **unattended Wayland** (con `libdrmtap`) en Fedora/RHEL desde el `.deb` oficial · ver [H-14](docs/hallazgos.md) |
| [`rustdesk-password.sh`](rustdesk-password.sh) | Fija la **contraseña permanente** de RustDesk (necesaria para unattended) · ver [H-15](docs/hallazgos.md) |
| [`tests.sh`](tests.sh) | Pruebas de humo (sintaxis, salidas, remoto) — **córrelo antes de un cliente nuevo** |
| [`verify-docs.sh`](verify-docs.sh) | Valida que los comandos de Tailscale y las URLs de la doc sigan vigentes |
| [`Makefile`](Makefile) | Atajos: `check`, `inventory`, `ssh`, `target-setup`… |
| [`docs/vpn-remoto.md`](docs/vpn-remoto.md) | WireGuard / Tailscale / Cloudflare para acceso fuera de la LAN |
| [`docs/tailscale.md`](docs/tailscale.md) | **Guía dedicada de Tailscale**: acceso sin abrir puertos (recomendado) |
| [`docs/onboarding-cliente.md`](docs/onboarding-cliente.md) | **Cómo preparar el PC de un cliente** (modelos de acceso, auth keys verificadas) |
| [`docs/hallazgos.md`](docs/hallazgos.md) | **Hallazgos verificados en pruebas reales** (reinicio, login screen Wayland, etc.) |
| [`docs/estado-sesion.md`](docs/estado-sesion.md) | **Estado del trabajo con Fedora 44**: entorno de prueba, trampas y pendientes |
| [`LICENSE`](LICENSE) | MIT |

---

## 1. El problema

> **¿Vienes de cero?** Lee primero
> [`docs/guia-desde-cero.md`](docs/guia-desde-cero.md): explica sin tecnicismos
> qué es cada pieza y da el paso a paso para conectar el primer PC.

Quieres "arreglar computadoras Linux" de forma remota, especialmente:

- **CachyOS / Arch** (rolling release, Wayland, KDE Plasma), **Debian/Ubuntu**
  o **Fedora/RHEL** (el kit trae ramas separadas para cada familia).
- Equipos a los que **solo tienes acceso visual** (RustDesk), no shell.
- Redes **WiFi**, donde la IP cambia y el rendimiento es variable.

RustDesk te da **ver la pantalla y controlarla**, pero:

- ❌ No guarda specs del peer (CPU, RAM, disco…).
- ❌ No expone **API ni CLI de control remoto**: es GUI pura.
- ❌ En Wayland, el **acceso desatendido** requiere configuración especial
  (captura DRM, uinput, portal).

Para *trabajar* (leer logs, instalar paquetes, sacar specs, editar configs) hace
falta **shell**. Ese es el rol de SSH.

---

## 2. Arquitectura del flujo

```
┌─────────────────────────┐                    ┌──────────────────────────┐
│   PC OPERADOR           │                    │   PC OBJETIVO (remoto)   │
│   (donde corre pi)      │                    │   (el que administras)   │
│                         │                    │                          │
│  ┌───────────────────┐  │   RustDesk (GUI)   │  ┌────────────────────┐  │
│  │ pi (agente IA)    │  │◄──────────────────►│  │ RustDesk server    │  │
│  │  + bash tool      │  │  screen + input    │  │ (unattended)       │  │
│  │  + modelo (pago)  │  │                    │  └────────────────────┘  │
│  └─────────┬─────────┘  │                    │                          │
│            │            │                    │  ┌────────────────────┐  │
│            │  SSH       │                    │  │ sshd (puerto 22)   │  │
│            └────────────┼────────────────────┼─►│ + clave operador   │  │
│                         │  shell real        │  └────────────────────┘  │
│  (el agente NO se       │                    │  (sin agente IA: solo    │
│   instala en el cliente)│                    │   infraestructura)       │
└─────────────────────────┘                    └──────────────────────────┘
        eth0 ────────── WiFi / LAN ──────────► wlan0 (192.168.1.20)
```

**Dos canales complementarios:**

| Canal | Para qué | Herramienta |
|---|---|---|
| **RustDesk** | Ver/controlar pantalla, sesión gráfica, soporte visual | GUI |
| **SSH** | Trabajar de verdad: shell, logs, paquetes, specs | `ssh` + agente IA |

La clave: **RustDesk para los ojos, SSH para las manos.**

### Qué necesita cada máquina (importante)

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
> que cada cliente pague un modelo (o que el operador lo pague por todos). Eso no
> escala ni es un producto vendible. El cliente **no necesita** el agente: el
> agente lo usa el operador **desde su propio equipo**, alcanzando el PC del
> cliente por SSH.

> **Error común:** habilitar `sshd`/abrir puertos en el **operador**. No sirve
> de nada: nadie entra en el operador. Solo el objetivo necesita aceptar
> conexiones. El operador solo necesita Tailscale (y RustDesk si va a mirar
> pantallas).

> **Al reiniciar el operador:** basta con que `tailscaled` esté `enabled`.
> No hace falta `sshd` ni config de firewall.

---

## 3. Configurar el PC objetivo (Arch / Debian / Fedora)

> **Hay dos caminos:** el **automático** (recomendado, script) o el **manual**
> (para entender qué hace). El script ejecuta exactamente los pasos manuales,
> pero además resuelve el usuario correcto bajo `sudo`, evita claves duplicadas
> y detecta el firewall. **Soporta Arch, Debian/Ubuntu y Fedora/RHEL** con
> ramas separadas por familia. Los pasos manuales de abajo usan `paru`/`pacman`
> (Arch); para otras familias ver [§ 11](#11-soporte-multi-distro-arch--debian--fedora).

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
paru -S rustdesk-unattended-wayland
```

Verificar los requisitos:

```fish
# El servicio corre como root y necesita acceso a /dev/dri
ls -la /dev/dri/            # renderD128 debe existir
id $USER                   # debe incluir el grupo 'video'

# uinput para inyección de teclado/ratón
ls -la /dev/uinput
lsmod | grep uinput
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

Generar una clave dedicada (sin passphrase, para automatización):

```fish
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "operador@mipc"
cat ~/.ssh/id_ed25519.pub   # esta es la que se pega en el PC objetivo
```

Añadir un alias cómodo en `~/.ssh/config` (importante en **WLAN**, donde la IP
puede cambiar):

```sshconfig
Host remoto
    HostName remoto.local        # mDNS: sobrevive cambios de IP (ver nota)
    User USUARIO
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes            # evita "too many authentication failures"
    ServerAliveInterval 30
    ServerAliveCountMax 3
    StrictHostKeyChecking accept-new
```

> **Nota mDNS:** `nombre.local` funciona si el operador tiene resolución mDNS
> (paquete `nss-mdns` + `avahi`). Compruébalo con `getent hosts remoto.local`.
> Si no resuelve, usa la IP fija o una reserva DHCP en el router.

Uso:

```fish
ssh remoto
```

---

## 5. Flujo de trabajo con el agente IA

Una vez que `ssh remoto` funciona, el agente `pi` puede ejecutar comandos en el
equipo remoto con su herramienta de shell:

```bash
# Ejemplo de patrón
ssh -o BatchMode=yes USUARIO@192.168.1.20 'comando a ejecutar en remoto'
```

### 5.1 Descubrimiento del equipo

```bash
# mDNS: encuentra el host por nombre aunque cambie la IP
avahi-browse -art | grep -i <hostname>
getent hosts remoto.local
```

### 5.2 Inventario de specs (un solo tiro)

```bash
ssh remoto '
  echo "== CPU ==";   lscpu | grep -E "Model name|^CPU\(s\)|MHz"
  echo "== RAM ==";   free -h
  echo "== RAM módulos =="; sudo dmidecode -t memory | grep -E "Size|Type:|Speed|Part Number"
  echo "== DISCOS =="; lsblk -d -o NAME,SIZE,MODEL,ROTA,TRAN
  echo "== GPU ==";   lspci | grep -iE "vga|3d"
  echo "== RED ==";   lspci | grep -iE "ethernet|network"
  echo "== BOARD =="; cat /sys/class/dmi/id/{sys_vendor,product_name}
  echo "== OS ==";    hostnamectl
  echo "== TEMP ==";  sensors
  echo "== BATERÍA =="; upower -i $(upower -e | grep BAT) | grep -E "state|percentage|capacity"
'
```

---

## 6. Resultados de la prueba (WLAN)

Caso real: dos equipos CachyOS en la misma red WiFi de 5 GHz.

> **Validación multi-distro:** las ramas Debian y Fedora se probaron en
> contenedores reales (`debian:12`, `fedora:41` y **`fedora:44`**): detección de
> familia correcta, resolución del asset en la API de GitHub y descarga íntegra
> del `.deb` (24 MB) y `.rpm` (33 MB) oficiales de RustDesk 1.5.0.
>
> Probado contra ISOs reales: **Linux Mint 22.3 "Zena"** (familia debian) y
> **Fedora 44** (`Fedora-Workstation-Live-44-1.7.x86_64.iso`, familia fedora).
>
> **Fedora 44 (imagen base):** `docker.io/library/fedora:44` detecta como
> `Familia: fedora` con **dnf5 5.4.3**. Ojo: esa imagen **no trae el binario
> `hostname`** — ver [H-10](docs/hallazgos.md). El kit ya usa respaldo
> (`/proc/sys/kernel/hostname` → `uname -n`).
>
> **Imágenes mínimas (sin `systemctl`/`firewall-cmd`/`ufw`):** el diagnóstico no
> se rompe, pero tampoco puede verificar el firewall. En vez de afirmar "sin
> firewall" informa `Detectado: sin-herramientas` — ver [H-12](docs/hallazgos.md).
> Para probar el flujo completo de firewall/sshd hace falta una ISO en VM
> (probado en Fedora 44 KDE real) o un contenedor con systemd.

### Equipos (ejemplo real de la prueba)

| | **Operador** | **Objetivo** |
|---|---|---|
| Tipo | Desktop | Laptop |
| CPU | AMD Ryzen 7 (8C/16T) | AMD Ryzen 5 (4C/8T) |
| RAM | 16 GiB | 8 GiB |
| GPU | AMD Vega (integrada) | AMD Vega (integrada) |
| Disco | NVMe 500 GB | SSD 120 GB + HDD 1 TB |
| Red | Ethernet | **WiFi** |
| Distro | CachyOS | CachyOS |

### Red

```
objetivo: wlan0 (WiFi 802.11ac) → router doméstico
          IP 192.168.1.16/24 · gateway 192.168.1.1
          eth0 (Ethernet) DOWN · sin cable

operador: desktop con Ethernet 192.168.1.12

ssh <objetivo> → por WLAN, latencia ~2 ms, throughput estable
```

### Verificación

```
✅ sshd: enabled + active, escuchando en :22 (IPv4 + IPv6)
✅ ufw: 22/tcp ALLOW (IPv4 + IPv6)
✅ clave del operador autorizada en authorized_keys
✅ RustDesk: captura DRM + uinput activos
✅ SSH sobre WLAN funcionando (specs, comandos, consultas)
✅ MagicDNS: `ssh <nombre>` resuelve por Tailscale (ver H-09)
```

### Hallazgos

- **WiFi es suficiente** para administración remota (SSH, logs, paquetes).
- **La IP cambia en WLAN** → usar `nombre.local` (mDNS) o reserva DHCP.
- **Firewall silencioso**: el síntoma "escucha pero da timeout" suele ser `ufw`.
- **Wayland + RustDesk**: la captura DRM es lo que habilita unattended.
- `authorized_keys` puede acumular **entradas duplicadas** si se agrega la clave
  varias veces — limpiar con `sort -u`.

---

## 7. Checklist rápido

**En el PC objetivo (primera vez) — camino rápido:**
- [ ] Copiar el kit (scp/git) al objetivo
- [ ] `./setup-remote-target.sh --check`  (diagnóstico, sin root)
- [ ] `sudo ./setup-remote-target.sh --all --key (cat ~/.ssh/id_ed25519.pub)`
  - hace: RustDesk unattended + sshd + firewall + clave
- [ ] Verificar `drm: consumer cache warmed` en los logs de RustDesk

**En el PC objetivo (primera vez) — manual, si prefieres paso a paso:**
- [ ] `paru -S rustdesk-unattended-wayland`
- [ ] `sudo pacman -S --needed openssh; and sudo systemctl enable --now sshd`
- [ ] **`sudo ufw allow 22/tcp`** ← el paso que se olvida
- [ ] Autorizar la clave del operador (ojo con `sudo` → ver 3.4)
- [ ] Verificar `drm: consumer cache warmed` en los logs de RustDesk

**Antes de cada sesión:**
- [ ] El equipo está encendido y en la misma red (WiFi o LAN)
- [ ] `ping <host>` responde
- [ ] RustDesk conecta (si hace falta GUI) · SSH entra con `BatchMode=yes`

---

## 8. Seguridad

- La **clave privada** del operador vive solo en su máquina (`chmod 600`).
- La clave autorizada da acceso **como el usuario `jp`**, nada más.
- **Revocar** = borrar la línea en `~/.ssh/authorized_keys` del objetivo.
- Con RustDesk unattended + contraseña fija, considera:
  - **IP whitelisting** en RustDesk
  - **2FA**
  - no exponer el puerto sin firewall adecuado
- En WLAN, la red puede ser menos confiable que el cable: usar SSH con clave
  (no contraseña) y considerar VPN/WireGuard si sales de la LAN local.

---

## 9. Acceso remoto fuera de la LAN (VPN)

SSH directo (`USUARIO@192.168.1.20`) solo funciona **dentro de la misma red**. Para
administrar el equipo desde otra red, usa **Tailscale** (recomendado), WireGuard o
un túnel.

### Tailscale (recomendado — sin abrir puertos)

Guía completa: [`docs/tailscale.md`](docs/tailscale.md)

```fish
# En CADA PC (misma cuenta):
sudo pacman -S --needed tailscale
sudo systemctl enable --now tailscaled
sudo tailscale up            # abre un enlace para autenticar

# Y desde cualquier red:
ssh USUARIO@100.x.y.z        # la IP Tailscale del otro PC
```

**Ventajas:** IP fija, cifrado, sin tocar el router, sin DuckDNS.

### Alternativas

Guía: [`docs/vpn-remoto.md`](docs/vpn-remoto.md)

**Regla de oro:** con VPN/túnel **no** abras el puerto 22 al internet.

| Escenario | Opción |
|---|---|
| **No quiero abrir puertos / no sé de redes** | **Tailscale** ⭐ (recomendado) |
| Puedo abrir un puerto UDP y quiero control total | **WireGuard** (hub + peers) |
| Solo SSH, tengo dominio en Cloudflare | **Cloudflare Tunnel** |
| IP pública dinámica con WireGuard | WireGuard + **DuckDNS** |

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

Si administras una **VM** (o cualquier equipo con sesión Wayland) y el
portapapeles de SPICE solo funciona en una dirección, este script lo puentea por
SSH. Ver [H-13](docs/hallazgos.md) para la explicación técnica.

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
./tests.sh                      # 119 comprobaciones locales
./tests.sh USUARIO@192.168.1.20 # + tests de hallazgos contra un host real
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
| `arch` | ID/ID_LIKE contiene `arch` (o existe `pacman`) | `pacman` | `rustdesk-unattended-wayland` vía AUR (`paru`/`yay`) |
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
