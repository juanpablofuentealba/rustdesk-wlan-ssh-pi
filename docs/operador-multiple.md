# Varios operadores (flota con más de una máquina operadora)

> Cómo montar **dos o más PCs operadores** (por ejemplo, un portátil y un
> escritorio) que comparten clientes, se pueden operar **entre sí** para
> pruebas, y no dependen de una sola máquina.
>
> Complementa a [`agente-operador.md`](agente-operador.md), que describe **un**
> operador. Acá se explica el caso de **varios**.

---

## Idea

Un solo operador es un punto único de falla: si el portátil se apaga, se queda
sin batería o viaja, no hay acceso a los clientes. Con **varios operadores**:

- Cualquiera puede atender a cualquier cliente (todos tienen las claves
  autorizadas en los clientes).
- Cada operador puede **operar a los demás** para pruebas y diagnóstico.
- Un operador caído no bloquea el trabajo.

```
                        TAILNET
   ┌───────────────────────────────────────────────┐
   │                                               │
 ┌─┴──────────┐   ┌──────────────┐   ┌──────────┐  │
 │ HP          │   │ MSI          │   │ cliente- │  │
 │ hp-operador │⇄ │ msi-operador │──►│ juan     │  │
 │ (portátil)  │   │ (escritorio) │   └──────────┘  │
 └─────────────┘   └──────────────┘                 │
        └────────► ambos operan a los clientes ◄────┘
```

---

## Regla de oro: **una identidad SSH por operador**

**Nunca compartas la misma clave privada entre operadores** (ver
[`hallazgos.md`](hallazgos.md) **H-43**). Cada máquina operadora genera su
propia clave:

```bash
# En cada operador (ejemplo en el HP):
ssh-keygen -t ed25519 -f ~/.ssh/id_hp_operador -C "hp-operador@HP"
# En el MSI:
ssh-keygen -t ed25519 -f ~/.ssh/id_msi_operador -C "msi-operador@MSI"
```

| Ventaja | Por qué |
|---|---|
| **Auditable** | sabés qué máquina abrió cada conexión |
| **Rotable** | rotar una clave no afecta a los demás operadores |
| **Ordenado** | cada rol tiene su identidad, sin ambigüedad |

---

## Montaje, paso a paso

### 1. Clave propia en cada operador

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_<rol>_operador -N "" -C "<rol>@<host>"
```

### 2. Autorización cruzada (operadores entre sí)

Cada operador autoriza la pública del otro en su `authorized_keys`:

```bash
# Desde el HP: meter su pública en el MSI
ssh msi-operador "echo '$(cat ~/.ssh/id_hp_operador.pub)' >> ~/.ssh/authorized_keys"
# Y al revés (el MSI mete la suya en el HP)
```

### 3. Los clientes autorizan a **todos** los operadores

Al dar de alta un cliente, se instalan **las públicas de todos los operadores**
en su `authorized_keys`. Así cualquier operador puede entrar sin depender del
que hizo la instalación.

> El `operador.pub` que empaqueta `alta-cliente.sh` es **la clave del operador
> local** (autodetectada, ver H-41). En una flota, el `kit-<cliente>` debería
> llevar **la pública de cada operador** (p. ej. `operador-hp.pub`,
> `operador-msi.pub`).

### 4. `~/.ssh/config` con un `Host` por operador

```sshconfig
Host msi-operador
    HostName msi-operador
    User jp
    IdentityFile ~/.ssh/id_hp_operador
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
```

### 5. Verificar y retirar claves viejas

```bash
# ¿entra con la clave nueva?
ssh -o BatchMode=yes msi-operador true && echo OK
# ¿la clave vieja/compartida ya NO sirve?  (debe dar Permission denied)
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -o -F /dev/null msi-operador true
```

---

## `flota.sh` con varios operadores

El script de flota se divide en **dos bloques**: clientes y operadores. Así ves
de un vistazo si los clientes responden **y** si el otro operador está vivo.

```
  CLIENTES
  cliente-juan             online    SSH:✔
  cliente-maria            offline   SSH:—

  OPERADORES
  hp-operador              online    (este equipo)
  msi-operador             online    SSH:✔
