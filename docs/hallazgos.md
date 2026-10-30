# Hallazgos verificados (pruebas reales)

Registro de comportamientos **comprobados en máquinas reales**, no supuestos.
Cada hallazgo indica cómo se verificó, para que puedas reproducirlo o refutarlo.

> Última actualización: 2026-10-29
> Equipos de prueba: desktop (operador) + laptop **HP** Ryzen 5 (objetivo),
> ambos CachyOS/Wayland

---

## H-01 — Tailscale sobrevive el reinicio

**Verificado:** ✅

Tras `sudo reboot` en el equipo objetivo:

```
tailscaled   enabled=enabled  active=active
IP Tailscale: 100.201.202.203   (MISMA que antes del reinicio)
Conexión: active; direct 192.168.1.x:41641
```

**Conclusión:** la IP de Tailscale es **estable entre reinicios**. No hay que
reconfigurar nada. La conexión vuelve a ser directa (no relay).

---

## H-02 — El servicio RustDesk arranca solo, pero depende de la sesión gráfica

**Verificado:** ✅

Tras el reinicio, `rustdesk.service` arrancó a los pocos segundos
(`Active: active (running) since ... 18:35:39`). **Pero** el proceso servidor
arrancó como el **usuario del greeter**:

```
sudo -E XDG_RUNTIME_DIR=/run/user/957 -u plasmalogin ... rustdesk --server
```

Es decir: el equipo quedó en la **pantalla de login** y RustDesk corrió en el
*login screen*, **sin sesión de escritorio de usuario**.

**Consecuencia:** sin sesión iniciada, **no hay captura DRM** (`drm: consumer
cache warmed` no aparece). Si te conectas en ese estado, ves la pantalla de
login, no el escritorio.

**Solución de facto:** que haya una sesión de escritorio iniciada. En la prueba,
al iniciar sesión como el usuario, RustDesk pasó a correr como el usuario y la
captura DRM arrancó de inmediato:

```
18:38:44  UInput keyboard created
18:38:44  drm: consumer cache warmed (1 displays) at startup
```

---

## H-03 — `allow-logon-screen-password` existe, pero Wayland login screen NO está soportado

**Verificado:** ⚠️ (con matiz crítico)

La opción `allow-logon-screen-password` **existe** en el binario:

```
$ strings -a /usr/share/rustdesk/lib/librustdesk.so | grep allow-logon-screen-password
allow-logon-screen-password
```

Aparece en el contexto del **servidor** (`librustdesk::server::connection:src/server/connection.rs`),
junto a otras opciones de permisos (`enable-remote-printer`, `enable-camera`,
`enable-terminal`) y con el mensaje:

```
Permanent password accepted via logon-screen fallback
```

**PERO** — el mismo binario contiene, de forma explícita:

```
Wayland login screen is not supported
```

**Interpretación (verificada contra el binario):**

| Entorno de la pantalla de login | ¿Soportado? |
|---|---|
| **X11** (login screen en X) | Sí — `allow-logon-screen-password` funciona |
| **Wayland** (login screen en Wayland) | **No** — el binario lo declara no soportado |

**Implicación práctica:** en CachyOS/KDE con SDDM en **Wayland** (el caso de
estos equipos), controlar la **pantalla de login** por RustDesk **no está
soportado**. No es que falte una opción: la funcionalidad no existe para Wayland.

**Verificación específica en el equipo de prueba** (plasmalogin de KDE, Wayland):

```
$ ps -eo cmd= | grep plasmalogin
/usr/bin/plasmalogin
/usr/lib/plasmalogin-helper ... --start ... startplasma-wayland ... --user jp

$ pgrep -a Xorg
(sin Xorg)          ← login screen en Wayland, no X11
```

Como el greeter (`plasmalogin`) corre en **Wayland**, `allow-logon-screen-password`
no tendría efecto en este equipo. **No se recomienda activarla aquí.**

> **Nota:** esto es coherente con el hecho de que la captura DRM de este paquete
> depende de que exista un **scanout** de una sesión real. En la pantalla de
> login Wayland, el pipeline del escritorio del usuario aún no está activo.

---

## H-04 — La captura DRM vuelve sola al iniciar sesión

**Verificado:** ✅

Al iniciar sesión gráfica (Wayland) tras el reinicio:

```
sesión: Type=wayland, Active=yes, State=active
log:    UInput keyboard created
log:    drm: consumer cache warmed (1 displays) at startup
```

**Conclusión:** no hay que reiniciar nada a mano. En cuanto hay sesión de
escritorio, RustDesk reengancha la captura DRM y el control completo.

---

## H-05 — Tailscale usa conexión directa (no relay) entre los dos equipos

**Verificado:** ✅

```
$ tailscale status
100.x  operador  ...  -
100.x  objetivo  ...  active; direct 192.168.1.x:41641, tx ... rx ...

$ tailscale ping <objetivo>
pong from <objetivo> (100.x.y.z) via 192.168.1.x:41641 in 2ms
```

**Conclusión:** NAT traversal funciona; la latencia es de ~1 ms. No está pasando
por un servidor DERP.

---

## H-06 — `sshd` sobrevive el reinicio (si está `enabled`)

**Verificado:** ✅

```
sshd  enabled=enabled  active=active
```

Tras el reinicio, `ssh usuario@100.x.y.z` funcionó sin intervención. Requisito:
`sudo systemctl enable sshd` (no basta con `start`).

---

## H-07 — `hostname -I` no existe en CachyOS

**Verificado:** ✅ (bug real encontrado durante el desarrollo)

```
$ hostname -I
hostname: invalid option -- 'I'
```

El `hostname` de estos sistemas (inetutils) no soporta `-I`. **Use `ip` para
obtener la IP local:**

```fish
ip -4 route get 1.1.1.1 | grep -oP 'src \K[0-9.]+'
```

---

## H-08 — `strings | grep -q` con `set -o pipefail` da falso negativo

**Verificado:** ✅ (bug encontrado en `verify-docs.sh`)

Con `set -o pipefail`, esta comprobación **falla aunque el grep encuentre**:

```bash
strings -a binario | grep -q "patrón"   # ← devuelve 141 (SIGPIPE)
```

Causa: `grep -q` cierra el pipe al primer match; `strings` recibe SIGPIPE y
termina con código 141; `pipefail` propaga ese error.

**Solución:** capturar a variable primero.

```bash
data="$(strings -a binario 2>/dev/null || true)"
grep -q "patrón" <<<"$data" && echo "encontrado"
```

---

## Resumen de implicaciones para el flujo con clientes

| Situación tras un reinicio | Comportamiento verificado |
|---|---|
| Equipo objetivo reinicia | Tailscale y sshd vuelven solos ✅ |
| Nadie inicia sesión | RustDesk corre pero **sin escritorio** (login screen) ⚠️ |
| Login screen en **Wayland** | **No controlable** por RustDesk (`Wayland login screen is not supported`) |
| Alguien inicia sesión | Captura DRM y control vuelven solos ✅ |

**Comprobación rápida del tipo de login screen:**

```fish
# En el equipo objetivo:
ps -eo cmd= | grep -E 'plasmalogin|sddm|gdm|lightdm'
pgrep -a Xorg && echo 'login screen X11 → allow-logon-screen-password aplica' \
              || echo 'login screen Wayland → allow-logon-screen-password NO aplica'
```

**Recomendación para equipos remotos que reinician solos:**

- Si el cliente puede iniciar sesión (o dejar la sesión abierta), todo funciona.
- **No** confíes en controlar la pantalla de login por RustDesk en Wayland.
- Evita "autologin" del sistema salvo que el riesgo de seguridad esté asumido.
- El acceso **SSH por Tailscale sí funciona** aunque no haya sesión gráfica:
  puedes administrar el equipo por terminal en cualquier caso.

---

## Cómo reproducir estas pruebas

```fish
# 1. Estado previo
ssh objetivo 'tailscale ip -4; systemctl is-enabled tailscaled sshd rustdesk'

# 2. Reiniciar el objetivo
ssh objetivo 'sudo reboot'

# 3. Esperar y verificar reconexión (desde el operador)
ssh objetivo 'uptime -p'                    # debe responder
ssh objetivo 'tailscale status | head -3'
ssh objetivo 'systemctl is-active tailscaled sshd rustdesk'

# 4. Comprobar captura DRM (solo si hay sesión iniciada)
ssh objetivo 'grep -iE "drm: consumer cache|UInput" ~/.local/share/logs/RustDesk/server/rustdesk_rCURRENT.log | tail -3'
```

## H-09 — MagicDNS funciona aunque Tailscale avise `resolved-NM wired incorrectly`

**Verificado:** ✅

`tailscale status` muestra este *health check* en el operador:

```
#     - systemd-resolved and NetworkManager are wired together incorrectly;
#       MagicDNS will probably not work. For more info, see https://tailscale.com/s/resolved-nm
```

Sin embargo, **MagicDNS sí resuelve**:

```
$ resolvectl query <objetivo>
<objetivo>: 100.x.y.z                                      -- link: tailscale0
       (<objetivo>.<tailnet>.ts.net)

$ tailscale status | grep <objetivo>
100.x.y.z  <objetivo>  ...  active; direct 192.168.1.x:41641

$ getent hosts <objetivo>
100.x.y.z  <objetivo>.<tailnet>.ts.net
```

**Causa (verificada):** el aviso tiene **dos** requisitos que deben cumplirse a
la vez, y en este equipo faltaban ambos:

1. **NetworkManager debe declarar el backend** `systemd-resolved`. Sin
   `dns=systemd-resolved` en `/etc/NetworkManager/conf.d/`, Tailscale no puede
   leer la config del sistema.
2. **`/etc/resolv.conf` debe ser el symlink al stub de resolved**
   (`/run/systemd/resolve/stub-resolv.conf`). Si es un **archivo normal** (como
   lo era aquí, con `nameserver 127.0.0.53` escrito a mano por NM),
   `resolvectl` reporta `resolv.conf mode: foreign` y Tailscale asume que la
   resolución no depende de resolved.

Comprobación del síntoma:

```fish
resolvectl status | grep "resolv.conf mode"   # 'foreign' = mal
ls -la /etc/resolv.conf                        # debe ser un symlink, no un archivo
```

**Fix (silencia el aviso de verdad):**

```fish
# 1. Declarar el backend DNS en NetworkManager
#    /etc/NetworkManager/conf.d/dns.conf
[main]
dns=systemd-resolved
```

```fish
# 2. Apuntar /etc/resolv.conf al stub de resolved (haz backup antes)
sudo cp -a /etc/resolv.conf /etc/resolv.conf.bak
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# 3. Reiniciar NM (lee dns.conf) y re-evaluar Tailscale
sudo systemctl restart NetworkManager
sudo systemctl restart tailscaled

# 4. Verificar
resolvectl status | grep "resolv.conf mode"   # ahora 'stub' ✅
tailscale status | grep -A3 "Health check"    # sin aviso ✅
```

**Conclusión:** el aviso es **real pero no bloqueante**: MagicDNS resolvía igual,
pero conviene arreglarlo para que resolved gestione bien
`search <tailnet>.ts.net`.
Tras el fix, el DNS normal (`getent hosts google.com`) y MagicDNS (`getent hosts
<host>`) funcionan, y `ssh <nombre>` entra sin especificar IP.

---

## H-10 — Fedora 44 (imagen base) no trae el binario `hostname`

**Verificado:** ✅ (bug real encontrado probando en `fedora:44`)

La imagen base de **Fedora 44** (`docker.io/library/fedora:44`) **no instala el
paquete `hostname`**, así que el binario no existe:

```
$ rpm -q hostname
package hostname is not installed
$ command -v hostname || echo "NO hostname binary"
NO hostname binary
$ ./setup-remote-target.sh --check
● Hostname:                 ← vacío (hostname: command not found)
```

Es un problema de **portabilidad**, no de Fedora en sí: el kit corría
`$(hostname)` sin respaldo. Lo mismo afecta a `inventory.sh` (`j HOSTNAME`, y el
encabezado `Inventario: local (...)`).

**Solución:** respaldo en cadena — binario → `/proc/sys/kernel/hostname` →
`uname -n`:

```bash
# setup-remote-target.sh
local_hostname() {
  if command -v hostname >/dev/null 2>&1; then hostname
  elif [[ -r /proc/sys/kernel/hostname ]]; then cat /proc/sys/kernel/hostname
  else uname -n; fi
}

# inventory.sh (one-liner)
hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || uname -n
```

Tras el fix, en `fedora:44` el diagnóstico y el inventario muestran el nombre
correcto (`/proc/sys/kernel/hostname` siempre está presente en Linux).

**Nota:** relacionado con H-07 (`hostname -I`): en ambos casos el binario
`hostname` es poco fiable fuera de un escritorio completo, y conviene preferir
`ip` / `/proc` / `uname`.

---

## H-11 — En Fedora 44 con KDE la "última sesión" no es la gráfica

**Verificado:** ✅ (bug real encontrado en VM Fedora 44 KDE, `192.168.122.11`)

