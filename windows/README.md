# Kit de acceso remoto — **Windows**

Equivalente Windows del kit de Linux. Prepara un PC con **Windows 10/11** para
soporte remoto con la misma filosofía: **RustDesk** (visual) + **OpenSSH Server**
(shell) + **Tailscale** (red privada) + **winget** (software).

> El operador es el mismo: desde un Linux (o cualquier equipo) se llega por
> Tailscale + SSH y, si hace falta la pantalla, por RustDesk.

## Scripts

| Script | Para qué |
|---|---|
| [`setup-remote-target.ps1`](setup-remote-target.ps1) | Instala y configura RustDesk + OpenSSH + Tailscale + winget. Idempotente. |
| [`inventory.ps1`](inventory.ps1) | Inventario de specs (texto / JSON / Markdown) para la ficha del cliente. |
| [`rustdesk-password.ps1`](rustdesk-password.ps1) | Verifica/fija la contraseña permanente de RustDesk (unattended). |
| [`diagnostico.ps1`](diagnostico.ps1) | **Diagnóstico de hardware**: apagones (Id 41), temperaturas, SMART, RAM, batería. |
| [`tests-windows.ps1`](tests-windows.ps1) | **Pruebas de humo** del kit (sintaxis, parámetros, seguridad); no toca el sistema. Equivale a `tests.sh` en Linux. |

## Uso rápido

Abrir **PowerShell como Administrador** en la carpeta y:

```powershell
# 1. Diagnóstico (no cambia nada)
Set-ExecutionPolicy -Scope Process Bypass -Force
.\setup-remote-target.ps1 -Check

# 2. Simulacro (muestra qué haría)
.\setup-remote-target.ps1 -DryRun

# 3. Aplicar (une a Tailscale con la auth key)
.\setup-remote-target.ps1 -Apply -AuthKey tskey-auth-xxxxx

# 4. Inventario para la ficha del cliente
.\inventory.ps1 -Out .\ficha

# 5. Contraseña permanente de RustDesk (H-15)
.\rustdesk-password.ps1 -Set -Password 'MiClaveSegura'

# 6. Pruebas de humo del kit (no cambia nada)
.\tests-windows.ps1
```

### Parámetros de `setup-remote-target.ps1`

| Parámetro | Efecto |
|---|---|
| `-Check` | Solo diagnóstico (por defecto si no se pasa nada → muestra ayuda). |
| `-DryRun` | Simula, sin tocar el sistema. |
| `-Apply` | Aplica los cambios (requiere **Administrador**). |
| `-AuthKey tskey-auth-...` | Une el equipo a la tailnet. La key se crea en https://login.tailscale.com/admin/settings/keys |
| `-RdPass 'Clave'` | Deja la contraseña permanente de RustDesk. |
| `-NoSsh` / `-NoTailscale` | Omite el componente (acceso solo visual, etc.). |

## Diagnóstico rápido desde el cliente (una línea, sin pegar)

Para diagnosticar un equipo remoto sin pedir credenciales ni pegar comandos
largos, el cliente (o tú por su pantalla) ejecuta **una sola línea** en
PowerShell:

```powershell
irm https://raw.githubusercontent.com/juanpablofuentealba/rustdesk-wlan-ssh-pi/main/windows/diagnostico.ps1 | iex
```

Recoge **apagones bruscos (Kernel-Power 41)**, temperaturas ACPI, salud/SMART
de discos, RAM, batería y top de procesos. **No cambia nada.** Para guardar el
informe:

```powershell
$s = irm https://raw.githubusercontent.com/juanpablofuentealba/rustdesk-wlan-ssh-pi/main/windows/diagnostico.ps1; iex "& { $s } -Out C:\kit\diag"
```

> **"Se apaga solo":** varios eventos **Id 41** = apagón **brusco** (hardware:
térmico o energía). **Id 1074** = apagado **planeado** (software/actualización).