```

Con la lista de operadores **fija** en el script (fácil de mantener):

```fish
set -l OPERADORES hp-operador msi-operador
```

---

## Cosas que mordieron (ver hallazgos)

| Hallazgo | Qué pasó |
|---|---|
| **H-41** | `ls` era alias de `eza --color=always` → contaminaba variables en scripts fish. Se usó `path filter`. |
| **H-42** | Migrar de disco regeneró el `machine-id` → **cambió el ID de RustDesk** y rompió el unattended. |
| **H-43** | Los 2 operadores compartían la misma clave SSH. Se separaron en identidades propias. |

---

## Checklist para añadir un operador nuevo

- [ ] Unir la máquina a la tailnet (`tailscale up`), con nombre `<algo>-operador`.
- [ ] Generar su clave propia (`id_<rol>_operador`).
- [ ] Autorizar su pública en los demás operadores y en los clientes.
- [ ] Meter su pública en el `kit` de altas (junto a las de los otros operadores).
- [ ] Añadir su nombre a la lista `OPERADORES` de `flota.sh`.
- [ ] Crear su `~/operador/` (kit + scripts + `AGENTS.md` propio, **no** copia).
- [ ] (Si tiene `sshd`) `systemctl enable --now sshd` para poder ser operado.
- [ ] Probar bidireccional: `<nuevo> → <existente>` y `<existente> → <nuevo>`.

---

## Operador móvil (Android/Termux)

Un teléfono puede ser operador más si en él corre **Termux** con Tailscale en
modo userspace (**H-60/H-61**). Es útil como operador de bolsillo: SSH a los
clientes sin depender del portátil/escritorio.

### Alta de un operador móvil

1. **Tailscale en Termux** (userspace + `proot`, ver H-60). Poner un hostname
   propio, distinto al de la app Android:

   ```
   <host>-termux        (ej. mi-telefono-termux)
   ```

2. **Clave propia** (jamás la de otro operador — H-43):

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/id_<rol>_operador -C "<rol>-operador@<host>"
   ```

3. **SSH por SOCKS5** (no hay `tun` en userspace), en `~/.ssh/config`:

   ```sshconfig
   Host <peer> 100.x.y.z
     ProxyCommand nc -X 5 -x localhost:1055 %h %p
   ```

4. **Autorizar su pública** en los demás operadores y en los clientes.

### Autorizar una clave — POSEE versión **fish**

Mandando la orden a un operador con **fish** (CachyOS), la sintaxis debe ser
fish, no bash (**H-23**). Cualquiera de estas sirve:

```fish
printf '%s\n' 'ssh-ed25519 AAAA... comentario' >> ~/.ssh/authorized_keys
```

```fish
cat >> ~/.ssh/authorized_keys << 'EOF'
ssh-ed25519 AAAA... comentario

---

## Operador móvil (Android/Termux)

Un teléfono puede ser operador más si en él corre **Termux** con Tailscale en
modo userspace (**H-60/H-61**). Es útil como operador de bolsillo: SSH a los
clientes sin depender del portátil/escritorio.

### Alta de un operador móvil

1. **Tailscale en Termux** (userspace + `proot`, ver H-60). Poner un hostname
   propio, distinto al de la app Android:

   ```
   <host>-termux        (ej. mi-telefono-termux)
   ```

2. **Clave propia** (jamás la de otro operador — H-43):

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/id_<rol>_operador -C "<rol>-operador@<host>"
   ```

3. **SSH por SOCKS5** (no hay `tun` en userspace), en `~/.ssh/config`:

   ```sshconfig
   Host <peer> 100.x.y.z
     ProxyCommand nc -X 5 -x localhost:1055 %h %p
   ```

4. **Autorizar su pública** en los demás operadores y en los clientes.

### Autorizar una clave — versión **fish**

