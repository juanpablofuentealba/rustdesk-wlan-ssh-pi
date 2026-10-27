# Tailscale — acceso remoto sin abrir puertos

**Tailscale** crea una red privada (VPN mesh) entre tus dispositivos. Cada máquina
recibe una IP fija propia (`100.x.y.z`) y todas se ven entre sí **desde cualquier
red**, sin tocar el router, sin IP pública, sin DuckDNS.

Es la forma recomendada de acceder a tus PCs cuando **no estás en casa**.

---

## Por qué Tailscale (y no abrir puertos + DuckDNS)

El enfoque clásico es: IP dinámica → DuckDNS + abrir puertos en el router.
Funciona, pero depende de **cuatro cosas** que deben estar todas bien:

```
1. DuckDNS apuntando a tu IP actual      (necesita updater corriendo)
2. Puertos redirigidos en el router      (NAT / port forwarding)
3. Tu PC encendido y el servicio arriba
4. El ISP no bloqueando / cambiando la IP
```

Si **una** falla, no hay acceso. Es un castillo de naipes.

Tailscale reemplaza todo eso:

| | DuckDNS + puertos | **Tailscale** |
|---|---|---|
| Abrir puertos | Sí | **No** |
| Updater de IP | Sí | **No** |
| Depende del router | Sí | **No** |
| IP fija | No (cambia) | **Sí (`100.x`)** |
| Cifrado | El que pongas | **Sí, por defecto** |
| Complejidad | Alta | **Baja** |

---

## Cómo funciona (idea general)

```
            ┌─────────────────────────────┐
            │      Red Tailscale          │
            │  (privada, cifrada, mesh)   │
            │                             │
 OPERADOR ──┤  100.101.102.103            ├── CLIENTE
  (tú)      │                             │  (remoto)
            │  100.201.202.203            │
            └─────────────────────────────┘
                        ▲
                        │
             Funciona aunque cada PC esté
             en una red / ciudad distinta
```

Cada PC tiene **dos direcciones**:

| Dirección | Sirve para | Ejemplo |
|---|---|---|
| **LAN** (`192.168.x.x`) | Misma red local | `192.168.1.20` |
| **Tailscale** (`100.x.y.z`) | Cualquier red | `100.201.202.203` |

Tailscale hace NAT traversal: los paquetes salen y llegan **directo entre las
máquinas**, sin servidor intermedio cuando es posible.

---

## Instalación

### En cada PC que quieras conectar

```fish
# En CachyOS/Arch está en los repos oficiales:
sudo pacman -S --needed tailscale
sudo systemctl enable --now tailscaled

# Autenticar (abre un enlace en el navegador)
sudo tailscale up
```

`tailscale up` te da un enlace del tipo:

```
To authenticate, visit:
    https://login.tailscale.com/a/xxxxxxxxxxxx
```

Ábrelo, entra con tu cuenta (Google/GitHub/Microsoft/email) y autoriza.

> **Importante:** usa **la misma cuenta** en todos los PCs. Así se ven entre sí.

> **Ojo:** el login por navegador solo sirve en un PC con sesión gráfica. En un
> equipo recién instalado (o al que entrás a ciegas) no hay navegador: usá una
> **auth key**. Ver la sección siguiente.

---

## Generar la auth key (paso a paso en la web)

Una **auth key** es un string que empieza con `tskey-auth-...` y reemplaza al
login por navegador. Con ella, `tailscale up` **no pide nada**:

```fish
sudo tailscale up --auth-key=tskey-auth-XXXX
```

### ¿Dónde está en la web? (la duda más común)

El link directo a la página de keys:

```fish
xdg-open "https://login.tailscale.com/admin/settings/keys"
```

`login.tailscale.com` y `console.tailscale.com` llevan a **la misma consola**; si
un link no responde, probá el otro. El camino manual desde el panel:

```
1. https://login.tailscale.com/admin
2. Menú izquierdo, abajo del todo  ->  Settings
3. Pestañas de arriba: General · Keys · Users · ...
4. Click en la pestaña         Keys          <-- AQUÍ está
5. Sección "Auth keys"  ->  botón "Generate auth key..."
```

### Dónde NO está (para no buscarla más)

| Sección del panel | Por qué no está ahí |
|---|---|
| **Machines** | Solo lista equipos ya unidos |
| **DNS / MagicDNS** | Solo configuración de nombres |
| **Access controls / ACLs** | Solo reglas de permisos |
| **App de escritorio / móvil** | Nunca muestra auth keys |
| **Settings → General** | Es la pestaña vecina; hay que ir a **Keys** |

> La auth key **solo se muestra una vez**, al crearla. Si cerrás el diálogo sin
> copiarla, tenés que generar otra. No se puede recuperar después.

