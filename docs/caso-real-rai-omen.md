# Caso real — cliente `rai` (HP Omen, Windows 11): "se apaga solo"

> Caso anonimizado (2026-10-29/30). Notebook gaming **HP Omen** con Windows 11,
> atendido **de punta a punta en remoto** (RustDesk + SSH por Tailscale).
> Complementa [`caso-real-apagon-solo.md`](caso-real-apagon-solo.md) y los
> hallazgos [H-54..H-62](hallazgos.md).

---

## La máquina

| Campo | Valor |
|---|---|
| Modelo | HP OMEN Gaming Laptop 16-wd0xxx |
| SO | Windows 11 Home (build 26200, 25H2) |
| CPU | Intel Core i5-13420H (8c/12t, RaptorLake-H) |
| RAM / SSD | 16 GB (2×8) / 477 GB Samsung (salud OK) |
| BIOS | Insyde F.26 (feb-2025) |
| Tailscale | nodo `rai` (Windows) |
| Acceso | RustDesk (pantalla) + SSH (consola) por Tailscale |

**Queja:** *"el equipo se apaga solo"*.

---

## Diagnóstico (solo lectura)

- **NO era apagón.** El equipo **se suspende** (Modern Standby S0) y a veces no
  despierta → pantalla negra que *parece* apagado.
- **`Kernel-Power 41` solo en septiembre** (17, 22 y 28-sep). El del **28-sep**
  fue un **BSOD `0x9F` = DRIVER_POWER_STATE_FAILURE** (un driver colgó al
  suspender).
- `powercfg /a`: **solo S0** (S1/S2/S3 no disponibles → firmware).
- `powercfg /sleepstudy`: **297 transiciones** de energía en bucle.
- **Fast Startup estaba activado** (causa clásica del `0x9F`).
- **`XTU3SERVICE` corriendo**; el log de XTU muestra que el OC de CPU **no está
  aplicado** (chip `-H` lo bloquea), pero XTU queda en estado inconsistente
  (**H-58/H-59**).

## Arreglo aplicado (29-oct, por SSH)

| Cambio | Antes | Ahora |
|---|---|---|
| Inicio rápido / hibernación | activado | `powercfg /h off` |
| Suspensión en AC | 5 min | **nunca** |
| Tapa en AC | suspender | **no hacer nada** |

Todo **reversible**; backup de `powercfg` guardado en el equipo.

**Decisión:** **no** actualizar drivers/firmware (equipo con OC + hacks — [H-56]).

---

## Seguimiento (30-oct, por SSH, solo lectura)

Verificado un día después del arreglo:

| Check | Resultado |
|---|---|
| `Id41` (apagones) nuevos | ✅ **ninguno** desde 28-sep |
| BSOD nuevos | ✅ ninguno |
| `sshd` / `Tailscale` | ✅ Running/Automatic |
| Disco C: | 141 GB libres de 476 |
| **`Kernel-Power 506/507` últimas 24h** | ⚠️ **58/58** (sigue suspendiéndose) |
| **`HiberbootEnabled`** | ⚠️ **1** (Fast Startup **volvió a activarse** — [H-62]) |
| `XTU3SERVICE` | ⚠️ Running (candidato a desactivar, [H-59]) |

**Interpretación:** los apagones secos (`0x9F`) **cedieron**, pero el **bucle de
suspensión sigue** (58 en 24 h). El patrón horario muestra picos en horas de
mantenimiento (06h, 14h, 18h) → coherente con **`Maintenance Scheduler`**
despertando y durmiendo el equipo.

**Pendiente (no aplicado, es cambio):** desactivar `XTU3SERVICE` (reversible) y
ver si baja el bucle; confirmar si el `Fast Startup` se re-activó solo tras el
reinicio (H-62).

---

## Acceso como operador (H-43)

- El **HP** (`hp-operador`) tiene su clave propia autorizada en el Omen.
- Un nuevo **operador móvil Android/Termux** (`zte-blade-a54-termux`, ver H-60)
  se autorizó **directamente** en `rai` vía
  `C:\ProgramData\ssh\administrators_authorized_keys` (el usuario es admin —
  **H-57**, y este fue el fallo típico: el archivo `.ssh\authorized_keys` normal
  se ignora para administradores).

---

## Reproducir

Desde el operador (con clave ya autorizada):

```bash
ssh rai 'echo %COMPUTERNAME%'
# PowerShell sin infierno de comillas (H-55):
PS='Get-WinEvent -FilterHashtable @{LogName="System";Id=41} -MaxEvents 3'
ENC=$(printf '%s' "$PS" | iconv -t UTF-16LE | base64 -w0)
ssh rai "powershell -NoProfile -EncodedCommand $ENC"
```