Mandando la orden a un operador con **fish** (CachyOS), la sintaxis debe ser
fish, no bash (**H-23**). Cualquiera de estas sirve:

```fish
printf '%s\n' 'ssh-ed25519 AAAA... comentario' >> ~/.ssh/authorized_keys
```

```fish
cat >> ~/.ssh/authorized_keys << 'EOF'
ssh-ed25519 AAAA... comentario
EOF
```

> En bash también funciona `echo ... >>`, pero **no mandes bash a un objetivo
> fish**: es el error clásico de H-23.

### En Windows (cliente admin): `administrators_authorized_keys`

Si el usuario SSH es **administrador** de Windows, el `authorized_keys` normal
**se ignora**: hay que escribir en
`C:\ProgramData\ssh\administrators_authorized_keys` y arreglar permisos
(**H-57**):

```powershell
$f = 'C:\ProgramData\ssh\administrators_authorized_keys'
Add-Content -Path $f -Value '<clave-publica>' -Encoding ascii
icacls $f /inheritance:r /grant '*S-1-5-32-544:F' /grant 'SYSTEM:F'
```

> Usar el **SID** `*S-1-5-32-544`, no el nombre del grupo (en español es
> `Administradores`, no `Administrators`).

### Entrar a Windows pasando por un operador (jump)

Si tu clave aún no está en el cliente Windows, podés **saltar por un operador
que sí tenga acceso** (usa `ProxyJump`):

```bash
ssh -J jp@hp-operador qquet@rai 'whoami'
```

Y para mandar PowerShell sin el infierno de comillas, codificar en UTF-16LE +
base64 (**H-55**):

```bash
PS='Get-Service sshd'
ENC=$(printf '%s' "$PS" | iconv -t UTF-16LE | base64 -w0)
ssh rai "powershell -NoProfile -EncodedCommand $ENC"
```

> En una **misma sesión SSH a Windows**, `hostname`/`whoami` pueden fallar por el
> shell del objetivo (H-55); usar `echo %COMPUTERNAME%` o PowerShell.

---

## Malla completa (todos contra todos)

Cada operador entra a **todos** los demás — se pueda diagnosticar y probar la
flota de forma cruzada. Verificado 30-oct-2026 con **3 operadores** (HP, MSI,
móvil Android/Termux).

| Origen → Destino | Resultado |
|---|---|
| HP → MSI | ok |
| HP → móvil (a13) | ok |
| MSI → HP | ok |
| MSI → móvil (a13) | ok |
| móvil → HP / MSI / cliente | ok |

### Reglas de la malla

1. **Una clave por operador** (H-43). Cada `authorized_keys` lleva las públicas
   de los demás, nunca privadas.
2. **El nodo que recibe** expone su `sshd`:
   - Linux (HP/MSI): puerto 22.
   - **Móvil Termux**: puerto **8022**, usuario = el de Termux (`u0_aXXXX`),
     `sshd` con auto-arranque. **Un nodo userspace SÍ recibe** (ver H-63).
3. **En el que conecta**, un `Host` por operador con su `IdentityFile` y
   `IdentitiesOnly yes`:

   ```sshconfig
   Host a13 100.x.y.z
     HostName 100.x.y.z
     Port 8022
     User u0_aXXXX
     IdentityFile ~/.ssh/id_<rol>_operador
     IdentitiesOnly yes
   ```

### Ejemplo: entrar al móvil desde el HP

```bash
ssh -p 8022 u0_aXXXX@100.x.y.z 'whoami'
```

> Sin `IdentityFile` + `IdentitiesOnly`, SSH puede intentar la clave equivocada
> y dar `Permission denied` aunque la pública esté autorizada. Es el fallo más
> común al montar la malla.

### Hallazgo clave

El `tailscaled` en `--tun=userspace-networking` **no impide** las conexiones
entrantes: los peers alcanzan la IP `100.x` del móvil (ping + puerto 8022 OK).
Ver **H-63**.
