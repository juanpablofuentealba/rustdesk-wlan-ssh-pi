# INSTALAR — PC de cliente desde cero

> **Este es el runbook completo.** Va desde el PC virgen (sin sistema operativo)
> hasta dejarlo administrable de forma remota por Tailscale.
>
> Orden: **instalar el SO con WiFi → cambiar a hotspot → correr el kit.**
> ¿Por qué WiFi primero? Porque al instalar el SO necesitás internet para bajar
> paquetes, y el instalador de CachyOS maneja WiFi mejor que un hotspot recién
> creado. Después cambiás a hotspot: así probás el caso real (red móvil, CGNAT).

---

## Resumen en una pantalla

```
PENDRIVE (Ventoy)
  ├── cachyos-desktop-linux-*.iso        ← se instala desde aquí
  └── kit-rustdesk/                      ← esto se copia al PC instalado
        ├── INSTALAR.md                  ← este archivo
        ├── setup-remote-target.sh       ← RustDesk + sshd + firewall + Tailscale
        ├── rustdesk-password.sh         ← contraseña permanente de RustDesk
        ├── inventory.sh                 ← ficha de specs del cliente
        ├── tests.sh                     ← verificación
        └── operador.pub                 ← tu clave pública (la pone make-kit.sh --with-key)
```

> **OJO con `operador.pub`:** **NO está en el repositorio** (está en
> `.gitignore`). Solo aparece dentro del kit si lo empaquetás con
> `./make-kit.sh --with-key` (toma `~/.ssh/id_ed25519.pub`). Si clonás el repo
> directo (`git clone`), **no vas a encontrarla**: pasá tu clave por parámetro
> (`--key "$(cat ~/.ssh/id_ed25519.pub)"`) o empaquetá el kit con `--with-key`.

**Flujo:**
1. Arrancar el pendrive → instalar CachyOS **con WiFi**
2. Reiniciar en el sistema instalado → **cambiar a hotspot** del teléfono
3. Copiar `kit-rustdesk/` del pendrive al PC
4. Correr el kit siguiendo los pasos de abajo
5. Verificar y entregar al cliente

---

## ANTES DE SALIR (en tu equipo operador)

- [ ] **Pendrive listo**: Ventoy + ISO de CachyOS + la carpeta `kit-rustdesk/`
- [ ] **Tu clave pública** incluida en el kit (`operador.pub`) — se agrega con
      `./make-kit.sh --with-key`; el repo no la trae
- [ ] **Auth key de Tailscale** del cliente (modelo B):
      **https://login.tailscale.com/admin/settings/keys**
      (admin → Settings → pestaña **Keys** → *Generate auth key*)
      La key **no se genera en el equipo**: se crea en esa página web, con tu
      cuenta, desde cualquier navegador (el celular sirve), y se copia.
      → Reusable: **NO** · Ephemeral: **NO** · Expiry: **1 día**
      (si es para pruebas tuyas, Reusable: SÍ)
      Si todavía no la tenés: usá `--tailscale-luego` y uní después con
      `./unir-tailscale.sh` (no bloquea la instalación)
- [ ] **Contraseña permanente de RustDesk** que le vas a poner a ese equipo
- [ ] **Contraseña de sudo** del usuario del cliente (la que elijas al instalar)

---

## FASE 1 — Instalar el sistema operativo

1. Conectá el pendrive al PC objetivo y arrancá desde él (tecla de boot: F12,
   F9, ESC… según el equipo).
2. En el menú de Ventoy, elegí `cachyos-desktop-linux-*.iso`.
3. Instalá CachyOS normalmente:
   - **Conectá el WiFi en el instalador** (arriba a la derecha suele estar el
     selector de red). Sin red no se pueden bajar los paquetes.
   - Usuario: el que va a usar el cliente (p. ej. `jp` o el nombre del cliente)
   - **Anotá la contraseña de sudo**: la vas a necesitar para el kit
4. Al terminar: reiniciar SACANDO el pendrive.

---

## FASE 2 — Cambiar a hotspot

Ya en el escritorio recién instalado:

1. En el teléfono: activá **compartir datos / hotspot WiFi**
2. En el PC: conectar a esa red
3. Verificá que hay internet:

```bash
curl -s https://api.ipify.org; echo
# debe devolver una IP pública (del operador móvil)
```

> **Por qué cambiar a hotspot:** así el equipo queda detrás del **CGNAT de un
> operador móvil**, que es exactamente la situación de un cliente en su casa
> sin puertos abiertos. Si el kit funciona acá, funciona en cualquier cliente.

---

## FASE 3 — Copiar el kit desde el pendrive