## Trabajar por SSH en Windows (tip de quoting)

Al entrar por SSH a un Windows, el shell por defecto es **CMD**, y el
"quoting" de comandos complejos por SSH es un infierno (las comillas se comen).
El método **fiable** es enviar el comando a PowerShell en **base64**
(`-EncodedCommand`), que evita todo el problema:

```bash
# en el operador (Linux):
enc() { printf '%s' "$1" | iconv -t UTF-16LE | base64 -w0; }
PS='Get-PnpDevice | Where-Object { $_.Status -ne "OK" } | Select Status,Class,FriendlyName'
ssh rai "powershell -NoProfile -EncodedCommand $(enc "$PS")"
```

Otra opción: enviar el script por **STDIN** a `powershell -NoProfile -Command -`.

> Un comando de una sola línea simple (`hostname`, `whoami`) sí funciona directo:
> `ssh rai 'hostname'`.

## Autorizar tu clave SSH (ojo si el usuario es administrador)

Si el usuario SSH es **administrador** de Windows, el `authorized_keys` normal
**se ignora**: hay que escribir en
`C:\ProgramData\ssh\administrators_authorized_keys` y arreglar los permisos,
usando el **SID** del grupo (en Windows en español el grupo se llama
`Administradores`, no `Administrators`) — ver **H-57**:

```powershell
$f = 'C:\ProgramData\ssh\administrators_authorized_keys'
Add-Content -Path $f -Value '<clave-publica>' -Encoding ascii
icacls $f /inheritance:r /grant '*S-1-5-32-544:F' /grant 'SYSTEM:F'
```

## Notas y diferencias con Linux

- **La auth key de Tailscale se genera en la web**, no en el equipo (igual que
  en Linux; ver el README raíz).
- **OpenSSH** en Windows es una *Capability* (`Add-WindowsCapability`). Puede
  requerir **reinicio**.
- **RustDesk unattended**: en Windows basta el `.msi`; no hace falta el truco
  del `libdrmtap` para Wayland (eso es solo Linux, H-14/H-37).
- La contraseña permanente de RustDesk se puede fijar por `--password` (CLI) o,
  si la versión no lo acepta, por la **GUI**: Ajustes → Seguridad (H-15).

Detalles de problemas reales encontrados al escribir estos scripts:
[H-45, H-46 y H-47](../docs/hallazgos.md).

## Estado de las pruebas (⚠️ leer antes de confiar)

Los `.ps1` de este kit están **validados estáticamente**:

- `tests-windows.ps1` comprueba sintaxis con **PowerShell real** (pwsh), que no
  hay flags muertos, y reglas de seguridad (BOM UTF-8, etc.).
- El CI de GitHub ejecuta `PSScriptAnalyzer` y `tests-windows.ps1` en cada push.

**Pero NO se han probado todavía en un Windows real de punta a punta** (no había
equipo Windows disponible; ver **H-50**). Eso significa que la lógica de
`setup-remote-target.ps1` (instalación real de RustDesk/OpenSSH/Tailscale) está
revisada pero **no ejecutada sobre Windows**.

**Prueba pendiente** — se hará en un Windows dentro de **WinBoat** (contenedor
Windows en Linux) en el equipo MSI:

1. `sudo systemctl start docker` (o `podman`) en el host Linux.
2. Lanzar **WinBoat** → Windows desatendido.
3. Dentro de Windows: instalar `spice-guest-tools`, luego
   `Set-ExecutionPolicy -Scope Process Bypass -Force` y
   `.\setup-remote-target.ps1 -Check` → `-DryRun` → `-Apply`.
4. Verificar RustDesk + OpenSSH + Tailscale y reportar cualquier fallo como
   hallazgo nuevo.

Si encontrás un error al probarlo, **es exactamente el objetivo**: documentá el
hallazgo (H-XX) en [`../docs/hallazgos.md`](../docs/hallazgos.md) con la salida
real.
