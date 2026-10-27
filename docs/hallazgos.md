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
pero conviene arreglarlo para que resolved gestione bien `search tailc15fd9.ts.net`.
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

```fish
./tests.sh                      # 85 comprobaciones (local)
./tests.sh USUARIO@IP           # + hallazgos en el host real
./verify-docs.sh                # 28 (comandos y URLs vigentes)
```

Para los hallazgos de comportamiento profundo (sobrevivir a un reinicio real),
la verificación es la prueba de reinicio descrita arriba: reiniciar el equipo y
comprobar que todo vuelve.
