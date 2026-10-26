# Hallazgos verificados (pruebas reales)

Registro de comportamientos **comprobados en máquinas reales**, no supuestos.
Cada hallazgo indica cómo se verificó, para que puedas reproducirlo o refutarlo.

> Última actualización: 2026-10-26
> Equipos de prueba: desktop AMD (operador) + laptop HP Ryzen 5 (objetivo), ambos CachyOS/Wayland

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
100.x  operador  ...  active; direct 192.168.1.x:41641, tx ... rx ...

$ tailscale ping <objetivo>
pong from <objetivo> (100.x.y.z) via 192.168.1.x:41641 in 1ms
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

## Verificación automatizada

`./verify-docs.sh` comprueba que los comandos y URLs citados sigan vigentes.
Para los hallazgos de comportamiento (login screen Wayland), la verificación es
la prueba de reinicio descrita arriba.
