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