El kit detectaba el tipo de sesión con:

```bash
loginctl show-session "$(loginctl list-sessions --no-legend | awk '{print $1}' | tail -1)" -p Type --value
```

En Fedora 44 con KDE, `loginctl list-sessions` deja **al final** sesiones de
tipo `manager` / `background`, cuyo `Type` es `unspecified`:

```
$ loginctl list-sessions --no-legend
  2 1000 jp seat0 1429 user       tty2 no -
 21 1000 jp -     9012 user       -    no -
  3 1000 jp -     1436 manager    -    no -
c15 1000 jp -     5806 background -    no -
```

Con `tail -1` se elegía `c15` → `Type=unspecified`, y el diagnóstico decía:

```
● Tipo de sesión detectada: unspecified      ← incorrecto
```

cuando la sesión gráfica real es la `2` (`seat0`, `Type=wayland`, `kwin_wayland`).
En CachyOS no se veía porque la sesión gráfica quedaba última.

**Solución:** elegir por `seat`, no por posición:

```bash
graphical_session_type() {
  local id t
  while read -r id; do
    [[ -z "$id" ]] && continue
    t="$(loginctl show-session "$id" -p Type --value 2>/dev/null || true)"
    case "$t" in wayland|x11) printf '%s' "$t"; return 0 ;; esac
  done < <(loginctl list-sessions --no-legend 2>/dev/null \
             | awk '$4 != "-" {print $1}')   # $4 = seat; '-' = sin seat
  ...
}
```

Tras el fix, en Fedora 44 KDE: `Tipo de sesión detectada: wayland` y se activa
el aviso de DRM. Afecta a los **dos** sitios que consultaban la sesión
(diagnóstico y aviso por familia en `--rustdesk`).

**Nota:** importa porque de esta detección depende el aviso de que el `.rpm`
oficial no trae el parche DRM de Arch y la captura desatendida puede caer al
portal. Un `unspecified` silenciaba ese aviso justo en el caso de riesgo.

---

## H-12 — Imágenes base mínimas sin `systemctl`/`firewall-cmd`: "sin firewall" era falso

**Verificado:** ✅ (en `docker.io/library/fedora:44` y `debian:12`)

Las imágenes base mínimas no traen ni `systemctl` ni `firewall-cmd` ni `ufw`:

```
$ for b in systemctl firewall-cmd ss ip loginctl lsmod hostname; do
    printf '%-14s %s\n' "$b" "$(command -v $b || echo AUSENTE)"; done
systemctl      AUSENTE
firewall-cmd   AUSENTE
ss             AUSENTE
ip             AUSENTE
loginctl       AUSENTE
lsmod          AUSENTE
hostname       AUSENTE
```

`detect_firewall` caía al final de su cascada y devolvía `none`, que el
diagnóstico traducía como:

```
● Detectado: none
✔ Sin firewall activo (accesible en LAN, pero menos seguro)   ← no verificado
```

Es una **afirmación sin pruebas**: no es que no haya filtrado, es que no se pudo
consultar. En una imagen mínima o un contenedor puede haber filtrado a nivel de
nftables o de la plataforma.

**Solución:** nuevo valor `sin-herramientas`, distinto de `none` (que queda para
el caso realmente verificado):

```bash
if pkg_installed firewalld 2>/dev/null || pkg_installed ufw 2>/dev/null \
   || ! command -v systemctl >/dev/null 2>&1; then
  printf 'sin-herramientas'; return
fi
printf 'none'
```

Y en el diagnóstico:

```
● Detectado: sin-herramientas
▲     Firewall NO verificable: falta systemctl/firewall-cmd/ufw
▲     (imagen mínima o contenedor). No se puede afirmar que no haya filtrado.
```

También se distingue el tipo de sesión: sin `loginctl` ya no dice
`desconocido` (que sugiere que hay sesión), sino:

```
● Tipo de sesión detectada: no verificable (falta loginctl)
```

**Sin cambios donde sí hay escritorio real:** Arch con `ufw` sigue diciendo
`ufw`; Fedora 44 KDE real sigue diciendo `firewalld-inactive`.

**Nota:** el script ya degradaba sin romperse en imágenes mínimas (no es un
crash). El problema era la **honestidad del reporte**: afirmar un estado de
seguridad que no se pudo comprobar.

---

## H-13 — Portapapeles SPICE en Wayland: **depende de la vía**, no de la dirección

**Verificado:** ✅ (VM Fedora 44 KDE Wayland, host CachyOS)
**Última revisión:** 27 oct 2026 (corrige la conclusión anterior)

### Conclusión vigente

Con `spice-vdagent 0.23.0` + `spice-vdagentd` activos y sesión **Wayland** en el
guest, lo que decide si el portapapeles se propaga **no es la dirección**, sino
**por qué vía se escribe** en el guest:

| Vía en el guest | host → guest | guest → host |
|---|---|---|
| **Wayland nativo** (`wl-copy`) | ✅ | ✅ **funciona** |
| **X11/Xwayland** (`xclip`) | ✅ | ❌ no propaga |

Medido, con contenido distinguible y verificando el valor recibido:

```
guest: printf 'WAYLAND-074632' | wl-copy      → host: WAYLAND-074632  ✅
guest: printf 'XCLIP-VIVO-074656' | xclip …    → host: (sin cambio)   ❌
```

> **Historial:** la primera medición de H-13 concluyó "guest→host no funciona".
> Esa medición se hizo escribiendo desde X11/Xwayland y se generalizó de más.
> Repetida con `wl-copy` (Wayland nativo), **sí funciona en ambas direcciones**.

### Por qué

`spice-vdagent` de Fedora 44 es una build **solo X11** (enlaza `libX11.so.6`,
cero libs Wayland). No habla Wayland: lee y escribe la selección X11. El puente
real lo hace **KWin/Xwayland**, que mantiene sincronizada la selección Wayland
con Xwayland:

- **host → guest:** el vdagent escribe en X11 → KWin/Xwayland lo publica en
  Wayland. Funciona siempre.
- **guest → host:** si el texto se escribió en **Wayland**, Xwayland ya lo tiene
  → vdagent lo lee → funciona. Pero hay que **sostener la selección**:
  `xclip` que termina al salir no deja nada que leer.

### Consecuencia práctica (importante)

**El portapapeles SPICE ya funciona en ambas direcciones para una persona
sentada frente a la VM** (copiar/pegar normal en el escritorio KDE).

Por eso `clip-vm.sh` (puente por SSH) **ya no es necesario para el uso normal**:
queda como herramienta para **scripting/automatización por SSH**, que es otro
caso (ahí el portapapeles de la sesión gráfica puede no existir).

### Trampas del puente SSH (siguen válidas para `clip-vm.sh`)

### Trampas encontradas al implementar el puente

**1. `wl-copy --paste-once` corrompe el portapapeles.** Verificado en
`wl-clipboard 2.3.0` (CachyOS):

```
$ printf 'X' | wl-copy              ; wl-paste   →  X     ✅
$ printf 'X' | wl-copy --paste-once ; wl-paste   →  1     ❌
```

Deja el carácter `1` en vez del contenido. **No usar ese flag.**

**2. `wl-copy` se queda residente.** Sirve el portapapeles desde un proceso en
segundo plano. Lanzado en primer plano por SSH, el comando **no termina nunca**
(el SSH espera a que cierre). Lanzado con `&` simple, no hereda el stdin.

Solución: guardar el contenido en un archivo del guest y lanzarlo desacoplado:

```bash
nohup wl-copy < "$f" >/dev/null 2>&1 &
disown 2>/dev/null || true
```

**3. Sin contraseña, siempre.** Usar `BatchMode=yes`: sin él, SSH cae a pedir
contraseña y el texto `usuario@host's password:` acaba dentro del portapapeles,
contaminando el resultado (fue exactamente lo que pasó en la primera prueba).

**4. El portapapeles del guest puede tener contenido viejo.** Si nadie sostiene
el portapapeles en el guest, `wl-paste` devuelve el último texto aunque no haya
proceso vivo. Conviene verificar con `clip-vm.sh show` antes de concluir que
"no funciona".

**5. Un test negativo puede ser un falso negativo.** La medición original de
H-13 concluyó "guest→host no funciona" usando `xclip` sin retener la selección.
Antes de dar por rota una vía, comprobar que **el proceso que publica el
portapapeles sigue vivo** (`pgrep -af wl-copy`) y repetir por la vía nativa del
compositor.

---

## H-14 — El `.rpm`/`.deb` estándar NO trae `libdrmtap`: en Wayland sin usuario falla la captura

**Verificado:** ✅ (Fedora 44 KDE Wayland, greeter `plasmalogin`, 27 oct 2026)

Síntoma reportado por el cliente al conectar por primera vez:

> *"Error en la captura de pantalla de Wayland. Es posible que el XDG Desktop
> Portal se haya bloqueado o no esté disponible. Intente reiniciarlo con
> `systemctl --user restart xdg-desktop-portal`."*

El log de captura lo confirma:

```
WARN  [libs/scrap/src/wayland/display.rs:283] Failed to get wayland displays: Could not find wayland compositor
WARN  [src/server/wayland.rs:567] Failed to get desktop rect for uinput
ERROR [src/server/wayland.rs:117] Wayland portal handshake failed:
      wl-stage:create-session:dbus:org.freedesktop.DBus.Error.NameHasNoOwner:
      Could not activate remote peer 'org.freedesktop.portal.Desktop': startup job failed
```

**Causa raíz:** el paquete **oficial estándar** (`.rpm` en Fedora, `.deb` de
Ubuntu/Debian) **no incluye `libdrmtap.so`**, el capturador que lee el
framebuffer por DRM directo. Sin él, RustDesk intenta capturar por el
**XDG Desktop Portal** (D-Bus de sesión). Pero `rustdesk.service` corre como
**root en contexto de sistema**, sin portal de sesión ni acceso al compositor
del usuario → el handshake falla.

Tres capas del mismo problema:

1. `--server` corre como `root` con `HOME=/var/lib/plasmalogin` (ve al greeter,
   no a un usuario logueado).
2. No hay portal D-Bus de sesión para root en ese contexto.
3. El `.rpm`/`.deb` estándar no trae captura DRM directa.

### La solución: paquete `rustdesk-unattended-wayland`

RustDesk publica **en su propio release de GitHub** un `.deb` llamado
`rustdesk-unattended-wayland-<ver>-x86_64.deb` que **sí** incluye el capturador
DRM. **No es exclusivo de Arch/AUR**: el AUR solo empaqueta ese mismo `.deb`
(ver su `PKGBUILD`).

| Pieza | `.rpm` estándar | `.deb` unattended-wayland |
|---|---|---|
| `libdrmtap.so` | ❌ | ✅ `0.5.8` |
| Captura DRM directa | ❌ | ✅ |
| Funciona en greeter Wayland | ❌ (error portal) | ✅ |

Verificado que es portable a Fedora:

- `sha256` del `.deb` coincide con el del PKGBUILD del AUR:
  `9eed5e9f4b47af8ed41585c399cb2c0d2870e801c99645330dea1063ad844e09`
- `libdrmtap` solo necesita `libdrm.so.2`, `libm`, `libc` → presentes en Fedora.
- El binario del `.deb` resuelve sus libs contra el sistema (`ldd` sin `not found`).

### Trampas al instalar el `.deb` en Fedora

1. **Dueño.** Al extraer el `.deb` en `/tmp` y copiarlo, los archivos quedan
   `jp:jp`. systemd falla con `status=203/EXEC` (*"Permission denied"*) si no se
   corrige a `root:root`.
2. **SELinux.** Los archivos copiados desde `/tmp` heredan el contexto
   `user_tmp_t`. Con SELinux en `Enforcing`, systemd **no puede ejecutarlos**.
   Hay que `restorecon -R` para devolverlos a `usr_t` / `lib_t`.
3. **Ruta del servicio.** En Fedora el unit vive en
   `/etc/systemd/system/rustdesk.service` (no en `/usr/lib/systemd/system/`).

Resultado tras corregir:

```
INFO [src/server/drm_capturer.rs:1889] drm: consumer cache warmed (1 displays) at startup
```

Esa línea (y la **ausencia** del error del portal) es la prueba de que la
captura DRM funciona sin usuario logueado.

**Instalador reproducible:** `install-rustdesk-unattended-fedora.sh`.

---

## H-15 — Sin contraseña permanente, unattended es imposible (y el campo puede engañar)

**Verificado:** ✅ (Fedora 44, 27 oct 2026)

`RustDesk.toml` **tenía la línea** `password = ''` y `salt = ''`: es decir,
`grep -c "^password"` devolvía `1` pero **no había contraseña**. Un chequeo que
cuente líneas da un falso positivo.

Sin contraseña permanente, RustDesk exige aceptación manual o contraseña
temporal en cada conexión → **no hay acceso desatendido**.

**Problema extra:** RustDesk 1.5.0 **no expone un flag CLI** para fijarla
(`rustdesk --password` no existe; la GUI es la única vía oficial).

