# Estado de la sesión — trabajo con Fedora 44

> **Nota de continuidad.** Este documento existe para poder retomar el trabajo
> aunque se pierda la sesión del agente. Registra el entorno de prueba, lo
> verificado, lo que quedó pendiente y cómo reproducirlo.
>
> Última actualización: sesión de trabajo sobre Fedora 44 (commits `558483d` →
> `d7df95b`).

---

## Entorno de prueba real

| Elemento | Valor |
|---|---|
| **Host operador** | CachyOS, Wayland (`WAYLAND_DISPLAY=wayland-1`), KDE |
| **Guest objetivo** | Fedora Linux 44 (KDE Plasma Desktop Edition) |
| **Kernel guest** | `6.19.10-300.fc44.x86_64` |
| **Gestor guest** | `dnf5 5.4.1.0` |
| **Sesión guest** | **Wayland** (`kwin_wayland`) — NO X11 |
| **Login guest** | `plasmalogin` (Fedora 44 KDE **no usa SDDM**) |
| **IP guest** | `192.168.122.11` (red NAT de libvirt) |
| **Acceso** | `ssh jp@192.168.122.11` con clave `pi-agent@MSI` (sin contraseña) |
| **sudo en guest** | **pide contraseña** (bloquea automatización) |

### Contenedores de prueba usados

```
docker.io/library/fedora:44     # imagen base mínima
docker.io/library/fedora:41     # dnf5 5.2.17
docker.io/library/debian:12     # apt 2.6.1
```

### Hardware de la VM

| Campo | Valor |
|---|---|
| CPU | AMD Ryzen 7 5700G — 4 núcleos (QEMU) |
| RAM | 3,8 GiB |
| Disco / | 28 GiB (5,2 GiB usados, 19%) |
| GPU | Red Hat Virtio 1.0 GPU |

Volcado completo guardado en el repo:

- [`inventarios/fedora44-kde.md`](inventarios/fedora44-kde.md) — diagnóstico + specs
- [`inventarios/fedora44-kde.json`](inventarios/fedora44-kde.json) — specs en JSON

---

## Hallazgos de esta sesión (todos con test de regresión)

| ID | Título | Verificado en |
|---|---|---|
| **H-10** | Fedora 44 (imagen base) no trae el binario `hostname` | `fedora:44` |
| **H-11** | En Fedora 44 KDE la "última sesión" de `loginctl` no es la gráfica | Fedora 44 KDE real |
| **H-12** | Imágenes mínimas sin `systemctl`: "sin firewall" era falso | `fedora:44`, `debian:12` |
| **H-13** | El portapapeles SPICE funciona en una sola dirección en Wayland | Fedora 44 KDE + CachyOS |
| **H-14** | El `.rpm`/`.deb` estándar NO trae `libdrmtap`: en Wayland sin usuario falla la captura (portal XDG) | Fedora 44 KDE Wayland |
| **H-15** | Sin contraseña permanente, unattended es imposible (y el campo `password = ''` engaña) | Fedora 44 |
| **H-16** | Con solo el greeter, el log de captura NO está donde el kit lo busca | Fedora 44 Wayland |
| **H-17** | RustDesk 1.5.0 no tiene CLI de conexión (es GUI pura) | CachyOS + Fedora 44 |
| **H-18** | El server se ancla a la sesión gráfica de seat0 (incluido el greeter) | Fedora 44 Wayland |

Detalle completo en [`hallazgos.md`](hallazgos.md).

### Punto 1 resuelto: unattended en Wayland sobre el greeter

Cierre del pendiente #1 (RustDesk unattended en la VM). Secuencia verificada:

1. **H-15** — `RustDesk.toml` tenía `password = ''` → sin contraseña permanente.
   Se fijó con `rustdesk-password.sh` (reproduce el formato del código fuente).
2. **H-14** — El `.rpm` oficial no trae `libdrmtap` → la captura caía al portal y
   fallaba con *"Error en la captura de pantalla de Wayland… XDG Desktop Portal"*.
   Se instaló el `.deb` oficial `rustdesk-unattended-wayland` con
   `install-rustdesk-unattended-fedora.sh` (sha256 verificado, portable a Fedora).
