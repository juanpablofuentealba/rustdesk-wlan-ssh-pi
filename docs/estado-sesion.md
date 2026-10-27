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

Detalle completo en [`hallazgos.md`](hallazgos.md).

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
./tests.sh          # 113 OK / 0 fallos
./verify-docs.sh    # 31 OK / 0 fallos
```

---

## Pendiente / ideas para retomar

Ninguna de estas está empezada; son opciones, no deuda técnica:

1. **RustDesk unattended en la VM** — probar el flujo visual completo
   (`--rustdesk`), que es justo el caso Wayland donde importa el parche DRM.
   Requiere `sudo` en el guest (pide contraseña).
2. **`clip-vm.sh` sin gestor de portapapeles** — probar en un guest sin Klipper
   (p. ej. Fedora KDE mínimo) y endurecer el script si se cuelga.
3. **Tailscale en la VM** — extender el kit al acceso fuera de la LAN.
4. **`inventory.sh` en QEMU** — mapear el chasis virtual a `vm` en vez de
   `desconocido` (hoy lee `/sys/class/dmi/id/chassis_type`, que en QEMU no da
   un tipo estándar).
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