### El formulario, campo por campo

Al pulsar **Generate auth key...**:

| Campo | Para el kit (un cliente) | Para varias instalaciones |
|---|---|---|
| **Description** | `kit-pendrive-cliente` | `kit-pendrive-cliente` |
| **Reusable** | ❌ NO (una key = un equipo) | ✅ **SÍ** (varios equipos) |
| **Ephemeral** | ❌ NO (el equipo es permanente) | ❌ NO |
| **Pre-approved** | ✅ sí (evita aprobar a mano) | ✅ sí |
| **Tags** | `tag:server` (opcional) | `tag:server` (opcional) |
| **Expiration** | 1 día | **90 días** |

Click **Generate key** → tailscale muestra:

```
tskey-auth-k1234ABCDEF-5678GHIJKLMNOPQRSTUVWXYZ
```

Copiala **ya** (es case-sensitive, distingue mayúsculas de minúsculas).

### Usarla con el kit

```fish
sudo ./instalar-todo.sh \
  --authkey 'tskey-auth-XXXX' \
  --rdpass  'TU_CLAVE_RUSTDESK'
```

El `--sudopass` solo hace falta si la contraseña de sudo no se pide de forma
interactiva; si la define el cliente al instalar el sistema, omitilo y el script
la pedirá sola.

### Seguridad de las keys

- **One-off**: se revoca automáticamente al usarse → lo más seguro por equipo.
- **Reusable**: cómoda para muchos equipos, pero **si se filtra, cualquiera entra
  a tu tailnet**. No la dejes en el pendrive ni en el repo.
- **Revocar**: panel → **Settings → Keys** → la key → *Revoke*. Hacelo al terminar
  las instalaciones.
- Al expirar la auth key, el equipo **ya unido sigue autorizado** hasta que expire
  su node key (180 días por defecto).

### Comprobar

```fish
tailscale status
```

Debe listar tus dispositivos:

```
100.101.102.103  operador  usuario@   linux   -
100.201.202.203  cliente   usuario@   linux   active; direct ...
```

### Ver tu IP Tailscale

```fish
tailscale ip -4
# → 100.101.102.103
```

---

## Uso

### SSH por Tailscale

```fish
ssh USUARIO@100.201.202.203
```

### O con MagicDNS (nombre en vez de IP)

Tailscale publica cada máquina con su nombre. Si MagicDNS funciona:

```fish
ssh USUARIO@remoto        # nombre del dispositivo
getent hosts remoto        # comprobar resolución
```

---

## Configuración recomendada de SSH

En el PC operador, `~/.ssh/config`:

```sshconfig
# Por Tailscale: funciona desde CUALQUIER red
Host remoto
    HostName remoto                  # MagicDNS (o la IP 100.x.y.z)
    User USUARIO
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
    StrictHostKeyChecking accept-new

# Por LAN: más rápido cuando estás en casa
Host remoto-lan
    HostName 192.168.1.20            # IP local real
    User USUARIO
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 30
    StrictHostKeyChecking accept-new
```

Uso:

```fish
ssh remoto        # desde cualquier lugar
ssh remoto-lan    # en casa, más rápido
```

---

## RustDesk + Tailscale

### Lo importante

RustDesk y Tailscale **no se estorban**: puedes seguir usando RustDesk con su
servidor público normal, y ganar la conectividad de Tailscale para SSH.

### Conexión directa por IP Tailscale

Como Tailscale da una IP fija a cada PC, **RustDesk puede conectar directo** por
esa IP en vez de depender del relay público. Resultado: **más rápido**.

En RustDesk, en vez de meter un ID numérico, escribe la IP:

```
100.201.202.203
```

RustDesk la tratará como conexión directa (usa el *direct access port*).

### Opciones útiles de RustDesk

En `~/.config/rustdesk/RustDesk2.toml`:

```toml
[options]
# IP local que RustDesk anuncia en la LAN (déjala con tu IP real de LAN)
local-ip-addr = '192.168.1.20'

# Descubrimiento de peers en la red local
enable-lan-discovery = 'Y'

# NAT traversal para conexiones directas entre pares
enable-webrtc = 'Y'
enable-ipv6-punch = 'Y'

# En Wayland: despertar el monitor si se apagó (evita fallos de captura)
enable-drm-display-wake = 'Y'
```

> **Nota:** `local-ip-addr` debe ser tu IP **de LAN**, no la de Tailscale.
> Tailscale (`tailscale0`) es una interfaz `/32`: RustDesk no la usa para LAN
> discovery, pero **sí** puedes conectar por su IP directamente.

---

## Verificación