3. **H-18** — Tras instalar, el log muestra la evidencia:
   `drm: consumer cache warmed (1 displays) at startup`.

La contraseña de prueba se fija con `rustdesk-password.sh install`. **No se
escribe en este repo** (es un secreto operativo): usar una distinta en cada
cliente.

### Confirmación visual: ✅ CONECTADO

Prueba manual de extremo a extremo **exitosa** (27 oct 2026). El operador se
conectó desde CachyOS (`192.168.1.12`) y entró a la VM de inmediato.

Evidencia en el log del servidor:

```
Connection opened from 192.168.1.12:38837
Start cm
libdrmtap loaded: /usr/lib/rustdesk/libdrmtap.so.0 (v0.5.8)
drm: cursor calibration for display 0 (Virtual-1): Ok(...)
new encoder: VPX(width: 1280, height: 800, codec: VP8, quality: 0.67)
```

Y del lado del sistema: conexión TCP `ESTAB` y el `--server` al 33 % de CPU
(capturando y codificando).

### H-19 — `os error 104` al conectar: portapapeles/audio en bucle sin contexto gráfico

**Verificado:** ✅ (Fedora 44, 27 oct 2026)

En un intento previo el cliente mostró *"Conexión reinicializada por la máquina
remota (os error 104)"*. El log del servidor mostró que la conexión **sí había
entrado** y la captura DRM funcionaba; el corte venía de un bucle de servicios:

```
ERROR [src/server/service.rs:308] Error of audio service: No such file or directory (os error 2)
ERROR [src/server/service.rs:308] Error of clipboard service: arboard: X11 server connection timed out because it was unreachable
WARN  [libs/scrap/src/wayland/display.rs:228] no usable wayland socket in /run/user/1000 (none present)
```

**Causa:** `arboard` (portapapeles) insiste en conectar a X11 y expira; el
audio busca un socket de PipeWire inexistente. Con el server corriendo en un
contexto sin sesión gráfica completa, ambos reintentan sin parar.

**Mitigación desde el operador:** desactivar **audio** y **portapapeles** en la
GUI de RustDesk antes de conectar (`disable_audio` / `disable_clipboard` son
opciones del cliente, no del servidor).

**Nota:** un intento fallido anterior coincidió además con un error transitorio
`Failed to load config ... RustDesk2.toml: Bad TOML data` al reescribirse la
config. Conviene validar el TOML tras editarlo a mano:

```fish
python3 -c "import tomllib; tomllib.load(open('/root/.config/rustdesk/RustDesk2.toml','rb'))"
```

---

## Herramientas añadidas

| Archivo | Qué |
|---|---|
| `clip-vm.sh` | Puente de portapapeles host↔VM por SSH (`get` / `put` / `show`) |

Comandos:

```fish
./clip-vm.sh get     # portapapeles de la VM → host
./clip-vm.sh put     # portapapeles del host → VM
./clip-vm.sh show    # qué hay en el portapapeles de la VM

# otro destino
CLIP_VM=jp@10.0.0.5 ./clip-vm.sh get
```

---

## Trampas verificadas (importante para no repetirlas)

### 1. `wl-copy --paste-once` corrompe el portapapeles

Verificado en `wl-clipboard 2.3.0` (CachyOS):

```
printf 'X' | wl-copy              ; wl-paste   →  X     ✅
printf 'X' | wl-copy --paste-once ; wl-paste   →  1     ❌
```

Deja el carácter `1` en vez del contenido. **No usar ese flag.**

### 2. `wl-copy` se queda residente

Sirve el portapapeles desde un proceso en segundo plano:

- En **primer plano** por SSH → el comando **no termina nunca** (el SSH espera).
- Con `&` simple → **no hereda el stdin**.

Solución aplicada en `clip-vm.sh`:

```bash
nohup wl-copy < "$f" >/dev/null 2>&1 &
disown 2>/dev/null || true
```

### 3. `BatchMode=yes` es obligatorio

Sin él, SSH cae a pedir contraseña y el texto `usuario@host's password:` acaba
**dentro del portapapeles**, contaminando el resultado. Fue exactamente lo que
pasó en la primera prueba.