```bash
# 1. enchufá el pendrive y encontrá dónde se montó
lsblk -o NAME,SIZE,LABEL,MOUNTPOINT | grep -i ventoy

# 2. montarlo (si no se montó solo)
udisksctl mount -b /dev/sdX1        # reemplazá sdX1 por tu partición

# 3. copiar el kit al home
cp -r /run/media/$USER/Ventoy/kit-rustdesk ~/kit
cd ~/kit
```

> **Alternativa sin pendrive**: clonar del repo
> `git clone https://github.com/juanpablofuentealba/rustdesk-wlan-ssh-pi`

---

## FASE 4 — Instalar el kit

### Paso 1 — Diagnóstico (no cambia nada)

```bash
./setup-remote-target.sh --check
```

Anotá: familia de distro, si hay firewall, si RustDesk ya está instalado y el
tipo de sesión (Wayland/X11).

### Paso 2 — Elegir la contraseña de RustDesk y anotarla

Elegí la contraseña **permanente** de RustDesk para este equipo. Guárdala en tu
gestor: la vas a necesitar cada vez que te conectes.

**Sobre el paquete de RustDesk:** el kit instala la build con **capturador DRM**
(`libdrmtap.so`), que es lo que permite capturar la pantalla en Wayland sin
depender del portal. Esa build solo existe como `.deb` en el release oficial de
RustDesk, así que el kit lo descarga, **verifica su sha256** y lo extrae a mano.
Funciona igual en Arch, Fedora y Debian, y **no necesita AUR ni compilar**.

### Paso 3 — Aplicar TODO con un solo comando

```bash
sudo ./setup-remote-target.sh --all \
  --key "$(cat operador.pub)" \
  --authkey 'tskey-auth-XXXX'
```

> Si no tenés `operador.pub` (porque clonaste el repo en vez de empaquetar el
> kit), usá tu clave directamente:
> ```bash
> --key "$(cat ~/.ssh/id_ed25519.pub)"
> ```
```

Qué hace `--all`:

| Módulo | Qué hace |
|---|---|
| `--rustdesk` | Instala RustDesk **unattended** (DRM + uinput) y lo habilita |
| `--ssh` | Instala y habilita `sshd` + abre el firewall solo |
| `--tailscale` | Instala Tailscale y une el equipo con la auth key |

> **¿Hay que instalar `paru` a mano? NO.** El kit lo resuelve solo, en cascada:
>
> 1. **`pacman -S paru`** desde el repo binario (CachyOS lo tiene en `cachyos`,
>    Arch en `extra`) — **sin compilar**, tarda segundos.
> 2. Si no estuviera en ningún repo, compila `paru-bin` desde AUR (necesita
>    `git` + `base-devel`, y tarda unos minutos).
> 3. Y para instalar RustDesk, **la vía del `.deb` con DRM ni siquiera usa paru**.
>
> Es decir: en un CachyOS recién instalado, `paru` puede no existir y no pasa
> nada. El kit lo pone.

**Dependencias que el kit instala solo:** `curl`, `ar`+`tar` (vienen en el
sistema), `python3`+PyNaCl, `openssh-server`, `tailscale`, `paru` y RustDesk con
DRM. Comprobalo todo con `./setup-remote-target.sh --check`.

Si igualmente preferís el AUR (y tenés paru/yay):

```bash
paru -S --needed rustdesk-unattended-wayland
```

### Paso 4 — Contraseña permanente de RustDesk

Esto es **imprescindible**: sin contraseña permanente no hay acceso desatendido
(cada conexión pediría aceptación manual). RustDesk **no tiene un flag de CLI**
para fijarla — ver H-15 en `docs/hallazgos.md`.

```bash
# SUDO_PASS= (vacío) si tu sudo no pide contraseña; si pide, poné la clave
SUDO_PASS='<clave-sudo>' ./rustdesk-password.sh install "$USER@localhost" '<password>'
```

El script genera el hash correcto (SHA256 + secretbox con el machine-id) y lo
escribe en la configuración de root y del usuario.

### Paso 5 — Verificar

```bash
./tests.sh "$USER@localhost"
```

Y comprobá que la captura DRM arrancó bien:

```bash
tail -20 ~/.local/share/logs/RustDesk/server/rustdesk_rCURRENT.log | grep -i drm
# debe aparecer: drm: consumer cache warmed (N displays) at startup
```

Si en su lugar ves `Wayland portal handshake failed`, falta el capturador DRM
(ver H-14 en `docs/hallazgos.md`): en Arch reinstalá
`rustdesk-unattended-wayland`; en Fedora usá
`sudo ./install-rustdesk-unattended-fedora.sh`.

### Paso 6 — Ficha del cliente

```bash
mkdir -p fichas
./inventory.sh | tee "fichas/$(hostname)-$(date +%F).txt"
```

Guardá este archivo **fuera del repo público** (contiene datos del cliente).

---

## FASE 5 — Entregar al cliente

- [ ] Mostrarle que su PC aparece en **su** panel de Tailscale
      (`https://login.tailscale.com/admin/machines`)