**Solución:** `rustdesk-password.sh`, que reproduce el formato exacto extraído
del código fuente (`libs/hbb_common/src/config/permanent_password.rs`):

```
salt    = 32 caracteres aleatorios          (DEFAULT_SALT_LEN)
h1      = SHA256(password || salt)          (32 bytes)
inner   = "00" + base64_original(h1)        (PASSWORD_HASH_PREFIX)
key     = machine_uid() padded a 32 bytes   (= /etc/machine-id en Linux)
sealed  = 0x01 || nonce(24B) || secretbox_seal(inner, nonce, key)
storage = "01" + base64_original(sealed)    (PERMANENT_PASSWORD_ENC_VERSION)
```

Se escribe en `RustDesk.toml` → `password` (storage) y `salt`.

**Roundtrip verificado:** descifrar el storage con PyNaCl devuelve el `h1`
esperado, y `SHA256(password||salt)` coincide. Una contraseña incorrecta falla.

**Nota:** el server corre como root y usa `/root/.config/rustdesk/`, pero el
usuario `jp` tiene la suya en `~jp/.config/rustdesk/`. Hay que escribir en ambas
(lo hace el instalador).

---

## H-16 — Con solo el greeter, el log de captura NO está donde el kit lo busca

**Verificado:** ✅ (Fedora 44 KDE Wayland, 27 oct 2026)

Cuando `rustdesk.service` (root) está corriendo y **no hay usuario logueado**,
los logs se reparten en **tres** rutas según el proceso:

| Proceso | Ruta del log |
|---|---|
| `--service` (root, systemd) | `/root/.local/share/logs/RustDesk/service/` |
| `--server` (root, sirve el greeter) | `/var/lib/plasmalogin/.local/share/logs/RustDesk/server/` |
| `--server` (con usuario logueado) | `~usuario/.local/share/logs/RustDesk/server/` |

El proceso `--server` corrió con **`HOME=/var/lib/plasmalogin`** y
`DISPLAY=Err(NotPresent)` (correcto: en Wayland no hay X11). El kit leía
`~jp/.local/share/...`, que en ese escenario **queda congelado** (última línea de
la sesión anterior). Un log "viejo" no significa "no funciona".

Instrumentos de diagnóstico usados:

```fish
# a qué usuario/hogar está atado el server
sudo tr '\0' '\n' < /proc/(pgrep -f 'rustdesk --server')/environ | grep -iE 'HOME|USER'

# dónde escribe realmente
sudo find /root /var/lib/plasmalogin -name 'rustdesk_rCURRENT.log' 2>/dev/null
```

---

## H-17 — RustDesk 1.5.0 no tiene CLI de conexión (es GUI pura)

**Verificado:** ✅ (CachyOS y Fedora 44, 1.5.0)

`rustdesk --help` **abre la GUI** y se queda residente (no imprime ayuda ni
termina). En el código, `core_main.rs` solo interpreta flags de
instalación/servicio (`--version`, `--uninstall`, `--install-idd`,
`--portable-service`…). **No hay `--connect` ni forma de iniciar una sesión por
CLI.**

Consecuencia práctica: la prueba visual de extremo a extremo **requiere
intervención humana** (abrir la GUI y escribir la ID + contraseña). No se puede
automatizar con el binario oficial, ni local ni remotamente.

---

## H-18 — El server se ancla a la sesión gráfica de seat0 (incluido el greeter)

**Verificado:** ✅ (Fedora 44 KDE Wayland, 27 oct 2026)

Con solo el greeter `plasmalogin` en `seat0` (sin usuario logueado), RustDesk
eligió correctamente servirlo:

```
INFO [src/core_main.rs:398] start --server with user plasmalogin
INFO [src/server.rs:665] DISPLAY=Err(NotPresent)
INFO [src/ipc.rs:725] Started ipc server at path: /tmp/RustDesk-981/ipc
```

El código tiene una ruta dedicada para este caso: `is_x11_for_drm()` evita el
"punto ciego del greeter" y `drm_capturer` documenta que, si no hay pantalla
encendida al arrancar, *"the first login probes again"*.

Esto es la evidencia de que el acceso desatendido **antes del login** es un caso
soportado, siempre que exista el capturador DRM (ver H-14).

**Quién puede usar `uinput`:** con la regla udev `TAG+="uaccess"`, el ACL de
`/dev/uinput` apunta al usuario de la sesión **activa de seat0**. En la pantalla
de login ese usuario es el **greeter** (aquí `plasmalogin`), no `jp`:

```
$ getfacl /dev/uinput
user:plasmalogin:rw-
```

Al iniciar sesión `jp`, el ACL debe moverse a `jp`. Verificar con `getfacl`
después del login si la inyección de input no responde.

---

## H-19 — `os error 104` tras conectar: audio/portapapeles en bucle

**Verificado:** ✅ (Fedora 44 KDE Wayland, 27 oct 2026)

Síntoma en el cliente: *"Conexión reinicializada por la máquina remota
(os error 104)"*.

El log del servidor demuestra que **la conexión sí entró** y la captura DRM
funcionaba:

```
INFO  Connection opened from 192.168.1.12:38837
INFO  libdrmtap loaded: /usr/lib/rustdesk/libdrmtap.so.0 (v0.5.8)
INFO  drm: cursor calibration for display 0 (Virtual-1): Ok(...)
INFO  new encoder: VPX(width: 1280, height: 800, codec: VP8)
```

El corte venía de servicios que reintentan sin contexto gráfico:

```
ERROR audio service: No such file or directory (os error 2)
ERROR clipboard service: arboard: X11 server connection timed out because it was unreachable
WARN  no usable wayland socket in /run/user/1000 (none present)
```

**Causa:** `arboard` (portapapeles) insiste en X11 y expira; el audio busca un
socket PipeWire inexistente. En un contexto sin sesión gráfica completa, ambos
reintentan en bucle y terminan cortando la sesión.

**Mitigación (desde el operador):** desactivar **audio** y **portapapeles** en la
GUI antes de conectar. `disable_audio` / `disable_clipboard` son opciones del
**cliente**:

```rust
// src/client.rs
option.disable_audio = ...;
option.disable_clipboard = ...;
```

**No hay** una opción equivalente del lado del servidor para desactivarlos por
configuración.

### Trampa asociada: TOML inválido al editar a mano

Un intento previo falló además con:

```
ERROR [libs/hbb_common/src/config.rs:566] Failed to load config
      '/home/jp/.config/rustdesk/RustDesk2.toml': Bad TOML data
```

RustDesk reescribe `RustDesk2.toml` al arrancar (por eso `enable-drm-display-wake`
añadido a mano puede desaparecer: su valor por defecto ya es ON). Tras editar a
mano, validar:

```fish
python3 -c "import tomllib; tomllib.load(open('/root/.config/rustdesk/RustDesk2.toml','rb'))"
```

---

## H-20 — `inventory.sh` clasificaba las VMs como `desconocido`

**Verificado:** ✅ (Fedora 44 en QEMU/KVM, 27 oct 2026)

En una VM QEMU/KVM:

```
$ cat /sys/class/dmi/id/chassis_type
1                            ← SMBIOS: "Other"
$ hostnamectl chassis
vm
$ systemd-detect-virt
kvm
```

El mapeo original solo cubría laptops (8/9/10/14) y desktops (3-7), así que `1`
caía en `desconocido` aunque `systemd` detecta perfectamente la virtualización.

**Solución:** consultar `systemd-detect-virt` **en el objetivo** y clasificar
como `vm` cuando no devuelve `none`.

**Trampa al implementarlo:** el respaldo `hostnamectl chassis` **se ejecutaba en
el operador**, no en el remoto, y devolvía el tipo del operador (`desktop` en
CachyOS). La detección debe usar **solo** datos recolectados por el
`REMOTE_SCRIPT` (la variable `D[...]`).

Resultado:

| Objetivo | Antes | Ahora |
|---|---|---|
| VM QEMU/KVM | `desconocido` | `vm` ✅ |
| PC real (CachyOS) | `desktop` | `desktop` ✅ (sin regresión) |

---

## H-21 — `paru` era un punto único de falla en Arch (y no hace falta)

**Verificado:** ✅ (CachyOS recién instalado, 27 oct 2026)

Síntoma reportado en una instalación real desde cero:

> *"me dice que no hay aur helper paru"*

**Causa:** la rama Arch dependía de un ayudante de AUR (paru/yay) para instalar
`rustdesk-unattended-wayland`. Eso encadena dependencias:

```
paru → git + base-devel + red + makepkg (compilar) → paquete
```

Si falla **cualquier** eslabón (sin red, sin git, sin base-devel, makepkg sin
TTY, directorio de build sin permisos), no hay RustDesk → no hay captura DRM →
no hay acceso desatendido.

**Lo importante:** el paquete de AUR **no compila nada especial**: su `PKGBUILD`
se limita a extraer el `.deb` que RustDesk publica en su release de GitHub
(mismo sha256 que el usado en Fedora, ver H-14). O sea, **el AUR es un
intermediario innecesario**.

**Solución:** cascada de 3 vías, de la más simple a la más compleja:

| Vía | Necesita | Cuándo se usa |
|---|---|---|
| 1. paru/yay | si ya existe | primero |
| 2. **`.deb` oficial extraído a mano** | solo `curl` + `ar` + `tar` | si paru falta o falla |
| 3. instalar paru | red + compilar | último recurso |

La vía 2 (`install_rustdesk_unattended_deb_arch`) descarga el `.deb`, verifica
el **sha256**, lo extrae con `ar`+`tar` y lo instala en `/usr/share/rustdesk` +
`/usr/lib/rustdesk` (donde va `libdrmtap.so`).

Verificado por separado:

```
sha256 verificado
libdrmtap.so.0 / libdrmtap.so.0.5.8 presentes
rustdesk.service presente
```

**Lección:** cuando un paquete de AUR solo empaqueta un binario ya publicado,
depender del AUR agrega fragilidad sin beneficio. Mejor bajar el binario oficial
directo, con verificación de integridad.

---

## H-22 — Fallos silenciosos: instalar sin red y `tailscale up` sin salida

**Verificado:** ✅ (CachyOS virgen, 27 oct 2026)

Dos clases de fallo que hacían imposible diagnosticar desde el PC del cliente:

### 1. Instalar sin comprobar la red

El kit intentaba instalar paquetes y, si no había internet, fallaba con un error
genérico. **No decía que el problema era la red.**

Ahora se comprueba antes:

```
SIN CONEXIÓN a internet: no puedo instalar Tailscale
  Comprobá:  curl -sI https://archlinux.org | head -1
  Conectá el WiFi/hotspot y reintentá.
```

### 2. `tailscale up` ocultaba su error

La llamada iba con `>/dev/null 2>&1` y solo imprimía *"no confirmó éxito (puede
requerir autorización)"*. Eso no distingue entre: auth key vencida, key no
reusable, o sin red.

Ahora se captura la salida **y se muestra**:

```
tailscale up FALLÓ. Salida:
    <mensaje real de tailscale>
  Causas típicas:
   · auth key vencida o ya usada (generá otra)
   · auth key no 'reusable' y este equipo ya estaba en la tailnet
   · sin internet en este momento
```

Además: se **espera hasta 10 s** a que `tailscaled` quede activo (con
`systemctl status` si no) y **hasta 15 s** a que aparezca la IP (antes eran 2 s,
lo que producía falsos *"aún sin IP"*).

### 3. Diagnóstico de dependencias en `--check`

`setup-remote-target.sh --check` ahora informa qué falta de un vistazo:

```
== Dependencias que suelen faltar ==
✔ curl presente
✔ ar + tar presentes (vía .deb)
● sin paru/yay (el kit usará el .deb oficial, no hace falta)
✔ internet: github.com alcanzable
```

**Lección:** en un equipo al que no vas a volver (el PC del cliente), un fallo
silencioso cuesta una visita. Todo comando que pueda fallar debe **mostrar su
salida** y decir **qué comprobar**.

---

## H-23 — Enviar sintaxis bash a un objetivo con `fish` da falsos fallos

**Verificado:** ✅ (CachyOS recién instalado, shell `fish`, 27 oct 2026)

Síntoma: `make check` y `tests.sh <host>` reportaban fallos **aunque el kit
estaba perfectamente instalado**:

```
✘ make check

fish: Uso no soportado de '='. En fish, utiliza 'set u ""'.
u=""; for x in sshd ssh; do ...
^~~
```

Y en `tests.sh`, peor: **omitía** 4 pruebas de hallazgos porque creía que
Tailscale no estaba instalado:

```
▲ H-01 Tailscale no instalado en el objetivo (acceso por LAN)
▲ H-04 no se pudo determinar el tipo de sesión del objetivo
▲ H-05 el objetivo no tiene Tailscale (acceso por LAN): H-05 no aplica
```

**Causa doble:**

### 1. El shell del objetivo es `fish`

CachyOS usa **fish por defecto**. Los comandos remotos se escribían en sintaxis
bash (`u=""`, `$(...)`, `>/dev/null 2>&1`, `awk "{print $1}"`) y fish los
rechaza:

