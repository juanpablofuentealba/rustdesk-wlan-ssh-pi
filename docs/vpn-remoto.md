# WireGuard — trabajar con el PC remoto fuera de la LAN

SSH directo (`USUARIO@192.168.1.20`) **solo funciona dentro de la misma red**. Para
administrar el equipo cuando no estás en casa (otra red, datos móviles, cafetería)
usa **WireGuard**: una VPN moderna, rápida y con muy poca config.

Resultado: desde cualquier lugar, `ssh remoto` funciona como si estuvieras en la LAN.

---

## Topología

```
   Tú (fuera de casa)                       Casa
 ┌──────────────────┐                   ┌──────────────────────┐
 │  Laptop/Phone    │   Internet        │  Router / Server     │
 │  10.10.0.2       │◄─────────────────►│  10.10.0.1 (hub)     │
 │  (peer cliente)  │   UDP cifrado     │  ├─ hub   10.10.0.3  │
 └──────────────────┘                   │  └─ remoto 10.10.0.4  │
                                        └──────────────────────┘
   ssh remoto  →  10.10.0.4  (túnel WireGuard, sin abrir SSH a internet)
```

**Belleza del diseño:** SSH **nunca se expone a internet**. Solo WireGuard
necesita un puerto UDP abierto. Dentro del túnel, SSH circula cifrado y privado.

---

## Opción A — Un equipo como "hub" (lo más simple)

El equipo que **siempre está encendido** (ideal: un desktop o un servidor) actúa de
servidor WireGuard. Los demás se conectan a él.

### A.1 En el hub

```fish
sudo pacman -S --needed wireguard-tools
```

Generar claves:

```fish
sudo mkdir -p /etc/wireguard; and cd /etc/wireguard
umask 077
wg genkey | tee hub.key | wg pubkey > hub.pub
wg genkey | tee remoto.key | wg pubkey > remoto.pub
wg genkey | tee cliente.key | wg pubkey > cliente.pub

echo "=== clave pública del hub ==="; cat hub.pub
```

`/etc/wireguard/wg0.conf`:

```ini
[Interface]
Address = 10.10.0.1/24
ListenPort = 51820
PrivateKey = <contenido de hub.key>
# Reenvío de tráfico entre peers
PostUp   = sysctl -w net.ipv4.ip_forward=1
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp   = iptables -t nat -A POSTROUTING -o enp37s0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o enp37s0 -j MASQUERADE

# --- peer: remoto ---
[Peer]
PublicKey = <contenido de remoto.pub>
AllowedIPs = 10.10.0.4/32

# --- peer: cliente (tú, fuera de casa) ---
[Peer]
PublicKey = <contenido de cliente.pub>
AllowedIPs = 10.10.0.2/32
```

Arrancar:

```fish
sudo systemctl enable --now wg-quick@wg0
sudo wg show
```

Abrir el puerto en el router: **UDP 51820 → 192.168.1.10** (o el IP del hub).
Si no puedes abrir puertos, ve a la **Opción B**.

### A.2 En el equipo objetivo

```fish
sudo pacman -S --needed wireguard-tools
# Traer la clave privada generada en el hub (ej. por scp desde el hub):
#   scp 192.168.1.10:/etc/wireguard/remoto.key /tmp/remoto.key
#   sudo install -m 600 /tmp/remoto.key /etc/wireguard/remoto.key; and rm /tmp/remoto.key
sudo chmod 600 /etc/wireguard/remoto.key   # la clave privada: solo root
```

`/etc/wireguard/wg0.conf`:

```ini
[Interface]
Address = 10.10.0.4/24
PrivateKey = <contenido de remoto.key>

[Peer]
PublicKey = <contenido de hub.pub>
Endpoint = TU_IP_PUBLICA_O_DDNS:51820
AllowedIPs = 10.10.0.0/24
PersistentKeepalive = 25
```

```fish
sudo systemctl enable --now wg-quick@wg0
```

### A.3 En tu equipo cliente (el de fuera)

```ini
[Interface]
Address = 10.10.0.2/24
PrivateKey = <contenido de cliente.key>

[Peer]
PublicKey = <contenido de hub.pub>
Endpoint = TU_IP_PUBLICA_O_DDNS:51820
AllowedIPs = 10.10.0.0/24
PersistentKeepalive = 25
```

Con `AllowedIPs = 10.10.0.0/24` **solo enruta la VPN** (no todo tu tráfico). Si
quieres tunelizar todo (salir a internet por casa), usa `0.0.0.0/0`.

---

## Opción B — DuckDNS + IP dinámica (sin IP fija)

La IP pública de casa cambia. Soluciones:

**a) DuckDNS** ((ejemplo)):

```fish
mkdir -p ~/.config/duckdns
printf '%s\n' '#!/bin/sh' \
  'curl -s -k "https://www.duckdns.org/update?domains=tu-subdominio&token=TU_TOKEN&ip=" -o /tmp/duck.log' \
  > ~/.config/duckdns/duck.sh
chmod +x ~/.config/duckdns/duck.sh
```

> En fish no hay heredoc clásico como en bash; el `printf` de arriba genera el
> script de forma portable. Alternativa: crear el archivo con un editor.
> Comprueba que devuelve `OK`: `~/.config/duckdns/duck.sh; and cat /tmp/duck.log`

Systemd timer cada 5 min:

```ini
# ~/.config/systemd/user/duckdns.service
[Unit]
Description=DuckDNS update
[Service]
Type=oneshot
ExecStart=%h/.config/duckdns/duck.sh
```

```ini
# ~/.config/systemd/user/duckdns.timer
[Unit]
Description=DuckDNS cada 5 min
[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
```

```fish
systemctl --user enable --now duckdns.timer
```

Usa `Endpoint = tu-subdominio.duckdns.org:51820`.

**b) Tailscale** (alternativa sin abrir puertos — ver Opción C).

---

## Opción C — Tailscale (VPN zero-config)

Si **no puedes abrir puertos** en el router, Tailscale es la vía más rápida.
No requiere servidor ni puertos: NAT traversal automático.

```fish
# En AMBOS equipos (hub y objetivo)
paru -S --needed tailscale
sudo systemctl enable --now tailscaled
sudo tailscale up
```

Te da un nombre estable (`remoto`, `hub`) y una IP `100.x.y.z`:

```fish
ssh USUARIO@remoto            # funciona desde cualquier red
```

Y en `~/.ssh/config` del operador:

```sshconfig
Host remoto
    HostName remoto          # nombre de Tailscale (MagicDNS)
    User jp
    IdentityFile ~/.ssh/id_ed25519
```

**Ventajas:** cero config de router, cero puertos, cifrado, funciona en 4G/5G.
**Contras:** depende de un servicio de terceros (gratis hasta 100 dispositivos).

---

## Opción D — Cloudflare Tunnel (sin abrir puertos, con SSH puro)

Si quieres **solo SSH** (sin VPN completa) y no tocas el router:

```fish
paru -S --needed cloudflared

# En el equipo objetivo
cloudflared tunnel login
cloudflared tunnel create remoto
cloudflared tunnel route dns remoto remoto.tudominio.com

# Crear el config (fish no tiene heredoc clásico): crea el archivo con un editor,
# o usa printf. Sustituye <UUID> por el que devolvió 'cloudflared tunnel create'.
mkdir -p ~/.cloudflared
printf '%s\n' \
  'tunnel: remoto' \
  'credentials-file: /home/jp/.cloudflared/<UUID>.json' \
  'ingress:' \
  '  - hostname: remoto.tudominio.com' \
  '    service: ssh://localhost:22' \
  '  - service: http_status:404' \
  > ~/.cloudflared/config.yml

sudo cloudflared service install
```

En el operador, `~/.ssh/config`:

```sshconfig
Host remoto
    HostName remoto.tudominio.com
    User jp
    ProxyCommand cloudflared access ssh --hostname %h
```

---

## Endurecer SSH (recomendado si sales a internet)

Con VPN/Túnel, SSH sigue siendo local. Pero si **alguna vez** lo expones, o para
defensa en profundidad, edita en el objetivo `/etc/ssh/sshd_config.d/99-hardening.conf`:

```sshconfig
# Solo autenticación por clave (sin contraseñas)
PasswordAuthentication no
KbdInteractiveAuthentication no

# No permitir root directo
PermitRootLogin no

# Límites
MaxAuthTries 3
MaxSessions 4
```

> Nota: `ChallengeResponseAuthentication` está obsoleto en OpenSSH moderno;
> `KbdInteractiveAuthentication` es su reemplazo. En el `sshd` de CachyOS
> (OpenSSH 10.x) usar solo los que aparecen arriba.

```fish
sudo sshd -t; and sudo systemctl reload sshd
```

Complementos:

```fish
# fail2ban contra fuerza bruta
sudo pacman -S --needed fail2ban
sudo systemctl enable --now fail2ban
```

> ⚠️ **Antes de poner `PasswordAuthentication no`**, verifica que tu clave
> funciona: `ssh -o BatchMode=yes remoto 'echo ok'`. Si no, te quedarás fuera.
> Ten a mano una segunda sesión SSH abierta mientras cambias esto.

---

## Elegir opción

| Escenario | Opción recomendada |
|---|---|
| Puedo abrir un puerto UDP en el router | **A — WireGuard hub** |
| No puedo abrir puertos, quiero simplicidad | **C — Tailscale** |
| Solo necesito SSH, tengo dominio en Cloudflare | **D — Cloudflare Tunnel** |
| IP pública dinámica | **A + DuckDNS (B)** |

---

## Verificación

```fish
# ¿el túnel está arriba?
sudo wg show                       # WireGuard: handshake, transfer
tailscale status                   # Tailscale: peers y estado

# ¿llego al equipo remoto por el túnel?
ping -c 2 10.10.0.4                # WireGuard
ssh remoto 'hostname'               # cualquiera de las opciones

# ¿mi SSH está expuesto a internet? (en el objetivo)
ss -tlnp | grep :22                # debe escuchar, pero el router NO debe redirigir 22
```

**Regla de oro:** si usas VPN/túnel, **no** abras el puerto 22 al internet.
La VPN ya te da acceso seguro y cifrado.

---

## Referencias

- WireGuard: <https://www.wireguard.com/quickstart/>
- Tailscale en Arch: <https://wiki.archlinux.org/title/Tailscale>
- Cloudflare Tunnel: <https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/>
- DuckDNS: <https://www.duckdns.org/>
- SSH hardening (Arch Wiki): <https://wiki.archlinux.org/title/OpenSSH>