```fish
# 1. ¿Tailscale conectado?
tailscale status

# 2. ¿Hay conectividad?
ping -c 2 100.201.202.203

# 3. ¿SSH funciona por Tailscale?
ssh -o BatchMode=yes remoto 'hostname'

# 4. Estado detallado
tailscale netcheck          # calidad de NAT/red
tailscale ping remoto       # ruta y latencia al peer
```

### `tailscale ping` — muy útil

Muestra si la conexión es **directa** o pasa por un relay (DERP):

```fish
tailscale ping remoto

# Directa (bueno):
#   pong from remoto (100.201.202.203) via 192.168.1.20:41641 in 3ms

# Por relay (más lento):
#   pong from remoto (100.201.202.203) via DERP(scl) in 45ms
```

Si siempre sale por DERP, revisa el NAT de tu red. No es grave, solo más lento.

### ⚠️ La trampa: "directo" no siempre significa "fuera de la LAN"

`tailscale ping` puede decir **directo** con 3 ms porque los dos equipos están
en la **misma red local**. Eso no prueba nada del acceso remoto real.

Fijate en el **endpoint** que reporta `tailscale status`:

| Endpoint | Qué significa | ¿Prueba válida de acceso remoto? |
|---|---|---|
| `192.168.x.y:41641` (privada) | Ruta **LAN**, misma red | ❌ NO |
| `190.x.y.z:4941` (pública) | Ruta **internet**, redes distintas | ✅ SÍ |
| `DERP(...)` | Relay de Tailscale | ✅ SÍ (funciona, más lento) |

**Comprobación rápida** — comparar la IP pública de los dos equipos:

```fish
curl -s https://api.ipify.org     # IP pública de donde estás
```

Si el operador y el objetivo tienen **la misma** IP pública, están en la misma
salida a internet (misma casa): la prueba es LAN-local y **no vale**. Si son
distintas, es una prueba real. El caso más limpio: el operador en el **hotspot
4G del teléfono** y el objetivo en la casa.

Para el veredicto automatizado está el script del kit:

```fish
./verify-offlan.sh <objetivo>     # 7 OK => funciona fuera de la LAN
```

---

## Seguridad

- El tráfico va **cifrado extremo a extremo** (WireGuard por debajo).
- Los dispositivos se autentican con tu cuenta.
- **Revocar un dispositivo:** panel de Tailscale → Machines → Disable/Delete.
- Puedes activar **Tailscale SSH** (SSH gestionado por Tailscale) en vez de
  `sshd` propio, pero este kit usa `sshd` normal por simplicidad.
- **ACL**: en el panel puedes limitar qué dispositivo habla con cuál.

---

## Problemas comunes

| Síntoma | Causa | Solución |
|---|---|---|
| `NeedsLogin` | No autenticado | `sudo tailscale up` (o con `--auth-key`) |
| `tailscale status` vacío | Servicio caído | `sudo systemctl restart tailscaled` |
| MagicDNS no resuelve | resolver mal configurado | Usa la IP `100.x` directamente |
| Todo va por DERP (lento) | NAT restrictivo | `tailscale netcheck`; aceptable |
| Dos cuentas distintas | Cada PC en cuenta separada | Usa la **misma cuenta** |
| IP `100.x` no responde | Tailscale caído en el otro PC | `sudo systemctl restart tailscaled` allí |

> **Aviso conocido (systemd-resolved + NetworkManager):**
> ```
> systemd-resolved and NetworkManager are wired together incorrectly;
> MagicDNS will probably not work
> ```
> Es una advertencia preventiva. Si `getent hosts NOMBRE` resuelve, funciona.
> Si no, usa la IP `100.x.y.z` directamente.

---

## Alternativas a Tailscale

| Opción | Cuándo usarla |
|---|---|
| **WireGuard** puro | Quieres control total, tienes IP fija o abres un puerto |
| **Cloudflare Tunnel** | Solo necesitas SSH, tienes dominio en Cloudflare |
| **ZeroTier** | Similar a Tailscale, otra empresa |
| **Netbird** | Alternativa open-source self-hosted |

Ver [`vpn-remoto.md`](vpn-remoto.md) para WireGuard y Cloudflare.

---

## Resumen

```
1. Instalar Tailscale en cada PC
2. sudo tailscale up  (misma cuenta en todos)
   - con sesión gráfica: login por navegador
   - sin navegador:      --auth-key=tskey-auth-... (Settings -> Keys)
3. ssh USUARIO@100.x.y.z   desde cualquier red
```

Sin router, sin puertos, sin DuckDNS. Y RustDesk sigue funcionando como antes,
pero ahora con la opción de conectar directo por la IP de Tailscale.
