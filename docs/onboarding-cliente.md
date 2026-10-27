# Onboarding de un cliente nuevo (flujo verificado)

Cómo preparar una computadora de un cliente para administrarla remotamente,
**sin contaminar tu red personal** y dejando al cliente el control.

> **Toda la información técnica de este documento fue validada contra la
> documentación oficial de Tailscale** (`tailscale.com/docs/features/access-control/auth-keys`,
> validada 30 jun 2026) y contra los binarios instalados (`tailscale 1.104.2`).
> Ver la sección [Fuentes verificadas](#fuentes-verificadas).

---

## 1. Los dos modelos (elige antes de empezar)

| | **Modelo A — tu cuenta** | **Modelo B — cuenta del cliente** ⭐ |
|---|---|---|
| Quién crea Tailscale | Tú | El cliente |
| El equipo aparece como | Tuyo | Del cliente |
| Control del acceso | Tú | El cliente |
| Revocar | Tú debes recordar quitarlo | El cliente lo hace solo |
| Apto para clientes reales | ⚠️ No recomendado | ✅ Sí |
| Apto para tus propios PCs | ✅ Sí | — |

**Regla:** si el equipo **no es tuyo**, usa **Modelo B**. Punto.

---

## 2. Flujo completo (Modelo B)

```
┌──────────────────────────────────────────────────────────────┐
│ FASE 0 — CON EL CLIENTE (antes de tocar el PC)               │
│                                                              │
│ El cliente:                                                  │
│  1. Crea su cuenta Tailscale (gratis, 1 min)                 │
│     → https://login.tailscale.com/start                      │
│  2. Genera una AUTH KEY en su panel:                         │
│     → https://login.tailscale.com/admin/settings/keys        │
│       (Settings → pestaña Keys → "Generate auth key...")     │
│     → https://console.tailscale.com/admin/settings/keys      │
│       (alias: lleva a la misma consola)                      │
│     · Description: kit-pendrive-cliente                      │
│     · Reusable:  NO   (para un solo equipo)                  │
│     · Ephemeral: NO   (el equipo es permanente)              │
│     · Expiry:    1 día (suficiente para el trabajo)          │
│     · Solo se muestra UNA VEZ: copiarla al generarla         │
│  3. Te pasa la key (string que empieza con `tskey-auth...`)  │
│  4. Te da el PRIMER acceso por RustDesk                      │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ FASE 1 — PRIMER ACCESO                                       │
│                                                              │
│ Requisito: el PC del cliente ya debe tener RustDesk          │
│ corriendo (el cliente lo instala, o vas presencialmente).    │
│                                                              │
│ El cliente te da: ID + contraseña de RustDesk                │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ FASE 2 — TÚ, POR RUSTDESK (en el PC del cliente)             │
│                                                              │
│  1. (Si aplica) instalar el SO                                │
│  2. Instalar RustDesk con unattended                          │
│  3. Instalar Tailscale y unirlo con la auth key:              │
│       sudo pacman -S --needed tailscale                       │
│       sudo systemctl enable --now tailscaled                  │
│       sudo tailscale up --auth-key=tskey-auth-XXXX            │
│  4. Instalar sshd + TU clave pública                          │
│  5. Verificar                                                │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ FASE 3 — VERIFICACIÓN Y ENTREGA                              │
│                                                              │
│ Tú:    ssh usuario@100.x.y.z   (IP Tailscale del cliente)    │
│ Cliente conserva el control: puede revocar cuando quiera     │
└──────────────────────────────────────────────────────────────┘
```

---

## 3. Por qué `--auth-key` y no el login normal

`tailscale up` sin argumentos abre un enlace donde **alguien debe loguearse con
un navegador**. Si lo hicieras tú:

- Abrirías sesión con **la cuenta del cliente desde tu navegador** → tu PC queda
  con su sesión iniciada. **Malo.**
- O tendrías que pedirle su contraseña. **Peor.**

Con `--auth-key`:

| Ventaja | Detalle |
|---|---|
| No compartes contraseñas | El cliente solo genera y te pasa una key |
| Queda registro | El dispositivo se registra con esa key |
| Expira | La key caduca (1-90 días según configures) |
| Se revoca solo | Las keys *one-off* se revocan automáticamente al usarse |

**Comando verificado** (documentación oficial):
```fish
sudo tailscale up --auth-key=tskey-abcdef1432341818
```

> ⚠️ Las keys de Tailscale son **case-sensitive** (distinguen mayúsculas).

---

## 4. Datos verificados sobre auth keys

| Concepto | Valor | Fuente |
|---|---|---|
| Tipos | **One-off** (un uso) / **Reusable** (varios) | doc oficial |
| Expiración | **1 a 90 días**; por defecto 90 | doc oficial |
| Node key | Expira a los **180 días** por defecto | doc oficial |
| Al expirar la auth key | El equipo **sigue autorizado** hasta que expire su node key | doc oficial |
| Ephemeral | Elimina el equipo automáticamente al desconectarse | doc oficial |
| Pre-approved | Autoriza sin aprobación manual (si tienes device approval) | doc oficial |
| Tagged | Aplica un tag al equipo desde la key | doc oficial |
| Revocar | Solo tus propias keys, desde el panel → Keys | doc oficial |
| One-off | Se revoca **automáticamente** tras usarse | doc oficial |

### Recomendación para un cliente

```
Reusable:  NO     → una key por equipo, más seguro
Ephemeral: NO     → el equipo es permanente
Expiry:    1 día  → suficiente; caduca si no lo usas
Pre-approved: opcional (solo si usas device approval)
Tagged: opcional  → útil si gestionas muchos equipos
```

---

## 5. Checklist operativa

### Antes de empezar (pídele al cliente)

- [ ] Cuenta Tailscale creada (suya)
- [ ] Auth key generada: `tskey-auth-...`
      (panel → Settings → **Keys** → Generate auth key;
      ver [`tailscale.md`](tailscale.md#generar-la-auth-key-paso-a-paso-en-la-web))
- [ ] RustDesk instalado en su PC, con ID y contraseña
- [ ] Confirmado: el equipo es **suyo** (Modelo B)

### Durante (por RustDesk)

```fish
# 1. Tailscale
sudo pacman -S --needed tailscale
sudo systemctl enable --now tailscaled
sudo tailscale up --auth-key=tskey-auth-XXXX

# 2. Verificar Tailscale
tailscale status
tailscale ip -4                  # anota la IP 100.x.y.z

# 3. SSH
sudo pacman -S --needed openssh
sudo systemctl enable --now sshd
# abrir firewall (el paso que se olvida)
sudo ufw allow 22/tcp

# 4. Tu clave pública
mkdir -p ~/.ssh; and chmod 700 ~/.ssh
echo "TU_CLAVE_PUBLICA" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# 5. Verificar
hostname; uname -r; ip -4 route get 1.1.1.1 | grep -oP 'src \K[0-9.]+'
```

> Los pasos 3 y 4 los automatiza `setup-remote-target.sh --ssh --key ...`
> (ver [README](../README.md)).

### Después (desde tu PC)

- [ ] `ssh usuario@100.x.y.z` funciona
- [ ] **Acceso fuera de la LAN** verificado: `./verify-offlan.sh <hostname>`
      (7 OK · 0 fallos). Ojo: si operador y objetivo tienen la misma IP pública
      es la misma casa y la prueba no vale.
- [ ] **Reinicio unattended** verificado: `./reboot-remoto.sh --host ... --all`
      → vuelve con `boot_id` nuevo y los 4 servicios `active` (ver H-27)
- [ ] Documentado: cliente, IP Tailscale, qué se instaló (ficha: `inventory.sh`)
- [ ] Informado al cliente: **cómo revocar tu acceso**

---

## 6. Cómo revoca el cliente tu acceso

El cliente tiene **el control total**. Para cortarte el acceso:

**Opción 1 — Deshabilitar el equipo** (corta todo acceso de red):
```
Panel Tailscale → Machines → [el equipo] → Disable
```

**Opción 2 — Quitar tu clave SSH** (mantiene la red, corta tu shell):
```fish
# En el PC del cliente:
nano ~/.ssh/authorized_keys    # borra tu línea → guardar
```

**Opción 3 — Borrar el dispositivo** (permanente):
```
Panel Tailscale → Machines → [el equipo] → Delete
```

> **Importante para el cliente:** revocar una **auth key** *no* desautoriza
> equipos que ya la usaron. Para eso debe **borrar el equipo** en Machines.
> (Dato verificado en la doc oficial.)

---

## 7. Qué NO hacer

| ❌ No hagas esto | Por qué |
|---|---|
| Unir el PC del cliente a **tu** cuenta | Contamina tu red, problema legal |
| Compartir tu sesión de navegador con su cuenta | Tu PC queda con su sesión |
| Pedir/guardar su contraseña | Innecesario con auth keys |
| Usar una key **Reusable** para todo | Si se filtra, riesgo grande (aviso oficial) |
| Dejar el acceso sin que el cliente lo sepa | Ético y legal |
| Poner `PasswordAuthentication no` sin probar antes | Te quedas fuera del equipo |

---

## 8. Alternativa: compartir dispositivo (Modelo C)

Si el cliente **ya tiene** su equipo en Tailscale, puede **compartirlo** contigo
sin darte su cuenta:

> Tailscale soporta *link-based node sharing*: compartir una máquina con un
> usuario de **otra** tailnet. El receptor accede **solo** a esa máquina, no a
> toda la red. (Fuente: `tailscale.com/docs/features/sharing`, validada 5 ene 2026.)

```
Cliente: Panel → Machines → [equipo] → Share → te manda el enlace
Tú:      aceptas con TU cuenta → ves solo ese equipo
```

**Ventaja:** el equipo sigue siendo suyo, tú no necesitas crear nada en su PC.
**Cuándo usarlo:** cuando el cliente ya está en Tailscale y prefiere no darte
una auth key.

---

## 9. Documentación del trabajo (plantilla)

Lleva registro de cada cliente. Plantilla:

```markdown
## Cliente: <nombre>
Fecha: <fecha>

- Modelo: B (cuenta del cliente) / C (sharing)
- Equipo: <marca-modelo>
- SO instalado: <distro> <versión>
- Hostname: <nombre>
- IP Tailscale: 100.x.y.z
- ID RustDesk: <id>
- Acceso SSH: usuario@100.x.y.z con clave ed25519
- Auth key usada: (registrada en el panel del cliente)
- Cambios en el router: no
- Revocación: el cliente puede deshabilitar el equipo en su panel
- Notas: ...
```

---

## Fuentes verificadas

| Dato | Fuente | Fecha validación |
|---|---|---|
| Auth keys (tipos, expiración 1-90 días, comandos) | `tailscale.com/docs/features/access-control/auth-keys` | 30 jun 2026 |
| Node key expira 180 días | misma | 30 jun 2026 |
| Revocar key ≠ desautorizar equipo | misma | 30 jun 2026 |
| Compartir máquinas entre tailnets | `tailscale.com/docs/features/sharing` | 5 ene 2026 |
| Prefijos reales de key | binario `tailscale` 1.104.2 | local |
| Flags `--auth-key`, `--hostname` | `tailscale up --help` | local |

Cuando cambie la versión de Tailscale, **vuelve a verificar** los comandos:
```fish
tailscale version
tailscale up --help
```
