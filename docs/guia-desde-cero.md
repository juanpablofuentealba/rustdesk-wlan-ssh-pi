# Guía desde cero: conectar `pi` a un PC remoto por WLAN

Esta guía asume que **no sabes nada** sobre SSH, RustDesk o terminal. Está
pensada para que copies, pegues y entiendas qué hace cada cosa.

---

## 1. Qué piezas hay y qué hace cada una

Piensa en tres herramientas, cada una con un rol distinto:

| Pieza | Qué es | Para qué sirve |
|---|---|---|
| **RustDesk** | Programa de escritorio remoto | **Ver y controlar la pantalla** del otro PC (como TeamViewer) |
| **SSH** | Acceso por terminal | **Ejecutar comandos** en el otro PC (texto, sin ver pantalla) |
| **pi** | Asistente IA | **Trabaja solo** usando SSH: saca specs, arregla cosas, revisa logs |

La idea central:

```
RustDesk  = los OJOS   (ves la pantalla)
SSH       = las MANOS  (ejecutas comandos)
pi        = quien USA las manos (y te reporta)
```

> **`pi` corre SOLO en tu PC (el operador).** No se instala en el PC objetivo.
> El otro PC solo necesita la infraestructura de acceso (SSH, RustDesk,
> Tailscale). El agente es **tu herramienta de trabajo**: tú lo usas desde tu
> equipo y él alcanza el PC del cliente por SSH.
>
> Además `pi` no trae modelos gratuitos fiables, así que instalar el agente en el
> PC de un cliente implicaría que él pague un modelo — algo que no tiene sentido
> para un servicio de mantención.

---

## 2. La analogía

Conectar `pi` a otro PC es como **dar una llave de tu casa a un ayudante**:

1. **Tú (operador)** tienes una **llave** → es tu *clave SSH*.
2. **El otro PC (objetivo)** debe tener:
   - La **puerta habilitada** → servicio **SSH encendido**.
   - El **portero despierto** → **firewall** que deje pasar el puerto 22.
   - Tu **llave autorizada** → para que entres sin contraseña.

Sin esas tres cosas, no hay acceso.

---

## 3. Antes de empezar: qué necesitas

- **Acceso físico** al PC nuevo la primera vez (teclado/pantalla), o que alguien
  lo haga por ti.
- Ambos PCs en la **misma red** (WiFi o cable).
- Saber la **IP local** del PC nuevo y el **usuario** (ej. `jp`).
- El **kit** en un lado u otro (`setup-remote-target.sh`, `inventory.sh`).

---

## 4. Paso a paso (dos PCs en la misma red)

### PASO 1 — Averiguar la IP del PC nuevo

En el **PC nuevo**, abre una terminal y ejecuta:

```fish
ip -4 route get 1.1.1.1 | grep -oP 'src \K[0-9.]+'
```

Salida de ejemplo: `192.168.1.20` ← **esa es la IP**.

También averigua tu nombre de usuario (en la misma terminal):

```fish
whoami
```

### PASO 2 — Copiar el kit al PC nuevo

Desde **tu PC** (el operador), reemplaza `USUARIO` e `IP` por lo del paso 1:

```fish
scp ~/rustdesk-wlan-ssh-pi/setup-remote-target.sh ~/rustdesk-wlan-ssh-pi/inventory.sh USUARIO@IP:~
```

Ejemplo real:

```fish
scp ~/rustdesk-wlan-ssh-pi/setup-remote-target.sh ~/rustdesk-wlan-ssh-pi/inventory.sh USUARIO@192.168.1.20:~
```

### PASO 3 — Diagnóstico (opcional pero recomendado)

En el **PC nuevo**:

```fish
bash ~/setup-remote-target.sh --check
```

Esto **NO cambia nada**: solo te dice qué falta (SSH, firewall, RustDesk...).

### PASO 4 — Aplicar la configuración

En el **PC nuevo** (te pedirá **su** contraseña de administrador):

```fish
sudo bash ~/setup-remote-target.sh --all --key "AQUI_VA_TU_CLAVE_PUBLICA"
```

#### ¿Cuál es "tu clave pública"?

Está en **tu PC** (operador) en `~/.ssh/id_ed25519.pub`. Para verla:

```fish
cat ~/.ssh/id_ed25519.pub
```

Verás algo así:

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... operador@mipc
```

Copia **toda esa línea**. Truco para no copiar a mano: en **tu PC** genera el
comando ya armado:

```fish
echo "sudo bash ~/setup-remote-target.sh --all --key \"(cat ~/.ssh/id_ed25519.pub)\""
```

Ese único comando, en el PC nuevo, hace todo:

- ✅ Instala RustDesk con acceso desatendido (Wayland + DRM)
- ✅ Habilita SSH
- ✅ **Abre el firewall** (el paso que se olvida)
- ✅ Autoriza tu llave

### PASO 5 — Verificar desde tu PC

Vuelve a **tu PC** y prueba:

```fish
ssh -o BatchMode=yes USUARIO@IP 'hostname'
```

Si responde el nombre del PC → **funciona**.

O usa el kit (más completo):

```fish
cd ~/rustdesk-wlan-ssh-pi
./tests.sh USUARIO@IP
```

Todo en verde (`0 fallos`) = todo bien.

Si vas a dejar el equipo **para acceso remoto de verdad** (fuera de tu casa),
corré además las dos pruebas que valen:

```fish
# ¿Se alcanza desde otra red? (7 OK = sí)
./verify-offlan.sh USUARIO@IP