### 4. El portapapeles del guest puede tener contenido viejo

Sin gestor de portapapeles activo, `wl-paste` devuelve el último texto aunque no
haya proceso vivo. Verificar con `clip-vm.sh show` antes de concluir que "no
funciona".

---

## Por qué NO se cambió la VM a X11

Se evaluó cambiar el guest a sesión X11 para tener copy-paste nativo. **Se
descartó** por el coste:

```
$ dnf install --assumeno plasma-workspace-x11 kwin-x11
 Instalando:      25 paquetes
 Modernizando:   133 paquetes      ← actualización completa de KDE
 Reemplazando:   133 paquetes
 Descarga:       313 MiB
```

Plasma está en `6.6.4` y el paquete X11 en `6.7.5` (`updates`), así que instalar
X11 arrastra una actualización completa de KDE.

**Además:** en Fedora 44 KDE **no existe `sddm`** (usa `plasmalogin`), y
`/usr/share/xsessions/` está **vacío** por defecto. No es un simple "elegir
sesión X11 en el login" como en otras distros.

**Decisión:** quedarse en Wayland con `clip-vm.sh`, que funciona en ambas
direcciones.

---

## Comandos de referencia

### Verificar el entorno

```fish
# sesión gráfica del guest (la que tiene seat, no la última)
ssh jp@192.168.122.11 'loginctl show-session (loginctl list-sessions --no-legend | awk "\$4 != \"-\" {print \$1}" | head -1) -p Type --value'

# diagnóstico del kit en el guest
ssh jp@192.168.122.11 'bash -s -- --check' < setup-remote-target.sh

# inventario del guest
./inventory.sh jp@192.168.122.11
```

### Probar el portapapeles

```fish
# poner contenido en el guest (para probar el get)
ssh jp@192.168.122.11 'pkill -u (id -u) -x wl-copy 2>/dev/null; sleep 0.3; printf "TEST-%s" (date +%H%M%S) | wl-copy & sleep 1; echo ok'

./clip-vm.sh get
wl-paste
```

### Suite de pruebas

```fish
./tests.sh          # 119 OK / 0 fallos
./verify-docs.sh    # 31 OK / 0 fallos
```

---

## Modelo de producto (aclarado por el autor)

Es importante para no confundir el alcance del kit:

| Pieza | Dónde vive | Para quién |
|---|---|---|
| **CachyOS** | PC del cliente | El producto que se ofrece |
| **RustDesk + sshd + Tailscale** | PC del cliente | Infraestructura de acceso remoto |
| **Clave del operador** | PC del cliente (en `authorized_keys`) | Para que el técnico entre |
| **`pi` + modelo (DeepSeek pago)** | **SOLO en el PC del operador** | Herramienta de trabajo del técnico |

**`pi` NO se instala en el PC del cliente.** Motivo: no incluye modelos gratuitos
fiables, así que requeriría que cada cliente pague un modelo (o que el operador
lo pague por todos). El cliente **no necesita** el agente: el operador lo usa
**desde su propio equipo**, alcanzando el PC del cliente por SSH.

**Contexto del autor:** 0 clientes actualmente. El trabajo es para *construir la
capacidad de dar mantención remota* y conseguir el primer cliente. El autor es
su propio cliente 1 y ofrece **CachyOS** como distro principal (es donde el kit
funciona mejor: el parche DRM de RustDesk unattended es específico de Arch/AUR).

### Qué significa esto para el empaquetado

Con 0 clientes, empaquetar (`.deb`/`.rpm`/`PKGBUILD`) y hacer una GUI es
**prematuro**: se construiría la fábrica antes del primer pedido.

Orden sensato:

1. Probar el kit de punta a punta **como si la VM fuera el PC de un cliente**.
2. Resolver el **acceso fuera de la LAN** (Tailscale) — es lo que permite dar
   mantención después sin volver al domicilio.
3. ~~Preparar un **kit de instalación**~~ — **RESUELTO** (`make-kit.sh` +
   `INSTALAR.md`, con manifiesto de integridad).
4. **El primer cliente real** — ahí se ve qué falta de verdad.

