# Autostart bloqueado en ZTE (Blade A54 / MyOS) — nodo a13

> Cómo nos dimos cuenta de que **ZTE bloquea el autoarranque de Termux** y qué
> hacemos para que el nodo a13 vuelva a la malla sin depender de eso.

---

## El síntoma

Tras reiniciar el ZTE Blade A54 (Android 13, MyOS), **el nodo a13 no se
levantaba solo**:

- `sshd` / `ssh-agent` no arrancaban hasta abrir Termux a mano.
- Termux:Boot estaba instalado, con permisos y en whitelist de Doze, pero
  **el boot script no se ejecutaba** (no aparecía `~/.termux/boot.log`).
- En una ocasión el teléfono quedó **sin red/malla** hasta correr el script
  manualmente desde a16.

Es decir: el `~/.termux/boot/20-malla-operadores.sh` **nunca corría**.

---

## La causa: `AutoLaunchManagerService` de ZTE

ZTE tiene un servicio propio (`AutoLaunch`) que decide qué apps pueden
autoarrancar. En el logcat, al reiniciar, aparece:

```
D AutoLaunchManagerService: Broadcast SelfStart BlockResult = true, callingPkg=com.termux.boot
D AutoLaunchManagerService: Broadcast SelfStart BlockResult = true, callingPkg=app.morphe.android.youtube
```

**Bloquea a TODAS las apps no-sistema**, no solo a Termux. Los campos que delatan
el veredicto:

| Campo                     | Permitido | Bloqueado |
|---------------------------|-----------|-----------|
| `BlockResult`             | `false`   | `true`    |
| `isNotPrivilegedOrSystemApp` | `true` | `true`    |
| `isEnabledPolicy`         | `true`    | `false`   |

Campos del log explicados:

- `compType=Broadcast` → es un **broadcast** (p.ej. `BOOT_COMPLETED`).
- `callingPkg=com.termux.boot` → quién intenta arrancar.
- `BlockResult=true` → **ZTE lo bloqueó**.

### Consecuencias confirmadas

- ❌ **Termux:Boot** (`BOOT_COMPLETED`) → bloqueado.
- ❌ **Termux:API** (`KeepAliveService`):

  ```bash
  $ termux-api-start
  Starting service: Intent { cmp=com.termux.api/.KeepAliveService }
  Error: Blocked by AutoLaunch
  ```

  Sin Termux:API, `termux-job-scheduler` **tampoco** sirve (depende de esa app).

- ❌ Cualquier app no-sistema que intente autoarrancar.

### No hay salida por config

- **No existe pantalla de "Auto-inicio/Autostart"** en este modelo
  (`AppManualOptimizeActivity` existe pero da `SecurityException` o abre un
  selector; no hay opción equivalente a MIUI/ColorOS).
- La whitelist de ZTE vive dentro del framework / `com.zte.powersavemode` y
  **no es legible ni editable por shell** (`/data/data/...` → Permission denied),
  ni con **Shizuku** (da permisos `shell` = uid 2000, **no root**).
- `dumpsys autolaunch` → denegado por SELinux (`scontext=u:r:shell:s0`).

**Pruebas realizadas para descartar vías:**

- `termux-job-scheduler --persisted` → no funciona (Termux:API bloqueado).
- Whitelist de Doze + standby bucket EXEMPTED → **no** anulan el AutoLaunch de ZTE.
- `am start` de activities de ZTE → requieren permisos de sistema.

---

## La solución (sin root): watchdog al abrir Termux

Como no hay root y ZTE no deja autoarrancar nada, **no es posible** el arranque
100% automático. Lo que hacemos es **reparar la malla al abrir Termux**.

### Pieza 1 — `~/bin/malla-watchdog.sh`

Script idempotente que revisa y repara:

1. `runsvdir` (lo arranca si falta).
2. `sshd` y `ssh-agent` (vía `sv up` si están caídos).
3. Llaves en el agente (`ssh-add` si faltan).
4. Tailscale userspace (`tailup.sh --start` si falta).
5. `termux-wake-lock`.

Log rotativo en `~/.malla-watchdog.log`.

Uso:

```bash
~/bin/malla-watchdog.sh            # repara todo
~/bin/malla-watchdog.sh --status   # solo reporta
tail ~/.malla-watchdog.log         # historial
```

### Pieza 2 — hook en `~/.bashrc`

```bash
if [ -x "$HOME/bin/malla-watchdog.sh" ]; then
  nohup "$HOME/bin/malla-watchdog.sh" >/dev/null 2>&1 &
fi
```

Así, **cada vez que se abre Termux**, la malla queda operativa en segundo plano
sin bloquear la shell.

### Flujo resultante

```
Reinicio del teléfono
   ↓
Abrir Termux (una vez)
   ↓
.bashrc → malla-watchdog.sh → repara runit + sshd + agente + llaves + tailscale
   ↓
Nodo a13 de nuevo en la malla
```

---

## Lo que NO sirve en este nodo (para no repetir intentos)

| Intento                                  | Resultado |
|------------------------------------------|-----------|
| Termux:Boot (`~/.termux/boot/`)          | Bloqueado por ZTE (`BlockResult=true`) |
| `termux-job-scheduler --persisted`       | Bloqueado (Termux:API no arranca) |
| Whitelist de Doze / standby EXEMPTED     | No afecta al AutoLaunch de ZTE |
| Activar "Autostart" en Ajustes           | **No existe** en este modelo |
| Shizuku/`rish` para editar la whitelist  | No hay acceso a las rutas de ZTE |
| `dumpsys autolaunch`                      | Denegado por SELinux |

---

## La única vía a autostart real: **root**

Con root (Magisk) se podría:

- Editar la whitelist de ZTE directamente.
- Usar un script en `service.d` que arranque SIEMPRE al boot, independiente de
  ZTE.

Sin root, el watchdog al abrir Termux es lo mejor posible.

> **Nota:** el nodo **a16** es de otro fabricante y **sí** arranca solo con
> Termux:Boot. El **msi-operador** (CachyOS) arranca solo con systemd. Solo el
> a13 (ZTE) sufre este bloqueo.

---

## Referencias de código

- `~/bin/malla-watchdog.sh` — el watchdog.
- `~/.bashrc` — hook que lo lanza al abrir Termux.
- `~/.termux/boot/20-malla-operadores.sh` — boot script (queda documentado
  aunque ZTE lo bloquee; sirve si algún día hay root o cambia el fabricante).
- `~/.malla-watchdog.log` — log de reparaciones.
