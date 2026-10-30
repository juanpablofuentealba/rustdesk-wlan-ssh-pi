# Onboarding de un cliente nuevo (de cero a operativo)

Guía del **operador** para dar de alta un cliente y dejarlo administrable
remotamente, sin tocar nada a mano en su equipo.

> Dos herramientas, una para cada lado:
> - **`nuevo-cliente.sh`** — en **tu PC operador**: prepara ficha, kit y la
>   línea de instalación.
> - **`onboarding.sh`** — en **el PC del cliente**: instala todo en una línea.

---

## Resumen del flujo

```
[operador]  ~/operador/nuevo-cliente.sh juan
                │
                ├─ crea clientes/juan/ficha.txt
                ├─ empaqueta clientes/juan/kit-juan/  (+ operador.pub + MANIFEST)
                └─ imprime la línea de onboarding (con contraseña ya generada)
                        │
                        ▼
[cliente]  curl …/onboarding.sh | sudo bash -s -- --nombre juan --rdpass '…' …
                │
                ├─ baja el kit del repo y verifica integridad
                ├─ autoriza las claves de operadores (operadores/*.pub)
                ├─ instala RustDesk unattended + sshd + firewall + Tailscale
                ├─ fija la contraseña permanente de RustDesk
                └─ imprime la FICHA (ID, contraseña, IP tailnet)
                        │
                        ▼
[operador]  ~/operador/conectar.sh cliente-juan
            ~/operador/ayudar.sh   cliente-juan
            ~/operador/flota.sh
```

---

## 1. En el operador: preparar el alta

```fish
~/operador/nuevo-cliente.sh juan
```

Qué produce:

| Salida | Para qué |
|---|---|
| `clientes/juan/ficha.txt` | datos del cliente (se completa al instalar) |
| `clientes/juan/kit-juan/` | kit completo + `operador.pub` + `MANIFEST.sha256` verificado |
| línea `curl … \| sudo bash` | **copiar y pegar** en el cliente (contraseña incluida) |

Además imprime la **alternativa por pendrive** (si el cliente no tiene internet):

```fish
cp -r clientes/juan/kit-juan /run/media/$USER/PENDRIVE/
# en el cliente:
cd ~/kit-juan && chmod +x *.sh
sudo ./instalar-todo.sh --key "$(cat operador.pub)" --rdpass '…' --tailscale-luego
```

> **Claves:** `nuevo-cliente.sh` usa tu clave pública del operador
> (`~/.ssh/id_hp_operador.pub` o `id_msi_operador.pub`). Cada operador tiene su
> **propia** identidad — nunca se comparte la misma clave entre equipos (H-43).

---

## 2. En el cliente: instalar

### 2.1 Crear la auth key de Tailscale (si querés acceso fuera de la LAN)

Se crea en la **web**, no en el equipo:

`https://login.tailscale.com/admin/settings/keys` → **Generate auth key…**

- Para un solo equipo: *Reusable* NO, *Pre-approved* SÍ.
- Se muestra **una sola vez**: copiala.

### 2.2 Correr el onboarding

```bash
# La auth key por STDIN: no queda en el historial ni en 'ps'
curl -fsSL https://raw.githubusercontent.com/juanpablofuentealba/rustdesk-wlan-ssh-pi/main/onboarding.sh \
  | sudo bash -s -- --nombre juan --rdpass 'ClaveLarga2026' \
      --operador-hosts 'hp-operador msi-operador' --authkey-stdin
```

`onboarding.sh`:

1. **Baja el kit** del ref indicado (`--ref`, por defecto `main`) y **verifica**
   el `MANIFEST.sha256`.
2. **Resuelve las claves** de los operadores desde
   [`operadores/<host>.pub`](../operadores/) y las pasa a `instalar-todo.sh`.
3. Corre `instalar-todo.sh` con `--tailnet-host cliente-<nombre>` (para
   reconocer la flota de un vistazo).
4. **Imprime la ficha** con ID de RustDesk, contraseña, IP de Tailscale y distro.

### Casos especiales

| Situación | Flags |
|---|---|
| No tengo la auth key ahora | `--tailscale-luego` (instala TS sin unir; unir después con `unir-tailscale.sh`) |
| Solo LAN, sin Tailscale | `--skip-tailscale` |
| El cliente no tiene internet | `--local ~/kit-juan` (kit ya descargado) |
| Nombre en tailnet distinto | `--tailnet-host otro-nombre` |
| Simulacro | `--dry-run` |
| Sin confirmaciones | `--yes` |

> **Nunca** pongas la auth key ni la contraseña en la línea de comandos de un
> equipo ajeno si podés evitarlo: quedan en el historial. La auth key siempre
> por `--authkey-stdin`.

---

## 3. Verificar desde el operador

```fish
~/operador/conectar.sh cliente-juan   # tailnet + SSH + datos
~/operador/ayudar.sh   cliente-juan   # diagnóstico completo (disco, RAM, logs)
~/operador/flota.sh                   # estado de toda la flota
```

También:

```bash
./verify-offlan.sh cliente-juan       # acceso desde fuera de la LAN (7 comprobaciones)
./reboot-remoto.sh --host jp@cliente-juan --all   # reinicio unattended
```

---

## 4. Añadir un operador a la flota

Publicá tu clave **pública** (nunca la privada):

```bash
cp ~/.ssh/id_<operador>.pub operadores/<host>.pub
git add operadores/<host>.pub && git commit -m "operadores: alta <host>"
```

A partir de ahí, cualquier onboarding con
`--operador-hosts '<host>'` la autoriza automáticamente. Ver
[`operadores/README.md`](../operadores/README.md) y
[`docs/operador-multiple.md`](operador-multiple.md).

---

## Preguntas frecuentes

**¿Y si el cliente es Windows?** Este flujo es Linux. Para Windows hay
[`windows/`](../windows/) (`setup-remote-target.ps1` + `inventory.ps1`).

**¿RustDesk pide una contraseña que no es la de acceso remoto?** Es
`trusted_devices` sin `unlock_pin` → ver **H-67** en
[`hallazgos.md`](hallazgos.md).

**¿El equipo se "apaga solo" y se pierde el acceso?** Puede ser la suspensión
por inactividad/tapa; el onboarding ya corre `laptop-no-suspend.sh` en portátiles
(H-29). En Windows es otra cosa (Modern Standby, H-54).

**¿Cómo sé qué versión del kit corrió ese cliente?** El kit trae
`.kit-version` (`kit_version=…`, con el commit de git).
