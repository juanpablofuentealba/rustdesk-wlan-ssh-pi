# Hallazgos verificados (pruebas reales)

Registro de comportamientos **comprobados en máquinas reales**, no supuestos.
Cada hallazgo indica cómo se verificó, para que puedas reproducirlo o refutarlo.

> Última actualización: 2026-10-26
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

```fish
./tests.sh                      # 119 comprobaciones (local)
./tests.sh USUARIO@IP           # + hallazgos en el host real
./verify-docs.sh                # 28 (comandos y URLs vigentes)
```

Para los hallazgos de comportamiento profundo (sobrevivir a un reinicio real),
la verificación es la prueba de reinicio descrita arriba: reiniciar el equipo y
comprobar que todo vuelve.