El paquete y la GUI tienen sentido **después** del primer cliente, cuando se sepa
qué se necesita realmente.

---

### Punto 2 resuelto: Tailscale (modelo B) en la VM

Tailscale unido a la tailnet y verificado. **Instalado desde los repos oficiales
de Fedora** (`tailscale 1.98.8-1.fc44`), sin repos externos.

| Dato | Valor |
|---|---|
| IP Tailscale del guest | `100.x.y.z` |
| Hostname en la tailnet | `<hostname>` |
| MagicDNS | `fedora.<tailnet>.ts.net` |
| Operador (esta máquina) | `100.a.b.c` (`<operador>`) |

Evidencia:

```
$ tailscale ping -c 3 100.x.y.z
pong from fedora (100.x.y.z) via 192.168.122.11:41641 in 1ms

$ ssh -o BatchMode=yes jp@100.x.y.z 'hostname'
fedora

$ getent hosts fedora
100.x.y.z   fedora.<tailnet>.ts.net
```

Configuración aplicada (`tailscale up --auth-key=... --accept-dns=false`):

```json
{ "WantRunning": true, "RouteAll": false, "CorpDNS": false }
```

- `RouteAll: false` → **no** enruta todo el tráfico (no es una VPN completa).
- `CorpDNS: false` → respeta el DNS local; MagicDNS igual resuelve nombres.
- `tailscaled` queda `enabled` (sobrevive el reinicio, ver H-01).

**Ojo con el alcance de la prueba:** el `tailscale ping` reportó
`via 192.168.122.11`, es decir, ahora mismo va por la **ruta LAN** (operador y VM
están en la misma máquina física). Que la IP `100.x` funcione está verificado;
la ruta **fuera de la LAN** requiere probar desde otra red.

El flag `--tailscale` se **integró al kit** durante esta sesión (antes no existía):

```fish
sudo ./setup-remote-target.sh --tailscale --authkey "tskey-auth-..."
```

---

## Pendiente / ideas para retomar

Ninguna de estas está empezada; son opciones, no deuda técnica:

1. ~~**RustDesk unattended en la VM**~~ — **RESUELTO** (ver H-14/H-15/H-18).
   Falta solo la confirmación visual manual. Herramientas nuevas:
   `install-rustdesk-unattended-fedora.sh`, `rustdesk-password.sh`.
2. **`clip-vm.sh` sin gestor de portapapeles** — probar en un guest sin Klipper
   (p. ej. Fedora KDE mínimo) y endurecer el script si se cuelga.
3. ~~**Tailscale en la VM**~~ — **RESUELTO** (IP `100.x.y.z`). El kit ya
   trae `--tailscale`/`--authkey` y lo diagnostica en `--check`. Falta probar
   la ruta **fuera de la LAN** desde otra red.
4. ~~**`inventory.sh` en QEMU**~~ — **RESUELTO** (H-20). En QEMU el
   `chassis_type` de SMBIOS es `1` ("Other"), así que caía en `desconocido`.
   Ahora `inventory.sh` consulta `systemd-detect-virt` en el objetivo y
   clasifica como `vm`. Verificado: VM → `vm`, PC real → `desktop`.
5. **X11 en el guest** — solo si se quiere copy-paste nativo; ver el coste
   arriba.

---

## Nota sobre el reporte de OpenCode/DeepSeek

Se revisó un reporte generado por OpenCode + DeepSeek sobre este trabajo. Todas
sus afirmaciones resultaron **correctas** al verificarlas (commit, 165 líneas,
108 tests, flujo `get`/`put`).

**Pero no era una auditoría independiente:** era un reformateo de la salida del
propio agente que hizo el trabajo. Conservaba incluso frases en primera persona
del autor original ("yo te lo recomendé al principio y era mal consejo"). Un
revisor que solo reformatea no detecta los errores del autor — y en esta sesión
hubo uno real (`--paste-once`), que solo se encontró porque el usuario insistió
en que no funcionaba.

**Lección:** verificar las afirmaciones contra el repo real, no contra el
reporte. Los hashes y conteos son lo único barato de comprobar objetivamente.