```
fish: Uso no soportado de '='
fish: $$ no corresponde al PID. En fish, usa $fish_pid.
```

### 2. `ssh host bash -lc 'cmd'` se come los flags del comando

Al expandir una variable como `$RH` (con `RH="ssh ... bash -lc"`), **ssh recibe
los argumentos por separado** y bash interpreta los flags del comando como
propios. Caso real:

```console
$ ssh host bash -lc 'tailscale ip -4'
The easiest, most secure way to use WireGuard.   <- ¡imprime la AYUDA!
USAGE
  tailscale [flags] <subcommand> [command flags]
```

`-4` se lo comía bash, así que `tailscale ip` iba sin flags y mostraba ayuda.
Por eso `H-01 tiene IP Tailscale` fallaba aunque `tailscale ip -4` funcionara
perfecto al ejecutarlo a mano.

### Solución

**Enviar el script por STDIN a `bash -s`**, que ni depende del shell del
objetivo ni reinterpreta argumentos:

```bash
rsh() { printf '%s\n' "$*" | ssh -o BatchMode=yes "$HOST" bash -s; }
```

Y en el Makefile, todo el bloque `check` va por `printf '%s\n' 'linea1' 'linea2'
... | $(SSH) $(HOST) bash -s`, una línea de script por argumento.

Resultado en el mismo equipo (antes: 7 fallos / 74 omitidos):

```
288 OK · 0 fallos · 0 omitidos
```

**Lección:** un objetivo con shell distinto (fish, csh, zsh) rompe cualquier
comando que se le mande "suelto" por SSH. Enviar siempre el script por stdin a
un intérprete explícito (`bash -s`) elimina la clase entera de problemas. Y ojo
con `ssh host bash -lc 'cmd' >>>usado a través de una variable<<<`: los flags
del comando pueden ser interceptados por el intérprete.

---

## H-24 — Fedora instalaba el `.rpm` sin capturador DRM

**Verificado:** ✅ (revisión de código, 27 oct 2026)

Síntoma latente: en un cliente **Fedora**, `setup-remote-target.sh --rustdesk`
instalaba `install_rustdesk_rpm` — el **build estándar**, que **no incluye
`libdrmtap.so`** (ver H-14). El acceso desatendido en Wayland habría cascado al
portal y fallado en silencio, exactamente el problema que en Fedora 44 ya
habíamos visto.

La vía buena (`install-rustdesk-unattended-fedora.sh`, que extrae el `.deb` con
DRM) **existía pero no estaba enganchada al flujo**: había que ejecutarla aparte.

**Por qué pasó:** la función que instalaba el `.deb` se llamaba
`install_rustdesk_unattended_deb_arch` y solo se invocaba desde la rama `arch`.
El nombre limitaba su uso aunque la lógica es **portable** (solo `curl` + `ar` +
`tar`, sin `dpkg` ni AUR).

**Solución:** renombrada a `install_rustdesk_unattended_deb` y enganchada como
**primera opción en Fedora**, con el `.rpm` como respaldo y un aviso explícito:

```
fedora)
  if install_rustdesk_unattended_deb; then        # capturador DRM
    :
  elif install_rustdesk_rpm; then
    warn "se instaló el .rpm estándar: SIN capturador DRM"
    warn "  En Wayland el acceso desatendido puede cascar al portal."
  fi
```

**Lección:** un nombre que menciona una distro (`_arch`) cuando la lógica no
depende de ella invita a no reutilizarla. Si la función es portable, el nombre
debe decirlo.

### Mejoras aplicadas junto con este hallazgo

| Mejora | Antes | Ahora |
|---|---|---|
| **Hardening SSH** | `ufw allow 22/tcp` | `ufw limit` (6 conexiones/30 s por IP) + rich rule en firewalld |
| **drm-wake** | Solo se *sugería* editar el TOML | Se **aplica** (usuario + root) y se **valida** el TOML resultante |
| **`verify-offlan.sh`** | `PEER=fedora` por defecto (resto de desarrollo) | Autodetecta el primer peer online; error claro si no hay |
| **Función `info`** | `verify-offlan.sh` la definía → colisiona con `info(1)` | Renombrada a `say` (mismo bug que en H-15) |
| **`--check` duplicado** | `instalar-todo.sh` lo corría dos veces | Se ejecuta una vez y se reutiliza la salida |
| **Backups** | `.bak-$(date +%s)` (colisiona) y acumulaban sin fin | Sufijo `mktemp -u` + rotación a los 3 últimos |
| **Limpieza remota** | El helper podía quedar en `/tmp` del cliente | `trap` de salida que lo borra |
| **Versionado** | Ningún script conocía su versión | `.kit-version` (de `git describe`) + `instalar-todo.sh` lo imprime |
| **Doc (drift)** | README/INSTALAR presentaban `paru` como ruta primaria | El `.deb` con DRM es la principal; AUR queda como alternativa |

---

## H-26 — La auth key de Tailscale: dónde está (y dónde la gente la busca)

**Verificado:** ✅ (27 oct 2026)

Síntoma real: al instalar en un equipo **sin sesión gráfica ni navegador**,
`tailscale up` pelado abre un login interactivo que no se puede completar. La
salida es `--auth-key`, pero el bloqueo siguiente es **no saber de qué parte del
panel web sale esa key**. Búsqueda infructuosa típica en *Machines*, *DNS* o la
app de escritorio.

**Dónde está de verdad:**

```
https://login.tailscale.com/admin/settings/keys
  admin  ->  Settings  ->  pestaña "Keys"  ->  "Generate auth key..."
```

`login.tailscale.com` y `console.tailscale.com` son la **misma consola**; ambos
links sirven. La key **solo se muestra una vez**, al generarla.

**Formulario, campo por campo** (un equipo vs. varias instalaciones):

| Campo | Un cliente | Varios equipos |
|---|---|---|
| Description | `kit-pendrive-cliente` | `kit-pendrive-cliente` |
| Reusable | ❌ NO | ✅ SÍ |
| Ephemeral | ❌ NO | ❌ NO |
| Pre-approved | ✅ sí | ✅ sí |
| Expiration | 1 día | 90 días |

