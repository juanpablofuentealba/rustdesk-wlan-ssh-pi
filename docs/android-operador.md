# Operador móvil (Android) — Tailscale y SSH sin root

> Cómo usar un teléfono Android como **operador** más de la flota, cuando la app
> de Tailscale de la Play Store **no sirve**.

---

## El problema: la app de Tailscale en Android moderno

En **Android 14, 15 y 16** la app de Tailscale (y cualquier VPN de terceros)
puede **no funcionar** por las restricciones nuevas de la **VPN API
(`VpnService`)** del sistema. En la práctica: instalas, inicias sesión, y no
enruta nada — o ni conecta.

**No es culpa de Tailscale ni del teléfono**: es una política de Android.

---

## La solución: contenedor proot + tailscaled en userspace

Se monta una **distro Linux (Ubuntu) dentro de Termux** con `proot-distro`
(sin root) y ahí se corre **`tailscaled` en modo userspace**, que **no necesita
la VPN del sistema ni privilegios**:

```
Android (Termux) ── proot ──► Ubuntu ──► tailscaled --tun=userspace-networking
                                              │
                                              └──► proxy SOCKS5 en localhost:1055
```

### Paso a paso

```bash
# --- 1. En Termux (Android) ---
pkg update -y
pkg install -y proot-distro
proot-distro install ubuntu

# --- 2. Entrar al Ubuntu del proot ---
proot-distro login ubuntu

# --- 3. Dentro de Ubuntu: instalar Tailscale ---
apt update && apt install -y curl ca-certificates
curl -fsSL https://tailscale.com/install.sh | sh

# --- 4. Arrancar tailscaled en userspace (sin tun, sin root real) ---
tailscaled --tun=userspace-networking \
           --socks5-server=localhost:1055 \
           --state="$HOME/.tailscale-state" &
sleep 3

# --- 5. Unirse a la tailnet ---
tailscale up --hostname=c75-operador
#   (o con auth key: tailscale up --auth-key=tskey-auth-... --hostname=c75-operador)

# --- 6. Verificar ---
tailscale status | head
tailscale ip -4
```

> **`--tun=userspace-networking`** es la clave: Tailscale arma su **propia pila
> de red en espacio de usuario** (netstack) en vez de crear una interfaz TUN del
> sistema. Por eso **no requiere root ni VPN API**.

---

## Cómo usar la red desde el móvil (SOCKS5)

En modo userspace **no hay interfaz de red transparente**: hay un **proxy
SOCKS5** en `localhost:1055`. Todo lo que quieras por Tailscale pasa por ahí:

```bash
# SSH a un cliente por el SOCKS5 de Tailscale:
ssh -o ProxyCommand='nc -X 5 -x localhost:1055 %h %p' jp@hp-operador

# o definir un alias en ~/.ssh/config dentro del proot:
Host hp-operador
    HostName hp-operador
    User jp
    ProxyCommand nc -X 5 -x localhost:1055 %h %p
```

---

## Preparar el Android como operador de pleno derecho

### Clave SSH **propia** del móvil

**Regla de oro:** cada operador tiene **su propia** identidad SSH (hallazgo
H-43). **Nunca** se copia la clave privada de otro equipo al móvil.

```bash
# dentro del proot Ubuntu:
apt install -y openssh-client
ssh-keygen -t ed25519 -C "movil-operador" -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub
```

Esa `.pub` se autoriza en los equipos donde el móvil vaya a operar.

### Autorizar la clave (Linux)

```bash
echo '<PUBLICA_MOVIL>' >> ~/.ssh/authorized_keys
```

### Autorizar la clave (Windows con usuario administrador)

En Windows, para un usuario que es **administrador**, el archivo
`.ssh/authorized_keys` normal **se ignora**: va en la ruta de admins:

```powershell
$f = 'C:\ProgramData\ssh\administrators_authorized_keys'
Add-Content -Path $f -Value '<PUBLICA_MOVIL>' -Encoding ascii
icacls $f /inheritance:r /grant '*S-1-5-32-544:F' /grant 'SYSTEM:F'
```

---

## Errores típicos

| Síntoma | Causa | Arreglo |
|---|---|---|
| `pkg install tailscale` → no existe | No está en los repos de Termux | Usar proot Ubuntu (esta guía) |
| La app de Play Store no conecta | Restricción de `VpnService` en Android 14+ | Usar proot + userspace |
| `tailscale status` dice "Logged out" | Falta autenticar | `tailscale up` (URL) o `--auth-key` |
| El nodo aparece como `localhost-0` | Hostname del proot sin definir | `tailscale up --hostname=<nombre> --reset` |
| SSH no conecta a los clientes | Falta el `ProxyCommand` SOCKS5 | Ver la sección SOCKS5 |

---

## Notas

- El nodo del proot **reporta `linux`** (no Android): es la distro la que corre
  Tailscale.
- El **proot no tiene IP propia**: comparte la red del Android, pero Tailscale
  userspace funciona igual porque usa su propio netstack.
- Para **que otros entren al móvil** por SSH haría falta `sshd` dentro del proot
  (más complejo). Para el rol de **operador que se conecta a otros**, basta con
  `openssh-client`.
