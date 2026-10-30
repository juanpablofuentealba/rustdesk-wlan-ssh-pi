# Caso real — "el equipo se apaga solo" (Windows, soporte remoto)

> Caso anonimizado de un trabajo real (2026-10-29). Notebook gaming,
> Windows 11, redes distintas, cliente que **no sabe usar RustDesk**.
> Incluye los tropiezos y cómo se resolvieron (todo aprendizaje).

---

## Punto de partida

- **Cliente:** usuario de un notebook (marca gaming), Windows 11.
- **Queja:** *"la máquina se apaga sola"*.
- **Acceso inicial:** RustDesk por **redes distintas** (el cliente pasó ID +
  contraseña por chat). Desconfiar de que sepa leerlos bien.

---

## Lo que salió mal (y cómo se resolvió)

| # | Problema | Solución | Hallazgo |
|---|---|---|---|
| 1 | El cliente **no sabía RustDesk**; se cayó la conexión a mitad | — (aprendido: fijar contraseña permanente ANTES) | [H-53](../docs/hallazgos.md) |
| 2 | Los `.ps1` del kit fallaban en Windows: `Token '}' inesperado` | Los `.ps1` necesitan **BOM UTF-8** (Windows PowerShell 5.1) | [H-51](../docs/hallazgos.md) |
| 3 | Tras subir el fix, la URL seguía sirviendo el archivo viejo | Caché de **GitHub raw**; verificar por SHA | [H-52](../docs/hallazgos.md) |
| 4 | `Add-WindowsCapability OpenSSH.Server` **se colgó** | Instalar OpenSSH **directo de GitHub** | [H-57](../docs/hallazgos.md) |
| 5 | SSH rechazaba la clave | Faltaba usar `-i id_operador` y **permisos** correctos | [H-57](../docs/hallazgos.md) |
| 6 | Comandos complejos por SSH fallaban (quoting CMD) | `powershell -EncodedCommand` (base64) | [H-55](../docs/hallazgos.md) |
| 7 | "Se apaga solo" parecía hardware | Era **Modern Standby (S0)** roto | [H-54](../docs/hallazgos.md) |
| 8 | Windows tenía drivers/firmware pendientes | **NO** actualizar: el equipo tiene **overclock + hacks** | [H-56](../docs/hallazgos.md) |

---

## El diagnóstico que SÍ funcionó

1. **Eventos:** sin `Id 41` reciente (solo uno en septiembre, con BSOD `0x9F`).
   Los eventos reales eran **`506/507`** = "entrando/saliendo del modo de espera
   moderno". → **no era apagón, era suspensión.**
2. **`powercfg /a`:** solo existe **S0** (sin S1/S2/S3).
3. **`powercfg /sleepstudy`:** **297 transiciones** de energía en bucle.
4. **Arreglo:** `powercfg /h off`, `standby-timeout-ac 0`, tapa AC = nada.

---

## Decisión clave: NO actualizar software

Windows ofrecía **7 actualizaciones** (firmware HP, Intel Display, NVIDIA...).
Parecía la solución. **Pero el dueño usa overclock + hacks/exploits** →
actualizar podría **resetear el OC**, **romper exploits** o **empeorar** el
problema. Se decidió **no tocar** y aplicar solo los ajustes de energía.

> Posible causa de fondo: **overclock inestable** → las transiciones de energía
> fallan → cuelgue seco (`0x9F`). Eso es **tema del dueño**, no del técnico.

## La verificación que cambió la conclusión

Antes de cerrar, se **verificó de verdad** si había overclock leyendo el log de
XTU ([H-58](../docs/hallazgos.md)):

```
Processor model is: H
ERR] Attempted to read OCMB fieldId NN on an invalid platform
ERR] Max proposed AC ratio resolved to <= 0.
WARN] Application Persistence - Proposed setting changes failed validation
```

**Resultado:** el **OC de CPU NO estaba aplicado** (chip `-H` de portátil →
bloqueado por firmware). XTU llevaba **desde mayo-2023** instalado e intentándolo
en cada arranque, fallando siempre ([H-59](../docs/hallazgos.md)).

**Conclusión corregida:** no es un "overclock" clásico, sino **XTU en estado
inconsistente** (componente `Degraded`) tocando TDP/voltaje. La decisión de no
actualizar **sigue siendo correcta**, y si vuelve a colgarse la prueba lógica es
**desactivar `XTU3SERVICE`** (reversible).

---

## Resultado

- **3 vías de acceso** al cliente: Tailscale (directo), SSH, RustDesk (clave fija).
- Problema del "se apaga" **mitigado** con ajustes de energía (reversibles).
- **Monitoreo automático** cada 30 min.
- Ficha e informe del cliente guardados.

---

## Lecciones transversales (para futuros casos)

1. **Acceso primero** (contraseña permanente), antes de tocar nada. [H-53]
2. **Probar en Windows real**: `pwsh` en Linux no caza todo (BOM, [H-51]).
3. **El shell del objetivo es parte del problema** ([H-23], [H-55]).
4. **"Se apaga solo" ≠ apagón**: mirar `Id 41` vs `506/507`. [H-54]
5. **Averiguar si el equipo está personalizado** antes de actualizar. [H-56]
6. **Componentes de Windows se cuelgan**: preferir paquetes directos. [H-57]