**Lección:** documentar *dónde* vive una credencial en la UI, no solo cómo se
usa. El runbook ya explicaba `--authkey` pero no la ruta en el panel; eso costó
una instalación detenida. Ver [`tailscale.md`](tailscale.md#generar-la-auth-key-paso-a-paso-en-la-web).

### Detalles que confunden al armar el comando

| Dato | Aclaración |
|---|---|
| `--rdpass` | Lo **elige el operador** (ej. `Juanpablo44`); no viene de ningún panel |
| `--sudopass` | Solo si sudo no se pide de forma interactiva; si lo define el cliente, se omite |
| Clave SSH del operador | Ya viene en `operador.pub`; no hay que generarla de nuevo |

> Una contraseña de RustDesk débil (`Juanpablo44`) **funciona**, pero el kit la
> advierte. Cambiarla con `./rustdesk-password.sh install "jp@localhost" '<nueva>'`.

---

## H-27 — Reinicio remoto bloqueado por sudo + polkit

**Verificado:** ✅ (27 oct 2026)

Síntoma: no se puede reiniciar el equipo objetivo por SSH para la prueba de
unattended. Todas las vías "normales" piden autenticación interactiva:

| Vía | Resultado en el objetivo |
|---|---|
| `sudo -n systemctl reboot` | ❌ `sudo: a password is required` |
| `systemctl reboot` (sin sudo) | ❌ *Access denied … requires interactive authentication* |
| `logind` por D-Bus (`Manager.Reboot`) | ❌ `InteractiveAuthorizationRequired` |

El usuario estaba en `wheel`, pero **sudo pide contraseña** y **polkit exige
consentimiento interactivo** (no hay sesión de escritorio que lo conceda). Desde
SSH **no hay forma** de autorizar sin un secreto.

### Solución: NOPASSWD acotado al reboot (no a todo sudo)

Regla en `/etc/sudoers.d/99-reboot-jp`:

```
jp ALL=(ALL) NOPASSWD: /usr/bin/systemctl reboot, /usr/bin/systemctl poweroff
```

Aplicación **siempre validando antes** (un sudoers roto puede dejar el equipo sin
sudo; `visudo -cf` lo evita):

```fish
# El script se copia por scp (sin contraseña, usa la clave SSH) y se ejecuta con sudo
scp fix-reboot-nopasswd.sh jp@100.x.y.z:/tmp/
ssh -t jp@100.x.y.z 'sudo sh /tmp/fix-reboot-nopasswd.sh'
```

Disparo del reinicio (ya sin contraseña):

```fish
ssh jp@100.x.y.z 'sudo -n /usr/bin/systemctl reboot'
```

**Rollback:** `sudo rm /etc/sudoers.d/99-reboot-jp`.

### Trampas encontradas al aplicar la regla

| Trampa | Qué pasó | Lección |
|---|---|---|
| Copiar/pegar multilínea por SSH | El `>` o el `chmod` quedaron al final de una línea partida → `sh: error de sintaxis` o `chmod: falta un operando` | Para comandos con redirección, usar un **script** (`scp` + `sh`), no una línea larga |
| Escribir sin `chmod 440` | El archivo quedó con permisos incorrectos; sudoers.d los exige | `chmod 440` **y** `visudo -cf` en el mismo paso |
| `sudo -n systemctl reboot --help` | Falla aunque la regla sea correcta | El sudoers autoriza **el binario y args exactos**; verificar con `sudo -n -l`, no inventando variantes |
| Comando a un objetivo con **fish** | `$$`, `for … end` y otros rompen; el heredoc a fish da error de sintaxis | Enviar por `bash -s` por stdin (H-23) |

**Distinción importante:** esto habilita *disparar* el reinicio. La prueba de que
el equipo **vuelve solo** es independiente y se verificó aparte: `boot_id`
distinto + servicios `active` sin intervención (ver
[`estado-sesion.md`](estado-sesion.md#prueba-de-reinicio-unattended-real-superada)).

---

## H-28 — `local-ip-addr` queda obsoleto al cambiar de red

**Verificado:** ✅ (27 oct 2026)

Síntoma: un equipo que se instaló/movió entre redes conserva en su config la
**IP de LAN vieja**, que ya no existe:

```toml
[options]
local-ip-addr = '10.71.93.77'    # red del hotspot 4G (ya no está)
```

IP real en ese momento: `192.168.1.16`. La declarada no coincidía con ninguna
interfaz.

**Qué afecta (y qué no):**

| Función | ¿Afectada? |
|---|---|
| Conexión por **ID** (rendezvous) | No |
| Conexión por **IP Tailscale** (`100.x`) | No |
| **LAN discovery** (verse en la misma red por IP local) | **Sí** |

No rompe el acceso remoto, pero degrada el descubrimiento local y confunde al
diagnosticar. Es exactamente el caso de un equipo que pasa de la red de
instalación a la red del cliente.

### Detección

```fish
# Comparar la IP declarada con la real
ip -4 route get 1.1.1.1 | grep -oP 'src \K[0-9.]+'
grep local-ip-addr ~/.config/rustdesk/RustDesk2.toml
```

Si no coinciden, está obsoleta.

### Corrección

Editar y **validar el TOML** (un TOML inválido impide arrancar RustDesk — ver
H-19):

```fish
F=~/.config/rustdesk/RustDesk2.toml
NEW="$(ip -4 route get 1.1.1.1 | grep -oP 'src \K[0-9.]+')"
cp -a "$F" "$F.bak-$(date +%s)"
sed -i "s|^local-ip-addr = .*|local-ip-addr = '$NEW'|" "$F"
python3 -c "import tomllib; tomllib.load(open('$F','rb')); print('TOML OK')"
```

### Trampa: el proceso no relee el TOML solo

El **proceso servidor lee la config al arrancar**. Editar el archivo con el
servicio corriendo **no aplica el cambio** hasta reiniciarlo:

```
proceso server arrancó: 15:32
mtime del TOML:         15:48   -> cambio NO aplicado aún
```

Reiniciar requiere `systemctl restart rustdesk`, que también pasa por polkit
(pide auth interactiva, igual que H-27). Opciones:

1. **Sudoer acotado** (recomendado, mismo patrón que H-27):
   ```
   jp ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart rustdesk
   ```
2. Reiniciar el equipo (recoge el valor al arrancar; ver la prueba de reinicio).
3. Reinicio presencial del servicio.

**Lección:** cualquier valor derivado de la red (`local-ip-addr`) es efímero. Al
entregar un equipo, o tras mudarlo de red, **verificar que coincida** con la
interfaz real antes de darlo por listo.

---

## H-29 — Un portátil suspende y se pierde el acceso remoto

**Verificado:** ✅ (27 oct 2026)

Síntoma: en un **portátil**, cerrar la tapa o dejarlo inactivo hace que
systemd-logind **suspenda** el equipo. Al suspender:

- Tailscale deja de responder (el peer pasa a `offline`)
- `sshd` no acepta conexiones
- RustDesk no captura

El operador **pierde el acceso remoto** y no puede recuperarlo hasta que
alguien abra la tapa o toque el equipo. En un **PC de escritorio esto no pasa**
(no tiene tapa ni batería), por eso el desarrollo previo no lo había expuesto.

Es el riesgo más serio en una entrega real con portátil: el equipo "está
instalado y funciona", y a la hora el cliente cierra la tapa → inaccesible.

### Detección

```fish
ls /sys/class/power_supply | grep -i BAT   # hay batería -> es portátil
grep -E '^#?HandleLidSwitch' /etc/systemd/logind.conf
```

Si `HandleLidSwitch` está comentado (o en `suspend`), cerrar la tapa suspende.

### Solución (reversible)

`laptop-no-suspend.sh` (o `setup-remote-target.sh --laptop`, incluido en `--all`):

1. Crea `/etc/systemd/logind.conf.d/99-no-suspend-laptop.conf`:
   ```
   [Login]
   HandleLidSwitch=ignore
   HandleLidSwitchExternalPower=ignore
   HandleLidSwitchDocked=ignore
   ```
2. Recarga `systemd-logind` (aplica sin reiniciar el equipo).
3. En KDE, desactiva la **suspensión por inactividad** (AC y batería) vía
   `kwriteconfig6` en `powermanagementprofilesrc`.

No toca apagado, reinicio ni bloqueo de pantalla.

```fish
sudo ./laptop-no-suspend.sh --apply     # aplica
sudo ./laptop-no-suspend.sh --revert    # deshace
./laptop-no-suspend.sh --check          # solo muestra
```

### Trampa: `systemctl restart systemd-logind` puede cortar la sesión

Recargar logind puede **cerrar la sesión gráfica** en algunos equipos. Por eso
el kit lo hace **después** de configurar RustDesk, y el PASO de instalación
corre primero. Si corta la sesión: volvé a entrar; el cambio ya quedó aplicado.

**Lección:** todo supuesto "de escritorio" (sin tapa, sin batería, sin WiFi
variable) puede romper el unattended en un portátil. Antes de entregar un
portátil, verificar explícitamente que no suspenda.

---

## H-30 — La auth key no sale del equipo: se genera en la web

**Verificado:** ✅ (27 oct 2026)

Síntoma real (bloqueó una instalación en un laptop de cliente): el kit pide
`--authkey` **antes** de unir Tailscale, el operador no la tiene a mano, y la
instalación queda a mitad. La pregunta que aparece es:

> "¿Cómo obtengo la auth key si todavía no tengo Tailscale instalado?"

**La confusión:** se cree que la key "sale" de Tailscale o del equipo. No es así.

**La respuesta:** la auth key se **crea en la WEB** de Tailscale, logueado con la
cuenta, desde **cualquier navegador** (el celular alcanza). No requiere Tailscale
instalado en el dispositivo donde la generás. Es simplemente un **string de
texto** que se copia de la web y se pega en el equipo.

```
1. En un navegador (celular o cualquier PC):
     https://login.tailscale.com/admin/settings/keys
     admin -> Settings -> pestaña "Keys" -> "Generate auth key..."
2. Copiar el string  tskey-auth-...   (se muestra UNA SOLA VEZ)
3. Pegarlo en el equipo objetivo (--authkey, o ./unir-tailscale.sh)
```

### Solución: separar instalar de autenticar

El kit pedía la key de entrada y bloqueaba. Ahora hay dos modos que **no
bloquean** si todavía no tenés la key:

| Modo | Qué hace |
|---|---|
| `--tailscale-luego` | Instala Tailscale y deja el daemon **sin unir**; explica cómo obtener la key |
| `--skip-tailscale` | No toca Tailscale (solo LAN) |

Y una segunda etapa explícita:

```fish
# Etapa 1 (no necesita la key)
sudo ./instalar-todo.sh --tailscale-luego --rdpass 'ClaveCliente'
# Etapa 2 (cuando ya tenés la key, generada en la web)
./unir-tailscale.sh --hostname laptop-cliente
```

`unir-tailscale.sh` imprime el paso a paso de dónde sale la key, valida el
formato (`tskey-`), une el equipo y verifica la IP `100.x`.

**Por qué es mejor partir el flujo:** la auth key **expira**. Generarla al
principio y tardar una hora instalando puede vencerla. Generarla al final (o en
el momento) evita esa carrera.

**Lección:** una credencial que se crea en la web debe documentarse como parte
del flujo, no como un prerrequisito "obvio". El operador novato no sabe que la
key se genera fuera del equipo.

---

## H-31 — Fedora 44: instalar apps KDE6 choca con `kmime` (transición KDE5→KDE6)

**Verificado:** ✅ (Fedora 44 KDE, 27 oct 2026)

Síntoma real: en un Fedora 44 recién instalado, cualquier `dnf5 install` de una
app KDE (p. ej. `kate`, que la imagen base no trae) termina en:

```
Transacción incorrecta: Transacción rpm incorrecta.
  - el archivo /usr/share/locale/lt/LC_MESSAGES/libkmime6_qt.qm de la instalación
    de kf6-kmime-6.31.0-1.fc44.x86_64 entra en conflicto con el archivo del
    paquete kmime-25.12.3-1.fc44.x86_64
```

**Causa:** Fedora 44 está en plena transición **KDE5 → KDE6**. El paquete viejo
`kmime` (KDE5-era, versión `25.12.3`) y el nuevo `kf6-kmime` (Framework KDE6,
versión `6.31.0`) **comparten rutas** (`/usr/share/locale/...`,
`/usr/share/qlogging-categories6/...`) → rpm los marca incompatibles. No es del
kit ni del `.deb` de RustDesk: es empaquetado de la distro.

**Por qué aparece al instalar `kate`:** `kate` no necesita `kf6-kmime`
directamente, pero la transacción arrastra una cadena de KDE PIM
(`akonadi-*`, `kdepim-*`, `kalarm`, `grantlee-editor`) que sí lo requiere.

**Solución A (recomendada, de raíz):** completar la transición actualizando todo
el sistema, con el equipo **delante** (puede pedir reinicio o tocar el arranque
gráfico — no hacerlo por SSH):

```fish
sudo dnf5 upgrade --refresh
```

**Solución B (rápida, sin upgrade):** instalar solo la app excluyendo la cadena
PIM que dispara el conflicto:

```fish
sudo dnf5 install kate \
  --exclude='kf6-kmime*' --exclude='kdepim-*' --exclude='akonadi-*' \
  --exclude='kalarm*' --exclude='grantlee-editor*' \
  --exclude='calendarsupport*' --exclude='incidenceeditor*'
```

Verificado que así `kate` queda instalado y `dnf5 check` reporta dependencias
sanas.

**Lección:** en Fedora el kit no debe asumir que las apps KDE están completas
(la imagen base no trae `kate`), y un `dnf5 install` de apps KDE en FE44 puede
fallar por la transición KDE5→KDE6. Documentar la Solución A como paso previo
recomendado cuando se agregan apps de escritorio.

---

## H-32 — El `.deb` inyectado en Arch/Fedora puede romperse en silencio

**Síntoma:** RustDesk abre y funciona como GUI, pero el acceso **desatendido en
Wayland** deja de capturar de un día para otro. En el log ya no aparece
`drm: consumer cache warmed`. No hubo cambio aparente: solo un `pacman -Syu`
(o `dnf upgrade`) de rutina.

**Causa:** en Arch y Fedora el capturador DRM se instala extrayendo el `.deb`
oficial con `ar`+`tar` (necesario porque el `.rpm` no trae `libdrmtap`, H-14).
Ese binario queda **fuera del gestor de paquetes**: `pacman`/`dnf` no saben que
existe ni lo incluyen en la resolución de dependencias. `libdrmtap.so` enlaza
contra `libdrm.so.2`, `libEGL.so.1`, `libGLESv2.so.2`, `libm` y `libc`. Si una
actualización del sistema sube esas librerías con ABI incompatible (Arch es
rolling) o las quita, el capturador deja de cargar **sin que nada avise**.

**Solución:** tras instalar/actualizar, comprobar las dependencias dinámicas
de `libdrmtap.so*` con `ldd` y avisar si alguna aparece como `not found`:

```fish
ldd /usr/lib/rustdesk/libdrmtap.so.* | grep 'not found'
```

El kit lo hace solo: `check_drmtap_deps()` en `setup-remote-target.sh` (tras
inyectar el `.deb`) y en `update.sh` (en la verificación final, justo después
de actualizar el sistema, que es cuando más probable es que una librería haya
cambiado). Si falta algo, sugiere el comando de diagnóstico según la distro.

**Lección:** cualquier binario inyectado a mano (*fuera* del gestor de
paquetes) necesita su propia comprobación de dependencias, porque el sistema
nunca lo va a proteger. Vale para el `.deb` de RustDesk y para cualquier cosa
que el kit copie directamente a `/usr`.

---

## Verificación automatizada

Los hallazgos están cubiertos por pruebas ejecutables:

| Hallazgo | Dónde se verifica |
|---|---|
| H-01 Tailscale sobrevive reboot | `tests.sh <host>`: `tailscaled enabled`, tiene IP `100.x` |
| H-02 RustDesk depende de la sesión | `tests.sh <host>`: detecta si hay sesión `seat0` |
| H-03 login screen Wayland | `tests.sh` (local) + `tests.sh <host>` + `verify-docs.sh` |
| H-04 captura DRM con sesión | `tests.sh <host>`: busca `drm: consumer cache` |
| H-05 Tailscale directo | `tests.sh <host>`: `tailscale ping` responde `pong` |
| H-06 sshd enabled | `tests.sh <host>`: `sshd enabled` |
| H-07 `hostname -I` | `tests.sh` (local): los scripts usan `ip route get` |
| H-08 pipefail falsos negativos | `tests.sh` (local): `verify-docs` no usa `strings|grep -q` |
| H-09 MagicDNS con aviso resolved-NM | `tests.sh <host>`: MagicDNS resuelve por nombre |
| H-10 `hostname` ausente (Fedora 44 base) | `tests.sh` (local): `local_hostname` + respaldo `/proc` |
| H-11 última sesión no es la gráfica (Fedora 44 KDE) | `tests.sh` (local): `graphical_session_type` prefiere seat |
| H-12 `sin-herramientas` (imagen mínima sin systemctl) | `tests.sh` (local): `detect_firewall` distingue de `none` |
| H-13 portapapeles SPICE (depende de la vía, no de la dirección) | `tests.sh` (local): `clip-vm.sh` sin `--paste-once`, con `nohup+disown` |
| H-14 `.rpm` sin `libdrmtap` → falla el portal | `tests.sh`: existe `install-rustdesk-unattended-fedora.sh`; el script verifica sha256 y libdrmtap |
| H-15 contraseña permanente vacía | `tests.sh`: existe `rustdesk-password.sh`; roundtrip con PyNaCl |
| H-16 log de captura bajo el greeter | `tests.sh`: el kit documenta las tres rutas de log |
| H-17 sin CLI de conexión | `tests.sh`: no hay llamadas a `rustdesk --connect` en los scripts |
| H-18 server anclado a seat0/greeter | `tests.sh <host>`: detecta el usuario de la sesión gráfica |
| H-19 `os error 104` por audio/clipboard | `tests.sh`: existe la sección H-19 en este documento |
| H-20 tipo de equipo en VMs | `tests.sh`: `inventory.sh` usa `systemd-detect-virt` y mapea a `vm` |
| H-21 `paru` no es necesario (cascada de 3 vías) | `tests.sh`: existe `install_rustdesk_unattended_deb_arch` y la cascada |
| H-22 fallos silenciosos (red / tailscale up) | `tests.sh`: el kit comprueba la red y muestra la salida de `tailscale up` |
| H-23 objetivo con fish (no mandar bash suelto) | `tests.sh`: los comandos remotos van por `bash -s`; `make check` también |
| H-24 Fedora con DRM (no `.rpm` estándar) | `tests.sh <host>`: la rama fedora intenta primero el `.deb` con `libdrmtap` |
| H-26 ubicación de la auth key en el panel | `tests.sh`: existe la sección H-26; `verify-docs.sh` comprueba la URL |
| H-27 reinicio remoto (sudo/polkit) | `tests.sh`: existe la sección H-27; documenta NOPASSWD acotado y rollback |
| H-28 `local-ip-addr` obsoleto tras cambiar de red | `tests.sh`: existe la sección H-28; documenta detección, corrección y el restart |
| H-29 portátil que suspende y pierde el acceso | `tests.sh`: existe `laptop-no-suspend.sh`; `setup-remote-target.sh` tiene `--laptop` |
| H-30 la auth key se genera en la web | `tests.sh`: existe `unir-tailscale.sh`; `instalar-todo.sh` tiene `--tailscale-luego` |
| H-32 `.deb` inyectado se rompe en silencio | `tests.sh`: `check_drmtap_deps` detecta `not found` (ldd simulado) y pasa si resuelve |

```fish
./tests.sh                      # 119 comprobaciones (local)
./tests.sh USUARIO@IP           # + hallazgos en el host real
./verify-docs.sh                # 28 (comandos y URLs vigentes)
```

Para los hallazgos de comportamiento profundo (sobrevivir a un reinicio real),
la verificación es la prueba de reinicio descrita arriba: reiniciar el equipo y
comprobar que todo vuelve.

---

## H-33 — Inyección en `/etc/sudoers.d` vía `--user` (reboot-remoto.sh)

**Síntoma:** ninguno visible. El script funciona bien con nombres normales. El
problema aparece solo si el nombre de usuario trae una comilla simple.

**Causa:** `USER_RULE` (de `--user`, o deducido de `${HOST%@*}`) se interpolaba
directo dentro de un heredoc que escribe en `/etc/sudoers.d/99-reboot`:

```bash
printf '%s\n' '$(printf "$SUDO_RULE_TMPL" "$USER_RULE")' | sudo tee "$SUDOERS_FILE"
```

Con un valor como:

```bash
./reboot-remoto.sh --host "evil@1.2.3.4" --user "evil' ALL=(ALL) NOPASSWD: ALL #" --enable
```

el archivo que se escribía era:

```
evil ALL=(ALL) NOPASSWD: ALL # ALL=(ALL) NOPASSWD: /usr/bin/systemctl reboot, ...
```

Es decir: **sudo total sin contraseña**, y `visudo -cf` lo valida como
sintaxis correcta (no lo detecta).

**Vector real:** limitado — el operador controla `--user` y el heredoc corre
sobre una sesión SSH ya autenticada con TTY. Pero (a) rompe con cualquier
nombre con comilla y (b) es defensa en profundidad: un `--host` mal escrito o
un nombre exótico no debe poder inyectar reglas de sudo.

**Solución:**

1. Validar el nombre contra un patrón POSIX antes de usarlo:
   ```bash
   [[ "$USER_RULE" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "usuario invalido" >&2; exit 2; }
   ```
2. Pasar el usuario **como argumento** al heredoc (`rsh_tty -- "$rule" "$file"`)
   y leerlo con `"$1"` dentro, en vez de interpolarlo en el texto. Así una
   comilla no rompe el quoting ni inyecta líneas.

**Verificación:** `tests.sh` sección **H-33** (rechaza comilla/espacios, exige
que el usuario llegue como argumento).

**Lección:** nunca interpolar datos externos dentro de un heredoc que escribe
en sudoers (ni en ningún archivo de config privilegiado). Pasalos como
argumento o por stdin, y validalos antes.

---

## H-34 — `--authkey` avisaba tarde (AUTHKEY_POR_ARGV muerta)

**Síntoma:** ninguno. El script instalaba igual.

**Causa:** el commit `ea87efe` introdujo `AUTHKEY_POR_ARGV=1` para avisar cuando
la auth key viene por `--authkey` (queda en `~/.bash_history` del cliente y es
visible en `ps` durante toda la instalación). Pero la variable **se asignaba y
nunca se leía**: el aviso quedó a medias. `unir-tailscale.sh` sí lo hace con su
`KEY_POR_ARGV`; `instalar-todo.sh` no.

**Solución:** añadir el bloque de aviso tras parsear los argumentos, igual que
en `unir-tailscale.sh`, sugiriendo `--authkey-stdin`:

```bash
if [[ $AUTHKEY_POR_ARGV -eq 1 ]]; then
  warn "--authkey en la linea de comandos queda en el historial y en 'ps'."
  warn "  Mejor:  printf %s \"tskey-...\" | sudo ./instalar-todo.sh --authkey-stdin ..."
fi
```

**Verificación:** `tests.sh` sección **H-34** (usa `AUTHKEY_POR_ARGV`, avisa y
sugiere el stdin).

**Lección:** si declarás un flag de seguridad, usalo; una variable asignada y
nunca leída pasa shellcheck (a veces) pero es código muerto que da falsa
sensación de protección.

---

## H-35 — `printf` sin escapar mostraba mal el consejo de `--key-stdin`

**Síntoma:** el mensaje de aviso de `unir-tailscale.sh` decía:

```
▲   Mejor:  printf  "$KEY" | ./unir-tailscale.sh --key-stdin
```

con un **espacio doble** donde debía ir `%s`. El ejemplo impreso no era el
comando correcto.

**Causa:** la cadena de formato tenía un `%s` literal (parte del ejemplo de
comando) **sin escapar**, así que `printf` lo interpretó como marcador de
formato y lo reemplazó por un argumento vacío (SC2183):

```bash
printf '...Mejor:  printf %s "$KEY" | ./unir-tailscale.sh --key-stdin\n' >&2
```

**Solución:** escapar el `%s` del ejemplo como `%%s`:

```bash
printf '...Mejor:  printf %%s "$KEY" | ./unir-tailscale.sh --key-stdin\n' >&2
```

**Verificación:** `tests.sh` sección **H-35**; y shellcheck 0.10.0 lo marca como
SC2183.

**Lección:** en `printf`, cualquier `%` que deba mostrarse literal va como `%%`.
Esto vale sobre todo en mensajes que **enseñan a usar el propio programa**:
un ejemplo mal impreso confunde más que no darlo.

---

## Nota de CI: shellcheck 0.9.0 no caza H-34/H-35

El job `shellcheck` del CI instala con `apt-get install shellcheck`, que en
Ubuntu da **0.9.0**. Esa versión **no reporta** SC2034 (variable sin usar) en el
caso de H-34 ni SC2183 en el de H-35, así que el CI pasa en verde aunque el
problema exista. Con **shellcheck 0.10.0** el CI falla en ambos.

**Sugerencia:** fijar la versión con el binario estático (reproducible):

```yaml
- name: shellcheck 0.10.0
  run: |
    curl -sL https://github.com/koalaman/shellcheck/releases/download/v0.10.0/shellcheck-v0.10.0.linux.x86_64.tar.xz | tar -xJ
    sudo mv shellcheck-v0.10.0/shellcheck /usr/local/bin/
```

**Lección:** un linter que sube solo puede quedarse atrás sin que nadie lo note.
Fijá la versión de las herramientas de CI.

---

## H-36 — En Arch, el .deb inyectado dejaba RustDesk sin menú, sin bandeja y sin aviso de libs

**Verificado:** ✅ (CachyOS, HP 15-db0xxx, 28 oct 2026)

**Síntoma:** tras instalar RustDesk por la vía del `.deb` oficial en Arch
(la que evita el AUR, ver H-14/H-24), pasaban tres cosas:

1. RustDesk **no aparecía en el menú de aplicaciones**: solo se abría por CLI
   (`rustdesk`), porque nadie copiaba los `.desktop`.
2. En el log del servicio:
   ```
   Failed to load ayatana-appindicator3 or appindicator3 dynamic library
   libayatana-appindicator3.so.1: cannot open shared object file
   ```
   → sin icono de bandeja.
3. Si faltaba una librería **del binario principal** (gtk3, etc.), no se avisaba:
   solo se comprobaba `libdrmtap` con `ldd`.

**Causa:** la extracción a mano del `.deb` copiaba `usr/share/rustdesk` y
`libdrmtap`, pero **no** `usr/share/applications`, ni `usr/share/icons`, ni
instalaba el proveedor del appindicator. Y la verificación de dependencias
cubría solo `libdrmtap`, no el binario.

**Solución (en `install_rustdesk_unattended_deb`):**
- Copiar `usr/share/applications/*.desktop` y `usr/share/icons/` del `.deb`.
- `maybe_install_appindicator()`: instalar `libayatana-appindicator` (Arch),
  `libayatana-appindicator3-1` (Debian) o `libayatana-appindicator-gtk3`
  (Fedora) si falta la librería. Es **opcional**: si falla, no aborta.
- `check_rustdesk_bin_deps()`: `ldd` del binario principal, ignorando
  `libcuda`/`libnvidia` (que no son obligatorios; el plugin de GPU los pide
  solo si existen).

**Verificación:** `tests.sh` sección **H-36** (11 comprobaciones).

**Lección:** cuando inyectás un paquete a mano (fuera del gestor), no basta con
"el binario": también hacen falta los `.desktop`, los iconos y las dependencias
opcionales. Y hay que verificar TODOS los binarios involucrados, no solo la
librería estrella.

## H-37 — El desatendido en Wayland depende del portal XDG + PipeWire (sin chequeo)

**Verificado:** ✅ (CachyOS/msi MS-7A38, 28 oct 2026)

**Síntoma:** en Wayland, si el capturador DRM (`libdrmtap`) no carga —por
ejemplo tras un update que cambia el ABI de `libdrm`/`libEGL`—, RustDesk cae
al **portal de escritorio (ScreenCast)** para capturar pantalla. Ese portal
necesita `xdg-desktop-portal` + un backend (`kde`/`gnome`/`wlr`) + **PipeWire**.
Si falta cualquiera de los tres, el desatendido **no captura nada** y el
operador ve la pantalla negra, sin ningún error visible.

**Causa:** `setup-remote-target.sh` verificaba `libdrmtap` (H-14) y el binario
(H-36), pero **no** la pila del portal + PipeWire. En un cliente doméstico
recién migrado de Windows, esa dependencia rota pasa desapercibida hasta que ya
no hay acceso — justo cuando más se necesita.

**Impacto:** alto en migraciones Windows→CachyOS domésticas (el cliente no sabe
diagnosticar; el operador descubre el problema recién al conectar).

**Solución:** `check_wayland_capture_stack()` en `setup-remote-target.sh`,
invocada desde la sección de diagnóstico ("Pila de captura Wayland"):
- comprueba que exista `xdg-desktop-portal` y un backend (`kde`/`gnome`/`wlr`),
- verifica que `pipewire` esté instalado y **activo en el user bus** del usuario
  objetivo (vía `runuser -u <user> -- systemctl --user is-active`),
- avisa si falta `wireplumber` (opcional pero recomendado),
- da el mensaje de arreglo concreto (`sudo pacman -S xdg-desktop-portal-kde`,
  `systemctl --user enable --now pipewire wireplumber`).

**Verificación:** `tests.sh` sección **"Pila de captura Wayland"** (8
comprobaciones, con árbol de portales simulado y stub de PipeWire).

**Lección:** en Wayland la captura tiene DOS vías (DRM y portal). El kit ya
auditaba la primera; la segunda es igual de crítica y ahora se audita antes de
prometer acceso remoto desatendido.

## H-38 — El inventario falla con locale ≠ inglés; otros agentes compiten por la captura

**Verificado:** ✅ (prueba real contra cliente/msi CachyOS **en español**, 28 oct 2026)

**Contexto:** prueba end-to-end tratando un equipo real como cliente doméstico
que migra de Windows a CachyOS. Salió un bug grave y una mejora.

### Bug: `inventory.sh` daba CPU/Swap vacíos con el sistema en español

**Síntoma:** el inventario salía con `CPU: ?`, `Núcleos: ?`, `Swap: ?`.

**Causa:** `inventory.sh` parseaba la salida **traducida** de `lscpu`, `free`,
`df` y `sensors`. En español:
- `lscpu` dice "Nombre del modelo" (no "Model name"),
- `free` dice "Intercambio" (no "Swap:"),
- `df` dice "usados de".

Como el cliente doméstico argentino suele tener el sistema **en español**, el
inventario salía incompleto y el operador creía que la máquina no reportaba.

**Solución:** forzar `LC_ALL=C` en `lscpu`/`free`/`df`/`lsblk`/`sensors`/`upower`
+ fallback a `/proc/cpuinfo` y `nproc` para la CPU (independientes del locale).

### Mejora: aviso de OTROS agentes de acceso remoto

**Síntoma (posible):** dos agentes de control remoto (p. ej. DWAgent + RustDesk)
pueden **competir** por la captura en Wayland (uinput/DRM/portal ScreenCast):
uno captura, el otro ve negro.

**Solución:** sección de diagnóstico "Otros agentes de acceso remoto" que
detecta `dwagent`, `anydesk`, `teamviewer`, `chrome-remote-desktop`, `xrdp`,
`vncserver`, `tigervnc`, `guacamole` (unidades systemd activas **y** procesos
sueltos). Avisa, no toca nada.

### Mejora: filtro de discos de tamaño 0

`sdb 0B Storage Device` y `sdc 0B USB` (lectores vacíos / USB sin medio)
aparecían como discos basura en el inventario. Ahora se filtran.

**Verificación:** `tests.sh` sección **H-38** (8 comprobaciones).
**Probado en vivo** contra un cliente real con locale es_ES y DWAgent activo.

**Lección:** el kit se diseñó en equipos **en inglés**. Un cliente real
doméstico casi siempre está **en español** y con software que uno no eligió.
Forzar `LC_ALL=C` al parsear herramientas del sistema y avisar de agentes
remotos ajenos son dos defensas que solo aparecen probando en el mundo real.

## H-39 — `rustdesk-password.sh` fallaba con error confuso al no poder usar sudo

**Verificado:** ✅ (probado contra cliente real/msi, 28 oct 2026)

**Síntoma:** al rotar la contraseña de RustDesk en un cliente donde `sudo`
pedía contraseña (o la dada era incorrecta), el script terminaba con:

```
sudo: 3 incorrect password attempts
./rustdesk-password.sh: línea 1: target: variable sin asignar
```

Un mensaje **inútil**: no decía ni que la contraseña de sudo era incorrecta ni
qué hacer. El operador quedaba a ciegas.

**Causa:** dos defectos en `install_remote`:

1. La rama **REMOTO** del bloque de escritura de config **no** tenía
   `|| { err ...; return 1; }` (la rama **LOCAL** sí). Al fallar sudo, el script
   seguía adelante en vez de abortar con un mensaje claro.
2. El `trap ... EXIT` de limpieza del helper referenciaba `$target`, que es
   `local` de la función. El trap corre al **salir** de la función, cuando
   `$target` ya no existe → con `set -u` explotaba con "variable sin asignar",
   tapando el error real.

**Solución:**
- Añadir manejo de error en la rama remota, con mensajes que distinguen
  "contraseña de sudo incorrecta" (con `SUDO_PASS`) de "sudo NOPASSWD no
  configurado", y que sugieren cómo verificarlo (`ssh host 'sudo true'`).
- Incrustar el valor de `$target` en el trap al **definirlo**
  (`printf '%q' "$target"`), no diferir la expansión.

**Verificación:** `tests.sh` sección **H-39**.
**Probado en vivo** contra el cliente real (sudo con contraseña desconocida):
ahora da un error claro en dos líneas, sin la traza confusa.

**Lección:** un buen manejo de error no es cosmético. En soporte remoto, un
mensaje como "variable sin asignar" hace perder minutos; "contraseña de sudo
incorrecta, verificala así" resuelve el problema. Y los traps con `set -u` y
variables `local` son una trampa clásica.

---

## H-40 — El portapapeles por SSH fallaba en un guest con fish (y con Wayland sin env)

**Verificado:** ✅ (HP → MSI CachyOS/Wayland, 28 oct 2026)

**Síntoma:** `clip-vm.sh put` (host → guest) devolvía:

```
fish: Uso no soportado de '='. En fish, utiliza 'set f "$(mktemp)"'.
Aviso: falló el envío al guest (rc=127)
```

El portapapeles entre host y guest no se propagaba.

**Causa (dos capas):**

1. **Bash suelto por SSH a un guest con fish (H-23).** La rama `put` mandaba un
   script bash sin `bash -s`; el shell del guest (fish) lo interpretaba y
   `f="$(mktemp)"` es inválido en fish.
2. **`WAYLAND_DISPLAY` vacío por SSH.** Aunque se arregle lo anterior,
   `wl-copy`/`wl-paste` fallan con *"Failed to connect to a Wayland server"*
   porque por SSH no se hereda la sesión gráfica. El socket **no es fijo**:
   KDE suele usar `wayland-1`, no `wayland-0`.

Un tercer detalle: `wl-copy` queda **residente** sirviendo el portapapeles; si
se lanza en primer plano, el script parece colgado.

**Solución (en `clip-vm.sh`):**
- Mandar todo script al guest con **`bash -s`** (nunca bash suelto).
- `guest_env()`: descubrir el entorno gráfico del guest — `XDG_RUNTIME_DIR` y
  el socket Wayland real (`/run/user/<uid>/wayland-*`, priorizando
  `wayland-1`). Exportarlos en `get`, `put` y `show`.
- Lanzar `wl-copy` con **`nohup ... &` + `disown`** tanto en el `get` (host)
  como en el `put` (guest) para no bloquear.

**Verificación:** `tests.sh` sección **clip-vm.sh** (11 comprobaciones) y prueba
real HP↔MSI en ambas direcciones.

**Lección:** un puente por SSH hacia un guest Wayland necesita **el entorno
gráfico explícito** (runtime dir + socket), no basta con `wl-clipboard`. Y el
nombre del socket Wayland no es portable: hay que descubrirlo, no asumir
`wayland-0`.

---

## H-41 — `ls` como alias de `eza` contamina variables en scripts fish

**Verificado:** ✅ (HP CachyOS, 29 oct 2026)

**Síntoma:** `alta-cliente.sh` (script de operador en fish) no encontraba la
clave SSH del operador, aunque el archivo existía:

```
✘ No hay clave SSH en ~/.ssh/id_ed25519.pub
```

**Causa:** el script capturaba la ruta con `set -l K (ls ~/.ssh/id_*.pub ...)`.
En la máquina del operador, `ls` es un **alias/wrapper de `eza --color=always`**
(habitual en CachyOS/fish). La salida con colores ANSI **contamina la variable**:

```
set -l K (ls ~/.ssh/id_ed25519.pub)
# $K = "\e[1;33m...\e[0m /home/jp/.ssh/id_ed25519.pub"  ← no es una ruta válida
```

`test -f $K` falla porque la cadena lleva códigos de escape.

**Solución:** usar herramientas que **no pasan por el alias**, como
`path filter` (nativo de fish):

```fish
set -l KEY_PUB (path filter ~/.ssh/id_*operador.pub 2>/dev/null | head -1)
```

Alternativas: `command ls --color=never`, `find`, o `/usr/bin/ls`.

**Verificación:** `tests.sh` y prueba real en HP y MSI (la autodetección de
clave devuelve la ruta limpia, `len=32` en vez de 167 con colores).

**Lección:** en scripts, nunca asumas que `ls` es el binario. Un alias en
fish (`.config/fish/config.fish` o distro) rompe la captura de salida. Usá
`path filter`/`find` para listar rutas.

---

## H-42 — Migrar el sistema de disco regenera el `machine-id` y cambia el ID de RustDesk

**Verificado:** ✅ (HP, migración HDD→SSD, 29 oct 2026)

**Síntoma:** tras migrar el sistema (btrfs `send/receive` a un disco nuevo), el
ID de RustDesk del equipo **cambió**:

```
antes:  1752551151
después: 1503822041
```

Para un equipo **unattended** eso es grave: quien tenga guardado el ID viejo
**ya no puede conectarse**. El operador debe actualizar su ficha del cliente.

**Causa:** el ID de RustDesk se deriva de la **identidad del sistema**, que
incluye el `machine-id`. Al migrar el sistema de archivos, `/etc/machine-id`
se **regeneró** (fecha de cambio `2026-10-29 11:36`, justo durante la migración):

```
$ cat /etc/machine-id
2806202463764cf1b2a268d8f5c7d0c6      # nuevo tras migrar
```

`/etc/machine-id` nuevo ⇒ ID de RustDesk nuevo. (En el caso real, la migración
en caliente copió el contenido pero el `machine-id` se regeneró al primer
arranque del disco nuevo.)

**Solución / mitigación:**
- **Antes de migrar**, guardar `cat /etc/machine-id`.
- **Después de migrar**, restaurarlo (`/etc/machine-id` + copia en
  `/var/lib/dbus/machine-id`) **antes** de arrancar servicios que dependan de él,
  para conservar el ID de RustDesk.
- Si ya cambió, **actualizar la ficha del cliente** con el ID nuevo y avisar a
  quien tenga el viejo guardado.
- Verificación: `rustdesk --get-id` y compararlo con el ID esperado.

**Lección:** el ID de RustDesk **no** está atado al hardware, sino a la
identidad del SO (`machine-id`). Clonar/migrar un disco puede cambiarlo en
silencio y romper el acceso desatendido.

---

## H-43 — Compartir la clave SSH entre operador y cliente (mala práctica)

**Verificado:** ✅ (HP y MSI, 29 oct 2026)

**Síntoma:** en el montaje inicial, el **operador (HP)** y el **cliente/segundo
operador (MSI)** usaban **la misma clave SSH**:

```
HP  ~/.ssh/id_ed25519.pub → ssh-ed25519 AAAAC3...Fc pi-agent@MSI
MSI ~/.ssh/id_ed25519.pub → ssh-ed25519 AAAAC3...Fc pi-agent@MSI   ← idénticas
```

Consecuencias:
- **No auditable**: una conexión no se puede atribuir a un equipo concreto.
- **Fallo en cascada**: rotar o filtrar esa clave rompe el acceso en **ambas**
  máquinas a la vez.
- **Confusión de rol**: la clave se llamaba `pi-agent@MSI` pero vivía en el HP.

**Solución (split de claves por operador):**
1. Generar una clave **propia** en cada máquina:
   `ssh-keygen -t ed25519 -f ~/.ssh/id_<rol>_operador -C "<rol>@<host>"`.
2. **Autorizar cruzado**: la pública de cada uno en el `authorized_keys` del otro.
3. Actualizar `~/.ssh/config` (un `Host` por operador, con su `IdentityFile`).
4. **Retirar** la clave compartida de los `authorized_keys`.
5. Verificar que la vieja **ya no sirve**:
   `ssh -i vieja -o IdentitiesOnly=yes -o -F /dev/null host true` → `Permission denied`.

**Resultado (2 operadores reales):**

| | HP | MSI |
|---|---|---|
| Clave | `id_hp_operador` (`hp-operador@HP`) | `id_msi_operador` (`msi-operador@MSI`) |
| Entra a | `msi-operador` ✔ | `hp-operador` ✔ |

Extra: el HP **no tenía `sshd`**;
hubo que `systemctl enable --now sshd` para poder ser operado.

**Lección:** en flotas con varios operadores, **una identidad SSH por máquina**.
Nunca compartas la clave privada entre nodos: impide auditar, y un compromiso
afecta a toda la flota.

---

## H-44 — Migrar el sistema de disco deja libvirt sin poder arrancar (`status=243/CREDENTIALS`)

**Verificado:** ✅ (HP, migración HDD→SSD, 29 oct 2026)

**Síntoma:** tras migrar el sistema a un disco nuevo, `libvirtd` **falla en
bucle** y no se puede abrir virt-manager ni `virsh`:

```
libvirtd.service: Failed to determine local credential key: No such file or directory
libvirtd.service: Failed at step CREDENTIALS spawning /usr/bin/libvirtd
libvirtd.service: Main process exited, code=exited, status=243/CREDENTIALS
libvirtd.service: Start request repeated too quickly.
libvirtd.service: Failed with result 'start-limit-hit'.
```

**Causa (dos capas encadenadas):**

1. **Falta la clave de credenciales de systemd.** El drop-in de libvirt
   (`/usr/lib/systemd/system/libvirtd.service.d/10-secret.conf`) usa:

   ```
   LoadCredentialEncrypted=secrets-encryption-key:/var/lib/libvirt/secrets/secrets-encryption-key
   ```

   Para descifrar eso, systemd necesita su clave maestra
   **`/var/lib/systemd/credential.secret`**. Una migración/copia del sistema
   de archivos **no siempre la lleva**, y el secret de libvirt queda cifrado
   con una clave que ya no existe.

2. **Círculo vicioso con el servicio reparador.** El drop-in también tiene
   `Requires=virt-secret-init-encryption.service`, pero ese servicio solo
   corre si la clave **NO** existe (`ConditionPathExists=!…secrets-encryption-key`).
   Como la clave existe (aunque sea indescifrable), el reparador se salta → y
   sin él, `libvirtd` se niega a arrancar.

**Solución:**

1. Comprobar que **no hay secretos que perder**: `ls /var/lib/libvirt/images`
   (si no hay VMs con cifrado, la clave se puede regenerar sin pérdida).
2. **Backup** y **borrar** la clave indescifrable:
   ```bash
   sudo cp -a /var/lib/libvirt/secrets/secrets-encryption-key /root/
   sudo rm -f /var/lib/libvirt/secrets/secrets-encryption-key
   ```
3. Dejar que el servicio la **regenere** (crea también la `credential.secret`):
   ```bash
   sudo systemctl reset-failed libvirtd.service
   sudo systemctl start virt-secret-init-encryption.service
   ```
4. Verificar que aparecieron ambas claves y arrancar:
   ```bash
   ls -la /var/lib/systemd/credential.secret
   ls -la /var/lib/libvirt/secrets/secrets-encryption-key
   sudo systemctl start libvirtd.service   # o el socket
   ```

**Resultado:** `libvirtd` activo, 0 servicios fallidos.

**Lección:** al **clonar/migrar un sistema Linux**, dos identidades pueden no
copiarse y romper servicios en silencio: el **`machine-id`** (cambia el ID de
RustDesk, ver **H-42**) y la **`credential.secret`** de systemd (rompe
`LoadCredentialEncrypted` y, con ello, libvirt). Conviene copiarlas
explícitamente **antes** de migrar, o regenerar los secretos dependientes
**después**.

---

## H-45 — El kit de Windows se escribió incompleto: `inventory.ps1` llamaba a una función inexistente

**Verificado:** ✅ (revisión de código, 29-oct-2026)

Al preparar el equivalente Windows del kit, `inventory.ps1`:

1. terminaba con `Ok "guardado: …"` **sin que `Ok` estuviera definida** en el
   script (solo existía en `setup-remote-target.ps1`) → en PowerShell el script
   habría fallado con `Ok: no se reconoce…` justo al guardar la ficha;
2. anunciaba en su `.SYNOPSIS` que generaba **texto, JSON y Markdown**, pero
   **nunca escribía el `.md`** ni definía el formateador.

**Solución:** definir `Ok`/`Warn` en `inventory.ps1` y añadir `Get-Markdown`
que produce la ficha en Markdown (con tablas), guardándola además como
`inventory.md`.

**Lección:** un script nuevo que "copia" el patrón de otro **no hereda sus
helpers**. Al portar de Linux a Windows, revisar que cada `.ps1` sea
autocontenido (o comparta un `.psm1`).

---

## H-46 — `rustdesk-password.ps1`: `-Set 'Clave'` NO pasa la clave (confusión switch/parámetro)

**Verificado:** ✅ (revisión de código, 29-oct-2026)

El parámetro se declara como `[switch]$Set` (booleano) y la clave en
`[string]$Password`, pero el `.SYNOPSIS` y el README mostraban el uso
`.\rustdesk-password.ps1 -Set 'MiClaveSegura'`. En PowerShell, `[switch]` **no
acepta un valor posicional con espacio**: el argumento `'MiClaveSegura'` queda
como argumento sobrante y `$Password` continúa vacío → el script abortaba con
`-Set requiere -Password`.

**Solución:** documentar y usar siempre `-Set -Password 'Clave'`, y aclararlo
en el propio script.

**Lección (PowerShell):** `[switch]` es un **flag**; para recibir un valor hay
que usar `[string]`/`[Parameter(Mandatory)]`. No mezclar "activar acción" con
"pasar dato" en el mismo nombre posicional.

---

## H-47 — `2>$null` no silencia el stderr de un `.exe` nativo en PowerShell

**Verificado:** ✅ (revisión de código, 29-oct-2026)

En `rustdesk-password.ps1` la llamada

```powershell
& $rdExe --password $Password 2>$null
```

pretendía ocultar el ruido de la CLI de RustDesk. Pero `2>$null` solo
redirecciona el *error stream de PowerShell*; el **stderr real de un proceso
nativo** (`.exe`) sigue saliendo por la consola en Windows PowerShell 5.1 y
puede, además, convertirse en `NativeCommandError` con `$ErrorActionPreference`
en modo estricto.

**Solución:**

```powershell
& $rdExe --password $Password 2>&1 | Out-Null
```

Es decir, **fusionar stderr en stdout** (`2>&1`) y descartar la tubería. Como
efecto secundario, el `$LASTEXITCODE` se consulta igual después.

**Lección:** otra vez la **zona gris**: `2>$null` sólo sirve para cmdlets de
PowerShell; para binarios nativos usar `2>&1 | Out-Null`. Esto ya había
mordido en Linux con `&&`/`||` en fish (H-23): cada shell/plataforma tiene su
propia trampa de redirección.

---

## H-48 — `rustdesk-password.sh install` rompía la verificación remota por comillas anidadas (H-23 otra vez)

**Verificado:** ✅ (prueba real contra el MSI, 29-oct-2026)

Al rotar la contraseña permanente por SSH, el paso final de **verificación**
mandaba:

```bash
ssh "$target" "sudo -S -p '' bash -c \"$vercmd\""
# con vercmd="grep -c \"^password = '01\" /root/.config/rustdesk/RustDesk.toml"
```

El comando viaja por el **shell remoto**, que en CachyOS es **fish**. Fish no
entiende la anidación de comillas y abortaba con:

```
fish: Final inesperado del string, las comillas no están balanceadas
sudo -S -p '' bash -c "grep -c "^password = '01" /root/..."
```

**La rotación en sí ya había funcionado** (ambos configs actualizados con
backup y `rustdesk` reiniciado); lo que falló fue solo el mensaje de
verificación, dando la falsa impresión de error.

**Solución:**

1. Enviar el comando por **STDIN a `bash -s`** (el patrón de H-23), sin
   `bash -c` ni comillas anidadas.
2. Usar un patrón de `grep` sin comillas simples conflictivas.
3. Verificar **siempre** el config del usuario (no necesita sudo) y verificar
   el de root con `sudo -n`; si sudo pide contraseña, **avisar y omitir** en
   vez de romper.

**Lección:** cualquier `ssh host "...bash -c \"...\"..."` es una bomba de
relojería si el host puede tener fish. La regla del kit (H-23) es **siempre**
`printf '%s\n' "$SCRIPT" | ssh host bash -s`, y la primera verificación
remota hay que hacerla **en un host con fish** para cazarlo.

---

## H-49 — `pam_faillock` convierte los reintentos de contraseña de sudo en un auto-bloqueo (trampa para agentes)

**Verificado:** ✅ (prueba real contra el MSI, 29-oct-2026)

Síntoma: un agente intenta una operación con `sudo -S` y la contraseña que el
usuario **sabe correcta** es rechazada una y otra vez. Al probar variantes
(`krishna`, `Krishna`, `krishna1`…), todas fallan; el agente concluye
erróneamente que "la contraseña cambió".

**Causa real:** `pam_faillock` cuenta los fallos y **bloquea la autenticación
sudo del usuario** tras 3 intentos. A partir del bloqueo, **incluso la
contraseña correcta es rechazada**, formando un bucle de falsos negativos. En
los logs:

```
pam_faillock(sudo:auth): User jp is temporarily locked out due to 3 consecutive failed login attempts
pam_unix(sudo:auth): auth could not identify password for [jp]
```

Detalle clave: el bloqueo aplica a **sudo** (el stack PAM de `sudo`), pero
`su` usa un stack distinto **sin faillock** → `su` sigue aceptando la
contraseña correcta. Eso permite **diagnosticar y desbloquear**:

```bash
printf '%s\n' 'LA_CONTRASEÑA' | su -c 'id'          # ¿es correcta? (salta faillock)
printf '%s\n' 'LA_CONTRASEÑA' | su -c 'faillock --user jp --reset'
```

**Solución / reglas para agentes:**

1. **No reintentar a ciegas** con `sudo -S`: cada fallo acerca el bloqueo.
2. Verificar una contraseña con **`su -c`** (no toca faillock) o con
   `sudo -A` una sola vez.
3. Si sudo empieza a rechazar algo que "debería" funcionar, **comprobar
   `faillock --user <u>`** antes de dudar de la contraseña.
4. Desbloquear con `faillock --user <u> --reset` (vía `su` o desde consola).

**Lección:** "contraseña incorrecta" puede significar en realidad **"cuenta
bloqueada"**. Un agente que martillea `sudo` se autobloquea y se engaña a sí
mismo. Probar credenciales por un camino que **no cuente fallos** (`su`) y
mirar los logs de PAM antes de sacar conclusiones.

---

## H-50 — Los scripts PowerShell del kit Windows tenían errores que solo se ven ejecutándolos

**Verificado:** ✅ (PowerShell 7.4.6 real, 29-oct-2026)

Al instalar **PowerShell 7.4.6 en el operador** (tarball portable, sin root) y
validar los `.ps1` con el parser de PowerShell + **PSScriptAnalyzer**, aparecieron
dos fallos que la revisión "a ojo" y los tests por `grep` **no detectaban**:

1. **`inventory.ps1`: `}` sobrante al final** → error de sintaxis
   (`Unexpected token '}' in expression or statement`). El script **habría
   fallado siempre** al ejecutarse, pero los tests de grep pasaban.
2. **`setup-remote-target.ps1`: `-RdPass` y `-Hostname` eran parámetros
   muertos** (`PSReviewUnusedParameter`): se declaraban y se documentaban, pero
   **nunca se usaban**. Pedir `-RdPass 'x'` no hacía absolutamente nada.

**Solución:** corregir el `}` y **implementar** de verdad `-RdPass` (fija la
contraseña permanente de RustDesk, con aviso si la versión no acepta `--password`
por CLI) y `-Hostname` (`Rename-Computer`).

**Prevención:** `tests.sh` ahora valida la **sintaxis real** de los `.ps1` con
`pwsh` cuando está disponible (se instala portable en `~/.local/opt/pwsh`).

**Lección:** para código PowerShell, **los tests por `grep` no bastan**: un
script puede "parecer" correcto y no ejecutarse nunca. Hay que parsearlo (y, si
se puede, ejecutarlo). Igual que con fish (H-23): el shell/plataforma del
objetivo es parte de la prueba, no un detalle.

**Cómo instalar pwsh portable (sin root):**

```bash
curl -sL -o /tmp/pwsh.tar.gz \
  https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/powershell-7.4.6-linux-x64.tar.gz
mkdir -p ~/.local/opt/pwsh && tar -xzf /tmp/pwsh.tar.gz -C ~/.local/opt/pwsh
chmod +x ~/.local/opt/pwsh/pwsh
```

---

## H-51 — Los `.ps1` necesitan BOM UTF-8 o Windows PowerShell 5.1 los rompe

**Verificado:** ✅ (cliente Windows real, 29-oct-2026)

Al correr `setup-remote-target.ps1` en el Windows 11 de un cliente, falló con:

```
En setup.ps1: 101 Carácter: 1
+ }
+ ~
Token '}' inesperado en la expresión o la instrucción.
```

**Causa:** los `.ps1` tienen caracteres no-ASCII (`—`, `á`, `é`, `═`) pero **no
tenían BOM UTF-8**. **Windows PowerShell 5.1** (el que trae Windows) lee los
archivos **sin BOM como ANSI/Windows-1252** → malinterpreta los bytes y el
parser revienta con un error **engañoso** (un `}` en una línea que no tiene
nada que ver con el problema real).

**Por qué no se cazó antes:** `pwsh` 7.x (Linux) **lee UTF-8 sin BOM por
defecto**, así que la validación de sintaxis daba OK. El fallo es **específico
de Windows PowerShell 5.1**. Además, PSScriptAnalyzer **sí lo advertía**
(`PSUseBOMForUnicodeEncodedFile`) y no se le hizo caso.

**Solución:** añadir **BOM UTF-8 (`EF BB BF`)** a todos los `.ps1`, y un test
que lo exija.

**Lección:** validar PowerShell con `pwsh` en Linux **no es suficiente**: hay
que probarlo en **Windows PowerShell 5.1** (o, como mínimo, hacer caso a
PSScriptAnalyzer sobre el BOM). Igual que con fish (H-23): la plataforma real
del objetivo es parte de la prueba.

---

## H-52 — GitHub raw cachea y puede servir una versión vieja del script

**Verificado:** ✅ (29-oct-2026)

Tras corregir el BOM (H-51) y mergear a `main`, el `curl` a
`raw.githubusercontent.com/.../main/windows/setup-remote-target.ps1` seguía
devolviendo el archivo **sin BOM** durante unos minutos. Consultando por
**SHA del commit** ya salía con BOM. Era **caché del CDN** de GitHub raw.

**Implicación:** si actualizas un script que se distribuye por URL raw y lo
pruebas enseguida, puedes estar probando la versión **vieja** y no entender por
qué sigue fallando.

**Solución / consejo:**

- Usar la URL **por SHA** (`.../<commit-sha>/ruta`) para pruebas reproducibles.
- O esperar unos minutos a que el CDN se refresque.
- El repositorio (`git`) siempre tiene la versión correcta; el problema es solo
  del **servidor raw con caché**.

**Lección:** al distribuir por `raw.githubusercontent.com`, **el contenido
puede ir con retraso**. Para "traer el script y ejecutarlo" (patrón
`irm | iex`) conviene verificar la versión o usar tags/SHA.

---

## H-53 — Con un cliente que no sabe RustDesk, fija la contraseña permanente ANTES de todo

**Verificado:** ✅ (cliente Windows real, 29-oct-2026)

Situación real: conexión a un cliente Windows por RustDesk (redes distintas,
relay público). El cliente **no sabía usar RustDesk** ni darte bien ID/contraseña.
A mitad del trabajo **se cayó la conexión** (probablemente el equipo entró en
suspensión) y **se perdió el acceso**: el cliente no sabía reconectar ni pasar
los datos correctamente.

**Causa raíz (de método):** se trabajó con la **contraseña temporal / aceptación
de un solo uso**, sin dejar el acceso garantizado. Cualquier caída (suspensión,
reinicio, cierre de la app) deja al operador **fuera**.

**Solución / regla:**

1. **Lo PRIMERO** al conectar con un cliente: fijar la **contraseña permanente**
de RustDesk (⚙ Ajustes → Seguridad → Contraseña permanente). **Hacerlo el
operador** por la pantalla compartida, no pedírselo al cliente.
2. **Anotar** ID + contraseña en la ficha del cliente (`~/operador/clientes/`).
3. **Después** de tener el acceso garantizado, instalar **Tailscale + SSH**.
4. Ver el runbook completo en [`docs/acceso-primero.md`](acceso-primero.md).

**Lección:** con un cliente que "no sabe", **el acceso es lo primero y no puede
depender de él**. Si haces primero Tailscale/SSH/drivers y algo se cae (o el
equipo se suspende, ver modern standby más abajo), quedas fuera sin poder
volver. Orden correcto: **acceso → anotar → Tailscale/SSH → lo demás.**