# ¿Vuelve solo tras un reinicio? (boot_id nuevo = sí)
./reboot-remoto.sh --host USUARIO@IP --all
```

### PASO 6 — Pedírselo a `pi`

Ya está. Ahora solo dilo:

> "Revisa el PC en `USUARIO@192.168.1.20`"

Y `pi` trabajará allí: specs, logs, instalaciones, diagnóstico.

---

## 5. Hacerlo cómodo (recomendado)

En **tu PC**, crea un alias para no escribir la IP cada vez:

```fish
mkdir -p ~/.ssh
printf '%s\n' \
  'Host remoto' \
  '    HostName 192.168.1.20' \
  '    User jp' \
  '    IdentityFile ~/.ssh/id_ed25519' \
  '    IdentitiesOnly yes' \
  '    ServerAliveInterval 30' \
  > ~/.ssh/config
chmod 600 ~/.ssh/config
```

Ahora basta:

```fish
ssh remoto
```

Y `pi` también puede usar `remoto`.

> **Importante en WLAN:** la IP **cambia** cuando el PC se reconecta al WiFi.
> Pide a tu router que fije la IP por MAC (**reserva DHCP**), o usa `remoto.local`
> si tu red resuelve mDNS (`getent hosts remoto.local`).

---

## 6. Las 3 fallas típicas (y cómo arreglarlas)

| Qué ves | Qué pasa | Solución |
|---|---|---|
| "Connection timed out" **y** en el PC nuevo `ss -tln \| grep :22` **sí** muestra `:22` | **Firewall** bloqueando | `sudo ufw allow 22/tcp` |
| "Permission denied (publickey)" | Tu llave no está autorizada | Repite el `--key` del Paso 4 |
| "Connection timed out" y **no** aparece `:22` | SSH no está corriendo | `sudo systemctl enable --now sshd` |

### Diagnóstico rápido

```fish
# ¿el PC responde en la red?
ping -c 2 192.168.1.20

# ¿el puerto SSH está abierto?
timeout 5 bash -c 'echo > /dev/tcp/192.168.1.20/22' && echo ABIERTO || echo CERRADO
```

---

## 7. Resumen ultra corto

```
1. Tu PC:    cat ~/.ssh/id_ed25519.pub          → copia la línea "ssh-ed25519..."
2. PC nuevo: sudo bash ~/setup-remote-target.sh --all --key "<pegada>"
3. Tu PC:    ssh usuario@ip 'hostname'          → si responde, listo
4. Tú:       "pi, revisa el PC en usuario@ip"
```

---

## 8. Preguntas frecuentes

**¿Tengo que hacer esto cada vez?**
No. Solo la **primera vez**. Después basta `ssh remoto` (o pedírselo a `pi`).

**¿Y si no tengo acceso físico al PC nuevo?**
Primero RustDesk te da la pantalla; desde ahí ejecutas los comandos. Pero
necesitas que alguien te dé el **primer** acceso (contraseña de RustDesk).

**¿Y si estoy fuera de casa?**
Ahí entra una **VPN** (WireGuard o Tailscale). Ver
[`docs/vpn-remoto.md`](vpn-remoto.md). Es el siguiente nivel: primero domina
esto en tu WiFi.

**¿Es seguro?**
Sí, si sigues esto:
- La **clave privada** nunca sale de tu PC.
- La pública solo permite entrar **como ese usuario**, nada más.
- **Revocar** acceso = borrar tu línea en `~/.ssh/authorized_keys` del PC nuevo.
- **Nunca** abras el puerto 22 al internet sin VPN ni firewall.

**¿Qué hago si algo falla?**
Copia la salida del comando que falló y pásasela a `pi`. Te dirá exactamente
qué pasa.

---

## 9. Glosario mínimo

| Término | Qué significa |
|---|---|
| **SSH** | Protocolo para entrar a otra máquina por terminal |
| **Clave SSH** | Archivo que funciona como llave. Hay **privada** (tuya, secreta) y **pública** (la que compartes) |
| **authorized_keys** | Archivo del PC objetivo donde se guardan las llaves permitidas |
| **sshd** | El "portero" del PC objetivo; el servicio que acepta conexiones SSH |
| **firewall** | Filtro de red; si no deja pasar el 22, no entras |
| **puerto 22** | La "puerta" estándar de SSH |
| **IP local** | Dirección del PC dentro de tu red (ej. 192.168.1.20) |
| **WLAN** | Red inalámbrica (WiFi) |
| **mDNS** | Permite usar `nombre.local` en vez de la IP |
| **RustDesk unattended** | RustDesk configurado para entrar **sin** que alguien acepte en pantalla |

---

## 10. Siguiente nivel

Cuando esto funcione bien en tu WiFi:

1. **Reserva DHCP** en el router (IP fija por MAC) → fin de las IPs que cambian.
2. **VPN** ([`docs/vpn-remoto.md`](vpn-remoto.md)) → acceso desde cualquier red.
3. **Hardening SSH** → sin contraseñas, solo llave + límites de intentos.