- [ ] Explicarle que **puede revocarte el acceso** cuando quiera:
      Machines → su equipo → **Disable**
- [ ] Dejarle la **contraseña de RustDesk** por escrito (es suya)
- [ ] Confirmar que el equipo se conecta solo: reiniciarlo y ver que vuelve
      online sin intervención (ver H-01 y H-02 en `docs/hallazgos.md`).
      El script `reboot-remoto.sh` hace la prueba completa (ver abajo).

---

## Prueba desde tu equipo operador

```bash
# 1. ¿está en la tailnet?
tailscale status | grep <hostname>

# 2. ¿la ruta es directa o por relay?
tailscale ping <hostname>

# 3. ¿entra por SSH?
ssh -o BatchMode=yes USUARIO@<hostname> 'hostname'

# 4. verificación completa de acceso fuera de la LAN
./verify-offlan.sh <hostname>
```

> **OJO con el paso 4:** la prueba solo vale si operador y objetivo salen por
> **IPs públicas distintas**. Si tienen la misma (misma casa), la ruta es la LAN
> y no prueba nada. Comprobá: `curl -s https://api.ipify.org` en cada equipo.
> El caso limpio: operador en el **hotspot 4G** y objetivo en la casa.

### Prueba de reinicio (la definitiva de unattended)

Deja una regla **NOPASSWD acotada** (solo `reboot`/`poweroff`, no todo sudo),
reinicia y espera que el equipo vuelva **solo**:

```bash
# una vez: habilita la regla (pide la clave de sudo del cliente)
./reboot-remoto.sh --host USUARIO@<hostname> --enable

# luego: reinicia y verifica la vuelta
./reboot-remoto.sh --host USUARIO@<hostname> --all
```

Debe volver con **`boot_id` NUEVO** (no una simple reconexión) y los cuatro
servicios `active` + `enabled`: `rustdesk`, `sshd`, `tailscaled`, `ufw`.

Rollback (dejar el equipo como estaba):

```bash
./reboot-remoto.sh --host USUARIO@<hostname> --disable
```

Detalle del bloqueo que resuelve (sudo + polkit): **H-27** en
`docs/hallazgos.md`.

Y por **RustDesk**: conectate al ID del equipo con la contraseña permanente.
Si al conectar da `os error 104`, desactivá audio/portapapeles en la GUI
(es el H-19, no un fallo del acceso).

---

## Si algo falla

| Síntoma | Causa probable | Solución |
|---|---|---|
| `Wayland portal handshake failed` | falta `libdrmtap` (H-14) | Arch: `rustdesk-unattended-wayland` · Fedora: `install-rustdesk-unattended-fedora.sh` |
| Pide aceptación en cada conexión | sin contraseña permanente (H-15) | `./rustdesk-password.sh install` |
| `Conexión reinicializada (os error 104)` | audio/portapapeles en bucle (H-19) | desactivá audio y portapapeles en la GUI antes de conectar |
| SSH no entra | falta tu clave o el firewall | `sudo ./setup-remote-target.sh --ssh --key "$(cat operador.pub)"` (o `~/.ssh/id_ed25519.pub` si clonaste el repo) |
| Tailscale no une | auth key vencida o mal copiada | generá otra; debe empezar con `tskey-` |
| `tailscale ping` va por LAN | seguís en la misma red | es lo esperado en pruebas; para el caso real usá otra red |

Todos los hallazgos con su explicación completa están en `docs/hallazgos.md`.

---

## Verificar integridad del kit

```bash
sha256sum -c MANIFEST.sha256
```

---

## Mantenimiento a largo plazo (`update.sh`)

RustDesk y Tailscale sacan versiones nuevas seguido. Para no tener que volver
físicamente a la casa del cliente, el kit trae `update.sh`:

```bash
sudo ./update.sh              # sistema + RustDesk + Tailscale
./update.sh --check           # solo consultar si hay pendientes (sin root)
./update.sh --dry-run         # simulacro: muestra qué haría
./update.sh --yes             # sin confirmaciones (cron)
```

Funciona en las tres familias (pacman / apt / dnf). En Debian/Ubuntu reinstala
el **`.deb` oficial** de RustDesk (última release de GitHub, arquitectura
detectada) y **reinicia el servicio** al terminar.

Desde el PC operador:

```bash
make HOST=USUARIO@<hostname> update       # copia update.sh al host
make HOST=USUARIO@<hostname> update-now   # lo ejecuta (--yes, vía sudo -n)
```

Automatizarlo en el cron de root del objetivo (semanal):

```bash
0 4 * * 1  /root/kit/update.sh --yes >/var/log/kit-update.log 2>&1
```
